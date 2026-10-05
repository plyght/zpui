//! [wiring] The composer's run-time surfaces, kept out of `composer.zig`:
//!
//! - the question wizard (zeron `composer.rs` `render_wizard`,
//!   `wizard_select` / `wizard_advance` / `wizard_back` / `wizard_finish`,
//!   the latch in `sync_selected_chat`): a pending `input` part replaces the
//!   pill with the question panel; answers go out as a `respondInput`
//!   command; a 2s safety net re-shows a question the host did not take;
//! - the todo tray (`todo_panel.rs` `render_todo_panel`): the latest `Todo`
//!   list above the queue, collapsible, foldable, dismissable while idle;
//! - the queue tray's drag reorder (`queue.rs` `move_queued`, optimistic +
//!   `MoveQueuedMessage`) and the leased edit (`begin_queue_edit`:
//!   `BeginQueuedMessageEdit` → 20s `RenewQueuedMessageEdit` heartbeat →
//!   `FinishQueuedMessageEdit` commit / discard / cancel);
//! - `@` file mentions (`SearchFiles`, 80ms debounce, canonical
//!   `[name](zeron-file:path)` insertion) and provider slash commands /
//!   skills (`ListCommands` + `ListSkills` merged with Zeron's own commands,
//!   `$` skill completion per the agent's completion preferences).
//!
//! The queue edit restores the row's attachments (`ReadAttachmentChunk`
//! from the chat's host) into the composer and uploads what is staged on
//! commit. Not ported: the Appshot half of that restore, the mention chip
//! projection and hover tooltips, the completion list's scrollbar rail.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const actions = @import("zeron_actions");
const input_mod = @import("zeron_input");
const chrome = @import("chrome.zig");
const m = @import("metrics.zig");
const slash = @import("slash.zig");
const rc = @import("run_config.zig");
const wizard_mod = @import("wizard.zig");
const todo = @import("todo_panel.zig");
const completions = @import("completions.zig");
const mentions = @import("mentions.zig");
const composer = @import("composer.zig");

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
const ComposerView = composer.ComposerView;
const Ctx = Context(ComposerView);
const es = model.engine_state;
const rems = chrome.rems;
const Allocator = std.mem.Allocator;
const att = model.attachments;

const log = std.log.scoped(.zeron_composer);

const queue_row_slot: f32 = 36;
const queue_pad_top: f32 = 4;
const mention_debounce_ms: u64 = 80;
const renew_interval_ms: u64 = 20_000;
const answer_recheck_ms: u64 = 2_000;

pub const QueueDrag = struct { key_hash: u64, from: usize };

/// `ComposerEvent::WorktreeSetup`: a new worktree chat's setup action handed
/// off by the host (`TakeProjectActionSetup`). Strings live until the next
/// handoff.
pub const WorktreeSetup = struct {
    chat_id: []const u8,
    /// Null when the project has no setup action (or it didn't start).
    setup_action: ?SetupRun = null,
    setup_error: ?[]const u8 = null,
    target_device_id: ?[]const u8 = null,
};

/// `ProjectActionRun`.
pub const SetupRun = struct {
    actionId: []const u8 = "",
    actionName: []const u8,
    terminal: protocol.TerminalSession,
};

/// A queued worktree run waiting for its `commandId`, then for the host's
/// setup handoff (polled every 250 ms, at most 480 times).
const SetupPoll = struct {
    chat_id: []u8,
    message_id: []u8,
    target: ?[]u8,
    command_id: ?[]u8 = null,
    attempts: u16 = 0,

    fn deinit(p: SetupPoll, gpa: Allocator) void {
        gpa.free(p.chat_id);
        gpa.free(p.message_id);
        if (p.target) |t| gpa.free(t);
        if (p.command_id) |c| gpa.free(c);
    }
};

const setup_poll_ms: u64 = 250;
const setup_poll_limit: u16 = 480;
const DragState = struct { from: usize, over: usize, prev_over: usize, epoch: usize };

const QueueEdit = struct {
    id: []u8,
    lease_id: []u8,
    base_hash: []u8,
    chat_id: []u8,
    host_device_id: []u8,
    /// The ordinary draft displaced while the row occupies the composer.
    draft: []u8,
    /// The draft's staged attachments, displaced with it.
    draft_staged: std.ArrayList(att.Staged) = .empty,

    fn deinit(e: QueueEdit, gpa: Allocator, app: *App) void {
        gpa.free(e.id);
        gpa.free(e.lease_id);
        gpa.free(e.base_hash);
        gpa.free(e.chat_id);
        gpa.free(e.host_device_id);
        gpa.free(e.draft);
        var staged = e.draft_staged;
        for (staged.items) |*a| a.deinit(gpa, app);
        staged.deinit(gpa);
    }
};

/// An acquired lease waiting for the row's attachments to load.
const AcquiredEdit = struct {
    id: []u8,
    lease_id: []u8,
    base_hash: []u8,
    chat_id: []u8,
    host_device_id: []u8,
    /// The row's editable text (`queue_visible_text`).
    text: []u8,

    fn deinit(a: AcquiredEdit, gpa: Allocator) void {
        gpa.free(a.id);
        gpa.free(a.lease_id);
        gpa.free(a.base_hash);
        gpa.free(a.chat_id);
        gpa.free(a.host_device_id);
        gpa.free(a.text);
    }
};

const Mention = struct {
    /// Token start of the open popup (null = closed).
    start: ?usize = null,
    query: std.ArrayList(u8) = .empty,
    arena: ?*std.heap.ArenaAllocator = null,
    results: []completions.FileMatch = &.{},
    active: usize = 0,
    loading: bool = false,
    err: ?[]const u8 = null,
    request: u64 = 0,
    dismissed: ?usize = null,
    debounce: zpui.Task(void) = .none,
};

const Catalog = struct {
    arena: ?*std.heap.ArenaAllocator = null,
    rows: []const completions.Candidate = &.{},
    key: u64 = 0,
    loading: bool = false,
    err: ?[]const u8 = null,
    skill: bool = false,
    supported: bool = true,
    request: u64 = 0,
    /// Replies still outstanding for `request`.
    pending: u8 = 0,
    commands: ?[]const completions.SlashCommand = null,
    skills: ?[]const completions.Skill = null,
    commands_failed: ?[]const u8 = null,
    skills_failed: ?[]const u8 = null,
    in_chat: bool = false,
    include_skills: bool = true,
    commands_allowed: bool = true,
};

pub const Extras = struct {
    // ---- wizard ----
    wizard: ?wizard_mod.Wizard = null,
    answered: std.StringHashMapUnmanaged(void) = .empty,
    advance_task: zpui.Task(void) = .none,
    recheck_task: zpui.Task(void) = .none,
    recheck_id: ?[]u8 = null,
    wizard_focus: ?zpui.FocusHandle = null,
    store_sub: ?zpui.Subscription = null,
    store_id: ?zpui.EntityId = null,
    // ---- todo ----
    todo: todo.Panels = .{},
    // ---- queue ----
    drag: ?DragState = null,
    edit: ?QueueEdit = null,
    edit_pending: ?[]u8 = null,
    edit_finishing: bool = false,
    /// The lease acquired while its attachments load (`edit_pending` stays set).
    edit_loading: ?AcquiredEdit = null,
    load_task: zpui.Task(?[]att.StageOutcome) = .none,
    /// The commit's attachment upload.
    commit_task: zpui.Task(att.UploadResult) = .none,
    commit_text: ?[]u8 = null,
    renew_task: zpui.Task(void) = .none,
    instance_id: [36]u8 = @splat('0'),
    // ---- worktree setup handoff ----
    /// FIFO: `QueueCommand` replies pair with the oldest entry.
    setup_queued: std.ArrayList(SetupPoll) = .empty,
    /// FIFO: polled one at a time.
    setup_polls: std.ArrayList(SetupPoll) = .empty,
    setup_timer: zpui.Task(void) = .none,
    setup_in_flight: bool = false,
    setup_event: ?std.heap.ArenaAllocator = null,
    // ---- completions ----
    mention: Mention = .{},
    catalog: Catalog = .{},

    pub fn deinit(self: *Extras, gpa: Allocator, app: *App) void {
        if (self.wizard) |*w| w.deinit(gpa);
        var it = self.answered.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        self.answered.deinit(gpa);
        self.advance_task.cancel();
        self.recheck_task.cancel();
        if (self.recheck_id) |r| gpa.free(r);
        if (self.wizard_focus) |f| f.release(app);
        if (self.store_sub) |*s| s.deinit();
        self.todo.deinit(gpa);
        if (self.edit) |e| e.deinit(gpa, app);
        if (self.edit_pending) |p| gpa.free(p);
        if (self.edit_loading) |l| l.deinit(gpa);
        self.load_task.cancel();
        self.commit_task.cancel();
        if (self.commit_text) |t| gpa.free(t);
        self.renew_task.cancel();
        for (self.setup_queued.items) |p| p.deinit(gpa);
        self.setup_queued.deinit(gpa);
        for (self.setup_polls.items) |p| p.deinit(gpa);
        self.setup_polls.deinit(gpa);
        self.setup_timer.cancel();
        if (self.setup_event) |*a| a.deinit();
        clearMention(&self.mention, gpa);
        self.mention.query.deinit(gpa);
        self.mention.debounce.cancel();
        clearCatalog(&self.catalog, gpa);
    }
};

fn ext(self: *ComposerView) *Extras {
    return &self.ext;
}

fn selectedChat(self: *const ComposerView, cx: anytype) ?[]const u8 {
    return self.state.read(cx).workspace.read(cx).selected_chat;
}

/// The selected chat's transcript store (when it is the selected chat's).
fn transcriptStore(self: *const ComposerView, cx: anytype) ?Entity(model.TranscriptStore) {
    const chat = selectedChat(self, cx) orelse return null;
    const t = self.state.read(cx).transcript orelse return null;
    if (!std.mem.eql(u8, t.read(cx).chat_id, chat)) return null;
    return t;
}

fn putDraft(self: *ComposerView, text: []const u8) void {
    if (self.drafts.fetchRemove(self.current_key.items)) |kv| {
        self.gpa.free(kv.key);
        self.gpa.free(kv.value);
    }
    if (text.len == 0) return;
    const k = self.gpa.dupe(u8, self.current_key.items) catch return;
    const v = self.gpa.dupe(u8, text) catch {
        self.gpa.free(k);
        return;
    };
    self.drafts.put(self.gpa, k, v) catch {
        self.gpa.free(k);
        self.gpa.free(v);
    };
}

fn currentDraft(self: *ComposerView) []const u8 {
    return self.drafts.get(self.current_key.items) orelse "";
}

// =============================================================================================
// Store lifecycle
// =============================================================================================

