//! Palettes and metrics of the desktop toolkits zpui imitates: GNOME / libadwaita
//! (GTK 4, libadwaita 1.6+ light and dark stylesheets), KDE Plasma 6 / Breeze, and
//! macOS System Settings (only the preference-page chrome: macOS form controls are real
//! AppKit controls). Used by the drawn native controls (desktop_controls.zig) and the
//! preference-page building blocks (prefs.zig).
//!
//! Colors follow the toolkits' stylesheets: libadwaita's named colors
//! (`--window-bg-color`, `--card-bg-color`, `--accent-bg-color`, `alpha(currentColor, …)`
//! for buttons and troughs, its card shadow), Breeze's color scheme (`BreezeLight`,
//! `BreezeDark`: Window/View/Button backgrounds, `DecorationFocus` highlight, the
//! 20 % / 30 % background–foreground mixes it uses for frames). All pure data: one
//! `Look` per (family, dark, accent), computed on demand without allocating.

const std = @import("std");
const color = @import("../color.zig");
const platform = @import("../platform/platform.zig");
const geometry = @import("../geometry.zig");

pub const Hsla = color.Hsla;
pub const Pixels = geometry.Pixels;

/// Which toolkit a look imitates.
pub const Family = enum {
    adwaita,
    breeze,
    macos,

    pub fn fromStyle(s: platform.DesktopStyle) ?Family {
        return switch (s) {
            .none => null,
            .adwaita => .adwaita,
            .breeze => .breeze,
        };
    }
};

/// libadwaita's default accent (`--accent-bg-color`, blue 3).
pub const adwaita_accent: u32 = 0x3584e4;
/// Breeze's highlight / `DecorationFocus`.
pub const breeze_accent: u32 = 0x3daee9;
/// macOS controlAccentColor (blue).
pub const macos_accent: u32 = 0x007aff;

/// GNOME 48+ ships Adwaita Sans (an Inter derivative); older GNOME uses Cantarell.
const adwaita_fonts = [_][]const u8{ "Adwaita Sans", "Cantarell", "Inter", "sans-serif" };
/// Plasma's default UI font.
const breeze_fonts = [_][]const u8{ "Noto Sans", "Inter", "sans-serif" };
const macos_fonts = [_][]const u8{".SystemUIFont"};

/// `0xRRGGBB` with alpha.
pub fn rgbA(v: u32, a: f32) Hsla {
    var c = color.rgb(v);
    c.a = a;
    return c.toHsla();
}

pub fn rgbOf(v: u32) color.Rgba {
    return color.rgb(v);
}

/// Linear blend in sRGB of `a` toward `b` by `t` (alpha too): CSS `color-mix(in srgb)`.
pub fn mix(a: Hsla, b: Hsla, t: f32) Hsla {
    const x = a.toRgba();
    const y = b.toRgba();
    const k = std.math.clamp(t, 0, 1);
    const out: color.Rgba = .{
        .r = x.r + (y.r - x.r) * k,
        .g = x.g + (y.g - x.g) * k,
        .b = x.b + (y.b - x.b) * k,
        .a = x.a + (y.a - x.a) * k,
    };
    return out.toHsla();
}

/// `top` composited over opaque `bottom` (an opaque result).
pub fn over(top: Hsla, bottom: Hsla) Hsla {
    const t = top.toRgba();
    const b = bottom.toRgba();
    const out: color.Rgba = .{
        .r = t.r * t.a + b.r * (1 - t.a),
        .g = t.g * t.a + b.g * (1 - t.a),
        .b = t.b * t.a + b.b * (1 - t.a),
        .a = 1,
    };
    return out.toHsla();
}

/// Relative luminance (WCAG) of an sRGB color.
pub fn luminance(c: Hsla) f32 {
    const r = c.toRgba();
    const lin = struct {
        fn f(v: f32) f32 {
            return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
        }
    }.f;
    return 0.2126 * lin(r.r) + 0.7152 * lin(r.g) + 0.0722 * lin(r.b);
}

