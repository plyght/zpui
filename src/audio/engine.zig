//! State shared by `Audio` (producer side) and the device backends
//! (consumer side): the mixer, the running/suspended handshake that lets
//! the output device stop when idle, the wake event, and statistics.
//!
//! Suspend handshake (no locks): the consumer stores `state = suspended`
//! and then re-checks the command ring; `play` pushes to the ring and then
//! loads `state`. Both sides use seq_cst, so either the consumer sees the
//! new command and stays running, or `play` sees `suspended` and signals
//! the wake event.

const std = @import("std");
const sys = @import("sys.zig");
const mixer_mod = @import("mixer.zig");
const Mixer = mixer_mod.Mixer;

pub const State = enum(u8) { suspended, running };

/// What a backend reports after opening its device.
pub const DeviceInfo = struct {
    /// Output rate the mixer renders at.
    rate: u32 = 0,
    channels: u32 = 2,
    /// Frames per callback / period.
    period_frames: u32 = 0,
    /// Estimated output latency (buffering between the callback and the
    /// speaker), when the OS reports it.
    latency_ns: u64 = 0,
};

pub const OpenOptions = struct {
    rate: u32,
    /// 0: backend default.
    buffer_frames: u32,
    app_name: [:0]const u8,
};

pub const OpenError = error{ Unavailable, OutOfMemory };

pub const Stats = struct {
    callbacks: std.atomic.Value(u64) = .init(0),
    frames: std.atomic.Value(u64) = .init(0),
    render_ns: std.atomic.Value(u64) = .init(0),
    render_ns_max: std.atomic.Value(u64) = .init(0),
    /// Callbacks that had at least one voice playing, and their render time.
    busy_callbacks: std.atomic.Value(u64) = .init(0),
    busy_render_ns: std.atomic.Value(u64) = .init(0),
    suspends: std.atomic.Value(u64) = .init(0),
    resumes: std.atomic.Value(u64) = .init(0),
    /// play() on a suspended device → first callback after restart.
    last_resume_ns: std.atomic.Value(u64) = .init(0),
    max_resume_ns: std.atomic.Value(u64) = .init(0),
    total_resume_ns: std.atomic.Value(u64) = .init(0),
    dropped: std.atomic.Value(u64) = .init(0),
    xruns: std.atomic.Value(u64) = .init(0),
};

