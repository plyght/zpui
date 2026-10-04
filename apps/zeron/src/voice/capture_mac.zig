//! macOS capture backend and the microphone permission bridge (zeron
//! `dictation/permission.m`). AudioToolbox, CoreAudio and AVFoundation are
//! loaded at run time, so the binary links no extra framework and the
//! module cross-compiles without an SDK.
//!
//! Capture is an input `AudioQueue` on the chosen CoreAudio device (by UID,
//! cpal's `coreaudio:<uid>` id) at the device's nominal rate and input
//! channel count — cpal's `default_input_config` — as packed f32, run on the
//! queue's internal thread. The queue stopping on its own (device removed)
//! marks the recording failed, as cpal's error callback does.

const std = @import("std");
const zpui = @import("zpui");
const Allocator = std.mem.Allocator;
const capture = @import("capture.zig");
const Capture = capture.Capture;
const InputDevice = capture.InputDevice;
const StartError = capture.StartError;

const objc = zpui.mac_platform.objc_runtime;
const id = objc.id;
const log = std.log.scoped(.zeron_voice);

const OSStatus = i32;
const AudioObjectID = u32;
const CFStringRef = *anyopaque;

fn fourcc(comptime s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

const PropertyAddress = extern struct { selector: u32, scope: u32, element: u32 = 0 };
const scope_global = fourcc("glob");
const scope_input = fourcc("inpt");
const system_object: AudioObjectID = 1;

const ASBD = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32 = 0,
};

const AQBuffer = extern struct {
    capacity: u32,
    data: *anyopaque,
    size: u32,
    user_data: ?*anyopaque,
    packet_desc_capacity: u32,
    packet_descs: ?*anyopaque,
    packet_desc_count: u32,
};

const AudioQueue = opaque {};
const InputCallback = *const fn (?*anyopaque, *AudioQueue, *AQBuffer, *const anyopaque, u32, ?*const anyopaque) callconv(.c) void;
const PropertyListener = *const fn (?*anyopaque, *AudioQueue, u32) callconv(.c) void;

const Lib = struct {
    AudioQueueNewInput: *const fn (*const ASBD, InputCallback, ?*anyopaque, ?*anyopaque, ?*anyopaque, u32, *?*AudioQueue) callconv(.c) OSStatus,
    AudioQueueAllocateBuffer: *const fn (*AudioQueue, u32, *?*AQBuffer) callconv(.c) OSStatus,
    AudioQueueEnqueueBuffer: *const fn (*AudioQueue, *AQBuffer, u32, ?*const anyopaque) callconv(.c) OSStatus,
    AudioQueueStart: *const fn (*AudioQueue, ?*const anyopaque) callconv(.c) OSStatus,
    AudioQueueStop: *const fn (*AudioQueue, u8) callconv(.c) OSStatus,
    AudioQueueDispose: *const fn (*AudioQueue, u8) callconv(.c) OSStatus,
    AudioQueueSetProperty: *const fn (*AudioQueue, u32, *const anyopaque, u32) callconv(.c) OSStatus,
    AudioQueueGetProperty: *const fn (*AudioQueue, u32, *anyopaque, *u32) callconv(.c) OSStatus,
    AudioQueueAddPropertyListener: *const fn (*AudioQueue, u32, PropertyListener, ?*anyopaque) callconv(.c) OSStatus,
    AudioObjectGetPropertyDataSize: *const fn (AudioObjectID, *const PropertyAddress, u32, ?*const anyopaque, *u32) callconv(.c) OSStatus,
    AudioObjectGetPropertyData: *const fn (AudioObjectID, *const PropertyAddress, u32, ?*const anyopaque, *u32, *anyopaque) callconv(.c) OSStatus,
    CFStringGetCString: *const fn (CFStringRef, [*]u8, isize, u32) callconv(.c) u8,
    CFStringCreateWithCString: *const fn (?*anyopaque, [*:0]const u8, u32) callconv(.c) ?CFStringRef,
    CFRelease: *const fn (*anyopaque) callconv(.c) void,
};

const utf8: u32 = 0x08000100; // kCFStringEncodingUTF8

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

