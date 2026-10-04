//! Integration tests for the reactive core: entities, effects, subscriptions, globals, tasks.
//! Ordering expectations mirror gpui (`app.rs` flush_effects / SubscriberSet semantics).

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const core = @import("mod.zig");
const App = core.App;
const Context = core.Context;
const Entity = core.Entity;
const WeakEntity = core.WeakEntity;
const Subscription = core.Subscription;
const Subscriptions = core.Subscriptions;
const Task = core.Task;

/// Ordered log of static strings shared by test entities.
const Log = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn push(self: *Log, s: []const u8) void {
        self.items.append(testing.allocator, s) catch unreachable;
    }
    fn deinit(self: *Log) void {
        self.items.deinit(testing.allocator);
    }
    fn clear(self: *Log) void {
        self.items.clearRetainingCapacity();
    }
    fn expect(self: *Log, expected: []const []const u8) !void {
        testing.expectEqual(expected.len, self.items.items.len) catch |err| {
            std.debug.print("log: {any}\n", .{self.items.items});
            return err;
        };
        for (expected, self.items.items) |e, a| try testing.expectEqualStrings(e, a);
    }
};

const Counter = struct {
    count: u32 = 0,
    log: ?*Log = null,
    name: []const u8 = "counter",

    pub const Events = .{ Changed, Reset };
    pub const Changed = struct { value: u32 };
    pub const Reset = struct {};

    fn increment(self: *Counter, by: u32, cx: *Context(Counter)) void {
        self.count += by;
        cx.emit(Changed{ .value = self.count });
        cx.notify();
    }
    fn reset(self: *Counter, cx: *Context(Counter)) void {
        self.count = 0;
        cx.emit(Reset{});
    }
    fn get(self: *Counter, _: *Context(Counter)) u32 {
        return self.count;
    }
    pub fn deinit(self: *Counter) void {
        if (self.log) |l| l.push(self.name);
    }
};

test "entity create, read, update, release" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();

    const c = try app.new(Counter, .{});
    try testing.expectEqual(@as(u32, 0), c.read(app).count);
    c.update(app, Counter.increment, .{5});
    try testing.expectEqual(@as(u32, 5), c.read(app).count);
    try testing.expectEqual(@as(u32, 5), c.update(app, Counter.get, .{}));
    try testing.expectEqual(@as(usize, 1), app.entities.live_count);

    const weak = c.downgrade();
    try testing.expect(weak.isAlive(app));
    c.release(app);
    // Strong count hit zero: not upgradable even before the next flush destroys it.
    try testing.expect(!weak.isAlive(app));
    try testing.expect(weak.upgrade(app) == null);
    app.update({}, struct {
        fn f(_: void, _: *App) void {}
    }.f);
    try testing.expectEqual(@as(usize, 0), app.entities.live_count);
}

test "lease API and leased flag" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const a = try app.new(Counter, .{});
    defer a.release(app);
    const b = try app.new(Counter, .{});
    defer b.release(app);

    {
        var l = a.lease(app);
        defer l.end();
        try testing.expect(app.entities.isLeased(a.id));
        l.value.count = 41;
        // Other entities are freely readable/updatable while `a` is leased.
        b.update(&l.cx, Counter.increment, .{1});
        try testing.expectEqual(@as(u32, 1), b.read(&l.cx).count);
        l.cx.notify();
    }
    try testing.expect(!app.entities.isLeased(a.id));
    try testing.expectEqual(@as(u32, 41), a.read(app).count);
}

test "weak handles do not resurrect reused slots" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const a = try app.new(Counter, .{});
    const weak_a = a.downgrade();
    a.release(app);
    app.notify(a.id); // any update flushes and destroys `a`
    const b = try app.new(Counter, .{ .count = 9 });
    defer b.release(app);
    try testing.expectEqual(a.id.index(), b.id.index());
    try testing.expect(a.id != b.id);
    try testing.expect(weak_a.upgrade(app) == null);
    try testing.expect(weak_a.read(app) == null);
    const up = b.downgrade().upgrade(app).?;
    try testing.expectEqual(@as(u32, 2), app.entities.strongCount(b.id));
    up.release(app);
}

test "AnyEntity downcast" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const a = try app.new(Counter, .{});
    defer a.release(app);
    const any = a.toAny();
    try testing.expect(any.downcast(Counter) != null);
    try testing.expect(any.downcast(Log) == null);
    try testing.expect(any.downgrade().isAlive(app));
}

