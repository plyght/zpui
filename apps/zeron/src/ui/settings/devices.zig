//! Settings → Devices (zeron `settings/devices.rs`): this device and (in a
//! synced workspace) the others, each with platform · version · presence,
//! Copy ID and Rename (a small dialog over a scrim; Enter saves).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const prefs_mod = @import("../shell/prefs.zig");
const w = @import("widgets.zig");
const view_mod = @import("view.zig");

const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const div = zpui.div;
const px = zpui.px;
const rems = ui.rems;
const Device = engine.protocol.Device;

const online_window_secs: i64 = 70;

pub fn platformLabel(p: []const u8) []const u8 {
    if (std.mem.eql(u8, p, "macos") or std.mem.eql(u8, p, "darwin")) return "macOS";
    if (std.mem.eql(u8, p, "linux")) return "Linux";
    if (std.mem.eql(u8, p, "windows")) return "Windows";
    if (std.mem.eql(u8, p, "web")) return "Web";
    if (std.mem.eql(u8, p, "ios")) return "iOS";
    if (std.mem.eql(u8, p, "android")) return "Android";
    return p;
}

fn subtitle(scope: ?engine.protocol.WorkspaceScope) []const u8 {
    const sc = scope orelse return "Devices in this workspace.";
    return switch (sc) {
        .local => "Devices in this local workspace.",
        .synced => "Devices synced to this workspace.",
        .development => "Devices in this workspace.",
    };
}

fn lastSeen(secs: i64) []const u8 {
    if (secs < 60) return "just now";
    if (secs < 3600) return zpui.fmt("{d}m ago", .{@divTrunc(secs, 60)});
    if (secs < 86_400) return zpui.fmt("{d}h ago", .{@divTrunc(secs, 3600)});
    return zpui.fmt("{d}d ago", .{@divTrunc(secs, 86_400)});
}

fn deviceRow(v: *SettingsView, t: *const Theme, d: *const Device, ix: usize, first: bool, local: bool, now: model.Timestamp, cx: *zpui.Context(SettingsView)) zpui.Div {
    var meta: [3]w.Fragment = undefined;
    var n: usize = 0;
    meta[n] = .{ .text = platformLabel(d.platform) };
    n += 1;
    if (d.version) |ver| if (ver.len > 0) {
        meta[n] = .{ .text = zpui.fmt("v{s}", .{ver}) };
        n += 1;
    };
    if (!local) {
        const seen = model.time.parseOpt(d.lastSeenAt);
        const secs: ?i64 = if (seen) |s| now.secondsSince(s) else null;
        meta[n] = if (secs != null and secs.? <= online_window_secs)
            .{ .text = "Online", .color = t.success_muted }
        else
            .{ .text = if (secs) |s| zpui.fmt("Last seen {s}", .{lastSeen(s)}) else "Last seen never seen" };
        n += 1;
    }
    const copied = if (v.copied) |c| std.mem.eql(u8, c, d.id) else false;
    const frags = zpui.window.arena_mod.frameAllocator().dupe(w.Fragment, meta[0..n]) catch &.{};
    return w.cardRow(t, first)
        .child(w.textBlock(t, v.deviceName(d), frags))
        .child(div().flexNone().flex().itemsCenter().gap(px(4))
        .child(w.textAction(t, .quiet, if (copied) "Copied" else "Copy ID").id(.{ "device-id", ix })
        .onClick(cx.listenerWith(ix, SettingsView.onCopyDeviceId)))
        .child(w.textAction(t, .filled, "Rename").id(.{ "device-rename", ix })
        .onClick(cx.listenerWith(ix, SettingsView.onRenameDevice))));
}

pub fn render(v: *SettingsView, t: *const Theme, _: *zpui.Window, cx: *zpui.Context(SettingsView)) zpui.Div {
    const app_state = v.state.read(cx);
    const ws = app_state.workspace.read(cx);
    const scope = app_state.engine.read(cx).workspaceScope() orelse ws.workspace_scope;
    const now = prefs_mod.get(cx).now(ws.io);
    const list = ws.devices();
    var local_block: ?zpui.Div = null;
    var others = w.sectionCard(t).mt(px(8));
    var n_local: usize = 0;
    var n_other: usize = 0;
    for (list, 0..) |*d, ix| {
        const local = if (ws.local_device_id) |l| std.mem.eql(u8, l, d.id) else false;
        if (local) {
            local_block = (local_block orelse w.sectionCard(t).mt(px(8))).child(deviceRow(v, t, d, ix, n_local == 0, true, now, cx));
            n_local += 1;
        } else {
            others = others.child(deviceRow(v, t, d, ix, n_other == 0, false, now, cx));
            n_other += 1;
        }
    }
    if (n_other == 0) others = others.child(w.cardRow(t, true).child(div().textSize(rems(13)).textColor(t.text_muted).child("Sign in on another device to see it here.")));
    var body = div().flex().flexCol();
    if (local_block) |b| body = body.child(w.sectionLabel(t, "This device").mt(px(28))).child(b);
    if (scope == null or scope.? != .local) body = body.child(w.sectionLabel(t, "Other devices").mt(px(28))).child(others);
    return w.pageColumn()
        .child(w.pageHeader(t, "Devices", null))
        .child(w.pageSubtitle(t, subtitle(scope)))
        .child(body);
}

/// The rename dialog (`popover::dialog_card` + `modal`).
pub fn renameDialog(v: *SettingsView, window: *zpui.Window, cx: *zpui.Context(SettingsView)) zpui.AnyElement {
    const t_val = ui.theme.get(cx).forPopup();
    const t = &t_val;
    const r = v.rename.?;
    const card = div().id("rename-device-card").w(px(360)).p(px(20)).rounded(px(16))
        .bg(ui.popover.surfaceBg(t)).border1().borderColor(t.hairline(0.10))
        .flex().flexCol().textColor(t.text)
        .child(div().textSize(rems(15)).fontWeight(600).textColor(t.text).child("Rename device"))
        .child(div().mt(px(12)).child(div().wFull().px(px(12)).py(px(8)).rounded(px(8))
        .border1().borderColor(t.hairline(0.08)).bg(t.ink(0.04)).textSize(rems(14)).child(r.input)))
        .child(div().mt(px(16)).flex().flexRow().justifyEnd().gap(px(8))
        .child(w.textAction(t, .quiet, "Cancel").id("rename-cancel").onClick(cx.listener(SettingsView.onRenameCancel)))
        .child(w.textAction(t, .solid, "Rename").id("rename-save").onClick(cx.listener(SettingsView.onRenameSave))));
    const card_shadowed = if (t.isFrost()) card else card.shadowLg();
    const vs = window.viewportSize();
    return zpui.intoAnyElement(zpui.deferred(zpui.anchored().position(.{ .x = 0, .y = 0 })
        .child(div().occlude().w(px(vs.width)).h(px(vs.height)).bg(zt.theme.scrimFor(t.appearance, 0.35))
        .flex().itemsCenter().justifyCenter()
        .child(ui.anim.menuIn("rename-device-dialog", div().child(ui.effects.frosted(16, zt.layout.menu_blur, card_shadowed)), 2)))).withPriority(2));
}
