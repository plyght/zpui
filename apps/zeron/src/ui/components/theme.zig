//! The active `Theme` as an app global, plus the small type helpers every
//! zeron view uses.
//!
//! ```zig
//! const ui = @import("../components/root.zig");
//! const theme = ui.theme.get(cx);          // *const zeron_theme.Theme (cx: *App or *Context(T))
//! div().textSize(ui.rems(13)).textColor(theme.text_muted)
//! ```
//!
//! - `ThemeGlobal` is installed once by main.zig (`install`) and replaced on
//!   appearance changes (`set`); views that read it redraw through
//!   `app.observeGlobal(ThemeGlobal, …)` / `window.refresh()`.
//! - `rems(px)` is zeron's `ui_rems(px)`: px/16 rem, so UI text follows the
//!   user's base font size (`window.setRemSize`).
//! - `wash`, `ink`, `hairline`: appearance-aware paint helpers (theme.rs).

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");

pub const Theme = zt.Theme;
pub const Hsla = zpui.Hsla;
pub const layout = zt.layout;

pub const ThemeGlobal = struct {
    theme: Theme,
};

fn appOf(cx: anytype) *zpui.App {
    const T = @TypeOf(cx);
    if (T == *zpui.App) return cx;
    return cx.app;
}

/// The installed theme (falls back to Zeron Dark when none is installed).
pub fn get(cx: anytype) *const Theme {
    const app = appOf(cx);
    if (app.tryGlobal(ThemeGlobal)) |g| return &g.theme;
    if (fallback == null) fallback = Theme.dark();
    return &fallback.?;
}

var fallback: ?Theme = null;

pub fn install(app: *zpui.App, theme: Theme) !void {
    try app.setGlobal(ThemeGlobal{ .theme = theme });
}

/// Replace the theme and redraw every window.
pub fn set(app: *zpui.App, theme: Theme) void {
    app.setGlobal(ThemeGlobal{ .theme = theme }) catch return;
    app.refreshWindows();
}

/// zeron `ui_rems(px)`: authored at a 16px baseline, scales with the rem size.
pub fn rems(px_at_16: f32) zpui.Rems {
    return zpui.rems(px_at_16 / 16.0);
}

/// Dark: white @ a; light: black @ a (`ink`).
pub fn ink(theme: *const Theme, a: f32) Hsla {
    return theme.ink(a);
}

/// `wash(a)`: hsl(0,0,.92)@a in dark, hsl(0,0,.10)@a in light.
pub fn wash(theme: *const Theme, a: f32) Hsla {
    return theme.wash(a);
}

pub fn hairline(theme: *const Theme, a: f32) Hsla {
    return theme.hairline(a);
}

/// `glass_selected_bg()` — the selected sidebar row wash.
pub fn glassSelectedBg(theme: *const Theme) Hsla {
    return zt.theme.glassSelectedBg(theme.appearance);
}

/// `card_selected_bg()` — menu row hover / selected wash.
pub fn cardSelectedBg(theme: *const Theme) Hsla {
    return zt.theme.cardSelectedBg(theme.appearance);
}

pub fn isDark(theme: *const Theme) bool {
    return theme.appearance.isDark();
}

/// The Claude brand orange (`CLAUDE_BRAND`).
pub const claude_brand = zt.theme.claude_brand;
