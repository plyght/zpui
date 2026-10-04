//! Raster/SVG decoding to straight-alpha BGRA (gpui `ImageAssetLoader::load`
//! + `decode_static_image`): PNG, JPEG, GIF (every frame, with delays), BMP,
//! TGA, HDR, PNM via stb_image; WebP (still images; first frame) via
//! simplewebp; anything else that parses as SVG via lunasvg (gpui falls back
//! to `render_single_frame` the same way). EXIF orientation is applied like
//! gpui's `apply_orientation` (JPEG APP1, PNG eXIf, WebP EXIF), and images
//! larger than `Options.max_dimension` are downscaled with an area filter.
//!
//! Everything here is a pure function of its inputs (no globals, no shared
//! state), so the window layer can run `decode` inside an executor job.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig");
const svg = @import("svg.zig");
const render_image = @import("render_image.zig");
const DecodedImage = render_image.DecodedImage;
const Frame = render_image.Frame;

pub const Format = enum {
    png,
    jpeg,
    gif,
    bmp,
    webp,
    tga,
    hdr,
    pnm,
    svg,

    pub fn mimeType(self: Format) []const u8 {
        return switch (self) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .bmp => "image/bmp",
            .webp => "image/webp",
            .tga => "image/x-tga",
            .hdr => "image/vnd.radiance",
            .pnm => "image/x-portable-anymap",
            .svg => "image/svg+xml",
        };
    }

    /// From a file extension (with or without the dot), case-insensitive.
    pub fn fromExtension(ext_in: []const u8) ?Format {
        const ext = if (ext_in.len > 0 and ext_in[0] == '.') ext_in[1..] else ext_in;
        const table = [_]struct { []const u8, Format }{
            .{ "png", .png },  .{ "jpg", .jpeg }, .{ "jpeg", .jpeg }, .{ "gif", .gif },
            .{ "bmp", .bmp },  .{ "webp", .webp }, .{ "tga", .tga },  .{ "hdr", .hdr },
            .{ "pbm", .pnm },  .{ "pgm", .pnm },  .{ "ppm", .pnm },   .{ "pnm", .pnm },
            .{ "svg", .svg },
        };
        for (table) |e| if (std.ascii.eqlIgnoreCase(ext, e[0])) return e[1];
        return null;
    }
};

/// File extensions `decode` handles (gpui `Img::extensions`, restricted to what is vendored).
pub const extensions = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "bmp", "tga", "hdr", "pbm", "pgm", "ppm", "pnm", "svg" };

