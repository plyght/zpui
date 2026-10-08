//! Tinted control icons (zeron `icons.rs::icon`) and harness brand marks.
//!
//! ```zig
//! icon.of(.folder, 16, theme.text_muted)          // zpui.elements.Svg, size 16, tinted
//! icon.harness(.@"claude-code", 13, theme.text_muted.opacity(0.5))
//! ```
//!
//! All SVGs paint with `currentColor`; the tint is the element's text color.
//! On macOS, with Settings → Appearance → Use SF Symbols on (the default), control
//! icons draw as SF Symbols instead (`symbols`, docs/SF_SYMBOLS.md): every
//! `icons/*.svg` svg switches through the resolver `installSystemSymbols` registers,
//! so call sites and layout boxes stay as they are; brand marks and file types stay SVG.

const zpui = @import("zpui");
const assets = @import("zeron_assets");
const engine = @import("zeron_engine");
const theme_mod = @import("theme.zig");

pub const Icon = assets.Icon;
/// The icon → SF Symbol table and resolver (icon_symbols.zig).
pub const symbols = @import("icon_symbols.zig");

/// Register the SF Symbols mapping with zpui (once, at launch). Inert off macOS and
/// while the setting is off.
pub fn installSystemSymbols(app: *zpui.App) void {
    zpui.system_symbols.setResolver(app, .{ .resolve = symbols.resolve });
}
pub const HarnessId = engine.protocol.HarnessId;

/// A `size`×`size` icon tinted with `color`.
pub fn of(i: Icon, size: f32, color: zpui.Hsla) zpui.elements.Svg {
    return zpui.svg().source(i.path(), i.svg()).size(zpui.px(size)).flexNone().textColor(color);
}

/// `harness_brand_icon`: the mark and its fixed tint (Claude orange) or null
/// (monochrome marks take the surface tint).
pub fn harnessMark(h: HarnessId) struct { Icon, ?zpui.Hsla } {
    return switch (h) {
        .@"claude-code", .mock => .{ .claude_mark, theme_mod.claude_brand },
        .codex => .{ .openai_mark, null },
        .cursor => .{ .cursor_mark, null },
        .devin => .{ .devin_mark, null },
        .grok => .{ .grok_mark, null },
        .hermes => .{ .hermes_mark, null },
        .pi => .{ .pi_mark, null },
        .opencode => .{ .opencode_mark, null },
        .antigravity => .{ .antigravity_mark, null },
    };
}

/// The harness mark at `size`; brand-tinted marks keep their color at
/// `alpha`, monochrome ones use `fallback`.
pub fn harness(h: HarnessId, size: f32, fallback: zpui.Hsla, alpha: f32) zpui.elements.Svg {
    const mark, const tint = harnessMark(h);
    return of(mark, size, (tint orelse fallback).opacity(alpha));
}

/// Display name of a harness (picker labels).
pub fn harnessName(h: HarnessId) []const u8 {
    return switch (h) {
        .@"claude-code" => "Claude Code",
        .codex => "Codex",
        .cursor => "Cursor",
        .devin => "Devin",
        .grok => "Grok",
        .hermes => "Hermes",
        .pi => "Pi",
        .opencode => "opencode",
        .antigravity => "Antigravity",
        .mock => "Mock",
    };
}
