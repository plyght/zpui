//! Real-time voice mixer: a lock-free single-producer/single-consumer
//! command ring feeding a fixed pool of voices, mixed in f32 with linear
//! resampling, equal-power panning, a smoothed master gain and a
//! stateless soft-knee limiter. `render` never allocates, locks or makes a
//! system call, and with no voices playing it only zero-fills the output.

const std = @import("std");

pub const max_voices = 32;
/// Mixing block (frames); larger device buffers are rendered in chunks.
pub const block_frames = 512;
pub const queue_capacity = 256;

/// Limiter: linear up to `knee`, then a smooth curve approaching ±1.0
/// (slope 1 at the knee, so quiet material is bit-exact).
pub const limiter_knee: f32 = 0.8;

/// PCM owned by `Audio`, immutable after load. Each channel's data is
/// followed by one zero guard frame so interpolation never branches.
pub const Sound = struct {
    /// Interleaved samples, `(frames + 1) * channels` long.
    samples: []const f32,
    frames: u32,
    channels: u8,
    rate: u32,
};

pub const Command = struct {
    kind: Kind,
    sound: ?*const Sound = null,
    gain_l: f32 = 1,
    gain_r: f32 = 1,
    pitch: f32 = 1,

    pub const Kind = enum(u8) { play, stop_all };
};

/// Bounded lock-free SPSC ring. `push` from the (single, serialized)
/// producer; `pop` from the audio thread. Head and tail live on separate
/// cache lines.
pub fn Ring(comptime T: type, comptime capacity: usize) type {
    std.debug.assert(std.math.isPowerOfTwo(capacity));
    return struct {
        const Self = @This();
        head: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0), // consumer
        tail: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0), // producer
        items: [capacity]T = undefined,

        pub fn push(self: *Self, item: T) bool {
            const tail = self.tail.load(.monotonic);
            if (tail -% self.head.load(.acquire) >= capacity) return false;
            self.items[tail & (capacity - 1)] = item;
            // seq_cst so the suspend handshake (store tail, then load state)
            // is totally ordered against the consumer's (store state, load tail).
            self.tail.store(tail +% 1, .seq_cst);
            return true;
        }

        pub fn pop(self: *Self) ?T {
            const head = self.head.load(.monotonic);
            if (head == self.tail.load(.acquire)) return null;
            const item = self.items[head & (capacity - 1)];
            self.head.store(head +% 1, .release);
            return item;
        }

        pub fn len(self: *const Self) usize {
            return self.tail.load(.seq_cst) -% self.head.load(.seq_cst);
        }
    };
}

pub const CommandRing = Ring(Command, queue_capacity);

const Voice = struct {
    sound: ?*const Sound = null,
    /// 32.32 fixed-point read position in source frames.
    pos: u64 = 0,
    step: u64 = 0,
    /// sound.rate * pitch; the step is derived from it and the output rate.
    src_rate: f32 = 0,
    gain_l: f32 = 0,
    gain_r: f32 = 0,
    serial: u64 = 0,
};

