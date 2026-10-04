//! [wiring] The shell's event routing — what Rust's `Shell` does in its
//! subscriptions and `on_action` handlers, kept out of `shell.zig`:
//!
//! - keymap: the file editor's bindings are reinstalled after every keymap
//!   rebuild (Rust `gpui_base::init` inside `apply_keymap`), and
//!   `shell::SaveFile` saves the active file tab (`save_active_document`);
//! - `shell::ArchiveSession` (`archive_selected_chat`), `shell::OpenModelPicker`
//!   (`open_model_menu`);
//! - composer events: workspace slash commands (`execute_workspace_command`),
//!   the paperclip (the composer opens its own picker), dictation (no capture
//!   yet: a no-op hook);
//! - explorer "Add to chat" → a file reference in the composer
//!   (`attach_workspace_drag` → `add_workspace_path`);
//! - transcript links → the right pane's editor (`activate_session_link` →
//!   `open_workspace_file_link`); web links go to the system browser;
//! - spawn chips → subagent tabs; side-chat errors → the composer notice;
//! - the sidebar's Delete… (confirm dialog → `deleteChat`), sign-in URLs
//!   (opened in the browser, `start_sign_in`), "Enable sync" with its
//!   "Open browser again" dialog, the org gate (create / pick a workspace).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const actions = @import("zeron_actions");
const tr = @import("zeron_ui_transcript");
const md = @import("zeron_ui_markdown");
const composer_mod = @import("zeron_composer");
const input_mod = @import("zeron_input");
const ui = @import("../components/root.zig");
const shell_mod = @import("shell.zig");
const sidebar_mod = @import("../sidebar/sidebar.zig");
const right_pane_mod = @import("right_pane.zig");
const rp_chats = @import("right_pane_chats.zig");
const editor = @import("../editor/root.zig");
const settings_ui = @import("../settings/root.zig");
const background = @import("../background/root.zig");
const prefs_mod = @import("prefs.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Shell = shell_mod.Shell;
const TextInput = input_mod.TextInput;
const shell_actions = actions.shell;
const dialog = @import("../components/dialog.zig");
const Ctx = Context(Shell);

const log = std.log.scoped(.zeron_wiring);

pub const SyncFlow = enum { idle, enabling, canceling };

/// Shell-owned state for the routed flows (lives in `Shell.wiring`).
pub const State = struct {
    /// Chat id awaiting the "Delete session?" confirmation (owned).
    delete_confirm: ?[]u8 = null,
    sync_flow: SyncFlow = .idle,
    /// The org gate's workspace-name field and its status.
    org_input: ?Entity(TextInput) = null,
    org_sub: ?zpui.Subscription = null,
    org_error: ?[]u8 = null,
    org_submitting: bool = false,
    orgs_requested: bool = false,
    /// The transcript's inline-code link root last handed out (owned).
    link_root: ?[]u8 = null,
    /// A composer slash command waiting for the composer's update to end.
    pending_command: ?composer_mod.slash.WorkspaceCommand = null,
    /// "Rename project" dialog (`RenameSpaceDialog`) and "Remove project?" confirm.
    rename_space: ?struct { id: []u8, input: Entity(TextInput), sub: zpui.Subscription, focus_pending: bool = true } = null,
    delete_space: ?[]u8 = null,

    pub fn deinit(self: *State, gpa: std.mem.Allocator, app: *App) void {
        if (self.delete_confirm) |d| gpa.free(d);
        if (self.org_sub) |*s| s.deinit();
        if (self.org_input) |i| i.release(app);
        if (self.org_error) |e| gpa.free(e);
        if (self.link_root) |r| gpa.free(r);
        if (self.rename_space) |*r| {
            r.sub.deinit();
            r.input.release(app);
            gpa.free(r.id);
        }
        if (self.delete_space) |d| gpa.free(d);
        self.* = .{};
    }
};

/// The live shell for the process-wide transcript link hook.
var shell_ref: ?zpui.WeakEntity(Shell) = null;

fn installEditorBindings(app: *App) anyerror!void {
    try editor.actions.bindDefaults(app);
}

/// Called from `Shell.init`: subscribe to every routed source.
pub fn attach(self: *Shell, cx: *Ctx) !void {
    // The file editor's keymap rides every keymap rebuild (settings edits too).
    if (actions.keymap.component_bindings == null) {
        actions.keymap.component_bindings = installEditorBindings;
        settings_ui.store.applyKeymap(cx.app);
    }
    shell_ref = .{ .id = cx.entityId() };
    md.rich_text.registry.handler = onLink;
    background.wallpaper.open_appearance = openAppearance;

    const gpa = cx.gpa();
    const slots = &self.main.read(cx).slots;
    try self.subs.add(gpa, try cx.subscribe(slots.composer_view, onComposerEvent));
    try self.subs.add(gpa, try cx.subscribe(slots.transcript_view, onOpenSubagent));
    try self.subs.add(gpa, try cx.subscribe(self.sidebar, onDeleteChat));
    try self.subs.add(gpa, try cx.subscribe(self.sidebar, onEnableSync));
    try self.subs.add(gpa, try cx.subscribe(self.sidebar, onRenameSpace));
    try self.subs.add(gpa, try cx.subscribe(self.sidebar, onDeleteSpace));
    try self.subs.add(gpa, try cx.subscribe(self.right_pane, onAddToChat));
    try self.subs.add(gpa, try cx.subscribe(self.right_pane, onSideChatError));
    const auth = self.state.read(cx).auth;
    try self.subs.add(gpa, try cx.subscribe(auth, onSignInUrl));
    try self.subs.add(gpa, try cx.subscribe(auth, onAuthError));
    try self.subs.add(gpa, try cx.subscribe(auth, onAuthChanged));
}

/// Called from `Shell.deinit`.
pub fn detach(self: *Shell, app: *App) void {
    self.wiring.deinit(self.gpa, app);
    shell_ref = null;
    md.rich_text.registry.handler = null;
    background.wallpaper.open_appearance = null;
}

/// The shell actions this module handles (`Shell.render` root div).
pub fn actionsOn(root: zpui.Div, cx: *Ctx) zpui.Div {
    return root
        .onAction(shell_actions.SaveFile, cx.listener(actSaveFile))
        .onAction(shell_actions.RandomWallpaper, cx.listener(actRandomWallpaper))
        .onKeyDown(cx.listener(onShellKey))
        .onAction(shell_actions.ArchiveSession, cx.listener(actArchiveSession))
        .onAction(shell_actions.OpenModelPicker, cx.listener(actOpenModelPicker));
}

fn inChat(self: *Shell, cx: anytype) bool {
    return self.settings_view == null and self.state.read(cx).workspace.read(cx).selected_chat != null;
}

/// An open palette / project picker owns the keyboard (`overlay_owns_keyboard`).
fn overlayOwnsKeyboard(self: *Shell) bool {
    return self.palette != null or self.add_project != null or self.wiring.delete_confirm != null or
        self.wiring.rename_space != null or self.wiring.delete_space != null;
}

/// Escape on the chat route (`resolve_shell_escape`): with "Escape stops the
/// active agent" on and no overlay up, interrupt the selected chat's run.
fn onShellKey(self: *Shell, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Ctx) void {
    if (!std.mem.eql(u8, ev.keystroke.key, "escape") or !ev.keystroke.modifiers.none()) return;
    if (overlayOwnsKeyboard(self) or self.settings_view != null or self.palette != null) return;
    if (!settings_ui.store.current(cx).escapeStopsActiveAgent) return;
    const composer = self.main.read(cx).slots.composer_view;
    if (composer.update(cx, composer_mod.ComposerView.escapeStop, .{})) cx.stopPropagation();
}

/// `shell::RandomWallpaper` (mod-u, `Shell::random_wallpaper`): without a
/// folder, open Settings → Appearance and ask for one; else switch to a
/// random image (errors open Appearance with the message).
fn actRandomWallpaper(_: *Shell, _: *const shell_actions.RandomWallpaper, _: *Window, cx: *Ctx) void {
    background.wallpaper.randomize(cx.app, .shortcut);
}

/// `wallpaper.open_appearance`: Settings → Appearance (+ the folder prompt).
fn openAppearance(app: *App, choose_folder: bool) void {
    // Deferred: the shortcut path runs inside the shell's own action handler.
    if (choose_folder) app.deferFn({}, openAppearanceChoose) else app.deferFn({}, openAppearanceOnly);
}

fn openAppearanceChoose(_: void, app: *App) void {
    openAppearanceNow(true, app);
}

fn openAppearanceOnly(_: void, app: *App) void {
    openAppearanceNow(false, app);
}

fn openAppearanceNow(choose_folder: bool, app: *App) void {
    const weak = shell_ref orelse return;
    const Open = struct {
        fn f(self: *Shell, choose: bool, cx: *Ctx) void {
            const w = window0(cx) orelse return;
            self.openSettings(w, cx);
            if (self.settings_view) |v| v.update(cx, settings_ui.SettingsView.openSection, .{.appearance});
            if (choose) settings_ui.file_prompts.chooseWallpaperFolder(cx.app);
            cx.notify();
        }
    };
    _ = weak.update(app, Open.f, .{choose_folder});
}

/// `shell::SaveFile`: save the active file tab (chat route, pane open).
fn actSaveFile(self: *Shell, _: *const shell_actions.SaveFile, _: *Window, cx: *Ctx) void {
    if (!inChat(self, cx) or !self.rightOpen(cx)) return;
    const ed = rp_chats.activeFileEditor(self.right_pane.read(cx), cx) orelse return;
    ed.update(cx, editor.FileEditor.save, .{});
}

/// `shell::ArchiveSession`: archive the selected chat.
fn actArchiveSession(self: *Shell, _: *const shell_actions.ArchiveSession, _: *Window, cx: *Ctx) void {
    if (!inChat(self, cx) or overlayOwnsKeyboard(self)) return;
    const ws = self.state.read(cx).workspace;
    const id = ws.read(cx).archivableSelectedChat() orelse return;
    const copy = self.gpa.dupe(u8, id) catch return;
    defer self.gpa.free(copy);
    sidebar_mod.Sidebar.setChatArchived(ws, copy, true, cx);
}

/// `shell::OpenModelPicker`: the composer's model menu.
fn actOpenModelPicker(self: *Shell, _: *const shell_actions.OpenModelPicker, window: *Window, cx: *Ctx) void {
    if (self.settings_view != null or overlayOwnsKeyboard(self)) return;
    const c = self.main.read(cx).slots.composer_view;
    c.update(cx, composer_mod.ComposerView.toggleModelPicker, .{window});
}

// ---- composer --------------------------------------------------------------------------

fn window0(cx: anytype) ?*Window {
    const app: *App = if (@TypeOf(cx) == *App) cx else cx.app;
    return if (app.windows.items.len > 0) app.windows.items[0] else null;
}

fn onComposerEvent(self: *Shell, _: Entity(composer_mod.ComposerView), ev: *const composer_mod.ComposerEvent, cx: *Ctx) void {
    switch (ev.*) {
        .workspace_command => |c| {
            // The composer is mid-update: run the command once it is done.
            self.wiring.pending_command = c;
            cx.deferUpdate(runPendingCommand);
        },
        // The composer opens its own native picker; nothing to route.
        .attach_requested => {},
        // Hook for voice capture (not ported): the mic state is UI-only.
        .dictation_toggled => {},
        else => {},
    }
}

fn runPendingCommand(self: *Shell, cx: *Ctx) void {
    const cmd = self.wiring.pending_command orelse return;
    self.wiring.pending_command = null;
    executeWorkspaceCommand(self, cmd, cx);
}

/// `execute_workspace_command`.
pub fn executeWorkspaceCommand(self: *Shell, cmd: composer_mod.slash.WorkspaceCommand, cx: *Ctx) void {
    const w = window0(cx) orelse return;
    switch (cmd) {
        .model => self.main.read(cx).slots.composer_view.update(cx, composer_mod.ComposerView.toggleModelPicker, .{w}),
        .new => {
            const ws = self.state.read(cx).workspace;
            ws.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, null)});
        },
        .@"resume" => if (self.palette == null) self.togglePalette(w, cx),
        .settings => self.openSettings(w, cx),
        .diff => {
            self.setRightOpen(true, cx);
            self.right_pane.update(cx, right_pane_mod.RightPane.add, .{ right_pane_mod.Kind.diffs, w });
        },
        .files => if (!self.filesOpen(cx)) self.toggleFiles(w, cx),
        .terminal => {
            self.setRightOpen(true, cx);
            self.right_pane.update(cx, right_pane_mod.RightPane.add, .{ right_pane_mod.Kind.terminal, w });
        },
        .rename => {
            const id = self.state.read(cx).workspace.read(cx).selected_chat orelse return;
            const copy = self.gpa.dupe(u8, id) catch return;
            defer self.gpa.free(copy);
            self.sidebar.update(cx, sidebar_mod.Sidebar.beginRename, .{ copy, w });
        },
        // The composer interrupts the run itself.
        .stop => {},
    }
    cx.notify();
}

