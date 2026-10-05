//! Video frames on Linux through GStreamer, loaded at run time (`dlopen` of
//! libgstreamer-1.0 / libgstapp-1.0), so the binary links nothing extra and
//! machines without GStreamer just report video backgrounds as unsupported.
//!
//! Pipeline: `filesrc ! decodebin ! videoconvert ! videoscale ! capsfilter
//! (RGBA, square pixels, ≤ max side) ! appsink (sync=false)`: decoding runs
//! as fast as the consumer pulls (appsink holds at most a few buffers), so
//! memory stays bounded; looping is a flushing seek to 0.
//!
//! Only stable GStreamer 1.x ABI is used: function calls plus the public
//! `GstBuffer` / `GstMapInfo` layouts.

const std = @import("std");
const anim = @import("anim_decode.zig");
const artwork = @import("artwork.zig");

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.zeron_background_video);

const Element = opaque {};
const Sample = opaque {};
const Caps = opaque {};
const Structure = opaque {};
const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]const u8 };

const MiniObject = extern struct {
    type: usize,
    refcount: c_int,
    lockstate: c_int,
    flags: c_uint,
    copy: ?*anyopaque,
    dispose: ?*anyopaque,
    free: ?*anyopaque,
    priv_uint: c_uint,
    priv_pointer: ?*anyopaque,
};

const Buffer = extern struct {
    mini_object: MiniObject,
    pool: ?*anyopaque,
    pts: u64,
    dts: u64,
    duration: u64,
    offset: u64,
    offset_end: u64,
};

const MapInfo = extern struct {
    memory: ?*anyopaque = null,
    flags: c_int = 0,
    data: ?[*]u8 = null,
    size: usize = 0,
    maxsize: usize = 0,
    user_data: [4]?*anyopaque = @splat(null),
    reserved: [4]?*anyopaque = @splat(null),
};

const clock_time_none: u64 = std.math.maxInt(u64);
const state_null: c_int = 1;
const state_playing: c_int = 4;
const format_time: c_int = 3;
const seek_flush: c_int = 1;
const seek_key_unit: c_int = 4;
const map_read: c_int = 1;
const pull_timeout_ns: u64 = 10 * std.time.ns_per_s;
const pull_slice_ns: u64 = 50 * std.time.ns_per_ms;
const message_error: c_uint = 1 << 1;

const Api = struct {
    init_check: *const fn (?*c_int, ?*anyopaque, ?*?*GError) callconv(.c) c_int,
    parse_launch: *const fn ([*:0]const u8, ?*?*GError) callconv(.c) ?*Element,
    bin_get_by_name: *const fn (*Element, [*:0]const u8) callconv(.c) ?*Element,
    element_set_state: *const fn (*Element, c_int) callconv(.c) c_int,
    element_seek_simple: *const fn (*Element, c_int, c_int, i64) callconv(.c) c_int,
    object_unref: *const fn (*anyopaque) callconv(.c) void,
    util_set_object_arg: *const fn (*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) void,
    mini_object_unref: *const fn (*anyopaque) callconv(.c) void,
    sample_get_buffer: *const fn (*Sample) callconv(.c) ?*Buffer,
    sample_get_caps: *const fn (*Sample) callconv(.c) ?*Caps,
    caps_get_structure: *const fn (*Caps, c_uint) callconv(.c) ?*Structure,
    structure_get_int: *const fn (*Structure, [*:0]const u8, *c_int) callconv(.c) c_int,
    structure_get_fraction: *const fn (*Structure, [*:0]const u8, *c_int, *c_int) callconv(.c) c_int,
    buffer_map: *const fn (*Buffer, *MapInfo, c_int) callconv(.c) c_int,
    buffer_unmap: *const fn (*Buffer, *MapInfo) callconv(.c) void,
    app_sink_try_pull_sample: *const fn (*Element, u64) callconv(.c) ?*Sample,
    app_sink_is_eos: *const fn (*Element) callconv(.c) c_int,
    element_get_bus: *const fn (*Element) callconv(.c) ?*anyopaque,
    bus_pop_filtered: *const fn (*anyopaque, c_uint) callconv(.c) ?*anyopaque,
    error_free: ?*const fn (*GError) callconv(.c) void,
};

