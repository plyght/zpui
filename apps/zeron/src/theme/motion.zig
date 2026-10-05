//! zeron's motion catalog (port of `crates/ui/src/motion.rs` and the pure
//! loader math in `crates/proto/src/motion.rs`): CSS cubic-bezier easing,
//! named durations, hover color fades and reduced-motion resolution.
//!
//! Everything here is pure: callers feed elapsed time / raw progress and get
//! eased values back. Under reduced motion, oneshot animations snap to their
//! end state and repeating ones rest at phase 0 (`MotionSpec.progressReduced`,
//! `HoverFades.set` with `reduced = true`).

const std = @import("std");
const zpui = @import("zpui");

const Hsla = zpui.Hsla;
const Rgba = zpui.Rgba;

/// Dev/measurement knob `ZERON_MOTION_SCALE` (`motion::speed_scale`, default
/// 1): stretches every catalog timeline (`MotionSpec.totalNs`, `animation`,
/// hover fades, the hand-driven tweens) by this factor. Set once at startup
/// from the environment (`parseSpeedScale`); never changed in production.
pub var speed_scale: f32 = 1.0;

/// Seconds/nanoseconds helper for hand-driven tweens with their own spans:
/// `span_ns` stretched by `speed_scale`.
pub fn scaledNs(span_ns: u64) u64 {
    return @intFromFloat(@as(f64, @floatFromInt(span_ns)) * speed_scale);
}

/// A CSS `cubic-bezier(x1, y1, x2, y2)` timing function with endpoints fixed
/// at (0,0) and (1,1). Solves x(t) = input by Newton iteration with a bisection
/// fallback (the standard UnitBezier approach).
pub const CubicBezier = struct {
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,

    pub fn init(x1: f32, y1: f32, x2: f32, y2: f32) CubicBezier {
        return .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2 };
    }

    fn coefficients(a: f32, b: f32) [3]f32 {
        const c = 3.0 * a;
        const bb = 3.0 * (b - a) - c;
        return .{ 1.0 - c - bb, bb, c };
    }

    fn sampleX(self: CubicBezier, t: f32) f32 {
        const k = coefficients(self.x1, self.x2);
        return ((k[0] * t + k[1]) * t + k[2]) * t;
    }

    fn sampleY(self: CubicBezier, t: f32) f32 {
        const k = coefficients(self.y1, self.y2);
        return ((k[0] * t + k[1]) * t + k[2]) * t;
    }

    fn sampleXDerivative(self: CubicBezier, t: f32) f32 {
        const k = coefficients(self.x1, self.x2);
        return (3.0 * k[0] * t + 2.0 * k[1]) * t + k[2];
    }

    /// Curve parameter `t` for progress `x` (both 0..1).
    fn solveTForX(self: CubicBezier, x: f32) f32 {
        var t = x;
        for (0..8) |_| {
            const err = self.sampleX(t) - x;
            if (@abs(err) < 1e-6) return t;
            const d = self.sampleXDerivative(t);
            if (@abs(d) < 1e-6) break;
            t -= err / d;
        }
        var lo: f32 = 0;
        var hi: f32 = 1;
        for (0..32) |_| {
            const mid = (lo + hi) / 2.0;
            if (self.sampleX(mid) < x) lo = mid else hi = mid;
        }
        return (lo + hi) / 2.0;
    }

    /// Eased output for input progress `x` (clamped to 0..1, output too).
    pub fn eval(self: CubicBezier, x: f32) f32 {
        if (x <= 0.0) return 0.0;
        if (x >= 1.0) return 1.0;
        return std.math.clamp(self.sampleY(self.solveTForX(x)), 0.0, 1.0);
    }
};

