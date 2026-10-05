//! The main composer's route choreography (zeron `composer_dock.rs` +
//! `composer_dock/panel_handoff.rs`): one retargetable clock for the hero ↔
//! thread hand-off. Pure state, driven from `main_panel.zig` each frame with
//! the executor clock (ns); parity-tested against fixtures dumped from the
//! Rust code (`scripts/dock_parity.rs` → `testdata/dock_parity.zig`).
//!
//! - `Glide`: critically damped motion; position and velocity survive a new
//!   target (12 time constants over the 420 / 470 ms hand-off).
//! - `Visuals`: the staged fades (transcript, selectors, footer, dissolve).
//! - `PanelHandoff`: a fade-through when the route also changes the
//!   conversation's horizontal frame (the right pane opens or closes).
//! - `DockState.tick` / `positionAt` / `layoutWidth`: the per-frame steps.

const std = @import("std");
const zt = @import("zeron_theme");

const lerp = zt.motion.lerp;

pub const ns_per_s: f64 = 1_000_000_000.0;

fn seconds(from: u64, to: u64) f32 {
    return @floatCast(@as(f64, @floatFromInt(to -| from)) / ns_per_s);
}

/// Critically damped motion: no oscillation, and both position and velocity
/// survive a new target.
pub const Glide = struct {
    value: f32,
    velocity: f32 = 0,
    target: f32,

    pub fn init(value: f32) Glide {
        return .{ .value = value, .velocity = 0, .target = value };
    }

    pub fn advance(self: *Glide, target: f32, secs: f32, span: f32) void {
        self.target = target;
        const omega = 12.0 / span;
        const displacement = self.value - target;
        const c = self.velocity + omega * displacement;
        const decay = @exp(-omega * secs);
        self.value = target + (displacement + c * secs) * decay;
        self.velocity = (self.velocity - omega * c * secs) * decay;
        if (!self.active()) self.* = init(target);
    }

    pub fn active(self: Glide) bool {
        return @abs(self.value - self.target) > 0.0005 or @abs(self.velocity) > 0.005;
    }
};

