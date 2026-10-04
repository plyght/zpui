//! Port of gpui `subscription.rs`: a keyed set of callbacks that tolerates subscribing and
//! unsubscribing from inside its own callbacks.
//!
//! Semantics kept from gpui:
//! * New subscribers start *inactive*; the owner activates them (usually via a deferred
//!   effect) so a listener added during an emit does not see that same emit.
//! * `retain` calls every active subscriber of a key in insertion order. Subscribers added
//!   during the walk are not visited; subscribers dropped during the walk are skipped.
//!   A callback returning `false` removes itself. Re-entrant `retain` on the same key is a
//!   no-op (gpui "takes" the inner map).
//! * `Subscription.deinit()` unsubscribes; `detach()` forgets the handle.
//!
//! Main-thread only. Keys are `u64` (EntityId / TypeId bits).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Handle returned by every `observe`/`subscribe` style API. Zig has no destructors:
/// call `deinit()` to unsubscribe or `detach()` to keep the callback alive for as long
/// as the emitter lives. A Subscription must not outlive the `App` that created it.
pub const Subscription = struct {
    set: ?*anyopaque = null,
    unsubscribe_fn: ?*const fn (set: *anyopaque, key: u64, id: u64) void = null,
    key: u64 = 0,
    id: u64 = 0,

    /// A subscription that does nothing (useful as a field default).
    pub const empty: Subscription = .{};

    /// Unsubscribe. Idempotent; safe to call from inside the subscriber's own callback.
    pub fn deinit(self: *Subscription) void {
        const set = self.set orelse return;
        self.set = null;
        self.unsubscribe_fn.?(set, self.key, self.id);
    }

    /// Forget this handle; the callback stays registered until it returns false or its
    /// emitter is released.
    pub fn detach(self: *Subscription) void {
        self.set = null;
    }

    pub fn isActive(self: Subscription) bool {
        return self.set != null;
    }
};

/// A growable list of subscriptions owned by a view (gpui `_subscriptions: Vec<Subscription>`).
pub const Subscriptions = struct {
    list: std.ArrayList(Subscription) = .empty,

    pub fn add(self: *Subscriptions, gpa: Allocator, sub: Subscription) Allocator.Error!void {
        self.list.append(gpa, sub) catch |err| {
            var s = sub;
            s.deinit();
            return err;
        };
    }

    /// Unsubscribe everything and free the list.
    pub fn deinit(self: *Subscriptions, gpa: Allocator) void {
        for (self.list.items) |*s| s.deinit();
        self.list.deinit(gpa);
        self.* = .{};
    }
};