fn onAddToChat(self: *Shell, _: Entity(right_pane_mod.RightPane), ev: *const right_pane_mod.AddToChat, cx: *Ctx) void {
    const c = self.main.read(cx).slots.composer_view;
    c.update(cx, composer_mod.ComposerView.addWorkspacePath, .{ ev.path, ev.is_directory, window0(cx) });
}

fn onSideChatError(self: *Shell, _: Entity(right_pane_mod.RightPane), ev: *const right_pane_mod.SideChatError, cx: *Ctx) void {
    const c = self.main.read(cx).slots.composer_view;
    c.update(cx, composer_mod.ComposerView.showError, .{ev.message});
}

fn onOpenSubagent(self: *Shell, _: Entity(tr.TranscriptView), ev: *const tr.subagents.OpenSubagent, cx: *Ctx) void {
    // The chip lives in the conversation column: open the pane it lands in.
    self.setRightOpen(true, cx);
    var l = self.right_pane.lease(cx);
    defer l.end();
    rp_chats.openSubagent(l.value, ev.*, &l.cx);
}

// ---- links -----------------------------------------------------------------------------

fn onLink(url: []const u8, window: *Window, app: *App) bool {
    const weak = shell_ref orelse return false;
    var handled = false;
    _ = weak.update(app, openLink, .{ url, window, &handled });
    return handled;
}