/// zeron's signature entrance curve, `cubic-bezier(0.16, 1, 0.3, 1)`.
pub const ease_out_expo: CubicBezier = .init(0.16, 1.0, 0.3, 1.0);
/// CSS `ease-out`: width/height transitions.
pub const ease_out: CubicBezier = .init(0.0, 0.0, 0.58, 1.0);
/// CSS `ease`: quick fades, menu/dialog pops.
pub const ease: CubicBezier = .init(0.25, 0.1, 0.25, 1.0);
/// `easeOutQuint`, `cubic-bezier(0.22, 1, 0.36, 1)`.
pub const ease_out_quint: CubicBezier = .init(0.22, 1.0, 0.36, 1.0);
/// Sidebar resort glide.
pub const ease_resort = ease_out_quint;
/// CSS `ease-in-out`: the transcript scroll glide.
pub const ease_in_out: CubicBezier = .init(0.42, 0.0, 0.58, 1.0);
/// Tailwind's default transition curve, `cubic-bezier(0.4, 0, 0.2, 1)`.
pub const ease_tailwind: CubicBezier = .init(0.4, 0.0, 0.2, 1.0);

/// One catalog entry: duration + optional delay + curve. The delay is folded
/// into the timeline: it runs for `delay + duration` and progress holds at 0
/// until the delay has elapsed.
pub const MotionSpec = struct {
    duration_ms: u64,
    delay_ms: u64 = 0,
    curve: CubicBezier,

    pub fn init(duration_ms: u64, curve: CubicBezier) MotionSpec {
        return .{ .duration_ms = duration_ms, .curve = curve };
    }

    pub fn withDelay(self: MotionSpec, delay_ms: u64) MotionSpec {
        var s = self;
        s.delay_ms = delay_ms;
        return s;
    }

    /// Wall-clock span of the whole timeline (delay + duration), in ms.
    pub fn totalMs(self: MotionSpec) u64 {
        return self.delay_ms + self.duration_ms;
    }

    /// Timeline span in nanoseconds, stretched by `extra_scale` and the
    /// process-wide `ZERON_MOTION_SCALE` knob (`speed_scale`).
    pub fn totalNs(self: MotionSpec, extra_scale: f32) u64 {
        return @intFromFloat(@as(f64, @floatFromInt(self.totalMs())) * std.time.ns_per_ms * extra_scale * speed_scale);
    }

    /// The oneshot `zpui.Animation` for this spec (`MotionSpec::animation`):
    /// scaled span, this curve. Delayed specs fold the delay into the span
    /// via `progress` at the call site (only the splash has one).
    pub fn animation(self: MotionSpec) zpui.Animation {
        std.debug.assert(self.delay_ms == 0);
        return zpui.Animation.init(self.totalNs(1.0)).withEasing(.{ .cubic_bezier = .init(self.curve.x1, self.curve.y1, self.curve.x2, self.curve.y2) });
    }

    /// Eased progress (0..1) for a raw timeline delta (0..1 across the total span).
    pub fn progress(self: MotionSpec, raw_delta: f32) f32 {
        const total: f32 = @floatFromInt(self.delay_ms + self.duration_ms);
        if (total <= 0.0 or self.duration_ms == 0) return 1.0;
        const t = (std.math.clamp(raw_delta, 0.0, 1.0) * total - @as(f32, @floatFromInt(self.delay_ms))) /
            @as(f32, @floatFromInt(self.duration_ms));
        return self.curve.eval(std.math.clamp(t, 0.0, 1.0));
    }

    /// Eased progress after `elapsed_ns` of wall time.
    pub fn progressAt(self: MotionSpec, elapsed_ns: u64, extra_scale: f32) f32 {
        const total = self.totalNs(extra_scale);
        if (total == 0) return 1.0;
        return self.progress(@floatCast(@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(total))));
    }

    /// Oneshot progress honoring reduced motion (snaps to the end state).
    pub fn progressReduced(self: MotionSpec, raw_delta: f32, reduced: bool) f32 {
        return if (reduced) 1.0 else self.progress(raw_delta);
    }

    /// Phase in [0, 1) of a repeating spec after `elapsed_ns` (0 when reduced).
    pub fn phase(self: MotionSpec, elapsed_ns: u64, reduced: bool) f32 {
        if (reduced) return 0;
        const total = self.totalMs() * std.time.ns_per_ms;
        if (total == 0) return 0;
        return @floatCast(@as(f64, @floatFromInt(elapsed_ns % total)) / @as(f64, @floatFromInt(total)));
    }
};

