//! `WorkspaceFiles`: one workspace's file service for the explorer and the
//! editor — zeron `files/client.rs` (`WorkspaceFilesClient`) plus
//! `files/watch.rs`, over two interchangeable sources:
//!
//! - `.engine`: the zeron engine RPCs (`ListWorkspaceDirectory`,
//!   `SearchWorkspaceFiles`, `ReadWorkspaceFile`, hash-guarded
//!   `WriteWorkspaceFile`, `MoveWorkspaceEntry`, `DeleteWorkspaceEntry`,
//!   `WatchWorkspaceFiles`, `WatchWorkspaceGitStatus`) for a chat / space
//!   target;
//! - `.local`: the same contract implemented on a local directory with
//!   `std.Io` on background workers (the demo, tests, and engine-less use).
//!   It mirrors the engine's semantics: `.git` hidden, `.gitignore`d entries
//!   flagged / filtered, dirs-first case-insensitive order, SHA-256 content
//!   hashes, binary / encoding / line-ending classification with CRLF
//!   normalization, conflict-checked writes, no-replace moves, a polling
//!   watcher for watched directories and files, and `git status` decorations.
//!
//! Requests are issued *from the requesting entity* so results re-enter it:
//!
//! ```zig
//! files.read(cx).listDirectory(cx, .{ .directory = "src" }, Panel.onListed);
//! fn onListed(self: *Panel, res: client.DirectoryResult, cx: *Context(Panel)) void { defer res.deinit(); ... }
//! ```
//!
//! Change notifications (`FileChangesEvent`) are emitted by the entity.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = std.json;
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine_mod = @import("zeron_engine");
const proto = @import("protocol.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Task = zpui.Task;
const es = model.engine_state;
const EngineState = model.EngineState;

const log = std.log.scoped(.zeron_files);

/// Local reads up to this size (the engine caps previews at 8 MiB; a local
/// editor can open far larger files).
pub const local_max_read: usize = 512 * 1024 * 1024;
/// Local files above this open read-only (engine: 1 MiB).
pub const local_max_editable: usize = 128 * 1024 * 1024;
/// Polling cadence of the local watcher.
pub const local_poll_ns: u64 = 1000 * std.time.ns_per_ms;

// ---------------------------------------------------------------------------
// results
// ---------------------------------------------------------------------------

/// A request outcome owning its memory (`deinit` it once consumed).
pub fn Result(comptime V: type) type {
    return struct {
        const Self = @This();
        arena: ?*std.heap.ArenaAllocator = null,
        value: ?V = null,
        err: ?[]const u8 = null,

        pub fn deinit(self: Self) void {
            if (self.arena) |a| {
                const gpa = a.child_allocator;
                a.deinit();
                gpa.destroy(a);
            }
        }

        pub fn init(gpa: Allocator) Self {
            const a = gpa.create(std.heap.ArenaAllocator) catch @panic("OOM");
            a.* = .init(gpa);
            return .{ .arena = a };
        }

        pub fn allocator(self: Self) Allocator {
            return self.arena.?.allocator();
        }

        pub fn fail(gpa: Allocator, comptime f: []const u8, args: anytype) Self {
            var r = init(gpa);
            r.err = std.fmt.allocPrint(r.allocator(), f, args) catch "error";
            return r;
        }
    };
}

pub const DirectoryResult = Result(proto.DirectoryPage);
pub const SearchResult = Result([]const proto.SearchMatch);
pub const WriteResult = Result(proto.WriteOutcome);
pub const MutationResult = Result(proto.MutationOutcome);
pub const GitStatusResult = Result(proto.CheckoutGitStatus);

/// `ReadWorkspaceFile` result; the text is a separate gpa allocation the
/// receiver may `takeText()` (zero-copy for huge local files).
pub const ReadResult = struct {
    base: Result(proto.FileText) = .{},
    text: ?[]u8 = null,
    gpa: Allocator,

    pub fn deinit(self: ReadResult) void {
        if (self.text) |t| self.gpa.free(t);
        self.base.deinit();
    }

    pub fn takeText(self: *ReadResult) ?[]u8 {
        const t = self.text;
        self.text = null;
        if (self.base.value) |*v| v.text = null;
        return t;
    }

    pub fn err(self: ReadResult) ?[]const u8 {
        return self.base.err;
    }

    pub fn file(self: ReadResult) ?proto.FileText {
        return self.base.value;
    }
};

pub const FileChangesEvent = struct {
    changes: []const proto.FileChange,
    resync: bool = false,
};

pub const GitStatusChanged = struct {};

pub const FileWatch = struct {
    print: u64 = 0,
    owners: std.ArrayList(zpui.EntityId) = .empty,
};

pub const ListRequest = struct { directory: []const u8 = "", include_ignored: bool = false, cursor: ?[]const u8 = null };
pub const WriteRequest = struct {
    path: []const u8,
    text: []const u8,
    expected_hash: []const u8,
    expected_checkout: []const u8 = "",
    encoding: proto.WritableEncoding = .utf8,
    line_ending: proto.WritableLineEnding = .lf,
};
pub const MoveRequest = struct { source: []const u8, destination: []const u8, revision: []const u8, kind: proto.EntryKind };
pub const DeleteRequest = struct { path: []const u8, revision: []const u8, kind: proto.EntryKind, recursive: bool };

// ---------------------------------------------------------------------------
// the entity
// ---------------------------------------------------------------------------

pub const Target = struct {
    chat_id: ?[]const u8 = null,
    space_id: ?[]const u8 = null,
    checkout_path: ?[]const u8 = null,
};

pub const Source = union(enum) {
    /// Absolute (or cwd-relative) root directory.
    local: []const u8,
    engine: struct { state: Entity(EngineState), target: Target },
};

pub const WorkspaceFiles = struct {
    gpa: Allocator,
    io: Io,
    source: union(enum) {
        local: []u8,
        engine: struct { state: Entity(EngineState), chat_id: ?[]u8, space_id: ?[]u8, checkout_path: ?[]u8 },
    },
    /// Shown as the workspace root (`cwd` for the full path in "Copy path").
    root_label: []u8,
    engine_sub: ?zpui.Subscription = null,

    // watching
    watch: es.Watch = .{},
    git_watch: es.Watch = .{},
    git_status: ?json.Parsed(proto.CheckoutGitStatus) = null,
    /// Local: static git status fed by a host / fixture (overrides `git status`).
    git_fixture: bool = false,
    watched_dirs: std.StringArrayHashMapUnmanaged(u64) = .empty,
    /// Watched file → fingerprint and the entities that asked (pruned when they die).
    watched_files: std.StringArrayHashMapUnmanaged(FileWatch) = .empty,
    poll_task: Task(PollOutcome) = .none,
    poll_timer: Task(void) = .none,
    git_task: Task(GitStatusResult) = .none,
    polling: bool = false,
    retry_task: Task(void) = .none,
    /// Payload storage for emitted `FileChangesEvent`s (events are delivered
    /// after the emitting callback returns; reset before the next batch).
    change_arena: std.heap.ArenaAllocator,

    pub const Events = .{ FileChangesEvent, GitStatusChanged };

    pub fn init(io: Io, source: Source, cx: *Context(WorkspaceFiles)) !WorkspaceFiles {
        const gpa = cx.gpa();
        var self: WorkspaceFiles = .{
            .gpa = gpa,
            .io = io,
            .source = undefined,
            .root_label = undefined,
            .change_arena = .init(gpa),
        };
        switch (source) {
            .local => |root| {
                self.source = .{ .local = try gpa.dupe(u8, root) };
                self.root_label = try gpa.dupe(u8, root);
            },
            .engine => |e| {
                self.source = .{ .engine = .{
                    .state = e.state.retain(cx),
                    .chat_id = if (e.target.chat_id) |s| try gpa.dupe(u8, s) else null,
                    .space_id = if (e.target.space_id) |s| try gpa.dupe(u8, s) else null,
                    .checkout_path = if (e.target.checkout_path) |s| try gpa.dupe(u8, s) else null,
                } };
                self.root_label = try gpa.dupe(u8, e.target.checkout_path orelse "");
                self.engine_sub = try cx.subscribe(e.state, onEngineEvent);
            },
        }
        return self;
    }

    pub fn deinit(self: *WorkspaceFiles, app: *App) void {
        if (self.engine_sub) |*s| s.deinit();
        self.watch.close();
        self.git_watch.close();
        if (self.git_status) |g| g.deinit();
        self.poll_task.cancel();
        self.poll_timer.cancel();
        self.git_task.cancel();
        self.retry_task.cancel();
        self.change_arena.deinit();
        for (self.watched_dirs.keys()) |k| self.gpa.free(k);
        self.watched_dirs.deinit(self.gpa);
        for (self.watched_files.keys(), self.watched_files.values()) |k, *v| {
            self.gpa.free(k);
            v.owners.deinit(self.gpa);
        }
        self.watched_files.deinit(self.gpa);
        switch (self.source) {
            .local => |r| self.gpa.free(r),
            .engine => |e| {
                e.state.release(app);
                if (e.chat_id) |s| self.gpa.free(s);
                if (e.space_id) |s| self.gpa.free(s);
                if (e.checkout_path) |s| self.gpa.free(s);
            },
        }
        self.gpa.free(self.root_label);
    }

    pub fn isLocal(self: *const WorkspaceFiles) bool {
        return self.source == .local;
    }

    /// Absolute path of a workspace-relative path (for "Copy path").
    pub fn absolutePath(self: *const WorkspaceFiles, a: Allocator, rel: []const u8) []const u8 {
        const root = std.mem.trimEnd(u8, self.root_label, "/");
        if (root.len == 0) return rel;
        if (rel.len == 0) return root;
        return std.fmt.allocPrint(a, "{s}/{s}", .{ root, rel }) catch rel;
    }

    fn targetFields(self: *const WorkspaceFiles) struct { ?[]const u8, ?[]const u8, ?[]const u8 } {
        return switch (self.source) {
            .engine => |e| .{ e.chat_id, e.space_id, e.checkout_path },
            .local => .{ null, null, null },
        };
    }

    // ---- requests -----------------------------------------------------------------

    pub fn listDirectory(self: *const WorkspaceFiles, cx: anytype, req: ListRequest, comptime f: anytype) void {
        const T = CtxEntity(@TypeOf(cx));
        switch (self.source) {
            .local => |root| self.spawnLocal(cx, LocalJob(.list){ .gpa = self.gpa, .io = self.io, .root = root, .a = req.directory, .flag = req.include_ignored }, f),
            .engine => |e| {
                const t = self.targetFields();
                const p: proto.params.ListDirectory = .{ .chatId = t[0], .spaceId = t[1], .checkoutPath = t[2], .directory = req.directory, .includeIgnored = req.include_ignored, .cursor = req.cursor };
                request(T, e.state, cx, .ListWorkspaceDirectory, p, proto.DirectoryPage, f);
            },
        }
    }

    pub fn search(self: *const WorkspaceFiles, cx: anytype, query: []const u8, include_ignored: bool, comptime f: anytype) void {
        const T = CtxEntity(@TypeOf(cx));
        switch (self.source) {
            .local => |root| self.spawnLocal(cx, LocalJob(.search){ .gpa = self.gpa, .io = self.io, .root = root, .a = query, .flag = include_ignored }, f),
            .engine => |e| {
                const t = self.targetFields();
                const p: proto.params.Search = .{ .chatId = t[0], .spaceId = t[1], .checkoutPath = t[2], .query = query, .includeIgnored = include_ignored, .limit = proto.max_search_results };
                request(T, e.state, cx, .SearchWorkspaceFiles, p, []const proto.SearchMatch, f);
            },
        }
    }

    pub fn readFile(self: *const WorkspaceFiles, cx: anytype, path: []const u8, comptime f: anytype) void {
        const T = CtxEntity(@TypeOf(cx));
        switch (self.source) {
            .local => |root| self.spawnLocal(cx, LocalJob(.read){ .gpa = self.gpa, .io = self.io, .root = root, .a = path }, f),
            .engine => |e| {
                const t = self.targetFields();
                const p: proto.params.Read = .{ .chatId = t[0], .spaceId = t[1], .checkoutPath = t[2], .path = path };
                const gpa = self.gpa;
                const Gen = struct {
                    fn deliver(target: *T, r: es.CallResult, c: *Context(T)) void {
                        var out: ReadResult = .{ .gpa = c.gpa() };
                        out.base = decodeResult(proto.FileText, c.gpa(), r);
                        if (out.base.value) |*v| if (v.text) |txt| {
                            out.text = c.gpa().dupe(u8, txt) catch null;
                            v.text = out.text;
                        };
                        f(target, out, c);
                    }
                };
                es.EngineState.request(e.state, cx, T, cx.entityId(), .ReadWorkspaceFile, p, Gen.deliver) catch |err| {
                    var out: ReadResult = .{ .gpa = gpa };
                    out.base = Result(proto.FileText).fail(gpa, "Workspace service is still starting ({t}).", .{err});
                    const Fail = struct {
                        res: ReadResult,
                        pub fn run(j: *@This()) ReadResult {
                            return j.res;
                        }
                        pub fn discard(_: *@This(), r: ReadResult) void {
                            r.deinit();
                        }
                    };
                    var task = cx.spawn(Fail{ .res = out }, f) catch return;
                    task.detach();
                };
            },
        }
    }

    /// One `ReadWorkspaceImage` chunk (engine workspaces; local ones read
    /// the file directly — see `ui/files/image_preview.zig`).
    pub fn readImageChunk(self: *const WorkspaceFiles, cx: anytype, path: []const u8, checkout_id: []const u8, offset: u64, content_hash: ?[]const u8, comptime f: anytype) void {
        const T = CtxEntity(@TypeOf(cx));
        switch (self.source) {
            .local => {},
            .engine => |e| {
                const t = self.targetFields();
                const p: proto.params.ReadImage = .{ .chatId = t[0], .spaceId = t[1], .checkoutPath = t[2], .path = path, .expectedCheckoutId = checkout_id, .offset = offset, .expectedContentHash = content_hash };
                request(T, e.state, cx, .ReadWorkspaceImage, p, proto.ImageChunk, f);
            },
        }
    }

    /// The local root (null for engine workspaces).
    pub fn localRoot(self: *const WorkspaceFiles) ?[]const u8 {
        return switch (self.source) {
            .local => |r| r,
            .engine => null,
        };
    }

    pub fn writeFile(self: *const WorkspaceFiles, cx: anytype, req: WriteRequest, comptime f: anytype) void {
        const T = CtxEntity(@TypeOf(cx));
        switch (self.source) {
            .local => |root| {
                const text = self.gpa.dupe(u8, req.text) catch @panic("OOM");
                self.spawnLocal(cx, LocalJob(.write){ .gpa = self.gpa, .io = self.io, .root = root, .a = req.path, .b = req.expected_hash, .owned = text, .crlf = req.line_ending == .crlf, .bom = req.encoding == .utf8Bom }, f);
            },
            .engine => |e| {
                const t = self.targetFields();
                const p: proto.params.Write = .{ .expectedCheckoutId = req.expected_checkout, .chatId = t[0], .spaceId = t[1], .checkoutPath = t[2], .path = req.path, .text = req.text, .expectedContentHash = req.expected_hash, .encoding = req.encoding, .lineEnding = req.line_ending };
                request(T, e.state, cx, .WriteWorkspaceFile, p, proto.WriteOutcome, f);
            },
        }
    }

    pub fn moveEntry(self: *const WorkspaceFiles, cx: anytype, req: MoveRequest, comptime f: anytype) void {
        const T = CtxEntity(@TypeOf(cx));
        switch (self.source) {
            .local => |root| self.spawnLocal(cx, LocalJob(.move){ .gpa = self.gpa, .io = self.io, .root = root, .a = req.source, .b = req.destination, .c = req.revision }, f),
            .engine => |e| {
                const t = self.targetFields();
                var op_buf: [32]u8 = undefined;
                const p: proto.params.Move = .{ .chatId = t[0], .spaceId = t[1], .checkoutPath = t[2], .operationId = operationId(&op_buf), .expectedCheckoutId = "", .sourcePath = req.source, .destinationPath = req.destination, .expectedSourceRevision = req.revision, .expectedKind = req.kind };
                request(T, e.state, cx, .MoveWorkspaceEntry, p, proto.MutationOutcome, f);
            },
        }
    }

    pub fn deleteEntry(self: *const WorkspaceFiles, cx: anytype, req: DeleteRequest, comptime f: anytype) void {
        const T = CtxEntity(@TypeOf(cx));
        switch (self.source) {
            .local => |root| self.spawnLocal(cx, LocalJob(.delete){ .gpa = self.gpa, .io = self.io, .root = root, .a = req.path, .c = req.revision, .flag = req.recursive }, f),
            .engine => |e| {
                const t = self.targetFields();
                var op_buf: [32]u8 = undefined;
                const p: proto.params.Delete = .{ .chatId = t[0], .spaceId = t[1], .checkoutPath = t[2], .operationId = operationId(&op_buf), .expectedCheckoutId = "", .path = req.path, .expectedSourceRevision = req.revision, .expectedKind = req.kind, .recursive = req.recursive };
                request(T, e.state, cx, .DeleteWorkspaceEntry, p, proto.MutationOutcome, f);
            },
        }
    }

    fn spawnLocal(self: *const WorkspaceFiles, cx: anytype, job: anytype, comptime f: anytype) void {
        _ = self;
        var task = cx.spawn(job.owning(), f) catch return;
        task.detach();
    }

    // ---- watching -----------------------------------------------------------------

    /// Start the change watch (engine stream or local polling). Idempotent.
    pub fn ensureWatch(self: *WorkspaceFiles, cx: *Context(WorkspaceFiles)) void {
        switch (self.source) {
            .engine => |e| {
                if (self.watch.isOpen() or self.watch.unsupported) return;
                const conn = e.state.read(cx).conn orelse return;
                const t = self.targetFields();
                self.watch.open(conn, .WatchWorkspaceFiles, proto.params.Watch{ .chatId = t[0], .spaceId = t[1], .checkoutPath = t[2] }) catch |err| {
                    log.debug("file watch unavailable: {t}", .{err});
                    self.scheduleRetry(cx);
                };
                if (!self.git_watch.isOpen() and !self.git_watch.unsupported) {
                    self.git_watch.open(conn, .WatchWorkspaceGitStatus, proto.params.Watch{ .chatId = t[0], .spaceId = t[1], .checkoutPath = t[2] }) catch {};
                }
            },
            .local => {
                if (self.polling) return;
                self.polling = true;
                self.schedulePoll(cx, 0);
                self.refreshLocalGitStatus(cx);
            },
        }
    }

    pub fn watchDirectory(self: *WorkspaceFiles, path: []const u8, _: *Context(WorkspaceFiles)) void {
        if (self.watched_dirs.contains(path)) return;
        self.watched_dirs.put(self.gpa, self.gpa.dupe(u8, path) catch return, 0) catch {};
    }

    pub fn unwatchDirectory(self: *WorkspaceFiles, path: []const u8, _: *Context(WorkspaceFiles)) void {
        if (self.watched_dirs.fetchSwapRemove(path)) |kv| self.gpa.free(kv.key);
    }

    /// Watch `path` on behalf of `owner` (released owners are pruned on the next poll).
    pub fn watchFile(self: *WorkspaceFiles, path: []const u8, owner: zpui.EntityId, _: *Context(WorkspaceFiles)) void {
        const gop = self.watched_files.getOrPut(self.gpa, path) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, path) catch {
                _ = self.watched_files.swapRemove(path);
                return;
            };
            gop.value_ptr.* = .{};
        }
        for (gop.value_ptr.owners.items) |o| if (o == owner) return;
        gop.value_ptr.owners.append(self.gpa, owner) catch {};
    }

    pub fn unwatchFile(self: *WorkspaceFiles, path: []const u8, owner: zpui.EntityId, _: *Context(WorkspaceFiles)) void {
        const v = self.watched_files.getPtr(path) orelse return;
        for (v.owners.items, 0..) |o, i| if (o == owner) {
            _ = v.owners.swapRemove(i);
            break;
        };
        if (v.owners.items.len == 0) self.dropFileWatch(path);
    }

    fn dropFileWatch(self: *WorkspaceFiles, path: []const u8) void {
        if (self.watched_files.fetchSwapRemove(path)) |kv| {
            var v = kv.value;
            v.owners.deinit(self.gpa);
            self.gpa.free(kv.key);
        }
    }

    fn pruneFileWatches(self: *WorkspaceFiles, app: *App) void {
        var i: usize = 0;
        while (i < self.watched_files.count()) {
            const v = &self.watched_files.values()[i];
            var k: usize = 0;
            while (k < v.owners.items.len) {
                if (app.entities.isAlive(v.owners.items[k])) k += 1 else _ = v.owners.swapRemove(k);
            }
            if (v.owners.items.len == 0) {
                self.dropFileWatch(self.watched_files.keys()[i]);
                continue;
            }
            i += 1;
        }
    }

    /// Forget a watched file's fingerprint so the next poll re-baselines it
    /// (after our own write, the editor already knows the new state).
    pub fn noteOwnWrite(self: *WorkspaceFiles, path: []const u8, fingerprint: ?u64, _: *Context(WorkspaceFiles)) void {
        if (self.watched_files.getPtr(path)) |v| v.print = fingerprint orelse 0;
    }

    pub fn gitStatus(self: *const WorkspaceFiles) ?*const proto.CheckoutGitStatus {
        return if (self.git_status) |*g| &g.value else null;
    }

    /// Feed a fixed git status (fixtures / tests); disables `git status` polling.
    pub fn setGitStatusJson(self: *WorkspaceFiles, bytes: []const u8, cx: *Context(WorkspaceFiles)) void {
        const parsed = json.parseFromSlice(proto.CheckoutGitStatus, self.gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
            log.warn("bad git status fixture: {t}", .{err});
            return;
        };
        if (self.git_status) |g| g.deinit();
        self.git_status = parsed;
        self.git_fixture = true;
        cx.emit(GitStatusChanged{});
        cx.notify();
    }

    fn scheduleRetry(self: *WorkspaceFiles, cx: *Context(WorkspaceFiles)) void {
        if (self.retry_task.header != null) return;
        self.retry_task = cx.timer(es.retry_delay_ns, onRetry) catch return;
    }

    fn onRetry(self: *WorkspaceFiles, cx: *Context(WorkspaceFiles)) void {
        self.retry_task.detach();
        self.retry_task = .none;
        self.ensureWatch(cx);
    }

    fn onEngineEvent(self: *WorkspaceFiles, _: Entity(EngineState), ev: *const es.EngineEvent, cx: *Context(WorkspaceFiles)) void {
        switch (ev.*) {
            .connected => {
                self.ensureWatch(cx);
                self.emitChanges(&.{}, true, cx);
            },
            .disconnected => {
                self.watch.close();
                self.git_watch.close();
            },
            .wake => self.drain(cx),
        }
    }

    /// Copy changes into the event arena so the deferred emit outlives the caller.
    fn emitChanges(self: *WorkspaceFiles, changes: []const proto.FileChange, resync: bool, cx: *Context(WorkspaceFiles)) void {
        const a = self.change_arena.allocator();
        const copy = a.alloc(proto.FileChange, changes.len) catch return;
        for (changes, copy) |c, *d| d.* = .{
            .kind = c.kind,
            .path = a.dupe(u8, c.path) catch "",
            .oldPath = if (c.oldPath) |o| a.dupe(u8, o) catch null else null,
        };
        cx.emit(FileChangesEvent{ .changes = copy, .resync = resync });
    }

    fn drain(self: *WorkspaceFiles, cx: *Context(WorkspaceFiles)) void {
        _ = self.change_arena.reset(.retain_capacity);
        while (self.watch.next()) |payload| {
            const parsed = engine_mod.rpc.decode(proto.FileChanges, payload) catch |err| {
                log.warn("dropping malformed file change frame: {t}", .{err});
                continue;
            };
            defer parsed.deinit();
            self.emitChanges(parsed.value.changes, parsed.value.resyncRequired, cx);
        }
        if (self.watch.isOpen()) switch (self.watch.end(null)) {
            .open => {},
            .unknown_method => {
                self.watch.unsupported = true;
                self.watch.close();
            },
            else => {
                self.watch.close();
                self.scheduleRetry(cx);
            },
        };
        if (es.latest(proto.WorkspaceGitStatusFrame, &self.git_watch, "WatchWorkspaceGitStatus")) |frame| {
            defer frame.deinit();
            if (frame.value.status) |st| {
                // Re-own the status through a JSON round trip (frames are short-lived).
                const bytes = json.Stringify.valueAlloc(self.gpa, st, .{}) catch return;
                defer self.gpa.free(bytes);
                const parsed = json.parseFromSlice(proto.CheckoutGitStatus, self.gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
                if (self.git_status) |g| g.deinit();
                self.git_status = parsed;
            } else {
                if (self.git_status) |g| g.deinit();
                self.git_status = null;
            }
            cx.emit(GitStatusChanged{});
            cx.notify();
        }
    }

    // ---- local polling ----------------------------------------------------------------

    fn schedulePoll(self: *WorkspaceFiles, cx: *Context(WorkspaceFiles), delay: u64) void {
        self.poll_timer.cancel();
        self.poll_timer = cx.timer(delay, onPollTimer) catch .none;
    }

    fn onPollTimer(self: *WorkspaceFiles, cx: *Context(WorkspaceFiles)) void {
        self.poll_timer.detach();
        self.poll_timer = .none;
        if (self.source != .local) return;
        if (self.poll_task.header != null) return;
        self.pruneFileWatches(cx.app);
        const root = self.source.local;
        const dirs = self.gpa.alloc([]const u8, self.watched_dirs.count()) catch return;
        for (self.watched_dirs.keys(), 0..) |k, i| dirs[i] = self.gpa.dupe(u8, k) catch "";
        const files = self.gpa.alloc([]const u8, self.watched_files.count()) catch return;
        for (self.watched_files.keys(), 0..) |k, i| files[i] = self.gpa.dupe(u8, k) catch "";
        self.poll_task = cx.spawn(PollJob{ .gpa = self.gpa, .io = self.io, .root = root, .dirs = dirs, .files = files }, onPolled) catch .none;
    }

    fn onPolled(self: *WorkspaceFiles, out: PollOutcome, cx: *Context(WorkspaceFiles)) void {
        self.poll_task.detach();
        self.poll_task = .none;
        defer out.deinit(self.gpa);
        _ = self.change_arena.reset(.retain_capacity);
        var changes: std.ArrayList(proto.FileChange) = .empty;
        defer changes.deinit(self.gpa);
        var any_dir = false;
        for (out.dirs, out.dir_prints) |path, print| {
            const slot = self.watched_dirs.getPtr(path) orelse continue;
            if (slot.* != 0 and slot.* != print) {
                changes.append(self.gpa, .{ .kind = .modified, .path = path }) catch {};
                any_dir = true;
            }
            slot.* = print;
        }
        for (out.files, out.file_prints) |path, print| {
            const slot = self.watched_files.getPtr(path) orelse continue;
            if (slot.print != 0 and slot.print != print) {
                changes.append(self.gpa, .{ .kind = if (print == missing_print) .removed else .modified, .path = path }) catch {};
            }
            slot.print = print;
        }
        if (changes.items.len > 0) self.emitChanges(changes.items, false, cx);
        if (any_dir or changes.items.len > 0) self.refreshLocalGitStatus(cx);
        if (self.polling) self.schedulePoll(cx, local_poll_ns);
    }

    pub fn refreshLocalGitStatus(self: *WorkspaceFiles, cx: *Context(WorkspaceFiles)) void {
        if (self.source != .local or self.git_fixture) return;
        if (self.git_task.header != null) return;
        self.git_task = cx.spawn(LocalJob(.git){ .gpa = self.gpa, .io = self.io, .root = self.source.local }, onGitStatus) catch .none;
    }

    fn onGitStatus(self: *WorkspaceFiles, res: GitStatusResult, cx: *Context(WorkspaceFiles)) void {
        self.git_task.detach();
        self.git_task = .none;
        defer res.deinit();
        if (self.git_fixture) return;
        const st = res.value orelse return;
        const bytes = json.Stringify.valueAlloc(self.gpa, st, .{}) catch return;
        defer self.gpa.free(bytes);
        if (self.git_status) |g| {
            const old = json.Stringify.valueAlloc(self.gpa, g.value, .{}) catch return;
            defer self.gpa.free(old);
            if (std.mem.eql(u8, old, bytes)) return;
        }
        const parsed = json.parseFromSlice(proto.CheckoutGitStatus, self.gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return;
        if (self.git_status) |g| g.deinit();
        self.git_status = parsed;
        cx.emit(GitStatusChanged{});
        cx.notify();
    }
};

fn CtxEntity(comptime C: type) type {
    return @typeInfo(C).pointer.child.Type;
}

fn operationId(buf: *[32]u8) []const u8 {
    var raw: [16]u8 = undefined;
    const S = struct {
        var counter: std.atomic.Value(u64) = .init(0);
    };
    const n = S.counter.fetchAdd(1, .monotonic);
    var prng = std.Random.DefaultPrng.init(n *% 0x9E3779B97F4A7C15 ^ @intFromPtr(buf));
    prng.random().bytes(&raw);
    const hex = std.fmt.bytesToHex(raw, .lower);
    buf.* = hex;
    return buf;
}

fn decodeResult(comptime V: type, gpa: Allocator, r: es.CallResult) Result(V) {
    var out = Result(V).init(gpa);
    switch (r) {
        .ok => |v| {
            out.value = json.parseFromValueLeaky(V, out.allocator(), v, engine_mod.rpc.decode_options) catch |err| {
                out.err = std.fmt.allocPrint(out.allocator(), "Unexpected response ({t}).", .{err}) catch "Unexpected response.";
                return out;
            };
        },
        .err => |e| out.err = out.allocator().dupe(u8, if (e.message.len > 0) e.message else @errorName(e.kind)) catch "error",
    }
    return out;
}

/// Engine unary call whose decoded `Result(V)` lands in `f(*T, Result(V), *Context(T))`.
fn request(comptime T: type, state: Entity(EngineState), cx: *Context(T), method: engine_mod.Method, params: anytype, comptime V: type, comptime f: anytype) void {
    const Gen = struct {
        fn deliver(target: *T, r: es.CallResult, c: *Context(T)) void {
            f(target, decodeResult(V, c.gpa(), r), c);
        }
    };
    es.EngineState.request(state, cx, T, cx.entityId(), method, params, Gen.deliver) catch |err| {
        const gpa = cx.gpa();
        const Fail = struct {
            fn run(target: *T, res: Result(V), c: *Context(T)) void {
                f(target, res, c);
            }
        };
        // Deliver the failure asynchronously so callers see one code path.
        const job = FailJob(V){ .res = Result(V).fail(gpa, "Workspace service is still starting ({t}).", .{err}) };
        var task = cx.spawn(job, Fail.run) catch return;
        task.detach();
    };
}

fn FailJob(comptime V: type) type {
    return struct {
        res: Result(V),
        pub fn run(self: *@This()) Result(V) {
            return self.res;
        }
        pub fn discard(_: *@This(), r: Result(V)) void {
            r.deinit();
        }
    };
}

// ---------------------------------------------------------------------------
// local backend (background jobs)
// ---------------------------------------------------------------------------

const LocalOp = enum { list, search, read, write, move, delete, git };

fn LocalResultType(comptime op: LocalOp) type {
    return switch (op) {
        .list => DirectoryResult,
        .search => SearchResult,
        .read => ReadResult,
        .write => WriteResult,
        .move, .delete => MutationResult,
        .git => GitStatusResult,
    };
}

fn LocalJob(comptime op: LocalOp) type {
    return struct {
        const Self = @This();
        const R = LocalResultType(op);
        gpa: Allocator,
        io: Io,
        root: []const u8,
        a: []const u8 = "",
        b: []const u8 = "",
        c: []const u8 = "",
        flag: bool = false,
        crlf: bool = false,
        bom: bool = false,
        owned: ?[]u8 = null,
        // Copies taken at spawn time (the caller's strings are transient).
        copies: [4]?[]u8 = .{ null, null, null, null },

        pub fn run(self: *Self) R {
            return switch (op) {
                .list => listLocal(self.gpa, self.io, self.root, self.a, self.flag),
                .search => searchLocal(self.gpa, self.io, self.root, self.a, self.flag),
                .read => readLocal(self.gpa, self.io, self.root, self.a),
                .write => writeLocal(self.gpa, self.io, self.root, self.a, self.b, self.owned orelse "", self.crlf, self.bom),
                .move => moveLocal(self.gpa, self.io, self.root, self.a, self.b, self.c),
                .delete => deleteLocal(self.gpa, self.io, self.root, self.a, self.c, self.flag),
                .git => gitStatusLocal(self.gpa, self.io, self.root),
            };
        }

        /// Copy the borrowed strings (callers pass transient slices).
        pub fn owning(self: Self) Self {
            var j = self;
            inline for (.{ "root", "a", "b", "c" }, 0..) |name, i| {
                const copy = j.gpa.dupe(u8, @field(j, name)) catch @panic("OOM");
                j.copies[i] = copy;
                @field(j, name) = copy;
            }
            return j;
        }

        pub fn discard(_: *Self, r: R) void {
            r.deinit();
        }

        pub fn deinit(self: *Self) void {
            if (self.owned) |o| self.gpa.free(o);
            self.owned = null;
            for (&self.copies) |*cp| if (cp.*) |s| {
                self.gpa.free(s);
                cp.* = null;
            };
        }
    };
}

fn joinPath(a: Allocator, root: []const u8, rel: []const u8) []const u8 {
    if (rel.len == 0) return root;
    return std.fs.path.join(a, &.{ root, rel }) catch rel;
}

/// The engine's path rules: relative, no `..`, no `.git`.
pub fn validRelative(path: []const u8) bool {
    if (path.len == 0) return true;
    if (path[0] == '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        if (std.ascii.eqlIgnoreCase(part, ".git")) return false;
    }
    return true;
}

fn revisionOf(st: Io.File.Stat) []const u8 {
    var h = std.hash.Wyhash.init(0x5eed);
    h.update(std.mem.asBytes(&st.kind));
    h.update(std.mem.asBytes(&st.mtime.nanoseconds));
    h.update(std.mem.asBytes(&st.size));
    const v = h.final();
    const S = struct {
        threadlocal var buf: [16]u8 = undefined;
    };
    S.buf = std.fmt.bytesToHex(std.mem.toBytes(v), .lower);
    return &S.buf;
}

fn fingerprintStat(st: Io.File.Stat) u64 {
    var h = std.hash.Wyhash.init(7);
    h.update(std.mem.asBytes(&st.mtime.nanoseconds));
    h.update(std.mem.asBytes(&st.size));
    h.update(std.mem.asBytes(&st.kind));
    return h.final() | 1;
}

const missing_print: u64 = 2; // even: never produced by fingerprintStat

/// Minimal `.gitignore` support (root file only): names, `dir/`, `*.ext`,
/// `/anchored`, `prefix*`, comments and negations are skipped.
pub const IgnoreRules = struct {
    patterns: std.ArrayList([]const u8) = .empty,

    pub fn load(a: Allocator, io: Io, root: []const u8) IgnoreRules {
        var self: IgnoreRules = .{};
        const p = joinPath(a, root, ".gitignore");
        const bytes = Io.Dir.cwd().readFileAlloc(io, p, a, .limited(1 << 20)) catch return self;
        var it = std.mem.tokenizeAny(u8, bytes, "\r\n");
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0 or line[0] == '#' or line[0] == '!') continue;
            self.patterns.append(a, line) catch {};
        }
        return self;
    }

    pub fn ignored(self: *const IgnoreRules, rel: []const u8, name: []const u8, is_dir: bool) bool {
        for (self.patterns.items) |pat_in| {
            var pat = pat_in;
            const dir_only = pat.len > 1 and pat[pat.len - 1] == '/';
            if (dir_only) pat = pat[0 .. pat.len - 1];
            if (dir_only and !is_dir) continue;
            const anchored = pat[0] == '/';
            if (anchored) pat = pat[1..];
            const subject = if (anchored or std.mem.indexOfScalar(u8, pat, '/') != null) rel else name;
            if (globMatch(pat, subject)) return true;
        }
        return false;
    }

    fn globMatch(pat: []const u8, s: []const u8) bool {
        if (pat.len == 0) return s.len == 0;
        if (pat[0] == '*') {
            var i: usize = 0;
            while (i <= s.len) : (i += 1) {
                if (i > 0 and s[i - 1] == '/') break;
                if (globMatch(pat[1..], s[i..])) return true;
            }
            return false;
        }
        if (s.len == 0) return false;
        if (pat[0] == '?' or pat[0] == s[0]) return globMatch(pat[1..], s[1..]);
        return false;
    }
};

