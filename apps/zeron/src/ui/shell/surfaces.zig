//! Right-pane surfaces for agent sub-conversations (zeron `shell.rs`
//! `RightSurface::Subagent` / `RightSurface::SideChat`,
//! `add_subagent_surface`, `spawn_subagent_snapshot_fetch`,
//! `shell/side_chats.rs`, and the explorer footer rows of
//! `files/sections.rs`).
//!
//! - `SubagentSurface`: a spawn chip's subagent doc as a transcript tab. A
//!   running subagent watches its doc (`WatchDocMessages` works for any doc
//!   id) and follows the tail; a frozen one (done / failed) reads its
//!   uploaded blob first (`FetchToolBlob {source}/{doc}` → `{text}` JSON
//!   entries) and falls back to the watch on any failure.
//! - `SideChatSurface`: a side chat (a fork, or an agent-spawned child) —
//!   its transcript plus a reply field that queues `Run` commands on it with
//!   the chat's own config. Not ported: the side chat's full composer
//!   (model picker, attachments, queue tray), the unsaved "New side chat"
//!   draft that mints its row on first send.
//!
//! `forkSideChat` (`ForkSideChat {chatId, sourceChatId, parentChatId,
//! targetDeviceId}`) replies with the new `Chat`; the right pane opens it.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const tr = @import("zeron_ui_transcript");
const composer_mod = @import("zeron_composer");
const input_mod = @import("zeron_input");
const ui = @import("../components/root.zig");
const files = @import("../files/root.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const protocol = engine.protocol;
const TextInput = input_mod.TextInput;
const TranscriptStore = model.TranscriptStore;
const TranscriptView = tr.TranscriptView;
const rc = composer_mod.run_config;
const es = model.engine_state;

const log = std.log.scoped(.zeron_surfaces);

pub const OpenSubagent = tr.subagents.OpenSubagent;

/// A spawn chip's subagent transcript (`SubagentTab`).
pub const SubagentSurface = struct {
    gpa: std.mem.Allocator,
    state: Entity(model.AppState),
    chat_id: []u8,
    doc_id: []u8,
    title: []u8,
    frozen: bool,
    store: Entity(TranscriptStore),
    view: Entity(TranscriptView),
    sub: ?zpui.Subscription = null,
    /// The frozen blob fetch is in flight.
    fetching: bool = false,

    /// Nested spawn chips inside the subagent's own transcript.
    pub const Events = .{OpenSubagent};

    pub fn init(state: Entity(model.AppState), ev: OpenSubagent, cx: *Context(SubagentSurface)) !SubagentSurface {
        const gpa = cx.gpa();
        const engine_e = state.read(cx).engine;
        const store = try cx.newWith(TranscriptStore, TranscriptStore.init, .{ engine_e, ev.doc_id });
        errdefer store.release(cx);
        const view = try cx.newWith(TranscriptView, TranscriptView.initWithStore, .{store});
        errdefer view.release(cx);
        {
            var l = view.lease(cx);
            defer l.end();
            // A frozen subagent reads top-down; a live one follows its end.
            l.value.start_at_top = ev.frozen;
            l.value.rail_enabled = false;
            l.value.top_inset = zt.layout.space_lg;
        }
        var self: SubagentSurface = .{
            .gpa = gpa,
            .state = state.retain(cx),
            .chat_id = try gpa.dupe(u8, ev.chat_id),
            .doc_id = try gpa.dupe(u8, ev.doc_id),
            .title = try gpa.dupe(u8, ev.title),
            .frozen = ev.frozen,
            .store = store,
            .view = view,
        };
        self.sub = cx.subscribe(view, onNested) catch null;
        if (ev.frozen) self.fetchSnapshot(cx);
        return self;
    }

    pub fn deinit(self: *SubagentSurface, app: *App) void {
        if (self.sub) |*s| s.deinit();
        self.view.release(app);
        self.store.release(app);
        self.state.release(app);
        self.gpa.free(self.chat_id);
        self.gpa.free(self.doc_id);
        self.gpa.free(self.title);
    }

    pub fn tabTitle(self: *const SubagentSurface) []const u8 {
        return self.title;
    }

    fn fetchSnapshot(self: *SubagentSurface, cx: *Context(SubagentSurface)) void {
        // The blob wins over a possibly-purged live doc: no watch meanwhile.
        self.store.update(cx, TranscriptStore.setActive, .{false});
        var buf: [512]u8 = undefined;
        const blob = tr.subagents.blobRef(&buf, self.chat_id, self.doc_id);
        const engine_e = self.state.read(cx).engine;
        es.EngineState.request(engine_e, cx, SubagentSurface, cx.entityId(), .FetchToolBlob, .{ .blobRef = blob }, onBlob) catch {
            self.store.update(cx, TranscriptStore.setActive, .{true});
            return;
        };
        self.fetching = true;
    }

    fn onBlob(self: *SubagentSurface, result: es.CallResult, cx: *Context(SubagentSurface)) void {
        self.fetching = false;
        const loaded = blk: {
            const v = switch (result) {
                .ok => |v| v,
                .err => |e| {
                    log.debug("subagent blob {s}: {s}", .{ self.doc_id, e.message });
                    break :blk false;
                },
            };
            break :blk loadSnapshot(self.store, v, cx.app);
        };
        if (!loaded) self.store.update(cx, TranscriptStore.setActive, .{true});
        cx.notify();
    }

    fn onNested(_: *SubagentSurface, _: Entity(TranscriptView), ev: *const OpenSubagent, cx: *Context(SubagentSurface)) void {
        cx.emit(ev.*);
    }

    pub fn render(self: *SubagentSurface, _: *Window, _: *Context(SubagentSurface)) zpui.Div {
        return div().sizeFull().relative().child(self.view);
    }
};

/// Decode a `FetchToolBlob` reply (`{text}` = JSON `[SessionMessageEntry]`)
/// into `store` as a reset frame. False when the reply can't be used.
pub fn loadSnapshot(store: Entity(TranscriptStore), value: std.json.Value, app: *App) bool {
    if (value != .object) return false;
    const text = value.object.get("text") orelse return false;
    if (text != .string) return false;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const entries = std.json.parseFromSliceLeaky([]protocol.SessionMessageEntry, arena.allocator(), text.string, .{ .ignore_unknown_fields = true }) catch return false;
    tr.loadEntries(store, entries, app) catch return false;
    return true;
}

/// A side chat in the right pane (`SideChatTab`).
pub const SideChatSurface = struct {
    gpa: std.mem.Allocator,
    state: Entity(model.AppState),
    chat_id: []u8,
    store: Entity(TranscriptStore),
    view: Entity(TranscriptView),
    input: Entity(TextInput),
    subs: zpui.Subscriptions = .{},
    failure: ?[]u8 = null,
    /// "New side chat": the chat is only minted here; its first send writes
    /// the row (`createChat` with the parent's context) — an abandoned one
    /// leaves nothing behind.
    unsaved_parent: ?[]u8 = null,

    pub const Events = .{OpenSubagent};

    pub fn init(state: Entity(model.AppState), chat_id: []const u8, unsaved_parent: ?[]const u8, cx: *Context(SideChatSurface)) !SideChatSurface {
        const gpa = cx.gpa();
        const store = try cx.newWith(TranscriptStore, TranscriptStore.init, .{ state.read(cx).engine, chat_id });
        errdefer store.release(cx);
        const view = try cx.newWith(TranscriptView, TranscriptView.initWithStore, .{store});
        errdefer view.release(cx);
        {
            var l = view.lease(cx);
            defer l.end();
            l.value.rail_enabled = false;
            l.value.top_inset = zt.layout.space_lg;
            l.value.bottom_clearance = 56;
        }
        const theme = ui.theme.get(cx);
        const input = try cx.newWith(TextInput, TextInput.init, .{input_mod.Options{
            .placeholder = "Reply in this side chat…",
            .key_context = "MessageComposer",
            .text_size = 13,
            .line_height = 18,
            .max_content_height = 120,
            .colors = input_mod.Colors.fromTheme(theme),
        }});
        var self: SideChatSurface = .{
            .gpa = gpa,
            .state = state.retain(cx),
            .chat_id = try gpa.dupe(u8, chat_id),
            .store = store,
            .view = view,
            .input = input,
            .unsaved_parent = if (unsaved_parent) |p| try gpa.dupe(u8, p) else null,
        };
        try self.subs.add(gpa, try cx.subscribe(input, onInput));
        try self.subs.add(gpa, try cx.subscribe(view, onNested));
        try self.subs.add(gpa, try cx.observe(state.read(cx).workspace, onWorkspace));
        return self;
    }

    pub fn deinit(self: *SideChatSurface, app: *App) void {
        self.subs.deinit(self.gpa);
        self.input.release(app);
        self.view.release(app);
        self.store.release(app);
        self.state.release(app);
        self.gpa.free(self.chat_id);
        if (self.failure) |f| self.gpa.free(f);
        if (self.unsaved_parent) |p| self.gpa.free(p);
    }

    fn onWorkspace(_: *SideChatSurface, _: Entity(model.WorkspaceStore), cx: *Context(SideChatSurface)) void {
        cx.notify();
    }

    fn onNested(_: *SideChatSurface, _: Entity(TranscriptView), ev: *const OpenSubagent, cx: *Context(SideChatSurface)) void {
        cx.emit(ev.*);
    }

    /// `child_chat_title`: the title, else the preview, else a placeholder.
    pub fn tabTitle(self: *const SideChatSurface, cx: anytype) []const u8 {
        const c = self.state.read(cx).workspace.read(cx).chat(self.chat_id) orelse return "New side chat";
        return c.title orelse c.lastMessagePreview orelse "New side chat";
    }

    fn setFailure(self: *SideChatSurface, msg: ?[]const u8, cx: *Context(SideChatSurface)) void {
        if (self.failure) |f| self.gpa.free(f);
        self.failure = if (msg) |m| self.gpa.dupe(u8, m) catch null else null;
        cx.notify();
    }

    fn onInput(self: *SideChatSurface, _: Entity(TextInput), ev: *const input_mod.TextInputEvent, cx: *Context(SideChatSurface)) void {
        switch (ev.*) {
            .submitted, .modified_submitted => self.send(cx),
            else => {},
        }
    }

    fn onSendClick(self: *SideChatSurface, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SideChatSurface)) void {
        self.send(cx);
    }

    /// Queue a `Run` on the side chat with its own config and an optimistic echo.
    pub fn send(self: *SideChatSurface, cx: *Context(SideChatSurface)) void {
        const prompt_raw = self.input.read(cx).text();
        if (std.mem.trim(u8, prompt_raw, " \t\r\n").len == 0) return;
        const st = self.state.read(cx);
        const ws = st.workspace.read(cx);
        // An unsaved side chat sends with (and is created from) its parent's context.
        const chat = ws.chat(self.chat_id) orelse if (self.unsaved_parent) |p| ws.chat(p) else null;
        if (self.unsaved_parent) |parent_id| {
            const parent = ws.chat(parent_id) orelse return self.setFailure("The parent conversation is gone", cx);
            st.workspace.update(cx, model.WorkspaceStore.mutate, .{protocol.Mutate{ .createChat = .{
                .chatId = self.chat_id,
                .spaceId = parent.spaceId,
                .deviceId = if (parent.spaceId == null) parent.deviceId else null,
                .config = parent.config,
                .branch = parent.branch,
                .cwd = parent.cwd,
                .parentChatId = parent_id,
            } }}) catch |err| return self.setFailure(if (err == error.NotConnected) "Engine not connected" else "Couldn't create the side chat", cx);
            self.gpa.free(parent_id);
            self.unsaved_parent = null;
        }
        const prompt = self.gpa.dupe(u8, prompt_raw) catch return;
        defer self.gpa.free(prompt);
        var mid: [36]u8 = undefined;
        _ = rc.uuidV4(ws.io, &mid);
        const cfg: ?protocol.ChatConfig = if (chat) |c| c.config else null;
        const resolved: rc.Resolved = .{
            .harness = if (cfg) |c| c.harness else null,
            .model = if (cfg) |c| c.model else null,
            .reasoning = if (cfg) |c| c.reasoning else null,
            .model_options = if (cfg) |c| c.modelOptions else .{},
        };
        const cwd = rc.sendCwd(false, null, if (chat) |c| c.cwd else null);
        var parts = [_]protocol.MessagePart{.{ .text = .{ .id = "t0", .text = prompt } }};
        const created: i64 = model.Timestamp.now(ws.io).toUnixMillis();
        self.store.update(cx, TranscriptStore.pushEcho, .{protocol.SessionMessageEntry{
            .id = &mid,
            .role = .user,
            .parts = &parts,
            .createdAt = created,
            .deviceId = "local",
        }}) catch {};
        self.store.update(cx, TranscriptStore.beginPendingSend, .{@as([]const u8, &mid)}) catch {};
        const cmd = rc.runCommand(resolved, .{ .prompt = prompt, .cwd = cwd, .message_id = &mid });
        self.store.update(cx, TranscriptStore.queueCommand, .{cmd}) catch |err| {
            self.store.update(cx, TranscriptStore.removeEcho, .{@as([]const u8, &mid)});
            self.store.update(cx, TranscriptStore.endPendingSend, .{@as([]const u8, &mid)});
            return self.setFailure(if (err == error.NotConnected) "Engine not connected" else "Send failed", cx);
        };
        self.input.update(cx, TextInput.setText, .{""});
        self.setFailure(null, cx);
    }

    pub fn render(self: *SideChatSurface, _: *Window, cx: *Context(SideChatSurface)) zpui.Div {
        const theme = ui.theme.get(cx);
        var bar = div().flexNone().px(px(12)).pb(px(12)).pt(px(4)).flex().flexCol().gap(px(6));
        if (self.failure) |f| bar = bar.child(div().textSize(ui.rems(12)).textColor(theme.danger).child(f));
        bar = bar.child(div().id("side-chat-reply").minH(px(40)).px(px(12)).py(px(8)).rounded(px(16)).border1().borderColor(theme.border)
            .bg(theme.ink(0.03)).flex().flexRow().itemsEnd().gap(px(8))
            .child(div().flex1().minW0().child(self.input))
            .child(div().id("side-chat-send").size(px(24)).flexNone().roundedFull().bg(theme.text).flex().itemsCenter().justifyCenter()
            .cursorPointer().hover(sb.opacity(0.85))
            .onClick(cx.listener(onSendClick))
            .child(ui.icon.of(.arrow_up, 12, theme.bg))));
        return div().sizeFull().flex().flexCol()
            .child(div().flex1().minH0().relative().child(self.view))
            .child(bar);
    }
};

