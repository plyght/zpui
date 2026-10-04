//! `HistoryStore`: one checkout's git history — zeron `GitHistory`'s data
//! half (`ensure_loaded`, `fetch_page`, `load_older`, `refresh`,
//! `fetch_all`, `request_search_page`).
//!
//! Pages of `ListGitHistory` accumulate into `commits` (deduplicated by
//! sha); `FetchAll` updates remote refs and reloads; search queries go to
//! `SearchGitHistory` (complete history) with a local fuzzy filter over the
//! loaded pages until the reply lands.
//!
//! ```zig
//! const store = try cx.newWith(HistoryStore, HistoryStore.init, .{engine});
//! store.update(cx, HistoryStore.setTarget, .{ key, cwd, target });
//! HistoryStore.applyFixture(store, app, bytes)    // engine-free feed
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const zpui = @import("zpui");
const model = @import("zeron_model");
const types = @import("types.zig");
const graph = @import("graph.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const es = model.engine_state;
const EngineState = model.EngineState;
const Commit = types.GitHistoryCommit;

const log = std.log.scoped(.zeron_history);

pub const HistoryChanged = struct {};
/// `FetchAll` succeeded (branch lists / scoped diffs should refresh).
pub const FetchSucceeded = struct {};

pub const HistoryStore = struct {
    gpa: Allocator,
    engine: Entity(EngineState),
    arena: std.heap.ArenaAllocator,
    target_key: ?[]u8 = null,
    cwd: ?[]u8 = null,
    target: ?[]u8 = null,

    commits: std.ArrayList(Commit) = .empty,
    branch_tips: []const Commit = &.{},
    head_sha: ?[]const u8 = null,
    next_cursor: ?usize = null,
    total_count: ?usize = null,
    head_commit_count: ?usize = null,
    comparison: ?types.GitHistoryComparison = null,
    loading: bool = false,
    error_message: ?[]u8 = null,
    /// Bumps whenever `commits` changes (views rebuild their graph).
    generation: u64 = 0,

    fetching_all: bool = false,
    fetch_error: ?[]u8 = null,

    search_arena: std.heap.ArenaAllocator,
    search_query: []u8 = &.{},
    search_results: ?[]const Commit = null,
    search_total: ?usize = null,
    search_loading: bool = false,
    search_error: ?[]u8 = null,
    search_generation: u64 = 0,
    /// Offline (fixtures): never calls the engine.
    offline: bool = false,
    /// Whether the in-flight page replaces (cursor 0) or appends.
    pending_reset: bool = false,

    pub const Events = .{ HistoryChanged, FetchSucceeded };

    pub fn init(engine: Entity(EngineState), cx: *Context(HistoryStore)) !HistoryStore {
        return .{
            .gpa = cx.gpa(),
            .engine = engine.retain(cx),
            .arena = .init(cx.gpa()),
            .search_arena = .init(cx.gpa()),
        };
    }

    pub fn deinit(self: *HistoryStore, app: *App) void {
        self.commits.deinit(self.gpa);
        self.arena.deinit();
        self.search_arena.deinit();
        inline for (.{ "target_key", "cwd", "target", "error_message", "fetch_error", "search_error" }) |f| {
            if (@field(self, f)) |s| self.gpa.free(s);
        }
        self.gpa.free(self.search_query);
        self.engine.release(app);
    }

    pub fn searchActive(self: *const HistoryStore) bool {
        return std.mem.trim(u8, self.search_query, " \t").len > 0;
    }

    /// "N commits" for the header.
    pub fn commitCount(self: *const HistoryStore) ?usize {
        if (self.searchActive()) return self.search_total;
        return self.head_commit_count;
    }

    pub fn hasLoadMore(self: *const HistoryStore) bool {
        if (self.searchActive()) return false;
        return self.next_cursor != null;
    }

    fn reset(self: *HistoryStore) void {
        self.commits.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.branch_tips = &.{};
        self.head_sha = null;
        self.next_cursor = null;
        self.total_count = null;
        self.head_commit_count = null;
        self.comparison = null;
        self.loading = false;
        freeOpt(self.gpa, &self.error_message);
        freeOpt(self.gpa, &self.fetch_error);
        self.fetching_all = false;
        self.clearSearch();
        self.generation +%= 1;
    }

    fn clearSearch(self: *HistoryStore) void {
        self.gpa.free(self.search_query);
        self.search_query = &.{};
        self.search_results = null;
        self.search_total = null;
        self.search_loading = false;
        freeOpt(self.gpa, &self.search_error);
        _ = self.search_arena.reset(.retain_capacity);
        self.search_generation +%= 1;
    }

    /// Follow a checkout (`key` = `device|cwd`); null clears everything.
    pub fn setTarget(self: *HistoryStore, key: ?[]const u8, cwd: ?[]const u8, target: ?[]const u8, cx: *Context(HistoryStore)) void {
        if (self.offline) return;
        const k = key orelse {
            if (self.target_key != null) {
                freeOpt(self.gpa, &self.target_key);
                self.reset();
                cx.emit(HistoryChanged{});
                cx.notify();
            }
            return;
        };
        if (self.target_key) |old| if (std.mem.eql(u8, old, k)) {
            if (!self.loading and self.commits.items.len == 0 and self.error_message == null) self.fetchPage(0, true, cx);
            return;
        };
        self.reset();
        freeOpt(self.gpa, &self.target_key);
        freeOpt(self.gpa, &self.cwd);
        freeOpt(self.gpa, &self.target);
        self.target_key = self.gpa.dupe(u8, k) catch null;
        self.cwd = if (cwd) |c| self.gpa.dupe(u8, c) catch null else null;
        self.target = if (target) |t| self.gpa.dupe(u8, t) catch null else null;
        cx.emit(HistoryChanged{});
        cx.notify();
        self.fetchPage(0, true, cx);
    }

    pub fn refresh(self: *HistoryStore, cx: *Context(HistoryStore)) void {
        if (self.target_key == null) return;
        self.loading = false;
        self.fetchPage(0, true, cx);
    }

    pub fn loadOlder(self: *HistoryStore, cx: *Context(HistoryStore)) void {
        const cursor = self.next_cursor orelse return;
        self.fetchPage(cursor, false, cx);
    }

    fn fetchPage(self: *HistoryStore, cursor: usize, reset_page: bool, cx: *Context(HistoryStore)) void {
        if (self.loading or self.offline) return;
        const cwd = self.cwd orelse return;
        if (self.engine.read(cx).conn == null) return;
        self.loading = true;
        freeOpt(self.gpa, &self.error_message);
        self.pending_reset = reset_page;
        EngineState.request(self.engine, cx, HistoryStore, cx.entityId(), .ListGitHistory, types.params.ListGitHistory{
            .cwd = cwd,
            .cursor = cursor,
            .limit = graph.page_size,
            .targetDeviceId = self.target,
        }, onPage) catch {
            self.loading = false;
            return;
        };
        cx.notify();
    }

    fn onPage(self: *HistoryStore, result: es.CallResult, cx: *Context(HistoryStore)) void {
        self.loading = false;
        switch (result) {
            .ok => |v| self.applyPageValue(v, self.pending_reset) catch |err| {
                self.error_message = std.fmt.allocPrint(self.gpa, "{t}", .{err}) catch null;
            },
            .err => |e| self.error_message = self.gpa.dupe(u8, e.message) catch null,
        }
        if (self.searchActive() and self.pending_reset) {
            const q = self.gpa.dupe(u8, self.search_query) catch null;
            if (q) |query| {
                defer self.gpa.free(query);
                self.setSearch(query, cx);
            }
        }
        cx.emit(HistoryChanged{});
        cx.notify();
    }

    fn applyPageValue(self: *HistoryStore, v: json.Value, reset_page: bool) !void {
        if (reset_page) {
            self.commits.clearRetainingCapacity();
            _ = self.arena.reset(.retain_capacity);
        }
        const a = self.arena.allocator();
        const page = try json.parseFromValueLeaky(types.GitHistoryPage, a, v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        if (reset_page) {
            self.branch_tips = page.branchTips;
            self.total_count = page.totalCount;
            self.head_commit_count = page.headCommitCount;
            self.comparison = page.comparison;
        } else {
            if (page.totalCount) |t| self.total_count = t;
            if (page.headCommitCount) |t| self.head_commit_count = t;
        }
        for (page.commits) |c| {
            var dup = false;
            if (!reset_page) for (self.commits.items) |e| if (std.mem.eql(u8, e.sha, c.sha)) {
                dup = true;
                break;
            };
            if (!dup) try self.commits.append(self.gpa, c);
        }
        self.head_sha = page.headSha;
        self.next_cursor = page.nextCursor;
        self.generation +%= 1;
    }

    /// Engine-free feed: `bytes` is a `ListGitHistory` reply.
    pub fn applyFixture(entity: Entity(HistoryStore), app: *App, key: []const u8, bytes: []const u8) void {
        var l = entity.lease(app);
        defer l.end();
        const self = l.value;
        self.offline = true;
        freeOpt(self.gpa, &self.target_key);
        self.target_key = self.gpa.dupe(u8, key) catch null;
        var tmp: std.heap.ArenaAllocator = .init(self.gpa);
        defer tmp.deinit();
        const v = json.parseFromSliceLeaky(json.Value, tmp.allocator(), bytes, .{}) catch |err| {
            log.warn("history fixture: {t}", .{err});
            return;
        };
        self.applyPageValue(v, true) catch |err| log.warn("history fixture: {t}", .{err});
        l.cx.emit(HistoryChanged{});
        l.cx.notify();
    }

    /// Mark offline with a key but no data (loading state screenshots).
    pub fn setOfflineLoading(self: *HistoryStore, key: []const u8, cx: *Context(HistoryStore)) void {
        self.offline = true;
        freeOpt(self.gpa, &self.target_key);
        self.target_key = self.gpa.dupe(u8, key) catch null;
        self.loading = true;
        cx.notify();
    }

    // ---- fetch all ----------------------------------------------------------------

    pub fn fetchAll(self: *HistoryStore, cx: *Context(HistoryStore)) void {
        if (self.fetching_all) return;
        const cwd = self.cwd orelse return;
        if (self.offline or self.engine.read(cx).conn == null) return;
        self.fetching_all = true;
        freeOpt(self.gpa, &self.fetch_error);
        EngineState.request(self.engine, cx, HistoryStore, cx.entityId(), .FetchAll, types.params.FetchAll{ .repoPath = cwd, .targetDeviceId = self.target }, onFetched) catch {
            self.fetching_all = false;
            return;
        };
        cx.notify();
    }

    fn onFetched(self: *HistoryStore, result: es.CallResult, cx: *Context(HistoryStore)) void {
        self.fetching_all = false;
        switch (result) {
            .ok => {
                self.loading = false;
                self.fetchPage(0, true, cx);
                cx.emit(FetchSucceeded{});
            },
            .err => |e| self.fetch_error = self.gpa.dupe(u8, e.message) catch null,
        }
        cx.notify();
    }

    // ---- search -------------------------------------------------------------------

    /// Set the search query (empty clears). Local matches show immediately;
    /// `SearchGitHistory` covers commits beyond the loaded pages.
    pub fn setSearch(self: *HistoryStore, query: []const u8, cx: *Context(HistoryStore)) void {
        const trimmed = std.mem.trim(u8, query, " \t");
        if (std.mem.eql(u8, trimmed, std.mem.trim(u8, self.search_query, " \t")) and self.search_results != null) return;
        const owned = self.gpa.dupe(u8, query) catch return;
        self.clearSearch();
        self.search_query = owned;
        if (trimmed.len > 0 and !self.offline and self.cwd != null and self.engine.read(cx).conn != null) {
            self.search_loading = true;
            EngineState.request(self.engine, cx, HistoryStore, cx.entityId(), .SearchGitHistory, types.params.SearchGitHistory{
                .cwd = self.cwd.?,
                .query = trimmed,
                .limit = graph.page_size,
                .targetDeviceId = self.target,
            }, onSearch) catch {
                self.search_loading = false;
            };
        }
        cx.emit(HistoryChanged{});
        cx.notify();
    }

    fn onSearch(self: *HistoryStore, result: es.CallResult, cx: *Context(HistoryStore)) void {
        if (!self.search_loading) return;
        self.search_loading = false;
        switch (result) {
            .ok => |v| {
                const a = self.search_arena.allocator();
                if (json.parseFromValueLeaky(types.GitHistoryPage, a, v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |page| {
                    self.search_results = page.commits;
                    self.search_total = page.totalCount orelse page.commits.len;
                } else |err| self.search_error = std.fmt.allocPrint(self.gpa, "{t}", .{err}) catch null;
            },
            .err => |e| self.search_error = self.gpa.dupe(u8, e.message) catch null,
        }
        self.search_generation +%= 1;
        cx.emit(HistoryChanged{});
        cx.notify();
    }
};

fn freeOpt(gpa: Allocator, slot: *?[]u8) void {
    if (slot.*) |s| gpa.free(s);
    slot.* = null;
}
