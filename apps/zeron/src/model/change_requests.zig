//! Checkout change-request (pull request) state for desktop views — port of
//! zeron `crates/ui/src/change_requests.rs` (pure resolution) and the
//! `AppState` watch lifecycle in `state.rs`
//! (`reconcile_change_request_watches`, `spawn_change_request_watch`).
//!
//! The workspace document stays the source of truth for chats; PR metadata
//! is host-local, short-lived capability state, never written back.
//!
//! - one `WatchCheckoutChangeRequest` per distinct active checkout (device,
//!   repo root, branch, checkout id) of a chat with a `sourceContext`;
//! - `targetDeviceId` routes to the checkout's host when it is not this
//!   engine; an `UnknownMethod` marks the device unsupported until it
//!   publishes a different engine version;
//! - a snapshot is shown for a chat only after re-validating the device,
//!   repo root, branch and checkout id (`changeRequestForChat`);
//! - a dropped stream keeps the last snapshot and resubscribes after 2s.
//!
//! ```zig
//! const prs = state.read(cx).change_requests;
//! if (prs.read(cx).forChat(chat)) |pr| badge(pr)   // *const protocol.ChangeRequestSummary
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const zpui = @import("zpui");
const engine_mod = @import("zeron_engine");
const es = @import("engine_state.zig");
const workspace_mod = @import("workspace.zig");
const settings_store = @import("settings_store.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Task = zpui.Task;
const protocol = engine_mod.protocol;
const Chat = protocol.Chat;
const Summary = protocol.ChangeRequestSummary;
const Status = protocol.CheckoutChangeRequestStatus;

const log = std.log.scoped(.zeron_change_requests);

// ---------------------------------------------------------------------------
// Badge model
// ---------------------------------------------------------------------------

pub const BadgeTone = enum {
    open,
    merged,
    closed,
};

pub const BadgeModel = struct {
    /// Decimal PR number.
    number: []const u8,
    state_label: []const u8,
    /// Title with CR/LF replaced by spaces.
    title: []const u8,
    tone: BadgeTone,

    /// `ChangeRequestBadgeModel::from_summary` (strings from `a`).
    pub fn fromSummary(a: Allocator, s: *const Summary) Allocator.Error!BadgeModel {
        const label: []const u8, const tone: BadgeTone = switch (s.state) {
            .open => .{ "Open", .open },
            .merged => .{ "Merged", .merged },
            .closed => .{ "Closed", .closed },
        };
        const title = try a.dupe(u8, s.title);
        for (title) |*c| if (c.* == '\r' or c.* == '\n') {
            c.* = ' ';
        };
        return .{ .number = try std.fmt.allocPrint(a, "{d}", .{s.number}), .state_label = label, .title = title, .tone = tone };
    }
};

/// Where a badge renders (`ChangeRequestBadgeSurface`).
pub const BadgeSurface = enum { sidebar, composer };

// ---------------------------------------------------------------------------
// Watch targets
// ---------------------------------------------------------------------------

/// One host-side checkout watch; several chats can share it.
pub const WatchKey = struct {
    device_id: []const u8,
    cwd: []const u8,
    branch: []const u8,
    checkout_id: ?[]const u8,

    pub fn eql(a: WatchKey, b: WatchKey) bool {
        return std.mem.eql(u8, a.device_id, b.device_id) and std.mem.eql(u8, a.cwd, b.cwd) and
            std.mem.eql(u8, a.branch, b.branch) and optEql(a.checkout_id, b.checkout_id);
    }

    fn dupe(self: WatchKey, gpa: Allocator) Allocator.Error!WatchKey {
        const d = try gpa.dupe(u8, self.device_id);
        errdefer gpa.free(d);
        const c = try gpa.dupe(u8, self.cwd);
        errdefer gpa.free(c);
        const b = try gpa.dupe(u8, self.branch);
        errdefer gpa.free(b);
        return .{ .device_id = d, .cwd = c, .branch = b, .checkout_id = if (self.checkout_id) |k| try gpa.dupe(u8, k) else null };
    }

    fn free(self: WatchKey, gpa: Allocator) void {
        gpa.free(self.device_id);
        gpa.free(self.cwd);
        gpa.free(self.branch);
        if (self.checkout_id) |k| gpa.free(k);
    }
};

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn blank(s: []const u8) bool {
    return std.mem.trim(u8, s, " \t\r\n\x0b\x0c").len == 0;
}

/// `conversation_branch`: only conversation-owned source context is trusted
/// (a legacy scalar branch may describe an old checkout state).
pub fn conversationBranch(chat: *const Chat) ?[]const u8 {
    const src = chat.sourceContext orelse return null;
    if (blank(src.branch)) return null;
    return src.branch;
}

/// `desired_watch_targets`: active, fully identified checkouts, deduplicated.
pub fn desiredWatchTargets(a: Allocator, chats: []const Chat, ctx: anytype, comptime unsupported: fn (@TypeOf(ctx), []const u8) bool) Allocator.Error![]WatchKey {
    var out: std.ArrayList(WatchKey) = .empty;
    for (chats) |*chat| {
        if (chat.archived) continue;
        if (unsupported(ctx, chat.deviceId)) continue;
        const src = chat.sourceContext orelse continue;
        if (blank(src.branch)) continue;
        const key: WatchKey = .{ .device_id = chat.deviceId, .cwd = src.repoRoot, .branch = src.branch, .checkout_id = src.checkoutId };
        for (out.items) |k| {
            if (k.eql(key)) break;
        } else try out.append(a, key);
    }
    return out.toOwnedSlice(a);
}

/// `watch_params`: `{cwd, branch}` plus `targetDeviceId` unless the checkout
/// lives on the connected engine.
pub const WatchParams = struct {
    cwd: []const u8,
    branch: []const u8,
    targetDeviceId: ?[]const u8 = null,

    pub fn jsonStringify(self: WatchParams, w: anytype) !void {
        try w.beginObject();
        try w.objectField("cwd");
        try w.write(self.cwd);
        try w.objectField("branch");
        try w.write(self.branch);
        if (self.targetDeviceId) |t| {
            try w.objectField("targetDeviceId");
            try w.write(t);
        }
        try w.endObject();
    }
};

pub fn watchParams(target: WatchKey, local_device_id: ?[]const u8) WatchParams {
    const local = if (local_device_id) |l| std.mem.eql(u8, l, target.device_id) else false;
    return .{ .cwd = target.cwd, .branch = target.branch, .targetDeviceId = if (local) null else target.device_id };
}

/// `change_request_for_chat`: a snapshot for this chat, re-validated against
/// device, repo root, branch and checkout id (never the cache key alone).
pub fn changeRequestForChat(chat: *const Chat, snapshots: []const *const Status) ?*const Summary {
    for (snapshots) |snap| if (snapshotMatches(chat, snap)) return if (snap.changeRequest) |*cr| cr else null;
    return null;
}

fn snapshotMatches(chat: *const Chat, s: *const Status) bool {
    const branch = std.mem.trim(u8, conversationBranch(chat) orelse return false, " \t\r\n\x0b\x0c");
    if (branch.len == 0) return false;
    const src = chat.sourceContext orelse return false;
    if (!std.mem.eql(u8, s.deviceId, chat.deviceId)) return false;
    if (!std.mem.eql(u8, s.cwd, src.repoRoot)) return false;
    if (!std.mem.eql(u8, s.branch, branch)) return false;
    return s.checkoutId.len > 0 and std.mem.eql(u8, s.checkoutId, src.checkoutId);
}

// ---------------------------------------------------------------------------
// Client state (`ChangeRequestClientState`)
// ---------------------------------------------------------------------------

const Snapshot = struct { key: WatchKey, frame: json.Parsed(Status) };

pub const ClientState = struct {
    gpa: Allocator,
    snapshots: std.ArrayList(Snapshot) = .empty,
    /// device id → the engine version that rejected the method.
    unsupported: std.StringHashMapUnmanaged(?[]u8) = .empty,

    pub fn init(gpa: Allocator) ClientState {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ClientState) void {
        for (self.snapshots.items) |s| freeSnapshot(self.gpa, s);
        self.snapshots.deinit(self.gpa);
        var it = self.unsupported.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            if (e.value_ptr.*) |v| self.gpa.free(v);
        }
        self.unsupported.deinit(self.gpa);
    }

    fn freeSnapshot(gpa: Allocator, s: Snapshot) void {
        s.key.free(gpa);
        s.frame.deinit();
    }

    pub fn isSupported(self: *const ClientState, device_id: []const u8) bool {
        return !self.unsupported.contains(device_id);
    }

    pub fn markUnsupported(self: *ClientState, device_id: []const u8, engine_version: ?[]const u8) void {
        const v = if (engine_version) |e| self.gpa.dupe(u8, e) catch null else null;
        const gop = self.unsupported.getOrPut(self.gpa, device_id) catch {
            if (v) |x| self.gpa.free(x);
            return;
        };
        if (gop.found_existing) {
            if (gop.value_ptr.*) |old| self.gpa.free(old);
        } else {
            gop.key_ptr.* = self.gpa.dupe(u8, device_id) catch {
                self.unsupported.removeByPtr(gop.key_ptr);
                if (v) |x| self.gpa.free(x);
                return;
            };
        }
        gop.value_ptr.* = v;
        var i: usize = 0;
        while (i < self.snapshots.items.len) {
            if (std.mem.eql(u8, self.snapshots.items[i].key.device_id, device_id)) {
                freeSnapshot(self.gpa, self.snapshots.orderedRemove(i));
            } else i += 1;
        }
    }

    /// Forget a version-skew rejection once the host advertises a different
    /// engine version.
    pub fn clearUnsupportedOnVersionChange(self: *ClientState, device_id: []const u8, engine_version: ?[]const u8) bool {
        const v = self.unsupported.get(device_id) orelse return false;
        if (optEql(v, engine_version)) return false;
        const kv = self.unsupported.fetchRemove(device_id).?;
        self.gpa.free(kv.key);
        if (kv.value) |x| self.gpa.free(x);
        return true;
    }

    /// A new frame replaces the old one for this target (takes `frame`).
    pub fn store(self: *ClientState, key: WatchKey, frame: json.Parsed(Status)) void {
        for (self.snapshots.items) |*s| if (s.key.eql(key)) {
            s.frame.deinit();
            s.frame = frame;
            return;
        };
        const owned = key.dupe(self.gpa) catch {
            frame.deinit();
            return;
        };
        self.snapshots.append(self.gpa, .{ .key = owned, .frame = frame }) catch {
            owned.free(self.gpa);
            frame.deinit();
        };
    }

    pub fn retainTargets(self: *ClientState, targets: []const WatchKey) void {
        var i: usize = 0;
        while (i < self.snapshots.items.len) {
            const keep = for (targets) |t| {
                if (t.eql(self.snapshots.items[i].key)) break true;
            } else false;
            if (keep) i += 1 else freeSnapshot(self.gpa, self.snapshots.orderedRemove(i));
        }
    }

    pub fn changeRequestForChat(self: *const ClientState, chat: *const Chat) ?*const Summary {
        for (self.snapshots.items) |*snap| if (snapshotMatches(chat, &snap.frame.value)) {
            return if (snap.frame.value.changeRequest) |*cr| cr else null;
        };
        return null;
    }
};

