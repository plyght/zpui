//! Deterministic tests for the audio engine through the null backend
//! (`renderOffline`) and the device control loop with a fake backend.

const std = @import("std");
const audio = @import("audio.zig");
const mixer = @import("mixer.zig");
const engine = @import("engine.zig");
const sys = @import("sys.zig");
const testing = std.testing;
const Audio = audio.Audio;

fn openNull(rate: u32) !*Audio {
    const a = try Audio.init(testing.allocator, .{ .sample_rate = rate, .backend = .null });
    try testing.expectEqual(audio.BackendKind.null, a.status().backend);
    return a;
}

/// A sound of `n` frames all equal to `v`.
fn constSound(a: *Audio, v: i16, n: usize, rate: u32) !audio.SoundId {
    const buf = try testing.allocator.alloc(i16, n);
    defer testing.allocator.free(buf);
    @memset(buf, v);
    return a.loadPcm(buf, rate);
}

fn render(a: *Audio, comptime frames: usize) [frames * 2]f32 {
    var out: [frames * 2]f32 = undefined;
    a.renderOffline(&out);
    return out;
}

test "silence with no voices" {
    const a = try openNull(48000);
    defer a.deinit();
    const out = render(a, 256);
    for (out) |x| try testing.expectEqual(@as(f32, 0), x);
    try testing.expect(a.status().running);
}

test "single voice at unity, centered" {
    const a = try openNull(48000);
    defer a.deinit();
    const id = try constSound(a, 8192, 100, 48000); // 0.25
    a.play(id, .{});
    const out = render(a, 128);
    for (0..100) |i| {
        try testing.expectApproxEqAbs(@as(f32, 0.25), out[2 * i], 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 0.25), out[2 * i + 1], 1e-6);
    }
    for (100..128) |i| try testing.expectEqual(@as(f32, 0), out[2 * i]);
    try testing.expectEqual(@as(u64, 1), a.stats().voices_started);
}

test "voices sum" {
    const a = try openNull(48000);
    defer a.deinit();
    const x = try constSound(a, 4096, 64, 48000); // 0.125
    const y = try constSound(a, 8192, 32, 48000); // 0.25
    a.play(x, .{});
    a.play(y, .{});
    const out = render(a, 64);
    try testing.expectApproxEqAbs(@as(f32, 0.375), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.375), out[2 * 31], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.125), out[2 * 32], 1e-6);
}

test "gain and equal-power pan" {
    const a = try openNull(48000);
    defer a.deinit();
    const id = try constSound(a, 8192, 16, 48000);
    a.play(id, .{ .gain = 0.5, .pan = -1 });
    var out = render(a, 16);
    try testing.expectApproxEqAbs(@as(f32, 0.25 * 0.5 * std.math.sqrt2), out[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), out[1], 1e-6);
    a.play(id, .{ .pan = 1 });
    out = render(a, 16);
    try testing.expectApproxEqAbs(@as(f32, 0), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.25 * std.math.sqrt2), out[1], 1e-5);
    // Equal power: L² + R² is constant across the pan range.
    var p: f32 = -1;
    while (p <= 1) : (p += 0.25) {
        const g = mixer.panGains(1, p);
        try testing.expectApproxEqAbs(@as(f32, 2), g[0] * g[0] + g[1] * g[1], 1e-5);
    }
}

test "stereo sound balance" {
    const a = try openNull(48000);
    defer a.deinit();
    var pcm: [16]f32 = undefined;
    for (0..8) |k| {
        pcm[2 * k] = 0.5;
        pcm[2 * k + 1] = -0.25;
    }
    const id = try a.loadPcmF32(&pcm, 2, 48000);
    a.play(id, .{ .pan = 0.5 });
    const out = render(a, 8);
    try testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -0.25), out[1], 1e-6);
}

