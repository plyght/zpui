//! Settings → Notifications (zeron `settings/notifications.rs`): desktop
//! banners (agent updates, background-only) and session sounds; subordinate
//! rows dim and go inert while their parent switch is off.

const zpui = @import("zpui");
const ui = @import("../components/root.zig");
const store = @import("store.zig");
const w = @import("widgets.zig");
const view_mod = @import("view.zig");
const select = @import("select.zig");

const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const div = zpui.div;
const px = zpui.px;

/// The switch inside its 44.8×40 activation target.
fn target(v: *SettingsView, which: select.Toggle, on: bool, interactive: bool, t: *const Theme, cx: *zpui.Context(SettingsView)) zpui.Div {
    return div().flexNone().w(px(w.switch_width)).h(px(40)).flex().itemsCenter().justifyCenter()
        .child(v.toggle(which, on, interactive, t, cx));
}

fn simpleRow(t: *const Theme, first: bool, title: []const u8) zpui.Div {
    return w.cardRow(t, first).child(div().flex1().minW(px(160)).flex().flexCol().child(w.rowTitle(t, title)));
}

pub fn render(v: *SettingsView, t: *const Theme, _: *zpui.Window, cx: *zpui.Context(SettingsView)) zpui.Div {
    const s = store.current(cx);
    const desktop = s.notificationsEnabled;
    const sound = s.soundEnabled;
    var agent_row = w.cardRow(t, false)
        .child(w.rowTile(t, .refresh))
        .child(div().flex1().minW0().flex().flexCol().child(w.rowTitle(t, "Agent updates"))
        .child(w.metaLine(t, &.{.{ .text = "Show a banner when monitored agent CLIs have updates." }})))
        .child(target(v, .agent_updates, s.agentUpdateNotifications, desktop, t, cx));
    var bg_row = simpleRow(t, false, "Only when in the background").child(target(v, .background_only, s.notificationsBackgroundOnly, desktop, t, cx));
    if (!desktop) {
        agent_row = agent_row.opacity(0.55);
        bg_row = bg_row.opacity(0.55);
    }
    const desktop_card = w.sectionCard(t).mt0()
        .child(simpleRow(t, true, "Desktop notifications").child(target(v, .desktop_notifications, desktop, true, t, cx)))
        .child(agent_row)
        .child(bg_row);

    var card = w.sectionCard(t).mt0()
        .child(simpleRow(t, true, "Session sounds").child(target(v, .sound, sound, true, t, cx)));
    const subs = [_]struct { []const u8, select.Toggle, bool }{
        .{ "Task completed", .sound_completion, s.soundCompletionEnabled },
        .{ "Input required", .sound_input, s.soundInputEnabled },
        .{ "Errors and disconnections", .sound_attention, s.soundAttentionEnabled },
    };
    for (subs) |r| {
        var row = simpleRow(t, false, r[0]).child(target(v, r[1], r[2], sound, t, cx));
        if (!sound) row = row.opacity(0.55);
        card = card.child(row);
    }
    return w.pageColumn()
        .child(w.pageHeader(t, "Notifications", null))
        .child(w.section(t, "Desktop", desktop_card).mt(px(24)))
        .child(w.section(t, "Sounds", card));
}
