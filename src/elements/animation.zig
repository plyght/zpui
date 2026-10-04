//! Animations (gpui `elements/animation.rs`): `withAnimation` wraps an element and rebuilds
//! it every frame from an eased progress value, requesting animation frames until done.
//!
//! ```zig
//! const anim = zpui.Animation.ms(500).withEasing(zpui.easing.ease_out_expo);
//! zpui.withAnimation(card, "card-in", anim, struct {
//!     fn f(el: zpui.Div, t: f32) zpui.Div {
//!         return el.opacity(t).top(px(4 * (1 - t)));      // fade + slide up
//!     }
//! }.f)
//! // or chained on divs: div().id("x").withAnimation("pulse", Animation.ms(1200).repeat()
//! //     .withEasing(zpui.easing.pulsatingBetween(0.4, 1)), Self.pulse)
//! // with captured data:  zpui.withAnimationCtx(el, id, anim, color, fn (Hsla, Div, f32) Div)
//! // chains:              zpui.withAnimations(el, id, &.{ a, b }, fn (Div, usize, f32) Div)
//! ```
//!
//! Progress starts the first frame the element (by its id) is drawn and persists while it
//! keeps being drawn. Under reduced motion (`window.prefersReducedMotion()`) oneshot
//! animations render their end state and repeating ones their start state, with no frames
//! scheduled. Also here: easing functions (gpui's set plus an exact CSS `cubic-bezier`),
//! `Tween` and `Spring` helpers for hand-driven motion (scroll glides, springs).

const std = @import("std");
const App = @import("../app/app.zig").App;
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const element = @import("../window/element.zig");
const AnyElement = element.AnyElement;
const ElementId = element.ElementId;
const GlobalElementId = element.GlobalElementId;
const LayoutId = element.LayoutId;
const geometry = @import("../geometry.zig");
const arena_mod = @import("../window/arena.zig");

const Bounds = geometry.Bounds(geometry.Pixels);

pub const ns_per_ms: u64 = 1_000_000;

// ---------------------------------------------------------------------------------------
// Easing
// ---------------------------------------------------------------------------------------

/// A CSS `cubic-bezier(x1, y1, x2, y2)` timing function (endpoints (0,0) and (1,1)), solved
/// exactly like browsers do (Newton iterations with a bisection fallback).
pub const CubicBezier = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub fn init(x1: f32, y1: f32, x2: f32, y2: f32) CubicBezier {
        return .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 };
    }

    fn coeff(a: f32, b: f32) [3]f32 {
        const c = 3.0 * a;
        const bb = 3.0 * (b - a) - c;
        return .{ 1.0 - c - bb, bb, c };
    }

    fn sampleX(self: CubicBezier, t: f32) f32 {
        const k = coeff(self.x1, self.x2);
        return ((k[0] * t + k[1]) * t + k[2]) * t;
    }

    fn sampleY(self: CubicBezier, t: f32) f32 {
        const k = coeff(self.y1, self.y2);
        return ((k[0] * t + k[1]) * t + k[2]) * t;
    }

    fn sampleDX(self: CubicBezier, t: f32) f32 {
        const k = coeff(self.x1, self.x2);
        return (3.0 * k[0] * t + 2.0 * k[1]) * t + k[2];
    }

    fn solveT(self: CubicBezier, x: f32) f32 {
        var t = x;
        for (0..8) |_| {
            const err = self.sampleX(t) - x;
            if (@abs(err) < 1e-6) return t;
            const d = self.sampleDX(t);
            if (@abs(d) < 1e-6) break;
            t -= err / d;
        }
        var lo: f32 = 0;
        var hi: f32 = 1;
        t = x;
        for (0..40) |_| {
            const v = self.sampleX(t);
            if (@abs(v - x) < 1e-7) return t;
            if (v < x) lo = t else hi = t;
            t = (lo + hi) / 2;
        }
        return t;
    }

    /// Eased value for progress `x` (input and output clamped to 0..1).
    pub fn eval(self: CubicBezier, x: f32) f32 {
        if (x <= 0) return 0;
        if (x >= 1) return 1;
        return std.math.clamp(self.sampleY(self.solveT(x)), 0, 1);
    }
};

