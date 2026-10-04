//! Settings → Archived sessions (zeron `settings/archived.rs`): archived
//! chats newest first, 40 per page, each with an Unarchive action; a
//! centered empty state otherwise.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const ui = @import("../components/root.zig");
const prefs_mod = @import("../shell/prefs.zig");
const w = @import("widgets.zig");
const view_mod = @import("view.zig");

const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const rems = ui.rems;
const Chat = engine.protocol.Chat;

pub const page_size = 40;

/// Archived chats (minus ones unarchived this visit), newest activity first.
pub fn rows(v: *SettingsView, cx: anytype, a: std.mem.Allocator) ![]*const Chat {
    const ws = v.state.read(cx).workspace.read(cx);
    var out: std.ArrayList(*const Chat) = .empty;
    for (ws.chats()) |*c| if (c.archived and !v.isUnarchived(c.id)) try out.append(a, c);
    return out.items;
}

pub fn render(v: *SettingsView, t: *const Theme, _: *zpui.Window, cx: *zpui.Context(SettingsView)) zpui.Div {
    const a = zpui.window.arena_mod.frameAllocator();
    const list = rows(v, cx, a) catch &.{};
    const ws = v.state.read(cx).workspace.read(cx);
    const now = prefs_mod.get(cx).now(ws.io);
    var page = w.pageColumn()
        .child(w.pageHeader(t, "Archived sessions", if (list.len > 0) list.len else null))
        .child(w.pageSubtitle(t, "Hidden from the sidebar until restored."));
    if (list.len == 0) {
        return page.child(div().mt(px(96)).flex().flexCol().itemsCenter().textCenter().textColor(t.text_muted)
            .child(ui.icon.of(.archive_minimalistic, 28, t.text_muted.opacity(0.2)))
            .child(div().mt(px(12)).textSize(rems(14)).child("Nothing archived"))
            .child(div().mt(px(4)).textSize(rems(12)).textColor(t.text_muted).child("Right-click a session in the sidebar to archive it.")));
    }
    var items = div().mt(px(24)).flex().flexCol().gap(px(2));
    for (list[0..@min(list.len, page_size)], 0..) |c, ix| {
        const title = c.title orelse "Untitled session";
        var device: ?[]const u8 = null;
        for (ws.devices()) |*d| if (std.mem.eql(u8, d.id, c.deviceId)) {
            device = v.deviceName(d);
        };
        const at = model.time.parse(c.lastMessageAt orelse c.createdAt);
        const buf = a.alloc(u8, 16) catch continue;
        const ago = if (at) |ts| model.view.formatTimeAgo(buf, ts, now) else "";
        var meta = div().mt(px(2)).flex().flexRow().itemsCenter().gap(px(6)).textSize(rems(11)).textColor(t.text_muted);
        if (device) |d| meta = meta.child(d);
        const location = model.view.chatLocation(a, c) catch null;
        if (location) |l| {
            if (device != null) meta = meta.child("·");
            meta = meta.child(div().minW0().truncate().child(l));
        }
        items = items.child(div().id(.{ "archived-row", ix }).flex().flexRow().itemsCenter().gap(px(12))
            .rounded(px(8)).px(px(12)).py(px(8)).hover(sb.bg(t.ink(0.03)))
            .child(div().flexNone().size(px(32)).rounded(px(6)).border1().borderColor(t.border).flex().itemsCenter().justifyCenter()
            .child(ui.icon.of(.archive_minimalistic, 16, t.text_muted.opacity(0.6))))
            .child(div().flex1().minW0().flex().flexCol()
            .child(div().flex().flexRow().itemsCenter().gap(px(8))
            .child(div().minW0().truncate().textSize(rems(13)).fontWeight(500).textColor(t.text).child(title))
            .child(div().flexNone().textSize(rems(11)).textColor(t.text_muted).child(ago)))
            .child(meta))
            .child(div().id(.{ "unarchive", ix }).flexNone().flex().flexRow().itemsCenter().gap(px(6))
            .px(px(10)).py(px(4)).rounded(px(6)).border1().borderColor(t.border)
            .textSize(rems(12)).textColor(t.text_muted).opacity(0.8).cursorPointer()
            .hover(sb.bg(t.surface_raised).textColor(t.text))
            .onClick(cx.listenerWith(ix, SettingsView.onUnarchive))
            .child(ui.icon.of(.archive_up_minimalistic, 14, t.text_muted)).child("Unarchive")));
    }
    page = page.child(items);
    return page;
}
