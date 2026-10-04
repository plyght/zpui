//! The App: owner of all entities, globals, executors and the effect queue (gpui `app.rs`).
//!
//! ```zig
//! const Counter = struct {
//!     count: u32 = 0,
//!     pub const Events = .{Changed};
//!     pub const Changed = struct { new: u32 };
//!
//!     pub fn increment(self: *Counter, by: u32, cx: *Context(Counter)) void {
//!         self.count += by;
//!         cx.emit(Changed{ .new = self.count });
//!         cx.notify();
//!     }
//! };
//!
//! const Label = struct {
//!     text_len: u32 = 0,
//!     sub: Subscription = .empty,
//!
//!     pub fn init(counter: Entity(Counter), cx: *Context(Label)) !Label {
//!         return .{ .sub = try cx.subscribe(counter, Label.onCounterChanged) };
//!     }
//!     fn onCounterChanged(self: *Label, _: Entity(Counter), ev: *const Counter.Changed, cx: *Context(Label)) void {
//!         self.text_len = ev.new;
//!         cx.notify();
//!     }
//!     pub fn deinit(self: *Label, _: *App) void {
//!         self.sub.deinit();
//!     }
//! };
//!
//! const counter = try app.new(Counter, .{});
//! const label = try app.newWith(Label, Label.init, .{counter});
//! counter.update(app, Counter.increment, .{1}); // label sees the event after the update
//! ```
//!
//! Effects (`notify`, `emit`, global changes, deferred calls, entity creation) are queued and
//! delivered FIFO when the outermost update finishes; effects queued during delivery are
//! delivered in the same flush. Released entities are destroyed at the top of each flush
//! iteration. Every public mutating App method wraps itself in an update, so calling them at
//! top level also flushes.
//!
//! OOM policy: APIs that register things (`new`, `observe`, `subscribe`, `spawn`, globals)
//! return errors; fire-and-forget effect APIs (`notify`, `emit`, `defer`) panic on OOM.

const std = @import("std");
const Allocator = std.mem.Allocator;
const platform = @import("../platform/platform.zig");
const type_id = @import("type_id.zig");
const TypeId = type_id.TypeId;
const typeId = type_id.typeId;
const entity_mod = @import("entity.zig");
const EntityId = entity_mod.EntityId;
const EntityMap = entity_mod.EntityMap;
const Entity = entity_mod.Entity;
const AnyEntity = entity_mod.AnyEntity;
const subscriber_set = @import("subscriber_set.zig");
const SubscriberSet = subscriber_set.SubscriberSet;
pub const Subscription = subscriber_set.Subscription;
const executor_mod = @import("executor.zig");
const Context = @import("context.zig").Context;
const keymap_mod = @import("keymap.zig");
const action_mod = @import("action.zig");
const TestPlatform = @import("test_platform.zig").TestPlatform;

// ---------------------------------------------------------------------------------------
// Erased callbacks. gpui boxes closures; zpui stores a function pointer plus small inline
// captures (two u64s, usually entity ids) and an optional heap pointer. Comptime wrappers
// (see Context) generate `func` from typed methods, so most callbacks never allocate.
// ---------------------------------------------------------------------------------------

pub const Captures = struct {
    a: u64 = 0,
    b: u64 = 0,
    ptr: ?*anyopaque = null,
    /// Frees `ptr` when the callback is dropped.
    free: ?*const fn (ptr: *anyopaque, gpa: Allocator) void = null,

    fn deinit(self: *Captures, gpa: Allocator) void {
        if (self.free) |f| if (self.ptr) |p| f(p, gpa);
        self.free = null;
    }
};

/// Observer of notifications / global changes. Return false to unsubscribe.
pub const Handler = struct {
    func: *const fn (cap: *const Captures, app: *App) bool,
    cap: Captures = .{},
    pub fn deinit(self: *Handler, gpa: Allocator) void {
        self.cap.deinit(gpa);
    }
};

/// Event listener for one event type. Return false to unsubscribe.
pub const Listener = struct {
    event_type: TypeId,
    func: *const fn (cap: *const Captures, event: *const anyopaque, app: *App) bool,
    cap: Captures = .{},
    pub fn deinit(self: *Listener, gpa: Allocator) void {
        self.cap.deinit(gpa);
    }
};