/// An easing function: maps linear progress 0..1 to eased progress 0..1 (gpui passes
/// `Rc<dyn Fn(f32) -> f32>`; Zig has no closures, so the parameterized easings are data).
pub const Easing = union(enum) {
    linear,
    quadratic,
    ease_in_out,
    ease_out_quint,
    cubic_bezier: CubicBezier,
    pulsating_between: struct { min: f32, max: f32 },
    /// Apply the easing forward over the first half and in reverse over the second.
    bounce: *const Easing,
    custom: *const fn (f32) f32,

    pub fn apply(self: Easing, t: f32) f32 {
        return switch (self) {
            .linear => t,
            .quadratic => t * t,
            .ease_in_out => if (t < 0.5) 2 * t * t else blk: {
                const x = -2 * t + 2;
                break :blk 1 - x * x / 2;
            },
            .ease_out_quint => 1 - std.math.pow(f32, 1 - t, 5),
            .cubic_bezier => |b| b.eval(t),
            .pulsating_between => |p| blk: {
                // Sine/cubic mix for a natural breathing rhythm (gpui `pulsating_between`).
                const s = @sin(t * 2 * std.math.pi);
                const breath = (s * s * s + s) / 2;
                break :blk p.min + (breath + 1) / 2 * (p.max - p.min);
            },
            .bounce => |e| if (t < 0.5) e.apply(t * 2) else e.apply((1 - t) * 2),
            .custom => |f| f(t),
        };
    }
};

/// Easing constructors and CSS presets.
pub const easing = struct {
    pub const linear: Easing = .linear;
    pub const quadratic: Easing = .quadratic;
    /// Quadratic ease-in-out (gpui `ease_in_out`).
    pub const ease_in_out: Easing = .ease_in_out;
    /// gpui `ease_out_quint()`.
    pub const ease_out_quint: Easing = .ease_out_quint;
    /// CSS `ease`.
    pub const ease: Easing = cubicBezier(0.25, 0.1, 0.25, 1.0);
    pub const css_ease_in: Easing = cubicBezier(0.42, 0, 1, 1);
    pub const css_ease_out: Easing = cubicBezier(0, 0, 0.58, 1);
    pub const css_ease_in_out: Easing = cubicBezier(0.42, 0, 0.58, 1);
    /// `cubic-bezier(0.16, 1, 0.3, 1)` (entrances).
    pub const ease_out_expo: Easing = cubicBezier(0.16, 1, 0.3, 1);
    /// Tailwind's default transition curve `cubic-bezier(0.4, 0, 0.2, 1)`.
    pub const standard: Easing = cubicBezier(0.4, 0, 0.2, 1);

    pub fn cubicBezier(x1: f32, y1: f32, x2: f32, y2: f32) Easing {
        return .{ .cubic_bezier = .init(x1, y1, x2, y2) };
    }

    /// gpui `pulsating_between(min, max)`.
    pub fn pulsatingBetween(min: f32, max: f32) Easing {
        return .{ .pulsating_between = .{ .min = min, .max = max } };
    }

    /// gpui `bounce(easing)` for a comptime-known inner easing.
    pub fn bounce(comptime inner: Easing) Easing {
        return .{ .bounce = &struct {
            const v = inner;
        }.v };
    }

    /// `bounce` over an easing that outlives the animation.
    pub fn bounceOf(inner: *const Easing) Easing {
        return .{ .bounce = inner };
    }

    pub fn custom(f: *const fn (f32) f32) Easing {
        return .{ .custom = f };
    }
};

// ---------------------------------------------------------------------------------------
// Animation
// ---------------------------------------------------------------------------------------

/// An animation description (gpui `Animation`).
pub const Animation = struct {
    duration_ns: u64,
    /// Run once (true) or loop (false).
    oneshot: bool = true,
    easing: Easing = .linear,

    pub fn init(duration_ns: u64) Animation {
        return .{ .duration_ns = duration_ns };
    }

    pub fn ms(millis: u64) Animation {
        return .{ .duration_ns = millis * ns_per_ms };
    }

    /// Loop when finished.
    pub fn repeat(self: Animation) Animation {
        var a = self;
        a.oneshot = false;
        return a;
    }

    pub fn withEasing(self: Animation, e: Easing) Animation {
        var a = self;
        a.easing = e;
        return a;
    }
};

