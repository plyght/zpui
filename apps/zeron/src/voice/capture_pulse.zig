//! PulseAudio capture backend (PipeWire serves it through pipewire-pulse),
//! loaded with `dlopen`. Capture is a `pa_simple` record stream read on its
//! own thread in 10 ms blocks (the "callback"); the device's native rate and
//! channel count come from the source's sample spec. Enumeration uses the
//! async introspection API on a private main loop.

const std = @import("std");
const Allocator = std.mem.Allocator;
const capture = @import("capture.zig");
const Capture = capture.Capture;
const InputDevice = capture.InputDevice;
const StartError = capture.StartError;

const log = std.log.scoped(.zeron_voice);

const SampleSpec = extern struct { format: c_int, rate: u32, channels: u8 };
const BufferAttr = extern struct { maxlength: u32, tlength: u32, prebuf: u32, minreq: u32, fragsize: u32 };
const PA_SAMPLE_FLOAT32LE: c_int = 5;
const PA_STREAM_RECORD: c_int = 2;

/// Leading fields of `pa_source_info` / `pa_server_info` (stable ABI).
const SourceInfo = extern struct { name: ?[*:0]const u8, index: u32, description: ?[*:0]const u8, sample_spec: SampleSpec };
const ServerInfo = extern struct {
    user_name: ?[*:0]const u8,
    host_name: ?[*:0]const u8,
    server_version: ?[*:0]const u8,
    server_name: ?[*:0]const u8,
    sample_spec: SampleSpec,
    default_sink_name: ?[*:0]const u8,
    default_source_name: ?[*:0]const u8,
};

const Simple = opaque {};
const Mainloop = opaque {};
const Context = opaque {};
const Operation = opaque {};