// ---------------------------------------------------------------------------
// ChangeRequestStore: the per-checkout watches (AppState's lifecycle)
// ---------------------------------------------------------------------------

pub const ChangeRequestsChanged = struct {};

const Running = struct { key: WatchKey, watch: es.Watch = .{} };

pub const ChangeRequestStore = struct {
    gpa: Allocator,
    engine: Entity(es.EngineState),
    workspace: Entity(workspace_mod.WorkspaceStore),
    subs: zpui.Subscriptions = .{},
    client: ClientState,
    running: std.ArrayList(Running) = .empty,
    retry_task: Task(void) = .none,
    /// `change_requests_visible` (Settings → sidebar "Pull request").
    visible: bool = true,
    /// The local device id the open watches were routed with.
    routed_local: ?[]u8 = null,

    pub const Events = .{ChangeRequestsChanged};

    pub fn init(engine: Entity(es.EngineState), workspace: Entity(workspace_mod.WorkspaceStore), cx: *Context(ChangeRequestStore)) !ChangeRequestStore {
        var self: ChangeRequestStore = .{
            .gpa = cx.gpa(),
            .engine = engine.retain(cx),
            .workspace = workspace.retain(cx),
            .client = .init(cx.gpa()),
        };
        if (settings_store.current(cx.app)) |s| self.visible = s.sidebarShowPullRequest;
        try self.subs.add(cx.gpa(), try cx.subscribe(engine, onEngineEvent));
        try self.subs.add(cx.gpa(), try cx.observe(workspace, onWorkspace));
        if (cx.app.hasGlobal(settings_store.SettingsStore)) try self.subs.add(cx.gpa(), try cx.observeGlobal(settings_store.SettingsStore, onSettings));
        return self;
    }

    pub fn deinit(self: *ChangeRequestStore, app: *App) void {
        self.subs.deinit(self.gpa);
        self.retry_task.cancel();
        self.closeAll();
        self.running.deinit(self.gpa);
        self.client.deinit();
        if (self.routed_local) |l| self.gpa.free(l);
        self.workspace.release(app);
        self.engine.release(app);
    }

    /// The latest valid PR for `chat`.
    pub fn forChat(self: *const ChangeRequestStore, chat: *const Chat) ?*const Summary {
        return self.client.changeRequestForChat(chat);
    }

    /// `set_change_requests_visible`.
    pub fn setVisible(self: *ChangeRequestStore, visible: bool, cx: *Context(ChangeRequestStore)) void {
        if (self.visible == visible) return;
        self.visible = visible;
        self.reconcile(cx);
    }

    /// Engine-free feed (fixtures / tests): store `status` for its own target.
    pub fn applyFixture(self: *ChangeRequestStore, status_json: []const u8, cx: *Context(ChangeRequestStore)) !void {
        const parsed = try json.parseFromSlice(Status, self.gpa, status_json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        const v = parsed.value;
        self.client.store(.{ .device_id = v.deviceId, .cwd = v.cwd, .branch = v.branch, .checkout_id = v.checkoutId }, parsed);
        cx.emit(ChangeRequestsChanged{});
        cx.notify();
    }

    fn onSettings(self: *ChangeRequestStore, cx: *Context(ChangeRequestStore)) void {
        if (settings_store.current(cx.app)) |s| self.setVisible(s.sidebarShowPullRequest, cx);
    }

    fn onWorkspace(self: *ChangeRequestStore, ws: Entity(workspace_mod.WorkspaceStore), cx: *Context(ChangeRequestStore)) void {
        // A host that publishes a new engine version may support the method now.
        for (ws.read(cx).devices()) |d| _ = self.client.clearUnsupportedOnVersionChange(d.id, d.version);
        // Watches opened before LocalDevice resolved route through
        // targetDeviceId: recreate them once local routing is known.
        const local = ws.read(cx).local_device_id;
        if (!optEql(local, self.routed_local)) {
            self.closeAll();
            if (self.routed_local) |l| self.gpa.free(l);
            self.routed_local = if (local) |l| self.gpa.dupe(u8, l) catch null else null;
        }
        self.reconcile(cx);
    }

    fn onEngineEvent(self: *ChangeRequestStore, _: Entity(es.EngineState), ev: *const es.EngineEvent, cx: *Context(ChangeRequestStore)) void {
        switch (ev.*) {
            .connected => {
                self.closeAll();
                self.reconcile(cx);
            },
            .disconnected => {
                self.retry_task.cancel();
                self.closeAll();
            },
            .wake => self.drain(cx),
        }
    }

    fn closeAll(self: *ChangeRequestStore) void {
        for (self.running.items) |*r| {
            r.watch.close();
            r.key.free(self.gpa);
        }
        self.running.clearRetainingCapacity();
    }

    const Unsupported = struct {
        fn check(c: *const ClientState, device: []const u8) bool {
            return !c.isSupported(device);
        }
    };

    /// `reconcile_change_request_watches`.
    pub fn reconcile(self: *ChangeRequestStore, cx: *Context(ChangeRequestStore)) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const targets: []const WatchKey = if (self.visible)
            desiredWatchTargets(arena.allocator(), self.workspace.read(cx).chats(), &self.client, Unsupported.check) catch return
        else
            &.{};
        var i: usize = 0;
        while (i < self.running.items.len) {
            const r = &self.running.items[i];
            const wanted = for (targets) |t| {
                if (t.eql(r.key)) break true;
            } else false;
            if (wanted) {
                i += 1;
            } else {
                r.watch.close();
                r.key.free(self.gpa);
                _ = self.running.orderedRemove(i);
            }
        }
        const before = self.client.snapshots.items.len;
        self.client.retainTargets(targets);
        if (self.client.snapshots.items.len != before) {
            cx.emit(ChangeRequestsChanged{});
            cx.notify();
        }
        for (targets) |t| {
            const exists = for (self.running.items) |r| {
                if (r.key.eql(t)) break true;
            } else false;
            if (exists) continue;
            const owned = t.dupe(self.gpa) catch continue;
            self.running.append(self.gpa, .{ .key = owned }) catch {
                owned.free(self.gpa);
                continue;
            };
        }
        self.openPending(cx);
    }

    fn openPending(self: *ChangeRequestStore, cx: *Context(ChangeRequestStore)) void {
        const conn = self.engine.read(cx).conn orelse return;
        const local = self.workspace.read(cx).local_device_id;
        var failed = false;
        for (self.running.items) |*r| {
            if (r.watch.isOpen()) continue;
            r.watch.open(conn, .WatchCheckoutChangeRequest, watchParams(r.key, local)) catch |err| {
                log.debug("checkout change request watch unavailable ({s}): {t}; retrying", .{ r.key.cwd, err });
                failed = true;
            };
        }
        if (failed) self.scheduleRetry(cx);
    }

    fn scheduleRetry(self: *ChangeRequestStore, cx: *Context(ChangeRequestStore)) void {
        if (self.retry_task.header != null) return;
        self.retry_task = cx.timer(es.retry_delay_ns, onRetry) catch return;
    }

    fn onRetry(self: *ChangeRequestStore, cx: *Context(ChangeRequestStore)) void {
        self.retry_task.detach();
        self.openPending(cx);
    }

    fn drain(self: *ChangeRequestStore, cx: *Context(ChangeRequestStore)) void {
        var changed = false;
        var retry = false;
        var i: usize = 0;
        while (i < self.running.items.len) {
            const r = &self.running.items[i];
            while (r.watch.next()) |payload| {
                const parsed = engine_mod.rpc.decode(Status, payload) catch |err| {
                    log.warn("dropping malformed checkout change request frame: {t}", .{err});
                    continue;
                };
                self.client.store(r.key, parsed);
                changed = true;
            }
            switch (r.watch.end(null)) {
                .open => {},
                .unknown_method => {
                    const device = self.gpa.dupe(u8, r.key.device_id) catch {
                        i += 1;
                        continue;
                    };
                    defer self.gpa.free(device);
                    const version: ?[]const u8 = if (self.workspace.read(cx).device(device)) |d| d.version else null;
                    self.client.markUnsupported(device, version);
                    // Drop every watch on that device (`desired_watch_targets` filters it).
                    var j: usize = 0;
                    while (j < self.running.items.len) {
                        if (std.mem.eql(u8, self.running.items[j].key.device_id, device)) {
                            self.running.items[j].watch.close();
                            self.running.items[j].key.free(self.gpa);
                            _ = self.running.orderedRemove(j);
                        } else j += 1;
                    }
                    changed = true;
                    i = 0;
                    continue;
                },
                // Keep the latest snapshot through a transport gap.
                .closed, .done, .remote => {
                    r.watch.close();
                    retry = true;
                },
            }
            i += 1;
        }
        if (retry) self.scheduleRetry(cx);
        if (changed) {
            cx.emit(ChangeRequestsChanged{});
            cx.notify();
        }
    }
};

