//! PipeWire output via libpipewire-0.3, loaded with dlopen (no build-time
//! dependency). A `pw_stream` with RT_PROCESS: the mixer renders directly
//! on PipeWire's real-time data thread. The stream is connected once
//! (inactive) and toggled with `pw_stream_set_active` for suspend/resume,
//! so an idle app has no node in the graph schedule and no wakeups.
//! AUTOCONNECT without a target follows the default sink automatically.

const std = @import("std");
const sys = @import("sys.zig");
const engine = @import("engine.zig");
const Engine = engine.Engine;
const log = std.log.scoped(.zpui_audio);

const ThreadLoop = opaque {};
const Loop = opaque {};
const Props = opaque {};
const Stream = opaque {};

const SpaChunk = extern struct { offset: u32, size: u32, stride: i32, flags: i32 };
const SpaData = extern struct {
    type: u32,
    flags: u32,
    fd: i64,
    mapoffset: u32,
    maxsize: u32,
    data: ?*anyopaque,
    chunk: *SpaChunk,
};
const SpaBuffer = extern struct { n_metas: u32, n_datas: u32, metas: ?*anyopaque, datas: [*]SpaData };
/// `requested` exists since 0.3.49 (checked at run time before reading).
const PwBuffer = extern struct { buffer: *SpaBuffer, user_data: ?*anyopaque, size: u64, requested: u64 };

const StreamEvents = extern struct {
    version: u32 = 2,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void = null,
    state_changed: ?*const fn (?*anyopaque, c_int, c_int, ?[*:0]const u8) callconv(.c) void = null,
    control_info: ?*const anyopaque = null,
    io_changed: ?*const anyopaque = null,
    param_changed: ?*const anyopaque = null,
    add_buffer: ?*const anyopaque = null,
    remove_buffer: ?*const anyopaque = null,
    process: ?*const fn (?*anyopaque) callconv(.c) void = null,
    drained: ?*const anyopaque = null,
    command: ?*const anyopaque = null,
    trigger_done: ?*const anyopaque = null,
};

pub const Fns = struct {
    pw_init: *const fn (?*c_int, ?*anyopaque) callconv(.c) void,
    pw_get_library_version: *const fn () callconv(.c) [*:0]const u8,
    pw_thread_loop_new: *const fn (?[*:0]const u8, ?*const anyopaque) callconv(.c) ?*ThreadLoop,
    pw_thread_loop_get_loop: *const fn (*ThreadLoop) callconv(.c) ?*Loop,
    pw_thread_loop_start: *const fn (*ThreadLoop) callconv(.c) c_int,
    pw_thread_loop_stop: *const fn (*ThreadLoop) callconv(.c) void,
    pw_thread_loop_destroy: *const fn (*ThreadLoop) callconv(.c) void,
    pw_thread_loop_lock: *const fn (*ThreadLoop) callconv(.c) void,
    pw_thread_loop_unlock: *const fn (*ThreadLoop) callconv(.c) void,
    pw_properties_new_string: *const fn ([*:0]const u8) callconv(.c) ?*Props,
    pw_properties_set: *const fn (*Props, [*:0]const u8, ?[*:0]const u8) callconv(.c) c_int,
    pw_stream_new_simple: *const fn (*Loop, [*:0]const u8, *Props, *const StreamEvents, ?*anyopaque) callconv(.c) ?*Stream,
    pw_stream_connect: *const fn (*Stream, u32, u32, u32, [*]const *const anyopaque, u32) callconv(.c) c_int,
    pw_stream_dequeue_buffer: *const fn (*Stream) callconv(.c) ?*PwBuffer,
    pw_stream_queue_buffer: *const fn (*Stream, *PwBuffer) callconv(.c) c_int,
    pw_stream_set_active: *const fn (*Stream, bool) callconv(.c) c_int,
    pw_stream_destroy: *const fn (*Stream) callconv(.c) void,
};

/// The library stays loaded for the life of the process once opened:
/// unloading libpipewire (and its spa plugins) is not safe.
var lib_once: std.atomic.Value(u8) = .init(0); // 0 untried, 1 loading, 2 ok, 3 failed
var lib_fns: Fns = undefined;
var lib_has_requested = false;

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
        const lib = sys.DynLib.open(&.{ "libpipewire-0.3.so.0", "libpipewire-0.3.so" }) orelse break :blk false;
        lib_fns = lib.load(Fns) orelse break :blk false;
        lib_fns.pw_init(null, null);
        lib_has_requested = versionAtLeast(std.mem.span(lib_fns.pw_get_library_version()), 0, 3, 49);
        break :blk true;
    };
    lib_once.store(if (ok) 2 else 3, .release);
    return if (ok) &lib_fns else null;
}

fn versionAtLeast(v: []const u8, major: u32, minor: u32, micro: u32) bool {
    var it = std.mem.splitScalar(u8, v, '.');
    const want = [3]u32{ major, minor, micro };
    for (want) |w| {
        const part = it.next() orelse return false;
        const n = std.fmt.parseInt(u32, part, 10) catch return false;
        if (n != w) return n > w;
    }
    return true;
}

