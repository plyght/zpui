//! ActivityMonitor: is some *other* process playing audio, or is the
//! microphone in use (a call)? Typing sounds use it to mute themselves.
//! No permissions are needed on any platform; our own process is excluded.
//!
//!     const mon = try zpui.audio.ActivityMonitor.init(gpa, .{
//!         .policy = .{ .mute_when_other_audio = true, .mute_when_mic_in_use = true },
//!         .notify = wakeMainLoop, // any thread: schedule dispatch() on the main thread
//!     });
//!     mon.setCallback(onChange, ctx); // runs inside dispatch()
//!     ...
//!     if (!mon.shouldMute()) audio.play(click, .{});
//!
//! Backends (event-driven unless noted):
//!   macOS 14.2+  CoreAudio process objects (kAudioHardwarePropertyProcessObjectList,
//!                per-process PID / IsRunningOutput / IsRunningInput) with listeners.
//!   older macOS  kAudioDevicePropertyDeviceIsRunningSomewhere on the default output
//!                and input devices. The output flag includes our own engine, so it is
//!                only sampled while `audio` (if given) is suspended; while it runs the
//!                previous value is held and re-checked at 1 Hz until it suspends.
//!   Windows      WASAPI sessions, polled at 1 Hz: other audio = an Active render
//!                session of another process whose peak meter is above −60 dBFS
//!                (browsers keep paused sessions active); mic = any Active capture
//!                session of another process on the default console or
//!                communications capture endpoint.
//!   Linux        PulseAudio protocol (PulseAudio or pipewire-pulse) with a
//!                subscription: uncorked sink inputs / source outputs of other
//!                processes; else native PipeWire registry: Stream/Output/Audio and
//!                Stream/Input/Audio nodes of other processes in state "running".
//!
//! Callbacks: backend threads only update atomics and call `notify`; the
//! change callback runs from `dispatch()`, which the app calls on its main
//! thread (from `notify`'s wakeup, a timer, or its event loop), so it is
//! always delivered on the main thread. `setEnabled(false)` tears the
//! backend down (no threads, listeners or polling) while typing sounds are off.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const audio_mod = @import("audio.zig");
const log = std.log.scoped(.zpui_audio);
const os = builtin.os.tag;

pub const Policy = struct {
    mute_when_other_audio: bool = true,
    mute_when_mic_in_use: bool = true,

    pub fn shouldMute(p: Policy, a: Activity) bool {
        return (p.mute_when_other_audio and a.other_audio) or (p.mute_when_mic_in_use and a.mic_in_use);
    }
};

pub const Activity = struct {
    other_audio: bool = false,
    mic_in_use: bool = false,
};

/// Hysteresis for sampled signals (Windows peak meters at 1 Hz): turns on
/// after `on_after` consecutive active samples, off after `off_after`
/// consecutive inactive ones, so gaps in speech or music don't flicker.
pub const Debounce = struct {
    on_after: u8 = 1,
    off_after: u8 = 3,
    state: bool = false,
    run: u8 = 0,

    pub fn update(self: *Debounce, sample: bool) bool {
        if (sample == self.state) {
            self.run = 0;
        } else {
            self.run +|= 1;
            if (self.run >= (if (sample) self.on_after else self.off_after)) {
                self.state = sample;
                self.run = 0;
            }
        }
        return self.state;
    }
};

pub const BackendKind = enum { none, manual, coreaudio_process, coreaudio_device, wasapi, pulse, pipewire };

const Stub = struct {
    pub const Monitor = struct {
        pub fn open(_: Allocator, _: *ActivityMonitor) ?*Monitor {
            return null;
        }
        pub fn close(_: *Monitor) void {}
    };
};

const mac = if (os == .macos) @import("activity_mac.zig") else Stub;
const win = if (os == .windows) @import("activity_wasapi.zig") else Stub;
const pulse = if (os == .linux) @import("activity_pulse.zig") else Stub;
const pipewire = if (os == .linux) @import("activity_pipewire.zig") else Stub;

const Backend = union(enum) {
    none,
    manual,
    mac: *mac.Monitor,
    win: *win.Monitor,
    pulse: *pulse.Monitor,
    pipewire: *pipewire.Monitor,
};

