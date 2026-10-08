//! zpui.audio — small, low-latency sound-effect playback (UI clicks,
//! keyboard sounds, notification chimes). No third-party libraries:
//! CoreAudio AUHAL on macOS, WASAPI on Windows, PipeWire → PulseAudio →
//! ALSA on Linux (all loaded at run time), plus a null backend that is
//! rendered by hand for tests and offline bouncing.
//!
//!     const audio = try zpui.audio.Audio.init(gpa, .{ .sample_rate = 48000 });
//!     defer audio.deinit();
//!     const click = try audio.loadWav(@embedFile("click.wav"));
//!     audio.play(click, .{ .gain = 0.8, .pan = -0.2, .pitch = 1.03 });
//!
//! `play` is wait-free for the audio thread: it pushes a command into a
//! lock-free SPSC ring (callers on several threads serialize on a tiny
//! producer-only spin lock) and never blocks on the device. Mixing runs
//! on the device's callback with no allocation, locks or syscalls.
//!
//! Idle cost: after `keep_alive_ms` (default 2 s) with no voice playing the
//! output stream is stopped (objects stay open and configured), so an idle
//! app has no audio-thread wakeups and lets the audio hardware sleep. The
//! next `play` restarts it; `stats().last_resume_ns` reports how long that
//! took (play → first callback). The 2 s default sits below the session
//! managers' own sink-suspend timeouts (PipeWire/PulseAudio ~5 s), so typing
//! bursts with short pauses never close the hardware.
//!
//! Output paths (default period / measured restart, see each backend):
//!   macOS    DefaultOutput AudioUnit, f32 at the device rate, 256-frame IO buffer
//!   Windows  WASAPI shared, event-driven, IAudioClient3 minimum engine period
//!            when available (else 10 ms), buffer kept at 2 periods, MMCSS thread
//!   Linux    PipeWire pw_stream (node.latency 256/48000, RT data thread) →
//!            PulseAudio (tlength 512 frames, minreq 256) → ALSA "default"
//!            (5 ms period × 4); none available → `.none`, play() is a no-op.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const sys = @import("sys.zig");
pub const mixer = @import("mixer.zig");
pub const wav = @import("wav.zig");
pub const engine = @import("engine.zig");
const Engine = engine.Engine;
pub const DeviceInfo = engine.DeviceInfo;

const os = builtin.os.tag;
const log = std.log.scoped(.zpui_audio);

pub const max_sounds = 256;
pub const max_voices = mixer.max_voices;

pub const BackendKind = enum {
    /// No output device could be opened; `play` is a no-op.
    none,
    /// No device: render with `renderOffline` (tests, headless, bouncing).
    null,
    coreaudio,
    wasapi,
    pipewire,
    pulse,
    alsa,
};

pub const Preference = enum { auto, null, none, coreaudio, wasapi, pipewire, pulse, alsa };

pub const Options = struct {
    /// Preferred output rate. CoreAudio and WASAPI use the device's rate
    /// instead (no resampler in the OS path); sounds are resampled on the fly.
    sample_rate: u32 = 48000,
    backend: Preference = .auto,
    /// Stop the output device after this long without an active voice.
    keep_alive_ms: u32 = 2000,
    /// Frames per device period; 0 picks the backend default (CoreAudio,
    /// PipeWire and PulseAudio 256, WASAPI the engine minimum, ALSA 5 ms).
    buffer_frames: u32 = 0,
    /// Stream/application name shown by PulseAudio/PipeWire mixers.
    app_name: [:0]const u8 = "zpui",
};

pub const PlayOptions = struct {
    gain: f32 = 1.0,
    /// -1 (left) … 1 (right). Equal-power for mono sounds, balance for stereo.
    pan: f32 = 0.0,
    /// Playback-rate multiplier (0.25…4), linear interpolation.
    pitch: f32 = 1.0,
};

pub const SoundId = enum(u32) { _ };

pub const Status = struct {
    backend: BackendKind,
    /// Why `backend` is `.none` (or which backends were skipped).
    reason: []const u8 = "",
    device: DeviceInfo = .{},
    running: bool = false,
};

pub const StatsSnapshot = struct {
    callbacks: u64,
    frames: u64,
    /// Average render time per callback (all callbacks / those with voices).
    avg_render_ns: u64,
    avg_busy_render_ns: u64,
    max_render_ns: u64,
    suspends: u64,
    resumes: u64,
    last_resume_ns: u64,
    avg_resume_ns: u64,
    max_resume_ns: u64,
    voices_started: u64,
    voices_stolen: u64,
    dropped: u64,
    xruns: u64,
};

