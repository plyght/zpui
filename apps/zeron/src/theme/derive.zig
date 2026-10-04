//! Seed -> full variant derivation (port of `variant()` in zeron
//! `crates/theme/src/builtins.rs`). Pure and comptime-friendly: the built-in
//! registry is derived at compile time from the generated seeds.

const std = @import("std");
const model = @import("model.zig");

const Color = model.Color;

/// The hand-curated inputs of a built-in variant; everything else is derived.
pub const Seeds = struct {
    id: []const u8,
    family_id: []const u8,
    name: []const u8,
    appearance: model.Appearance,
    treatment: model.SurfaceTreatment,
    background: []const u8,
    shell: []const u8,
    raised: []const u8,
    card: []const u8,
    text: []const u8,
    muted: []const u8,
    faint: []const u8,
    accent: []const u8,
    danger: []const u8,
    warning: []const u8,
    success: []const u8,
    terminal_background: []const u8,
    ansi: [16][]const u8,
    /// comment, keyword, string, number, type, function, property, variable,
    /// punctuation, tag, attribute, invalid.
    syntax: [12][]const u8,
    source: Source,

    pub const Source = struct {
        format: []const u8,
        url: []const u8,
        revision: []const u8,
        license: []const u8,
    };
};

/// Derive a complete variant. Call at comptime with constant seeds (colors are
/// then validated at compile time) or at runtime with known-valid hex strings.
pub fn variant(comptime seed: Seeds) model.ThemeVariant {
    @setEvalBranchQuota(200_000);
    return comptime derive(seed) catch |e| @compileError(seed.id ++ ": " ++ @errorName(e));
}

/// Runtime form of `variant`; fails on a malformed color string.
pub fn derive(seed: Seeds) model.Color.ParseError!model.ThemeVariant {
    const background = try c(seed.background);
    const shell = try c(seed.shell);
    const raised = try c(seed.raised);
    const card = try c(seed.card);
    const text = try c(seed.text);
    const muted = (try c(seed.muted)).ensureContrast(background, 4.5);
    const faint = try c(seed.faint);
    const danger = try c(seed.danger);
    const warning = try c(seed.warning);
    const success = try c(seed.success);
    const accent = model.AccentRoles.derive(try c(seed.accent), seed.appearance, background);
    const dark = seed.appearance.isDark();
    const border_tone = if (dark) Color.white else Color.black;
    const solid = if (dark) Color.rgb(235, 235, 239) else Color.rgb(35, 35, 40);
    const colors: model.ThemeColors = .{
        .background = background,
        .shell = shell,
        .raised = raised,
        .card = card,
        .dialog = card.mix(raised, if (dark) 0.18 else 0.04),
        .overlay = card.mix(raised, if (dark) 0.34 else 0.02),
        .hover = border_tone.withAlpha(if (dark) 0.11 else 0.06),
        .active = accent.primary.withAlpha(if (dark) 0.18 else 0.10),
        .border = border_tone.withAlpha(if (dark) 0.10 else 0.12),
        .border_strong = border_tone.withAlpha(if (dark) 0.18 else 0.22),
        .text = text,
        .text_muted = muted,
        .text_faint = faint,
        .solid = solid,
        .on_solid = solid.bestOnColor(),
        .danger = danger,
        .danger_muted = danger.mix(text, 0.28),
        .warning = warning,
        .warning_muted = warning.mix(text, 0.25),
        .success = success,
        .success_muted = success.mix(text, 0.25),
        .input = if (dark) raised.withAlpha(0.72) else card,
        .cursor = text.withAlpha(if (dark) 0.40 else 0.55),
        .diff_add = success,
        .diff_delete = danger,
        .diff_hunk = accent.primary.withAlpha(if (dark) 0.08 else 0.07),
    };
    const terminal_background = try c(seed.terminal_background);
    var ansi: [16]Color = undefined;
    for (&ansi, seed.ansi) |*dst, s| dst.* = try c(s);
    return .{
        .id = seed.id,
        .family_id = seed.family_id,
        .name = seed.name,
        .appearance = seed.appearance,
        .recommended_surface_treatment = seed.treatment,
        .colors = colors,
        .accent = accent,
        .syntax = try syntax(seed.syntax),
        .terminal = .{
            .background = terminal_background,
            .foreground = text.ensureContrast(terminal_background, 4.5),
            .selection = border_tone.withAlpha(if (dark) 0.22 else 0.16),
            .ansi = ansi,
        },
        .source = .{
            .format = seed.source.format,
            .url = seed.source.url,
            .revision = seed.source.revision,
            .license = seed.source.license,
        },
    };
}

/// Expand the 12 seed syntax colors onto zeron's 25 syntax keys.
fn syntax(seed: [12][]const u8) model.Color.ParseError!model.Syntax {
    const comment, const keyword, const string, const number, const type_name, const function, const property, const variable, const punctuation, const tag, const attribute, const invalid = .{
        try c(seed[0]), try c(seed[1]), try c(seed[2]),  try c(seed[3]),
        try c(seed[4]), try c(seed[5]), try c(seed[6]),  try c(seed[7]),
        try c(seed[8]), try c(seed[9]), try c(seed[10]), try c(seed[11]),
    };
    return .init(.{
        .comment = comment,
        .keyword = keyword,
        .string = string,
        .string_special = attribute,
        .escape = attribute,
        .number = number,
        .boolean = number,
        .type_name = type_name,
        .type_builtin = type_name,
        .constructor = type_name,
        .function = function,
        .function_builtin = function,
        .macro_name = keyword,
        .property = property,
        .constant = number,
        .variable = variable,
        .variable_special = keyword,
        .parameter = variable,
        .operator = keyword,
        .punctuation = punctuation,
        .tag = tag,
        .attribute = attribute,
        .label = function,
        .markup_heading = null,
        .markup_raw = null,
        .markup_link = null,
        .markup_reference = null,
        .markup_emphasis = null,
        .markup_strong = null,
        .embedded = punctuation,
        .invalid = invalid,
    });
}

fn c(s: []const u8) model.Color.ParseError!Color {
    return Color.parse(s);
}
