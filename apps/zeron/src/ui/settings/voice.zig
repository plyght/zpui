//! Settings → Voice (zeron `dictation/model.rs` `VoiceCard::render`): the
//! opt-in Dictation switch (downloads Parakeet v3 first, with live progress
//! and cancel), the microphone choice once dictation is on and ready, the
//! hold-to-dictate shortcut recorder (always visible so ⌘D can be rebound
//! before the download), errors, and the downloaded speech model with
//! Remove. State lives in the app's `VoiceModel` (voice/service.zig).

const std = @import("std");
const zpui = @import("zpui");
const ui = @import("../components/root.zig");
const store = @import("store.zig");
const w = @import("widgets.zig");
const shortcuts = @import("shortcuts.zig");
const select = @import("select.zig");
const view_mod = @import("view.zig");
const voice_service = @import("../../voice/service.zig");
const model_files = @import("../../voice/model.zig");

const SettingsView = view_mod.SettingsView;
const VoiceModel = voice_service.VoiceModel;
const Theme = ui.Theme;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;

/// `zeron_voice::download_size()` in MB, as Rust prints it (`{:.0}`).
fn sizeMb() f64 {
    return @as(f64, @floatFromInt(model_files.downloadSize())) / 1e6;
}

/// The Dictation row's meta line: progress while downloading, the size
/// before the model is installed, nothing once ready.
pub fn dictationMeta(downloading: bool, ready: bool, progress: u64) ?[]const u8 {
    if (downloading) return zpui.fmt("Downloading \u{b7} {d:.0} of {d:.0} MB", .{ @as(f64, @floatFromInt(progress)) / 1e6, sizeMb() });
    if (!ready) return zpui.fmt("{d:.0} MB download", .{sizeMb()});
    return null;
}

fn onRemove(_: *SettingsView, _: *const zpui.ClickEvent, _: *zpui.Window, cx: *zpui.Context(SettingsView)) void {
    if (voice_service.voiceModel(cx.app)) |vm| vm.update(cx, VoiceModel.remove, .{});
}

fn onRemoveKey(v: *SettingsView, ev: *const zpui.input.KeyDownEvent, window: *zpui.Window, cx: *zpui.Context(SettingsView)) void {
    if (!std.mem.eql(u8, ev.keystroke.key, "enter") and !std.mem.eql(u8, ev.keystroke.key, "space")) return;
    cx.stopPropagation();
    onRemove(v, undefined, window, cx);
}

fn refreshInputs(vm: *VoiceModel, cx: *zpui.Context(VoiceModel)) void {
    vm.refreshInputs(cx);
}

pub fn render(v: *SettingsView, t: *const Theme, _: *zpui.Window, cx: *zpui.Context(SettingsView)) zpui.Div {
    const s = store.current(cx);
    const vm_entity = voice_service.voiceModel(cx.app);
    const vm: ?*const VoiceModel = if (vm_entity) |e| e.read(cx) else null;
    const downloading = if (vm) |m| m.downloading() else false;
    const ready = if (vm) |m| m.ready else false;
    const progress = if (vm) |m| m.progress else 0;
    const on = downloading or (s.dictationEnabled and ready);

    var title_col = div().flex1().minW(px(160)).flex().flexCol().child(w.rowTitle(t, "Dictation"));
    if (dictationMeta(downloading, ready, progress)) |meta| {
        title_col = title_col.child(div().id("voice-status").role(.status).ariaLabel(meta)
            .child(w.metaLine(t, &.{.{ .text = meta }})));
    }
    if (downloading) {
        const fraction = std.math.clamp(@as(f32, @floatFromInt(progress)) / @as(f32, @floatFromInt(model_files.downloadSize())), 0, 1);
        title_col = title_col.child(div().mt(px(8)).wFull().h(px(3)).roundedFull().bg(t.border)
            .child(div().hFull().roundedFull().w(zpui.relative(fraction)).bg(t.accent)));
    }
    var card = w.sectionCard(t).child(w.cardRow(t, true).child(title_col).child(v.toggle(.dictation, on, true, t, cx)));

    if (s.dictationEnabled and ready) {
        if (vm_entity) |e| e.update(cx, refreshInputs, .{});
        card = card.child(w.cardRow(t, false)
            .child(div().flex1().minW(px(160)).child(w.rowTitle(t, "Microphone")))
            .child(select.render(v, .microphone, t, cx)));
    }
    // Always visible, so ⌘D can be rebound (and freed) before the model is downloaded.
    card = card.child(w.cardRow(t, false)
        .child(w.textBlock(t, "Shortcut", &.{.{ .text = "Hold to talk, release to transcribe" }}))
        .child(shortcuts.field(v, .toggle_dictation, t, cx)));

    var page = w.pageColumn()
        .child(w.pageHeader(t, "Voice", null))
        .child(w.pageSubtitle(t, "Transcribed on this device. Audio is never saved."))
        .child(card);
    if (vm) |m| if (m.err) |e| {
        page = page.child(div().id("voice-error").role(.status).ariaLabel(e).child(w.errorStrip(t, e)));
    };
    if (vm) |m| if (m.cache_present and !downloading) {
        page = page.child(w.sectionCard(t).child(w.cardRow(t, true)
            .child(w.textBlock(t, "Speech model", &.{ .{ .text = "Parakeet v3" }, .{ .text = zpui.fmt("{d:.0} MB", .{sizeMb()}) } }))
            .child(w.actionButton(t, .quiet).id("voice-remove").role(.button).ariaLabel("Remove speech model").tabIndex(0)
            .focusVisible(sb.border2().borderColor(t.accent))
            .onClick(cx.listener(onRemove))
            .onKeyDown(cx.listener(onRemoveKey))
            .child("Remove"))));
    };
    return page;
}

test "dictation meta follows download state" {
    try std.testing.expect(dictationMeta(false, true, 0) == null);
}
