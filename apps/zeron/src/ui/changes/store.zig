//! `ChangesStore`: the `WatchCheckoutDiffs` stream for one Changes pane —
//! zeron `Changes::ensure_watch` / `spawn_watch` / `apply_diff_frame`.
//!
//! - frames are either a whole `[]CheckoutDiff` (replace) or one
//!   `CheckoutDiff` (upsert by checkout id);
//! - the watch follows the selected chat's host device (`targetDeviceId`
//!   when it is not the connected engine), retargeting clears the old rows;
//! - a failed or ended stream keeps the last content under a banner and
//!   retries after 2s.
//!
//! ```zig
//! const store = try cx.newWith(ChangesStore, ChangesStore.init, .{engine});
//! store.update(cx, ChangesStore.setTarget, .{null});    // local device
//! store.read(cx).diffs()                                 // []const *const CheckoutDiff
//! ChangesStore.applyFixture(store, app, bytes)           // engine-free feed
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const zpui = @import("zpui");
const engine_mod = @import("zeron_engine");
const model = @import("zeron_model");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Task = zpui.Task;
const Subscription = zpui.Subscription;
const protocol = engine_mod.protocol;
const es = model.engine_state;
const EngineState = model.EngineState;

const log = std.log.scoped(.zeron_changes);

pub const DiffsChanged = struct {};

const WatchParams = struct { targetDeviceId: ?[]const u8 = null };

