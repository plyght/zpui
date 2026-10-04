//! zeron's source-neutral theme data model (port of `crates/theme/src/lib.rs`).
//!
//! Runtime code consumes complete `ThemeVariant` values; how a variant was
//! produced (built-in seeds, an imported VS Code theme) never leaks into the
//! renderer. Colors here are 8-bit sRGB (`Color`) exactly as zeron stores and
//! serializes them; the UI layer (`theme.zig`) converts them to `Hsla`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Appearance = enum {
    dark,
    light,

    pub const all = [_]Appearance{ .light, .dark };

    pub fn isDark(self: Appearance) bool {
        return self == .dark;
    }
};

pub const SurfaceTreatment = enum { opaque_, frosted };

/// Device-local policy applied to a variant's recommended surface treatment,
/// independent of theme and accent choices.
pub const SurfacePreference = enum {
    theme_default,
    frosted,
    opaque_,
    /// [liquid-glass] Native Liquid Glass (macOS 26+) on chrome and floating surfaces;
    /// the token math is the frosted theme's. Offered only where supported; elsewhere
    /// it renders exactly like `.frosted`.
    liquid,

    /// The choices every platform offers (Settings → Appearance → Glass).
    pub const all = [_]SurfacePreference{ .theme_default, .frosted, .opaque_ };
    /// [liquid-glass] With native Liquid Glass available (appended: indices of `all` keep).
    pub const all_with_liquid = [_]SurfacePreference{ .theme_default, .frosted, .opaque_, .liquid };

    /// [liquid-glass] The options to show.
    pub fn offered(liquid_supported: bool) []const SurfacePreference {
        return if (liquid_supported) &all_with_liquid else &all;
    }

    pub fn resolve(self: SurfacePreference, recommended: SurfaceTreatment) SurfaceTreatment {
        return switch (self) {
            .theme_default => recommended,
            .frosted, .liquid => .frosted,
            .opaque_ => .opaque_,
        };
    }
};

/// An 8-bit sRGB color with straight alpha, serialized as `#rrggbb` or `#rrggbbaa`.
/// All arithmetic mirrors zeron's `f32` math and rounding exactly.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub const black: Color = rgb(0, 0, 0);
    pub const white: Color = rgb(255, 255, 255);

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub const ParseError = error{InvalidColor};

    /// Parse `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa` (surrounding whitespace allowed).
    pub fn parse(input: []const u8) ParseError!Color {
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '#') return error.InvalidColor;
        const d = trimmed[1..];
        var c: [4]u8 = .{ 0, 0, 0, 255 };
        switch (d.len) {
            3, 4 => for (d, 0..) |ch, i| {
                const v = try nibble(ch);
                c[i] = (v << 4) | v;
            },
            6, 8 => for (0..d.len / 2) |i| {
                c[i] = (try nibble(d[2 * i]) << 4) | try nibble(d[2 * i + 1]);
            },
            else => return error.InvalidColor,
        }
        return .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
    }

    /// Comptime `parse`; invalid input is a compile error.
    pub fn hex(comptime s: []const u8) Color {
        return comptime parse(s) catch @compileError("invalid color '" ++ s ++ "'");
    }

    fn nibble(ch: u8) ParseError!u8 {
        return switch (ch) {
            '0'...'9' => ch - '0',
            'a'...'f' => ch - 'a' + 10,
            'A'...'F' => ch - 'A' + 10,
            else => error.InvalidColor,
        };
    }

    /// `#rrggbb` when opaque, else `#rrggbbaa` (zeron's `Display`).
    pub fn format(self: Color, w: *Writer) Writer.Error!void {
        if (self.a == 255) {
            try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b });
        } else {
            try w.print("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b, self.a });
        }
    }

    /// Same color with alpha `round(clamp(alpha) * 255)`.
    pub fn withAlpha(self: Color, alpha: f32) Color {
        var c = self;
        c.a = roundU8(std.math.clamp(alpha, 0.0, 1.0) * 255.0);
        return c;
    }

    /// Composite `self` over an opaque `background`; the result is opaque.
    pub fn blendOver(self: Color, background: Color) Color {
        const alpha = @as(f32, @floatFromInt(self.a)) / 255.0;
        const blend = struct {
            fn f(front: u8, back: u8, al: f32) u8 {
                return roundU8(@as(f32, @floatFromInt(front)) * al + @as(f32, @floatFromInt(back)) * (1.0 - al));
            }
        }.f;
        return rgb(blend(self.r, background.r, alpha), blend(self.g, background.g, alpha), blend(self.b, background.b, alpha));
    }

    /// Per-channel (including alpha) linear mix toward `other` by `amount`.
    pub fn mix(self: Color, other: Color, amount: f32) Color {
        const t = std.math.clamp(amount, 0.0, 1.0);
        const m = struct {
            fn f(a: u8, b: u8, k: f32) u8 {
                const fa: f32 = @floatFromInt(a);
                const fb: f32 = @floatFromInt(b);
                return roundU8(fa + (fb - fa) * k);
            }
        }.f;
        return rgba(m(self.r, other.r, t), m(self.g, other.g, t), m(self.b, other.b, t), m(self.a, other.a, t));
    }

    /// WCAG contrast ratio; a translucent `self` is first flattened onto `background`.
    pub fn contrast(self: Color, background: Color) f32 {
        const fg = if (self.a == 255) self else self.blendOver(background);
        const a = fg.luminance();
        const b = background.luminance();
        return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
    }

    /// White or black, whichever contrasts more with `self` (ties pick white).
    pub fn bestOnColor(self: Color) Color {
        return if (white.contrast(self) >= black.contrast(self)) white else black;
    }

    /// Move toward black or white in 5% steps until `minimum` contrast is met.
    pub fn ensureContrast(self: Color, background: Color, minimum: f32) Color {
        if (self.contrast(background) >= minimum) return self;
        const target = if (black.contrast(background) >= white.contrast(background)) black else white;
        var step: u32 = 1;
        while (step <= 20) : (step += 1) {
            const candidate = self.mix(target, @as(f32, @floatFromInt(step)) / 20.0);
            if (candidate.contrast(background) >= minimum) return candidate;
        }
        return target;
    }

    /// WCAG 2.1 relative luminance (alpha ignored).
    pub fn luminance(self: Color) f32 {
        return 0.2126 * linear(self.r) + 0.7152 * linear(self.g) + 0.0722 * linear(self.b);
    }

    fn linear(channel: u8) f32 {
        const v = @as(f32, @floatFromInt(channel)) / 255.0;
        return if (v <= 0.04045) v / 12.92 else powf((v + 0.055) / 1.055, 2.4);
    }

    pub fn eql(a: Color, b: Color) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
    }
};

