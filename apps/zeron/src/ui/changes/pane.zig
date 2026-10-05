//! `ChangesPane`: the right-pane Changes (diff) surface — port of zeron
//! `changes.rs` `Changes` (+ the shell's `surface_chrome::toolbar` wrapper
//! and its discard confirmation dialog).
//!
//! - toolbar: scope dropdown (Working tree / Branch changes / Latest turn),
//!   `{branch} → {base ⌄}` ref selector (branch scope), discard (working
//!   tree), split / wrap toggles, collapse-all;
//! - states: preparing (spinner), clean, scoped notice, list; a watch error
//!   shows a banner while the last content stays;
//! - the diff is flattened to line rows virtualized by `zpui.list` — every
//!   file header, hunk header and line is its own row; a collapsed file's
//!   body rows are removed; folds tween over 180ms on a clipped stand-in;
//! - a frosted sticky file header follows the top file and is pushed up by
//!   the next one;
//! - syntax colors: excerpt highlights immediately, then full-document
//!   highlights from `GetCheckoutFileDiffText` when they match the patch;
//! - nowrap rows share one horizontal scroll plane per file.
//!
//! ```zig
//! const pane = try cx.newWith(ChangesPane, ChangesPane.init, .{app_state});
//! div().child(pane)                     // toolbar + content, fills its parent
//! // events: ChangesPane.OpenFile{ .path }, ChangesPane.DiscardRequested{ … }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const diff = @import("zeron_diff");
const model = @import("zeron_model");
const engine_mod = @import("zeron_engine");
const input = @import("zeron_input");
const md = @import("zeron_ui_markdown");
const ui = @import("../components/root.zig");
const dialog = @import("../components/dialog.zig");
const m = @import("model.zig");
const rows = @import("rows.zig");
const hl = @import("highlight.zig");
const store_mod = @import("store.zig");
const comment_ui = @import("comment_ui.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Task = zpui.Task;
const AnyElement = zpui.AnyElement;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = zt.Theme;
const Hsla = zpui.Hsla;
const protocol = engine_mod.protocol;
const es = model.engine_state;
const ChangesStore = store_mod.ChangesStore;
const Icon = ui.icon.Icon;
const cm = model.comments;
const ReviewCommentStore = model.ReviewCommentStore;

const log = std.log.scoped(.zeron_changes);

fn frame() Allocator {
    return zpui.window.arena_mod.frameAllocator();
}

fn nowNs(cx: anytype) u64 {
    return ui.loaders.nowNs(cx);
}

/// A History row asked for its commit (also the pin of a commit pane).
pub const CommitPin = struct { sha: []const u8, subject: []const u8 };

/// Open the post-change path in the workspace file browser.
pub const OpenFile = struct { path: []const u8 };
/// The working-tree trash was clicked (emitted alongside the pane's own
/// confirmation; a host that owns a global dialog can listen instead).
pub const DiscardRequested = struct {
    chat_id: []const u8,
    checkout_id: []const u8,
    expected_checksum: []const u8,
    target_device_id: ?[]const u8,
    file_count: usize,
};

const Parsed = struct {
    key: []u8,
    ps: diff.PatchSet,
    truncated: bool,
    additions: u32,
    deletions: u32,
    file_count: usize,
    /// Widest line per file in px (scrollable content width).
    max_text: []f32,
    /// One shared horizontal scroll plane per file.
    scroll: []zpui.ScrollHandle,

    fn deinit(self: *Parsed, gpa: Allocator) void {
        gpa.free(self.key);
        for (self.scroll) |s| s.release();
        gpa.free(self.scroll);
        gpa.free(self.max_text);
        self.ps.deinit();
    }
};

const HighlightState = enum { pending, excerpt, ready, plain };

const HighlightSlot = struct {
    state: HighlightState,
    data: ?hl.FileHighlights = null,
    fetch_started: bool = false,
};

const DiscardFlow = union(enum) {
    confirm: struct { chat_id: []u8, checkout_id: []u8, checksum: []u8, target: ?[]u8 },
    failed: []u8,
};

const PendingText = struct { file_ix: usize, key: []u8 };

/// The line the pointer is on (`HoverRow`): only one element per anchor ever
/// takes the hover — the unified row, or a split row's right column.
const HoverRow = struct { file: u32, side: cm.CommentSide, line: u32 };

/// An open comment composer (`CommentDraft`).
const CommentDraft = struct {
    editing_id: ?[]u8 = null,
    /// The composer key the note stages onto, captured when the card opened.
    key: []u8,
    path: []u8,
    /// The file's pre-rename path, carried onto an old-side citation.
    old_path: ?[]u8 = null,
    side: cm.CommentSide,
    line: u32,
    input: Entity(input.TextInput),
    sub: zpui.Subscription,

    fn citePath(self: *const CommentDraft) []const u8 {
        return if (self.side == .old) (self.old_path orelse self.path) else self.path;
    }
};

fn setDiffSplit(v: bool, s: *model.UiSettings, _: Allocator) void {
    s.diffSplit = v;
}

fn setDiffWrap(v: bool, s: *model.UiSettings, _: Allocator) void {
    s.diffWrap = v;
}

const RefMenu = struct {
    search: Entity(input.TextInput),
    active: usize = 0,
    focus: zpui.FocusHandle,
    sub: zpui.Subscription,
};

pub const ChangesPane = struct {
    gpa: Allocator,
    state: Entity(model.AppState),
    store: Entity(ChangesStore),
    subs: zpui.Subscriptions = .{},
    focus: zpui.FocusHandle,

    scope: m.DiffScope = .working_tree,
    mode: m.DiffMode = .unified,
    wrap_lines: bool = false,
    /// Draw the 38px toolbar (false when a host renders `toolbar()` itself).
    show_toolbar: bool = true,
    /// Show the discard confirmation here (false when a host owns it).
    own_discard_dialog: bool = true,

    parsed: ?Parsed = null,
    flat: m.Flattened = .{},
    list: zpui.ListState,
    folds: std.StringHashMapUnmanaged(m.FileFold) = .empty,
    highlights: std.AutoHashMapUnmanaged(usize, HighlightSlot) = .empty,
    fold_settle: Task(void) = .none,

    // Branch scope.
    base_ref: ?[]u8 = null,
    branches: std.ArrayList([]u8) = .empty,
    branches_for: ?[]u8 = null,
    // One-shot scoped capture (Branch / Latest turn / Commit).
    scoped: ?json.Parsed(protocol.CheckoutDiff) = null,
    scoped_for: ?[]u8 = null,
    scoped_inflight: ?[]u8 = null,
    scoped_error: ?[]u8 = null,
    commit: ?struct { sha: []u8, subject: []u8 } = null,

    scope_menu_open: bool = false,
    ref_menu: ?RefMenu = null,
    discard: ?DiscardFlow = null,
    discard_inflight: bool = false,
    /// In-flight `GetCheckoutFileDiffText` calls (FIFO with their replies).
    pending_text: std.ArrayList(PendingText) = .empty,

    // Review comments (`comments.rs` / `comment_ui.rs`).
    draft: ?CommentDraft = null,
    hover: ?HoverRow = null,
    comment_key: u64 = 0,

    pub const Events = .{ OpenFile, DiscardRequested };

    pub fn init(state: Entity(model.AppState), cx: *Context(ChangesPane)) !ChangesPane {
        const s = state.read(cx);
        const store = try cx.newWith(ChangesStore, ChangesStore.init, .{s.engine});
        var self: ChangesPane = .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .store = store,
            .focus = cx.focusHandle(),
            .list = zpui.ListState.init(cx.gpa(), 0, .top, px(1024)),
        };
        if (model.settings_store.current(cx.app)) |settings| {
            self.mode = if (settings.diffSplit) .split else .unified;
            self.wrap_lines = settings.diffWrap;
        }
        try self.subs.add(cx.gpa(), try cx.observe(state, onStateChanged));
        try self.subs.add(cx.gpa(), try cx.observe(s.workspace, onWorkspaceChanged));
        try self.subs.add(cx.gpa(), try cx.subscribe(store, onDiffs));
        try self.subs.add(cx.gpa(), try cx.observe(s.review_comments, onCommentsChanged));
        return self;
    }

    /// A pane pinned to one commit's diff (a History row click).
    pub fn initCommit(state: Entity(model.AppState), pin: CommitPin, cx: *Context(ChangesPane)) !ChangesPane {
        var self = try init(state, cx);
        self.scope = .commit;
        self.commit = .{ .sha = try cx.gpa().dupe(u8, pin.sha), .subject = try cx.gpa().dupe(u8, pin.subject) };
        return self;
    }

    pub fn deinit(self: *ChangesPane, app: *App) void {
        self.subs.deinit(self.gpa);
        self.fold_settle.cancel();
        self.clearParsed();
        self.flat.deinit(self.gpa);
        self.folds.deinit(self.gpa);
        self.highlights.deinit(self.gpa);
        self.list.release();
        self.closeRefMenu(app);
        self.clearBranches();
        if (self.base_ref) |b| self.gpa.free(b);
        if (self.branches_for) |b| self.gpa.free(b);
        if (self.scoped) |sc| sc.deinit();
        freeOpt(self.gpa, &self.scoped_for);
        freeOpt(self.gpa, &self.scoped_inflight);
        freeOpt(self.gpa, &self.scoped_error);
        if (self.commit) |c| {
            self.gpa.free(c.sha);
            self.gpa.free(c.subject);
        }
        self.clearDiscard();
        self.dropDraft(app);
        for (self.pending_text.items) |p| self.gpa.free(p.key);
        self.pending_text.deinit(self.gpa);
        self.focus.release(app);
        self.store.release(app);
        self.state.release(app);
    }

    // ---- public API -----------------------------------------------------------------

    /// The surface-tab title: the pinned commit's subject (short sha when
    /// empty), else the scope label.
    pub fn tabTitle(self: *const ChangesPane) []const u8 {
        if (self.commit) |c| {
            const subject = std.mem.trim(u8, c.subject, " \t\r\n");
            if (subject.len > 0) return subject;
            return c.sha[0..@min(7, c.sha.len)];
        }
        return self.scope.label();
    }

    pub fn tabIcon(_: *const ChangesPane) Icon {
        return .list;
    }

    /// The host's hook for a freshly mounted tab (idempotent).
    pub fn ensureContent(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        self.sync(cx);
    }

    pub fn setScope(self: *ChangesPane, scope: m.DiffScope, cx: *Context(ChangesPane)) void {
        if (self.scope != scope) {
            self.scope = scope;
            self.resetHorizontal();
            self.sync(cx);
        }
        cx.notify();
    }

    // ---- model plumbing -------------------------------------------------------------

    fn onStateChanged(self: *ChangesPane, _: Entity(model.AppState), cx: *Context(ChangesPane)) void {
        self.sync(cx);
    }

    fn onWorkspaceChanged(self: *ChangesPane, _: Entity(model.WorkspaceStore), cx: *Context(ChangesPane)) void {
        self.sync(cx);
    }

    fn onDiffs(self: *ChangesPane, _: Entity(ChangesStore), _: *const store_mod.DiffsChanged, cx: *Context(ChangesPane)) void {
        self.sync(cx);
        cx.notify();
    }

    fn selectedChat(self: *const ChangesPane, cx: anytype) ?*const protocol.Chat {
        return self.state.read(cx).workspace.read(cx).selectedChatRow();
    }

    /// The selected chat's host device when it is not the connected engine.
    fn desiredTarget(self: *const ChangesPane, cx: anytype) ?[]const u8 {
        const ws = self.state.read(cx).workspace.read(cx);
        const chat = ws.selectedChatRow() orelse return null;
        if (ws.local_device_id) |local| if (std.mem.eql(u8, local, chat.deviceId)) return null;
        if (ws.local_device_id == null) return null;
        return chat.deviceId;
    }

    fn resolved(self: *const ChangesPane, cx: anytype) ?*const protocol.CheckoutDiff {
        const chat = self.selectedChat(cx) orelse return null;
        return m.resolveDiff(self.store.read(cx).diffs(), chat);
    }

    fn scopedCwd(self: *const ChangesPane, cx: anytype) ?[]const u8 {
        if (self.resolved(cx)) |d| return d.cwd;
        const chat = self.selectedChat(cx) orelse return null;
        return chat.cwd;
    }

    /// The diff the pane currently displays.
    fn activeDiff(self: *const ChangesPane, cx: anytype) ?*const protocol.CheckoutDiff {
        return switch (self.scope) {
            .working_tree => self.resolved(cx),
            .branch, .latest_turn, .commit => if (self.scoped) |*sc| &sc.value else null,
            .history => null,
        };
    }

    fn scopeKey(self: *const ChangesPane, a: Allocator) []const u8 {
        return switch (self.scope) {
            .working_tree => "wt",
            .branch => std.fmt.allocPrint(a, "br:{s}", .{self.base_ref orelse ""}) catch "br",
            .latest_turn => "turn",
            .history => "history",
            .commit => std.fmt.allocPrint(a, "commit:{s}", .{if (self.commit) |c| c.sha else ""}) catch "commit",
        };
    }

    fn parseKey(self: *const ChangesPane, a: Allocator, d: *const protocol.CheckoutDiff) []const u8 {
        return std.fmt.allocPrint(a, "{s}:{s}:{s}", .{ d.checkoutId, d.checksum, self.scopeKey(a) }) catch "";
    }

    /// Reconcile parsed content with the active diff.
    pub fn sync(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        self.store.update(cx, ChangesStore.setTarget, .{self.desiredTarget(cx)});
        if (self.scope == .history) return;
        if (self.scope != .commit) self.ensureBranches(cx);
        self.ensureScoped(cx);
        const d = self.activeDiff(cx) orelse {
            if (self.parsed != null) {
                self.clearParsed();
                self.flat.deinit(self.gpa);
                self.flat = .{};
                self.list.reset(0);
                self.folds.clearRetainingCapacity();
                cx.notify();
            }
            return;
        };
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const key = self.parseKey(arena.allocator(), d);
        if (self.parsed) |p| if (std.mem.eql(u8, p.key, key)) {
            self.syncCommentRows(cx);
            return;
        };
        self.reparse(d, key, cx) catch |err| log.warn("cannot parse diff: {t}", .{err});
        cx.notify();
    }

    fn reparse(self: *ChangesPane, d: *const protocol.CheckoutDiff, key: []const u8, cx: *Context(ChangesPane)) !void {
        var ps = try diff.parsePatch(self.gpa, d.patch);
        errdefer ps.deinit();
        const n = ps.files.len;
        const max_text = try self.gpa.alloc(f32, n);
        errdefer self.gpa.free(max_text);
        const scroll = try self.gpa.alloc(zpui.ScrollHandle, n);
        for (ps.files, 0..) |*f, i| {
            // Geist Mono 12px advances 0.6em = 7.2px per column.
            max_text[i] = @as(f32, @floatFromInt(m.maxColumns(f))) * 7.2 + 2;
            scroll[i] = zpui.ScrollHandle.init(self.gpa);
        }
        const key_owned = try self.gpa.dupe(u8, key);
        self.clearParsed();
        self.folds.clearRetainingCapacity();
        self.parsed = .{
            .key = key_owned,
            .ps = ps,
            .truncated = d.truncated,
            .additions = d.additions,
            .deletions = d.deletions,
            .file_count = if (d.files.len > 0) d.files.len else n,
            .max_text = max_text,
            .scroll = scroll,
        };
        self.hover = null;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const staged = self.stagedComments(arena.allocator(), cx);
        const draft = self.draftAnchor();
        self.flat.deinit(self.gpa);
        self.flat = try m.flattenRowsWith(self.gpa, ps.files, staged, draft, self.mode, &.{});
        self.comment_key = m.commentStateKey(staged, draft);
        self.list.resetWithUniformHeight(self.flat.rows.items.len, px(m.line_height));
    }

    fn clearParsed(self: *ChangesPane) void {
        var it = self.highlights.valueIterator();
        while (it.next()) |s| if (s.data) |*h| h.deinit(self.gpa);
        self.highlights.clearRetainingCapacity();
        if (self.parsed) |*p| p.deinit(self.gpa);
        self.parsed = null;
    }

    fn files(self: *const ChangesPane) []diff.FileDiff {
        return if (self.parsed) |p| p.ps.files else &.{};
    }

    pub fn foldOf(self: *const ChangesPane, file_ix: usize) m.FileFold {
        const fs = self.files();
        if (file_ix >= fs.len) return .{};
        return self.folds.get(fs[file_ix].path) orelse .{};
    }

    pub fn foldPtr(self: *ChangesPane, file_ix: usize) ?*m.FileFold {
        const fs = self.files();
        if (file_ix >= fs.len) return null;
        const gop = self.folds.getOrPut(self.gpa, fs[file_ix].path) catch return null;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    fn collapsedMask(self: *const ChangesPane, a: Allocator) []bool {
        const fs = self.files();
        const mask = a.alloc(bool, fs.len) catch return &.{};
        for (fs, 0..) |f, i| mask[i] = if (self.folds.get(f.path)) |fold| fold.collapsed else false;
        return mask;
    }

    fn resetHorizontal(self: *ChangesPane) void {
        if (self.parsed) |p| for (p.scroll) |s| s.setOffset(.{ .x = 0, .y = 0 });
    }

    // ---- branches + scoped captures ---------------------------------------------------

    fn clearBranches(self: *ChangesPane) void {
        for (self.branches.items) |b| self.gpa.free(b);
        self.branches.deinit(self.gpa);
        self.branches = .empty;
    }

    fn engine(self: *const ChangesPane, cx: anytype) Entity(model.EngineState) {
        return self.state.read(cx).engine;
    }

    const ListBranchesParams = struct { repoPath: []const u8, targetDeviceId: ?[]const u8 = null };

    fn ensureBranches(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        const cwd = self.scopedCwd(cx) orelse return;
        const target = self.desiredTarget(cx);
        const key = std.fmt.allocPrint(self.gpa, "{s}:{s}", .{ target orelse "local", cwd }) catch return;
        if (self.branches_for) |b| if (std.mem.eql(u8, b, key)) {
            self.gpa.free(key);
            return;
        };
        if (self.engine(cx).read(cx).conn == null) {
            self.gpa.free(key);
            return;
        }
        freeOpt(self.gpa, &self.branches_for);
        self.branches_for = key;
        model.EngineState.request(self.engine(cx), cx, ChangesPane, cx.entityId(), .ListBranches, ListBranchesParams{ .repoPath = cwd, .targetDeviceId = target }, onBranches) catch {
            freeOpt(self.gpa, &self.branches_for);
        };
    }

    fn onBranches(self: *ChangesPane, result: es.CallResult, cx: *Context(ChangesPane)) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const list = result.decodeAs([]const []const u8, arena.allocator()) catch {
            freeOpt(self.gpa, &self.branches_for);
            return;
        };
        self.clearBranches();
        for (list) |b| self.branches.append(self.gpa, self.gpa.dupe(u8, b) catch continue) catch {};
        const keep = if (self.base_ref) |b| for (self.branches.items) |x| {
            if (std.mem.eql(u8, x, b)) break true;
        } else false else false;
        if (!keep) {
            const current = if (self.selectedChat(cx)) |c| c.branch else null;
            var view: std.ArrayList([]const u8) = .empty;
            defer view.deinit(self.gpa);
            for (self.branches.items) |b| view.append(self.gpa, b) catch {};
            const next = m.defaultBaseRef(view.items, current);
            const owned = if (next) |n| self.gpa.dupe(u8, n) catch null else null;
            if (self.base_ref) |b| self.gpa.free(b);
            self.base_ref = owned;
        }
        self.sync(cx);
        cx.notify();
    }

    const GetCheckoutDiffParams = struct {
        cwd: []const u8,
        mode: []const u8,
        chatId: []const u8,
        baseRef: ?[]const u8 = null,
        commitSha: ?[]const u8 = null,
        targetDeviceId: ?[]const u8 = null,
    };

    fn ensureScoped(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        if (self.scope == .working_tree or self.scope == .history) {
            freeOpt(self.gpa, &self.scoped_inflight);
            return;
        }
        const chat = self.selectedChat(cx) orelse return;
        const cwd = self.scopedCwd(cx) orelse return;
        const base: ?[]const u8 = if (self.scope == .branch) (self.base_ref orelse return) else null;
        const sha: ?[]const u8 = if (self.scope == .commit) (if (self.commit) |c| c.sha else return) else null;
        const target = self.desiredTarget(cx);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const context = std.fmt.allocPrint(a, "{s}|{s}|{s}|{s}|{s}|{s}", .{ target orelse "local", chat.id, cwd, self.scope.mode(), base orelse "", sha orelse "" }) catch return;
        const watch_sum = if (self.resolved(cx)) |d| d.checksum else "";
        const key = std.fmt.allocPrint(a, "{s}|{s}", .{ context, watch_sum }) catch return;
        if (eqlOpt(self.scoped_for, key) or eqlOpt(self.scoped_inflight, key)) return;
        const prefix = std.fmt.allocPrint(a, "{s}|", .{context}) catch return;
        if (self.scoped_for == null or !std.mem.startsWith(u8, self.scoped_for.?, prefix)) {
            // Context change: drop stale content so the pane shows the spinner.
            if (self.scoped) |sc| sc.deinit();
            self.scoped = null;
            freeOpt(self.gpa, &self.scoped_error);
        }
        if (self.engine(cx).read(cx).conn == null) return;
        freeOpt(self.gpa, &self.scoped_inflight);
        self.scoped_inflight = self.gpa.dupe(u8, key) catch return;
        model.EngineState.request(self.engine(cx), cx, ChangesPane, cx.entityId(), .GetCheckoutDiff, GetCheckoutDiffParams{
            .cwd = cwd,
            .mode = self.scope.mode(),
            .chatId = chat.id,
            .baseRef = base,
            .commitSha = sha,
            .targetDeviceId = target,
        }, onScoped) catch {
            freeOpt(self.gpa, &self.scoped_inflight);
        };
    }

    fn onScoped(self: *ChangesPane, result: es.CallResult, cx: *Context(ChangesPane)) void {
        const key = self.scoped_inflight orelse return;
        self.scoped_inflight = null;
        if (self.scoped) |sc| sc.deinit();
        self.scoped = null;
        freeOpt(self.gpa, &self.scoped_error);
        switch (result) {
            .ok => |v| {
                if (json.parseFromValue(protocol.CheckoutDiff, self.gpa, v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |parsed| {
                    self.scoped = parsed;
                } else |err| {
                    self.scoped_error = std.fmt.allocPrint(self.gpa, "{t}", .{err}) catch null;
                }
            },
            .err => |e| self.scoped_error = self.gpa.dupe(u8, e.message) catch null,
        }
        freeOpt(self.gpa, &self.scoped_for);
        self.scoped_for = key;
        self.sync(cx);
        cx.notify();
    }

    // ---- highlights -----------------------------------------------------------------

    const FileTextParams = struct {
        checkoutId: []const u8,
        cwd: []const u8,
        path: []const u8,
        mode: []const u8,
        baseRef: ?[]const u8 = null,
        chatId: ?[]const u8 = null,
        commitSha: ?[]const u8 = null,
        diffChecksum: []const u8,
        targetDeviceId: ?[]const u8 = null,
    };

    /// Highlights for file `ix` (excerpt immediately; a full-text fetch is
    /// started once and replaces them when it verifies).
    fn highlightFor(self: *ChangesPane, ix: usize, cx: *Context(ChangesPane)) ?*const hl.FileHighlights {
        const fs = self.files();
        if (ix >= fs.len) return null;
        const gop = self.highlights.getOrPut(self.gpa, ix) catch return null;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .state = .plain };
            if (hl.supported(fs[ix].path)) {
                if (hl.excerpt(self.gpa, &fs[ix])) |h| {
                    gop.value_ptr.* = .{ .state = .excerpt, .data = h };
                }
                self.requestFullText(ix, cx);
            }
        }
        const slot = self.highlights.getPtr(ix).?;
        return if (slot.data) |*d| d else null;
    }

    fn requestFullText(self: *ChangesPane, ix: usize, cx: *Context(ChangesPane)) void {
        const d = self.activeDiff(cx) orelse return;
        if (self.engine(cx).read(cx).conn == null) return;
        const fs = self.files();
        const chat = self.selectedChat(cx);
        const file_ix = ix;
        const params: FileTextParams = .{
            .checkoutId = d.checkoutId,
            .cwd = d.cwd,
            .path = fs[ix].path,
            .mode = self.scope.mode(),
            .baseRef = if (self.scope == .branch) self.base_ref else null,
            .chatId = if (chat) |c| c.id else null,
            .commitSha = if (self.scope == .commit) (if (self.commit) |c| c.sha else null) else null,
            .diffChecksum = d.checksum,
            .targetDeviceId = self.desiredTarget(cx),
        };
        const key = self.gpa.dupe(u8, if (self.parsed) |p| p.key else "") catch return;
        const Reply = struct {
            fn on(pane: *ChangesPane, result: es.CallResult, c: *Context(ChangesPane)) void {
                pane.onFileText(result, c);
            }
        };
        self.pending_text.append(self.gpa, .{ .file_ix = file_ix, .key = key }) catch {
            self.gpa.free(key);
            return;
        };
        model.EngineState.request(self.engine(cx), cx, ChangesPane, cx.entityId(), .GetCheckoutFileDiffText, params, Reply.on) catch {
            const p = self.pending_text.pop().?;
            self.gpa.free(p.key);
        };
    }

    fn onFileText(self: *ChangesPane, result: es.CallResult, cx: *Context(ChangesPane)) void {
        if (self.pending_text.items.len == 0) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        // Replies carry no file identity: the one whose sources verify against
        // a pending file's patch is that file's (others stay pending).
        const reply = result.decodeAs(protocol.CheckoutFileDiffText, arena.allocator()) catch {
            self.gpa.free(self.pending_text.orderedRemove(0).key);
            return;
        };
        const parsed = self.parsed orelse return;
        const fs = self.files();
        var matched: ?usize = null;
        for (self.pending_text.items, 0..) |p, i| {
            if (!std.mem.eql(u8, parsed.key, p.key) or p.file_ix >= fs.len) continue;
            if (reply.stale or reply.binary or reply.truncated) break;
            var h = hl.full(self.gpa, &fs[p.file_ix], reply.oldText, reply.newText) orelse continue;
            if (self.highlights.getPtr(p.file_ix)) |slot| {
                if (slot.data) |*old| old.deinit(self.gpa);
                slot.* = .{ .state = .ready, .data = h, .fetch_started = true };
                cx.notify();
            } else h.deinit(self.gpa);
            matched = i;
            break;
        }
        self.gpa.free(self.pending_text.orderedRemove(matched orelse 0).key);
    }

    // ---- folds ----------------------------------------------------------------------

    fn bodyFor(self: *ChangesPane, a: Allocator, file_ix: usize, cx: anytype) []const m.DiffRow {
        var out: std.ArrayList(m.DiffRow) = .empty;
        const file = &self.files()[file_ix];
        const fc = self.fileComments(a, cx, file.path);
        m.bodyRowsWith(a, &out, @intCast(file_ix), file, fc, self.draftAnchorIn(file.path), self.mode) catch return &.{};
        return out.items;
    }

    fn replaceBody(self: *ChangesPane, file_ix: usize, body: []const m.DiffRow) void {
        const r = (m.replaceFileBody(self.gpa, &self.flat, file_ix, body) catch return) orelse return;
        self.list.splice(.{ .start = r.start, .end = r.end }, r.count);
    }

    pub fn toggleFold(self: *ChangesPane, file_ix: usize, cx: *Context(ChangesPane)) void {
        if (file_ix >= self.files().len) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const fold = self.foldPtr(file_ix) orelse return;
        if (self.wrap_lines) {
            fold.collapsed = !fold.collapsed;
            fold.toggled_at_ns = null;
            self.replaceBody(file_ix, if (fold.collapsed) &.{} else self.bodyFor(a, file_ix, cx));
            cx.notify();
            return;
        }
        const path = self.files()[file_ix].path;
        const expanded = m.bodyHeightWith(a, &self.files()[file_ix], self.fileComments(a, cx, path), self.draftAnchorIn(path), self.mode);
        const was = fold.collapsed;
        fold.from = if (was) 0 else expanded;
        fold.to = if (was) expanded else 0;
        fold.collapsed = !was;
        fold.epoch += 1;
        fold.toggled_at_ns = nowNs(cx);
        self.replaceBody(file_ix, &.{.{ .folding_body = @intCast(file_ix) }});
        self.ensureFoldSettle(cx);
        cx.notify();
    }

    fn ensureFoldSettle(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        if (self.fold_settle.header != null) return;
        self.fold_settle = cx.timer(m.fold_tween_window_ms * std.time.ns_per_ms, onFoldSettle) catch return;
    }

    fn onFoldSettle(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        self.fold_settle.detach();
        if (self.settleFolds(cx)) self.ensureFoldSettle(cx);
    }

    /// Swap settled stand-ins for steady rows; true while some still tween.
    fn settleFolds(self: *ChangesPane, cx: *Context(ChangesPane)) bool {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const now = nowNs(cx);
        var pending = false;
        var ix = self.flat.ranges.items.len;
        while (ix > 0) {
            ix -= 1;
            const r = self.flat.ranges.items[ix];
            if (r.start + 1 >= self.flat.rows.items.len) continue;
            const row = self.flat.rows.items[r.start + 1];
            if (row != .folding_body or r.start + 1 >= r.end) continue;
            const fold = self.foldOf(ix);
            if (fold.animating(now)) {
                pending = true;
                continue;
            }
            self.replaceBody(ix, if (fold.collapsed) &.{} else self.bodyFor(arena.allocator(), ix, cx));
        }
        cx.notify();
        return pending;
    }

    fn allCollapsed(self: *const ChangesPane) bool {
        const fs = self.files();
        if (fs.len == 0) return false;
        for (fs) |f| if (!(if (self.folds.get(f.path)) |fold| fold.collapsed else false)) return false;
        return true;
    }

    fn foldAllLabel(self: *const ChangesPane) []const u8 {
        return if (self.allCollapsed()) "Expand all files" else "Collapse all files";
    }

    pub fn toggleCollapseAll(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        if (self.parsed == null) return;
        const collapse = !self.allCollapsed();
        for (0..self.files().len) |i| if (self.foldPtr(i)) |f| {
            f.collapsed = collapse;
            f.toggled_at_ns = null;
        };
        self.reflatten(false, cx);
    }

    pub fn toggleMode(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        self.mode = self.mode.toggled();
        self.resetHorizontal();
        _ = model.settings_store.update(cx.app, .immediate, self.mode == .split, setDiffSplit);
        self.reflatten(true, cx);
    }

    pub fn toggleWrap(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        self.wrap_lines = !self.wrap_lines;
        self.resetHorizontal();
        _ = model.settings_store.update(cx.app, .immediate, self.wrap_lines, setDiffWrap);
        for (0..self.files().len) |i| if (self.foldPtr(i)) |f| {
            f.toggled_at_ns = null;
        };
        self.reflatten(true, cx);
    }

    pub fn reflatten(self: *ChangesPane, keep_anchor: bool, cx: *Context(ChangesPane)) void {
        if (self.parsed == null) {
            cx.notify();
            return;
        }
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const top = self.list.logicalScrollTop().item_ix;
        var anchor: ?usize = null;
        for (self.flat.ranges.items, 0..) |r, i| if (r.contains(top)) {
            anchor = i;
        };
        const staged = self.stagedComments(arena.allocator(), cx);
        const draft = self.draftAnchor();
        const next = m.flattenRowsWith(self.gpa, self.files(), staged, draft, self.mode, self.collapsedMask(arena.allocator())) catch return;
        self.flat.deinit(self.gpa);
        self.flat = next;
        self.comment_key = m.commentStateKey(staged, draft);
        self.list.resetWithUniformHeight(self.flat.rows.items.len, px(m.line_height));
        if (keep_anchor) if (anchor) |a| if (a < self.flat.ranges.items.len) self.list.scrollToRevealItem(self.flat.ranges.items[a].start);
        cx.notify();
    }

    // ---- review comments ------------------------------------------------------------

    fn comments(self: *const ChangesPane, cx: anytype) Entity(ReviewCommentStore) {
        return self.state.read(cx).review_comments;
    }

    fn composerKey(self: *const ChangesPane, cx: anytype) []const u8 {
        return self.comments(cx).read(cx).composerKey();
    }

    /// The selected chat's staged set, minus the comment being edited (its
    /// draft stands in for it). Shallow copies in `a`.
    fn stagedComments(self: *const ChangesPane, a: Allocator, cx: anytype) []cm.ReviewComment {
        const store = self.comments(cx).read(cx);
        var out: std.ArrayList(cm.ReviewComment) = .empty;
        const editing: ?[]const u8 = if (self.draft) |d| d.editing_id else null;
        for (store.comments(store.composerKey())) |c| {
            if (editing) |id| if (std.mem.eql(u8, id, c.id)) continue;
            out.append(a, c) catch break;
        }
        return out.items;
    }

    /// `comments_for(path)`: this file's diff comments, in staged order.
    fn fileComments(self: *const ChangesPane, a: Allocator, cx: anytype, path: []const u8) []cm.ReviewComment {
        return m.commentsFor(a, self.stagedComments(a, cx), path) catch &.{};
    }

    fn draftAnchor(self: *const ChangesPane) ?m.DraftAnchor {
        const d = self.draft orelse return null;
        return .{ .path = d.path, .anchor = .{ .side = d.side, .line = d.line } };
    }

    fn draftAnchorIn(self: *const ChangesPane, path: []const u8) ?cm.DiffAnchor {
        const d = self.draft orelse return null;
        if (!std.mem.eql(u8, d.path, path)) return null;
        return .{ .side = d.side, .line = d.line };
    }

    fn onCommentsChanged(self: *ChangesPane, _: Entity(ReviewCommentStore), cx: *Context(ChangesPane)) void {
        self.discardStaleDraft(cx);
        self.syncCommentRows(cx);
    }

    /// A draft belongs to the checkout it was opened over: chat navigation
    /// drops it rather than letting it follow the user across.
    fn discardStaleDraft(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        const d = self.draft orelse return;
        if (std.mem.eql(u8, d.key, self.composerKey(cx))) return;
        self.dropDraft(cx.app);
        cx.notify();
    }

    fn dropDraft(self: *ChangesPane, app: *App) void {
        var d = self.draft orelse return;
        self.draft = null;
        d.sub.deinit();
        d.input.release(app);
        if (d.editing_id) |id| self.gpa.free(id);
        if (d.old_path) |o| self.gpa.free(o);
        self.gpa.free(d.key);
        self.gpa.free(d.path);
    }

    /// `sync_comment_rows`: re-splice every steady file body whose cards changed.
    pub fn syncCommentRows(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        if (self.parsed == null) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const staged = self.stagedComments(a, cx);
        const key = m.commentStateKey(staged, self.draftAnchor());
        if (key == self.comment_key) return;
        self.comment_key = key;
        const fs = self.files();
        var ix = @min(self.flat.ranges.items.len, fs.len);
        while (ix > 0) {
            ix -= 1;
            // A mid-tween stand-in is the settle sweep's to replace.
            if (self.foldOf(ix).collapsed) continue;
            const r = self.flat.ranges.items[ix];
            if (r.start + 1 < self.flat.rows.items.len and r.start + 1 < r.end and self.flat.rows.items[r.start + 1] == .folding_body) continue;
            self.replaceBody(ix, self.bodyFor(a, ix, cx));
        }
        cx.notify();
    }

    fn setHover(self: *ChangesPane, h: ?HoverRow, cx: *Context(ChangesPane)) void {
        if (std.meta.eql(h, self.hover)) return;
        self.hover = h;
        cx.notify();
    }

    fn hovering(self: *const ChangesPane, h: HoverRow) bool {
        return if (self.hover) |cur| std.meta.eql(cur, h) else false;
    }

    fn onLineMove(self: *ChangesPane, h: HoverRow, _: *const zpui.input.MouseMoveEvent, _: *Window, cx: *Context(ChangesPane)) void {
        self.setHover(h, cx);
    }

    fn onLineHover(self: *ChangesPane, h: HoverRow, hovered: *const bool, _: *Window, cx: *Context(ChangesPane)) void {
        if (!hovered.* and self.hovering(h)) {
            self.hover = null;
            cx.notify();
        }
    }

    fn onAdderClick(self: *ChangesPane, h: HoverRow, window: *Window, cx: *Context(ChangesPane)) void {
        const fs = self.files();
        if (h.file >= fs.len) return;
        self.openDraft(fs[h.file].path, h.side, h.line, window, cx);
    }

    /// `open_draft`: a fresh composer card under the line.
    pub fn openDraft(self: *ChangesPane, path: []const u8, side: cm.CommentSide, line: u32, window: ?*Window, cx: *Context(ChangesPane)) void {
        const theme = ui.theme.get(cx);
        const text_input = cx.newWith(input.TextInput, input.TextInput.init, .{input.Options{
            .placeholder = "Request a change\u{2026}",
            .colors = .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
        }}) catch return;
        const sub = cx.subscribe(text_input, onDraftInput) catch {
            text_input.release(cx);
            return;
        };
        var old_path: ?[]u8 = null;
        for (self.files()) |f| if (std.mem.eql(u8, f.path, path)) {
            if (f.old_path) |o| old_path = self.gpa.dupe(u8, o) catch null;
            break;
        };
        const key = self.gpa.dupe(u8, self.composerKey(cx)) catch return;
        const owned_path = self.gpa.dupe(u8, path) catch {
            self.gpa.free(key);
            return;
        };
        self.dropDraft(cx.app);
        self.draft = .{ .key = key, .path = owned_path, .old_path = old_path, .side = side, .line = line, .input = text_input, .sub = sub };
        if (window) |w| w.focus(text_input.read(cx).focusHandle());
        self.syncCommentRows(cx);
        cx.notify();
    }

    /// `edit_comment`: reopen a staged diff comment's card with its body.
    pub fn editComment(self: *ChangesPane, id: []const u8, window: *Window, cx: *Context(ChangesPane)) void {
        self.editCommentIn(id, window, cx);
    }

    pub fn editCommentIn(self: *ChangesPane, id: []const u8, window: ?*Window, cx: *Context(ChangesPane)) void {
        const store = self.comments(cx).read(cx);
        const c = store.find(store.composerKey(), id) orelse return;
        if (c.isFile()) return;
        const anchor = c.diffAnchor() orelse return;
        const path = self.gpa.dupe(u8, c.path) catch return;
        defer self.gpa.free(path);
        const body = self.gpa.dupe(u8, c.body) catch return;
        defer self.gpa.free(body);
        const old_path: ?[]u8 = if (c.source.diff.old_path) |o| self.gpa.dupe(u8, o) catch null else null;
        const owned_id = self.gpa.dupe(u8, c.id) catch return;
        self.openDraft(path, anchor.side, anchor.line, window, cx);
        const d = if (self.draft) |*dd| dd else {
            self.gpa.free(owned_id);
            if (old_path) |o| self.gpa.free(o);
            return;
        };
        d.editing_id = owned_id;
        if (d.old_path) |o| self.gpa.free(o);
        d.old_path = old_path;
        d.input.update(cx, input.TextInput.setText, .{body});
        self.syncCommentRows(cx);
        cx.notify();
    }

    pub fn cancelDraft(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        self.dropDraft(cx.app);
        self.syncCommentRows(cx);
        cx.notify();
    }

    /// `commit_draft`: stage (or update) the note onto the composer it was
    /// written against, even if the selection moved under it.
    pub fn commitDraft(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        const d = self.draft orelse return;
        const body = cm.trimUnicode(d.input.read(cx).text());
        if (body.len > 0) {
            const store = self.comments(cx);
            if (d.editing_id) |id| {
                store.update(cx, ReviewCommentStore.updateBody, .{ d.key, id, body });
            } else {
                _ = store.update(cx, ReviewCommentStore.add, .{ d.key, model.review_comments.NewComment{
                    .path = d.path,
                    .line = d.line,
                    .body = body,
                    .source = .{ .diff = .{ .side = d.side, .old_path = d.old_path } },
                } }) catch {};
            }
        }
        self.dropDraft(cx.app);
        self.syncCommentRows(cx);
        cx.notify();
    }

    pub fn removeComment(self: *ChangesPane, id: []const u8, cx: *Context(ChangesPane)) void {
        const store = self.comments(cx);
        const key = self.gpa.dupe(u8, store.read(cx).composerKey()) catch return;
        defer self.gpa.free(key);
        store.update(cx, ReviewCommentStore.remove, .{ key, id });
        self.syncCommentRows(cx);
        cx.notify();
    }

    fn onDraftInput(self: *ChangesPane, _: Entity(input.TextInput), ev: *const input.TextInputEvent, cx: *Context(ChangesPane)) void {
        switch (ev.*) {
            .submitted => self.commitDraft(cx),
            .escape => self.cancelDraft(cx),
            .edited => cx.notify(),
            else => {},
        }
    }

    // ---- discard --------------------------------------------------------------------

    fn discardRequest(self: *const ChangesPane, cx: anytype) ?DiscardRequested {
        if (self.scope != .working_tree) return null;
        const d = self.resolved(cx) orelse return null;
        if (d.truncated or (d.files.len == 0 and std.mem.trim(u8, d.patch, " \t\r\n").len == 0)) return null;
        const chat = self.selectedChat(cx) orelse return null;
        return .{ .chat_id = chat.id, .checkout_id = d.checkoutId, .expected_checksum = d.checksum, .target_device_id = self.desiredTarget(cx), .file_count = d.files.len };
    }

    fn clearDiscard(self: *ChangesPane) void {
        if (self.discard) |flow| switch (flow) {
            .confirm => |c| {
                self.gpa.free(c.chat_id);
                self.gpa.free(c.checkout_id);
                self.gpa.free(c.checksum);
                if (c.target) |t| self.gpa.free(t);
            },
            .failed => |msg| self.gpa.free(msg),
        };
        self.discard = null;
    }

    fn onDiscardClick(self: *ChangesPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ChangesPane)) void {
        cx.stopPropagation();
        self.openDiscard(cx);
    }

    /// The trash action: emit `DiscardRequested` and (unless a host owns the
    /// dialog) show the confirmation.
    pub fn openDiscard(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        const req = self.discardRequest(cx) orelse return;
        cx.emit(req);
        if (!self.own_discard_dialog or self.discard_inflight) return;
        self.clearDiscard();
        self.discard = .{ .confirm = .{
            .chat_id = self.gpa.dupe(u8, req.chat_id) catch return,
            .checkout_id = self.gpa.dupe(u8, req.checkout_id) catch return,
            .checksum = self.gpa.dupe(u8, req.expected_checksum) catch return,
            .target = if (req.target_device_id) |t| self.gpa.dupe(u8, t) catch null else null,
        } };
        cx.notify();
    }

    fn onDiscardCancel(self: *ChangesPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ChangesPane)) void {
        self.clearDiscard();
        cx.notify();
    }

    fn onDiscardScrim(self: *ChangesPane, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(ChangesPane)) void {
        self.clearDiscard();
        cx.notify();
    }

    const DiscardParams = struct { chatId: []const u8, checkoutId: []const u8, expectedChecksum: []const u8, targetDeviceId: ?[]const u8 = null };

    fn onDiscardConfirm(self: *ChangesPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ChangesPane)) void {
        if (self.discard_inflight) return;
        const flow = self.discard orelse return;
        if (flow != .confirm) return;
        const c = flow.confirm;
        if (self.engine(cx).read(cx).conn == null) {
            self.clearDiscard();
            self.discard = .{ .failed = self.gpa.dupe(u8, "Engine is not connected.") catch return };
            cx.notify();
            return;
        }
        model.EngineState.request(self.engine(cx), cx, ChangesPane, cx.entityId(), .DiscardWorkingTree, DiscardParams{
            .chatId = c.chat_id,
            .checkoutId = c.checkout_id,
            .expectedChecksum = c.checksum,
            .targetDeviceId = c.target,
        }, onDiscarded) catch |err| {
            self.clearDiscard();
            self.discard = .{ .failed = std.fmt.allocPrint(self.gpa, "{t}", .{err}) catch return };
            cx.notify();
            return;
        };
        // Dismiss immediately; the in-flight flag blocks a second request.
        self.discard_inflight = true;
        self.clearDiscard();
        cx.notify();
    }

    fn onDiscarded(self: *ChangesPane, result: es.CallResult, cx: *Context(ChangesPane)) void {
        self.discard_inflight = false;
        switch (result) {
            .ok => {},
            .err => |e| {
                self.clearDiscard();
                self.discard = .{ .failed = self.gpa.dupe(u8, e.message) catch return };
            },
        }
        cx.notify();
    }

    // ---- menus ----------------------------------------------------------------------

    fn onScopeTrigger(self: *ChangesPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ChangesPane)) void {
        cx.stopPropagation();
        self.scope_menu_open = !self.scope_menu_open;
        cx.notify();
    }

    fn onScopeOutside(self: *ChangesPane, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(ChangesPane)) void {
        if (!self.scope_menu_open) return;
        self.scope_menu_open = false;
        cx.notify();
    }

    fn onScopeRow(self: *ChangesPane, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ChangesPane)) void {
        self.scope_menu_open = false;
        self.setScope(m.DiffScope.menu[ix], cx);
    }

    fn closeRefMenu(self: *ChangesPane, app: *App) void {
        if (self.ref_menu) |*r| {
            r.sub.deinit();
            r.focus.release(app);
            r.search.release(app);
        }
        self.ref_menu = null;
    }

    fn onRefTrigger(self: *ChangesPane, _: *const zpui.ClickEvent, window: *Window, cx: *Context(ChangesPane)) void {
        cx.stopPropagation();
        if (self.ref_menu != null) {
            self.closeRefMenu(cx.app);
            cx.notify();
            return;
        }
        const theme = ui.theme.get(cx).forPopup();
        const search = cx.newWith(input.TextInput, input.TextInput.init, .{input.Options{
            .placeholder = "Search branches…",
            .key_context = "PaletteSearch",
            .single_line = true,
            .text_size = 12,
            .line_height = 16,
            .colors = .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
        }}) catch return;
        const sub = cx.subscribe(search, onRefSearch) catch {
            search.release(cx);
            return;
        };
        self.ref_menu = .{ .search = search, .focus = cx.focusHandle(), .sub = sub };
        window.focus(search.read(cx).focusHandle());
        cx.notify();
    }

    fn refRows(self: *const ChangesPane, a: Allocator, cx: anytype) []usize {
        var out: std.ArrayList(usize) = .empty;
        const q = if (self.ref_menu) |r| std.mem.trim(u8, r.search.read(cx).text(), " ") else "";
        for (self.branches.items, 0..) |b, i| {
            if (q.len == 0 or std.ascii.findIgnoreCase(b, q) != null) out.append(a, i) catch {};
        }
        return out.items;
    }

    fn onRefSearch(self: *ChangesPane, _: Entity(input.TextInput), ev: *const input.TextInputEvent, cx: *Context(ChangesPane)) void {
        switch (ev.*) {
            .edited => {
                if (self.ref_menu) |*r| r.active = 0;
                cx.notify();
            },
            .escape => {
                self.closeRefMenu(cx.app);
                cx.notify();
            },
            .submitted => self.pickActiveRef(cx),
            else => {},
        }
    }

    fn pickActiveRef(self: *ChangesPane, cx: *Context(ChangesPane)) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const list = self.refRows(arena.allocator(), cx);
        const active = if (self.ref_menu) |r| r.active else 0;
        if (active < list.len) self.setBaseRef(list[active], cx);
    }

    fn onRefKey(self: *ChangesPane, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Context(ChangesPane)) void {
        const key = ev.keystroke.key;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const n = self.refRows(arena.allocator(), cx).len;
        const r = if (self.ref_menu) |*rm| rm else return;
        if (std.mem.eql(u8, key, "down")) {
            if (n > 0) r.active = (r.active + 1) % n;
        } else if (std.mem.eql(u8, key, "up")) {
            if (n > 0) r.active = (r.active + n - 1) % n;
        } else return;
        cx.stopPropagation();
        cx.notify();
    }

    fn setBaseRef(self: *ChangesPane, branch_ix: usize, cx: *Context(ChangesPane)) void {
        if (branch_ix < self.branches.items.len) {
            const name = self.branches.items[branch_ix];
            if (!eqlOpt(self.base_ref, name)) {
                if (self.base_ref) |b| self.gpa.free(b);
                self.base_ref = self.gpa.dupe(u8, name) catch null;
                self.sync(cx);
            }
        }
        self.closeRefMenu(cx.app);
        cx.notify();
    }

    fn onRefRow(self: *ChangesPane, branch_ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ChangesPane)) void {
        self.setBaseRef(branch_ix, cx);
    }

    fn onRefOutside(self: *ChangesPane, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(ChangesPane)) void {
        if (self.ref_menu == null) return;
        self.closeRefMenu(cx.app);
        cx.notify();
    }

    // ---- listeners ------------------------------------------------------------------

    fn onHeaderClick(self: *ChangesPane, file_ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ChangesPane)) void {
        self.toggleFold(file_ix, cx);
    }

    fn onOpenFile(self: *ChangesPane, file_ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ChangesPane)) void {
        cx.stopPropagation();
        const fs = self.files();
        if (file_ix < fs.len) cx.emit(OpenFile{ .path = fs[file_ix].path });
    }

    fn onSplitClick(self: *ChangesPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ChangesPane)) void {
        cx.stopPropagation();
        self.toggleMode(cx);
    }

    fn onWrapClick(self: *ChangesPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ChangesPane)) void {
        cx.stopPropagation();
        self.toggleWrap(cx);
    }

    fn onFoldAllClick(self: *ChangesPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(ChangesPane)) void {
        cx.stopPropagation();
        self.toggleCollapseAll(cx);
    }

    fn onHoverKey(_: *ChangesPane, key: []const u8, hovered: *const bool, _: *Window, cx: *Context(ChangesPane)) void {
        ui.hover.set(cx, key, hovered.*);
    }

    /// Keyboard: ↑↓ / PageUp / PageDown / Home / End scroll; Esc closes menus.
    fn onKey(self: *ChangesPane, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Context(ChangesPane)) void {
        const key = ev.keystroke.key;
        const page: f32 = @max(self.list.viewportBounds().size.height - 2 * m.line_height, m.line_height);
        if (std.mem.eql(u8, key, "escape")) {
            if (!self.scope_menu_open and self.ref_menu == null and self.discard == null) return;
            self.scope_menu_open = false;
            self.closeRefMenu(cx.app);
            self.clearDiscard();
        } else if (std.mem.eql(u8, key, "down")) {
            self.list.scrollBy(m.line_height * 3);
        } else if (std.mem.eql(u8, key, "up")) {
            self.list.scrollBy(-m.line_height * 3);
        } else if (std.mem.eql(u8, key, "pagedown") or std.mem.eql(u8, key, "space")) {
            self.list.scrollBy(page);
        } else if (std.mem.eql(u8, key, "pageup")) {
            self.list.scrollBy(-page);
        } else if (std.mem.eql(u8, key, "home")) {
            self.list.scrollTo(.{});
        } else if (std.mem.eql(u8, key, "end")) {
            self.list.scrollToEnd();
        } else return;
        cx.stopPropagation();
        cx.notify();
    }

    // ---- rendering: toolbar -----------------------------------------------------------

    /// `header_toggle`: 24px, radius 6, hover blend wash 0 → 0.14; latched
    /// toggles hold the wash and the full text tone.
    fn headerToggle(id: []const u8, i: Icon, label: []const u8, active: bool, theme: *const Theme, cx: *Context(ChangesPane)) zpui.StatefulDiv {
        var b = div().id(id).role(.button).ariaLabel(label).ariaToggled(active).size(px(m.control_size)).flexNone().flex().itemsCenter().justifyCenter()
            .rounded(px(m.control_radius)).cursorPointer();
        b = if (active)
            b.bg(theme.wash(0.14))
        else
            b.bg(ui.hover.blend(cx, id, theme.wash(0), theme.wash(0.14))).onHover(cx.listenerWith(id, onHoverKey));
        return b.occlude().onMouseDown(.left, preventDefault)
            .tooltipWith(label, ui.tooltip.build).tooltipShowDelay(350 * std.time.ns_per_ms)
            .child(ui.icon.of(i, m.icon_size, if (active) theme.text else theme.text_muted.opacity(0.7)));
    }

    fn preventDefault(_: *const zpui.input.MouseDownEvent, window: *Window, _: *App) void {
        window.preventDefault();
    }

    /// The pane-header controls (what Rust's shell mounts inside
    /// `surface_chrome::toolbar`).
    pub fn renderHeaderControls(self: *ChangesPane, theme: *const Theme, cx: *Context(ChangesPane)) zpui.Div {
        var row = div().sizeFull().flex().flexRow().itemsCenter().gap(px(m.control_gap));
        if (self.commit) |c| {
            return row
                .child(div().flexNone().h(px(m.control_size)).px(px(6)).rounded(px(m.control_radius)).flex().itemsCenter()
                    .bg(theme.ink(0.05)).fontFamily(theme.font_mono).textSize(px(10.5)).textColor(theme.text_muted)
                    .child(c.sha[0..@min(7, c.sha.len)]))
                .child(div().flex1().minW0().truncate().whitespaceNowrap().textSize(px(12)).textColor(theme.text).child(c.subject))
                .child(headerToggle("changes-split", .split_columns, "Split view", self.mode == .split, theme, cx).onClick(cx.listener(onSplitClick)))
                .child(headerToggle("changes-wrap", .wrap_text, "Wrap long lines", self.wrap_lines, theme, cx).onClick(cx.listener(onWrapClick)))
                .child(headerToggle("changes-fold-all", .fold_vertical, self.foldAllLabel(), false, theme, cx).onClick(cx.listener(onFoldAllClick)));
        }
        const trigger_key = "changes-scope-trigger";
        var trigger = div().id(trigger_key).role(.button).ariaLabel(zpui.fmt("Diff scope: {s}", .{self.scope.label()})).ariaExpanded(self.scope_menu_open).h(px(m.control_size)).px(px(8)).flexNone().flex().flexRow().itemsCenter().gap(px(6))
            .rounded(px(m.control_radius)).cursorPointer()
            .bg(ui.hover.blend(cx, trigger_key, theme.wash(0.05), theme.wash(0.14)))
            .onHover(cx.listenerWith(@as([]const u8, trigger_key), onHoverKey))
            .occlude().onMouseDown(.left, preventDefault)
            .onClick(cx.listener(onScopeTrigger))
            .child(div().textSize(px(12)).lineHeight(px(14)).textColor(theme.text).whitespaceNowrap().child(self.scope.label()))
            .child(ui.icon.of(.alt_arrow_down, 12, theme.text_muted.opacity(0.7)));
        if (self.scope_menu_open) trigger = trigger.relative().child(self.scopeMenu(theme, cx));
        row = row.child(trigger);
        if (self.renderRefSelector(theme, cx)) |sel| row = row.child(sel);
        row = row.child(div().flex1());
        var trailing = div().flexNone().flex().itemsCenter().gap(px(m.control_gap));
        if (self.scope == .working_tree) {
            const enabled = self.discardRequest(cx) != null;
            var trash = headerToggle("changes-discard-working-tree", .trash_bin_minimalistic, "Discard changes", false, theme, cx);
            if (enabled) trash = trash.onClick(cx.listener(onDiscardClick)) else trash = trash.opacity(0.35);
            trailing = trailing.child(trash);
        }
        trailing = trailing
            .child(headerToggle("changes-split", .split_columns, "Split view", self.mode == .split, theme, cx).onClick(cx.listener(onSplitClick)))
            .child(headerToggle("changes-wrap", .wrap_text, "Wrap long lines", self.wrap_lines, theme, cx).onClick(cx.listener(onWrapClick)))
            .child(headerToggle("changes-fold-all", .fold_vertical, self.foldAllLabel(), false, theme, cx).onClick(cx.listener(onFoldAllClick)));
        return row.child(trailing);
    }

    fn anchoredBelow(id: []const u8, gap: f32, card: zpui.Div) zpui.Div {
        return div().absolute().bottom(px(0)).left(px(0)).size(px(0)).child(zpui.deferred(
            zpui.anchored().anchorCorner(.top_left).snapToWindowWithMargin(.all(8))
                .child(ui.anim.menuIn(id, div().occlude().pt(px(gap)).child(ui.popover.frostedCard(card)), -2)),
        ).withPriority(1));
    }

    fn scopeMenu(self: *ChangesPane, base_theme: *const Theme, cx: *Context(ChangesPane)) zpui.Div {
        const theme = zpui.window.arena_mod.current().create(Theme, base_theme.forPopup());
        var col = div().flex().flexCol().gap(px(2));
        for (m.DiffScope.menu, 0..) |scope, ix| {
            col = col.child(ui.popover.menuRow(theme, scope == self.scope).id(.{ "changes-scope-row", ix }).role(.menu_item)
                .onClick(cx.listenerWith(ix, onScopeRow))
                .child(div().flex1().child(scope.label())));
        }
        const card = ui.popover.card(theme).w(px(180)).onMouseDownOut(cx.listener(onScopeOutside)).child(col);
        return anchoredBelow("changes-scope-menu", 10, card);
    }

    fn renderRefSelector(self: *ChangesPane, theme: *const Theme, cx: *Context(ChangesPane)) ?zpui.Div {
        if (self.scope != .branch) return null;
        const branch = if (self.selectedChat(cx)) |c| (c.branch orelse "HEAD") else "HEAD";
        const base: []const u8 = self.base_ref orelse "…";
        const key = "changes-ref-trigger";
        var trigger = div().id(key).role(.button).ariaLabel(zpui.fmt("Compare against {s}", .{base})).ariaExpanded(self.ref_menu != null).h(px(m.control_size)).px(px(6)).minW0().flex().flexRow().itemsCenter().gap(px(4))
            .rounded(px(6)).cursorPointer()
            .bg(ui.hover.blend(cx, key, theme.wash(0), theme.wash(0.12)))
            .onHover(cx.listenerWith(@as([]const u8, key), onHoverKey))
            .occlude().onMouseDown(.left, preventDefault)
            .onClick(cx.listener(onRefTrigger))
            .child(div().minW0().truncate().whitespaceNowrap().fontFamily(theme.font_mono).textSize(px(11.5)).textColor(theme.text).child(base))
            .child(ui.icon.of(.alt_arrow_down, 11, theme.text_muted.opacity(0.7)));
        if (self.ref_menu != null) trigger = trigger.relative().child(self.refMenu(theme, cx));
        return div().minW0().flex().flexRow().itemsCenter().gap(px(6)).ml(px(m.control_gap))
            .child(div().minW0().truncate().whitespaceNowrap().fontFamily(theme.font_mono).textSize(px(11.5)).textColor(theme.text_dim).child(branch))
            .child(ui.icon.of(.arrow_right, 12, theme.text_faint))
            .child(trigger);
    }

    fn refMenu(self: *ChangesPane, base_theme: *const Theme, cx: *Context(ChangesPane)) zpui.Div {
        const theme = zpui.window.arena_mod.current().create(Theme, base_theme.forPopup());
        const r = self.ref_menu.?;
        const list = self.refRows(frame(), cx);
        var rows_col = div().id("changes-ref-list").flex().flexCol().gap(px(2)).maxH(px(240)).overflowYScroll();
        if (list.len == 0) {
            rows_col = rows_col.child(div().px(px(8)).py(px(6)).textSize(px(12)).textColor(theme.text_faint)
                .child(if (self.branches.items.len == 0) "No branches" else "No matching branches"));
        }
        for (list, 0..) |bi, row_ix| {
            const name = self.branches.items[bi];
            const selected = eqlOpt(self.base_ref, name);
            var row = ui.popover.menuRow(theme, selected);
            if (row_ix == r.active and !selected) row = row.bg(theme.ink(0.08));
            rows_col = rows_col.child(row.id(.{ "changes-ref-row", row_ix }).role(.menu_item_radio).ariaLabel(name).ariaToggled(selected).onClick(cx.listenerWith(bi, onRefRow))
                .child(div().flex1().minW0().truncate().whitespaceNowrap().fontFamily(theme.font_mono).textSize(px(12)).child(name)));
        }
        const search_frame = div().h(px(28)).mb(px(4)).px(px(8)).rounded(px(7)).flex().itemsCenter().gap(px(6))
            .bg(theme.ink(0.035))
            .child(ui.icon.of(.magnifer, 12, theme.text_faint))
            .child(div().flex1().minW0().child(r.search));
        const card = ui.popover.card(theme).w(px(240)).trackFocus(r.focus)
            .captureKeyDown(cx.listener(onRefKey))
            .onMouseDownOut(cx.listener(onRefOutside))
            .child(search_frame).child(rows_col);
        return anchoredBelow("changes-ref-menu", 10, card);
    }

    /// `surface_chrome::toolbar` with the header controls inside.
    pub fn toolbar(self: *ChangesPane, theme: *const Theme, cx: *Context(ChangesPane)) zpui.Div {
        return div().h(px(m.header_height)).wFull().flexNone().px(px(m.edge_inset)).flex().itemsCenter().gap(px(m.control_gap))
            .borderT1().borderB1().borderColor(theme.border)
            .bg(if (theme.isGlass()) theme.surface.opacity(0.26) else theme.surface)
            .child(self.renderHeaderControls(theme, cx));
    }

    // ---- rendering: content -----------------------------------------------------------

    fn headerStrip(self: *ChangesPane, theme: *const Theme) ?zpui.Div {
        const p = self.parsed orelse return null;
        var strip = div().flexNone().h(px(m.header_height)).flex().flexRow().itemsCenter().gap(px(10)).px(px(16))
            .borderB1().borderColor(theme.hairline(0.06))
            .child(div().minW0().truncate().whitespaceNowrap().textSize(px(12)).textColor(theme.text_muted)
                .child(m.scopeLabel(frame(), self.scope, p.file_count, self.base_ref)))
            .child(div().fontFamily(theme.font_mono).textSize(px(11)).textColor(rows.addColor(theme)).child(zpui.fmt("+{d}", .{p.additions})))
            .child(div().fontFamily(theme.font_mono).textSize(px(11)).textColor(rows.delColor(theme)).child(zpui.fmt("\u{2212}{d}", .{p.deletions})))
            .child(div().flex1());
        if (p.truncated) strip = strip.child(div().flexNone().textSize(px(10)).px(px(6)).py(px(2)).rounded(px(4))
            .bg(theme.warning.opacity(0.08)).textColor(theme.warning.opacity(0.75)).child("Partial snapshot"));
        return strip;
    }

    const HeaderPaint = struct { rest: Hsla, hover: Hsla };

    fn stickyPaint(theme: *const Theme) HeaderPaint {
        if (theme.isFrost()) return .{ .rest = theme.ink(0.025), .hover = theme.glassHover() };
        return .{ .rest = zt.colorspace.flatten(theme.ink(0.025), theme.bg), .hover = zt.colorspace.flatten(theme.element_hover, theme.bg) };
    }

    fn chevronFrame(_: void, el: zpui.Div, t: f32) zpui.Div {
        return el.opacity(0.25 + 0.75 * t);
    }

    fn fileHeader(self: *ChangesPane, ix: usize, sticky: bool, theme: *const Theme, cx: *Context(ChangesPane)) AnyElement {
        const fs = self.files();
        const file = &fs[ix];
        const fold = self.foldOf(ix);
        const paint: HeaderPaint = if (sticky) stickyPaint(theme) else .{ .rest = theme.ink(0.025), .hover = theme.ink(0.05) };
        const chevron = div().flexNone().size(px(14)).flex().itemsCenter()
            .child(ui.icon.of(if (fold.collapsed) .alt_arrow_right else .alt_arrow_down, 13, theme.text_muted.opacity(0.7)));
        const chev_el: AnyElement = if (fold.animating(nowNs(cx)))
            zpui.intoAnyElement(zpui.withAnimationCtx(chevron, .{ if (sticky) "chev-sticky" else "chev", ix * 65536 + fold.epoch }, zt.motion.chevron.animation(), {}, chevronFrame))
        else
            zpui.intoAnyElement(chevron);
        var row = div().id(.{ if (sticky) "sticky-file-hdr" else "file-hdr", ix }).role(.button).ariaLabel(file.path).ariaExpanded(!fold.collapsed)
            .wFull().h(px(m.file_header_height)).flexNone().flex().flexRow().itemsCenter().gap(px(8)).px(px(12))
            .bg(paint.rest).cursorPointer().hover(sb.bg(paint.hover))
            .onClick(cx.listenerWith(ix, onHeaderClick));
        if (!sticky and ix > 0) row = row.borderT1().borderColor(theme.hairline(0.04));
        if (sticky) row = row.borderB1().borderColor(theme.border).blockMouseExceptScroll();
        row = row.child(chev_el)
            .child(md.file_icons.icon(file.path, theme, 14))
            .child(div().flex1().minW0().truncate().whitespaceNowrap().fontFamily(theme.font_mono).textSize(px(12)).textColor(theme.text_dim).child(file.path));
        if (file.binary) row = row.child(div().flexNone().textSize(px(10)).textColor(theme.text_faint).child("BIN"));
        if (file.additions > 0 or !file.binary) row = row.child(div().flexNone().fontFamily(theme.font_mono).textSize(px(11)).textColor(rows.addColor(theme)).child(zpui.fmt("+{d}", .{file.additions})));
        if (file.deletions > 0 or !file.binary) row = row.child(div().flexNone().fontFamily(theme.font_mono).textSize(px(11)).textColor(rows.delColor(theme)).child(zpui.fmt("\u{2212}{d}", .{file.deletions})));
        row = row.child(div().id(.{ "diff-open-file", ix }).role(.button).ariaLabel("Open in file browser").flexNone().size(px(m.control_size)).flex().itemsCenter().justifyCenter()
            .rounded(px(m.control_radius)).hover(sb.bg(theme.ink(0.08)))
            .onMouseDown(.left, stopDown)
            .onClick(cx.listenerWith(ix, onOpenFile))
            .tooltipWith(@as([]const u8, "Open in file browser"), ui.tooltip.build).tooltipShowDelay(350 * std.time.ns_per_ms)
            .child(ui.icon.of(.document, m.icon_size, theme.text_muted)));
        return zpui.intoAnyElement(row);
    }

    fn stopDown(_: *const zpui.input.MouseDownEvent, window: *Window, cx: *App) void {
        window.preventDefault();
        cx.propagate_event = false;
    }

    fn codeWidth(self: *const ChangesPane, file_ix: usize, split: bool) rows.CodeWidth {
        if (self.wrap_lines) return .wrapped;
        const p = self.parsed orelse return .clipped;
        const t = p.max_text[file_ix];
        return .{ .scrollable = if (split) rows.splitContentWidth(t) else rows.unifiedContentWidth(t) };
    }

    fn foldFrame(ctx: [2]f32, el: zpui.Div, t: f32) zpui.Div {
        return el.h(px(ctx[0] + (ctx[1] - ctx[0]) * t));
    }

    pub fn renderRow(self: *ChangesPane, ix: usize, _: *Window, cx: *Context(ChangesPane)) AnyElement {
        if (ix >= self.flat.rows.items.len or self.parsed == null) return zpui.empty();
        const theme = zpui.window.arena_mod.current().create(Theme, ui.theme.get(cx).*);
        const row = self.flat.rows.items[ix];
        const fs = self.files();
        const fi = row.file();
        if (fi >= fs.len) return zpui.empty();
        const file = &fs[fi];
        const scroll = self.parsed.?.scroll[fi];
        return switch (row) {
            .file_header => self.fileHeader(fi, false, theme, cx),
            .notice => |n| blk: {
                const notices = diff.fileNotices(frame(), file.*) catch break :blk zpui.empty();
                break :blk if (n.notice < notices.len) zpui.intoAnyElement(rows.noticeRow(notices[n.notice], theme)) else zpui.empty();
            },
            .hunk_header => |h| zpui.intoAnyElement(rows.hunkHeaderRow(file.hunks[h.hunk].header, theme)),
            .line => |l| blk: {
                const hlx = self.highlightFor(fi, cx);
                const line = &file.hunks[l.hunk].lines[l.line];
                const gutter = m.gutterWidth(file);
                const row_el = rows.diffLineRow(line, hl.spansFor(hlx, line), theme, gutter, self.codeWidth(fi, false), .{ .handle = scroll, .id = zpui.fmt("changes-code-row-{d}", .{ix}) });
                const anchor = m.lineAnchor(line) orelse break :blk zpui.intoAnyElement(row_el);
                const h: HoverRow = .{ .file = @intCast(fi), .side = anchor.side, .line = anchor.line };
                var wrapped = div().id(.{ "diff-line", ix }).wFull().relative().child(row_el)
                    .onMouseMove(cx.listenerWith(h, onLineMove))
                    .onHover(cx.listenerWith(h, onLineHover));
                if (self.hovering(h)) wrapped = wrapped.child(comment_ui.positioned(m.commentAdderLeft(anchor.side, gutter), self.adderFor(file.path, h, theme, cx)));
                break :blk zpui.intoAnyElement(wrapped);
            },
            .split_line => |s| self.splitRowWithAdder(ix, fi, s.hunk, s.left, s.right, theme, cx),
            .comment_card => |c| blk: {
                const fc = self.fileComments(frame(), cx, file.path);
                if (c.card >= fc.len) break :blk zpui.empty();
                break :blk zpui.intoAnyElement(comment_ui.card(ChangesPane, &fc[c.card], theme, cx, editComment, removeComment, null));
            },
            .comment_draft => blk: {
                const d = if (self.draft) |*dd| dd else break :blk zpui.empty();
                if (!std.mem.eql(u8, d.path, file.path)) break :blk zpui.empty();
                // The header cites the same path the staged card and the prompt bullet will.
                break :blk zpui.intoAnyElement(comment_ui.draft(ChangesPane, d.citePath(), d.line, d.input, d.editing_id != null, theme, cx, cancelDraft, commitDraft, null));
            },
            .body_pad => zpui.intoAnyElement(div().wFull().h(px(m.body_bottom_pad))),
            .folding_body => blk: {
                const fold = self.foldOf(fi);
                const cap = @min(@max(fold.from, fold.to), m.fold_tween_max_px);
                const hlx = self.highlightFor(fi, cx);
                const body = rows.fileBodyUpto(file, hlx, theme, cap, self.mode, self.codeWidth(fi, self.mode == .split), scroll, zpui.fmt("changes-fold-code-{d}-{d}", .{ fi, fold.epoch }));
                const clipped = div().wFull().overflowHidden().child(body);
                if (fold.animating(nowNs(cx))) {
                    break :blk zpui.intoAnyElement(zpui.withAnimationCtx(clipped, .{ "fold", fi * 65536 + fold.epoch }, zt.motion.collapse.animation(), [2]f32{ fold.from, fold.to }, foldFrame));
                }
                break :blk zpui.intoAnyElement(clipped.h(px(fold.to)));
            },
        };
    }

    fn adderFor(_: *ChangesPane, path: []const u8, h: HoverRow, theme: *const Theme, cx: *Context(ChangesPane)) zpui.StatefulDiv {
        return comment_ui.adder(ChangesPane, zpui.fmt("cmt-add-{s}-{s}-{d}", .{ path, h.side.tag(), h.line }), theme, cx, h, onAdderClick);
    }

    /// A split row. The left column is inert (it shows the pre-change file);
    /// only the right column takes a `+`. Cards for old-side notes still
    /// render (they are pushed by the row), so switching layouts never hides one.
    fn splitRowWithAdder(self: *ChangesPane, ix: usize, fi: usize, hunk_ix: u32, left_ix: ?u32, right_ix: ?u32, theme: *const Theme, cx: *Context(ChangesPane)) AnyElement {
        const file = &self.files()[fi];
        const hunk = &file.hunks[hunk_ix];
        const hlx = self.highlightFor(fi, cx);
        const gutter = m.gutterWidth(file);
        const width = self.codeWidth(fi, true);
        const scroll = self.parsed.?.scroll[fi];
        const sl: rows.CodeScroll = .{ .handle = scroll, .id = zpui.fmt("changes-code-row-{d}-old", .{ix}) };
        const sr: rows.CodeScroll = .{ .handle = scroll, .id = zpui.fmt("changes-code-row-{d}-new", .{ix}) };
        const right: ?*const diff.DiffLine = if (right_ix) |i| &hunk.lines[i] else null;
        const anchor = if (right) |r| m.lineAnchor(r) else null;
        if (anchor == null or (if (left_ix) |i| hunk.lines[i].kind == .meta else false) or right.?.kind == .meta)
            return zpui.intoAnyElement(rows.splitPairRow(hunk, left_ix, right_ix, hlx, theme, gutter, width, sl, sr));
        const r = right.?;
        const lcell: AnyElement = if (left_ix) |i|
            zpui.intoAnyElement(rows.splitLineCell(&hunk.lines[i], hunk.lines[i].old_no, hl.spansFor(hlx, &hunk.lines[i]), theme, gutter, width, sl))
        else
            zpui.intoAnyElement(rows.splitFiller(theme));
        const h: HoverRow = .{ .file = @intCast(fi), .side = anchor.?.side, .line = anchor.?.line };
        var rcell = rows.splitLineCell(r, r.new_no, hl.spansFor(hlx, r), theme, gutter, width, sr).id(.{ "split-new", ix })
            .onMouseMove(cx.listenerWith(h, onLineMove))
            .onHover(cx.listenerWith(h, onLineHover));
        if (self.hovering(h)) rcell = rcell.relative().child(comment_ui.positioned(m.splitAdderLeft(gutter), self.adderFor(file.path, h, theme, cx)));
        return zpui.intoAnyElement(rows.splitRow(lcell, zpui.intoAnyElement(rcell), width == .wrapped, theme));
    }

    fn stickyHeader(self: *ChangesPane, theme: *const Theme, cx: *Context(ChangesPane)) ?zpui.Div {
        const top = self.list.logicalScrollTop();
        const s = m.stickyFileHeader(self.flat.ranges.items, top.item_ix, top.offset_in_item) orelse return null;
        if (s.file_ix >= self.files().len) return null;
        const next_y: ?f32 = if (s.next_header_row) |r| blk: {
            const b = self.list.boundsForItem(r) orelse break :blk null;
            break :blk b.origin.y - self.list.viewportBounds().origin.y;
        } else null;
        const offset = m.stickyPushOffset(next_y);
        const header = self.fileHeader(s.file_ix, true, theme, cx);
        var tinted = div().wFull();
        if (theme.isFrost()) tinted = tinted.bg(theme.bg.opacity(if (theme.appearance.isDark()) m.sticky_tint_alpha_dark else m.sticky_tint_alpha_light));
        const framed: AnyElement = if (theme.isFrost())
            zpui.intoAnyElement(ui.effects.frosted(0, m.sticky_blur, tinted.child(header)))
        else
            zpui.intoAnyElement(tinted.child(header));
        return div().absolute().top(px(offset)).left(px(0)).wFull().child(framed);
    }

    fn centered(theme: *const Theme, text: []const u8, color: Hsla) zpui.Div {
        _ = theme;
        return div().flex1().flex().itemsCenter().justifyCenter().px(px(16)).textSize(px(12)).textColor(color).child(text);
    }

    fn spinner(window: *Window, cx: *Context(ChangesPane)) zpui.Div {
        window.requestAnimationFrame();
        return ui.loaders.gradientSpinner(3, ui.loaders.phaseOf(cx, zt.motion.gradient_spin));
    }

    pub fn render(self: *ChangesPane, window: *Window, cx: *Context(ChangesPane)) zpui.AnyElement {
        const theme = zpui.window.arena_mod.current().create(Theme, ui.theme.get(cx).*);
        ui.hover.tick(window, cx);
        const no_chat = self.selectedChat(cx) == null;
        const active = self.activeDiff(cx);
        const phase: m.DiffPhase = if (no_chat) .clean else m.diffPhase(active);

        const content: AnyElement = blk: {
            if (!no_chat and self.scope != .working_tree) if (self.scoped_error) |msg| {
                if (std.mem.indexOf(u8, msg, "no turn recorded") != null)
                    break :blk zpui.intoAnyElement(centered(theme, "No turn recorded yet — send a message first", theme.text_faint));
                if (std.mem.indexOf(u8, msg, "unknown method") != null or std.mem.indexOf(u8, msg, "UnknownMethod") != null)
                    break :blk zpui.intoAnyElement(centered(theme, "This chat's device is running an older Zeron — update it to view branch and turn diffs", theme.text_faint));
                break :blk zpui.intoAnyElement(centered(theme, msg, theme.warning.opacity(0.85)));
            };
            switch (phase) {
                .preparing => break :blk zpui.intoAnyElement(div().flex1().flex().flexCol().itemsCenter().justifyCenter().gap(px(8))
                    .child(spinner(window, cx))
                    .child(div().textSize(px(12)).textColor(theme.text_faint).child("Preparing diff\u{2026}"))),
                .clean => break :blk zpui.intoAnyElement(centered(theme, m.cleanMessage(frame(), self.scope, self.base_ref), theme.text_faint)),
                .list => {
                    if (self.parsed == null) break :blk zpui.intoAnyElement(div().flex1().flex().itemsCenter().justifyCenter().child(spinner(window, cx)));
                    var body = div().relative().flex1().minH0().overflowHidden()
                        .child(zpui.list(self.list, cx, renderRow).sizeFull().withSizingBehavior(.auto));
                    if (self.stickyHeader(theme, cx)) |s| body = body.child(s);
                    break :blk zpui.intoAnyElement(div().flex1().minH0().flex().flexCol()
                        .child(self.headerStrip(theme))
                        .child(body));
                },
            }
        };

        var root = div().id("changes-pane").trackFocus(self.focus).keyContext("ChangesPane")
            .onKeyDown(cx.listener(onKey))
            .sizeFull().flex().flexCol().fontFamily(theme.font_sans_fixed).textColor(theme.text);
        if (self.show_toolbar) root = root.child(self.toolbar(theme, cx));
        if (self.store.read(cx).error_message) |msg| root = root.child(div().flexNone().px(px(12)).py(px(4)).borderB1().borderColor(theme.border)
            .textSize(px(11)).textColor(theme.warning).child(msg));
        root = root.child(content);
        if (self.discard) |flow| root = root.child(self.discardDialog(flow, theme, window, cx));
        return zpui.intoAnyElement(root);
    }

    fn discardDialog(self: *ChangesPane, flow: DiscardFlow, base_theme: *const Theme, window: *Window, cx: *Context(ChangesPane)) AnyElement {
        _ = self;
        const theme = zpui.window.arena_mod.current().create(Theme, base_theme.forPopup());
        const card = switch (flow) {
            .confirm => dialog.card(theme)
                .child(dialog.title(theme, "Discard working tree changes?"))
                .child(div().mt(px(6)).child(dialog.body(theme, "Discard all uncommitted changes in this working tree? This can\u{2019}t be undone.")))
                .child(div().mt(px(16)).flex().flexRow().justifyEnd().gap(px(8))
                    .child(dialog.btnGhost(theme, "Cancel").id("discard-working-tree-cancel").role(.button).onClick(cx.listener(onDiscardCancel)))
                    .child(dialog.btnDanger(theme, "Discard changes").id("discard-working-tree-confirm").role(.button).onClick(cx.listener(onDiscardConfirm)))),
            .failed => |msg| dialog.card(theme)
                .child(dialog.title(theme, "Couldn\u{2019}t discard changes"))
                .child(div().mt(px(6)).child(dialog.body(theme, msg)))
                .child(div().mt(px(16)).flex().justifyEnd()
                    .child(dialog.btnPrimary(theme, "Close").id("discard-working-tree-error-close").role(.button).onClick(cx.listener(onDiscardCancel)))),
        };
        return dialog.modal(window, card, cx.listener(onDiscardScrim));
    }
};

fn freeOpt(gpa: Allocator, slot: *?[]u8) void {
    if (slot.*) |s| gpa.free(s);
    slot.* = null;
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}