/// A manually driven tween (zeron `WidthTween` evaluated by
/// `Shell::eval_tween`): `from → to` over `spec` from `start_ns`, never
/// through an element-keyed animation, so a remount can't replay it.
pub const Tween = struct {
    from: f32,
    to: f32,
    start_ns: u64,

    /// `eval_tween`: mid-flight the eased lerp; finished, absent or under
    /// reduced motion exactly `target`.
    pub fn eval(tween: ?Tween, target: f32, now_ns: u64, spec: MotionSpec, reduced: bool) f32 {
        const t = tween orelse return target;
        if (reduced) return target;
        const total = spec.totalNs(1.0);
        const elapsed = now_ns -| t.start_ns;
        if (total == 0 or elapsed >= total) return target;
        return lerp(t.from, t.to, spec.progress(@floatCast(@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(total)))));
    }

    /// `tween_active`: still moving (keep frames coming).
    pub fn active(tween: ?Tween, now_ns: u64, spec: MotionSpec, reduced: bool) bool {
        const t = tween orelse return false;
        return !reduced and now_ns -| t.start_ns < spec.totalNs(1.0);
    }
};

/// Entrances: 0.5s expo-out fade + 4px rise.
pub const fade_in: MotionSpec = .init(500, ease_out_expo);
/// Quick fade: 0.15s.
pub const fade_quick: MotionSpec = .init(150, ease);
/// Wallpaper replacement: immediate attack, short soft landing.
pub const wallpaper_crossfade: MotionSpec = .init(180, .init(1.0 / 3.0, 1.0, 2.0 / 3.0, 1.0));
/// Popover-in: 0.14s, opacity 0.3 -> 1, translateY -2 -> 0.
pub const menu_in: MotionSpec = .init(140, ease);
/// Popover-out: 0.1s (exits get out of the way faster).
pub const menu_out: MotionSpec = .init(100, ease);
/// Dialog-in: 0.18s, translateY 2 -> 0.
pub const dialog_in: MotionSpec = .init(180, ease);
/// Boot splash exit: 0.5s fade + 6px lift after a 0.15s hold.
pub const splash_out: MotionSpec = MotionSpec.init(500, ease).withDelay(150);
/// Sidebar / pane width+height transitions.
pub const resize: MotionSpec = .init(200, ease_out);
/// Terminal tab drag-reorder slides.
pub const tab_slide: MotionSpec = .init(150, ease_out);
/// Diff-pane per-file collapse.
pub const collapse: MotionSpec = .init(180, ease_out);
/// New-thread <-> session composer handoff.
pub const new_thread_transition: MotionSpec = .init(420, ease_resort);
/// Diff-pane chevron rotate.
pub const chevron: MotionSpec = .init(200, ease);
/// Rail-tick / scroll-to-row glide over the whole distance.
pub const scroll_glide: MotionSpec = .init(500, ease_in_out);
/// CSS `transition-colors` default: every hover wash fades over this.
pub const hover_fade: MotionSpec = .init(150, ease_tailwind);
/// Zeron loader pulse period.
pub const zeron_pulse: MotionSpec = .init(2400, ease);
/// Gradient matrix spinner wave period.
pub const gradient_spin: MotionSpec = .init(750, ease);
/// Transcript tool-row reveal and its per-row stagger.
pub const tool_row_reveal: MotionSpec = .init(360, ease_out_expo);
pub const tool_row_stagger_ms: u64 = 65;

/// Entrance offsets (px) the catalog's element helpers animate from.
pub const fade_in_rise: f32 = 4;
pub const settle_down_drop: f32 = -10;
pub const menu_in_travel: f32 = -2;
pub const menu_in_opacity_from: f32 = 0.3;
pub const dialog_in_rise: f32 = 2;
pub const splash_out_lift: f32 = -6;

/// Opacity and vertical offset of an animated element at eased progress `t`.
pub const Frame = struct { opacity: f32, offset_y: f32 };

pub fn fadeInFrame(t: f32) Frame {
    return .{ .opacity = t, .offset_y = fade_in_rise * (1.0 - t) };
}

pub fn settleDownFrame(t: f32) Frame {
    return .{ .opacity = t, .offset_y = settle_down_drop * (1.0 - t) };
}

