//! `Context(T)`: the entity-scoped API handed to every entity method (gpui `Context<T>`).
//!
//! gpui closures become comptime method references. The callback's captures are just the
//! entity ids involved, so registering a callback does not allocate a closure:
//!
//! ```zig
//! const Editor = struct {
//!     buffer: Entity(Buffer),
//!     subs: Subscriptions = .{},
//!     save_task: Task(SaveResult) = .none,
//!
//!     pub fn init(buffer: Entity(Buffer), cx: *Context(Editor)) !Editor {
//!         var self: Editor = .{ .buffer = buffer.retain(cx) };
//!         try self.subs.add(cx.gpa(), try cx.observe(buffer, Editor.onBufferChanged));
//!         try self.subs.add(cx.gpa(), try cx.subscribe(buffer, Editor.onBufferEvent));
//!         return self;
//!     }
//!     fn onBufferChanged(self: *Editor, buffer: Entity(Buffer), cx: *Context(Editor)) void {
//!         _ = buffer.read(cx).len;
//!         cx.notify();
//!     }
//!     fn onBufferEvent(self: *Editor, _: Entity(Buffer), ev: *const Buffer.Edited, cx: *Context(Editor)) void { ... }
//!
//!     pub fn save(self: *Editor, cx: *Context(Editor)) !void {
//!         // `run` executes on a worker; `onSaved` re-enters on the main thread if the
//!         // editor is still alive (tasks are canceled when the entity is released).
//!         self.save_task = try cx.spawn(SaveJob{ .path = self.path }, Editor.onSaved);
//!     }
//!     fn onSaved(self: *Editor, result: SaveResult, cx: *Context(Editor)) void { ... }
//!
//!     pub fn deinit(self: *Editor, cx: *App) void {
//!         self.subs.deinit(cx.gpa);
//!         self.save_task.cancel();
//!         self.buffer.release(cx);
//!     }
//! };
//! ```
//!
//! Method signatures expected by each helper (all receive `*Context(T)` last):
//! * `observe(other, f)`        f: fn(*T, Entity(W), *Context(T)) void
//! * `subscribe(other, f)`      f: fn(*T, Entity(E), *const Ev, *Context(T)) void
//! * `observeRelease(other, f)` f: fn(*T, *W, *Context(T)) void
//! * `observeGlobal(G, f)`      f: fn(*T, *Context(T)) void
//! * `onRelease(f)`             f: fn(*T, *App) void
//! * `deferUpdate(f)`           f: fn(*T, *Context(T)) void
//! * `spawn(job, f)`            f: fn(*T, R, *Context(T)) void   (or without R if void)
//! * `timer(ns, f)`             f: fn(*T, *Context(T)) void
//! * `listener(f)`              f: fn(*T, *const Event, *Context(T)) void

const std = @import("std");
const Allocator = std.mem.Allocator;
const app_mod = @import("app.zig");
const App = app_mod.App;
const Captures = app_mod.Captures;
const Subscription = app_mod.Subscription;
const type_id = @import("type_id.zig");
const entity_mod = @import("entity.zig");
const EntityId = entity_mod.EntityId;
const Entity = entity_mod.Entity;
const WeakEntity = entity_mod.WeakEntity;
const executor = @import("executor.zig");
const Task = executor.Task;

fn paramCount(comptime f: anytype) usize {
    return @typeInfo(@TypeOf(f)).@"fn".param_types.len;
}