/// A parsed workspace file link: `path` (absolute or relative) + location.
pub const FileLink = struct { path: []const u8, line: ?usize = null, col: ?usize = null };

fn percentDecode(buf: []u8, s: []const u8) []const u8 {
    var o: usize = 0;
    var i: usize = 0;
    while (i < s.len and o < buf.len) {
        if (s[i] == '%' and i + 2 < s.len + 0 and i + 2 <= s.len - 1) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                buf[o] = b;
                o += 1;
                i += 3;
                continue;
            } else |_| {}
        }
        buf[o] = s[i];
        o += 1;
        i += 1;
    }
    return buf[0..o];
}

/// `file:///abs/path[:line[:col]]`, or a scheme-less (relative / absolute)
/// path with an optional `#L12` / `:12:3` anchor. Web URLs return null.
pub fn parseFileLink(buf: []u8, url: []const u8) ?FileLink {
    var rest = url;
    if (std.mem.startsWith(u8, rest, "file://")) {
        rest = rest["file://".len..];
    } else {
        if (std.mem.indexOf(u8, rest, "://") != null) return null;
        if (std.mem.startsWith(u8, rest, "mailto:") or std.mem.startsWith(u8, rest, "#")) return null;
        if (std.mem.indexOfScalar(u8, rest, ':')) |c| {
            // `scheme:` shapes (not `C:\` drive paths, not `path:12`).
            if (c > 1 and std.ascii.isAlphabetic(rest[0]) and !std.ascii.isDigit(if (c + 1 < rest.len) rest[c + 1] else 'x')) return null;
        }
    }
    var line: ?usize = null;
    var col: ?usize = null;
    if (std.mem.indexOfScalar(u8, rest, '#')) |h| {
        const frag = rest[h + 1 ..];
        if (frag.len > 1 and frag[0] == 'L') line = std.fmt.parseInt(usize, frag[1 .. std.mem.indexOfScalar(u8, frag, 'C') orelse frag.len], 10) catch null;
        rest = rest[0..h];
    }
    // Trailing `:line[:col]`.
    var parts: [2]?usize = .{ null, null };
    var n: usize = 0;
    while (n < 2) {
        const c = std.mem.lastIndexOfScalar(u8, rest, ':') orelse break;
        const v = std.fmt.parseInt(usize, rest[c + 1 ..], 10) catch break;
        parts[n] = v;
        n += 1;
        rest = rest[0..c];
    }
    if (n == 2) {
        line = parts[1];
        col = parts[0];
    } else if (n == 1) line = parts[0];
    const decoded = percentDecode(buf, rest);
    if (decoded.len == 0) return null;
    return .{ .path = decoded, .line = line, .col = col };
}