/// Sniff the format from magic bytes (gpui `image::guess_format`, then SVG).
pub fn guessFormat(bytes: []const u8) ?Format {
    const startsWith = std.mem.startsWith;
    if (startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (startsWith(u8, bytes, "\xff\xd8\xff")) return .jpeg;
    if (startsWith(u8, bytes, "GIF87a") or startsWith(u8, bytes, "GIF89a")) return .gif;
    if (startsWith(u8, bytes, "BM")) return .bmp;
    if (bytes.len >= 12 and startsWith(u8, bytes, "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    if (startsWith(u8, bytes, "#?RADIANCE") or startsWith(u8, bytes, "#?RGBE")) return .hdr;
    if (bytes.len >= 2 and bytes[0] == 'P' and bytes[1] >= '1' and bytes[1] <= '6') return .pnm;
    if (looksLikeSvg(bytes)) return .svg;
    // TGA has no magic; let stb try it last.
    return null;
}

fn looksLikeSvg(bytes: []const u8) bool {
    var s = bytes;
    if (std.mem.startsWith(u8, s, "\xef\xbb\xbf")) s = s[3..];
    s = std.mem.trimStart(u8, s, " \t\r\n");
    if (s.len == 0 or s[0] != '<') return false;
    const head = s[0..@min(s.len, 4096)];
    return std.mem.indexOf(u8, head, "<svg") != null;
}

pub const Options = struct {
    /// Longest allowed side; larger images are downscaled (aspect kept). The
    /// atlas holds tiles up to `Atlas.Options.max_size - 1` per side.
    max_dimension: u32 = 4096,
    /// Decode every GIF frame (gpui animates GIFs); false keeps only the first.
    animate: bool = true,
    /// Upper bound on decoded frames (memory guard for long GIFs).
    max_frames: u32 = 1024,
    /// Apply EXIF orientation (gpui does).
    apply_orientation: bool = true,
    /// SVG render scale (gpui `render_single_frame(bytes, 1.0)`; the image is
    /// rasterized at `svg_scale * SMOOTH_SVG_SCALE_FACTOR`).
    svg_scale: f32 = 1.0,
};

pub const Error = error{ OutOfMemory, UnsupportedFormat, InvalidImage, ImageTooLarge };

pub const Info = struct { format: Format, width: u32, height: u32 };

/// Format and dimensions without decoding pixels (SVG: intrinsic size, parses the document).
pub fn probe(bytes: []const u8) ?Info {
    const format = guessFormat(bytes) orelse .tga;
    switch (format) {
        .svg => {
            var doc = svg.Document.parse(bytes) catch return null;
            defer doc.deinit();
            return .{ .format = .svg, .width = @intFromFloat(@ceil(doc.width)), .height = @intFromFloat(@ceil(doc.height)) };
        },
        .webp => {
            const d = webpDimensions(bytes) orelse return null;
            return .{ .format = .webp, .width = d[0], .height = d[1] };
        },
        else => {
            if (bytes.len > std.math.maxInt(c_int)) return null;
            var w: c_int = 0;
            var h: c_int = 0;
            if (c.zpui_stbi_info(bytes.ptr, @intCast(bytes.len), &w, &h) == 0) return null;
            return .{ .format = format, .width = @intCast(w), .height = @intCast(h) };
        },
    }
}

/// Decode `bytes` into BGRA frames allocated with `gpa` (gpui `ImageAssetLoader::load`).
pub fn decode(gpa: Allocator, bytes: []const u8, options: Options) Error!DecodedImage {
    const format = guessFormat(bytes);
    var decoded: DecodedImage = switch (format orelse .tga) {
        .svg => return svg.rasterizeImage(gpa, bytes, options.svg_scale) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidImage,
        },
        .webp => try decodeWebp(gpa, bytes),
        .gif => if (options.animate) try decodeGif(gpa, bytes, options.max_frames) else try decodeStb(gpa, bytes),
        else => decodeStb(gpa, bytes) catch |err| return if (format == null and err == error.InvalidImage) error.UnsupportedFormat else err,
    };
    errdefer decoded.deinit(gpa);

    for (decoded.frames) |*f| {
        if (@max(f.width, f.height) > options.max_dimension) {
            const scale = @as(f64, @floatFromInt(options.max_dimension)) / @as(f64, @floatFromInt(@max(f.width, f.height)));
            const nw: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(f.width)) * scale))));
            const nh: u32 = @max(1, @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(f.height)) * scale))));
            const out = try downscale(gpa, f.pixels, f.width, f.height, nw, nh);
            gpa.free(f.pixels);
            f.pixels = out;
            f.width = nw;
            f.height = nh;
        }
    }

    if (options.apply_orientation and (format == .jpeg or format == .png or format == .webp)) {
        const orientation = exifOrientation(bytes, format.?);
        if (orientation > 1) for (decoded.frames) |*f| try applyOrientation(gpa, f, orientation);
    }
    return decoded;
}

/// Read a file and decode it (gpui `Resource::Path`). Meant for workers.
pub fn decodeFile(gpa: Allocator, io: std.Io, path: []const u8, options: Options) (Error || std.Io.Dir.ReadFileAllocError)!DecodedImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(256 << 20));
    defer gpa.free(bytes);
    return decode(gpa, bytes, options);
}

// ---------------------------------------------------------------------------
// Backends
// ---------------------------------------------------------------------------

fn oneFrame(gpa: Allocator, width: u32, height: u32, pixels: []u8) Allocator.Error!DecodedImage {
    const frames = try gpa.alloc(Frame, 1);
    frames[0] = .{ .width = width, .height = height, .pixels = pixels };
    return .{ .frames = frames };
}

/// Copy C-allocated RGBA into a `gpa` buffer as BGRA.
fn rgbaToBgra(gpa: Allocator, src: []const u8) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, src.len);
    var i: usize = 0;
    while (i + 4 <= src.len) : (i += 4) {
        out[i + 0] = src[i + 2];
        out[i + 1] = src[i + 1];
        out[i + 2] = src[i + 0];
        out[i + 3] = src[i + 3];
    }
    return out;
}

