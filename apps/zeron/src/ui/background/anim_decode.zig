//! Moving new-thread backgrounds, decoding half (no Rust counterpart: Rust
//! zeron only shows stills). Sniffs what a background file is and decodes
//! animated images one composited frame at a time:
//!
//! - GIF: stb_image's compositor, streamed (`zpui_gif_stream_*` in zpui's
//!   decode shim), so only the canvas and two history buffers live in memory;
//! - APNG: the `acTL`/`fcTL`/`fdAT` chunks, each frame rebuilt as a plain PNG
//!   for zpui's (stb) decoder, then disposed/blended onto the canvas;
//! - animated WebP: the `ANIM`/`ANMF` chunks, each frame rebuilt as a still
//!   WebP for zpui's (simplewebp) decoder, then disposed/blended.
//!
//! Video (WebM / MP4 / MOV) is classified here and decoded by `video.zig`.
//!
//! ```zig
//! switch (anim_decode.classify(bytes, path)) { .still => ..., .gif, .apng, .webp => ..., .video => ... }
//! var d = try anim_decode.ImageDecoder.open(gpa, bytes, kind); // bytes must outlive `d`
//! while (try d.next(gpa)) |frame| use(frame.image, frame.duration_ns);
//! d.rewind();
//! ```
//!
//! Everything here is allocation-explicit and runs on background workers.

const std = @import("std");
const zpui = @import("zpui");
const artwork = @import("artwork.zig");

const Allocator = std.mem.Allocator;
const Rgba = artwork.Rgba;

pub const Kind = enum {
    still,
    gif,
    apng,
    webp,
    video,

    pub fn isMotion(k: Kind) bool {
        return k != .still;
    }
};

/// The shortest frame shown (a 30 fps cap); faster frames are merged.
pub const min_frame_ns: u64 = std.time.ns_per_s / 30;
/// Browsers treat GIF/APNG/WebP delays of ≤ 10 ms as "unspecified" (100 ms).
pub const default_delay_ms: u32 = 100;
/// Largest canvas side an animated image may have.
pub const max_side: u32 = 8192;

pub fn delayNs(ms: u32) u64 {
    return @as(u64, if (ms <= 10) default_delay_ms else ms) * std.time.ns_per_ms;
}

