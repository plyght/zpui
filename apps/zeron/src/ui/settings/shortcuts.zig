//! Settings → Shortcuts (zeron `settings/shortcuts.rs`): one block per group
//! of rebindable shortcuts. Click a combo to record (the app keymap is
//! suspended meanwhile so the chord never fires), Escape cancels; a combo
//! another shortcut owns (or the reserved composer send chord) is refused
//! with a notice naming the owner. Customized rows offer Reset; Restore
//! defaults resets everything. Changes persist and re-bind immediately.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const model = @import("zeron_model");
const ui = @import("../components/root.zig");
const store = @import("store.zig");
const w = @import("widgets.zig");
const view_mod = @import("view.zig");

const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const rems = ui.rems;
const settings = model.settings;
const ShortcutId = settings.ShortcutId;

const group_order = [_][]const u8{ "Appearance", "Files", "Browser", "Panels", "Sessions", "Projects", "Jump to session", "Appshots", "Voice" };

/// The section a shortcut's row renders under.
pub fn group(id: ShortcutId) []const u8 {
    return switch (id) {
        .random_wallpaper => "Appearance",
        .capture_appshot => "Appshots",
        .save_file => "Files",
        .browser_reload => "Browser",
        .toggle_sidebar, .toggle_changes, .toggle_files, .toggle_terminal => "Panels",
        .new_project => "Projects",
        .toggle_dictation => "Voice",
        .open_model_picker, .new_session, .next_session, .prev_session, .archive_session => "Sessions",
        .jump_session => "Jump to session",
    };
}

pub fn indexOf(id: ShortcutId) usize {
    for (ShortcutId.all, 0..) |x, i| if (std.meta.eql(x, id)) return i;
    return 0;
}

fn display(combo: []const u8) []const u8 {
    const buf = zpui.window.arena_mod.frameAllocator().alloc(u8, 64) catch return combo;
    return settings.displayCombo(buf, combo);
}

/// The shortcut other than `id` already bound to `combo`.
pub fn conflictOwner(keymap: *const settings.KeymapConfig, id: ShortcutId, combo: []const u8) ?ShortcutId {
    for (ShortcutId.all) |other| {
        if (!other.available() or std.meta.eql(other, id)) continue;
        if (std.mem.eql(u8, keymap.get(other), combo)) return other;
    }
    return null;
}

/// Why `combo` cannot be bound to `id` (writes the notice into the view).
pub fn refusal(v: *SettingsView, id: ShortcutId, combo: []const u8, cx: anytype) ?[]const u8 {
    v.notice.clearRetainingCapacity();
    var buf: [64]u8 = undefined;
    const shown = settings.displayCombo(&buf, combo);
    const mods = settings.comboModifiers(combo);
    if (id == .capture_appshot and !mods.mod and !mods.alt and std.mem.indexOf(u8, combo, "ctrl-") == null) {
        v.notice.print(v.gpa, "Use {s} with a letter, number, function key or navigation key.", .{if (builtin.os.tag == .macos) "Control, Option or Command" else "Control or Alt"}) catch {};
        return v.notice.items;
    }
    if (std.mem.eql(u8, combo, "mod-enter")) {
        v.notice.print(v.gpa, "{s} is reserved for the composer.", .{shown}) catch {};
        return v.notice.items;
    }
    const s = store.current(cx);
    const owner = conflictOwner(&s.keymap, id, combo) orelse return null;
    const g = group(owner);
    const page: []const u8 = if (std.mem.eql(u8, g, "Appshots")) " in Settings → Appshots" else if (std.mem.eql(u8, g, "Voice")) " in Settings → Voice" else "";
    v.notice.print(v.gpa, "{s} is already assigned to {s}{s}.", .{ shown, owner.label(), page }) catch {};
    return v.notice.items;
}