/// `SelectedChatStoresChanged`: follow the new transcript store's changes.
pub fn onStoresChanged(self: *ComposerView, cx: *Ctx) void {
    const e = ext(self);
    const t = self.state.read(cx).transcript;
    const id: ?zpui.EntityId = if (t) |s| s.id else null;
    if (!std.meta.eql(id, e.store_id)) {
        if (e.store_sub) |*s| s.deinit();
        e.store_sub = null;
        e.store_id = id;
        if (t) |s| e.store_sub = cx.subscribe(s, onTranscriptChanged) catch null;
    }
    syncWizard(self, cx);
}

fn onTranscriptChanged(self: *ComposerView, _: Entity(model.TranscriptStore), _: *const model.transcript_store.Changed, cx: *Ctx) void {
    syncWizard(self, cx);
    cx.notify();
}

/// Before `syncKey` swaps drafts: a question borrows the editor, so its
/// typed answer must never become the outgoing chat's draft.
pub fn beforeKeySwap(self: *ComposerView, cx: *Ctx) void {
    const e = ext(self);
    if (e.wizard) |*w| {
        w.deinit(self.gpa);
        e.wizard = null;
        e.advance_task.cancel();
        const draft = self.gpa.dupe(u8, currentDraft(self)) catch return;
        defer self.gpa.free(draft);
        self.input.update(cx, TextInput.setText, .{draft});
        restoreInputIdentity(self, cx);
    }
    if (e.edit != null) clearQueueEdit(self, true, cx);
    resetMention(self, null);
    e.drag = null;
}

fn restoreInputIdentity(self: *ComposerView, cx: *Ctx) void {
    self.input.update(cx, TextInput.setPlaceholder, .{"Do anything…"});
    self.input.update(cx, TextInput.setKeyContext, .{actions.keymap.message_composer_context});
}

// =============================================================================================
// Question wizard
// =============================================================================================

pub fn wizardActive(self: *const ComposerView) bool {
    return self.ext.wizard != null;
}

/// The panel lifecycle (wizard state cached per request id, with the latch).
pub fn syncWizard(self: *ComposerView, cx: *Ctx) void {
    const e = ext(self);
    if (e.edit != null or e.edit_pending != null) return;
    const t = transcriptStore(self, cx) orelse return;
    const store = t.read(cx);
    const pending = wizard_mod.pendingInputRequest(store);
    if (pending) |p| if (!e.answered.contains(p.request_id)) {
        if (e.wizard) |w| if (std.mem.eql(u8, w.request_id, p.request_id)) return;
        if (e.wizard == null) putDraft(self, self.input.read(cx).text());
        if (e.wizard) |*w| w.deinit(self.gpa);
        e.wizard = wizard_mod.Wizard.init(self.gpa, p.request_id, p.questions) catch return;
        e.advance_task.cancel();
        resetMention(self, null);
        const prefill = if (p.questions.len > 0) p.questions[0].prefill orelse "" else "";
        self.input.update(cx, TextInput.setText, .{prefill});
        // The shared input becomes the panel's free-text override.
        self.input.update(cx, TextInput.setPlaceholder, .{"Type your own answer, or pick an option above"});
        self.input.update(cx, TextInput.setKeyContext, .{actions.keymap.generic_composer_context});
        cx.notify();
        return;
    };
    // LATCH: release only on explicit resolution, or when a non-empty
    // transcript no longer shows the question (superseded).
    if (e.wizard) |*w| {
        const released = wizard_mod.inputRequestResolved(store, w.request_id) or
            (store.len() > 0 and !e.answered.contains(w.request_id));
        if (!released) return;
        w.deinit(self.gpa);
        e.wizard = null;
        e.advance_task.cancel();
        const draft = self.gpa.dupe(u8, currentDraft(self)) catch return;
        defer self.gpa.free(draft);
        self.input.update(cx, TextInput.setText, .{draft});
        restoreInputIdentity(self, cx);
        cx.notify();
    }
}

pub fn wizardSelect(self: *ComposerView, option_ix: usize, cx: *Ctx) void {
    const w = &(ext(self).wizard orelse return);
    const step = w.select(option_ix);
    const has_pick = w.pageHasPick();
    self.input.update(cx, TextInput.setPlaceholder, .{if (has_pick) "Type your own answer, or leave this blank to use the selected option" else "Type your own answer, or pick an option above"});
    switch (step) {
        .auto_advance => {
            ext(self).advance_task.cancel();
            ext(self).advance_task = cx.timer(wizard_mod.auto_advance_ms * std.time.ns_per_ms, onAutoAdvance) catch .none;
        },
        .done => |answers| wizardFinish(self, answers, cx),
        .stay => {},
    }
    cx.notify();
}

fn onAutoAdvance(self: *ComposerView, cx: *Ctx) void {
    ext(self).advance_task.detach();
    ext(self).advance_task = .none;
    wizardAdvance(self, cx);
}

pub fn wizardAdvance(self: *ComposerView, cx: *Ctx) void {
    const w = &(ext(self).wizard orelse return);
    w.setTyped(self.input.read(cx).text());
    switch (w.advance()) {
        .done => |answers| wizardFinish(self, answers, cx),
        else => {
            const text = self.gpa.dupe(u8, w.typedText()) catch return;
            defer self.gpa.free(text);
            self.input.update(cx, TextInput.setText, .{text});
            cx.notify();
        },
    }
}

pub fn wizardBack(self: *ComposerView, cx: *Ctx) void {
    const w = &(ext(self).wizard orelse return);
    w.setTyped(self.input.read(cx).text());
    _ = w.back();
    const text = self.gpa.dupe(u8, w.typedText()) catch return;
    defer self.gpa.free(text);
    self.input.update(cx, TextInput.setText, .{text});
    cx.notify();
}

/// Submit `respondInput` and retire the panel.
fn wizardFinish(self: *ComposerView, answers: []const protocol.UserInputAnswer, cx: *Ctx) void {
    const e = ext(self);
    var w = e.wizard orelse return;
    e.wizard = null;
    defer w.deinit(self.gpa);
    e.advance_task.cancel();
    const rid = self.gpa.dupe(u8, w.request_id) catch return;
    e.answered.put(self.gpa, rid, {}) catch self.gpa.free(rid);
    const draft = self.gpa.dupe(u8, currentDraft(self)) catch return;
    defer self.gpa.free(draft);
    self.input.update(cx, TextInput.setText, .{draft});
    restoreInputIdentity(self, cx);
    const t = transcriptStore(self, cx) orelse return;
    t.update(cx, model.TranscriptStore.queueCommand, .{protocol.SessionCommandPayload{ .respondInput = .{ .requestId = w.request_id, .answers = answers } }}) catch |err| {
        var buf: [96]u8 = undefined;
        self.showError(std.fmt.bufPrint(&buf, "Answer failed: {t}", .{err}) catch "Answer failed", cx);
        // The answer never left this device — put the panel back.
        if (e.answered.fetchRemove(w.request_id)) |kv| self.gpa.free(kv.key);
        syncWizard(self, cx);
        return;
    };
    // Safety net: still the live pending input after 2s → un-hide it.
    if (e.recheck_id) |r| self.gpa.free(r);
    e.recheck_id = self.gpa.dupe(u8, w.request_id) catch null;
    e.recheck_task.cancel();
    e.recheck_task = cx.timer(answer_recheck_ms * std.time.ns_per_ms, onAnswerRecheck) catch .none;
    cx.notify();
}

fn onAnswerRecheck(self: *ComposerView, cx: *Ctx) void {
    const e = ext(self);
    e.recheck_task.detach();
    e.recheck_task = .none;
    const rid = e.recheck_id orelse return;
    defer {
        self.gpa.free(rid);
        e.recheck_id = null;
    }
    const t = transcriptStore(self, cx) orelse return;
    const pending = wizard_mod.pendingInputRequest(t.read(cx)) orelse return;
    if (!std.mem.eql(u8, pending.request_id, rid)) return;
    if (e.answered.fetchRemove(rid)) |kv| self.gpa.free(kv.key);
    syncWizard(self, cx);
    cx.notify();
}

fn onWizardKey(self: *ComposerView, ev: *const zpui.input.KeyDownEvent, window: *Window, cx: *Ctx) void {
    const in = self.input.read(cx);
    const focused = in.focus.isFocused(window);
    const empty = in.text().len == 0;
    const key = ev.keystroke.key;
    const mods = ev.keystroke.modifiers;
    const modified = mods.control or mods.alt or mods.platform or mods.function;
    if (key.len == 1 and key[0] >= '1' and key[0] <= '9' and !modified) {
        if (!focused or empty) {
            wizardSelect(self, key[0] - '1', cx);
            cx.stopPropagation();
        }
    } else if (std.mem.eql(u8, key, "enter")) {
        if (!focused) {
            wizardAdvance(self, cx);
            cx.stopPropagation();
        }
    } else if (std.mem.eql(u8, key, "escape")) {
        if (wizard_mod.escapeGoesBack(focused, empty)) wizardBack(self, cx);
        cx.stopPropagation();
    }
}

fn onWizardOption(self: *ComposerView, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    wizardSelect(self, ix, cx);
}

fn onWizardBack(self: *ComposerView, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    wizardBack(self, cx);
}

fn onWizardSubmit(self: *ComposerView, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    wizardAdvance(self, cx);
}

/// `tracked_upper`: the header in uppercase.
fn upper(text: []const u8) []const u8 {
    const a = zpui.window.arena_mod.frameAllocator();
    const out = a.alloc(u8, text.len) catch return text;
    for (text, out) |c, *o| o.* = std.ascii.toUpper(c);
    return out;
}

