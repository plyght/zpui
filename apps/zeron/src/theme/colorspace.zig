//! Color math used by the UI theme (port of the free functions at the bottom
//! of zeron `crates/ui/src/theme.rs`): OKLCH, zeron's own HSL conversion,
//! WCAG contrast and alpha compositing, all on zpui `Hsla`.
//!
//! zeron converts with its *own* `rgb_to_hsl`/`hsl_to_rgb` (epsilon-guarded),
//! not gpui's `Rgba <-> Hsla`, so these are ported separately to keep token
//! values bit-compatible.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("model.zig");

pub const Hsla = zpui.Hsla;
pub const hsla = zpui.hsla;

const eps = std.math.floatEps(f32);

/// An exact achromatic tone from an 8-bit channel (`grey(13)` is `#0d0d0d`).
pub fn grey(value: u8) Hsla {
    return hsla(0, 0, @as(f32, @floatFromInt(value)) / 255.0, 1);
}

/// A neutral (chroma 0) OKLCH tone.
pub fn neutral(lightness: f32) Hsla {
    return hsla(0, 0, oklchToSrgb(lightness, 0, 0)[0], 1);
}

/// OKLCH (CSS notation: L in 0..1, C, H in degrees) as `Hsla`.
pub fn oklch(l: f32, c: f32, h_deg: f32) Hsla {
    const v = oklchToSrgb(l, c, h_deg);
    const h, const s, const ll = rgbToHsl(v[0], v[1], v[2]);
    return hsla(h, s, ll, 1);
}

/// OKLCH -> gamma-encoded sRGB, each channel clipped to 0..1 (Ottosson's
/// OKLab matrices, as in CSS Color 4).
pub fn oklchToSrgb(l: f32, c: f32, h_deg: f32) [3]f32 {
    // Rust's `to_radians`: multiply by an f32-rounded PI / 180.
    const pi32: f32 = std.math.pi;
    const h = h_deg * (pi32 / 180.0);
    const a = c * @as(f32, @floatCast(@cos(@as(f64, h))));
    const b = c * @as(f32, @floatCast(@sin(@as(f64, h))));

    const l_ = l + 0.39633778 * a + 0.21580376 * b;
    const m_ = l - 0.105561346 * a - 0.06385417 * b;
    const s_ = l - 0.08948418 * a - 1.2914855 * b;
    const l3 = l_ * l_ * l_;
    const m3 = m_ * m_ * m_;
    const s3 = s_ * s_ * s_;

    const r = 4.0767417 * l3 - 3.3077116 * m3 + 0.23096993 * s3;
    const g = -1.268438 * l3 + 2.6097574 * m3 - 0.3413194 * s3;
    const bb = -0.0041960863 * l3 - 0.7034186 * m3 + 1.7076147 * s3;
    return .{ gammaEncode(r), gammaEncode(g), gammaEncode(bb) };
}

fn gammaEncode(x0: f32) f32 {
    const x = std.math.clamp(x0, 0.0, 1.0);
    return if (x <= 0.0031308) 12.92 * x else 1.055 * model.powf(x, @as(f32, 1.0) / @as(f32, 2.4)) - 0.055;
}

/// Rust's `f32::rem_euclid` for a positive divisor.
fn remEuclid(x: f32, y: f32) f32 {
    const r = @rem(x, y);
    return if (r < 0) r + @abs(y) else r;
}

/// sRGB (0..1) -> HSL (all 0..1), zeron's epsilon-guarded variant.
pub fn rgbToHsl(r: f32, g: f32, b: f32) struct { f32, f32, f32 } {
    const max = @max(@max(r, g), b);
    const min = @min(@min(r, g), b);
    const l = (max + min) / 2.0;
    const delta = max - min;
    if (delta < eps) return .{ 0, 0, l };
    const s = if (l > 0.5) delta / (2.0 - max - min) else delta / (max + min);
    const h6 = if (@abs(max - r) < eps)
        remEuclid((g - b) / delta, 6.0)
    else if (@abs(max - g) < eps)
        (b - r) / delta + 2.0
    else
        (r - g) / delta + 4.0;
    return .{ h6 / 6.0, s, l };
}

/// HSL (all 0..1) -> sRGB components (0..1).
pub fn hslToRgb(h: f32, s: f32, l: f32) [3]f32 {
    if (s <= eps) return .{ l, l, l };
    const q = if (l < 0.5) l * (1.0 + s) else l + s - l * s;
    const p = 2.0 * l - q;
    const hue = struct {
        fn f(t0: f32, pp: f32, qq: f32) f32 {
            const t = remEuclid(t0, 1.0);
            if (t < 1.0 / 6.0) return pp + (qq - pp) * 6.0 * t;
            if (t < 0.5) return qq;
            if (t < 2.0 / 3.0) return pp + (qq - pp) * (2.0 / 3.0 - t) * 6.0;
            return pp;
        }
    }.f;
    return .{ hue(h + 1.0 / 3.0, p, q), hue(h, p, q), hue(h - 1.0 / 3.0, p, q) };
}