test "voice stealing takes the oldest" {
    const a = try openNull(48000);
    defer a.deinit();
    // Voice k is a constant (k + 1) / 1024 so the survivors are identifiable.
    var ids: [audio.max_voices + 1]audio.SoundId = undefined;
    for (&ids, 0..) |*id, k| id.* = try constSound(a, @intCast((k + 1) * 32), 4800, 48000);
    for (ids) |id| a.play(id, .{});
    const out = render(a, 4);
    var expect: f32 = 0;
    for (1..ids.len) |k| expect += @as(f32, @floatFromInt((k + 1) * 32)) / 32768.0;
    try testing.expectApproxEqAbs(expect, out[0], 1e-5);
    const s = a.stats();
    try testing.expectEqual(@as(u64, 1), s.voices_stolen);
    try testing.expectEqual(@as(u64, audio.max_voices + 1), s.voices_started);
}

test "limiter is transparent below the knee and bounded above" {
    try testing.expectEqual(@as(f32, 0.5), mixer.softLimit(0.5));
    try testing.expectEqual(@as(f32, -0.8), mixer.softLimit(-0.8));
    var x: f32 = 0.81;
    var prev: f32 = 0.8;
    while (x < 50) : (x *= 1.3) {
        const y = mixer.softLimit(x);
        try testing.expect(y < 1.0 and y > prev); // monotonic, never clips
        try testing.expectEqual(-y, mixer.softLimit(-x));
        prev = y;
    }
    const a = try openNull(48000);
    defer a.deinit();
    const id = try constSound(a, 30000, 64, 48000);
    for (0..8) |_| a.play(id, .{ .gain = 2 });
    const out = render(a, 64);
    for (out) |s| try testing.expect(@abs(s) < 1.0 and @abs(s) > 0.95);
}

test "linear resampling: rate conversion and pitch" {
    const a = try openNull(48000);
    defer a.deinit();
    // A ramp at 24 kHz plays at half speed on a 48 kHz device: twice as
    // long, with interpolated midpoints.
    var ramp: [100]i16 = undefined;
    for (&ramp, 0..) |*s, i| s.* = @intCast(i * 100);
    const id = try a.loadPcm(&ramp, 24000);
    a.play(id, .{});
    var out = render(a, 256);
    try testing.expectApproxEqAbs(@as(f32, 100.0 / 32768.0), out[2 * 2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 150.0 / 32768.0), out[2 * 3], 1e-6);
    try testing.expect(out[2 * 199] != 0);
    try testing.expectEqual(@as(f32, 0), out[2 * 200]);

    // pitch 2 at the native rate: every other sample, half the length.
    const id48 = try a.loadPcm(&ramp, 48000);
    a.play(id48, .{ .pitch = 2 });
    out = render(a, 256);
    try testing.expectApproxEqAbs(@as(f32, 400.0 / 32768.0), out[2 * 2], 1e-6);
    try testing.expect(out[2 * 49] != 0);
    try testing.expectEqual(@as(f32, 0), out[2 * 50]);

    // pitch 1.5: fractional positions interpolate between neighbours.
    a.play(id48, .{ .pitch = 1.5 });
    out = render(a, 256);
    try testing.expectApproxEqAbs(@as(f32, 150.0 / 32768.0), out[2 * 1], 1e-6);
}

test "master volume ramps and applies" {
    const a = try openNull(48000);
    defer a.deinit();
    const id = try constSound(a, 8192, 4096, 48000);
    a.setMasterVolume(0.5);
    try testing.expectEqual(@as(f32, 0.5), a.masterVolume());
    a.play(id, .{});
    var out = render(a, 512);
    // First block ramps 1.0 → 0.5, then holds.
    try testing.expect(out[0] > 0.24);
    try testing.expectApproxEqAbs(@as(f32, 0.125), out[2 * 511], 1e-4);
    out = render(a, 512);
    try testing.expectApproxEqAbs(@as(f32, 0.125), out[0], 1e-6);
    a.setMasterVolume(0);
    _ = render(a, 512);
    out = render(a, 512);
    for (out) |s| try testing.expectEqual(@as(f32, 0), s);
}