// SPA constants (spa/param/format.h, spa/param/audio/raw.h, spa/utils/type.h).
const SPA_TYPE_Id = 3;
const SPA_TYPE_Int = 4;
const SPA_TYPE_Array = 13;
const SPA_TYPE_Object = 15;
const SPA_TYPE_OBJECT_Format = 0x40003;
const SPA_PARAM_EnumFormat = 3;
const SPA_FORMAT_mediaType = 1;
const SPA_FORMAT_mediaSubtype = 2;
const SPA_FORMAT_AUDIO_format = 0x10001;
const SPA_FORMAT_AUDIO_rate = 0x10003;
const SPA_FORMAT_AUDIO_channels = 0x10004;
const SPA_FORMAT_AUDIO_position = 0x10005;
const SPA_MEDIA_TYPE_audio = 1;
const SPA_MEDIA_SUBTYPE_raw = 1;
const SPA_AUDIO_FORMAT_F32_LE = 0x11b;
const SPA_AUDIO_CHANNEL_FL = 3;
const SPA_AUDIO_CHANNEL_FR = 4;
const PW_DIRECTION_OUTPUT = 1;
const PW_ID_ANY: u32 = 0xffff_ffff;
const PW_STREAM_FLAG_AUTOCONNECT = 1 << 0;
const PW_STREAM_FLAG_INACTIVE = 1 << 1;
const PW_STREAM_FLAG_MAP_BUFFERS = 1 << 2;
const PW_STREAM_FLAG_RT_PROCESS = 1 << 4;
const PW_STREAM_STATE_ERROR = -1;
const PW_STREAM_STATE_PAUSED = 2;

/// SPA_PARAM_EnumFormat object: F32 interleaved stereo (FL, FR) at `rate`,
/// hand-encoded (the spa_pod_builder helpers are header-only inlines).
pub fn formatPod(rate: u32) [42]u32 {
    var w: [42]u32 = undefined;
    var i: usize = 0;
    const put = struct {
        fn f(buf: *[42]u32, at: *usize, vals: []const u32) void {
            @memcpy(buf[at.*..][0..vals.len], vals);
            at.* += vals.len;
        }
    }.f;
    put(&w, &i, &.{ 160, SPA_TYPE_Object, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat });
    // Each scalar property: key, flags, pod{size 4, type}, value, padding.
    put(&w, &i, &.{ SPA_FORMAT_mediaType, 0, 4, SPA_TYPE_Id, SPA_MEDIA_TYPE_audio, 0 });
    put(&w, &i, &.{ SPA_FORMAT_mediaSubtype, 0, 4, SPA_TYPE_Id, SPA_MEDIA_SUBTYPE_raw, 0 });
    put(&w, &i, &.{ SPA_FORMAT_AUDIO_format, 0, 4, SPA_TYPE_Id, SPA_AUDIO_FORMAT_F32_LE, 0 });
    put(&w, &i, &.{ SPA_FORMAT_AUDIO_rate, 0, 4, SPA_TYPE_Int, rate, 0 });
    put(&w, &i, &.{ SPA_FORMAT_AUDIO_channels, 0, 4, SPA_TYPE_Int, 2, 0 });
    // position: Array of Id { FL, FR }.
    put(&w, &i, &.{ SPA_FORMAT_AUDIO_position, 0, 16, SPA_TYPE_Array, 4, SPA_TYPE_Id, SPA_AUDIO_CHANNEL_FL, SPA_AUDIO_CHANNEL_FR });
    std.debug.assert(i == w.len);
    return w;
}

