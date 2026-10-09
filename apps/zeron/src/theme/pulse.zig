//! The pulse clock: a throttled frame source for repeating loaders and
//! cosmetic motion (zeron `motion.rs` `PulseClock`, `pulse_lease`,
//! `activity_pulse[_slow]`).
//!
//! A view that paints a spinner, a shimmer or a streaming fade calls
//! `frame(window)` (30 Hz) or `frameSlow(window)` (15 Hz) from its render
//! instead of `window.requestAnimationFrame()`. That renews a short lease; one
//! shared 33 ms timer notifies every leased view, and the clock parks once the
//! last lease lapses (a spinner that stops painting stops scheduling). A
//! display-frame request would instead redraw the whole window at the display
//! rate for as long as the loader is mounted, which is what kept a streaming
//! reply at 60/120 Hz.
//!
//! All views share one tick counter, so 30 Hz and 15 Hz leases land on the
//! same ticks and coalesce into one redraw. Phases still come from wall-clock
//! time (`loaders.phaseOf`), so the motion's period and look are unchanged;
//! only the redraw rate is bounded.

const std = @import("std");
const zpui = @import("zpui");

const App = zpui.App;
const Window = zpui.Window;
const EntityId = zpui.EntityId;
const motion = @import("motion.zig");

/// Repeat-tick interval (`PULSE_TICK`, ~30 fps).
pub const tick_ns: u64 = 33 * std.time.ns_per_ms;

/// How long a view stays on the tick list after its last paint (`PULSE_LEASE`).
pub const lease_ns: u64 = 300 * std.time.ns_per_ms;

const Lease = struct {
    until: u64,
    stride: u64,

    fn renew(self: *Lease, now: u64, stride: u64) void {
        self.until = now + lease_ns;
        self.stride = @min(self.stride, stride);
    }

    /// Each paint re-establishes the fastest mounted animation: a retired
    /// 30 Hz animation must not keep a 15 Hz loader at 30 Hz.
    fn takeTick(self: *Lease, tick: u64) bool {
        if (tick % self.stride != 0) return false;
        self.stride = std.math.maxInt(u64);
        return true;
    }
};

const State = struct {
    leases: std.AutoArrayHashMapUnmanaged(EntityId, Lease) = .empty,
    tick: u64 = 0,
    task: zpui.Task(void) = .none,
    /// Ticks that notified at least one view (tests, diagnostics).
    fired: u64 = 0,
    /// `MotionState`: activity loaders keep their subtle pulse while motion
    /// is reduced (System preference + OS setting, not paused in the
    /// background). Set by the settings layer (`ui/settings/motion.zig`
    /// `sync`); false until then, as Rust without a `MotionState`.
    reduced_activity_animates: bool = false,
};

/// App global owning the clock (heap state, so ticks mutate it without
/// notifying global observers).
const Clock = struct {
    state: *State,

    pub fn deinit(self: *Clock, app: *App) void {
        self.state.task.cancel();
        self.state.leases.deinit(app.gpa);
        app.gpa.destroy(self.state);
    }
};

fn stateOf(app: *App) ?*State {
    if (app.tryGlobal(Clock)) |c| return c.state;
    const s = app.gpa.create(State) catch return null;
    s.* = .{};
    app.setGlobal(Clock{ .state = s }) catch {
        app.gpa.destroy(s);
        return null;
    };
    return s;
}

/// Keep `view` re-rendering every `stride` pulse ticks while it keeps calling
/// this (once per paint).
pub fn lease(app: *App, view: EntityId, stride: u64) void {
    const s = stateOf(app) orelse return;
    const now = app.executor.now();
    const gop = s.leases.getOrPut(app.gpa, view) catch return;
    if (!gop.found_existing) gop.value_ptr.* = .{ .until = now + lease_ns, .stride = stride };
    gop.value_ptr.renew(now, @max(stride, 1));
    if (s.task.header == null) arm(app, s);
}

/// 30 Hz redraws for the view being rendered (`pulse_lease`, `activity_pulse`).
pub fn frame(window: *Window) void {
    lease(window.app, window.currentView(), 1);
}

/// 15 Hz redraws for the view being rendered (`activity_pulse_slow`,
/// `pulse_delta_slow`: the coarse cell loaders).
pub fn frameSlow(window: *Window) void {
    lease(window.app, window.currentView(), 2);
}

/// The settings layer reports whether activity loaders still animate (the
/// subtle pulse) while motion is reduced: `motion.activityAnimates` for the
/// current preference, OS setting and focus.
pub fn setReducedActivityAnimates(app: *App, animates: bool) void {
    const s = stateOf(app) orelse return;
    s.reduced_activity_animates = animates;
}

