//! Minimal RIFF/WAVE reader (PCM 8/16/24/32-bit, IEEE float 32/64,
//! WAVE_FORMAT_EXTENSIBLE) and a 16-bit PCM writer for offline renders.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{ InvalidWav, UnsupportedWav, OutOfMemory };

pub const Decoded = struct {
    /// Interleaved f32 in [-1, 1].
    samples: []f32,
    channels: u8,
    rate: u32,

    pub fn deinit(self: Decoded, gpa: Allocator) void {
        gpa.free(self.samples);
    }
};

const Format = enum { pcm, float };

pub fn decode(gpa: Allocator, bytes: []const u8) Error!Decoded {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) return error.InvalidWav;
    var off: usize = 12;
    var fmt: ?struct { format: Format, channels: u16, rate: u32, bits: u16 } = null;
    var data: ?[]const u8 = null;
    while (off + 8 <= bytes.len) {
        const id = bytes[off..][0..4];
        const size = std.mem.readInt(u32, bytes[off + 4 ..][0..4], .little);
        const body_start = off + 8;
        const body_end = @min(bytes.len, body_start + @as(usize, size));
        const body = bytes[body_start..body_end];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return error.InvalidWav;
            var tag = std.mem.readInt(u16, body[0..2], .little);
            if (tag == 0xFFFE) {
                if (body.len < 40) return error.InvalidWav;
                tag = std.mem.readInt(u16, body[24..26], .little); // SubFormat GUID's first field
            }
            fmt = .{
                .format = switch (tag) {
                    1 => .pcm,
                    3 => .float,
                    else => return error.UnsupportedWav,
                },
                .channels = std.mem.readInt(u16, body[2..4], .little),
                .rate = std.mem.readInt(u32, body[4..8], .little),
                .bits = std.mem.readInt(u16, body[14..16], .little),
            };
        } else if (std.mem.eql(u8, id, "data")) {
            data = body;
        }
        off = body_start + @as(usize, size) + (size & 1);
    }
    const f = fmt orelse return error.InvalidWav;
    const d = data orelse return error.InvalidWav;
    if (f.channels == 0 or f.channels > 2 or f.rate == 0) return error.UnsupportedWav;
    const bytes_per = switch (f.format) {
        .pcm => switch (f.bits) {
            8, 16, 24, 32 => f.bits / 8,
            else => return error.UnsupportedWav,
        },
        .float => switch (f.bits) {
            32, 64 => f.bits / 8,
            else => return error.UnsupportedWav,
        },
    };
    const count = d.len / bytes_per / f.channels * f.channels;
    const out = try gpa.alloc(f32, count);
    for (out, 0..) |*s, i| {
        const p = d[i * bytes_per ..];
        s.* = switch (f.format) {
            .pcm => switch (bytes_per) {
                1 => (@as(f32, @floatFromInt(p[0])) - 128.0) / 128.0,
                2 => @as(f32, @floatFromInt(std.mem.readInt(i16, p[0..2], .little))) / 32768.0,
                3 => @as(f32, @floatFromInt(std.mem.readInt(i24, p[0..3], .little))) / 8388608.0,
                else => @as(f32, @floatFromInt(std.mem.readInt(i32, p[0..4], .little))) / 2147483648.0,
            },
            .float => if (bytes_per == 4)
                @bitCast(std.mem.readInt(u32, p[0..4], .little))
            else
                @floatCast(@as(f64, @bitCast(std.mem.readInt(u64, p[0..8], .little)))),
        };
    }
    return .{ .samples = out, .channels = @intCast(f.channels), .rate = f.rate };
}

/// Encodes interleaved f32 as a 16-bit PCM WAV file.
pub fn encode16(gpa: Allocator, samples: []const f32, channels: u16, rate: u32) Allocator.Error![]u8 {
    const data_len: u32 = @intCast(samples.len * 2);
    const out = try gpa.alloc(u8, 44 + data_len);
    const block: u16 = channels * 2;
    @memcpy(out[0..4], "RIFF");
    std.mem.writeInt(u32, out[4..8], 36 + data_len, .little);
    @memcpy(out[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, out[16..20], 16, .little);
    std.mem.writeInt(u16, out[20..22], 1, .little);
    std.mem.writeInt(u16, out[22..24], channels, .little);
    std.mem.writeInt(u32, out[24..28], rate, .little);
    std.mem.writeInt(u32, out[28..32], rate * block, .little);
    std.mem.writeInt(u16, out[32..34], block, .little);
    std.mem.writeInt(u16, out[34..36], 16, .little);
    @memcpy(out[36..40], "data");
    std.mem.writeInt(u32, out[40..44], data_len, .little);
    for (samples, 0..) |s, i| {
        const v: i16 = @intFromFloat(@round(std.math.clamp(s, -1, 1) * 32767.0));
        std.mem.writeInt(i16, out[44 + i * 2 ..][0..2], v, .little);
    }
    return out;
}

test "wav round trip" {
    const gpa = std.testing.allocator;
    const src = [_]f32{ 0, 0.5, -0.5, 1.0, -1.0, 0.25 };
    const bytes = try encode16(gpa, &src, 2, 44100);
    defer gpa.free(bytes);
    const d = try decode(gpa, bytes);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(u8, 2), d.channels);
    try std.testing.expectEqual(@as(u32, 44100), d.rate);
    try std.testing.expectEqual(src.len, d.samples.len);
    for (src, d.samples) |a, b| try std.testing.expectApproxEqAbs(a, b, 1.0 / 16384.0);
}

test "wav rejects garbage" {
    try std.testing.expectError(error.InvalidWav, decode(std.testing.allocator, "RIFF\x00\x00\x00\x00JUNK"));
}
