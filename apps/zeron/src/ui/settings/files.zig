//! Settings → Files (zeron `settings/files.rs`): autosave (+ its delay),
//! word wrap, hidden and ignored files.

const zpui = @import("zpui");
const ui = @import("../components/root.zig");
const store = @import("store.zig");
const w = @import("widgets.zig");
const select = @import("select.zig");
const view_mod = @import("view.zig");

const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const div = zpui.div;
const px = zpui.px;

fn titleOnly(t: *const Theme, title: []const u8) zpui.Div {
    return div().flex1().minW(px(160)).flex().flexCol().child(w.rowTitle(t, title));
}

pub fn render(v: *SettingsView, t: *const Theme, _: *zpui.Window, cx: *zpui.Context(SettingsView)) zpui.Div {
    const s = store.current(cx);
    var card = w.sectionCard(t)
        .child(w.cardRow(t, true).child(titleOnly(t, "Autosave")).child(v.toggle(.files_autosave, s.filesAutosaveEnabled, true, t, cx)));
    if (s.filesAutosaveEnabled) card = card.child(w.cardRow(t, true).child(titleOnly(t, "Autosave delay")).child(select.render(v, .autosave_delay, t, cx)));
    card = card
        .child(w.cardRow(t, false).child(titleOnly(t, "Word wrap")).child(v.toggle(.files_word_wrap, s.filesWordWrap, true, t, cx)))
        .child(w.cardRow(t, false).child(titleOnly(t, "Show hidden and ignored files")).child(v.toggle(.files_show_all, s.filesShowAll, true, t, cx)));
    return w.pageColumn().child(w.pageHeader(t, "Files", null)).child(card);
}
