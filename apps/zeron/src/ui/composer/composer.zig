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
//! Attachments (Rust `attachments.rs` + composer staging): the paperclip
//! opens the native picker, pastes of image data / copied files and drops on
//! the conversation stage images per draft (BMP → PNG, 24 MB cap) as 56px
//! thumbnails (click: lightbox, ×: remove). A send uploads them first —
//! `UploadChunk`/`UploadCommit` to the local engine with `pending://` refs and
//! transfer escorts when every engine involved is ≥ 0.2.12 (queued flow),
//! else to the chat's host device with the committed paths — and the refs
//! ride the prompt (`with_attachments`) and the Run request's `attachments`.
//! Stop during the upload cancels it and hands the draft back.
//!
//! The question wizard, todo tray, queue drag / leased edit, `@` file
//! mentions and provider slash commands / skills live in `extras.zig`.
//! Not ported (yet): mention chip projection in the input, dictation
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
const mentions = @import("mentions.zig"); // [wiring]
const extras = @import("extras.zig"); // [wiring] wizard, todo tray, queue drag/lease, @ mentions, provider commands
const media = @import("zeron_media");
const att = model.attachments;

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

/// An in-flight send whose attachments are uploading (Rust `send_task`).
const Upload = struct {
    is_new: bool,
    queue: bool,
    queued_flow: bool,
    chat_id: [36]u8,
    chat_id_len: usize,
    message_id: [36]u8,
    /// The draft key the send came from (restored on failure).
    key: []u8,
    /// The user's own words (restored on failure).
    typed: []u8,
    staged: std.ArrayList(att.Staged),
    upload_ids: [][36]u8,
    echo_paths: [][]u8,
    /// Device the transcript reads attachments from (chat / target device).
    device_id: []u8,
    host_device_id: ?[]u8,
    local_device_id: ?[]u8,
    progress: *att.Progress,

    fn chatId(u: *const Upload) []const u8 {
        return u.chat_id[0..u.chat_id_len];
    }
};

const StageBatch = struct { key: []u8, outcomes: []att.StageOutcome };

/// A stage job tagged with the draft it belongs to.
const StageForKey = struct {
    inner: att.StageJob,
    key: []u8,

    pub fn run(self: *StageForKey) StageBatch {
        const k = self.key;
        self.key = &.{};
        return .{ .key = k, .outcomes = self.inner.run() };
    }
    pub fn discard(self: *StageForKey, r: StageBatch) void {
        self.inner.gpa.free(r.key);
        att.freeOutcomes(self.inner.gpa, r.outcomes);
    }
    pub fn deinit(self: *StageForKey) void {
        self.inner.gpa.free(self.key);
        self.inner.deinit();
    }
};

