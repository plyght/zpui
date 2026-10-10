//! The UI theme: one semantic token set resolved from a `ThemeVariant` (port
//! of zeron `crates/ui/src/theme.rs`).
//!
//! **Numbers drive layout, colors are paint**: layout constants live in
//! `layout.zig` and never depend on the painted palette.
//!
//! Light is designed, not inverted: in light mode the content plane is white
//! and chrome goes grey, elevation comes from border + shadow rather than
//! lightness, and accents move down the scale to keep WCAG AA. `Theme.dark()`
//! / `Theme.light()` are the authored fallbacks; at runtime the app resolves a
//! registered variant with `Theme.forSelection`.
//!
//! zeron reads the appearance for its context-free paint helpers (`ink`,
//! `hairline`, `wash`, ...) from a process global; here they take it explicitly.

const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const cs = @import("colorspace.zig");
const registry = @import("registry.zig");
const typography = @import("typography.zig");

pub const Hsla = cs.Hsla;
const hsla = cs.hsla;
const grey = cs.grey;
const neutral = cs.neutral;
const oklch = cs.oklch;
const flatten = cs.flatten;
const paintedContrast = cs.paintedContrast;

pub const Appearance = model.Appearance;
pub const SurfaceTreatment = model.SurfaceTreatment;
pub const SurfacePreference = model.SurfacePreference;
pub const AccentSelection = model.AccentSelection;
/// User-selectable accent family (zeron's UI `AccentColor` mirrors the model preset).
pub const AccentColor = model.AccentPreset;
pub const HighlightKind = model.SyntaxKey;

const os = builtin.os.tag;
const glass_platform = os == .macos or os == .windows;

/// Light-mode alpha multiplier for fills (hover/active washes, chip plates).
/// The same number in both appearances: only the tone flips.
pub const ink_fill_scale: f32 = 1.0;
/// Light-mode alpha multiplier for hairlines: a 1px edge needs more ink on white.
pub const ink_hairline_scale: f32 = 1.35;
/// Alpha of the standard modal backdrop, quoted in dark-mode terms.
pub const scrim_alpha_dark: f32 = 0.60;
/// The Claude mark's brand orange, applied at the call site.
pub const claude_brand: Hsla = cs.fromModel(.rgb(0xD9, 0x77, 0x57));

/// The three rows of the animated 2x3 pixel glyph: light -> mid -> deep.
pub const GlyphPalette = struct {
    light: Hsla,
    mid: Hsla,
    deep: Hsla,

    fn forAccent(primary: Hsla, strong: Hsla, appearance: Appearance) GlyphPalette {
        var light = primary;
        var deep = strong;
        switch (appearance) {
            .dark => {
                light.l = @min(light.l + 0.14, 0.90);
                light.s *= 0.72;
            },
            .light => {
                light.l = @min(light.l + 0.11, 0.76);
                light.s *= 0.78;
                deep.l = @max(deep.l - 0.09, 0.22);
            },
        }
        return .{ .light = light, .mid = primary, .deep = deep };
    }

    pub fn rows(self: GlyphPalette) [3]Hsla {
        return .{ self.light, self.mid, self.deep };
    }
};

const AccentTokens = struct {
    primary: Hsla,
    strong: Hsla,
    wash: Hsla,
    selection: Hsla,
    caret: Hsla,
    code_text: Hsla,
    code_wash: Hsla,
    activity: Hsla,
    glyph: GlyphPalette,
};

/// The authored OKLCH (primary, strong) pair of each accent preset; used by
/// the fallback themes (`Theme.dark()`/`light()`), not by registered variants.
fn accentTokens(accent: AccentColor, appearance: Appearance) AccentTokens {
    const dark = appearance.isDark();
    const pair: [2]Hsla = switch (accent) {
        .zeron => if (dark) .{ oklch(0.673, 0.182, 276.935), oklch(0.585, 0.233, 277.117) } else .{ oklch(0.511, 0.262, 276.966), oklch(0.511, 0.262, 276.966) },
        .orange => if (dark) .{ oklch(0.75, 0.18, 55.0), oklch(0.54, 0.19, 55.0) } else .{ oklch(0.50, 0.19, 55.0), oklch(0.50, 0.19, 55.0) },
        .amber => if (dark) .{ oklch(0.80, 0.17, 84.0), oklch(0.52, 0.14, 84.0) } else .{ oklch(0.48, 0.14, 84.0), oklch(0.48, 0.14, 84.0) },
        .green => if (dark) .{ oklch(0.75, 0.17, 150.0), oklch(0.50, 0.15, 150.0) } else .{ oklch(0.46, 0.14, 150.0), oklch(0.46, 0.14, 150.0) },
        .cyan => if (dark) .{ oklch(0.76, 0.13, 205.0), oklch(0.49, 0.12, 205.0) } else .{ oklch(0.45, 0.11, 205.0), oklch(0.45, 0.11, 205.0) },
        .blue => if (dark) .{ oklch(0.70, 0.17, 255.0), oklch(0.50, 0.20, 255.0) } else .{ oklch(0.47, 0.21, 255.0), oklch(0.47, 0.21, 255.0) },
        .pink => if (dark) .{ oklch(0.72, 0.18, 350.0), oklch(0.51, 0.20, 350.0) } else .{ oklch(0.48, 0.20, 350.0), oklch(0.48, 0.20, 350.0) },
    };
    const primary, const strong = pair;
    return .{
        .primary = primary,
        .strong = strong,
        .wash = if (dark) strong.opacity(0.45) else primary.opacity(0.10),
        .selection = primary.opacity(if (dark) 0.35 else 0.24),
        .caret = primary,
        .code_text = primary,
        .code_wash = primary.opacity(if (dark) 0.12 else 0.10),
        .activity = primary,
        .glyph = .forAccent(primary, strong, appearance),
    };
}

