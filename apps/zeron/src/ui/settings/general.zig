//! Settings → General (zeron `shortcuts.rs` general half +
//! `thread_naming.rs`): send key, compact transcript, compact model
//! picker, Escape stops the agent; then the new-thread defaults card
//! (default agent + model) and the thread-naming card.

const zpui = @import("zpui");
const ui = @import("../components/root.zig");
const store = @import("store.zig");
const w = @import("widgets.zig");
const select = @import("select.zig");
const view_mod = @import("view.zig");
const thread_naming = @import("thread_naming.zig");
const new_thread_defaults = @import("new_thread_defaults.zig");

const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const div = zpui.div;
const px = zpui.px;

pub fn render(v: *SettingsView, t: *const Theme, _: *zpui.Window, cx: *zpui.Context(SettingsView)) zpui.Div {
    const s = store.current(cx);
    const card = w.sectionCard(t)
        .child(w.cardRow(t, true)
        .child(div().flex1().minW(px(160)).child(w.rowTitle(t, "Send messages with")))
        .child(select.render(v, .send_behavior, t, cx)))
        .child(w.cardRow(t, false)
        .child(w.textBlock(t, "Compact mode", &.{.{ .text = "Collapse thinking and tools." }}).minW0())
        .child(v.toggle(.compact_mode, s.transcriptCompactMode, true, t, cx)))
        .child(w.cardRow(t, false)
        .child(w.textBlock(t, "Compact model picker", &.{.{ .text = "Adjust effort with a slider, then open the model list when needed." }}).minW0())
        .child(v.toggle(.compact_model_picker, s.compactModelPicker, true, t, cx)))
        .child(w.cardRow(t, false)
        .child(w.textBlock(t, "Stop agent with Escape", &.{.{ .text = "When no dialog or menu is open." }}))
        .child(v.toggle(.escape_stops, s.escapeStopsActiveAgent, true, t, cx)));
    thread_naming.ensureLoaded(v, cx);
    var naming = w.sectionCard(t).child(w.cardRow(t, true)
        .child(w.textBlock(t, "Thread naming", &.{.{ .text = thread_naming.description(v) }}))
        .child(thread_naming.control(v, t, cx)));
    if (v.title.phase == .ready) if (v.title.err) |e| {
        naming = naming.child(w.cardRow(t, false).child(w.errorStrip(t, e)));
    };
    return w.pageColumn().child(w.pageHeader(t, "General", null)).child(card)
        .child(new_thread_defaults.card(v, t, cx)).child(naming);
}