/// The workspace-relative path for `path` under `root` (absolute inputs must
/// sit inside it; relative ones are taken as-is). Null when outside.
pub fn relativeTo(root: []const u8, path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] != '/') {
        const p = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;
        var it = std.mem.splitScalar(u8, p, '/');
        while (it.next()) |c| if (std.mem.eql(u8, c, "..")) return null;
        return p;
    }
    const r = std.mem.trimEnd(u8, root, "/");
    if (!std.mem.startsWith(u8, path, r) or path.len <= r.len + 1 or path[r.len] != '/') return null;
    return path[r.len + 1 ..];
}

/// `activate_session_link`: a file link opens in the right pane's editor
/// (at its line); anything else falls through to the system opener.
fn openLink(self: *Shell, url: []const u8, _: *Window, handled: *bool, cx: *Ctx) void {
    var buf: [4096]u8 = undefined;
    const link = parseFileLink(&buf, url) orelse return;
    const ws = self.state.read(cx).workspace.read(cx);
    const chat = ws.selectedChatRow() orelse return;
    const root = chat.cwd orelse (if (ws.spaceForChat(chat)) |sp| sp.path else return);
    const rel = relativeTo(root, link.path) orelse return;
    handled.* = true;
    self.setRightOpen(true, cx);
    var l = self.right_pane.lease(cx);
    defer l.end();
    rp_chats.openFileAt(l.value, rel, link.line, link.col, &l.cx);
}

/// Keep the transcript's inline-code file links rooted at the selected local
/// chat's checkout (`file_link_roots`); remote chats get none.
pub fn syncLinkRoot(self: *Shell, cx: *Ctx) void {
    const ws = self.state.read(cx).workspace.read(cx);
    const root: ?[]const u8 = blk: {
        const chat = ws.selectedChatRow() orelse break :blk null;
        if (ws.local_device_id) |l| if (!std.mem.eql(u8, l, chat.deviceId)) break :blk null;
        if (self.fixtures != null) break :blk null;
        break :blk chat.cwd orelse if (ws.spaceForChat(chat)) |sp| sp.path else null;
    };
    const same = if (self.wiring.link_root) |r| (root != null and std.mem.eql(u8, r, root.?)) else root == null;
    if (same) return;
    if (self.wiring.link_root) |r| self.gpa.free(r);
    self.wiring.link_root = if (root) |r| self.gpa.dupe(u8, r) catch null else null;
    const owned = self.wiring.link_root;
    const t = self.main.read(cx).slots.transcript_view;
    t.update(cx, struct {
        fn f(v: *tr.TranscriptView, r: ?[]const u8, c: *Context(tr.TranscriptView)) void {
            v.setWorkspaceRoot(r);
            c.notify();
        }
    }.f, .{owned});
}

/// Per-frame upkeep from `Shell.render` (cheap: both short-circuit).
pub fn tick(self: *Shell, cx: *Ctx) void {
    syncLinkRoot(self, cx);
    var l = self.right_pane.lease(cx);
    defer l.end();
    rp_chats.syncSections(l.value, &l.cx);
}