/// Popover entrance from a signed starting offset (`menu_in_travel` by default).
pub fn menuInFrame(t: f32, from: f32) Frame {
    return .{ .opacity = menu_in_opacity_from + (1.0 - menu_in_opacity_from) * t, .offset_y = from * (1.0 - t) };
}

/// Popover exit retreating toward the trigger by half the entrance travel.
pub fn menuOutFrame(t: f32, toward: f32) Frame {
    return .{ .opacity = 1.0 - t, .offset_y = toward * 0.5 * t };
}

pub fn dialogInFrame(t: f32) Frame {
    return .{ .opacity = t, .offset_y = dialog_in_rise * (1.0 - t) };
}

pub fn splashOutFrame(t: f32) Frame {
    return .{ .opacity = 1.0 - t, .offset_y = splash_out_lift * t };
}

// ---- resize-edge feedback ----

pub const resize_edge_nudge: f32 = 5.0;
pub const resize_edge_bounce_ms: u64 = 220;
pub const resize_edge_bounce_out_fraction: f32 = 0.32;

pub const ResizeEdge = enum { min, max };

pub const ResizeDragSample = struct {
    width: f32,
    edge: ?ResizeEdge,
    starts_bounce: bool,
};

/// Clamp a resize sample while latching its constrained edge; a held pointer
/// starts one bounce rather than one per drag event.
pub fn resizeDragSample(requested: f32, min: f32, max: f32, latched_edge: ?ResizeEdge, reduced_motion: bool) ResizeDragSample {
    std.debug.assert(min <= max);
    const edge: ?ResizeEdge = if (requested <= min) .min else if (requested >= max) .max else null;
    return .{
        .width = std.math.clamp(requested, min, max),
        .edge = edge,
        .starts_bounce = !reduced_motion and edge != null and edge != latched_edge,
    };
}

