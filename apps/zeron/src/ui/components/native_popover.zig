//! zeron's rich popovers in native popover containers (`zpui.nativePopover`): on macOS
//! with Settings → Appearance → Native menus on, pickers, cards and lists open in a
//! glass popover window (Liquid Glass when it is on, the system popover material
//! otherwise) that can extend past the main window; tooltips show in native tooltip
//! windows. Linux, tests and the setting off keep the drawn in-window popovers.
//!
//! ```zig
//! if (ui.native_popover.enabled(cx)) {
//!     if (self.open) trigger = trigger.child(zpui.nativePopover(.trigger("x-popover"),
//!         ui.native_popover.options(theme, .below, .start, self.focus),
//!         zpui.popoverContent(cx.entity(), Owner.nativeCard, Owner.dismissNative)));
//! } else if (self.open or exit != null) trigger = trigger.child(ui.popover.anchoredBelowExit(card, exit));
//!
//! fn nativeCard(self: *Owner, _: *Window, cx: *Context(Owner)) zpui.Div {
//!     return ui.native_popover.bare(self.card(cx)); // the material replaces the card fill
//! }
//! ```
//!
//! The native container plays the system show / hide animation, so the drawn
//! MENU_IN / MENU_OUT motion is skipped there (mount the native popover only while open).

const builtin = @import("builtin");
const zpui = @import("zpui");
const model = @import("zeron_model");

const transparent = zpui.hsla(0, 0, 0, 0);

fn appOf(cx: anytype) *zpui.App {
    if (@TypeOf(cx) == *zpui.App) return cx;
    return cx.app;
}

/// The "Native menus" setting (macOS only).
fn settingOn(app: *zpui.App) bool {
    if (comptime @hasDecl(model, "native_menus")) return model.native_menus.enabled(app);
    return builtin.os.tag == .macos;
}

/// Tests: take the native path wherever the platform has popovers (a TestPlatform with
/// `native_popovers` set), whatever the setting says.
pub var force_for_testing: bool = false;

/// Rich popovers and tooltips use native containers (setting on + platform support).
pub fn enabled(cx: anytype) bool {
    const app = appOf(cx);
    if (!app.platform.supportsNativePopovers()) return false;
    return force_for_testing or settingOn(app);
}

/// Placement + material for a popover card: glass follows the theme's Liquid Glass
/// mode, the appearance is pinned to the theme.
pub fn options(theme: anytype, edge: zpui.native_popover.Edge, alignment: zpui.native_popover.Align, focus: ?zpui.FocusHandle) zpui.NativePopoverOptions {
    return .{
        .edge = edge,
        .alignment = alignment,
        .gap = 6,
        .focus = focus,
        .key = true,
        .liquid_glass = theme.isLiquid(),
        .dark = theme.appearance.isDark(),
        .corner_radius = 12,
        .material = .popover,
    };
}

/// A drawn card restyled for the native container: no fill, hairline or shadow (the
/// material and the window shadow provide them); padding and rows stay.
pub fn bare(card: anytype) @TypeOf(card) {
    return card.bg(transparent).borderColor(transparent).shadowNone();
}

/// Per frame (the shell's render): tooltips follow the setting and the theme.
pub fn syncWindow(window: *zpui.Window, theme: anytype, cx: anytype) void {
    const on = enabled(cx);
    window.native_tooltip_options.liquid_glass = theme.isLiquid();
    window.native_tooltip_options.dark = theme.appearance.isDark();
    window.setNativeTooltips(on);
}