fn open() ?Lib {
    const flags: std.c.RTLD = .{ .NOW = true };
    const toolbox = std.c.dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", flags) orelse return null;
    const core = std.c.dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", flags) orelse return null;
    const cf = std.c.dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", flags) orelse return null;
    var l: Lib = undefined;
    const info = @typeInfo(Lib).@"struct";
    inline for (info.field_names) |name| {
        const h = if (comptime std.mem.startsWith(u8, name, "AudioQueue")) toolbox else if (comptime std.mem.startsWith(u8, name, "CF")) cf else core;
        @field(l, name) = @ptrCast(@alignCast(std.c.dlsym(h, name) orelse return null));
    }
    return l;
}

fn getProp(l: *const Lib, obj: AudioObjectID, selector: u32, scope: u32, comptime T: type) ?T {
    const addr: PropertyAddress = .{ .selector = selector, .scope = scope };
    var out: T = undefined;
    var size: u32 = @sizeOf(T);
    if (l.AudioObjectGetPropertyData(obj, &addr, 0, null, &size, @ptrCast(&out)) != 0) return null;
    return out;
}

fn cfString(l: *const Lib, gpa: Allocator, s: CFStringRef) ?[]u8 {
    defer l.CFRelease(s);
    var buf: [1024]u8 = undefined;
    if (l.CFStringGetCString(s, &buf, buf.len, utf8) == 0) return null;
    return gpa.dupe(u8, std.mem.sliceTo(&buf, 0)) catch null;
}

/// Total input channels of `dev` (0 when it has no input streams).
fn inputChannels(l: *const Lib, gpa: Allocator, dev: AudioObjectID) u32 {
    const addr: PropertyAddress = .{ .selector = fourcc("slay"), .scope = scope_input };
    var size: u32 = 0;
    if (l.AudioObjectGetPropertyDataSize(dev, &addr, 0, null, &size) != 0 or size < 8) return 0;
    const buf = gpa.alignedAlloc(u8, .@"8", size) catch return 0;
    defer gpa.free(buf);
    if (l.AudioObjectGetPropertyData(dev, &addr, 0, null, &size, buf.ptr) != 0) return 0;
    // AudioBufferList { u32 count; AudioBuffer { u32 channels; u32 bytes; void *data; }[] }.
    const count = std.mem.readInt(u32, buf[0..4], .little);
    var channels: u32 = 0;
    var i: usize = 0;
    while (i < count and 8 + i * 16 + 4 <= size) : (i += 1) {
        channels += std.mem.readInt(u32, buf[8 + i * 16 ..][0..4], .little);
    }
    return channels;
}

fn deviceIds(l: *const Lib, gpa: Allocator) []AudioObjectID {
    const addr: PropertyAddress = .{ .selector = fourcc("dev#"), .scope = scope_global };
    var size: u32 = 0;
    if (l.AudioObjectGetPropertyDataSize(system_object, &addr, 0, null, &size) != 0) return &.{};
    const ids = gpa.alloc(AudioObjectID, size / @sizeOf(AudioObjectID)) catch return &.{};
    if (l.AudioObjectGetPropertyData(system_object, &addr, 0, null, &size, @ptrCast(ids.ptr)) != 0) {
        gpa.free(ids);
        return &.{};
    }
    return ids[0 .. size / @sizeOf(AudioObjectID)];
}

fn deviceUid(l: *const Lib, gpa: Allocator, dev: AudioObjectID) ?[]u8 {
    const s = getProp(l, dev, fourcc("uid "), scope_global, CFStringRef) orelse return null;
    return cfString(l, gpa, s);
}

pub fn inputDevices(gpa: Allocator) []InputDevice {
    const l = load() orelse return &.{};
    const ids = deviceIds(l, gpa);
    defer gpa.free(ids);
    var list: std.ArrayList(InputDevice) = .empty;
    for (ids) |dev| {
        if (inputChannels(l, gpa, dev) == 0) continue;
        const uid = deviceUid(l, gpa, dev) orelse continue;
        defer gpa.free(uid);
        const name_ref = getProp(l, dev, fourcc("lnam"), scope_global, CFStringRef) orelse continue;
        const name = cfString(l, gpa, name_ref) orelse continue;
        const dev_id = std.fmt.allocPrint(gpa, "coreaudio:{s}", .{uid}) catch {
            gpa.free(name);
            continue;
        };
        list.append(gpa, .{ .id = dev_id, .name = name }) catch {
            gpa.free(dev_id);
            gpa.free(name);
        };
    }
    return list.toOwnedSlice(gpa) catch &.{};
}

