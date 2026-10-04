//! Convert device-rate mono capture to the model's 16 kHz input on the
//! worker — zeron `crates/voice/src/resample.rs`, on a port of rubato 0.16.2's
//! synchronous `FftFixedInOut` (`synchro.rs`: an FFT overlap-add filter with
//! a BlackmanHarris² windowed-sinc low-pass, cutoff from `calculate_cutoff`).
//! Window, sinc and cutoff are evaluated in f32 exactly as rubato does for
//! `T = f32`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fft = @import("fft.zig");
const Complex = fft.Complex;

pub const model_rate: u32 = 16_000;

pub const Error = Allocator.Error || error{UnsupportedSampleRate};

/// rubato `calculate_cutoff::<f32>(npoints, BlackmanHarris2)`.
fn calculateCutoff(npoints: usize) f32 {
    const k1: f32 = 13.745202940783823;
    const k2: f32 = 121.73532586374934;
    const k3: f32 = 5964.163279612051;
    const n: f32 = @floatFromInt(npoints);
    return 1.0 / (k1 / n + k2 / (n * n) + k3 / (n * n * n) + 1.0);
}

/// rubato `make_sincs::<f32>(npoints, 1, cutoff, BlackmanHarris2)[0]`.
fn makeSinc(gpa: Allocator, npoints: usize, cutoff: f32) Allocator.Error![]f32 {
    const y = try gpa.alloc(f32, npoints);
    const pi: f32 = std.math.pi;
    const pi2 = 2.0 * pi;
    const pi4 = 4.0 * pi;
    const pi6 = 6.0 * pi;
    const np_f: f32 = @floatFromInt(npoints);
    var sum: f32 = 0;
    const half: f32 = @floatFromInt(npoints / 2);
    for (y, 0..) |*v, x| {
        const xf: f32 = @floatFromInt(x);
        // Periodic Blackman-Harris, squared.
        var w = 0.35875 - 0.48829 * @cos(pi2 * xf / np_f) + 0.14128 * @cos(pi4 * xf / np_f) - 0.01168 * @cos(pi6 * xf / np_f);
        w = w * w;
        const arg = (xf - half) * cutoff / 1.0;
        const s: f32 = if (arg == 0) 1.0 else @sin(arg * pi) / (arg * pi);
        v.* = w * s;
        sum += v.*;
    }
    // factor = 1: sincs[0][p] = y[p] / sum.
    for (y) |*v| v.* /= sum;
    return y;
}

/// rubato `FftResampler<f32>`.
const FftResampler = struct {
    gpa: Allocator,
    size_in: usize,
    size_out: usize,
    filter_f: []Complex,
    fwd: fft.RealPlan,
    inv: fft.RealPlan,
    input_buf: []f32,
    input_f: []Complex,
    output_f: []Complex,
    output_buf: []f32,

    fn init(gpa: Allocator, size_in: usize, size_out: usize) Allocator.Error!FftResampler {
        const cutoff = if (size_in > size_out)
            calculateCutoff(size_out) * @as(f32, @floatFromInt(size_out)) / @as(f32, @floatFromInt(size_in))
        else
            calculateCutoff(size_in);
        const sinc = try makeSinc(gpa, size_in, cutoff);
        defer gpa.free(sinc);
        const filter_t = try gpa.alloc(f32, 2 * size_in);
        defer gpa.free(filter_t);
        @memset(filter_t, 0);
        const denom: f32 = @floatFromInt(2 * size_in);
        for (0..size_in) |n| filter_t[n] = sinc[n] / denom;
        var fwd = try fft.RealPlan.init(gpa, 2 * size_in);
        errdefer fwd.deinit();
        var inv = try fft.RealPlan.init(gpa, 2 * size_out);
        errdefer inv.deinit();
        const filter_f = try gpa.alloc(Complex, size_in + 1);
        fwd.forward(filter_t, filter_f);
        return .{
            .gpa = gpa,
            .size_in = size_in,
            .size_out = size_out,
            .filter_f = filter_f,
            .fwd = fwd,
            .inv = inv,
            .input_buf = try gpa.alloc(f32, 2 * size_in),
            .input_f = try gpa.alloc(Complex, size_in + 1),
            .output_f = try gpa.alloc(Complex, size_out + 1),
            .output_buf = try gpa.alloc(f32, 2 * size_out),
        };
    }

    fn deinit(self: *FftResampler) void {
        self.fwd.deinit();
        self.inv.deinit();
        self.gpa.free(self.filter_f);
        self.gpa.free(self.input_buf);
        self.gpa.free(self.input_f);
        self.gpa.free(self.output_f);
        self.gpa.free(self.output_buf);
    }

    fn resampleUnit(self: *FftResampler, wave_in: []const f32, wave_out: []f32, overlap: []f32) void {
        @memcpy(self.input_buf[0..self.size_in], wave_in);
        @memset(self.input_buf[self.size_in..], 0);
        self.fwd.forward(self.input_buf, self.input_f);
        const new_len = if (self.size_in < self.size_out) self.size_in + 1 else self.size_out;
        for (self.input_f[0..new_len], self.filter_f[0..new_len]) |*s, f| s.* = s.mul(f);
        @memcpy(self.output_f[0..new_len], self.input_f[0..new_len]);
        @memset(self.output_f[new_len..], .{});
        self.inv.inverse(self.output_f, self.output_buf);
        for (wave_out[0..self.size_out], 0..) |*o, n| o.* = self.output_buf[n] + overlap[n];
        @memcpy(overlap, self.output_buf[self.size_out..]);
    }
};

