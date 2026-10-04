//! Viewport-local dictation state — zeron `crates/ui/src/dictation.rs`
//! (`Event`, `Transcriber`, `Phase`, `Dictation`) and `dictation/meter.rs`
//! (`Meter`). Only transcript strings cross this boundary; audio never
//! enters the editor. The native engine lives in the app (`voice/`); tests
//! inject fakes through `Transcriber`.

const std = @import("std");
const zpui = @import("zpui");
const Allocator = std.mem.Allocator;
const editor = @import("editor.zig");
const Range = editor.Range;

/// The app's dictation backend (Rust `dictation::{enabled, start,
/// permission_pending}`), installed as a zpui global by the app so the
/// editor and composer modules never link the voice engine. Without it
/// dictation is off: no microphone, the shortcut propagates.
pub const Service = struct {
    ctx: ?*anyopaque = null,
    /// Settings → Voice is on and the model is installed.
    enabled: *const fn (?*anyopaque, *zpui.App) bool,
    /// A new transcription for the focused composer (null: dictation off).
    start: *const fn (?*anyopaque, *zpui.App) ?Transcriber,
    /// The microphone permission prompt has not been answered yet (macOS).
    permission_pending: *const fn (?*anyopaque) bool,
    /// The hold-to-talk shortcut as a platform combo (`cmd-d`), written
    /// into `buf`; recognises the shortcut's release. Empty: any key.
    binding: *const fn (?*anyopaque, *zpui.App, buf: []u8) []const u8,
};

/// `dictation::enabled`.
pub fn enabled(app: *zpui.App) bool {
    const s = app.tryGlobal(Service) orelse return false;
    return s.enabled(s.ctx, app);
}

/// `dictation::start`.
pub fn startSession(app: *zpui.App) ?Transcriber {
    const s = app.tryGlobal(Service) orelse return null;
    if (!s.enabled(s.ctx, app)) return null;
    return s.start(s.ctx, app);
}

/// `dictation::permission_pending`.
pub fn permissionPending(app: *zpui.App) bool {
    const s = app.tryGlobal(Service) orelse return false;
    return s.permission_pending(s.ctx);
}

/// The hold-to-talk binding as a keystroke (Rust parses
/// `settings.keymap.toggle_dictation`, falling back to the default combo).
pub fn binding(app: *zpui.App, buf: *[64]u8, key_buf: *[32]u8) ?zpui.input.Keystroke {
    const s = app.tryGlobal(Service) orelse return null;
    const combo = s.binding(s.ctx, app, buf);
    if (combo.len == 0) return null;
    var fba: std.heap.FixedBufferAllocator = .init(key_buf);
    return zpui.core.parseKeystroke(fba.allocator(), combo) catch null;
}

/// `waveform::clock`: display time for the recording clock (`0:07`).
pub fn clockLabel(buf: []u8, elapsed_ns: u64) []const u8 {
    const seconds = elapsed_ns / std.time.ns_per_s;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ seconds / 60, seconds % 60 }) catch "";
}

pub const ns_per_ms = std.time.ns_per_ms;

/// `FINALIZE_TIMEOUT`.
pub const finalize_timeout_ns: u64 = 30 * std.time.ns_per_s;
/// The input's poll cadence while a session is active (Rust's 40 ms timer).
pub const poll_interval_ns: u64 = 40 * ns_per_ms;

/// Transcriber → editor. Strings stay valid until the next `poll`.
pub const Event = union(enum) {
    listening,
    finalizing,
    partial: []const u8,
    final: []const u8,
    denied: []const u8,
    unavailable: []const u8,
    failed: []const u8,
    cancelled,
};

/// A running transcription (Rust `Box<dyn Transcriber>`). Dropping it
/// (`deinit`) signals capture cancellation and invalidates pending results.
pub const Transcriber = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        poll: *const fn (*anyopaque) ?Event,
        finish: *const fn (*anyopaque) void,
        /// Peak input RMS since the previous call, for the live waveform.
        level: *const fn (*anyopaque) f32,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn poll(self: Transcriber) ?Event {
        return self.vtable.poll(self.ctx);
    }
    pub fn finish(self: Transcriber) void {
        self.vtable.finish(self.ctx);
    }
    pub fn level(self: Transcriber) f32 {
        return self.vtable.level(self.ctx);
    }
    pub fn deinit(self: Transcriber) void {
        self.vtable.deinit(self.ctx);
    }
};