fn kindOf(k: Io.File.Kind) ?proto.EntryKind {
    return switch (k) {
        .directory => .directory,
        .file => .file,
        .sym_link => .symlink,
        else => null,
    };
}

fn entryLess(_: void, l: proto.Entry, r: proto.Entry) bool {
    const lr: u8 = switch (l.kind) {
        .directory => 0,
        .file => 1,
        .symlink => 2,
    };
    const rr: u8 = switch (r.kind) {
        .directory => 0,
        .file => 1,
        .symlink => 2,
    };
    if (lr != rr) return lr < rr;
    const o = std.ascii.orderIgnoreCase(l.name, r.name);
    if (o != .eq) return o == .lt;
    return std.mem.lessThan(u8, l.path, r.path);
}

fn listLocal(gpa: Allocator, io: Io, root: []const u8, directory: []const u8, include_ignored: bool) DirectoryResult {
    if (!validRelative(directory)) return DirectoryResult.fail(gpa, "Invalid path.", .{});
    var out = DirectoryResult.init(gpa);
    const a = out.allocator();
    const rules = IgnoreRules.load(a, io, root);
    const full = joinPath(a, root, directory);
    var dir = Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch |err| {
        out.err = std.fmt.allocPrint(a, "Could not open {s}: {t}", .{ if (directory.len == 0) "workspace" else directory, err }) catch "error";
        // The directory travels with the error so the tree marks the right node.
        out.value = .{ .directory = a.dupe(u8, directory) catch "", .entries = &.{} };
        return out;
    };
    defer dir.close(io);
    var entries: std.ArrayList(proto.Entry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (std.ascii.eqlIgnoreCase(e.name, ".git")) continue;
        const kind = kindOf(e.kind) orelse continue;
        const name = a.dupe(u8, e.name) catch continue;
        const rel = if (directory.len == 0) name else std.fmt.allocPrint(a, "{s}/{s}", .{ directory, name }) catch continue;
        const ign = rules.ignored(rel, name, kind == .directory);
        if (ign and !include_ignored) continue;
        const st = dir.statFile(io, e.name, .{ .follow_symlinks = false }) catch null;
        entries.append(a, .{
            .mutationRevision = if (st) |s| (if (kind != .symlink) a.dupe(u8, revisionOf(s)) catch null else null) else null,
            .path = rel,
            .name = name,
            .kind = kind,
            .size = if (st) |s| (if (kind == .file) s.size else null) else null,
            .ignored = ign,
            .readOnly = kind != .file,
        }) catch {};
        if (entries.items.len >= 50_000) break;
    }
    std.mem.sort(proto.Entry, entries.items, {}, entryLess);
    out.value = .{
        .checkoutId = "local",
        .mutationCapabilities = .{ .moveEntry = true, .deleteEntry = true },
        .directory = a.dupe(u8, directory) catch "",
        .entries = entries.items,
    };
    return out;
}