const Observer = struct {
    log: *Log,
    seen: u32 = 0,
    sub: Subscription = .empty,

    fn onNotify(self: *Observer, counter: Entity(Counter), cx: *Context(Observer)) void {
        self.seen = counter.read(cx).count;
        self.log.push("observed");
    }
    pub fn deinit(self: *Observer) void {
        self.sub.deinit();
    }
};

test "notify is delivered after the outermost update, deduplicated" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var log: Log = .{};
    defer log.deinit();

    const counter = try app.new(Counter, .{});
    defer counter.release(app);
    const obs = try app.new(Observer, .{ .log = &log });
    defer obs.release(app);
    try obs.update(app, struct {
        fn f(self: *Observer, c: Entity(Counter), cx: *Context(Observer)) !void {
            self.sub = try cx.observe(c, Observer.onNotify);
        }
    }.f, .{counter});

    counter.update(app, struct {
        fn f(self: *Counter, l: *Log, cx: *Context(Counter)) void {
            self.count += 1;
            cx.notify();
            self.count += 1;
            cx.notify();
            l.push("update done");
        }
    }.f, .{&log});
    try log.expect(&.{ "update done", "observed" });
    try testing.expectEqual(@as(u32, 2), obs.read(app).seen);
}

test "observer activation is ordered with effects (gpui defer(activate))" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var log: Log = .{};
    defer log.deinit();

    const counter = try app.new(Counter, .{});
    defer counter.release(app);

    const Ctx = struct {
        log: *Log,
        counter: Entity(Counter),
        late: Subscription = .empty,
        early: Subscription = .empty,
        fn onLate(self: *@This(), _: Entity(Counter), _: *App) void {
            self.log.push("late");
        }
        fn onEarly(self: *@This(), _: Entity(Counter), _: *App) void {
            self.log.push("early");
        }
        fn run(self: *@This(), a: *App) void {
            self.early = a.observe(self.counter, self, onEarly) catch unreachable;
            a.notify(self.counter.id);
            // Registered after the notify was queued: activation comes after it.
            self.late = a.observe(self.counter, self, onLate) catch unreachable;
        }
    };
    var ctx: Ctx = .{ .log = &log, .counter = counter };
    defer ctx.late.deinit();
    defer ctx.early.deinit();
    app.update(&ctx, Ctx.run);
    try log.expect(&.{"early"});
    app.notify(counter.id);
    try log.expect(&.{ "early", "early", "late" });
}

const Listener = struct {
    log: *Log,
    total: u32 = 0,
    subs: Subscriptions = .{},

    fn init(log: *Log, counter: Entity(Counter), cx: *Context(Listener)) !Listener {
        var self: Listener = .{ .log = log };
        try self.subs.add(cx.gpa(), try cx.subscribe(counter, Listener.onChanged));
        try self.subs.add(cx.gpa(), try cx.subscribe(counter, Listener.onReset));
        return self;
    }
    fn onChanged(self: *Listener, _: Entity(Counter), ev: *const Counter.Changed, _: *Context(Listener)) void {
        self.total += ev.value;
        self.log.push("changed");
    }
    fn onReset(self: *Listener, _: Entity(Counter), _: *const Counter.Reset, _: *Context(Listener)) void {
        self.log.push("reset");
    }
    pub fn deinit(self: *Listener, app: *App) void {
        self.subs.deinit(app.gpa);
    }
};

test "emit/subscribe delivers typed events in order" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var log: Log = .{};
    defer log.deinit();
    const counter = try app.new(Counter, .{});
    defer counter.release(app);
    const listener = try app.newWith(Listener, Listener.init, .{ &log, counter });
    defer listener.release(app);

    counter.update(app, Counter.increment, .{2});
    counter.update(app, Counter.reset, .{});
    counter.update(app, Counter.increment, .{3});
    try log.expect(&.{ "changed", "reset", "changed" });
    try testing.expectEqual(@as(u32, 5), listener.read(app).total);
}