test "command queue: order, overflow and stopAll" {
    var ring: mixer.Ring(u32, 4) = .{};
    try testing.expect(ring.pop() == null);
    for (0..4) |i| try testing.expect(ring.push(@intCast(i)));
    try testing.expect(!ring.push(99));
    try testing.expectEqual(@as(usize, 4), ring.len());
    for (0..4) |i| try testing.expectEqual(@as(u32, @intCast(i)), ring.pop().?);
    try testing.expect(ring.pop() == null);
    // Wrap-around.
    for (0..10) |i| {
        try testing.expect(ring.push(@intCast(i)));
        try testing.expectEqual(@as(u32, @intCast(i)), ring.pop().?);
    }

    const a = try openNull(48000);
    defer a.deinit();
    const id = try constSound(a, 8192, 4800, 48000);
    for (0..mixer.queue_capacity + 10) |_| a.play(id, .{});
    try testing.expectEqual(@as(u64, 10), a.stats().dropped);
    _ = render(a, 16);
    try testing.expectEqual(@as(u64, mixer.queue_capacity), a.stats().voices_started);
    a.stopAll();
    const out = render(a, 16);
    for (out) |s| try testing.expectEqual(@as(f32, 0), s);
}

test "SPSC ring across threads" {
    const R = mixer.Ring(u64, 64);
    var ring: R = .{};
    const n = 200_000;
    const Producer = struct {
        fn run(r: *R) void {
            var i: u64 = 0;
            while (i < n) {
                if (r.push(i)) i += 1 else std.atomic.spinLoopHint();
            }
        }
    };
    const t = try std.Thread.spawn(.{}, Producer.run, .{&ring});
    var expect: u64 = 0;
    while (expect < n) {
        if (ring.pop()) |v| {
            try testing.expectEqual(expect, v);
            expect += 1;
        } else std.atomic.spinLoopHint();
    }
    t.join();
}

test "i16 output and channel layouts" {
    var m = mixer.Mixer.init(48000);
    const snd_data = [_]f32{ 0.5, 0.5, 0.5, 0.5, 0 };
    const snd: mixer.Sound = .{ .samples = &snd_data, .frames = 4, .channels = 1, .rate = 48000 };
    _ = m.ring.push(.{ .kind = .play, .sound = &snd });
    var out6: [4 * 6]i16 = undefined;
    m.render(i16, &out6, 4, 6);
    try testing.expectEqual(@as(i16, 16384), out6[0]);
    try testing.expectEqual(@as(i16, 16384), out6[1]);
    for (out6[2..6]) |s| try testing.expectEqual(@as(i16, 0), s);
    _ = m.ring.push(.{ .kind = .play, .sound = &snd, .gain_l = 1, .gain_r = 0 });
    var mono: [4]f32 = undefined;
    m.render(f32, &mono, 4, 1);
    try testing.expectApproxEqAbs(@as(f32, 0.25), mono[0], 1e-6);
}

test "wav loading" {
    const a = try openNull(48000);
    defer a.deinit();
    const pcm = [_]f32{ 0.5, -0.5, 0.25, -0.25 };
    const bytes = try audio.wav.encode16(testing.allocator, &pcm, 1, 48000);
    defer testing.allocator.free(bytes);
    const id = try a.loadWav(bytes);
    a.play(id, .{});
    const out = render(a, 4);
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -0.25), out[6], 1e-4);
    try testing.expectError(error.InvalidWav, a.loadWav("not a wav file"));
}

test "synthesized click is short, non-silent and bounded" {
    const click = try audio.synthesizeClick(testing.allocator, 48000, 1);
    defer testing.allocator.free(click);
    try testing.expect(click.len > 1000 and click.len < 4800);
    var peak: i32 = 0;
    for (click) |s| peak = @max(peak, @as(i32, @abs(s)));
    try testing.expect(peak > 3000 and peak < 32767);
    try testing.expect(@abs(click[click.len - 1]) < 200); // faded out
}