fn smoothstep(t0: f32) f32 {
    const t = std.math.clamp(t0, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Two-phase pulse: ease out to the overshoot, ease home a little slower.
pub fn resizeBounceOffset(edge: ResizeEdge, raw0: f32) f32 {
    const raw = std.math.clamp(raw0, 0.0, 1.0);
    const f = resize_edge_bounce_out_fraction;
    const magnitude = (if (raw < f) smoothstep(raw / f) else 1.0 - smoothstep((raw - f) / (1.0 - f))) * resize_edge_nudge;
    return switch (edge) {
        .min => -magnitude,
        .max => magnitude,
    };
}

// ---- loader math (crates/proto/src/motion.rs) ----

pub const zeron_cells: usize = 5;
pub const matrix_side: usize = 3;
pub const pulse_min_opacity: f32 = 0.08;
pub const pulse_min_scale: f32 = 0.9;
/// Per-cell stagger as a fraction of the pulse period (0.15s of 2.4s).
pub const pulse_stagger: f32 = @as(f32, 0.15) / @as(f32, 2.4);
/// Gradient spinner row tints (0xRRGGBB): blue -> amber -> pink.
pub const gspin_row_tints = [matrix_side]u32{ 0xB6D3EF, 0xEDB185, 0xF888A0 };
pub const gspin_dim: f32 = 0.1;
/// Clockwise ring position of each (row, col) of the 2x3 mini spinner.
pub const mini_ring = [3][2]usize{ .{ 0, 1 }, .{ 5, 2 }, .{ 4, 3 } };
pub const mini_ring_len: f32 = 6.0;
/// Fraction of the pulse cycle the mark's light sweep occupies.
pub const mark_spread: f32 = 0.55;
/// The zeron mark's 100x100 cells on its 820x940 canvas.
pub const mark_cells = [34][2]f32{
    .{ 0, 600 },   .{ 0, 720 },   .{ 240, 840 }, .{ 240, 720 }, .{ 120, 840 }, .{ 120, 600 }, .{ 240, 600 },
    .{ 0, 480 },   .{ 0, 360 },   .{ 480, 840 }, .{ 480, 720 }, .{ 120, 360 }, .{ 120, 240 }, .{ 240, 360 },
    .{ 600, 720 }, .{ 480, 600 }, .{ 360, 360 }, .{ 240, 240 }, .{ 600, 600 }, .{ 720, 600 }, .{ 720, 480 },
    .{ 240, 120 }, .{ 600, 380 }, .{ 720, 240 }, .{ 720, 0 },   .{ 480, 240 }, .{ 480, 0 },   .{ 120, 480 },
    .{ 240, 480 }, .{ 360, 840 }, .{ 360, 720 }, .{ 360, 600 }, .{ 360, 480 }, .{ 120, 720 },
};

pub fn lerp(from: f32, to: f32, t: f32) f32 {
    return from + (to - from) * t;
}

fn remEuclid1(x: f32) f32 {
    const r = @rem(x, 1.0);
    return if (r < 0) r + 1.0 else r;
}

/// A cell's phase given the loader's raw phase and the cell's index.
pub fn staggeredPhase(raw_delta: f32, index: usize, stagger: f32) f32 {
    return remEuclid1(raw_delta - @as(f32, @floatFromInt(index)) * stagger);
}

/// Cosine pulse: 0 at phase 0, 1 at 0.5, 0 at 1.
pub fn pulseWave(p: f32) f32 {
    return 0.5 - 0.5 * @cos(p * std.math.tau);
}

pub fn pulseOpacity(p: f32) f32 {
    return pulse_min_opacity + (1.0 - pulse_min_opacity) * pulseWave(p);
}

pub fn pulseScale(p: f32) f32 {
    return pulse_min_scale + (1.0 - pulse_min_scale) * pulseWave(p);
}

/// Gradient-spin cell opacity: full at cycle start, down to `dim` by 45%,
/// resting until 92%, then back to full.
pub fn gspinOpacity(t0: f32, dim: f32) f32 {
    const t = remEuclid1(t0);
    if (t < 0.45) return lerp(1.0, dim, t / 0.45);
    if (t < 0.92) return dim;
    return lerp(dim, 1.0, (t - 0.92) / 0.08);
}

/// Phase offset of a (row, col) cell in the 3x3 gradient spinner: the pulse
/// enters at the bottom edge and converges on the top-centre cell.
pub fn gspinCellPhase(row: usize, col: usize) f32 {
    const side: f32 = @floatFromInt(matrix_side);
    const centre = (side - 1.0) / 2.0;
    const max = side - 1.0 + centre;
    const d = side - 1.0 - @as(f32, @floatFromInt(row)) + @abs(@as(f32, @floatFromInt(col)) - centre);
    return if (max == 0.0) 0.0 else d / (max + 1.0);
}

/// Gradient-matrix spinner wave intensity of diagonal `wave_index` of `wave_count`.
pub fn matrixWave(raw_delta: f32, wave_index: usize, wave_count: usize) f32 {
    const count: f32 = @floatFromInt(@max(wave_count, 1));
    return pulseWave(staggeredPhase(raw_delta, wave_index, 1.0 / count));
}

/// Per-cell stagger along the mark's flight axis (larger leads).
pub fn markCellStagger(x: f32, y: f32) f32 {
    const t = (820.0 - x + y) / 1660.0;
    return (1.0 - t) * mark_spread;
}

pub fn markPhase(delta: f32, x: f32, y: f32) f32 {
    return remEuclid1(delta + markCellStagger(x, y));
}

/// Activity-grid opacity. Under system reduced motion (`subtle`) the grid
/// keeps a gentle uniform 2.4s brightness pulse instead of the chase.
pub fn activityOpacity(phase: f32, cell_phase: f32, dim: f32, subtle: bool) f32 {
    return if (subtle) 0.6 + 0.2 * pulseWave(phase) else gspinOpacity(phase + cell_phase, dim);
}

// ---- hover color fades (CSS `transition-colors` parity) ----

/// Blend like a browser transition: sRGB with premultiplied alpha, so a wash
/// fading in from transparent brightens without passing through grey.
pub fn mix(from: Hsla, to: Hsla, t0: f32) Hsla {
    const t = std.math.clamp(t0, 0.0, 1.0);
    if (t <= 0.0) return from;
    if (t >= 1.0) return to;
    const f = from.toRgba();
    const g = to.toRgba();
    const a = lerp(f.a, g.a, t);
    if (a <= std.math.floatEps(f32)) {
        var c = g;
        c.a = 0;
        return c.toHsla();
    }
    const out: Rgba = .{
        .r = lerp(f.r * f.a, g.r * g.a, t) / a,
        .g = lerp(f.g * f.a, g.g * g.a, t) / a,
        .b = lerp(f.b * f.a, g.b * g.a, t) / a,
        .a = a,
    };
    return out.toHsla();
}

/// Per-key hover progress store: progress runs origin -> target over
/// `duration_ns`, re-anchored on direction flips so blends stay continuous.
/// Entries unread for a full frame (unmounted elements) are pruned by `tick`.
pub const HoverFades = struct {
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    frame: u64 = 0,
    duration_ns: u64 = hover_fade.totalMs() * std.time.ns_per_ms,

    const Entry = struct {
        origin: f32,
        target: f32,
        started: u64,
        seen: u64,

        fn value(e: Entry, now: u64, duration: u64) f32 {
            const elapsed = now -| e.started;
            const span = scaledNs(duration);
            if (span == 0 or elapsed >= span) return e.target;
            const raw: f32 = @floatCast(@as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(span)));
            return lerp(e.origin, e.target, hover_fade.curve.eval(raw));
        }

        fn settled(e: Entry, now: u64, duration: u64) bool {
            return e.origin == e.target or now -| e.started >= scaledNs(duration);
        }
    };

    pub fn deinit(self: *HoverFades, gpa: std.mem.Allocator) void {
        var it = self.entries.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.entries.deinit(gpa);
    }

    /// Pointer entered or left the element behind `key` at monotonic `now` (ns).
    /// Reduced motion snaps straight to the endpoint.
    pub fn set(self: *HoverFades, gpa: std.mem.Allocator, key: []const u8, hovered: bool, reduced: bool, now: u64) !void {
        const target: f32 = if (hovered) 1.0 else 0.0;
        const existing = self.entries.getPtr(key);
        if (existing == null and target == 0.0) return; // never hovered: nothing to do
        const current = if (existing) |e| e.value(now, self.duration_ns) else 0.0;
        const entry: Entry = .{ .origin = if (reduced) target else current, .target = target, .started = now, .seen = self.frame };
        if (existing) |e| {
            e.* = entry;
        } else {
            const owned = try gpa.dupe(u8, key);
            errdefer gpa.free(owned);
            try self.entries.put(gpa, owned, entry);
        }
    }

    /// Hover progress (0..1) for `key`; stamps liveness.
    pub fn value(self: *HoverFades, key: []const u8, now: u64) f32 {
        const e = self.entries.getPtr(key) orelse return 0.0;
        e.seen = self.frame;
        return e.value(now, self.duration_ns);
    }

    /// The standard hover blend: rest -> hover at `key`'s progress.
    pub fn blend(self: *HoverFades, key: []const u8, rest: Hsla, hover: Hsla, now: u64) Hsla {
        return mix(rest, hover, self.value(key, now));
    }

    /// Once per frame: prune settled-at-rest and unread entries; true while
    /// any fade is mid-flight (keep frames coming).
    pub fn tick(self: *HoverFades, gpa: std.mem.Allocator, now: u64) bool {
        self.frame += 1;
        var active = false;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            const e = kv.value_ptr.*;
            const stale = e.seen + 1 < self.frame;
            const settled = e.settled(now, self.duration_ns);
            if (!stale and !settled) active = true;
            if (stale or (settled and e.target == 0.0)) {
                const k = kv.key_ptr.*;
                self.entries.removeByPtr(kv.key_ptr);
                gpa.free(k);
                // Removal invalidates the iterator; restart (entries are few).
                it = self.entries.iterator();
            }
        }
        return active;
    }
};