// ---- delete ----------------------------------------------------------------------------

fn onDeleteChat(self: *Shell, _: Entity(sidebar_mod.Sidebar), ev: *const sidebar_mod.DeleteChat, cx: *Ctx) void {
    if (self.wiring.delete_confirm) |d| self.gpa.free(d);
    self.wiring.delete_confirm = self.gpa.dupe(u8, ev.chat_id) catch null;
    cx.notify();
}

fn onDeleteCancel(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    cancelDelete(self, cx);
}

fn onDeleteScrim(self: *Shell, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Ctx) void {
    cancelDelete(self, cx);
}

fn cancelDelete(self: *Shell, cx: *Ctx) void {
    if (self.wiring.delete_confirm) |d| self.gpa.free(d);
    self.wiring.delete_confirm = null;
    cx.notify();
}

fn onDeleteConfirm(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    const id = self.wiring.delete_confirm orelse return;
    self.wiring.delete_confirm = null;
    defer self.gpa.free(id);
    deleteChat(self, id, cx);
}

/// `delete_chat`: leave the chat if it is open, drop its draft, `deleteChat`.
pub fn deleteChat(self: *Shell, chat_id: []const u8, cx: *Ctx) void {
    const ws = self.state.read(cx).workspace;
    if (ws.read(cx).selected_chat) |sel| if (std.mem.eql(u8, sel, chat_id)) {
        ws.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, null)});
    };
    self.main.read(cx).slots.composer_view.update(cx, composer_mod.ComposerView.purgeChat, .{chat_id});
    ws.update(cx, model.WorkspaceStore.mutate, .{engine.protocol.Mutate{ .deleteChat = .{ .chatId = chat_id } }}) catch |err| {
        self.sidebar.update(cx, sidebar_mod.Sidebar.setNotice, .{@as(?[]const u8, if (err == error.NotConnected) "Engine not connected" else "Delete failed")});
    };
    cx.notify();
}

fn deleteDialog(self: *Shell, window: *Window, theme_in: *const ui.Theme, cx: *Ctx) ?zpui.AnyElement {
    const id = self.wiring.delete_confirm orelse return null;
    const theme = zpui.window.arena_mod.current().create(ui.Theme, theme_in.forPopup());
    const ws = self.state.read(cx).workspace.read(cx);
    const raw = if (ws.chat(id)) |c| c.title orelse "New session" else "New session";
    const title = model.view.singleLine(zpui.window.arena_mod.frameAllocator(), raw) catch raw;
    const card = dialog.card(theme)
        .child(dialog.title(theme, "Delete session?"))
        .child(div().mt(px(6)).child(dialog.body(theme, zpui.fmt("\u{201C}{s}\u{201D} will be permanently deleted. This can\u{2019}t be undone.", .{title}))))
        .child(div().mt(px(16)).flex().flexRow().justifyEnd().gap(px(8))
        .child(dialog.btnGhost(theme, "Cancel").id("delete-chat-cancel").onClick(cx.listener(onDeleteCancel)))
        .child(dialog.btnDanger(theme, "Delete").id("delete-chat-confirm").onClick(cx.listener(onDeleteConfirm))));
    return dialog.modal(window, card, cx.listener(onDeleteScrim));
}

// ---- sign-in / sync ----------------------------------------------------------------------

fn onSignInUrl(_: *Shell, _: Entity(model.AuthStore), ev: *const model.status.SignInUrl, cx: *Ctx) void {
    cx.app.platform.vtable.openUrl(cx.app.platform.ptr, ev.url);
}

fn onAuthError(self: *Shell, _: Entity(model.AuthStore), ev: *const model.status.AuthError, cx: *Ctx) void {
    if (self.wiring.org_submitting or self.gate(cx) == .org_gate) {
        self.wiring.org_submitting = false;
        if (self.wiring.org_error) |e| self.gpa.free(e);
        self.wiring.org_error = self.gpa.dupe(u8, ev.message) catch null;
        cx.notify();
        return;
    }
    if (self.wiring.sync_flow == .canceling) self.wiring.sync_flow = .enabling;
    if (self.wiring.sync_flow == .enabling) self.wiring.sync_flow = .idle;
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Sign in failed: {s}", .{ev.message}) catch "Sign in failed";
    self.sidebar.update(cx, sidebar_mod.Sidebar.setNotice, .{@as(?[]const u8, msg)});
}

fn onAuthChanged(self: *Shell, auth: Entity(model.AuthStore), _: *const model.status.AuthChanged, cx: *Ctx) void {
    const a = auth.read(cx).auth orelse return;
    switch (a) {
        .signedIn => {
            self.wiring.sync_flow = .idle;
            self.wiring.org_submitting = false;
        },
        .signedOut => if (self.wiring.sync_flow == .canceling) {
            self.wiring.sync_flow = .idle;
        },
        .needsOrganization => {},
    }
    cx.notify();
}

fn onEnableSync(self: *Shell, _: Entity(sidebar_mod.Sidebar), _: *const sidebar_mod.EnableSync, cx: *Ctx) void {
    startSignIn(self, cx);
}