test "backend none: play is a no-op" {
    const a = try Audio.init(testing.allocator, .{ .backend = .none });
    defer a.deinit();
    const st = a.status();
    try testing.expectEqual(audio.BackendKind.none, st.backend);
    try testing.expect(st.reason.len > 0);
    const id = try constSound(a, 1000, 10, 48000);
    a.play(id, .{});
    try testing.expectEqual(@as(u64, 0), a.stats().dropped);
}

/// A device that "plays" by rendering on a thread of its own while
/// started, at a fast fake clock (1 ms per 480-frame period).
const FakeDevice = struct {
    e: *engine.Engine,
    running: std.atomic.Value(bool) = .init(false),
    quit: std.atomic.Value(bool) = .init(false),
    starts: std.atomic.Value(u32) = .init(0),
    stops: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    pub fn start(self: *FakeDevice) bool {
        _ = self.starts.fetchAdd(1, .monotonic);
        self.running.store(true, .release);
        return true;
    }
    pub fn stop(self: *FakeDevice) void {
        _ = self.stops.fetchAdd(1, .monotonic);
        self.running.store(false, .release);
    }
    pub fn deviceChanged(_: *FakeDevice, _: bool) void {}

    fn pump(self: *FakeDevice) void {
        var buf: [480 * 2]f32 = undefined;
        while (!self.quit.load(.acquire)) {
            if (self.running.load(.acquire)) self.e.render(f32, &buf, 480, 2);
            sys.sleepNs(std.time.ns_per_ms);
        }
    }
};

fn waitFor(cond: anytype, ctx: anytype, timeout_ms: u64) bool {
    const deadline = sys.nowNs() + timeout_ms * std.time.ns_per_ms;
    while (sys.nowNs() < deadline) {
        if (cond(ctx)) return true;
        sys.sleepNs(std.time.ns_per_ms);
    }
    return cond(ctx);
}

test "auto-suspend after keep-alive, resume on play" {
    var e: engine.Engine = undefined;
    // 50 ms keep-alive = 2400 frames = 5 fake periods.
    try e.init(48000, 50 * std.time.ns_per_ms);
    defer e.deinit();
    var dev: FakeDevice = .{ .e = &e };
    dev.thread = try std.Thread.spawn(.{}, FakeDevice.pump, .{&dev});
    const ctl = try std.Thread.spawn(.{}, engine.controlLoop, .{ FakeDevice, &dev, &e });

    var data: [961]f32 = @splat(0.1);
    data[960] = 0;
    const snd: mixer.Sound = .{ .samples = &data, .frames = 960, .channels = 1, .rate = 48000 };
    const Cond = struct {
        fn started(d: *FakeDevice) bool {
            return d.starts.load(.monotonic) >= 1;
        }
        fn stopped(d: *FakeDevice) bool {
            return d.stops.load(.monotonic) >= 1;
        }
        fn restarted(d: *FakeDevice) bool {
            return d.starts.load(.monotonic) >= 2;
        }
        fn stopped2(d: *FakeDevice) bool {
            return d.stops.load(.monotonic) >= 2;
        }
    };

    try testing.expectEqual(engine.State.suspended, e.state.load(.seq_cst));
    _ = e.mixer.ring.push(.{ .kind = .play, .sound = &snd });
    e.notifyPlay();
    try testing.expect(waitFor(Cond.started, &dev, 2000));
    try testing.expect(waitFor(Cond.stopped, &dev, 3000));
    try testing.expectEqual(engine.State.suspended, e.state.load(.seq_cst));
    try testing.expectEqual(@as(u64, 1), e.mixer.played.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), e.stats.resumes.load(.monotonic));

    _ = e.mixer.ring.push(.{ .kind = .play, .sound = &snd });
    e.notifyPlay();
    try testing.expect(waitFor(Cond.restarted, &dev, 2000));
    try testing.expect(waitFor(Cond.stopped2, &dev, 3000));

    e.quit.store(true, .release);
    e.poke();
    ctl.join();
    dev.quit.store(true, .release);
    dev.thread.?.join();
    try testing.expect(e.mixer.played.load(.monotonic) == 2);
}