// ---- reduced motion ----

/// The user's reduced-motion preference (`reduceMotion` in ui-settings.json).
pub const ReduceMotion = enum {
    system,
    on,
    off,

    pub const all = [_]ReduceMotion{ .system, .on, .off };

    pub fn label(self: ReduceMotion) []const u8 {
        return switch (self) {
            .system => "System",
            .on => "On",
            .off => "Off",
        };
    }
};

/// Combine the preference with the OS setting and main-window focus.
pub fn resolveReduced(preference: ReduceMotion, system: bool, pause_in_background: bool, active: bool) bool {
    const reduced = switch (preference) {
        .system => system,
        .on => true,
        .off => false,
    };
    return reduced or (pause_in_background and !active);
}

/// Whether activity grids still animate (subtly) while motion is reduced:
/// only when the reduction comes from the OS, not an explicit On or a
/// background pause.
pub fn activityAnimates(preference: ReduceMotion, system: bool, pause_in_background: bool, active: bool) bool {
    if (!resolveReduced(preference, system, pause_in_background, active)) return true;
    return preference == .system and system and !(pause_in_background and !active);
}

/// `ZERON_MOTION_SCALE` parsing: finite values clamped to [0.01, 100], else 1.
pub fn parseSpeedScale(value: ?[]const u8) f32 {
    const v = value orelse return 1.0;
    const s = std.fmt.parseFloat(f32, v) catch return 1.0;
    if (!std.math.isFinite(s)) return 1.0;
    return std.math.clamp(s, 0.01, 100.0);
}