pub const LoadError = error{ TooManySounds, OutOfMemory } || wav.Error;

const Stub = struct {
    pub const Backend = struct {
        info: DeviceInfo = .{},
        pub fn open(_: Allocator, _: *Engine, _: engine.OpenOptions) engine.OpenError!*Backend {
            return error.Unavailable;
        }
        pub fn close(_: *Backend) void {}
        pub fn start(_: *Backend) bool {
            return false;
        }
        pub fn stop(_: *Backend) void {}
        pub fn deviceChanged(_: *Backend, _: bool) void {}
    };
};

const coreaudio = if (os == .macos) @import("coreaudio.zig") else Stub;
const wasapi = if (os == .windows) @import("wasapi.zig") else Stub;
const pipewire = if (os == .linux) @import("pipewire.zig") else Stub;
const pulse = if (os == .linux) @import("pulse.zig") else Stub;
const alsa = if (os == .linux) @import("alsa.zig") else Stub;

const Device = union(BackendKind) {
    none,
    null,
    coreaudio: *coreaudio.Backend,
    wasapi: *wasapi.Backend,
    pipewire: *pipewire.Backend,
    pulse: *pulse.Backend,
    alsa: *alsa.Backend,
};

pub const Audio = struct {
    gpa: Allocator,
    engine: Engine,
    device: Device = .none,
    reason: []const u8 = "",
    control: ?std.Thread = null,
    produce: sys.SpinLock = .{},
    sounds: [max_sounds]?*mixer.Sound = @splat(null),
    sound_count: std.atomic.Value(u32) = .init(0),
    load_lock: sys.SpinLock = .{},

    /// Opens the output device (or the null backend). Never fails for lack
    /// of audio hardware: check `status().backend` (`.none` → `play` is a
    /// no-op, `status().reason` says why).
    pub fn init(gpa: Allocator, opts: Options) error{ OutOfMemory, SystemResources }!*Audio {
        const self = try gpa.create(Audio);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .engine = undefined };
        try self.engine.init(@max(8000, opts.sample_rate), @as(u64, opts.keep_alive_ms) * std.time.ns_per_ms);
        const o: engine.OpenOptions = .{ .rate = self.engine.mixer.rate, .buffer_frames = opts.buffer_frames, .app_name = opts.app_name };
        switch (opts.backend) {
            .null => {
                self.device = .null;
                self.engine.markRunning(); // rendered on demand, never suspended
            },
            .none => self.reason = "audio disabled",
            .auto => switch (os) {
                .macos => _ = self.tryOpen(.coreaudio, o) catch |e| return e,
                .windows => _ = self.tryOpen(.wasapi, o) catch |e| return e,
                .linux => {
                    const ok = (try self.tryOpen(.pipewire, o)) or (try self.tryOpen(.pulse, o)) or (try self.tryOpen(.alsa, o));
                    if (!ok) self.reason = "no PipeWire, PulseAudio or ALSA output available";
                },
                else => self.reason = "no audio backend for this OS",
            },
            inline .coreaudio, .wasapi, .pipewire, .pulse, .alsa => |k| _ = try self.tryOpen(@field(BackendKind, @tagName(k)), o),
        }
        if (self.device == .none and self.reason.len == 0) self.reason = "output device unavailable";
        if (self.device == .none) log.info("audio: no output ({s}); play() is a no-op", .{self.reason});
        return self;
    }

    fn tryOpen(self: *Audio, comptime kind: BackendKind, o: engine.OpenOptions) error{ OutOfMemory, SystemResources }!bool {
        const B = switch (kind) {
            .coreaudio => coreaudio.Backend,
            .wasapi => wasapi.Backend,
            .pipewire => pipewire.Backend,
            .pulse => pulse.Backend,
            .alsa => alsa.Backend,
            else => unreachable,
        };
        if (B == Stub.Backend) {
            self.reason = "backend not available on this OS";
            return false;
        }
        const b = B.open(self.gpa, &self.engine, o) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Unavailable => {
                self.reason = @tagName(kind) ++ " unavailable";
                return false;
            },
        };
        self.device = @unionInit(Device, @tagName(kind), b);
        self.reason = "";
        // Callback-driven backends (CoreAudio, PipeWire, PulseAudio) get a
        // control thread for suspend/resume; WASAPI and ALSA have no `start`:
        // their own render thread does it inline.
        if (@hasDecl(B, "start")) {
            self.control = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, engine.controlLoop, .{ B, b, &self.engine }) catch {
                b.close();
                self.device = .none;
                self.reason = "could not start the audio control thread";
                return error.SystemResources;
            };
        }
        log.info("audio: {s} {d} Hz, {d} ch, {d}-frame period, ~{d:.1} ms output latency", .{
            @tagName(kind), b.info.rate, b.info.channels, b.info.period_frames, @as(f64, @floatFromInt(b.info.latency_ns)) / 1e6,
        });
        return true;
    }

    pub fn deinit(self: *Audio) void {
        self.engine.quit.store(true, .release);
        self.engine.poke();
        if (self.control) |t| t.join();
        switch (self.device) {
            .none, .null => {},
            inline else => |b| b.close(),
        }
        for (self.sounds[0..self.sound_count.load(.acquire)]) |s| if (s) |snd| {
            self.gpa.free(snd.samples);
            self.gpa.destroy(snd);
        };
        self.engine.deinit();
        self.gpa.destroy(self);
    }

    pub fn status(self: *const Audio) Status {
        return .{
            .backend = self.device,
            .reason = self.reason,
            .device = switch (self.device) {
                .none => .{},
                .null => .{ .rate = self.engine.mixer.rate, .channels = 2 },
                inline else => |b| b.info,
            },
            .running = self.device != .none and self.engine.state.load(.monotonic) == .running,
        };
    }

    /// Loads interleaved f32 PCM (1 or 2 channels). The data is copied.
    pub fn loadPcmF32(self: *Audio, samples: []const f32, channels: u8, rate: u32) LoadError!SoundId {
        if (channels != 1 and channels != 2) return error.UnsupportedWav;
        const frames = samples.len / channels;
        const buf = try self.gpa.alloc(f32, (frames + 1) * channels);
        errdefer self.gpa.free(buf);
        @memcpy(buf[0 .. frames * channels], samples[0 .. frames * channels]);
        @memset(buf[frames * channels ..], 0); // guard frame
        return self.addSound(buf, @intCast(frames), channels, rate);
    }

    /// Loads mono 16-bit PCM.
    pub fn loadPcm(self: *Audio, samples: []const i16, rate: u32) LoadError!SoundId {
        const buf = try self.gpa.alloc(f32, samples.len + 1);
        errdefer self.gpa.free(buf);
        for (samples, buf[0..samples.len]) |s, *d| d.* = @as(f32, @floatFromInt(s)) / 32768.0;
        buf[samples.len] = 0;
        return self.addSound(buf, @intCast(samples.len), 1, rate);
    }

    /// Loads a RIFF/WAVE file (PCM 8/16/24/32, float; mono or stereo).
    pub fn loadWav(self: *Audio, bytes: []const u8) LoadError!SoundId {
        const d = try wav.decode(self.gpa, bytes);
        defer d.deinit(self.gpa);
        return self.loadPcmF32(d.samples, d.channels, d.rate);
    }

    fn addSound(self: *Audio, buf: []f32, frames: u32, channels: u8, rate: u32) LoadError!SoundId {
        if (rate == 0) return error.UnsupportedWav;
        const snd = try self.gpa.create(mixer.Sound);
        snd.* = .{ .samples = buf, .frames = frames, .channels = channels, .rate = rate };
        self.load_lock.lock();
        defer self.load_lock.unlock();
        const n = self.sound_count.load(.monotonic);
        if (n >= max_sounds) {
            self.gpa.destroy(snd);
            return error.TooManySounds;
        }
        self.sounds[n] = snd;
        self.sound_count.store(n + 1, .release);
        return @fromBackingInt(@intCast(n));
    }

    /// Starts a voice. Callable from any thread; never blocks on the
    /// device (a suspended device is restarted by the backend thread).
    pub fn play(self: *Audio, id: SoundId, opts: PlayOptions) void {
        if (self.device == .none) return;
        const i = @backingInt(id);
        if (i >= self.sound_count.load(.acquire)) return;
        const snd = self.sounds[i].?;
        const g = if (snd.channels == 1) mixer.panGains(opts.gain, opts.pan) else mixer.balanceGains(opts.gain, opts.pan);
        self.push(.{ .kind = .play, .sound = snd, .gain_l = g[0], .gain_r = g[1], .pitch = opts.pitch });
    }

    /// Silences every voice.
    pub fn stopAll(self: *Audio) void {
        if (self.device == .none) return;
        self.push(.{ .kind = .stop_all });
    }

    fn push(self: *Audio, cmd: mixer.Command) void {
        self.produce.lock();
        const ok = self.engine.mixer.ring.push(cmd);
        self.produce.unlock();
        if (!ok) {
            _ = self.engine.stats.dropped.fetchAdd(1, .monotonic);
            return;
        }
        self.engine.notifyPlay();
    }

    /// 0 … 4 (1 = unity), smoothed over one callback.
    pub fn setMasterVolume(self: *Audio, v: f32) void {
        self.engine.mixer.setMasterVolume(v);
    }

    pub fn masterVolume(self: *const Audio) f32 {
        return self.engine.mixer.masterVolume();
    }

    /// Null backend only: renders `out.len / 2` interleaved stereo f32
    /// frames, exactly as a device callback would.
    pub fn renderOffline(self: *Audio, out: []f32) void {
        std.debug.assert(self.device == .null);
        self.engine.render(f32, out, out.len / 2, 2);
    }

    pub fn sampleRate(self: *const Audio) u32 {
        return self.engine.mixer.rate;
    }

    pub fn stats(self: *const Audio) StatsSnapshot {
        const s = &self.engine.stats;
        const cb = s.callbacks.load(.monotonic);
        const busy = s.busy_callbacks.load(.monotonic);
        const resumes = s.resumes.load(.monotonic);
        return .{
            .callbacks = cb,
            .frames = s.frames.load(.monotonic),
            .avg_render_ns = if (cb == 0) 0 else s.render_ns.load(.monotonic) / cb,
            .avg_busy_render_ns = if (busy == 0) 0 else s.busy_render_ns.load(.monotonic) / busy,
            .max_render_ns = s.render_ns_max.load(.monotonic),
            .suspends = s.suspends.load(.monotonic),
            .resumes = resumes,
            .last_resume_ns = s.last_resume_ns.load(.monotonic),
            .avg_resume_ns = if (resumes == 0) 0 else s.total_resume_ns.load(.monotonic) / resumes,
            .max_resume_ns = s.max_resume_ns.load(.monotonic),
            .voices_started = self.engine.mixer.played.load(.monotonic),
            .voices_stolen = self.engine.mixer.steals.load(.monotonic),
            .dropped = s.dropped.load(.monotonic),
            .xruns = s.xruns.load(.monotonic),
        };
    }
};