const AnimationState = struct {
    start_ns: ?u64 = null,
    animation_ix: usize = 0,
};

/// Progress of an animation chain at `elapsed_ns` since its start: (index, eased delta,
/// done, new start offset). Pure; used by the element and exposed for custom tweens.
pub const Progress = struct { ix: usize, delta: f32, done: bool };

fn advance(state: *AnimationState, animations: []const Animation, now: u64, reduced: bool) Progress {
    if (reduced) {
        const ix = animations.len - 1;
        const raw: f32 = if (animations[ix].oneshot) 1 else 0;
        return .{ .ix = ix, .delta = animations[ix].easing.apply(raw), .done = true };
    }
    const start = state.start_ns orelse now;
    state.start_ns = start;
    const ix = state.animation_ix;
    const a = animations[ix];
    const elapsed: f64 = @floatFromInt(now -| start);
    const dur: f64 = @floatFromInt(@max(a.duration_ns, 1));
    var delta: f32 = @floatCast(elapsed / dur);
    var done = false;
    if (delta > 1) {
        if (a.oneshot) {
            if (ix >= animations.len - 1) {
                done = true;
            } else {
                state.start_ns = now;
                state.animation_ix += 1;
            }
            delta = 1;
        } else {
            delta = @mod(delta, 1);
        }
    }
    return .{ .ix = ix, .delta = a.easing.apply(delta), .done = done };
}

/// The element produced by `withAnimation` & co. `animator` is called with `(ctx,)`
/// `element`, `(index,)` and the eased delta, depending on `kind`.
pub fn AnimationElement(comptime E: type, comptime Ctx: type, comptime kind: enum { simple, ctx, chain }, comptime animator: anytype) type {
    return struct {
        const Self = @This();
        id: ElementId,
        element: E,
        animations: []const Animation,
        ctx: Ctx,

        /// Add a child to the animated element (gpui `ParentElement for AnimationElement`).
        pub fn child(self: Self, c: anytype) Self {
            var s = self;
            s.element = s.element.child(c);
            return s;
        }

        /// Transform the wrapped element (gpui `map_element`).
        pub fn mapElement(self: Self, comptime f: fn (E) E) Self {
            var s = self;
            s.element = f(s.element);
            return s;
        }

        pub fn intoAnyElement(self: Self) AnyElement {
            return AnyElement.new(Impl{ .a = self });
        }

        const Impl = struct {
            a: Self,
            pub const RequestLayoutState = AnyElement;

            pub fn elementId(self: *Impl) ?ElementId {
                return self.a.id;
            }

            pub fn requestLayout(self: *Impl, gid: ?GlobalElementId, rl: *AnyElement, window: *Window, cx: *App) LayoutId {
                const st = window.elementState(AnimationState, gid.?);
                const p = advance(st, self.a.animations, cx.executor.now(), window.prefersReducedMotion());
                std.debug.assert(p.delta >= -0.0001 and p.delta <= 1.0001);
                const el = switch (kind) {
                    .simple => element.intoAnyElement(animator(self.a.element, p.delta)),
                    .ctx => element.intoAnyElement(animator(self.a.ctx, self.a.element, p.delta)),
                    .chain => element.intoAnyElement(animator(self.a.element, p.ix, p.delta)),
                };
                if (!p.done) window.requestAnimationFrame();
                rl.* = el;
                return el.requestLayout(window, cx);
            }

            pub fn prepaint(_: *Impl, _: ?GlobalElementId, _: Bounds, rl: *AnyElement, _: *void, window: *Window, cx: *App) void {
                rl.prepaint(window, cx);
            }

            pub fn paint(_: *Impl, _: ?GlobalElementId, _: Bounds, rl: *AnyElement, _: *void, window: *Window, cx: *App) void {
                rl.paint(window, cx);
            }
        };
    };
}

fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

/// Animate `el` (gpui `AnimationExt::with_animation`): `animator(el, delta) R` rebuilds the
/// element each frame from the eased delta in 0..1. `id` identifies the animation state.
pub fn withAnimation(el: anytype, id: anytype, animation: Animation, comptime animator: anytype) AnimationElement(@TypeOf(el), void, .simple, animator) {
    return .{ .id = ElementId.from(id), .element = el, .animations = dupeAnimations(&.{animation}), .ctx = {} };
}

