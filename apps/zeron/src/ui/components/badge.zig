//! Small chips: the sidebar PR badge, jump-hint chip, kbd chip, avatar and
//! the project monogram tile.
//!
//! ```zig
//! badge.pullRequest(413, theme)            // "#413" mono 10 medium, success @0.85 on success @0.08
//! badge.hint("Ctrl+1", theme)              // neutral variant of the same cloth
//! badge.kbd("Ctrl K", theme)               // palette-style kbd chip (mono 11, radius 4)
//! badge.avatar("A", 16, theme)             // filled circle, centered mono initial
//! badge.monogram("fieldnotes", 13, theme)  // colored project initial tile
//! ```

const std = @import("std");
const zpui = @import("zpui");
const theme_mod = @import("theme.zig");

const Theme = theme_mod.Theme;
const div = zpui.div;
const px = zpui.px;

fn chip(label: []const u8, tone: zpui.Hsla, theme: *const Theme) zpui.Div {
    return div().h(px(16)).flexNone().flex().flexRow().itemsCenter()
        .px(px(4)).rounded(px(4)).bg(tone.opacity(0.08))
        .whitespaceNowrap()
        .textSize(theme_mod.rems(10)).fontWeight(500).lineHeight(px(16))
        .textColor(tone.opacity(0.85)).fontFamily(theme.font_mono)
        .child(label);
}

/// Open pull request badge (`pull_request_badge`, sidebar surface).
pub fn pullRequest(number: u64, theme: *const Theme) zpui.Div {
    return chip(zpui.fmt("#{d}", .{number}), theme.success, theme);
}

/// Neutral chip in the PR badge's cloth (jump hints).
pub fn hint(label: []const u8, theme: *const Theme) zpui.Div {
    return chip(label, theme.text_muted, theme);
}

/// Keyboard shortcut chip (command palette).
pub fn kbd(label: []const u8, theme: *const Theme) zpui.Div {
    return div().flexNone().px(px(6)).py(px(2)).rounded(px(4))
        .bg(theme.ink(0.06)).fontFamily(theme.font_mono)
        .textSize(theme_mod.rems(11)).textColor(theme.text_muted)
        .child(label);
}

/// A circular avatar with a centered monospace initial.
pub fn avatar(initial: []const u8, size: f32, theme: *const Theme) zpui.Div {
    return div().size(px(size)).flexNone().roundedFull().bg(theme.text)
        .flex().itemsCenter().justifyCenter()
        .fontFamily(theme.font_mono).textSize(px(@round(size * 0.62))).lineHeight(px(size))
        .fontWeight(600).textColor(theme.bg)
        .child(initial);
}

/// Curated monogram tones (dark, light) — slate, blue, violet, rose, amber,
/// emerald, teal, orange (`project_icon.rs` MONOGRAM_PALETTE).
const palette = [_][2]u32{
    .{ 0x94a3b8, 0x475569 }, .{ 0x93c5fd, 0x2563eb }, .{ 0xc4b5fd, 0x7c3aed }, .{ 0xfda4af, 0xbe123c },
    .{ 0xfcd34d, 0xa16207 }, .{ 0x6ee7b7, 0x047857 }, .{ 0x5eead4, 0x0f766e }, .{ 0xfdba74, 0xc2410c },
};

fn fnv1a32(s: []const u8) u32 {
    var h: u32 = 2166136261;
    for (s) |b| h = (h ^ b) *% 16777619;
    return h;
}

pub fn projectTone(seed: []const u8, theme: *const Theme) zpui.Hsla {
    const e = palette[fnv1a32(seed) % palette.len];
    return zpui.rgb(if (theme.appearance.isDark()) e[0] else e[1]).toHsla();
}

/// Project initial on a tinted 3px tile (fallback repository artwork).
/// `seed` is the project path; `group` names the row group whose hover
/// strengthens the tint (or null).
pub fn monogram(name: []const u8, seed: []const u8, size: f32, selected: bool, group: ?[]const u8, theme: *const Theme) zpui.Div {
    const tone = projectTone(seed, theme);
    var hover_text = tone;
    hover_text.l = if (theme.appearance.isDark()) @min(tone.l + 0.12, 0.95) else @max(tone.l - 0.10, 0.15);
    const trimmed = std.mem.trim(u8, name, " ");
    const initial: []const u8 = if (trimmed.len > 0) zpui.fmt("{c}", .{std.ascii.toUpper(trimmed[0])}) else "?";
    var tile = div().size(px(size)).flexNone().rounded(px(3))
        .flex().itemsCenter().justifyCenter()
        .bg(tone.opacity(if (selected) 0.24 else 0.08))
        .textColor(if (selected) hover_text else tone.opacity(0.85))
        .fontFamily(theme.font_mono).fontWeight(500)
        .child(div().wFull().textCenter().textSize(px(9)).lineHeight(px(13)).child(initial));
    if (group) |g| tile = tile.groupHover(g, zpui.StyleBuilder.init.bg(tone.opacity(0.24)).textColor(hover_text));
    return tile;
}