// ---------------------------------------------------------------------------
// Tests (zeron `change_requests.rs` unit tests)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testChat(id: []const u8, device: []const u8, cwd: ?[]const u8, checkout: ?[]const u8) Chat {
    return .{ .id = id, .deviceId = device, .archived = false, .cwd = cwd, .branch = "feature/pr", .checkoutId = checkout, .createdAt = "1970-01-01T00:00:00Z", .spaceId = "space" };
}

fn withSource(chat: Chat, branch: []const u8) Chat {
    var c = chat;
    c.sourceContext = .{ .checkoutId = "checkout", .repoRoot = "/repo", .cwd = "/repo", .branch = branch, .headSha = "abc123", .observedAt = "1970-01-01T00:00:02Z" };
    return c;
}

fn testSnapshot(device: []const u8, cwd: []const u8, checkout: []const u8) Status {
    return .{ .checkoutId = checkout, .deviceId = device, .cwd = cwd, .branch = "feature/pr", .updatedAt = "1970-01-01T00:00:01Z", .changeRequest = .{
        .provider = "github",
        .number = 90,
        .title = "Add pull request badges",
        .url = "https://github.com/acme/zeron/pull/90",
        .state = .open,
        .baseRef = "main",
        .headRef = "feature/pr",
    } };
}