/// `start_sign_in`: `SignIn` → the browser (the URL comes back as an event).
pub fn startSignIn(self: *Shell, cx: *Ctx) void {
    const ws = self.state.read(cx).workspace.read(cx);
    if (ws.workspace_scope) |s| if (s == .development) return;
    if (ws.workspace_scope) |s| if (s == .local) {
        self.wiring.sync_flow = .enabling;
    };
    const auth = self.state.read(cx).auth;
    auth.update(cx, model.AuthStore.signIn, .{false}) catch |err| {
        self.wiring.sync_flow = .idle;
        self.sidebar.update(cx, sidebar_mod.Sidebar.setNotice, .{@as(?[]const u8, if (err == error.NotConnected) "Sign in failed: engine not connected" else "Sign in failed")});
    };
    cx.notify();
}

fn onSyncCancel(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    // `cancel_auth_setup`: drop the partial sign-in.
    self.wiring.sync_flow = .canceling;
    const auth = self.state.read(cx).auth;
    auth.update(cx, model.AuthStore.signOut, .{}) catch {
        self.wiring.sync_flow = .idle;
    };
    cx.notify();
}

fn onSyncReopen(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    startSignIn(self, cx);
}

fn onSyncScrim(_: *Shell, _: *const zpui.input.MouseDownEvent, _: *Window, _: *Ctx) void {}

fn syncDialog(self: *Shell, window: *Window, theme_in: *const ui.Theme, cx: *Ctx) ?zpui.AnyElement {
    const theme = zpui.window.arena_mod.current().create(ui.Theme, theme_in.forPopup());
    const card = switch (self.wiring.sync_flow) {
        .idle => return null,
        .enabling => dialog.card(theme)
            .child(dialog.title(theme, "Enable sync"))
            .child(div().mt(px(6)).child(dialog.body(theme, "Finish signing in in your browser. Zeron will keep using this local workspace until you quit and reopen.")))
            .child(div().mt(px(16)).flex().flexRow().justifyEnd().gap(px(8))
            .child(dialog.btnGhost(theme, "Cancel").id("sync-enable-cancel").onClick(cx.listener(onSyncCancel)))
            .child(dialog.btnPrimary(theme, "Open browser again").id("sync-enable-open-browser").onClick(cx.listener(onSyncReopen)))),
        .canceling => dialog.card(theme)
            .child(dialog.title(theme, "Canceling sync setup…"))
            .child(div().mt(px(6)).child(dialog.body(theme, "Removing the partial sign-in before returning to your local workspace."))),
    };
    return dialog.modal(window, card, cx.listener(onSyncScrim));
}

// ---- project rename / remove (`render_space_overlays`) ------------------------------------

fn onRenameSpace(self: *Shell, _: Entity(sidebar_mod.Sidebar), ev: *const sidebar_mod.RenameSpace, cx: *Ctx) void {
    openRenameSpace(self, ev.space_id, cx);
}