const PendingNew = struct {
    chat_id: [36]u8,
    message_id: [36]u8,
    prompt: []u8,
    cwd: []u8,
    /// A "New worktree" plan: the host materializes it when the run drains.
    worktree: ?struct { repo_path: []u8, base: []u8, space_id: ?[]u8 } = null,
    /// Attachment refs for the Run request, and transfer escorts (owned).
    attachments: [][]u8 = &.{},
    transfers: []protocol.AttachmentTransfer = &.{},
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
    /// Staged images per draft key ("" = the new-thread canvas).
    staged_by_key: std.StringHashMapUnmanaged(std.ArrayList(att.Staged)) = .empty,
    /// The full-size preview (lightbox) of a staged image.
    lightbox: ?Entity(media.Lightbox) = null,
    lightbox_sub: ?zpui.Subscription = null,
    /// A send waiting on its attachment upload.
    upload: ?Upload = null,
    upload_task: zpui.Task(att.UploadResult) = .none,
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

    // ---- host hooks (the shell's `ui/pickers`) ----
    /// Replaces the built-in device/project chips above the canvas pill.
    target_row: ?zpui.AnyView = null,
    /// Replaces the canvas footer's checkout chip (checkout + ref pickers).
    git_row: ?zpui.AnyView = null,
    /// The new session's checkout plan (strings owned by the host).
    checkout_plan: ?model.view.CheckoutPlan = null,
    /// [wiring] Run-time surfaces + completions state (extras.zig).
    ext: extras.Extras = .{},

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
            .paste_images = true,
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
        extras.onStoresChanged(&self, cx); // [wiring] the selected chat's transcript (question wizard)
        return self;
    }

    pub fn deinit(self: *ComposerView, cx: *App) void {
        self.ext.deinit(self.gpa, cx); // [wiring]
        self.subs.deinit(self.gpa);
        self.settle_task.cancel();
        self.input.release(cx);
        self.picker.release(cx);
        self.state.release(cx);
        self.failure.deinit(self.gpa);
        var sit = self.staged_by_key.iterator();
        while (sit.next()) |e| {
            for (e.value_ptr.items) |*st| st.deinit(self.gpa, cx);
            e.value_ptr.deinit(self.gpa);
            self.gpa.free(e.key_ptr.*);
        }
        self.staged_by_key.deinit(self.gpa);
        self.closeLightbox(cx);
        self.upload_task.cancel();
        if (self.upload) |*u| self.freeUpload(u, cx);
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
        for (p.attachments) |a| self.gpa.free(a);
        self.gpa.free(p.attachments);
        for (p.transfers) |t| {
            self.gpa.free(t.uploadId);
            self.gpa.free(t.fileName);
        }
        self.gpa.free(p.transfers);
        if (p.worktree) |w| {
            self.gpa.free(w.repo_path);
            self.gpa.free(w.base);
            if (w.space_id) |id| self.gpa.free(id);
        }
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

    /// Stage image files (picker / drop / pasted paths) into the current
    /// draft (`add_paths`). Non-images are skipped silently; read failures and
    /// oversize files surface in the failure notice.
    pub fn addPaths(self: *ComposerView, paths: []const []const u8, cx: *Context(ComposerView)) void {
        const owned = self.gpa.alloc([]u8, paths.len) catch return;
        for (paths, 0..) |p, i| owned[i] = self.gpa.dupe(u8, p) catch @panic("OOM");
        self.stageInBackground(.{ .paths = owned }, cx);
    }

    /// Stage a pasted clipboard image (takes ownership of `img.bytes`).
    pub fn addClipboardImage(self: *ComposerView, img: zpui.platform.ClipboardImage, cx: *Context(ComposerView)) void {
        self.stageInBackground(.{ .clipboard = .{ .format = att.Format.fromClipboard(img.format), .bytes = img.bytes } }, cx);
    }

    /// `stage_in_background`: read / convert / decode on a worker, then add
    /// what it staged to the draft that was current when it started.
    fn stageInBackground(self: *ComposerView, input: att.StageInput, cx: *Context(ComposerView)) void {
        const io = self.io orelse {
            var job: att.StageJob = .{ .gpa = self.gpa, .io = undefined, .input = input };
            job.deinit();
            return;
        };
        const job: StageForKey = .{
            .inner = .{ .gpa = self.gpa, .io = io, .input = input },
            .key = self.gpa.dupe(u8, self.current_key.items) catch @panic("OOM"),
        };
        var task = cx.spawn(job, ComposerView.onStaged) catch return;
        task.detach();
    }

    fn onStaged(self: *ComposerView, batch: StageBatch, cx: *Context(ComposerView)) void {
        defer self.gpa.free(batch.key);
        defer att.freeOutcomes(self.gpa, batch.outcomes);
        const io = self.io orelse return;
        for (batch.outcomes) |*o| switch (o.*) {
            .err => |msg| self.setFailure(msg, false, cx),
            .ok => {
                const st = att.stagedFromOutcome(self.gpa, io, o) catch continue;
                const list = self.stagedList(batch.key);
                list.append(self.gpa, st) catch {
                    var x = st;
                    x.deinit(self.gpa, cx.app);
                };
            },
        };
        cx.notify();
    }

    fn stagedList(self: *ComposerView, key: []const u8) *std.ArrayList(att.Staged) {
        const gop = self.staged_by_key.getOrPut(self.gpa, key) catch @panic("OOM");
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, key) catch @panic("OOM");
            gop.value_ptr.* = .empty;
        }
        return gop.value_ptr;
    }

    /// Staged images of the draft the composer is showing.
    pub fn staged(self: *const ComposerView) []const att.Staged {
        const list = self.staged_by_key.getPtr(self.current_key.items) orelse return &.{};
        return list.items;
    }

    /// Move the staged list of `key` out (`takeAttachments`).
    fn takeStaged(self: *ComposerView, key: []const u8) std.ArrayList(att.Staged) {
        const kv = self.staged_by_key.fetchRemove(key) orelse return .empty;
        self.gpa.free(kv.key);
        return kv.value;
    }

    fn removeStaged(self: *ComposerView, ix: usize, cx: *Context(ComposerView)) void {
        const list = self.staged_by_key.getPtr(self.current_key.items) orelse return;
        if (ix >= list.items.len) return;
        var st = list.orderedRemove(ix);
        st.deinit(self.gpa, cx.app);
        if (list.items.len == 0) {
            var l = self.takeStaged(self.current_key.items);
            l.deinit(self.gpa);
        }
        cx.notify();
    }

    // ---- lightbox ----

    fn openLightbox(self: *ComposerView, ix: usize, window: *Window, cx: *Context(ComposerView)) void {
        const list = self.staged();
        if (ix >= list.len) return;
        const img = list[ix].image orelse return;
        self.closeLightbox(cx.app);
        const lb = cx.newWith(media.Lightbox, media.Lightbox.init, .{ media.LightboxOptions{
            .image = img,
            .name = list[ix].name,
            .release = att.releaseImage,
            .appearance = self.theme.appearance,
        }, window }) catch return;
        self.lightbox = lb;
        self.lightbox_sub = cx.subscribe(lb, ComposerView.onLightboxClosed) catch null;
        cx.notify();
    }

    fn closeLightbox(self: *ComposerView, app: *App) void {
        if (self.lightbox_sub) |*sub| sub.deinit();
        self.lightbox_sub = null;
        if (self.lightbox) |lb| lb.release(app);
        self.lightbox = null;
    }

    fn onLightboxClosed(self: *ComposerView, _: Entity(media.Lightbox), _: *const media.LightboxClosed, cx: *Context(ComposerView)) void {
        self.closeLightbox(cx.app);
        cx.notify();
    }

    // ---- file picker ----

    const PickerCtx = struct { app: *App, id: zpui.EntityId };

    /// Paperclip: the native image picker (`prompt_for_paths`, multiple files).
    fn openFilePicker(self: *ComposerView, cx: *Context(ComposerView)) void {
        const ctx = self.gpa.create(PickerCtx) catch return;
        ctx.* = .{ .app = cx.app, .id = cx.entityId() };
        cx.app.platform.promptForPaths(.{ .files = true, .directories = false, .multiple = true, .prompt = "Attach", .title = "Attach images" }, .{ .ctx = ctx, .func = onPickedPaths });
    }

    fn onPickedPaths(raw: ?*anyopaque, paths: ?[]const []const u8) void {
        const ctx: *PickerCtx = @ptrCast(@alignCast(raw.?));
        const app = ctx.app;
        const id = ctx.id;
        app.gpa.destroy(ctx);
        const weak: zpui.WeakEntity(ComposerView) = .{ .id = id };
        const Apply = struct {
            fn f(self: *ComposerView, ps: ?[]const []const u8, cx: *Context(ComposerView)) void {
                if (ps) |list| self.addPaths(list, cx);
                cx.notify();
            }
        };
        _ = weak.update(app, Apply.f, .{paths});
    }

    pub fn text(self: *const ComposerView, cx: anytype) []const u8 {
        return self.input.read(cx).text();
    }

    // ---- [wiring] shell hooks ------------------------------------------------------------

    /// `add_workspace_path` (explorer "Add to chat"): insert a canonical file
    /// reference at the selection and focus the draft.
    pub fn addWorkspacePath(self: *ComposerView, path: []const u8, is_dir: bool, window: ?*Window, cx: *Context(ComposerView)) void {
        const in = self.input.read(cx);
        const sel = in.state.selected;
        const ins = (mentions.droppedFileMention(self.gpa, in.text(), sel.start, sel.end, path, is_dir) catch return) orelse return;
        defer self.gpa.free(ins.text);
        const start = sel.start;
        self.input.update(cx, TextInput.replaceRange, .{ sel.start, sel.end, ins.text });
        if (ins.cursor_advance > ins.text.len) {
            const Move = struct {
                fn f(t: *TextInput, at: usize, c: *Context(TextInput)) void {
                    t.state.selected = .collapsed(@min(at, t.text().len));
                    c.notify();
                }
            };
            self.input.update(cx, Move.f, .{start + ins.cursor_advance});
        }
        if (window) |w| self.focusInput(w, cx);
        cx.notify();
    }

    /// Forget a deleted chat's draft (`purge_chat`).
    pub fn purgeChat(self: *ComposerView, chat_id: []const u8, cx: *Context(ComposerView)) void {
        if (self.drafts.fetchRemove(chat_id)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
        cx.notify();
    }

    /// `shell::OpenModelPicker` / `/model`: open (or close) the model menu.
    pub fn toggleModelPicker(self: *ComposerView, window: *Window, cx: *Context(ComposerView)) void {
        self.picker.update(cx, ModelPicker.toggle, .{window});
    }

    /// Show `message` in the failure notice (`show_error`).
    pub fn showError(self: *ComposerView, message: []const u8, cx: *Context(ComposerView)) void {
        self.setFailure(message, false, cx);
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
        extras.beforeKeySwap(self, cx); // [wiring] the wizard / queue edit borrow the editor
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
        return m.composerHasContent(self.input.read(cx).text(), self.staged().len, 0);
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
                extras.onEdited(self, cx); // [wiring] @ mentions + provider catalogs
                cx.notify();
            },
            .cursor_moved => {
                extras.onEdited(self, cx);
                cx.notify();
            },
            .mention_navigate => |d| extras.navigate(self, d, cx),
            .mention_accept => extras.accept(self, cx),
            .mention_dismiss => extras.dismiss(self, cx),
            .escape => extras.onEscape(self, cx),
            .pasted_paths => {
                const paths = self.input.read(cx).pastedPaths();
                self.addPaths(paths, cx);
            },
            .pasted_image => {
                var l = self.input.lease(cx);
                const img = l.value.takePastedImage();
                l.end();
                if (img) |i| self.addClipboardImage(i, cx);
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
        extras.onStoresChanged(self, cx); // [wiring] question wizard follows the transcript
        // A new thread's first send waits for its transcript store.
        const p = self.pending_new orelse return cx.notify();
        const st = self.state.read(cx);
        const t = st.transcript orelse return cx.notify();
        if (!std.mem.eql(u8, t.read(cx).chat_id, &p.chat_id)) return cx.notify();
        self.pending_new = null;
        defer self.freePending(p);
        const resolved = self.picker.read(cx).resolved(cx);
        const spec: ?protocol.WorktreeSpec = if (p.worktree) |w| .{ .repoPath = w.repo_path, .base = w.base, .spaceId = w.space_id } else null;
        const paths: []const []const u8 = @ptrCast(p.attachments);
        self.queueRunIn(t, &p.message_id, p.prompt, p.cwd, spec, resolved, paths, p.transfers, true, cx);
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
        if (true) return extras.updateControls(self, cx); // [wiring]
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

    /// [wiring] Zeron's own slash commands (`execute_workspace_command`).
    pub fn executeWorkspaceCommand(self: *ComposerView, command: slash.WorkspaceCommand, cx: *Context(ComposerView)) void {
        self.executeCommand(command, cx);
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
        if (extras.onSubmit(self, cx)) return; // [wiring] wizard advance / queue edit commit
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
        // One upload at a time; the button shows Stop meanwhile.
        if (self.upload != null) return;
        if (self.staged().len > 0) return self.sendWithAttachments(queue, cx);
        const typed = self.input.read(cx).text();
        const prompt = self.gpa.dupe(u8, typed) catch @panic("OOM");
        defer self.gpa.free(prompt);
        const selected = self.selectedChat(cx);
        const is_new = selected == null;
        const ws = st.workspace.read(cx);

        if (queue and !is_new) {
            const q = st.queue orelse return self.setFailure("Update the chat's engine to queue messages during a response.", false, cx);
            const no_paths: []const []const u8 = &.{};
            q.update(cx, model.QueueStore.queueMessage, .{ prompt, no_paths, true }) catch |err| {
                return self.setFailure(if (err == error.NotConnected) "Engine not connected" else "Send failed", err == error.NotConnected, cx);
            };
            self.clearAfterSend(cx);
            cx.emit(ComposerEvent{ .queued = {} });
            return;
        }

        const resolved = self.picker.read(cx).resolved(cx);
        const message_id = self.uuid();
        if (is_new) {
            self.startNewChat(self.uuid(), message_id, prompt, &.{}, &.{}, resolved, cx);
            return;
        }
        _ = ws;

        const chat_id = selected.?;
        const t = st.transcript orelse return self.setFailure("Send failed: chat not loaded", false, cx);
        if (!std.mem.eql(u8, t.read(cx).chat_id, chat_id)) return self.setFailure("Send failed: chat not loaded", false, cx);
        const chat = st.workspace.read(cx).selectedChatRow();
        const cwd = rc.sendCwd(false, null, if (chat) |c| c.cwd else null);
        var chat_buf: [36]u8 = @splat('0');
        @memcpy(chat_buf[0..@min(36, chat_id.len)], chat_id[0..@min(36, chat_id.len)]);
        self.queueRunIn(t, &message_id, prompt, cwd, null, resolved, &.{}, &.{}, true, cx);
        self.clearAfterSend(cx);
        cx.emit(ComposerEvent{ .sent = .{ .chat_id = chat_buf, .message_id = message_id } });
    }

    /// The new-thread canvas's first send: `Mutate createChat` with the
    /// resolved config, then the Run once the chat's stores exist.
    fn startNewChat(self: *ComposerView, chat_id: [36]u8, message_id: [36]u8, prompt: []const u8, attachment_paths: []const []const u8, transfers: []const protocol.AttachmentTransfer, resolved: rc.Resolved, cx: *Context(ComposerView)) void {
        const st = self.state.read(cx);
        const ws = st.workspace.read(cx);
        {
            const space = ws.selectedSpaceRow();
            var cwd = rc.sendCwd(true, if (space) |s| s.path else null, null);
            // The picked checkout: reuse an existing worktree (cwd override)
            // and name the ref on createChat so the footer shows it at once.
            var chat_branch: ?[]const u8 = null;
            var chat_cwd: ?[]const u8 = null;
            if (space != null) if (self.checkout_plan) |plan| switch (plan) {
                .current_checkout => |c| chat_branch = c.branch,
                .reuse_worktree => |r| {
                    cwd = r.path;
                    chat_cwd = r.path;
                    chat_branch = r.branch;
                },
                .new_worktree => |n| chat_branch = n.base,
            };
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
                .branch = chat_branch,
                .cwd = chat_cwd,
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
                .attachments = dupePaths(self.gpa, attachment_paths),
                .transfers = dupeTransfers(self.gpa, transfers),
            };
            // A fresh worktree off the picked base (HEAD when the ref list
            // never arrived: the isolation the user picked must not be dropped).
            if (space) |sp| if (self.checkout_plan) |plan| if (plan == .new_worktree) {
                self.pending_new.?.worktree = .{
                    .repo_path = self.gpa.dupe(u8, sp.path) catch @panic("OOM"),
                    .base = self.gpa.dupe(u8, plan.new_worktree.base orelse "HEAD") catch @panic("OOM"),
                    .space_id = self.gpa.dupe(u8, sp.id) catch @panic("OOM"),
                };
            };
            self.clearAfterSend(cx);
            // The canvas draft must not follow us into the new chat.
            self.current_key.clearRetainingCapacity();
            self.current_key.appendSlice(self.gpa, &chat_id) catch @panic("OOM");
            cx.emit(ComposerEvent{ .new_thread_started = chat_id });
            st.workspace.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, &chat_id)});
            return;
        }
    }

    // ---- sends with attachments (Rust `send`, the staging half) ----

    fn sendWithAttachments(self: *ComposerView, queue_in: bool, cx: *Context(ComposerView)) void {
        const io = self.io orelse return;
        const st = self.state.read(cx);
        const engine_state = st.engine.read(cx);
        const conn = engine_state.conn orelse return self.setFailure("Engine not connected", true, cx);
        const ws = st.workspace.read(cx);
        const selected = self.selectedChat(cx);
        const is_new = selected == null;
        const queue = queue_in and !is_new;
        if (queue and (st.queue == null or !engine_state.supports(protocol.capabilities.message_queue_attachments_v1))) {
            return self.setFailure("Update the chat's engine to queue messages during a response.", false, cx);
        }
        if (!is_new) {
            const t = st.transcript orelse return self.setFailure("Send failed: chat not loaded", false, cx);
            if (!std.mem.eql(u8, t.read(cx).chat_id, selected.?)) return self.setFailure("Send failed: chat not loaded", false, cx);
        }
        const local = ws.local_device_id;
        const target = ws.effectiveDeviceId();
        const chat_row = ws.selectedChatRow();
        // Where the transcript reads the attachments back, and the upload host.
        const device_id: []const u8 = if (is_new) (target orelse "local") else (if (chat_row) |c| c.deviceId else (local orelse "local"));
        const host: ?[]const u8 = if (is_new)
            (if (target) |t| (if (local != null and std.mem.eql(u8, local.?, t)) null else t) else null)
        else if (chat_row) |c| c.deviceId else null;
        const host_is_remote = if (host) |h| !(local != null and std.mem.eql(u8, local.?, h)) else false;
        // Queued-attachment flow: commit to the LOCAL engine and let it deliver
        // the bytes; needs every engine involved to understand `pending://`.
        const queued_flow = !queue and local != null and ws.deviceVersionAtLeast(local.?, att.queued_attachments_min) and
            (!host_is_remote or ws.deviceVersionAtLeast(host.?, att.queued_attachments_min));

        const staged_list = self.takeStaged(self.current_key.items);
        const n = staged_list.items.len;
        const gpa = self.gpa;
        var u: Upload = .{
            .is_new = is_new,
            .queue = queue,
            .queued_flow = queued_flow,
            .chat_id = undefined,
            .chat_id_len = 36,
            .message_id = self.uuid(),
            .key = gpa.dupe(u8, self.current_key.items) catch @panic("OOM"),
            .typed = gpa.dupe(u8, self.input.read(cx).text()) catch @panic("OOM"),
            .staged = staged_list,
            .upload_ids = gpa.alloc([36]u8, n) catch @panic("OOM"),
            .echo_paths = gpa.alloc([]u8, n) catch @panic("OOM"),
            .device_id = gpa.dupe(u8, device_id) catch @panic("OOM"),
            .host_device_id = if (host) |h| (gpa.dupe(u8, h) catch @panic("OOM")) else null,
            .local_device_id = if (local) |l| (gpa.dupe(u8, l) catch @panic("OOM")) else null,
            .progress = undefined,
        };
        if (is_new) u.chat_id = self.uuid() else {
            const id = selected.?;
            u.chat_id_len = @min(id.len, 36);
            @memcpy(u.chat_id[0..u.chat_id_len], id[0..u.chat_id_len]);
        }
        // Upload identities minted NOW: in the queued flow the `pending://` ref
        // IS the persisted transport until the host rewrites it.
        var total: u64 = 0;
        for (staged_list.items, 0..) |*a, i| {
            att.uuidV4(io, &u.upload_ids[i]);
            u.echo_paths[i] = if (queued_flow)
                std.fmt.allocPrint(gpa, "pending://{s}/{s}", .{ &u.upload_ids[i], a.name }) catch @panic("OOM")
            else
                std.fmt.allocPrint(gpa, "pending/{s}/{s}", .{ &a.id, a.name }) catch @panic("OOM");
            total += a.bytes().len;
        }
        // Seed the transcript cache so the echo's thumbnails render from local bytes.
        const cache = att.Cache.of(cx.app);
        for (staged_list.items, 0..) |*a, i| {
            const img = a.image orelse continue;
            const local_other = if (local) |l| (if (!std.mem.eql(u8, l, device_id)) l else null) else null;
            if (queued_flow) {
                cache.seedAlias(cx.app, device_id, &u.upload_ids[i], a.name, img);
                if (local_other) |l| cache.seedAlias(cx.app, l, &u.upload_ids[i], a.name, img);
            }
            cache.seed(cx.app, device_id, u.echo_paths[i], a.name, img);
            if (local_other) |l| cache.seed(cx.app, l, u.echo_paths[i], a.name, img);
        }
        // Optimistic echo with attachment refs from the first frame (a queued
        // message is represented by the queue panel instead).
        if (!is_new and !queue) if (st.transcript) |t| {
            const echo_paths: []const []const u8 = @ptrCast(u.echo_paths);
            const echo_text = att.withAttachments(gpa, u.typed, echo_paths) catch @panic("OOM");
            defer gpa.free(echo_text);
            self.pushEchoFor(t, &u.message_id, echo_text, cx);
            t.update(cx, model.TranscriptStore.beginPendingSend, .{@as([]const u8, &u.message_id)}) catch {};
            var chat_buf: [36]u8 = @splat('0');
            @memcpy(chat_buf[0..u.chat_id_len], u.chatId());
            cx.emit(ComposerEvent{ .sent = .{ .chat_id = chat_buf, .message_id = u.message_id } });
        };
        u.progress = att.Progress.create(gpa, total) catch @panic("OOM");
        cache.beginUploadProgress(u.progress);

        const items = gpa.alloc(att.UploadItem, n) catch @panic("OOM");
        for (staged_list.items, 0..) |*a, i| items[i] = .{
            .upload_id = gpa.dupe(u8, &u.upload_ids[i]) catch @panic("OOM"),
            .name = gpa.dupe(u8, a.name) catch @panic("OOM"),
            .blob = a.blob.retain(),
        };
        const job: att.UploadJob = .{
            .gpa = gpa,
            .client = conn.client(),
            .conn = conn.retain(),
            .items = items,
            .target_device_id = if (queued_flow) null else if (host) |h| (gpa.dupe(u8, h) catch null) else null,
            .progress = u.progress.retain(),
        };
        self.input.update(cx, TextInput.setText, .{""});
        if (self.drafts.fetchRemove(self.current_key.items)) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value);
        }
        self.failure.clearRetainingCapacity();
        self.sending = true;
        self.upload = u;
        self.upload_task = cx.spawn(job, ComposerView.onUploaded) catch {
            var uu = self.upload.?;
            self.upload = null;
            self.restoreFailedSend(&uu, "Couldn't upload the attachment — the device may be offline.", cx);
            self.freeUpload(&uu, cx.app);
            return;
        };
        cx.notify();
    }

    fn onUploaded(self: *ComposerView, result: att.UploadResult, cx: *Context(ComposerView)) void {
        defer att.freeUploadResult(self.gpa, result);
        self.upload_task = .none;
        var u = self.upload orelse return;
        self.upload = null;
        defer self.freeUpload(&u, cx.app);
        self.sending = false;
        att.Cache.of(cx.app).endUploadProgress();
        const paths = switch (result) {
            .canceled => return self.restoreFailedSend(&u, null, cx),
            .err => |e| {
                std.log.scoped(.composer).warn("attachment upload failed: {s}", .{e});
                return self.restoreFailedSend(&u, if (u.queued_flow) "Couldn't stage the attachment locally." else "Couldn't upload the attachment — the device may be offline.", cx);
            },
            .ok => |p| p,
        };
        const gpa = self.gpa;
        const st = self.state.read(cx);
        // The refs the Run carries: the queued flow's `pending://` echo refs
        // (stable), else the host's committed absolute paths.
        const refs: []const []const u8 = if (u.queued_flow) @ptrCast(u.echo_paths) else @ptrCast(paths);
        var transfers: std.ArrayList(protocol.AttachmentTransfer) = .empty;
        defer transfers.deinit(gpa);
        if (u.queued_flow) {
            for (u.staged.items, 0..) |*a, i| transfers.append(gpa, .{ .uploadId = &u.upload_ids[i], .fileName = a.name }) catch {};
        } else {
            // Seed the cache under the committed paths so the sent bubble never round-trips.
            const cache = att.Cache.of(cx.app);
            const seed_device = u.host_device_id orelse u.device_id;
            for (u.staged.items, 0..) |*a, i| {
                const img = a.image orelse continue;
                cache.seed(cx.app, seed_device, paths[i], a.name, img);
                if (!std.mem.eql(u8, seed_device, u.device_id)) cache.seed(cx.app, u.device_id, paths[i], a.name, img);
            }
        }
        const content = att.withAttachments(gpa, u.typed, refs) catch @panic("OOM");
        defer gpa.free(content);
        const resolved = self.picker.read(cx).resolved(cx);

        if (u.queue) {
            const q = st.queue orelse return self.restoreFailedSend(&u, "Update the chat's engine to queue messages during a response.", cx);
            // A queue row stays free of the attachment-path trailer when the
            // engine rebuilds it (`message-queue-clean-attachment-text-v1`).
            const clean = st.engine.read(cx).supports(protocol.capabilities.message_queue_clean_attachment_text_v1);
            const queue_text: []const u8 = if (!clean) content else if (std.mem.trim(u8, u.typed, " \t\r\n").len == 0) att.attachment_only_text else u.typed;
            q.update(cx, model.QueueStore.queueMessage, .{ queue_text, refs, true }) catch {
                return self.restoreFailedSend(&u, "Send failed", cx);
            };
            cx.emit(ComposerEvent{ .queued = {} });
            return cx.notify();
        }
        if (u.is_new) {
            self.startNewChat(u.chat_id, u.message_id, content, refs, transfers.items, resolved, cx);
            return cx.notify();
        }
        const t = st.transcript orelse return self.restoreFailedSend(&u, "Send failed: chat not loaded", cx);
        if (!std.mem.eql(u8, t.read(cx).chat_id, u.chatId())) return self.restoreFailedSend(&u, "Send failed: chat not loaded", cx);
        if (!u.queued_flow) {
            // Refresh the echo in place with the uploaded refs.
            t.update(cx, model.TranscriptStore.removeEcho, .{@as([]const u8, &u.message_id)});
            self.pushEchoFor(t, &u.message_id, content, cx);
        }
        const chat = st.workspace.read(cx).selectedChatRow();
        const cwd = rc.sendCwd(false, null, if (chat) |c| c.cwd else null);
        self.queueRunIn(t, &u.message_id, content, cwd, null, resolved, refs, transfers.items, false, cx);
        cx.notify();
    }

    /// Failure (or cancel): echo removed, prompt and staged files handed back
    /// to their draft, and the message shown (null = silent).
    fn restoreFailedSend(self: *ComposerView, u: *Upload, message: ?[]const u8, cx: *Context(ComposerView)) void {
        self.sending = false;
        att.Cache.of(cx.app).endUploadProgress();
        const st = self.state.read(cx);
        if (!u.is_new and !u.queue) if (st.transcript) |t| if (std.mem.eql(u8, t.read(cx).chat_id, u.chatId())) {
            t.update(cx, model.TranscriptStore.removeEcho, .{@as([]const u8, &u.message_id)});
            t.update(cx, model.TranscriptStore.endPendingSend, .{@as([]const u8, &u.message_id)});
        };
        if (std.mem.eql(u8, self.current_key.items, u.key)) {
            if (self.input.read(cx).text().len == 0) self.input.update(cx, TextInput.setText, .{u.typed});
        } else if (!self.drafts.contains(u.key)) {
            const k = self.gpa.dupe(u8, u.key) catch @panic("OOM");
            const v = self.gpa.dupe(u8, u.typed) catch @panic("OOM");
            self.drafts.put(self.gpa, k, v) catch @panic("OOM");
        }
        // Merge by id: files staged while the send was in flight survive.
        const list = self.stagedList(u.key);
        var merged: std.ArrayList(att.Staged) = .empty;
        merged.appendSlice(self.gpa, u.staged.items) catch @panic("OOM");
        for (list.items) |e| {
            var dup = false;
            for (merged.items) |f| dup = dup or std.mem.eql(u8, &f.id, &e.id);
            if (dup) {
                var x = e;
                x.deinit(self.gpa, cx.app);
            } else merged.append(self.gpa, e) catch @panic("OOM");
        }
        list.deinit(self.gpa);
        list.* = merged;
        u.staged = .empty; // moved
        if (message) |msg| self.setFailure(msg, false, cx);
        cx.notify();
    }

    fn freeUpload(self: *ComposerView, u: *Upload, app: *App) void {
        const gpa = self.gpa;
        gpa.free(u.key);
        gpa.free(u.typed);
        for (u.staged.items) |*a| a.deinit(gpa, app);
        u.staged.deinit(gpa);
        gpa.free(u.upload_ids);
        for (u.echo_paths) |p| gpa.free(p);
        gpa.free(u.echo_paths);
        gpa.free(u.device_id);
        if (u.host_device_id) |h| gpa.free(h);
        if (u.local_device_id) |l| gpa.free(l);
        u.progress.release();
    }

    fn dupePaths(gpa: std.mem.Allocator, paths: []const []const u8) [][]u8 {
        const out = gpa.alloc([]u8, paths.len) catch @panic("OOM");
        for (paths, 0..) |p, i| out[i] = gpa.dupe(u8, p) catch @panic("OOM");
        return out;
    }

    fn dupeTransfers(gpa: std.mem.Allocator, ts: []const protocol.AttachmentTransfer) []protocol.AttachmentTransfer {
        const out = gpa.alloc(protocol.AttachmentTransfer, ts.len) catch @panic("OOM");
        for (ts, 0..) |t, i| out[i] = .{ .uploadId = gpa.dupe(u8, t.uploadId) catch @panic("OOM"), .fileName = gpa.dupe(u8, t.fileName) catch @panic("OOM") };
        return out;
    }

    fn pushEchoFor(self: *ComposerView, t: Entity(model.TranscriptStore), message_id: []const u8, text_: []const u8, cx: *Context(ComposerView)) void {
        var parts = [_]protocol.MessagePart{.{ .text = .{ .id = "t0", .text = text_ } }};
        const created: i64 = if (self.nowTimestamp()) |ts| @intCast(@divTrunc(ts.toNanos(), std.time.ns_per_ms)) else 0;
        t.update(cx, model.TranscriptStore.pushEcho, .{protocol.SessionMessageEntry{
            .id = message_id,
            .role = .user,
            .parts = &parts,
            .createdAt = created,
            .deviceId = "local",
        }}) catch {};
    }

    fn queueRunIn(self: *ComposerView, t: Entity(model.TranscriptStore), message_id: []const u8, prompt: []const u8, cwd: []const u8, worktree: ?protocol.WorktreeSpec, resolved: rc.Resolved, attachment_paths: []const []const u8, transfers: []const protocol.AttachmentTransfer, push_echo: bool, cx: *Context(ComposerView)) void {
        // Optimistic echo: the client-minted id doubles as the persisted id.
        if (push_echo) {
            self.pushEchoFor(t, message_id, prompt, cx);
            t.update(cx, model.TranscriptStore.beginPendingSend, .{message_id}) catch {};
        }
        const cmd = rc.runCommand(resolved, .{ .prompt = prompt, .cwd = cwd, .message_id = message_id, .attachments = attachment_paths, .worktree = worktree });
        const queued = if (transfers.len > 0)
            t.update(cx, model.TranscriptStore.queueCommandWithTransfers, .{ cmd, transfers })
        else
            t.update(cx, model.TranscriptStore.queueCommand, .{cmd});
        queued catch |err| {
            t.update(cx, model.TranscriptStore.removeEcho, .{message_id});
            t.update(cx, model.TranscriptStore.endPendingSend, .{message_id});
            self.setFailure(if (err == error.NotConnected) "Engine not connected" else "Send failed", err == error.NotConnected, cx);
        };
    }

    fn clearAfterSend(self: *ComposerView, cx: *Context(ComposerView)) void {
        self.input.update(cx, TextInput.setText, .{""});
        self.failure.clearRetainingCapacity();
        if (self.drafts.fetchRemove(self.current_key.items)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
        cx.notify();
    }

    fn interrupt(self: *ComposerView, cx: *Context(ComposerView)) void {
        // Stop while the attachments upload cancels the send and hands the
        // draft back (nothing reached the host yet).
        if (self.upload != null) {
            self.upload_task.cancel();
            self.upload_task = .none;
            var u = self.upload.?;
            self.upload = null;
            self.restoreFailedSend(&u, null, cx);
            self.freeUpload(&u, cx.app);
            return;
        }
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
        self.openFilePicker(cx);
    }

    fn onMicClick(self: *ComposerView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ComposerView)) void {
        self.toggleDictation(cx);
    }

    fn onFailureClick(self: *ComposerView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ComposerView)) void {
        self.failure.clearRetainingCapacity();
        cx.notify();
    }

    fn onRemoveAttachment(self: *ComposerView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ComposerView)) void {
        // The button overhangs the thumbnail: don't also open the preview.
        cx.stopPropagation();
        self.removeStaged(ix, cx);
    }

    fn onThumbClick(self: *ComposerView, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(ComposerView)) void {
        self.openLightbox(ix, window, cx);
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
        // [wiring] `begin_queue_edit`: the host's edit lease first.
        extras.beginQueueEdit(self, ix, cx);
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
        const strip_h = m.attachmentStripHeight(self.staged().len, strip_width_hint);
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
            .rounded(px(m.composer_radius)).border1().borderColor(theme.onGlassBorder(theme.composerSurfaceBorder()))
            .bg(theme.onGlass(theme.composerSurfaceBg())); // [liquid-glass] onGlass: no-op unless Liquid Glass
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

        // [wiring] a pending question replaces the pill; completions float above it.
        const pill_surface = extras.renderWizard(self, window, cx) orelse div().relative().id("composer-surface")
            .child(chrome.frosted(theme, m.composer_radius, zt.layout.menu_blur, body))
            .child(extras.renderPopup(self, window, cx));

        var container = div().wFull().maxW(px(self.available_width orelse m.composer_max_width)).mxAuto()
            .flex().flexCol().gap(px(zt.layout.space_sm)).px(px(zt.layout.space_lg)).pb(px(zt.layout.space_lg))
            .fontFamily(theme.font_sans);
        if (self.failure.items.len > 0) container = container.child(self.renderFailure(cx));
        const queue_tray = self.renderQueue(cx);
        if (extras.renderTodo(self, queue_tray != null, cx)) |t| container = container.child(t); // [wiring] todo tray
        if (queue_tray) |q| {
            container = container.child(div().mx(px(m.queue_side_inset)).mb(px(-(zt.layout.space_sm + m.queue_composer_overlap))).child(q));
        }
        if (new_chat) container = container.child(self.renderTargetSelectors(cx));
        container = container.child(pill_surface);
        container = container.child(self.renderFooter(new_chat, cx));
        if (self.lightbox) |lb| container = container.child(lb);
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

    /// The staged-thumbnail strip (attachment-ui.tsx AttachmentStrip):
    /// `flex flex-wrap gap-2 px-4 pt-3`, 56px rounded thumbs, a remove button
    /// revealed on hover, click opens the full-size preview.
    fn renderAttachmentStrip(self: *ComposerView, cx: *Context(ComposerView)) ?zpui.Div {
        const list = self.staged();
        if (list.len == 0) return null;
        const theme = &self.theme;
        var strip = div().wFull().flexNone().flex().flexRow().flexWrap().gap(px(m.strip_gap)).px(px(m.strip_pad_x)).pt(px(m.strip_pad_top));
        for (list, 0..) |a, ix| {
            const group = zpui.fmt("composer-att-{s}", .{&a.id});
            var thumb = div().id(.{ "composer-att-thumb", ix }).size(px(m.strip_thumb)).rounded(px(8)).overflowHidden()
                .border1().borderColor(theme.hairline(0.10)).cursorPointer()
                .onClick(cx.listenerWith(ix, ComposerView.onThumbClick));
            thumb = if (a.image) |r|
                thumb.child(zpui.img(r).w(px(m.strip_thumb - 2)).h(px(m.strip_thumb - 2)).rounded(px(7)).objectFit(.cover))
            else
                thumb.bg(theme.ink(0.05)).flex().itemsCenter().justifyCenter().child(chrome.icon(.file_image, 18, theme.text_muted));
            strip = strip.child(div().group(group).flexNone().relative()
                .child(thumb)
                .child(zpui.layered(div().id(.{ "composer-att-remove", ix }).absolute().top(px(-6)).right(px(-6)).size(px(18)).roundedFull()
                    .bg(theme.bg).flex().itemsCenter().justifyCenter().cursorPointer().shadowSm().opacity(0)
                    .groupHover(group, sb.opacity(1))
                    .onClick(cx.listenerWith(ix, ComposerView.onRemoveAttachment))
                    .tooltipWith(chrome.TipData{ .text = zpui.fmt("Remove {s}", .{a.name}), .dark = theme.appearance.isDark() }, chrome.buildTooltip)
                    .child(chrome.icon(.close_circle, 14, theme.text_muted)))));
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
            .bg(theme.onGlass(if (theme.isFrost() and theme.appearance.isDark()) theme.composerSidebarTint() else theme.inputGlassBg())) // [liquid-glass]
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
            panel = panel.child(extras.queueRow(self, row, ix, item.id, cx)); // [wiring] drag reorder / edit wash
        }
        return chrome.frosted(theme, 16, zt.layout.menu_blur, extras.queuePanel(self, panel, cx));
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
        } else if (new_chat and self.git_row != null) {
            left = left.child(self.git_row.?);
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
        if (self.target_row) |v| return row.child(v);
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