pub const PhaseTag = enum { idle, requesting, listening, finalizing, no_speech, tapped, denied, unavailable, failed };

/// Rust `Phase`; messages are owned by the `Dictation` that holds it.
pub const Phase = union(PhaseTag) {
    idle,
    requesting,
    listening,
    finalizing,
    no_speech,
    /// Released almost immediately: dictation is hold to talk.
    tapped,
    denied: []u8,
    unavailable: []u8,
    failed: []u8,

    pub fn active(self: Phase) bool {
        return switch (self) {
            .requesting, .listening, .finalizing => true,
            else => false,
        };
    }

    /// Button names describe the action, independently of the live status.
    pub fn actionLabel(self: Phase) []const u8 {
        return switch (self) {
            .idle, .tapped => "Hold to dictate",
            .requesting, .listening => "Release to transcribe",
            .finalizing => "Transcribing",
            .no_speech, .denied, .unavailable, .failed => "Hold to retry dictation",
        };
    }

    pub const Status = struct { title: []const u8, detail: []const u8 };

    pub fn status(self: Phase) ?Status {
        return switch (self) {
            .idle => null,
            .requesting => .{ .title = "Getting ready\u{2026}", .detail = "Wait for Listening before speaking." },
            .listening => .{ .title = "Listening", .detail = "Release when you\u{2019}re done \u{b7} Up to 1 minute" },
            .finalizing => .{ .title = "Transcribing\u{2026}", .detail = "Processing on this device." },
            .no_speech => .{ .title = "No speech detected", .detail = "Check your microphone, then try again." },
            .tapped => .{ .title = "Hold to dictate", .detail = "Keep holding the microphone or the shortcut while you speak." },
            .denied, .unavailable => |m| .{ .title = "Dictation unavailable", .detail = m },
            .failed => |m| .{ .title = "Dictation stopped", .detail = m },
        };
    }

    /// The phase as a message-carrying variant (owned copy).
    pub fn withMessage(gpa: Allocator, tag: PhaseTag, message: []const u8) Allocator.Error!Phase {
        return switch (tag) {
            .denied => .{ .denied = try gpa.dupe(u8, message) },
            .unavailable => .{ .unavailable = try gpa.dupe(u8, message) },
            .failed => .{ .failed = try gpa.dupe(u8, message) },
            .idle => .idle,
            .requesting => .requesting,
            .listening => .listening,
            .finalizing => .finalizing,
            .no_speech => .no_speech,
            .tapped => .tapped,
        };
    }

    fn free(self: Phase, gpa: Allocator) void {
        switch (self) {
            .denied, .unavailable, .failed => |m| gpa.free(m),
            else => {},
        }
    }
};

// ---- meter (dictation/meter.rs) ---------------------------------------------

/// One bar per slot.
pub const step_ns: u64 = 60 * ns_per_ms;
const lag_ns: u64 = 70 * ns_per_ms;
/// Enough slots for the widest composer; older bars have scrolled away.
pub const capacity = 320;
/// A bar never drops below its neighbour faster than this, so syllables leave
/// a short tail instead of flickering between loud and silent.
pub const release = 0.62;
/// The quietest bar still reads as a dot on the baseline.
pub const floor = 0.08;

/// One visible bar: `age` in slots behind the trailing edge (0 = newest) and
/// its normalised height.
pub const Bar = struct { age: f32, amplitude: f32 };

/// Maps microphone RMS onto a perceptual 0–1 scale: −50 dBFS is silence and
/// −12 dBFS, a close, raised voice, fills the bar.
pub fn normalize(rms: f32) f32 {
    if (!std.math.isFinite(rms) or rms <= 1e-6) return 0;
    return std.math.clamp((20.0 * std.math.log10(rms) + 50.0) / 38.0, 0.0, 1.0);
}

