//! zeron's one-line hover chip (`settings::widgets::TextTooltip`): a frosted
//! 6px-radius card, 11px muted text, hairline border.
//!
//! ```zig
//! div().id("x").tooltipWith(@as([]const u8, "Toggle left sidebar"), tooltip.build)
//! div().id("x").tooltipWith(@as([]const u8, "Archive"), tooltip.buildAbove)
//! ```
//! The label must outlive the tooltip (a literal or view-owned string).

const zpui = @import("zpui");
const theme_mod = @import("theme.zig");
const effects = @import("effects.zig");
const popover = @import("popover.zig");

const div = zpui.div;
const px = zpui.px;

pub const TextTooltip = struct {
    text: []const u8,
    above: bool = false,

    pub fn render(self: *TextTooltip, _: *zpui.Window, cx: *zpui.Context(TextTooltip)) zpui.AnyElement {
        const theme = theme_mod.get(cx);
        const card = div()
            .maxW(px(320)).px(px(9)).py(px(6)).rounded(px(6))
            .border1().borderColor(theme.border)
            .bg(popover.surfaceBg(theme))
            .fontFamily(theme.font_sans)
            .textSize(px(11)).lineHeight(px(17.8)).textColor(theme.text_muted)
            .whitespaceNowrap()
            .child(self.text);
        const frosted = effects.frosted(6, theme_mod.layout.menu_blur, card);
        if (!self.above) return zpui.intoAnyElement(frosted);
        return zpui.intoAnyElement(div().h(px(0)).flex().flexCol().justifyEnd()
            .child(div().relative().bottom(px(20)).child(frosted)));
    }
};

pub fn build(text: []const u8, _: *zpui.Window, cx: *zpui.App) zpui.Entity(TextTooltip) {
    return cx.new(TextTooltip, .{ .text = text }) catch @panic("OOM");
}

pub fn buildAbove(text: []const u8, _: *zpui.Window, cx: *zpui.App) zpui.Entity(TextTooltip) {
    return cx.new(TextTooltip, .{ .text = text, .above = true }) catch @panic("OOM");
}
