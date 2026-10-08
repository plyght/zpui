//! Activity monitor over the PulseAudio protocol (PulseAudio itself or
//! pipewire-pulse): subscribes to sink-input and source-output events and,
//! on each, re-lists them. Other audio = an uncorked sink input of another
//! process; mic in use = an uncorked source output of another process
//! (pavucontrol-style peak meters are ignored). Runs on its own
//! `pa_threaded_mainloop`, idle in poll() between events.

const std = @import("std");
const pulse = @import("pulse.zig");
const activity = @import("activity.zig");
const ActivityMonitor = activity.ActivityMonitor;

const Proplist = opaque {};
const SampleSpec = pulse.SampleSpec;

const SinkInputInfo = extern struct {
    index: u32,
    name: ?[*:0]const u8,
    owner_module: u32,
    client: u32,
    sink: u32,
    sample_spec: SampleSpec,
    channel_map: [33]u32,
    volume: [33]u32,
    buffer_usec: u64,
    sink_usec: u64,
    resample_method: ?[*:0]const u8,
    driver: ?[*:0]const u8,
    mute: c_int,
    proplist: ?*Proplist,
    corked: c_int,
};
const SourceOutputInfo = extern struct {
    index: u32,
    name: ?[*:0]const u8,
    owner_module: u32,
    client: u32,
    source: u32,
    sample_spec: SampleSpec,
    channel_map: [33]u32,
    buffer_usec: u64,
    source_usec: u64,
    resample_method: ?[*:0]const u8,
    driver: ?[*:0]const u8,
    proplist: ?*Proplist,
    corked: c_int,
};
comptime {
    // libpulse ABI (checked against pulse/introspect.h on x86_64/aarch64).
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@offsetOf(SinkInputInfo, "proplist") == 344);
        std.debug.assert(@offsetOf(SinkInputInfo, "corked") == 352);
        std.debug.assert(@offsetOf(SourceOutputInfo, "proplist") == 208);
        std.debug.assert(@offsetOf(SourceOutputInfo, "corked") == 216);
    }
}

const Context = pulse.Context;
const Operation = pulse.Operation;
const SubscribeCb = *const fn (*Context, c_uint, u32, ?*anyopaque) callconv(.c) void;
const SinkInputCb = *const fn (*Context, ?*const SinkInputInfo, c_int, ?*anyopaque) callconv(.c) void;
const SourceOutputCb = *const fn (*Context, ?*const SourceOutputInfo, c_int, ?*anyopaque) callconv(.c) void;

const Fns = struct {
    pa_context_set_subscribe_callback: *const fn (*Context, ?SubscribeCb, ?*anyopaque) callconv(.c) void,
    pa_context_subscribe: *const fn (*Context, c_uint, ?*const anyopaque, ?*anyopaque) callconv(.c) ?*Operation,
    pa_context_get_sink_input_info_list: *const fn (*Context, SinkInputCb, ?*anyopaque) callconv(.c) ?*Operation,
    pa_context_get_source_output_info_list: *const fn (*Context, SourceOutputCb, ?*anyopaque) callconv(.c) ?*Operation,
    pa_proplist_gets: *const fn (*Proplist, [*:0]const u8) callconv(.c) ?[*:0]const u8,
};

const PA_SUBSCRIPTION_MASK_SINK_INPUT = 0x4;
const PA_SUBSCRIPTION_MASK_SOURCE_OUTPUT = 0x8;