test "app-level subscribe with plain context pointer" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const counter = try app.new(Counter, .{});
    defer counter.release(app);
    var sum: u32 = 0;
    var sub = try app.subscribe(counter, &sum, struct {
        fn f(s: *u32, _: Entity(Counter), ev: *const Counter.Changed, _: *App) void {
            s.* += ev.value;
        }
    }.f);
    counter.update(app, Counter.increment, .{4});
    try testing.expectEqual(@as(u32, 4), sum);
    sub.deinit();
    counter.update(app, Counter.increment, .{4});
    try testing.expectEqual(@as(u32, 4), sum);
}

const Chain = struct {
    log: *Log,
    next: ?Entity(Chain) = null,
    label: []const u8,
    pub const Events = .{Ping};
    pub const Ping = struct {};

    fn ping(_: *Chain, cx: *Context(Chain)) void {
        cx.emit(Ping{});
        cx.notify();
    }
};

test "effects produced during flush are processed in the same flush, FIFO" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var log: Log = .{};
    defer log.deinit();
    const a = try app.new(Chain, .{ .log = &log, .label = "a" });
    defer a.release(app);
    const b = try app.new(Chain, .{ .log = &log, .label = "b" });
    defer b.release(app);

    const Ctx = struct {
        log: *Log,
        b: Entity(Chain),
        fn onPingA(self: *@This(), _: Entity(Chain), _: *const Chain.Ping, app_: *App) void {
            self.log.push("a:ping");
            // Effects queued here run after everything already in the queue.
            self.b.update(app_, Chain.ping, .{});
            app_.deferFn(self.log, struct {
                fn f(l: *Log, _: *App) void {
                    l.push("deferred");
                }
            }.f);
        }
        fn onNotifyA(self: *@This(), _: Entity(Chain), _: *App) void {
            self.log.push("a:notify");
        }
        fn onPingB(self: *@This(), _: Entity(Chain), _: *const Chain.Ping, _: *App) void {
            self.log.push("b:ping");
        }
        fn onNotifyB(self: *@This(), _: Entity(Chain), _: *App) void {
            self.log.push("b:notify");
        }
    };
    var ctx: Ctx = .{ .log = &log, .b = b };
    var subs: [4]Subscription = .{
        try app.subscribe(a, &ctx, Ctx.onPingA),
        try app.observe(a, &ctx, Ctx.onNotifyA),
        try app.subscribe(b, &ctx, Ctx.onPingB),
        try app.observe(b, &ctx, Ctx.onNotifyB),
    };
    defer for (&subs) |*s| s.deinit();

    a.update(app, Chain.ping, .{});
    try log.expect(&.{ "a:ping", "a:notify", "b:ping", "b:notify", "deferred" });
}

test "unsubscribing another subscriber during a callback skips it" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var log: Log = .{};
    defer log.deinit();
    const counter = try app.new(Counter, .{});
    defer counter.release(app);

    const Ctx = struct {
        log: *Log,
        second: Subscription = .empty,
        first: Subscription = .empty,
        fn onFirst(self: *@This(), _: Entity(Counter), _: *App) void {
            self.log.push("first");
            self.second.deinit();
        }
        fn onSecond(self: *@This(), _: Entity(Counter), _: *App) void {
            self.log.push("second");
        }
    };
    var ctx: Ctx = .{ .log = &log };
    ctx.first = try app.observe(counter, &ctx, Ctx.onFirst);
    ctx.second = try app.observe(counter, &ctx, Ctx.onSecond);
    defer ctx.first.deinit();
    app.notify(counter.id);
    app.notify(counter.id);
    try log.expect(&.{ "first", "first" });
}

test "a subscriber can drop itself during its callback; detach keeps it alive" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const counter = try app.new(Counter, .{});
    defer counter.release(app);

    const Ctx = struct {
        calls: u32 = 0,
        detached_calls: u32 = 0,
        sub: Subscription = .empty,
        fn onSelfDrop(self: *@This(), _: Entity(Counter), _: *App) void {
            self.calls += 1;
            self.sub.deinit();
        }
        fn onDetached(self: *@This(), _: Entity(Counter), _: *App) void {
            self.detached_calls += 1;
        }
    };
    var ctx: Ctx = .{};
    ctx.sub = try app.observe(counter, &ctx, Ctx.onSelfDrop);
    var d = try app.observe(counter, &ctx, Ctx.onDetached);
    d.detach();
    app.notify(counter.id);
    app.notify(counter.id);
    try testing.expectEqual(@as(u32, 1), ctx.calls);
    try testing.expectEqual(@as(u32, 2), ctx.detached_calls);
    try testing.expect(!app.observers.isEmpty(counter.id.toKey()));
}

