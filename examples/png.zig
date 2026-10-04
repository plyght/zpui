//! Minimal RGBA8 PNG encoder/decoder for the golden-image harness.
//! Encodes 8-bit RGBA with the `Sub` filter and zlib (std.compress.flate);
//! decodes 8-bit RGBA, non-interlaced PNGs with any filter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const Crc32 = std.hash.Crc32;

const signature = "\x89PNG\r\n\x1a\n";

pub const Image = struct {
    width: u32,
    height: u32,
    /// Tightly packed RGBA8 rows, top row first.
    pixels: []u8,

    pub fn deinit(self: *Image, gpa: Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

/// Encode `pixels` (RGBA8, straight alpha) as a PNG. Caller owns the result.
pub fn encode(gpa: Allocator, width: u32, height: u32, pixels: []const u8) ![]u8 {
    std.debug.assert(pixels.len == @as(usize, width) * height * 4);
    const stride = @as(usize, width) * 4;

    // Filtered scanlines: filter byte 1 (Sub) per row.
    var raw = try gpa.alloc(u8, (stride + 1) * height);
    defer gpa.free(raw);
    for (0..height) |y| {
        const row = pixels[y * stride ..][0..stride];
        const out = raw[y * (stride + 1) ..][0 .. stride + 1];
        out[0] = 1;
        for (row, 0..) |b, i| out[1 + i] = b -% (if (i >= 4) row[i - 4] else 0);
    }

    var zlib: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    defer zlib.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var compress = try flate.Compress.init(&zlib.writer, window, .zlib, .default);
    try compress.writer.writeAll(raw);
    try compress.finish();

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8-bit, RGBA, deflate, adaptive filter, no interlace
    try writeChunk(w, "IHDR", &ihdr);
    try writeChunk(w, "IDAT", zlib.written());
    try writeChunk(w, "IEND", "");
    return out.toOwnedSlice();
}

fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

/// Decode an 8-bit RGBA, non-interlaced PNG.
pub fn decode(gpa: Allocator, bytes: []const u8) !Image {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], signature)) return error.NotPng;
    var pos: usize = 8;
    var width: u32 = 0;
    var height: u32 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (pos + 12 + len > bytes.len) return error.Truncated;
        const data = bytes[pos + 8 ..][0..len];
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            if (data[8] != 8 or data[9] != 6 or data[12] != 0) return error.UnsupportedPng;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    const stride = @as(usize, width) * 4;
    var input: std.Io.Reader = .fixed(idat.items);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var decompress: flate.Decompress = .init(&input, .zlib, window);
    const raw = try decompress.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(raw);
    if (raw.len != (stride + 1) * height) return error.Truncated;

    const pixels = try gpa.alloc(u8, stride * height);
    errdefer gpa.free(pixels);
    for (0..height) |y| {
        const filter = raw[y * (stride + 1)];
        const src = raw[y * (stride + 1) + 1 ..][0..stride];
        const row = pixels[y * stride ..][0..stride];
        const prev: ?[]const u8 = if (y > 0) pixels[(y - 1) * stride ..][0..stride] else null;
        for (0..stride) |i| {
            const a: u8 = if (i >= 4) row[i - 4] else 0;
            const b: u8 = if (prev) |p| p[i] else 0;
            const cc: u8 = if (i >= 4) (if (prev) |p| p[i - 4] else 0) else 0;
            row[i] = src[i] +% switch (filter) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @as(u8, @intCast((@as(u16, a) + b) / 2)),
                4 => paeth(a, b, cc),
                else => return error.UnsupportedPng,
            };
        }
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

test "png round trip" {
    const gpa = std.testing.allocator;
    var px: [3 * 2 * 4]u8 = undefined;
    for (&px, 0..) |*p, i| p.* = @intCast(i * 7 % 256);
    const encoded = try encode(gpa, 3, 2, &px);
    defer gpa.free(encoded);
    var img = try decode(gpa, encoded);
    defer img.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &px, img.pixels);
}