/// `Callback` may declare `pub fn deinit(self: *Callback, gpa: Allocator) void`; it is
/// called exactly once when the subscriber is removed (or the set is destroyed).
pub fn SubscriberSet(comptime Callback: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        map: std.AutoHashMapUnmanaged(u64, Entry) = .empty,
        next_id: u64 = 1,

        const Subscriber = struct {
            id: u64,
            active: bool,
            dropped: bool,
            callback: Callback,
        };

        const Entry = struct {
            list: std.ArrayList(Subscriber) = .empty,
            /// A `retain` walk over this key is in progress: removals only mark `dropped`.
            iterating: bool = false,
        };

        pub const Inserted = struct { subscription: Subscription, id: u64 };

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.valueIterator();
            while (it.next()) |entry| {
                for (entry.list.items) |*s| freeCallback(self.gpa, &s.callback);
                entry.list.deinit(self.gpa);
            }
            self.map.deinit(self.gpa);
        }

        fn freeCallback(gpa: Allocator, cb: *Callback) void {
            if (comptime @hasDecl(Callback, "deinit")) cb.deinit(gpa);
        }

        /// Insert an inactive subscriber. On OOM the callback is freed.
        pub fn insert(self: *Self, key: u64, callback: Callback) Allocator.Error!Inserted {
            var cb = callback;
            const gop = self.map.getOrPut(self.gpa, key) catch |err| {
                freeCallback(self.gpa, &cb);
                return err;
            };
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const id = self.next_id;
            gop.value_ptr.list.append(self.gpa, .{ .id = id, .active = false, .dropped = false, .callback = cb }) catch |err| {
                if (gop.value_ptr.list.items.len == 0 and !gop.value_ptr.iterating) {
                    gop.value_ptr.list.deinit(self.gpa);
                    self.map.removeByPtr(gop.key_ptr);
                }
                freeCallback(self.gpa, &cb);
                return err;
            };
            self.next_id += 1;
            return .{
                .id = id,
                .subscription = .{ .set = self, .unsubscribe_fn = unsubscribeErased, .key = key, .id = id },
            };
        }

        pub fn activate(self: *Self, key: u64, id: u64) void {
            const entry = self.map.getPtr(key) orelse return;
            for (entry.list.items) |*s| {
                if (s.id == id) {
                    s.active = true;
                    return;
                }
            }
        }

        fn unsubscribeErased(set: *anyopaque, key: u64, id: u64) void {
            const self: *Self = @ptrCast(@alignCast(set));
            self.unsubscribe(key, id);
        }

        pub fn unsubscribe(self: *Self, key: u64, id: u64) void {
            const entry = self.map.getPtr(key) orelse return;
            for (entry.list.items, 0..) |*s, i| {
                if (s.id != id) continue;
                if (entry.iterating) {
                    s.dropped = true;
                } else {
                    var removed = entry.list.orderedRemove(i);
                    freeCallback(self.gpa, &removed.callback);
                    if (entry.list.items.len == 0) self.removeEntry(key);
                }
                return;
            }
        }

        fn removeEntry(self: *Self, key: u64) void {
            if (self.map.fetchRemove(key)) |kv| {
                var list = kv.value.list;
                list.deinit(self.gpa);
            }
        }

        pub fn isEmpty(self: *const Self, key: u64) bool {
            const entry = self.map.getPtr(key) orelse return true;
            for (entry.list.items) |s| if (!s.dropped) return false;
            return true;
        }

        /// Remove every subscriber of `key`. Active, non-dropped callbacks are appended to
        /// `out` (ownership moves to the caller, who must `deinit` them); the rest are freed.
        /// If a `retain` over `key` is running, subscribers are only marked dropped.
        pub fn remove(self: *Self, key: u64, out: ?*std.ArrayList(Callback)) void {
            const entry = self.map.getPtr(key) orelse return;
            if (entry.iterating) {
                for (entry.list.items) |*s| s.dropped = true;
                return;
            }
            var kv = self.map.fetchRemove(key).?;
            for (kv.value.list.items) |*s| {
                if (out) |o| {
                    if (s.active and !s.dropped) {
                        o.append(self.gpa, s.callback) catch {
                            freeCallback(self.gpa, &s.callback);
                        };
                        continue;
                    }
                }
                freeCallback(self.gpa, &s.callback);
            }
            kv.value.list.deinit(self.gpa);
        }

        /// Call `f(ctx, &callback)` for each active subscriber of `key`; `false` removes it.
        /// `f` receives a copy of the stored callback (callbacks must keep mutable state
        /// behind a pointer).
        pub fn retain(self: *Self, key: u64, ctx: anytype, comptime f: fn (@TypeOf(ctx), *Callback) bool) void {
            const first = self.map.getPtr(key) orelse return;
            if (first.iterating) return;
            first.iterating = true;
            const end_id = self.next_id;

            var i: usize = 0;
            while (true) {
                // Re-lookup every step: callbacks may grow the map and move entries.
                const entry = self.map.getPtr(key).?;
                if (i >= entry.list.items.len) break;
                const s = &entry.list.items[i];
                i += 1;
                if (s.id >= end_id) break;
                if (!s.active or s.dropped) continue;
                var cb = s.callback;
                const id = s.id;
                const keep = f(ctx, &cb);
                if (!keep) {
                    const e = self.map.getPtr(key).?;
                    for (e.list.items) |*t| {
                        if (t.id == id) {
                            t.dropped = true;
                            break;
                        }
                    }
                }
            }

            // Compact: free dropped subscribers, keep the rest (incl. ones added meanwhile).
            const entry = self.map.getPtr(key).?;
            entry.iterating = false;
            var w: usize = 0;
            for (entry.list.items) |*s| {
                if (s.dropped) {
                    freeCallback(self.gpa, &s.callback);
                } else {
                    entry.list.items[w] = s.*;
                    w += 1;
                }
            }
            entry.list.shrinkRetainingCapacity(w);
            if (w == 0) self.removeEntry(key);
        }
    };
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;