const Parent = struct {
    log: *Log,
    child: Entity(Counter),
    pub fn deinit(self: *Parent, app: *App) void {
        self.log.push("parent deinit");
        self.child.release(app);
    }
};

test "release order: release listeners, deinit, then entities released by deinit" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var log: Log = .{};
    defer log.deinit();
    const child = try app.new(Counter, .{ .log = &log, .name = "child deinit" });
    const parent = try app.new(Parent, .{ .log = &log, .child = child });

    const Ctx = struct {
        fn onParentReleased(l: *Log, p: *Parent, _: *App) void {
            _ = p.child;
            l.push("parent released");
        }
        fn onChildReleased(l: *Log, c: *Counter, _: *App) void {
            _ = c.count;
            l.push("child released");
        }
        fn onChildNotify(l: *Log, _: Entity(Counter), _: *App) void {
            l.push("child notify");
        }
    };
    var s1 = try app.observeRelease(parent, &log, Ctx.onParentReleased);
    s1.detach();
    var s2 = try app.observeRelease(child, &log, Ctx.onChildReleased);
    s2.detach();
    var s3 = try app.observe(child, &log, Ctx.onChildNotify);
    s3.detach();

    parent.release(app);
    try log.expect(&.{});
    app.notify(child.id); // flush: parent destroyed first, its deinit releases child
    try log.expect(&.{ "parent released", "parent deinit", "child released", "child deinit" });
    try testing.expectEqual(@as(usize, 0), app.entities.live_count);
    try testing.expect(app.observers.isEmpty(child.id.toKey()));
}

const SelfAware = struct {
    log: *Log,
    sub: Subscription = .empty,
    fn init(log: *Log, cx: *Context(SelfAware)) !SelfAware {
        return .{ .log = log, .sub = try cx.onRelease(onReleased) };
    }
    fn onReleased(self: *SelfAware, _: *App) void {
        self.log.push("on_release");
    }
};

test "cx.onRelease and observers of dead subscribers are pruned" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var log: Log = .{};
    defer log.deinit();
    const counter = try app.new(Counter, .{});
    defer counter.release(app);
    const e = try app.newWith(SelfAware, SelfAware.init, .{&log});

    // `e` observes counter with a detached subscription; after `e` dies the observer
    // returns false on the next notify and is removed.
    e.update(app, struct {
        fn f(_: *SelfAware, c: Entity(Counter), cx: *Context(SelfAware)) void {
            var s = cx.observe(c, struct {
                fn on(self: *SelfAware, _: Entity(Counter), _: *Context(SelfAware)) void {
                    self.log.push("observed");
                }
            }.on) catch unreachable;
            s.detach();
        }
    }.f, .{counter});
    app.notify(counter.id);
    e.release(app);
    app.notify(counter.id);
    try log.expect(&.{ "observed", "on_release" });
    try testing.expect(app.observers.isEmpty(counter.id.toKey()));
}

const Built = struct {
    value: u32,
    fn init(v: u32, fail: bool, _: *Context(Built)) !Built {
        if (fail) return error.Nope;
        return .{ .value = v };
    }
};

test "newWith propagates constructor errors without leaking" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    try testing.expectError(error.Nope, app.newWith(Built, Built.init, .{ 1, true }));
    try testing.expectEqual(@as(usize, 0), app.entities.live_count);
    const ok = try app.newWith(Built, Built.init, .{ 7, false });
    defer ok.release(app);
    try testing.expectEqual(@as(u32, 7), ok.read(app).value);
}

test "nested updates flush only at the outermost update" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var log: Log = .{};
    defer log.deinit();
    const a = try app.new(Counter, .{});
    defer a.release(app);
    const b = try app.new(Counter, .{});
    defer b.release(app);
    var sub = try app.observe(b, &log, struct {
        fn f(l: *Log, _: Entity(Counter), _: *App) void {
            l.push("b notified");
        }
    }.f);
    defer sub.deinit();

    const Outer = struct {
        fn f(_: *Counter, other: Entity(Counter), l: *Log, cx: *Context(Counter)) void {
            other.update(cx, Counter.increment, .{1});
            l.push("inner returned");
        }
    };
    a.update(app, Outer.f, .{ b, &log });
    try log.expect(&.{ "inner returned", "b notified" });
}