/// A model color (8-bit sRGB) as `Hsla`.
pub fn fromModel(color: model.Color) Hsla {
    const h, const s, const l = rgbToHsl(
        @as(f32, @floatFromInt(color.r)) / 255.0,
        @as(f32, @floatFromInt(color.g)) / 255.0,
        @as(f32, @floatFromInt(color.b)) / 255.0,
    );
    return hsla(h, s, l, @as(f32, @floatFromInt(color.a)) / 255.0);
}

/// WCAG 2.1 relative luminance of an opaque color.
pub fn relativeLuminance(color: Hsla) f32 {
    const lin = struct {
        fn f(c: f32) f32 {
            return if (c <= 0.04045) c / 12.92 else model.powf((c + 0.055) / 1.055, 2.4);
        }
    }.f;
    const v = hslToRgb(color.h, color.s, color.l);
    return 0.2126 * lin(v[0]) + 0.7152 * lin(v[1]) + 0.0722 * lin(v[2]);
}

/// WCAG 2.1 contrast ratio between two opaque colors (1 ... 21).
pub fn contrastRatio(a: Hsla, b: Hsla) f32 {
    const la = relativeLuminance(a);
    const lb = relativeLuminance(b);
    const hi = @max(la, lb);
    const lo = @min(la, lb);
    return (hi + 0.05) / (lo + 0.05);
}

/// Contrast of a possibly translucent `foreground` as painted over `background`.
pub fn paintedContrast(foreground: Hsla, background: Hsla) f32 {
    return contrastRatio(flatten(foreground, background), background);
}

/// Composite `fg` over an opaque `bg`; the opaque color the eye receives.
pub fn flatten(fg: Hsla, bg: Hsla) Hsla {
    const a = std.math.clamp(fg.a, 0.0, 1.0);
    const f = hslToRgb(fg.h, fg.s, fg.l);
    const b = hslToRgb(bg.h, bg.s, bg.l);
    const h, const s, const l = rgbToHsl(
        f[0] * a + b[0] * (1.0 - a),
        f[1] * a + b[1] * (1.0 - a),
        f[2] * a + b[2] * (1.0 - a),
    );
    return hsla(h, s, l, 1);
}

/// Naive per-component HSLA lerp (zeron `theme::mix`, used for text hardening
/// and the gradient spinner). For browser-style transitions use `motion.mix`.
pub fn mix(a: Hsla, b: Hsla, t0: f32) Hsla {
    const t = std.math.clamp(t0, 0.0, 1.0);
    return hsla(
        a.h + (b.h - a.h) * t,
        a.s + (b.s - a.s) * t,
        a.l + (b.l - a.l) * t,
        a.a + (b.a - a.a) * t,
    );
}

const testing = std.testing;

fn srgbU8(c: [3]f32) [3]u8 {
    var out: [3]u8 = undefined;
    for (c, &out) |v, *o| o.* = @intFromFloat(@round(v * 255.0));
    return out;
}

test "neutral 950 is #0a0a0a" {
    try testing.expectEqual([3]u8{ 10, 10, 10 }, srgbU8(oklchToSrgb(0.145, 0, 0)));
}

test "oklch accents match reference" {
    try testing.expectEqual([3]u8{ 124, 134, 255 }, srgbU8(oklchToSrgb(0.673, 0.182, 276.935)));
    try testing.expectEqual([3]u8{ 255, 100, 103 }, srgbU8(oklchToSrgb(0.704, 0.191, 22.216)));
    try testing.expectEqual([3]u8{ 255, 185, 0 }, srgbU8(oklchToSrgb(0.828, 0.189, 84.429)));
}

test "hsl round trips through rgb" {
    for ([_]Hsla{ oklch(0.673, 0.182, 276.935), oklch(0.577, 0.245, 27.325), neutral(0.556) }) |c| {
        const v = hslToRgb(c.h, c.s, c.l);
        const h, const s, const l = rgbToHsl(v[0], v[1], v[2]);
        try testing.expectApproxEqAbs(c.l, l, 1e-3);
        try testing.expectApproxEqAbs(c.s, s, 1e-3);
        if (c.s > 1e-3) try testing.expectApproxEqAbs(c.h, h, 1e-3);
    }
}

test "contrast ratio anchors" {
    try testing.expectApproxEqAbs(@as(f32, 21), contrastRatio(grey(255), grey(0)), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), contrastRatio(grey(255), grey(255)), 0.01);
}
