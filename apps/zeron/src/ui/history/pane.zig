//! `HistoryPane`: the right-pane Git History surface — port of zeron
//! `history.rs` `GitHistory` (+ `GitHistoryCount`, `GitHistoryFetchButton`,
//! `GitHistoryViewButton`, `GitHistorySearchControl` and the Changes
//! toolbar's History branch title / refresh button).
//!
//! - toolbar: current branch (mono), "N commits" (+ ahead/behind), search
//!   (collapsible 196px field), Fetch all, branch-tips view, refresh;
//! - column header (Commit / Author / Date / SHA; the checklist button
//!   toggles columns, right-click Author switches avatar ⇄ name);
//! - virtualized 36px rows: lane graph cell (dot, HEAD ring, branch fold
//!   knob on hover), subject, ref badges with `+N` overflow, avatar, date,
//!   short sha (click copies, flashes "Copied");
//! - the lane graph (indigo / pink / … lanes, cubic curves) paints on one
//!   canvas under the rows; hovering a row focuses its lane;
//! - click a row → `OpenCommit` (the host opens a commit diff tab).
//!
//! ```zig
//! const pane = try cx.newWith(HistoryPane, HistoryPane.init, .{app_state});
//! // events: HistoryPane.OpenCommit{ .sha, .subject }, history store FetchSucceeded
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const engine_mod = @import("zeron_engine");
const input = @import("zeron_input");
const ui = @import("../components/root.zig");
const types = @import("types.zig");
const graph = @import("graph.zig");
const store_mod = @import("store.zig");

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
const Commit = types.GitHistoryCommit;
const HistoryStore = store_mod.HistoryStore;
const Icon = ui.icon.Icon;
const protocol = engine_mod.protocol;

const control_size: f32 = 24;
const control_radius: f32 = 6;
const icon_size: f32 = 14;
const control_gap: f32 = 4;
const edge_inset: f32 = 8;
const header_height: f32 = 38;

fn frame() Allocator {
    return zpui.window.arena_mod.frameAllocator();
}

fn arenaTheme(t: Theme) *Theme {
    return zpui.window.arena_mod.current().create(Theme, t);
}

/// A commit row was clicked: open its diff as its own tab.
pub const OpenCommit = struct { sha: []const u8, subject: []const u8 };

pub const ViewMode = enum { all_commits, branch_tips };

const Column = enum { author, date, sha };

const Focus = struct { color_id: usize, amount: f32 };

/// Columns a resize handle sits between (Commit is elastic).
const DataColumn = enum { commit, author, date, sha };

const ResizeAnchor = struct {
    start_x: f32,
    left: DataColumn,
    right: DataColumn,
    left_w: f32,
    right_w: f32,
};

/// Drag payload of a column resize handle (no preview).
const ColumnResize = struct {};

const DragGhost = struct {
    pub fn render(_: *DragGhost, _: *Window, _: *Context(DragGhost)) zpui.Div {
        return div();
    }
};

fn buildResizeGhost(_: *const ColumnResize, _: zpui.Point(f32), _: *Window, app: *App) Entity(DragGhost) {
    return app.new(DragGhost, .{}) catch @panic("OOM");
}

fn limits(c: DataColumn) [2]f32 {
    return switch (c) {
        .commit => .{ graph.subject_min_width, std.math.floatMax(f32) },
        .author => .{ graph.author_min, graph.author_max },
        .date => .{ graph.date_min, graph.date_max },
        .sha => .{ graph.sha_min, graph.sha_max },
    };
}