/// Paint-only syntax colors, one per `HighlightKind` (`embedded` paints as
/// punctuation and has no slot of its own).
pub const SyntaxPalette = struct {
    colors: std.EnumArray(HighlightKind, Hsla),

    pub fn color(self: SyntaxPalette, kind: HighlightKind) Hsla {
        return self.colors.get(if (kind == .embedded) .punctuation else kind);
    }

    /// Variant colors where present, `fallback` elsewhere (markup roles etc.).
    fn fromVariant(variant: *const model.ThemeVariant, fallback: SyntaxPalette) SyntaxPalette {
        var out = fallback;
        for (std.enums.values(HighlightKind)) |k| {
            if (k == .embedded) continue;
            if (variant.syntax.get(k)) |c| out.colors.set(k, cs.fromModel(c));
        }
        return out;
    }

    /// Git-graph hue families (indigo, pink, emerald, amber) at 72% saturation.
    fn forAppearance(appearance: Appearance, text: Hsla, comment: Hsla, danger: Hsla) SyntaxPalette {
        const indigo, const pink, const emerald, const amber = switch (appearance) {
            .dark => .{ oklch(0.673, 0.182, 276.935), oklch(0.718, 0.202, 349.761), oklch(0.765, 0.177, 163.223), oklch(0.828, 0.189, 84.429) },
            .light => .{ oklch(0.47, 0.20, 276.966), oklch(0.47, 0.17, 0.584), oklch(0.46, 0.11, 163.225), oklch(0.47, 0.12, 48.998) },
        };
        const i = gitGraphTone(indigo);
        const p = gitGraphTone(pink);
        const e = gitGraphTone(emerald);
        const a = gitGraphTone(amber);
        var colors: std.EnumArray(HighlightKind, Hsla) = .init(.{
            .comment = comment,
            .keyword = i,
            .string = e,
            .string_special = p,
            .escape = p,
            .number = a,
            .boolean = a,
            .type_name = a,
            .type_builtin = e,
            .constructor = a,
            .function = i,
            .function_builtin = p,
            .macro_name = p,
            .property = a,
            .constant = e,
            .variable = text,
            .variable_special = p,
            .parameter = text,
            .operator = text,
            .punctuation = text,
            .tag = p,
            .attribute = a,
            .label = a,
            .markup_heading = i,
            .markup_raw = e,
            .markup_link = p,
            .markup_reference = a,
            .markup_emphasis = p,
            .markup_strong = i,
            .embedded = text,
            .invalid = gitGraphTone(danger),
        });
        colors.set(.embedded, colors.get(.punctuation));
        return .{ .colors = colors };
    }
};

fn gitGraphTone(color: Hsla) Hsla {
    var c = color;
    c.s *= 0.72;
    return c;
}

pub const TerminalColors = struct {
    background: Hsla,
    foreground: Hsla,
    selection: Hsla,
    ansi: [16]Hsla,

    pub fn fromVariant(variant: *const model.ThemeVariant) TerminalColors {
        var ansi: [16]Hsla = undefined;
        for (&ansi, variant.terminal.ansi) |*dst, c| dst.* = cs.fromModel(c);
        return .{
            .background = cs.fromModel(variant.terminal.background),
            .foreground = cs.fromModel(variant.terminal.foreground),
            .selection = cs.fromModel(variant.terminal.selection),
            .ansi = ansi,
        };
    }

    fn zeron(appearance: Appearance) TerminalColors {
        const id = if (appearance.isDark()) "zeron-dark" else "zeron-light";
        return fromVariant(registry.builtin.variant(id).?);
    }
};

/// How the platform should composite the window behind our paint.
pub const WindowBackgroundAppearance = enum { @"opaque", transparent, blurred };

/// Inputs for `Theme.forSelection`.
pub const Selection = struct {
    appearance: Appearance,
    variant_id: []const u8,
    accent: AccentSelection = .theme_default,
    surface: SurfacePreference = .theme_default,
    /// Effective wallpaper color overlay (see `wallpaper.zig`), if enabled.
    wallpaper_color: ?model.Color = null,
};

/// Liquid Glass tint strength (main.zig reads ZERON_GLASS_TINT).
pub var glass_tint_strength: f32 = 0.22;

const TintKey = struct { text: Hsla, text_muted: Hsla, tint: Hsla, base: f32, backdrop: Hsla };
threadlocal var tint_memo: [4]?struct { key: TintKey, alpha: f32 } = @splat(null);
threadlocal var tint_memo_next: usize = 0;
threadlocal var popup_memo: ?struct { in: Theme, out: Theme } = null;