/// Called with the value of a released entity, before it is destroyed.
pub const ReleaseListener = struct {
    func: *const fn (cap: *const Captures, value: *anyopaque, app: *App) void,
    cap: Captures = .{},
    pub fn deinit(self: *ReleaseListener, gpa: Allocator) void {
        self.cap.deinit(gpa);
    }
};

pub const NewEntityListener = struct {
    func: *const fn (cap: *const Captures, entity: AnyEntity, app: *App) void,
    cap: Captures = .{},
    pub fn deinit(self: *NewEntityListener, gpa: Allocator) void {
        self.cap.deinit(gpa);
    }
};

/// A callback run once at the end of the current effect cycle.
pub const Deferred = struct {
    func: *const fn (cap: *const Captures, app: *App) void,
    cap: Captures = .{},
    pub fn deinit(self: *Deferred, gpa: Allocator) void {
        self.cap.deinit(gpa);
    }
};

/// Wrap a pointer (or `{}`) as captures; converted back with `unwrapCtx`.
pub fn wrapCtx(ctx: anytype) Captures {
    const C = @TypeOf(ctx);
    if (C == void) return .{};
    if (@typeInfo(C) != .pointer) @compileError("callback context must be a pointer or {}, got " ++ @typeName(C));
    return .{ .ptr = @ptrCast(@constCast(ctx)) };
}

pub fn unwrapCtx(comptime C: type, cap: *const Captures) C {
    if (C == void) return {};
    return @ptrCast(@alignCast(cap.ptr.?));
}

// ---------------------------------------------------------------------------------------

pub const Effect = union(enum) {
    notify: EntityId,
    emit: struct { emitter: EntityId, event_type: TypeId, event: *const anyopaque },
    refresh_windows,
    notify_global_observers: u64,
    deferred: Deferred,
    /// Activate a subscriber inserted earlier in this cycle (gpui `defer(activate)`).
    activate: struct { set: SetKind, key: u64, id: u64 },
    /// Holds a strong reference until delivered.
    entity_created: AnyEntity,
};

pub const SetKind = enum { observers, event_listeners, global_observers };

const GlobalVTable = struct {
    type_name: []const u8,
    destroy: *const fn (ptr: *anyopaque, app: *App) void,
};

fn globalVTable(comptime G: type) *const GlobalVTable {
    return &struct {
        const vt: GlobalVTable = .{ .type_name = @typeName(G), .destroy = destroy };
        fn destroy(ptr: *anyopaque, app: *App) void {
            const p: *G = @ptrCast(@alignCast(ptr));
            entity_mod.callDeinit(G, p, app);
            app.gpa.destroy(p);
        }
    }.vt;
}

const GlobalSlot = struct {
    ptr: *anyopaque,
    vtable: *const GlobalVTable,
    leased: bool = false,
};