fn never(_: void, _: []const u8) bool {
    return false;
}

test "change requests: shared checkout keeps conversation branches independent" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const first = withSource(testChat("first", "local", "/repo", null), "feature/one");
    const second = withSource(testChat("second", "local", "/repo", null), "feature/two");
    const targets = try desiredWatchTargets(arena.allocator(), &.{ first, second }, {}, never);
    try testing.expectEqual(@as(usize, 2), targets.len);
    var snap = testSnapshot("local", "/repo", "checkout");
    snap.branch = "feature/one";
    try testing.expectEqual(@as(u64, 90), changeRequestForChat(&first, &.{&snap}).?.number);
    try testing.expect(changeRequestForChat(&second, &.{&snap}) == null);
}

test "change requests: snapshot validation" {
    const status = testSnapshot("local", "/repo", "checkout");
    const local_chat = withSource(testChat("chat", "local", "/repo", "checkout"), "feature/pr");
    try testing.expectEqual(@as(u64, 90), changeRequestForChat(&local_chat, &.{&status}).?.number);
    // A remote chat needs the same device.
    const remote = withSource(testChat("chat", "remote", "/repo", "checkout"), "feature/pr");
    try testing.expect(changeRequestForChat(&remote, &.{&status}) == null);
    // A mismatched checkout rejects a cwd match.
    var moved = withSource(testChat("chat", "local", "/repo", "new-checkout"), "feature/pr");
    moved.sourceContext.?.checkoutId = "new-checkout";
    const old = testSnapshot("local", "/repo", "old-checkout");
    try testing.expect(changeRequestForChat(&moved, &.{&old}) == null);
    // A different branch hides the snapshot even when the scalar branch matches.
    const other = withSource(testChat("chat", "local", "/repo", "checkout"), "feature/other");
    try testing.expect(changeRequestForChat(&other, &.{&status}) == null);
}

