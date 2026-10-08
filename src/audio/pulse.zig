//! PulseAudio output (also pipewire-pulse) via libpulse.so.0, loaded with
//! dlopen. A playback stream on a `pa_threaded_mainloop`: the server asks
//! for data through the write callback, which renders on the mainloop
//! thread. Suspend/resume corks/uncorks the stream (connection, stream and
//! thread stay up; a corked stream gets no write requests). The server
//! moves the stream to a new default sink by itself.

const std = @import("std");
const sys = @import("sys.zig");
const engine = @import("engine.zig");
const Engine = engine.Engine;

pub const Mainloop = opaque {};
pub const Api = opaque {};
pub const Context = opaque {};
pub const Stream = opaque {};
pub const Operation = opaque {};

pub const SampleSpec = extern struct { format: c_int, rate: u32, channels: u8 };
pub const BufferAttr = extern struct { maxlength: u32, tlength: u32, prebuf: u32, minreq: u32, fragsize: u32 };

pub const ContextStateCb = *const fn (*Context, ?*anyopaque) callconv(.c) void;
const StreamStateCb = *const fn (*Stream, ?*anyopaque) callconv(.c) void;
const WriteCb = *const fn (*Stream, usize, ?*anyopaque) callconv(.c) void;

pub const Fns = struct {
    pa_threaded_mainloop_new: *const fn () callconv(.c) ?*Mainloop,
    pa_threaded_mainloop_free: *const fn (*Mainloop) callconv(.c) void,
    pa_threaded_mainloop_start: *const fn (*Mainloop) callconv(.c) c_int,
    pa_threaded_mainloop_stop: *const fn (*Mainloop) callconv(.c) void,
    pa_threaded_mainloop_lock: *const fn (*Mainloop) callconv(.c) void,
    pa_threaded_mainloop_unlock: *const fn (*Mainloop) callconv(.c) void,
    pa_threaded_mainloop_wait: *const fn (*Mainloop) callconv(.c) void,
    pa_threaded_mainloop_signal: *const fn (*Mainloop, c_int) callconv(.c) void,
    pa_threaded_mainloop_get_api: *const fn (*Mainloop) callconv(.c) *Api,
    pa_context_new: *const fn (*Api, [*:0]const u8) callconv(.c) ?*Context,
    pa_context_set_state_callback: *const fn (*Context, ?ContextStateCb, ?*anyopaque) callconv(.c) void,
    pa_context_connect: *const fn (*Context, ?[*:0]const u8, c_uint, ?*const anyopaque) callconv(.c) c_int,
    pa_context_get_state: *const fn (*Context) callconv(.c) c_int,
    pa_context_disconnect: *const fn (*Context) callconv(.c) void,
    pa_context_unref: *const fn (*Context) callconv(.c) void,
    pa_stream_new: *const fn (*Context, [*:0]const u8, *const SampleSpec, ?*const anyopaque) callconv(.c) ?*Stream,
    pa_stream_set_state_callback: *const fn (*Stream, ?StreamStateCb, ?*anyopaque) callconv(.c) void,
    pa_stream_set_write_callback: *const fn (*Stream, ?WriteCb, ?*anyopaque) callconv(.c) void,
    pa_stream_connect_playback: *const fn (*Stream, ?[*:0]const u8, ?*const BufferAttr, c_uint, ?*const anyopaque, ?*Stream) callconv(.c) c_int,
    pa_stream_get_state: *const fn (*Stream) callconv(.c) c_int,
    pa_stream_begin_write: *const fn (*Stream, *?*anyopaque, *usize) callconv(.c) c_int,
    pa_stream_write: *const fn (*Stream, *const anyopaque, usize, ?*const anyopaque, i64, c_int) callconv(.c) c_int,
    pa_stream_cork: *const fn (*Stream, c_int, ?*const anyopaque, ?*anyopaque) callconv(.c) ?*Operation,
    pa_stream_get_buffer_attr: *const fn (*Stream) callconv(.c) ?*const BufferAttr,
    pa_stream_disconnect: *const fn (*Stream) callconv(.c) c_int,
    pa_stream_unref: *const fn (*Stream) callconv(.c) void,
    pa_operation_unref: *const fn (*Operation) callconv(.c) void,
};