pub const App = struct {
    gpa: Allocator,
    platform: platform.Platform,
    /// Set when created with `initTest`.
    test_platform: ?*TestPlatform = null,
    executor: executor_mod.Executor,
    entities: EntityMap,
    globals: std.AutoHashMapUnmanaged(u64, GlobalSlot) = .empty,
    keymap: keymap_mod.Keymap,
    actions: action_mod.ActionRegistry,

    pending_effects: std.Deque(Effect) = .empty,
    pending_notifications: std.AutoHashMapUnmanaged(EntityId, void) = .empty,
    pending_global_notifications: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Event payloads, cleared when the effect queue drains.
    event_arena: std.heap.ArenaAllocator,

    observers: SubscriberSet(Handler),
    event_listeners: SubscriberSet(Listener),
    release_listeners: SubscriberSet(ReleaseListener),
    global_observers: SubscriberSet(Handler),
    new_entity_observers: SubscriberSet(NewEntityListener),

    pending_updates: u32 = 0,
    flushing_effects: bool = false,
    shutting_down: bool = false,
    quit_requested: bool = false,
    // Window registry: added in the window phase (gpui `windows: SlotMap<WindowId, Option<Box<Window>>>`).

    /// Create an App that owns `plat` (deinit'ed with the App).
    pub fn init(gpa: Allocator, plat: platform.Platform) Allocator.Error!*App {
        const app = try gpa.create(App);
        app.* = .{
            .gpa = gpa,
            .platform = plat,
            .executor = .init(gpa, plat.dispatcher()),
            .entities = .init(gpa),
            .keymap = .init(gpa),
            .actions = .init(gpa),
            .event_arena = .init(gpa),
            .observers = .init(gpa),
            .event_listeners = .init(gpa),
            .release_listeners = .init(gpa),
            .global_observers = .init(gpa),
            .new_entity_observers = .init(gpa),
        };
        return app;
    }

    /// Headless App on a fresh `TestPlatform`; drive it with `runUntilParked`/`advanceClock`.
    pub fn initTest(gpa: Allocator) Allocator.Error!*App {
        const tp = try TestPlatform.create(gpa);
        errdefer tp.destroy();
        const app = try init(gpa, tp.platform());
        app.test_platform = tp;
        return app;
    }

    pub fn deinit(app: *App) void {
        const gpa = app.gpa;
        app.shutting_down = true;
        app.executor.deinit();

        // Globals first: they may own entity handles.
        var git = app.globals.valueIterator();
        while (git.next()) |g| g.vtable.destroy(g.ptr, app);
        app.globals.deinit(gpa);

        // Destroy every remaining entity (no release listeners at shutdown).
        for (app.entities.slots.items) |*s| {
            const ptr = s.ptr orelse continue;
            s.ptr = null;
            s.vtable.?.destroy(ptr, app);
        }

        while (app.pending_effects.popFront()) |eff| {
            var e = eff;
            if (e == .deferred) e.deferred.deinit(gpa);
        }
        app.pending_effects.deinit(gpa);
        app.pending_notifications.deinit(gpa);
        app.pending_global_notifications.deinit(gpa);
        app.event_arena.deinit();
        app.observers.deinit();
        app.event_listeners.deinit();
        app.release_listeners.deinit();
        app.global_observers.deinit();
        app.new_entity_observers.deinit();
        app.keymap.deinit();
        app.actions.deinit();
        app.entities.deinit();
        app.platform.deinit();
        gpa.destroy(app);
    }

    // ---- run loop / test driving -----------------------------------------------------

    pub fn foregroundExecutor(app: *App) executor_mod.ForegroundExecutor {
        return app.executor.foreground();
    }

    pub fn backgroundExecutor(app: *App) executor_mod.BackgroundExecutor {
        return app.executor.background();
    }

    /// Test platform only: run every ready runnable.
    pub fn runUntilParked(app: *App) void {
        app.test_platform.?.runUntilParked();
    }

    /// Test platform only: advance the fake clock and run due timers.
    pub fn advanceClock(app: *App, delta_ns: u64) void {
        app.test_platform.?.advanceClock(delta_ns);
    }

    /// Enter the platform event loop; `on_launch(ctx, app)` runs (as an update) once the
    /// platform finished launching. Returns after `quit`.
    pub fn run(app: *App, ctx: anytype, comptime on_launch: fn (@TypeOf(ctx), *App) void) void {
        const State = struct {
            app: *App,
            ctx: @TypeOf(ctx),
            fn launch(p: ?*anyopaque, _: void) void {
                const st: *@This() = @ptrCast(@alignCast(p.?));
                st.app.update(st.ctx, on_launch);
            }
        };
        var state: State = .{ .app = app, .ctx = ctx };
        app.platform.run(.{ .ctx = &state, .func = State.launch });
    }

    pub fn quit(app: *App) void {
        app.quit_requested = true;
        app.platform.quit();
    }

    // ---- updates and effects ---------------------------------------------------------

    pub fn startUpdate(app: *App) void {
        app.pending_updates += 1;
    }

    pub fn finishUpdate(app: *App) void {
        if (!app.flushing_effects and app.pending_updates == 1) {
            app.flushing_effects = true;
            app.flushEffects();
            app.flushing_effects = false;
        }
        app.pending_updates -= 1;
    }

    /// Run `f(ctx, app)` as an update (effects flush when the outermost update returns).
    pub fn update(app: *App, ctx: anytype, comptime f: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        app.startUpdate();
        defer app.finishUpdate();
        return f(ctx, app);
    }

    pub fn pushEffect(app: *App, effect: Effect) void {
        switch (effect) {
            .notify => |id| {
                const gop = app.pending_notifications.getOrPut(app.gpa, id) catch @panic("OOM");
                if (gop.found_existing) return;
            },
            .notify_global_observers => |k| {
                const gop = app.pending_global_notifications.getOrPut(app.gpa, k) catch @panic("OOM");
                if (gop.found_existing) return;
            },
            else => {},
        }
        app.pending_effects.pushBack(app.gpa, effect) catch @panic("OOM");
    }

    fn flushEffects(app: *App) void {
        while (true) {
            app.releaseDroppedEntities();
            if (app.pending_effects.popFront()) |effect| {
                switch (effect) {
                    .notify => |id| app.applyNotify(id),
                    .emit => |e| app.applyEmit(e.emitter, e.event_type, e.event),
                    .refresh_windows => {}, // window phase
                    .notify_global_observers => |k| app.applyNotifyGlobal(k),
                    .deferred => |d| {
                        var cb = d;
                        cb.func(&cb.cap, app);
                        cb.deinit(app.gpa);
                    },
                    .activate => |a| switch (a.set) {
                        .observers => app.observers.activate(a.key, a.id),
                        .event_listeners => app.event_listeners.activate(a.key, a.id),
                        .global_observers => app.global_observers.activate(a.key, a.id),
                    },
                    .entity_created => |e| app.applyEntityCreated(e),
                }
            } else if (app.pending_effects.len == 0) {
                // (window phase: draw dirty windows in tests here, like gpui)
                _ = app.event_arena.reset(.retain_capacity);
                break;
            }
        }
    }

    fn releaseDroppedEntities(app: *App) void {
        var dropped: std.ArrayList(entity_mod.Dropped) = .empty;
        defer dropped.deinit(app.gpa);
        var listeners: std.ArrayList(ReleaseListener) = .empty;
        defer listeners.deinit(app.gpa);
        while (true) {
            dropped.clearRetainingCapacity();
            app.entities.takeDropped(&dropped) catch @panic("OOM");
            if (dropped.items.len == 0) break;
            for (dropped.items) |d| {
                const key = d.id.toKey();
                app.observers.remove(key, null);
                app.event_listeners.remove(key, null);
                app.executor.cancelOwnedBy(key);
                _ = app.pending_notifications.remove(d.id);
                listeners.clearRetainingCapacity();
                app.release_listeners.remove(key, &listeners);
                const ptr = d.ptr orelse {
                    for (listeners.items) |*l| l.deinit(app.gpa);
                    continue;
                };
                for (listeners.items) |*l| {
                    l.func(&l.cap, ptr, app);
                    l.deinit(app.gpa);
                }
                d.vtable.destroy(ptr, app);
            }
        }
    }

    fn applyNotify(app: *App, id: EntityId) void {
        _ = app.pending_notifications.remove(id);
        app.observers.retain(id.toKey(), app, struct {
            fn call(a: *App, h: *Handler) bool {
                return h.func(&h.cap, a);
            }
        }.call);
    }

    fn applyEmit(app: *App, emitter: EntityId, event_type: TypeId, event: *const anyopaque) void {
        const Ctx = struct { app: *App, event_type: TypeId, event: *const anyopaque };
        var ctx: Ctx = .{ .app = app, .event_type = event_type, .event = event };
        app.event_listeners.retain(emitter.toKey(), &ctx, struct {
            fn call(c: *Ctx, l: *Listener) bool {
                if (l.event_type != c.event_type) return true;
                return l.func(&l.cap, c.event, c.app);
            }
        }.call);
    }

    fn applyNotifyGlobal(app: *App, k: u64) void {
        _ = app.pending_global_notifications.remove(k);
        app.global_observers.retain(k, app, struct {
            fn call(a: *App, h: *Handler) bool {
                return h.func(&h.cap, a);
            }
        }.call);
    }

    fn applyEntityCreated(app: *App, e: AnyEntity) void {
        const Ctx = struct { app: *App, e: AnyEntity };
        var ctx: Ctx = .{ .app = app, .e = e };
        app.new_entity_observers.retain(type_id.key(e.type_id), &ctx, struct {
            fn call(c: *Ctx, l: *NewEntityListener) bool {
                if (c.app.entities.isAlive(c.e.id)) l.func(&l.cap, c.e, c.app);
                return true;
            }
        }.call);
        e.release(app);
    }

    // ---- entities --------------------------------------------------------------------

    /// Create an entity from a ready value. Returns an owned strong handle.
    pub fn new(app: *App, comptime T: type, value: T) Allocator.Error!Entity(T) {
        const Build = struct {
            fn build(v: T, _: *Context(T)) T {
                return v;
            }
        };
        return app.newWith(T, Build.build, .{value});
    }

    /// Create an entity by calling `build(args..., cx: *Context(T)) T` (or `!T`). The
    /// context lets the constructor observe/subscribe before the entity exists, as in gpui.
    pub fn newWith(app: *App, comptime T: type, comptime build: anytype, args: anytype) BuildError(build)!Entity(T) {
        app.startUpdate();
        defer app.finishUpdate();
        const id = try app.entities.reserve(T);
        errdefer app.entities.release(id);
        const ptr = try app.gpa.create(T);
        errdefer app.gpa.destroy(ptr);
        var cx: Context(T) = .{ .app = app, .entity_id = id };
        const result = @call(.auto, build, args ++ .{&cx});
        ptr.* = if (comptime isErrorUnion(@TypeOf(result))) try result else result;
        app.entities.insert(id, ptr);
        app.entities.retain(id);
        app.pushEffect(.{ .entity_created = .{ .id = id, .type_id = typeId(T) } });
        return .{ .id = id };
    }

    /// Mark an entity as changed; its observers run at the end of the update.
    pub fn notify(app: *App, id: EntityId) void {
        // Window phase: invalidate windows that rendered `id` (gpui `window_invalidators_by_entity`).
        app.startUpdate();
        defer app.finishUpdate();
        app.pushEffect(.{ .notify = id });
    }

    /// Schedule all windows to be redrawn (no-op until the window phase).
    pub fn refreshWindows(app: *App) void {
        app.pushEffect(.refresh_windows);
    }

    pub fn newObserver(app: *App, emitter: EntityId, handler: Handler) Allocator.Error!Subscription {
        app.startUpdate();
        defer app.finishUpdate();
        const ins = try app.observers.insert(emitter.toKey(), handler);
        app.pushEffect(.{ .activate = .{ .set = .observers, .key = emitter.toKey(), .id = ins.id } });
        return ins.subscription;
    }

    pub fn newSubscription(app: *App, emitter: EntityId, listener: Listener) Allocator.Error!Subscription {
        app.startUpdate();
        defer app.finishUpdate();
        const ins = try app.event_listeners.insert(emitter.toKey(), listener);
        app.pushEffect(.{ .activate = .{ .set = .event_listeners, .key = emitter.toKey(), .id = ins.id } });
        return ins.subscription;
    }

    /// Release listeners are active immediately (gpui).
    pub fn newReleaseListener(app: *App, id: EntityId, listener: ReleaseListener) Allocator.Error!Subscription {
        const ins = try app.release_listeners.insert(id.toKey(), listener);
        app.release_listeners.activate(id.toKey(), ins.id);
        return ins.subscription;
    }

    /// `f(ctx, observed: Entity(W), app)` after each `notify` of `entity`.
    pub fn observe(app: *App, entity: anytype, ctx: anytype, comptime f: anytype) Allocator.Error!Subscription {
        const W = @TypeOf(entity).Type;
        const C = @TypeOf(ctx);
        const Gen = struct {
            fn call(cap: *const Captures, a: *App) bool {
                const observed: Entity(W) = .{ .id = .fromKey(cap.a) };
                if (!a.entities.isAlive(observed.id)) return false;
                f(unwrapCtx(C, cap), observed, a);
                return true;
            }
        };
        var cap = wrapCtx(ctx);
        cap.a = entity.id.toKey();
        return app.newObserver(entity.id, .{ .func = Gen.call, .cap = cap });
    }

    /// `f(ctx, emitter: Entity(E), event: *const Ev, app)` for each `Ev` emitted by `entity`.
    pub fn subscribe(app: *App, entity: anytype, ctx: anytype, comptime f: anytype) Allocator.Error!Subscription {
        const E = @TypeOf(entity).Type;
        const C = @TypeOf(ctx);
        const Ev = @typeInfo(@typeInfo(@TypeOf(f)).@"fn".param_types[2].?).pointer.child;
        comptime assertEmits(E, Ev);
        const Gen = struct {
            fn call(cap: *const Captures, event: *const anyopaque, a: *App) bool {
                const emitter: Entity(E) = .{ .id = .fromKey(cap.a) };
                if (!a.entities.isAlive(emitter.id)) return false;
                f(unwrapCtx(C, cap), emitter, @as(*const Ev, @ptrCast(@alignCast(event))), a);
                return true;
            }
        };
        var cap = wrapCtx(ctx);
        cap.a = entity.id.toKey();
        return app.newSubscription(entity.id, .{ .event_type = typeId(Ev), .func = Gen.call, .cap = cap });
    }

    /// `f(ctx, value: *W, app)` when `entity` is released, before it is destroyed.
    pub fn observeRelease(app: *App, entity: anytype, ctx: anytype, comptime f: anytype) Allocator.Error!Subscription {
        const W = @TypeOf(entity).Type;
        const C = @TypeOf(ctx);
        const Gen = struct {
            fn call(cap: *const Captures, value: *anyopaque, a: *App) void {
                f(unwrapCtx(C, cap), @as(*W, @ptrCast(@alignCast(value))), a);
            }
        };
        return app.newReleaseListener(entity.id, .{ .func = Gen.call, .cap = wrapCtx(ctx) });
    }

    /// `f(ctx, value: *T, cx: *Context(T))` whenever an entity of type `T` is created.
    /// Active immediately (gpui `observe_new`).
    pub fn observeNew(app: *App, comptime T: type, ctx: anytype, comptime f: anytype) Allocator.Error!Subscription {
        const C = @TypeOf(ctx);
        const Gen = struct {
            fn call(cap: *const Captures, e: AnyEntity, a: *App) void {
                const typed = e.downcast(T).?;
                typed.update(a, inner, .{unwrapCtx(C, cap)});
            }
            fn inner(value: *T, c: C, cx: *Context(T)) void {
                f(c, value, cx);
            }
        };
        const k = type_id.key(typeId(T));
        const ins = try app.new_entity_observers.insert(k, .{ .func = Gen.call, .cap = wrapCtx(ctx) });
        app.new_entity_observers.activate(k, ins.id);
        return ins.subscription;
    }

    /// Run `f(ctx, app)` at the end of the current effect cycle (gpui `defer`).
    pub fn deferFn(app: *App, ctx: anytype, comptime f: anytype) void {
        const C = @TypeOf(ctx);
        const Gen = struct {
            fn call(cap: *const Captures, a: *App) void {
                f(unwrapCtx(C, cap), a);
            }
        };
        app.deferCallback(.{ .func = Gen.call, .cap = wrapCtx(ctx) });
    }

    pub fn deferCallback(app: *App, d: Deferred) void {
        app.startUpdate();
        defer app.finishUpdate();
        app.pushEffect(.{ .deferred = d });
    }

    // ---- globals ---------------------------------------------------------------------

    /// Set (or replace) the global of type `@TypeOf(value)`; notifies global observers.
    pub fn setGlobal(app: *App, value: anytype) Allocator.Error!void {
        const G = @TypeOf(value);
        const k = type_id.key(typeId(G));
        app.startUpdate();
        defer app.finishUpdate();
        const gop = try app.globals.getOrPut(app.gpa, k);
        if (gop.found_existing) {
            if (gop.value_ptr.leased) std.debug.panic("cannot set global {s} while it is being updated", .{@typeName(G)});
            const p: *G = @ptrCast(@alignCast(gop.value_ptr.ptr));
            entity_mod.callDeinit(G, p, app);
            p.* = value;
        } else {
            const p = app.gpa.create(G) catch |err| {
                app.globals.removeByPtr(gop.key_ptr);
                return err;
            };
            p.* = value;
            gop.value_ptr.* = .{ .ptr = p, .vtable = globalVTable(G) };
        }
        app.pushEffect(.{ .notify_global_observers = k });
    }

    pub fn hasGlobal(app: *App, comptime G: type) bool {
        return app.globals.contains(type_id.key(typeId(G)));
    }

    pub fn tryGlobal(app: *App, comptime G: type) ?*const G {
        const s = app.globals.getPtr(type_id.key(typeId(G))) orelse return null;
        if (s.leased) std.debug.panic("cannot read global {s} while it is being updated", .{@typeName(G)});
        return @ptrCast(@alignCast(s.ptr));
    }

    /// Panics if no global of type `G` was set.
    pub fn global(app: *App, comptime G: type) *const G {
        return app.tryGlobal(G) orelse std.debug.panic("no global of type {s} exists", .{@typeName(G)});
    }

    /// Mutable access; queues a global-observer notification (gpui `global_mut`).
    pub fn globalMut(app: *App, comptime G: type) *G {
        const k = type_id.key(typeId(G));
        const s = app.globals.getPtr(k) orelse std.debug.panic("no global of type {s} exists", .{@typeName(G)});
        if (s.leased) std.debug.panic("cannot access global {s} while it is being updated", .{@typeName(G)});
        app.startUpdate();
        defer app.finishUpdate();
        app.pushEffect(.{ .notify_global_observers = k });
        return @ptrCast(@alignCast(s.ptr));
    }

    /// Lease the global and call `f(ctx, global: *G, app)`; notifies observers afterwards.
    pub fn updateGlobal(app: *App, comptime G: type, ctx: anytype, comptime f: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        const k = type_id.key(typeId(G));
        app.startUpdate();
        defer app.finishUpdate();
        const s = app.globals.getPtr(k) orelse std.debug.panic("no global of type {s} exists", .{@typeName(G)});
        if (s.leased) std.debug.panic("cannot update global {s} while it is already being updated", .{@typeName(G)});
        s.leased = true;
        const ptr: *G = @ptrCast(@alignCast(s.ptr));
        defer {
            // Re-lookup: `f` may have added globals and rehashed the map.
            app.globals.getPtr(k).?.leased = false;
            app.pushEffect(.{ .notify_global_observers = k });
        }
        return f(ctx, ptr, app);
    }

    /// Remove and return the global (does not run its deinit). Notifies observers.
    pub fn removeGlobal(app: *App, comptime G: type) ?G {
        const k = type_id.key(typeId(G));
        const kv = app.globals.fetchRemove(k) orelse return null;
        if (kv.value.leased) std.debug.panic("cannot remove global {s} while it is being updated", .{@typeName(G)});
        const p: *G = @ptrCast(@alignCast(kv.value.ptr));
        const value = p.*;
        app.gpa.destroy(p);
        app.startUpdate();
        defer app.finishUpdate();
        app.pushEffect(.{ .notify_global_observers = k });
        return value;
    }

    /// `f(ctx, app)` after each change of global `G`. Activated at the end of the update.
    pub fn observeGlobal(app: *App, comptime G: type, ctx: anytype, comptime f: anytype) Allocator.Error!Subscription {
        const C = @TypeOf(ctx);
        const Gen = struct {
            fn call(cap: *const Captures, a: *App) bool {
                f(unwrapCtx(C, cap), a);
                return true;
            }
        };
        return app.newGlobalObserver(G, .{ .func = Gen.call, .cap = wrapCtx(ctx) });
    }

    pub fn newGlobalObserver(app: *App, comptime G: type, handler: Handler) Allocator.Error!Subscription {
        const k = type_id.key(typeId(G));
        app.startUpdate();
        defer app.finishUpdate();
        const ins = try app.global_observers.insert(k, handler);
        app.pushEffect(.{ .activate = .{ .set = .global_observers, .key = k, .id = ins.id } });
        return ins.subscription;
    }

    // ---- keymap ----------------------------------------------------------------------

    /// Add bindings, e.g. `try app.bindKeys(&.{ .init("cmd-z", Undo{}, "Editor") })`.
    pub fn bindKeys(app: *App, specs: []const keymap_mod.BindingSpec) !void {
        try app.keymap.addSpecs(specs);
    }
};

fn isErrorUnion(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

fn BuildError(comptime build: anytype) type {
    const R = @typeInfo(@TypeOf(build)).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .error_union => |eu| eu.error_set || Allocator.Error,
        else => Allocator.Error,
    };
}

/// Whether entity type `E` declares that it emits `Ev` (gpui `EventEmitter<Ev>`), via
/// `pub const Events = .{ A, B }` or `pub const Event = A`.
pub fn emits(comptime E: type, comptime Ev: type) bool {
    if (@hasDecl(E, "Events")) {
        inline for (E.Events) |T| if (T == Ev) return true;
    }
    if (@hasDecl(E, "Event")) {
        if (E.Event == Ev) return true;
    }
    return false;
}

pub fn assertEmits(comptime E: type, comptime Ev: type) void {
    if (!emits(E, Ev)) @compileError(@typeName(E) ++ " does not emit " ++ @typeName(Ev) ++
        "; declare `pub const Events = .{" ++ @typeName(Ev) ++ "};`");
}