/// The question panel (question-panel.tsx) in place of the pill.
pub fn renderWizard(self: *ComposerView, window: *Window, cx: *Ctx) ?zpui.StatefulDiv {
    const e = ext(self);
    const w = &(e.wizard orelse return null);
    const q = w.current() orelse return null;
    const theme = &self.theme;
    if (e.wizard_focus == null) e.wizard_focus = cx.focusHandle();
    self.input.update(cx, TextInput.setViewport, .{ null, null, false, 0 });
    const typed_empty = self.input.read(cx).text().len == 0;
    const last = w.page + 1 >= w.questions.len;
    const can_advance = w.pageHasPick() or !typed_empty or q.multiline;
    _ = window;

    var options = div().mt(px(12)).flex().flexCol().gap(px(4));
    for (q.options, 0..) |label, ix| {
        const picked = w.isPicked(ix) and typed_empty;
        var row = div().id(.{ "wizard-option", ix }).role(if (q.multiSelect) .check_box else .radio_button).ariaLabel(label).ariaToggled(picked).flex().flexRow().itemsCenter().gap(px(12)).px(px(14)).py(px(10)).rounded(px(12))
            .border1().borderColor(if (picked) theme.ink(0.16) else zpui.color.transparent_black)
            .bg(if (picked) theme.ink(0.09) else theme.ink(0.025)).cursorPointer()
            .onClick(cx.listenerWith(ix, onWizardOption))
            .child(div().flex1().minW0().textSize(rems(13.5)).fontWeight(500).textColor(if (picked) theme.text else theme.text.opacity(0.9)).child(label));
        if (!picked) row = row.hover(sb.bg(theme.ink(0.06)));
        if (ix < 9) row = row.child(div().flexNone().size(px(22)).flex().itemsCenter().justifyCenter().rounded(px(6))
            .bg(if (picked) theme.ink(0.16) else theme.ink(0.05)).textSize(rems(11))
            .textColor(if (picked) theme.text else theme.text_muted.opacity(0.6))
            .child(zpui.fmt("{d}", .{ix + 1})));
        options = options.child(row);
    }
    var header = div().flex().flexRow().itemsCenter().gap(px(10))
        .child(div().textSize(rems(10.5)).fontWeight(500).textColor(theme.text_muted.opacity(0.6)).child(upper(q.header)));
    if (w.questions.len > 1) {
        var buf: [16]u8 = undefined;
        header = header.child(div().h(px(20)).px(px(6)).flex().itemsCenter().rounded(px(6)).bg(theme.ink(0.06))
            .textSize(rems(10)).fontWeight(500).textColor(theme.text_muted.opacity(0.6)).child(zpui.window.arena_mod.dupe(w.counter(&buf))));
    }
    var body = div().px(px(16)).pt(px(16)).flex().flexCol()
        .child(header)
        .child(div().mt(px(6)).textSize(rems(15)).lineHeight(px(20)).fontWeight(500).textColor(theme.text).child(q.question));
    if (q.multiSelect) body = body.child(div().mt(px(4)).textSize(rems(12)).textColor(theme.text_muted.opacity(0.65)).child("Select one or more options."));
    body = body.child(options)
        .child(div().mt(px(12)).borderT1().borderColor(theme.hairline(0.06)).pt(px(12)).pb(px(4)).px(px(4)).child(self.input));
    var submit = div().id("wizard-submit").role(.button).ariaDisabled(!can_advance).px(px(16)).py(px(6)).rounded(px(8)).bg(theme.text)
        .textSize(rems(13)).fontWeight(500).textColor(theme.on_solid).cursorPointer().hover(sb.opacity(0.9))
        .onClick(cx.listener(onWizardSubmit))
        .child(if (last) "Submit" else "Next");
    if (!can_advance) submit = submit.opacity(0.4);
    const back: ?zpui.StatefulDiv = if (w.page > 0) div().id("wizard-back").role(.button).px(px(12)).py(px(6)).rounded(px(8)).textSize(rems(13))
        .textColor(theme.text_muted).cursorPointer().hover(sb.bg(theme.ink(0.06)).textColor(theme.text))
        .onClick(cx.listener(onWizardBack)).child("Back") else null;
    const footer = div().flex().flexRow().justifyBetween().itemsCenter().px(px(16)).pb(px(16)).pt(px(4))
        .child(if (back) |b| zpui.intoAnyElement(b) else zpui.intoAnyElement(div()))
        .child(submit);
    var panel = div().id("question-panel").trackFocus(e.wizard_focus.?)
        .onKeyDown(cx.listener(onWizardKey))
        .occlude().rounded(px(m.composer_radius)).border1().borderColor(theme.onGlassBorder(theme.border))
        .bg(theme.onGlass(theme.composerSurfaceBg())).flex().flexCol() // [liquid-glass]
        .child(body).child(footer);
    if (!theme.isFrost()) panel = panel.shadowLg();
    return div().relative().id("composer-surface").child(chrome.frosted(theme, m.composer_radius, zt.layout.menu_blur, panel));
}

// =============================================================================================
// Submit / escape routing
// =============================================================================================

/// Enter in the input: the wizard advances, a queue edit commits. True when handled.
pub fn onSubmit(self: *ComposerView, cx: *Ctx) bool {
    const e = ext(self);
    if (e.wizard != null) {
        wizardAdvance(self, cx);
        return true;
    }
    if (e.edit != null) {
        commitQueueEdit(self, cx);
        return true;
    }
    return false;
}

/// Escape in the input: wizard back (empty field), queue edit cancel.
pub fn onEscape(self: *ComposerView, cx: *Ctx) void {
    const e = ext(self);
    if (e.wizard != null) {
        if (self.input.read(cx).text().len == 0) wizardBack(self, cx);
        return;
    }
    if (e.edit != null) finishQueueEdit(self, "cancel", null, cx);
}

// =============================================================================================
// Todo tray
// =============================================================================================

fn onTodoToggle(self: *ComposerView, finished: bool, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    const chat = selectedChat(self, cx) orelse return;
    ext(self).todo.get(self.gpa, chat).toggle(finished);
    cx.notify();
}

fn onTodoDismiss(self: *ComposerView, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    const chat = selectedChat(self, cx) orelse return;
    const t = transcriptStore(self, cx) orelse return;
    const items = todo.latestTodo(t.read(cx)) orelse return;
    ext(self).todo.get(self.gpa, chat).dismiss(items);
    cx.notify();
}

fn onTodoFold(self: *ComposerView, side: todo.FoldSide, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    const chat = selectedChat(self, cx) orelse return;
    ext(self).todo.get(self.gpa, chat).toggleFold(side);
    cx.notify();
}

/// The checklist tray (null when the chat has no todo or it was dismissed).
const TodoView = struct { items: []const protocol.TodoItem, summary: todo.Summary, st: *todo.State, live: bool };

/// The tray's model for this frame (null: no list, or dismissed).
pub fn todoView(self: *ComposerView, cx: *Ctx) ?TodoView {
    const chat = selectedChat(self, cx) orelse return null;
    const t = transcriptStore(self, cx) orelse return null;
    const items = todo.latestTodo(t.read(cx)) orelse return null;
    const live = self.runLive(cx);
    const summary = todo.Summary.of(items);
    const st = ext(self).todo.get(self.gpa, chat);
    st.observe(summary.finished() and !live);
    if (st.isDismissed(items)) return null;
    return .{ .items = items, .summary = summary, .st = st, .live = live };
}

pub fn renderTodo(self: *ComposerView, below_queue: bool, cx: *Ctx) ?zpui.Div {
    const tv = todoView(self, cx) orelse return null;
    const items = tv.items;
    const live = tv.live;
    const summary = tv.summary;
    const st = tv.st;
    const expanded = st.isExpanded(summary.finished());
    const theme = &self.theme;
    const finished = summary.finished();

    var toggle = div().id("todo-panel-toggle").role(.button).ariaLabel(if (expanded) "Collapse todo list" else "Expand todo list").ariaExpanded(expanded).flex1().minW0().h(px(32)).px(px(8)).rounded(px(8)).flex().itemsCenter().gap(px(8))
        .cursorPointer().hover(sb.bg(theme.element_hover))
        .onClick(cx.listenerWith(finished, onTodoToggle))
        .tooltipWith(chrome.TipData{ .text = if (expanded) "Collapse todo list" else "Expand todo list", .dark = theme.appearance.isDark() }, chrome.buildTooltip)
        .child(chrome.icon(if (finished) .check else .checklist, 14, if (finished) theme.success else theme.text_muted))
        .child(div().flexNone().flex().itemsBaseline().gap(px(6)).textSize(px(12.5))
        .child(div().fontWeight(500).textColor(theme.text).child("Todo"))
        .child(div().textColor(theme.text_faint).child(zpui.fmt("{d}/{d}", .{ summary.done, summary.total }))));
    if (!expanded) {
        if (finished) {
            toggle = toggle.child(div().flex1().minW0().truncate().textSize(px(12.5)).textColor(theme.text_faint).child("All done"));
        } else if (summary.headline()) |h| {
            toggle = toggle.child(div().flex1().minW0().truncate().textSize(px(12.5)).textColor(theme.text_muted).child(items[h].text));
        } else toggle = toggle.child(div().flex1());
    } else toggle = toggle.child(div().flex1());
    toggle = toggle.child(chrome.icon(if (expanded) .alt_arrow_down else .alt_arrow_up, 13, theme.text_muted.opacity(0.7)));
    var header = div().flex().itemsCenter().gap(px(2)).child(toggle);
    if (!live) header = header.child(div().id("todo-panel-dismiss").role(.button).ariaLabel("Dismiss todo list").size(px(24)).flexNone().flex().itemsCenter().justifyCenter().rounded(px(5))
        .cursorPointer().hover(sb.bg(theme.element_hover))
        .onClick(cx.listener(onTodoDismiss))
        .tooltipWith(chrome.TipData{ .text = "Dismiss", .dark = theme.appearance.isDark() }, chrome.buildTooltip)
        .child(chrome.icon(.close, 11, theme.text_muted.opacity(0.8))));

    var surface = div().occlude().roundedT(px(16))
        .bg(theme.onGlass(if (theme.isFrost() and theme.appearance.isDark()) theme.composerSidebarTint() else theme.inputGlassBg())) // [liquid-glass]
        .border1().borderColor(theme.border)
        .px(px(4)).pt(px(4)).pb(px(m.queue_composer_overlap)).flex().flexCol()
        .child(header);
    if (!theme.isFrost()) surface = surface.shadowLg();
    if (expanded) {
        var list: std.ArrayList(todo.Row) = .empty;
        const a = zpui.window.arena_mod.frameAllocator();
        todo.rows(&list, a, items, st.show_earlier, st.show_later) catch {};
        var col = div().mt(px(2)).pb(px(6)).flex().flexCol();
        for (list.items) |row| switch (row) {
            .item => |ix| col = col.child(todoItemRow(ix, items[ix], live, theme)),
            .fold => |f| col = col.child(div().id(.{ "todo-fold", @backingInt(f.side) }).role(.button).ariaLabel(zpui.fmt("{s} {d} {s} items", .{ if (f.open) "Hide" else "Show", f.count, if (f.side == .earlier) "earlier" else "later" })).ariaExpanded(f.open).h(px(24)).px(px(8)).rounded(px(6)).flex().itemsCenter().gap(px(8))
                .cursorPointer().hover(sb.bg(theme.element_hover))
                .onClick(cx.listenerWith(f.side, onTodoFold))
                .child(div().w(px(14)).flexNone().flex().justifyCenter()
                    .child(chrome.icon(if ((f.side == .earlier) != f.open) .alt_arrow_up else .alt_arrow_down, 12, theme.text_faint)))
                .child(div().textSize(px(11.5)).textColor(theme.text_faint).child(zpui.fmt("{d} {s}", .{ f.count, if (f.side == .earlier) "earlier" else "later" })))),
        };
        // [motion] `todo-rows-{epoch}`: the rows fade in (FADE_QUICK) per toggle.
        const Fade = struct {
            fn f(el: zpui.Div, t: f32) zpui.Div {
                return el.opacity(t);
            }
        };
        surface = surface.child(zpui.withAnimation(col, .{ "todo-rows", @as(u64, st.epoch) }, zt.motion.fade_quick.animation(), Fade.f));
    }
    const inset: f32 = if (below_queue) 32 else 16;
    return div().mx(px(inset)).mb(px(-(zt.layout.space_sm + m.queue_composer_overlap)))
        .child(chrome.frosted(theme, 16, zt.layout.menu_blur, surface));
}