fn searchLocal(gpa: Allocator, io: Io, root: []const u8, query: []const u8, include_ignored: bool) SearchResult {
    var out = SearchResult.init(gpa);
    const a = out.allocator();
    const q = std.mem.trim(u8, query, " \t");
    if (q.len == 0) {
        out.value = &.{};
        return out;
    }
    const ql = std.ascii.allocLowerString(a, q) catch "";
    const rules = IgnoreRules.load(a, io, root);
    var matches: std.ArrayList(proto.SearchMatch) = .empty;
    // Breadth-first walk.
    var queue: std.ArrayList([]const u8) = .empty;
    queue.append(a, "") catch {};
    var qi: usize = 0;
    var visited: usize = 0;
    while (qi < queue.items.len and visited < 200_000) : (qi += 1) {
        const rel_dir = queue.items[qi];
        var dir = Io.Dir.cwd().openDir(io, joinPath(a, root, rel_dir), .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            visited += 1;
            if (std.ascii.eqlIgnoreCase(e.name, ".git")) continue;
            const kind = kindOf(e.kind) orelse continue;
            const name = a.dupe(u8, e.name) catch continue;
            const rel = if (rel_dir.len == 0) name else std.fmt.allocPrint(a, "{s}/{s}", .{ rel_dir, name }) catch continue;
            if (rules.ignored(rel, name, kind == .directory) and !include_ignored) continue;
            if (kind == .directory) queue.append(a, rel) catch {};
            if (proto.searchScore(name, rel, ql)) |score| {
                matches.append(a, .{ .path = rel, .name = name, .kind = kind, .score = score }) catch {};
            }
        }
    }
    std.mem.sort(proto.SearchMatch, matches.items, {}, proto.lessThanMatch);
    out.value = matches.items[0..@min(matches.items.len, proto.max_search_results)];
    return out;
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn detectLineEnding(b: []const u8) proto.LineEnding {
    var crlf: usize = 0;
    var lf: usize = 0;
    var lone_cr: usize = 0;
    var i: usize = 0;
    while (i < b.len) {
        const nl = std.mem.indexOfAnyPos(u8, b, i, "\r\n") orelse break;
        if (b[nl] == '\r') {
            if (nl + 1 < b.len and b[nl + 1] == '\n') {
                crlf += 1;
                i = nl + 2;
            } else {
                lone_cr += 1;
                i = nl + 1;
            }
        } else {
            lf += 1;
            i = nl + 1;
        }
    }
    if (crlf == 0 and lf == 0 and lone_cr == 0) return .none;
    if (crlf == 0 and lone_cr == 0) return .lf;
    if (lf == 0 and lone_cr == 0) return .crlf;
    return .mixed;
}

/// Engine `classify_file_text` (shared by the local read and tests).
pub fn classify(gpa: Allocator, path: []const u8, bytes: []u8, max_editable: usize, out: *ReadResult) void {
    var r = Result(proto.FileText).init(gpa);
    const a = r.allocator();
    const hash = sha256Hex(bytes);
    var ft: proto.FileText = .{ .checkoutId = "local", .path = a.dupe(u8, path) catch "", .contentHash = a.dupe(u8, &hash) catch null, .size = bytes.len };
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) {
        ft.encoding = .binary;
        ft.readOnlyReason = .binary;
        r.value = ft;
        out.base = r;
        gpa.free(bytes);
        return;
    }
    var body: []u8 = bytes;
    ft.encoding = .utf8;
    if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) {
        ft.encoding = .utf8Bom;
        body = bytes[3..];
    }
    if (!std.unicode.utf8ValidateSlice(body)) {
        ft.encoding = .unsupported;
        ft.readOnlyReason = .unsupportedEncoding;
        r.value = ft;
        out.base = r;
        gpa.free(bytes);
        return;
    }
    const le = detectLineEnding(body);
    ft.lineEnding = le;
    // Normalize CRLF to LF in place.
    var n = body.len;
    if (le == .crlf or le == .mixed) {
        var w: usize = 0;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] == '\r' and i + 1 < body.len and body[i + 1] == '\n') continue;
            body[w] = body[i];
            w += 1;
        }
        n = w;
    }
    // Move the text to the front of the allocation (dropping a BOM).
    if (body.ptr != bytes.ptr) std.mem.copyForwards(u8, bytes[0..n], body[0..n]);
    const text = if (gpa.resize(bytes, n)) bytes[0..n] else blk: {
        const t = gpa.dupe(u8, bytes[0..n]) catch bytes[0..n];
        if (t.ptr != bytes.ptr) gpa.free(bytes);
        break :blk t;
    };
    if (bytes.len > max_editable) ft.readOnlyReason = .tooLarge else if (le == .mixed) ft.readOnlyReason = .mixedLineEndings;
    ft.text = text;
    r.value = ft;
    out.base = r;
    out.text = text;
}

