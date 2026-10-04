//! PNG work for Appshots (zeron `appshots.rs` `trim_appshot_padding`, which uses the
//! `png` crate): decode with palette / tRNS expansion while keeping 16-bit channels,
//! crop rows and columns whose alpha is entirely zero, and re-encode keeping the
//! colour-management chunks (pHYs, gAMA, cHRM, sRGB, iCCP, cICP, mDCv, cLLi).
//! Images without an alpha channel after expansion, animated PNGs and images with
//! nothing to crop are left byte-identical (`null`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const max_attachment_bytes: u64 = 24 * 1024 * 1024;
pub const max_capture_dimension: u32 = 8_192;
pub const max_capture_pixels: u64 = 32 * 1024 * 1024;
pub const max_capture_rgba_bytes: u64 = 128 * 1024 * 1024;

/// `png_dimensions`: width/height from the IHDR without decoding.
pub fn dimensions(bytes: []const u8) ?[2]u32 {
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n") or !std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    const w = std.mem.readInt(u32, bytes[16..20], .big);
    const h = std.mem.readInt(u32, bytes[20..24], .big);
    if (w == 0 or h == 0) return null;
    return .{ w, h };
}

/// A user-facing failure message (owned by the caller's allocator when `owned`).
pub const Failure = struct {
    message: []u8,
};

pub const Error = error{ OutOfMemory, Failed };

/// `validate_capture_dimensions`; on failure `msg` receives the message.
pub fn validateDimensions(gpa: Allocator, w: u32, h: u32, msg: *?[]u8) Error!usize {
    if (w == 0 or h == 0 or w > max_capture_dimension or h > max_capture_dimension) {
        msg.* = try std.fmt.allocPrint(gpa, "The captured window dimensions ({d}×{d}) are not supported.", .{ w, h });
        return error.Failed;
    }
    const pixels = @as(u64, w) * h;
    if (pixels > max_capture_pixels or pixels * 4 > max_capture_rgba_bytes) {
        msg.* = try std.fmt.allocPrint(gpa, "The captured window ({d}×{d}) exceeds Zeron's capture budget.", .{ w, h });
        return error.Failed;
    }
    return @intCast(pixels * 4);
}

fn fail(gpa: Allocator, msg: *?[]u8, comptime text: []const u8, args: anytype) Error {
    msg.* = try std.fmt.allocPrint(gpa, text, args);
    return error.Failed;
}

const Chunk = struct { kind: [4]u8, data: []const u8 };

const color_management = [_]*const [4]u8{ "pHYs", "gAMA", "cHRM", "sRGB", "iCCP", "cICP", "mDCv", "cLLi" };