fn todoItemRow(ix: usize, item: protocol.TodoItem, live: bool, theme: *const Theme) zpui.StatefulDiv {
    const status = item.effectiveStatus();
    const color = switch (status) {
        .completed => theme.text_faint,
        .inProgress => theme.text,
        .pending => theme.text_muted,
    };
    const glyph: zpui.AnyElement = switch (status) {
        .completed => zpui.intoAnyElement(chrome.icon(.check, 12, theme.success)),
        .inProgress => if (live)
            zpui.intoAnyElement(div().size(px(10)).roundedFull().border1().borderColor(theme.accent).bg(theme.accent.opacity(0.35)))
        else
            zpui.intoAnyElement(div().size(px(10)).roundedFull().border1().borderColor(theme.accent).flex().itemsCenter().justifyCenter()
                .child(div().size(px(4)).roundedFull().bg(theme.accent))),
        .pending => zpui.intoAnyElement(div().size(px(10)).roundedFull().border1().borderColor(theme.text_faint.opacity(0.7))),
    };
    return div().id(.{ "todo-item", ix }).minH(px(26)).px(px(8)).py(px(4)).flex().itemsStart().gap(px(8))
        .child(div().w(px(14)).h(px(17)).flexNone().flex().itemsCenter().justifyCenter().child(glyph))
        .child(div().flex1().minW0().textSize(px(12.5)).lineHeight(px(17)).fontWeight(if (status == .inProgress) 500 else 400).textColor(color).child(item.text));
}

// =============================================================================================
// Queue: drag reorder + leased edit
// =============================================================================================

fn keyHash(self: *const ComposerView) u64 {
    return std.hash.Wyhash.hash(0x9e7e, self.current_key.items);
}

pub const QueueGhost = struct {
    pub fn render(_: *QueueGhost, _: *Window, _: *Context(QueueGhost)) zpui.Div {
        return div();
    }
};

fn buildGhost(_: *const QueueDrag, _: zpui.Point(f32), _: *Window, app: *App) Entity(QueueGhost) {
    return app.new(QueueGhost, .{}) catch @panic("OOM");
}

/// `queue_drop_index`.
pub fn queueDropIndex(panel_y: f32, count: usize) usize {
    if (count == 0) return 0;
    const ix: isize = @intFromFloat(@floor((panel_y - queue_pad_top) / queue_row_slot));
    return @intCast(std.math.clamp(ix, 0, @as(isize, @intCast(count - 1))));
}

fn slideOffset(ix: usize, from: usize, over: usize) f32 {
    if (from < over and ix > from and ix <= over) return -1;
    if (over < from and ix >= over and ix < from) return 1;
    return 0;
}

/// `queue_drag_offsets` (target only): the dragged row travels to its slot,
/// rows in its path slide into the gap.
pub fn queueDragOffset(ix: usize, from: usize, over: usize) f32 {
    if (ix == from) return (@as(f32, @floatFromInt(over)) - @as(f32, @floatFromInt(from))) * queue_row_slot;
    return slideOffset(ix, from, over) * queue_row_slot;
}

fn onQueueDragMove(self: *ComposerView, ev: *const zpui.DragMoveEvent(QueueDrag), _: *Window, cx: *Ctx) void {
    if (ev.value.key_hash != keyHash(self)) return;
    const q = self.state.read(cx).queue orelse return;
    const count = q.read(cx).items().len;
    const over = queueDropIndex(ev.event.position.y - ev.bounds.origin.y, count);
    const e = ext(self);
    if (e.drag) |*d| {
        if (d.from == ev.value.from and d.over != over) {
            d.prev_over = d.over;
            d.over = over;
            d.epoch += 1;
            cx.notify();
        }
    } else {
        e.drag = .{ .from = ev.value.from, .over = over, .prev_over = ev.value.from, .epoch = 0 };
        cx.notify();
    }
}

fn onQueueDrop(self: *ComposerView, payload: *const QueueDrag, _: *Window, cx: *Ctx) void {
    const e = ext(self);
    const to = if (e.drag) |d| d.over else payload.from;
    e.drag = null;
    if (payload.key_hash != keyHash(self)) return cx.notify();
    moveQueued(self, payload.from, to, cx);
}

/// `move_queued`: optimistic here, `MoveQueuedMessage` for real.
pub fn moveQueued(self: *ComposerView, from: usize, to: usize, cx: *Ctx) void {
    defer cx.notify();
    if (from == to) return;
    const q = self.state.read(cx).queue orelse return;
    const items = q.read(cx).items();
    if (from >= items.len) return;
    const id = self.gpa.dupe(u8, items[from].id) catch return;
    defer self.gpa.free(id);
    q.update(cx, model.QueueStore.moveLocal, .{ from, to });
    q.update(cx, model.QueueStore.moveQueuedMessage, .{ id, to }) catch |err| {
        self.showError(if (err == error.NotConnected) "Engine not connected" else "Couldn't reorder the queue", cx);
    };
}

/// Decorate one queue row (drag source + slide offset + editing wash).
pub fn queueRow(self: *ComposerView, row: zpui.StatefulDiv, ix: usize, item_id: []const u8, cx: *Ctx) zpui.AnyElement {
    _ = cx;
    const e = ext(self);
    const editing = if (e.edit) |ed| std.mem.eql(u8, ed.id, item_id) else false;
    var r = row;
    if (editing) return zpui.intoAnyElement(r.bg(self.theme.ink(0.06)));
    if (e.edit == null and e.edit_pending == null) r = r.onDrag(QueueDrag{ .key_hash = keyHash(self), .from = ix }, buildGhost);
    if (e.drag) |d| {
        if (ix == d.from) r = r.opacity(0.9);
        // `queue-row-slide`: TAB_SLIDE between the previous and the current
        // committed offsets (reduced motion lands on the target).
        const start = queueDragOffset(ix, d.from, d.prev_over);
        const target = queueDragOffset(ix, d.from, d.over);
        if (start == 0 and target == 0) return zpui.intoAnyElement(r);
        const Slide = struct {
            fn f(c: [2]f32, el: zpui.Div, t: f32) zpui.Div {
                return el.relative().top(px(c[0] + (c[1] - c[0]) * t));
            }
        };
        return zpui.intoAnyElement(zpui.withAnimationCtx(div().flexNone().child(r), .{ "queue-row-slide", (ix & 0xffff) | (d.epoch << 16) }, zt.motion.tab_slide.animation(), [2]f32{ start, target }, Slide.f));
    }
    return zpui.intoAnyElement(r);
}

/// Make the whole queue surface the drop target.
pub fn queuePanel(self: *ComposerView, panel: zpui.Div, cx: *Ctx) zpui.Div {
    const e = ext(self);
    if (e.drag != null and !cx.app.hasActiveDrag()) e.drag = null;
    return panel.onDragMove(QueueDrag, cx.listener(onQueueDragMove)).onDrop(QueueDrag, cx.listener(onQueueDrop));
}

pub fn isEditingQueued(self: *const ComposerView) bool {
    return self.ext.edit != null;
}

const EditParams = struct {
    chatId: []const u8,
    id: []const u8,
    editorDeviceId: ?[]const u8 = null,
    editorInstanceId: ?[]const u8 = null,
    leaseId: ?[]const u8 = null,
    action: ?[]const u8 = null,
    text: ?[]const u8 = null,
    expectedTextHash: ?[]const u8 = null,
    /// Commit only: the staged attachments' uploaded paths (may be empty).
    attachments: ?[]const []const u8 = null,
    targetDeviceId: []const u8,
};