pub const ChangesStore = struct {
    gpa: Allocator,
    engine: Entity(EngineState),
    engine_sub: Subscription,
    /// Every frame we keep (whole-list frames replace, singles upsert).
    frames: std.ArrayList(json.Parsed(json.Value)) = .empty,
    /// Decoded view over `frames` (arena-backed by `decoded`).
    decoded: std.heap.ArenaAllocator,
    list: std.ArrayList(*const protocol.CheckoutDiff) = .empty,
    watch: es.Watch = .{},
    retry_task: Task(void) = .none,
    /// Banner text while the stream is down (owned).
    error_message: ?[]u8 = null,
    started: bool = false,
    target: ?[]u8 = null,
    /// Offline (fixtures): never opens a watch.
    offline: bool = false,

    pub const Events = .{DiffsChanged};

    pub fn init(engine: Entity(EngineState), cx: *Context(ChangesStore)) !ChangesStore {
        var self: ChangesStore = .{
            .gpa = cx.gpa(),
            .engine = engine.retain(cx),
            .engine_sub = undefined,
            .decoded = .init(cx.gpa()),
        };
        self.engine_sub = try cx.subscribe(engine, onEngineEvent);
        return self;
    }

    pub fn deinit(self: *ChangesStore, app: *App) void {
        self.engine_sub.deinit();
        self.retry_task.cancel();
        self.watch.close();
        for (self.frames.items) |f| f.deinit();
        self.frames.deinit(self.gpa);
        self.list.deinit(self.gpa);
        self.decoded.deinit();
        if (self.error_message) |m| self.gpa.free(m);
        if (self.target) |t| self.gpa.free(t);
        self.engine.release(app);
    }

    /// The current checkout diffs.
    pub fn diffs(self: *const ChangesStore) []const *const protocol.CheckoutDiff {
        return self.list.items;
    }

    /// Start (or retarget) the watch. Idempotent per target.
    pub fn setTarget(self: *ChangesStore, target: ?[]const u8, cx: *Context(ChangesStore)) void {
        if (self.offline) return;
        const same = if (self.target) |t| (if (target) |n| std.mem.eql(u8, t, n) else false) else target == null;
        if (self.started and same) return;
        if (self.started) {
            // Rows from the previous device would resolve against the wrong checkouts.
            self.clearFrames();
            self.setError(null);
            cx.emit(DiffsChanged{});
            cx.notify();
        }
        if (self.target) |t| self.gpa.free(t);
        self.target = if (target) |t| self.gpa.dupe(u8, t) catch null else null;
        self.started = true;
        self.watch.close();
        self.open(cx);
    }

    fn open(self: *ChangesStore, cx: *Context(ChangesStore)) void {
        if (self.offline or !self.started) return;
        const conn = self.engine.read(cx).conn orelse return;
        self.watch.open(conn, .WatchCheckoutDiffs, WatchParams{ .targetDeviceId = self.target }) catch |err| {
            self.setErrorFmt("Diff watch unavailable: {t}", .{err});
            cx.notify();
            self.scheduleRetry(cx);
        };
    }

    fn onEngineEvent(self: *ChangesStore, _: Entity(EngineState), ev: *const es.EngineEvent, cx: *Context(ChangesStore)) void {
        switch (ev.*) {
            .connected => self.open(cx),
            .disconnected => {
                self.retry_task.cancel();
                self.watch.close();
            },
            .wake => self.drain(cx),
        }
    }

    fn scheduleRetry(self: *ChangesStore, cx: *Context(ChangesStore)) void {
        if (self.retry_task.header != null) return;
        self.retry_task = cx.timer(es.retry_delay_ns, onRetry) catch return;
    }

    fn onRetry(self: *ChangesStore, cx: *Context(ChangesStore)) void {
        self.retry_task.detach();
        if (!self.watch.isOpen()) self.open(cx);
    }

    fn drain(self: *ChangesStore, cx: *Context(ChangesStore)) void {
        var changed = false;
        while (self.watch.next()) |payload| {
            const parsed = engine_mod.rpc.decode(json.Value, payload) catch |err| {
                log.warn("dropping malformed diff frame: {t}", .{err});
                continue;
            };
            if (self.applyValue(parsed)) changed = true;
        }
        if (changed) {
            self.setError(null);
            cx.emit(DiffsChanged{});
            cx.notify();
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
                self.setError("Diff stream interrupted — retrying");
                cx.notify();
                self.scheduleRetry(cx);
            },
        };
    }

    /// Fold one frame (takes ownership). Returns whether anything changed.
    pub fn applyValue(self: *ChangesStore, frame: json.Parsed(json.Value)) bool {
        switch (frame.value) {
            .array => {
                // Whole list: replaces everything.
                self.clearFrames();
                self.frames.append(self.gpa, frame) catch {
                    frame.deinit();
                    return false;
                };
            },
            .object => |o| {
                const id = if (o.get("checkoutId")) |v| (if (v == .string) v.string else "") else "";
                // Drop an older single frame for the same checkout.
                var i: usize = 0;
                while (i < self.frames.items.len) {
                    const f = self.frames.items[i];
                    if (f.value == .object) if (f.value.object.get("checkoutId")) |v| if (v == .string and std.mem.eql(u8, v.string, id)) {
                        f.deinit();
                        _ = self.frames.orderedRemove(i);
                        continue;
                    };
                    i += 1;
                }
                self.frames.append(self.gpa, frame) catch {
                    frame.deinit();
                    return false;
                };
            },
            else => {
                frame.deinit();
                return false;
            },
        }
        self.rebuild();
        return true;
    }

    /// Engine-free feed (fixtures): `bytes` is a `WatchCheckoutDiffs` frame.
    pub fn applyFixture(entity: Entity(ChangesStore), app: *App, bytes: []const u8) void {
        var l = entity.lease(app);
        defer l.end();
        const self = l.value;
        self.offline = true;
        self.started = true;
        const parsed = json.parseFromSlice(json.Value, self.gpa, bytes, .{ .allocate = .alloc_always }) catch |err| {
            log.warn("checkout-diffs fixture: {t}", .{err});
            return;
        };
        if (self.applyValue(parsed)) {
            l.cx.emit(DiffsChanged{});
            l.cx.notify();
        }
    }

    /// Mark as offline with no data (the "Preparing diff…" state).
    pub fn setOffline(self: *ChangesStore, cx: *Context(ChangesStore)) void {
        self.offline = true;
        self.started = true;
        self.watch.close();
        cx.notify();
    }

    fn clearFrames(self: *ChangesStore) void {
        for (self.frames.items) |f| f.deinit();
        self.frames.clearRetainingCapacity();
        self.list.clearRetainingCapacity();
        _ = self.decoded.reset(.retain_capacity);
    }

    fn rebuild(self: *ChangesStore) void {
        self.list.clearRetainingCapacity();
        _ = self.decoded.reset(.retain_capacity);
        const a = self.decoded.allocator();
        const opts: json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_if_needed };
        for (self.frames.items) |f| switch (f.value) {
            .array => |arr| for (arr.items) |v| {
                const d = a.create(protocol.CheckoutDiff) catch continue;
                d.* = json.parseFromValueLeaky(protocol.CheckoutDiff, a, v, opts) catch continue;
                self.upsert(d);
            },
            .object => {
                const d = a.create(protocol.CheckoutDiff) catch continue;
                d.* = json.parseFromValueLeaky(protocol.CheckoutDiff, a, f.value, opts) catch continue;
                self.upsert(d);
            },
            else => {},
        };
    }

    fn upsert(self: *ChangesStore, d: *const protocol.CheckoutDiff) void {
        for (self.list.items) |*e| if (std.mem.eql(u8, e.*.checkoutId, d.checkoutId)) {
            e.* = d;
            return;
        };
        self.list.append(self.gpa, d) catch {};
    }

    fn setError(self: *ChangesStore, msg: ?[]const u8) void {
        if (self.error_message) |m| self.gpa.free(m);
        self.error_message = if (msg) |m| self.gpa.dupe(u8, m) catch null else null;
    }

    fn setErrorFmt(self: *ChangesStore, comptime f: []const u8, args: anytype) void {
        if (self.error_message) |m| self.gpa.free(m);
        self.error_message = std.fmt.allocPrint(self.gpa, f, args) catch null;
    }
};