fn defaultDevice(l: *const Lib) ?AudioObjectID {
    const dev = getProp(l, system_object, fourcc("dIn "), scope_global, AudioObjectID) orelse return null;
    return if (dev == 0) null else dev;
}

pub fn defaultInputDevice(gpa: Allocator) ?[]u8 {
    const l = load() orelse return null;
    const dev = defaultDevice(l) orelse return null;
    const uid = deviceUid(l, gpa, dev) orelse return null;
    defer gpa.free(uid);
    return std.fmt.allocPrint(gpa, "coreaudio:{s}", .{uid}) catch null;
}

/// The device for a saved id when connected, the default otherwise.
fn resolve(l: *const Lib, gpa: Allocator, device: ?[]const u8) ?AudioObjectID {
    if (device) |want| if (std.mem.startsWith(u8, want, "coreaudio:")) {
        const ids = deviceIds(l, gpa);
        defer gpa.free(ids);
        for (ids) |dev| {
            const uid = deviceUid(l, gpa, dev) orelse continue;
            defer gpa.free(uid);
            if (std.mem.eql(u8, uid, want["coreaudio:".len..]) and inputChannels(l, gpa, dev) > 0) return dev;
        }
    };
    return defaultDevice(l);
}

const buffer_count = 3;

pub const Backend = struct {
    cap: *Capture,
    queue: *AudioQueue,
    stopping: std.atomic.Value(bool) = .init(false),
    closed: bool = false,

    pub fn open(cap: *Capture, device: ?[]const u8) StartError!void {
        const l = load() orelse return error.NoMicrophone;
        const dev = resolve(l, cap.gpa, device) orelse return error.NoMicrophone;
        const rate = getProp(l, dev, fourcc("nsrt"), scope_global, f64) orelse return error.UnsupportedFormat;
        const channels = inputChannels(l, cap.gpa, dev);
        if (channels == 0 or !(rate >= 1)) return error.UnsupportedFormat;
        const asbd: ASBD = .{
            .sample_rate = rate,
            .format_id = fourcc("lpcm"),
            .format_flags = 1 | 8, // float | packed
            .bytes_per_packet = 4 * channels,
            .frames_per_packet = 1,
            .bytes_per_frame = 4 * channels,
            .channels_per_frame = channels,
            .bits_per_channel = 32,
        };
        try cap.allocAudio(@intFromFloat(rate), channels);
        errdefer {
            cap.audio.samples.deinit(cap.gpa);
            cap.gpa.destroy(cap.audio);
        }
        cap.backend = .{ .cap = cap, .queue = undefined };
        var queue: ?*AudioQueue = null;
        if (l.AudioQueueNewInput(&asbd, onInput, &cap.backend, null, null, 0, &queue) != 0) return error.StreamFailed;
        const q = queue.?;
        cap.backend.queue = q;
        errdefer _ = l.AudioQueueDispose(q, 1);
        if (deviceUid(l, cap.gpa, dev)) |uid| {
            defer cap.gpa.free(uid);
            const z = cap.gpa.dupeSentinel(u8, uid, 0) catch return error.OutOfMemory;
            defer cap.gpa.free(z);
            if (l.CFStringCreateWithCString(null, z, utf8)) |s| {
                defer l.CFRelease(s);
                _ = l.AudioQueueSetProperty(q, fourcc("aqcd"), @ptrCast(&s), @sizeOf(CFStringRef));
            }
        }
        // ~20 ms per buffer.
        const bytes: u32 = @intCast(@max(256, @as(u32, @intFromFloat(rate / 50.0)) * 4 * channels));
        for (0..buffer_count) |_| {
            var buf: ?*AQBuffer = null;
            if (l.AudioQueueAllocateBuffer(q, bytes, &buf) != 0) return error.StreamFailed;
            _ = l.AudioQueueEnqueueBuffer(q, buf.?, 0, null);
        }
        _ = l.AudioQueueAddPropertyListener(q, fourcc("aqrn"), onRunning, &cap.backend);
        if (l.AudioQueueStart(q, null) != 0) return error.StreamFailed;
    }

    fn onInput(ud: ?*anyopaque, q: *AudioQueue, buf: *AQBuffer, _: *const anyopaque, _: u32, _: ?*const anyopaque) callconv(.c) void {
        const self: *Backend = @ptrCast(@alignCast(ud.?));
        if (self.stopping.load(.acquire)) return;
        const n = buf.size / @sizeOf(f32);
        const data: [*]const f32 = @ptrCast(@alignCast(buf.data));
        self.cap.deliver(data[0..n]);
        _ = load().?.AudioQueueEnqueueBuffer(q, buf, 0, null);
    }

    fn onRunning(ud: ?*anyopaque, q: *AudioQueue, _: u32) callconv(.c) void {
        const self: *Backend = @ptrCast(@alignCast(ud.?));
        var running: u32 = 1;
        var size: u32 = @sizeOf(u32);
        if (load().?.AudioQueueGetProperty(q, fourcc("aqrn"), @ptrCast(&running), &size) != 0) return;
        if (running == 0 and !self.stopping.load(.acquire)) self.cap.audio.failed.store(true, .release);
    }

    pub fn close(self: *Backend) void {
        if (self.closed) return;
        self.closed = true;
        self.stopping.store(true, .release);
        const l = load().?;
        _ = l.AudioQueueStop(self.queue, 1);
        _ = l.AudioQueueDispose(self.queue, 1);
    }
};

