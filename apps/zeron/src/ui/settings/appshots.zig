//! Settings → Appshots (zeron `settings/appshots.rs`): capture + sound switches,
//! the global capture shortcut with its readiness badge, destination, and the
//! platform capability rows (window capture, application text) with their access
//! actions; copy follows the live platform capabilities.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
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
const appshots = model.appshots;
const pf = zpui.platform;

fn row(t: *const Theme, first: bool, title: []const u8, description: []const u8, control: anytype) zpui.Div {
    return w.cardRow(t, first).flexWrap()
        .child(div().flex1().minW(px(160)).flex().flexCol().gap(px(2))
        .child(w.rowTitle(t, title))
        .child(div().textSize(rems(12)).lineHeight(rems(16)).textColor(t.text_muted).child(description)))
        .child(control);
}

pub fn destinationDescription(d: model.settings.AppshotDestination) []const u8 {
    return switch (d) {
        .automatic => "Use the open session, or the new-session composer when no session is open.",
        .@"last-session" => "Use the open session, or return to the last session used for an Appshot.",
        .@"new-session" => "Stage captures in a new-session composer, keeping existing drafts intact.",
    };
}

/// The capability snapshot the page shows (taken once, refreshed on demand).
pub fn capabilities(v: *SettingsView, app: *zpui.App) pf.WindowCaptureCapabilities {
    if (v.appshot_caps == null) v.appshot_caps = app.platform.windowCaptureCapabilities();
    return v.appshot_caps.?;
}

const Access = enum { capture, semantic };

fn onAccess(v: *SettingsView, kind: Access, _: *const zpui.ClickEvent, _: *zpui.Window, cx: *zpui.Context(SettingsView)) void {
    const caps = capabilities(v, cx.app);
    const prompted = switch (kind) {
        .capture => &v.capture_access_prompted,
        .semantic => &v.semantic_access_prompted,
    };
    const access: pf.CaptureAccess = if (kind == .capture) .capture else .semantic;
    if (prompted.*) {
        if (appshots.settingsUrl(caps.system, access)) |url| cx.app.platform.vtable.openUrl(cx.app.platform.ptr, url);
    } else {
        prompted.* = true;
        cx.app.platform.requestCaptureAccess(access);
    }
    v.appshot_caps = cx.app.platform.windowCaptureCapabilities();
    cx.notify();
}

fn onRefresh(v: *SettingsView, _: *const zpui.ClickEvent, _: *zpui.Window, cx: *zpui.Context(SettingsView)) void {
    v.appshot_caps = cx.app.platform.windowCaptureCapabilities();
    cx.notify();
}

fn accessButton(t: *const Theme, id: []const u8, label: []const u8, kind: Access, cx: *zpui.Context(SettingsView)) zpui.StatefulDiv {
    return w.actionButton(t, .quiet).id(id).role(.button).ariaLabel(label)
        .onClick(cx.listenerWith(kind, onAccess)).child(label);
}

pub fn render(v: *SettingsView, t: *const Theme, _: *zpui.Window, cx: *zpui.Context(SettingsView)) zpui.Div {
    const s = store.current(cx);
    const caps = capabilities(v, cx.app);
    var window_access = div().flex().itemsCenter().gap(px(10)).child(w.badge(t, appshots.badge(caps.window_capture)));
    if (s.appshotsEnabled and caps.window_capture == .permission_required) {
        const label = if (v.capture_access_prompted) "Open System Settings" else "Allow window capture";
        window_access = window_access.child(accessButton(t, "appshots-capture-access", label, .capture, cx));
    }
    var text_access = div().flex().itemsCenter().gap(px(10)).child(w.badge(t, appshots.badge(caps.application_text)));
    if (s.appshotsEnabled and caps.application_text == .permission_required and appshots.settingsUrl(caps.system, .semantic) != null) {
        const label = if (v.semantic_access_prompted) "Open System Settings" else "Enable text capture";
        text_access = text_access.child(accessButton(t, "appshots-semantic-access", label, .semantic, cx));
    }
    const card = w.sectionCard(t)
        .child(row(t, true, "Capture Appshots", "Captures are staged for review and never sent automatically.", v.toggle(.appshots_enabled, s.appshotsEnabled, true, t, cx)))
        .child(row(t, false, "Capture sound", "Play a sound when an Appshot is ready.", v.toggle(.appshot_sound, s.appshotSoundEnabled, true, t, cx)))
        .child(row(t, false, if (caps.system == .linux_wayland) "Preferred shortcut" else "Global shortcut", appshots.shortcutDescription(caps), div().flex().itemsCenter().gap(px(10))
        .child(w.badge(t, appshots.badge(caps.global_hotkey))).child(shortcuts.bindingControl(v, .capture_appshot, t, cx))))
        .child(row(t, false, "Destination", destinationDescription(s.appshotDestination), select.render(v, .appshot_destination, t, cx)))
        .child(row(t, false, "Window capture", appshots.captureDescription(caps), window_access))
        .child(row(t, false, "Application text", appshots.semanticDescription(caps), text_access));
    const mine = if (v.notice_for) |n| n == .capture_appshot else false;
    const helper: []const u8 = if (v.recording != null) "Press Escape to cancel." else if (mine) v.notice.items else "";
    return w.pageColumn()
        .child(w.pageHeader(t, "Appshots", null))
        .child(w.pageSubtitle(t, appshots.setupDescription(caps)).lineHeight(px(20)))
        .child(card)
        .child(div().minH(px(20)).mt(px(8)).px(px(8)).textSize(px(12)).textColor(t.text_muted).child(helper))
        .child(div().mt(px(12)).pl(px(8)).flex().flexWrap().itemsCenter().gap(px(12))
        .child(div().flex1().textSize(px(12)).textColor(t.text_muted).child("Changed a permission? Check again after returning to Zeron."))
        .child(w.actionButton(t, .quiet).id("appshots-refresh-permissions").role(.button).ariaLabel("Check permissions again")
        .onClick(cx.listener(onRefresh)).child("Check again")));
}