/// `FetchToolBlob`-free parameters for `ForkSideChat`.
pub const ForkParams = struct {
    chatId: []const u8,
    sourceChatId: []const u8,
    parentChatId: []const u8,
    targetDeviceId: []const u8,
};

// ---- explorer footer rows (`files/sections.rs`) ------------------------------------------

pub fn rowStatusOfSubagent(s: ?protocol.SubagentStatus) files.panel.RowStatus {
    const st = s orelse return .idle;
    return switch (st) {
        .running => .working,
        .done => .completed,
        .failed => .failed,
    };
}

pub fn rowStatusOfChat(i: model.view.ChatIndicator) files.panel.RowStatus {
    return switch (i) {
        .working => .working,
        .awaitingInput => .attention,
        .errored => .failed,
        .completed => .completed,
        .idle => .idle,
    };
}

/// `child_chat_rows`: the live (unarchived) children of `parent_id`, most
/// recent activity first. Strings borrow the workspace / `arena`.
pub fn childChatRows(arena: std.mem.Allocator, ws: *const model.WorkspaceStore, parent_id: []const u8, now: model.Timestamp) ![]files.panel.SectionRow {
    const Item = struct { row: files.panel.SectionRow, activity: []const u8 };
    var items: std.ArrayList(Item) = .empty;
    for (ws.chats()) |*c| {
        if (c.archived) continue;
        const parent = c.parentChatId orelse continue;
        if (!std.mem.eql(u8, parent, parent_id)) continue;
        const activity = c.lastMessageAt orelse c.createdAt;
        const then = model.time.parseOpt(activity) orelse now;
        var buf: [16]u8 = undefined;
        try items.append(arena, .{ .row = .{
            .id = c.id,
            .title = c.title orelse c.lastMessagePreview orelse "New side chat",
            .time_ago = try arena.dupe(u8, model.view.formatTimeAgo(&buf, then, now)),
            .status = rowStatusOfChat(ws.displayStatusFor(c, now)),
        }, .activity = activity });
    }
    // RFC 3339 UTC timestamps order lexicographically.
    std.sort.insertion(Item, items.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return std.mem.order(u8, a.activity, b.activity) == .gt;
        }
    }.lt);
    const out = try arena.alloc(files.panel.SectionRow, items.items.len);
    for (items.items, out) |it, *o| o.* = it.row;
    return out;
}

/// The explorer's Subagents rows for `entries` (the open chat's transcript).
pub fn subagentSectionRows(arena: std.mem.Allocator, store: *const TranscriptStore, now_ms: i64) ![]files.panel.SectionRow {
    const rows = try tr.subagents.subagentRows(arena, store);
    const out = try arena.alloc(files.panel.SectionRow, rows.len);
    for (rows, out) |r, *o| {
        var buf: [16]u8 = undefined;
        const ago = model.view.formatTimeAgo(&buf, model.Timestamp.fromUnixMillis(r.spawned_at), model.Timestamp.fromUnixMillis(now_ms));
        o.* = .{ .id = r.doc_id, .title = r.title, .time_ago = try arena.dupe(u8, ago), .status = rowStatusOfSubagent(r.status) };
    }
    return out;
}