var api_mutex: std.c.pthread_mutex_t = .{};
var api_state: enum { unknown, ready, missing } = .unknown;
var api: Api = undefined;

fn sym(comptime T: type, handle: *anyopaque, name: [:0]const u8) ?T {
    const p = std.c.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn openLib(names: []const [:0]const u8) ?*anyopaque {
    for (names) |n| if (std.c.dlopen(n, .{ .NOW = true, .GLOBAL = true })) |h| return h;
    return null;
}

fn loadApi() ?*const Api {
    _ = std.c.pthread_mutex_lock(&api_mutex);
    defer _ = std.c.pthread_mutex_unlock(&api_mutex);
    switch (api_state) {
        .ready => return &api,
        .missing => return null,
        .unknown => {},
    }
    api_state = .missing;
    const core = openLib(&.{ "libgstreamer-1.0.so.0", "libgstreamer-1.0.so" }) orelse return null;
    const app = openLib(&.{ "libgstapp-1.0.so.0", "libgstapp-1.0.so" }) orelse return null;
    const glib = openLib(&.{ "libglib-2.0.so.0", "libglib-2.0.so" });
    var a: Api = undefined;
    inline for (.{
        .{ "init_check", "gst_init_check", core },
        .{ "parse_launch", "gst_parse_launch", core },
        .{ "bin_get_by_name", "gst_bin_get_by_name", core },
        .{ "element_set_state", "gst_element_set_state", core },
        .{ "element_seek_simple", "gst_element_seek_simple", core },
        .{ "object_unref", "gst_object_unref", core },
        .{ "util_set_object_arg", "gst_util_set_object_arg", core },
        .{ "mini_object_unref", "gst_mini_object_unref", core },
        .{ "sample_get_buffer", "gst_sample_get_buffer", core },
        .{ "sample_get_caps", "gst_sample_get_caps", core },
        .{ "caps_get_structure", "gst_caps_get_structure", core },
        .{ "structure_get_int", "gst_structure_get_int", core },
        .{ "structure_get_fraction", "gst_structure_get_fraction", core },
        .{ "buffer_map", "gst_buffer_map", core },
        .{ "buffer_unmap", "gst_buffer_unmap", core },
        .{ "app_sink_try_pull_sample", "gst_app_sink_try_pull_sample", app },
        .{ "app_sink_is_eos", "gst_app_sink_is_eos", app },
        .{ "element_get_bus", "gst_element_get_bus", core },
        .{ "bus_pop_filtered", "gst_bus_pop_filtered", core },
    }) |e| {
        @field(a, e[0]) = sym(@FieldType(Api, e[0]), e[2], e[1]) orelse {
            log.info("GStreamer is missing {s}; video backgrounds are unavailable", .{e[1]});
            return null;
        };
    }
    a.error_free = if (glib) |g| sym(@typeInfo(@FieldType(Api, "error_free")).optional.child, g, "g_error_free") else null;
    var err: ?*GError = null;
    if (a.init_check(null, null, &err) == 0) {
        if (err) |e| if (a.error_free) |f| f(e);
        return null;
    }
    api = a;
    api_state = .ready;
    return &api;
}

/// Whether GStreamer could be loaded (tests skip video when it can't).
pub fn available() bool {
    return loadApi() != null;
}

pub const Decoder = struct {
    gpa: Allocator,
    api: *const Api,
    path: [:0]u8,
    max_side: u32,
    pipeline: ?*Element = null,
    sink: ?*Element = null,
    canvas: ?artwork.Rgba = null,
    fallback_ns: u64 = anim.min_frame_ns,
    /// The frame pulled while opening (returned by the first `next`).
    pending: ?*Sample = null,

    pub fn open(gpa: Allocator, path: []const u8, max_side: u32) error{ OutOfMemory, Unsupported, InvalidVideo }!*Decoder {
        const a = loadApi() orelse return error.Unsupported;
        const self = try gpa.create(Decoder);
        errdefer gpa.destroy(self);
        const pathz = try gpa.dupeSentinel(u8, path, 0);
        errdefer gpa.free(pathz);
        self.* = .{ .gpa = gpa, .api = a, .path = pathz, .max_side = max_side };
        try self.build(null);
        errdefer self.teardown();
        // Pull the first frame now: it proves the file decodes and gives the size.
        const first = (try self.pull()) orelse return error.InvalidVideo;
        const dims = sampleSize(a, first) orelse {
            a.mini_object_unref(first);
            return error.InvalidVideo;
        };
        if (@max(dims[0], dims[1]) > max_side) {
            // Rebuild with a scaled caps filter (aspect kept, even sides).
            a.mini_object_unref(first);
            self.teardown();
            const fit = artwork.fitDimensions(dims[0], dims[1], max_side, max_side);
            try self.build(.{ fit[0] & ~@as(u32, 1), fit[1] & ~@as(u32, 1) });
            self.pending = (try self.pull()) orelse return error.InvalidVideo;
        } else self.pending = first;
        return self;
    }

    fn build(self: *Decoder, size: ?[2]u32) error{ OutOfMemory, InvalidVideo }!void {
        const a = self.api;
        var err: ?*GError = null;
        const desc = "filesrc name=src ! decodebin ! videoconvert ! videoscale ! capsfilter name=caps ! appsink name=sink sync=false max-buffers=3 drop=false enable-last-sample=false";
        const pipeline = a.parse_launch(desc, &err) orelse {
            if (err) |e| if (a.error_free) |f| f(e);
            return error.InvalidVideo;
        };
        if (err) |e| if (a.error_free) |f| f(e);
        errdefer a.object_unref(pipeline);
        const src = a.bin_get_by_name(pipeline, "src") orelse return error.InvalidVideo;
        a.util_set_object_arg(src, "location", self.path.ptr);
        a.object_unref(src);
        const caps = a.bin_get_by_name(pipeline, "caps") orelse return error.InvalidVideo;
        var buf: [160]u8 = undefined;
        const caps_str = if (size) |s|
            std.fmt.bufPrintSentinel(&buf, "video/x-raw,format=RGBA,pixel-aspect-ratio=1/1,width={d},height={d}", .{ @max(s[0], 2), @max(s[1], 2) }, 0) catch unreachable
        else
            std.fmt.bufPrintSentinel(&buf, "video/x-raw,format=RGBA,pixel-aspect-ratio=1/1", .{}, 0) catch unreachable;
        a.util_set_object_arg(caps, "caps", caps_str.ptr);
        a.object_unref(caps);
        const sink = a.bin_get_by_name(pipeline, "sink") orelse return error.InvalidVideo;
        if (a.element_set_state(pipeline, state_playing) == 0) {
            a.object_unref(sink);
            _ = a.element_set_state(pipeline, state_null);
            return error.InvalidVideo;
        }
        self.pipeline = pipeline;
        self.sink = sink;
    }

    /// The next sample; null at the end of the stream. Polls the bus so a
    /// decoding error fails fast instead of waiting out the timeout.
    fn pull(self: *Decoder) error{InvalidVideo}!?*Sample {
        const a = self.api;
        const sink = self.sink orelse return error.InvalidVideo;
        const bus = a.element_get_bus(self.pipeline.?) orelse return error.InvalidVideo;
        defer a.object_unref(bus);
        var waited: u64 = 0;
        while (waited < pull_timeout_ns) : (waited += pull_slice_ns) {
            if (a.app_sink_try_pull_sample(sink, pull_slice_ns)) |sample| return sample;
            if (a.app_sink_is_eos(sink) != 0) return null;
            if (a.bus_pop_filtered(bus, message_error)) |msg| {
                a.mini_object_unref(msg);
                return error.InvalidVideo;
            }
        }
        return error.InvalidVideo;
    }

    fn teardown(self: *Decoder) void {
        const a = self.api;
        if (self.pending) |p| a.mini_object_unref(p);
        self.pending = null;
        if (self.pipeline) |pl| _ = a.element_set_state(pl, state_null);
        if (self.sink) |sk| a.object_unref(sk);
        if (self.pipeline) |pl| a.object_unref(pl);
        self.pipeline = null;
        self.sink = null;
    }

    pub fn deinit(self: *Decoder) void {
        self.teardown();
        if (self.canvas) |*c| c.deinit(self.gpa);
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    fn sampleSize(a: *const Api, sample: *Sample) ?[2]u32 {
        const caps = a.sample_get_caps(sample) orelse return null;
        const s = a.caps_get_structure(caps, 0) orelse return null;
        var w: c_int = 0;
        var h: c_int = 0;
        if (a.structure_get_int(s, "width", &w) == 0 or a.structure_get_int(s, "height", &h) == 0) return null;
        if (w <= 0 or h <= 0) return null;
        return .{ @intCast(w), @intCast(h) };
    }

    /// The next frame (RGBA, borrowed until the next call), null at the end.
    pub fn next(self: *Decoder) error{ OutOfMemory, InvalidVideo }!?anim.Frame {
        const a = self.api;
        const sample = self.pending orelse (try self.pull()) orelse return null;
        self.pending = null;
        defer a.mini_object_unref(sample);
        const dims = sampleSize(a, sample) orelse return error.InvalidVideo;
        const buffer = a.sample_get_buffer(sample) orelse return error.InvalidVideo;
        if (self.canvas == null or self.canvas.?.width != dims[0] or self.canvas.?.height != dims[1]) {
            if (self.canvas) |*c| c.deinit(self.gpa);
            self.canvas = null;
            self.canvas = .{ .width = dims[0], .height = dims[1], .pixels = try self.gpa.alloc([4]u8, @as(usize, dims[0]) * dims[1]) };
            if (a.sample_get_caps(sample)) |caps| if (a.caps_get_structure(caps, 0)) |s| {
                var n: c_int = 0;
                var d: c_int = 0;
                if (a.structure_get_fraction(s, "framerate", &n, &d) != 0 and n > 0 and d > 0)
                    self.fallback_ns = @intCast(@divTrunc(@as(i64, d) * std.time.ns_per_s, n));
            };
        }
        const canvas = self.canvas.?;
        var map: MapInfo = .{};
        if (a.buffer_map(buffer, &map, map_read) == 0) return error.InvalidVideo;
        defer a.buffer_unmap(buffer, &map);
        const data = map.data orelse return error.InvalidVideo;
        const row = @as(usize, canvas.width) * 4;
        const stride = if (canvas.height > 0) map.size / canvas.height else 0;
        if (stride < row) return error.InvalidVideo;
        const out = std.mem.sliceAsBytes(canvas.pixels);
        for (0..canvas.height) |y| @memcpy(out[y * row ..][0..row], data[y * stride ..][0..row]);
        const dur = if (buffer.duration != clock_time_none and buffer.duration > 0) buffer.duration else self.fallback_ns;
        return .{ .image = canvas, .duration_ns = dur };
    }

    /// Back to the first frame (a flushing seek; a rebuild if that fails).
    pub fn rewind(self: *Decoder) error{ OutOfMemory, InvalidVideo }!void {
        const a = self.api;
        if (self.pending) |p| a.mini_object_unref(p);
        self.pending = null;
        if (self.pipeline) |pl| if (a.element_seek_simple(pl, format_time, seek_flush | seek_key_unit, 0) != 0) return;
        const size: ?[2]u32 = if (self.canvas) |c| .{ c.width, c.height } else null;
        self.teardown();
        try self.build(size);
    }
};
