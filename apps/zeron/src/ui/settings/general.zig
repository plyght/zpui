//! Settings → General (zeron `shortcuts.rs` general half +
//! `thread_naming.rs`): send key, compact transcript, compact model
//! picker, Escape stops the agent; then the thread-naming card.

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
    const naming = w.sectionCard(t).child(w.cardRow(t, true)
        .child(w.textBlock(t, "Thread naming", &.{.{ .text = "Each thread is named by its own agent." }}))
        .child(threadNamingPicker(v, t, cx)));
    return w.pageColumn().child(w.pageHeader(t, "General", null)).child(card).child(naming);
}

/// The compact picker chip ("Session agent" with the chat glyph).
fn threadNamingPicker(v: *SettingsView, t: *const Theme, cx: *zpui.Context(SettingsView)) zpui.StatefulDiv {
    const open = v.open_select == .thread_naming;
    const key = select.hoverKey(.thread_naming);
    const bg = if (open) t.glassHover() else ui.hover.blend(cx, key, t.glassHover().opacity(0), t.glassHover());
    var chip = div().id("thread-naming-picker").relative().flexNone().h(px(28)).px(px(6)).rounded(px(8))
        .flex().flexRow().itemsCenter().gap(px(6)).cursorPointer().bg(bg)
        .textSize(ui.rems(12.5)).textColor(t.text)
        .onHover(cx.listenerWith(select.SelectId.thread_naming, SettingsView.onSelectHover))
        .onClick(cx.listenerWith(select.SelectId.thread_naming, SettingsView.onSelectTrigger))
        .child(ui.icon.of(.chat_round_line, 16, t.text_muted))
        .child("Session agent");
    if (open) chip = chip.child(select.menuFor(v, .thread_naming, t, cx));
    return chip;
}
