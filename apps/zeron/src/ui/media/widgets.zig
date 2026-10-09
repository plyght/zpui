//! Small attachment widgets (zeron `loaders.rs` `upload_progress_ring`,
//! `mini_glyph_spinner`) and the pulse used by loading thumbnails.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");

const div = zpui.div;
const px = zpui.px;
const motion = zt.motion;

/// Stroke width of `progressRing`.
pub const ring_stroke: f32 = 2.5;

/// An SVG arc (clockwise from 12 o'clock, `sweep` of a full turn) for a ring
/// of `diameter`, as a monochrome mask tinted by the element's text color.
fn arcSvg(diameter: f32, sweep: f32) []const u8 {
    const r = diameter / 2.0 - ring_stroke;
    const c = diameter / 2.0;
    if (sweep >= 0.9999) {
        return zpui.fmt("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\"><circle cx=\"{d}\" cy=\"{d}\" r=\"{d}\" fill=\"none\" stroke=\"#000\" stroke-width=\"{d}\"/></svg>", .{ diameter, diameter, diameter, diameter, c, c, r, ring_stroke });
    }
    const theta = -std.math.pi / 2.0 + std.math.tau * sweep;
    const x = c + r * @cos(theta);
    const y = c + r * @sin(theta);
    const large: u8 = if (sweep > 0.5) 1 else 0;
    return zpui.fmt("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\"><path d=\"M {d} {d} A {d} {d} 0 {d} 1 {d:.3} {d:.3}\" fill=\"none\" stroke=\"#000\" stroke-width=\"{d}\"/></svg>", .{ diameter, diameter, diameter, diameter, c, c - r, r, r, large, x, y, ring_stroke });
}

/// Radial upload-progress ring with the percent centered, white on the
/// dimmed thumbnail behind it (both themes).
pub fn progressRing(percent: u8, diameter: f32) zpui.Div {
    const frac = @as(f32, @floatFromInt(@min(percent, 100))) / 100.0;
    var ring = div().relative().size(px(diameter)).flex().itemsCenter().justifyCenter();
    const track_key = zpui.fmt("upload-ring-track-{d}", .{diameter});
    ring = ring.child(zpui.svg().source(track_key, arcSvg(diameter, 1.0)).absolute().inset0().size(px(diameter)).textColor(zpui.hsla(0, 0, 1, 0.22)));
    if (frac > 0) {
        const key = zpui.fmt("upload-ring-{d}-{d}", .{ diameter, percent });
        ring = ring.child(zpui.svg().source(key, arcSvg(diameter, frac)).absolute().inset0().size(px(diameter)).textColor(zpui.hsla(0, 0, 1, 0.95)));
    }
    return ring.child(div().textSize(px(9)).fontWeight(600).textColor(zpui.hsla(0, 0, 1, 0.95)).child(zpui.fmt("{d}%", .{percent})));
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

/// Raw 0..1 phase of a looping `spec` at `now_ns`.
pub fn phaseAt(now_ns: u64, spec: motion.MotionSpec) f32 {
    const period: u64 = spec.duration_ms * std.time.ns_per_ms;
    if (period == 0) return 0;
    return @as(f32, @floatFromInt(now_ns % period)) / @as(f32, @floatFromInt(period));
}

/// `motion::pulse_wave(pulse_delta(&ZERON_PULSE))`: 0..1..0 over 2.4s.
pub fn pulseWave(now_ns: u64) f32 {
    return motion.pulseWave(phaseAt(now_ns, motion.zeron_pulse));
}

test {
    @import("std").testing.refAllDecls(@This());
}