var lib_once: std.atomic.Value(u8) = .init(0); // 0 untried, 1 loading, 2 ok, 3 failed
var lib_fns: Fns = undefined;

/// Loads libpulse once per process (it stays loaded).
pub fn library() ?*const Fns {
    switch (lib_once.load(.acquire)) {
        2 => return &lib_fns,
        3 => return null,
        else => {},
    }
    while (lib_once.cmpxchgWeak(0, 1, .acquire, .acquire)) |v| switch (v) {
        2 => return &lib_fns,
        3 => return null,
        else => std.atomic.spinLoopHint(),
    };
    const ok = blk: {
        const lib = sys.DynLib.open(&.{ "libpulse.so.0", "libpulse.so" }) orelse break :blk false;
        lib_fns = lib.load(Fns) orelse break :blk false;
        break :blk true;
    };
    lib_once.store(if (ok) 2 else 3, .release);
    return if (ok) &lib_fns else null;
}

pub const PA_SAMPLE_FLOAT32LE = 5;
pub const PA_CONTEXT_NOAUTOSPAWN = 1;
pub const PA_CONTEXT_READY = 4;
pub const PA_CONTEXT_FAILED = 5;
pub const PA_CONTEXT_TERMINATED = 6;
const PA_STREAM_READY = 2;
const PA_STREAM_FAILED = 3;
const PA_STREAM_TERMINATED = 4;
const PA_STREAM_START_CORKED = 0x1;
const PA_STREAM_ADJUST_LATENCY = 0x2000;
const PA_SEEK_RELATIVE = 0;

/// Connects a context on a running threaded mainloop and waits until it is
/// ready. Call with the mainloop locked. Shared with the activity monitor.
pub fn connectContext(fns: *const Fns, ml: *Mainloop, name: [*:0]const u8) ?*Context {
    const ctx = fns.pa_context_new(fns.pa_threaded_mainloop_get_api(ml), name) orelse return null;
    fns.pa_context_set_state_callback(ctx, signalMainloop, ml);
    if (fns.pa_context_connect(ctx, null, PA_CONTEXT_NOAUTOSPAWN, null) < 0) {
        fns.pa_context_unref(ctx);
        return null;
    }
    while (true) {
        const st = fns.pa_context_get_state(ctx);
        if (st == PA_CONTEXT_READY) return ctx;
        if (st == PA_CONTEXT_FAILED or st == PA_CONTEXT_TERMINATED) {
            fns.pa_context_disconnect(ctx);
            fns.pa_context_unref(ctx);
            return null;
        }
        fns.pa_threaded_mainloop_wait(ml);
    }
}

fn signalMainloop(_: *Context, ud: ?*anyopaque) callconv(.c) void {
    lib_fns.pa_threaded_mainloop_signal(@ptrCast(ud.?), 0);
}