/// A short procedural mechanical-keyboard click (mono, `rate` Hz): a
/// noise transient through a resonant band-pass plus a decaying body
/// thump. Caller owns the returned slice.
pub fn synthesizeClick(gpa: Allocator, rate: u32, seed: u64) Allocator.Error![]i16 {
    const n: usize = rate * 35 / 1000;
    const out = try gpa.alloc(i16, n);
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const fs: f32 = @floatFromInt(rate);
    // RBJ band-pass around 3.2 kHz, Q 2.5 (the "tick").
    const f0: f32 = 3200;
    const w0 = 2 * std.math.pi * f0 / fs;
    const alpha = @sin(w0) / (2 * 2.5);
    const a0 = 1 + alpha;
    const b0 = alpha / a0;
    const a1 = -2 * @cos(w0) / a0;
    const a2 = (1 - alpha) / a0;
    var x1: f32 = 0;
    var x2: f32 = 0;
    var y1: f32 = 0;
    var y2: f32 = 0;
    for (out, 0..) |*o, i| {
        const t = @as(f32, @floatFromInt(i)) / fs;
        const noise = r.float(f32) * 2 - 1;
        const x = noise * @exp(-t * 900);
        const y = b0 * x - b0 * x2 - a1 * y1 - a2 * y2;
        x2 = x1;
        x1 = x;
        y2 = y1;
        y1 = y;
        // Body: 180 Hz → 120 Hz thump with a fast decay, and a second
        // bottom-out transient 6 ms in.
        const body = @sin(2 * std.math.pi * (180 - 1700 * t) * t) * @exp(-t * 140) * 0.45;
        const t2 = t - 0.006;
        const bottom = if (t2 > 0) (r.float(f32) * 2 - 1) * @exp(-t2 * 1400) * 0.25 else 0;
        const fade = @min(1.0, @as(f32, @floatFromInt(n - i)) / (fs * 0.004));
        const s = std.math.clamp((y * 2.2 + body + bottom) * fade * 0.7, -1, 1);
        o.* = @intFromFloat(s * 32767);
    }
    return out;
}

test {
    _ = sys;
    _ = mixer;
    _ = wav;
    _ = @import("tests.zig");
    if (os == .linux) {
        _ = @import("pipewire.zig");
    }
}
