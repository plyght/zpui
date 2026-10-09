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
    renders: u32 = 0,

    fn init(_: *Window, _: *zpui.Context(Spinner)) Spinner {
        return .{};
    }

    pub fn render(self: *Spinner, window: *Window, _: *zpui.Context(Spinner)) zpui.Div {
        self.renders += 1;
        if (self.animate) {
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