test "change requests: source-less chats hide legacy metadata" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const worktree = testChat("chat", "local", "/repo", null);
    const status = testSnapshot("local", "/repo", "checkout");
    try testing.expect(changeRequestForChat(&worktree, &.{&status}) == null);
    try testing.expect(conversationBranch(&worktree) == null);
    try testing.expectEqual(@as(usize, 0), (try desiredWatchTargets(arena.allocator(), &.{worktree}, {}, never)).len);
    const root = testChat("chat", "local", null, null);
    const status2 = testSnapshot("local", "/project", "checkout");
    try testing.expect(changeRequestForChat(&root, &.{&status2}) == null);
    try testing.expectEqual(@as(usize, 0), (try desiredWatchTargets(arena.allocator(), &.{root}, {}, never)).len);
}

test "change requests: shared chats deduplicate and the last archive removes the target" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var first = withSource(testChat("one", "local", "/repo", "checkout"), "feature/pr");
    var second = withSource(testChat("two", "local", "/repo", "checkout"), "feature/pr");
    try testing.expectEqual(@as(usize, 1), (try desiredWatchTargets(a, &.{ first, second }, {}, never)).len);
    second.archived = true;
    try testing.expectEqual(@as(usize, 1), (try desiredWatchTargets(a, &.{ first, second }, {}, never)).len);
    first.archived = true;
    try testing.expectEqual(@as(usize, 0), (try desiredWatchTargets(a, &.{ first, second }, {}, never)).len);
}