fn readLocal(gpa: Allocator, io: Io, root: []const u8, path: []const u8) ReadResult {
    var out: ReadResult = .{ .gpa = gpa };
    if (!validRelative(path) or path.len == 0) {
        out.base = Result(proto.FileText).fail(gpa, "Invalid path.", .{});
        return out;
    }
    var path_buf: [4096]u8 = undefined;
    const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, path }) catch {
        out.base = Result(proto.FileText).fail(gpa, "Path too long.", .{});
        return out;
    };
    const st = Io.Dir.cwd().statFile(io, full, .{ .follow_symlinks = false }) catch |err| {
        out.base = Result(proto.FileText).fail(gpa, "{s}", .{if (err == error.FileNotFound) "File not found." else "Could not read file."});
        return out;
    };
    if (st.kind != .file) {
        var r = Result(proto.FileText).init(gpa);
        r.value = .{ .path = r.allocator().dupe(u8, path) catch "", .readOnlyReason = if (st.kind == .sym_link) .symlink else .notRegularFile, .encoding = .unsupported, .size = st.size };
        out.base = r;
        return out;
    }
    const bytes = Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(local_max_read)) catch |err| {
        out.base = Result(proto.FileText).fail(gpa, "Could not read file ({t}).", .{err});
        return out;
    };
    classify(gpa, path, bytes, local_max_editable, &out);
    return out;
}