pub const Theme = struct {
    /// Which appearance these tokens were built for.
    appearance: Appearance,
    /// Stable id of the resolved theme variant.
    variant_id: []const u8,
    /// Family owning `variant_id`.
    family_id: []const u8,
    /// Whether the base theme or a user preset owns interactive identity.
    accent_selection: AccentSelection,
    /// Effective wallpaper overlay; manual theme/accent selections stay intact.
    wallpaper_color: ?model.Color = null,
    /// The persisted policy that resolved `surface_treatment`.
    surface_preference: SurfacePreference,
    /// Effective treatment after applying the preference to the variant's recommendation.
    surface_treatment: SurfaceTreatment,
    /// [liquid-glass] Native Liquid Glass is on: the preference is `.liquid` (or forced)
    /// AND the platform supports it (set by the settings store, never by the token math).
    liquid_glass: bool = false,
    /// The accent family used to build the fallback tokens.
    accent_color: AccentColor,

    // ---- neutral surfaces ----
    /// Main content panel (dark: deepest plane; light: pure white).
    bg: Hsla,
    /// Shell / sidebar surface (one step up in dark, grey in light).
    surface: Hsla,
    /// Opaque pills and chips that sit proud of the panel.
    surface_raised: Hsla,

    // ---- elevation ladder (dark distinguishes planes by small lightness steps) ----
    /// Inline card resting on the main panel.
    surface_card: Hsla,
    /// Modal dialog over a scrim.
    surface_dialog: Hsla,
    /// Popover, menu and command-palette surface: the highest plane.
    surface_overlay: Hsla,
    /// Hover wash for interactive rows/buttons.
    element_hover: Hsla,
    /// Active/selected wash.
    element_active: Hsla,
    /// Hairline border.
    border: Hsla,
    /// Stronger border for focused/raised edges.
    border_strong: Hsla,

    // ---- text ----
    text: Hsla,
    /// Timestamps, secondary labels.
    text_muted: Hsla,
    /// Placeholders, disabled.
    text_faint: Hsla,
    /// One notch below `text_muted` (diff file paths).
    text_dim: Hsla,

    // ---- high-contrast solid (primary buttons) ----
    solid: Hsla,
    on_solid: Hsla,

    // ---- accents & status ----
    accent: Hsla,
    /// Fill that carries `on_accent` text.
    accent_strong: Hsla,
    accent_wash: Hsla,
    on_accent: Hsla,
    danger: Hsla,
    danger_muted: Hsla,
    warning: Hsla,
    warning_muted: Hsla,
    success: Hsla,
    /// Working / streaming indicator.
    busy: Hsla,
    glyph: GlyphPalette,
    success_muted: Hsla,

    // ---- components ----
    /// Hover tone for an opaque raised pill (brightens, never goes translucent).
    surface_raised_hover: Hsla,
    /// Recessed band behind palette/picker header or footer strips.
    band: Hsla,
    /// Composer pill and other input plates.
    input_bg: Hsla,
    selection: Hsla,
    /// Terminal block cursor.
    cursor: Hsla,
    /// Composer text caret.
    caret: Hsla,
    /// Destructive-action button fill.
    danger_strong: Hsla,

    // ---- code & diff ----
    code_text: Hsla,
    code_wash: Hsla,
    syntax: SyntaxPalette,
    diff_add: Hsla,
    diff_del: Hsla,
    diff_hunk_bg: Hsla,
    terminal: TerminalColors,

    // ---- fonts ----
    font_sans: []const u8 = typography.font_sans,
    /// Fixed Geist chrome for code-adjacent surfaces.
    font_sans_fixed: []const u8 = typography.font_sans,
    /// User-selected family for code, diffs, and file editors.
    font_mono: []const u8 = typography.font_mono,
    font_terminal: []const u8 = typography.font_mono,
    code_font_size: f32 = typography.code_font_size_default,
    terminal_font_size: f32 = typography.terminal_font_size_default,
    font_sans_fallback: []const u8 = typography.system_sans,
    font_mono_fallback: []const u8 = typography.system_mono,

    /// Window frost alpha over the blurred desktop (macOS vibrancy / Windows
    /// Acrylic). Opaque elsewhere: compositor blur is not guaranteed.
    pub const glass_alpha: f32 = if (glass_platform) 0.80 else 1.0;
    /// Light-mode frost alpha.
    pub const glass_alpha_light: f32 = if (glass_platform) 0.80 else 1.0;
    /// [liquid-glass] Max alpha of a surface fill laid over native glass (`onGlass`).
    pub const liquid_fill_alpha: f32 = 0.10;

    /// The authored dark theme (surface tones sampled from the original app).
    pub fn dark() Theme {
        return darkWithAccent(.zeron);
    }

    pub fn darkWithAccent(accent_color: AccentColor) Theme {
        const accent = accentTokens(accent_color, .dark);
        return .{
            .appearance = .dark,
            .variant_id = "zeron-dark",
            .family_id = "zeron",
            .accent_selection = .{ .preset = accent_color },
            .surface_preference = .theme_default,
            .surface_treatment = .frosted,
            .accent_color = accent_color,
            .bg = grey(6),
            .surface = grey(13),
            .surface_raised = neutral(0.235),
            .surface_card = grey(0x0e),
            .surface_dialog = grey(0x10),
            .surface_overlay = grey(0x16),
            .element_hover = hsla(0, 0, 0.92, 0.11),
            .element_active = hsla(0, 0, 0.92, 0.16),
            .border = hsla(0, 0, 1, 0.08),
            .border_strong = hsla(0, 0, 1, 0.14),
            .text = neutral(0.922),
            .text_muted = neutral(0.708),
            .text_faint = neutral(0.556),
            .text_dim = grey(0x98),
            .solid = neutral(0.922),
            .on_solid = grey(0x0e),
            .accent = accent.primary,
            .accent_strong = accent.strong,
            .accent_wash = accent.wash,
            .on_accent = neutral(0.985),
            .danger = oklch(0.704, 0.191, 22.216),
            .danger_muted = oklch(0.808, 0.114, 19.571),
            .warning = oklch(0.828, 0.189, 84.429),
            .warning_muted = oklch(0.924, 0.12, 95.746),
            .success = oklch(0.765, 0.177, 163.223),
            .busy = accent.activity,
            .glyph = accent.glyph,
            .success_muted = oklch(0.845, 0.143, 164.978),
            .surface_raised_hover = neutral(0.29),
            .band = bandFor(.dark),
            .input_bg = hsla(0, 0, 1, 0.03),
            .selection = accent.selection,
            .cursor = hsla(0, 0, 1, 0.35),
            .caret = accent.caret,
            .danger_strong = oklch(0.58, 0.16, 25.0),
            .code_text = accent.code_text,
            .code_wash = accent.code_wash,
            .syntax = .forAppearance(.dark, neutral(0.922), neutral(0.60), oklch(0.704, 0.191, 22.216)),
            .diff_add = oklch(0.765, 0.177, 163.223),
            .diff_del = oklch(0.704, 0.191, 22.216),
            .diff_hunk_bg = hsla(0.6, 0.35, 0.6, 0.05),
            .terminal = .zeron(.dark),
        };
    }

    /// The authored light theme: roles reassigned (white content plane, grey
    /// chrome), text tones paired to dark by contrast ratio.
    pub fn light() Theme {
        return lightWithAccent(.zeron);
    }

    pub fn lightWithAccent(accent_color: AccentColor) Theme {
        const accent = accentTokens(accent_color, .light);
        return .{
            .appearance = .light,
            .variant_id = "zeron-light",
            .family_id = "zeron",
            .accent_selection = .{ .preset = accent_color },
            .surface_preference = .theme_default,
            .surface_treatment = .frosted,
            .accent_color = accent_color,
            .bg = grey(0xff),
            .surface = neutral(0.968),
            .surface_raised = neutral(0.940),
            .surface_card = grey(0xff),
            .surface_dialog = grey(0xff),
            .surface_overlay = grey(0xff),
            .element_hover = hsla(0, 0, 0.10, 0.06),
            .element_active = hsla(0, 0, 0.10, 0.10),
            .border = hsla(0, 0, 0, 0.10),
            .border_strong = hsla(0, 0, 0, 0.17),
            .text = neutral(0.25),
            .text_muted = neutral(0.439),
            .text_faint = neutral(0.535),
            .text_dim = neutral(0.50),
            .solid = neutral(0.205),
            .on_solid = neutral(0.985),
            .accent = accent.primary,
            .accent_strong = accent.strong,
            .accent_wash = accent.wash,
            .on_accent = neutral(0.985),
            .danger = oklch(0.577, 0.245, 27.325),
            .danger_muted = oklch(0.505, 0.213, 27.518),
            .warning = oklch(0.555, 0.163, 48.998),
            .warning_muted = oklch(0.473, 0.137, 46.201),
            .success = oklch(0.596, 0.145, 163.225),
            .busy = accent.activity,
            .glyph = accent.glyph,
            .success_muted = oklch(0.508, 0.118, 165.612),
            .surface_raised_hover = neutral(0.900),
            .band = bandFor(.light),
            .input_bg = grey(0xff),
            .selection = accent.selection,
            .cursor = hsla(0, 0, 0, 0.55),
            .caret = accent.caret,
            .danger_strong = oklch(0.51, 0.20, 25.0),
            .code_text = accent.code_text,
            .code_wash = accent.code_wash,
            .syntax = .forAppearance(.light, neutral(0.25), neutral(0.48), oklch(0.505, 0.213, 27.518)),
            .diff_add = oklch(0.596, 0.145, 163.225),
            .diff_del = oklch(0.577, 0.245, 27.325),
            .diff_hunk_bg = hsla(0.6, 0.35, 0.35, 0.07),
            .terminal = .zeron(.light),
        };
    }

    pub fn forPreferences(appearance: Appearance, accent: AccentColor) Theme {
        return switch (appearance) {
            .dark => darkWithAccent(accent),
            .light => lightWithAccent(accent),
        };
    }

    /// Resolve a registered variant for `sel.appearance` (falling back to the
    /// Zeron variant when the id is unknown or of the other appearance), then
    /// apply the accent policy, surface preference and wallpaper overlay.
    pub fn forSelection(reg: *const registry.Registry, sel: Selection) Theme {
        const fallback_id = if (sel.appearance.isDark()) "zeron-dark" else "zeron-light";
        const variant = blk: {
            if (reg.variant(sel.variant_id)) |v| if (v.appearance == sel.appearance) break :blk v;
            break :blk reg.variant(fallback_id).?;
        };
        const color = sel.wallpaper_color orelse return fromVariant(variant, sel.accent, sel.surface);
        var tinted = variant.*;
        @import("wallpaper.zig").tintVariant(&tinted, color);
        var theme = fromVariant(&tinted, .theme_default, sel.surface);
        theme.accent_selection = sel.accent;
        theme.wallpaper_color = color;
        if (theme.surface_treatment == .frosted) {
            // Glass interactions lift toward white rather than laying a dark
            // wallpaper accent over the translucent surface.
            theme.element_hover = cs.hsla(0, 0, 1, 0.09);
            theme.element_active = cs.hsla(0, 0, 1, 0.15);
            theme.band = theme.element_hover;
        }
        return theme;
    }

    /// Map a complete variant onto the semantic tokens. Curated built-ins are
    /// taken verbatim; anything else has its text hardened to 4.5:1.
    pub fn fromVariant(variant: *const model.ThemeVariant, accent_selection: AccentSelection, surface_preference: SurfacePreference) Theme {
        const accent_color: AccentColor = switch (accent_selection) {
            .theme_default => .zeron,
            .preset => |p| p,
        };
        var theme = forPreferences(variant.appearance, accent_color);
        const colors = &variant.colors;
        const accent = variant.accentFor(accent_selection);
        const text_backgrounds = [_]model.Color{ colors.background, colors.shell, colors.raised, colors.card, colors.dialog, colors.overlay, colors.input };
        const curated = registry.isCuratedBuiltin(variant);
        const safe_text = if (curated) colors.text else hardenForeground(colors.text, &text_backgrounds, 4.5, null);
        const safe_text_muted = if (curated) colors.text_muted else hardenForeground(colors.text_muted, &text_backgrounds, 4.5, safe_text);
        const m = cs.fromModel;
        theme.variant_id = variant.id;
        theme.family_id = variant.family_id;
        theme.accent_selection = accent_selection;
        theme.surface_preference = surface_preference;
        theme.surface_treatment = surface_preference.resolve(variant.recommended_surface_treatment);
        theme.bg = m(colors.background);
        theme.surface = m(colors.shell);
        theme.surface_raised = m(colors.raised);
        theme.surface_card = m(colors.card);
        theme.surface_dialog = m(colors.dialog);
        theme.surface_overlay = m(colors.overlay);
        theme.element_hover = m(colors.hover);
        theme.element_active = m(colors.active);
        theme.border = m(colors.border);
        theme.border_strong = m(colors.border_strong);
        theme.text = m(safe_text);
        theme.text_muted = m(safe_text_muted);
        theme.text_faint = m(colors.text_faint);
        theme.text_dim = m(safe_text_muted);
        theme.solid = m(colors.solid);
        theme.on_solid = m(if (curated) colors.on_solid else hardenForeground(colors.on_solid, &.{colors.solid}, 4.5, safe_text));
        theme.accent = m(accent.primary);
        theme.accent_strong = m(accent.strong);
        theme.accent_wash = m(accent.wash);
        theme.on_accent = m(accent.on);
        theme.danger = m(colors.danger);
        theme.danger_muted = m(colors.danger_muted);
        theme.warning = m(colors.warning);
        theme.warning_muted = m(colors.warning_muted);
        theme.success = m(colors.success);
        theme.success_muted = m(colors.success_muted);
        theme.busy = m(accent.activity);
        theme.glyph = .{ .light = m(accent.glyph[0]), .mid = m(accent.glyph[1]), .deep = m(accent.glyph[2]) };
        theme.surface_raised_hover = m(colors.raised);
        theme.band = m(colors.hover);
        theme.input_bg = m(colors.input);
        theme.selection = m(accent.selection);
        theme.cursor = m(colors.cursor);
        theme.caret = m(accent.caret);
        theme.danger_strong = m(colors.danger);
        theme.code_text = m(accent.primary);
        theme.code_wash = m(accent.wash);
        theme.syntax = .fromVariant(variant, theme.syntax);
        theme.diff_add = m(colors.diff_add);
        theme.diff_del = m(colors.diff_delete);
        theme.diff_hunk_bg = m(colors.diff_hunk);
        theme.terminal = .fromVariant(variant);
        if (!curated) {
            theme.terminal.foreground = m(hardenForeground(variant.terminal.foreground, &.{variant.terminal.background}, 4.5, safe_text));
        }
        return theme;
    }

    // ---- glass ----

    /// The theme's shell tint over the blurred window background; opaque
    /// themes paint the plain surface.
    pub fn glass(self: Theme) Hsla {
        if (self.surface_treatment == .opaque_) return self.surface;
        const base = if (self.appearance.isDark()) glass_alpha else glass_alpha_light;
        return self.surface.opacity(self.contrastCheckedTintAlpha(self.surface, base, self.adverseBackdrop()));
    }

    /// Raise `tint`'s coverage in 1/20 steps until primary text reaches 4.5:1
    /// and muted text 3:1 over `backdrop`.
    fn contrastCheckedTintAlpha(self: Theme, tint: Hsla, base: f32, backdrop: Hsla) f32 {
        // Pure, and asked for every frame (pow/log contrast steps): remember recent answers.
        const key: TintKey = .{ .text = self.text, .text_muted = self.text_muted, .tint = tint, .base = base, .backdrop = backdrop };
        for (&tint_memo) |*e| if (e.*) |m| if (std.meta.eql(m.key, key)) return m.alpha;
        const alpha = self.contrastCheckedTintAlphaUncached(tint, base, backdrop);
        tint_memo[tint_memo_next] = .{ .key = key, .alpha = alpha };
        tint_memo_next = (tint_memo_next + 1) % tint_memo.len;
        return alpha;
    }

    fn contrastCheckedTintAlphaUncached(self: Theme, tint: Hsla, base: f32, backdrop: Hsla) f32 {
        var step: u32 = 0;
        while (step <= 20) : (step += 1) {
            const alpha = base + (1.0 - base) * @as(f32, @floatFromInt(step)) / 20.0;
            const composite = flatten(tint.opacity(alpha), backdrop);
            if (paintedContrast(self.text, composite) >= 4.5 and paintedContrast(self.text_muted, composite) >= 3.0) return alpha;
        }
        return 1.0;
    }

    /// The worst-case desktop luminance behind glass: white for dark, black for light.
    pub fn adverseBackdrop(self: Theme) Hsla {
        return if (self.appearance.isDark()) grey(0xff) else grey(0);
    }

    /// Whether chrome paints translucently over the blurred desktop.
    pub fn isGlass(self: Theme) bool {
        return self.glass().a < 1.0;
    }

    /// Shared background for the editor host and the Files column.
    pub fn panelBg(self: Theme) Hsla {
        return if (self.isGlass()) self.bg.opacity(0.4) else self.bg;
    }

    /// Whether floating surfaces (popovers, composer) paint in-scene backdrop
    /// blur and translucent tints.
    pub fn isFrost(self: Theme) bool {
        return self.surface_treatment == .frosted and (os == .macos or os == .linux or os == .windows);
    }

    /// [liquid-glass] Chrome and floating surfaces use native Liquid Glass instead of
    /// in-scene frost (implies `isFrost`, whose token math stays in effect).
    /// Liquid Glass tint: the theme's shell surface, light enough to stay glass (macOS 27
    /// renders near-opaque tints solid). `ZERON_GLASS_TINT` overrides the strength
    /// (0 disables, default 0.22).
    pub fn glassTint(self: *const Theme) ?Hsla {
        if (glass_tint_strength <= 0) return null;
        return self.surface.alpha(glass_tint_strength);
    }

    pub fn isLiquid(self: Theme) bool {
        return self.liquid_glass and self.isFrost();
    }

    /// [liquid-glass] A surface fill that sits on native glass: a faint wash of it,
    /// so the glass shows through; unchanged otherwise.
    pub fn onGlass(self: Theme, fill: Hsla) Hsla {
        if (!self.isLiquid()) return fill;
        return fill.opacity(@min(fill.a, liquid_fill_alpha));
    }

    /// [liquid-glass] Hairline borders of glass surfaces: the glass draws its own rim.
    pub fn onGlassBorder(self: Theme, border: Hsla) Hsla {
        return if (self.isLiquid()) border.opacity(0) else border;
    }

    pub fn glassHover(self: Theme) Hsla {
        return self.element_hover;
    }

    /// Text hierarchy adjusted for floating (frosted) surfaces.
    pub fn forPopup(self: Theme) Theme {
        // Pure, and asked for every frame by the composer and popovers (each light frost
        // call runs up to 400 pow/log contrast steps): remember the last answer.
        if (popup_memo) |*m| if (std.meta.eql(m.in, self)) return m.out;
        const out = self.forPopupUncached();
        popup_memo = .{ .in = self, .out = out };
        return out;
    }

    fn forPopupUncached(self: Theme) Theme {
        var popup = self;
        if (!self.isFrost()) return popup;
        if (self.appearance.isDark()) {
            popup.text_muted = self.text.opacity(0.64);
            popup.text_faint = self.text.opacity(0.48);
            return popup;
        }
        var primary_surface = self;
        primary_surface.text_muted = self.text;
        const background = flatten(primary_surface.glassOverlay(), flatten(self.glass(), self.adverseBackdrop()));
        if (paintedContrast(popup.text, background) < 4.5) {
            var step: u32 = 1;
            while (step <= 100) : (step += 1) {
                popup.text = cs.mix(self.text, grey(0), @as(f32, @floatFromInt(step)) / 100.0);
                if (paintedContrast(popup.text, background) >= 4.5) break;
            }
        }
        for ([_]*Hsla{ &popup.text_muted, &popup.text_dim, &popup.text_faint }) |color| {
            const original = color.*;
            if (paintedContrast(original, background) >= 4.5) continue;
            var step: u32 = 1;
            while (step <= 100) : (step += 1) {
                color.* = cs.mix(original, popup.text, @as(f32, @floatFromInt(step)) / 100.0);
                if (paintedContrast(color.*, background) >= 4.5) break;
            }
        }
        return popup;
    }

    /// Settings pages: authored palette in dark, popup text in light.
    pub fn forSettingsSurface(self: Theme) Theme {
        return if (self.appearance.isDark()) self else self.forPopup();
    }

    /// Tint floating cards paint over their backdrop blur.
    pub fn glassOverlay(self: Theme) Hsla {
        if (!self.isFrost()) return self.surface_overlay;
        if (self.appearance == .light) return self.surface_overlay.opacity(0.45);
        return self.surface_overlay.opacity(self.contrastCheckedTintAlpha(self.surface_overlay, 0.50, self.adverseBackdrop()));
    }

    /// The composer pill's fill (dark frost tint, else input glass).
    pub fn composerSurfaceBg(self: Theme) Hsla {
        return if (self.isFrost() and self.appearance.isDark()) self.composerSidebarTint() else self.inputGlassBg();
    }

    /// The composer pill's edge: cool silver/slate on frost, else `border`.
    pub fn composerSurfaceBorder(self: Theme) Hsla {
        if (!self.isFrost()) return self.border;
        return switch (self.appearance) {
            .dark => hsla(210.0 / 360.0, 0.18, 0.78, 0.09),
            .light => hsla(210.0 / 360.0, 0.18, 0.32, 0.10),
        };
    }

    /// A color at 15% alpha solved so that, over the window glass, it lands on
    /// `bg @ 0.4` over glass (the dark floating-surface recipe).
    pub fn composerSidebarTint(self: Theme) Hsla {
        const target_hsla = if (self.isGlass()) flatten(self.bg.opacity(0.4), flatten(self.glass(), self.bg)) else self.bg;
        const canvas_hsla = flatten(self.glass(), self.bg);
        const canvas = cs.hslToRgb(canvas_hsla.h, canvas_hsla.s, canvas_hsla.l);
        const target = cs.hslToRgb(target_hsla.h, target_hsla.s, target_hsla.l);
        const eps = std.math.floatEps(f32);
        var alpha: f32 = 0.60;
        for (canvas, target) |base, desired| {
            const needed = if (desired > base) (desired - base) / @max(1.0 - base, eps) else (base - desired) / @max(base, eps);
            alpha = @max(alpha, needed);
        }
        var v: [3]f32 = undefined;
        for (&v, 0..) |*o, i| o.* = std.math.clamp((target[i] - canvas[i] * (1.0 - alpha)) / alpha, 0.0, 1.0);
        const h, const s, const l = cs.rgbToHsl(v[0], v[1], v[2]);
        return hsla(h, s, l, 0.15);
    }

    /// Shared fill for the composer, queue tray and input panels.
    pub fn inputGlassBg(self: Theme) Hsla {
        const tint = flatten(self.input_bg, self.bg);
        if (!self.isFrost()) return tint;
        if (self.appearance == .light) return tint.opacity(0.35);
        const window = flatten(self.glass(), self.adverseBackdrop());
        return self.input_bg.opacity(self.contrastCheckedTintAlpha(self.input_bg, self.input_bg.a, window));
    }

    /// Section-card fill: a translucent `surface` (>= 40%) on frost.
    pub fn cardGlassBg(self: Theme) Hsla {
        if (!self.isFrost()) return self.surface;
        const window = flatten(self.glass(), self.adverseBackdrop());
        return self.surface.opacity(self.contrastCheckedTintAlpha(self.surface, 0.40, window));
    }

    /// The standard modal backdrop.
    pub fn scrim(self: Theme) Hsla {
        return scrimFor(self.appearance, scrim_alpha_dark);
    }

    pub fn windowBackgroundAppearance(self: Theme) WindowBackgroundAppearance {
        if (os == .linux) return .transparent;
        return if (self.isGlass()) .blurred else .@"opaque";
    }

    /// Scrollbar thumb (normal, hover, active).
    pub fn scrollbarThumbColors(self: Theme) [3]Hsla {
        return .{ self.text.opacity(0.30), self.text.opacity(0.42), self.text.opacity(0.55) };
    }

    pub fn ink(self: Theme, alpha: f32) Hsla {
        return inkFor(self.appearance, alpha);
    }

    pub fn hairline(self: Theme, alpha: f32) Hsla {
        return hairlineFor(self.appearance, alpha);
    }

    pub fn wash(self: Theme, alpha: f32) Hsla {
        return washFor(self.appearance, alpha);
    }
};