pub const HistoryPane = struct {
    gpa: Allocator,
    state: Entity(model.AppState),
    store: Entity(HistoryStore),
    subs: zpui.Subscriptions = .{},
    focus: zpui.FocusHandle,
    list: zpui.ListState,
    /// Draw the 38px toolbar (false when a host renders `toolbar()`).
    show_toolbar: bool = true,

    view_mode: ViewMode = .all_commits,
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    view_arena: std.heap.ArenaAllocator,
    /// [motion] The previous build's arena: rows leaving during a fold
    /// transition still point into it (the two swap on every rebuild).
    prev_arena: std.heap.ArenaAllocator,
    /// [motion] A branch fold's row choreography (`HistoryViewTransition`):
    /// the merged old + new rows, which of them enter / exit, and the final
    /// rows the settle swaps in after COLLAPSE.
    transition: ?struct { final: []const Commit, rows: []const RowTransition } = null,
    view_epoch: u64 = 0,
    animate_fold: bool = false,
    transition_task: Task(void) = .none,
    visible: []const Commit = &.{},
    layout: graph.Layout = .{},
    hidden_counts: std.StringHashMapUnmanaged(usize) = .empty,
    lane_capacity: usize = 0,
    built_key: u64 = std.math.maxInt(u64),
    geometry: graph.Geometry = .natural(1),
    target_geometry: graph.Geometry = .natural(1),
    /// The compact ⇄ full graph morph (`graph_geometry_morph`, COLLAPSE).
    morph: ?struct { from: graph.Geometry, to: graph.Geometry, started: u64 } = null,

    hovered_color: ?usize = null,
    copied_sha: ?[]u8 = null,
    copy_task: Task(void) = .none,

    search: ?Entity(input.TextInput) = null,
    search_sub: ?zpui.Subscription = null,
    /// [motion] The search control's width morph (`history-search-morph`,
    /// RESIZE): bumps per open/close; `search_closing` while it collapses.
    search_epoch: u64 = 0,
    search_closing: bool = false,
    search_close_task: Task(void) = .none,
    show_author: bool = true,
    show_date: bool = true,
    show_sha: bool = true,
    author_name_mode: bool = false,
    column_menu_at: ?zpui.Point(f32) = null,
    author_menu_at: ?zpui.Point(f32) = null,
    /// [motion] The two menus' closing phases (MENU_OUT).
    column_exit: ui.popover.Exit = .{},
    author_exit: ui.popover.Exit = .{},
    focus_key_buf: [48]u8 = undefined,
    author_w: f32 = graph.author_width,
    date_w: f32 = graph.date_width,
    sha_w: f32 = graph.sha_width,
    resize: ?ResizeAnchor = null,

    pub const Events = .{OpenCommit};

    pub fn init(state: Entity(model.AppState), cx: *Context(HistoryPane)) !HistoryPane {
        const s = state.read(cx);
        const store = try cx.newWith(HistoryStore, HistoryStore.init, .{s.engine});
        var self: HistoryPane = .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .store = store,
            .focus = cx.focusHandle(),
            .list = zpui.ListState.init(cx.gpa(), 0, .top, px(graph.row_height * 5)),
            .view_arena = .init(cx.gpa()),
            .prev_arena = .init(cx.gpa()),
        };
        if (model.settings_store.current(cx.app)) |st| {
            self.show_author = st.gitHistoryColumns.author;
            self.show_date = st.gitHistoryColumns.date;
            self.show_sha = st.gitHistoryColumns.sha;
            self.author_name_mode = st.gitHistoryAuthorDisplay == .name;
            self.author_w = st.gitHistoryColumnWidths.author;
            self.date_w = st.gitHistoryColumnWidths.date;
            self.sha_w = st.gitHistoryColumnWidths.sha;
        }
        try self.subs.add(cx.gpa(), try cx.observe(state, onStateChanged));
        try self.subs.add(cx.gpa(), try cx.observe(s.workspace, onWorkspaceChanged));
        try self.subs.add(cx.gpa(), try cx.observe(store, onStoreChanged));
        return self;
    }

    pub fn deinit(self: *HistoryPane, app: *App) void {
        self.subs.deinit(self.gpa);
        self.copy_task.cancel();
        self.search_close_task.cancel();
        if (self.copied_sha) |s| self.gpa.free(s);
        var it = self.collapsed.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.collapsed.deinit(self.gpa);
        self.transition_task.cancel();
        self.view_arena.deinit();
        self.prev_arena.deinit();
        self.closeSearch(app);
        self.list.release();
        self.focus.release(app);
        self.store.release(app);
        self.state.release(app);
    }

    pub fn tabTitle(_: *const HistoryPane) []const u8 {
        return "History";
    }

    pub fn tabIcon(_: *const HistoryPane) Icon {
        return .git_branch;
    }

    // ---- model --------------------------------------------------------------------

    fn onStateChanged(self: *HistoryPane, _: Entity(model.AppState), cx: *Context(HistoryPane)) void {
        self.ensureLoaded(cx);
    }

    fn onWorkspaceChanged(self: *HistoryPane, _: Entity(model.WorkspaceStore), cx: *Context(HistoryPane)) void {
        self.ensureLoaded(cx);
    }

    fn onStoreChanged(_: *HistoryPane, _: Entity(HistoryStore), cx: *Context(HistoryPane)) void {
        cx.notify();
    }

    /// Follow the selected chat's checkout (idempotent).
    pub fn ensureLoaded(self: *HistoryPane, cx: *Context(HistoryPane)) void {
        const ws = self.state.read(cx).workspace.read(cx);
        const chat = ws.selectedChatRow();
        const cwd: ?[]const u8 = if (chat) |c| c.cwd else null;
        if (chat == null or cwd == null) {
            self.store.update(cx, HistoryStore.setTarget, .{ null, null, null });
            return;
        }
        const local = if (ws.local_device_id) |l| std.mem.eql(u8, l, chat.?.deviceId) else true;
        const target: ?[]const u8 = if (local) null else chat.?.deviceId;
        var buf: [4096]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ target orelse "local", cwd.? }) catch return;
        self.store.update(cx, HistoryStore.setTarget, .{ key, cwd, target });
    }

    fn branchLabel(self: *const HistoryPane, cx: anytype) []const u8 {
        const chat = self.state.read(cx).workspace.read(cx).selectedChatRow() orelse return "HEAD";
        return chat.branch orelse "HEAD";
    }

    fn optionalColumnsWidth(self: *const HistoryPane) f32 {
        var w: f32 = 0;
        if (self.show_author) w += self.author_w;
        if (self.show_date) w += self.date_w;
        if (self.show_sha) w += self.sha_w;
        return w;
    }

    /// Recompute the visible commits + lane layout when inputs changed.
    fn rebuild(self: *HistoryPane, cx: anytype) void {
        const st = self.store.read(cx);
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&st.generation));
        h.update(std.mem.asBytes(&st.search_generation));
        h.update(st.search_query);
        h.update(std.mem.asBytes(&self.view_mode));
        var it = self.collapsed.keyIterator();
        while (it.next()) |k| h.update(k.*);
        const key = h.final();
        if (key == self.built_key) return;
        self.built_key = key;
        // A second fold mid-tween starts from the previous destination.
        const old: []const Commit = if (self.transition) |t| t.final else self.visible;
        self.transition = null;
        self.transition_task.cancel();
        self.transition_task = .none;
        const animate = self.animate_fold and !ui.popover.appReduced(cx.app);
        self.animate_fold = false;
        const anchor = self.scrollAnchor();
        // Keep the old rows alive in the other arena for the exit rows.
        std.mem.swap(std.heap.ArenaAllocator, &self.view_arena, &self.prev_arena);
        _ = self.view_arena.reset(.retain_capacity);
        self.hidden_counts = .empty;
        const a = self.view_arena.allocator();
        const head = st.head_sha;
        if (st.searchActive()) {
            const source = st.search_results orelse st.commits.items;
            var visible: std.StringHashMapUnmanaged(void) = .empty;
            for (source) |c| if (graph.matches(st.search_query, c)) visible.put(a, c.sha, {}) catch {};
            self.visible = graph.compactToVisible(a, source, &visible) catch &.{};
        } else switch (self.view_mode) {
            .all_commits => {
                var set: std.StringHashMapUnmanaged(void) = .empty;
                var kit = self.collapsed.keyIterator();
                while (kit.next()) |k| set.put(a, k.*, {}) catch {};
                const r = graph.collapseBranchRuns(a, st.commits.items, &set, head) catch graph.Collapsed{ .commits = st.commits.items };
                self.visible = r.commits;
                self.hidden_counts = r.hidden;
            },
            .branch_tips => {
                const tips: []Commit = a.alloc(Commit, st.branch_tips.len) catch &.{};
                for (st.branch_tips, 0..) |c, i| {
                    tips[i] = c;
                    tips[i].parentShas = &.{};
                }
                self.visible = tips;
            },
        }
        // [motion] `apply_view_change(animate_rows)`: a fold merges the old and
        // new rows; leaving rows collapse and arriving rows grow over COLLAPSE.
        if (animate and old.len > 0 and !sameShas(old, self.visible)) {
            if (historyTransitionRows(a, old, self.visible)) |tr| {
                self.transition = .{ .final = self.visible, .rows = tr.rows };
                self.visible = tr.commits;
                self.view_epoch +%= 1;
                self.transition_task = cx.timer(zt.motion.collapse.totalNs(1.0), onTransitionSettled) catch .none;
            } else |_| {}
        }
        self.layout = graph.layoutGraph(a, self.visible, head) catch .{};
        const loaded = graph.layoutGraph(a, st.commits.items, head) catch graph.Layout{};
        self.lane_capacity = @max(self.lane_capacity, @max(self.layout.max_lane_count, loaded.max_lane_count));
        const count = self.visible.len + @intFromBool(st.hasLoadMore());
        self.list.resetWithUniformHeight(count, px(graph.row_height));
        self.restoreScrollAnchor(anchor);
    }

    /// `settle_view_transition`: swap in the final rows (the merged rows'
    /// zero-height leftovers drop out without moving the viewport).
    fn onTransitionSettled(self: *HistoryPane, cx: *Context(HistoryPane)) void {
        self.transition_task = .none;
        const t = self.transition orelse return;
        const anchor = self.scrollAnchor();
        self.transition = null;
        self.visible = t.final;
        const st = self.store.read(cx);
        self.layout = graph.layoutGraph(self.view_arena.allocator(), self.visible, st.head_sha) catch .{};
        self.list.resetWithUniformHeight(self.visible.len + @intFromBool(st.hasLoadMore()), px(graph.row_height));
        self.restoreScrollAnchor(anchor);
        cx.notify();
    }

    const ScrollAnchor = struct { sha_buf: [64]u8 = undefined, sha_len: usize = 0, offset: f32 = 0 };

    /// `current_scroll_anchor`: the first visible row's sha + the offset into it.
    fn scrollAnchor(self: *const HistoryPane) ?ScrollAnchor {
        const top = self.list.logicalScrollTop();
        if (top.item_ix >= self.visible.len) return null;
        const sha = self.visible[top.item_ix].sha;
        var out: ScrollAnchor = .{ .offset = top.offset_in_item };
        out.sha_len = @min(sha.len, out.sha_buf.len);
        @memcpy(out.sha_buf[0..out.sha_len], sha[0..out.sha_len]);
        return out;
    }

    /// `restore_scroll_anchor`: the same commit stays under the viewport top.
    fn restoreScrollAnchor(self: *HistoryPane, anchor: ?ScrollAnchor) void {
        const an = anchor orelse return;
        const sha = an.sha_buf[0..an.sha_len];
        for (self.visible, 0..) |c, i| if (std.mem.eql(u8, c.sha, sha)) {
            self.list.scrollTo(.{ .item_ix = i, .offset_in_item = an.offset });
            return;
        };
    }

    // ---- interactions -------------------------------------------------------------

    fn onRowClick(self: *HistoryPane, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(HistoryPane)) void {
        if (ix >= self.visible.len) return;
        const c = self.visible[ix];
        cx.emit(OpenCommit{ .sha = c.sha, .subject = c.subject });
    }

    fn onRowHover(self: *HistoryPane, ix: usize, hovered: *const bool, _: *Window, cx: *Context(HistoryPane)) void {
        const key = self.focusKey(cx);
        if (hovered.*) {
            if (ix < self.layout.rows.len) self.hovered_color = self.layout.rows[ix].node_color_id;
            ui.hover.set(cx, key, true);
        } else {
            ui.hover.set(cx, key, false);
        }
        cx.notify();
    }

    fn focusKey(self: *HistoryPane, cx: *Context(HistoryPane)) []const u8 {
        return std.fmt.bufPrint(&self.focus_key_buf, "history-graph-focus-{d}", .{@intFromEnum(cx.entityId())}) catch "history-graph-focus";
    }

    fn graphFocus(self: *HistoryPane, cx: *Context(HistoryPane)) ?Focus {
        const color = self.hovered_color orelse return null;
        const amount = ui.hover.value(cx, self.focusKey(cx));
        if (amount <= 0.001) return null;
        return .{ .color_id = color, .amount = amount };
    }

    fn onShaClick(self: *HistoryPane, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(HistoryPane)) void {
        cx.stopPropagation();
        if (ix >= self.visible.len) return;
        const sha = self.visible[ix].sha;
        _ = window;
        cx.app.platform.vtable.writeClipboard(cx.app.platform.ptr, sha);
        if (self.copied_sha) |s| self.gpa.free(s);
        self.copied_sha = self.gpa.dupe(u8, sha) catch null;
        self.copy_task.cancel();
        self.copy_task = cx.timer(1200 * std.time.ns_per_ms, onCopyExpired) catch .none;
        cx.notify();
    }

    fn onCopyExpired(self: *HistoryPane, cx: *Context(HistoryPane)) void {
        self.copy_task.detach();
        if (self.copied_sha) |s| self.gpa.free(s);
        self.copied_sha = null;
        cx.notify();
    }

    fn onLoadMore(self: *HistoryPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(HistoryPane)) void {
        self.store.update(cx, HistoryStore.loadOlder, .{});
    }

    fn onRefresh(self: *HistoryPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(HistoryPane)) void {
        cx.stopPropagation();
        self.store.update(cx, HistoryStore.refresh, .{});
    }

    fn onFetchAll(self: *HistoryPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(HistoryPane)) void {
        cx.stopPropagation();
        self.store.update(cx, HistoryStore.fetchAll, .{});
    }

    fn onViewToggle(self: *HistoryPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(HistoryPane)) void {
        cx.stopPropagation();
        self.view_mode = if (self.view_mode == .branch_tips) .all_commits else .branch_tips;
        cx.notify();
    }

    fn onFoldBranch(self: *HistoryPane, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(HistoryPane)) void {
        cx.stopPropagation();
        if (ix >= self.visible.len) return;
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        for (self.visible[ix].refs) |r| {
            const key = graph.branchRefKey(arena.allocator(), r) orelse continue;
            if (self.collapsed.fetchRemove(key)) |kv| {
                self.gpa.free(kv.key);
            } else {
                const owned = self.gpa.dupe(u8, key) catch return;
                self.collapsed.put(self.gpa, owned, {}) catch self.gpa.free(owned);
            }
            break;
        }
        self.animate_fold = true; // [motion] `toggle_branch_ref` animates the rows
        cx.notify();
    }

    fn onSearchOpen(self: *HistoryPane, _: *const zpui.ClickEvent, window: *Window, cx: *Context(HistoryPane)) void {
        cx.stopPropagation();
        if (self.search != null) {
            // Reopened mid-collapse: morph back out from the trigger.
            if (self.search_closing) {
                self.search_close_task.cancel();
                self.search_close_task = .none;
                self.search_closing = false;
                self.search_epoch +%= 1;
                window.focus(self.search.?.read(cx).focusHandle());
                cx.notify();
            }
            return;
        }
        self.search_epoch +%= 1;
        self.search_closing = false;
        const theme = ui.theme.get(cx);
        const search = cx.newWith(input.TextInput, input.TextInput.init, .{input.Options{
            .placeholder = "Search commits",
            .key_context = "PaletteSearch",
            .single_line = true,
            .text_size = 11.5,
            .line_height = 14,
            .colors = .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
        }}) catch return;
        self.search_sub = cx.subscribe(search, onSearchEvent) catch null;
        self.search = search;
        window.focus(search.read(cx).focusHandle());
        cx.notify();
    }

    fn closeSearch(self: *HistoryPane, app: *App) void {
        if (self.search_sub) |*s| s.deinit();
        self.search_sub = null;
        if (self.search) |s| s.release(app);
        self.search = null;
    }

    fn onSearchClose(self: *HistoryPane, _: *const zpui.ClickEvent, window: *Window, cx: *Context(HistoryPane)) void {
        cx.stopPropagation();
        self.store.update(cx, HistoryStore.setSearch, .{""});
        self.beginCollapse(window.prefersReducedMotion(), cx);
    }

    /// `begin_collapse`: the expanded control morphs back to the 24 px
    /// trigger over RESIZE, then unmounts its input.
    fn beginCollapse(self: *HistoryPane, reduced: bool, cx: *Context(HistoryPane)) void {
        if (self.search == null or self.search_closing) return;
        if (reduced) {
            self.closeSearch(cx.app);
            cx.notify();
            return;
        }
        self.search_closing = true;
        self.search_epoch +%= 1;
        self.search_close_task.cancel();
        self.search_close_task = cx.timer(zt.motion.resize.totalNs(1.0), onSearchCollapsed) catch blk: {
            self.closeSearch(cx.app);
            break :blk .none;
        };
        cx.notify();
    }

    fn onSearchCollapsed(self: *HistoryPane, cx: *Context(HistoryPane)) void {
        self.search_close_task.detach();
        self.search_close_task = .none;
        if (!self.search_closing) return;
        self.search_closing = false;
        self.closeSearch(cx.app);
        cx.notify();
    }

    fn onSearchEvent(self: *HistoryPane, input_entity: Entity(input.TextInput), ev: *const input.TextInputEvent, cx: *Context(HistoryPane)) void {
        switch (ev.*) {
            .edited => {
                const q = input_entity.read(cx).text();
                self.store.update(cx, HistoryStore.setSearch, .{q});
            },
            .escape => {
                self.store.update(cx, HistoryStore.setSearch, .{""});
                const reduced = if (cx.app.windows.items.len > 0) (if (cx.app.windows.items[0]) |w| w.prefersReducedMotion() else false) else false;
                self.beginCollapse(reduced, cx);
            },
            else => {},
        }
    }

    fn onColumnsButton(self: *HistoryPane, ev: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(HistoryPane)) void {
        window.preventDefault();
        cx.stopPropagation();
        self.closeMenuAt(&self.author_menu_at, &self.author_exit, cx);
        if (self.column_menu_at == null or self.column_exit.isClosing()) {
            self.column_menu_at = ev.position;
            self.column_exit.clear();
        } else self.closeMenuAt(&self.column_menu_at, &self.column_exit, cx);
        cx.notify();
    }

    fn onAuthorRightClick(self: *HistoryPane, ev: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(HistoryPane)) void {
        window.preventDefault();
        cx.stopPropagation();
        self.closeMenuAt(&self.column_menu_at, &self.column_exit, cx);
        self.author_menu_at = ev.position;
        self.author_exit.clear();
        cx.notify();
    }

    fn onMenuOutside(self: *HistoryPane, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(HistoryPane)) void {
        self.closeMenuAt(&self.column_menu_at, &self.column_exit, cx);
        self.closeMenuAt(&self.author_menu_at, &self.author_exit, cx);
        cx.notify();
    }

    /// `begin_close` for a positioned menu: it plays MENU_OUT, then the
    /// render drops it (reduced motion drops it at once).
    fn closeMenuAt(_: *HistoryPane, slot: *?zpui.Point(f32), exit: *ui.popover.Exit, cx: *Context(HistoryPane)) void {
        if (slot.* == null or exit.isClosing()) return;
        if (ui.popover.appReduced(cx.app)) {
            slot.* = null;
            return;
        }
        if (exit.begin(cx.app.executor.now())) ui.popover.reap(HistoryPane, cx);
    }

    /// Per frame: drop a finished exit; the exit progress (null while open).
    fn menuExit(slot: *?zpui.Point(f32), exit: *ui.popover.Exit, now: u64) ?f32 {
        if (exit.done(now)) {
            exit.clear();
            slot.* = null;
        }
        return exit.progress(now);
    }

    fn onToggleColumn(self: *HistoryPane, col: Column, _: *const zpui.ClickEvent, _: *Window, cx: *Context(HistoryPane)) void {
        cx.stopPropagation();
        switch (col) {
            .author => self.show_author = !self.show_author,
            .date => self.show_date = !self.show_date,
            .sha => self.show_sha = !self.show_sha,
        }
        const Set = struct {
            fn set(v: [3]bool, s: *model.UiSettings, _: Allocator) void {
                s.gitHistoryColumns.author = v[0];
                s.gitHistoryColumns.date = v[1];
                s.gitHistoryColumns.sha = v[2];
            }
        };
        _ = model.settings_store.update(cx.app, .immediate, [3]bool{ self.show_author, self.show_date, self.show_sha }, Set.set);
        cx.notify();
    }

    fn onToggleAuthorDisplay(self: *HistoryPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(HistoryPane)) void {
        cx.stopPropagation();
        self.author_name_mode = !self.author_name_mode;
        self.closeMenuAt(&self.author_menu_at, &self.author_exit, cx);
        const Set = struct {
            fn set(v: bool, s: *model.UiSettings, _: Allocator) void {
                s.gitHistoryAuthorDisplay = if (v) .name else .avatar;
            }
        };
        _ = model.settings_store.update(cx.app, .immediate, self.author_name_mode, Set.set);
        cx.notify();
    }

    fn onHoverKey(_: *HistoryPane, key: []const u8, hovered: *const bool, _: *Window, cx: *Context(HistoryPane)) void {
        ui.hover.set(cx, key, hovered.*);
    }

    fn preventDefault(_: *const zpui.input.MouseDownEvent, window: *Window, _: *App) void {
        window.preventDefault();
    }

    fn onKey(self: *HistoryPane, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Context(HistoryPane)) void {
        const key = ev.keystroke.key;
        if (std.mem.eql(u8, key, "down")) {
            self.list.scrollBy(graph.row_height);
        } else if (std.mem.eql(u8, key, "up")) {
            self.list.scrollBy(-graph.row_height);
        } else if (std.mem.eql(u8, key, "pagedown")) {
            self.list.scrollBy(self.list.viewportBounds().size.height - graph.row_height);
        } else if (std.mem.eql(u8, key, "pageup")) {
            self.list.scrollBy(-(self.list.viewportBounds().size.height - graph.row_height));
        } else if (std.mem.eql(u8, key, "home")) {
            self.list.scrollTo(.{});
        } else if (std.mem.eql(u8, key, "end")) {
            self.list.scrollToEnd();
        } else if (std.mem.eql(u8, key, "escape")) {
            if ((self.column_menu_at == null or self.column_exit.isClosing()) and (self.author_menu_at == null or self.author_exit.isClosing())) return;
            self.closeMenuAt(&self.column_menu_at, &self.column_exit, cx);
            self.closeMenuAt(&self.author_menu_at, &self.author_exit, cx);
        } else return;
        cx.stopPropagation();
        cx.notify();
    }

    // ---- toolbar ------------------------------------------------------------------

    fn headerButton(id: []const u8, i: Icon, label: []const u8, theme: *const Theme, cx: *Context(HistoryPane)) zpui.StatefulDiv {
        return headerButtonTinted(id, i, label, theme.text_muted.opacity(0.7), theme, cx);
    }

    fn headerButtonTinted(id: []const u8, i: Icon, label: []const u8, tint: Hsla, theme: *const Theme, cx: *Context(HistoryPane)) zpui.StatefulDiv {
        return div().id(id).role(.button).ariaLabel(label).size(px(control_size)).flexNone().flex().itemsCenter().justifyCenter()
            .rounded(px(control_radius)).cursorPointer()
            .bg(ui.hover.blend(cx, id, theme.wash(0), theme.wash(0.14)))
            .onHover(cx.listenerWith(id, onHoverKey))
            .occlude().onMouseDown(.left, preventDefault)
            .tooltipWith(label, ui.tooltip.build).tooltipShowDelay(350 * std.time.ns_per_ms)
            .child(ui.icon.of(i, icon_size, tint));
    }

    const CountQuery = struct {
        theme: *const Theme,
        count: ?usize,
        comparison: ?struct { base: []const u8, ahead: u64, behind: u64 },

        /// `GitHistoryCount`: the ahead/behind comparison only shows once the
        /// count's own container is `comparison_min_width` wide.
        fn render(q: CountQuery, size: zpui.Size(f32), _: *Window, _: *App) zpui.Div {
            const theme = q.theme;
            var row = div().sizeFull().minW0().flex().itemsCenter().gap(px(10));
            if (q.count) |n| row = row.child(div().flexNone().whitespaceNowrap().textSize(px(11)).lineHeight(px(14)).textColor(theme.text_muted)
                .child(zpui.fmt("{d} commit{s}", .{ n, if (n == 1) "" else "s" })));
            if (size.width >= graph.comparison_min_width) if (q.comparison) |cmp| {
                var c = div().id("history-comparison").relative().top(px(1)).flexNone().flex().itemsCenter().gap(px(4))
                    .tooltipWith(zpui.fmt("Compared with {s}: {d} ahead, {d} behind", .{ cmp.base, cmp.ahead, cmp.behind }), ui.tooltip.build);
                if (cmp.ahead > 0) c = c.child(div().whitespaceNowrap().textSize(px(10.5)).lineHeight(px(13)).textColor(theme.accent.opacity(0.88)).child(zpui.fmt("{d} ahead", .{cmp.ahead})));
                if (cmp.ahead > 0 and cmp.behind > 0) c = c.child(div().textSize(px(10)).textColor(theme.text_faint).child("\u{00b7}"));
                if (cmp.behind > 0) c = c.child(div().whitespaceNowrap().textSize(px(10.5)).lineHeight(px(13)).textColor(theme.warning.opacity(0.82)).child(zpui.fmt("{d} behind", .{cmp.behind})));
                row = row.child(c);
            };
            return row;
        }
    };

    fn countLabel(self: *HistoryPane, theme: *const Theme, cx: *Context(HistoryPane)) zpui.Div {
        const st = self.store.read(cx);
        var q: CountQuery = .{
            .theme = theme,
            .count = if (st.searchActive()) (st.search_total orelse self.visible.len) else st.commitCount(),
            .comparison = null,
        };
        if (st.comparison) |cmp| if (cmp.ahead > 0 or cmp.behind > 0) {
            q.comparison = .{ .base = frame().dupe(u8, cmp.base) catch "", .ahead = cmp.ahead, .behind = cmp.behind };
        };
        return div().hFull().minW0().flex1().flex().itemsCenter().overflowHidden()
            .child(zpui.containerQuery(q, CountQuery.render));
    }

    fn searchControl(self: *HistoryPane, theme: *const Theme, window: *Window, cx: *Context(HistoryPane)) AnyElement {
        const search = self.search orelse return zpui.intoAnyElement(headerButtonTinted("history-search-trigger", .magnifer, "Search commits", theme.text_muted, theme, cx)
            .onClick(cx.listener(onSearchOpen)));
        const st = self.store.read(cx);
        const status: AnyElement = if (st.search_loading) blk: {
            window.requestAnimationFrame();
            break :blk zpui.intoAnyElement(ui.loaders.miniGlyphSpinner(1.5, theme.glyph.rows(), ui.loaders.phaseOf(cx, zt.motion.gradient_spin)));
        } else zpui.intoAnyElement(ui.icon.of(.magnifer, 11, theme.text_faint));
        const control = div().id("history-search-expanded").h(px(control_size)).w(px(graph.search_width)).minW(px(80)).flexShrink(1)
            .overflowHidden().flex().itemsCenter().gap(px(6)).pl(px(edge_inset)).pr(px(2))
            .rounded(px(control_radius)).bg(theme.ink(0.035))
            .child(div().size(px(14)).flexNone().flex().itemsCenter().justifyCenter().child(status))
            .child(div().h(px(14)).flex1().minW0().flex().itemsCenter().overflowHidden().child(search))
            .child(div().id("history-search-close").role(.button).ariaLabel("Close search").size(px(16)).flexNone().flex().itemsCenter().justifyCenter()
                .rounded(px(3.5)).cursorPointer().hover(sb.bg(theme.ink(0.08)))
                .onMouseDown(.left, preventDefault)
                .onClick(cx.listener(onSearchClose))
                .tooltipWith(@as([]const u8, "Close search"), ui.tooltip.build)
                .child(ui.icon.of(.close, 9, theme.text_faint)));
        // `history-search-morph-{epoch}-{in|out}`: width 24 ↔ full, opacity .45 ↔ 1.
        const Morph = struct {
            fn f(closing: bool, el: zpui.StatefulDiv, t: f32) zpui.StatefulDiv {
                const amount = if (closing) 1 - t else t;
                return el.w(px(24 + (graph.search_width - 24) * amount)).opacity(0.45 + 0.55 * amount);
            }
        };
        return zpui.intoAnyElement(zpui.withAnimationCtx(control, .{ "history-search-morph", self.search_epoch * 2 + @intFromBool(self.search_closing) }, zt.motion.resize.animation(), self.search_closing, Morph.f));
    }

    fn fetchButton(self: *HistoryPane, theme: *const Theme, window: *Window, cx: *Context(HistoryPane)) zpui.StatefulDiv {
        const fetching = self.store.read(cx).fetching_all;
        const key = "history-fetch-all";
        var b = div().id(key).role(.button).ariaDisabled(fetching).h(px(control_size)).px(px(8)).flexNone().flex().itemsCenter().justifyCenter().gap(px(6))
            .rounded(px(control_radius))
            .bg(if (fetching) theme.wash(0.05) else ui.hover.blend(cx, key, theme.wash(0), theme.wash(0.14)))
            .occlude().onMouseDown(.left, preventDefault);
        if (!fetching) b = b.cursorPointer().onHover(cx.listenerWith(@as([]const u8, key), onHoverKey)).onClick(cx.listener(onFetchAll));
        const glyph: AnyElement = if (fetching) blk: {
            window.requestAnimationFrame();
            break :blk zpui.intoAnyElement(ui.loaders.miniGlyphSpinner(1.75, theme.glyph.rows(), ui.loaders.phaseOf(cx, zt.motion.gradient_spin)));
        } else zpui.intoAnyElement(ui.icon.of(.cloud, icon_size, theme.text_muted.opacity(0.75)));
        return b.child(glyph).child(div().whitespaceNowrap().textSize(px(11)).textColor(if (fetching) theme.text_faint else theme.text_muted)
            .child(if (fetching) "Fetching\u{2026}" else "Fetch all"));
    }

    fn viewButton(self: *HistoryPane, theme: *const Theme, cx: *Context(HistoryPane)) zpui.StatefulDiv {
        const tips = self.view_mode == .branch_tips;
        const key = "history-view-trigger";
        return div().id(key).role(.button).ariaLabel(if (tips) "Show all commits" else "Show branch tips").ariaToggled(tips).size(px(control_size)).flexNone().flex().itemsCenter().justifyCenter()
            .rounded(px(control_radius)).cursorPointer()
            .bg(if (tips) theme.accent.opacity(0.12) else ui.hover.blend(cx, key, theme.wash(0), theme.wash(0.14)))
            .onHover(cx.listenerWith(@as([]const u8, key), onHoverKey))
            .occlude().onMouseDown(.left, preventDefault)
            .onClick(cx.listener(onViewToggle))
            .tooltipWith(@as([]const u8, if (tips) "Show all commits" else "Show branch tips"), ui.tooltip.build).tooltipShowDelay(350 * std.time.ns_per_ms)
            .child(ui.icon.of(.fold_vertical, icon_size, if (tips) theme.accent else theme.text_muted));
    }

    /// The pane-header controls (Rust renders them in the Changes toolbar).
    pub fn renderHeaderControls(self: *HistoryPane, theme: *const Theme, window: *Window, cx: *Context(HistoryPane)) zpui.Div {
        // The branch name overflows into its padding and clips there (no
        // ellipsis), exactly like the reference.
        const title = div().id("history-surface-title").minW0().maxW(px(160)).overflowHidden().whitespaceNowrap()
            .h(px(control_size)).px(px(8)).flexShrink(1).flex().itemsCenter()
            .fontFamily(theme.font_mono).textSize(px(11.5)).lineHeight(px(14)).textColor(theme.text_dim)
            .child(self.branchLabel(cx));
        return div().sizeFull().flex().flexRow().itemsCenter().gap(px(control_gap))
            .child(title)
            .child(self.countLabel(theme, cx))
            .child(div().minW0().flexShrink(1).flex().itemsCenter().gap(px(control_gap))
                .child(self.searchControl(theme, window, cx))
                .child(self.fetchButton(theme, window, cx))
                .child(self.viewButton(theme, cx))
                .child(headerButton("history-refresh", .refresh, "Refresh", theme, cx).onClick(cx.listener(onRefresh))));
    }

    pub fn toolbar(self: *HistoryPane, theme: *const Theme, window: *Window, cx: *Context(HistoryPane)) zpui.Div {
        return div().h(px(header_height)).wFull().flexNone().px(px(edge_inset)).flex().itemsCenter().gap(px(control_gap))
            .borderT1().borderB1().borderColor(theme.border)
            .bg(if (theme.isGlass()) theme.surface.opacity(0.26) else theme.surface)
            .child(self.renderHeaderControls(theme, window, cx));
    }

    // ---- rows ---------------------------------------------------------------------

    fn palette(theme: *const Theme) [6]Hsla {
        var p = [6]Hsla{ theme.accent, theme.busy, theme.success, theme.warning, theme.danger, theme.text_muted };
        for (&p) |*c| c.s *= graph.graph_saturation;
        return p;
    }

    fn graphCell(self: *HistoryPane, ix: usize, focus: ?Focus, theme: *const Theme, cx: *Context(HistoryPane)) zpui.StatefulDiv {
        const row = self.layout.rows[ix];
        const geo = self.geometry;
        const pal = palette(theme);
        var color = pal[row.node_color_id % pal.len];
        const selected = if (focus) |f| f.color_id == row.node_color_id else false;
        if (focus) |f| if (!selected) {
            color.a *= 1 - (1 - graph.unfocused_opacity) * f.amount;
        };
        const r = graph.node_radius + (if (focus) |f| (if (selected) f.amount * 0.75 else 0) else 0);
        const x = geo.laneX(row.node_lane);
        const h = graph.row_height;
        var cell = div().id(.{ "history-graph-cell", ix }).relative().group("history-graph-tip")
            .w(px(geo.width)).h(px(h)).flexNone();
        if (row.is_head) cell = cell.child(div().absolute().left(px(x - r - graph.head_ring_padding)).top(px(h / 2 - r - graph.head_ring_padding))
            .size(px((r + graph.head_ring_padding) * 2)).roundedFull().border1().borderColor(color).bg(theme.bg));
        cell = cell.child(div().absolute().left(px(x - r)).top(px(h / 2 - r)).size(px(r * 2)).roundedFull().bg(color));
        // Branch fold knob (appears on hover; held while collapsed).
        if (self.view_mode == .all_commits and ix < self.visible.len) {
            for (self.visible[ix].refs) |ref| {
                const key = graph.branchRefKey(frame(), ref) orelse continue;
                const is_collapsed = self.collapsed.contains(key);
                const hidden = self.hidden_counts.get(key) orelse 0;
                const tip = if (is_collapsed)
                    (if (hidden == 0) zpui.fmt("Expand {s}", .{ref.label}) else zpui.fmt("Expand {s} ({d} hidden)", .{ ref.label, hidden }))
                else
                    zpui.fmt("Collapse {s}", .{ref.label});
                var knob = div().id(.{ "history-graph-fold", ix }).role(.button).ariaLabel(tip).ariaExpanded(!is_collapsed).absolute().left(px(x + graph.node_radius + 3)).top(px((h - 16) / 2))
                    .size(px(16)).flex().itemsCenter().justifyCenter().roundedFull()
                    .border1().borderColor(color.opacity(0.32)).bg(theme.bg.opacity(0.96)).cursorPointer()
                    .onMouseDown(.left, preventDefault)
                    .onClick(cx.listenerWith(ix, onFoldBranch))
                    .tooltipWith(tip, ui.tooltip.build).tooltipShowDelay(250 * std.time.ns_per_ms)
                    .child(ui.icon.of(if (is_collapsed) .expand_arrows else .fold_vertical, 9, color.opacity(0.9)));
                knob = if (is_collapsed) knob else knob.opacity(0).groupHover("history-graph-tip", sb.opacity(1));
                cell = cell.child(knob);
                break;
            }
        }
        return cell;
    }

    fn refColor(kind: types.GitHistoryRefKind, theme: *const Theme) Hsla {
        return switch (kind) {
            .branch => theme.accent,
            .remote => theme.busy,
            .tag => theme.warning,
        };
    }

    fn refIcon(kind: types.GitHistoryRefKind) Icon {
        return switch (kind) {
            .branch => .git_branch,
            .remote => .cloud,
            .tag => .tag,
        };
    }

    fn refDescription(r: types.GitHistoryRef) []const u8 {
        const kind = switch (r.kind) {
            .branch => "Branch",
            .remote => "Remote branch",
            .tag => "Tag",
        };
        return zpui.fmt("{s}: {s}", .{ kind, r.label });
    }

    fn refArea(refs: []const types.GitHistoryRef, ix: usize, available: f32, theme: *const Theme) zpui.Div {
        const n = graph.visibleRefCount(refs, available);
        var area = div().maxW(px(available)).minW0().overflowHidden().flex().itemsCenter().gap(px(graph.ref_gap));
        for (refs[0..n], 0..) |r, ri| {
            const color = refColor(r.kind, theme);
            area = area.child(div().id(.{ "history-ref", ix * 64 + ri }).h(px(16)).maxW(px(graph.ref_badge_max_width)).px(px(5)).flexNone()
                .flex().itemsCenter().gap(px(2)).rounded(px(4)).bg(color.opacity(0.07))
                .textSize(px(10)).textColor(color.opacity(0.9))
                .tooltipWith(refDescription(r), ui.tooltip.build).tooltipShowDelay(350 * std.time.ns_per_ms)
                .child(ui.icon.of(refIcon(r.kind), 10, color.opacity(0.78)).mt(px(1)))
                .child(div().minW0().truncate().whitespaceNowrap().child(r.label)));
        }
        if (refs.len > n) {
            var desc: std.ArrayList(u8) = .empty;
            for (refs[n..], 0..) |r, i| {
                if (i > 0) desc.appendSlice(frame(), " · ") catch {};
                desc.appendSlice(frame(), refDescription(r)) catch {};
            }
            area = area.child(div().id(.{ "history-ref-overflow", ix }).flexNone().textSize(px(10)).textColor(theme.text_faint)
                .tooltipWith(@as([]const u8, desc.items), ui.tooltip.build).tooltipShowDelay(350 * std.time.ns_per_ms)
                .child(zpui.fmt("+{d}", .{refs.len - n})));
        }
        return area;
    }

    /// The commit column: refs get `ref_area_width` of the column's laid-out width.
    const CommitQuery = struct {
        theme: *const Theme,
        subject: []const u8,
        refs: []const types.GitHistoryRef,
        ix: usize,
        opacity: f32,

        fn render(q: CommitQuery, size: zpui.Size(f32), _: *Window, _: *App) zpui.Div {
            var col = div().sizeFull().flex().itemsCenter().gap(px(graph.ref_gap)).pr(px(8)).opacity(q.opacity)
                .child(div().flex1().minW0().truncate().whitespaceNowrap().textSize(px(12)).textColor(q.theme.text).child(q.subject));
            if (q.refs.len > 0) col = col.child(refArea(q.refs, q.ix, graph.refAreaWidth(size.width), q.theme));
            return col;
        }
    };

    pub fn renderRow(self: *HistoryPane, ix: usize, _: *Window, cx: *Context(HistoryPane)) AnyElement {
        const theme = arenaTheme(ui.theme.get(cx).*);
        if (ix >= self.visible.len) return self.loadMoreRow(theme, cx);
        if (ix >= self.layout.rows.len) return zpui.empty();
        const c = self.visible[ix];
        const grow = self.layout.rows[ix];
        const focus = self.graphFocus(cx);
        const focused = if (focus) |f| f.color_id == grow.node_color_id else false;
        const content_opacity: f32 = if (focus) |f| (if (!focused) 1 - (1 - graph.row_unfocused_opacity) * f.amount else 1) else 1;
        const a = frame();
        var row = div().id(.{ "history-row", ix }).role(.button).ariaLabel(c.subject).h(px(graph.row_height)).wFull().flexNone().flex().flexRow().itemsCenter()
            .textSize(px(11)).cursorPointer()
            .hover(sb.bg(theme.ink(0.025)))
            .onHover(cx.listenerWith(ix, onRowHover))
            .onClick(cx.listenerWith(ix, onRowClick));
        if (focus) |f| if (focused) {
            row = row.bg(theme.ink(0.018 * f.amount));
        };
        const subject = if (c.subject.len == 0) "(no subject)" else c.subject;
        const commit_col = zpui.containerQuery(CommitQuery{ .theme = theme, .subject = subject, .refs = c.refs, .ix = ix, .opacity = content_opacity }, CommitQuery.render)
            .flex1().minW(px(graph.subject_min_width)).hFull().overflowHidden();
        row = row.child(self.graphCell(ix, focus, theme, cx)).child(commit_col);
        var cells = div().hFull().flex().flexRow().flexShrink(1);
        if (self.show_author) {
            var author = div().w(px(self.author_w)).minW(px(graph.author_min)).hFull().flexShrink(1).flex().itemsCenter().opacity(content_opacity);
            const name = graph.authorName(c.authorName);
            if (self.author_name_mode) {
                author = author.pr(px(8)).truncate().whitespaceNowrap().textColor(theme.text_muted).child(name);
            } else {
                author = author.justifyCenter().child(div().id(.{ "history-author-avatar", ix }).size(px(20)).flexNone().flex().itemsCenter().justifyCenter()
                    .overflowHidden().roundedFull().border1().borderColor(theme.hairline(0.12)).bg(theme.wash(0.08))
                    .tooltipWith(name, ui.tooltip.build).tooltipShowDelay(300 * std.time.ns_per_ms)
                    .child(div().wFull().textCenter().fontFamily(theme.font_sans).textSize(px(9)).lineHeight(px(18)).relative().top(px(0.5))
                        .textColor(theme.text_faint).child(graph.authorInitial(a, name))));
            }
            cells = cells.child(author);
        }
        if (self.show_date) cells = cells.child(div().w(px(self.date_w)).minW(px(graph.date_min)).hFull().flexShrink(1).flex().itemsCenter()
            .truncate().whitespaceNowrap().pr(px(8)).textSize(px(10.5)).opacity(content_opacity).textColor(theme.text_muted)
            .child(graph.formatDate(a, c.authoredAt)));
        if (self.show_sha) {
            const copied = if (self.copied_sha) |s| std.mem.eql(u8, s, c.sha) else false;
            cells = cells.child(div().w(px(self.sha_w)).minW(px(graph.sha_min)).hFull().pr(px(6)).flexShrink(1).flex().itemsCenter().opacity(content_opacity)
                .child(div().id(.{ "history-sha", ix }).role(.button).ariaLabel(if (copied) "Copied" else zpui.fmt("Copy {s}", .{c.sha[0..@min(7, c.sha.len)]})).wFull().h(px(24)).flex().itemsCenter().rounded(px(4)).cursorPointer()
                    .hover(sb.bg(theme.ink(0.07))).fontFamily(theme.font_mono).textSize(px(10.5))
                    .textColor(if (copied) theme.accent else theme.text_muted)
                    .onClick(cx.listenerWith(ix, onShaClick))
                    .child(if (copied) "Copied" else c.sha[0..@min(7, c.sha.len)])));
        }
        const done = zpui.intoAnyElement(row.child(cells));
        // [motion] `history-row-fold-{epoch}-{sha}-{in|out}`: COLLAPSE height
        // 36·k with opacity .35 → 1 for rows entering / leaving a fold.
        if (self.transition) |t| if (ix < t.rows.len and t.rows[ix] != .stable) {
            const entering = t.rows[ix] == .entering;
            const Fold = struct {
                fn f(enter: bool, el: zpui.Div, k: f32) zpui.Div {
                    const amount = if (enter) k else 1 - k;
                    return el.h(px(graph.row_height * amount)).opacity(0.35 + 0.65 * amount);
                }
            };
            return zpui.intoAnyElement(zpui.withAnimationCtx(div().wFull().flexNone().overflowHidden().child(done), .{ "history-row-fold", std.hash.Wyhash.hash(self.view_epoch *% 2 +% @intFromBool(entering), c.sha) }, zt.motion.collapse.animation(), entering, Fold.f));
        };
        return done;
    }

    fn loadMoreRow(self: *HistoryPane, theme: *const Theme, cx: *Context(HistoryPane)) AnyElement {
        const st = self.store.read(cx);
        const pending = st.loading;
        const has_error = st.error_message != null;
        const label: []const u8 = if (pending) "Loading\u{2026}" else if (has_error) "Retry" else "Load more";
        var b = div().id("history-load-older").h(px(28)).px(px(11)).flex().itemsCenter().justifyCenter().gap(px(6))
            .rounded(px(7)).border1().borderColor(theme.border.opacity(0.85)).bg(theme.surface_raised.opacity(0.72))
            .textSize(px(11)).textColor(if (pending) theme.text_faint else theme.text_muted);
        if (!pending) b = b.cursorPointer()
            .hover(sb.bg(theme.element_hover).borderColor(theme.border_strong.opacity(0.75)).textColor(theme.text))
            .onClick(cx.listener(onLoadMore))
            .child(ui.icon.of(if (has_error) .refresh else .alt_arrow_down, 11, theme.text_faint));
        return zpui.intoAnyElement(div().wFull().h(px(48)).flexNone().flex().itemsCenter().justifyCenter().child(b.child(label)));
    }

    // ---- graph canvas -------------------------------------------------------------

    const GraphPaint = struct {
        rows: []const graph.Row,
        list: zpui.ListState,
        geometry: graph.Geometry,
        palette: [6]Hsla,
        bg: Hsla,
        focus: ?Focus,
        compact_rail: bool,
    };

    const Emitter = struct {
        path: *zpui.scene.Path,
        a: Allocator,
        any: bool = false,
        pub fn triangle(self: *Emitter, p0: graph.Pt, p1: graph.Pt, p2: graph.Pt) void {
            self.path.pushTriangle(self.a, .{ .{ .x = p0.x, .y = p0.y }, .{ .x = p1.x, .y = p1.y }, .{ .x = p2.x, .y = p2.y } }, .{ .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 1 } }) catch {};
            self.any = true;
        }
    };

    fn paintGraph(g: GraphPaint, viewport: zpui.Bounds(f32), window: *Window, _: *App) void {
        const a = frame();
        const passes: usize = if (g.focus != null) 2 else 1;
        for (0..passes) |pass| {
            const selected_pass = g.focus != null and pass == 1;
            for (g.palette, 0..) |color, color_ix| {
                const width = if (selected_pass) graph.stroke_width + (graph.focused_stroke_width - graph.stroke_width) * g.focus.?.amount else graph.stroke_width;
                var path = zpui.scene.Path.init(.{ .x = viewport.origin.x, .y = viewport.origin.y });
                var em: Emitter = .{ .path = &path, .a = a };
                for (g.rows, 0..) |row, ix| {
                    const rb = g.list.boundsForItem(ix) orelse continue;
                    if (rb.origin.y + rb.size.height < viewport.origin.y or rb.origin.y > viewport.origin.y + viewport.size.height) continue;
                    const h = rb.size.height;
                    if (h <= 0.5) continue;
                    const mid = h / 2;
                    const overlap = graph.row_overlap * std.math.clamp(h / graph.row_height, 0, 1);
                    const ox = rb.origin.x;
                    const oy = rb.origin.y;
                    if (g.geometry.compact and g.compact_rail) {
                        if (row.node_color_id % g.palette.len != color_ix) continue;
                        if (g.focus) |f| if ((row.node_color_id == f.color_id) != selected_pass) continue;
                        const x = ox + g.geometry.laneX(0);
                        const end_y = if (g.list.boundsForItem(ix + 1)) |nb| nb.origin.y + nb.size.height / 2 else oy + h;
                        graph.strokeQuads(&.{ .{ .x = x, .y = oy + mid }, .{ .x = x, .y = end_y } }, width, &em);
                        continue;
                    }
                    for (row.segments) |seg| {
                        if (seg.color_id % g.palette.len != color_ix) continue;
                        if (g.focus) |f| if ((seg.color_id == f.color_id) != selected_pass) continue;
                        const fx = ox + g.geometry.laneX(seg.from_lane);
                        const tx = ox + g.geometry.laneX(seg.to_lane);
                        var buf: [17]graph.Pt = undefined;
                        switch (seg.shape) {
                            .incoming => graph.strokeQuads(graph.flattenCubic(&buf, .{ .x = fx, .y = oy - overlap }, .{ .x = fx, .y = oy + mid * 0.55 }, .{ .x = tx, .y = oy + mid * 0.55 }, .{ .x = tx, .y = oy + mid }), width, &em),
                            .outgoing => graph.strokeQuads(graph.flattenCubic(&buf, .{ .x = fx, .y = oy + mid }, .{ .x = fx, .y = oy + mid * 1.45 }, .{ .x = tx, .y = oy + mid * 1.45 }, .{ .x = tx, .y = oy + h + overlap }), width, &em),
                            .through => if (seg.from_lane == seg.to_lane)
                                graph.strokeQuads(&.{ .{ .x = fx, .y = oy - overlap }, .{ .x = tx, .y = oy + h + overlap } }, width, &em)
                            else
                                graph.strokeQuads(graph.flattenCubic(&buf, .{ .x = fx, .y = oy - overlap }, .{ .x = fx, .y = oy + mid }, .{ .x = tx, .y = oy + mid }, .{ .x = tx, .y = oy + h + overlap }), width, &em),
                        }
                    }
                }
                if (!em.any) continue;
                var paint = color;
                if (g.focus) |f| if (!selected_pass) {
                    paint = zt.colorspace.mix(paint, g.bg, (1 - graph.unfocused_opacity) * f.amount);
                };
                window.paintPath(path, paint);
            }
        }
    }

    // ---- menus --------------------------------------------------------------------

    fn menuOption(theme: *const Theme, id: anytype, label: []const u8, checked: bool) zpui.StatefulDiv {
        return ui.popover.menuRow(theme, false).id(id).role(.menu_item).gap(px(0)).px(px(7)).py(px(4)).rounded(px(9 - ui.popover.card_inset)).textSize(px(11.5))
            .child(div().flex1().child(label))
            .child(div().w(px(12)).flexNone().flex().justifyEnd().child(if (checked) ui.icon.of(.check, 10, theme.text_muted) else null));
    }

    fn columnMenu(self: *HistoryPane, at: zpui.Point(f32), exit: ?f32, base: *const Theme, cx: *Context(HistoryPane)) AnyElement {
        const theme = arenaTheme(base.forPopup());
        const card = ui.popover.card(theme).w(px(132)).rounded(px(9)).onMouseDownOut(cx.listener(onMenuOutside))
            .child(div().flex().flexCol().gap(px(ui.popover.menu_gap))
                .child(menuOption(theme, "history-column-author", "Author", self.show_author).onClick(cx.listenerWith(Column.author, onToggleColumn)))
                .child(menuOption(theme, "history-column-date", "Date", self.show_date).onClick(cx.listenerWith(Column.date, onToggleColumn)))
                .child(menuOption(theme, "history-column-sha", "SHA", self.show_sha).onClick(cx.listenerWith(Column.sha, onToggleColumn))));
        return ui.popover.anchoredAtExit(at, card, exit);
    }

    fn authorMenu(self: *HistoryPane, at: zpui.Point(f32), exit: ?f32, base: *const Theme, cx: *Context(HistoryPane)) AnyElement {
        const theme = arenaTheme(base.forPopup());
        const card = ui.popover.card(theme).w(px(116)).rounded(px(9)).onMouseDownOut(cx.listener(onMenuOutside))
            .child(menuOption(theme, "history-author-display-name", "Name", self.author_name_mode).onClick(cx.listener(onToggleAuthorDisplay)));
        return ui.popover.anchoredAtExit(at, card, exit);
    }

    // ---- render -------------------------------------------------------------------

    fn columnHeader(self: *HistoryPane, theme: *const Theme, cx: *Context(HistoryPane)) zpui.StatefulDiv {
        var cols = div().hFull().flex().flexRow().flexShrink(1);
        var left: DataColumn = .commit;
        if (self.show_author) {
            cols = cols.child(div().id("history-author-header").relative().w(px(self.author_w)).minW(px(graph.author_min)).hFull().flexShrink(1)
                .flex().itemsCenter().justifyCenter().cursorPointer().onMouseDown(.right, cx.listener(onAuthorRightClick)).child("Author")
                .child(self.resizeHandle(left, .author, theme, cx)));
            left = .author;
        }
        if (self.show_date) {
            cols = cols.child(div().relative().w(px(self.date_w)).minW(px(graph.date_min)).hFull().flexShrink(1).flex().itemsCenter().child("Date")
                .child(self.resizeHandle(left, .date, theme, cx)));
            left = .date;
        }
        if (self.show_sha) cols = cols.child(div().relative().w(px(self.sha_w)).minW(px(graph.sha_min)).hFull().flexShrink(1).flex().itemsCenter().child("SHA")
            .child(self.resizeHandle(left, .sha, theme, cx)));
        var button = div().id("history-columns-button").role(.button).ariaLabel("Columns").absolute().right(px(3)).top(px(2)).size(px(20)).flex().itemsCenter().justifyCenter()
            .rounded(px(5)).cursorPointer().hover(sb.bg(theme.ink(0.08)))
            .onMouseDown(.left, cx.listener(onColumnsButton))
            .tooltipWith(@as([]const u8, "Columns"), ui.tooltip.build).tooltipShowDelay(350 * std.time.ns_per_ms)
            .child(ui.icon.of(.checklist, 12, theme.text_muted));
        button = if (self.column_menu_at != null) button else button.opacity(0).groupHover("history-column-header", sb.opacity(1));
        return div().id("history-column-header").group("history-column-header").relative().h(px(24)).flexNone().flex().itemsCenter()
            .borderB1().borderColor(theme.hairline(0.06)).textSize(px(9.5)).textColor(theme.text_faint)
            .child(div().w(px(self.geometry.width)).flexNone())
            .child(div().flex1().minW(px(80)).child("Commit"))
            .child(cols).child(button);
    }

    fn resizeHandle(self: *HistoryPane, left: DataColumn, right: DataColumn, theme: *const Theme, cx: *Context(HistoryPane)) zpui.StatefulDiv {
        _ = self;
        const pair: [2]DataColumn = .{ left, right };
        return div().id(.{ "history-resize", @as(usize, @intFromEnum(left)) * 4 + @intFromEnum(right) }).role(.separator).ariaLabel("Resize column").ariaOrientation(.vertical)
            .absolute().left(px(-3)).top(px(0)).bottom(px(0)).w(px(6)).cursorColResize()
            .hover(sb.bg(theme.border_strong.opacity(0.7)))
            .onMouseDown(.left, cx.listenerWith(pair, onResizeDown))
            .onDrag(ColumnResize{}, buildResizeGhost);
    }

    fn widthOf(self: *const HistoryPane, c: DataColumn) f32 {
        return switch (c) {
            .commit => graph.subject_min_width,
            .author => self.author_w,
            .date => self.date_w,
            .sha => self.sha_w,
        };
    }

    fn setWidth(self: *HistoryPane, c: DataColumn, w: f32) void {
        switch (c) {
            .commit => {},
            .author => self.author_w = w,
            .date => self.date_w = w,
            .sha => self.sha_w = w,
        }
    }

    fn onResizeDown(self: *HistoryPane, pair: [2]DataColumn, ev: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(HistoryPane)) void {
        window.preventDefault();
        cx.stopPropagation();
        if (ev.click_count >= 2) {
            self.author_w = graph.author_width;
            self.date_w = graph.date_width;
            self.sha_w = graph.sha_width;
            self.resize = null;
            self.persistWidths(cx);
            cx.notify();
            return;
        }
        self.resize = .{ .start_x = ev.position.x, .left = pair[0], .right = pair[1], .left_w = self.widthOf(pair[0]), .right_w = self.widthOf(pair[1]) };
    }

    /// `resized_history_column_widths`: Commit's divider resizes only the
    /// right column; other dividers trade width between neighbours.
    fn onColumnResize(self: *HistoryPane, ev: *const zpui.DragMoveEvent(ColumnResize), _: *Window, cx: *Context(HistoryPane)) void {
        const a = self.resize orelse return;
        const delta = ev.event.position.x - a.start_x;
        const rl = limits(a.right);
        if (a.left == .commit) {
            self.setWidth(a.right, std.math.clamp(a.right_w - delta, rl[0], rl[1]));
        } else {
            const ll = limits(a.left);
            const min_d = @max(ll[0] - a.left_w, a.right_w - rl[1]);
            const max_d = @min(ll[1] - a.left_w, a.right_w - rl[0]);
            const d = std.math.clamp(delta, min_d, @max(min_d, max_d));
            self.setWidth(a.left, a.left_w + d);
            self.setWidth(a.right, a.right_w - d);
        }
        self.persistWidths(cx);
        cx.notify();
    }

    fn persistWidths(self: *HistoryPane, cx: *Context(HistoryPane)) void {
        const Set = struct {
            fn set(v: [3]f32, s: *model.UiSettings, _: Allocator) void {
                s.gitHistoryColumnWidths.author = v[0];
                s.gitHistoryColumnWidths.date = v[1];
                s.gitHistoryColumnWidths.sha = v[2];
            }
        };
        _ = model.settings_store.update(cx.app, .debounced, [3]f32{ self.author_w, self.date_w, self.sha_w }, Set.set);
    }

    /// `container_query` → geometry: a compactness flip morphs the graph
    /// (width + lane spacing) over COLLAPSE; other changes apply at once.
    fn updateGeometry(self: *HistoryPane, width: f32, scale: f32, window: *Window, cx: *Context(HistoryPane)) void {
        const opt = self.optionalColumnsWidth();
        const previous = self.target_geometry;
        const responsive = graph.responsiveGeometry(self.lane_capacity, width, opt);
        const compact = graph.shouldUseCompact(responsive, previous, width, opt);
        const target = graph.stabilizedGeometry(responsive, previous, scale, compact);
        const now = cx.app.executor.now();
        if (self.morph) |m| if (std.meta.eql(self.geometry, m.to)) {
            self.morph = null;
        };
        const reduced = if (model.settings_store.current(cx.app)) |st| st.theme.reduce_motion == .on else false;
        if (self.morph) |m| {
            if (m.to.compact != target.compact) self.morph = null;
        }
        if (self.morph == null and target.compact != previous.compact and !reduced) {
            self.morph = .{ .from = self.geometry, .to = target, .started = now };
            self.target_geometry = target;
        }
        if (self.morph) |m| {
            const t = zt.motion.collapse.progressAt(now -| m.started, 1);
            self.geometry = if (t >= 1) m.to else graph.interpolate(m.from, m.to, t);
            if (t >= 1) self.morph = null else window.requestAnimationFrame();
            return;
        }
        self.target_geometry = target;
        self.geometry = target;
    }

    pub fn render(self: *HistoryPane, window: *Window, cx: *Context(HistoryPane)) zpui.AnyElement {
        const theme = arenaTheme(ui.theme.get(cx).*);
        ui.hover.tick(window, cx);
        self.ensureLoaded(cx);
        self.rebuild(cx);
        const st = self.store.read(cx);

        var root = div().id("history-pane").trackFocus(self.focus).keyContext("HistoryPane")
            .onKeyDown(cx.listener(onKey))
            .onDragMove(ColumnResize, cx.listener(onColumnResize))
            .sizeFull().flex().flexCol().fontFamily(theme.font_sans_fixed).textColor(theme.text);
        if (self.show_toolbar) root = root.child(self.toolbar(theme, window, cx));
        if (st.fetch_error) |e| root = root.child(errorBanner(zpui.fmt("Fetch failed: {s}", .{e}), theme));
        if ((if (st.searchActive()) st.search_error else st.error_message)) |e| if (self.visible.len > 0) {
            root = root.child(errorBanner(e, theme));
        };
        root = root.child(zpui.containerQuery(MainQuery{ .pane = cx.weakEntity(), .theme = theme }, MainQuery.render).wFull().flex1().minH0());
        const column_exit = menuExit(&self.column_menu_at, &self.column_exit, cx.app.executor.now());
        const author_exit = menuExit(&self.author_menu_at, &self.author_exit, cx.app.executor.now());
        if (self.column_menu_at) |at| root = root.child(self.columnMenu(at, column_exit, theme, cx));
        if (self.author_menu_at) |at| root = root.child(self.authorMenu(at, author_exit, theme, cx));
        return zpui.intoAnyElement(root);
    }

    fn renderBodyArea(self: *HistoryPane, theme: *const Theme, window: *Window, cx: *Context(HistoryPane)) AnyElement {
        const st = self.store.read(cx);
        return blk: {
            if (st.target_key == null) break :blk zpui.intoAnyElement(div().flex1().flex().itemsCenter().justifyCenter().textSize(px(12)).textColor(theme.text_faint).child("No repository selected"));
            if (st.loading and st.commits.items.len == 0) {
                window.requestAnimationFrame();
                break :blk zpui.intoAnyElement(div().flex1().flex().flexCol().itemsCenter().justifyCenter().gap(px(8))
                    .child(ui.loaders.gradientSpinner(3, ui.loaders.phaseOf(cx, zt.motion.gradient_spin)))
                    .child(div().textSize(px(12)).textColor(theme.text_faint).child("Loading history\u{2026}")));
            }
            if (self.visible.len == 0) {
                const err = if (st.searchActive()) st.search_error else st.error_message;
                const msg: []const u8 = err orelse if (st.searchActive()) "No matching commits" else if (self.view_mode == .branch_tips) "No branch tips found" else "No commits found";
                break :blk zpui.intoAnyElement(div().flex1().flex().itemsCenter().justifyCenter().px(px(20)).textSize(px(12))
                    .textColor(if (err != null) theme.warning else theme.text_faint).child(msg));
            }
            const paint: GraphPaint = .{
                .rows = self.layout.rows,
                .list = self.list,
                .geometry = self.geometry,
                .palette = palette(theme),
                .bg = theme.bg,
                .focus = self.graphFocus(cx),
                .compact_rail = self.view_mode == .all_commits,
            };
            break :blk zpui.intoAnyElement(div().relative().flex1().minH0().overflowHidden()
                .child(zpui.canvas(paint, paintGraph).absolute().inset0())
                .child(zpui.list(self.list, cx, renderRow).sizeFull().withSizingBehavior(.auto)));
        };

    }

    /// The column header + rows, laid out from the area's own width
    /// (`container_query` → `responsive_graph_geometry`), so the lane graph,
    /// the header spacer and every row agree in the same frame.
    const MainQuery = struct {
        pane: zpui.WeakEntity(HistoryPane),
        theme: *const Theme,

        fn render(q: MainQuery, size: zpui.Size(f32), window: *Window, app: *App) AnyElement {
            return q.pane.update(app, HistoryPane.renderMain, .{ q.theme, size.width, window }) orelse zpui.empty();
        }
    };

    fn renderMain(self: *HistoryPane, theme: *const Theme, width: f32, window: *Window, cx: *Context(HistoryPane)) AnyElement {
        self.updateGeometry(width, window.scaleFactor(), window, cx);
        var main = div().sizeFull().flex().flexCol();
        if (self.visible.len > 0) main = main.child(self.columnHeader(theme, cx));
        return zpui.intoAnyElement(main.child(self.renderBodyArea(theme, window, cx)));
    }

    fn errorBanner(text: []const u8, theme: *const Theme) zpui.Div {
        return div().h(px(28)).flexNone().flex().itemsCenter().px(px(8)).borderB1().borderColor(theme.danger.opacity(0.16))
            .bg(theme.danger.opacity(0.05)).truncate().whitespaceNowrap().textSize(px(11)).textColor(theme.danger_muted).child(text);
    }
};