/// `begin_queue_edit`: acquire the host's edit lease before the row moves
/// into the composer.
pub fn beginQueueEdit(self: *ComposerView, ix: usize, cx: *Ctx) void {
    const e = ext(self);
    if (e.edit_pending != null or e.edit_finishing or e.edit != null or e.wizard != null) return;
    const st = self.state.read(cx);
    const q = st.queue orelse return;
    const items = q.read(cx).items();
    if (ix >= items.len) return;
    const ws = st.workspace.read(cx);
    const chat = ws.selectedChatRow() orelse return;
    const eng = st.engine.read(cx);
    const cap = protocol.capabilities.message_queue_edit_lease_v1;
    if (!(eng.supports(cap) and ws.deviceSupports(eng, chat.deviceId, cap))) {
        return self.showError("Update the chat host to edit queued messages safely", cx);
    }
    if (e.instance_id[0] == '0') if (self.io) |io| {
        _ = rc.uuidV4(io, &e.instance_id);
    };
    e.edit_pending = self.gpa.dupe(u8, items[ix].id) catch return;
    e.drag = null;
    es.EngineState.request(st.engine, cx, ComposerView, cx.entityId(), .BeginQueuedMessageEdit, EditParams{
        .chatId = chat.id,
        .id = items[ix].id,
        .editorDeviceId = eng.deviceId(),
        .editorInstanceId = &e.instance_id,
        .targetDeviceId = chat.deviceId,
    }, onBeginEdit) catch {
        self.gpa.free(e.edit_pending.?);
        e.edit_pending = null;
        self.showError("Connect to the chat host to edit this message", cx);
    };
    cx.notify();
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

pub fn onBeginEdit(self: *ComposerView, result: es.CallResult, cx: *Ctx) void {
    const e = ext(self);
    const id = e.edit_pending orelse return;
    defer cx.notify();
    const v = switch (result) {
        .ok => |v| v,
        .err => {
            clearPending(self);
            return self.showError("Connect to the chat host to edit this message", cx);
        },
    };
    const outcome = str(v, "outcome") orelse "";
    if (!std.mem.eql(u8, outcome, "acquired")) clearPending(self);
    if (std.mem.eql(u8, outcome, "locked")) return self.showError("That queued message is being edited on another device", cx);
    if (!std.mem.eql(u8, outcome, "acquired")) return self.showError("That queued message is no longer available", cx);
    const ws = self.state.read(cx).workspace.read(cx);
    const chat = ws.selectedChatRow() orelse return clearPending(self);
    const lease = str(v, "leaseId");
    // `attachments` must be a string array (Rust: a missing field fails the restore).
    var arena = std.heap.ArenaAllocator.init(self.gpa);
    defer arena.deinit();
    const paths: ?[]const []const u8 = blk: {
        const f = if (v == .object) v.object.get("attachments") else null;
        const arr = f orelse break :blk null;
        if (arr != .array) break :blk null;
        const out = arena.allocator().alloc([]const u8, arr.array.items.len) catch break :blk null;
        for (arr.array.items, out) |item, *o| {
            if (item != .string) break :blk null;
            o.* = item.string;
        }
        break :blk out;
    };
    const host = chat.deviceId;
    const list = paths orelse return failLoad(self, chat.id, id, lease, host, cx);
    const hash = str(v, "baseTextHash");
    const raw_text = str(v, "text") orelse "";
    var text = att.queueVisibleText(arena.allocator(), raw_text, list) catch raw_text;
    if (list.len > 0 and std.mem.eql(u8, text, att.attachment_only_text)) text = "";
    if (lease == null or hash == null) {
        clearPending(self);
        return self.showError("The chat host returned an invalid edit lease", cx);
    }
    const acquired: AcquiredEdit = .{
        .id = self.gpa.dupe(u8, id) catch return,
        .lease_id = self.gpa.dupe(u8, lease.?) catch return,
        .base_hash = self.gpa.dupe(u8, hash.?) catch return,
        .chat_id = self.gpa.dupe(u8, chat.id) catch return,
        .host_device_id = self.gpa.dupe(u8, host) catch return,
        .text = self.gpa.dupe(u8, text) catch return,
    };
    if (list.len == 0) return acquire(self, acquired, &.{}, cx);
    // Read the row's images back from the host before the row moves in.
    const engine_state = self.state.read(cx).engine.read(cx);
    const conn = engine_state.conn orelse {
        defer acquired.deinit(self.gpa);
        return failLoad(self, acquired.chat_id, acquired.id, acquired.lease_id, acquired.host_device_id, cx);
    };
    const owned = self.gpa.alloc([]u8, list.len) catch return acquired.deinit(self.gpa);
    for (list, owned) |p, *o| o.* = self.gpa.dupe(u8, p) catch @panic("OOM");
    const job: att.QueuedLoadJob = .{
        .gpa = self.gpa,
        .client = conn.client(),
        .conn = conn.retain(),
        .paths = owned,
        .target_device_id = self.gpa.dupe(u8, host) catch null,
    };
    e.edit_loading = acquired;
    e.load_task.cancel();
    e.load_task = cx.spawn(job, onQueuedLoaded) catch {
        e.edit_loading = null;
        defer acquired.deinit(self.gpa);
        return failLoad(self, acquired.chat_id, acquired.id, acquired.lease_id, acquired.host_device_id, cx);
    };
}

fn clearPending(self: *ComposerView) void {
    const e = ext(self);
    if (e.edit_pending) |p| self.gpa.free(p);
    e.edit_pending = null;
}

/// The restore failed: release the lease and say why (Rust's copy).
fn failLoad(self: *ComposerView, chat_id: []const u8, id: []const u8, lease: ?[]const u8, host: []const u8, cx: *Ctx) void {
    es.EngineState.send(self.state.read(cx).engine, cx, .FinishQueuedMessageEdit, EditParams{
        .chatId = chat_id,
        .id = id,
        .leaseId = lease,
        .action = "cancel",
        .targetDeviceId = host,
    }) catch {};
    clearPending(self);
    self.showError("Couldn't load the queued attachments or Appshot context. Check the connection and update the chat host.", cx);
}

fn onQueuedLoaded(self: *ComposerView, result: ?[]att.StageOutcome, cx: *Ctx) void {
    const e = ext(self);
    e.load_task.detach();
    e.load_task = .none;
    const acquired = e.edit_loading orelse {
        if (result) |r| att.freeOutcomes(self.gpa, r);
        return;
    };
    e.edit_loading = null;
    defer cx.notify();
    const outcomes = result orelse {
        defer acquired.deinit(self.gpa);
        return failLoad(self, acquired.chat_id, acquired.id, acquired.lease_id, acquired.host_device_id, cx);
    };
    defer att.freeOutcomes(self.gpa, outcomes);
    const io = self.io orelse {
        defer acquired.deinit(self.gpa);
        return failLoad(self, acquired.chat_id, acquired.id, acquired.lease_id, acquired.host_device_id, cx);
    };
    var staged: std.ArrayList(att.Staged) = .empty;
    for (outcomes) |*o| switch (o.*) {
        .ok => {
            const st = att.stagedFromOutcome(self.gpa, io, o) catch continue;
            staged.append(self.gpa, st) catch {
                var x = st;
                x.deinit(self.gpa, cx.app);
            };
        },
        .err => {},
    };
    acquire(self, acquired, staged.items, cx);
    staged.deinit(self.gpa);
}

/// The lease is ours and the row's attachments are loaded: displace the
/// draft (text + staged images) and load the row (takes `acquired` and the
/// `staged` items).
fn acquire(self: *ComposerView, acquired: AcquiredEdit, staged: []att.Staged, cx: *Ctx) void {
    const e = ext(self);
    clearPending(self);
    const selected_matches = if (selectedChat(self, cx)) |c| std.mem.eql(u8, c, acquired.chat_id) else false;
    if (!selected_matches or e.edit != null or e.wizard != null) {
        // Navigation or another composer action won acquisition: release now.
        defer acquired.deinit(self.gpa);
        for (staged) |*a| a.deinit(self.gpa, cx.app);
        es.EngineState.send(self.state.read(cx).engine, cx, .FinishQueuedMessageEdit, EditParams{
            .chatId = acquired.chat_id,
            .id = acquired.id,
            .leaseId = acquired.lease_id,
            .action = "cancel",
            .targetDeviceId = acquired.host_device_id,
        }) catch {};
        return;
    }
    e.edit = .{
        .id = acquired.id,
        .lease_id = acquired.lease_id,
        .base_hash = acquired.base_hash,
        .chat_id = acquired.chat_id,
        .host_device_id = acquired.host_device_id,
        .draft = self.gpa.dupe(u8, self.input.read(cx).text()) catch @panic("OOM"),
        .draft_staged = self.takeStaged(self.current_key.items),
    };
    if (staged.len > 0) {
        const list = self.stagedList(self.current_key.items);
        list.appendSlice(self.gpa, staged) catch @panic("OOM");
    }
    self.input.update(cx, TextInput.setText, .{acquired.text});
    self.gpa.free(acquired.text);
    e.renew_task.cancel();
    e.renew_task = cx.timer(renew_interval_ms * std.time.ns_per_ms, onRenew) catch .none;
    cx.notify();
}

fn onRenew(self: *ComposerView, cx: *Ctx) void {
    const e = ext(self);
    e.renew_task.detach();
    e.renew_task = .none;
    const ed = e.edit orelse return;
    es.EngineState.request(self.state.read(cx).engine, cx, ComposerView, cx.entityId(), .RenewQueuedMessageEdit, EditParams{
        .chatId = ed.chat_id,
        .id = ed.id,
        .leaseId = ed.lease_id,
        .targetDeviceId = ed.host_device_id,
    }, onRenewed) catch {};
    // A transient miss is tolerated by the 60s lease: keep beating.
    e.renew_task = cx.timer(renew_interval_ms * std.time.ns_per_ms, onRenew) catch .none;
}

fn onRenewed(self: *ComposerView, result: es.CallResult, cx: *Ctx) void {
    switch (result) {
        .ok => |v| if (!std.mem.eql(u8, str(v, "outcome") orelse "", "renewed")) {
            ext(self).renew_task.cancel();
            self.showError("Edit protection expired; review this message before sending", cx);
        },
        .err => {},
    }
}

/// `commit_queue_edit`: save the composer (text and staged images) into
/// the row; an entirely empty composer removes it.
fn commitQueueEdit(self: *ComposerView, cx: *Ctx) void {
    const text = self.gpa.dupe(u8, self.input.read(cx).text()) catch return;
    defer self.gpa.free(text);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0 and self.staged().len == 0) finishQueueEdit(self, "discard", null, cx) else finishQueueEdit(self, "commit", text, cx);
}

/// `finish_queue_edit`. A commit first uploads the staged images to the
/// chat's host, then sends their paths with the text.
fn finishQueueEdit(self: *ComposerView, action: []const u8, text: ?[]const u8, cx: *Ctx) void {
    const e = ext(self);
    if (e.edit_finishing) return;
    const ed = e.edit orelse return;
    const committing = std.mem.eql(u8, action, "commit");
    const staged = self.staged();
    if (committing and staged.len > 0) {
        const engine_state = self.state.read(cx).engine.read(cx);
        const conn = engine_state.conn orelse return self.showError("Couldn't reach the chat host; your edit is still in the editor", cx);
        const items = self.gpa.alloc(att.UploadItem, staged.len) catch return;
        const io = self.io orelse {
            self.gpa.free(items);
            return;
        };
        for (staged, items) |*a, *it| {
            var uid: [36]u8 = undefined;
            att.uuidV4(io, &uid);
            it.* = .{ .upload_id = self.gpa.dupe(u8, &uid) catch @panic("OOM"), .name = self.gpa.dupe(u8, a.name) catch @panic("OOM"), .blob = a.blob.retain() };
        }
        const job: att.UploadJob = .{
            .gpa = self.gpa,
            .client = conn.client(),
            .conn = conn.retain(),
            .items = items,
            .target_device_id = self.gpa.dupe(u8, ed.host_device_id) catch null,
        };
        e.edit_finishing = true;
        self.input.update(cx, TextInput.setReadOnly, .{true});
        if (e.commit_text) |t| self.gpa.free(t);
        e.commit_text = self.gpa.dupe(u8, text orelse "") catch null;
        e.commit_task = cx.spawn(job, onCommitUploaded) catch {
            e.edit_finishing = false;
            self.input.update(cx, TextInput.setReadOnly, .{false});
            return self.showError("Couldn't reach the chat host; your edit is still in the editor", cx);
        };
        cx.notify();
        return;
    }
    e.edit_finishing = true;
    self.input.update(cx, TextInput.setReadOnly, .{true});
    sendFinish(self, action, text, if (committing) &.{} else null, cx);
}

fn onCommitUploaded(self: *ComposerView, result: att.UploadResult, cx: *Ctx) void {
    const e = ext(self);
    defer att.freeUploadResult(self.gpa, result);
    e.commit_task.detach();
    e.commit_task = .none;
    const typed = e.commit_text orelse "";
    defer {
        if (e.commit_text) |t| self.gpa.free(t);
        e.commit_text = null;
    }
    switch (result) {
        .ok => |paths| {
            const text: []const u8 = if (std.mem.trim(u8, typed, " \t\r\n").len == 0 and paths.len > 0) att.attachment_only_text else typed;
            const borrowed = self.gpa.alloc([]const u8, paths.len) catch return;
            defer self.gpa.free(borrowed);
            for (paths, borrowed) |p, *b| b.* = p;
            sendFinish(self, "commit", text, borrowed, cx);
        },
        .err, .canceled => {
            e.edit_finishing = false;
            self.input.update(cx, TextInput.setReadOnly, .{false});
            self.showError("Couldn't reach the chat host; your edit is still in the editor", cx);
        },
    }
}