/// `trim_appshot_padding`: the cropped PNG (owned), or null when nothing changes.
pub fn trimPadding(gpa: Allocator, bytes: []const u8, msg: *?[]u8) Error!?[]u8 {
    if (bytes.len > max_attachment_bytes) return fail(gpa, msg, "The captured window is larger than Zeron's 24 MB image limit.", .{});
    const dims = dimensions(bytes) orelse return fail(gpa, msg, "The captured window is not a valid PNG image.", .{});
    _ = try validateDimensions(gpa, dims[0], dims[1], msg);
    var decoded = (decode(gpa, bytes) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return fail(gpa, msg, "Could not decode the captured window: {t}", .{e}),
    }) orelse return null;
    defer decoded.deinit(gpa);
    const w = decoded.width;
    const h = decoded.height;
    const px = decoded.pixelBytes();
    const sample = decoded.sampleBytes();
    const alpha_off = px - sample;
    const Vis = struct {
        d: *const Decoded,
        px: usize,
        sample: usize,
        alpha_off: usize,
        fn at(s: @This(), x: u32, y: u32) bool {
            const start = (@as(usize, y) * s.d.width + x) * s.px + s.alpha_off;
            for (s.d.pixels[start .. start + s.sample]) |b| if (b != 0) return true;
            return false;
        }
        fn row(s: @This(), y: u32, x0: u32, x1: u32) bool {
            var x = x0;
            while (x < x1) : (x += 1) if (s.at(x, y)) return true;
            return false;
        }
        fn col(s: @This(), x: u32, y0: u32, y1: u32) bool {
            var y = y0;
            while (y < y1) : (y += 1) if (s.at(x, y)) return true;
            return false;
        }
    };
    const v: Vis = .{ .d = &decoded, .px = px, .sample = sample, .alpha_off = alpha_off };
    var top: u32 = 0;
    while (top < h and !v.row(top, 0, w)) top += 1;
    if (top == h) return null;
    var bottom: u32 = h;
    while (bottom > top and !v.row(bottom - 1, 0, w)) bottom -= 1;
    var left: u32 = 0;
    while (left < w and !v.col(left, top, bottom)) left += 1;
    var right: u32 = w;
    while (right > left and !v.col(right - 1, top, bottom)) right -= 1;
    if (left == 0 and top == 0 and right == w and bottom == h) return null;
    const cw = right - left;
    const ch = bottom - top;
    const row_bytes = @as(usize, cw) * px;
    // Compact in place.
    for (0..ch) |r| {
        const start = ((r + top) * @as(usize, w) + left) * px;
        std.mem.copyForwards(u8, decoded.pixels[r * row_bytes ..][0..row_bytes], decoded.pixels[start..][0..row_bytes]);
    }
    return encode(gpa, decoded.pixels[0 .. row_bytes * ch], cw, ch, decoded.color_type, decoded.bit_depth, decoded.ancillary.items) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooLarge => return fail(gpa, msg, "Could not encode the captured window: encoded Appshot exceeds attachment budget", .{}),
        else => return fail(gpa, msg, "Could not encode the captured window: {t}", .{e}),
    };
}

/// Decoded pixels in the expanded output format (RGBA or gray+alpha, 8 or 16 bits).
pub const Decoded = struct {
    width: u32,
    height: u32,
    /// 6 (RGBA) or 4 (gray + alpha).
    color_type: u8,
    bit_depth: u8,
    pixels: []u8,
    /// Colour-management chunks to carry over (borrowed from the input).
    ancillary: std.ArrayList(Chunk) = .empty,

    pub fn deinit(self: *Decoded, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.ancillary.deinit(gpa);
    }
    pub fn sampleBytes(self: *const Decoded) usize {
        return self.bit_depth / 8;
    }
    pub fn pixelBytes(self: *const Decoded) usize {
        return self.sampleBytes() * @as(usize, if (self.color_type == 6) 4 else 2);
    }
};

const DecodeError = error{ OutOfMemory, Invalid, Unsupported, Truncated, TooLarge };

