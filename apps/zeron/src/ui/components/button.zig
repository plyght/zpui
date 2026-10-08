//! Buttons (zeron shell.rs `window_control_button`, `header_icon_button`,
//! gate-card buttons).
//!
//! ```zig
//! button.windowControlWith("toggle-sidebar", icon.sidebarGlyph(open_t, false, 16, theme.text_muted), "Toggle left sidebar", theme)
//!     .onClick(cx.listener(Shell.onToggleSidebar))          // 24px, radius 6, icon 16 muted
//! button.headerIconWith("toggle-right", icon.sidebarGlyph(open_t, true, 16, theme.text_muted), "Toggle right sidebar", theme)   // 28px
//! button.disabledControl(.arrow_right, theme)               // 35% muted, inert
//! button.solid("sign-in", "Log in", theme).wFull()           // white pill, 36px
//! button.outline("retry", "Retry", theme)                    // hairline-bordered, hover wash
//! ```
//! Window-control buttons `occlude()` and `preventDefault` on mouse down so
//! they never feed the titlebar drag strip underneath.
//!
//! Every button is an accessibility `button` node (zeron `.role(Role::Button)`):
//! icon buttons are named by their tooltip label, text buttons by their text.

const zpui = @import("zpui");
const theme_mod = @import("theme.zig");
const icon = @import("icon.zig");
const tooltip = @import("tooltip.zig");

const Theme = theme_mod.Theme;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;

fn preventDefault(_: *const zpui.input.MouseDownEvent, window: *zpui.Window, _: *zpui.App) void {
    window.preventDefault();
}

/// 24px titlebar control: rounded 6, glass-hover wash, 16px muted icon.
pub fn windowControl(id: anytype, i: icon.Icon, label: []const u8, theme: *const Theme) zpui.StatefulDiv {
    return windowControlWith(id, icon.of(i, 16, theme.text_muted), label, theme);
}

/// `window_control_button_with`: `windowControl` around a caller-drawn glyph
/// (the morphing sidebar glyph).
pub fn windowControlWith(id: anytype, glyph: anytype, label: []const u8, theme: *const Theme) zpui.StatefulDiv {
    return div().id(id).role(.button).ariaLabel(label)
        .size(px(24)).flexNone().flex().itemsCenter().justifyCenter()
        .rounded(px(6)).cursorPointer()
        .hover(sb.bg(theme.glassHover()))
        .occlude()
        .onMouseDown(.left, preventDefault)
        .tooltipWith(label, tooltip.build)
        .child(glyph);
}

/// A disabled 24px control (history arrows with nowhere to go).
pub fn disabledControl(i: icon.Icon, theme: *const Theme) zpui.Div {
    return div().size(px(24)).flexNone().flex().itemsCenter().justifyCenter().occlude()
        .child(icon.of(i, 16, theme.text_muted.opacity(0.35)));
}

/// 28px main-panel header button (`size-7 rounded-md`), wash 0.11 on hover.
pub fn headerIcon(id: anytype, i: icon.Icon, label: []const u8, theme: *const Theme) zpui.StatefulDiv {
    return headerIconWith(id, icon.of(i, 16, theme.text_muted), label, theme);
}

/// `header_icon_button_with`: `headerIcon` around a caller-drawn glyph.
pub fn headerIconWith(id: anytype, glyph: anytype, label: []const u8, theme: *const Theme) zpui.StatefulDiv {
    return div().id(id).role(.button).ariaLabel(label)
        .size(px(28)).flexNone().flex().itemsCenter().justifyCenter()
        .rounded(px(6)).cursorPointer()
        .hover(sb.bg(theme.wash(0.11)))
        .occlude()
        .onMouseDown(.left, preventDefault)
        .tooltipWith(label, tooltip.build)
        .child(glyph);
}

/// Primary solid button: `bg text`, label `on_solid`, 36px, radius 6, 14px medium.
pub fn solid(id: anytype, label: []const u8, theme: *const Theme) zpui.StatefulDiv {
    return div().id(id).role(.button)
        .h(px(36)).px(px(16)).flex().itemsCenter().justifyCenter()
        .rounded(px(6)).bg(theme.text)
        .textSize(theme_mod.rems(14)).fontWeight(500).textColor(theme.on_solid)
        .cursorPointer().hover(sb.opacity(0.9))
        .child(label);
}

/// Quiet bordered button (gate "Retry"): px 12, py 6, radius 8, 13px.
pub fn outline(id: anytype, label: []const u8, theme: *const Theme) zpui.StatefulDiv {
    return div().id(id).role(.button)
        .px(px(12)).py(px(6)).rounded(px(8))
        .border1().borderColor(theme.border)
        .textSize(theme_mod.rems(13)).textColor(theme.text)
        .cursorPointer().hover(sb.bg(theme.glassHover()))
        .child(label);
}

/// Ghost text button with an optional leading icon (menus / banners).
pub fn ghost(id: anytype, label: []const u8, theme: *const Theme) zpui.StatefulDiv {
    return div().id(id).role(.button)
        .h(px(28)).px(px(8)).flex().itemsCenter().gap(px(6))
        .rounded(px(8)).textSize(theme_mod.rems(13)).textColor(theme.text.opacity(0.8))
        .cursorPointer().hover(sb.bg(theme.glassHover()).textColor(theme.text))
        .child(label);
}