pub const ActivityMonitor = struct {
    gpa: Allocator,
    opts: Options,
    backend: Backend = .none,
    kind: BackendKind = .none,
    other: std.atomic.Value(bool) = .init(false),
    mic: std.atomic.Value(bool) = .init(false),
    generation: std.atomic.Value(u32) = .init(0),
    // Main-thread state.
    seen_generation: u32 = 0,
    reported: Activity = .{},
    callback: ?*const fn (?*anyopaque, *ActivityMonitor) void = null,
    callback_ctx: ?*anyopaque = null,
    enabled: bool = false,

    pub const Options = struct {
        policy: Policy = .{},
        /// Start monitoring right away (see `setEnabled`).
        enabled: bool = true,
        /// Called from a backend thread after the state changed: wake the
        /// main thread so it calls `dispatch()`. Must not block.
        notify: ?*const fn (?*anyopaque) void = null,
        notify_ctx: ?*anyopaque = null,
        /// Our output engine. The pre-14.2 macOS fallback can only tell
        /// "someone else is playing" while this engine is suspended.
        audio: ?*audio_mod.Audio = null,
        /// `.manual`: no OS backend; the app/tests call `publish`.
        backend: enum { auto, none, manual } = .auto,
    };

    pub fn init(gpa: Allocator, opts: Options) Allocator.Error!*ActivityMonitor {
        const self = try gpa.create(ActivityMonitor);
        self.* = .{ .gpa = gpa, .opts = opts };
        if (opts.enabled) self.setEnabled(true);
        return self;
    }

    pub fn deinit(self: *ActivityMonitor) void {
        self.setEnabled(false);
        self.gpa.destroy(self);
    }

    /// Starts or stops the OS backend. Disabled, it costs nothing and
    /// reports no activity.
    pub fn setEnabled(self: *ActivityMonitor, on: bool) void {
        if (on == self.enabled) return;
        self.enabled = on;
        if (!on) {
            switch (self.backend) {
                .none, .manual => {},
                inline else => |b| b.close(),
            }
            self.backend = .none;
            self.kind = .none;
            self.publish(.{});
            return;
        }
        switch (self.opts.backend) {
            .none => {},
            .manual => {
                self.backend = .manual;
                self.kind = .manual;
            },
            .auto => self.openBackend(),
        }
    }

    fn openBackend(self: *ActivityMonitor) void {
        switch (os) {
            .macos => if (mac.Monitor.open(self.gpa, self)) |m| {
                self.backend = .{ .mac = m };
                self.kind = if (m.process_api) .coreaudio_process else .coreaudio_device;
            },
            .windows => if (win.Monitor.open(self.gpa, self)) |m| {
                self.backend = .{ .win = m };
                self.kind = .wasapi;
            },
            .linux => if (pulse.Monitor.open(self.gpa, self)) |m| {
                self.backend = .{ .pulse = m };
                self.kind = .pulse;
            } else if (pipewire.Monitor.open(self.gpa, self)) |m| {
                self.backend = .{ .pipewire = m };
                self.kind = .pipewire;
            },
            else => {},
        }
        if (self.kind == .none) log.info("audio: activity monitor unavailable; reporting no activity", .{});
    }

    pub fn backendKind(self: *const ActivityMonitor) BackendKind {
        return self.kind;
    }

    pub fn backendName(self: *const ActivityMonitor) []const u8 {
        return @tagName(self.kind);
    }

    /// Another process is playing audio (live value, any thread).
    pub fn otherAudioPlaying(self: *const ActivityMonitor) bool {
        return self.other.load(.acquire);
    }

    /// Another process is recording (likely a call; live value, any thread).
    pub fn microphoneInUse(self: *const ActivityMonitor) bool {
        return self.mic.load(.acquire);
    }

    pub fn activity(self: *const ActivityMonitor) Activity {
        return .{ .other_audio = self.otherAudioPlaying(), .mic_in_use = self.microphoneInUse() };
    }

    pub fn setPolicy(self: *ActivityMonitor, p: Policy) void {
        self.opts.policy = p;
    }

    pub fn policy(self: *const ActivityMonitor) Policy {
        return self.opts.policy;
    }

    /// The policy applied to the current activity.
    pub fn shouldMute(self: *const ActivityMonitor) bool {
        return self.opts.policy.shouldMute(self.activity());
    }

    /// Change callback, invoked from `dispatch()` (main thread).
    pub fn setCallback(self: *ActivityMonitor, cb: ?*const fn (?*anyopaque, *ActivityMonitor) void, ctx: ?*anyopaque) void {
        self.callback = cb;
        self.callback_ctx = ctx;
    }

    /// Main thread: delivers a pending change to the callback. Cheap
    /// (one atomic load) when nothing changed. Returns true if it fired.
    pub fn dispatch(self: *ActivityMonitor) bool {
        const g = self.generation.load(.acquire);
        if (g == self.seen_generation) return false;
        self.seen_generation = g;
        const now = self.activity();
        if (std.meta.eql(now, self.reported)) return false;
        self.reported = now;
        if (self.callback) |cb| cb(self.callback_ctx, self);
        return true;
    }

    /// Backend side (any thread): records the current activity.
    pub fn publish(self: *ActivityMonitor, a: Activity) void {
        const o = self.other.swap(a.other_audio, .acq_rel);
        const m = self.mic.swap(a.mic_in_use, .acq_rel);
        if (o == a.other_audio and m == a.mic_in_use) return;
        _ = self.generation.fetchAdd(1, .acq_rel);
        if (self.opts.notify) |n| n(self.opts.notify_ctx);
    }

    /// Whether our own output engine is currently suspended (true when the
    /// monitor was not given an engine).
    pub fn ownEngineIdle(self: *const ActivityMonitor) bool {
        const a = self.opts.audio orelse return true;
        return !a.status().running;
    }
};