/// Everything a drawn control or preference page needs from the desktop theme.
pub const Look = struct {
    family: Family,
    dark: bool,

    // -- surfaces -----------------------------------------------------------------------
    window_bg: Hsla,
    view_bg: Hsla,
    card_bg: Hsla,
    popover_bg: Hsla,
    /// Text.
    fg: Hsla,
    /// Secondary text (subtitles, descriptions).
    fg_dim: Hsla,
    /// Row separators inside boxed lists / grouped forms.
    separator: Hsla,
    /// Frame outlines (Breeze buttons and fields, popover borders).
    outline: Hsla,

    // -- accent -------------------------------------------------------------------------
    /// Accent fill (switch on, checkbox checked, slider highlight).
    accent: Hsla,
    /// Text / icons on `accent`.
    accent_fg: Hsla,
    /// Keyboard focus ring.
    focus_ring: Hsla,

    // -- buttons ------------------------------------------------------------------------
    button_bg: Hsla,
    button_hover: Hsla,
    button_active: Hsla,
    /// Selected segment of a toggle group.
    toggle_checked: Hsla,
    toggle_group_bg: Hsla,

    // -- switches, checks, sliders -----------------------------------------------------
    trough: Hsla,
    trough_hover: Hsla,
    knob: Hsla,
    knob_border: Hsla,
    check_border: Hsla,
    check_bg: Hsla,
    /// Popover / menu row hover.
    item_hover: Hsla,

    // -- metrics ------------------------------------------------------------------------
    /// UI font families, preferred first (the first one installed is used).
    fonts: []const []const u8,
    font_size: Pixels,
    small_font_size: Pixels,
    line_height: Pixels,
    /// Buttons, drop-downs, spin buttons, toggle groups.
    control_height: Pixels,
    button_radius: Pixels,
    card_radius: Pixels,
    popover_radius: Pixels,
    /// Opacity of insensitive controls.
    disabled_opacity: f32,

    pub fn shadowColor(self: Look, a: f32) Hsla {
        return if (self.dark) rgbA(0x000006, a * 2) else rgbA(0x000006, a);
    }
};

/// The look for `family` in light or dark, with the system accent (0xRRGGBB, null =
/// the toolkit default).
pub fn look(family: Family, dark: bool, accent: ?u32) Look {
    return switch (family) {
        .adwaita => adwaita(dark, accent orelse adwaita_accent),
        .breeze => breeze(dark, accent orelse breeze_accent),
        .macos => macos(dark, accent orelse macos_accent),
    };
}

/// Text color for `bg` the way libadwaita picks `--accent-fg-color`: white unless the
/// accent is light (yellow).
fn onAccent(bg: Hsla) Hsla {
    return if (luminance(bg) > 0.45) rgbA(0x000000, 0.8) else rgbA(0xffffff, 1);
}

fn adwaita(dark: bool, accent_rgb: u32) Look {
    const accent = rgbA(accent_rgb, 1);
    // libadwaita 1.6: `--accent-color` (text/focus) is the accent pushed toward the
    // background's contrast; a 50 % alpha of it is the focus ring.
    const accent_text = if (dark) mix(accent, rgbA(0xffffff, 1), 0.35) else mix(accent, rgbA(0x000000, 1), 0.15);
    if (dark) {
        const fg = rgbA(0xffffff, 1);
        const window_bg = rgbA(0x222226, 1);
        return .{
            .family = .adwaita,
            .dark = true,
            .window_bg = window_bg,
            .view_bg = rgbA(0x1d1d20, 1),
            .card_bg = over(rgbA(0xffffff, 0.08), window_bg),
            .popover_bg = rgbA(0x36363a, 1),
            .fg = fg,
            .fg_dim = rgbA(0xffffff, 0.55),
            .separator = rgbA(0x000006, 0.36),
            .outline = rgbA(0x000006, 0.5),
            .accent = accent,
            .accent_fg = onAccent(accent),
            .focus_ring = accent_text.alpha(0.5),
            .button_bg = rgbA(0xffffff, 0.10),
            .button_hover = rgbA(0xffffff, 0.15),
            .button_active = rgbA(0xffffff, 0.30),
            .toggle_checked = rgbA(0xffffff, 0.20),
            .toggle_group_bg = rgbA(0xffffff, 0.08),
            .trough = rgbA(0xffffff, 0.15),
            .trough_hover = rgbA(0xffffff, 0.20),
            .knob = rgbA(0xffffff, 1),
            .knob_border = rgbA(0x000000, 0.0),
            .check_border = rgbA(0xffffff, 0.15),
            .check_bg = rgbA(0xffffff, 0),
            .item_hover = rgbA(0xffffff, 0.07),
            .fonts = &adwaita_fonts,
        .font_size = 14.67,
            .small_font_size = 12.5,
            .line_height = 20,
            .control_height = 34,
            .button_radius = 6,
            .card_radius = 12,
            .popover_radius = 12,
            .disabled_opacity = 0.5,
        };
    }
    // `--window-fg-color: rgb(0 0 6 / 80%)`; translucent blacks are tinted the same.
    const fg = rgbA(0x000006, 0.8);
    return .{
        .family = .adwaita,
        .dark = false,
        .window_bg = rgbA(0xfafafb, 1),
        .view_bg = rgbA(0xffffff, 1),
        .card_bg = rgbA(0xffffff, 1),
        .popover_bg = rgbA(0xffffff, 1),
        .fg = fg,
        .fg_dim = rgbA(0x000006, 0.8 * 0.55),
        .separator = rgbA(0x000006, 0.07),
        .outline = rgbA(0x000006, 0.14),
        .accent = accent,
        .accent_fg = onAccent(accent),
        .focus_ring = accent_text.alpha(0.5),
        .button_bg = rgbA(0x000006, 0.08),
        .button_hover = rgbA(0x000006, 0.12),
        .button_active = rgbA(0x000006, 0.24),
        .toggle_checked = rgbA(0xffffff, 1),
        .toggle_group_bg = rgbA(0x000006, 0.07),
        .trough = rgbA(0x000006, 0.12),
        .trough_hover = rgbA(0x000006, 0.16),
        .knob = rgbA(0xffffff, 1),
        .knob_border = rgbA(0x000006, 0.0),
        .check_border = rgbA(0x000006, 0.12),
        .check_bg = rgbA(0xffffff, 0),
        .item_hover = rgbA(0x000006, 0.06),
        .fonts = &adwaita_fonts,
        .font_size = 14.67,
        .small_font_size = 12.5,
        .line_height = 20,
        .control_height = 34,
        .button_radius = 6,
        .card_radius = 12,
        .popover_radius = 12,
        .disabled_opacity = 0.5,
    };
}