/// Live input level for the waveform: one normalised amplitude per fixed
/// time slot (never audio). Slots sit on a fixed clock from the moment
/// capture starts; drawing trails it by `lag_ns` so a slot is always filled
/// before it scrolls into view. Times are monotonic nanoseconds.
pub const Meter = struct {
    started: ?u64 = null,
    frozen: ?u64 = null,
    slots: [capacity]f32 = undefined,
    /// Ring buffer: `len` valid slots ending at `filled`.
    len: usize = 0,
    filled: u64 = 0,
    pending: f32 = 0,

    pub fn start(self: *Meter, now: u64) void {
        self.* = .{ .started = now };
    }

    /// Time since capture began; null until the microphone is live.
    pub fn sinceStart(self: *const Meter, now: u64) ?u64 {
        const at = self.started orelse return null;
        return now -| at;
    }

    pub fn reset(self: *Meter) void {
        self.* = .{};
    }

    /// Stops the clock where capture ended; bars and timer hold still.
    pub fn freeze(self: *Meter, now: u64) void {
        if (self.started != null and self.frozen == null) self.frozen = now;
    }

    fn slot(self: *const Meter, i: usize) f32 {
        // i-th of the retained slots, oldest first.
        const first = self.filled - self.len;
        return self.slots[@intCast((first + i) % capacity)];
    }

    /// Folds in the loudest RMS since the previous call. Returns true when a
    /// new slot was filled.
    pub fn record(self: *Meter, now: u64, rms: f32) bool {
        const started = self.started orelse return false;
        if (self.frozen != null) return false;
        self.pending = @max(self.pending, normalize(rms));
        const due = (now -| started) / step_ns + 1;
        if (self.filled >= due) return false;
        while (self.filled < due) {
            const previous: f32 = if (self.len > 0) self.slot(self.len - 1) else 0;
            self.slots[@intCast(self.filled % capacity)] = @max(self.pending, previous * release);
            self.filled += 1;
            if (self.len < capacity) self.len += 1;
        }
        self.pending = 0;
        return true;
    }

    pub fn elapsed(self: *const Meter, now: u64) u64 {
        const started = self.started orelse return 0;
        return (self.frozen orelse now) -| started;
    }

    /// Bars visible at `now`, newest first. `continuous` false snaps the
    /// scroll to whole slots for reduced motion.
    pub fn bars(self: *const Meter, now: u64, continuous: bool, out: []Bar) []Bar {
        const started = self.started orelse return out[0..0];
        const end = if (self.frozen) |f| @min(f, now) else now;
        const clock = end -| started;
        if (clock < lag_ns) return out[0..0];
        const head = @as(f32, @floatFromInt(clock - lag_ns)) / @as(f32, @floatFromInt(step_ns));
        const first = self.filled - self.len;
        var n: usize = 0;
        var i = self.len;
        while (i > 0 and n < out.len) {
            i -= 1;
            const age = head - @as(f32, @floatFromInt(first + i));
            if (age < 0) continue;
            out[n] = .{ .age = if (continuous) age else @floor(age), .amplitude = self.slot(i) };
            n += 1;
        }
        return out[0..n];
    }

    /// Current loudness for the glow, blended between the two newest visible
    /// slots as the newest one scrolls in, so it changes without steps.
    pub fn level(self: *const Meter, now: u64) f32 {
        var buf: [2]Bar = undefined;
        const b = self.bars(now, true, &buf);
        return switch (b.len) {
            0 => 0,
            1 => b[0].amplitude * std.math.clamp(b[0].age, 0, 1),
            else => b[1].amplitude + (b[0].amplitude - b[1].amplitude) * std.math.clamp(b[0].age, 0, 1),
        };
    }
};

// ---- the session state (Rust `Dictation`) -------------------------------------