pub const Engine = struct {
    mixer: Mixer,
    state: std.atomic.Value(State) = .init(.suspended),
    wake: sys.Event = .{},
    quit: std.atomic.Value(bool) = .init(false),
    device_changed: std.atomic.Value(bool) = .init(false),
    wake_requested_ns: std.atomic.Value(u64) = .init(0),
    keep_alive_ns: u64,
    stats: Stats = .{},

    pub fn init(self: *Engine, rate: u32, keep_alive_ns: u64) !void {
        self.* = .{ .mixer = .init(rate), .keep_alive_ns = keep_alive_ns };
        try self.wake.init();
    }

    pub fn deinit(self: *Engine) void {
        self.wake.deinit();
    }

    /// Device callback entry point: mixes `frames` frames and records timing.
    pub fn render(self: *Engine, comptime T: type, out: []T, frames: usize, channels: usize) void {
        const t0 = sys.nowNs();
        const w = self.wake_requested_ns.load(.monotonic);
        if (w != 0 and self.wake_requested_ns.cmpxchgStrong(w, 0, .monotonic, .monotonic) == null and t0 > w) {
            const lat = t0 - w;
            self.stats.last_resume_ns.store(lat, .monotonic);
            _ = self.stats.total_resume_ns.fetchAdd(lat, .monotonic);
            _ = self.stats.max_resume_ns.fetchMax(lat, .monotonic);
            _ = self.stats.resumes.fetchAdd(1, .monotonic);
        }
        const busy = self.mixer.active != 0 or self.mixer.ring.len() != 0;
        self.mixer.render(T, out, frames, channels);
        const dt = sys.nowNs() -| t0;
        _ = self.stats.callbacks.fetchAdd(1, .monotonic);
        _ = self.stats.frames.fetchAdd(frames, .monotonic);
        _ = self.stats.render_ns.fetchAdd(dt, .monotonic);
        _ = self.stats.render_ns_max.fetchMax(dt, .monotonic);
        if (busy) {
            _ = self.stats.busy_callbacks.fetchAdd(1, .monotonic);
            _ = self.stats.busy_render_ns.fetchAdd(dt, .monotonic);
        }
    }

    /// Producer side, after pushing a command: wake a suspended device.
    pub fn notifyPlay(self: *Engine) void {
        if (self.state.load(.seq_cst) == .running) return;
        _ = self.wake_requested_ns.cmpxchgStrong(0, sys.nowNs(), .monotonic, .monotonic);
        self.wake.signal();
    }

    pub fn idleNs(self: *const Engine) u64 {
        const frames = self.mixer.idle_frames.load(.seq_cst);
        return frames * std.time.ns_per_s / @max(1, self.mixer.rate);
    }

    /// Time left before the keep-alive expires (0 when it has).
    pub fn keepAliveLeft(self: *const Engine) u64 {
        if (self.mixer.ring.len() != 0) return self.keep_alive_ns;
        const idle = self.idleNs();
        if (self.mixer.active_voices.load(.monotonic) != 0) return self.keep_alive_ns;
        return self.keep_alive_ns -| idle;
    }

    /// Consumer side: moves to `suspended` if the keep-alive expired and
    /// nothing is queued. The caller then stops the device. Returns false
    /// (staying running) when a command raced in.
    pub fn trySuspend(self: *Engine) bool {
        if (self.mixer.ring.len() != 0) return false;
        if (self.idleNs() < self.keep_alive_ns) return false;
        if (self.mixer.active_voices.load(.monotonic) != 0) return false;
        self.state.store(.suspended, .seq_cst);
        if (self.mixer.ring.len() != 0) {
            self.state.store(.running, .seq_cst);
            return false;
        }
        _ = self.stats.suspends.fetchAdd(1, .monotonic);
        return true;
    }

    /// Consumer side: about to (re)start the device.
    pub fn markRunning(self: *Engine) void {
        self.state.store(.running, .seq_cst);
    }

    pub fn hasPending(self: *const Engine) bool {
        return self.mixer.ring.len() != 0;
    }

    /// Wake the backend's thread (device change, shutdown).
    pub fn poke(self: *Engine) void {
        self.wake.signal();
    }
};

/// Device control loop for callback-driven backends (CoreAudio, PulseAudio,
/// PipeWire), run on its own thread. `B` provides:
///   fn start(*B) bool      — start/uncork the already-open stream
///   fn stop(*B) void       — stop/cork it (objects stay alive)
///   fn deviceChanged(*B, running: bool) void — follow a new default device
/// While running it wakes at most once per keep-alive period to check for
/// idleness; while suspended it blocks until `play` (or shutdown) wakes it.
pub fn controlLoop(comptime B: type, b: *B, e: *Engine) void {
    while (!e.quit.load(.acquire)) {
        const running = e.state.load(.seq_cst) == .running;
        if (running) {
            _ = e.wake.wait(@max(e.keepAliveLeft(), 20 * std.time.ns_per_ms));
        } else {
            _ = e.wake.wait(null);
        }
        if (e.quit.load(.acquire)) break;
        if (e.device_changed.swap(false, .acq_rel)) b.deviceChanged(e.state.load(.seq_cst) == .running);
        if (e.state.load(.seq_cst) == .running) {
            if (e.trySuspend()) b.stop();
        } else if (e.hasPending()) {
            e.markRunning();
            if (!b.start()) {
                // Device unavailable: drop the backlog and stay suspended so
                // the next play() retries.
                e.state.store(.suspended, .seq_cst);
                e.wake_requested_ns.store(0, .monotonic);
                while (e.mixer.ring.pop()) |_| _ = e.stats.dropped.fetchAdd(1, .monotonic);
            }
        }
    }
}