/// Mix `color` toward a target (preferred, then black, then white) in 1%
/// steps until it reaches `minimum` contrast on every background; returns the
/// best candidate found otherwise.
pub fn hardenForeground(color: model.Color, backgrounds: []const model.Color, minimum: f32, preferred_target: ?model.Color) model.Color {
    const minContrast = struct {
        fn f(candidate: model.Color, bgs: []const model.Color) f32 {
            var m = std.math.inf(f32);
            for (bgs) |b| m = @min(m, candidate.contrast(b));
            return m;
        }
    }.f;
    if (minContrast(color, backgrounds) >= minimum) return color;
    var targets: [3]model.Color = undefined;
    var n: usize = 0;
    if (preferred_target) |t| {
        targets[0] = t;
        n = 1;
    }
    targets[n] = .black;
    targets[n + 1] = .white;
    n += 2;
    var best = color;
    var best_contrast = minContrast(color, backgrounds);
    for (targets[0..n]) |target| {
        var step: u32 = 1;
        while (step <= 100) : (step += 1) {
            const candidate = color.mix(target, @as(f32, @floatFromInt(step)) / 100.0);
            const contrast = minContrast(candidate, backgrounds);
            if (contrast > best_contrast) {
                best = candidate;
                best_contrast = contrast;
            }
            if (contrast >= minimum) return candidate;
        }
    }
    return best;
}