test "observeNew sees new entities with mutable access" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var created: u32 = 0;
    var sub = try app.observeNew(Counter, &created, struct {
        fn f(n: *u32, c: *Counter, _: *Context(Counter)) void {
            n.* += 1;
            c.count = 100;
        }
    }.f);
    defer sub.deinit();
    const a = try app.new(Counter, .{});
    defer a.release(app);
    try testing.expectEqual(@as(u32, 1), created);
    try testing.expectEqual(@as(u32, 100), a.read(app).count);
}

test "cx.deferUpdate and cx.entity" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var log: Log = .{};
    defer log.deinit();
    const a = try app.new(Counter, .{ .log = null });
    defer a.release(app);
    a.update(app, struct {
        fn f(self: *Counter, l: *Log, cx: *Context(Counter)) void {
            self.log = l;
            cx.deferUpdate(struct {
                fn d(s: *Counter, _: *Context(Counter)) void {
                    s.log.?.push("deferred");
                }
            }.d);
            const me = cx.entity();
            defer me.release(cx);
            std.debug.assert(me.id == cx.entityId());
            l.push("body");
        }
    }.f, .{&log});
    try log.expect(&.{ "body", "deferred" });
    a.update(app, struct {
        fn f(self: *Counter, _: *Context(Counter)) void {
            self.log = null;
        }
    }.f, .{});
}

// ---- globals ---------------------------------------------------------------------------

const Theme = struct {
    dark: bool = false,
    version: u32 = 0,
};

const ThemeWatcher = struct {
    changes: u32 = 0,
    sub: Subscription = .empty,
    fn init(cx: *Context(ThemeWatcher)) !ThemeWatcher {
        return .{ .sub = try cx.observeGlobal(Theme, onTheme) };
    }
    fn onTheme(self: *ThemeWatcher, _: *Context(ThemeWatcher)) void {
        self.changes += 1;
    }
    pub fn deinit(self: *ThemeWatcher) void {
        self.sub.deinit();
    }
};

test "globals: set, read, update, observe, remove" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    try testing.expect(!app.hasGlobal(Theme));
    try app.setGlobal(Theme{});
    try testing.expect(!app.global(Theme).dark);

    const w = try app.newWith(ThemeWatcher, ThemeWatcher.init, .{});
    defer w.release(app);
    var count: u32 = 0;
    var sub = try app.observeGlobal(Theme, &count, struct {
        fn f(c: *u32, _: *App) void {
            c.* += 1;
        }
    }.f);
    defer sub.deinit();

    const v = app.update({}, struct {
        fn outer(_: void, a: *App) u32 {
            const r = a.updateGlobal(Theme, {}, struct {
                fn f(_: void, t: *Theme, _: *App) u32 {
                    t.dark = true;
                    t.version += 1;
                    return t.version;
                }
            }.f);
            // A second change in the same outer update is deduplicated.
            a.globalMut(Theme).version += 1;
            return r + 1;
        }
    }.outer);
    try testing.expectEqual(@as(u32, 2), v);
    try testing.expect(app.global(Theme).dark);
    try testing.expectEqual(@as(u32, 1), count);
    try testing.expectEqual(@as(u32, 1), w.read(app).changes);

    try app.setGlobal(Theme{ .version = 10 });
    try testing.expectEqual(@as(u32, 10), app.global(Theme).version);
    try testing.expectEqual(@as(u32, 2), count);

    const removed = app.removeGlobal(Theme).?;
    try testing.expectEqual(@as(u32, 10), removed.version);
    try testing.expect(app.tryGlobal(Theme) == null);
    try testing.expectEqual(@as(u32, 3), count);
}

const OwnsEntity = struct {
    e: Entity(Counter),
    pub fn deinit(self: *OwnsEntity, app: *App) void {
        self.e.release(app);
    }
};

test "App.deinit destroys globals and live entities without leaks" {
    var log: Log = .{};
    defer log.deinit();
    const app = try App.initTest(testing.allocator);
    const c = try app.new(Counter, .{});
    try app.setGlobal(OwnsEntity{ .e = c.retain(app) });
    _ = try app.new(Parent, .{ .log = &log, .child = c }); // never released on purpose
    var sub = try app.observe(c, {}, struct {
        fn f(_: void, _: Entity(Counter), _: *App) void {}
    }.f);
    sub.detach();
    var task = try app.foregroundExecutor().timer(1000, Tick{ .log = &log, .label = "never" });
    task.detach();
    app.deinit();
    try log.expect(&.{"parent deinit"});
}