// ---- Tests ----

const testing = std.testing;

test "cubic bezier endpoints, linear and monotonic" {
    try testing.expectEqual(@as(f32, 0), ease.eval(0));
    try testing.expectEqual(@as(f32, 1), ease.eval(1));
    try testing.expectEqual(@as(f32, 0), ease.eval(-1));
    const linear: CubicBezier = .init(0, 0, 1, 1);
    for ([_]f32{ 0.1, 0.25, 0.5, 0.9 }) |x| try testing.expectApproxEqAbs(x, linear.eval(x), 1e-5);
    var prev: f32 = 0;
    for (1..100) |i| {
        const y = ease_out_expo.eval(@as(f32, @floatFromInt(i)) / 100.0);
        try testing.expect(y >= prev and y <= 1.0);
        prev = y;
    }
    // Front-loaded: expo-out is well past halfway at 30% progress.
    try testing.expect(ease_out_expo.eval(0.3) > 0.8);
    // CSS `ease` at 50% is ~0.8024.
    try testing.expectApproxEqAbs(@as(f32, 0.8024), ease.eval(0.5), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0.5), ease_in_out.eval(0.5), 1e-4);
}

test "motion spec delay and reduced motion" {
    try testing.expectEqual(@as(u64, 650), splash_out.totalMs());
    try testing.expectEqual(@as(f32, 0), splash_out.progress(0.2));
    try testing.expectEqual(@as(f32, 1), splash_out.progress(1));
    try testing.expectEqual(@as(f32, 1), fade_in.progressReduced(0, true));
    try testing.expectEqual(@as(f32, 1), fade_in.progressAt(600 * std.time.ns_per_ms, 1));
    try testing.expectEqual(@as(f32, 0), zeron_pulse.phase(1234, true));
    try testing.expectApproxEqAbs(@as(f32, 0.5), zeron_pulse.phase(1200 * std.time.ns_per_ms, false), 1e-6);
}

test "resize edge latching and bounce" {
    const s = resizeDragSample(100, 224, 400, null, false);
    try testing.expectEqual(@as(f32, 224), s.width);
    try testing.expectEqual(ResizeEdge.min, s.edge.?);
    try testing.expect(s.starts_bounce);
    try testing.expect(!resizeDragSample(100, 224, 400, .min, false).starts_bounce);
    try testing.expect(!resizeDragSample(500, 224, 400, null, true).starts_bounce);
    try testing.expectEqual(@as(f32, 0), resizeBounceOffset(.max, 0));
    try testing.expectApproxEqAbs(resize_edge_nudge, resizeBounceOffset(.max, resize_edge_bounce_out_fraction), 1e-5);
    try testing.expectApproxEqAbs(-resize_edge_nudge, resizeBounceOffset(.min, resize_edge_bounce_out_fraction), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), resizeBounceOffset(.max, 1), 1e-6);
}