pub const Mixer = struct {
    rate: u32,
    ring: CommandRing = .{},
    voices: [max_voices]Voice = @splat(.{}),
    active: u32 = 0,
    serial: u64 = 0,
    acc: [block_frames * 2]f32 = undefined,
    /// Master gain as f32 bits (written by any thread, read by the renderer).
    master_target: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 1.0))),
    master: f32 = 1.0,

    // Read by other threads (relaxed).
    active_voices: std.atomic.Value(u32) = .init(0),
    /// Frames rendered since the last voice finished (0 while playing).
    idle_frames: std.atomic.Value(u64) = .init(0),
    steals: std.atomic.Value(u64) = .init(0),
    played: std.atomic.Value(u64) = .init(0),

    pub fn init(rate: u32) Mixer {
        return .{ .rate = rate };
    }

    /// Changes the output rate. Only call while no render is in progress
    /// (from the render thread itself, or while the device is stopped).
    pub fn setRate(self: *Mixer, rate: u32) void {
        if (rate == 0 or rate == self.rate) return;
        self.rate = rate;
        for (&self.voices) |*v| if (v.sound != null) {
            v.step = stepFor(v.src_rate, rate);
        };
    }

    pub fn setMasterVolume(self: *Mixer, v: f32) void {
        self.master_target.store(@bitCast(std.math.clamp(v, 0, 4)), .release);
    }

    pub fn masterVolume(self: *const Mixer) f32 {
        return @bitCast(self.master_target.load(.acquire));
    }

    /// True when nothing is playing and nothing is queued.
    pub fn isIdle(self: *const Mixer) bool {
        return self.active_voices.load(.monotonic) == 0 and self.ring.len() == 0;
    }

    fn stepFor(src_rate: f32, out_rate: u32) u64 {
        const s: f64 = @as(f64, src_rate) / @as(f64, @floatFromInt(out_rate));
        return @intFromFloat(@max(s, 1.0 / 65536.0) * 4294967296.0);
    }

    fn apply(self: *Mixer, cmd: Command) void {
        switch (cmd.kind) {
            .stop_all => {
                for (&self.voices) |*v| v.sound = null;
                self.active = 0;
            },
            .play => {
                const sound = cmd.sound orelse return;
                if (sound.frames == 0) return;
                var slot: ?*Voice = null;
                var oldest: *Voice = &self.voices[0];
                for (&self.voices) |*v| {
                    if (v.sound == null) {
                        slot = v;
                        break;
                    }
                    if (v.serial < oldest.serial) oldest = v;
                }
                const v = slot orelse blk: {
                    _ = self.steals.fetchAdd(1, .monotonic);
                    self.active -= 1;
                    break :blk oldest;
                };
                self.serial += 1;
                const src_rate = @as(f32, @floatFromInt(sound.rate)) * std.math.clamp(cmd.pitch, 0.25, 4.0);
                v.* = .{
                    .sound = sound,
                    .pos = 0,
                    .src_rate = src_rate,
                    .step = stepFor(src_rate, self.rate),
                    .gain_l = cmd.gain_l,
                    .gain_r = cmd.gain_r,
                    .serial = self.serial,
                };
                self.active += 1;
                _ = self.played.fetchAdd(1, .monotonic);
            },
        }
    }

    /// Renders `frames` interleaved frames of `channels` channels into
    /// `out` (L/R in the first two channels, the rest silent; a mono
    /// device gets the downmix). `T` is f32 or i16.
    pub fn render(self: *Mixer, comptime T: type, out: []T, frames: usize, channels: usize) void {
        std.debug.assert(out.len >= frames * channels);
        if (self.ring.len() != 0) {
            // Reset the idle clock before the commands leave the ring, so a
            // watcher that sees the ring empty also sees idle_frames == 0.
            self.idle_frames.store(0, .seq_cst);
            while (self.ring.pop()) |cmd| self.apply(cmd);
        }

        const target: f32 = @bitCast(self.master_target.load(.acquire));
        if (self.active == 0) {
            @memset(out[0 .. frames * channels], 0);
            self.master = target;
            self.active_voices.store(0, .monotonic);
            _ = self.idle_frames.fetchAdd(frames, .monotonic);
            return;
        }

        var done: usize = 0;
        while (done < frames) {
            const n = @min(block_frames, frames - done);
            self.mixBlock(n);
            self.writeBlock(T, out[done * channels ..], n, channels, target);
            done += n;
        }
        self.active_voices.store(self.active, .monotonic);
        self.idle_frames.store(0, .monotonic);
    }

    fn mixBlock(self: *Mixer, n: usize) void {
        const acc = self.acc[0 .. n * 2];
        @memset(acc, 0);
        for (&self.voices) |*v| {
            const sound = v.sound orelse continue;
            const end: u64 = @as(u64, sound.frames) << 32;
            // Frames left before the voice runs out (ceil((end - pos) / step)).
            const left: u64 = (end - v.pos + v.step - 1) / v.step;
            const run: usize = @intCast(@min(left, n));
            var pos = v.pos;
            const step = v.step;
            const gl = v.gain_l;
            const gr = v.gain_r;
            const s = sound.samples.ptr;
            if (sound.channels == 1) {
                for (0..run) |i| {
                    const idx: usize = @intCast(pos >> 32);
                    const frac = @as(f32, @floatFromInt(pos & 0xffff_ffff)) * (1.0 / 4294967296.0);
                    const a = s[idx];
                    const x = a + (s[idx + 1] - a) * frac;
                    acc[2 * i] += x * gl;
                    acc[2 * i + 1] += x * gr;
                    pos += step;
                }
            } else {
                for (0..run) |i| {
                    const idx: usize = @intCast(pos >> 32);
                    const frac = @as(f32, @floatFromInt(pos & 0xffff_ffff)) * (1.0 / 4294967296.0);
                    const al = s[2 * idx];
                    const ar = s[2 * idx + 1];
                    acc[2 * i] += (al + (s[2 * idx + 2] - al) * frac) * gl;
                    acc[2 * i + 1] += (ar + (s[2 * idx + 3] - ar) * frac) * gr;
                    pos += step;
                }
            }
            v.pos = pos;
            if (run < n or pos >= end) {
                v.sound = null;
                self.active -= 1;
            }
        }
    }

    fn writeBlock(self: *Mixer, comptime T: type, out: []T, n: usize, channels: usize, target: f32) void {
        var g = self.master;
        const dg = (target - g) / @as(f32, @floatFromInt(n));
        for (0..n) |i| {
            g += dg;
            const l = softLimit(self.acc[2 * i] * g);
            const r = softLimit(self.acc[2 * i + 1] * g);
            const o = out[i * channels ..][0..channels];
            if (channels == 1) {
                o[0] = convert(T, softLimit((self.acc[2 * i] + self.acc[2 * i + 1]) * 0.5 * g));
            } else {
                o[0] = convert(T, l);
                o[1] = convert(T, r);
                for (o[2..]) |*x| x.* = 0;
            }
        }
        self.master = target;
    }
};

inline fn convert(comptime T: type, x: f32) T {
    return switch (T) {
        f32 => x,
        i16 => @intFromFloat(@round(x * 32767.0)),
        else => @compileError("unsupported sample type"),
    };
}

/// Soft-knee limiter: identity below `limiter_knee`, then
/// knee + (1 - knee) * t / (1 + t) with t = (|x| - knee) / (1 - knee),
/// which is continuous in value and slope and never reaches 1.0.
pub inline fn softLimit(x: f32) f32 {
    const a = @abs(x);
    if (a <= limiter_knee) return x;
    const t = (a - limiter_knee) / (1 - limiter_knee);
    const y = limiter_knee + (1 - limiter_knee) * t / (1 + t);
    return if (x < 0) -y else y;
}

/// Equal-power pan gains for a mono source: center is unity on both
/// channels (no −3 dB dip), hard left/right is +3 dB on one side.
pub fn panGains(gain: f32, pan: f32) [2]f32 {
    const p = std.math.clamp(pan, -1, 1);
    const theta = (p + 1) * (std.math.pi / 4.0);
    return .{ gain * @cos(theta) * std.math.sqrt2, gain * @sin(theta) * std.math.sqrt2 };
}

/// Balance for a stereo source: attenuates the opposite side only.
pub fn balanceGains(gain: f32, pan: f32) [2]f32 {
    const p = std.math.clamp(pan, -1, 1);
    return .{ gain * @min(1, 1 - p), gain * @min(1, 1 + p) };
}