// ---- permission (dictation/permission.m) ----------------------------------

extern "c" const _NSConcreteGlobalBlock: anyopaque;

const BlockDescriptor = extern struct { reserved: c_ulong = 0, size: c_ulong };
const AccessBlock = extern struct {
    isa: *const anyopaque,
    flags: c_int,
    reserved: c_int = 0,
    invoke: *const fn (*const AccessBlock, objc.BOOL) callconv(.c) void,
    descriptor: *const BlockDescriptor,
};
const access_descriptor: BlockDescriptor = .{ .size = @sizeOf(AccessBlock) };

/// No Zig callbacks or audio are retained by the permission block.
fn onAccess(_: *const AccessBlock, _: objc.BOOL) callconv(.c) void {}

var access_block: AccessBlock = undefined;

fn mediaTypeAudio() ?id {
    const av = std.c.dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", .{ .NOW = true }) orelse return null;
    const p: *const id = @ptrCast(@alignCast(std.c.dlsym(av, "AVMediaTypeAudio") orelse return null));
    return p.*;
}

/// 1 authorized, 0 not determined, -1 denied/restricted, -2 not a packaged
/// app with a usage description (`zeron_microphone_permission`).
pub fn microphonePermission() i32 {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const bundle = objc.getClass("NSBundle").?.msg(id, "mainBundle", .{});
    const path = bundle.msg(?id, "bundlePath", .{}) orelse return -2;
    const ext = path.msg(?id, "pathExtension", .{}) orelse return -2;
    if (!objc.fromBOOL(ext.msg(objc.BOOL, "isEqualToString:", .{objc.nsString("app")}))) return -2;
    if (bundle.msg(?id, "objectForInfoDictionaryKey:", .{objc.nsString("NSMicrophoneUsageDescription")}) == null) return -2;
    const media = mediaTypeAudio() orelse return -2;
    const device = objc.getClass("AVCaptureDevice") orelse return -2;
    const status = device.msg(objc.NSInteger, "authorizationStatusForMediaType:", .{media});
    return switch (status) {
        3 => 1, // AVAuthorizationStatusAuthorized
        0 => 0, // NotDetermined
        else => -1,
    };
}

/// `zeron_request_microphone`: show the system prompt (answer read by polling).
pub fn requestMicrophone() void {
    const media = mediaTypeAudio() orelse return;
    const device = objc.getClass("AVCaptureDevice") orelse return;
    access_block = .{ .isa = &_NSConcreteGlobalBlock, .flags = 1 << 28, .invoke = onAccess, .descriptor = &access_descriptor };
    device.msg(void, "requestAccessForMediaType:completionHandler:", .{ media, @as(*const anyopaque, @ptrCast(&access_block)) });
}

/// `zeron_microphone_window`: the key window while the app is active, else 0.
pub fn microphoneWindow() usize {
    const app = objc.getClass("NSApplication").?.msg(id, "sharedApplication", .{});
    if (!objc.fromBOOL(app.msg(objc.BOOL, "isActive", .{}))) return 0;
    const w = app.msg(?id, "keyWindow", .{}) orelse return 0;
    return @intFromPtr(w);
}