fn breeze(dark: bool, accent_rgb: u32) Look {
    const accent = rgbA(accent_rgb, 1);
    // BreezeLight / BreezeDark (Plasma 6) color schemes.
    const window_bg = if (dark) rgbA(0x202326, 1) else rgbA(0xeff0f1, 1);
    const view_bg = if (dark) rgbA(0x141618, 1) else rgbA(0xffffff, 1);
    const button_bg = if (dark) rgbA(0x292c30, 1) else rgbA(0xfcfcfc, 1);
    const fg = if (dark) rgbA(0xfcfcfc, 1) else rgbA(0x232629, 1);
    // Breeze frames: `KColorUtils::mix(background, foreground, 0.3)`.
    const outline = mix(button_bg, fg, if (dark) 0.25 else 0.3);
    return .{
        .family = .breeze,
        .dark = dark,
        .window_bg = window_bg,
        .view_bg = view_bg,
        .card_bg = view_bg,
        .popover_bg = if (dark) rgbA(0x292c30, 1) else rgbA(0xffffff, 1),
        .fg = fg,
        .fg_dim = if (dark) rgbA(0xa1a9b1, 1) else rgbA(0x707d8a, 1),
        .separator = mix(window_bg, fg, 0.2),
        .outline = outline,
        .accent = accent,
        .accent_fg = rgbA(0xffffff, 1),
        .focus_ring = accent,
        .button_bg = button_bg,
        .button_hover = mix(button_bg, accent, 0.08),
        .button_active = mix(button_bg, accent, 0.25),
        .toggle_checked = mix(button_bg, accent, if (dark) 0.35 else 0.25),
        .toggle_group_bg = button_bg,
        .trough = mix(window_bg, fg, 0.2),
        .trough_hover = mix(window_bg, fg, 0.25),
        .knob = button_bg,
        .knob_border = outline,
        .check_border = outline,
        .check_bg = view_bg,
        .item_hover = mix(view_bg, accent, 0.25),
        .fonts = &breeze_fonts,
        .font_size = 13.33,
        .small_font_size = 11.5,
        .line_height = 18,
        .control_height = 30,
        .button_radius = 5,
        .card_radius = 5,
        .popover_radius = 5,
        .disabled_opacity = 0.45,
    };
}