// ---- executors & tasks -----------------------------------------------------------------

const Square = struct {
    n: u64,
    out: ?*u64 = null,
    pub fn run(self: *Square) u64 {
        return self.n * self.n;
    }
    pub fn finish(self: *Square, r: u64) void {
        if (self.out) |o| o.* = r;
    }
};

test "background task runs, then finishes on the main thread" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var out: u64 = 0;
    var task = try app.backgroundExecutor().spawn(Square{ .n = 7, .out = &out });
    try testing.expect(!task.isReady());
    app.runUntilParked();
    try testing.expect(task.isReady());
    try testing.expectEqual(@as(u64, 49), task.result().?.*);
    try testing.expectEqual(@as(u64, 49), out);
    try testing.expectEqual(core.executor.TaskState.completed, task.state());
    task.detach();
    try testing.expectEqual(@as(usize, 0), app.executor.live_count);
}

test "cancel before run prevents finish; detach still completes" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var a: u64 = 0;
    var b: u64 = 0;
    var t1 = try app.backgroundExecutor().spawn(Square{ .n = 3, .out = &a });
    var t2 = try app.backgroundExecutor().spawn(Square{ .n = 4, .out = &b });
    t1.cancel();
    t1.cancel(); // idempotent
    t2.detach();
    app.runUntilParked();
    try testing.expectEqual(@as(u64, 0), a);
    try testing.expectEqual(@as(u64, 16), b);
    try testing.expectEqual(@as(usize, 0), app.executor.live_count);
}

const Discarding = struct {
    discarded: *bool,
    pub fn run(_: *Discarding) u32 {
        return 1;
    }
    pub fn finish(_: *Discarding, _: u32) void {
        unreachable;
    }
    pub fn discard(self: *Discarding, _: u32) void {
        self.discarded.* = true;
    }
};

test "cancel after background phase discards the result" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var discarded = false;
    var t = try app.backgroundExecutor().spawn(Discarding{ .discarded = &discarded });
    const d = app.test_platform.?.dispatcher();
    _ = d.tick(); // background phase only; finish is now queued on the main thread
    try testing.expect(t.isReady());
    t.cancel();
    try testing.expect(discarded);
    app.runUntilParked();
}

const TokenJob = struct {
    saw_cancel: *bool,
    pub fn run(self: *TokenJob, token: core.CancelToken) void {
        self.saw_cancel.* = token.isCanceled();
    }
};

test "CancelToken reports cancellation to background work" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var saw = true;
    var t = try app.backgroundExecutor().spawn(TokenJob{ .saw_cancel = &saw });
    app.runUntilParked();
    try testing.expect(!saw);
    t.detach();
}

const Tick = struct {
    log: *Log,
    label: []const u8,
    pub fn finish(self: *Tick) void {
        self.log.push(self.label);
    }
};

test "foreground spawn is FIFO and timers fire with advanceClock" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var log: Log = .{};
    defer log.deinit();
    const fg = app.foregroundExecutor();
    var t3 = try fg.timer(2 * std.time.ns_per_s, Tick{ .log = &log, .label = "2s" });
    var t2 = try fg.timer(std.time.ns_per_s, Tick{ .log = &log, .label = "1s" });
    var t1 = try fg.spawn(Tick{ .log = &log, .label = "now-a" });
    var t0 = try fg.spawn(Tick{ .log = &log, .label = "now-b" });
    var timer = try app.backgroundExecutor().timer(500 * std.time.ns_per_ms);
    defer timer.detach();
    inline for (.{ &t0, &t1, &t2, &t3 }) |t| t.detach();

    app.runUntilParked();
    try log.expect(&.{ "now-a", "now-b" });
    app.advanceClock(999 * std.time.ns_per_ms);
    try log.expect(&.{ "now-a", "now-b" });
    try testing.expect(timer.isReady());
    app.advanceClock(std.time.ns_per_ms);
    try log.expect(&.{ "now-a", "now-b", "1s" });
    app.advanceClock(std.time.ns_per_s);
    try log.expect(&.{ "now-a", "now-b", "1s", "2s" });
}

