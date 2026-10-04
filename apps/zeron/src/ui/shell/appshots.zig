//! [appshots] The shell's half of Appshot delivery (zeron `shell.rs`
//! `receive_appshot` / `show_appshot_error`): route a completed capture to the
//! destination the user picked (Settings → Appshots → Destination), stage it on that
//! draft's composer by explicit key, and focus the composer.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const composer_mod = @import("zeron_composer");
const shell_mod = @import("shell.zig");
const settings_ui = @import("../settings/root.zig");

const Shell = shell_mod.Shell;
const Window = zpui.Window;
const Context = zpui.Context;
const Captured = model.appshots.Captured;

fn composer(self: *Shell, cx: anytype) zpui.Entity(composer_mod.ComposerView) {
    return self.main.read(cx).slots.composer_view;
}

/// Back to the chat route (settings mode closes).
fn showChat(self: *Shell, window: *Window, cx: *Context(Shell)) void {
    if (self.settings_view != null) self.closeSettings(window, cx);
}

/// The chat an Appshot lands on (`receive_appshot`'s target), null = the
/// new-session canvas. `last` must still exist.
pub fn destinationChat(destination: model.settings.AppshotDestination, selected: ?[]const u8, last: ?[]const u8, last_exists: bool) ?[]const u8 {
    return switch (destination) {
        .automatic => selected,
        .@"last-session" => selected orelse (if (last_exists) last else null),
        .@"new-session" => null,
    };
}

/// `receive_appshot` (takes `shot`).
pub fn receive(self: *Shell, shot: Captured, window: *Window, cx: *Context(Shell)) void {
    const gpa = self.gpa;
    const destination = settings_ui.store.current(cx).appshotDestination;
    const ws_e = self.state.read(cx).workspace;
    const ws = ws_e.read(cx);
    const selected = ws.selected_chat;
    const last_exists = if (self.last_appshot_chat) |id| ws.chat(id) != null else false;
    const target_ref = destinationChat(destination, selected, self.last_appshot_chat, last_exists);
    // The key outlives the selection change below.
    const key = gpa.dupe(u8, target_ref orelse "") catch return;
    defer gpa.free(key);
    showChat(self, window, cx);
    if (target_ref != null) {
        if (selected == null or !std.mem.eql(u8, selected.?, key))
            ws_e.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, key)});
    } else if (destination == .@"new-session" or selected != null) {
        // A new canvas (upstream's project/device defaults stay).
        ws_e.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, null)});
    }
    const c = composer(self, cx);
    _ = c.update(cx, composer_mod.ComposerView.stageAppshotFor, .{ key, shot });
    c.update(cx, composer_mod.ComposerView.focusInput, .{window});
    cx.notify();
}

/// `show_appshot_error`.
pub fn showError(self: *Shell, message: []const u8, window: *Window, cx: *Context(Shell)) void {
    showChat(self, window, cx);
    const c = composer(self, cx);
    c.update(cx, composer_mod.ComposerView.showAppshotError, .{message});
    c.update(cx, composer_mod.ComposerView.focusInput, .{window});
    cx.notify();
}

/// Remember the last selected chat (`last_appshot_chat`, from `on_state_changed`).
pub fn noteSelection(self: *Shell, selected: ?[]const u8) void {
    const id = selected orelse return;
    if (id.len == 0) return;
    if (self.last_appshot_chat) |old| {
        if (std.mem.eql(u8, old, id)) return;
        self.gpa.free(old);
    }
    self.last_appshot_chat = self.gpa.dupe(u8, id) catch null;
}

test "destinations keep the open session, fall back to the last one, or a new canvas" {
    const t = std.testing;
    try t.expectEqualStrings("a", destinationChat(.automatic, "a", "b", true).?);
    try t.expect(destinationChat(.automatic, null, "b", true) == null);
    try t.expectEqualStrings("a", destinationChat(.@"last-session", "a", "b", true).?);
    try t.expectEqualStrings("b", destinationChat(.@"last-session", null, "b", true).?);
    try t.expect(destinationChat(.@"last-session", null, "b", false) == null);
    try t.expect(destinationChat(.@"new-session", "a", "b", true) == null);
}