fn writeLocal(gpa: Allocator, io: Io, root: []const u8, path: []const u8, expected_hash: []const u8, text: []const u8, crlf: bool, bom: bool) WriteResult {
    var out = WriteResult.init(gpa);
    const a = out.allocator();
    if (!validRelative(path) or path.len == 0) {
        out.err = "Invalid path.";
        return out;
    }
    const full = joinPath(a, root, path);
    // Hash guard: the file on disk must still be what the editor loaded.
    const current = Io.Dir.cwd().readFileAlloc(io, full, a, .limited(local_max_read)) catch |err| {
        if (err == error.FileNotFound) {
            out.value = .{ .conflict = .{ .reason = .deleted } };
        } else out.err = std.fmt.allocPrint(a, "Could not read file ({t}).", .{err}) catch "error";
        return out;
    };
    const cur_hash = sha256Hex(current);
    if (!std.mem.eql(u8, &cur_hash, expected_hash)) {
        out.value = .{ .conflict = .{ .reason = .changed, .currentContentHash = a.dupe(u8, &cur_hash) catch null } };
        return out;
    }
    // Re-apply the file's encoding and line ending.
    var bytes: std.ArrayList(u8) = .empty;
    if (bom) bytes.appendSlice(a, "\xEF\xBB\xBF") catch {};
    if (crlf) {
        bytes.ensureTotalCapacity(a, text.len + text.len / 16 + 4) catch {};
        for (text) |ch| {
            if (ch == '\n') bytes.append(a, '\r') catch {};
            bytes.append(a, ch) catch {};
        }
    } else bytes.appendSlice(a, text) catch {};
    // Atomic replace: temp file + rename.
    const tmp = std.fmt.allocPrint(a, "{s}.zeron-save-{x}", .{ full, std.hash.Wyhash.hash(0, text) }) catch full;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = bytes.items }) catch |err| {
        out.err = std.fmt.allocPrint(a, "Could not write file ({t}).", .{err}) catch "error";
        return out;
    };
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), full, io) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        out.err = std.fmt.allocPrint(a, "Could not replace file ({t}).", .{err}) catch "error";
        return out;
    };
    const new_hash = sha256Hex(bytes.items);
    out.value = .{ .written = .{ .path = a.dupe(u8, path) catch "", .contentHash = a.dupe(u8, &new_hash) catch "", .size = bytes.items.len } };
    return out;
}