const Fetcher = struct {
    result: u64 = 0,
    ticks: u32 = 0,
    task: Task(u64) = .none,
    timer_task: Task(void) = .none,

    const Job = struct {
        n: u64,
        pub fn run(self: *Job) u64 {
            return self.n + 1;
        }
    };

    fn start(self: *Fetcher, n: u64, cx: *Context(Fetcher)) !void {
        self.task = try cx.spawn(Job{ .n = n }, Fetcher.onDone);
    }
    fn onDone(self: *Fetcher, r: u64, cx: *Context(Fetcher)) void {
        self.result = r;
        cx.notify();
    }
    fn startTicking(self: *Fetcher, cx: *Context(Fetcher)) !void {
        self.timer_task = try cx.timer(100, Fetcher.onTick);
    }
    fn onTick(self: *Fetcher, cx: *Context(Fetcher)) void {
        self.ticks += 1;
        self.timer_task.detach();
        if (self.ticks < 3) self.timer_task = cx.timer(100, Fetcher.onTick) catch unreachable;
    }
    pub fn deinit(self: *Fetcher) void {
        self.task.cancel();
        self.timer_task.cancel();
    }
};

test "cx.spawn re-enters the entity; cx.timer chains" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const f = try app.new(Fetcher, .{});
    defer f.release(app);
    var notified: u32 = 0;
    var sub = try app.observe(f, &notified, struct {
        fn on(n: *u32, _: Entity(Fetcher), _: *App) void {
            n.* += 1;
        }
    }.on);
    defer sub.deinit();

    try f.update(app, Fetcher.start, .{41});
    try testing.expectEqual(@as(u64, 0), f.read(app).result);
    app.runUntilParked();
    try testing.expectEqual(@as(u64, 42), f.read(app).result);
    try testing.expectEqual(@as(u32, 1), notified);

    try f.update(app, Fetcher.startTicking, .{});
    app.advanceClock(1000);
    try testing.expectEqual(@as(u32, 3), f.read(app).ticks);
}

test "releasing an entity cancels the tasks it spawned" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const f = try app.new(Fetcher, .{});
    try f.update(app, Fetcher.start, .{1});
    try f.update(app, Fetcher.startTicking, .{});
    try testing.expectEqual(@as(usize, 2), app.executor.live_count);
    f.release(app);
    app.notify(f.id); // flush → entity destroyed, owned tasks canceled
    try testing.expectEqual(@as(usize, 0), app.executor.live_count);
    app.runUntilParked();
    app.advanceClock(1000);
}

test "cx.listener updates the bound entity" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const c = try app.new(Counter, .{});
    const Click = struct { times: u32 };
    const l = c.update(app, struct {
        fn f(_: *Counter, cx: *Context(Counter)) core.Listener(Click) {
            return cx.listener(struct {
                fn on(self: *Counter, ev: *const Click, _: *Context(Counter)) void {
                    self.count += ev.times;
                }
            }.on);
        }
    }.f, .{});
    l.call(&.{ .times = 3 }, app);
    try testing.expectEqual(@as(u32, 3), c.read(app).count);
    c.release(app);
    l.call(&.{ .times = 3 }, app); // dead entity: no-op
}

test "test platform: clipboard, displays, quit" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const p = app.platform;
    p.vtable.writeClipboard(p.ptr, "hello");
    const got = p.vtable.readClipboard(p.ptr, testing.allocator).?;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello", got);
    var displays: [2]@import("../platform/platform.zig").Display = undefined;
    try testing.expectEqual(@as(usize, 1), p.vtable.displays(p.ptr, &displays));
    try testing.expectError(error.Unsupported, p.openWindow(.{ .bounds = displays[0].bounds }));
    app.quit();
    try testing.expect(app.test_platform.?.quit_requested);
}

test "App.run calls on_launch and drains the loop (test platform)" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var log: Log = .{};
    defer log.deinit();
    app.run(&log, struct {
        fn launch(l: *Log, a: *App) void {
            l.push("launched");
            var t = a.foregroundExecutor().spawn(Tick{ .log = l, .label = "tick" }) catch unreachable;
            t.detach();
        }
    }.launch);
    try log.expect(&.{ "launched", "tick" });
}