/// `f32` power computed in `f64` and rounded once: matches a correctly rounded
/// libm `powf` (what Rust's `f32::powf` calls) in practice.
pub fn powf(x: f32, y: f32) f32 {
    return @floatCast(std.math.pow(f64, x, y));
}

/// Rust's saturating `(x).round() as u8`.
fn roundU8(x: f32) u8 {
    if (!(x > 0)) return 0;
    return @intFromFloat(@min(255.0, @round(x)));
}

pub const AccentPreset = enum {
    zeron,
    orange,
    amber,
    green,
    cyan,
    blue,
    pink,

    pub const all = std.enums.values(AccentPreset);

    pub fn label(self: AccentPreset) []const u8 {
        return switch (self) {
            .zeron => "Zeron",
            .orange => "Orange",
            .amber => "Amber",
            .green => "Green",
            .cyan => "Cyan",
            .blue => "Blue",
            .pink => "Pink",
        };
    }

    pub fn color(self: AccentPreset, appearance: Appearance) Color {
        const pair: [2]Color = switch (self) {
            .zeron => .{ .hex("#8b7cf6"), .hex("#5b43e8") },
            .orange => .{ .hex("#fb923c"), .hex("#c2410c") },
            .amber => .{ .hex("#fbbf24"), .hex("#a16207") },
            .green => .{ .hex("#4ade80"), .hex("#15803d") },
            .cyan => .{ .hex("#22d3ee"), .hex("#0e7490") },
            .blue => .{ .hex("#60a5fa"), .hex("#2563eb") },
            .pink => .{ .hex("#f472b6"), .hex("#be185d") },
        };
        return if (appearance.isDark()) pair[0] else pair[1];
    }
};

/// The theme's own accent, or a user preset overlay.
pub const AccentSelection = union(enum) {
    theme_default,
    preset: AccentPreset,

    pub fn label(self: AccentSelection) []const u8 {
        return switch (self) {
            .theme_default => "Theme default",
            .preset => |p| p.label(),
        };
    }

    pub fn eql(a: AccentSelection, b: AccentSelection) bool {
        return std.meta.eql(a, b);
    }
};