fn decodeStb(gpa: Allocator, bytes: []const u8) Error!DecodedImage {
    if (bytes.len > std.math.maxInt(c_int)) return error.ImageTooLarge;
    var w: c_int = 0;
    var h: c_int = 0;
    const ptr = c.zpui_stbi_load_rgba(bytes.ptr, @intCast(bytes.len), &w, &h) orelse {
        const reason = std.mem.span(c.zpui_stbi_failure_reason());
        return if (std.mem.eql(u8, reason, "outofmem")) error.OutOfMemory else if (std.mem.eql(u8, reason, "too large")) error.ImageTooLarge else error.InvalidImage;
    };
    defer c.zpui_decode_free(ptr);
    const len = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    const pixels = try rgbaToBgra(gpa, ptr[0..len]);
    errdefer gpa.free(pixels);
    return oneFrame(gpa, @intCast(w), @intCast(h), pixels);
}

fn decodeGif(gpa: Allocator, bytes: []const u8, max_frames: u32) Error!DecodedImage {
    if (bytes.len > std.math.maxInt(c_int)) return error.ImageTooLarge;
    var w: c_int = 0;
    var h: c_int = 0;
    var n: c_int = 0;
    var delays: ?[*]c_int = null;
    const ptr = c.zpui_stbi_load_gif(bytes.ptr, @intCast(bytes.len), &delays, &w, &h, &n) orelse return error.InvalidImage;
    defer c.zpui_decode_free(ptr);
    defer c.zpui_decode_free(delays);
    const count: usize = @min(@as(usize, @intCast(@max(n, 0))), max_frames);
    if (count == 0) return error.InvalidImage;
    const frame_len = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;

    const frames = try gpa.alloc(Frame, count);
    var done: usize = 0;
    errdefer {
        for (frames[0..done]) |f| gpa.free(f.pixels);
        gpa.free(frames);
    }
    while (done < count) : (done += 1) {
        const d: i64 = if (delays) |ds| ds[done] else 0;
        frames[done] = .{
            .width = @intCast(w),
            .height = @intCast(h),
            // Browsers (and gpui's image crate users) treat <= 10 ms as "unspecified".
            .delay_ms = if (d <= 10) render_image.default_delay_ms else @intCast(d),
            .pixels = try rgbaToBgra(gpa, ptr[done * frame_len ..][0..frame_len]),
        };
    }
    return .{ .frames = frames };
}

fn decodeWebp(gpa: Allocator, bytes: []const u8) Error!DecodedImage {
    var w: c_int = 0;
    var h: c_int = 0;
    const ptr = c.zpui_webp_load_rgba(bytes.ptr, bytes.len, &w, &h) orelse return error.InvalidImage;
    defer c.zpui_decode_free(ptr);
    const len = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    const pixels = try rgbaToBgra(gpa, ptr[0..len]);
    errdefer gpa.free(pixels);
    return oneFrame(gpa, @intCast(w), @intCast(h), pixels);
}

