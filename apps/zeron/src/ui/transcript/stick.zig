//! The transcript's scroll motion (zeron `transcript.rs`): the
//! stick-to-bottom spring (`StickSpring`, mugen's DEFAULT_SPRING) and the
//! sent-prompt glide constants (`OWN_SEND_*`). Pure; `view.zig` drives them
//! once per frame. Parity-tested against `scripts/stick_parity.rs`.

const std = @import("std");

/// Retains velocity frame-to-frame (higher = more glide).
pub const damping: f32 = 0.7;
/// Pull toward the target (higher = snappier).
pub const stiffness: f32 = 0.05;
/// Inertia (higher = slower to start/stop).
pub const mass: f32 = 1.25;
/// Reference frame for the fixed-timestep integration (60fps), ms.
pub const frame_ms: f32 = 1000.0 / 60.0;
/// Cap on simulated frames per tick: a hitch catches up instead of teleporting.
pub const max_catchup_frames: f32 = 8.0;
/// EMA rate for the feed-forward target-growth estimate.
pub const growth_ema: f32 = 0.12;
/// While streaming, chase up to this many px above the true bottom.
pub const chase_max_lead: f32 = 32.0;
/// Treat as exactly pinned within this distance of the bottom.
pub const at_bottom_px: f32 = 2.0;
/// Retain the spring's state this long after landing (a pause resumes at cruise).
pub const settle_grace_ms: u64 = 500;
/// Teleport when farther than this many viewports from the end; glide the rest.
pub const glide_max_viewports: f32 = 2.5;
/// Extra height under the own-turn reservation (keeps the held layout out of
/// the shorter-than-viewport regime; below perception).
pub const own_send_scroll_slack_px: f32 = 2.0;
/// Per-60fps-frame fraction of the remaining entry glide retained (~90%
/// covered in ~230 ms, ease-out).
pub const own_send_glide_retain: f32 = 0.85;
/// The entry glide snaps to the absolute hold within this error.
pub const own_send_glide_snap_px: f32 = 1.0;

/// 60fps frames since `last` (1 on the first tick), capped for hitches.
pub fn framesSince(last: ?u64, now: u64) f32 {
    const l = last orelse return 1;
    const ms = @as(f32, @floatFromInt(now -| l)) / @as(f32, @floatFromInt(std.time.ns_per_ms));
    return @min(ms / frame_ms, max_catchup_frames);
}

/// `1 - RETAIN^frames`: the share of the remaining glide covered this tick.
pub fn glideEase(frames: f32) f32 {
    return 1 - std.math.pow(f32, own_send_glide_retain, frames);
}

/// Pure stick-to-bottom stepper (mugen `tick()`): velocity relaxes toward
/// `(damping·v + stiffness·diff)/mass` per 60fps sub-frame, position
/// advances by `v + target_vel` where `target_vel` is a feed-forward EMA of
/// target growth, and the chase point leads the bottom by up to 32 px.
pub const StickSpring = struct {
    velocity: f32 = 0,
    target_vel: f32 = 0,
    last_target: ?f32 = null,

    pub fn reset(self: *StickSpring) void {
        self.* = .{};
    }

    pub fn isIdle(self: StickSpring) bool {
        return self.velocity < 0.05 and self.target_vel < 0.05;
    }

    /// The spring is clamped to the target: residual velocity cannot move a
    /// viewport already there.
    pub fn needsFrame(distance: f32) bool {
        return distance > 0.5;
    }

    /// Advance one tick (`pos`/`target` in px, larger = closer to the
    /// bottom; `frames` in 60fps frames). Never overshoots `target`, and
    /// snaps exactly once within 0.5 px.
    pub fn step(self: *StickSpring, pos_in: f32, target: f32, frames_in: f32) f32 {
        var pos = pos_in;
        var frames = frames_in;
        const grew: f32 = if (self.last_target) |last| target - last else 0;
        self.last_target = target;
        if (grew < -1.0) {
            // Target shrank (row collapse/removal): growth estimate is stale.
            self.target_vel = 0;
        } else {
            const observed = @max(grew, 0) / @max(frames, 0.25);
            self.target_vel += growth_ema * (observed - self.target_vel);
        }
        const chase = target - @min(self.target_vel * 9.0, chase_max_lead);
        var v = self.velocity;
        while (frames > 0) {
            const h = @min(frames, 1.0);
            frames -= h;
            const diff = @max(chase - pos, 0);
            v += h * ((damping * v + stiffness * diff) / mass - v);
            pos = @min(pos + (v + self.target_vel) * h, target);
        }
        self.velocity = v;
        return if (target - pos <= 0.5) target else pos;
    }
};

test "stick spring parity with transcript.rs" {
    const data = @import("testdata/stick_parity.zig");
    for (data.cases) |c| {
        var s: StickSpring = .{};
        for (c.steps) |st| try std.testing.expectApproxEqAbs(st.out, s.step(st.pos, st.target, st.frames), 1e-2);
    }
}

test "spring never overshoots and lands exactly" {
    var s: StickSpring = .{};
    var pos: f32 = 0;
    var n: usize = 0;
    while (pos < 500) : (n += 1) {
        const next = s.step(pos, 500, 1);
        try std.testing.expect(next >= pos and next <= 500);
        pos = next;
        if (n > 1000) return error.NoLanding;
    }
    try std.testing.expectEqual(@as(f32, 500), pos);
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), glideEase(1), 1e-6);
}