/// Interactive accent roles derived from one primary color.
pub const AccentRoles = struct {
    primary: Color,
    strong: Color,
    wash: Color,
    on: Color,
    selection: Color,
    caret: Color,
    activity: Color,
    /// Rows of the animated pixel glyph: light, mid, deep.
    glyph: [3]Color,

    /// Contrast-correct `primary` against `background` and derive every role.
    pub fn derive(primary_seed: Color, appearance: Appearance, background: Color) AccentRoles {
        const dark = appearance.isDark();
        const primary = primary_seed.ensureContrast(background, 3.0);
        const on = primary.bestOnColor();
        var strong = primary;
        if (on.contrast(strong) < 4.5) strong = strong.ensureContrast(on, 4.5);
        const light = primary.mix(if (dark) Color.white else background, if (dark) 0.28 else 0.18);
        const deep = primary.mix(Color.black, if (dark) 0.18 else 0.26);
        return .{
            .primary = primary,
            .strong = strong,
            .wash = primary.withAlpha(if (dark) 0.22 else 0.12),
            .on = on,
            .selection = primary.withAlpha(if (dark) 0.35 else 0.24),
            .caret = primary,
            .activity = primary,
            .glyph = .{ light, primary, deep },
        };
    }
};

/// Which variant to use for each appearance (`themeSelection` in ui-settings.json).
pub const ThemeSelection = struct {
    light: []const u8 = "zeron-light",
    dark: []const u8 = "zeron-dark",

    pub fn variantId(self: ThemeSelection, appearance: Appearance) []const u8 {
        return if (appearance.isDark()) self.dark else self.light;
    }

    pub fn setVariant(self: *ThemeSelection, appearance: Appearance, id: []const u8) void {
        if (appearance.isDark()) self.dark = id else self.light = id;
    }
};

pub const ThemeSource = struct {
    format: []const u8,
    url: []const u8,
    revision: []const u8,
    license: []const u8,
    /// `sha256:<hex>` of the variant's JSON with this field blank. Built-ins
    /// leave it empty; `ThemeVariant.computeAssetHash` reproduces zeron's value.
    asset_hash: []const u8 = "",
};

pub const ThemeColors = struct {
    background: Color,
    shell: Color,
    raised: Color,
    card: Color,
    dialog: Color,
    overlay: Color,
    hover: Color,
    active: Color,
    border: Color,
    border_strong: Color,
    text: Color,
    text_muted: Color,
    text_faint: Color,
    solid: Color,
    on_solid: Color,
    danger: Color,
    danger_muted: Color,
    warning: Color,
    warning_muted: Color,
    success: Color,
    success_muted: Color,
    input: Color,
    cursor: Color,
    diff_add: Color,
    diff_delete: Color,
    diff_hunk: Color,
};

pub const TerminalPalette = struct {
    background: Color,
    foreground: Color,
    selection: Color,
    ansi: [16]Color,
};

/// Syntax highlight roles (zeron_syntax `HighlightKind`); a variant's syntax
/// map is keyed by `wireName`.
pub const SyntaxKey = enum {
    comment,
    keyword,
    string,
    string_special,
    escape,
    number,
    boolean,
    type_name,
    type_builtin,
    constructor,
    function,
    function_builtin,
    macro_name,
    property,
    constant,
    variable,
    variable_special,
    parameter,
    operator,
    punctuation,
    tag,
    attribute,
    label,
    markup_heading,
    markup_raw,
    markup_link,
    markup_reference,
    markup_emphasis,
    markup_strong,
    embedded,
    invalid,

    /// The camelCase key zeron uses in theme JSON.
    pub fn wireName(self: SyntaxKey) []const u8 {
        return switch (self) {
            .type_name => "type",
            .macro_name => "macro",
            inline else => |k| comptime camel(@tagName(k)),
        };
    }

    pub fn fromWireName(name: []const u8) ?SyntaxKey {
        inline for (comptime std.enums.values(SyntaxKey)) |k| {
            if (std.mem.eql(u8, name, comptime k.wireName())) return k;
        }
        return null;
    }

    fn camel(comptime snake: []const u8) []const u8 {
        comptime var out: []const u8 = "";
        comptime var upper = false;
        inline for (snake) |ch| {
            if (ch == '_') {
                upper = true;
            } else {
                out = out ++ &[_]u8{if (upper) std.ascii.toUpper(ch) else ch};
                upper = false;
            }
        }
        return out;
    }

    /// All keys sorted by `wireName` (zeron serializes syntax as a `BTreeMap`).
    pub const sorted: [std.enums.values(SyntaxKey).len]SyntaxKey = blk: {
        const all = std.enums.values(SyntaxKey);
        var keys: [all.len]SyntaxKey = all[0..all.len].*;
        @setEvalBranchQuota(20_000);
        std.mem.sort(SyntaxKey, &keys, {}, struct {
            fn lt(_: void, a: SyntaxKey, b: SyntaxKey) bool {
                return std.mem.lessThan(u8, a.wireName(), b.wireName());
            }
        }.lt);
        break :blk keys;
    };
};

