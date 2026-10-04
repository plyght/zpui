//! The engine connection as a zpui entity — the `EngineHandle` /
//! `AppState::bootstrap` half of zeron `crates/ui/src/state.rs`.
//!
//! ## Lifecycle
//! `EngineState.init` starts a background connect job (`Engine.connect`:
//! probe the IPC port, else spawn `zeron headless`, then the
//! `EngineInfo` → `EngineReady` barrier). Success publishes
//! `connection = .ready` and emits `.connected`; failure publishes
//! `.failed` and (when `reconnect` is on) retries with backoff. A dropped
//! socket emits `.disconnected`, flips back to `.connecting` and reconnects
//! (`500ms << min(attempt, 4)`, capped at 8s — the terminal panel's curve).
//! Rust has no whole-connection reconnect (only per-watch resubscribe); a
//! Zig viewport always talks to an out-of-process engine, so a restarted
//! daemon must be picked up again.
//!
//! ## Threading
//! The RPC client's reader thread fires `Waker.onWake` after delivering
//! frames. In `.dispatch` mode that posts one runnable to the platform's
//! main-thread queue (coalesced by an atomic flag); on the main thread
//! `pump` then (1) completes finished unary calls into their callbacks and
//! (2) emits `.wake`, on which every store drains its subscriptions with the
//! client's non-blocking `next`. In `.poll` mode (tests on `TestDispatcher`,
//! which isn't thread-safe) the flag is only set and the test loop calls
//! `pollWake`.
//!
//! ## Ownership
//! `Connection` is a main-thread refcounted wrapper over one `Engine`.
//! EngineState holds a reference while connected; every open `Watch` holds
//! one too, so the client is torn down only after the last subscription
//! handle is gone, regardless of entity destruction order.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const zpui = @import("zpui");
const engine_mod = @import("zeron_engine");
const view = @import("view.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const WeakEntity = zpui.WeakEntity;
const EntityId = zpui.EntityId;
const Task = zpui.Task;
const protocol = engine_mod.protocol;
const rpc = engine_mod.rpc;
const Method = engine_mod.Method;

const log = std.log.scoped(.zeron_engine_state);

pub const Payload = engine_mod.Payload;

/// How reader-thread wakeups reach the main thread.
pub const WakeMode = enum {
    /// Post to the platform dispatcher's main-thread queue (real apps).
    dispatch,
    /// Only set a flag; the owner calls `EngineState.pollWake` (tests).
    poll,
};

// ---------------------------------------------------------------------------
// Waker
// ---------------------------------------------------------------------------

/// Bridges the RPC reader thread to the main thread. Atomically refcounted:
/// the connection holds one reference, each queued runnable another.
pub const Waker = struct {
    gpa: Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    pending: std.atomic.Value(bool) = .init(false),
    mode: WakeMode,
    app: *App,
    dispatcher: zpui.platform.Dispatcher,
    target: EntityId,

    pub fn create(gpa: Allocator, app: *App, target: EntityId, mode: WakeMode) Allocator.Error!*Waker {
        const w = try gpa.create(Waker);
        w.* = .{ .gpa = gpa, .mode = mode, .app = app, .dispatcher = app.platform.dispatcher(), .target = target };
        return w;
    }

    pub fn retain(w: *Waker) void {
        _ = w.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(w: *Waker) void {
        if (w.refs.fetchSub(1, .acq_rel) == 1) w.gpa.destroy(w);
    }

    pub fn hook(w: *Waker) engine_mod.Wake {
        return .{ .ctx = w, .func = onWake };
    }

    /// Reader thread.
    fn onWake(ctx: ?*anyopaque) void {
        const w: *Waker = @ptrCast(@alignCast(ctx.?));
        if (w.pending.swap(true, .acq_rel)) return;
        if (w.mode == .poll) return;
        w.retain();
        w.dispatcher.dispatchOnMainThread(.{ .ctx = w, .run = runMain, .drop = dropRun }, .high);
    }

    fn runMain(ctx: *anyopaque) void {
        const w: *Waker = @ptrCast(@alignCast(ctx));
        defer w.release();
        w.pending.store(false, .release);
        pumpTarget(w.app, w.target);
    }

    fn dropRun(ctx: *anyopaque) void {
        const w: *Waker = @ptrCast(@alignCast(ctx));
        w.release();
    }

    /// Main thread: take the pending flag (poll mode).
    pub fn take(w: *Waker) bool {
        return w.pending.swap(false, .acq_rel);
    }
};

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

/// One connected engine, shared by EngineState and every open `Watch`.
/// Refcounted on the main thread only.
pub const Connection = struct {
    gpa: Allocator,
    refs: u32 = 1,
    engine: engine_mod.Engine,
    waker: *Waker,
    stop_spawned: bool,
    generation: u64 = 0,

    pub fn client(c: *Connection) *engine_mod.Client {
        return c.engine.client;
    }

    pub fn info(c: *const Connection) *const protocol.EngineInfo {
        return &c.engine.info.value;
    }

    pub fn isAlive(c: *Connection) bool {
        return c.engine.client.isAlive();
    }

    pub fn retain(c: *Connection) *Connection {
        c.refs += 1;
        return c;
    }

    /// Dropping the last reference disconnects (and stops a `zeron headless`
    /// we spawned when `stop_spawned`).
    pub fn release(c: *Connection) void {
        c.refs -= 1;
        if (c.refs > 0) return;
        c.engine.deinitWith(.{ .stop_spawned = c.stop_spawned });
        c.waker.release();
        c.gpa.destroy(c);
    }
};

// ---------------------------------------------------------------------------
// Watch: one stream handle bound to a connection
// ---------------------------------------------------------------------------

pub const Watch = struct {
    conn: ?*Connection = null,
    sub: ?*engine_mod.Subscription = null,
    /// The method failed with `UnknownMethod`; don't retry on this connection.
    unsupported: bool = false,

    pub fn isOpen(w: *const Watch) bool {
        return w.sub != null;
    }

    /// (Re)open on `conn`. On failure the watch stays closed.
    pub fn open(w: *Watch, conn: *Connection, method: Method, params: anytype) !void {
        w.close();
        const sub = try conn.client().subscribe(method, params);
        w.sub = sub;
        w.conn = conn.retain();
    }

    /// Cancel the stream (if still open server-side) and drop the connection ref.
    pub fn close(w: *Watch) void {
        if (w.sub) |s| s.deinit();
        w.sub = null;
        if (w.conn) |c| c.release();
        w.conn = null;
    }

    /// Next queued item (caller owns it), without blocking.
    pub fn next(w: *Watch) ?Payload {
        const s = w.sub orelse return null;
        return s.next();
    }

    pub const End = union(enum) {
        open,
        done,
        unknown_method,
        remote: void,
        closed,
    };

    /// How the stream ended (`.open` while live or closed locally).
    pub fn end(w: *Watch, diag: ?*engine_mod.Diagnostic) End {
        const s = w.sub orelse return .open;
        return switch (s.status(diag)) {
            .open => .open,
            .done => .done,
            .closed => .closed,
            .err => if (s.endError(null)) |_| End.remote else |e| switch (e) {
                error.UnknownMethod => .unknown_method,
                error.Closed => .closed,
                error.Remote => .remote,
            },
        };
    }
};

/// Decode the most recent decodable item queued on `w` (snapshot streams
/// resend whole state, so older frames in the batch are superseded). Frames
/// that fail to decode are dropped with a warning (Rust: "dropping malformed
/// watch frame").
pub fn latest(comptime T: type, w: *Watch, method: []const u8) ?json.Parsed(T) {
    var last: ?json.Parsed(T) = null;
    while (w.next()) |payload| {
        const parsed = rpc.decode(T, payload) catch |err| {
            log.warn("dropping malformed {s} frame: {t}", .{ method, err });
            continue;
        };
        if (last) |l| l.deinit();
        last = parsed;
    }
    return last;
}

/// Resubscribe delay after a stream ends or fails (Rust `RETRY_DELAY`).
pub const retry_delay_ns: u64 = 2 * std.time.ns_per_s;

/// Engine reconnect backoff for attempt `n` (0-based).
pub fn backoffMs(attempt: u32) u64 {
    return @min(@as(u64, 500) << @intCast(@min(attempt, 4)), 8_000);
}

// ---------------------------------------------------------------------------
// Unary calls
// ---------------------------------------------------------------------------

/// A completed unary call, borrowed by the callback.
pub const CallResult = union(enum) {
    ok: json.Value,
    err: struct {
        kind: rpc.RemoteError,
        message: []const u8,
    },

    pub fn decodeAs(r: CallResult, comptime T: type, arena: Allocator) !T {
        return switch (r) {
            .ok => |v| json.parseFromValueLeaky(T, arena, v, rpc.decode_options),
            .err => |e| e.kind,
        };
    }
};

const PendingCall = struct {
    call: *engine_mod.Call,
    target: EntityId,
    deliver: ?*const fn (app: *App, target: EntityId, result: CallResult) void,
    label: []const u8,
};

const Completed = struct {
    target: EntityId,
    deliver: *const fn (app: *App, target: EntityId, result: CallResult) void,
    payload: ?Payload,
    err: ?struct { kind: rpc.RemoteError, diag: engine_mod.Diagnostic },
};

// ---------------------------------------------------------------------------
// EngineState
// ---------------------------------------------------------------------------

pub const Config = struct {
    port: u16 = engine_mod.default_port,
    /// `zeron` binary to spawn as `zeron headless` when nothing answers;
    /// null disables spawning. Borrowed: must outlive the entity.
    zeron_path: ?[]const u8 = "zeron",
    /// Environment for a spawned engine (borrowed).
    spawn_environ: ?*const std.process.Environ.Map = null,
    inherit_child_output: bool = false,
    /// Ask a spawned engine to stop when the connection is dropped.
    stop_spawned: bool = true,
    /// Reconnect after failures and drops.
    reconnect: bool = true,
    wake_mode: WakeMode = .dispatch,
    spawn_timeout_ms: i64 = 30_000,
    ready_timeout_ms: i64 = 60_000,
};

pub const EngineEvent = union(enum) {
    /// Attached and ready; stores (re)open their watches. Payload: generation.
    connected: u64,
    /// The connection dropped (or is being replaced); stores close watches.
    disconnected,
    /// The reader delivered frames; stores drain their subscriptions.
    wake,
};

pub const EngineState = struct {
    gpa: Allocator,
    io: Io,
    config: Config,
    connection: view.ConnectionStatus = .connecting,
    /// Owned text behind `connection.failed`.
    failed_message: ?[]u8 = null,
    conn: ?*Connection = null,
    /// Bumps on every attach; `connected` events carry it.
    generation: u64 = 0,
    attempt: u32 = 0,
    connect_task: Task(ConnectResult) = .none,
    retry_task: Task(void) = .none,
    pending: std.ArrayList(PendingCall) = .empty,
    self_id: EntityId,

    pub const Events = .{EngineEvent};

    pub fn init(io: Io, config: Config, cx: *Context(EngineState)) !EngineState {
        var self: EngineState = .{ .gpa = cx.gpa(), .io = io, .config = config, .self_id = cx.entityId() };
        try self.startConnect(cx);
        return self;
    }

    pub fn deinit(self: *EngineState, _: *App) void {
        self.connect_task.cancel();
        self.retry_task.cancel();
        self.dropConnection();
        self.pending.deinit(self.gpa);
        if (self.failed_message) |m| self.gpa.free(m);
    }

    // ---- queries --------------------------------------------------------------------

    pub fn client(self: *const EngineState) ?*engine_mod.Client {
        const c = self.conn orelse return null;
        return c.client();
    }

    pub fn info(self: *const EngineState) ?*const protocol.EngineInfo {
        const c = self.conn orelse return null;
        return c.info();
    }

    pub fn isReady(self: *const EngineState) bool {
        return self.conn != null and self.connection == .ready;
    }

    pub fn workspaceScope(self: *const EngineState) ?protocol.WorkspaceScope {
        return if (self.info()) |i| i.workspaceScope else null;
    }

    pub fn deviceId(self: *const EngineState) ?[]const u8 {
        return if (self.info()) |i| i.deviceId else null;
    }

    pub fn supports(self: *const EngineState, capability: []const u8) bool {
        return if (self.info()) |i| i.supports(capability) else false;
    }

    // ---- connect / reconnect --------------------------------------------------------

    const ConnectResult = union(enum) {
        ok: *Connection,
        err: anyerror,
    };

    /// Plain fields only: `Io.Duration` (i96, 16-byte aligned) in a job
    /// trips the executor's `@fieldParentPtr` alignment (TaskImpl header).
    const ConnectJob = struct {
        gpa: Allocator,
        io: Io,
        port: u16,
        zeron_path: ?[]const u8,
        spawn_environ: ?*const std.process.Environ.Map,
        spawn_timeout_ms: i64,
        ready_timeout_ms: i64,
        inherit_child_output: bool,
        waker: *Waker,
        stop_spawned: bool,

        pub fn run(j: *ConnectJob) ConnectResult {
            const options: engine_mod.ConnectOptions = .{
                .port = j.port,
                .zeron_path = j.zeron_path,
                .spawn_environ = j.spawn_environ,
                .spawn_timeout = .fromMilliseconds(j.spawn_timeout_ms),
                .ready_timeout = .fromMilliseconds(j.ready_timeout_ms),
                .inherit_child_output = j.inherit_child_output,
                .wake = j.waker.hook(),
            };
            const engine = engine_mod.Engine.connect(j.gpa, j.io, options) catch |err| {
                return .{ .err = err };
            };
            const c = j.gpa.create(Connection) catch {
                var e = engine;
                e.deinitWith(.{ .stop_spawned = j.stop_spawned });
                return .{ .err = error.OutOfMemory };
            };
            j.waker.retain();
            c.* = .{ .gpa = j.gpa, .engine = engine, .waker = j.waker, .stop_spawned = j.stop_spawned };
            return .{ .ok = c };
        }

        pub fn discard(_: *ConnectJob, r: ConnectResult) void {
            switch (r) {
                .ok => |c| c.release(),
                .err => {},
            }
        }

        pub fn deinit(j: *ConnectJob) void {
            j.waker.release();
        }
    };

    fn startConnect(self: *EngineState, cx: *Context(EngineState)) !void {
        self.connect_task.cancel();
        const waker = try Waker.create(self.gpa, cx.app, self.self_id, self.config.wake_mode);
        errdefer waker.release();
        self.connect_task = try cx.spawn(ConnectJob{
            .gpa = self.gpa,
            .io = self.io,
            .waker = waker,
            .stop_spawned = self.config.stop_spawned,
            .port = self.config.port,
            .zeron_path = self.config.zeron_path,
            .spawn_environ = self.config.spawn_environ,
            .spawn_timeout_ms = self.config.spawn_timeout_ms,
            .ready_timeout_ms = self.config.ready_timeout_ms,
            .inherit_child_output = self.config.inherit_child_output,
        }, onConnected);
    }

    fn onConnected(self: *EngineState, result: ConnectResult, cx: *Context(EngineState)) void {
        self.connect_task.detach();
        switch (result) {
            .ok => |c| {
                self.dropConnection();
                self.generation += 1;
                c.generation = self.generation;
                self.conn = c;
                self.attempt = 0;
                self.setStatus(.ready);
                log.debug("engine attached (generation {d})", .{self.generation});
                cx.emit(EngineEvent{ .connected = self.generation });
                cx.notify();
                // Frames may already be queued from before the stores subscribed.
                self.emitWakeSoon(cx);
            },
            .err => |err| {
                const msg = std.fmt.allocPrint(self.gpa, "{t}", .{err}) catch null;
                log.warn("engine connect failed: {t}", .{err});
                self.setFailed(msg);
                cx.notify();
                self.scheduleReconnect(cx);
            },
        }
    }

    fn emitWakeSoon(self: *EngineState, cx: *Context(EngineState)) void {
        _ = self;
        cx.deferUpdate(emitWake);
    }

    fn emitWake(_: *EngineState, cx: *Context(EngineState)) void {
        cx.emit(EngineEvent{ .wake = {} });
    }

    fn scheduleReconnect(self: *EngineState, cx: *Context(EngineState)) void {
        if (!self.config.reconnect) return;
        self.retry_task.cancel();
        const delay = backoffMs(self.attempt) * std.time.ns_per_ms;
        self.attempt +|= 1;
        self.retry_task = cx.timer(delay, onRetry) catch return;
    }

    fn onRetry(self: *EngineState, cx: *Context(EngineState)) void {
        self.retry_task.detach();
        if (self.conn != null) return;
        if (self.connection != .connecting) {
            self.setStatus(.connecting);
            cx.notify();
        }
        self.startConnect(cx) catch |err| {
            log.warn("cannot start engine reconnect: {t}", .{err});
            self.scheduleReconnect(cx);
        };
    }

    /// Drop the current connection and connect again now (a "Retry" button).
    pub fn reconnect(self: *EngineState, cx: *Context(EngineState)) void {
        if (self.conn != null) {
            self.dropConnection();
            cx.emit(EngineEvent{ .disconnected = {} });
        }
        self.retry_task.cancel();
        self.attempt = 0;
        self.setStatus(.connecting);
        cx.notify();
        self.startConnect(cx) catch |err| log.warn("cannot start engine connect: {t}", .{err});
    }

    fn setStatus(self: *EngineState, status: view.ConnectionStatus) void {
        std.debug.assert(status != .failed);
        if (self.failed_message) |m| self.gpa.free(m);
        self.failed_message = null;
        self.connection = status;
    }

    fn setFailed(self: *EngineState, msg: ?[]u8) void {
        if (self.failed_message) |m| self.gpa.free(m);
        self.failed_message = msg;
        self.connection = .{ .failed = msg orelse "engine connection failed" };
    }

    fn dropConnection(self: *EngineState) void {
        for (self.pending.items) |p| p.call.deinit();
        self.pending.clearRetainingCapacity();
        if (self.conn) |c| c.release();
        self.conn = null;
    }

    fn handleDrop(self: *EngineState, cx: *Context(EngineState)) void {
        log.info("engine connection dropped; reconnecting", .{});
        self.dropConnection();
        self.setStatus(.connecting);
        cx.emit(EngineEvent{ .disconnected = {} });
        cx.notify();
        if (self.config.reconnect) {
            self.scheduleReconnect(cx);
        } else {
            self.setFailed(self.gpa.dupe(u8, "engine connection closed") catch null);
        }
    }

    // ---- pump -----------------------------------------------------------------------

    /// Main thread, poll mode: pump if the reader signalled. Returns whether it did.
    pub fn pollWake(entity: Entity(EngineState), app: *App) bool {
        const s = entity.read(app);
        const c = s.conn orelse return false;
        if (!c.waker.take()) return false;
        pumpTarget(app, entity.entityId());
        return true;
    }

    /// Main thread: pump unconditionally (completes calls, wakes stores,
    /// detects a dropped socket).
    pub fn pumpNow(entity: Entity(EngineState), app: *App) void {
        pumpTarget(app, entity.entityId());
    }

    /// Collect finished calls under a short lease, deliver them with the
    /// lease released (callbacks may read EngineState), then wake stores.
    fn collect(self: *EngineState, out: *std.ArrayList(Completed)) void {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const p = self.pending.items[i];
            if (p.call.poll() == .pending) {
                i += 1;
                continue;
            }
            _ = self.pending.swapRemove(i);
            var diag: engine_mod.Diagnostic = .{};
            const taken = p.call.take(&diag);
            if (p.deliver) |deliver| {
                const done: Completed = if (taken) |payload| .{
                    .target = p.target,
                    .deliver = deliver,
                    .payload = payload.?,
                    .err = null,
                } else |err| .{ .target = p.target, .deliver = deliver, .payload = null, .err = .{ .kind = err, .diag = diag } };
                out.append(self.gpa, done) catch {
                    if (done.payload) |pl| pl.deinit();
                };
            } else {
                if (taken) |payload| payload.?.deinit() else |err| {
                    log.debug("{s} failed: {t} {s}", .{ p.label, err, diag.message() });
                }
            }
            p.call.deinit();
        }
    }

    fn afterDeliver(self: *EngineState, cx: *Context(EngineState)) void {
        const c = self.conn orelse return;
        cx.emit(EngineEvent{ .wake = {} });
        if (!c.isAlive()) self.handleDrop(cx);
    }

    // ---- requests -------------------------------------------------------------------

    /// Start a unary call whose result is delivered to `f(target, result, cx)`
    /// on the main thread (borrowed for the call). Dropped silently if the
    /// target is gone; delivered as `error.Closed` if the connection drops.
    pub fn request(
        entity: Entity(EngineState),
        cx: anytype,
        comptime T: type,
        target: EntityId,
        method: Method,
        params: anytype,
        comptime f: fn (*T, CallResult, *Context(T)) void,
    ) !void {
        const Gen = struct {
            fn deliver(app: *App, id: EntityId, result: CallResult) void {
                const weak: WeakEntity(T) = .{ .id = id };
                _ = weak.update(app, f, .{result});
            }
        };
        var l = entity.lease(cx);
        defer l.end();
        try l.value.startCall(method, params, target, Gen.deliver);
    }

    /// Fire-and-forget unary call (errors are logged at debug level).
    pub fn send(entity: Entity(EngineState), cx: anytype, method: Method, params: anytype) !void {
        var l = entity.lease(cx);
        defer l.end();
        try l.value.startCall(method, params, l.value.self_id, null);
    }

    fn startCall(
        self: *EngineState,
        method: Method,
        params: anytype,
        target: EntityId,
        deliver: ?*const fn (*App, EntityId, CallResult) void,
    ) !void {
        const c = self.conn orelse return error.NotConnected;
        const call = try c.client().start(method, params);
        errdefer call.deinit();
        try self.pending.append(self.gpa, .{ .call = call, .target = target, .deliver = deliver, .label = method.name() });
    }
};

/// Main-thread pump for the EngineState entity `id` (see module docs).
fn pumpTarget(app: *App, id: EntityId) void {
    const weak: WeakEntity(EngineState) = .{ .id = id };
    const entity = weak.upgrade(app) orelse return;
    defer entity.release(app);
    var completed: std.ArrayList(Completed) = .empty;
    defer completed.deinit(app.gpa);
    {
        var l = entity.lease(app);
        defer l.end();
        l.value.collect(&completed);
    }
    for (completed.items) |done| {
        const result: CallResult = if (done.payload) |p|
            .{ .ok = p.value }
        else
            .{ .err = .{ .kind = done.err.?.kind, .message = done.err.?.diag.message() } };
        done.deliver(app, done.target, result);
        if (done.payload) |p| p.deinit();
    }
    _ = entity.update(app, EngineState.afterDeliver, .{});
}

test "backoff curve" {
    try std.testing.expectEqual(@as(u64, 500), backoffMs(0));
    try std.testing.expectEqual(@as(u64, 4000), backoffMs(3));
    try std.testing.expectEqual(@as(u64, 8000), backoffMs(4));
    try std.testing.expectEqual(@as(u64, 8000), backoffMs(40));
}

/// A param-less snapshot stream plus its latest decoded frame — the shape of
/// most standing watches (`WatchConnectivity`, `AuthStatus`, ...). The owner
/// supplies the retry timer.
pub fn Snapshot(comptime T: type, comptime method: Method) type {
    return struct {
        const Self = @This();
        watch: Watch = .{},
        frame: ?json.Parsed(T) = null,

        pub fn value(self: *const Self) ?*const T {
            return if (self.frame) |*f| &f.value else null;
        }

        pub fn deinit(self: *Self) void {
            self.watch.close();
            if (self.frame) |f| f.deinit();
            self.frame = null;
        }

        /// Open unless open/unsupported. Returns false if it failed (retry).
        pub fn open(self: *Self, conn: *Connection) bool {
            if (self.watch.isOpen() or self.watch.unsupported) return true;
            self.watch.open(conn, method, {}) catch |err| {
                log.debug("{s} unavailable: {t}", .{ method.name(), err });
                return false;
            };
            return true;
        }

        pub fn close(self: *Self) void {
            self.watch.close();
        }

        /// Apply the newest queued frame; true if the value changed. Returns
        /// `.retry` in `ended` when the stream must be reopened later.
        pub fn drain(self: *Self, ended: *bool) bool {
            ended.* = false;
            var changed = false;
            if (latest(T, &self.watch, method.name())) |next_frame| {
                changed = if (self.frame) |old| !@import("eql.zig").deepEql(old.value, next_frame.value) else true;
                if (self.frame) |old| old.deinit();
                self.frame = next_frame;
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
                    ended.* = true;
                },
            };
            return changed;
        }
    };
}