fn rd16be(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .big);
}
fn rd32be(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}
fn rd24le(b: []const u8) u32 {
    return @as(u32, b[0]) | @as(u32, b[1]) << 8 | @as(u32, b[2]) << 16;
}
fn rd32le(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

/// File extensions that may hold a moving background (the folder scan and
/// the install's staging accept these besides the still formats).
pub const video_extensions = [_][]const u8{ "webm", "mp4", "m4v", "mov", "mkv" };
pub const image_extensions = [_][]const u8{ "gif", "png", "apng", "webp" };

pub fn isVideoExtension(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return false;
    for (video_extensions) |e| if (std.ascii.eqlIgnoreCase(ext[1..], e)) return true;
    return false;
}

/// Matroska/WebM (EBML) or ISO-BMFF/QuickTime (`ftyp`, or a leading `moov`/`mdat`/`wide`/`free` atom).
pub fn looksLikeVideo(head: []const u8) bool {
    if (head.len >= 4 and std.mem.eql(u8, head[0..4], "\x1a\x45\xdf\xa3")) return true;
    if (head.len >= 8) {
        const atom = head[4..8];
        for ([_][]const u8{ "ftyp", "moov", "mdat", "wide", "free", "skip" }) |a| if (std.mem.eql(u8, atom, a)) return true;
    }
    return false;
}

/// What a background file is, from its content (the extension only breaks
/// ties for headerless video containers). `bytes` may be just the head for
/// video sniffing; image animation checks need the whole file.
pub fn classify(bytes: []const u8) Kind {
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return if (apngFrameCount(bytes) > 1) .apng else .still;
    if (std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a")) return if (gifFrameCountAtLeast(bytes, 2)) .gif else .still;
    if (bytes.len >= 12 and std.mem.startsWith(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return if (webpAnimated(bytes)) .webp else .still;
    if (looksLikeVideo(bytes)) return .video;
    return .still;
}

// ---- GIF ---------------------------------------------------------------------

/// Count image descriptors without decoding (stops at `want`).
pub fn gifFrameCountAtLeast(bytes: []const u8, want: usize) bool {
    return gifScan(bytes, want).frames >= want;
}

const GifScan = struct { frames: usize = 0, loops: ?u16 = null };

/// Walk the block structure: frames and the NETSCAPE2.0 loop count.
fn gifScan(bytes: []const u8, stop_after: usize) GifScan {
    var out: GifScan = .{};
    if (bytes.len < 13) return out;
    var pos: usize = 13;
    const flags = bytes[10];
    if (flags & 0x80 != 0) pos += 3 * (@as(usize, 2) << @intCast(flags & 7));
    const skipBlocks = struct {
        fn f(b: []const u8, p_in: usize) ?usize {
            var p = p_in;
            while (p < b.len) {
                const n = b[p];
                p += 1;
                if (n == 0) return p;
                p += n;
            }
            return null;
        }
    }.f;
    while (pos < bytes.len) {
        switch (bytes[pos]) {
            0x2C => {
                if (pos + 10 > bytes.len) return out;
                const lflags = bytes[pos + 9];
                pos += 10;
                if (lflags & 0x80 != 0) pos += 3 * (@as(usize, 2) << @intCast(lflags & 7));
                pos += 1; // LZW minimum code size
                pos = skipBlocks(bytes, pos) orelse return out;
                out.frames += 1;
                if (out.frames >= stop_after) return out;
            },
            0x21 => {
                if (pos + 2 > bytes.len) return out;
                const label = bytes[pos + 1];
                pos += 2;
                if (label == 0xFF and pos + 12 <= bytes.len and bytes[pos] == 11 and
                    (std.mem.eql(u8, bytes[pos + 1 .. pos + 12], "NETSCAPE2.0") or std.mem.eql(u8, bytes[pos + 1 .. pos + 12], "ANIMEXTS1.0")))
                {
                    const sub = pos + 12;
                    if (sub + 4 <= bytes.len and bytes[sub] >= 3 and bytes[sub + 1] == 1) out.loops = std.mem.readInt(u16, bytes[sub + 2 ..][0..2], .little);
                }
                pos = skipBlocks(bytes, pos) orelse return out;
            },
            else => return out, // 0x3B trailer or garbage
        }
    }
    return out;
}

/// Total plays (0 = forever). A NETSCAPE loop count n repeats n more times
/// (Chrome/Firefox); without the extension the animation plays once.
pub fn gifPlays(bytes: []const u8) u32 {
    const loops = gifScan(bytes, std.math.maxInt(usize)).loops orelse return 1;
    return if (loops == 0) 0 else @as(u32, loops) + 1;
}

const GifStream = opaque {};
extern fn zpui_gif_stream_open(data: [*]const u8, len: c_int) ?*GifStream;
extern fn zpui_gif_stream_next(s: *GifStream, width: *c_int, height: *c_int, delay_ms: *c_int, done: *c_int) ?[*]const u8;
extern fn zpui_gif_stream_rewind(s: *GifStream) void;
extern fn zpui_gif_stream_close(s: ?*GifStream) void;

pub const GifDecoder = struct {
    stream: *GifStream,
    canvas: Rgba,

    pub fn open(gpa: Allocator, bytes: []const u8) DecodeError!GifDecoder {
        if (bytes.len < 13 or bytes.len > std.math.maxInt(c_int)) return error.InvalidImage;
        const w = std.mem.readInt(u16, bytes[6..8], .little);
        const h = std.mem.readInt(u16, bytes[8..10], .little);
        if (w == 0 or h == 0 or w > max_side or h > max_side) return error.InvalidImage;
        const s = zpui_gif_stream_open(bytes.ptr, @intCast(bytes.len)) orelse return error.InvalidImage;
        errdefer zpui_gif_stream_close(s);
        const px = try gpa.alloc([4]u8, @as(usize, w) * h);
        return .{ .stream = s, .canvas = .{ .width = w, .height = h, .pixels = px } };
    }

    pub fn deinit(self: *GifDecoder, gpa: Allocator) void {
        zpui_gif_stream_close(self.stream);
        self.canvas.deinit(gpa);
    }

    pub fn next(self: *GifDecoder) DecodeError!?Frame {
        var w: c_int = 0;
        var h: c_int = 0;
        var delay: c_int = 0;
        var done: c_int = 0;
        const ptr = zpui_gif_stream_next(self.stream, &w, &h, &delay, &done) orelse
            return if (done != 0) null else error.InvalidImage;
        // stb's canvas is the logical screen; header and stream agree.
        if (@as(u32, @intCast(w)) != self.canvas.width or @as(u32, @intCast(h)) != self.canvas.height) return error.InvalidImage;
        @memcpy(std.mem.sliceAsBytes(self.canvas.pixels), ptr[0 .. self.canvas.pixels.len * 4]);
        return .{ .image = self.canvas, .duration_ns = delayNs(@intCast(@max(delay, 0))) };
    }

    pub fn rewind(self: *GifDecoder) void {
        zpui_gif_stream_rewind(self.stream);
    }
};

// ---- shared compositing ------------------------------------------------------

pub const DecodeError = error{ OutOfMemory, InvalidImage };

/// One composited frame. `image` is borrowed from the decoder (valid until
/// its next `next`/`rewind`).
pub const Frame = struct {
    image: Rgba,
    duration_ns: u64,
};

const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

fn clearRect(canvas: Rgba, r: Rect) void {
    for (r.y..r.y + r.h) |y| @memset(canvas.pixels[y * canvas.width + r.x ..][0..r.w], .{ 0, 0, 0, 0 });
}

/// Straight-alpha "over" (`blend`) or replace, of an RGBA patch at `r`.
fn composite(canvas: Rgba, r: Rect, patch: []const [4]u8, blend: bool) void {
    for (0..r.h) |py| {
        const row = canvas.pixels[(r.y + py) * canvas.width + r.x ..][0..r.w];
        const src = patch[py * r.w ..][0..r.w];
        if (!blend) {
            @memcpy(row, src);
            continue;
        }
        for (row, src) |*d, s| {
            if (s[3] == 255) {
                d.* = s;
            } else if (s[3] != 0) {
                const sa: u32 = s[3];
                const da: u32 = @as(u32, d[3]) * (255 - sa) / 255;
                const oa = sa + da;
                inline for (0..3) |c| d[c] = @intCast((@as(u32, s[c]) * sa + @as(u32, d[c]) * da + oa / 2) / oa);
                d[3] = @intCast(oa);
            }
        }
    }
}

fn snapshot(gpa: Allocator, keep: *?[][4]u8, canvas: Rgba) Allocator.Error!void {
    if (keep.* == null) keep.* = try gpa.alloc([4]u8, canvas.pixels.len);
    @memcpy(keep.*.?, canvas.pixels);
}

/// Decode a rebuilt still (PNG / WebP) to RGBA through zpui's decoder.
fn decodePatch(gpa: Allocator, bytes: []const u8, w: u32, h: u32) DecodeError![][4]u8 {
    var decoded = zpui.image.decode(gpa, bytes, .{ .max_dimension = max_side, .animate = false, .max_frames = 1, .apply_orientation = false }) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidImage;
    defer decoded.deinit(gpa);
    if (decoded.frames.len == 0) return error.InvalidImage;
    const f = decoded.frames[0];
    if (f.width != w or f.height != h) return error.InvalidImage;
    const out = try gpa.alloc([4]u8, @as(usize, w) * h);
    for (out, 0..) |*p, i| {
        const s = f.pixels[i * 4 ..][0..4];
        p.* = .{ s[2], s[1], s[0], s[3] };
    }
    return out;
}

// ---- APNG --------------------------------------------------------------------

/// `acTL.num_frames` when the chunk precedes the first IDAT, else 0.
pub fn apngFrameCount(bytes: []const u8) u32 {
    var pos: usize = 8;
    while (pos + 12 <= bytes.len) {
        const len = rd32be(bytes[pos..]);
        const kind = bytes[pos + 4 .. pos + 8];
        if (std.mem.eql(u8, kind, "IDAT")) return 0;
        if (std.mem.eql(u8, kind, "acTL") and len >= 8 and pos + 16 <= bytes.len) return rd32be(bytes[pos + 8 ..]);
        pos +|= 12 + @as(usize, len);
    }
    return 0;
}

const Chunk = struct { kind: [4]u8, data: []const u8 };

fn pngChunks(bytes: []const u8, it: *usize) ?Chunk {
    const pos = it.*;
    if (pos + 12 > bytes.len) return null;
    const len = rd32be(bytes[pos..]);
    if (pos + 12 + @as(usize, len) > bytes.len) return null;
    it.* = pos + 12 + len;
    return .{ .kind = bytes[pos + 4 ..][0..4].*, .data = bytes[pos + 8 ..][0..len] };
}

fn appendChunk(gpa: Allocator, out: *std.ArrayList(u8), kind: []const u8, data: []const []const u8) Allocator.Error!void {
    var len: usize = 0;
    for (data) |d| len += d.len;
    var hdr: [8]u8 = undefined;
    std.mem.writeInt(u32, hdr[0..4], @intCast(len), .big);
    @memcpy(hdr[4..8], kind);
    try out.appendSlice(gpa, &hdr);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    for (data) |d| {
        try out.appendSlice(gpa, d);
        crc.update(d);
    }
    var tail: [4]u8 = undefined;
    std.mem.writeInt(u32, &tail, crc.final(), .big);
    try out.appendSlice(gpa, &tail);
}

pub const ApngDecoder = struct {
    bytes: []const u8,
    canvas: Rgba,
    ihdr: []const u8,
    /// PLTE / tRNS / gAMA / … copied into every rebuilt frame.
    shared: std.ArrayList(Chunk) = .empty,
    /// Offset of the first chunk after IHDR.
    body: usize,
    pos: usize,
    previous: ?[][4]u8 = null,
    pending_dispose: ?struct { rect: Rect, op: u8 } = null,
    first: bool = true,

    pub fn open(gpa: Allocator, bytes: []const u8) DecodeError!ApngDecoder {
        if (!std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return error.InvalidImage;
        var it: usize = 8;
        const ihdr = pngChunks(bytes, &it) orelse return error.InvalidImage;
        if (!std.mem.eql(u8, &ihdr.kind, "IHDR") or ihdr.data.len != 13) return error.InvalidImage;
        const w = rd32be(ihdr.data);
        const h = rd32be(ihdr.data[4..]);
        if (w == 0 or h == 0 or w > max_side or h > max_side) return error.InvalidImage;
        var d: ApngDecoder = .{ .bytes = bytes, .canvas = undefined, .ihdr = ihdr.data, .body = it, .pos = it };
        errdefer d.shared.deinit(gpa);
        var scan = it;
        while (pngChunks(bytes, &scan)) |c| {
            if (std.mem.eql(u8, &c.kind, "IDAT") or std.mem.eql(u8, &c.kind, "fcTL")) break;
            if (std.mem.eql(u8, &c.kind, "acTL")) continue;
            try d.shared.append(gpa, c);
        }
        const px = try gpa.alloc([4]u8, @as(usize, w) * h);
        @memset(px, .{ 0, 0, 0, 0 });
        d.canvas = .{ .width = w, .height = h, .pixels = px };
        return d;
    }

    pub fn deinit(self: *ApngDecoder, gpa: Allocator) void {
        self.shared.deinit(gpa);
        if (self.previous) |p| gpa.free(p);
        self.canvas.deinit(gpa);
    }

    pub fn rewind(self: *ApngDecoder) void {
        self.pos = self.body;
        self.pending_dispose = null;
        self.first = true;
        @memset(self.canvas.pixels, .{ 0, 0, 0, 0 });
    }

    pub fn next(self: *ApngDecoder, gpa: Allocator) DecodeError!?Frame {
        // Find the next fcTL, then gather its IDAT (only right after it) / fdAT data.
        var fctl: ?[]const u8 = null;
        while (pngChunks(self.bytes, &self.pos)) |c| {
            if (std.mem.eql(u8, &c.kind, "fcTL")) {
                fctl = c.data;
                break;
            }
            if (std.mem.eql(u8, &c.kind, "IEND")) return null;
        }
        const ctl = fctl orelse return null;
        if (ctl.len < 26) return error.InvalidImage;
        const r: Rect = .{ .w = rd32be(ctl[4..]), .h = rd32be(ctl[8..]), .x = rd32be(ctl[12..]), .y = rd32be(ctl[16..]) };
        if (r.w == 0 or r.h == 0 or @as(u64, r.x) + r.w > self.canvas.width or @as(u64, r.y) + r.h > self.canvas.height) return error.InvalidImage;
        const num = rd16be(ctl[20..]);
        const den = rd16be(ctl[22..]);
        var dispose = ctl[24];
        const blend = ctl[25] == 1;
        // A first frame disposed "to previous" is treated as "to background" (spec).
        if (self.first and dispose == 2) dispose = 1;

        var png: std.ArrayList(u8) = .empty;
        defer png.deinit(gpa);
        try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
        var ihdr: [13]u8 = self.ihdr[0..13].*;
        std.mem.writeInt(u32, ihdr[0..4], r.w, .big);
        std.mem.writeInt(u32, ihdr[4..8], r.h, .big);
        try appendChunk(gpa, &png, "IHDR", &.{&ihdr});
        for (self.shared.items) |c| try appendChunk(gpa, &png, &c.kind, &.{c.data});
        var any = false;
        while (true) {
            const save = self.pos;
            const c = pngChunks(self.bytes, &self.pos) orelse break;
            if (std.mem.eql(u8, &c.kind, "IDAT")) {
                try appendChunk(gpa, &png, "IDAT", &.{c.data});
                any = true;
            } else if (std.mem.eql(u8, &c.kind, "fdAT")) {
                if (c.data.len < 4) return error.InvalidImage;
                try appendChunk(gpa, &png, "IDAT", &.{c.data[4..]});
                any = true;
            } else if (std.mem.eql(u8, &c.kind, "fcTL") or std.mem.eql(u8, &c.kind, "IEND")) {
                self.pos = save;
                break;
            }
        }
        if (!any) return error.InvalidImage;
        try appendChunk(gpa, &png, "IEND", &.{});

        // Previous frame's disposal, then this frame.
        if (self.pending_dispose) |pd| switch (pd.op) {
            1 => clearRect(self.canvas, pd.rect),
            2 => if (self.previous) |prev| @memcpy(self.canvas.pixels, prev),
            else => {},
        };
        if (dispose == 2) try snapshot(gpa, &self.previous, self.canvas);
        const patch = try decodePatch(gpa, png.items, r.w, r.h);
        defer gpa.free(patch);
        composite(self.canvas, r, patch, blend and !self.first);
        self.pending_dispose = .{ .rect = r, .op = dispose };
        self.first = false;
        const delay_ms: u32 = if (den == 0) num * 10 else @intCast(@as(u64, num) * 1000 / den);
        return .{ .image = self.canvas, .duration_ns = delayNs(delay_ms) };
    }
};

/// `acTL.num_plays` (0 = forever).
pub fn apngPlays(bytes: []const u8) u32 {
    var it: usize = 8;
    while (pngChunks(bytes, &it)) |c| {
        if (std.mem.eql(u8, &c.kind, "acTL") and c.data.len >= 8) return rd32be(c.data[4..]);
        if (std.mem.eql(u8, &c.kind, "IDAT")) break;
    }
    return 0;
}

// ---- animated WebP ------------------------------------------------------------

const RiffChunk = struct { kind: [4]u8, data: []const u8 };

fn riffChunk(bytes: []const u8, it: *usize) ?RiffChunk {
    const pos = it.*;
    if (pos + 8 > bytes.len) return null;
    const len = rd32le(bytes[pos + 4 ..]);
    if (pos + 8 + @as(usize, len) > bytes.len) return null;
    it.* = pos + 8 + len + (len & 1);
    return .{ .kind = bytes[pos..][0..4].*, .data = bytes[pos + 8 ..][0..len] };
}

/// VP8X with the animation flag.
pub fn webpAnimated(bytes: []const u8) bool {
    return bytes.len >= 21 and std.mem.eql(u8, bytes[12..16], "VP8X") and bytes[20] & 0x02 != 0;
}

pub fn webpPlays(bytes: []const u8) u32 {
    var it: usize = 12;
    while (riffChunk(bytes, &it)) |c| if (std.mem.eql(u8, &c.kind, "ANIM") and c.data.len >= 6) return std.mem.readInt(u16, c.data[4..6], .little);
    return 0;
}

pub const WebpDecoder = struct {
    bytes: []const u8,
    canvas: Rgba,
    body: usize,
    pos: usize,
    pending_clear: ?Rect = null,

    pub fn open(gpa: Allocator, bytes: []const u8) DecodeError!WebpDecoder {
        if (!webpAnimated(bytes) or bytes.len < 30) return error.InvalidImage;
        const w = 1 + rd24le(bytes[24..]);
        const h = 1 + rd24le(bytes[27..]);
        if (w > max_side or h > max_side) return error.InvalidImage;
        const px = try gpa.alloc([4]u8, @as(usize, w) * h);
        @memset(px, .{ 0, 0, 0, 0 });
        return .{ .bytes = bytes, .canvas = .{ .width = w, .height = h, .pixels = px }, .body = 12, .pos = 12 };
    }

    pub fn deinit(self: *WebpDecoder, gpa: Allocator) void {
        self.canvas.deinit(gpa);
    }

    pub fn rewind(self: *WebpDecoder) void {
        self.pos = self.body;
        self.pending_clear = null;
        @memset(self.canvas.pixels, .{ 0, 0, 0, 0 });
    }

    pub fn next(self: *WebpDecoder, gpa: Allocator) DecodeError!?Frame {
        const frame = while (riffChunk(self.bytes, &self.pos)) |c| {
            if (std.mem.eql(u8, &c.kind, "ANMF")) break c.data;
        } else return null;
        if (frame.len < 16) return error.InvalidImage;
        const r: Rect = .{ .x = 2 * rd24le(frame[0..]), .y = 2 * rd24le(frame[3..]), .w = 1 + rd24le(frame[6..]), .h = 1 + rd24le(frame[9..]) };
        if (@as(u64, r.x) + r.w > self.canvas.width or @as(u64, r.y) + r.h > self.canvas.height) return error.InvalidImage;
        const duration_ms = rd24le(frame[12..]);
        const flags = frame[15];
        const blend = flags & 0x02 == 0;
        const dispose = flags & 0x01 != 0;

        // Rebuild a still: RIFF WEBP + the frame's ALPH / VP8 / VP8L chunks.
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try out.appendSlice(gpa, "RIFF\x00\x00\x00\x00WEBP");
        const payload = frame[16..];
        var any = false;
        var it: usize = 0;
        while (riffChunk(payload, &it)) |c| {
            const keep = std.mem.eql(u8, &c.kind, "ALPH") or std.mem.eql(u8, &c.kind, "VP8 ") or std.mem.eql(u8, &c.kind, "VP8L");
            if (!keep) continue;
            if (!std.mem.eql(u8, &c.kind, "ALPH")) any = true;
            var hdr: [8]u8 = undefined;
            @memcpy(hdr[0..4], &c.kind);
            std.mem.writeInt(u32, hdr[4..8], @intCast(c.data.len), .little);
            try out.appendSlice(gpa, &hdr);
            try out.appendSlice(gpa, c.data);
            if (c.data.len & 1 != 0) try out.append(gpa, 0);
        }
        if (!any) return error.InvalidImage;
        std.mem.writeInt(u32, out.items[4..8], @intCast(out.items.len - 8), .little);

        if (self.pending_clear) |pc| clearRect(self.canvas, pc);
        const patch = try decodePatch(gpa, out.items, r.w, r.h);
        defer gpa.free(patch);
        composite(self.canvas, r, patch, blend);
        self.pending_clear = if (dispose) r else null;
        return .{ .image = self.canvas, .duration_ns = delayNs(duration_ms) };
    }
};

// ---- one interface -----------------------------------------------------------

pub const ImageDecoder = union(enum) {
    gif: GifDecoder,
    apng: ApngDecoder,
    webp: WebpDecoder,

    /// `bytes` must outlive the decoder.
    pub fn open(gpa: Allocator, bytes: []const u8, kind: Kind) DecodeError!ImageDecoder {
        return switch (kind) {
            .gif => .{ .gif = try GifDecoder.open(gpa, bytes) },
            .apng => .{ .apng = try ApngDecoder.open(gpa, bytes) },
            .webp => .{ .webp = try WebpDecoder.open(gpa, bytes) },
            .still, .video => error.InvalidImage,
        };
    }

    pub fn deinit(self: *ImageDecoder, gpa: Allocator) void {
        switch (self.*) {
            inline else => |*d| d.deinit(gpa),
        }
    }

    /// The next composited frame, or null after the last one.
    pub fn next(self: *ImageDecoder, gpa: Allocator) DecodeError!?Frame {
        return switch (self.*) {
            .gif => |*d| d.next(),
            .apng => |*d| d.next(gpa),
            .webp => |*d| d.next(gpa),
        };
    }

    pub fn rewind(self: *ImageDecoder) void {
        switch (self.*) {
            inline else => |*d| d.rewind(),
        }
    }
};

/// Total plays for an animated image (0 = forever).
pub fn plays(bytes: []const u8, kind: Kind) u32 {
    return switch (kind) {
        .gif => gifPlays(bytes),
        .apng => apngPlays(bytes),
        .webp => webpPlays(bytes),
        .still => 1,
        .video => 0,
    };
}

/// The first composited frame as an owned image (the poster still).
pub fn firstFrame(gpa: Allocator, bytes: []const u8, kind: Kind) DecodeError!Rgba {
    var d = try ImageDecoder.open(gpa, bytes, kind);
    defer d.deinit(gpa);
    const f = (try d.next(gpa)) orelse return error.InvalidImage;
    return .{ .width = f.image.width, .height = f.image.height, .pixels = try gpa.dupe([4]u8, f.image.pixels) };
}

// ---- test fixtures (built in code; no binary files) ----------------------------

pub const fixtures = struct {
    /// An uncompressed-LZW GIF: `frames` solid frames of 2 palette colours
    /// (index i % 2), `delay_cs` centiseconds each, optional NETSCAPE loop.
    pub fn gif(gpa: Allocator, w: u16, h: u16, colors: []const [3]u8, frame_colors: []const u8, delay_cs: u16, loops: ?u16) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, "GIF89a");
        var lsd: [7]u8 = undefined;
        std.mem.writeInt(u16, lsd[0..2], w, .little);
        std.mem.writeInt(u16, lsd[2..4], h, .little);
        lsd[4] = 0x80 | 0x70 | 1; // GCT, 8-bit color res, 4 entries
        lsd[5] = 0;
        lsd[6] = 0;
        try out.appendSlice(gpa, &lsd);
        for (0..4) |i| {
            const c: [3]u8 = if (i < colors.len) colors[i] else .{ 0, 0, 0 };
            try out.appendSlice(gpa, &c);
        }
        if (loops) |n| {
            try out.appendSlice(gpa, "\x21\xFF\x0BNETSCAPE2.0\x03\x01");
            try out.append(gpa, @intCast(n & 0xff));
            try out.append(gpa, @intCast(n >> 8));
            try out.append(gpa, 0);
        }
        for (frame_colors) |ci| {
            try out.appendSlice(gpa, &.{ 0x21, 0xF9, 4, 0x04 }); // GCE, dispose 1
            try out.append(gpa, @intCast(delay_cs & 0xff));
            try out.append(gpa, @intCast(delay_cs >> 8));
            try out.appendSlice(gpa, &.{ 0, 0 });
            try out.append(gpa, 0x2C);
            var desc: [9]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };
            std.mem.writeInt(u16, desc[4..6], w, .little);
            std.mem.writeInt(u16, desc[6..8], h, .little);
            try out.appendSlice(gpa, &desc);
            // LZW min code size 2 → 3-bit codes; emit CLEAR before every pixel so
            // the code size never grows: [clear(4), index] pairs, then EOI(5).
            try out.append(gpa, 2);
            var bits: std.ArrayList(u8) = .empty;
            defer bits.deinit(gpa);
            var acc: u32 = 0;
            var nbits: u5 = 0;
            const n = @as(usize, w) * h;
            for (0..n + 1) |k| {
                const codes: []const u32 = if (k < n) &.{ 4, ci } else &.{5};
                for (codes) |code| {
                    acc |= code << nbits;
                    nbits += 3;
                    while (nbits >= 8) {
                        try bits.append(gpa, @intCast(acc & 0xff));
                        acc >>= 8;
                        nbits -= 8;
                    }
                }
            }
            if (nbits > 0) try bits.append(gpa, @intCast(acc & 0xff));
            var i: usize = 0;
            while (i < bits.items.len) {
                const take = @min(255, bits.items.len - i);
                try out.append(gpa, @intCast(take));
                try out.appendSlice(gpa, bits.items[i .. i + take]);
                i += take;
            }
            try out.append(gpa, 0);
        }
        try out.append(gpa, 0x3B);
        return out.toOwnedSlice(gpa);
    }

    /// An APNG of solid RGBA frames (each a full-canvas frame, `delay_ms`).
    pub fn apng(gpa: Allocator, w: u32, h: u32, frame_rgba: []const [4]u8, delay_ms: u16, num_plays: u32) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
        var seq: u32 = 0;
        for (frame_rgba, 0..) |c, fi| {
            const bgra = try gpa.alloc(u8, @as(usize, w) * h * 4);
            defer gpa.free(bgra);
            var i: usize = 0;
            while (i < bgra.len) : (i += 4) bgra[i..][0..4].* = .{ c[2], c[1], c[0], c[3] };
            const png = try zpui.image.encodePng(gpa, bgra, w, h, .bgra);
            defer gpa.free(png);
            var it: usize = 8;
            var wrote_fctl = false;
            while (pngChunks(png, &it)) |ch| {
                if (fi == 0 and std.mem.eql(u8, &ch.kind, "IHDR")) {
                    try appendChunk(gpa, &out, "IHDR", &.{ch.data});
                    var actl: [8]u8 = undefined;
                    std.mem.writeInt(u32, actl[0..4], @intCast(frame_rgba.len), .big);
                    std.mem.writeInt(u32, actl[4..8], num_plays, .big);
                    try appendChunk(gpa, &out, "acTL", &.{&actl});
                }
                if (!std.mem.eql(u8, &ch.kind, "IDAT")) continue;
                // One fcTL precedes the frame's first data chunk.
                if (!wrote_fctl) {
                    var fctl: [26]u8 = @splat(0);
                    std.mem.writeInt(u32, fctl[0..4], seq, .big);
                    std.mem.writeInt(u32, fctl[4..8], w, .big);
                    std.mem.writeInt(u32, fctl[8..12], h, .big);
                    std.mem.writeInt(u16, fctl[20..22], delay_ms, .big);
                    std.mem.writeInt(u16, fctl[22..24], 1000, .big);
                    seq += 1;
                    try appendChunk(gpa, &out, "fcTL", &.{&fctl});
                    wrote_fctl = true;
                }
                if (fi == 0) {
                    try appendChunk(gpa, &out, "IDAT", &.{ch.data});
                } else {
                    var sn: [4]u8 = undefined;
                    std.mem.writeInt(u32, &sn, seq, .big);
                    seq += 1;
                    try appendChunk(gpa, &out, "fdAT", &.{ &sn, ch.data });
                }
            }
        }
        try appendChunk(gpa, &out, "IEND", &.{});
        return out.toOwnedSlice(gpa);
    }
};

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "classify sniffs animation from content" {
    const gpa = testing.allocator;
    const one = try fixtures.gif(gpa, 2, 2, &.{ .{ 255, 0, 0 }, .{ 0, 0, 255 } }, &.{0}, 5, null);
    defer gpa.free(one);
    const two = try fixtures.gif(gpa, 2, 2, &.{ .{ 255, 0, 0 }, .{ 0, 0, 255 } }, &.{ 0, 1 }, 5, 0);
    defer gpa.free(two);
    try testing.expectEqual(Kind.still, classify(one));
    try testing.expectEqual(Kind.gif, classify(two));
    try testing.expectEqual(Kind.video, classify("\x1a\x45\xdf\xa3\x01\x00\x00\x00"));
    try testing.expectEqual(Kind.video, classify("\x00\x00\x00\x20ftypisom"));
    try testing.expectEqual(Kind.still, classify("\xff\xd8\xff\xe0"));
    try testing.expect(isVideoExtension("/a/b.WebM") and isVideoExtension("x.mov") and !isVideoExtension("x.gif"));
}

test "GIF frames stream with delays, loop counts and rewind" {
    const gpa = testing.allocator;
    const bytes = try fixtures.gif(gpa, 3, 2, &.{ .{ 255, 0, 0 }, .{ 0, 0, 255 } }, &.{ 0, 1, 0 }, 4, 2);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(u32, 3), gifPlays(bytes));
    var d = try ImageDecoder.open(gpa, bytes, .gif);
    defer d.deinit(gpa);
    const expect = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 255, 0, 0, 255 } };
    for (expect) |px| {
        const f = (try d.next(gpa)).?;
        try testing.expectEqual(@as(u32, 3), f.image.width);
        try testing.expectEqual(px, f.image.pixels[5]);
        try testing.expectEqual(40 * std.time.ns_per_ms, f.duration_ns);
    }
    try testing.expect((try d.next(gpa)) == null);
    d.rewind();
    try testing.expectEqual(expect[0], (try d.next(gpa)).?.image.pixels[0]);
    // The streamed frames match zpui's whole-file GIF decode.
    var all = try zpui.image.decode(gpa, bytes, .{ .apply_orientation = false });
    defer all.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), all.frames.len);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, all.frames[1].pixels[0..4]); // BGRA blue
    // No NETSCAPE block → plays once; 2-cs delays read as unspecified.
    const once = try fixtures.gif(gpa, 1, 1, &.{.{ 1, 2, 3 }}, &.{ 0, 0 }, 1, null);
    defer gpa.free(once);
    try testing.expectEqual(@as(u32, 1), gifPlays(once));
    var d2 = try ImageDecoder.open(gpa, once, .gif);
    defer d2.deinit(gpa);
    try testing.expectEqual(100 * std.time.ns_per_ms, (try d2.next(gpa)).?.duration_ns);
}