fn mutationReject(gpa: Allocator, reason: proto.MutationRejection, msg: []const u8) MutationResult {
    var out = MutationResult.init(gpa);
    out.value = .{ .rejected = .{ .reason = reason, .message = out.allocator().dupe(u8, msg) catch "" } };
    return out;
}

fn moveLocal(gpa: Allocator, io: Io, root: []const u8, source: []const u8, dest: []const u8, revision: []const u8) MutationResult {
    if (!validRelative(source) or !validRelative(dest) or source.len == 0 or dest.len == 0) return mutationReject(gpa, .invalidPath, "Invalid path");
    var a_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    const src = std.fmt.bufPrint(&a_buf, "{s}/{s}", .{ root, source }) catch return mutationReject(gpa, .invalidPath, "Path too long");
    const dst = std.fmt.bufPrint(&b_buf, "{s}/{s}", .{ root, dest }) catch return mutationReject(gpa, .invalidPath, "Path too long");
    const st = Io.Dir.cwd().statFile(io, src, .{ .follow_symlinks = false }) catch return mutationReject(gpa, .sourceMissing, "Entry no longer exists");
    if (revision.len > 0 and !std.mem.eql(u8, revisionOf(st), revision)) return mutationReject(gpa, .sourceChanged, "Entry changed; refresh and try again");
    if (Io.Dir.cwd().statFile(io, dst, .{ .follow_symlinks = false })) |_| {
        return mutationReject(gpa, .destinationExists, "An entry with that name already exists");
    } else |_| {}
    if (std.mem.startsWith(u8, dest, source) and dest.len > source.len and dest[source.len] == '/') return mutationReject(gpa, .invalidDestination, "Cannot move a folder into itself");
    Io.Dir.cwd().rename(src, Io.Dir.cwd(), dst, io) catch |err| {
        var out = MutationResult.init(gpa);
        out.value = .{ .rejected = .{ .reason = .permissionDenied, .message = std.fmt.allocPrint(out.allocator(), "Could not move entry ({t})", .{err}) catch "" } };
        return out;
    };
    var out = MutationResult.init(gpa);
    const a = out.allocator();
    out.value = .{ .applied = .{ .change = .{ .kind = .renamed, .path = a.dupe(u8, dest) catch "", .oldPath = a.dupe(u8, source) catch null } } };
    return out;
}

