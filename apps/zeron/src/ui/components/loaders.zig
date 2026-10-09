//! Pixel loaders (zeron `loaders.rs`): the 3×3 gradient matrix spinner (boot
//! splash), the 2×3 mini glyph spinner (sidebar "Working"), and the static /
//! pulsing zeron mark.
//!
//! The activity grids are pure functions of a `zt.pulse.Activity`
//! (`motion::ActivityPulse`). `zt.pulse.activity(window)` (30 Hz) /
//! `activitySlow(window)` (15 Hz, the 3×3 matrix) returns it and keeps frames
//! coming on the pulse clock: the chase, or under system reduced motion the
//! gentle 2.4 s brightness pulse at 15 Hz; explicit On and a background pause
//! hold still. Never `window.requestAnimationFrame()`: that redraws the
//! window at the display rate for as long as the loader shows.
//!
//! ```zig
//! loaders.gradientSpinner(2.5, zt.pulse.activitySlow(window))
//! loaders.miniGlyphSpinner(2, theme.glyph.rows(), zt.pulse.activity(window))
//! ```

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");

const motion = zt.motion;
const div = zpui.div;
const px = zpui.px;

fn appOf(cx: anytype) *zpui.App {
    if (@TypeOf(cx) == *zpui.App) return cx;
    return cx.app;
}

/// Monotonic nanoseconds (platform clock).
pub fn nowNs(cx: anytype) u64 {
    return appOf(cx).platform.dispatcher().now();
}

/// Raw 0..1 phase of a looping `spec` at the current time.
pub fn phaseOf(cx: anytype, spec: motion.MotionSpec) f32 {
    const period: u64 = spec.duration_ms * std.time.ns_per_ms;
    if (period == 0) return 0;
    const t = nowNs(cx) % period;
    return @as(f32, @floatFromInt(t)) / @as(f32, @floatFromInt(period));
}

/// The boot splash's 3×3 matrix: rows tinted blue → amber → pink, a wave
/// travelling up the diagonals once per 750ms.
pub fn gradientSpinner(cell: f32, pulse: zt.pulse.Activity) zpui.Div {
    var col_div = div().flex().flexCol().gap(px(cell / 2));
    for (0..motion.matrix_side) |row| {
        const tint = zpui.rgb(motion.gspin_row_tints[row]).toHsla();
        var r = div().flex().flexRow().gap(px(cell / 2));
        for (0..motion.matrix_side) |col| {
            const op = pulse.opacity(motion.gspinCellPhase(row, col), motion.gspin_dim);
            r = r.child(div().size(px(cell)).rounded(px(cell / 2)).bg(tint).opacity(op));
        }
        col_div = col_div.child(r);
    }
    return col_div;
}

/// The 2×3 mini spinner whose brightness chases around the ring.
pub fn miniGlyphSpinner(cell: f32, rows: [3]zpui.Hsla, pulse: zt.pulse.Activity) zpui.Div {
    const ring = [3][2]usize{ .{ 0, 1 }, .{ 5, 2 }, .{ 4, 3 } };
    var col_div = div().flexNone().flex().flexCol().gap(px(cell / 2));
    for (0..3) |row| {
        var r = div().flex().flexRow().gap(px(cell / 2));
        for (0..2) |col| {
            const cell_phase = @as(f32, @floatFromInt(ring[row][col])) / 6.0;
            const op = pulse.opacity(cell_phase, motion.gspin_dim);
            r = r.child(div().size(px(cell)).rounded(px(cell / 2)).bg(rows[row]).opacity(op));
        }
        col_div = col_div.child(r);
    }
    return col_div;
}

pub const mark_cells = motion.mark_cells;

/// The zeron mark as pixel cells, `height` tall, pulsing when `phase` is set.
pub fn zeronMark(height: f32, color: zpui.Hsla, phase: ?f32) zpui.Div {
    const scale = height / 940.0;
    const cell = 100.0 * scale;
    var d = div().relative().flexNone().w(px(820.0 * scale)).h(px(height));
    for (mark_cells) |c| {
        var dot = div().rounded(px(16.0 * scale)).bg(color);
        if (phase) |p| {
            const ph = motion.markPhase(p, c[0], c[1]);
            dot = dot.opacity(motion.pulseOpacity(ph)).size(px(cell * motion.pulseScale(ph)));
        } else dot = dot.size(px(cell));
        d = d.child(div().absolute().left(px(c[0] * scale)).top(px(c[1] * scale)).size(px(cell))
            .flex().itemsCenter().justifyCenter().child(dot));
    }
    return d;
}