pub const Backend = struct {
    gpa: std.mem.Allocator,
    fns: *const Fns,
    engine: *Engine,
    info: engine.DeviceInfo = .{},
    tl: *ThreadLoop,
    stream: *Stream = undefined,
    events: StreamEvents = .{},
    state: std.atomic.Value(c_int) = .init(0),
    pod: [42]u32 = undefined,

    pub fn open(gpa: std.mem.Allocator, e: *Engine, o: engine.OpenOptions) engine.OpenError!*Backend {
        const fns = library() orelse return error.Unavailable;
        const tl = fns.pw_thread_loop_new("zpui-audio", null) orelse return error.Unavailable;
        const self = gpa.create(Backend) catch {
            fns.pw_thread_loop_destroy(tl);
            return error.OutOfMemory;
        };
        self.* = .{ .gpa = gpa, .fns = fns, .engine = e, .tl = tl };
        self.events = .{ .state_changed = onStateChanged, .process = onProcess };
        const period: u32 = if (o.buffer_frames != 0) o.buffer_frames else 256;
        const rate = o.rate;

        const props = fns.pw_properties_new_string("media.type=Audio media.category=Playback media.role=Game") orelse {
            fns.pw_thread_loop_destroy(tl);
            gpa.destroy(self);
            return error.Unavailable;
        };
        var lat_buf: [32]u8 = undefined;
        const lat = std.mem.printSentinel(&lat_buf, "{d}/{d}", .{ period, rate }, 0) catch unreachable;
        _ = fns.pw_properties_set(props, "node.latency", lat.ptr);
        _ = fns.pw_properties_set(props, "node.name", o.app_name.ptr);
        _ = fns.pw_properties_set(props, "application.name", o.app_name.ptr);
        _ = fns.pw_properties_set(props, "node.description", o.app_name.ptr);

        const loop = fns.pw_thread_loop_get_loop(tl) orelse {
            fns.pw_thread_loop_destroy(tl);
            gpa.destroy(self);
            return error.Unavailable;
        };
        // pw_stream_new_simple takes ownership of `props`.
        self.stream = fns.pw_stream_new_simple(loop, o.app_name.ptr, props, &self.events, self) orelse {
            fns.pw_thread_loop_destroy(tl);
            gpa.destroy(self);
            return error.Unavailable;
        };
        if (fns.pw_thread_loop_start(tl) < 0) {
            self.destroy();
            return error.Unavailable;
        }
        self.pod = formatPod(rate);
        const params = [_]*const anyopaque{@ptrCast(&self.pod)};
        fns.pw_thread_loop_lock(tl);
        const rc = fns.pw_stream_connect(self.stream, PW_DIRECTION_OUTPUT, PW_ID_ANY, PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_INACTIVE |
            PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS, &params, params.len);
        fns.pw_thread_loop_unlock(tl);
        if (rc < 0) {
            self.destroy();
            return error.Unavailable;
        }
        // Wait for format negotiation (state PAUSED) or an error, ≤ 2 s.
        const deadline = sys.nowNs() + 2 * std.time.ns_per_s;
        while (true) {
            const st = self.state.load(.acquire);
            if (st == PW_STREAM_STATE_ERROR) {
                self.destroy();
                return error.Unavailable;
            }
            if (st >= PW_STREAM_STATE_PAUSED) break;
            if (sys.nowNs() > deadline) {
                self.destroy();
                return error.Unavailable;
            }
            sys.sleepNs(2 * std.time.ns_per_ms);
        }
        self.info = .{
            .rate = rate,
            .channels = 2,
            .period_frames = period,
            // One quantum queued in the graph plus the driver's period
            // (when the graph runs at the requested quantum).
            .latency_ns = @as(u64, period) * 2 * std.time.ns_per_s / rate,
        };
        return self;
    }

    fn destroy(self: *Backend) void {
        self.fns.pw_thread_loop_stop(self.tl);
        self.fns.pw_stream_destroy(self.stream);
        self.fns.pw_thread_loop_destroy(self.tl);
        self.gpa.destroy(self);
    }

    pub fn close(self: *Backend) void {
        self.fns.pw_thread_loop_lock(self.tl);
        _ = self.fns.pw_stream_set_active(self.stream, false);
        self.fns.pw_thread_loop_unlock(self.tl);
        self.destroy();
    }

    pub fn start(self: *Backend) bool {
        self.fns.pw_thread_loop_lock(self.tl);
        const rc = self.fns.pw_stream_set_active(self.stream, true);
        self.fns.pw_thread_loop_unlock(self.tl);
        return rc >= 0 and self.state.load(.acquire) != PW_STREAM_STATE_ERROR;
    }

    pub fn stop(self: *Backend) void {
        self.fns.pw_thread_loop_lock(self.tl);
        _ = self.fns.pw_stream_set_active(self.stream, false);
        self.fns.pw_thread_loop_unlock(self.tl);
    }

    /// PipeWire re-links AUTOCONNECT streams to the new default sink itself.
    pub fn deviceChanged(_: *Backend, _: bool) void {}

    fn onStateChanged(data: ?*anyopaque, _: c_int, new: c_int, err: ?[*:0]const u8) callconv(.c) void {
        const self: *Backend = @ptrCast(@alignCast(data.?));
        self.state.store(new, .release);
        if (new == PW_STREAM_STATE_ERROR) log.warn("audio: PipeWire stream error: {s}", .{if (err) |e| std.mem.span(e) else "?"});
    }

    fn onProcess(data: ?*anyopaque) callconv(.c) void {
        const self: *Backend = @ptrCast(@alignCast(data.?));
        const b = self.fns.pw_stream_dequeue_buffer(self.stream) orelse return;
        const d = &b.buffer.datas[0];
        if (d.data) |ptr| {
            var frames: usize = d.maxsize / 8;
            if (lib_has_requested and b.requested != 0) frames = @min(frames, b.requested);
            const out: [*]f32 = @ptrCast(@alignCast(ptr));
            self.engine.render(f32, out[0 .. frames * 2], frames, 2);
            d.chunk.offset = 0;
            d.chunk.stride = 8;
            d.chunk.size = @intCast(frames * 8);
        }
        _ = self.fns.pw_stream_queue_buffer(self.stream, b);
    }
};

test "pipewire version compare" {
    try std.testing.expect(versionAtLeast("1.0.5", 0, 3, 49));
    try std.testing.expect(versionAtLeast("0.3.49", 0, 3, 49));
    try std.testing.expect(!versionAtLeast("0.3.48", 0, 3, 49));
    try std.testing.expect(!versionAtLeast("junk", 0, 3, 49));
}