// ---- context-free paint helpers (appearance passed explicitly) ----

/// Translucent fill ink: white on dark, black on light. Alphas are quoted in
/// dark-mode terms.
pub fn inkFor(appearance: Appearance, alpha: f32) Hsla {
    return switch (appearance) {
        .dark => hsla(0, 0, 1, alpha),
        .light => hsla(0, 0, 0, alpha * ink_fill_scale),
    };
}

/// Translucent hairline ink (borders, dividers, rings); light scales x1.35, capped at 0.5.
pub fn hairlineFor(appearance: Appearance, alpha: f32) Hsla {
    return switch (appearance) {
        .dark => hsla(0, 0, 1, alpha),
        .light => hsla(0, 0, 0, @min(alpha * ink_hairline_scale, 0.5)),
    };
}

/// Interactive-state wash: softened ink that stops short of pure black/white.
pub fn washFor(appearance: Appearance, alpha: f32) Hsla {
    return switch (appearance) {
        .dark => hsla(0, 0, 0.92, alpha),
        .light => hsla(0, 0, 0.10, alpha * ink_fill_scale),
    };
}

/// Modal backdrop at `alpha_dark`; black in both appearances, light scaled to ~half.
pub fn scrimFor(appearance: Appearance, alpha_dark: f32) Hsla {
    return switch (appearance) {
        .dark => hsla(0, 0, 0, alpha_dark),
        .light => hsla(0, 0, 0, 0.32 * (alpha_dark / scrim_alpha_dark)),
    };
}