/// `stage`: smoothstep of `value` across `[start, end]`.
pub fn stage(value: f32, start: f32, end: f32) f32 {
    const t = std.math.clamp((value - start) / (end - start), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// `duration(docked)`: the hand-off span (s), stretched by ZERON_MOTION_SCALE.
pub fn duration(docked: bool) f32 {
    return (if (docked) @as(f32, 0.420) else 0.470) * zt.motion.speed_scale;
}

pub const Visuals = struct {
    transcript: f32,
    selectors: f32,
    footer: f32,
    dissolve: f32,

    pub fn settled(docked: bool) Visuals {
        const v: f32 = if (docked) 1 else 0;
        return .{ .transcript = v, .selectors = 1 - v, .footer = v, .dissolve = v };
    }

    fn blend(from: f32, to: f32, time: f32, start: f32, end: f32) f32 {
        return lerp(from, to, stage(time, start, end));
    }

    pub fn advance(self: Visuals, docked: bool, time: f32) Visuals {
        const target = settled(docked);
        if (docked) return .{
            .transcript = blend(self.transcript, target.transcript, time, 0.20, 0.65),
            // The spring covers 80% of its travel at a quarter of the clock:
            // release the departing chips during travel, finish the footer
            // with the arrival.
            .selectors = blend(self.selectors, target.selectors, time, 0.0, 0.25),
            .footer = blend(self.footer, target.footer, time, 0.25, 0.55),
            .dissolve = blend(self.dissolve, target.dissolve, time, 0.06, 0.88),
        };
        // On return, release thread chrome first; unfold the hero behind the
        // rising input and restore destination selectors near arrival.
        return .{
            .transcript = blend(self.transcript, target.transcript, time, 0.0, 0.25),
            .selectors = blend(self.selectors, target.selectors, time, 0.50, 0.95),
            .footer = blend(self.footer, target.footer, time, 0.0, 0.18),
            .dissolve = blend(self.dissolve, target.dissolve, time, 0.08, 0.85),
        };
    }

    pub fn enterWithPanel(self: Visuals, time: f32) Visuals {
        // The whole composer fades through zero: keep the source controls
        // until the hidden geometry switch, then reveal the destination's.
        const controls = if (time < geometry_switch) self else settled(true);
        return .{
            .transcript = lerp(self.transcript, 1.0, stage(time, 0.26, 1.0)),
            .selectors = controls.selectors,
            .footer = controls.footer,
            .dissolve = lerp(self.dissolve, 1.0, stage(time, 0.0, 0.18)),
        };
    }

    pub fn returnFromPanel(self: Visuals, time: f32) Visuals {
        return .{
            .transcript = self.transcript * (1.0 - stage(time, 0.0, 0.18)),
            .footer = self.footer * (1.0 - stage(time, 0.0, 0.18)),
            .selectors = lerp(self.selectors, 1.0, stage(time, 0.26, 0.85)),
            .dissolve = self.dissolve * (1.0 - stage(time, 0.26, 0.80)),
        };
    }
};

pub const DockFrame = struct {
    /// Canonical position: 0 is the hero, 1 the established thread.
    amount: f32,
    docked: bool,
    active: bool,
    /// Panel hand-offs replace geometry while hidden; reduced motion snaps.
    snap_reflow: bool,
    visuals: Visuals,

    pub fn settled(docked: bool) DockFrame {
        return .{ .amount = if (docked) 1 else 0, .docked = docked, .active = false, .snap_reflow = false, .visuals = .settled(docked) };
    }

    pub fn transcript(self: DockFrame) f32 {
        return self.visuals.transcript;
    }
    pub fn selectors(self: DockFrame) f32 {
        return self.visuals.selectors;
    }
    pub fn footer(self: DockFrame) f32 {
        return self.visuals.footer;
    }
    pub fn dissolve(self: DockFrame) f32 {
        return self.visuals.dissolve;
    }
};

// ---- panel hand-off (`composer_dock/panel_handoff.rs`) ----

pub const handoff_duration: f32 = 0.320;
/// Between the fade-out ending at 0.18 and the fade-in starting at 0.26.
pub const geometry_switch: f32 = 0.22;

pub const PanelHandoff = struct {
    previous: ?struct { docked: bool, width: f32 } = null,
    started: ?u64 = null,
    from_opacity: f32 = 0,
    progress: ?f32 = null,

    pub fn opacity(self: PanelHandoff) f32 {
        const p = self.progress orelse return 1.0;
        return self.from_opacity * (1.0 - stage(p, 0.0, 0.18)) + stage(p, 0.26, 1.0);
    }

    pub fn sample(self: *PanelHandoff, docked: bool, width: f32, enabled: bool, now: u64, span: f32) bool {
        if (!enabled) {
            self.* = .{};
            return false;
        }
        if (self.previous) |prev| if (prev.docked != docked and (@abs(prev.width - width) > 0.5 or self.started != null)) {
            self.from_opacity = self.opacity();
            self.started = now;
        };
        self.previous = .{ .docked = docked, .width = width };
        self.progress = if (self.started) |start| blk: {
            const p = seconds(start, now) / span;
            break :blk if (p < 1.0) p else null;
        } else null;
        if (self.progress == null) self.started = null;
        return self.progress != null;
    }
};

// ---- the route state (`DockState`) ----

pub const DockState = struct {
    pane: PanelHandoff = .{},
    phase: Glide = .init(0),
    last_frame: ?u64 = null,
    frame: DockFrame = .settled(false),
    position: ?[2]Glide = null,
    last_geometry: ?u64 = null,
    last_docked: bool = false,
    moving: bool = false,
    width: ?Glide = null,
    last_width_frame: ?u64 = null,
    route_changed: bool = false,
    choreography: ?struct { started: u64, from: Visuals } = null,
    panel_return: bool = false,
    panel_departure: bool = false,
    column_width: ?f32 = null,
    departing_column_width: ?f32 = null,

    /// `position_at`: one step of the composer's (x, y) glide toward its
    /// route slot; sampling copies leaves the stored state untouched.
    pub fn positionAt(self: *const DockState, x: f32, y: f32, reduced: bool, now: u64) [2]Glide {
        const docked = self.frame.docked;
        const dt: f32 = if (self.last_docked != docked) 0 else if (self.last_geometry) |last| seconds(last, now) else 0;
        const moving = self.moving or self.last_docked != docked or self.frame.active;
        var position = self.position orelse [2]Glide{ .init(x), .init(y) };
        if (self.pane.progress) |progress| {
            if (progress >= geometry_switch) {
                const travel: f32 = if (docked) 12.0 else 8.0;
                position = .{ .init(x), .init(y + travel * (1.0 - stage(progress, geometry_switch, 1.0))) };
            }
        } else if (reduced or !moving) {
            position = .{ .init(x), .init(y) };
        } else {
            position[0].advance(x, dt, duration(docked));
            position[1].advance(y, dt, duration(docked));
        }
        return position;
    }

    /// Commit a prepaint's position step (`DockedComposer::prepaint`):
    /// returns the painted (x, y) and whether frames must keep coming.
    pub fn place(self: *DockState, x: f32, y: f32, reduced: bool, now: u64) struct { x: f32, y: f32, moving: bool } {
        const position = self.positionAt(x, y, reduced, now);
        self.last_geometry = now;
        self.last_docked = self.frame.docked;
        self.position = position;
        const unsettled = @abs(position[0].value - x) > 0.1 or @abs(position[1].value - y) > 0.1 or
            @abs(position[0].velocity) > 1.0 or @abs(position[1].velocity) > 1.0;
        const width_active = if (self.width) |w| w.active() else false;
        self.moving = !reduced and (unsettled or self.frame.active or width_active);
        return .{ .x = position[0].value, .y = position[1].value, .moving = self.moving };
    }

    /// `terminal_limit`: the free space below the composer's animated slot.
    pub fn terminalLimit(self: *const DockState, viewport: f32, height: f32, reserved: f32, reduced: bool, now: u64) f32 {
        const y = if (self.frame.docked) viewport - height - reserved else (viewport - height) * 0.5 + 8.0;
        const bottom = self.positionAt(0, y, reduced, now)[1].value + height;
        return @max(viewport - bottom, 0);
    }

    /// Retained transcript pixels belong to the source column: a departing
    /// transcript keeps its width through a panel hand-off.
    pub fn transcriptWidth(self: *DockState, target: f32, docked: bool, panel_handoff: bool) f32 {
        if (!docked and self.frame.docked and panel_handoff) self.departing_column_width = self.column_width;
        if (docked or !panel_handoff) self.departing_column_width = null;
        self.column_width = target;
        return self.departing_column_width orelse target;
    }

    pub fn observePane(self: *DockState, docked: bool, target: f32, enabled: bool, now: u64) bool {
        return self.pane.sample(docked, target, enabled, now, handoff_duration * zt.motion.speed_scale);
    }

    pub fn opacity(self: *const DockState) f32 {
        return self.pane.opacity();
    }

    pub fn layoutWidth(self: *DockState, target: f32, reduced: bool, now: u64) f32 {
        const dt: f32 = if (self.route_changed) 0 else if (self.last_width_frame) |last| seconds(last, now) else 0;
        self.last_width_frame = now;
        if (self.width == null) self.width = .init(target);
        const w = &self.width.?;
        if (self.pane.progress) |progress| {
            // Change horizontal geometry only inside the invisible interval.
            if (progress >= geometry_switch) w.* = .init(target);
        } else if (reduced or (!self.frame.active and !self.moving)) {
            w.* = .init(target);
        } else {
            w.advance(target, dt, duration(self.frame.docked));
        }
        return @max(w.value, 0);
    }

    pub fn tick(self: *DockState, docked: bool, reduced: bool, now: u64) DockFrame {
        self.route_changed = docked != self.frame.docked;
        if (self.route_changed or reduced) {
            self.panel_return = !reduced and !docked and self.pane.progress != null;
            self.panel_departure = !reduced and docked and self.pane.progress != null;
        }
        const target: f32 = if (docked) 1 else 0;
        if (reduced or self.last_frame == null or self.position == null) {
            self.phase = .init(target);
            self.choreography = null;
        } else {
            // A click after an idle window is the START of the new motion,
            // not elapsed animation time. Keep the last painted velocity.
            const dt: f32 = if (docked != self.frame.docked) 0 else seconds(self.last_frame.?, now);
            self.phase.advance(target, dt, duration(docked));
            // Capture the exact previous visual state on interruption.
            if (self.route_changed) self.choreography = .{ .started = now, .from = self.frame.visuals };
        }
        self.last_frame = now;
        const visuals: Visuals = if (self.choreography) |ch| blk: {
            const total = if (self.panel_return or self.panel_departure) handoff_duration * zt.motion.speed_scale else duration(docked);
            const time = seconds(ch.started, now) / total;
            if (time >= 1.0) self.choreography = null;
            break :blk if (self.panel_return) ch.from.returnFromPanel(time) else if (self.panel_departure) ch.from.enterWithPanel(time) else ch.from.advance(docked, time);
        } else .settled(docked);
        if (self.panel_return or self.panel_departure) {
            const amount = if (self.pane.progress) |p| (if (p < geometry_switch) self.frame.amount else target) else target;
            // Keep the retargetable state aligned with what was painted so a
            // reversal cannot revive the old, longer height animation.
            self.phase = .init(amount);
        }
        self.frame = .{
            .amount = std.math.clamp(self.phase.value, 0, 1),
            .docked = docked,
            .active = self.phase.active() or self.choreography != null,
            .snap_reflow = reduced or self.pane.progress != null,
            .visuals = visuals,
        };
        return self.frame;
    }
};

// ---- tests ----

const testing = std.testing;

test "glide settles critically damped and keeps velocity across a retarget" {
    var g: Glide = .init(0);
    var prev: f32 = 0;
    for (0..120) |_| {
        g.advance(100, 1.0 / 120.0, 0.42);
        try testing.expect(g.value >= prev - 1e-4 and g.value <= 100.0001);
        prev = g.value;
    }
    try testing.expect(!g.active());
    try testing.expectEqual(@as(f32, 100), g.value);
    var r: Glide = .init(0);
    r.advance(100, 0.05, 0.42);
    const v = r.velocity;
    r.advance(0, 0, 0.42);
    try testing.expectEqual(v, r.velocity);
}

test "route choreography: reduced motion snaps; a route flip starts at the old visuals" {
    var d: DockState = .{};
    const ms = std.time.ns_per_ms;
    var f = d.tick(false, false, 0);
    try testing.expect(!f.active);
    _ = d.place(0, 300, false, 0);
    f = d.tick(true, false, 16 * ms);
    try testing.expect(f.active and f.docked);
    try testing.expectEqual(@as(f32, 0), f.transcript());
    const p = d.place(0, 600, false, 16 * ms);
    try testing.expectEqual(@as(f32, 300), p.y); // dt = 0 on the flip frame
    var t: u64 = 16 * ms;
    while (t < 700 * ms) : (t += 16 * ms) {
        f = d.tick(true, false, t);
        _ = d.place(0, 600, false, t);
    }
    try testing.expect(!f.active);
    try testing.expectEqual(@as(f32, 1), f.transcript());
    var r: DockState = .{};
    _ = r.tick(false, true, 0);
    _ = r.place(0, 300, true, 0);
    f = r.tick(true, true, 16 * ms);
    try testing.expect(!f.active);
    try testing.expectEqual(@as(f32, 600), r.place(0, 600, true, 16 * ms).y);
}

test "panel hand-off hides the geometry switch" {
    var h: PanelHandoff = .{};
    const ms = std.time.ns_per_ms;
    _ = h.sample(false, 0, true, 0, 0.320);
    try testing.expect(h.sample(true, 480, true, 0, 0.320));
    try testing.expectEqual(@as(f32, 1), h.opacity());
    for ([_]u64{ 60, 70, 80 }) |m| {
        _ = h.sample(true, 480, true, m * ms, 0.320);
        try testing.expectEqual(@as(f32, 0), h.opacity());
    }
    try testing.expect(!h.sample(true, 480, true, 321 * ms, 0.320));
    try testing.expectEqual(@as(f32, 1), h.opacity());
}

test "dock parity with composer_dock.rs" {
    const data = @import("testdata/dock_parity.zig");
    // Glide trajectories.
    for (data.glides) |c| {
        var g: Glide = .init(c.start);
        for (c.steps, 0..) |step, i| {
            g.advance(step[0], step[1], c.duration);
            try testing.expectApproxEqAbs(c.values[i][0], g.value, 2e-3);
            try testing.expectApproxEqAbs(c.values[i][1], g.velocity, 2e-2);
        }
    }
    // Visual schedules.
    for (data.visuals) |c| {
        const from: Visuals = .{ .transcript = c.from[0], .selectors = c.from[1], .footer = c.from[2], .dissolve = c.from[3] };
        const v = switch (c.kind) {
            0 => from.advance(true, c.time),
            1 => from.advance(false, c.time),
            2 => from.enterWithPanel(c.time),
            else => from.returnFromPanel(c.time),
        };
        try testing.expectApproxEqAbs(c.out[0], v.transcript, 1e-5);
        try testing.expectApproxEqAbs(c.out[1], v.selectors, 1e-5);
        try testing.expectApproxEqAbs(c.out[2], v.footer, 1e-5);
        try testing.expectApproxEqAbs(c.out[3], v.dissolve, 1e-5);
    }
    // Whole-route runs: tick + position + width per frame.
    for (data.routes) |c| {
        var d: DockState = .{};
        for (c.frames) |fr| {
            const now: u64 = fr.t_ms * std.time.ns_per_ms;
            _ = d.observePane(fr.docked, fr.pane_width, true, now);
            const f = d.tick(fr.docked, false, now);
            const w = d.layoutWidth(fr.width, false, now);
            const p = d.place(fr.x, fr.y, false, now);
            try testing.expectEqual(fr.out_active, f.active);
            try testing.expectApproxEqAbs(fr.out_amount, f.amount, 2e-3);
            try testing.expectApproxEqAbs(fr.out_visuals[0], f.transcript(), 2e-3);
            try testing.expectApproxEqAbs(fr.out_visuals[1], f.selectors(), 2e-3);
            try testing.expectApproxEqAbs(fr.out_visuals[2], f.footer(), 2e-3);
            try testing.expectApproxEqAbs(fr.out_visuals[3], f.dissolve(), 2e-3);
            try testing.expectApproxEqAbs(fr.out_opacity, d.opacity(), 2e-3);
            try testing.expectApproxEqAbs(fr.out_width, w, 0.05);
            try testing.expectApproxEqAbs(fr.out_y, p.y, 0.05);
        }
    }
}