pub const Dictation = struct {
    gpa: Allocator,
    phase: Phase = .idle,
    generation: u64 = 0,
    range: Range = .collapsed(0),
    expected: std.ArrayList(u8) = .empty,
    has_partial: bool = false,
    pending_send: bool = false,
    finish_started: ?u64 = null,
    meter: Meter = .{},

    pub fn init(gpa: Allocator) Dictation {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Dictation) void {
        self.phase.free(self.gpa);
        self.expected.deinit(self.gpa);
    }

    pub fn setPhase(self: *Dictation, phase: Phase) void {
        self.phase.free(self.gpa);
        self.phase = phase;
    }

    pub fn begin(self: *Dictation, content: []const u8, selection: Range) Allocator.Error!void {
        self.cancel();
        self.setPhase(.requesting);
        self.range = selection;
        try self.expected.appendSlice(self.gpa, content);
        self.has_partial = false;
    }

    /// Invalidates late callbacks AND pending sends, preserving committed text.
    pub fn cancel(self: *Dictation) void {
        self.generation +%= 1;
        self.setPhase(.idle);
        self.pending_send = false;
        self.finish_started = null;
        self.expected.clearRetainingCapacity();
        self.meter.reset();
    }

    /// Returns true only on the transition that must finish the audio stream.
    pub fn finish(self: *Dictation, send: bool, now: u64) bool {
        if (!self.phase.active()) return false;
        self.pending_send = self.pending_send or send;
        if (self.phase == .finalizing) return false;
        self.setPhase(.finalizing);
        self.finish_started = now;
        self.meter.freeze(now);
        return true;
    }

    pub fn timedOut(self: *const Dictation, now: u64) bool {
        const at = self.finish_started orelse return false;
        return now -| at >= finalize_timeout_ns;
    }

    /// Whether `content` is still the draft dictation expects; a changed
    /// draft cannot be overwritten, even if a caller missed cancellation.
    /// Returns the range to replace, or null (after cancelling / for an
    /// empty transcript).
    pub fn target(self: *Dictation, content: []const u8, transcript: []const u8) ?Range {
        if (!self.phase.active() or !std.mem.eql(u8, content, self.expected.items)) {
            self.cancel();
            return null;
        }
        // Empty recognition does not erase selected text or the latest partial.
        if (std.mem.trim(u8, transcript, " \t\r\n").len == 0) return null;
        return self.range;
    }

    /// After the caller replaced `target()`'s range with `transcript`:
    /// remember the new range and draft. Returns the caret offset.
    pub fn replaced(self: *Dictation, content: []const u8, transcript: []const u8) Allocator.Error!usize {
        self.range.end = self.range.start + transcript.len;
        self.expected.clearRetainingCapacity();
        try self.expected.appendSlice(self.gpa, content);
        self.has_partial = true;
        return self.range.end;
    }

    /// Ends the session in `phase`; returns whether a pending send fires.
    pub fn complete(self: *Dictation, phase: Phase) bool {
        const send = self.pending_send and phase == .idle;
        self.cancel();
        self.setPhase(phase);
        return send;
    }
};

const testing = std.testing;

fn ms(n: u64) u64 {
    return n * ns_per_ms;
}

test "normalizes speech range and rejects invalid levels" {
    try testing.expectEqual(@as(f32, 0), normalize(0));
    try testing.expectEqual(@as(f32, 0), normalize(std.math.nan(f32)));
    try testing.expectEqual(@as(f32, 0), normalize(std.math.pow(f32, 10, -50.0 / 20.0)));
    try testing.expectEqual(@as(f32, 1), normalize(1));
    const mid = normalize(0.02);
    try testing.expect(mid > 0.2 and mid < 0.8);
}

test "slots stay on the clock when polls are irregular" {
    const t0: u64 = 1_000_000_000;
    var meter: Meter = .{};
    meter.start(t0);
    try testing.expect(meter.record(t0 + ms(5), 0.1));
    try testing.expect(!meter.record(t0 + ms(30), 0));
    // A late poll fills every slot it skipped.
    try testing.expect(meter.record(t0 + step_ns * 3 + ms(1), 0));
    try testing.expectEqual(@as(u64, 4), meter.filled);
    var buf: [capacity]Bar = undefined;
    const b = meter.bars(t0 + step_ns * 3 + lag_ns + ms(1), true, &buf);
    try testing.expectEqual(@as(usize, 4), b.len);
    for (b[0 .. b.len - 1], b[1..]) |p0, p1| try testing.expect(@abs(p1.age - p0.age - 1) < 1e-3);
    // Loud slot decays into its neighbours instead of dropping to zero.
    const loud = normalize(0.1);
    try testing.expectEqual(loud, b[3].amplitude);
    try testing.expect(@abs(b[2].amplitude - loud * release) < 1e-6);
}

test "peak between slots is kept for the next slot" {
    const t0: u64 = 1_000_000_000;
    var meter: Meter = .{};
    meter.start(t0);
    _ = meter.record(t0, 0);
    try testing.expect(!meter.record(t0 + ms(20), 0.2));
    try testing.expect(meter.record(t0 + step_ns, 0));
    try testing.expectEqual(normalize(0.2), meter.slot(meter.len - 1));
}