/// Recessed band behind a palette/picker header or footer strip.
pub fn bandFor(appearance: Appearance) Hsla {
    return switch (appearance) {
        .dark => hsla(0, 0, 0, 0.16),
        .light => hsla(0, 0, 0, 0.045),
    };
}

/// Selected-state glass wash (tabs, session rows); the ring distinguishes selection.
pub fn glassSelectedBg(appearance: Appearance) Hsla {
    return washFor(appearance, if (appearance.isDark()) 0.11 else 0.06);
}

/// The user message bubble's plate: one step softer than selection.
pub fn userBubbleBg(appearance: Appearance) Hsla {
    return washFor(appearance, if (appearance.isDark()) 0.08 else 0.04);
}

/// Selected rows and chips inside a floating card.
pub fn cardSelectedBg(appearance: Appearance) Hsla {
    return washFor(appearance, if (appearance.isDark()) 0.11 else 0.06);
}

/// Inset selection ring (spread 1px, no blur, no offset) for selected chips,
/// both on glass and inside floating cards.
pub const SelectedRing = struct {
    color: Hsla,
    spread_radius: f32 = 1.0,
    blur_radius: f32 = 0.0,
    inset: bool = true,
};

pub fn cardSelectedRing(appearance: Appearance) SelectedRing {
    return .{ .color = if (appearance.isDark()) hairlineFor(.dark, 0.09) else hsla(0, 0, 0, 0.07) };
}

