//! Video frames on macOS through AVFoundation (`AVAssetReader` +
//! `AVAssetReaderTrackOutput`, 32BGRA), on raw Objective-C. AVFoundation,
//! CoreMedia and CoreVideo are loaded at run time (`dlopen`), so the binary
//! links no extra framework and cross-compiles without an SDK.
//!
//! Plays what AVFoundation decodes (MP4 / MOV / M4V with H.264, HEVC, …);
//! WebM generally fails to open and reports as unsupported. Looping
//! recreates the reader (readers are single-pass).

const std = @import("std");
const zpui = @import("zpui");
const anim = @import("anim_decode.zig");
const artwork = @import("artwork.zig");

const objc = zpui.mac_platform.objc_runtime;
const id = objc.id;
const Allocator = std.mem.Allocator;

const CMTime = extern struct { value: i64, timescale: i32, flags: u32, epoch: i64 };
const cmtime_valid: u32 = 1;
const pixel_format_bgra: u32 = 0x42475241; // 'BGRA'
const reader_status_completed: objc.NSInteger = 2;

const Api = struct {
    get_image_buffer: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    get_duration: *const fn (*anyopaque) callconv(.c) CMTime,
    lock: *const fn (*anyopaque, u64) callconv(.c) i32,
    unlock: *const fn (*anyopaque, u64) callconv(.c) i32,
    base_address: *const fn (*anyopaque) callconv(.c) ?[*]u8,
    bytes_per_row: *const fn (*anyopaque) callconv(.c) usize,
    width: *const fn (*anyopaque) callconv(.c) usize,
    height: *const fn (*anyopaque) callconv(.c) usize,
    cf_release: *const fn (*anyopaque) callconv(.c) void,
    /// `kCVPixelBufferPixelFormatTypeKey` / `AVMediaTypeVideo` (CFString/NSString).
    pixel_format_key: id,
    media_type_video: id,
};

var api_mutex: std.c.pthread_mutex_t = .{};
var api_state: enum { unknown, ready, missing } = .unknown;
var api: Api = undefined;

fn sym(comptime T: type, handle: *anyopaque, name: [:0]const u8) ?T {
    const p = std.c.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(p));
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
    const flags: std.c.RTLD = .{ .LAZY = true, .GLOBAL = true };
    const av = std.c.dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", flags) orelse return null;
    const cm = std.c.dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", flags) orelse return null;
    const cv = std.c.dlopen("/System/Library/Frameworks/CoreVideo.framework/CoreVideo", flags) orelse return null;
    const cf = std.c.dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", flags) orelse return null;
    const fmt_key = sym(*const id, cv, "kCVPixelBufferPixelFormatTypeKey") orelse return null;
    const video = sym(*const id, av, "AVMediaTypeVideo") orelse return null;
    api = .{
        .get_image_buffer = sym(@FieldType(Api, "get_image_buffer"), cm, "CMSampleBufferGetImageBuffer") orelse return null,
        .get_duration = sym(@FieldType(Api, "get_duration"), cm, "CMSampleBufferGetDuration") orelse return null,
        .lock = sym(@FieldType(Api, "lock"), cv, "CVPixelBufferLockBaseAddress") orelse return null,
        .unlock = sym(@FieldType(Api, "unlock"), cv, "CVPixelBufferUnlockBaseAddress") orelse return null,
        .base_address = sym(@FieldType(Api, "base_address"), cv, "CVPixelBufferGetBaseAddress") orelse return null,
        .bytes_per_row = sym(@FieldType(Api, "bytes_per_row"), cv, "CVPixelBufferGetBytesPerRow") orelse return null,
        .width = sym(@FieldType(Api, "width"), cv, "CVPixelBufferGetWidth") orelse return null,
        .height = sym(@FieldType(Api, "height"), cv, "CVPixelBufferGetHeight") orelse return null,
        .cf_release = sym(@FieldType(Api, "cf_release"), cf, "CFRelease") orelse return null,
        .pixel_format_key = fmt_key.*,
        .media_type_video = video.*,
    };
    if (objc.getClass("AVAssetReader") == null or objc.getClass("AVURLAsset") == null) return null;
    api_state = .ready;
    return &api;
}

pub fn available() bool {
    return loadApi() != null;
}