fn deleteLocal(gpa: Allocator, io: Io, root: []const u8, path: []const u8, revision: []const u8, recursive: bool) MutationResult {
    if (!validRelative(path) or path.len == 0) return mutationReject(gpa, .invalidPath, "Invalid path");
    var buf: [4096]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, path }) catch return mutationReject(gpa, .invalidPath, "Path too long");
    const st = Io.Dir.cwd().statFile(io, full, .{ .follow_symlinks = false }) catch return mutationReject(gpa, .sourceMissing, "Entry no longer exists");
    if (revision.len > 0 and !std.mem.eql(u8, revisionOf(st), revision)) return mutationReject(gpa, .sourceChanged, "Entry changed; reopen Delete to confirm its current contents");
    const ok = if (st.kind == .directory)
        (if (recursive) Io.Dir.cwd().deleteTree(io, full) else Io.Dir.cwd().deleteDir(io, full))
    else
        Io.Dir.cwd().deleteFile(io, full);
    ok catch |err| {
        var out = MutationResult.init(gpa);
        out.value = .{ .rejected = .{ .reason = .permissionDenied, .message = std.fmt.allocPrint(out.allocator(), "Could not delete entry ({t})", .{err}) catch "" } };
        return out;
    };
    var out = MutationResult.init(gpa);
    out.value = .{ .applied = .{ .change = .{ .kind = .removed, .path = out.allocator().dupe(u8, path) catch "" } } };
    return out;
}