// ---- Tests ----

const testing = std.testing;

test "zeron accent is the exact upstream default" {
    const d = Theme.dark();
    const l = Theme.light();
    try testing.expect(d.accent.eql(oklch(0.673, 0.182, 276.935)));
    try testing.expect(d.accent_strong.eql(oklch(0.585, 0.233, 277.117)));
    try testing.expect(d.code_text.eql(d.accent) and d.busy.eql(d.accent) and d.glyph.mid.eql(d.accent));
    try testing.expect(l.accent.eql(oklch(0.511, 0.262, 276.966)));
    try testing.expect(l.accent_strong.eql(l.accent));
}

test "text contrast is paired across appearances and clears AA" {
    const d = Theme.dark();
    const l = Theme.light();
    for ([_][2]Hsla{ .{ d.text, l.text }, .{ d.text_muted, l.text_muted }, .{ d.text_faint, l.text_faint } }) |pair| {
        try testing.expect(@abs(cs.contrastRatio(pair[0], d.bg) - cs.contrastRatio(pair[1], l.bg)) < 1.0);
    }
    for ([_]Theme{ d, l }) |t| {
        for ([_]struct { Hsla, f32 }{ .{ t.text, 4.5 }, .{ t.text_muted, 4.5 }, .{ t.text_dim, 4.5 }, .{ t.text_faint, 4.1 } }) |c| {
            try testing.expect(cs.contrastRatio(c[0], t.bg) >= c[1]);
            try testing.expect(cs.contrastRatio(c[0], t.surface) >= c[1]);
        }
    }
}

test "every accent is one coherent color identity" {
    const base_dark = Theme.dark();
    const base_light = Theme.light();
    for (AccentColor.all) |accent| {
        for ([_][2]Theme{ .{ .darkWithAccent(accent), base_dark }, .{ .lightWithAccent(accent), base_light } }) |pair| {
            const t, const baseline = pair;
            for ([_]Hsla{ t.bg, t.surface, t.surface_card }) |s| try testing.expect(cs.contrastRatio(t.accent, s) >= 4.5);
            try testing.expect(cs.contrastRatio(t.on_accent, t.accent_strong) >= 4.0);
            try testing.expect(t.selection.eql(t.accent.opacity(if (t.appearance.isDark()) 0.35 else 0.24)));
            try testing.expect(!t.glyph.light.eql(t.glyph.mid) and !t.glyph.deep.eql(t.glyph.mid));
            try testing.expect(t.danger.eql(baseline.danger) and t.success.eql(baseline.success));
            try testing.expect(t.syntax.color(.keyword).eql(baseline.syntax.color(.keyword)));
        }
    }
}