/// Reset (when customized) + the click-to-record combo chip.
pub fn bindingControl(v: *SettingsView, id: ShortcutId, t: *const Theme, cx: *Context(SettingsView)) zpui.Div {
    const s = store.current(cx);
    const ix = indexOf(id);
    const combo = s.keymap.get(id);
    const recording = if (v.recording) |r| std.meta.eql(r, id) else false;
    const non_default = !std.mem.eql(u8, combo, id.defaultCombo());
    var ctl = div().flex().flexNone().itemsCenter().gap(px(20));
    if (non_default and !recording) {
        ctl = ctl.child(div().id(.{ "shortcut-reset", ix }).role(.button).ariaLabel(zpui.fmt("Reset {s} shortcut", .{id.label()})).minH(px(24)).flex().itemsCenter()
            .textSize(rems(11)).textColor(t.text_muted).cursorPointer().hover(sb.textColor(t.text))
            .onClick(cx.listenerWith(ix, SettingsView.onResetShortcut)).child("Reset"));
    }
    var chip = div().id(.{ "shortcut-combo", ix }).role(.button).ariaLabel(zpui.fmt("Change {s} shortcut: {s}", .{ id.label(), display(combo) })).minW(px(96)).h(px(w.select_height)).px(px(12)).rounded(px(8))
        .border1().flex().itemsCenter().justifyCenter()
        .fontFamily(t.font_mono).textSize(rems(12)).cursorPointer()
        .onClick(cx.listenerWith(ix, SettingsView.onRecord));
    if (recording) {
        chip = chip.bg(t.accent.opacity(0.16)).borderColor(t.accent.opacity(0.55)).textColor(t.text).child("Press keys…");
    } else {
        chip = chip.borderColor(zpui.hsla(0, 0, 0, 0)).bg(w.selectFill(t, false)).hover(sb.bg(w.selectFill(t, true)))
            .textColor(t.text).child(display(combo));
    }
    return ctl.child(chip);
}

/// A shortcut recorder on a feature page (Voice): the control plus its
/// helper line while recording or after a refusal.
pub fn field(v: *SettingsView, id: ShortcutId, t: *const Theme, cx: *Context(SettingsView)) zpui.Div {
    var d = div().flex().flexCol().itemsEnd().gap(px(4)).child(bindingControl(v, id, t, cx));
    const recording = if (v.recording) |r| std.meta.eql(r, id) else false;
    const mine = if (v.notice_for) |n| std.meta.eql(n, id) else false;
    if (recording) {
        d = d.child(div().textSize(rems(12)).textColor(t.text_muted).child("Press Escape to cancel."));
    } else if (mine and v.notice.items.len > 0) {
        d = d.child(div().textSize(rems(12)).textColor(t.text_muted).child(v.notice.items));
    }
    return d;
}

fn shortcutRow(v: *SettingsView, id: ShortcutId, first: bool, t: *const Theme, cx: *Context(SettingsView)) zpui.Div {
    var text = div().flex1().minW(px(160)).flex().flexCol().child(w.rowTitle(t, id.label()));
    if (id == .next_session or id == .prev_session) text = text.child(w.metaLine(t, &.{.{ .text = "Navigate within the focused pane." }}));
    return w.cardRow(t, first).child(text).child(bindingControl(v, id, t, cx));
}

pub fn render(v: *SettingsView, t: *const Theme, _: *zpui.Window, cx: *Context(SettingsView)) zpui.Div {
    const s = store.current(cx);
    const default_keymap: settings.KeymapConfig = .{};
    const customized = !settings.deepEql(s.keymap, default_keymap) or s.escapeStopsActiveAgent or s.composerSendBehavior != .enter;
    const disabled = !customized or v.recording != null;

    var restore = w.actionButton(t, .quiet).id("shortcuts-restore-defaults").role(.button).flexNone()
        .child(ui.icon.of(.restart, 14, t.text_muted)).child("Restore defaults");
    if (disabled) restore = restore.opacity(0.35) else restore = restore.onClick(cx.listener(SettingsView.onRestoreDefaults));

    const header = div().flex().flexRow().itemsStart().flexWrap().justifyBetween().gap(px(24))
        .child(div().flex1().minW(px(200)).flex().flexCol()
        .child(w.pageHeader(t, "Keyboard shortcuts", null))
        .child(w.pageSubtitle(t, "Click a binding, then press the new key combination.").maxW(px(512)).lineHeight(px(20))))
        .child(restore);

    var groups = div().flex().flexCol();
    for (group_order) |name| {
        if (std.mem.eql(u8, name, "Appshots") or std.mem.eql(u8, name, "Voice")) continue;
        var card = w.sectionCard(t).mt0();
        var gx: usize = 0;
        for (ShortcutId.all) |id| {
            if (!std.mem.eql(u8, group(id), name)) continue;
            card = card.child(shortcutRow(v, id, gx == 0, t, cx));
            gx += 1;
        }
        if (gx > 0) groups = groups.child(w.section(t, name, card));
    }
    const helper: []const u8 = if (v.recording != null) "Press Escape to cancel." else if (v.notice.items.len > 0) v.notice.items else "Shortcuts must be unique.";
    return w.pageColumn()
        .child(header)
        .child(groups)
        .child(div().mt(px(12)).px(px(4)).minH(px(20)).flex().justifyCenter().textSize(rems(12)).textColor(t.text_muted).child(helper));
}