/// `open_rename_space`: a dialog seeded with the project's display name.
pub fn openRenameSpace(self: *Shell, space_id: []const u8, cx: *Ctx) void {
    closeRenameSpace(self, cx);
    const ws = self.state.read(cx).workspace.read(cx);
    const current = if (ws.space(space_id)) |sp| model.view.spaceDisplayName(sp) else "";
    const theme = ui.theme.get(cx);
    const in = cx.newWith(TextInput, TextInput.init, .{input_mod.Options{
        .placeholder = "Project name",
        .key_context = "Composer",
        .single_line = true,
        .text_size = 13,
        .line_height = 18,
        .colors = .{ .text = theme.text, .placeholder = theme.text_muted.opacity(0.6), .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
        .edge_fade = false,
    }}) catch return;
    in.update(cx, TextInput.setText, .{current});
    in.update(cx, TextInput.selectAllText, .{});
    const sub = cx.subscribe(in, onRenameSpaceInput) catch {
        in.release(cx);
        return;
    };
    const id = self.gpa.dupe(u8, space_id) catch return;
    self.wiring.rename_space = .{ .id = id, .input = in, .sub = sub };
    cx.notify();
}

fn closeRenameSpace(self: *Shell, cx: *Ctx) void {
    if (self.wiring.rename_space) |*r| {
        r.sub.deinit();
        r.input.release(cx);
        self.gpa.free(r.id);
    }
    self.wiring.rename_space = null;
    cx.notify();
}

fn onRenameSpaceInput(self: *Shell, _: Entity(TextInput), ev: *const input_mod.TextInputEvent, cx: *Ctx) void {
    switch (ev.*) {
        .submitted, .modified_submitted => submitRenameSpace(self, cx),
        .escape => closeRenameSpace(self, cx),
        else => {},
    }
}

/// `submit_rename_space`: a non-empty name → `renameSpace`.
pub fn submitRenameSpace(self: *Shell, cx: *Ctx) void {
    const r = self.wiring.rename_space orelse return;
    const name = std.mem.trim(u8, r.input.read(cx).text(), " \t\r\n");
    if (name.len > 0) {
        const owned = self.gpa.dupe(u8, name) catch return;
        defer self.gpa.free(owned);
        const ws = self.state.read(cx).workspace;
        ws.update(cx, model.WorkspaceStore.mutate, .{engine.protocol.Mutate{ .renameSpace = .{ .spaceId = r.id, .name = owned } }}) catch |err| {
            self.sidebar.update(cx, sidebar_mod.Sidebar.setNotice, .{@as(?[]const u8, if (err == error.NotConnected) "Engine not connected" else "Rename failed")});
        };
    }
    closeRenameSpace(self, cx);
}

fn onRenameSpaceSave(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    submitRenameSpace(self, cx);
}

fn onRenameSpaceCancel(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    closeRenameSpace(self, cx);
}

fn onRenameSpaceScrim(self: *Shell, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Ctx) void {
    closeRenameSpace(self, cx);
}

fn onDeleteSpace(self: *Shell, _: Entity(sidebar_mod.Sidebar), ev: *const sidebar_mod.DeleteSpace, cx: *Ctx) void {
    if (self.wiring.delete_space) |d| self.gpa.free(d);
    self.wiring.delete_space = self.gpa.dupe(u8, ev.space_id) catch null;
    cx.notify();
}

fn cancelDeleteSpace(self: *Shell, cx: *Ctx) void {
    if (self.wiring.delete_space) |d| self.gpa.free(d);
    self.wiring.delete_space = null;
    cx.notify();
}

fn onDeleteSpaceCancel(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    cancelDeleteSpace(self, cx);
}

fn onDeleteSpaceScrim(self: *Shell, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Ctx) void {
    cancelDeleteSpace(self, cx);
}

/// `delete_space`: `deleteSpace` (the engine removes its sessions).
pub fn onDeleteSpaceConfirm(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    const id = self.wiring.delete_space orelse return;
    self.wiring.delete_space = null;
    defer self.gpa.free(id);
    const ws = self.state.read(cx).workspace;
    ws.update(cx, model.WorkspaceStore.mutate, .{engine.protocol.Mutate{ .deleteSpace = .{ .spaceId = id } }}) catch |err| {
        self.sidebar.update(cx, sidebar_mod.Sidebar.setNotice, .{@as(?[]const u8, if (err == error.NotConnected) "Engine not connected" else "Remove failed")});
    };
    cx.notify();
}

fn spaceDialogs(self: *Shell, window: *Window, theme_in: *const ui.Theme, cx: *Ctx) ?zpui.AnyElement {
    const theme = zpui.window.arena_mod.current().create(ui.Theme, theme_in.forPopup());
    if (self.wiring.rename_space) |*r| {
        if (r.focus_pending) {
            r.focus_pending = false;
            window.focus(r.input.read(cx).focusHandle());
        }
        const card = dialog.card(theme)
            .child(dialog.title(theme, "Rename project"))
            .child(div().mt(px(12)).h(px(36)).px(px(12)).flex().itemsCenter().rounded(px(8)).border1().borderColor(theme.border)
                .bg(theme.bg).child(div().flex1().minW0().child(r.input)))
            .child(div().mt(px(16)).flex().flexRow().justifyEnd().gap(px(8))
            .child(dialog.btnGhost(theme, "Cancel").id("rename-space-cancel").onClick(cx.listener(onRenameSpaceCancel)))
            .child(dialog.btnPrimary(theme, "Rename").id("rename-space-save").onClick(cx.listener(onRenameSpaceSave))));
        return dialog.modal(window, card, cx.listener(onRenameSpaceScrim));
    }
    const id = self.wiring.delete_space orelse return null;
    const ws = self.state.read(cx).workspace.read(cx);
    const sp = ws.space(id);
    const name = if (sp) |s| model.view.spaceDisplayName(s) else "this project";
    const device = if (sp) |s| ws.deviceName(s.deviceId) orelse "its device" else "its device";
    const count = blk: {
        const a = zpui.window.arena_mod.frameAllocator();
        const list = ws.chatsInSpace(a, id) catch break :blk 0;
        break :blk list.len;
    };
    const copy = if (count == 1)
        zpui.fmt("Removing \u{201C}{s}\u{201D} permanently deletes its 1 session on {s}. This can\u{2019}t be undone.", .{ name, device })
    else
        zpui.fmt("Removing \u{201C}{s}\u{201D} permanently deletes its {d} sessions on {s}. This can\u{2019}t be undone.", .{ name, count, device });
    const card = dialog.card(theme)
        .child(dialog.title(theme, "Remove project?"))
        .child(div().mt(px(6)).child(dialog.body(theme, copy)))
        .child(div().mt(px(16)).flex().flexRow().justifyEnd().gap(px(8))
        .child(dialog.btnGhost(theme, "Cancel").id("delete-space-cancel").onClick(cx.listener(onDeleteSpaceCancel)))
        .child(dialog.btnDanger(theme, "Remove").id("delete-space-confirm").onClick(cx.listener(onDeleteSpaceConfirm))));
    return dialog.modal(window, card, cx.listener(onDeleteSpaceScrim));
}

/// The shell's modal overlays (`Shell.render`).
pub fn overlays(self: *Shell, window: *Window, cx: *Ctx) ?zpui.AnyElement {
    const theme = ui.theme.get(cx);
    if (deleteDialog(self, window, theme, cx)) |d| return d;
    if (spaceDialogs(self, window, theme, cx)) |d| return d;
    return syncDialog(self, window, theme, cx);
}

// ---- org gate ----------------------------------------------------------------------------

/// The org gate's name field (made on first render, `ensure_org_ui`), and
/// the membership list request (`load_orgs`).
pub fn orgInput(self: *Shell, cx: *Ctx) ?Entity(TextInput) {
    if (!self.wiring.orgs_requested) {
        self.wiring.orgs_requested = true;
        const auth = self.state.read(cx).auth;
        auth.update(cx, model.AuthStore.listOrgs, .{}) catch {};
    }
    if (self.wiring.org_input) |i| return i;
    const theme = ui.theme.get(cx);
    const in = cx.newWith(TextInput, TextInput.init, .{input_mod.Options{
        .placeholder = "Workspace name",
        .key_context = "Composer",
        .single_line = true,
        .text_size = 13,
        .line_height = 18,
        .colors = .{ .text = theme.text, .placeholder = theme.text_muted.opacity(0.6), .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
        .edge_fade = false,
    }}) catch return null;
    self.wiring.org_sub = cx.subscribe(in, onOrgInput) catch null;
    self.wiring.org_input = in;
    return in;
}

fn onOrgInput(self: *Shell, _: Entity(TextInput), ev: *const input_mod.TextInputEvent, cx: *Ctx) void {
    switch (ev.*) {
        .submitted, .modified_submitted => createOrg(self, cx),
        else => {},
    }
}

pub fn onCreateOrgClick(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    createOrg(self, cx);
}

/// `create_org`: validate the name, then `CreateOrg`; the AuthStatus stream
/// flips to SignedIn on success and the gate falls away.
pub fn createOrg(self: *Shell, cx: *Ctx) void {
    if (self.wiring.org_submitting) return;
    const in = self.wiring.org_input orelse return;
    const name = std.mem.trim(u8, in.read(cx).text(), " \t\r\n");
    if (self.wiring.org_error) |e| self.gpa.free(e);
    self.wiring.org_error = null;
    if (!model.status.orgNameValid(name)) {
        self.wiring.org_error = self.gpa.dupe(u8, "Enter a workspace name") catch null;
        return cx.notify();
    }
    const owned = self.gpa.dupe(u8, name) catch return;
    defer self.gpa.free(owned);
    const auth = self.state.read(cx).auth;
    self.wiring.org_submitting = true;
    auth.update(cx, model.AuthStore.createOrg, .{owned}) catch |err| {
        self.wiring.org_submitting = false;
        self.wiring.org_error = self.gpa.dupe(u8, if (err == error.NotConnected) "Engine not connected" else "Couldn't create the workspace") catch null;
    };
    cx.notify();
}

/// `select_org`.
pub fn onPickOrg(self: *Shell, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    if (self.wiring.org_submitting) return;
    const auth = self.state.read(cx).auth;
    const orgs = auth.read(cx).orgs;
    if (ix >= orgs.len) return;
    const id = self.gpa.dupe(u8, orgs[ix].organizationId) catch return;
    defer self.gpa.free(id);
    if (self.wiring.org_error) |e| self.gpa.free(e);
    self.wiring.org_error = null;
    self.wiring.org_submitting = true;
    auth.update(cx, model.AuthStore.selectOrg, .{id}) catch |err| {
        self.wiring.org_submitting = false;
        self.wiring.org_error = self.gpa.dupe(u8, if (err == error.NotConnected) "Engine not connected" else "Couldn't open that workspace") catch null;
    };
    cx.notify();
}

const testing = std.testing;

test "file links parse locations and stay inside the workspace" {
    var buf: [256]u8 = undefined;
    const a = parseFileLink(&buf, "file:///repo/src/main.zig:12:3").?;
    try testing.expectEqualStrings("/repo/src/main.zig", a.path);
    try testing.expectEqual(@as(?usize, 12), a.line);
    try testing.expectEqual(@as(?usize, 3), a.col);
    const b = parseFileLink(&buf, "src/lib.rs#L40").?;
    try testing.expectEqualStrings("src/lib.rs", b.path);
    try testing.expectEqual(@as(?usize, 40), b.line);
    const c = parseFileLink(&buf, "file:///a%20dir/x.md").?;
    try testing.expectEqualStrings("/a dir/x.md", c.path);
    try testing.expect(parseFileLink(&buf, "https://example.com/x") == null);
    try testing.expect(parseFileLink(&buf, "mailto:a@b") == null);
    try testing.expectEqualStrings("src/a.rs", relativeTo("/repo/", "/repo/src/a.rs").?);
    try testing.expectEqualStrings("src/a.rs", relativeTo("/repo", "./src/a.rs").?);
    try testing.expect(relativeTo("/repo", "/repository/a") == null);
    try testing.expect(relativeTo("/repo", "../x") == null);
}