test "loader math" {
    try testing.expectApproxEqAbs(@as(f32, 0), pulseWave(0), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), pulseWave(0.5), 1e-5);
    try testing.expectApproxEqAbs(pulse_min_opacity, pulseOpacity(0), 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), pulseScale(0.5), 1e-5);
    try testing.expectApproxEqAbs(1.0 - pulse_stagger, staggeredPhase(0, 1, pulse_stagger), 1e-5);
    try testing.expectEqual(@as(f32, 1), gspinOpacity(0, gspin_dim));
    try testing.expectEqual(gspin_dim, gspinOpacity(0.6, gspin_dim));
    try testing.expectEqual(@as(f32, 0), gspinCellPhase(2, 1));
    try testing.expectEqual(@as(f32, 0.5), gspinCellPhase(0, 1));
    try testing.expectApproxEqAbs(mark_spread, markCellStagger(820, 0), 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.6), activityOpacity(0, 0, gspin_dim, true), 1e-6);
}

test "premultiplied mix brightens from transparent" {
    const from = zpui.color.white.alpha(0);
    const to = zpui.color.white.alpha(0.2);
    const mid = mix(from, to, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 1), mid.l, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0.1), mid.a, 1e-5);
}

test "hover fades" {
    const gpa = testing.allocator;
    var fades: HoverFades = .{};
    defer fades.deinit(gpa);
    const ms = std.time.ns_per_ms;
    try fades.set(gpa, "row", false, false, 0);
    try testing.expectEqual(@as(usize, 0), fades.entries.count());
    try fades.set(gpa, "row", true, false, 0);
    try testing.expectEqual(@as(f32, 0), fades.value("row", 0));
    const mid = fades.value("row", 75 * ms);
    try testing.expect(mid > 0 and mid < 1);
    try testing.expect(fades.tick(gpa, 75 * ms));
    try testing.expectEqual(@as(f32, 1), fades.value("row", 200 * ms));
    // Reverse mid-flight re-anchors at the current value.
    try fades.set(gpa, "row", false, false, 200 * ms);
    try testing.expectEqual(@as(f32, 1), fades.value("row", 200 * ms));
    _ = fades.value("row", 400 * ms);
    try testing.expect(!fades.tick(gpa, 400 * ms)); // settled at rest -> pruned
    try testing.expectEqual(@as(usize, 0), fades.entries.count());
    // Reduced motion snaps; unread entries are pruned after a frame.
    try fades.set(gpa, "btn", true, true, 0);
    try testing.expectEqual(@as(f32, 1), fades.value("btn", 0));
    _ = fades.tick(gpa, 0);
    _ = fades.tick(gpa, 0);
    try testing.expectEqual(@as(usize, 0), fades.entries.count());
}

test "manual tween" {
    const ms = std.time.ns_per_ms;
    const tw: Tween = .{ .from = 0, .to = 300, .start_ns = 1000 * ms };
    try testing.expectEqual(@as(f32, 300), Tween.eval(null, 300, 0, resize, false));
    try testing.expectEqual(@as(f32, 0), Tween.eval(tw, 300, 1000 * ms, resize, false));
    const mid = Tween.eval(tw, 300, 1100 * ms, resize, false);
    try testing.expect(mid > 150 and mid < 300); // ease-out: past halfway at half time
    try testing.expectEqual(@as(f32, 300), Tween.eval(tw, 300, 1100 * ms, resize, true));
    try testing.expectEqual(@as(f32, 300), Tween.eval(tw, 300, 1200 * ms, resize, false));
    try testing.expect(Tween.active(tw, 1199 * ms, resize, false));
    try testing.expect(!Tween.active(tw, 1200 * ms, resize, false));
    // ZERON_MOTION_SCALE stretches the span.
    speed_scale = 10;
    defer speed_scale = 1;
    try testing.expect(Tween.active(tw, 2900 * ms, resize, false));
    try testing.expect(Tween.eval(tw, 300, 1200 * ms, resize, false) < 300);
}

test "reduced motion resolution" {
    try testing.expect(resolveReduced(.system, true, false, true));
    try testing.expect(!resolveReduced(.off, true, false, true));
    try testing.expect(resolveReduced(.off, false, true, false));
    try testing.expect(activityAnimates(.system, true, false, true));
    try testing.expect(!activityAnimates(.on, false, false, true));
    try testing.expectEqual(@as(f32, 10), parseSpeedScale("10"));
    try testing.expectEqual(@as(f32, 1), parseSpeedScale("nan"));
    try testing.expectEqual(@as(f32, 100), parseSpeedScale("1e9"));
}