/// `withAnimation` with captured data: `animator(ctx, el, delta) R`.
pub fn withAnimationCtx(el: anytype, id: anytype, animation: Animation, ctx: anytype, comptime animator: anytype) AnimationElement(@TypeOf(el), @TypeOf(ctx), .ctx, animator) {
    return .{ .id = ElementId.from(id), .element = el, .animations = dupeAnimations(&.{animation}), .ctx = ctx };
}

/// A chain of animations run one after another (gpui `with_animations`):
/// `animator(el, animation_index, delta) R`. Repeating animations loop in place.
pub fn withAnimations(el: anytype, id: anytype, animations: []const Animation, comptime animator: anytype) AnimationElement(@TypeOf(el), void, .chain, animator) {
    std.debug.assert(animations.len > 0);
    return .{ .id = ElementId.from(id), .element = el, .animations = dupeAnimations(animations), .ctx = {} };
}

fn dupeAnimations(a: []const Animation) []const Animation {
    return arena_mod.frameAllocator().dupe(Animation, a) catch @panic("OOM");
}

/// Methods for element builders (`pub const withAnimation = animation.Ext(Self).withAnimation;`).
pub fn Ext(comptime Self: type) type {
    return struct {
        pub fn withAnimation(self: Self, id: anytype, animation: Animation, comptime animator: anytype) AnimationElement(Self, void, .simple, animator) {
            return @import("animation.zig").withAnimation(self, id, animation, animator);
        }
        pub fn withAnimationCtx(self: Self, id: anytype, animation: Animation, ctx: anytype, comptime animator: anytype) AnimationElement(Self, @TypeOf(ctx), .ctx, animator) {
            return @import("animation.zig").withAnimationCtx(self, id, animation, ctx, animator);
        }
        pub fn withAnimations(self: Self, id: anytype, animations: []const Animation, comptime animator: anytype) AnimationElement(Self, void, .chain, animator) {
            return @import("animation.zig").withAnimations(self, id, animations, animator);
        }
    };
}

// ---------------------------------------------------------------------------------------
// Hand-driven motion
// ---------------------------------------------------------------------------------------

/// A time-based interpolation from `from` to `to` (scroll glides, width transitions).
/// Call `sample(now)` each frame and `window.requestAnimationFrame()` while `!done(now)`.
pub const Tween = struct {
    from: f32,
    to: f32,
    start_ns: u64,
    duration_ns: u64,
    easing: Easing = .linear,

    pub fn progress(self: Tween, now: u64) f32 {
        if (self.duration_ns == 0) return 1;
        const e: f64 = @floatFromInt(now -| self.start_ns);
        return @floatCast(@min(e / @as(f64, @floatFromInt(self.duration_ns)), 1));
    }

    pub fn sample(self: Tween, now: u64) f32 {
        const t = self.easing.apply(self.progress(now));
        return self.from + (self.to - self.from) * t;
    }

    pub fn done(self: Tween, now: u64) bool {
        return self.progress(now) >= 1;
    }
};

/// A damped spring stepped per frame (zeron's transcript scroll spring uses
/// damping 0.7, stiffness 0.05, mass 1.25 at 60 fps).
pub const Spring = struct {
    stiffness: f32 = 0.05,
    damping: f32 = 0.7,
    mass: f32 = 1.25,
    value: f32 = 0,
    velocity: f32 = 0,
    target: f32 = 0,
    /// Considered at rest when both |target - value| and |velocity| are below this.
    rest_threshold: f32 = 0.5,

    /// Advance by `frames` 60 Hz frames (fractional allowed); returns true when at rest
    /// (the value then snaps to the target).
    pub fn step(self: *Spring, frames: f32) bool {
        var remaining = frames;
        while (remaining > 0) {
            const dt = @min(remaining, 1);
            const force = (self.target - self.value) * self.stiffness;
            const accel = force / self.mass;
            self.velocity = (self.velocity + accel * dt) * std.math.pow(f32, self.damping, dt);
            self.value += self.velocity * dt;
            remaining -= dt;
        }
        if (self.isAtRest()) {
            self.value = self.target;
            self.velocity = 0;
            return true;
        }
        return false;
    }

    pub fn isAtRest(self: Spring) bool {
        return @abs(self.target - self.value) < self.rest_threshold and @abs(self.velocity) < self.rest_threshold;
    }
};

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