fn webpDimensions(bytes: []const u8) ?[2]u32 {
    if (bytes.len < 30) return null;
    const chunk = bytes[12..16];
    const d = bytes[20..];
    if (std.mem.eql(u8, chunk, "VP8X")) {
        const w = 1 + (@as(u32, d[4]) | @as(u32, d[5]) << 8 | @as(u32, d[6]) << 16);
        const h = 1 + (@as(u32, d[7]) | @as(u32, d[8]) << 8 | @as(u32, d[9]) << 16);
        return .{ w, h };
    }
    if (std.mem.eql(u8, chunk, "VP8L")) {
        if (d[0] != 0x2f) return null;
        const bits = std.mem.readInt(u32, d[1..5], .little);
        return .{ (bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1 };
    }
    if (std.mem.eql(u8, chunk, "VP8 ")) {
        if (d[3] != 0x9d or d[4] != 0x01 or d[5] != 0x2a) return null;
        return .{ std.mem.readInt(u16, d[6..8], .little) & 0x3fff, std.mem.readInt(u16, d[8..10], .little) & 0x3fff };
    }
    return null;
}

// ---------------------------------------------------------------------------
// Downscaling (area average in premultiplied space)
// ---------------------------------------------------------------------------

/// Resample BGRA `src` (sw x sh, straight alpha) to dw x dh with a box/area
/// filter (each destination pixel averages the source area it covers).
/// Premultiplies while accumulating so transparent pixels don't bleed color.
pub fn downscale(gpa: Allocator, src: []const u8, sw: u32, sh: u32, dw: u32, dh: u32) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, @as(usize, dw) * dh * 4);
    errdefer gpa.free(out);
    // Horizontal pass into a float buffer of dw x sh (premultiplied).
    const tmp = try gpa.alloc([4]f32, @as(usize, dw) * sh);
    defer gpa.free(tmp);
    const fx = @as(f64, @floatFromInt(sw)) / @as(f64, @floatFromInt(dw));
    const fy = @as(f64, @floatFromInt(sh)) / @as(f64, @floatFromInt(dh));

    for (0..sh) |y| {
        const row = src[y * sw * 4 ..][0 .. sw * 4];
        for (0..dw) |x| {
            const x0 = @as(f64, @floatFromInt(x)) * fx;
            const x1 = x0 + fx;
            var acc: [4]f64 = @splat(0);
            var sx: usize = @intFromFloat(@floor(x0));
            while (sx < sw and @as(f64, @floatFromInt(sx)) < x1) : (sx += 1) {
                const lo = @max(x0, @as(f64, @floatFromInt(sx)));
                const hi = @min(x1, @as(f64, @floatFromInt(sx + 1)));
                const wgt = hi - lo;
                if (wgt <= 0) continue;
                const p = row[sx * 4 ..][0..4];
                const a = @as(f64, @floatFromInt(p[3])) / 255.0;
                acc[0] += wgt * @as(f64, @floatFromInt(p[0])) * a;
                acc[1] += wgt * @as(f64, @floatFromInt(p[1])) * a;
                acc[2] += wgt * @as(f64, @floatFromInt(p[2])) * a;
                acc[3] += wgt * @as(f64, @floatFromInt(p[3]));
            }
            tmp[y * dw + x] = .{ @floatCast(acc[0] / fx), @floatCast(acc[1] / fx), @floatCast(acc[2] / fx), @floatCast(acc[3] / fx) };
        }
    }
    // Vertical pass.
    for (0..dh) |y| {
        const y0 = @as(f64, @floatFromInt(y)) * fy;
        const y1 = y0 + fy;
        for (0..dw) |x| {
            var acc: [4]f64 = @splat(0);
            var sy: usize = @intFromFloat(@floor(y0));
            while (sy < sh and @as(f64, @floatFromInt(sy)) < y1) : (sy += 1) {
                const lo = @max(y0, @as(f64, @floatFromInt(sy)));
                const hi = @min(y1, @as(f64, @floatFromInt(sy + 1)));
                const wgt = hi - lo;
                if (wgt <= 0) continue;
                const p = tmp[sy * dw + x];
                inline for (0..4) |k| acc[k] += wgt * p[k];
            }
            const o = out[(y * dw + x) * 4 ..][0..4];
            const a = acc[3] / fy;
            o[3] = @intFromFloat(@min(255.0, @round(a)));
            if (a <= 0.0) {
                o[0] = 0;
                o[1] = 0;
                o[2] = 0;
            } else {
                const un = 255.0 / a;
                inline for (0..3) |k| o[k] = @intFromFloat(@min(255.0, @round(acc[k] / fy * un)));
            }
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// EXIF orientation
// ---------------------------------------------------------------------------

/// EXIF orientation tag (1..8; 1 = as stored) from a JPEG APP1, PNG eXIf or WebP EXIF chunk.
pub fn exifOrientation(bytes: []const u8, format: Format) u8 {
    const tiff = switch (format) {
        .jpeg => jpegExif(bytes),
        .png => pngExif(bytes),
        .webp => webpExif(bytes),
        else => null,
    } orelse return 1;
    return tiffOrientation(tiff) orelse 1;
}

fn jpegExif(bytes: []const u8) ?[]const u8 {
    var i: usize = 2;
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xff) return null;
        const marker = bytes[i + 1];
        if (marker == 0xff) {
            i += 1;
            continue;
        }
        if (marker == 0xd8 or (marker >= 0xd0 and marker <= 0xd7) or marker == 0x01) {
            i += 2;
            continue;
        }
        if (marker == 0xda or marker == 0xd9) return null; // start of scan / end
        const len = std.mem.readInt(u16, bytes[i + 2 ..][0..2], .big);
        if (len < 2 or i + 2 + len > bytes.len) return null;
        const seg = bytes[i + 4 .. i + 2 + len];
        if (marker == 0xe1 and std.mem.startsWith(u8, seg, "Exif\x00\x00")) return seg[6..];
        i += 2 + len;
    }
    return null;
}