/// `git status --porcelain=v1 -z` → `CheckoutGitStatus` (nothing outside a repo).
fn gitStatusLocal(gpa: Allocator, io: Io, root: []const u8) GitStatusResult {
    var out = GitStatusResult.init(gpa);
    const a = out.allocator();
    const res = std.process.run(a, io, .{
        .argv = &.{ "git", "-C", root, "status", "--porcelain=v1", "-z", "--untracked-files=all" },
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch {
        out.err = "git unavailable";
        return out;
    };
    switch (res.term) {
        .exited => |code| if (code != 0) {
            out.err = "not a git repository";
            return out;
        },
        else => {
            out.err = "git failed";
            return out;
        },
    }
    var files: std.ArrayList(proto.GitFileStatus) = .empty;
    var it = std.mem.splitScalar(u8, res.stdout, 0);
    while (it.next()) |rec| {
        if (rec.len < 4) continue;
        const x = rec[0];
        const y = rec[1];
        const path = a.dupe(u8, rec[3..]) catch continue;
        var old: ?[]const u8 = null;
        if (x == 'R' or x == 'C') old = it.next();
        files.append(a, .{ .path = path, .oldPath = old, .index = gitState(x), .worktree = gitState(y) }) catch {};
    }
    out.value = .{ .checkoutId = "local", .deviceId = "local", .revision = "", .complete = true, .files = files.items };
    return out;
}

fn gitState(c: u8) proto.GitFileState {
    return switch (c) {
        'A' => .added,
        'M' => .modified,
        'D' => .deleted,
        'R' => .renamed,
        'C' => .copied,
        'U' => .unmerged,
        '?' => .untracked,
        'T' => .typeChanged,
        else => .unchanged,
    };
}

const PollOutcome = struct {
    dirs: []const []const u8,
    dir_prints: []u64,
    files: []const []const u8,
    file_prints: []u64,

    fn deinit(self: PollOutcome, gpa: Allocator) void {
        for (self.dirs) |d| gpa.free(d);
        gpa.free(self.dirs);
        gpa.free(self.dir_prints);
        for (self.files) |f| gpa.free(f);
        gpa.free(self.files);
        gpa.free(self.file_prints);
    }
};

const PollJob = struct {
    gpa: Allocator,
    io: Io,
    root: []const u8,
    dirs: []const []const u8,
    files: []const []const u8,
    handed_off: bool = false,

    pub fn run(self: *PollJob) PollOutcome {
        const dp = self.gpa.alloc(u64, self.dirs.len) catch @panic("OOM");
        for (self.dirs, 0..) |d, i| dp[i] = dirPrint(self.gpa, self.io, self.root, d);
        const fp = self.gpa.alloc(u64, self.files.len) catch @panic("OOM");
        for (self.files, 0..) |f, i| {
            var buf: [4096]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.root, f }) catch {
                fp[i] = missing_print;
                continue;
            };
            fp[i] = if (Io.Dir.cwd().statFile(self.io, full, .{})) |st| fingerprintStat(st) else |_| missing_print;
        }
        self.handed_off = true;
        return .{ .dirs = self.dirs, .dir_prints = dp, .files = self.files, .file_prints = fp };
    }

    pub fn discard(self: *PollJob, r: PollOutcome) void {
        r.deinit(self.gpa);
    }

    pub fn deinit(self: *PollJob) void {
        if (self.handed_off) return;
        for (self.dirs) |d| self.gpa.free(d);
        self.gpa.free(self.dirs);
        for (self.files) |f| self.gpa.free(f);
        self.gpa.free(self.files);
    }
};

fn dirPrint(gpa: Allocator, io: Io, root: []const u8, rel: []const u8) u64 {
    var buf: [4096]u8 = undefined;
    const full = if (rel.len == 0) root else std.fmt.bufPrint(&buf, "{s}/{s}", .{ root, rel }) catch return missing_print;
    var dir = Io.Dir.cwd().openDir(io, full, .{ .iterate = true }) catch return missing_print;
    defer dir.close(io);
    var acc: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        var h = std.hash.Wyhash.init(0);
        h.update(e.name);
        h.update(std.mem.asBytes(&e.kind));
        if (e.kind == .file) if (dir.statFile(io, e.name, .{ .follow_symlinks = false })) |st| {
            // Files' contents are watched separately; size/mtime of the listing
            // only matter for the explorer's revision tokens.
            h.update(std.mem.asBytes(&st.mtime.nanoseconds));
        } else |_| {};
        acc +%= h.final(); // order-independent
    }
    _ = gpa;
    return acc | 1;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "classify normalizes CRLF, detects binary and BOM" {
    const gpa = testing.allocator;
    {
        var out: ReadResult = .{ .gpa = gpa };
        classify(gpa, "a.txt", try gpa.dupe(u8, "a\r\nb\r\n"), 1 << 20, &out);
        defer out.deinit();
        try testing.expectEqualStrings("a\nb\n", out.text.?);
        try testing.expectEqual(proto.LineEnding.crlf, out.file().?.lineEnding.?);
        try testing.expect(out.file().?.readOnlyReason == null);
    }
    {
        var out: ReadResult = .{ .gpa = gpa };
        classify(gpa, "b.bin", try gpa.dupe(u8, "ab\x00cd"), 1 << 20, &out);
        defer out.deinit();
        try testing.expect(out.text == null);
        try testing.expectEqual(proto.ReadOnlyReason.binary, out.file().?.readOnlyReason.?);
    }
    {
        var out: ReadResult = .{ .gpa = gpa };
        classify(gpa, "c.txt", try gpa.dupe(u8, "\xEF\xBB\xBFhi\n"), 1 << 20, &out);
        defer out.deinit();
        try testing.expectEqualStrings("hi\n", out.text.?);
        try testing.expectEqual(proto.TextEncoding.utf8Bom, out.file().?.encoding);
    }
}

test "gitignore patterns" {
    var rules: IgnoreRules = .{};
    defer rules.patterns.deinit(testing.allocator);
    try rules.patterns.append(testing.allocator, "target/");
    try rules.patterns.append(testing.allocator, "*.log");
    try rules.patterns.append(testing.allocator, "/build");
    try testing.expect(rules.ignored("target", "target", true));
    try testing.expect(!rules.ignored("target", "target", false));
    try testing.expect(rules.ignored("src/x.log", "x.log", false));
    try testing.expect(rules.ignored("build", "build", true));
    try testing.expect(!rules.ignored("src/build", "build", true));
}

test "relative path validation" {
    try testing.expect(validRelative("src/main.rs"));
    try testing.expect(!validRelative("../x"));
    try testing.expect(!validRelative(".git/config"));
    try testing.expect(!validRelative("/abs"));
}

test "local list, read, write with hash guard, move and delete" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/a.rs", .data = "fn a() {}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "README.md", .data = "# hi\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "x.log", .data = "log" });
    var root_buf: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    const list = listLocal(gpa, io, root, "", false);
    defer list.deinit();
    const page = list.value.?;
    try testing.expectEqual(@as(usize, 3), page.entries.len);
    try testing.expectEqualStrings("src", page.entries[0].name);
    try testing.expectEqualStrings(".gitignore", page.entries[1].name);
    const all = listLocal(gpa, io, root, "", true);
    defer all.deinit();
    try testing.expectEqual(@as(usize, 4), all.value.?.entries.len);

    var read = readLocal(gpa, io, root, "src/a.rs");
    defer read.deinit();
    const hash = read.file().?.contentHash.?;
    const w1 = writeLocal(gpa, io, root, "src/a.rs", hash, "fn b() {}\n", false, false);
    defer w1.deinit();
    try testing.expect(w1.value.? == .written);
    // Writing again with the stale hash conflicts.
    const w2 = writeLocal(gpa, io, root, "src/a.rs", hash, "fn c() {}\n", false, false);
    defer w2.deinit();
    try testing.expect(w2.value.? == .conflict);

    const mv = moveLocal(gpa, io, root, "README.md", "NOTES.md", "");
    defer mv.deinit();
    try testing.expect(mv.value.? == .applied);
    const del = deleteLocal(gpa, io, root, "src", "", true);
    defer del.deinit();
    try testing.expect(del.value.? == .applied);
    const after = listLocal(gpa, io, root, "", false);
    defer after.deinit();
    try testing.expectEqual(@as(usize, 2), after.value.?.entries.len);

    const found = searchLocal(gpa, io, root, "notes", false);
    defer found.deinit();
    try testing.expectEqual(@as(usize, 1), found.value.?.len);
}

test "readLocal reads a regular file under a real tmp dir" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    var r = readLocal(testing.allocator, io, buf[0..n], "a.txt");
    defer r.deinit();
    if (r.text == null) std.debug.print("readLocal root={s} result={any}\n", .{ buf[0..n], r.base });
    try testing.expectEqualStrings("hello\n", r.text orelse "");
}
