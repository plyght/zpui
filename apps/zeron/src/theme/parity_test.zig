//! Parity with zeron's Rust implementation, against values dumped by
//! `scripts/theme_parity.rs` into `parity_data.zig`.

const std = @import("std");
const builtin = @import("builtin");
const data = @import("parity_data.zig");
const model = @import("model.zig");
const registry = @import("registry.zig");
const theme_mod = @import("theme.zig");

const Theme = theme_mod.Theme;
const Hsla = theme_mod.Hsla;
const testing = std.testing;

test "zeron dark/light derive to zeron's exact serialized variants" {
    for ([_][]const u8{ "zeron-dark", "zeron-light" }, [_][]const u8{ data.zeron_dark_json, data.zeron_light_json }) |id, expected| {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try registry.builtin.variant(id).?.writeJson(&w);
        try testing.expectEqualStrings(expected, w.buffered());
    }
}

test "all 30 built-ins hash identically to zeron (every derived token matches)" {
    try testing.expectEqual(@as(usize, 30), data.asset_hashes.len);
    var it = registry.builtin.iterator();
    var i: usize = 0;
    while (it.next()) |v| : (i += 1) {
        try testing.expectEqualStrings(data.asset_hashes[i][0], v.id);
        try testing.expectEqualStrings(data.asset_hashes[i][1], &v.computeAssetHash());
    }
}

/// The UI theme for one dumped configuration (labels match theme_parity.rs).
fn build(name: []const u8) Theme {
    const reg = &registry.builtin;
    const S = struct { []const u8, Theme };
    const table = [_]S{
        .{ "dark()", Theme.dark() },
        .{ "light()", Theme.light() },
        .{ "dark_with_accent(pink)", Theme.darkWithAccent(.pink) },
        .{ "light_with_accent(amber)", Theme.lightWithAccent(.amber) },
        .{ "zeron-dark", Theme.forSelection(reg, .{ .appearance = .dark, .variant_id = "zeron-dark" }) },
        .{ "zeron-light", Theme.forSelection(reg, .{ .appearance = .light, .variant_id = "zeron-light" }) },
        .{ "zeron-dark+cyan", Theme.forSelection(reg, .{ .appearance = .dark, .variant_id = "zeron-dark", .accent = .{ .preset = .cyan } }) },
        .{ "zeron-light+orange/opaque", Theme.forSelection(reg, .{ .appearance = .light, .variant_id = "zeron-light", .accent = .{ .preset = .orange }, .surface = .opaque_ }) },
        .{ "catppuccin-mocha/frosted", Theme.forSelection(reg, .{ .appearance = .dark, .variant_id = "catppuccin-mocha", .surface = .frosted }) },
        .{ "github-light/frosted", Theme.forSelection(reg, .{ .appearance = .light, .variant_id = "github-light", .surface = .frosted }) },
        .{ "synthwave-84", Theme.forSelection(reg, .{ .appearance = .dark, .variant_id = "synthwave-84" }) },
        .{ "light fallback", Theme.forSelection(reg, .{ .appearance = .light, .variant_id = "dracula" }) },
    };
    for (table) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
    @panic("unknown parity configuration");
}

/// Every dumped token of `t`, in theme_parity.rs order.
fn tokens(t: Theme, out: *[128]Hsla) []Hsla {
    const popup = t.forPopup();
    const fixed = [_]Hsla{
        t.bg,                   t.surface,                 t.surface_raised,      t.surface_card,        t.surface_dialog,
        t.surface_overlay,      t.element_hover,           t.element_active,      t.border,              t.border_strong,
        t.text,                 t.text_muted,              t.text_faint,          t.text_dim,            t.solid,
        t.on_solid,             t.accent,                  t.accent_strong,       t.accent_wash,         t.on_accent,
        t.danger,               t.danger_muted,            t.warning,             t.warning_muted,       t.success,
        t.busy,                 t.glyph.light,             t.glyph.mid,           t.glyph.deep,          t.success_muted,
        t.surface_raised_hover, t.band,                    t.input_bg,            t.selection,           t.cursor,
        t.caret,                t.danger_strong,           t.code_text,           t.code_wash,           t.diff_add,
        t.diff_del,             t.diff_hunk_bg,            t.terminal.background, t.terminal.foreground, t.terminal.selection,
        t.glass(),              t.glassOverlay(),          t.inputGlassBg(),      t.cardGlassBg(),       t.composerSidebarTint(),
        t.composerSurfaceBg(),  t.composerSurfaceBorder(), t.panelBg(),           t.scrim(),             popup.text,
        popup.text_muted,       popup.text_dim,            popup.text_faint,
    };
    var n: usize = 0;
    for (fixed) |c| {
        out[n] = c;
        n += 1;
    }
    for (t.terminal.ansi) |c| {
        out[n] = c;
        n += 1;
    }
    for (std.enums.values(theme_mod.HighlightKind)) |k| {
        out[n] = t.syntax.color(k);
        n += 1;
    }
    return out[0..n];
}

test "UI theme tokens match zeron bit-exactly (fallbacks, variants, accents, glass math)" {
    // Glass alpha (and thus the dumped glass values) is platform dependent;
    // the checked-in data was produced on Linux.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    for (data.themes) |expected| {
        const t = build(expected.name);
        var buf: [128]Hsla = undefined;
        const got = tokens(t, &buf);
        try testing.expectEqual(expected.tokens.len, got.len);
        try testing.expectEqual(expected.is_glass, t.isGlass());
        try testing.expectEqual(expected.is_frost, t.isFrost());
        for (expected.tokens, got) |e, g| {
            const want = e[1];
            const have = [4]f32{ g.h, g.s, g.l, g.a };
            // Bit-exact: the f32 math (including OKLCH and pow) mirrors zeron's.
            for (want, have) |a, b| {
                if (a != b) {
                    std.debug.print("{s}: {s} want {any} got {any}\n", .{ expected.name, e[0], want, have });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}
