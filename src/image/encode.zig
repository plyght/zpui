//! PNG encoding (the `image` crate's `write_to(.., ImageFormat::Png)` for the
//! cases zeron needs: converting pasted/dropped BMP screenshots to PNG and
//! writing rasterized SVGs). 8-bit RGBA, filter type 0 (None) per row, zlib
//! stream from `std.compress.flate`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

pub const Error = error{ OutOfMemory, WriteFailed, ZeroSize };

/// Encodes straight-alpha pixels as an RGBA PNG. `pixels` is `width * height * 4`
/// bytes in `layout` order (zpui's decoders produce BGRA).
pub fn encodePng(gpa: Allocator, pixels: []const u8, width: u32, height: u32, layout: enum { rgba, bgra }) Error![]u8 {
    if (width == 0 or height == 0) return error.ZeroSize;
    std.debug.assert(pixels.len == @as(usize, width) * height * 4);
    // Raw scanlines: a filter byte (0) then RGBA.
    const stride = @as(usize, width) * 4;
    const raw = try gpa.alloc(u8, (stride + 1) * height);
    defer gpa.free(raw);
    for (0..height) |y| {
        const dst = raw[y * (stride + 1) ..][0 .. stride + 1];
        dst[0] = 0;
        const src = pixels[y * stride ..][0..stride];
        switch (layout) {
            .rgba => @memcpy(dst[1..], src),
            .bgra => {
                var x: usize = 0;
                while (x < stride) : (x += 4) {
                    dst[1 + x] = src[x + 2];
                    dst[1 + x + 1] = src[x + 1];
                    dst[1 + x + 2] = src[x];
                    dst[1 + x + 3] = src[x + 3];
                }
            },
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
    const z = zout.written();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type RGBA
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try chunk(gpa, &out, "IHDR", &ihdr);
    try chunk(gpa, &out, "IDAT", z);
    try chunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn chunk(gpa: Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) Allocator.Error!void {
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

test "encodePng round-trips through the decoder" {
    const gpa = std.testing.allocator;
    const decode = @import("decode.zig");
    // 2x2 BGRA: red, green / blue, half-transparent white.
    const px = [_]u8{ 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255, 255, 255, 255, 128 };
    const png = try encodePng(gpa, &px, 2, 2, .bgra);
    defer gpa.free(png);
    try std.testing.expectEqual(decode.Format.png, decode.guessFormat(png).?);
    var img = try decode.decode(gpa, png, .{});
    defer img.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), img.frames[0].width);
    try std.testing.expectEqualSlices(u8, &px, img.frames[0].pixels);
}