test "easing functions" {
    const t = std.testing;
    try t.expectEqual(@as(f32, 0.25), easing.quadratic.apply(0.5));
    try t.expectEqual(@as(f32, 0.5), easing.ease_in_out.apply(0.5));
    try t.expectApproxEqAbs(@as(f32, 1 - 0.03125), easing.ease_out_quint.apply(0.5), 1e-6);
    const b = easing.bounce(.linear);
    try t.expectApproxEqAbs(@as(f32, 0.5), b.apply(0.25), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 1.0), b.apply(0.5), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.5), b.apply(0.75), 1e-6);
    const p = easing.pulsatingBetween(0.4, 0.8);
    try t.expectApproxEqAbs(@as(f32, 0.6), p.apply(0), 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.8), p.apply(0.25), 1e-6);
    // CSS `ease` at 0.5 ≈ 0.8024 (browser reference value).
    try t.expectApproxEqAbs(@as(f32, 0.8024), easing.ease.apply(0.5), 1e-3);
    try t.expectApproxEqAbs(@as(f32, 0.5), easing.css_ease_in_out.apply(0.5), 1e-4);
    try t.expectEqual(@as(f32, 0), easing.ease_out_expo.apply(0));
    try t.expectEqual(@as(f32, 1), easing.ease_out_expo.apply(1));
    // Monotonic.
    var prev: f32 = 0;
    for (0..101) |i| {
        const v = easing.ease_out_expo.apply(@as(f32, @floatFromInt(i)) / 100);
        try t.expect(v >= prev - 1e-6);
        prev = v;
    }
}

test "animation progress: oneshot chains, repeat, reduced motion" {
    const t = std.testing;
    const chain = [_]Animation{ .ms(100), .ms(200) };
    var st: AnimationState = .{};
    var p = advance(&st, &chain, 1000 * ns_per_ms, false);
    try t.expectEqual(@as(usize, 0), p.ix);
    try t.expectEqual(@as(f32, 0), p.delta);
    p = advance(&st, &chain, 1050 * ns_per_ms, false);
    try t.expectApproxEqAbs(@as(f32, 0.5), p.delta, 1e-6);
    p = advance(&st, &chain, 1150 * ns_per_ms, false); // past the first: next starts now
    try t.expectEqual(@as(usize, 0), p.ix);
    try t.expectEqual(@as(f32, 1), p.delta);
    try t.expect(!p.done);
    p = advance(&st, &chain, 1250 * ns_per_ms, false);
    try t.expectEqual(@as(usize, 1), p.ix);
    try t.expectApproxEqAbs(@as(f32, 0.5), p.delta, 1e-6);
    p = advance(&st, &chain, 1400 * ns_per_ms, false);
    try t.expect(p.done);
    try t.expectEqual(@as(f32, 1), p.delta);

    const rep = [_]Animation{Animation.ms(100).repeat()};
    var rs: AnimationState = .{};
    _ = advance(&rs, &rep, 0, false);
    p = advance(&rs, &rep, 250 * ns_per_ms, false);
    try t.expectApproxEqAbs(@as(f32, 0.5), p.delta, 1e-4);
    try t.expect(!p.done);

    var red: AnimationState = .{};
    p = advance(&red, &chain, 0, true);
    try t.expect(p.done);
    try t.expectEqual(@as(f32, 1), p.delta);
    p = advance(&red, &rep, 0, true);
    try t.expectEqual(@as(f32, 0), p.delta);
}

test "tween and spring" {
    const t = std.testing;
    const tw: Tween = .{ .from = 0, .to = 100, .start_ns = 0, .duration_ns = 500 * ns_per_ms, .easing = easing.css_ease_in_out };
    try t.expectApproxEqAbs(@as(f32, 50), tw.sample(250 * ns_per_ms), 0.01);
    try t.expect(tw.done(600 * ns_per_ms));
    var s: Spring = .{ .target = 300 };
    var frames: usize = 0;
    while (!s.step(1)) : (frames += 1) if (frames > 1000) return error.SpringDidNotSettle;
    try t.expectEqual(@as(f32, 300), s.value);
}