pub fn Context(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Type = T;

        app: *App,
        entity_id: EntityId,

        pub fn gpa(self: *const Self) Allocator {
            return self.app.gpa;
        }

        /// A new strong handle to this entity (release it when done).
        pub fn entity(self: *Self) Entity(T) {
            self.app.entities.retain(self.entity_id);
            return .{ .id = self.entity_id };
        }

        pub fn weakEntity(self: *const Self) WeakEntity(T) {
            return .{ .id = self.entity_id };
        }

        pub fn entityId(self: *const Self) EntityId {
            return self.entity_id;
        }

        /// Mark this entity changed; observers run at the end of the update (gpui `cx.notify()`).
        pub fn notify(self: *Self) void {
            self.app.notify(self.entity_id);
        }

        /// Emit an event to subscribers. `T` must list `@TypeOf(event)` in `pub const Events`.
        pub fn emit(self: *Self, event: anytype) void {
            const Ev = @TypeOf(event);
            comptime app_mod.assertEmits(T, Ev);
            const p = self.app.event_arena.allocator().create(Ev) catch @panic("OOM");
            p.* = event;
            self.app.pushEffect(.{ .emit = .{ .emitter = self.entity_id, .event_type = type_id.typeId(Ev), .event = p } });
        }

        // ---- shortcuts to App ----------------------------------------------------------

        pub fn new(self: *Self, comptime U: type, value: U) Allocator.Error!Entity(U) {
            return self.app.new(U, value);
        }

        pub fn newWith(self: *Self, comptime U: type, comptime build: anytype, args: anytype) @TypeOf(self.app.newWith(U, build, args)) {
            return self.app.newWith(U, build, args);
        }

        pub fn global(self: *Self, comptime G: type) *const G {
            return self.app.global(G);
        }

        pub fn setGlobal(self: *Self, value: anytype) Allocator.Error!void {
            return self.app.setGlobal(value);
        }

        // ---- observation ---------------------------------------------------------------

        /// Call `f(self, other, cx)` whenever `other` notifies.
        pub fn observe(self: *Self, other: anytype, comptime f: anytype) Allocator.Error!Subscription {
            const W = @TypeOf(other).Type;
            const Gen = struct {
                fn call(cap: *const Captures, a: *App) bool {
                    const observed: Entity(W) = .{ .id = .fromKey(cap.b) };
                    if (!a.entities.isAlive(observed.id)) return false;
                    const this: Entity(T) = .{ .id = .fromKey(cap.a) };
                    if (!a.entities.isAlive(this.id)) return false;
                    this.update(a, f, .{observed});
                    return true;
                }
            };
            return self.app.newObserver(other.id, .{ .func = Gen.call, .cap = .{ .a = self.entity_id.toKey(), .b = other.id.toKey() } });
        }

        /// Call `f(self, other, event, cx)` for each event of the type named by `f`'s third
        /// parameter emitted by `other`.
        pub fn subscribe(self: *Self, other: anytype, comptime f: anytype) Allocator.Error!Subscription {
            const E = @TypeOf(other).Type;
            const Ev = @typeInfo(@typeInfo(@TypeOf(f)).@"fn".param_types[2].?).pointer.child;
            comptime app_mod.assertEmits(E, Ev);
            const Gen = struct {
                fn call(cap: *const Captures, event: *const anyopaque, a: *App) bool {
                    const emitter: Entity(E) = .{ .id = .fromKey(cap.b) };
                    if (!a.entities.isAlive(emitter.id)) return false;
                    const this: Entity(T) = .{ .id = .fromKey(cap.a) };
                    if (!a.entities.isAlive(this.id)) return false;
                    this.update(a, f, .{ emitter, @as(*const Ev, @ptrCast(@alignCast(event))) });
                    return true;
                }
            };
            return self.app.newSubscription(other.id, .{
                .event_type = type_id.typeId(Ev),
                .func = Gen.call,
                .cap = .{ .a = self.entity_id.toKey(), .b = other.id.toKey() },
            });
        }

        /// Observe this entity's own notifications.
        pub fn observeSelf(self: *Self, comptime f: fn (*T, *Self) void) Allocator.Error!Subscription {
            const Gen = struct {
                fn call(this: *T, _: Entity(T), cx: *Self) void {
                    f(this, cx);
                }
            };
            return self.observe(Entity(T){ .id = self.entity_id }, Gen.call);
        }

        /// Call `f(self, released_value, cx)` when `other` is released (before destruction).
        pub fn observeRelease(self: *Self, other: anytype, comptime f: anytype) Allocator.Error!Subscription {
            const W = @TypeOf(other).Type;
            const Gen = struct {
                fn call(cap: *const Captures, value: *anyopaque, a: *App) void {
                    const this: Entity(T) = .{ .id = .fromKey(cap.a) };
                    if (!a.entities.isAlive(this.id)) return;
                    this.update(a, f, .{@as(*W, @ptrCast(@alignCast(value)))});
                }
            };
            return self.app.newReleaseListener(other.id, .{ .func = Gen.call, .cap = .{ .a = self.entity_id.toKey() } });
        }

        /// Call `f(self, app)` when this entity is released, before it is destroyed.
        pub fn onRelease(self: *Self, comptime f: fn (*T, *App) void) Allocator.Error!Subscription {
            const Gen = struct {
                fn call(_: *const Captures, value: *anyopaque, a: *App) void {
                    f(@ptrCast(@alignCast(value)), a);
                }
            };
            return self.app.newReleaseListener(self.entity_id, .{ .func = Gen.call });
        }

        /// Call `f(self, cx)` whenever global `G` changes.
        pub fn observeGlobal(self: *Self, comptime G: type, comptime f: fn (*T, *Self) void) Allocator.Error!Subscription {
            const Gen = struct {
                fn call(cap: *const Captures, a: *App) bool {
                    const this: Entity(T) = .{ .id = .fromKey(cap.a) };
                    if (!a.entities.isAlive(this.id)) return false;
                    this.update(a, f, .{});
                    return true;
                }
            };
            return self.app.newGlobalObserver(G, .{ .func = Gen.call, .cap = .{ .a = self.entity_id.toKey() } });
        }

        /// Run `f(self, cx)` at the end of the current effect cycle, if still alive.
        pub fn deferUpdate(self: *Self, comptime f: fn (*T, *Self) void) void {
            const Gen = struct {
                fn call(cap: *const Captures, a: *App) void {
                    const this: WeakEntity(T) = .{ .id = .fromKey(cap.a) };
                    _ = this.update(a, f, .{});
                }
            };
            self.app.deferCallback(.{ .func = Gen.call, .cap = .{ .a = self.entity_id.toKey() } });
        }

        // ---- async -----------------------------------------------------------------------

        /// Run `job.run()` on a background worker (if `job` has one), then `f(self, result, cx)`
        /// on the main thread. Owned by this entity: canceled automatically on release.
        /// `job` follows the executor job protocol (`run`, optional `discard`/`deinit`); it
        /// must not touch the App from `run`.
        pub fn spawn(self: *Self, job: anytype, comptime f: anytype) Allocator.Error!Task(executor.JobResult(@TypeOf(job))) {
            const Job = EntityJob(@TypeOf(job), f);
            return self.app.executor.spawn(Job{ .job = job, .app = self.app, .id = self.entity_id }, .{ .background = .medium }, self.entity_id.toKey());
        }

        /// Run `f(self, cx)` on the main thread after `delay_ns` (0 = next loop iteration).
        /// Owned by this entity.
        pub fn timer(self: *Self, delay_ns: u64, comptime f: fn (*T, *Self) void) Allocator.Error!Task(void) {
            const Job = EntityJob(struct {}, f);
            const mode: executor.Executor.SpawnMode = if (delay_ns == 0) .foreground else .{ .after_ns = delay_ns };
            return self.app.executor.spawn(Job{ .job = .{}, .app = self.app, .id = self.entity_id }, mode, self.entity_id.toKey());
        }

        fn EntityJob(comptime J: type, comptime f: anytype) type {
            const R = executor.JobResult(J);
            const has_run = executor.hasFn(J, "run");
            const run_token = has_run and paramCount(J.run) == 2;
            return struct {
                const Job = @This();
                job: J,
                app: *App,
                id: EntityId,

                pub const run = if (!has_run) {} else if (run_token) runToken else runPlain;
                fn runPlain(j: *Job) R {
                    return j.job.run();
                }
                fn runToken(j: *Job, token: executor.CancelToken) R {
                    return j.job.run(token);
                }

                pub fn finish(j: *Job, r: R) void {
                    const this: WeakEntity(T) = .{ .id = j.id };
                    if (!this.isAlive(j.app)) {
                        j.discard(r);
                        return;
                    }
                    if (comptime paramCount(f) == 2)
                        _ = this.update(j.app, f, .{})
                    else
                        _ = this.update(j.app, f, .{r});
                }

                pub fn discard(j: *Job, r: R) void {
                    if (comptime executor.hasFn(J, "discard")) j.job.discard(r);
                }

                pub fn deinit(j: *Job) void {
                    if (comptime executor.hasFn(J, "deinit")) j.job.deinit();
                }
            };
        }

        // ---- element listeners -----------------------------------------------------------

        /// A type-erased listener bound to this entity (gpui `cx.listener`), for elements:
        /// `div.onClick(cx.listener(Self.onClick))` with `fn onClick(*Self, *const ClickEvent, *Context(Self)) void`.
        /// The window phase adds a variant that also receives `*Window`.
        pub fn listener(self: *const Self, comptime f: anytype) Listener(EventOf(f)) {
            const Ev = EventOf(f);
            const Gen = struct {
                fn call(id: EntityId, event: *const Ev, a: *App) void {
                    const this: WeakEntity(T) = .{ .id = id };
                    _ = this.update(a, f, .{event});
                }
            };
            return .{ .entity_id = self.entity_id, .func = Gen.call };
        }

        fn EventOf(comptime f: anytype) type {
            return @typeInfo(@typeInfo(@TypeOf(f)).@"fn".param_types[1].?).pointer.child;
        }
    };
}

/// A listener produced by `Context(T).listener`. Calling it updates the bound entity if alive.
pub fn Listener(comptime Event: type) type {
    return struct {
        entity_id: EntityId,
        func: *const fn (id: EntityId, event: *const Event, app: *App) void,

        pub fn call(self: @This(), event: *const Event, app: *App) void {
            self.func(self.entity_id, event, app);
        }
    };
}