/// Decode `bytes` with `png::Transformations::EXPAND`. Null when the expanded image
/// has no alpha channel or is animated (nothing to trim).
pub fn decode(gpa: Allocator, bytes: []const u8) DecodeError!?Decoded {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return error.Invalid;
    var pos: usize = 8;
    var ihdr: ?[]const u8 = null;
    var plte: ?[]const u8 = null;
    var trns: ?[]const u8 = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var ancillary: std.ArrayList(Chunk) = .empty;
    errdefer ancillary.deinit(gpa);
    var seen_idat = false;
    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4].*;
        if (pos + 12 + len > bytes.len) return error.Truncated;
        const data = bytes[pos + 8 ..][0..len];
        pos += 12 + len;
        if (std.mem.eql(u8, &kind, "IHDR")) ihdr = data else if (std.mem.eql(u8, &kind, "PLTE")) plte = data else if (std.mem.eql(u8, &kind, "tRNS")) trns = data else if (std.mem.eql(u8, &kind, "acTL")) {
            ancillary.deinit(gpa);
            return null;
        } else if (std.mem.eql(u8, &kind, "IDAT")) {
            seen_idat = true;
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, &kind, "IEND")) break else if (!seen_idat) {
            for (color_management) |cm| if (std.mem.eql(u8, &kind, cm)) {
                try ancillary.append(gpa, .{ .kind = kind, .data = data });
                break;
            };
        }
    }
    const hdr = ihdr orelse return error.Invalid;
    if (hdr.len != 13) return error.Invalid;
    const w = std.mem.readInt(u32, hdr[0..4], .big);
    const h = std.mem.readInt(u32, hdr[4..8], .big);
    const depth = hdr[8];
    const color = hdr[9];
    const interlace = hdr[12];
    if (w == 0 or h == 0 or interlace > 1) return error.Invalid;
    const channels: u8 = switch (color) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.Invalid,
    };
    // Output colour after EXPAND: only images that end up with alpha are trimmed.
    const out_color: u8 = switch (color) {
        6 => 6,
        4 => 4,
        3, 2 => if (trns != null) 6 else {
            ancillary.deinit(gpa);
            return null;
        },
        0 => if (trns != null) 4 else {
            ancillary.deinit(gpa);
            return null;
        },
        else => unreachable,
    };
    if (color == 3 and plte == null) return error.Invalid;
    const out_depth: u8 = if (depth == 16) 16 else 8;
    const out_channels: usize = if (out_color == 6) 4 else 2;
    const out_px = out_channels * (out_depth / 8);
    const out_len = std.math.mul(usize, @as(usize, w) * h, out_px) catch return error.TooLarge;
    if (out_len > max_capture_rgba_bytes * 2) return error.TooLarge;

    // Inflate the whole filtered stream.
    const bits_pp: usize = @as(usize, channels) * depth;
    const passes = adam7Passes(w, h, interlace == 1);
    var raw_len: usize = 0;
    for (passes) |p| if (p.w > 0 and p.h > 0) {
        raw_len += (1 + (p.w * bits_pp + 7) / 8) * p.h;
    };
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    {
        var in: std.Io.Reader = .fixed(idat.items);
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var d = flate.Decompress.init(&in, .zlib, window);
        d.reader.readSliceAll(raw) catch return error.Truncated;
    }

    const pixels = try gpa.alloc(u8, out_len);
    errdefer gpa.free(pixels);
    const bpp_filter: usize = @max(1, bits_pp / 8);
    var off: usize = 0;
    var prev_buf: std.ArrayList(u8) = .empty;
    defer prev_buf.deinit(gpa);
    for (passes) |p| {
        if (p.w == 0 or p.h == 0) continue;
        const stride = (p.w * bits_pp + 7) / 8;
        try prev_buf.resize(gpa, stride);
        @memset(prev_buf.items, 0);
        for (0..p.h) |row| {
            const filter = raw[off];
            const line = raw[off + 1 ..][0..stride];
            off += 1 + stride;
            try unfilter(filter, line, prev_buf.items, bpp_filter);
            @memcpy(prev_buf.items, line);
            const y = p.y0 + row * p.dy;
            for (0..p.w) |col| {
                const x = p.x0 + col * p.dx;
                const dst = pixels[(y * w + x) * out_px ..][0..out_px];
                expandPixel(line, col, color, depth, plte, trns, dst, out_depth);
            }
        }
    }
    return .{ .width = w, .height = h, .color_type = out_color, .bit_depth = out_depth, .pixels = pixels, .ancillary = ancillary };
}

const Pass = struct { x0: usize, y0: usize, dx: usize, dy: usize, w: usize, h: usize };

