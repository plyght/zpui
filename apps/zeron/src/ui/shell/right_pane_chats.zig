//! [wiring] The right pane's agent-conversation tabs and explorer glue
//! (zeron `shell.rs` `add_subagent_surface`, `shell/side_chats.rs`
//! `fork_chat` / `create_child_chat` / `open_child_chat_tab`,
//! `shell/files_panel.rs` FilesEvent routing, `files/sections.rs` rows).
//! Free functions over `RightPane` so `right_pane.zig` stays small.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const composer_mod = @import("zeron_composer");
const rp_mod = @import("right_pane.zig");
const surfaces = @import("surfaces.zig");
const files = @import("../files/root.zig");
const editor = @import("../editor/root.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const RightPane = rp_mod.RightPane;
const ChatTabs = rp_mod.ChatTabs;
const es = model.engine_state;
const protocol = engine.protocol;
const Ctx = Context(RightPane);

pub fn subscribeExplorer(rp: *RightPane, t: *ChatTabs, e: Entity(files.FilesPanel), cx: *Ctx) void {
    _ = rp;
    const gpa = cx.gpa();
    t.explorer_subs.add(gpa, cx.subscribe(e, onAddToChat) catch return) catch {};
    t.explorer_subs.add(gpa, cx.subscribe(e, onExplorerSubagent) catch return) catch {};
    t.explorer_subs.add(gpa, cx.subscribe(e, onExplorerChildChat) catch return) catch {};
    t.explorer_subs.add(gpa, cx.subscribe(e, onExplorerNewChildChat) catch return) catch {};
    t.explorer_subs.add(gpa, cx.subscribe(e, onExplorerFork) catch return) catch {};
}

fn onAddToChat(_: *RightPane, _: Entity(files.FilesPanel), ev: *const files.panel.AddToChat, cx: *Ctx) void {
    cx.emit(rp_mod.AddToChat{ .path = ev.path, .is_directory = ev.is_directory });
}

fn onExplorerSubagent(rp: *RightPane, _: Entity(files.FilesPanel), ev: *const files.panel.OpenSubagent, cx: *Ctx) void {
    const chat = rp.key(cx) orelse return;
    // The footer row's status decides frozen-vs-live like the chip does.
    var frozen = false;
    if (rp.state.read(cx).transcript) |t| {
        const store = t.read(cx);
        var arena = std.heap.ArenaAllocator.init(cx.gpa());
        defer arena.deinit();
        if (@import("zeron_ui_transcript").subagents.subagentRows(arena.allocator(), store)) |rows| {
            for (rows) |r| if (std.mem.eql(u8, r.doc_id, ev.doc_id)) {
                frozen = @import("zeron_ui_transcript").subagents.isFrozen(r.status);
            };
        } else |_| {}
    }
    openSubagent(rp, .{ .chat_id = chat, .doc_id = ev.doc_id, .title = ev.title, .frozen = frozen }, cx);
}

fn onExplorerChildChat(rp: *RightPane, _: Entity(files.FilesPanel), ev: *const files.panel.OpenChildChat, cx: *Ctx) void {
    openSideChat(rp, ev.chat_id, null, cx);
}

fn onExplorerNewChildChat(rp: *RightPane, _: Entity(files.FilesPanel), _: *const files.panel.NewChildChat, cx: *Ctx) void {
    newChildChat(rp, cx);
}

fn onExplorerFork(rp: *RightPane, _: Entity(files.FilesPanel), _: *const files.panel.ForkChat, cx: *Ctx) void {
    forkSideChat(rp, cx);
}

// ---- subagent tabs ------------------------------------------------------------------------

/// `add_subagent_surface`: focus the tab already showing `doc_id`, or open one.
pub fn openSubagent(rp: *RightPane, ev: surfaces.OpenSubagent, cx: *Ctx) void {
    const t = rp.current(cx) orelse return;
    for (t.tabs.items) |tab| if (tab.surface == .subagent and std.mem.eql(u8, tab.surface.subagent.read(cx).doc_id, ev.doc_id)) {
        t.open = true;
        rp.activate(tab.id, cx);
        return;
    };
    const S = surfaces.SubagentSurface;
    const surface = cx.newWith(S, S.init, .{ rp.state, ev }) catch return;
    const tab = rp.push(.{ .subagent = surface }, cx) orelse return surface.release(cx);
    tab.sub = cx.subscribe(surface, onNestedSubagent) catch null;
}

fn onNestedSubagent(rp: *RightPane, _: Entity(surfaces.SubagentSurface), ev: *const surfaces.OpenSubagent, cx: *Ctx) void {
    openSubagent(rp, ev.*, cx);
}

fn onSideChatSubagent(rp: *RightPane, _: Entity(surfaces.SideChatSurface), ev: *const surfaces.OpenSubagent, cx: *Ctx) void {
    openSubagent(rp, ev.*, cx);
}

// ---- side chats ---------------------------------------------------------------------------

/// `open_side_chat_tab`: focus the side chat's tab, or open one.
/// `unsaved_parent`: a "New side chat" minted here (written on first send).
pub fn openSideChat(rp: *RightPane, chat_id: []const u8, unsaved_parent: ?[]const u8, cx: *Ctx) void {
    const t = rp.current(cx) orelse return;
    for (t.tabs.items) |tab| if (tab.surface == .side_chat and std.mem.eql(u8, tab.surface.side_chat.read(cx).chat_id, chat_id)) {
        t.open = true;
        rp.activate(tab.id, cx);
        return;
    };
    const S = surfaces.SideChatSurface;
    const surface = cx.newWith(S, S.init, .{ rp.state, chat_id, unsaved_parent }) catch return;
    const tab = rp.push(.{ .side_chat = surface }, cx) orelse return surface.release(cx);
    tab.sub = cx.subscribe(surface, onSideChatSubagent) catch null;
}

/// `create_child_chat`: a fresh, empty side chat under the open chat.
pub fn newChildChat(rp: *RightPane, cx: *Ctx) void {
    const parent = rp.key(cx) orelse return;
    if (rp.state.read(cx).workspace.read(cx).chat(parent) == null) {
        cx.emit(rp_mod.SideChatError{ .message = "Start a conversation before creating a side chat." });
        return;
    }
    var id: [36]u8 = undefined;
    _ = composer_mod.run_config.uuidV4(rp.state.read(cx).workspace.read(cx).io, &id);
    const parent_copy = cx.gpa().dupe(u8, parent) catch return;
    defer cx.gpa().free(parent_copy);
    openSideChat(rp, &id, parent_copy, cx);
}

/// `fork_chat` / `create_side_chat`: fork the open chat through its latest
/// completed response as a child of it (`ForkSideChat`), then open it.
pub fn forkSideChat(rp: *RightPane, cx: *Ctx) void {
    const st = rp.state.read(cx);
    const ws = st.workspace.read(cx);
    const source = ws.selectedChatRow() orelse {
        cx.emit(rp_mod.SideChatError{ .message = "Start a conversation before creating a side chat." });
        return;
    };
    var id: [36]u8 = undefined;
    _ = composer_mod.run_config.uuidV4(ws.io, &id);
    es.EngineState.request(st.engine, cx, RightPane, cx.entityId(), .ForkSideChat, surfaces.ForkParams{
        .chatId = &id,
        .sourceChatId = source.id,
        .parentChatId = source.id,
        .targetDeviceId = source.deviceId,
    }, onForked) catch |err| {
        cx.emit(rp_mod.SideChatError{ .message = if (err == error.NotConnected) "Engine not connected" else "Couldn't create the side chat" });
    };
}

var fork_error_buf: [512]u8 = undefined;

fn onForked(rp: *RightPane, result: es.CallResult, cx: *Ctx) void {
    switch (result) {
        .ok => |v| {
            var arena = std.heap.ArenaAllocator.init(cx.gpa());
            defer arena.deinit();
            const chat = std.json.parseFromValueLeaky(protocol.Chat, arena.allocator(), v, .{ .ignore_unknown_fields = true }) catch return;
            const parent = chat.parentChatId orelse return;
            if (rp.state.read(cx).workspace.read(cx).chat(parent) == null) return;
            openSideChat(rp, chat.id, null, cx);
        },
        .err => |e| {
            // The reply is freed after this callback; the event outlives it.
            const n = @min(e.message.len, fork_error_buf.len);
            @memcpy(fork_error_buf[0..n], e.message[0..n]);
            cx.emit(rp_mod.SideChatError{ .message = fork_error_buf[0..n] });
        },
    }
}

// ---- explorer footer + editor helpers -------------------------------------------------------

/// Hand the open chat's explorer its Subagents / Chats rows when they changed.
pub fn syncSections(rp: *RightPane, cx: *Ctx) void {
    const t = rp.current(cx) orelse return;
    const explorer = t.explorer orelse return;
    const chat_id = rp.key(cx) orelse return;
    const st = rp.state.read(cx);
    const ws = st.workspace.read(cx);
    const store_e = st.transcript orelse return;
    const store = store_e.read(cx);
    if (!std.mem.eql(u8, store.chat_id, chat_id)) return;
    const now = model.Timestamp.now(ws.io);
    var h = std.hash.Wyhash.init(0x5ec7);
    h.update(std.mem.asBytes(&store.revision));
    h.update(std.mem.asBytes(&store_e.id));
    const chats = ws.chats();
    h.update(std.mem.asBytes(&chats.len));
    h.update(std.mem.asBytes(&@intFromPtr(chats.ptr)));
    const minute = @divTrunc(now.toUnixMillis(), 60_000);
    h.update(std.mem.asBytes(&minute));
    const key = h.final();
    if (key == t.sections_key) return;
    t.sections_key = key;
    var arena = std.heap.ArenaAllocator.init(cx.gpa());
    defer arena.deinit();
    const a = arena.allocator();
    const subs = surfaces.subagentSectionRows(a, store, now.toUnixMillis()) catch return;
    const kids = surfaces.childChatRows(a, ws, chat_id, now) catch return;
    explorer.update(cx, files.FilesPanel.setSections, .{ subs, kids });
}

/// The active tab's file editor, if a file tab is showing.
pub fn activeFileEditor(rp: *const RightPane, cx: anytype) ?Entity(editor.FileEditor) {
    const t = rp.peek(cx) orelse return null;
    if (!t.open) return null;
    const id = t.resolvedActive() orelse return null;
    const tab = t.tabs.items[t.indexOf(id) orelse return null];
    return if (tab.surface == .file) tab.surface.file else null;
}

/// Open `path` (workspace-relative) and put the caret on `line[:col]`.
pub fn openFileAt(rp: *RightPane, path: []const u8, line: ?usize, col: ?usize, cx: *Ctx) void {
    rp.openFile(path, cx);
    const ed = activeFileEditor(rp, cx) orelse return;
    if (line) |l| ed.update(cx, editor.FileEditor.goToLineWhenLoaded, .{ l, col });
}