pub const Decoder = struct {
    gpa: Allocator,
    api: *const Api,
    /// +1 references.
    asset: id,
    track: id,
    reader: ?id = null,
    output: ?id = null,
    canvas: ?artwork.Rgba = null,
    max_side: u32,
    fallback_ns: u64 = anim.min_frame_ns,

    pub fn open(gpa: Allocator, path: []const u8, max_side: u32) error{ OutOfMemory, Unsupported, InvalidVideo }!*Decoder {
        const a = loadApi() orelse return error.Unsupported;
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const pathz = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(pathz);
        const NSURL = objc.getClass("NSURL") orelse return error.Unsupported;
        const url = NSURL.msg(?id, "fileURLWithPath:", .{objc.nsString(pathz)}) orelse return error.InvalidVideo;
        const AVURLAsset = objc.getClass("AVURLAsset") orelse return error.Unsupported;
        const asset = AVURLAsset.msg(?id, "URLAssetWithURL:options:", .{ url, @as(?id, null) }) orelse return error.InvalidVideo;
        const tracks = asset.msg(?id, "tracksWithMediaType:", .{a.media_type_video}) orelse return error.InvalidVideo;
        if (tracks.msg(objc.NSUInteger, "count", .{}) == 0) return error.InvalidVideo;
        const track = tracks.msg(?id, "objectAtIndex:", .{@as(objc.NSUInteger, 0)}) orelse return error.InvalidVideo;
        const self = try gpa.create(Decoder);
        self.* = .{ .gpa = gpa, .api = a, .asset = asset.retain(), .track = track.retain(), .max_side = max_side };
        const fps = track.msg(f32, "nominalFrameRate", .{});
        if (fps > 0 and std.math.isFinite(fps)) self.fallback_ns = @intFromFloat(@as(f64, std.time.ns_per_s) / fps);
        self.startReader() catch {
            self.deinit();
            return error.InvalidVideo;
        };
        return self;
    }

    fn startReader(self: *Decoder) error{InvalidVideo}!void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        self.stopReader();
        const AVAssetReader = objc.getClass("AVAssetReader") orelse return error.InvalidVideo;
        const AVAssetReaderTrackOutput = objc.getClass("AVAssetReaderTrackOutput") orelse return error.InvalidVideo;
        const NSNumber = objc.getClass("NSNumber") orelse return error.InvalidVideo;
        const NSDictionary = objc.getClass("NSDictionary") orelse return error.InvalidVideo;
        var err: ?id = null;
        const reader = AVAssetReader.msg(?id, "assetReaderWithAsset:error:", .{ self.asset, &err }) orelse return error.InvalidVideo;
        const format = NSNumber.msg(?id, "numberWithUnsignedInt:", .{pixel_format_bgra}) orelse return error.InvalidVideo;
        const settings = NSDictionary.msg(?id, "dictionaryWithObject:forKey:", .{ format, self.api.pixel_format_key }) orelse return error.InvalidVideo;
        const output = AVAssetReaderTrackOutput.msg(?id, "assetReaderTrackOutputWithTrack:outputSettings:", .{ self.track, settings }) orelse return error.InvalidVideo;
        output.msg(void, "setAlwaysCopiesSampleData:", .{objc.NO});
        if (!objc.fromBOOL(reader.msg(objc.BOOL, "canAddOutput:", .{output}))) return error.InvalidVideo;
        reader.msg(void, "addOutput:", .{output});
        if (!objc.fromBOOL(reader.msg(objc.BOOL, "startReading", .{}))) return error.InvalidVideo;
        self.reader = reader.retain();
        self.output = output.retain();
    }

    fn stopReader(self: *Decoder) void {
        if (self.reader) |r| {
            r.msg(void, "cancelReading", .{});
            r.release();
        }
        if (self.output) |o| o.release();
        self.reader = null;
        self.output = null;
    }

    pub fn deinit(self: *Decoder) void {
        self.stopReader();
        self.track.release();
        self.asset.release();
        if (self.canvas) |*c| c.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn next(self: *Decoder) error{ OutOfMemory, InvalidVideo }!?anim.Frame {
        const a = self.api;
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const output = self.output orelse return error.InvalidVideo;
        const sbuf = output.msg(?*anyopaque, "copyNextSampleBuffer", .{}) orelse {
            const status = self.reader.?.msg(objc.NSInteger, "status", .{});
            return if (status == reader_status_completed) null else error.InvalidVideo;
        };
        defer a.cf_release(sbuf);
        const pb = a.get_image_buffer(sbuf) orelse return error.InvalidVideo;
        if (a.lock(pb, 1) != 0) return error.InvalidVideo;
        defer _ = a.unlock(pb, 1);
        const w: u32 = @intCast(a.width(pb));
        const h: u32 = @intCast(a.height(pb));
        const base = a.base_address(pb) orelse return error.InvalidVideo;
        const stride = a.bytes_per_row(pb);
        if (w == 0 or h == 0 or stride < @as(usize, w) * 4) return error.InvalidVideo;
        if (self.canvas == null or self.canvas.?.width != w or self.canvas.?.height != h) {
            if (self.canvas) |*c| c.deinit(self.gpa);
            self.canvas = null;
            self.canvas = .{ .width = w, .height = h, .pixels = try self.gpa.alloc([4]u8, @as(usize, w) * h) };
        }
        const canvas = self.canvas.?;
        for (0..h) |y| {
            const src = base[y * stride ..][0 .. @as(usize, w) * 4];
            const dst = canvas.pixels[y * w ..][0..w];
            for (dst, 0..) |*p, x| p.* = .{ src[x * 4 + 2], src[x * 4 + 1], src[x * 4], src[x * 4 + 3] };
        }
        const d = a.get_duration(sbuf);
        const dur: u64 = if (d.flags & cmtime_valid != 0 and d.timescale > 0 and d.value > 0)
            @intCast(@divTrunc(@as(i128, d.value) * std.time.ns_per_s, d.timescale))
        else
            self.fallback_ns;
        return .{ .image = canvas, .duration_ns = dur };
    }

    pub fn rewind(self: *Decoder) error{ OutOfMemory, InvalidVideo }!void {
        try self.startReader();
    }
};