fn adam7Passes(w: u32, h: u32, interlaced: bool) [7]Pass {
    var out: [7]Pass = @splat(.{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1, .w = 0, .h = 0 });
    if (!interlaced) {
        out[0] = .{ .x0 = 0, .y0 = 0, .dx = 1, .dy = 1, .w = w, .h = h };
        return out;
    }
    const spec = [7][4]usize{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };
    for (spec, 0..) |s, i| {
        const pw = if (w > s[0]) (w - s[0] + s[2] - 1) / s[2] else 0;
        const ph = if (h > s[1]) (h - s[1] + s[3] - 1) / s[3] else 0;
        out[i] = .{ .x0 = s[0], .y0 = s[1], .dx = s[2], .dy = s[3], .w = pw, .h = ph };
    }
    return out;
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn unfilter(filter: u8, line: []u8, prev: []const u8, bpp: usize) DecodeError!void {
    switch (filter) {
        0 => {},
        1 => for (bpp..line.len) |i| {
            line[i] +%= line[i - bpp];
        },
        2 => for (line, 0..) |*b, i| {
            b.* +%= prev[i];
        },
        3 => for (line, 0..) |*b, i| {
            const left: u16 = if (i >= bpp) line[i - bpp] else 0;
            b.* +%= @intCast((left + prev[i]) / 2);
        },
        4 => for (line, 0..) |*b, i| {
            const left: u8 = if (i >= bpp) line[i - bpp] else 0;
            const ul: u8 = if (i >= bpp) prev[i - bpp] else 0;
            b.* +%= paeth(left, prev[i], ul);
        },
        else => return error.Invalid,
    }
}

fn sampleAt(line: []const u8, index: usize, depth: u8) u16 {
    return switch (depth) {
        16 => std.mem.readInt(u16, line[index * 2 ..][0..2], .big),
        8 => line[index],
        else => blk: {
            const bit = index * depth;
            const byte = line[bit / 8];
            const shift: u3 = @intCast(8 - depth - (bit % 8));
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
            break :blk (byte >> shift) & mask;
        },
    };
}

fn put(dst: []u8, i: usize, v: u16, depth: u8) void {
    if (depth == 16) std.mem.writeInt(u16, dst[i * 2 ..][0..2], v, .big) else dst[i] = @intCast(v);
}

/// One pixel of `line` (column `col`) expanded into `dst` (RGBA / GA at `out_depth`).
fn expandPixel(line: []const u8, col: usize, color: u8, depth: u8, plte: ?[]const u8, trns: ?[]const u8, dst: []u8, out_depth: u8) void {
    const maxv: u16 = if (out_depth == 16) 0xffff else 0xff;
    switch (color) {
        6 => for (0..4) |c| put(dst, c, sampleAt(line, col * 4 + c, depth), out_depth),
        4 => for (0..2) |c| put(dst, c, sampleAt(line, col * 2 + c, depth), out_depth),
        2 => {
            var rgb: [3]u16 = undefined;
            for (0..3) |c| rgb[c] = sampleAt(line, col * 3 + c, depth);
            for (0..3) |c| put(dst, c, rgb[c], out_depth);
            const t = trns.?;
            const transparent = t.len >= 6 and rgb[0] == std.mem.readInt(u16, t[0..2], .big) and rgb[1] == std.mem.readInt(u16, t[2..4], .big) and rgb[2] == std.mem.readInt(u16, t[4..6], .big);
            put(dst, 3, if (transparent) 0 else maxv, out_depth);
        },
        3 => {
            const ix = sampleAt(line, col, depth);
            const p = plte.?;
            const ok = @as(usize, ix) * 3 + 3 <= p.len;
            for (0..3) |c| dst[c] = if (ok) p[@as(usize, ix) * 3 + c] else 0;
            const t = trns.?;
            dst[3] = if (ix < t.len) t[ix] else 255;
        },
        0 => {
            const g = sampleAt(line, col, depth);
            // Low bit depths scale up to 8 bits (`EXPAND`).
            const scaled: u16 = switch (depth) {
                1 => g * 255,
                2 => g * 85,
                4 => g * 17,
                else => g,
            };
            put(dst, 0, scaled, out_depth);
            const t = trns.?;
            const transparent = t.len >= 2 and g == std.mem.readInt(u16, t[0..2], .big);
            put(dst, 1, if (transparent) 0 else maxv, out_depth);
        },
        else => {},
    }
}

const EncodeError = error{ OutOfMemory, TooLarge, WriteFailed };

fn appendChunk(gpa: Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) EncodeError!void {
    if (out.items.len + data.len + 12 > max_attachment_bytes) return error.TooLarge;
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    var c: [4]u8 = undefined;
    std.mem.writeInt(u32, &c, crc.final(), .big);
    try out.appendSlice(gpa, &c);
}

/// Encode RGBA / GA pixels at 8 or 16 bits with adaptive per-row filtering.
pub fn encode(gpa: Allocator, pixels: []const u8, w: u32, h: u32, color: u8, depth: u8, ancillary: []const Chunk) EncodeError![]u8 {
    const px: usize = (depth / 8) * @as(usize, if (color == 6) 4 else 2);
    const stride = @as(usize, w) * px;
    const raw = try gpa.alloc(u8, (stride + 1) * h);
    defer gpa.free(raw);
    const scratch = try gpa.alloc(u8, stride);
    defer gpa.free(scratch);
    for (0..h) |y| {
        const cur = pixels[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y > 0) pixels[(y - 1) * stride ..][0..stride] else null;
        const dst = raw[y * (stride + 1) ..][0 .. stride + 1];
        var best_sum: u64 = std.math.maxInt(u64);
        for (0..5) |f| {
            var sum: u64 = 0;
            for (0..stride) |i| {
                const a: u8 = if (i >= px) cur[i - px] else 0;
                const b: u8 = if (prev) |p| p[i] else 0;
                const c: u8 = if (i >= px) (if (prev) |p| p[i - px] else 0) else 0;
                const v: u8 = switch (f) {
                    0 => cur[i],
                    1 => cur[i] -% a,
                    2 => cur[i] -% b,
                    3 => cur[i] -% @as(u8, @intCast((@as(u16, a) + b) / 2)),
                    else => cur[i] -% paeth(a, b, c),
                };
                scratch[i] = v;
                sum += @min(v, 256 - @as(u16, v));
            }
            if (sum < best_sum) {
                best_sum = sum;
                dst[0] = @intCast(f);
                @memcpy(dst[1..], scratch);
            }
        }
    }
    var zout = try std.Io.Writer.Allocating.initCapacity(gpa, 64 + raw.len / 2);
    defer zout.deinit();
    {
        const window = try gpa.alloc(u8, flate.max_window_len);
        defer gpa.free(window);
        var compress = flate.Compress.init(&zout.writer, window, .zlib, .default) catch return error.WriteFailed;
        compress.writer.writeAll(raw) catch return error.WriteFailed;
        compress.finish() catch return error.WriteFailed;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = depth;
    ihdr[9] = color;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try appendChunk(gpa, &out, "IHDR", &ihdr);
    for (ancillary) |c| try appendChunk(gpa, &out, &c.kind, c.data);
    try appendChunk(gpa, &out, "IDAT", zout.written());
    try appendChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------------------
// Tests (zeron `appshots.rs` padding tests)
// ---------------------------------------------------------------------------------------

const testing = std.testing;

/// An RGBA PNG fixture (`fixture_png`, sRGB perceptual).
pub fn fixturePng(gpa: Allocator, w: u32, h: u32, pixels: []const u8, depth: u8) ![]u8 {
    const srgb = [_]Chunk{.{ .kind = "sRGB".*, .data = &.{0} }};
    return encode(gpa, pixels, w, h, 6, depth, &srgb);
}

fn decodedPixels(gpa: Allocator, png: []const u8) !Decoded {
    return (try decode(gpa, png)).?;
}

test "trim removes Chrome backing-surface padding and keeps sRGB" {
    const gpa = testing.allocator;
    const pixels = try gpa.alloc(u8, 302 * 165 * 4);
    defer gpa.free(pixels);
    @memset(pixels, 0);
    for (0..165) |y| for (0..264) |x| @memcpy(pixels[(y * 302 + x) * 4 ..][0..4], &[_]u8{ 22, 33, 44, 255 });
    const png = try fixturePng(gpa, 302, 165, pixels, 8);
    defer gpa.free(png);
    var msg: ?[]u8 = null;
    const trimmed = (try trimPadding(gpa, png, &msg)).?;
    defer gpa.free(trimmed);
    try testing.expectEqual([2]u32{ 264, 165 }, dimensions(trimmed).?);
    var d = try decodedPixels(gpa, trimmed);
    defer d.deinit(gpa);
    for (0..264 * 165) |i| try testing.expectEqualSlices(u8, &.{ 22, 33, 44, 255 }, d.pixels[i * 4 ..][0..4]);
    try testing.expectEqual(@as(usize, 1), d.ancillary.items.len);
    try testing.expectEqualStrings("sRGB", &d.ancillary.items[0].kind);
    try testing.expectEqual(@as(?[]u8, null), try trimPadding(gpa, trimmed, &msg));
}

test "trim preserves rounded corners, faint pixels and interior transparency" {
    const gpa = testing.allocator;
    var pixels: [8 * 7 * 4]u8 = @splat(0);
    for (1..6) |y| for (2..7) |x| @memcpy(pixels[(y * 8 + x) * 4 ..][0..4], &[_]u8{ 12, 34, 56, 255 });
    pixels[(1 * 8 + 2) * 4 + 3] = 0;
    pixels[(3 * 8 + 4) * 4 + 3] = 0;
    pixels[(3 * 8 + 2) * 4 + 3] = 1;
    const png = try fixturePng(gpa, 8, 7, &pixels, 8);
    defer gpa.free(png);
    var msg: ?[]u8 = null;
    const trimmed = (try trimPadding(gpa, png, &msg)).?;
    defer gpa.free(trimmed);
    var d = try decodedPixels(gpa, trimmed);
    defer d.deinit(gpa);
    try testing.expectEqual(@as(u32, 5), d.width);
    try testing.expectEqual(@as(u32, 5), d.height);
    var expected: [5 * 5 * 4]u8 = undefined;
    for (1..6) |y| @memcpy(expected[(y - 1) * 20 ..][0..20], pixels[(y * 8 + 2) * 4 ..][0..20]);
    try testing.expectEqualSlices(u8, &expected, d.pixels);
}

test "trim keeps opaque margins and empty images untouched" {
    const gpa = testing.allocator;
    for ([_][4]u8{ .{ 0, 0, 0, 255 }, .{ 255, 255, 255, 255 }, .{ 23, 45, 67, 0 } }) |p| {
        var pixels: [8 * 6 * 4]u8 = undefined;
        for (0..48) |i| @memcpy(pixels[i * 4 ..][0..4], &p);
        const png = try fixturePng(gpa, 8, 6, &pixels, 8);
        defer gpa.free(png);
        var msg: ?[]u8 = null;
        try testing.expectEqual(@as(?[]u8, null), try trimPadding(gpa, png, &msg));
    }
}

test "trim preserves 16-bit colour and alpha precision" {
    const gpa = testing.allocator;
    var pixels: [3 * 2 * 8]u8 = @splat(0);
    const sample = [_]u8{ 0x12, 0x34, 0xab, 0xcd, 0x56, 0x78, 0x00, 0x01 };
    @memcpy(pixels[8..16], &sample);
    const png = try fixturePng(gpa, 3, 2, &pixels, 16);
    defer gpa.free(png);
    var msg: ?[]u8 = null;
    const trimmed = (try trimPadding(gpa, png, &msg)).?;
    defer gpa.free(trimmed);
    var d = try decodedPixels(gpa, trimmed);
    defer d.deinit(gpa);
    try testing.expectEqual(@as(u32, 1), d.width);
    try testing.expectEqual(@as(u8, 16), d.bit_depth);
    try testing.expectEqualSlices(u8, &sample, d.pixels);
}

test "dimension and validity checks" {
    const gpa = testing.allocator;
    var png = std.ArrayList(u8).empty;
    defer png.deinit(gpa);
    try png.appendSlice(gpa, "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR");
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, 1440, .big);
    try png.appendSlice(gpa, &b);
    std.mem.writeInt(u32, &b, 900, .big);
    try png.appendSlice(gpa, &b);
    try testing.expectEqual([2]u32{ 1440, 900 }, dimensions(png.items).?);
    try testing.expectEqual(@as(?[2]u32, null), dimensions("not a png"));
    @memset(png.items[16..20], 0);
    try testing.expectEqual(@as(?[2]u32, null), dimensions(png.items));
    var msg: ?[]u8 = null;
    try testing.expectEqual(@as(usize, 4096 * 4096 * 4), try validateDimensions(gpa, 4096, 4096, &msg));
    try testing.expectError(error.Failed, validateDimensions(gpa, 8193, 1, &msg));
    gpa.free(msg.?);
    try testing.expectError(error.Failed, validateDimensions(gpa, 8192, 8192, &msg));
    try testing.expectEqualStrings("The captured window (8192×8192) exceeds Zeron's capture budget.", msg.?);
    gpa.free(msg.?);
}