fn pngExif(bytes: []const u8) ?[]const u8 {
    var i: usize = 8;
    while (i + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[i..][0..4], .big);
        const kind = bytes[i + 4 .. i + 8];
        if (len > bytes.len - i - 12) return null;
        if (std.mem.eql(u8, kind, "eXIf")) return bytes[i + 8 ..][0..len];
        if (std.mem.eql(u8, kind, "IEND")) return null;
        i += 12 + len;
    }
    return null;
}

fn webpExif(bytes: []const u8) ?[]const u8 {
    var i: usize = 12;
    while (i + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        if (len > bytes.len - i - 8) return null;
        const data = bytes[i + 8 ..][0..len];
        if (std.mem.eql(u8, bytes[i .. i + 4], "EXIF"))
            return if (std.mem.startsWith(u8, data, "Exif\x00\x00")) data[6..] else data;
        i += 8 + len + (len & 1);
    }
    return null;
}

fn tiffOrientation(t: []const u8) ?u8 {
    if (t.len < 8) return null;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, t[0..2], "II")) .little else if (std.mem.eql(u8, t[0..2], "MM")) .big else return null;
    if (std.mem.readInt(u16, t[2..4], endian) != 42) return null;
    const ifd = std.mem.readInt(u32, t[4..8], endian);
    if (ifd > t.len - 2) return null;
    const count = std.mem.readInt(u16, t[ifd..][0..2], endian);
    var e: usize = ifd + 2;
    var n: usize = 0;
    while (n < count and e + 12 <= t.len) : ({
        n += 1;
        e += 12;
    }) {
        if (std.mem.readInt(u16, t[e..][0..2], endian) != 0x0112) continue;
        const v = std.mem.readInt(u16, t[e + 8 ..][0..2], endian);
        return if (v >= 1 and v <= 8) @intCast(v) else null;
    }
    return null;
}

/// Rotate/flip a frame so it displays upright (gpui `apply_orientation`).
pub fn applyOrientation(gpa: Allocator, f: *Frame, orientation: u8) Allocator.Error!void {
    if (orientation <= 1 or orientation > 8) return;
    const w = f.width;
    const h = f.height;
    const swap = orientation >= 5;
    const ow = if (swap) h else w;
    const oh = if (swap) w else h;
    const out = try gpa.alloc(u8, f.pixels.len);
    const src: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, f.pixels));
    const dst: []u32 = @alignCast(std.mem.bytesAsSlice(u32, out));
    for (0..oh) |dy| for (0..ow) |dx| {
        const s: [2]usize = switch (orientation) {
            2 => .{ w - 1 - dx, dy },
            3 => .{ w - 1 - dx, h - 1 - dy },
            4 => .{ dx, h - 1 - dy },
            5 => .{ dy, dx },
            6 => .{ dy, h - 1 - dx },
            7 => .{ w - 1 - dy, h - 1 - dx },
            8 => .{ w - 1 - dy, dx },
            else => unreachable,
        };
        dst[dy * ow + dx] = src[s[1] * w + s[0]];
    };
    gpa.free(f.pixels);
    f.pixels = out;
    f.width = ow;
    f.height = oh;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// 2x1 RGBA PNG (red, half-transparent blue), generated with ImageMagick.
const tiny_png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x01\x08\x06\x00\x00\x00\xf4\x22\x7f\x8a\x00\x00\x00\x11\x49\x44\x41\x54\x08\xd7\x63\xf8\xcf\xc0\xf0\x9f\x81\xe1\x7f\x03\x00\x0f\x7a\x03\x7e\x1b\xda\x3d\x85\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82";