/// An activity loader's frame (`motion::ActivityPulse`): the travelling chase
/// at `phase` of GRADIENT_SPIN, or under reduced motion (`subtle`) a gentle
/// uniform 2.4 s brightness pulse at `phase` of ZERON_PULSE.
pub const Activity = struct {
    phase: f32 = 0,
    subtle: bool = false,

    /// `ActivityPulse::opacity`.
    pub fn opacity(self: Activity, cell_phase: f32, dim: f32) f32 {
        return motion.activityOpacity(self.phase, cell_phase, dim, self.subtle);
    }
};

/// `activity_pulse`: the chase at 30 Hz; under system reduced motion the
/// subtle pulse at 15 Hz; explicit On or a background pause hold still and
/// schedule nothing.
pub fn activity(window: *Window) Activity {
    return activityEvery(window, 1);
}

/// `activity_pulse_slow`: the coarse 3×3 matrix at 15 Hz (same rules).
pub fn activitySlow(window: *Window) Activity {
    return activityEvery(window, 2);
}

fn activityEvery(window: *Window, stride: u64) Activity {
    return activityFor(window.app, window.currentView(), window.prefersReducedMotion(), stride);
}

/// `activity_pulse_every` for a view and reduced-motion flag at hand (a
/// render with no window, or a lease taken after the rows were built).
pub fn activityFor(app: *App, view: EntityId, reduced: bool, stride: u64) Activity {
    const a = peekFor(app, reduced);
    if (a.animates) lease(app, view, if (reduced) 2 else stride);
    return a.pulse;
}

/// The frame without taking a lease (pair with `activityFor` / `activity`).
pub fn peek(window: *Window) Activity {
    return peekFor(window.app, window.prefersReducedMotion()).pulse;
}

fn peekFor(app: *App, subtle: bool) struct { pulse: Activity, animates: bool } {
    const animate = !subtle or (if (app.tryGlobal(Clock)) |c| c.state.reduced_activity_animates else false);
    if (!animate) return .{ .pulse = .{ .subtle = subtle }, .animates = false };
    return .{ .pulse = .{ .phase = phaseAt(app.executor.now(), if (subtle) motion.zeron_pulse else motion.gradient_spin), .subtle = subtle }, .animates = true };
}

/// `pulse_phase`: 0..1 of a loop's period at `now_ns` (loops are not scaled).
pub fn phaseAt(now_ns: u64, spec: motion.MotionSpec) f32 {
    const period: u64 = (spec.delay_ms + spec.duration_ms) * std.time.ns_per_ms;
    if (period == 0) return 0;
    return @as(f32, @floatFromInt(now_ns % period)) / @as(f32, @floatFromInt(period));
}

/// Whether the clock is scheduled (tests).
pub fn running(app: *App) bool {
    const c = app.tryGlobal(Clock) orelse return false;
    return c.state.task.header != null;
}

/// Ticks that notified a view so far (tests).
pub fn firedTicks(app: *App) u64 {
    const c = app.tryGlobal(Clock) orelse return 0;
    return c.state.fired;
}

fn arm(app: *App, s: *State) void {
    s.task = app.foregroundExecutor().timer(tick_ns, Tick{ .app = app }) catch .none;
}

const Tick = struct {
    app: *App,

    pub fn finish(self: *Tick) void {
        const app = self.app;
        const c = app.tryGlobal(Clock) orelse return;
        const s = c.state;
        s.task.detach();
        s.task = .none;
        const now = app.executor.now();
        var i: usize = 0;
        while (i < s.leases.count()) {
            if (s.leases.values()[i].until > now) i += 1 else s.leases.swapRemoveAt(i);
        }
        if (s.leases.count() == 0) return; // parked until the next lease
        s.tick +%= 1;
        var due: std.ArrayList(EntityId) = .empty;
        defer due.deinit(app.gpa);
        for (s.leases.keys(), s.leases.values()) |view, *l| {
            if (l.takeTick(s.tick)) due.append(app.gpa, view) catch {};
        }
        arm(app, s);
        if (due.items.len == 0) return;
        s.fired += 1;
        app.startUpdate();
        defer app.finishUpdate();
        for (due.items) |view| app.notify(view);
    }
};

// ---- Tests ----

const testing = std.testing;

const Spinner = struct {
    animate: bool = true,
    slow: bool = false,
    activity_loader: bool = false,
    last: Activity = .{},
    renders: u32 = 0,

    fn init(_: *Window, _: *zpui.Context(Spinner)) Spinner {
        return .{};
    }

    pub fn render(self: *Spinner, window: *Window, _: *zpui.Context(Spinner)) zpui.Div {
        self.renders += 1;
        if (self.activity_loader) {
            self.last = activity(window);
        } else if (self.animate) {
            if (self.slow) frameSlow(window) else frame(window);
        }
        return zpui.div().size(zpui.px(40)).bg(zpui.color.white);
    }
};