/// A variant's syntax colors; absent keys fall back to the UI palette.
pub const Syntax = std.EnumArray(SyntaxKey, ?Color);

pub const ThemeVariant = struct {
    id: []const u8,
    family_id: []const u8,
    name: []const u8,
    appearance: Appearance,
    /// The author's recommended treatment; the user's `SurfacePreference` is
    /// applied on top at runtime.
    recommended_surface_treatment: SurfaceTreatment,
    colors: ThemeColors,
    accent: AccentRoles,
    syntax: Syntax,
    terminal: TerminalPalette,
    source: ThemeSource,

    pub fn accentFor(self: *const ThemeVariant, selection: AccentSelection) AccentRoles {
        return switch (selection) {
            .theme_default => self.accent,
            .preset => |p| AccentRoles.derive(p.color(self.appearance), self.appearance, self.colors.background),
        };
    }

    /// Deep equality (string contents compared, not pointers).
    pub fn eql(a: *const ThemeVariant, b: *const ThemeVariant) bool {
        return deepEql(a.*, b.*);
    }

    /// Serialize exactly like zeron's `serde_json::to_vec(&variant)`.
    pub fn writeJson(self: *const ThemeVariant, w: *Writer) Writer.Error!void {
        try w.writeAll("{\"id\":");
        try writeString(w, self.id);
        try w.writeAll(",\"familyId\":");
        try writeString(w, self.family_id);
        try w.writeAll(",\"name\":");
        try writeString(w, self.name);
        try w.print(",\"appearance\":\"{s}\",\"recommendedSurfaceTreatment\":\"{s}\",\"colors\":{{", .{
            @tagName(self.appearance), wireTreatment(self.recommended_surface_treatment),
        });
        inline for (comptime std.meta.fieldNames(ThemeColors), 0..) |name, i| {
            try w.print("{s}\"{s}\":\"{f}\"", .{ if (i == 0) "" else ",", comptime SyntaxKey.camel(name), @field(self.colors, name) });
        }
        try w.writeAll("},\"accent\":{");
        inline for (.{ "primary", "strong", "wash", "on", "selection", "caret", "activity" }, 0..) |name, i| {
            try w.print("{s}\"{s}\":\"{f}\"", .{ if (i == 0) "" else ",", name, @field(self.accent, name) });
        }
        try w.print(",\"glyph\":[\"{f}\",\"{f}\",\"{f}\"]}},\"syntax\":{{", .{ self.accent.glyph[0], self.accent.glyph[1], self.accent.glyph[2] });
        var first = true;
        for (SyntaxKey.sorted) |key| {
            const c = self.syntax.get(key) orelse continue;
            try w.print("{s}\"{s}\":\"{f}\"", .{ if (first) "" else ",", key.wireName(), c });
            first = false;
        }
        try w.print("}},\"terminal\":{{\"background\":\"{f}\",\"foreground\":\"{f}\",\"selection\":\"{f}\",\"ansi\":[", .{
            self.terminal.background, self.terminal.foreground, self.terminal.selection,
        });
        for (self.terminal.ansi, 0..) |c, i| try w.print("{s}\"{f}\"", .{ if (i == 0) "" else ",", c });
        try w.writeAll("]},\"source\":{\"format\":");
        try writeString(w, self.source.format);
        try w.writeAll(",\"url\":");
        try writeString(w, self.source.url);
        try w.writeAll(",\"revision\":");
        try writeString(w, self.source.revision);
        try w.writeAll(",\"license\":");
        try writeString(w, self.source.license);
        try w.writeAll(",\"assetHash\":");
        try writeString(w, self.source.asset_hash);
        try w.writeAll("}}");
    }

    /// zeron's provenance hash: `sha256:` + hex digest of the JSON encoding
    /// with `source.asset_hash` blanked.
    pub fn computeAssetHash(self: *const ThemeVariant) [71]u8 {
        var blank = self.*;
        blank.source.asset_hash = "";
        var buf: [256]u8 = undefined;
        var hashing: Writer.Hashing(std.crypto.hash.sha2.Sha256) = .init(&buf);
        blank.writeJson(&hashing.writer) catch unreachable;
        hashing.writer.flush() catch unreachable;
        var digest: [32]u8 = undefined;
        hashing.hasher.final(&digest);
        var out: [71]u8 = undefined;
        @memcpy(out[0..7], "sha256:");
        out[7..].* = std.fmt.bytesToHex(digest, .lower);
        return out;
    }
};

