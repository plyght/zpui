//! Confirmation dialogs (zeron `popover.rs` `dialog_card`, `dialog_title`,
//! `dialog_body`, `btn_ghost` / `btn_primary` / `btn_danger`, `modal`).
//! Added by the changes pane (discard working tree); other views may use it.
//!
//! ```zig
//! const card = dialog.card(theme)
//!     .child(dialog.title(theme, "Discard working tree changes?"))
//!     .child(div().mt(px(6)).child(dialog.body(theme, "…")))
//!     .child(div().mt(px(16)).flex().justifyEnd().gap(px(8))
//!         .child(dialog.btnGhost(theme, "Cancel").id("cancel").onClick(...))
//!         .child(dialog.btnDanger(theme, "Discard changes").id("ok").onClick(...)));
//! root.child(dialog.modal(window, card, cx.listener(Self.onScrimDown)))
//! ```

const zpui = @import("zpui");
const theme_mod = @import("theme.zig");
const effects = @import("effects.zig");
const popover = @import("popover.zig");
const anim = @import("anim.zig");

const Theme = theme_mod.Theme;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;

/// 360px card, padding 20, radius 16, hairline(0.10) border.
pub fn card(theme: *const Theme) zpui.Div {
    var d = div().w(px(360)).p(px(20)).rounded(px(16))
        .bg(popover.surfaceBg(theme))
        .border1().borderColor(theme.hairline(0.10))
        .flex().flexCol().textColor(theme.text).fontFamily(theme.font_sans);
    if (!theme.isFrost()) d = d.shadowLg();
    return d;
}

/// `text-[15px] font-semibold`.
pub fn title(theme: *const Theme, text: []const u8) zpui.Div {
    return div().textSize(theme_mod.rems(15)).fontWeight(600).textColor(theme.text).child(text);
}

/// `text-[13px] leading-relaxed text-muted-foreground`.
pub fn body(theme: *const Theme, text: []const u8) zpui.Div {
    return div().textSize(theme_mod.rems(13)).lineHeight(px(19)).textColor(theme.text_muted).child(text);
}

pub fn btnGhost(theme: *const Theme, label: []const u8) zpui.Div {
    return div().px(px(12)).py(px(6)).rounded(px(8)).textSize(theme_mod.rems(13))
        .textColor(theme.text_muted).cursorPointer()
        .hover(sb.bg(theme.ink(0.06)).textColor(theme.text))
        .child(label);
}

pub fn btnPrimary(theme: *const Theme, label: []const u8) zpui.Div {
    return div().px(px(12)).py(px(6)).rounded(px(8)).bg(theme.text)
        .textSize(theme_mod.rems(13)).fontWeight(500).textColor(theme.on_solid)
        .cursorPointer().hover(sb.opacity(0.9)).child(label);
}

pub fn btnDanger(theme: *const Theme, label: []const u8) zpui.Div {
    return div().px(px(12)).py(px(6)).rounded(px(8)).bg(theme.danger_strong)
        .textSize(theme_mod.rems(13)).fontWeight(500).textColor(zpui.color.white)
        .cursorPointer().hover(sb.opacity(0.9)).child(label);
}

/// The full-window scrim (black 0.35) with `content` centered, frosted, in a
/// deferred layer. `on_scrim` fires for mouse-downs outside the card.
pub fn modal(window: *zpui.Window, content: zpui.Div, on_scrim: anytype) zpui.AnyElement {
    const vp = window.viewportSize();
    const framed = effects.frosted(16, theme_mod.layout.menu_blur, content);
    return zpui.intoAnyElement(zpui.deferred(zpui.anchored().position(.{ .x = 0, .y = 0 }).child(
        div().occlude().w(px(vp.width)).h(px(vp.height)).bg(zpui.color.black.alpha(0.35))
            .flex().itemsCenter().justifyCenter()
            .child(anim.menuIn("dialog-in", div().onMouseDownOut(on_scrim).child(framed), 2)),
    )).withPriority(3));
}
