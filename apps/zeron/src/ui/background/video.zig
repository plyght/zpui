//! Video background frames, per platform: AVFoundation on macOS
//! (`video_mac.zig`), GStreamer loaded at run time on Linux
//! (`video_gst.zig`); elsewhere video is unsupported.
//!
//! ```zig
//! var v = try video.Decoder.open(gpa, path, 1920); // error.Unsupported → video.msg_unsupported
//! while (try v.next()) |frame| use(frame);         // RGBA, borrowed until the next call
//! try v.rewind();
//! v.deinit();
//! ```

const std = @import("std");
const builtin = @import("builtin");
const anim = @import("anim_decode.zig");

const Allocator = std.mem.Allocator;

const Backend = switch (builtin.os.tag) {
    .macos => @import("video_mac.zig"),
    .linux => @import("video_gst.zig"),
    else => struct {
        pub fn available() bool {
            return false;
        }
        pub const Decoder = struct {
            const Self = @This();
            pub fn open(_: Allocator, _: []const u8, _: u32) Error!*Self {
                return error.Unsupported;
            }
            pub fn deinit(_: *Self) void {}
            pub fn next(_: *Self) error{ OutOfMemory, InvalidVideo }!?anim.Frame {
                return null;
            }
            pub fn rewind(_: *Self) error{ OutOfMemory, InvalidVideo }!void {}
        };
    },
};

pub const Error = error{ OutOfMemory, Unsupported, InvalidVideo };

/// Largest decoded side (frames are proxied smaller for effects anyway).
pub const max_decode_side: u32 = 1920;

/// Appearance-row errors for videos (Rust has no video support; worded like
/// `install::msg_unsupported`).
pub const msg_unsupported = switch (builtin.os.tag) {
    .macos => "This video can't be played on macOS. Choose an MP4 or MOV video (H.264 or HEVC), or an animated GIF, PNG or WebP.",
    .linux => "Video backgrounds need GStreamer. Install GStreamer and its good plugins, or choose an animated GIF, PNG or WebP.",
    else => "Video backgrounds aren't supported on this platform. Choose an animated GIF, PNG or WebP.",
};
pub const msg_undecodable = switch (builtin.os.tag) {
    .macos => "This video can't be played on macOS. Choose an MP4 or MOV video (H.264 or HEVC), or an animated GIF, PNG or WebP.",
    else => "This video is unsupported or damaged. Choose a WebM (VP8 or VP9) video, or an animated GIF, PNG or WebP.",
};

pub fn available() bool {
    return Backend.available();
}

pub const Decoder = struct {
    inner: *Backend.Decoder,

    pub fn open(gpa: Allocator, path: []const u8, max_side: u32) Error!Decoder {
        return .{ .inner = try Backend.Decoder.open(gpa, path, max_side) };
    }

    pub fn deinit(self: *Decoder) void {
        self.inner.deinit();
    }

    pub fn next(self: *Decoder) error{ OutOfMemory, InvalidVideo }!?anim.Frame {
        return self.inner.next();
    }

    pub fn rewind(self: *Decoder) error{ OutOfMemory, InvalidVideo }!void {
        return self.inner.rewind();
    }
};

/// The first frame as an owned image (the poster still).
pub fn firstFrame(gpa: Allocator, path: []const u8) Error!@import("artwork.zig").Rgba {
    var d = try Decoder.open(gpa, path, max_decode_side);
    defer d.deinit();
    const f = (d.next() catch |e| return e) orelse return error.InvalidVideo;
    return .{ .width = f.image.width, .height = f.image.height, .pixels = try gpa.dupe([4]u8, f.image.pixels) };
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "a WebM decodes frame by frame and loops (skipped without a backend)" {
    if (builtin.os.tag != .linux or !available()) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "clip.webm", .data = @embedFile("testdata/clip.webm") });
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(testing.io, &buf);
    const path = try std.fs.path.join(testing.allocator, &.{ buf[0..n], "clip.webm" });
    defer testing.allocator.free(path);
    var d = Decoder.open(testing.allocator, path, max_decode_side) catch |e| {
        // GStreamer without the VP8 / Matroska plugins.
        if (e == error.InvalidVideo) return error.SkipZigTest;
        return e;
    };
    defer d.deinit();
    var frames: usize = 0;
    var first: [4]u8 = undefined;
    while (try d.next()) |f| {
        try testing.expectEqual(@as(u32, 32), f.image.width);
        try testing.expectEqual(@as(u32, 16), f.image.height);
        try testing.expectEqual(100 * std.time.ns_per_ms, f.duration_ns);
        if (frames == 0) first = f.image.pixels[0];
        frames += 1;
    }
    try testing.expectEqual(@as(usize, 3), frames);
    try testing.expect(first[0] > 200 and first[1] < 60 and first[2] < 60); // red, green, blue
    try d.rewind();
    const again = (try d.next()).?;
    try testing.expect(again.image.pixels[0][0] > 200);
}