fn wireTreatment(t: SurfaceTreatment) []const u8 {
    return switch (t) {
        .opaque_ => "opaque",
        .frosted => "frosted",
    };
}

/// JSON string with serde_json's escaping (non-ASCII passes through as UTF-8).
fn writeString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        0...0x07, 0x0b, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeByte('"');
}

fn deepEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    if (T == []const u8) return std.mem.eql(u8, a, b);
    switch (@typeInfo(T)) {
        .@"struct" => {
            inline for (comptime std.meta.fieldNames(T)) |name| if (!deepEql(@field(a, name), @field(b, name))) return false;
            return true;
        },
        .array => {
            for (a, b) |x, y| if (!deepEql(x, y)) return false;
            return true;
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return deepEql(a.?, b.?);
        },
        else => return std.meta.eql(a, b),
    }
}

pub const ThemeFamily = struct {
    id: []const u8,
    name: []const u8,
    variants: []const ThemeVariant,
};

/// Built-in plus custom families; lookups search built-ins first.
pub const Registry = struct {
    families: []const ThemeFamily,
    custom: []const ThemeFamily = &.{},

    pub fn variant(self: *const Registry, id: []const u8) ?*const ThemeVariant {
        for ([_][]const ThemeFamily{ self.families, self.custom }) |list| {
            for (list) |*family| for (family.variants) |*v| {
                if (std.mem.eql(u8, v.id, id)) return v;
            };
        }
        return null;
    }

    /// The selected variant for `appearance`, falling back to the Zeron variant.
    /// Panics if the registry lacks the Zeron fallback (the built-in one never does).
    pub fn resolve(self: *const Registry, selection: ThemeSelection, appearance: Appearance) *const ThemeVariant {
        return self.variant(selection.variantId(appearance)) orelse
            self.variant(if (appearance.isDark()) "zeron-dark" else "zeron-light").?;
    }

    pub fn iterator(self: *const Registry) Iterator {
        return .{ .registry = self };
    }

    /// Iterates every variant (built-in families, then custom), optionally
    /// filtered by appearance.
    pub const Iterator = struct {
        registry: *const Registry,
        appearance: ?Appearance = null,
        list: usize = 0,
        family: usize = 0,
        index: usize = 0,

        pub fn next(it: *Iterator) ?*const ThemeVariant {
            while (it.list < 2) {
                const list = if (it.list == 0) it.registry.families else it.registry.custom;
                if (it.family >= list.len) {
                    it.list += 1;
                    it.family = 0;
                    continue;
                }
                const vs = list[it.family].variants;
                if (it.index >= vs.len) {
                    it.family += 1;
                    it.index = 0;
                    continue;
                }
                const v = &vs[it.index];
                it.index += 1;
                if (it.appearance == null or it.appearance.? == v.appearance) return v;
            }
            return null;
        }
    };

    pub fn variantsFor(self: *const Registry, appearance: Appearance) Iterator {
        return .{ .registry = self, .appearance = appearance };
    }

    /// Structural and contrast checks (zeron `ThemeRegistry::validate`).
    /// Issue messages are allocated with `gpa`; free with `ValidationIssue.deinitList`.
    pub fn validate(self: *const Registry, gpa: Allocator) Allocator.Error!std.ArrayList(ValidationIssue) {
        var issues: std.ArrayList(ValidationIssue) = .empty;
        errdefer ValidationIssue.deinitList(&issues, gpa);
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(gpa);
        var it = self.iterator();
        while (it.next()) |v| {
            const dup = try seen.fetchPut(gpa, v.id, {});
            if (std.mem.trim(u8, v.id, " \t\r\n").len == 0 or dup != null)
                try issues.append(gpa, try .init(gpa, v.id, .structural, .err, "variant id must be unique", .{}));
            const checks = [_]struct { []const u8, Color, Color, f32 }{
                .{ "text", v.colors.text, v.colors.background, 4.5 },
                .{ "muted text", v.colors.text_muted, v.colors.background, 4.5 },
                .{ "accent", v.accent.primary, v.colors.background, 3.0 },
                .{ "on-accent", v.accent.on, v.accent.strong, 4.5 },
                .{ "terminal foreground", v.terminal.foreground, v.terminal.background, 4.5 },
            };
            for (checks) |c| {
                const actual = c[1].contrast(c[2]);
                if (actual < c[3]) try issues.append(gpa, try .init(gpa, v.id, .contrast, .err, "{s} contrast is {d:.2}:1; expected {d:.1}:1", .{ c[0], actual, c[3] }));
            }
            const s = v.source;
            if (s.url.len == 0 or s.revision.len == 0 or s.license.len == 0)
                try issues.append(gpa, try .init(gpa, v.id, .structural, .err, "source provenance is incomplete", .{}));
            for (v.terminal.ansi, 0..) |c, i| {
                // Slots 0 and 8 are structural black/dim colors.
                if (i % 8 == 0) continue;
                if (c.contrast(v.terminal.background) < 3.0)
                    try issues.append(gpa, try .init(gpa, v.id, .contrast, .warning, "terminal ANSI slot {d} is below 3:1", .{i}));
            }
        }
        return issues;
    }
};

