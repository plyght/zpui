//! Floating-menu chrome (zeron `popover.rs`): the frosted card, menu rows,
//! headings, separators, kbd hints and the anchored/deferred mount helpers.
//!
//! ```zig
//! const card = popover.card(theme).w(px(240)).child(popover.heading(theme, "Actions"))
//!     .child(popover.menuRow(theme, false).id("new").onClick(...).child(icon.of(.plus, 16, muted)).child("New chat"));
//! // Mounted from the trigger (relative) while open:
//! trigger.child(popover.anchoredAbove(card))      // opens upward, left-aligned
//! trigger.child(popover.anchoredBelow(card))      // dropdown
//! ```
//!
//! `card` is radius 12 with a 4px inset; rows have radius 7 (concentric), a
//! 10px gap and 8×6 padding. On frosted themes the card is wrapped in a 16px
//! backdrop blur and has no shadow; opaque themes get `shadow_lg`.

const zpui = @import("zpui");
const theme_mod = @import("theme.zig");
const effects = @import("effects.zig");
const anim = @import("anim.zig");

const Theme = theme_mod.Theme;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;

pub const card_radius: f32 = 12;
pub const card_inset: f32 = 4;
pub const menu_gap: f32 = 2;
pub const menu_item_radius: f32 = card_radius - 1 - card_inset;
pub const palette_item_radius: f32 = 14 - card_inset;

/// `popover::surface_bg`.
pub fn surfaceBg(theme: *const Theme) zpui.Hsla {
    if (theme.isFrost()) {
        return theme.onGlass(if (theme.appearance.isDark()) theme.composerSidebarTint() else theme.glassOverlay()); // [liquid-glass] onGlass
    }
    return theme.inputGlassBg();
}

/// The card body (callers add width / children). Pass `theme.forPopup()`
/// for the text hierarchy of floating surfaces.
pub fn card(theme: *const Theme) zpui.Div {
    var d = div()
        .border1().borderColor(theme.onGlassBorder(theme.border)) // [liquid-glass] onGlassBorder
        .rounded(px(card_radius))
        .bg(surfaceBg(theme))
        .p(px(card_inset)).gap(px(menu_gap))
        .flex().flexCol()
        .overflowHidden()
        .fontFamily(theme.font_sans)
        .textSize(theme_mod.rems(13)).textColor(theme.text);
    if (!theme.isFrost()) d = d.shadowLg();
    return d;
}

/// The card wrapped in its backdrop blur (what a mount helper paints).
pub fn frostedCard(c: anytype) effects.Frosted {
    return effects.frosted(card_radius, theme_mod.layout.menu_blur, c);
}

/// A menu row: 13px, text @0.9 → text on hover, hover wash `card_selected_bg`.
/// Add `.id(...)` + `.onClick(...)` and children (icon 16, label).
pub fn menuRow(theme: *const Theme, active: bool) zpui.Div {
    const row = div()
        .flex().flexRow().itemsCenter().gap(px(10))
        .px(px(8)).py(px(6))
        .rounded(px(menu_item_radius))
        .textSize(theme_mod.rems(13))
        .cursorPointer();
    if (active) return row.bg(theme_mod.cardSelectedBg(theme)).textColor(theme.text);
    return row.textColor(theme.text.opacity(0.9))
        .hover(sb.bg(theme_mod.cardSelectedBg(theme)).textColor(theme.text));
}

/// Small uppercase heading (`MenuHeading`): 10px medium muted.
pub fn heading(theme: *const Theme, upper_label: []const u8) zpui.Div {
    return div().px(px(8)).pb(px(4)).pt(px(6))
        .textSize(theme_mod.rems(10)).fontWeight(500)
        .textColor(theme.text_muted)
        .child(upper_label);
}

/// Full-bleed hairline between menu sections.
pub fn separator(theme: *const Theme) zpui.Div {
    return div().h(px(1)).mx(px(-card_inset)).my(px(2)).bg(theme_mod.ink(theme, 0.07));
}

/// A muted kbd hint chip inside menu rows (`⌘↵`-style accelerators).
pub fn kbdHint(theme: *const Theme, label: []const u8) zpui.Div {
    return div().flexNone().px(px(5)).py(px(1)).rounded(px(5))
        .bg(theme_mod.ink(theme, 0.05))
        .textSize(theme_mod.rems(10)).fontFamily(theme.font_mono)
        .textColor(theme.text_muted)
        .child(label);
}

/// Mount `content` (a card) as a floating layer opening upward from the
/// trigger's top-left (`anchored_menu_above`); the trigger must be `relative`.
pub fn anchoredAbove(content: anytype) zpui.Div {
    return div().absolute().top(px(0)).left(px(0)).child(zpui.deferred(
        zpui.anchored().anchorCorner(.bottom_left).snapToWindowWithMargin(.all(8))
            .child(anim.menuIn("menu-above", div().occlude().pb(px(6)).child(frostedCard(content)), 4)),
    ).withPriority(1));
}

/// Dropdown below the trigger's bottom-left (`anchored_menu_below`, 6px gap).
pub fn anchoredBelow(content: anytype) zpui.Div {
    return div().absolute().top(zpui.relative(1)).left(px(0)).child(zpui.deferred(
        zpui.anchored().anchorCorner(.top_left).snapToWindowWithMargin(.all(8))
            .child(anim.menuIn("menu-below", div().occlude().pt(px(6)).child(frostedCard(content)), -2)),
    ).withPriority(1));
}

/// Opens to the right of the trigger, top-aligned (`anchored_menu_right`).
pub fn anchoredRight(content: anytype) zpui.Div {
    return div().absolute().top(px(0)).left(zpui.relative(1)).child(zpui.deferred(
        zpui.anchored().anchorCorner(.top_left).snapToWindowWithMargin(.all(8))
            .child(anim.menuIn("menu-right", div().occlude().pl(px(6)).child(frostedCard(content)), -2)),
    ).withPriority(1));
}

/// Floating layer at an absolute window `position` (context menus).
pub fn anchoredAt(position: zpui.Point(f32), content: anytype) zpui.AnyElement {
    return zpui.intoAnyElement(zpui.deferred(
        zpui.anchored().position(position).snapToWindowWithMargin(.all(8))
            .child(div().occlude().child(frostedCard(content))),
    ).withPriority(1));
}