fn sendFinish(self: *ComposerView, action: []const u8, text: ?[]const u8, attachments: ?[]const []const u8, cx: *Ctx) void {
    const e = ext(self);
    const ed = e.edit orelse {
        e.edit_finishing = false;
        self.input.update(cx, TextInput.setReadOnly, .{false});
        return;
    };
    es.EngineState.request(self.state.read(cx).engine, cx, ComposerView, cx.entityId(), .FinishQueuedMessageEdit, EditParams{
        .chatId = ed.chat_id,
        .id = ed.id,
        .leaseId = ed.lease_id,
        .action = action,
        .text = text,
        .expectedTextHash = ed.base_hash,
        .attachments = attachments,
        .targetDeviceId = ed.host_device_id,
    }, onFinished) catch {
        e.edit_finishing = false;
        self.input.update(cx, TextInput.setReadOnly, .{false});
        self.showError("Couldn't reach the chat host; your edit is still in the editor", cx);
    };
    cx.notify();
}

pub fn onFinished(self: *ComposerView, result: es.CallResult, cx: *Ctx) void {
    const e = ext(self);
    e.edit_finishing = false;
    self.input.update(cx, TextInput.setReadOnly, .{false});
    defer cx.notify();
    const v = switch (result) {
        .ok => |v| v,
        .err => return self.showError("Couldn't reach the chat host; your edit is still in the editor", cx),
    };
    const outcome = str(v, "outcome") orelse "";
    for ([_][]const u8{ "committed", "cancelled", "discarded", "released" }) |o| if (std.mem.eql(u8, outcome, o)) return clearQueueEdit(self, false, cx);
    if (std.mem.eql(u8, outcome, "conflict")) return self.showError("This message changed on another device; your edit was kept locally", cx);
    if (std.mem.eql(u8, outcome, "missing")) return self.showError("The queued message was removed; your edit was kept locally", cx);
    self.showError("The edit lease changed; your text is still in the editor", cx);
}

/// Drop the edit state and restore the displaced draft; `release` also
/// cancels the lease best-effort (navigation).
fn clearQueueEdit(self: *ComposerView, release: bool, cx: *Ctx) void {
    const e = ext(self);
    var ed = e.edit orelse return;
    e.edit = null;
    e.commit_task.cancel();
    e.edit_finishing = false;
    self.input.update(cx, TextInput.setReadOnly, .{false});
    // The displaced draft's images come back (the row's go away with it).
    var row_staged = self.takeStaged(self.current_key.items);
    for (row_staged.items) |*a| a.deinit(self.gpa, cx.app);
    row_staged.deinit(self.gpa);
    if (ed.draft_staged.items.len > 0) {
        self.stagedList(self.current_key.items).appendSlice(self.gpa, ed.draft_staged.items) catch @panic("OOM");
        ed.draft_staged.clearRetainingCapacity();
    }
    defer ed.deinit(self.gpa, cx.app);
    e.renew_task.cancel();
    if (release) es.EngineState.send(self.state.read(cx).engine, cx, .FinishQueuedMessageEdit, EditParams{
        .chatId = ed.chat_id,
        .id = ed.id,
        .leaseId = ed.lease_id,
        .action = "cancel",
        .targetDeviceId = ed.host_device_id,
    }) catch {};
    self.input.update(cx, TextInput.setText, .{ed.draft});
}

// =============================================================================================
// Worktree setup handoff (`composer.rs` send: `TakeProjectActionSetup` poll)
// =============================================================================================

/// Queue a Run that creates a worktree in a project (`worktree.spaceId`):
/// its `commandId` starts the setup-action handoff poll.
pub fn queueWorktreeRun(self: *ComposerView, t: Entity(model.TranscriptStore), command: protocol.SessionCommandPayload, transfers: []const protocol.AttachmentTransfer, message_id: []const u8, cx: *Ctx) !void {
    const e = ext(self);
    const st = self.state.read(cx);
    const store = t.read(cx);
    const ws = st.workspace.read(cx);
    const local = ws.local_device_id;
    const host: ?[]const u8 = if (ws.chat(store.chat_id)) |c| (if (local != null and std.mem.eql(u8, local.?, c.deviceId)) null else c.deviceId) else null;
    try es.EngineState.request(st.engine, cx, ComposerView, cx.entityId(), .QueueCommand, protocol.params.QueueCommand{
        .chatId = store.chat_id,
        .command = command,
        .transfers = transfers,
    }, onWorktreeQueued);
    e.setup_queued.append(self.gpa, .{
        .chat_id = self.gpa.dupe(u8, store.chat_id) catch return,
        .message_id = self.gpa.dupe(u8, message_id) catch return,
        .target = if (host) |h| self.gpa.dupe(u8, h) catch null else null,
    }) catch {};
}

fn onWorktreeQueued(self: *ComposerView, result: es.CallResult, cx: *Ctx) void {
    const e = ext(self);
    if (e.setup_queued.items.len == 0) return;
    var p = e.setup_queued.orderedRemove(0);
    switch (result) {
        .err => |err| {
            log.warn("QueueCommand for {s} failed: {s}", .{ p.chat_id, err.message });
            // The transcript store's own failure path: drop the pending send.
            if (self.state.read(cx).transcript) |t| if (std.mem.eql(u8, t.read(cx).chat_id, p.chat_id)) {
                t.update(cx, model.TranscriptStore.endPendingSend, .{@as([]const u8, p.message_id)});
            };
            p.deinit(self.gpa);
        },
        .ok => |v| {
            const id = str(v, "commandId") orelse return p.deinit(self.gpa);
            p.command_id = self.gpa.dupe(u8, id) catch return p.deinit(self.gpa);
            e.setup_polls.append(self.gpa, p) catch return p.deinit(self.gpa);
            if (!e.setup_in_flight and e.setup_timer.header == null) pollSetup(self, cx);
        },
    }
}

const TakeSetupParams = struct { chatId: []const u8, commandId: []const u8, targetDeviceId: ?[]const u8 = null };

fn pollSetup(self: *ComposerView, cx: *Ctx) void {
    const e = ext(self);
    if (e.setup_polls.items.len == 0) return;
    const p = &e.setup_polls.items[0];
    es.EngineState.request(self.state.read(cx).engine, cx, ComposerView, cx.entityId(), .TakeProjectActionSetup, TakeSetupParams{
        .chatId = p.chat_id,
        .commandId = p.command_id.?,
        .targetDeviceId = p.target,
    }, onSetupPolled) catch return scheduleSetupPoll(self, cx);
    e.setup_in_flight = true;
}

fn scheduleSetupPoll(self: *ComposerView, cx: *Ctx) void {
    const e = ext(self);
    if (e.setup_polls.items.len == 0) return;
    e.setup_timer.cancel();
    e.setup_timer = cx.timer(setup_poll_ms * std.time.ns_per_ms, onSetupTimer) catch .none;
}

fn onSetupTimer(self: *ComposerView, cx: *Ctx) void {
    const e = ext(self);
    e.setup_timer.detach();
    e.setup_timer = .none;
    pollSetup(self, cx);
}

fn onSetupPolled(self: *ComposerView, result: es.CallResult, cx: *Ctx) void {
    const e = ext(self);
    e.setup_in_flight = false;
    if (e.setup_polls.items.len == 0) return;
    const p = &e.setup_polls.items[0];
    var done = false;
    switch (result) {
        .ok => |v| {
            const ready = v == .object and if (v.object.get("ready")) |r| r == .bool and r.bool else false;
            if (ready) {
                emitSetup(self, p.*, v, cx);
                done = true;
            }
        },
        // An older host: no handoff to wait for.
        .err => |err| if (std.mem.startsWith(u8, err.message, "unknown method: ")) {
            done = true;
        },
    }
    if (!done) {
        p.attempts += 1;
        if (p.attempts >= setup_poll_limit) {
            log.warn("worktree setup handoff timed out (chat {s})", .{p.chat_id});
            done = true;
        }
    }
    if (done) e.setup_polls.orderedRemove(0).deinit(self.gpa);
    if (done) pollSetup(self, cx) else scheduleSetupPoll(self, cx);
}