fn parseStatus(s: Status) !json.Parsed(Status) {
    const text = try json.Stringify.valueAlloc(testing.allocator, s, .{});
    defer testing.allocator.free(text);
    return json.parseFromSlice(Status, testing.allocator, text, .{ .allocate = .alloc_always });
}

test "change requests: unsupported devices, upgrades and authoritative none" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const chat = withSource(testChat("chat", "old-engine", "/repo", "checkout"), "feature/pr");
    var state = ClientState.init(testing.allocator);
    defer state.deinit();
    const key: WatchKey = .{ .device_id = "old-engine", .cwd = "/repo", .branch = "feature/pr", .checkout_id = "checkout" };
    state.store(key, try parseStatus(testSnapshot("old-engine", "/repo", "checkout")));
    try testing.expect(state.changeRequestForChat(&chat) != null);
    state.markUnsupported("old-engine", "0.2.2");
    try testing.expect(state.changeRequestForChat(&chat) == null);
    const Ctx = struct {
        fn check(c: *const ClientState, d: []const u8) bool {
            return !c.isSupported(d);
        }
    };
    try testing.expectEqual(@as(usize, 0), (try desiredWatchTargets(arena.allocator(), &.{chat}, &state, Ctx.check)).len);
    // A host upgrade re-enables it.
    try testing.expect(!state.clearUnsupportedOnVersionChange("old-engine", "0.2.2"));
    try testing.expect(state.clearUnsupportedOnVersionChange("old-engine", "0.2.3"));
    try testing.expect(state.isSupported("old-engine"));
    try testing.expectEqual(@as(usize, 1), (try desiredWatchTargets(arena.allocator(), &.{chat}, &state, Ctx.check)).len);
    // A successful `changeRequest: null` clears a previous PR.
    state.store(key, try parseStatus(testSnapshot("old-engine", "/repo", "checkout")));
    try testing.expect(state.changeRequestForChat(&chat) != null);
    var none = testSnapshot("old-engine", "/repo", "checkout");
    none.changeRequest = null;
    state.store(key, try parseStatus(none));
    try testing.expect(state.changeRequestForChat(&chat) == null);
    state.retainTargets(&.{});
    try testing.expectEqual(@as(usize, 0), state.snapshots.items.len);
}