/// rubato `FftFixedInOut<f32>` for one channel.
pub const FftFixedInOut = struct {
    chunk_in: usize,
    chunk_out: usize,
    overlap: []f32,
    resampler: FftResampler,

    pub fn init(gpa: Allocator, rate_in: usize, rate_out: usize, chunk_size_in: usize) Allocator.Error!FftFixedInOut {
        const gcd = std.math.gcd(rate_in, rate_out);
        const min_chunk_in = rate_in / gcd;
        const fft_chunks: usize = @intFromFloat(@ceil(@as(f32, @floatFromInt(chunk_size_in)) / @as(f32, @floatFromInt(min_chunk_in))));
        const size_out = fft_chunks * rate_out / gcd;
        const size_in = fft_chunks * rate_in / gcd;
        var resampler = try FftResampler.init(gpa, size_in, size_out);
        errdefer resampler.deinit();
        const overlap = try gpa.alloc(f32, size_out);
        @memset(overlap, 0);
        return .{ .chunk_in = size_in, .chunk_out = size_out, .overlap = overlap, .resampler = resampler };
    }

    pub fn deinit(self: *FftFixedInOut) void {
        self.resampler.gpa.free(self.overlap);
        self.resampler.deinit();
    }

    pub fn outputDelay(self: *const FftFixedInOut) usize {
        return self.chunk_out / 2;
    }

    /// `input` is exactly `chunk_in` frames; writes `chunk_out` frames.
    pub fn process(self: *FftFixedInOut, input: []const f32, output: []f32) void {
        self.resampler.resampleUnit(input[0..self.chunk_in], output[0..self.chunk_out], self.overlap);
    }
};

/// zeron `resample::for_model`: device rate → 16 kHz. Takes ownership of
/// `samples` (returned unchanged at 16 kHz or when empty).
pub fn forModel(gpa: Allocator, samples: []f32, rate: u32) Error![]f32 {
    if (rate < 8_000 or rate > 192_000) return error.UnsupportedSampleRate;
    return convert(gpa, samples, rate, model_rate);
}

/// `for_model`'s loop for any target rate (the parity oracle uses it to
/// upsample the fixture). Takes ownership of `samples` on success; on
/// error the caller still owns them.
pub fn convert(gpa: Allocator, samples: []f32, rate: u32, to: u32) Allocator.Error![]f32 {
    if (rate == to or samples.len == 0) return samples;
    const length: usize = @intCast(@as(u64, samples.len) * to / rate);
    var r = try FftFixedInOut.init(gpa, rate, to, 1024);
    defer r.deinit();
    const delay = r.outputDelay();
    const chunk = r.chunk_in;
    const input = try gpa.alloc(f32, chunk);
    defer gpa.free(input);
    const output = try gpa.alloc(f32, r.chunk_out);
    defer gpa.free(output);
    var converted: std.ArrayList(f32) = .empty;
    errdefer converted.deinit(gpa);
    try converted.ensureTotalCapacity(gpa, length + delay + r.chunk_out);
    var offset: usize = 0;
    // Zero padding also flushes the filter tail. Remove its delay so short
    // utterances keep both their beginning and end and retain their duration.
    while (converted.items.len < length + delay) {
        @memset(input, 0);
        const end = @min(offset + chunk, samples.len);
        if (offset < end) @memcpy(input[0 .. end - offset], samples[offset..end]);
        r.process(input, output);
        try converted.appendSlice(gpa, output);
        offset = end;
    }
    const out = try gpa.alloc(f32, length);
    @memcpy(out, converted.items[delay..][0..length]);
    converted.deinit(gpa);
    gpa.free(samples);
    return out;
}

fn tone(gpa: Allocator, rate: u32, hz: f32) ![]f32 {
    const v = try gpa.alloc(f32, rate);
    for (v, 0..) |*s, i| s.* = @sin(std.math.tau * hz * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rate)));
    return v;
}

fn rms(s: []const f32) f32 {
    var acc: f32 = 0;
    for (s) |x| acc += x * x;
    return @sqrt(acc / @as(f32, @floatFromInt(s.len)));
}

test "device rates preserve duration and speech band (resample.rs)" {
    const gpa = std.testing.allocator;
    for ([_]u32{ 8_000, 16_000, 24_000, 44_100, 48_000, 96_000 }) |rate| {
        const converted = try forModel(gpa, try tone(gpa, rate, 1_000), rate);
        defer gpa.free(converted);
        try std.testing.expectEqual(@as(usize, model_rate), converted.len);
        const steady = converted[1000..15000];
        var cycles: usize = 0;
        for (steady[0 .. steady.len - 1], steady[1..]) |a, b| {
            if (a <= 0 and b > 0) cycles += 1;
        }
        try std.testing.expect(cycles >= 874 and cycles <= 876);
        try std.testing.expect(@abs(rms(steady) - std.math.sqrt1_2) < 0.01);
    }
}

test "downsampling filters frequencies above model nyquist" {
    const gpa = std.testing.allocator;
    const converted = try forModel(gpa, try tone(gpa, 48_000, 12_000), 48_000);
    defer gpa.free(converted);
    try std.testing.expect(rms(converted[1000..15000]) < 0.01);
}

test "short capture and invalid rates are bounded" {
    const gpa = std.testing.allocator;
    const short = try gpa.alloc(f32, 147);
    @memset(short, 0);
    const out = try forModel(gpa, short, 44_100);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 53), out.len);
    const empty = try forModel(gpa, &.{}, 48_000);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    const one = try gpa.alloc(f32, 1);
    defer gpa.free(one);
    try std.testing.expectError(error.UnsupportedSampleRate, forModel(gpa, one, 0));
}