fn emitSetup(self: *ComposerView, p: SetupPoll, v: std.json.Value, cx: *Ctx) void {
    const e = ext(self);
    if (e.setup_event) |*a| a.deinit();
    e.setup_event = std.heap.ArenaAllocator.init(self.gpa);
    const a = e.setup_event.?.allocator();
    const run: ?SetupRun = blk: {
        const sa = v.object.get("setupAction") orelse break :blk null;
        if (sa == .null) break :blk null;
        const parsed = std.json.parseFromValueLeaky(SetupRun, a, sa, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch break :blk null;
        break :blk parsed;
    };
    const err_text: ?[]const u8 = if (str(v, "setupError")) |s| a.dupe(u8, s) catch null else null;
    cx.emit(WorktreeSetup{
        .chat_id = a.dupe(u8, p.chat_id) catch return,
        .setup_action = run,
        .setup_error = err_text,
        .target_device_id = if (p.target) |t| a.dupe(u8, t) catch null else null,
    });
}

// =============================================================================================
// Completions: `@` file mentions + provider slash commands / skills
// =============================================================================================

fn clearMention(mn: *Mention, gpa: Allocator) void {
    if (mn.arena) |a| {
        a.deinit();
        gpa.destroy(a);
    }
    mn.arena = null;
    mn.results = &.{};
}

fn resetMention(self: *ComposerView, dismissed: ?usize) void {
    const mn = &ext(self).mention;
    clearMention(mn, self.gpa);
    mn.debounce.cancel();
    mn.start = null;
    mn.query.clearRetainingCapacity();
    mn.active = 0;
    mn.loading = false;
    mn.err = null;
    mn.request +%= 1;
    mn.dismissed = dismissed;
}

fn clearCatalog(c: *Catalog, gpa: Allocator) void {
    if (c.arena) |a| {
        a.deinit();
        gpa.destroy(a);
    }
    c.arena = null;
    c.rows = &.{};
    c.commands = null;
    c.skills = null;
}

/// Which completion owns the popup right now.
pub const Mode = enum { none, slash, mention };

fn mentionToken(self: *const ComposerView, cx: anytype) ?slash.Token {
    const in = self.input.read(cx);
    if (!in.state.selected.isEmpty()) return null;
    return slash.mentionToken(in.text(), in.cursorOffset());
}

fn skillPrefs(self: *const ComposerView, cx: anytype) model.settings.SkillCompletionSettings {
    const app: *App = if (@TypeOf(cx) == *App) cx else cx.app;
    const s = model.settings_store.current(app) orelse return .{};
    const h = self.picker.read(cx).resolved(cx).harness orelse .codex;
    return s.skillCompletion(h);
}

fn trigger(self: *const ComposerView, cx: anytype) ?completions.Trigger {
    const in = self.input.read(cx);
    if (!in.state.selected.isEmpty()) return null;
    const p = skillPrefs(self, cx);
    return completions.completionTrigger(in.text(), in.cursorOffset(), p.dollar, p.separateFromSlash);
}

pub fn mode(self: *const ComposerView, cx: anytype) Mode {
    if (self.ext.wizard != null) return .none;
    if (trigger(self, cx)) |t| if (self.slash_dismissed != t.token.start) return .slash;
    if (self.ext.mention.start != null) return .mention;
    return .none;
}

/// The input changed: track the `@` token and the slash catalog.
pub fn onEdited(self: *ComposerView, cx: *Ctx) void {
    if (ext(self).wizard != null) return;
    updateMention(self, cx);
    if (trigger(self, cx)) |t| ensureCatalog(self, t, cx);
    updateControls(self, cx);
}

fn updateMention(self: *ComposerView, cx: *Ctx) void {
    const mn = &ext(self).mention;
    const tok = mentionToken(self, cx) orelse {
        if (mn.start != null) resetMention(self, null);
        return;
    };
    if (mn.dismissed == tok.start) {
        mn.start = null;
        return;
    }
    mn.dismissed = null;
    if (mn.start == tok.start and std.mem.eql(u8, mn.query.items, tok.query)) return;
    const refining = mn.start != null;
    mn.start = tok.start;
    mn.query.clearRetainingCapacity();
    mn.query.appendSlice(self.gpa, tok.query) catch {};
    mn.request +%= 1;
    if (!refining) {
        clearMention(mn, self.gpa);
        mn.active = 0;
    }
    mn.err = null;
    mn.loading = true;
    mn.debounce.cancel();
    mn.debounce = cx.timer(mention_debounce_ms * std.time.ns_per_ms, onMentionDebounce) catch .none;
}

const SearchParams = struct {
    chatId: ?[]const u8 = null,
    spaceId: ?[]const u8 = null,
    targetDeviceId: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    path: ?[]const u8 = null,
    query: ?[]const u8 = null,
    harness: ?protocol.HarnessId = null,
};

/// `completion_workspace_params`.
fn workspaceParams(self: *const ComposerView, cx: anytype) ?SearchParams {
    const ws = self.state.read(cx).workspace.read(cx);
    if (ws.selectedChatRow()) |c| return .{ .chatId = c.id, .targetDeviceId = c.deviceId, .cwd = c.cwd };
    if (ws.selectedSpaceRow()) |s| {
        var p: SearchParams = .{ .spaceId = s.id, .targetDeviceId = s.deviceId, .cwd = s.path };
        if (self.checkout_plan) |plan| if (plan == .reuse_worktree) {
            p.path = plan.reuse_worktree.path;
        };
        return p;
    }
    return null;
}

fn onMentionDebounce(self: *ComposerView, cx: *Ctx) void {
    const mn = &ext(self).mention;
    mn.debounce.detach();
    mn.debounce = .none;
    if (mn.start == null) return;
    var p = workspaceParams(self, cx) orelse {
        mn.loading = false;
        return cx.notify();
    };
    p.query = mn.query.items;
    es.EngineState.request(self.state.read(cx).engine, cx, ComposerView, cx.entityId(), .SearchFiles, p, onSearchResult) catch {
        mn.loading = false;
        mn.err = "File search requires a connection";
    };
    cx.notify();
}

pub fn onSearchResult(self: *ComposerView, result: es.CallResult, cx: *Ctx) void {
    const mn = &ext(self).mention;
    if (mn.start == null) return;
    mn.loading = false;
    defer {
        updateControls(self, cx);
        cx.notify();
    }
    switch (result) {
        .ok => |v| {
            const arena = self.gpa.create(std.heap.ArenaAllocator) catch return;
            arena.* = .init(self.gpa);
            const a = arena.allocator();
            const raw = std.json.parseFromValueLeaky([]completions.FileMatch, a, v, .{ .ignore_unknown_fields = true }) catch {
                arena.deinit();
                self.gpa.destroy(arena);
                return;
            };
            var keep: std.ArrayList(completions.FileMatch) = .empty;
            for (raw) |f| if (mentions.localPathIsSafe(std.mem.trimEnd(u8, f.path, "/"))) {
                keep.append(a, .{ .path = a.dupe(u8, f.path) catch continue, .isDir = f.isDir }) catch {};
            };
            clearMention(mn, self.gpa);
            mn.arena = arena;
            mn.results = keep.items;
            mn.active = 0;
            mn.err = null;
        },
        .err => |e| {
            clearMention(mn, self.gpa);
            mn.err = if (e.kind == error.UnknownMethod) "File search requires an updated engine" else "File search failed";
        },
    }
}

fn acceptMention(self: *ComposerView, cx: *Ctx) void {
    const mn = &ext(self).mention;
    const start = mn.start orelse return;
    if (mn.results.len == 0) return;
    const r = mn.results[@min(mn.active, mn.results.len - 1)];
    const tok = mentionToken(self, cx) orelse return;
    if (tok.start != start) return;
    const text = self.input.read(cx).text();
    const next: ?u8 = if (tok.end < text.len) text[tok.end] else null;
    const link = mentions.localFileLink(self.gpa, r.path, r.isDir) catch return;
    defer self.gpa.free(link);
    const suffix = mentions.referenceSuffix(next);
    const ins = std.mem.concat(self.gpa, u8, &.{ link, suffix.trailing }) catch return;
    defer self.gpa.free(ins);
    self.input.update(cx, TextInput.replaceRange, .{ tok.start, tok.end, ins });
    resetMention(self, null);
    updateControls(self, cx);
    cx.notify();
}

// ---- slash catalog ----

fn catalogKey(self: *const ComposerView, t: completions.Trigger, cx: anytype) u64 {
    var h = std.hash.Wyhash.init(0xca7a);
    const p = workspaceParams(self, cx);
    if (p) |w| {
        h.update(w.chatId orelse "");
        h.update(w.spaceId orelse "");
        h.update(w.targetDeviceId orelse "");
    }
    const harness = self.picker.read(cx).resolved(cx).harness;
    h.update(if (harness) |x| @tagName(x) else "");
    h.update(&.{ @intFromBool(t.skill), @intFromBool(t.include_skills), @intFromBool(t.commands_allowed), @intFromBool(selectedChat(self, cx) != null) });
    h.update(std.mem.asBytes(&self.state.read(cx).engine.read(cx).generation));
    return h.final();
}

fn ensureCatalog(self: *ComposerView, t: completions.Trigger, cx: *Ctx) void {
    const c = &ext(self).catalog;
    const key = catalogKey(self, t, cx);
    if (key == c.key and c.arena != null) return;
    clearCatalog(c, self.gpa);
    c.key = key;
    c.skill = t.skill;
    c.include_skills = t.include_skills;
    c.commands_allowed = t.commands_allowed;
    c.in_chat = selectedChat(self, cx) != null;
    c.err = null;
    c.supported = true;
    c.commands_failed = null;
    c.skills_failed = null;
    c.request +%= 1;
    const arena = self.gpa.create(std.heap.ArenaAllocator) catch return;
    arena.* = .init(self.gpa);
    c.arena = arena;
    // Zeron's own commands show at once; provider rows join when they land.
    c.rows = if (t.commands_allowed) completions.withWorkspaceCommands(arena.allocator(), &.{}, c.in_chat) catch &.{} else &.{};
    const harness = self.picker.read(cx).resolved(cx).harness orelse return;
    var p = workspaceParams(self, cx) orelse SearchParams{ .targetDeviceId = self.state.read(cx).workspace.read(cx).effectiveDeviceId() };
    p.harness = harness;
    const engine_e = self.state.read(cx).engine;
    c.pending = 0;
    c.loading = true;
    if (t.commands_allowed and !t.skill) {
        if (es.EngineState.request(engine_e, cx, ComposerView, cx.entityId(), .ListCommands, p, onCommands)) {
            c.pending += 1;
        } else |_| {}
    }
    if (es.EngineState.request(engine_e, cx, ComposerView, cx.entityId(), .ListSkills, p, onSkills)) {
        c.pending += 1;
    } else |_| {}
    if (c.pending == 0) {
        c.loading = false;
        if (!t.skill and t.commands_allowed) c.err = "Agent command discovery requires a connection";
    }
}

pub fn onCommands(self: *ComposerView, result: es.CallResult, cx: *Ctx) void {
    const c = &ext(self).catalog;
    const a = (c.arena orelse return).allocator();
    switch (result) {
        .ok => |v| {
            const list = std.json.parseFromValueLeaky([]completions.SlashCommand, a, v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch &.{};
            c.commands = list;
        },
        .err => |e| c.commands_failed = slashError(e.kind, false),
    }
    replyLanded(self, cx);
}

pub fn onSkills(self: *ComposerView, result: es.CallResult, cx: *Ctx) void {
    const c = &ext(self).catalog;
    const a = (c.arena orelse return).allocator();
    switch (result) {
        .ok => |v| {
            if (v == .null) {
                c.supported = !c.skill;
                c.skills = &.{};
            } else c.skills = std.json.parseFromValueLeaky([]completions.Skill, a, v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch &.{};
        },
        .err => |e| c.skills_failed = slashError(e.kind, true),
    }
    replyLanded(self, cx);
}

fn slashError(kind: anyerror, skill: bool) []const u8 {
    return switch (kind) {
        error.UnknownMethod => if (skill) "Skills require an updated engine on the selected device. Restart that device’s Zeron after updating." else "Commands require an updated engine on the selected device. Restart that device’s Zeron after updating.",
        error.Transport, error.Closed => "The session's device is unreachable",
        else => if (skill) "Couldn't load this agent's skills" else "Couldn't load this agent's commands",
    };
}

/// `merge_invocation_results` once every reply is in.
fn replyLanded(self: *ComposerView, cx: *Ctx) void {
    const c = &ext(self).catalog;
    if (c.pending > 0) c.pending -= 1;
    if (c.pending > 0) return;
    c.loading = false;
    const a = (c.arena orelse return).allocator();
    const cmds = c.commands orelse &.{};
    const skills = c.skills orelse &.{};
    if (c.commands_failed != null and c.skills_failed != null) {
        c.err = c.commands_failed;
    } else if (c.commands_failed) |e| {
        if (skills.len == 0) c.err = e else c.err = e;
    } else if (c.skills_failed) |e| {
        if (c.skill or cmds.len == 0) c.err = e;
    }
    var rows: []const completions.Candidate = completions.invocationCandidates(a, cmds, skills) catch &.{};
    if (!c.include_skills) {
        var keep: std.ArrayList(completions.Candidate) = .empty;
        for (rows) |r| if (r.invocation.prefix() == '/') keep.append(a, r) catch {};
        rows = keep.items;
    }
    c.rows = if (!c.skill and c.commands_allowed) completions.withWorkspaceCommands(a, rows, c.in_chat) catch rows else rows;
    self.slash_active = 0;
    updateControls(self, cx);
    cx.notify();
}

/// The filtered slash rows (indices into `catalog.rows`) for the live token.
pub fn slashRows(self: *const ComposerView, cx: anytype, out: []usize) []usize {
    const t = trigger(self, cx) orelse return out[0..0];
    if (self.slash_dismissed == t.token.start) return out[0..0];
    return completions.filter(t.token.query, self.ext.catalog.rows, out);
}

/// Keep the input's completion redirects (Up/Down/Enter/Tab/Escape) in sync.
pub fn updateControls(self: *ComposerView, cx: *Ctx) void {
    var buf: [64]usize = undefined;
    switch (mode(self, cx)) {
        .slash => {
            const n = slashRows(self, cx, &buf).len;
            if (self.slash_active >= n) self.slash_active = 0;
            self.input.update(cx, TextInput.setMentionControls, .{ true, n > 0 });
        },
        .mention => {
            const mn = &self.ext.mention;
            if (mn.active >= mn.results.len) mn.active = 0;
            self.input.update(cx, TextInput.setMentionControls, .{ true, mn.results.len > 0 });
        },
        .none => self.input.update(cx, TextInput.setMentionControls, .{ false, false }),
    }
}

pub fn navigate(self: *ComposerView, d: i8, cx: *Ctx) void {
    switch (mode(self, cx)) {
        .slash => {
            var buf: [64]usize = undefined;
            const n = slashRows(self, cx, &buf).len;
            if (n > 0) self.slash_active = @intCast(@mod(@as(isize, @intCast(self.slash_active)) + d, @as(isize, @intCast(n))));
        },
        .mention => {
            const mn = &ext(self).mention;
            const n = mn.results.len;
            if (n > 0) mn.active = @intCast(@mod(@as(isize, @intCast(mn.active)) + d, @as(isize, @intCast(n))));
        },
        .none => {},
    }
    cx.notify();
}

pub fn dismiss(self: *ComposerView, cx: *Ctx) void {
    switch (mode(self, cx)) {
        .slash => if (trigger(self, cx)) |t| {
            self.slash_dismissed = t.token.start;
        },
        .mention => resetMention(self, ext(self).mention.start),
        .none => {},
    }
    updateControls(self, cx);
    cx.notify();
}

/// Whether reference links reach the target device (`composer-references-v1`).
fn referencesSupported(self: *const ComposerView, cx: anytype) bool {
    const st = self.state.read(cx);
    const ws = st.workspace.read(cx);
    const target = (workspaceParams(self, cx) orelse return false).targetDeviceId orelse return false;
    return ws.deviceSupports(st.engine.read(cx), target, protocol.capabilities.composer_references_v1);
}

pub fn accept(self: *ComposerView, cx: *Ctx) void {
    switch (mode(self, cx)) {
        .mention => acceptMention(self, cx),
        .slash => acceptSlash(self, cx),
        .none => {},
    }
}

/// `accept_slash`: Zeron commands execute; provider rows insert their link.
pub fn acceptSlash(self: *ComposerView, cx: *Ctx) void {
    var buf: [64]usize = undefined;
    const rows = slashRows(self, cx, &buf);
    if (rows.len == 0) return;
    const cand = self.ext.catalog.rows[rows[@min(self.slash_active, rows.len - 1)]];
    const t = trigger(self, cx) orelse return;
    if (cand.workspace) |cmd| {
        // Actions consume only their trigger; the draft stays.
        self.input.update(cx, TextInput.replaceRange, .{ t.token.start, t.token.end, "" });
        self.executeWorkspaceCommand(cmd, cx);
        return;
    }
    const ins = completions.insertion(self.gpa, cand.invocation, referencesSupported(self, cx)) catch return;
    defer self.gpa.free(ins);
    self.input.update(cx, TextInput.replaceRange, .{ t.token.start, t.token.end, ins });
    updateControls(self, cx);
    cx.notify();
}

fn onSlashRow(self: *ComposerView, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Ctx) void {
    self.slash_active = ix;
    acceptSlash(self, cx);
    self.focusInput(window, cx);
}

fn onMentionRow(self: *ComposerView, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Ctx) void {
    ext(self).mention.active = ix;
    acceptMention(self, cx);
    self.focusInput(window, cx);
}

fn onPopupOut(self: *ComposerView, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Ctx) void {
    dismiss(self, cx);
}

fn popup(self: *ComposerView, card: zpui.Div) zpui.Div {
    return div().absolute().bottomFull().left0().right0().child(
        zpui.deferred(div().occlude().pb(px(6)).child(chrome.frosted(&self.theme, chrome.card_radius, chrome.menu_blur, card))).withPriority(1),
    );
}

fn note(text: []const u8, color: zpui.Hsla) zpui.Div {
    return div().px(px(12)).py(px(10)).textSize(rems(12)).textColor(color).child(text);
}

/// The completion popup over the pill (slash commands or `@` files).
pub fn renderPopup(self: *ComposerView, window: *Window, cx: *Ctx) ?zpui.Div {
    if (!self.input.read(cx).focus.isFocused(window)) return null;
    const theme = self.theme.forPopup();
    switch (mode(self, cx)) {
        .none => return null,
        .slash => {
            const c = &self.ext.catalog;
            var buf: [64]usize = undefined;
            const rows = slashRows(self, cx, &buf);
            var card = chrome.card(&theme).wFull().maxH(px(320)).flex().flexCol().overflowHidden()
                .onMouseDownOut(cx.listener(onPopupOut));
            if (c.err) |e| card = card.child(note(e, theme.danger_muted));
            if (c.loading and c.rows.len == 0) {
                card = card.child(note("Loading…", theme.text_muted));
            } else if (rows.len == 0 and c.err == null) {
                const sep = skillPrefs(self, cx).separateFromSlash;
                const msg = if (c.rows.len == 0)
                    (if (c.skill) (if (c.supported) "No skills available for this project" else "This agent does not advertise skills") else if (!sep) "No commands or skills available" else "No slash commands available in this integration")
                else if (c.skill) "No matching skills" else if (!sep) "No matching commands or skills" else "No matching commands";
                card = card.child(note(msg, theme.text_muted));
            }
            var list = div().id("slash-rows").flex().flexCol().maxH(px(300)).overflowYScroll();
            for (rows, 0..) |ri, ix| {
                if (ix >= 200) break;
                const r = c.rows[ri];
                const is_skill = r.invocation.prefix() == '$';
                const name = if (is_skill) r.name else zpui.fmt("/{s}", .{r.name});
                const desc = if (r.input_hint) |hint| (if (r.description.len == 0) zpui.fmt("<{s}>", .{hint}) else zpui.fmt("{s} · <{s}>", .{ r.description, hint })) else r.description;
                list = list.child(chrome.menuRow(&theme, .{ "slash-result", ix }, ix == self.slash_active)
                    .role(.list_box_option).ariaLabel(name).ariaSelected(ix == self.slash_active)
                    .onClick(cx.listenerWith(ix, onSlashRow))
                    .child(div().wFull().minW0().flex().itemsCenter().gap(px(8))
                    .child(chrome.icon(if (is_skill) .magic_stick_3 else .command, 16, theme.text_muted))
                    .child(div().flexNone().maxW(zpui.relative(0.55)).truncate().textSize(rems(13)).fontWeight(500).textColor(theme.text).child(name))
                    .child(div().flex1().minW0().truncate().textSize(rems(12)).textColor(theme.text_muted).child(desc))));
            }
            if (rows.len > 0) card = card.child(list);
            return popup(self, card);
        },
        .mention => {
            const mn = &self.ext.mention;
            var card = chrome.card(&theme).wFull().maxH(px(320)).flex().flexCol().overflowHidden()
                .onMouseDownOut(cx.listener(onPopupOut));
            if (mn.loading and mn.results.len == 0) {
                card = card.child(note("Searching…", theme.text_muted));
            } else if (mn.err) |e| {
                card = card.child(note(e, theme.danger_muted));
            } else if (mn.results.len == 0) {
                card = card.child(note(if (mn.query.items.len == 0) "No files available" else "No matching files", theme.text_muted));
            }
            var list = div().id("mention-rows").flex().flexCol().maxH(px(300)).overflowYScroll();
            for (mn.results, 0..) |r, ix| {
                if (ix >= 200) break;
                const path = std.mem.trimEnd(u8, r.path, "/");
                const slash_ix = std.mem.lastIndexOfScalar(u8, path, '/');
                const dir = if (slash_ix) |s| path[0..s] else "";
                const base = if (slash_ix) |s| path[s + 1 ..] else path;
                list = list.child(chrome.menuRow(&theme, .{ "file-mention-result", ix }, ix == mn.active)
                    .role(.list_box_option).ariaLabel(path).ariaSelected(ix == mn.active)
                    .onClick(cx.listenerWith(ix, onMentionRow))
                    .child(div().wFull().minW0().flex().itemsCenter().gap(px(8))
                    .child(chrome.icon(if (r.isDir) .folder else .document, 16, theme.text_muted))
                    .child(div().flexNone().maxW(zpui.relative(0.55)).truncate().textSize(rems(13)).fontWeight(500).textColor(theme.text).child(base))
                    .child(div().flex1().minW0().truncate().textSize(rems(12)).textColor(theme.text_muted).child(dir))));
            }
            if (mn.results.len > 0) card = card.child(list);
            return popup(self, card);
        },
    }
}

const testing = std.testing;

test "queue drop slots and drag offsets" {
    try testing.expectEqual(@as(usize, 0), queueDropIndex(2, 3));
    try testing.expectEqual(@as(usize, 1), queueDropIndex(4 + 36 + 1, 3));
    try testing.expectEqual(@as(usize, 2), queueDropIndex(999, 3));
    // Row 0 dragged over slot 2: it travels two slots, rows 1-2 slide up.
    try testing.expectEqual(@as(f32, 72), queueDragOffset(0, 0, 2));
    try testing.expectEqual(@as(f32, -36), queueDragOffset(1, 0, 2));
    try testing.expectEqual(@as(f32, -36), queueDragOffset(2, 0, 2));
    try testing.expectEqual(@as(f32, 0), queueDragOffset(3, 0, 2));
}