pub const ValidationIssue = struct {
    variant_id: []const u8,
    category: Category,
    severity: Severity,
    message: []u8,

    pub const Category = enum { structural, contrast };
    pub const Severity = enum { warning, err };

    fn init(gpa: Allocator, id: []const u8, category: Category, severity: Severity, comptime fmt: []const u8, args: anytype) Allocator.Error!ValidationIssue {
        return .{ .variant_id = id, .category = category, .severity = severity, .message = try std.fmt.allocPrint(gpa, fmt, args) };
    }

    /// Structural errors make a theme unsafe to install.
    pub fn isBlocking(self: ValidationIssue) bool {
        return self.category == .structural and self.severity == .err;
    }

    pub fn deinitList(list: *std.ArrayList(ValidationIssue), gpa: Allocator) void {
        for (list.items) |issue| gpa.free(issue.message);
        list.deinit(gpa);
    }
};

// ---- Tests ----

const testing = std.testing;

test "color parse and format round trip" {
    for ([_][]const u8{ "#abc", "#abcd", "#102030", "#10203040" }) |s| {
        const c = try Color.parse(s);
        var buf: [16]u8 = undefined;
        const out = try std.fmt.bufPrint(&buf, "{f}", .{c});
        try testing.expect(c.eql(try Color.parse(out)));
    }
    try testing.expectError(error.InvalidColor, Color.parse("abc"));
    try testing.expectError(error.InvalidColor, Color.parse("#abcde"));
}

test "accent overlay meets interaction contrast" {
    for (Appearance.all) |appearance| {
        const background = if (appearance.isDark()) Color.rgb(6, 6, 6) else Color.white;
        for (AccentPreset.all) |preset| {
            const roles = AccentRoles.derive(preset.color(appearance), appearance, background);
            try testing.expect(roles.primary.contrast(background) >= 3.0);
            try testing.expect(roles.on.contrast(roles.strong) >= 4.5);
        }
    }
}

test "surface preference resolves independently" {
    try testing.expectEqual(SurfaceTreatment.frosted, SurfacePreference.theme_default.resolve(.frosted));
    try testing.expectEqual(SurfaceTreatment.opaque_, SurfacePreference.theme_default.resolve(.opaque_));
    for ([_]SurfaceTreatment{ .frosted, .opaque_ }) |r| {
        try testing.expectEqual(SurfaceTreatment.frosted, SurfacePreference.frosted.resolve(r));
        try testing.expectEqual(SurfaceTreatment.opaque_, SurfacePreference.opaque_.resolve(r));
    }
}

test "syntax wire names" {
    try testing.expectEqualStrings("stringSpecial", SyntaxKey.string_special.wireName());
    try testing.expectEqualStrings("type", SyntaxKey.type_name.wireName());
    try testing.expectEqual(SyntaxKey.markup_heading, SyntaxKey.fromWireName("markupHeading").?);
    try testing.expectEqual(SyntaxKey.attribute, SyntaxKey.sorted[0]);
}