test "guessFormat" {
    try std.testing.expectEqual(Format.png, guessFormat(tiny_png).?);
    try std.testing.expectEqual(Format.jpeg, guessFormat("\xff\xd8\xff\xe0").?);
    try std.testing.expectEqual(Format.gif, guessFormat("GIF89a....").?);
    try std.testing.expectEqual(Format.webp, guessFormat("RIFF\x00\x00\x00\x00WEBPVP8 ").?);
    try std.testing.expectEqual(Format.svg, guessFormat("\xef\xbb\xbf  <?xml version=\"1.0\"?>\n<svg xmlns=\"\"/>").?);
    try std.testing.expectEqual(@as(?Format, null), guessFormat("hello"));
    try std.testing.expectEqual(Format.jpeg, Format.fromExtension(".JPG").?);
}

test "decode PNG to BGRA" {
    const gpa = std.testing.allocator;
    var img = try decode(gpa, tiny_png, .{});
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), img.frames.len);
    const f = img.frames[0];
    try std.testing.expectEqual(@as(u32, 2), f.width);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 255, 0, 0, 128 }, f.pixels);
    const info = probe(tiny_png).?;
    try std.testing.expectEqual(@as(u32, 1), info.height);
}

test "decode SVG through the svg fallback" {
    const gpa = std.testing.allocator;
    var img = try decode(gpa, "<svg width=\"10\" height=\"5\" xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"10\" height=\"5\" fill=\"#ff0000\"/></svg>", .{});
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(f32, 2), img.scale_factor);
    try std.testing.expectEqual(@as(u32, 20), img.frames[0].width);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, img.frames[0].pixels[0..4]);
}

test "decode errors" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedFormat, decode(gpa, "not an image", .{}));
    try std.testing.expectError(error.InvalidImage, decode(gpa, tiny_png[0..40], .{}));
    try std.testing.expectError(error.InvalidImage, decode(gpa, "<svg", .{}));
}

test "downscale averages area and respects alpha" {
    const gpa = std.testing.allocator;
    // 2x2: opaque white, transparent "red" garbage, opaque white, opaque white.
    const src = [_]u8{ 255, 255, 255, 255, 0, 0, 255, 0, 255, 255, 255, 255, 255, 255, 255, 255 };
    const out = try downscale(gpa, &src, 2, 2, 1, 1);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(u8, &.{ 255, 255, 255, 191 }, out);

    var img = try decode(gpa, tiny_png, .{ .max_dimension = 1 });
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), img.frames[0].width);
}

test "orientation transforms" {
    const gpa = std.testing.allocator;
    // 3x2 frame, pixel value = index.
    const base = [_]u32{ 0, 1, 2, 3, 4, 5 };
    const expected = [_][]const u32{
        &.{ 2, 1, 0, 5, 4, 3 }, // 2 mirror
        &.{ 5, 4, 3, 2, 1, 0 }, // 3 rotate 180
        &.{ 3, 4, 5, 0, 1, 2 }, // 4 flip vertical
        &.{ 0, 3, 1, 4, 2, 5 }, // 5 transpose
        &.{ 3, 0, 4, 1, 5, 2 }, // 6 rotate 90 cw
        &.{ 5, 2, 4, 1, 3, 0 }, // 7 transverse
        &.{ 2, 5, 1, 4, 0, 3 }, // 8 rotate 90 ccw
    };
    for (expected, 2..) |want, o| {
        var f: Frame = .{ .width = 3, .height = 2, .pixels = try gpa.dupe(u8, std.mem.sliceAsBytes(&base)) };
        defer gpa.free(f.pixels);
        try applyOrientation(gpa, &f, @intCast(o));
        try std.testing.expectEqual(@as(u32, if (o >= 5) 2 else 3), f.width);
        const got: []const u32 = @alignCast(std.mem.bytesAsSlice(u32, f.pixels));
        try std.testing.expectEqualSlices(u32, want, got);
    }
}

test "EXIF orientation from a JPEG APP1 segment" {
    // SOI, APP1 "Exif\0\0" + big-endian TIFF with one IFD entry (orientation = 6), SOS.
    const jpeg = "\xff\xd8" ++ "\xff\xe1\x00\x22" ++ "Exif\x00\x00" ++ "MM\x00\x2a\x00\x00\x00\x08" ++ "\x00\x01" ++
        "\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00" ++ "\x00\x00\x00\x00" ++ "\xff\xda";
    try std.testing.expectEqual(@as(u8, 6), exifOrientation(jpeg, .jpeg));
    try std.testing.expectEqual(@as(u8, 1), exifOrientation("\xff\xd8\xff\xda", .jpeg));
}