/// Our process id (for excluding our own streams/sessions).
pub fn ownPid() u32 {
    return switch (os) {
        .windows => GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

test "policy" {
    const both: Activity = .{ .other_audio = true, .mic_in_use = true };
    try std.testing.expect(!(Policy{}).shouldMute(.{}));
    try std.testing.expect((Policy{}).shouldMute(.{ .other_audio = true }));
    try std.testing.expect((Policy{}).shouldMute(.{ .mic_in_use = true }));
    try std.testing.expect(!(Policy{ .mute_when_other_audio = false, .mute_when_mic_in_use = false }).shouldMute(both));
    try std.testing.expect(!(Policy{ .mute_when_other_audio = false }).shouldMute(.{ .other_audio = true }));
    try std.testing.expect((Policy{ .mute_when_other_audio = false }).shouldMute(both));
    try std.testing.expect(!(Policy{ .mute_when_mic_in_use = false }).shouldMute(.{ .mic_in_use = true }));
}

test "debounce" {
    var d: Debounce = .{ .on_after = 1, .off_after = 3 };
    try std.testing.expect(!d.update(false));
    try std.testing.expect(d.update(true));
    try std.testing.expect(d.update(false)); // gap 1
    try std.testing.expect(d.update(false)); // gap 2
    try std.testing.expect(d.update(true)); // resets the gap
    try std.testing.expect(d.update(false));
    try std.testing.expect(d.update(false));
    try std.testing.expect(!d.update(false)); // third silent sample
    var d2: Debounce = .{ .on_after = 2, .off_after = 1 };
    try std.testing.expect(!d2.update(true));
    try std.testing.expect(d2.update(true));
    try std.testing.expect(!d2.update(false));
}

test "publish/dispatch delivers changes once, on the dispatching thread" {
    const Ctx = struct {
        calls: u32 = 0,
        notified: std.atomic.Value(u32) = .init(0),
        last: Activity = .{},
        fn onChange(p: ?*anyopaque, m: *ActivityMonitor) void {
            const c: *@This() = @ptrCast(@alignCast(p.?));
            c.calls += 1;
            c.last = m.activity();
        }
        fn notify(p: ?*anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(p.?));
            _ = c.notified.fetchAdd(1, .monotonic);
        }
    };
    var ctx: Ctx = .{};
    const m = try ActivityMonitor.init(std.testing.allocator, .{ .backend = .manual, .notify = Ctx.notify, .notify_ctx = &ctx });
    defer m.deinit();
    m.setCallback(Ctx.onChange, &ctx);
    try std.testing.expectEqual(BackendKind.manual, m.backendKind());
    try std.testing.expect(!m.dispatch());
    try std.testing.expect(!m.shouldMute());

    // From another thread, like a backend.
    const T = struct {
        fn run(mon: *ActivityMonitor) void {
            mon.publish(.{ .other_audio = true });
        }
    };
    const t = try std.Thread.spawn(.{}, T.run, .{m});
    t.join();
    try std.testing.expectEqual(@as(u32, 1), ctx.notified.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), ctx.calls); // not until dispatch
    try std.testing.expect(m.shouldMute());
    try std.testing.expect(m.dispatch());
    try std.testing.expectEqual(@as(u32, 1), ctx.calls);
    try std.testing.expect(ctx.last.other_audio and !ctx.last.mic_in_use);
    try std.testing.expect(!m.dispatch());

    // Same state again: no notification.
    m.publish(.{ .other_audio = true });
    try std.testing.expectEqual(@as(u32, 1), ctx.notified.load(.monotonic));

    // A blip that reverts before dispatch is coalesced away.
    m.publish(.{ .other_audio = true, .mic_in_use = true });
    m.publish(.{ .other_audio = true });
    try std.testing.expect(!m.dispatch());
    try std.testing.expectEqual(@as(u32, 1), ctx.calls);

    m.setPolicy(.{ .mute_when_other_audio = false });
    try std.testing.expect(!m.shouldMute());
    m.publish(.{ .other_audio = true, .mic_in_use = true });
    try std.testing.expect(m.shouldMute());

    // Disabling reports no activity.
    m.setEnabled(false);
    try std.testing.expect(!m.otherAudioPlaying() and !m.microphoneInUse());
    try std.testing.expect(m.dispatch());
    try std.testing.expectEqual(@as(u32, 2), ctx.calls);
}