const vsync_ns: u64 = 16_666_667;

/// Drive `n` display refreshes on the headless platform; returns the draws.
fn vsyncs(app: *App, w: *Window, n: usize) usize {
    const tw = zpui.core.test_platform.TestWindow.of(w.platform_window);
    const before = tw.present_count;
    for (0..n) |_| {
        app.advanceClock(vsync_ns);
        if (tw.frame_requested) tw.frame(false);
    }
    return tw.present_count - before;
}

test "a mounted loader redraws at the pulse cadence, not every vsync" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 100, .height = 100 } } }, Spinner, Spinner.init, .{});
    const w = handle.window(app).?;
    app.runUntilParked();
    try testing.expect(running(app));
    // 2 s at 60 Hz: ~60 redraws at 30 Hz (a display-frame request: 120).
    const draws = vsyncs(app, w, 120);
    try testing.expect(draws >= 55 and draws <= 62);
}

test "slow leases redraw at 15 Hz and coalesce with 30 Hz ones" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 100, .height = 100 } } }, Spinner, Spinner.init, .{});
    const w = handle.window(app).?;
    const Set = struct {
        fn slow(s: *Spinner, cx: *zpui.Context(Spinner)) void {
            s.slow = true;
            cx.notify();
        }
    };
    handle.rootView(app).?.update(app, Set.slow, .{});
    _ = vsyncs(app, w, 6);
    const draws = vsyncs(app, w, 120);
    try testing.expect(draws >= 28 and draws <= 32);
}

test "the clock parks once the loader stops painting" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 100, .height = 100 } } }, Spinner, Spinner.init, .{});
    const w = handle.window(app).?;
    _ = vsyncs(app, w, 10);
    const Set = struct {
        fn stop(s: *Spinner, cx: *zpui.Context(Spinner)) void {
            s.animate = false;
            cx.notify();
        }
    };
    handle.rootView(app).?.update(app, Set.stop, .{});
    _ = vsyncs(app, w, 30); // the lease (300 ms) lapses
    try testing.expect(!running(app));
    try testing.expectEqual(@as(usize, 0), vsyncs(app, w, 60));
}

fn activityHarness(reduced: bool, animates_reduced: bool) !struct { draws: usize, subtle: bool, phases_moved: bool, opacity: f32 } {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 100, .height = 100 } } }, Spinner, Spinner.init, .{});
    const w = handle.window(app).?;
    w.prefers_reduced_motion = reduced;
    setReducedActivityAnimates(app, animates_reduced);
    const Set = struct {
        fn on(sp: *Spinner, cx: *zpui.Context(Spinner)) void {
            sp.activity_loader = true;
            cx.notify();
        }
    };
    handle.rootView(app).?.update(app, Set.on, .{});
    _ = vsyncs(app, w, 6);
    const first = handle.rootView(app).?.read(app).last;
    const draws = vsyncs(app, w, 120);
    const last = handle.rootView(app).?.read(app).last;
    return .{ .draws = draws, .subtle = last.subtle, .phases_moved = first.phase != last.phase, .opacity = last.opacity(0.5, motion.gspin_dim) };
}

test "activity loaders: chase at 30 Hz with motion" {
    const r = try activityHarness(false, false);
    try testing.expect(!r.subtle);
    try testing.expect(r.phases_moved);
    try testing.expect(r.draws >= 55 and r.draws <= 62);
}

test "activity loaders: subtle 2.4 s pulse at 15 Hz under system reduced motion" {
    const r = try activityHarness(true, true);
    try testing.expect(r.subtle);
    try testing.expect(r.phases_moved);
    try testing.expect(r.draws >= 28 and r.draws <= 32);
    // A uniform brightness pulse between 0.6 and 0.8, whatever the cell.
    try testing.expect(r.opacity >= 0.6 and r.opacity <= 0.8);
    try testing.expectApproxEqAbs(@as(f32, 0.7), (Activity{ .phase = 0.25, .subtle = true }).opacity(0.9, motion.gspin_dim), 1e-5);
}

test "activity loaders: explicit On / background pause hold still, no frames" {
    const r = try activityHarness(true, false);
    try testing.expect(r.subtle);
    try testing.expect(!r.phases_moved);
    try testing.expectEqual(@as(usize, 0), r.draws);
    try testing.expectApproxEqAbs(@as(f32, 0.6), r.opacity, 1e-6);
}