const TestCb = struct {
    log: *std.ArrayList(u32),
    tag: u32,
    keep: bool = true,
    /// Subscription to drop when this callback runs.
    drop: ?*Subscription = null,
    /// Insert a new subscriber when this runs.
    insert_into: ?*SubscriberSet(TestCb) = null,
};

fn callTest(_: void, cb: *TestCb) bool {
    cb.log.append(testing.allocator, cb.tag) catch unreachable;
    if (cb.drop) |d| d.deinit();
    if (cb.insert_into) |set| {
        const ins = set.insert(1, .{ .log = cb.log, .tag = 99 }) catch unreachable;
        set.activate(1, ins.id);
    }
    return cb.keep;
}

test "SubscriberSet: inactive subscribers are skipped until activated" {
    var log: std.ArrayList(u32) = .empty;
    defer log.deinit(testing.allocator);
    var set = SubscriberSet(TestCb).init(testing.allocator);
    defer set.deinit();

    const a = try set.insert(1, .{ .log = &log, .tag = 1 });
    set.retain(1, {}, callTest);
    try testing.expectEqual(@as(usize, 0), log.items.len);
    set.activate(1, a.id);
    set.retain(1, {}, callTest);
    try testing.expectEqualSlices(u32, &.{1}, log.items);
}

test "SubscriberSet: returning false removes, deinit unsubscribes" {
    var log: std.ArrayList(u32) = .empty;
    defer log.deinit(testing.allocator);
    var set = SubscriberSet(TestCb).init(testing.allocator);
    defer set.deinit();

    const a = try set.insert(1, .{ .log = &log, .tag = 1, .keep = false });
    var b = try set.insert(1, .{ .log = &log, .tag = 2 });
    set.activate(1, a.id);
    set.activate(1, b.id);
    set.retain(1, {}, callTest);
    set.retain(1, {}, callTest);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 2 }, log.items);
    b.subscription.deinit();
    b.subscription.deinit(); // idempotent
    try testing.expect(set.isEmpty(1));
    try testing.expectEqual(@as(u32, 0), set.map.count());
}

test "SubscriberSet: unsubscribe a later subscriber during callback" {
    var log: std.ArrayList(u32) = .empty;
    defer log.deinit(testing.allocator);
    var set = SubscriberSet(TestCb).init(testing.allocator);
    defer set.deinit();

    var b_sub: Subscription = undefined;
    const a = try set.insert(1, .{ .log = &log, .tag = 1, .drop = &b_sub });
    const b = try set.insert(1, .{ .log = &log, .tag = 2 });
    b_sub = b.subscription;
    set.activate(1, a.id);
    set.activate(1, b.id);
    set.retain(1, {}, callTest);
    try testing.expectEqualSlices(u32, &.{1}, log.items);
}

test "SubscriberSet: subscribers inserted during retain are not visited" {
    var log: std.ArrayList(u32) = .empty;
    defer log.deinit(testing.allocator);
    var set = SubscriberSet(TestCb).init(testing.allocator);
    defer set.deinit();

    const a = try set.insert(1, .{ .log = &log, .tag = 1, .insert_into = &set, .keep = false });
    set.activate(1, a.id);
    set.retain(1, {}, callTest);
    try testing.expectEqualSlices(u32, &.{1}, log.items);
    set.retain(1, {}, callTest);
    try testing.expectEqualSlices(u32, &.{ 1, 99 }, log.items);
}

test "SubscriberSet: remove returns active callbacks only" {
    var log: std.ArrayList(u32) = .empty;
    defer log.deinit(testing.allocator);
    var set = SubscriberSet(TestCb).init(testing.allocator);
    defer set.deinit();
    const a = try set.insert(7, .{ .log = &log, .tag = 1 });
    _ = try set.insert(7, .{ .log = &log, .tag = 2 });
    set.activate(7, a.id);
    var out: std.ArrayList(TestCb) = .empty;
    defer out.deinit(testing.allocator);
    set.remove(7, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u32, 1), out.items[0].tag);
    try testing.expect(set.isEmpty(7));
}