fn macos(dark: bool, accent_rgb: u32) Look {
    const accent = rgbA(accent_rgb, 1);
    const fg = if (dark) rgbA(0xffffff, 0.85) else rgbA(0x000000, 0.85);
    // System Settings: grouped `Form` sections on the window background.
    return .{
        .family = .macos,
        .dark = dark,
        .window_bg = if (dark) rgbA(0x1e1e1e, 1) else rgbA(0xf2f2f2, 1),
        .view_bg = if (dark) rgbA(0x1e1e1e, 1) else rgbA(0xffffff, 1),
        .card_bg = if (dark) rgbA(0xffffff, 0.05) else rgbA(0x000000, 0.035),
        .popover_bg = if (dark) rgbA(0x2c2c2e, 1) else rgbA(0xffffff, 1),
        .fg = fg,
        .fg_dim = if (dark) rgbA(0xffffff, 0.5) else rgbA(0x000000, 0.5),
        .separator = if (dark) rgbA(0xffffff, 0.08) else rgbA(0x000000, 0.08),
        .outline = if (dark) rgbA(0xffffff, 0.08) else rgbA(0x000000, 0.06),
        .accent = accent,
        .accent_fg = rgbA(0xffffff, 1),
        .focus_ring = accent.alpha(0.5),
        .button_bg = if (dark) rgbA(0xffffff, 0.15) else rgbA(0xffffff, 1),
        .button_hover = if (dark) rgbA(0xffffff, 0.2) else rgbA(0xf6f6f6, 1),
        .button_active = if (dark) rgbA(0xffffff, 0.3) else rgbA(0xe0e0e0, 1),
        .toggle_checked = if (dark) rgbA(0xffffff, 0.25) else rgbA(0xffffff, 1),
        .toggle_group_bg = if (dark) rgbA(0xffffff, 0.08) else rgbA(0x000000, 0.06),
        .trough = if (dark) rgbA(0xffffff, 0.15) else rgbA(0x000000, 0.1),
        .trough_hover = if (dark) rgbA(0xffffff, 0.2) else rgbA(0x000000, 0.14),
        .knob = rgbA(0xffffff, 1),
        .knob_border = rgbA(0x000000, 0.1),
        .check_border = if (dark) rgbA(0xffffff, 0.2) else rgbA(0x000000, 0.2),
        .check_bg = if (dark) rgbA(0xffffff, 0.1) else rgbA(0xffffff, 1),
        .item_hover = accent,
        .fonts = &macos_fonts,
        .font_size = 13,
        .small_font_size = 11,
        .line_height = 16,
        .control_height = 22,
        .button_radius = 5,
        .card_radius = 10,
        .popover_radius = 8,
        .disabled_opacity = 0.4,
    };
}

/// `c` is `want` (0xRRGGBB) within HSLA round-off.
fn expectRgb(want: u32, c: Hsla) !void {
    const got = c.toRgba();
    const w = color.rgb(want);
    for ([_]f32{ got.r - w.r, got.g - w.g, got.b - w.b }) |d| try std.testing.expect(@abs(d) <= 1.5 / 255.0);
}

test "looks: light/dark surfaces, accent and contrast" {
    const t = std.testing;
    const light = look(.adwaita, false, null);
    const dark = look(.adwaita, true, null);
    try t.expect(luminance(light.window_bg) > 0.9);
    try t.expect(luminance(dark.window_bg) < 0.05);
    try expectRgb(adwaita_accent, light.accent);
    // A system accent replaces the default; a light (yellow) accent gets dark text.
    const orange = look(.adwaita, false, 0xed5b00);
    try expectRgb(0xed5b00, orange.accent);
    try t.expect(luminance(orange.accent_fg) > 0.9);
    const yellow = look(.adwaita, false, 0xf6d32d);
    try t.expect(luminance(yellow.accent_fg) < 0.1);
    const kde = look(.breeze, false, null);
    try expectRgb(breeze_accent, kde.accent);
    try t.expect(kde.control_height < light.control_height);
    const mac = look(.macos, true, null);
    try t.expect(mac.dark and mac.family == .macos);
}

test "mix and over" {
    const t = std.testing;
    const black = rgbA(0x000000, 1);
    const white = rgbA(0xffffff, 1);
    const half = mix(black, white, 0.5).toRgba();
    try t.expectApproxEqAbs(@as(f32, 0.5), half.r, 1e-3);
    const o = over(rgbA(0xffffff, 0.25), black).toRgba();
    try t.expectApproxEqAbs(@as(f32, 0.25), o.g, 1e-3);
    try t.expectEqual(@as(f32, 1), o.a);
}
