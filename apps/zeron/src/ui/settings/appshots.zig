//! Settings → Appshots (zeron `settings/appshots.rs`, Linux X11 copy):
//! capture + sound switches, the global capture shortcut with its readiness
//! badge, destination, and the platform capability rows.

const zpui = @import("zpui");
const ui = @import("../components/root.zig");
const store = @import("store.zig");
const w = @import("widgets.zig");
const select = @import("select.zig");
const shortcuts = @import("shortcuts.zig");
const view_mod = @import("view.zig");

const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const div = zpui.div;
const px = zpui.px;
const rems = ui.rems;

const setup_description = "X11 normally needs no capture permission. Zeron prefers an active-window screenshot portal when available and otherwise uses native X11 capture.";
const shortcut_description = "The shortcut works while another application has focus.";
const capture_description = "Zeron uses native X11 capture when active-window portal capture is unavailable. Obscured or protected windows may be incomplete.";
const semantic_description = "Native X11 captures can include AT-SPI text when the process and window can be matched uniquely. Portal captures include the screenshot only.";

fn row(t: *const Theme, first: bool, title: []const u8, description: []const u8, control: anytype) zpui.Div {
    return w.cardRow(t, first).flexWrap()
        .child(div().flex1().minW(px(160)).flex().flexCol().gap(px(2))
        .child(w.rowTitle(t, title))
        .child(div().textSize(rems(12)).lineHeight(rems(16)).textColor(t.text_muted).child(description)))
        .child(control);
}

fn destinationDescription(d: @import("zeron_model").settings.AppshotDestination) []const u8 {
    return switch (d) {
        .automatic => "Use the open session, or the new-session composer when no session is open.",
        .@"last-session" => "Use the open session, or return to the last session used for an Appshot.",
        .@"new-session" => "Stage captures in a new-session composer, keeping existing drafts intact.",
    };
}

pub fn render(v: *SettingsView, t: *const Theme, _: *zpui.Window, cx: *zpui.Context(SettingsView)) zpui.Div {
    const s = store.current(cx);
    const card = w.sectionCard(t)
        .child(row(t, true, "Capture Appshots", "Captures are staged for review and never sent automatically.", v.toggle(.appshots_enabled, s.appshotsEnabled, true, t, cx)))
        .child(row(t, false, "Capture sound", "Play a sound when an Appshot is ready.", v.toggle(.appshot_sound, s.appshotSoundEnabled, true, t, cx)))
        .child(row(t, false, "Global shortcut", shortcut_description, div().flex().itemsCenter().gap(px(10))
        .child(w.badge(t, "Ready")).child(shortcuts.bindingControl(v, .capture_appshot, t, cx))))
        .child(row(t, false, "Destination", destinationDescription(s.appshotDestination), select.render(v, .appshot_destination, t, cx)))
        .child(row(t, false, "Window capture", capture_description, div().flex().itemsCenter().gap(px(10)).child(w.badge(t, "Ready"))))
        .child(row(t, false, "Application text", semantic_description, div().flex().itemsCenter().gap(px(10)).child(w.badge(t, "Ready"))));
    const mine = if (v.notice_for) |n| n == .capture_appshot else false;
    const helper: []const u8 = if (v.recording != null) "Press Escape to cancel." else if (mine) v.notice.items else "";
    return w.pageColumn()
        .child(w.pageHeader(t, "Appshots", null))
        .child(w.pageSubtitle(t, setup_description).lineHeight(px(20)))
        .child(card)
        .child(div().minH(px(20)).mt(px(8)).px(px(8)).textSize(px(12)).textColor(t.text_muted).child(helper))
        .child(div().mt(px(12)).pl(px(8)).flex().flexWrap().itemsCenter().gap(px(12))
        .child(div().flex1().textSize(px(12)).textColor(t.text_muted).child("Changed a permission? Check again after returning to Zeron."))
        .child(w.actionButton(t, .quiet).id("appshots-refresh-permissions").child("Check again")));
}