test "change requests: watch params route to the checkout host" {
    const target: WatchKey = .{ .device_id = "host", .cwd = "/repo", .branch = "feature/pr", .checkout_id = "checkout" };
    const local = try json.Stringify.valueAlloc(testing.allocator, watchParams(target, "host"), .{});
    defer testing.allocator.free(local);
    try testing.expectEqualStrings("{\"cwd\":\"/repo\",\"branch\":\"feature/pr\"}", local);
    const remote = try json.Stringify.valueAlloc(testing.allocator, watchParams(target, "viewport"), .{});
    defer testing.allocator.free(remote);
    try testing.expectEqualStrings("{\"cwd\":\"/repo\",\"branch\":\"feature/pr\",\"targetDeviceId\":\"host\"}", remote);
}

test "change requests: badge models cover open, merged and closed" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { protocol.ChangeRequestState, []const u8, BadgeTone }{
        .{ .open, "Open", .open },
        .{ .merged, "Merged", .merged },
        .{ .closed, "Closed", .closed },
    };
    for (cases) |c| {
        var summary = testSnapshot("local", "/repo", "checkout").changeRequest.?;
        summary.state = c[0];
        summary.title = "First line\nSecond line";
        const m = try BadgeModel.fromSummary(arena.allocator(), &summary);
        try testing.expectEqualStrings("90", m.number);
        try testing.expectEqualStrings(c[1], m.state_label);
        try testing.expectEqual(c[2], m.tone);
        try testing.expectEqualStrings("First line Second line", m.title);
    }
}
