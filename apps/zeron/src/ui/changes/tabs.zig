//! Right-pane chrome used around the Changes / History surfaces: the
//! 112px surface tab chip (`RightPanelTabs`), the `+` new-tab menu card
//! (Files / Browser / Terminal / Diffs / History) and the empty-pane
//! launcher (`render_surface_picker`). The shell owns the live versions; these
//! mirror them for hosts and the `changes-demo` harness.

const zpui = @import("zpui");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");

const Theme = zt.Theme;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Icon = ui.icon.Icon;

pub const chip_width: f32 = 112;

/// One surface tab: 24px, radius 6, 12px icon in an 18px box, 11.5px title.
pub fn surfaceTab(id: anytype, icon: Icon, title: []const u8, active: bool, theme: *const Theme) zpui.StatefulDiv {
    var chip = div().id(id).h(px(24)).w(px(chip_width)).flexNone().px(px(4)).rounded(px(6))
        .flex().flexRow().itemsCenter().gap(px(3)).cursorPointer()
        .child(div().flexNone().size(px(18)).flex().itemsCenter().justifyCenter()
            .child(ui.icon.of(icon, 12, if (active) theme.text_muted else theme.text_muted.opacity(0.7))))
        .child(div().flex1().minW0().truncate().whitespaceNowrap().textSize(ui.rems(11.5))
            .textColor(if (active) theme.text else theme.text_muted).child(title))
        .child(div().flexNone().size(px(18)));
    chip = if (active) chip.bg(theme.wash(0.10)) else chip.hover(sb.bg(theme.wash(0.06)));
    return chip;
}

/// The `+` button (24px) that opens the new-tab menu.
pub fn newTabButton(theme: *const Theme) zpui.StatefulDiv {
    return div().id("right-surface-new").relative().size(px(24)).flexNone().flex().itemsCenter().justifyCenter()
        .rounded(px(6)).cursorPointer().hover(sb.bg(theme.wash(0.06)))
        .child(ui.icon.of(.plus, 14, theme.text_muted));
}

pub const NewTabEntry = enum { files, browser, terminal, diffs, history };

/// The new-tab menu card (168px).
pub fn newTabMenu(theme: *const Theme) zpui.Div {
    var menu = ui.popover.card(theme).w(px(168));
    const rows = [_]struct { []const u8, Icon }{ .{ "Files", .document }, .{ "Browser", .globe }, .{ "Terminal", .terminal }, .{ "Diffs", .list }, .{ "History", .git_branch } };
    for (rows, 0..) |r, i| {
        menu = menu.child(ui.popover.menuRow(theme, false).id(.{ "newtab-row", i }).role(.menu_item)
            .child(ui.icon.of(r[1], 16, theme.text_muted)).child(r[0]));
    }
    return menu;
}

/// The empty right pane: 44px rows (icon + label) in a 280px column.
pub fn launcher(theme: *const Theme, git: bool) zpui.Div {
    var list = div().wFull().maxW(px(280)).flex().flexCol().gap(px(8))
        .child(surfaceCard(theme, "surface-card-browser", .globe, "Browser"))
        .child(surfaceCard(theme, "surface-card-terminal", .terminal, "Terminal"));
    if (git) list = list.child(surfaceCard(theme, "surface-card-diffs", .list, "Diffs"))
        .child(surfaceCard(theme, "surface-card-history", .git_branch, "History"));
    return div().sizeFull().relative().flex().itemsCenter().justifyCenter().p(px(16)).child(list);
}

pub fn surfaceCard(theme: *const Theme, id: []const u8, i: Icon, title: []const u8) zpui.StatefulDiv {
    return div().id(id).role(.button).ariaLabel(title).wFull().h(px(44)).px(px(14)).rounded(px(10))
        .border1().borderColor(theme.border).bg(theme.ink(0.02))
        .flex().flexRow().itemsCenter().gap(px(10)).cursorPointer()
        .hover(sb.bg(theme.ink(0.05)).borderColor(theme.border_strong))
        .child(ui.icon.of(i, 15, theme.text_muted))
        .child(div().textSize(ui.rems(13)).fontWeight(500).textColor(theme.text).child(title));
}