const Lib = struct {
    simple_new: *const fn (?[*:0]const u8, [*:0]const u8, c_int, ?[*:0]const u8, [*:0]const u8, *const SampleSpec, ?*const anyopaque, ?*const BufferAttr, ?*c_int) callconv(.c) ?*Simple,
    simple_read: *const fn (*Simple, *anyopaque, usize, ?*c_int) callconv(.c) c_int,
    simple_free: *const fn (*Simple) callconv(.c) void,
    mainloop_new: *const fn () callconv(.c) ?*Mainloop,
    mainloop_get_api: *const fn (*Mainloop) callconv(.c) *anyopaque,
    mainloop_iterate: *const fn (*Mainloop, c_int, ?*c_int) callconv(.c) c_int,
    mainloop_free: *const fn (*Mainloop) callconv(.c) void,
    context_new: *const fn (*anyopaque, [*:0]const u8) callconv(.c) ?*Context,
    context_connect: *const fn (*Context, ?[*:0]const u8, c_int, ?*const anyopaque) callconv(.c) c_int,
    context_get_state: *const fn (*Context) callconv(.c) c_int,
    context_disconnect: *const fn (*Context) callconv(.c) void,
    context_unref: *const fn (*Context) callconv(.c) void,
    context_get_source_info_list: *const fn (*Context, *const fn (*Context, ?*const SourceInfo, c_int, ?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) ?*Operation,
    context_get_source_info_by_name: *const fn (*Context, [*:0]const u8, *const fn (*Context, ?*const SourceInfo, c_int, ?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) ?*Operation,
    context_get_server_info: *const fn (*Context, *const fn (*Context, ?*const ServerInfo, ?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) ?*Operation,
    operation_get_state: *const fn (*Operation) callconv(.c) c_int,
    operation_unref: *const fn (*Operation) callconv(.c) void,
};

var lib_lock: @import("sync.zig").Mutex = .{};
var lib_done = false;
var lib: ?Lib = null;

fn load() ?*const Lib {
    lib_lock.lock();
    defer lib_lock.unlock();
    if (!lib_done) {
        lib_done = true;
        lib = open();
    }
    return if (lib) |*l| l else null;
}

fn sym(h: *anyopaque, comptime T: type, name: [:0]const u8) ?T {
    return @ptrCast(@alignCast(std.c.dlsym(h, name) orelse return null));
}

fn open() ?Lib {
    const flags: std.c.RTLD = .{ .NOW = true };
    const pulse = std.c.dlopen("libpulse.so.0", flags) orelse return null;
    const simple = std.c.dlopen("libpulse-simple.so.0", flags) orelse return null;
    var l: Lib = undefined;
    const info = @typeInfo(Lib).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        const in_simple = comptime std.mem.startsWith(u8, name, "simple_");
        @field(l, name) = sym(if (in_simple) simple else pulse, T, "pa_" ++ name) orelse return null;
    }
    return l;
}

/// A connected introspection context on a private main loop.
const Introspect = struct {
    l: *const Lib,
    loop: *Mainloop,
    ctx: *Context,

    fn connect() ?Introspect {
        const l = load() orelse return null;
        const loop = l.mainloop_new() orelse return null;
        const ctx = l.context_new(l.mainloop_get_api(loop), "Zeron") orelse {
            l.mainloop_free(loop);
            return null;
        };
        var self: Introspect = .{ .l = l, .loop = loop, .ctx = ctx };
        if (l.context_connect(ctx, null, 0, null) < 0) {
            self.close();
            return null;
        }
        while (true) {
            switch (l.context_get_state(ctx)) {
                4 => return self, // READY
                5, 6 => { // FAILED, TERMINATED
                    self.close();
                    return null;
                },
                else => if (l.mainloop_iterate(loop, 1, null) < 0) {
                    self.close();
                    return null;
                },
            }
        }
    }

    fn wait(self: *Introspect, op: ?*Operation) void {
        const o = op orelse return;
        while (self.l.operation_get_state(o) == 0) { // RUNNING
            if (self.l.mainloop_iterate(self.loop, 1, null) < 0) break;
        }
        self.l.operation_unref(o);
    }

    fn close(self: *Introspect) void {
        self.l.context_disconnect(self.ctx);
        self.l.context_unref(self.ctx);
        self.l.mainloop_free(self.loop);
    }
};

const Collect = struct { gpa: Allocator, list: std.ArrayList(InputDevice) = .empty };

fn onSource(_: *Context, info: ?*const SourceInfo, eol: c_int, ud: ?*anyopaque) callconv(.c) void {
    if (eol != 0) return;
    const i = info orelse return;
    const c: *Collect = @ptrCast(@alignCast(ud.?));
    const name = std.mem.span(i.name orelse return);
    // Monitors of outputs are not microphones.
    if (std.mem.endsWith(u8, name, ".monitor")) return;
    const id = std.fmt.allocPrint(c.gpa, "pulse:{s}", .{name}) catch return;
    const desc = c.gpa.dupe(u8, if (i.description) |d| std.mem.span(d) else name) catch {
        c.gpa.free(id);
        return;
    };
    for (c.list.items) |d| if (std.mem.eql(u8, d.id, id)) {
        c.gpa.free(id);
        c.gpa.free(desc);
        return;
    };
    c.list.append(c.gpa, .{ .id = id, .name = desc }) catch {
        c.gpa.free(id);
        c.gpa.free(desc);
    };
}

pub fn inputDevices(gpa: Allocator) []InputDevice {
    var in = Introspect.connect() orelse return &.{};
    defer in.close();
    var c: Collect = .{ .gpa = gpa };
    in.wait(in.l.context_get_source_info_list(in.ctx, onSource, &c));
    return c.list.toOwnedSlice(gpa) catch &.{};
}

const DefaultName = struct { buf: [512]u8 = undefined, len: usize = 0 };

fn onServer(_: *Context, info: ?*const ServerInfo, ud: ?*anyopaque) callconv(.c) void {
    const out: *DefaultName = @ptrCast(@alignCast(ud.?));
    const i = info orelse return;
    const name = std.mem.span(i.default_source_name orelse return);
    if (name.len > out.buf.len) return;
    @memcpy(out.buf[0..name.len], name);
    out.len = name.len;
}

pub fn defaultInputDevice(gpa: Allocator) ?[]u8 {
    var in = Introspect.connect() orelse return null;
    defer in.close();
    var out: DefaultName = .{};
    in.wait(in.l.context_get_server_info(in.ctx, onServer, &out));
    if (out.len == 0) return null;
    return std.fmt.allocPrint(gpa, "pulse:{s}", .{out.buf[0..out.len]}) catch null;
}

const Spec = struct { found: bool = false, spec: SampleSpec = .{ .format = 0, .rate = 0, .channels = 0 } };

fn onSpec(_: *Context, info: ?*const SourceInfo, eol: c_int, ud: ?*anyopaque) callconv(.c) void {
    if (eol != 0) return;
    const out: *Spec = @ptrCast(@alignCast(ud.?));
    const i = info orelse return;
    out.spec = i.sample_spec;
    out.found = true;
}

/// The source's native sample spec (`@DEFAULT_SOURCE@` when `name` is null).
fn nativeSpec(name: ?[*:0]const u8) ?SampleSpec {
    var in = Introspect.connect() orelse return null;
    defer in.close();
    var out: Spec = .{};
    in.wait(in.l.context_get_source_info_by_name(in.ctx, name orelse "@DEFAULT_SOURCE@", onSpec, &out));
    return if (out.found) out.spec else null;
}

pub const Backend = struct {
    cap: *Capture,
    simple: *Simple,
    thread: std.Thread,
    stop: std.atomic.Value(bool) = .init(false),
    closed: bool = false,

    pub fn open(cap: *Capture, device: ?[]const u8) StartError!void {
        const l = load() orelse return error.NoMicrophone;
        var name_buf: [512]u8 = undefined;
        var source: ?[*:0]const u8 = null;
        if (device) |id| if (std.mem.startsWith(u8, id, "pulse:")) {
            if (std.fmt.bufPrintSentinel(&name_buf, "{s}", .{id["pulse:".len..]}, 0)) |n| {
                // A disconnected device records from the default instead.
                if (nativeSpec(n.ptr) != null) source = n.ptr;
            } else |_| {}
        };
        const native = nativeSpec(source) orelse return error.NoMicrophone;
        if (native.rate == 0 or native.channels == 0) return error.UnsupportedFormat;
        const channels: u8 = @min(native.channels, 32);
        const spec: SampleSpec = .{ .format = PA_SAMPLE_FLOAT32LE, .rate = native.rate, .channels = channels };
        const frag: u32 = @intCast(@as(usize, native.rate / 100) * channels * @sizeOf(f32));
        const attr: BufferAttr = .{ .maxlength = std.math.maxInt(u32), .tlength = std.math.maxInt(u32), .prebuf = std.math.maxInt(u32), .minreq = std.math.maxInt(u32), .fragsize = frag };
        var err: c_int = 0;
        const simple = l.simple_new(null, "Zeron", PA_STREAM_RECORD, source, "Dictation", &spec, null, &attr, &err) orelse {
            log.warn("pulse: record stream failed ({d})", .{err});
            return error.StreamFailed;
        };
        cap.allocAudio(native.rate, channels) catch |e| {
            l.simple_free(simple);
            return e;
        };
        cap.backend = .{ .cap = cap, .simple = simple, .thread = undefined };
        cap.backend.thread = std.Thread.spawn(.{}, readLoop, .{&cap.backend}) catch {
            l.simple_free(simple);
            cap.audio.samples.deinit(cap.gpa);
            cap.gpa.destroy(cap.audio);
            return error.StreamFailed;
        };
    }

    fn readLoop(self: *Backend) void {
        const l = load().?;
        const frames = self.cap.rate / 100;
        var buf: [48000 / 100 * 32 * 4]f32 = undefined; // 10 ms at up to 192 kHz × 2 ch / 48 kHz × 32 ch
        const n = @min(@as(usize, frames) * self.cap.channels, buf.len);
        while (!self.stop.load(.acquire)) {
            var err: c_int = 0;
            if (l.simple_read(self.simple, &buf, n * @sizeOf(f32), &err) < 0) {
                self.cap.audio.failed.store(true, .release);
                return;
            }
            self.cap.deliver(buf[0..n]);
        }
    }

    pub fn close(self: *Backend) void {
        if (self.closed) return;
        self.closed = true;
        self.stop.store(true, .release);
        self.thread.join();
        load().?.simple_free(self.simple);
    }
};