test "freezing stops scroll and timer" {
    const t0: u64 = 1_000_000_000;
    var meter: Meter = .{};
    meter.start(t0);
    _ = meter.record(t0 + step_ns * 5, 0.05);
    meter.freeze(t0 + step_ns * 5);
    try testing.expect(!meter.record(t0 + step_ns * 9, 0.5));
    const later = t0 + 10 * std.time.ns_per_s;
    try testing.expectEqual(step_ns * 5, meter.elapsed(later));
    var a: [capacity]Bar = undefined;
    var b: [capacity]Bar = undefined;
    try testing.expectEqualSlices(Bar, meter.bars(later, true, &a), meter.bars(later + ms(500), true, &b));
}

test "level glides between slots" {
    const t0: u64 = 1_000_000_000;
    var meter: Meter = .{};
    meter.start(t0);
    _ = meter.record(t0, 0);
    _ = meter.record(t0 + step_ns, 0.1);
    const base = t0 + step_ns + lag_ns + ms(1);
    const loud = normalize(0.1);
    try testing.expect(meter.level(base) < 0.03);
    try testing.expect(@abs(meter.level(base + step_ns / 2) - loud / 2) < 0.03);
    try testing.expect(@abs(meter.level(base + step_ns) - loud) < 1e-6);
}

test "reduced motion snaps to whole slots" {
    const t0: u64 = 1_000_000_000;
    var meter: Meter = .{};
    meter.start(t0);
    _ = meter.record(t0 + step_ns * 2, 0.05);
    var buf: [capacity]Bar = undefined;
    for (meter.bars(t0 + step_ns * 2 + lag_ns + ms(20), false, &buf)) |bar| try testing.expectEqual(@floor(bar.age), bar.age);
}

test "capacity bounds history" {
    const t0: u64 = 1_000_000_000;
    var meter: Meter = .{};
    meter.start(t0);
    _ = meter.record(t0 + step_ns * capacity * 2, 0.05);
    try testing.expectEqual(@as(usize, capacity), meter.len);
    var buf: [capacity]Bar = undefined;
    const b = meter.bars(t0 + step_ns * capacity * 2 + lag_ns + ms(1), true, &buf);
    try testing.expectEqual(@as(usize, capacity), b.len);
    try testing.expect(b[0].age < 1);
}

test "finalization deadline does not restart when send follows stop" {
    var state: Dictation = .init(testing.allocator);
    defer state.deinit();
    try state.begin("draft", .collapsed(5));
    const start: u64 = 1_000_000_000;
    try testing.expect(state.finish(false, start));
    try testing.expect(!state.finish(true, start + std.time.ns_per_s));
    try testing.expect(!state.timedOut(start + finalize_timeout_ns - ms(1)));
    try testing.expect(state.timedOut(start + finalize_timeout_ns));
    try testing.expect(state.complete(.idle));
    try testing.expect(!state.complete(.idle));
}

test "unexpected draft change rejects late partial and send" {
    var state: Dictation = .init(testing.allocator);
    defer state.deinit();
    try state.begin("old", .{ .start = 0, .end = 3 });
    _ = state.finish(true, 0);
    try testing.expect(state.target("new draft", "late") == null);
    try testing.expect(!state.complete(.idle));
}

test "phase labels and statuses" {
    try testing.expectEqualStrings("Hold to dictate", (Phase{ .idle = {} }).actionLabel());
    try testing.expectEqualStrings("Release to transcribe", (Phase{ .listening = {} }).actionLabel());
    try testing.expectEqualStrings("Transcribing", (Phase{ .finalizing = {} }).actionLabel());
    try testing.expect((Phase{ .idle = {} }).status() == null);
    var msg = "boom".*;
    const st = (Phase{ .failed = &msg }).status().?;
    try testing.expectEqualStrings("Dictation stopped", st.title);
    try testing.expectEqualStrings("boom", st.detail);
}

test "clock formats minutes and padded seconds" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("0:07", clockLabel(&buf, 7_900 * ns_per_ms));
    try testing.expectEqualStrings("1:00", clockLabel(&buf, 60 * std.time.ns_per_s));
}