test "theme recommendation and surface override resolve independently" {
    const reg = &registry.builtin;
    const cat = Theme.forSelection(reg, .{ .appearance = .dark, .variant_id = "catppuccin-mocha" });
    try testing.expect(!cat.surface.eql(Theme.dark().surface));
    try testing.expectEqual(SurfaceTreatment.opaque_, cat.surface_treatment);
    try testing.expect(!cat.isGlass());
    const frosted = Theme.forSelection(reg, .{ .appearance = .dark, .variant_id = "catppuccin-mocha", .surface = .frosted });
    try testing.expectEqual(SurfaceTreatment.frosted, frosted.surface_treatment);
    try testing.expectEqual(frosted.surface.h, frosted.glass().h);
    const opaque_zeron = Theme.forSelection(reg, .{ .appearance = .dark, .variant_id = "zeron-dark", .surface = .opaque_ });
    try testing.expect(opaque_zeron.glass().eql(opaque_zeron.surface));
    // Unknown ids and wrong-appearance ids fall back to Zeron.
    try testing.expectEqualStrings("zeron-light", Theme.forSelection(reg, .{ .appearance = .light, .variant_id = "dracula" }).variant_id);
}

test "forced frost preserves shell text contrast for every builtin" {
    var it = registry.builtin.iterator();
    while (it.next()) |v| {
        const t = Theme.fromVariant(v, .theme_default, .frosted);
        const composite = flatten(t.glass(), t.adverseBackdrop());
        try testing.expect(paintedContrast(t.text, composite) >= 4.5);
        try testing.expect(paintedContrast(t.text_muted, composite) >= 3.0);
        for ([_]Hsla{ flatten(t.glassOverlay(), composite), flatten(t.cardGlassBg(), composite), flatten(t.inputGlassBg(), composite) }) |s| {
            try testing.expect(paintedContrast(t.text, s) >= 4.5);
            try testing.expect(paintedContrast(t.text_muted, s) >= 3.0);
        }
    }
}

test "runtime hardening protects custom edits and leaves builtins unchanged" {
    var v = registry.builtin.variant("zeron-dark").?.*;
    v.colors.text = v.colors.background;
    v.colors.text_muted = v.colors.background;
    v.colors.on_solid = v.colors.solid;
    v.terminal.foreground = v.terminal.background;
    const t = Theme.fromVariant(&v, .theme_default, .opaque_);
    try testing.expect(paintedContrast(t.text, t.bg) >= 4.5);
    try testing.expect(paintedContrast(t.text_muted, t.bg) >= 4.5);
    try testing.expect(paintedContrast(t.on_solid, t.solid) >= 4.5);
    try testing.expect(paintedContrast(t.terminal.foreground, t.terminal.background) >= 4.5);

    var it = registry.builtin.iterator();
    while (it.next()) |b| {
        const bt = Theme.fromVariant(b, .theme_default, .opaque_);
        try testing.expect(bt.text.eql(cs.fromModel(b.colors.text)));
        try testing.expect(bt.text_muted.eql(cs.fromModel(b.colors.text_muted)));
    }
}

test "wallpaper keeps text readable and glass washes lift toward white" {
    for ([_][]const u8{ "zeron-dark", "zeron-light" }, [_]Appearance{ .dark, .light }) |id, appearance| {
        const t = Theme.forSelection(&registry.builtin, .{ .appearance = appearance, .variant_id = id, .surface = .frosted, .wallpaper_color = .rgb(20, 60, 140) });
        for ([_]Hsla{ t.element_hover, t.element_active }) |w| {
            try testing.expect(w.l == 1.0 and w.s == 0.0 and w.a > 0 and w.a < 1);
        }
        for ([_]model.Color{ .black, .white, .rgb(255, 220, 20), .rgb(10, 40, 240) }) |color| {
            const o = Theme.forSelection(&registry.builtin, .{ .appearance = appearance, .variant_id = id, .surface = .opaque_, .wallpaper_color = color });
            for ([_]Hsla{ o.bg, o.surface, o.surface_raised, o.surface_card, o.surface_dialog, o.input_bg }) |b| {
                try testing.expect(cs.contrastRatio(o.text, b) >= 4.49);
                try testing.expect(cs.contrastRatio(o.text_muted, b) >= 4.49);
            }
        }
    }
}

test "paint helpers" {
    try testing.expectEqual(@as(f32, 0.5), hairlineFor(.light, 0.5).a);
    try testing.expectApproxEqAbs(@as(f32, 0.135), hairlineFor(.light, 0.1).a, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.32), scrimFor(.light, scrim_alpha_dark).a, 1e-6);
    try testing.expectEqual(@as(f32, 0.08), userBubbleBg(.dark).a);
    const thumbs = Theme.light().scrollbarThumbColors();
    try testing.expectEqual(@as(f32, 0.42), thumbs[1].a);
}

test "memoized popup and tint math answer exactly as computed fresh, theme after theme" {
    // forPopup and contrastCheckedTintAlpha remember recent answers (the composer asks
    // every frame); alternating themes must never return another theme's answer.
    var themes: [6]Theme = undefined;
    var n: usize = 0;
    var it = registry.builtin.iterator();
    while (it.next()) |v| {
        if (n == themes.len) break;
        themes[n] = Theme.fromVariant(v, .theme_default, if (n % 2 == 0) .frosted else .opaque_);
        n += 1;
    }
    for (0..3) |_| for (themes[0..n]) |t| {
        try testing.expect(std.meta.eql(t.forPopup(), t.forPopupUncached()));
        try testing.expectEqual(t.contrastCheckedTintAlphaUncached(t.input_bg, 0.4, grey(0)), t.contrastCheckedTintAlpha(t.input_bg, 0.4, grey(0)));
        try testing.expectEqual(t.contrastCheckedTintAlphaUncached(t.surface, 0.4, grey(0xff)), t.contrastCheckedTintAlpha(t.surface, 0.4, grey(0xff)));
    };
}
