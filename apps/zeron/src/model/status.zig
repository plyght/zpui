//! Smaller engine-backed stores, each a zpui entity with typed events:
//!
//! - `AuthStore`: the `AuthStatus` stream (tolerant `parseAuthState`), the
//!   sign-in / org-gate RPCs, and Rust's org helpers (`parseOrgs`,
//!   `orgNameValid`, `sortMemberships`).
//! - `SyncStore`: `WatchConnectivity` (+ "observed" flag), `WatchTransfers`
//!   (relay-leg upload progress), `ProbeSync`, `SyncStatus`.
//! - `UpdateStore`: the engine's app `UpdateStatus` stream + `ApplyUpdate`.
//! - `CatalogStore`: `ListHarnesses`, per-harness `ListModels` cache,
//!   `SetHarnessEnabled`, and `WatchHarnessUpdates` (capability-gated).
//!
//! All follow the same pattern as `WorkspaceStore`: open on `.connected`,
//! close on `.disconnected`, drain on `.wake`, resubscribe ended streams
//! after 2s.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const zpui = @import("zpui");
const engine_mod = @import("zeron_engine");
const view = @import("view.zig");
const types = @import("types.zig");
const eql = @import("eql.zig");
const es = @import("engine_state.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Task = zpui.Task;
const Subscription = zpui.Subscription;
const protocol = engine_mod.protocol;
const EngineState = es.EngineState;

const log = std.log.scoped(.zeron_status);

/// Shared open/close/retry plumbing for the stores below.
fn StoreBase(comptime Self: type) type {
    return struct {
        fn onEngineEvent(self: *Self, _: Entity(EngineState), ev: *const es.EngineEvent, cx: *Context(Self)) void {
            switch (ev.*) {
                .connected => {
                    self.resetUnsupported();
                    self.attach(cx);
                },
                .disconnected => {
                    self.retry_task.cancel();
                    self.closeAll();
                },
                .wake => self.drain(cx),
            }
        }

        fn scheduleRetry(self: *Self, cx: *Context(Self)) void {
            if (self.retry_task.header != null) return;
            self.retry_task = cx.timer(es.retry_delay_ns, onRetry) catch return;
        }

        fn onRetry(self: *Self, cx: *Context(Self)) void {
            self.retry_task.detach();
            self.openAll(cx);
        }
    };
}

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

pub const AuthChanged = struct {};
pub const OrgsLoaded = struct {};
pub const SignInUrl = struct { url: []const u8 };
pub const AuthError = struct { message: []const u8 };

/// Parse a ListOrgs reply tolerantly (accepts a bare array too).
pub fn parseOrgs(arena: Allocator, value: json.Value) []types.OrgRow {
    const list = if (value == .object) value.object.get("orgs") orelse value else value;
    return json.parseFromValueLeaky([]types.OrgRow, arena, list, .{ .ignore_unknown_fields = true }) catch &.{};
}

/// Workspace names must be non-empty (trimmed) and ≤ 64 characters.
pub fn orgNameValid(name: []const u8) bool {
    const trimmed = view.trimUnicode(name);
    if (trimmed.len == 0) return false;
    const chars = std.unicode.utf8CountCodepoints(trimmed) catch trimmed.len;
    return chars <= 64;
}

/// Memberships sorted by name (case-insensitive, then exact), deduped by
/// consecutive organization id (Rust `dedup_by`). Sorts in place; returns
/// the deduped prefix.
pub fn sortMemberships(orgs: []types.OrgRow) []types.OrgRow {
    std.sort.block(types.OrgRow, orgs, {}, struct {
        fn lt(_: void, a: types.OrgRow, b: types.OrgRow) bool {
            const o = lowerUnicodeOrder(a.name, b.name);
            if (o != .eq) return o == .lt;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    var kept: usize = 0;
    for (orgs) |o| {
        if (kept > 0 and std.mem.eql(u8, orgs[kept - 1].organizationId, o.organizationId)) continue;
        orgs[kept] = o;
        kept += 1;
    }
    return orgs[0..kept];
}

fn lowerUnicodeOrder(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return std.math.order(lx, ly);
    }
    return std.math.order(a.len, b.len);
}

pub const AuthStore = struct {
    gpa: Allocator,
    engine: Entity(EngineState),
    engine_sub: Subscription,
    watch: es.Watch = .{},
    retry_task: Task(void) = .none,
    /// Arena behind `auth` (replaced per frame).
    arena: ?*std.heap.ArenaAllocator = null,
    /// `null` until the engine reports a state.
    auth: ?protocol.AuthState = null,
    orgs_arena: ?*std.heap.ArenaAllocator = null,
    orgs: []types.OrgRow = &.{},
    last_error: ?[]u8 = null,

    pub const Events = .{ AuthChanged, OrgsLoaded, SignInUrl, AuthError };
    const Base = StoreBase(AuthStore);

    pub fn init(engine: Entity(EngineState), cx: *Context(AuthStore)) !AuthStore {
        var self: AuthStore = .{ .gpa = cx.gpa(), .engine = engine.retain(cx), .engine_sub = undefined };
        self.engine_sub = try cx.subscribe(engine, Base.onEngineEvent);
        if (engine.read(cx).isReady()) self.attach(cx);
        return self;
    }

    pub fn deinit(self: *AuthStore, app: *App) void {
        self.engine_sub.deinit();
        self.retry_task.cancel();
        self.watch.close();
        freeArena(self.gpa, &self.arena);
        freeArena(self.gpa, &self.orgs_arena);
        if (self.last_error) |e| self.gpa.free(e);
        self.engine.release(app);
    }

    /// The signed-in user, if the engine reports one.
    pub fn user(self: *const AuthStore) ?protocol.UserProfile {
        const a = self.auth orelse return null;
        return switch (a) {
            .signedIn => |s| s.user,
            .needsOrganization => |n| n.user,
            .signedOut => null,
        };
    }

    fn resetUnsupported(self: *AuthStore) void {
        self.watch.unsupported = false;
    }

    fn attach(self: *AuthStore, cx: *Context(AuthStore)) void {
        self.openAll(cx);
    }

    fn openAll(self: *AuthStore, cx: *Context(AuthStore)) void {
        const conn = self.engine.read(cx).conn orelse return;
        if (self.watch.isOpen() or self.watch.unsupported) return;
        self.watch.open(conn, .AuthStatus, {}) catch Base.scheduleRetry(self, cx);
    }

    fn closeAll(self: *AuthStore) void {
        self.watch.close();
    }

    fn drain(self: *AuthStore, cx: *Context(AuthStore)) void {
        while (self.watch.next()) |payload| {
            const arena = payload.arena;
            const state = view.parseAuthState(arena.allocator(), payload.value) orelse {
                log.warn("dropping unrecognized AuthStatus frame", .{});
                payload.deinit();
                continue;
            };
            const changed = if (self.auth) |old| !eql.deepEql(old, state) else true;
            freeArena(self.gpa, &self.arena);
            self.arena = arena;
            self.auth = state;
            if (changed) {
                cx.emit(AuthChanged{});
                cx.notify();
            }
        }
        if (self.watch.isOpen()) switch (self.watch.end(null)) {
            .open => {},
            .closed => self.watch.close(),
            .unknown_method => {
                self.watch.unsupported = true;
                self.watch.close();
            },
            .done, .remote => {
                self.watch.close();
                Base.scheduleRetry(self, cx);
            },
        };
    }

    // ---- RPCs -----------------------------------------------------------------------

    /// `SignIn` (or `SignInHeadless`): emits `SignInUrl` with the browser URL.
    pub fn signIn(self: *AuthStore, headless: bool, cx: *Context(AuthStore)) !void {
        try EngineState.request(self.engine, cx, AuthStore, cx.entityId(), if (headless) .SignInHeadless else .SignIn, {}, onSignIn);
    }

    fn onSignIn(self: *AuthStore, result: es.CallResult, cx: *Context(AuthStore)) void {
        switch (result) {
            .ok => |v| if (v == .object) if (v.object.get("url")) |u| if (u == .string) cx.emit(SignInUrl{ .url = u.string }),
            .err => |e| self.reportError(e.message, cx),
        }
    }

    pub fn completeSignIn(self: *AuthStore, code: []const u8, cx: *Context(AuthStore)) !void {
        try EngineState.request(self.engine, cx, AuthStore, cx.entityId(), .CompleteSignIn, .{ .code = code }, onAck);
    }

    pub fn signOut(self: *AuthStore, cx: *Context(AuthStore)) !void {
        try EngineState.request(self.engine, cx, AuthStore, cx.entityId(), .SignOut, {}, onAck);
    }

    pub fn listOrgs(self: *AuthStore, cx: *Context(AuthStore)) !void {
        try EngineState.request(self.engine, cx, AuthStore, cx.entityId(), .ListOrgs, {}, onOrgs);
    }

    pub fn createOrg(self: *AuthStore, name: []const u8, cx: *Context(AuthStore)) !void {
        try EngineState.request(self.engine, cx, AuthStore, cx.entityId(), .CreateOrg, .{ .name = name }, onAck);
    }

    pub fn selectOrg(self: *AuthStore, organization_id: []const u8, cx: *Context(AuthStore)) !void {
        try EngineState.request(self.engine, cx, AuthStore, cx.entityId(), .SelectOrg, .{ .organizationId = organization_id }, onAck);
    }

    fn onAck(self: *AuthStore, result: es.CallResult, cx: *Context(AuthStore)) void {
        switch (result) {
            .ok => {},
            .err => |e| self.reportError(e.message, cx),
        }
    }

    fn onOrgs(self: *AuthStore, result: es.CallResult, cx: *Context(AuthStore)) void {
        switch (result) {
            .ok => |v| {
                const arena = self.gpa.create(std.heap.ArenaAllocator) catch return;
                arena.* = .init(self.gpa);
                // The payload is freed after this callback: copy what we keep.
                const owned = deepCopyValue(arena.allocator(), v) catch {
                    arena.deinit();
                    self.gpa.destroy(arena);
                    return;
                };
                freeArena(self.gpa, &self.orgs_arena);
                self.orgs_arena = arena;
                self.orgs = sortMemberships(parseOrgs(arena.allocator(), owned));
                cx.emit(OrgsLoaded{});
                cx.notify();
            },
            .err => |e| self.reportError(e.message, cx),
        }
    }

    fn reportError(self: *AuthStore, message: []const u8, cx: *Context(AuthStore)) void {
        if (self.last_error) |e| self.gpa.free(e);
        self.last_error = self.gpa.dupe(u8, message) catch null;
        cx.emit(AuthError{ .message = self.last_error orelse "" });
        cx.notify();
    }
};

// ---------------------------------------------------------------------------
// Sync / connectivity
// ---------------------------------------------------------------------------

pub const ConnectivityChanged = struct {};
pub const TransfersChanged = struct {};

pub const SyncStore = struct {
    gpa: Allocator,
    engine: Entity(EngineState),
    engine_sub: Subscription,
    connectivity: es.Snapshot(protocol.Connectivity, .WatchConnectivity) = .{},
    transfers: es.Snapshot([]types.TransferProgress, .WatchTransfers) = .{},
    /// The connectivity watch delivered its first frame on this runtime (the
    /// default `.disabled` is only a placeholder before that).
    connectivity_observed: bool = false,
    retry_task: Task(void) = .none,

    pub const Events = .{ ConnectivityChanged, TransfersChanged };
    const Base = StoreBase(SyncStore);

    pub fn init(engine: Entity(EngineState), cx: *Context(SyncStore)) !SyncStore {
        var self: SyncStore = .{ .gpa = cx.gpa(), .engine = engine.retain(cx), .engine_sub = undefined };
        self.engine_sub = try cx.subscribe(engine, Base.onEngineEvent);
        if (engine.read(cx).isReady()) self.attach(cx);
        return self;
    }

    pub fn deinit(self: *SyncStore, app: *App) void {
        self.engine_sub.deinit();
        self.retry_task.cancel();
        self.connectivity.deinit();
        self.transfers.deinit();
        self.engine.release(app);
    }

    /// Current posture (`.disabled` placeholder until observed).
    pub fn current(self: *const SyncStore) protocol.Connectivity {
        return if (self.connectivity.value()) |c| c.* else .{};
    }

    /// `(done, total)` of an in-flight relay transfer.
    pub fn transfer(self: *const SyncStore, upload_id: []const u8) ?types.TransferProgress {
        const list = self.transfers.value() orelse return null;
        for (list.*) |t| if (std.mem.eql(u8, t.uploadId, upload_id)) return t;
        return null;
    }

    /// Percent (0–100) of an in-flight transfer.
    pub fn transferPercent(self: *const SyncStore, upload_id: []const u8) ?u8 {
        const t = self.transfer(upload_id) orelse return null;
        if (t.total == 0) return null;
        return @intCast(@min(100, t.done * 100 / t.total));
    }

    fn resetUnsupported(self: *SyncStore) void {
        self.connectivity.watch.unsupported = false;
        self.transfers.watch.unsupported = false;
        self.connectivity_observed = false;
    }

    fn attach(self: *SyncStore, cx: *Context(SyncStore)) void {
        self.openAll(cx);
    }

    fn openAll(self: *SyncStore, cx: *Context(SyncStore)) void {
        const conn = self.engine.read(cx).conn orelse return;
        const ok = self.connectivity.open(conn) and self.transfers.open(conn);
        if (!ok) Base.scheduleRetry(self, cx);
    }

    fn closeAll(self: *SyncStore) void {
        self.connectivity.close();
        self.transfers.close();
    }

    fn drain(self: *SyncStore, cx: *Context(SyncStore)) void {
        var ended = false;
        const had = self.connectivity.frame != null;
        if (self.connectivity.drain(&ended) or (!had and self.connectivity.frame != null)) {
            self.connectivity_observed = true;
            cx.emit(ConnectivityChanged{});
            cx.notify();
        }
        if (ended) Base.scheduleRetry(self, cx);
        if (self.transfers.drain(&ended)) {
            cx.emit(TransfersChanged{});
            cx.notify();
        }
        if (ended) Base.scheduleRetry(self, cx);
    }

    /// Window-focus liveness sweep; `retry` also allows one fresh auth attempt.
    pub fn probeSync(self: *SyncStore, retry: bool, cx: *Context(SyncStore)) void {
        EngineState.send(self.engine, cx, .ProbeSync, .{ .retry = retry }) catch {};
    }
};

// ---------------------------------------------------------------------------
// App update status
// ---------------------------------------------------------------------------

pub const UpdateStatusChanged = struct {};

pub const UpdateStore = struct {
    gpa: Allocator,
    engine: Entity(EngineState),
    engine_sub: Subscription,
    status: es.Snapshot(types.UpdateStatus, .UpdateStatus) = .{},
    retry_task: Task(void) = .none,

    pub const Events = .{UpdateStatusChanged};
    const Base = StoreBase(UpdateStore);

    pub fn init(engine: Entity(EngineState), cx: *Context(UpdateStore)) !UpdateStore {
        var self: UpdateStore = .{ .gpa = cx.gpa(), .engine = engine.retain(cx), .engine_sub = undefined };
        self.engine_sub = try cx.subscribe(engine, Base.onEngineEvent);
        if (engine.read(cx).isReady()) self.attach(cx);
        return self;
    }

    pub fn deinit(self: *UpdateStore, app: *App) void {
        self.engine_sub.deinit();
        self.retry_task.cancel();
        self.status.deinit();
        self.engine.release(app);
    }

    pub fn current(self: *const UpdateStore) ?*const types.UpdateStatus {
        return self.status.value();
    }

    fn resetUnsupported(self: *UpdateStore) void {
        self.status.watch.unsupported = false;
    }

    fn attach(self: *UpdateStore, cx: *Context(UpdateStore)) void {
        self.openAll(cx);
    }

    fn openAll(self: *UpdateStore, cx: *Context(UpdateStore)) void {
        const conn = self.engine.read(cx).conn orelse return;
        if (!self.status.open(conn)) Base.scheduleRetry(self, cx);
    }

    fn closeAll(self: *UpdateStore) void {
        self.status.close();
    }

    fn drain(self: *UpdateStore, cx: *Context(UpdateStore)) void {
        var ended = false;
        if (self.status.drain(&ended)) {
            cx.emit(UpdateStatusChanged{});
            cx.notify();
        }
        if (ended) Base.scheduleRetry(self, cx);
    }

    /// `ApplyUpdate` (headless engines apply their own update).
    pub fn applyUpdate(self: *UpdateStore, cx: *Context(UpdateStore)) void {
        EngineState.send(self.engine, cx, .ApplyUpdate, {}) catch {};
    }
};

// ---------------------------------------------------------------------------
// Harness / model catalog
// ---------------------------------------------------------------------------

pub const HarnessesChanged = struct {};
pub const ModelsChanged = struct { harness: protocol.HarnessId };
pub const HarnessUpdatesChanged = struct {};

pub const CatalogStore = struct {
    gpa: Allocator,
    engine: Entity(EngineState),
    engine_sub: Subscription,
    harnesses: ?OwnedJson([]protocol.HarnessDescriptor) = null,
    /// `ListModels` replies per harness (filled on demand).
    models: std.EnumArray(protocol.HarnessId, ?OwnedJson([]protocol.Model)) = .initFill(null),
    models_loading: std.EnumSet(protocol.HarnessId) = .empty,
    updates: es.Snapshot([]types.HarnessUpdateStatus, .WatchHarnessUpdates) = .{},
    retry_task: Task(void) = .none,

    pub const Events = .{ HarnessesChanged, ModelsChanged, HarnessUpdatesChanged };
    const Base = StoreBase(CatalogStore);

    pub fn init(engine: Entity(EngineState), cx: *Context(CatalogStore)) !CatalogStore {
        var self: CatalogStore = .{ .gpa = cx.gpa(), .engine = engine.retain(cx), .engine_sub = undefined };
        self.engine_sub = try cx.subscribe(engine, Base.onEngineEvent);
        if (engine.read(cx).isReady()) self.attach(cx);
        return self;
    }

    pub fn deinit(self: *CatalogStore, app: *App) void {
        self.engine_sub.deinit();
        self.retry_task.cancel();
        self.updates.deinit();
        if (self.harnesses) |h| h.deinit();
        for (&self.models.values) |*m| if (m.*) |v| v.deinit();
        self.engine.release(app);
    }

    pub fn harnessList(self: *const CatalogStore) []const protocol.HarnessDescriptor {
        return if (self.harnesses) |h| h.value else &.{};
    }

    /// Models for `harness`, or null until loaded (call `loadModels`).
    pub fn modelList(self: *const CatalogStore, harness: protocol.HarnessId) ?[]const protocol.Model {
        return if (self.models.get(harness)) |m| m.value else null;
    }

    pub fn harnessUpdates(self: *const CatalogStore) []const types.HarnessUpdateStatus {
        return if (self.updates.value()) |v| v.* else &.{};
    }

    fn resetUnsupported(self: *CatalogStore) void {
        self.updates.watch.unsupported = false;
    }

    fn attach(self: *CatalogStore, cx: *Context(CatalogStore)) void {
        self.openAll(cx);
        self.refreshHarnesses(cx);
        // Engines without the capability get an empty update list.
        if (!self.engine.read(cx).supports(protocol.capabilities.harness_updates_v1)) {
            if (self.updates.frame) |f| f.deinit();
            self.updates.frame = null;
        }
    }

    fn openAll(self: *CatalogStore, cx: *Context(CatalogStore)) void {
        const engine = self.engine.read(cx);
        const conn = engine.conn orelse return;
        if (!engine.supports(protocol.capabilities.harness_updates_v1)) return;
        if (!self.updates.open(conn)) Base.scheduleRetry(self, cx);
    }

    fn closeAll(self: *CatalogStore) void {
        self.updates.close();
        self.models_loading = .empty;
    }

    fn drain(self: *CatalogStore, cx: *Context(CatalogStore)) void {
        var ended = false;
        if (self.updates.drain(&ended)) {
            cx.emit(HarnessUpdatesChanged{});
            cx.notify();
        }
        if (ended) Base.scheduleRetry(self, cx);
    }

    pub fn refreshHarnesses(self: *CatalogStore, cx: *Context(CatalogStore)) void {
        EngineState.request(self.engine, cx, CatalogStore, cx.entityId(), .ListHarnesses, {}, onHarnesses) catch {};
    }

    fn onHarnesses(self: *CatalogStore, result: es.CallResult, cx: *Context(CatalogStore)) void {
        const v = switch (result) {
            .ok => |v| v,
            .err => |e| return log.debug("ListHarnesses failed: {t} {s}", .{ e.kind, e.message }),
        };
        const owned = OwnedJson([]protocol.HarnessDescriptor).fromValue(self.gpa, v) catch |err| {
            return log.warn("malformed ListHarnesses reply: {t}", .{err});
        };
        if (self.harnesses) |h| h.deinit();
        self.harnesses = owned;
        cx.emit(HarnessesChanged{});
        cx.notify();
    }

    /// `ListModels{harness, force}`; emits `ModelsChanged` when it lands.
    pub fn loadModels(self: *CatalogStore, harness: protocol.HarnessId, force: bool, cx: *Context(CatalogStore)) void {
        if (self.models_loading.contains(harness)) return;
        if (!force and self.models.get(harness) != null) return;
        self.models_loading.insert(harness);
        const Gen = struct {
            fn make(comptime h: protocol.HarnessId) fn (*CatalogStore, es.CallResult, *Context(CatalogStore)) void {
                return struct {
                    fn f(s: *CatalogStore, r: es.CallResult, c: *Context(CatalogStore)) void {
                        s.onModels(h, r, c);
                    }
                }.f;
            }
        };
        switch (harness) {
            inline else => |h| EngineState.request(self.engine, cx, CatalogStore, cx.entityId(), .ListModels, protocol.params.ListModels{
                .harness = h,
                .force = force,
            }, Gen.make(h)) catch {
                self.models_loading.remove(harness);
            },
        }
    }

    fn onModels(self: *CatalogStore, harness: protocol.HarnessId, result: es.CallResult, cx: *Context(CatalogStore)) void {
        self.models_loading.remove(harness);
        const v = switch (result) {
            .ok => |v| v,
            .err => |e| return log.debug("ListModels({t}) failed: {t} {s}", .{ harness, e.kind, e.message }),
        };
        const owned = OwnedJson([]protocol.Model).fromValue(self.gpa, v) catch |err| {
            return log.warn("malformed ListModels reply: {t}", .{err});
        };
        if (self.models.get(harness)) |old| old.deinit();
        self.models.set(harness, owned);
        cx.emit(ModelsChanged{ .harness = harness });
        cx.notify();
    }

    pub fn setHarnessEnabled(self: *CatalogStore, harness: protocol.HarnessId, enabled: bool, cx: *Context(CatalogStore)) void {
        EngineState.request(self.engine, cx, CatalogStore, cx.entityId(), .SetHarnessEnabled, protocol.params.SetHarnessEnabled{
            .harness = harness,
            .enabled = enabled,
        }, onEnabled) catch {};
    }

    fn onEnabled(self: *CatalogStore, result: es.CallResult, cx: *Context(CatalogStore)) void {
        _ = result;
        self.refreshHarnesses(cx);
    }
};

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

/// A value decoded from a borrowed `json.Value` into its own arena.
pub fn OwnedJson(comptime T: type) type {
    return struct {
        const Self = @This();
        arena: *std.heap.ArenaAllocator,
        value: T,

        pub fn fromValue(gpa: Allocator, v: json.Value) !Self {
            const arena = try gpa.create(std.heap.ArenaAllocator);
            arena.* = .init(gpa);
            errdefer {
                arena.deinit();
                gpa.destroy(arena);
            }
            const a = arena.allocator();
            const copy = try deepCopyValue(a, v);
            return .{ .arena = arena, .value = try json.parseFromValueLeaky(T, a, copy, .{ .ignore_unknown_fields = true }) };
        }

        pub fn deinit(self: Self) void {
            const gpa = self.arena.child_allocator;
            self.arena.deinit();
            gpa.destroy(self.arena);
        }
    };
}

/// Deep-copy a `json.Value` (strings included) into `a`.
pub fn deepCopyValue(a: Allocator, v: json.Value) Allocator.Error!json.Value {
    return switch (v) {
        .null, .bool, .integer, .float => v,
        .number_string => |s| .{ .number_string = try a.dupe(u8, s) },
        .string => |s| .{ .string = try a.dupe(u8, s) },
        .array => |arr| blk: {
            var out = try json.Array.initCapacity(a, arr.items.len);
            for (arr.items) |item| out.appendAssumeCapacity(try deepCopyValue(a, item));
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out: json.ObjectMap = .empty;
            try out.ensureTotalCapacity(a, obj.count());
            var it = obj.iterator();
            while (it.next()) |e| out.putAssumeCapacity(try a.dupe(u8, e.key_ptr.*), try deepCopyValue(a, e.value_ptr.*));
            break :blk .{ .object = out };
        },
    };
}

fn freeArena(gpa: Allocator, slot: *?*std.heap.ArenaAllocator) void {
    if (slot.*) |a| {
        a.deinit();
        gpa.destroy(a);
    }
    slot.* = null;
}

test "org helpers" {
    const t = std.testing;
    try t.expect(orgNameValid(" Acme "));
    try t.expect(!orgNameValid("   "));
    const long: [65]u8 = @splat('x');
    try t.expect(!orgNameValid(&long));
    var rows = [_]types.OrgRow{
        .{ .organizationId = "2", .name = "beta" },
        .{ .organizationId = "1", .name = "Alpha" },
        .{ .organizationId = "1", .name = "alpha" },
    };
    const sorted = sortMemberships(&rows);
    try t.expectEqual(@as(usize, 2), sorted.len);
    try t.expectEqualStrings("Alpha", sorted[0].name);
    try t.expectEqualStrings("beta", sorted[1].name);
}
