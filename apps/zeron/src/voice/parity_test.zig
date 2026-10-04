//! Parity with Rust zeron-voice (data from apps/zeron/scripts/voice_parity.rs):
//! the resampler and the log-mel features always; the full transcript of
//! apps/zeron/fixtures/voice/speech.wav when ONNX Runtime and the model are
//! available (`ZERON_VOICE_MODEL=<dir>`, `ZERON_ONNXRUNTIME=<lib>`), else
//! that test is skipped.

const std = @import("std");
const data = @import("parity_data.zig");
const resample = @import("resample.zig");
const features = @import("features.zig");
const recognizer = @import("recognizer.zig");
const ort = @import("ort.zig");

const testing = std.testing;
const wav_path = "apps/zeron/fixtures/voice/speech.wav";

/// voice_parity.rs `signal`.
fn signal(gpa: std.mem.Allocator, n: usize, seed: u32) ![]f32 {
    const v = try gpa.alloc(f32, n);
    var state = seed;
    for (v, 0..) |*x, i| {
        state = state *% 1664525 +% 1013904223;
        const noise = @as(f32, @floatFromInt(state >> 8)) / 16777216.0 * 2.0 - 1.0;
        const phase = @as(f32, @floatFromInt(i % 200)) / 200.0;
        const tri = if (phase < 0.5) phase * 4.0 - 1.0 else 3.0 - phase * 4.0;
        x.* = 0.3 * noise + 0.5 * tri;
    }
    return v;
}

/// 16-bit PCM mono WAV → f32 (voice_parity.rs `read_wav`).
pub fn readWav(gpa: std.mem.Allocator, bytes: []const u8) ![]f32 {
    var i: usize = 12;
    while (i + 8 <= bytes.len and !std.mem.eql(u8, bytes[i .. i + 4], "data")) {
        i += 8 + std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
    }
    const n = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
    const pcm = bytes[i + 8 ..][0..n];
    const out = try gpa.alloc(f32, n / 2);
    for (out, 0..) |*s, k| s.* = @as(f32, @floatFromInt(std.mem.readInt(i16, pcm[2 * k ..][0..2], .little))) / 32768.0;
    return out;
}

test "resampler matches rubato FftFixedInOut (zeron resample::for_model)" {
    const gpa = testing.allocator;
    for (data.resample_cases) |case| {
        const input = try signal(gpa, case.n, case.seed);
        const out = try resample.forModel(gpa, input, case.rate);
        defer gpa.free(out);
        try testing.expectEqual(case.len, out.len);
        var sum: f64 = 0;
        var sum_sq: f64 = 0;
        for (out) |x| {
            sum += x;
            sum_sq += @as(f64, x) * x;
        }
        try testing.expectApproxEqAbs(case.sum, sum, 1e-3 * @max(1.0, @as(f64, @floatFromInt(out.len)) / 1000.0));
        try testing.expectApproxEqRel(case.sum_sq, sum_sq, 1e-5);
        var k: usize = 0;
        var i: usize = 0;
        while (i < out.len) : (i += data.stride) {
            try testing.expectApproxEqAbs(case.sampled[k], out[i], 2e-5);
            k += 1;
        }
        try testing.expectEqual(case.sampled.len, k);
    }
}

test "log-mel features match parakeet-rs extract_features" {
    const gpa = testing.allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, wav_path, gpa, .limited(4 << 20));
    defer gpa.free(bytes);
    const audio = try readWav(gpa, bytes);
    defer gpa.free(audio);
    var ex = try features.Extractor.init(gpa);
    defer ex.deinit();
    const f = try ex.extract(gpa, audio);
    defer f.deinit(gpa);
    try testing.expectEqual(@as(usize, data.feature_frames), f.frames);
    var k: usize = 0;
    var i: usize = 0;
    var worst: f32 = 0;
    while (i < f.data.len) : (i += data.stride * 7) {
        worst = @max(worst, @abs(data.feature_sampled[k] - f.data[i]));
        k += 1;
    }
    try testing.expectEqual(data.feature_sampled.len, k);
    // Normalised features: float summation order differs from ndarray's GEMM.
    try testing.expect(worst < 2e-3);
}

test "transcript matches zeron Recognizer (needs ONNX Runtime + model)" {
    const gpa = testing.allocator;
    const dir = std.mem.span(std.c.getenv("ZERON_VOICE_MODEL") orelse return error.SkipZigTest);
    if (!ort.available()) return error.SkipZigTest;
    var rec = try recognizer.Recognizer.load(gpa, testing.io, dir);
    defer rec.deinit();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(testing.io, wav_path, gpa, .limited(4 << 20));
    defer gpa.free(bytes);
    const audio = try readWav(gpa, bytes);
    const direct = try rec.transcribe(try gpa.dupe(f32, audio), 16_000);
    defer gpa.free(direct);
    try testing.expectEqualStrings(data.transcript_16k, direct);
    const up = try resample.convert(gpa, audio, 16_000, 48_000);
    const resampled = try rec.transcribe(up, 48_000);
    defer gpa.free(resampled);
    try testing.expectEqualStrings(data.transcript_48k, resampled);
}