pub const Monitor = struct {
    gpa: std.mem.Allocator,
    pa: *const pulse.Fns,
    fns: Fns,
    owner: *ActivityMonitor,
    ml: *pulse.Mainloop,
    ctx: *Context = undefined,
    own_pid: u32,
    // Mainloop-thread state for one refresh pass.
    pending: u8 = 0,
    dirty: bool = false,
    other: bool = false,
    mic: bool = false,

    pub fn open(gpa: std.mem.Allocator, owner: *ActivityMonitor) ?*Monitor {
        const pa = pulse.library() orelse return null;
        // The introspection symbols live in the same libpulse.so.0.
        const lib = @import("sys.zig").DynLib.open(&.{ "libpulse.so.0", "libpulse.so" }) orelse return null;
        const fns = lib.load(Fns) orelse return null;
        const ml = pa.pa_threaded_mainloop_new() orelse return null;
        const self = gpa.create(Monitor) catch {
            pa.pa_threaded_mainloop_free(ml);
            return null;
        };
        self.* = .{ .gpa = gpa, .pa = pa, .fns = fns, .owner = owner, .ml = ml, .own_pid = activity.ownPid() };
        if (pa.pa_threaded_mainloop_start(ml) < 0) {
            pa.pa_threaded_mainloop_free(ml);
            gpa.destroy(self);
            return null;
        }
        pa.pa_threaded_mainloop_lock(ml);
        const ctx = pulse.connectContext(pa, ml, "zpui activity monitor");
        if (ctx) |c| {
            self.ctx = c;
            fns.pa_context_set_subscribe_callback(c, onEvent, self);
            if (fns.pa_context_subscribe(c, PA_SUBSCRIPTION_MASK_SINK_INPUT | PA_SUBSCRIPTION_MASK_SOURCE_OUTPUT, null, null)) |op| pa.pa_operation_unref(op);
            self.refresh();
        }
        pa.pa_threaded_mainloop_unlock(ml);
        if (ctx == null) {
            pa.pa_threaded_mainloop_stop(ml);
            pa.pa_threaded_mainloop_free(ml);
            gpa.destroy(self);
            return null;
        }
        return self;
    }

    pub fn close(self: *Monitor) void {
        const pa = self.pa;
        pa.pa_threaded_mainloop_lock(self.ml);
        self.fns.pa_context_set_subscribe_callback(self.ctx, null, null);
        pa.pa_context_set_state_callback(self.ctx, null, null);
        pa.pa_context_disconnect(self.ctx);
        pa.pa_context_unref(self.ctx);
        pa.pa_threaded_mainloop_unlock(self.ml);
        pa.pa_threaded_mainloop_stop(self.ml);
        pa.pa_threaded_mainloop_free(self.ml);
        self.gpa.destroy(self);
    }

    /// Mainloop thread: re-list sink inputs and source outputs (coalescing
    /// events that arrive while a pass is running).
    fn refresh(self: *Monitor) void {
        if (self.pending != 0) {
            self.dirty = true;
            return;
        }
        self.dirty = false;
        self.other = false;
        self.mic = false;
        if (self.fns.pa_context_get_sink_input_info_list(self.ctx, onSinkInput, self)) |op| {
            self.pa.pa_operation_unref(op);
            self.pending += 1;
        }
        if (self.fns.pa_context_get_source_output_info_list(self.ctx, onSourceOutput, self)) |op| {
            self.pa.pa_operation_unref(op);
            self.pending += 1;
        }
    }

    fn finishOne(self: *Monitor) void {
        self.pending -|= 1;
        if (self.pending != 0) return;
        self.owner.publish(.{ .other_audio = self.other, .mic_in_use = self.mic });
        if (self.dirty) self.refresh();
    }

    fn isOurs(self: *Monitor, props: ?*Proplist) bool {
        const p = props orelse return false;
        const pid = self.fns.pa_proplist_gets(p, "application.process.id") orelse return false;
        const n = std.fmt.parseInt(u32, std.mem.span(pid), 10) catch return false;
        return n == self.own_pid;
    }

    fn isPeakMeter(self: *Monitor, props: ?*Proplist) bool {
        const p = props orelse return false;
        const name = self.fns.pa_proplist_gets(p, "media.name") orelse return false;
        return std.mem.eql(u8, std.mem.span(name), "Peak detect");
    }

    fn onEvent(_: *Context, _: c_uint, _: u32, ud: ?*anyopaque) callconv(.c) void {
        const self: *Monitor = @ptrCast(@alignCast(ud.?));
        self.refresh();
    }

    fn onSinkInput(_: *Context, info: ?*const SinkInputInfo, eol: c_int, ud: ?*anyopaque) callconv(.c) void {
        const self: *Monitor = @ptrCast(@alignCast(ud.?));
        if (eol != 0 or info == null) return self.finishOne();
        const i = info.?;
        if (i.corked == 0 and !self.isOurs(i.proplist) and !self.isPeakMeter(i.proplist)) self.other = true;
    }

    fn onSourceOutput(_: *Context, info: ?*const SourceOutputInfo, eol: c_int, ud: ?*anyopaque) callconv(.c) void {
        const self: *Monitor = @ptrCast(@alignCast(ud.?));
        if (eol != 0 or info == null) return self.finishOne();
        const i = info.?;
        if (i.corked == 0 and !self.isOurs(i.proplist) and !self.isPeakMeter(i.proplist)) self.mic = true;
    }
};