pub const Backend = struct {
    gpa: std.mem.Allocator,
    fns: *const Fns,
    engine: *Engine,
    info: engine.DeviceInfo = .{},
    ml: *Mainloop,
    ctx: ?*Context = null,
    stream: ?*Stream = null,

    pub fn open(gpa: std.mem.Allocator, e: *Engine, o: engine.OpenOptions) engine.OpenError!*Backend {
        const fns = library() orelse return error.Unavailable;
        const ml = fns.pa_threaded_mainloop_new() orelse return error.Unavailable;
        const self = gpa.create(Backend) catch {
            fns.pa_threaded_mainloop_free(ml);
            return error.OutOfMemory;
        };
        self.* = .{ .gpa = gpa, .fns = fns, .engine = e, .ml = ml };
        if (fns.pa_threaded_mainloop_start(ml) < 0) {
            fns.pa_threaded_mainloop_free(ml);
            gpa.destroy(self);
            return error.Unavailable;
        }
        fns.pa_threaded_mainloop_lock(ml);
        const ok = self.connect(o);
        fns.pa_threaded_mainloop_unlock(ml);
        if (!ok) {
            self.destroy();
            return error.Unavailable;
        }
        return self;
    }

    fn connect(self: *Backend, o: engine.OpenOptions) bool {
        const fns = self.fns;
        self.ctx = connectContext(fns, self.ml, o.app_name.ptr) orelse return false;
        const spec: SampleSpec = .{ .format = PA_SAMPLE_FLOAT32LE, .rate = o.rate, .channels = 2 };
        const s = fns.pa_stream_new(self.ctx.?, o.app_name.ptr, &spec, null) orelse return false;
        self.stream = s;
        fns.pa_stream_set_state_callback(s, onStreamState, self);
        fns.pa_stream_set_write_callback(s, onWrite, self);
        const period: u32 = if (o.buffer_frames != 0) o.buffer_frames else 256;
        const none = std.math.maxInt(u32);
        const attr: BufferAttr = .{ .maxlength = none, .tlength = period * 2 * 8, .prebuf = none, .minreq = period * 8, .fragsize = none };
        if (fns.pa_stream_connect_playback(s, null, &attr, PA_STREAM_START_CORKED | PA_STREAM_ADJUST_LATENCY, null, null) < 0) return false;
        while (true) {
            const st = fns.pa_stream_get_state(s);
            if (st == PA_STREAM_READY) break;
            if (st == PA_STREAM_FAILED or st == PA_STREAM_TERMINATED) return false;
            fns.pa_threaded_mainloop_wait(self.ml);
        }
        const got = fns.pa_stream_get_buffer_attr(s);
        const tlength = if (got) |a| a.tlength else attr.tlength;
        const minreq = if (got) |a| a.minreq else attr.minreq;
        self.info = .{
            .rate = o.rate,
            .channels = 2,
            .period_frames = minreq / 8,
            .latency_ns = @as(u64, tlength / 8) * std.time.ns_per_s / o.rate,
        };
        return true;
    }

    fn destroy(self: *Backend) void {
        const fns = self.fns;
        fns.pa_threaded_mainloop_lock(self.ml);
        if (self.stream) |s| {
            fns.pa_stream_set_write_callback(s, null, null);
            fns.pa_stream_set_state_callback(s, null, null);
            _ = fns.pa_stream_disconnect(s);
            fns.pa_stream_unref(s);
        }
        if (self.ctx) |c| {
            fns.pa_context_set_state_callback(c, null, null);
            fns.pa_context_disconnect(c);
            fns.pa_context_unref(c);
        }
        fns.pa_threaded_mainloop_unlock(self.ml);
        fns.pa_threaded_mainloop_stop(self.ml);
        fns.pa_threaded_mainloop_free(self.ml);
        self.gpa.destroy(self);
    }

    pub fn close(self: *Backend) void {
        self.destroy();
    }

    fn cork(self: *Backend, b: bool) bool {
        self.fns.pa_threaded_mainloop_lock(self.ml);
        defer self.fns.pa_threaded_mainloop_unlock(self.ml);
        const s = self.stream orelse return false;
        if (self.fns.pa_stream_get_state(s) != PA_STREAM_READY) return false;
        const op = self.fns.pa_stream_cork(s, @intFromBool(b), null, null) orelse return false;
        self.fns.pa_operation_unref(op);
        return true;
    }

    pub fn start(self: *Backend) bool {
        return self.cork(false);
    }

    pub fn stop(self: *Backend) void {
        _ = self.cork(true);
    }

    pub fn deviceChanged(_: *Backend, _: bool) void {}

    fn onStreamState(_: *Stream, ud: ?*anyopaque) callconv(.c) void {
        const self: *Backend = @ptrCast(@alignCast(ud.?));
        self.fns.pa_threaded_mainloop_signal(self.ml, 0);
    }

    fn onWrite(s: *Stream, nbytes: usize, ud: ?*anyopaque) callconv(.c) void {
        const self: *Backend = @ptrCast(@alignCast(ud.?));
        var left = nbytes;
        while (left >= 8) {
            var ptr: ?*anyopaque = null;
            var size: usize = left;
            if (self.fns.pa_stream_begin_write(s, &ptr, &size) < 0) return;
            const p = ptr orelse return;
            const frames = @min(size, left) / 8;
            if (frames == 0) return;
            const out: [*]f32 = @ptrCast(@alignCast(p));
            self.engine.render(f32, out[0 .. frames * 2], frames, 2);
            if (self.fns.pa_stream_write(s, p, frames * 8, null, 0, PA_SEEK_RELATIVE) < 0) return;
            left -= frames * 8;
        }
    }
};
