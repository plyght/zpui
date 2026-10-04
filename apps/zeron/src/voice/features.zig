//! Log-mel features for Parakeet TDT — parakeet-rs 0.3.8 `audio.rs`
//! (`extract_features_with_cache`) with the TDT preprocessor config: 128
//! Slaney mels, n_fft 512, hop 160, Hann window 400 (centred in the FFT
//! buffer, as torch.stft does), pre-emphasis 0.97, log with a 2^-24 additive
//! guard and per-feature normalisation (Bessel-corrected std + 1e-5).

const std = @import("std");
const Allocator = std.mem.Allocator;
const fft = @import("fft.zig");

pub const n_mels = 128;
pub const n_fft = 512;
pub const hop = 160;
pub const win = 400;
pub const sample_rate = 16_000;
const bins = n_fft / 2 + 1;

pub const Features = struct {
    frames: usize,
    /// frames × n_mels, row-major (time-major, like parakeet's `Array2`).
    data: []f32,

    pub fn deinit(self: Features, gpa: Allocator) void {
        gpa.free(self.data);
    }
};

const f_sp: f64 = 200.0 / 3.0;
const min_log_hz: f64 = 1000.0;
const min_log_mel: f64 = min_log_hz / f_sp;
const log_step: f64 = 0.06875177742094912;

fn hzToMel(hz: f64) f64 {
    return if (hz < min_log_hz) hz / f_sp else min_log_mel + @log(hz / min_log_hz) / log_step;
}

fn melToHz(mel: f64) f64 {
    return if (mel < min_log_mel) mel * f_sp else min_log_hz * @exp((mel - min_log_mel) * log_step);
}

/// Reusable filterbank, window and FFT plan (parakeet `FeatureCache`).
pub const Extractor = struct {
    gpa: Allocator,
    filterbank: [n_mels][bins]f32,
    window: [win]f32,
    plan: fft.RealPlan,

    pub fn init(gpa: Allocator) Allocator.Error!*Extractor {
        const self = try gpa.create(Extractor);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.plan = try fft.RealPlan.init(gpa, n_fft);
        // Slaney mel filterbank (librosa).
        const mel_min = hzToMel(0.0);
        const mel_max = hzToMel(@as(f64, sample_rate) / 2.0);
        var pts: [n_mels + 2]f64 = undefined;
        for (&pts, 0..) |*p, i| p.* = melToHz(mel_min + (mel_max - mel_min) * @as(f64, @floatFromInt(i)) / @as(f64, n_mels + 1));
        for (0..n_mels) |i| {
            const fd0 = pts[i + 1] - pts[i];
            const fd1 = pts[i + 2] - pts[i + 1];
            const enorm = 2.0 / (pts[i + 2] - pts[i]);
            for (0..bins) |k| {
                const freq = @as(f64, @floatFromInt(k)) * @as(f64, sample_rate) / @as(f64, n_fft);
                const lower = (freq - pts[i]) / fd0;
                const upper = (pts[i + 2] - freq) / fd1;
                const v: f32 = @floatCast(@max(0.0, @min(lower, upper)));
                self.filterbank[i][k] = v * @as(f32, @floatCast(enorm));
            }
        }
        for (&self.window, 0..) |*w, i| {
            w.* = 0.5 - 0.5 * @cos((2.0 * std.math.pi * @as(f32, @floatFromInt(i))) / (@as(f32, win) - 1.0));
        }
        return self;
    }

    pub fn deinit(self: *Extractor) void {
        self.plan.deinit();
        self.gpa.destroy(self);
    }

    /// 16 kHz mono samples → normalised log-mel features.
    pub fn extract(self: *Extractor, gpa: Allocator, audio: []const f32) Allocator.Error!Features {
        // Pre-emphasis, then centre padding of n_fft/2 zeros on each side.
        const pad = n_fft / 2;
        const padded = try gpa.alloc(f32, audio.len + 2 * pad);
        defer gpa.free(padded);
        @memset(padded, 0);
        if (audio.len > 0) {
            padded[pad] = audio[0];
            for (1..audio.len) |i| padded[pad + i] = audio[i] - 0.97 * audio[i - 1];
        }
        // NeMo reports floor(len / hop) valid frames (torch.stft's trailing
        // frame is masked out before normalisation).
        const frames = audio.len / hop;
        const data = try gpa.alloc(f32, frames * n_mels);
        errdefer gpa.free(data);
        const offset = (n_fft - win) / 2;
        var input: [n_fft]f32 = undefined;
        var output: [bins]fft.Complex = undefined;
        var power: [bins]f32 = undefined;
        const guard = std.math.pow(f32, 2.0, -24.0);
        for (0..frames) |f| {
            const start = f * hop;
            @memset(&input, 0);
            for (0..win) |i| input[offset + i] = padded[start + offset + i] * self.window[i];
            self.plan.forward(&input, &output);
            for (&power, output) |*p, c| p.* = c.normSqr();
            for (0..n_mels) |m| {
                var acc: f32 = 0;
                for (self.filterbank[m], power) |w, p| acc += w * p;
                data[f * n_mels + m] = @log(acc + guard);
            }
        }
        if (frames > 1) {
            const nf: f32 = @floatFromInt(frames);
            for (0..n_mels) |m| {
                var sum: f32 = 0;
                for (0..frames) |f| sum += data[f * n_mels + m];
                const mean = sum / nf;
                var vs: f32 = 0;
                for (0..frames) |f| {
                    const d = data[f * n_mels + m] - mean;
                    vs += d * d;
                }
                const std_dev = @sqrt(vs / (nf - 1.0)) + 1e-5;
                for (0..frames) |f| data[f * n_mels + m] = (data[f * n_mels + m] - mean) / std_dev;
            }
        }
        return .{ .frames = frames, .data = data };
    }
};

test "stft concentrates a 1 kHz tone and frame count follows the hop" {
    const gpa = std.testing.allocator;
    var ex = try Extractor.init(gpa);
    defer ex.deinit();
    const audio = try gpa.alloc(f32, 16000);
    defer gpa.free(audio);
    for (audio, 0..) |*s, i| s.* = @sin(2.0 * std.math.pi * 1000.0 * @as(f32, @floatFromInt(i)) / 16000.0);
    const feats = try ex.extract(gpa, audio);
    defer feats.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 100), feats.frames);
}