// ---- [motion] fold transition rows (`history_transition_rows`) ------------------------

pub const RowTransition = enum { stable, entering, exiting };

fn sameShas(a: []const Commit, b: []const Commit) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x.sha, y.sha)) return false;
    return true;
}

/// `history_transition_rows`: the target rows in order, with every row that
/// only the old view has re-inserted after the last shared row above it
/// (leading ones first) and tagged as exiting; new rows are entering.
pub fn historyTransitionRows(a: Allocator, old: []const Commit, target: []const Commit) !struct { commits: []Commit, rows: []RowTransition } {
    var target_shas: std.StringHashMapUnmanaged(void) = .empty;
    for (target) |c| try target_shas.put(a, c.sha, {});
    var old_shas: std.StringHashMapUnmanaged(void) = .empty;
    for (old) |c| try old_shas.put(a, c.sha, {});
    var before_first: std.ArrayList(Commit) = .empty;
    // anchor sha → the old-only rows that followed it.
    var after_anchor: std.StringArrayHashMapUnmanaged(std.ArrayList(Commit)) = .empty;
    var anchor: ?[]const u8 = null;
    for (old) |c| {
        if (target_shas.contains(c.sha)) {
            anchor = c.sha;
        } else if (anchor) |an| {
            const gop = try after_anchor.getOrPut(a, an);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, c);
        } else try before_first.append(a, c);
    }
    var commits: std.ArrayList(Commit) = .empty;
    var rows: std.ArrayList(RowTransition) = .empty;
    for (before_first.items) |c| {
        try commits.append(a, c);
        try rows.append(a, .exiting);
    }
    for (target) |c| {
        try commits.append(a, c);
        try rows.append(a, if (old_shas.contains(c.sha)) .stable else .entering);
        if (after_anchor.fetchSwapRemove(c.sha)) |kv| for (kv.value.items) |e| {
            try commits.append(a, e);
            try rows.append(a, .exiting);
        };
    }
    // Duplicate anchors / no shared row: keep the leftovers exiting.
    for (after_anchor.values()) |list| for (list.items) |e| {
        try commits.append(a, e);
        try rows.append(a, .exiting);
    };
    return .{ .commits = commits.items, .rows = rows.items };
}

test "history transition rows match history_transition_rows" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const C = struct {
        fn of(comptime shas: []const []const u8) []const Commit {
            comptime var out: [shas.len]Commit = undefined;
            inline for (shas, 0..) |sha, i| out[i] = .{ .sha = sha };
            const final = out;
            return &final;
        }
    };
    // Folding b, c away: they leave after their anchor a.
    const r = try historyTransitionRows(a, C.of(&.{ "a", "b", "c", "d" }), C.of(&.{ "a", "d" }));
    try std.testing.expectEqual(@as(usize, 4), r.commits.len);
    try std.testing.expectEqualStrings("b", r.commits[1].sha);
    try std.testing.expectEqualSlices(RowTransition, &.{ .stable, .exiting, .exiting, .stable }, r.rows);
    // Unfolding: x enters, a leading old-only row leaves first.
    const u = try historyTransitionRows(a, C.of(&.{ "z", "a", "d" }), C.of(&.{ "a", "x", "d" }));
    try std.testing.expectEqualStrings("z", u.commits[0].sha);
    try std.testing.expectEqualSlices(RowTransition, &.{ .exiting, .stable, .entering, .stable }, u.rows);
}