test "APNG frames decode through rebuilt PNGs" {
    const gpa = testing.allocator;
    const bytes = try fixtures.apng(gpa, 4, 3, &.{ .{ 10, 20, 30, 255 }, .{ 200, 100, 50, 255 }, .{ 0, 255, 0, 128 } }, 50, 0);
    defer gpa.free(bytes);
    try testing.expectEqual(Kind.apng, classify(bytes));
    try testing.expectEqual(@as(u32, 0), apngPlays(bytes));
    var d = try ImageDecoder.open(gpa, bytes, .apng);
    defer d.deinit(gpa);
    const f0 = (try d.next(gpa)).?;
    try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, f0.image.pixels[0]);
    try testing.expectEqual(50 * std.time.ns_per_ms, f0.duration_ns);
    try testing.expectEqual([4]u8{ 200, 100, 50, 255 }, (try d.next(gpa)).?.image.pixels[11]);
    // Frame 3 replaces (blend_op source) — its half alpha survives.
    try testing.expectEqual([4]u8{ 0, 255, 0, 128 }, (try d.next(gpa)).?.image.pixels[0]);
    try testing.expect((try d.next(gpa)) == null);
    // The still decoder (Rust's contract) sees the default image = frame 0.
    var still = try artwork.decode(gpa, bytes);
    defer still.deinit(gpa);
    try testing.expectEqual([4]u8{ 10, 20, 30, 255 }, still.pixels[0]);
    var poster = try firstFrame(gpa, bytes, .apng);
    defer poster.deinit(gpa);
    try testing.expectEqualSlices([4]u8, still.pixels, poster.pixels);
}

test "over-compositing keeps straight alpha" {
    const gpa = testing.allocator;
    const px = try gpa.alloc([4]u8, 1);
    defer gpa.free(px);
    px[0] = .{ 0, 0, 255, 255 };
    composite(.{ .width = 1, .height = 1, .pixels = px }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, &.{.{ 255, 0, 0, 128 }}, true);
    try testing.expectEqual([4]u8{ 128, 0, 127, 255 }, px[0]);
    px[0] = .{ 0, 0, 0, 0 };
    composite(.{ .width = 1, .height = 1, .pixels = px }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, &.{.{ 255, 0, 0, 128 }}, true);
    try testing.expectEqual([4]u8{ 255, 0, 0, 128 }, px[0]);
}
