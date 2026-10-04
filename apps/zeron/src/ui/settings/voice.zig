//! Settings → Voice (zeron `dictation/model.rs` `VoiceCard`): the opt-in
//! dictation switch (Parakeet download size), microphone choice once ready,
//! and the hold-to-dictate shortcut recorder.

const std = @import("std");
const zpui = @import("zpui");
const ui = @import("../components/root.zig");
const store = @import("store.zig");
const w = @import("widgets.zig");
const shortcuts = @import("shortcuts.zig");
const view_mod = @import("view.zig");

const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const div = zpui.div;
const px = zpui.px;

/// Parakeet v3 int8 download (zeron_voice::download_size ≈ 670 MB).
const download_mb: u32 = 670;

pub fn render(v: *SettingsView, t: *const Theme, _: *zpui.Window, cx: *zpui.Context(SettingsView)) zpui.Div {
    const s = store.current(cx);
    const card = w.sectionCard(t)
        .child(w.cardRow(t, true)
        .child(w.textBlock(t, "Dictation", &.{.{ .text = zpui.fmt("{d} MB download", .{download_mb}) }}))
        .child(v.toggle(.dictation, s.dictationEnabled, true, t, cx)))
        .child(w.cardRow(t, false)
        .child(w.textBlock(t, "Shortcut", &.{.{ .text = "Hold to talk, release to transcribe" }}))
        .child(shortcuts.field(v, .toggle_dictation, t, cx)));
    return w.pageColumn()
        .child(w.pageHeader(t, "Voice", null))
        .child(w.pageSubtitle(t, "Transcribed on this device. Audio is never saved."))
        .child(card);
}

comptime {
    _ = std;
}
