//! `ComposerView`: zeron's message composer — a port of Rust `Composer`
//! (`crates/ui/src/composer.rs` :5622–11000) on zpui.
//!
//! Layout (render at Rust :9856): a column (max 768 / the conversation
//! width, `px 16 pb 16`, gap 8) holding the failure notice, the queue tray
//! (tucked 18px behind the pill), the frosted pill (radius 26, composer
//! border tint, `composer_surface_bg`) and the session footer (checkout +
//! branch). The pill is compact (one 47px row: attach | input | model chip
//! | mic | send) until the draft outgrows the compact capacity or gets a
//! newline, then expanded (textarea `px 16 pt 16 pb 4`, auto-growing
//! 76–260, actions row pinned to the bottom); the new-thread canvas is
//! always expanded. The flip uses Rust's hysteresis and animates the pill
//! height for 180 ms (reduced motion snaps).
//!
//! Sending (`on_submit` / `send`): an exact `SessionCommandPayload::Run`
//! (`run_config.runCommand`) queued through `TranscriptStore.queueCommand`
//! with an optimistic echo and pending-send overlay; during a live run the
//! button morphs to Queue (→ `QueueStore.queueMessage`, hold for turn end)
//! or Stop (→ an `interrupt` command). New threads mint a chat id, `Mutate
//! createChat` with the resolved config, select the chat and send once the
//! selected-chat stores exist.
//!
//! Not ported (yet): attachment upload (paste/drop stage chips; sending
//! them needs the upload pipeline), file mention chips + provider slash
//! commands / skills (engine catalogs), the question wizard, dictation
//! capture (the mic button morphs and emits `dictation_toggled`), the dock
//! choreography between canvas and thread positions.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const actions = @import("zeron_actions");
const input_mod = @import("zeron_input");
const metrics = @import("metrics.zig");
const chrome = @import("chrome.zig");
const rc = @import("run_config.zig");
const slash = @import("slash.zig");
const picker_mod = @import("model_picker.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const protocol = engine.protocol;
const Theme = zt.Theme;
const TextInput = input_mod.TextInput;
const ModelPicker = picker_mod.ModelPicker;
const AppState = model.AppState;
const rems = chrome.rems;
const m = metrics;

pub const ComposerEvent = union(enum) {
    /// A run was queued for `chat_id` (optimistic echo published).
    sent: struct { chat_id: [36]u8, message_id: [36]u8 },
    /// A message was parked on the chat's queue (agent busy).
    queued,
    /// The first send on the new-thread canvas minted `chat_id`.
    new_thread_started: [36]u8,
    /// `/new`, `/settings`, ... — the shell executes it.
    workspace_command: slash.WorkspaceCommand,
    /// The paperclip was pressed (the shell owns the native file picker).
    attach_requested,
    /// The microphone button / shortcut toggled dictation (UI only).
    dictation_toggled: bool,
};

pub const Attachment = struct {
    path: []u8,

    pub fn name(self: Attachment) []const u8 {
        return std.fs.path.basename(self.path);
    }
};

const PendingNew = struct {
    chat_id: [36]u8,
    message_id: [36]u8,
    prompt: []u8,
    cwd: []u8,
};

pub const ComposerView = struct {
    gpa: std.mem.Allocator,
    state: Entity(AppState),
    input: Entity(TextInput),
    picker: Entity(ModelPicker),
    theme: Theme,
    subs: zpui.Subscriptions = .{},
    io: ?std.Io = null,

    // ---- compact ↔ expanded flip (Rust `expanded_mode`, hysteresis) ----
    expanded_mode: bool = false,
    flip_epoch: u64 = 0,
    compact_capacity: f32 = 0,
    expanded_anchor: f32 = 0,
    last_seen_width: f32 = 0,
    width_changed_at: ?u64 = null,
    settle_task: zpui.Task(void) = .none,
    flip_morph: ?m.FlipMorph = null,
    height_morph: ?m.FlipMorph = null,
    last_rendered_height: f32 = 0,
    last_target_height: f32 = 0,
    clock_origin: u64 = 0,

    /// Width the shell gives the composer column (conversation width).
    available_width: ?f32 = null,
    failure: std.ArrayList(u8) = .empty,
    failure_warning: bool = false,
    attachments: std.ArrayList(Attachment) = .empty,
    dictation_available: bool = false,
    dictating: bool = false,
    sending: bool = false,
    slash_active: usize = 0,
    /// A dismissed completion token start (Escape) stays closed until edited.
    slash_dismissed: ?usize = null,
    pending_new: ?PendingNew = null,
    /// Per-chat drafts ("" = the new-thread canvas).
    drafts: std.StringHashMapUnmanaged([]u8) = .empty,
    current_key: std.ArrayList(u8) = .empty,

    pub const Events = .{ComposerEvent};

    /// `ComposerView.init(app_state, cx)` — the contract the shell mounts.
    pub fn init(state: Entity(AppState), cx: *Context(ComposerView)) !ComposerView {
        const theme = chrome.defaultTheme(.dark);
        const input = try cx.newWith(TextInput, TextInput.init, .{input_mod.Options{
            .placeholder = "Do anything…",
            .key_context = actions.keymap.message_composer_context,
            .text_size = m.input_text_size,
            .line_height = m.input_line_height,
            .max_content_height = m.textarea_max - m.textarea_pad_v,
            .colors = input_mod.Colors.fromTheme(&theme),
        }});
        const picker = try cx.newWith(ModelPicker, ModelPicker.init, .{state});
        var self: ComposerView = .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .input = input,
            .picker = picker,
            .theme = theme,
            .clock_origin = cx.app.executor.now(),
            .io = state.read(cx).engine.read(cx).io,
        };
        try self.subs.add(cx.gpa(), try cx.subscribe(input, ComposerView.onInput));
        try self.subs.add(cx.gpa(), try cx.subscribe(picker, ComposerView.onPicked));
        try self.subs.add(cx.gpa(), try cx.subscribe(picker, ComposerView.onPickerClosed));
        try self.subs.add(cx.gpa(), try cx.subscribe(state, ComposerView.onStores));
        const st = state.read(cx);
        try self.subs.add(cx.gpa(), try cx.observe(st.workspace, ComposerView.onObserved(model.WorkspaceStore)));
        try self.subs.add(cx.gpa(), try cx.observe(st.catalog, ComposerView.onObserved(model.CatalogStore)));
        try self.subs.add(cx.gpa(), try cx.observe(st.engine, ComposerView.onObserved(model.EngineState)));
        self.syncKey(cx);
        return self;
    }

    pub fn deinit(self: *ComposerView, cx: *App) void {
        self.subs.deinit(self.gpa);
        self.settle_task.cancel();
        self.input.release(cx);
        self.picker.release(cx);
        self.state.release(cx);
        self.failure.deinit(self.gpa);
        for (self.attachments.items) |a| self.gpa.free(a.path);
        self.attachments.deinit(self.gpa);
        if (self.pending_new) |p| self.freePending(p);
        var it = self.drafts.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.drafts.deinit(self.gpa);
        self.current_key.deinit(self.gpa);
    }

    fn freePending(self: *ComposerView, p: PendingNew) void {
        self.gpa.free(p.prompt);
        self.gpa.free(p.cwd);
    }

    fn onObserved(comptime S: type) fn (*ComposerView, Entity(S), *Context(ComposerView)) void {
        return struct {
            fn f(self: *ComposerView, _: Entity(S), cx: *Context(ComposerView)) void {
                self.syncKey(cx);
                cx.notify();
            }
        }.f;
    }

    // ---- configuration (shell) ----------------------------------------------------------

    pub fn setTheme(self: *ComposerView, theme: Theme, cx: *Context(ComposerView)) void {
        self.theme = theme;
        self.input.update(cx, TextInput.setColors, .{input_mod.Colors.fromTheme(&theme)});
        self.picker.update(cx, ModelPicker.setTheme, .{theme});
        cx.notify();
    }

    /// The conversation column width (the composer follows it, max 768 on
    /// the canvas).
    pub fn setAvailableWidth(self: *ComposerView, width: ?f32, cx: *Context(ComposerView)) void {
        if (std.meta.eql(self.available_width, width)) return;
        self.available_width = width;
        cx.notify();
    }

    pub fn setDefaults(self: *ComposerView, defaults: ?*const rc.ComposerDefaults, cx: *Context(ComposerView)) void {
        self.picker.update(cx, ModelPicker.setDefaults, .{defaults});
    }

    /// Show the microphone (Settings → Voice ready).
    pub fn setDictationAvailable(self: *ComposerView, available: bool, cx: *Context(ComposerView)) void {
        self.dictation_available = available;
        cx.notify();
    }

    pub fn focusInput(self: *ComposerView, window: *Window, cx: *Context(ComposerView)) void {
        window.focus(self.input.read(cx).focus);
    }

    /// Stage dropped / pasted file paths as attachment chips.
    pub fn addPaths(self: *ComposerView, paths: []const []const u8, cx: *Context(ComposerView)) void {
        for (paths) |p| {
            const owned = self.gpa.dupe(u8, p) catch @panic("OOM");
            self.attachments.append(self.gpa, .{ .path = owned }) catch @panic("OOM");
        }
        cx.notify();
    }

    pub fn text(self: *const ComposerView, cx: anytype) []const u8 {
        return self.input.read(cx).text();
    }

    // ---- selection / drafts -------------------------------------------------------------

    fn selectedChat(self: *const ComposerView, cx: anytype) ?[]const u8 {
        const ws = self.state.read(cx).workspace.read(cx);
        return ws.selected_chat;
    }

    /// Swap per-chat drafts when the selected chat changes.
    fn syncKey(self: *ComposerView, cx: *Context(ComposerView)) void {
        const key: []const u8 = self.selectedChat(cx) orelse "";
        if (std.mem.eql(u8, key, self.current_key.items) and self.current_key.items.len + key.len > 0) return;
        if (std.mem.eql(u8, key, self.current_key.items)) return;
        // Save the outgoing draft.
        const old = self.input.read(cx).text();
        if (self.drafts.fetchRemove(self.current_key.items)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
        if (old.len > 0) {
            const k = self.gpa.dupe(u8, self.current_key.items) catch @panic("OOM");
            const v = self.gpa.dupe(u8, old) catch @panic("OOM");
            self.drafts.put(self.gpa, k, v) catch @panic("OOM");
        }
        self.current_key.clearRetainingCapacity();
        self.current_key.appendSlice(self.gpa, key) catch @panic("OOM");
        const draft = self.drafts.get(key) orelse "";
        self.input.update(cx, TextInput.setText, .{draft});
        self.picker.update(cx, ModelPicker.resetDraft, .{});
        self.failure.clearRetainingCapacity();
        // Route changes snap the composer.
        self.flip_morph = null;
        self.height_morph = null;
        self.last_rendered_height = 0;
    }

    // ---- state queries ------------------------------------------------------------------

    fn nowTimestamp(self: *const ComposerView) ?model.Timestamp {
        const io = self.io orelse return null;
        return model.Timestamp.now(io);
    }

    /// A live run: the selected chat is working / awaiting input, or a send
    /// is pending (`run_live`).
    pub fn runLive(self: *const ComposerView, cx: anytype) bool {
        const chat = self.selectedChat(cx) orelse return false;
        const now = self.nowTimestamp() orelse return false;
        const st = self.state.read(cx);
        const ind = st.workspace.read(cx).indicatorFor(chat, now);
        if (ind == .working or ind == .awaiting_input) return true;
        if (st.transcript) |t| if (std.mem.eql(u8, t.read(cx).chat_id, chat) and t.read(cx).sendPending(now)) return true;
        return false;
    }

    fn hasContent(self: *const ComposerView, cx: anytype) bool {
        return m.composerHasContent(self.input.read(cx).text(), self.attachments.items.len, 0);
    }

    pub fn buttonMode(self: *const ComposerView, cx: anytype) m.SendButtonMode {
        return m.sendButtonMode(self.runLive(cx), self.dictating or self.hasContent(cx));
    }

    /// New-chat canvas with nothing runnable blocks sends.
    fn sendBlocked(self: *const ComposerView, cx: anytype) bool {
        if (self.selectedChat(cx) != null) return false;
        const catalog = self.state.read(cx).catalog.read(cx);
        if (catalog.harnesses == null) return false;
        const in = self.picker.read(cx).inputs(cx);
        return rc.effectiveHarness(&in) == null;
    }

    // ---- input events -------------------------------------------------------------------

    fn onInput(self: *ComposerView, _: Entity(TextInput), ev: *const input_mod.TextInputEvent, cx: *Context(ComposerView)) void {
        switch (ev.*) {
            .submitted => self.onSubmit(cx),
            .modified_submitted => self.onModifiedSubmit(cx),
            .edited => {
                self.slash_dismissed = null;
                self.slash_active = 0;
                self.updateSlashControls(cx);
                cx.notify();
            },
            .cursor_moved => {
                self.updateSlashControls(cx);
                cx.notify();
            },
            .mention_navigate => |d| {
                var buf: [16]slash.CatalogEntry = undefined;
                const n = self.slashRows(cx, &buf).len;
                if (n > 0) {
                    const cur: isize = @intCast(self.slash_active);
                    self.slash_active = @intCast(@mod(cur + d, @as(isize, @intCast(n))));
                }
                cx.notify();
            },
            .mention_accept => self.acceptSlash(cx),
            .mention_dismiss => {
                if (self.slashToken(cx)) |t| self.slash_dismissed = t.start;
                self.updateSlashControls(cx);
                cx.notify();
            },
            .pasted_paths => {
                const paths = self.input.read(cx).pastedPaths();
                self.addPaths(paths, cx);
            },
            .toggle_dictation => self.toggleDictation(cx),
            else => {},
        }
    }

    fn onPicked(_: *ComposerView, _: Entity(ModelPicker), _: *const picker_mod.Picked, cx: *Context(ComposerView)) void {
        cx.notify();
    }

    fn onPickerClosed(_: *ComposerView, _: Entity(ModelPicker), _: *const picker_mod.Closed, cx: *Context(ComposerView)) void {
        cx.notify();
    }

    fn onStores(self: *ComposerView, _: Entity(AppState), _: *const model.app_state.SelectedChatStoresChanged, cx: *Context(ComposerView)) void {
        self.syncKey(cx);
        // A new thread's first send waits for its transcript store.
        const p = self.pending_new orelse return cx.notify();
        const st = self.state.read(cx);
        const t = st.transcript orelse return cx.notify();
        if (!std.mem.eql(u8, t.read(cx).chat_id, &p.chat_id)) return cx.notify();
        self.pending_new = null;
        defer self.freePending(p);
        const resolved = self.picker.read(cx).resolved(cx);
        self.queueRun(t, &p.chat_id, &p.message_id, p.prompt, p.cwd, resolved, cx);
        cx.notify();
    }

    // ---- slash completions --------------------------------------------------------------

    fn slashToken(self: *const ComposerView, cx: anytype) ?slash.Token {
        const in = self.input.read(cx);
        if (!in.state.selected.isEmpty()) return null;
        return slash.slashToken(in.text(), in.cursorOffset());
    }

    fn slashRows(self: *const ComposerView, cx: anytype, out: []slash.CatalogEntry) []slash.CatalogEntry {
        const t = self.slashToken(cx) orelse return out[0..0];
        if (self.slash_dismissed == t.start) return out[0..0];
        return slash.filter(t.query, self.selectedChat(cx) != null, out);
    }

    fn updateSlashControls(self: *ComposerView, cx: *Context(ComposerView)) void {
        var buf: [16]slash.CatalogEntry = undefined;
        const open = self.slashToken(cx) != null and self.slash_dismissed != (if (self.slashToken(cx)) |t| t.start else null);
        const rows = self.slashRows(cx, &buf);
        if (self.slash_active >= rows.len) self.slash_active = 0;
        self.input.update(cx, TextInput.setMentionControls, .{ open, rows.len > 0 });
    }

    fn acceptSlash(self: *ComposerView, cx: *Context(ComposerView)) void {
        var buf: [16]slash.CatalogEntry = undefined;
        const rows = self.slashRows(cx, &buf);
        if (rows.len == 0) return;
        const row = rows[@min(self.slash_active, rows.len - 1)];
        const t = self.slashToken(cx) orelse return;
        // Actions consume only their trigger; the draft stays.
        self.input.update(cx, TextInput.replaceRange, .{ t.start, t.end, "" });
        self.executeCommand(row.command, cx);
    }

    fn onSlashRow(self: *ComposerView, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(ComposerView)) void {
        self.slash_active = ix;
        self.acceptSlash(cx);
        self.focusInput(window, cx);
    }

    fn executeCommand(self: *ComposerView, command: slash.WorkspaceCommand, cx: *Context(ComposerView)) void {
        self.failure.clearRetainingCapacity();
        switch (command) {
            .stop => self.interrupt(cx),
            else => {},
        }
        cx.emit(ComposerEvent{ .workspace_command = command });
        self.updateSlashControls(cx);
        cx.notify();
    }

    // ---- submit / send ------------------------------------------------------------------

    fn onSubmit(self: *ComposerView, cx: *Context(ComposerView)) void {
        if (self.dictating) {
            self.dictating = false;
            cx.emit(ComposerEvent{ .dictation_toggled = false });
        }
        const txt = self.input.read(cx).text();
        if (slash.commandForText(txt, self.selectedChat(cx) != null)) |cmd| {
            self.input.update(cx, TextInput.setText, .{""});
            return self.executeCommand(cmd, cx);
        }
        const no_content = !self.hasContent(cx);
        switch (self.buttonMode(cx)) {
            // Enter never stops a run (issue #406).
            .stop => {},
            .send => if (!no_content and !self.sendBlocked(cx)) self.send(false, cx),
            .queue => if (!no_content and !self.sendBlocked(cx)) self.send(true, cx),
        }
    }

    fn onModifiedSubmit(self: *ComposerView, cx: *Context(ComposerView)) void {
        switch (m.modifiedSubmitTarget(self.hasContent(cx))) {
            .submit_content => self.onSubmit(cx),
            .activate_latest_queued => self.activateLatestQueued(cx),
        }
    }

    fn setFailure(self: *ComposerView, msg: []const u8, warning: bool, cx: *Context(ComposerView)) void {
        self.failure.clearRetainingCapacity();
        self.failure.appendSlice(self.gpa, msg) catch {};
        self.failure_warning = warning;
        cx.notify();
    }

    fn uuid(self: *const ComposerView) [36]u8 {
        var out: [36]u8 = undefined;
        if (self.io) |io| {
            _ = rc.uuidV4(io, &out);
        } else @memset(&out, '0');
        return out;
    }

    /// Queue a Run doc command with an optimistic echo — or, with the agent
    /// busy, park the message on the chat's queue (`Composer::send`).
    fn send(self: *ComposerView, queue: bool, cx: *Context(ComposerView)) void {
        const st = self.state.read(cx);
        if (!st.engine.read(cx).isReady()) {
            return self.setFailure("Engine not connected", true, cx);
        }
        const typed = self.input.read(cx).text();
        const prompt = self.gpa.dupe(u8, typed) catch @panic("OOM");
        defer self.gpa.free(prompt);
        const selected = self.selectedChat(cx);
        const is_new = selected == null;
        const ws = st.workspace.read(cx);

        if (queue and !is_new) {
            const q = st.queue orelse return self.setFailure("Update the chat's engine to queue messages during a response.", false, cx);
            var paths: [32][]const u8 = undefined;
            const n = @min(self.attachments.items.len, paths.len);
            for (self.attachments.items[0..n], 0..) |a, i| paths[i] = a.path;
            q.update(cx, model.QueueStore.queueMessage, .{ prompt, paths[0..n], true }) catch |err| {
                return self.setFailure(if (err == error.NotConnected) "Engine not connected" else "Send failed", err == error.NotConnected, cx);
            };
            self.clearAfterSend(cx);
            cx.emit(ComposerEvent{ .queued = {} });
            return;
        }

        const resolved = self.picker.read(cx).resolved(cx);
        const message_id = self.uuid();
        if (is_new) {
            const chat_id = self.uuid();
            const space = ws.selectedSpaceRow();
            const cwd = rc.sendCwd(true, if (space) |s| s.path else null, null);
            const config: ?protocol.ChatConfig = if (resolved.harness) |h| .{
                .harness = h,
                .model = resolved.model,
                .reasoning = resolved.reasoning,
                .modelOptions = resolved.model_options,
                .sandbox = .@"workspace-write",
            } else null;
            const op: protocol.Mutate = .{ .createChat = .{
                .chatId = &chat_id,
                .spaceId = if (space) |s| s.id else null,
                .deviceId = if (space == null) (ws.effectiveDeviceId() orelse "local") else null,
                .config = config,
            } };
            st.workspace.update(cx, model.WorkspaceStore.mutate, .{op}) catch |err| {
                std.log.scoped(.composer).warn("createChat failed: {t}", .{err});
            };
            if (self.pending_new) |p| self.freePending(p);
            self.pending_new = .{
                .chat_id = chat_id,
                .message_id = message_id,
                .prompt = self.gpa.dupe(u8, prompt) catch @panic("OOM"),
                .cwd = self.gpa.dupe(u8, cwd) catch @panic("OOM"),
            };
            self.clearAfterSend(cx);
            // The canvas draft must not follow us into the new chat.
            self.current_key.clearRetainingCapacity();
            self.current_key.appendSlice(self.gpa, &chat_id) catch @panic("OOM");
            cx.emit(ComposerEvent{ .new_thread_started = chat_id });
            st.workspace.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, &chat_id)});
            return;
        }

        const chat_id = selected.?;
        const t = st.transcript orelse return self.setFailure("Send failed: chat not loaded", false, cx);
        if (!std.mem.eql(u8, t.read(cx).chat_id, chat_id)) return self.setFailure("Send failed: chat not loaded", false, cx);
        const chat = ws.selectedChatRow();
        const cwd = rc.sendCwd(false, null, if (chat) |c| c.cwd else null);
        var chat_buf: [36]u8 = @splat('0');
        @memcpy(chat_buf[0..@min(36, chat_id.len)], chat_id[0..@min(36, chat_id.len)]);
        self.queueRun(t, chat_id, &message_id, prompt, cwd, resolved, cx);
        self.clearAfterSend(cx);
        cx.emit(ComposerEvent{ .sent = .{ .chat_id = chat_buf, .message_id = message_id } });
    }

    fn queueRun(self: *ComposerView, t: Entity(model.TranscriptStore), chat_id: []const u8, message_id: []const u8, prompt: []const u8, cwd: []const u8, resolved: rc.Resolved, cx: *Context(ComposerView)) void {
        _ = chat_id;
        var paths: [32][]const u8 = undefined;
        const n = @min(self.attachments.items.len, paths.len);
        for (self.attachments.items[0..n], 0..) |a, i| paths[i] = a.path;
        // Optimistic echo: the client-minted id doubles as the persisted id.
        var parts = [_]protocol.MessagePart{.{ .text = .{ .id = "t0", .text = prompt } }};
        const created: i64 = if (self.nowTimestamp()) |ts| @intCast(@divTrunc(ts.toNanos(), std.time.ns_per_ms)) else 0;
        t.update(cx, model.TranscriptStore.pushEcho, .{protocol.SessionMessageEntry{
            .id = message_id,
            .role = .user,
            .parts = &parts,
            .createdAt = created,
            .deviceId = "local",
        }}) catch {};
        t.update(cx, model.TranscriptStore.beginPendingSend, .{message_id}) catch {};
        const cmd = rc.runCommand(resolved, .{ .prompt = prompt, .cwd = cwd, .message_id = message_id, .attachments = paths[0..n] });
        t.update(cx, model.TranscriptStore.queueCommand, .{cmd}) catch |err| {
            t.update(cx, model.TranscriptStore.removeEcho, .{message_id});
            t.update(cx, model.TranscriptStore.endPendingSend, .{message_id});
            self.setFailure(if (err == error.NotConnected) "Engine not connected" else "Send failed", err == error.NotConnected, cx);
        };
    }

    fn clearAfterSend(self: *ComposerView, cx: *Context(ComposerView)) void {
        self.input.update(cx, TextInput.setText, .{""});
        for (self.attachments.items) |a| self.gpa.free(a.path);
        self.attachments.clearRetainingCapacity();
        self.failure.clearRetainingCapacity();
        if (self.drafts.fetchRemove(self.current_key.items)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
        cx.notify();
    }

    fn interrupt(self: *ComposerView, cx: *Context(ComposerView)) void {
        const st = self.state.read(cx);
        const t = st.transcript orelse return;
        t.update(cx, model.TranscriptStore.queueCommand, .{protocol.SessionCommandPayload{ .interrupt = {} }}) catch |err| {
            self.setFailure(if (err == error.NotConnected) "Engine not connected" else "Stop failed", err == error.NotConnected, cx);
        };
    }

    fn activateLatestQueued(self: *ComposerView, cx: *Context(ComposerView)) void {
        const st = self.state.read(cx);
        const q = st.queue orelse return;
        const items = q.read(cx).items();
        if (items.len == 0) return;
        const id = items[items.len - 1].id;
        q.update(cx, model.QueueStore.sendQueuedMessageNow, .{id}) catch {};
    }

    fn toggleDictation(self: *ComposerView, cx: *Context(ComposerView)) void {
        if (!self.dictation_available) return;
        self.dictating = !self.dictating;
        cx.emit(ComposerEvent{ .dictation_toggled = self.dictating });
        cx.notify();
    }

    // ---- button handlers ----------------------------------------------------------------

    fn onSendClick(self: *ComposerView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ComposerView)) void {
        self.onSubmit(cx);
    }

    fn onStopClick(self: *ComposerView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ComposerView)) void {
        self.interrupt(cx);
    }

    fn onAttachClick(self: *ComposerView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ComposerView)) void {
        if (self.dictating) {
            self.dictating = false;
            cx.emit(ComposerEvent{ .dictation_toggled = false });
            return cx.notify();
        }
        cx.emit(ComposerEvent{ .attach_requested = {} });
    }

    fn onMicClick(self: *ComposerView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ComposerView)) void {
        self.toggleDictation(cx);
    }

    fn onFailureClick(self: *ComposerView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ComposerView)) void {
        self.failure.clearRetainingCapacity();
        cx.notify();
    }

    fn onRemoveAttachment(self: *ComposerView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ComposerView)) void {
        if (ix >= self.attachments.items.len) return;
        self.gpa.free(self.attachments.orderedRemove(ix).path);
        cx.notify();
    }

    fn onPillMouseDown(self: *ComposerView, _: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(ComposerView)) void {
        // Padding and action controls are part of the text composer.
        if (self.picker.read(cx).isOpen()) return;
        window.focus(self.input.read(cx).focus);
        window.preventDefault();
    }

    fn onQueueRemove(self: *ComposerView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ComposerView)) void {
        const q = self.state.read(cx).queue orelse return;
        const items = q.read(cx).items();
        if (ix >= items.len) return;
        q.update(cx, model.QueueStore.removeQueuedMessage, .{items[ix].id}) catch {};
    }

    fn onQueueSend(self: *ComposerView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ComposerView)) void {
        const q = self.state.read(cx).queue orelse return;
        const items = q.read(cx).items();
        if (ix >= items.len) return;
        q.update(cx, model.QueueStore.sendQueuedMessageNow, .{items[ix].id}) catch {};
    }

    fn onQueueEdit(self: *ComposerView, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(ComposerView)) void {
        const q = self.state.read(cx).queue orelse return;
        const items = q.read(cx).items();
        if (ix >= items.len) return;
        self.input.update(cx, TextInput.setText, .{items[ix].text});
        self.focusInput(window, cx);
    }

    fn onSettle(self: *ComposerView, cx: *Context(ComposerView)) void {
        self.settle_task.detach();
        self.settle_task = .none;
        cx.notify();
    }

    // ---- render -------------------------------------------------------------------------

    fn nowMs(self: *const ComposerView, cx: anytype) f32 {
        const ns = cx.app.executor.now() -| self.clock_origin;
        return @as(f32, @floatFromInt(ns / std.time.ns_per_us)) / 1000.0;
    }

    fn prelayout(input: *TextInput, window: *Window, cx: *Context(TextInput)) void {
        if (input.needs_measure and input.last_width > 0) _ = input.layoutText(input.last_width, window, cx);
    }

    pub fn render(self: *ComposerView, window: *Window, cx: *Context(ComposerView)) zpui.Div {
        const theme = &self.theme;
        const mode = self.buttonMode(cx);
        // Shape the current draft before sizing the pill.
        self.input.update(cx, prelayout, .{window});
        const in = self.input.read(cx);
        const text_width = in.measuredTextWidth();
        const has_newline = in.hasNewline();
        const content_height = in.measuredContentHeight() / (window.remSize() / 16.0);
        const last_width = in.last_width;
        const epoch = in.layout_epoch;
        const now = cx.app.executor.now();
        const reduced = window.prefersReducedMotion();

        // Compact ↔ expanded flip (at most one per layout pass).
        const measured_since_flip = epoch > self.flip_epoch and last_width > 0;
        if (measured_since_flip) {
            if (self.last_seen_width > 0 and @abs(last_width - self.last_seen_width) > 0.5) self.width_changed_at = now;
            self.last_seen_width = last_width;
            if (self.expanded_mode) {
                if (self.expanded_anchor <= 0) self.expanded_anchor = last_width;
            } else self.compact_capacity = last_width - 8;
        }
        const resizing = if (self.width_changed_at) |t| now -| t < m.resize_settle_ms * std.time.ns_per_ms else false;
        if (resizing and self.settle_task.header == null) {
            self.settle_task = cx.timer((m.resize_settle_ms + 20) * std.time.ns_per_ms, onSettle) catch .none;
        }
        const capacity: f32 = if (!self.expanded_mode)
            (if (last_width > 0) last_width - 8 else std.math.floatMax(f32))
        else if (self.compact_capacity > 0)
            (if (self.expanded_anchor > 0 and last_width > 0) self.compact_capacity + (last_width - self.expanded_anchor) else self.compact_capacity)
        else
            std.math.floatMax(f32);
        const next = m.composerFlip(self.expanded_mode, text_width, capacity, has_newline, resizing);
        const committed_flip = next != self.expanded_mode and measured_since_flip;
        if (committed_flip) {
            self.expanded_mode = next;
            self.flip_epoch = epoch;
            self.expanded_anchor = 0;
            self.last_seen_width = 0;
        }
        const new_chat = self.selectedChat(cx) == null;
        const now_ms = self.nowMs(cx);
        self.flip_morph = m.flipMorphStep(self.flip_morph, committed_flip and !new_chat, self.last_rendered_height, now_ms, reduced, false);
        const expanded = self.expanded_mode or new_chat;

        // Heights.
        const strip_width_hint = (self.available_width orelse m.composer_max_width) - 2.0 * zt.layout.space_lg - 2.0;
        const strip_h = m.attachmentStripHeight(self.attachments.items.len, strip_width_hint);
        const base_height = if (expanded) m.composerTotalHeight(content_height) else m.compact_total_height;
        const target_height = base_height + strip_h;
        self.height_morph = m.flipMorphStep(self.height_morph, @abs(target_height - self.last_target_height) > 0.5, self.last_rendered_height, now_ms, reduced, false);
        self.last_target_height = target_height;
        const pill_height = if (self.height_morph) |hm| hm.height(target_height, now_ms) else target_height;
        if (self.height_morph != null) window.requestAnimationFrame();
        var morph_t: f32 = 1;
        var morphing = false;
        if (self.flip_morph) |fm| {
            if (!fm.done(now_ms)) {
                morph_t = fm.progress(now_ms);
                morphing = true;
                window.requestAnimationFrame();
            } else self.flip_morph = null;
        }
        self.last_rendered_height = pill_height;
        const text_pt = m.morphTextPad(morph_t);
        const textarea_height = @max(pill_height - strip_h - m.pill_border_v - m.actions_row_height, 0);
        {
            const rem_scale = window.remSize() / 16.0;
            const height: f32 = if (expanded) @max(textarea_height - text_pt - 4, 0) else m.input_line_height;
            const settled: f32 = if (expanded) @max(base_height - m.pill_border_v - m.actions_row_height - m.textarea_pad_v, 0) else m.input_line_height;
            self.input.update(cx, TextInput.setViewport, .{ height * rem_scale, settled * rem_scale, self.height_morph != null, if (expanded) text_pt else 0 });
        }

        // Controls.
        const send_button = self.renderSendButton(mode, cx);
        const attach = self.renderAttach(cx);
        const mic = if (self.dictation_available) self.renderMic(cx) else null;
        const cluster_dy = m.morphClusterDy(morph_t);
        const action_inset = m.morphClusterInset(expanded, morph_t);
        const surface_width = if (self.available_width) |w| @max(w - 2.0 * zt.layout.space_lg, 0) else strip_width_hint + m.pill_border_v;
        const model_action_gap: f32 = if (mic != null) m.action_primary_gap - 6 else m.action_primary_gap;
        const model_picker = div().minW0().maxW(px(surface_width * 0.45)).relative().child(self.picker);
        const strip = self.renderAttachmentStrip(cx);

        var pill = div()
            .onMouseDown(.left, cx.listener(ComposerView.onPillMouseDown))
            .rounded(px(m.composer_radius)).border1().borderColor(theme.composerSurfaceBorder())
            .bg(theme.composerSurfaceBg());
        if (!theme.isFrost()) pill = pill.shadowLg();

        const body = if (expanded)
            pill.h(px(pill_height)).overflowHidden().relative().flex().flexCol()
                .child(strip)
                .child(div().h(px(textarea_height)).flexNone().overflowHidden().px(px(16)).pt(px(text_pt)).pb(px(4)).child(self.input))
                .child(div().absolute().left0().right0().bottom(px(-cluster_dy)).h(px(m.actions_row_height))
                    .flex().flexRow().itemsCenter().gap(px(model_action_gap)).px(px(action_inset)).pt(px(2)).pb(px(m.actions_bottom_pad))
                    .child(div().flex1().minW0().flex().flexRow().itemsCenter().gap(px(m.action_utility_gap)).child(attach))
                    .child(model_picker)
                    .child(primaryGroup(mic, send_button)))
        else blk: {
            const glide: f32 = if (self.flip_morph) |fm| (if (morphing) m.collapseTextGlide(fm.from, morph_t) else 0) else 0;
            break :blk pill.h(px(pill_height)).overflowHidden().flex().flexCol().justifyEnd()
                .child(strip)
                .child(div().h(px(m.compact_total_height - m.pill_border_v)).relative().flex().flexRow().itemsCenter()
                    .child(div().flexNone().pl(px(action_inset)).relative().top(px(-cluster_dy)).flex().itemsCenter().gap(px(m.action_utility_gap)).child(attach))
                    .child(div().flex1().minW0().px(px(8)).relative().top(px(-glide)).child(self.input))
                    .child(div().minW0().maxW(px(surface_width * 0.45)).relative().top(px(-cluster_dy)).child(model_picker))
                    .child(div().flexNone().pl(px(model_action_gap)).pr(px(action_inset)).relative().top(px(-cluster_dy))
                        .flex().itemsCenter().gap(px(m.action_primary_gap)).child(primaryGroup(mic, send_button))));
        };

        const pill_surface = div().relative().id("composer-surface")
            .child(chrome.frosted(theme, m.composer_radius, zt.layout.menu_blur, body))
            .child(self.renderSlashPopup(window, cx));

        var container = div().wFull().maxW(px(self.available_width orelse m.composer_max_width)).mxAuto()
            .flex().flexCol().gap(px(zt.layout.space_sm)).px(px(zt.layout.space_lg)).pb(px(zt.layout.space_lg))
            .fontFamily(theme.font_sans);
        if (self.failure.items.len > 0) container = container.child(self.renderFailure(cx));
        if (self.renderQueue(cx)) |q| {
            container = container.child(div().mx(px(m.queue_side_inset)).mb(px(-(zt.layout.space_sm + m.queue_composer_overlap))).child(q));
        }
        if (new_chat) container = container.child(self.renderTargetSelectors(cx));
        container = container.child(pill_surface);
        container = container.child(self.renderFooter(new_chat, cx));
        return container;
    }

    /// Microphone (when available) + Send: an absent mic must not leave an
    /// empty flex item behind (it would add a gap).
    fn primaryGroup(mic: ?zpui.StatefulDiv, send_button: zpui.StatefulDiv) zpui.Div {
        var g = div().flexNone().flex().itemsCenter().gap(px(m.action_primary_gap));
        if (mic) |b| g = g.child(b);
        return g.child(send_button);
    }

    fn circle(id: anytype) zpui.StatefulDiv {
        return div().id(id).size(px(m.action_button_size)).flexNone().flex().itemsCenter().justifyCenter().roundedFull();
    }

    fn renderSendButton(self: *ComposerView, mode: m.SendButtonMode, cx: *Context(ComposerView)) zpui.StatefulDiv {
        const theme = &self.theme;
        switch (mode) {
            .stop => return circle("composer-stop").bg(theme.text).cursorPointer()
                .hover(sb.opacity(0.85))
                .onClick(cx.listener(ComposerView.onStopClick))
                .tooltipWith(chrome.TipData{ .text = "Stop", .dark = theme.appearance.isDark() }, chrome.buildTooltip)
                .child(div().size(px(11)).rounded(px(3)).bg(theme.bg)),
            .send, .queue => {
                const blocked = self.sendBlocked(cx);
                var b = circle("composer-send").bg(theme.text)
                    .tooltipWith(chrome.TipData{ .text = if (mode == .queue) "Queue message" else "Send message", .dark = theme.appearance.isDark() }, chrome.buildTooltip)
                    .child(chrome.icon(.arrow_up, 14, theme.bg));
                b = if (blocked) b.opacity(0.35) else b.cursorPointer().hover(sb.opacity(0.85)).onClick(cx.listener(ComposerView.onSendClick));
                return b;
            },
        }
    }

    fn renderAttach(self: *ComposerView, cx: *Context(ComposerView)) zpui.StatefulDiv {
        const theme = &self.theme;
        return circle("composer-attach").relative().cursorPointer()
            .hover(sb.bg(chrome.actionWash(theme)))
            .onClick(cx.listener(ComposerView.onAttachClick))
            .tooltipWith(chrome.TipData{ .text = if (self.dictating) "Cancel dictation" else "Attach images", .dark = theme.appearance.isDark() }, chrome.buildTooltip)
            .child(if (self.dictating) chrome.icon(.close, 16, theme.text_muted) else chrome.icon(.paperclip, 18, theme.text_muted));
    }

    fn renderMic(self: *ComposerView, cx: *Context(ComposerView)) zpui.StatefulDiv {
        const theme = &self.theme;
        var b = circle("composer-dictation").relative().cursorPointer()
            .onClick(cx.listener(ComposerView.onMicClick))
            .tooltipWith(chrome.TipData{ .text = if (self.dictating) "Stop dictation" else "Hold to dictate", .dark = theme.appearance.isDark() }, chrome.buildTooltip);
        if (self.dictating) {
            // Live: the accent plate with the stop square.
            b = b.bg(theme.accent_strong).hover(sb.opacity(0.85))
                .child(div().size(px(9)).rounded(px(2.5)).bg(theme.on_accent));
        } else {
            b = b.hover(sb.bg(chrome.actionWash(theme))).child(chrome.icon(.microphone, 18, theme.text_muted));
        }
        return b;
    }

    fn renderAttachmentStrip(self: *ComposerView, cx: *Context(ComposerView)) ?zpui.Div {
        if (self.attachments.items.len == 0) return null;
        const theme = &self.theme;
        var strip = div().flexNone().flex().flexRow().flexWrap().gap(px(m.strip_gap)).px(px(m.strip_pad_x)).pt(px(m.strip_pad_top));
        for (self.attachments.items, 0..) |a, ix| {
            strip = strip.child(div().id(.{ "attachment", ix }).group("attachment").relative()
                .size(px(m.strip_thumb)).flexNone().rounded(px(10)).border1().borderColor(theme.border).bg(theme.ink(0.05))
                .flex().flexCol().itemsCenter().justifyCenter().gap(px(4)).px(px(4))
                .child(chrome.icon(.file_image, 18, theme.text_muted))
                .child(div().wFull().textSize(px(9)).textColor(theme.text_muted).truncate().textCenter().child(a.name()))
                .child(div().id(.{ "attachment-remove", ix }).absolute().top(px(3)).right(px(3)).size(px(16)).roundedFull()
                    .flex().itemsCenter().justifyCenter().bg(theme.bg.opacity(0.8)).opacity(0).cursorPointer()
                    .groupHover("attachment", sb.opacity(1))
                    .onClick(cx.listenerWith(ix, ComposerView.onRemoveAttachment))
                    .child(chrome.icon(.close, 10, theme.text))));
        }
        return strip;
    }

    fn renderFailure(self: *ComposerView, cx: *Context(ComposerView)) zpui.StatefulDiv {
        const theme = &self.theme;
        const accent = if (self.failure_warning) theme.warning else theme.danger;
        const muted = if (self.failure_warning) theme.warning_muted else theme.danger_muted;
        return div().id("composer-failure").mx(px(4)).mt(px(6)).cursorPointer()
            .onClick(cx.listener(ComposerView.onFailureClick))
            .flex().flexCol().gap(px(6)).rounded(px(12)).border1().borderColor(accent.opacity(0.16)).bg(accent.opacity(0.05))
            .px(px(12)).py(px(8)).textSize(rems(12)).lineHeight(px(16)).textColor(muted.opacity(0.9))
            .child(div().flex().itemsCenter().gap(px(8))
                .child(chrome.icon(.danger_triangle, 14, muted.opacity(0.9)))
                .child(div().fontWeight(500).child(if (self.failure_warning) "Warning" else "Error")))
            .child(div().minW0().wFull().child(self.failure.items));
    }

    fn renderSlashPopup(self: *ComposerView, window: *Window, cx: *Context(ComposerView)) ?zpui.Div {
        const t = self.slashToken(cx) orelse return null;
        if (self.slash_dismissed == t.start) return null;
        if (!self.input.read(cx).focus.isFocused(window)) return null;
        const theme = self.theme.forPopup();
        var buf: [16]slash.CatalogEntry = undefined;
        const rows = slash.filter(t.query, self.selectedChat(cx) != null, &buf);
        var card = chrome.card(&theme).wFull().maxH(px(320)).flex().flexCol();
        if (rows.len == 0) {
            card = card.child(div().px(px(12)).py(px(10)).textSize(rems(12)).textColor(theme.text_muted).child("No matching commands"));
        }
        for (rows, 0..) |r, ix| {
            card = card.child(chrome.menuRow(&theme, .{ "slash-result", ix }, ix == self.slash_active)
                .onClick(cx.listenerWith(ix, ComposerView.onSlashRow))
                .child(div().wFull().minW0().flex().itemsCenter().gap(px(8))
                    .child(chrome.icon(.command, 16, theme.text_muted))
                    .child(div().flexNone().maxW(zpui.relative(0.55)).truncate().textSize(rems(13)).fontWeight(500).textColor(theme.text).child(zpui.fmt("/{s}", .{r.name})))
                    .child(div().flex1().minW0().truncate().textSize(rems(12)).textColor(theme.text_muted).child(r.description))));
        }
        return div().absolute().bottomFull().left0().right0().child(
            zpui.deferred(div().occlude().pb(px(6)).child(chrome.frosted(&self.theme, chrome.card_radius, chrome.menu_blur, card))).withPriority(1),
        );
    }

    fn renderQueue(self: *ComposerView, cx: *Context(ComposerView)) ?chrome.Frosted {
        const st = self.state.read(cx);
        if (self.selectedChat(cx) == null) return null;
        const q = st.queue orelse return null;
        const items = q.read(cx).items();
        if (items.len == 0) return null;
        const theme = &self.theme;
        var panel = div().occlude().roundedT(px(16))
            .bg(if (theme.isFrost() and theme.appearance.isDark()) theme.composerSidebarTint() else theme.inputGlassBg())
            .border1().borderColor(theme.border)
            .px(px(4)).pt(px(4)).pb(px(m.queue_composer_overlap)).flex().flexCol();
        if (!theme.isFrost()) panel = panel.shadowLg();
        for (items, 0..) |item, ix| {
            const label: []const u8 = if (item.deliveryGate) |g| switch (g) {
                .editing => "Editing on another device",
                .reviewRequired => "Needs review",
            } else item.text;
            var row = div().id(.{ "queue-row", ix }).h(px(36)).flexNone().px(px(4)).flex().flexRow().itemsCenter().gap(px(8))
                .rounded(px(8)).hover(sb.bg(theme.ink(0.04)))
                .child(div().w(px(14)).h(px(22)).flexNone().flex().itemsCenter().justifyCenter().rounded(px(4))
                    .child(chrome.icon(.queue_drag_handle, 13, theme.text_muted.opacity(0.5))));
            if (item.attachments.len > 0) row = row.child(chrome.icon(.queue_paperclip, 13, theme.text_muted));
            row = row.child(div().flex1().minW0().truncate().textSize(px(12.5)).lineHeight(px(16)).textColor(theme.text.opacity(0.9)).child(label))
                .child(div().flexNone().flex().flexRow().itemsCenter().gap(px(3))
                    .child(queueAction(theme, .{ "queue-drop", ix }, .trash_bin_minimalistic, "Remove").onClick(cx.listenerWith(ix, ComposerView.onQueueRemove)))
                    .child(queueAction(theme, .{ "queue-edit", ix }, .pen, "Edit").onClick(cx.listenerWith(ix, ComposerView.onQueueEdit)))
                    .child(div().id(.{ "queue-primary", ix }).w(px(72)).h(px(28)).flexNone().flex().itemsCenter().justifyCenter().rounded(px(5))
                        .textSize(px(11.5)).textColor(theme.text_muted).cursorPointer()
                        .hover(sb.bg(theme.ink(0.07)).textColor(theme.text))
                        .tooltipWith(chrome.TipData{ .text = "Send now (interrupt)", .dark = theme.appearance.isDark() }, chrome.buildTooltip)
                        .onClick(cx.listenerWith(ix, ComposerView.onQueueSend))
                        .child("Send now")));
            panel = panel.child(row);
        }
        return chrome.frosted(theme, 16, zt.layout.menu_blur, panel);
    }

    fn queueAction(theme: *const Theme, id: anytype, i: chrome.Icon, label: []const u8) zpui.StatefulDiv {
        return div().id(id).size(px(28)).flexNone().flex().itemsCenter().justifyCenter().rounded(px(5)).opacity(0.72).cursorPointer()
            .hover(sb.opacity(1).bg(theme.ink(0.07)))
            .tooltipWith(chrome.TipData{ .text = label, .dark = theme.appearance.isDark() }, chrome.buildTooltip)
            .child(chrome.icon(i, 13, theme.text_muted.opacity(0.8)));
    }

    fn footerLabel(theme: *const Theme, i: chrome.Icon, label: []const u8) zpui.Div {
        return div().h(px(20)).minW0().flex().flexRow().itemsCenter().gap(px(6)).px(px(8))
            .textSize(rems(12)).fontWeight(500).textColor(theme.text_muted.opacity(0.6))
            .child(chrome.icon(i, 12, theme.text_muted.opacity(0.6)))
            .child(div().minW0().truncate().child(label));
    }

    /// A footer-row trigger (`footer_chip`): icon, label, chevron.
    fn footerChip(theme: *const Theme, i: chrome.Icon, label: []const u8) zpui.Div {
        return div().h(px(20)).maxW(px(280)).flex().flexRow().itemsCenter().gap(px(6)).px(px(8)).rounded(px(6))
            .textSize(rems(12)).fontWeight(500).textColor(theme.text_muted.opacity(0.7)).cursorPointer()
            .hover(sb.bg(theme.element_hover).textColor(theme.text.opacity(0.8)))
            .child(chrome.icon(i, 12, theme.text_muted.opacity(0.7)))
            .child(div().minW0().truncate().child(label))
            .child(chrome.icon(.alt_arrow_down, 12, theme.text_muted.opacity(0.5)));
    }

    /// Session footer (`pickers::render_footer` + the usage rings): checkout
    /// and branch on the left, the context-usage ring on the right. The
    /// 24px slot's bottom margin cancels the column gap.
    fn renderFooter(self: *ComposerView, new_chat: bool, cx: *Context(ComposerView)) zpui.Div {
        const theme = &self.theme;
        const st = self.state.read(cx);
        const ws = st.workspace.read(cx);
        const chat = ws.selectedChatRow();
        const branch: ?[]const u8 = if (chat) |c| c.branch else null;
        var row = div().wFull().h(px(m.session_footer_height)).mb(px(-zt.layout.space_sm))
            .flex().flexRow().itemsCenter();
        var left = div().flex1().minW0().px(px(10)).flex().flexRow().itemsCenter().gap(px(4));
        if (chat) |c| {
            // Sessions: read-only checkout kind + ref, only for git projects.
            if (ws.spaceForChat(c)) |space| if (space.gitDetected) {
                const is_worktree = if (c.cwd) |cwd| !std.mem.eql(u8, cwd, space.path) else false;
                left = left.child(if (is_worktree) footerLabel(theme, .folder_with_files, "Worktree") else footerLabel(theme, .folder, "Local checkout"))
                    .child(div().minW0().maxW(px(280)).child(footerLabel(theme, .git_branch, branch orelse "No ref")));
            };
        } else if (new_chat) {
            // New-session draft: the checkout plan chip (the ref chip needs
            // the space's ref list, which the model doesn't load yet).
            if (ws.selectedSpaceRow()) |space| if (space.gitDetected) {
                left = left.child(footerChip(theme, .folder, "Current checkout"));
            };
        }
        row = row.child(left);
        const usage: ?protocol.ContextUsage = if (st.transcript) |t| t.read(cx).context_usage else null;
        if (usage) |u| if (u.window != null and u.window.? > 0) {
            const fraction = u.fraction();
            const color = if (fraction) |f| (if (f >= 0.9) theme.danger else if (f >= 0.75) theme.warning else theme.text_muted) else theme.text_faint;
            const label = if (fraction) |f| zpui.fmt("{d:.0}%", .{f * 100}) else "—";
            row = row.child(div().flexNone().pl(px(4)).pr(px(10)).child(
                div().id("context-usage").flexNone().flex().itemsCenter().gap(px(5)).h(px(24)).px(px(6)).rounded(px(6))
                    .textSize(px(11)).textColor(color).cursorPointer().hover(sb.bg(theme.ink(0.05)))
                    .child(chrome.ring(@floatCast(fraction orelse 0), color, theme.text_faint.opacity(0.25)))
                    .child(label),
            ));
        };
        return row;
    }

    /// New-thread destination chips (project / device) floating above the
    /// pill's trailing edge.
    fn renderTargetSelectors(self: *ComposerView, cx: *Context(ComposerView)) zpui.Div {
        const theme = &self.theme;
        const ws = self.state.read(cx).workspace.read(cx);
        var row = div().wFull().h(px(m.new_thread_selector_row_height)).px(px(10)).flex().itemsStart().justifyEnd().gap(px(4));
        const chip = struct {
            fn f(t: *const Theme, i: chrome.Icon, label: []const u8) zpui.Div {
                return div().h(px(20)).maxW(px(280)).flex().flexRow().itemsCenter().gap(px(6)).px(px(8)).rounded(px(6))
                    .textSize(rems(12)).fontWeight(500).textColor(t.text_muted.opacity(0.7))
                    .child(chrome.icon(i, 12, t.text_muted.opacity(0.7)))
                    .child(div().minW0().truncate().child(label))
                    .child(chrome.icon(.alt_arrow_down, 12, t.text_muted.opacity(0.5)));
            }
        }.f;
        if (ws.effectiveDeviceId()) |d| row = row.child(chip(theme, .monitor, ws.deviceName(d) orelse d));
        if (ws.selectedSpaceRow()) |s| row = row.child(chip(theme, .folder, s.name orelse std.fs.path.basename(s.path)));
        return row;
    }
};
