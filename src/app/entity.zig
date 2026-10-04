//! Entities: app-owned, reference-counted state (gpui `entity_map.rs`).
//!
//! * Values are heap-allocated (stable addresses) and stored type-erased in a slot table
//!   with generational ids. Slots carry a `leased` flag instead of moving the value out
//!   (gpui moves the `Box` to the stack): reading or updating an entity that is currently
//!   being updated panics, exactly like gpui's `double_lease_panic`.
//! * `Entity(T)` is a strong handle, `WeakEntity(T)` a weak one. Zig has no destructors, so
//!   strong handles are counted explicitly: every handle you *own* must eventually be
//!   `release`d. Rule of thumb: functions that **return** an `Entity` (new, upgrade,
//!   retain, cx.entity()) give you a reference; handles **passed into** callbacks are borrowed.
//! * When the strong count reaches zero the id is queued; the App destroys the value at the
//!   top of the next effect-flush iteration, after calling release listeners — same order as
//!   gpui `release_dropped_entities`.
//! * An entity type may declare `pub fn deinit(self: *T, cx: *App) void` (or take an
//!   `Allocator`, or nothing) to release handles, subscriptions and tasks it owns.

const std = @import("std");
const Allocator = std.mem.Allocator;
const type_id = @import("type_id.zig");
const TypeId = type_id.TypeId;
const App = @import("app.zig").App;
const Context = @import("context.zig").Context;

/// Generational entity id (gpui `EntityId`). Never zero.
pub const EntityId = enum(u64) {
    _,

    pub fn init(index_: u32, generation_: u32) EntityId {
        return @fromBackingInt(@intCast((@as(u64, generation_) << 32) | index_));
    }
    pub fn index(id: EntityId) u32 {
        return @truncate(@backingInt(id));
    }
    pub fn generation(id: EntityId) u32 {
        return @truncate(@backingInt(id) >> 32);
    }
    pub fn toKey(id: EntityId) u64 {
        return @backingInt(id);
    }
    pub fn fromKey(k: u64) EntityId {
        return @fromBackingInt(@intCast(k));
    }
    pub fn format(id: EntityId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("EntityId({d}v{d})", .{ id.index(), id.generation() });
    }
};

/// Per-type operations for type-erased entity values.
pub const EntityVTable = struct {
    type_id: TypeId,
    type_name: []const u8,
    /// Run `T.deinit` (if any) and free the value.
    destroy: *const fn (ptr: *anyopaque, app: *App) void,
};

pub fn vtableFor(comptime T: type) *const EntityVTable {
    return &struct {
        const vt: EntityVTable = .{ .type_id = type_id.typeId(T), .type_name = @typeName(T), .destroy = destroy };
        fn destroy(ptr: *anyopaque, app: *App) void {
            const p: *T = @ptrCast(@alignCast(ptr));
            callDeinit(T, p, app);
            app.gpa.destroy(p);
        }
    }.vt;
}

/// Calls `value.deinit(...)` if `T` declares one. Accepted signatures:
/// `fn(*T) void`, `fn(*T, *App) void`, `fn(*T, Allocator) void`.
pub fn callDeinit(comptime T: type, value: *T, app: *App) void {
    switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => {},
        else => return,
    }
    if (!@hasDecl(T, "deinit")) return;
    const params = @typeInfo(@TypeOf(T.deinit)).@"fn".param_types;
    switch (params.len) {
        1 => value.deinit(),
        2 => if (params[1] == *App)
            value.deinit(app)
        else if (params[1] == Allocator)
            value.deinit(app.gpa)
        else
            @compileError(@typeName(T) ++ ".deinit must take (*T), (*T, *App) or (*T, Allocator)"),
        else => @compileError(@typeName(T) ++ ".deinit has an unsupported signature"),
    }
}

const Slot = struct {
    generation: u32 = 1,
    strong: u32 = 0,
    /// Reserved or inserted and not yet destroyed.
    live: bool = false,
    /// Being updated (or under construction).
    leased: bool = false,
    ptr: ?*anyopaque = null,
    vtable: ?*const EntityVTable = null,
};

/// An entity whose last strong handle was released; destroyed by the App.
pub const Dropped = struct {
    id: EntityId,
    ptr: ?*anyopaque,
    vtable: *const EntityVTable,
};

pub const EntityMap = struct {
    gpa: Allocator,
    slots: std.ArrayList(Slot) = .empty,
    free_list: std.ArrayList(u32) = .empty,
    dropped: std.ArrayList(EntityId) = .empty,
    /// Ids read/updated while `track_accessed` is set (view caching, window phase).
    accessed: std.AutoHashMapUnmanaged(EntityId, void) = .empty,
    track_accessed: bool = false,
    live_count: usize = 0,

    pub fn init(gpa: Allocator) EntityMap {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *EntityMap) void {
        self.slots.deinit(self.gpa);
        self.free_list.deinit(self.gpa);
        self.dropped.deinit(self.gpa);
        self.accessed.deinit(self.gpa);
    }

    /// Allocate an id with strong count 1. The slot is leased until `insert`.
    pub fn reserve(self: *EntityMap, comptime T: type) Allocator.Error!EntityId {
        try self.dropped.ensureUnusedCapacity(self.gpa, 1);
        const index: u32 = if (self.free_list.pop()) |i| i else blk: {
            try self.slots.append(self.gpa, .{});
            break :blk @intCast(self.slots.items.len - 1);
        };
        const s = &self.slots.items[index];
        s.strong = 1;
        s.live = true;
        s.leased = true;
        s.ptr = null;
        s.vtable = vtableFor(T);
        self.live_count += 1;
        return EntityId.init(index, s.generation);
    }

    pub fn insert(self: *EntityMap, id: EntityId, ptr: *anyopaque) void {
        const s = self.slotOrPanic(id, "insert");
        s.ptr = ptr;
        s.leased = false;
    }

    pub fn slot(self: *EntityMap, id: EntityId) ?*Slot {
        const i = id.index();
        if (i >= self.slots.items.len) return null;
        const s = &self.slots.items[i];
        if (!s.live or s.generation != id.generation()) return null;
        return s;
    }

    fn slotOrPanic(self: *EntityMap, id: EntityId, comptime op: []const u8) *Slot {
        return self.slot(id) orelse std.debug.panic("cannot " ++ op ++ " {f}: entity was released", .{id});
    }

    /// Alive = has a strong reference (upgradable).
    pub fn isAlive(self: *EntityMap, id: EntityId) bool {
        const s = self.slot(id) orelse return false;
        return s.strong > 0;
    }

    pub fn strongCount(self: *EntityMap, id: EntityId) u32 {
        const s = self.slot(id) orelse return 0;
        return s.strong;
    }

    pub fn typeIdOf(self: *EntityMap, id: EntityId) ?TypeId {
        const s = self.slot(id) orelse return null;
        return s.vtable.?.type_id;
    }

    pub fn retain(self: *EntityMap, id: EntityId) void {
        const s = self.slotOrPanic(id, "retain");
        std.debug.assert(s.strong > 0);
        s.strong += 1;
    }

    /// Increment-if-nonzero (gpui weak upgrade).
    pub fn tryRetain(self: *EntityMap, id: EntityId) bool {
        const s = self.slot(id) orelse return false;
        if (s.strong == 0) return false;
        s.strong += 1;
        return true;
    }

    pub fn release(self: *EntityMap, id: EntityId) void {
        const s = self.slotOrPanic(id, "release");
        if (s.strong == 0) std.debug.panic("entity {f} ({s}) released more times than retained", .{ id, s.vtable.?.type_name });
        s.strong -= 1;
        if (s.strong == 0) self.dropped.append(self.gpa, id) catch @panic("OOM");
    }

    fn checkType(s: *Slot, comptime T: type, id: EntityId) void {
        if (s.vtable.?.type_id != type_id.typeId(T))
            std.debug.panic("entity {f} is a {s}, not a {s}", .{ id, s.vtable.?.type_name, @typeName(T) });
    }

    /// Mark the entity as being updated and return its value. Panics if already leased.
    pub fn lease(self: *EntityMap, id: EntityId, comptime T: type) *T {
        const s = self.slotOrPanic(id, "update");
        checkType(s, T, id);
        if (s.leased or s.ptr == null)
            std.debug.panic("cannot update {s} while it is already being updated", .{type_id.shortName(T)});
        s.leased = true;
        self.recordAccess(id);
        return @ptrCast(@alignCast(s.ptr.?));
    }

    pub fn endLease(self: *EntityMap, id: EntityId) void {
        const s = self.slotOrPanic(id, "end lease of");
        std.debug.assert(s.leased);
        s.leased = false;
    }

    pub fn isLeased(self: *EntityMap, id: EntityId) bool {
        const s = self.slot(id) orelse return false;
        return s.leased;
    }

    /// Shared access. Panics if the entity is being updated.
    pub fn read(self: *EntityMap, id: EntityId, comptime T: type) *const T {
        const s = self.slotOrPanic(id, "read");
        checkType(s, T, id);
        if (s.leased or s.ptr == null)
            std.debug.panic("cannot read {s} while it is already being updated", .{type_id.shortName(T)});
        self.recordAccess(id);
        return @ptrCast(@alignCast(s.ptr.?));
    }

    fn recordAccess(self: *EntityMap, id: EntityId) void {
        if (self.track_accessed) self.accessed.put(self.gpa, id, {}) catch {};
    }

    /// Move entities whose strong count is still zero out of the table into `out`.
    /// Their slots become free (generation bumped) immediately.
    pub fn takeDropped(self: *EntityMap, out: *std.ArrayList(Dropped)) Allocator.Error!void {
        const ids = self.dropped.items;
        try out.ensureUnusedCapacity(self.gpa, ids.len);
        try self.free_list.ensureUnusedCapacity(self.gpa, ids.len);
        for (ids) |id| {
            const s = self.slot(id) orelse continue;
            if (s.strong != 0) continue;
            std.debug.assert(!s.leased or s.ptr == null);
            out.appendAssumeCapacity(.{ .id = id, .ptr = s.ptr, .vtable = s.vtable.? });
            s.* = .{ .generation = s.generation +% 1 };
            if (s.generation == 0) s.generation = 1;
            self.free_list.appendAssumeCapacity(id.index());
            self.live_count -= 1;
            _ = self.accessed.remove(id);
        }
        self.dropped.clearRetainingCapacity();
    }
};

/// Returns the `*App` behind any context-like value (`*App`, `*Context(T)`, ...).
pub fn appOf(cx: anytype) *App {
    const C = @TypeOf(cx);
    if (C == *App) return cx;
    const info = @typeInfo(C);
    if (info != .pointer) @compileError("expected *App or *Context(T), got " ++ @typeName(C));
    const Child = info.pointer.child;
    if (@hasField(Child, "app")) return cx.app;
    @compileError("expected *App or *Context(T), got " ++ @typeName(C));
}

fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}

/// Strong handle to an entity of type `T` (gpui `Entity<T>`).
pub fn Entity(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Type = T;

        id: EntityId,

        pub fn entityId(self: Self) EntityId {
            return self.id;
        }

        pub fn eql(a: Self, b: Self) bool {
            return a.id == b.id;
        }

        pub fn downgrade(self: Self) WeakEntity(T) {
            return .{ .id = self.id };
        }

        pub fn toAny(self: Self) AnyEntity {
            return .{ .id = self.id, .type_id = type_id.typeId(T) };
        }

        /// Take an additional strong reference (gpui `clone`).
        pub fn retain(self: Self, cx: anytype) Self {
            appOf(cx).entities.retain(self.id);
            return self;
        }

        /// Give up this strong reference (gpui `drop`).
        pub fn release(self: Self, cx: anytype) void {
            appOf(cx).entities.release(self.id);
        }

        pub fn read(self: Self, cx: anytype) *const T {
            return appOf(cx).entities.read(self.id, T);
        }

        /// Lease the entity and call `f(value, args..., cx)` where `cx: *Context(T)`.
        /// Effects are flushed when the outermost update returns.
        ///
        /// `counter.update(cx, Counter.increment, .{5})` calls
        /// `fn increment(self: *Counter, by: u32, cx: *Context(Counter)) void`.
        pub fn update(self: Self, cx: anytype, comptime f: anytype, args: anytype) ReturnOf(f) {
            const app = appOf(cx);
            app.startUpdate();
            defer app.finishUpdate();
            const value = app.entities.lease(self.id, T);
            defer app.entities.endLease(self.id);
            var ctx: Context(T) = .{ .app = app, .entity_id = self.id };
            return @call(.auto, f, .{value} ++ args ++ .{&ctx});
        }

        /// Like `update` with a separate context argument: `f(ctx, value, cx)`.
        pub fn updateWith(self: Self, cx: anytype, ctx: anytype, comptime f: anytype) ReturnOf(f) {
            const Wrap = struct {
                fn call(value: *T, c: @TypeOf(ctx), context: *Context(T)) ReturnOf(f) {
                    return f(c, value, context);
                }
            };
            return self.update(cx, Wrap.call, .{ctx});
        }

        /// This view as a cached element (see docs/elements.md): its previous frame is reused
        /// while neither it nor anything it read was notified. `style` is its outer style.
        pub fn cached(self: Self, style: @import("../style.zig").StyleRefinement) @import("../window/view.zig").AnyView {
            return @import("../window/view.zig").AnyView.fromEntity(self).cached(style);
        }

        /// Closure-free update: `var l = e.lease(cx); defer l.end(); l.value.x += 1; l.cx.notify();`
        pub fn lease(self: Self, cx: anytype) Lease(T) {
            const app = appOf(cx);
            app.startUpdate();
            return .{ .value = app.entities.lease(self.id, T), .cx = .{ .app = app, .entity_id = self.id } };
        }
    };
}

/// An active update of an entity; see `Entity.lease`.
pub fn Lease(comptime T: type) type {
    return struct {
        value: *T,
        cx: Context(T),

        /// End the lease and flush effects if this was the outermost update.
        pub fn end(self: *@This()) void {
            self.cx.app.entities.endLease(self.cx.entity_id);
            self.cx.app.finishUpdate();
        }
    };
}

/// Weak handle (gpui `WeakEntity<T>`): plain copyable value; never keeps the entity alive.
pub fn WeakEntity(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Type = T;

        id: EntityId,

        pub fn entityId(self: Self) EntityId {
            return self.id;
        }

        pub fn isAlive(self: Self, cx: anytype) bool {
            return appOf(cx).entities.isAlive(self.id);
        }

        /// A new strong reference, or null if the entity was released. Release it when done.
        pub fn upgrade(self: Self, cx: anytype) ?Entity(T) {
            if (!appOf(cx).entities.tryRetain(self.id)) return null;
            return .{ .id = self.id };
        }

        /// `Entity.update` if the entity is still alive, else null.
        pub fn update(self: Self, cx: anytype, comptime f: anytype, args: anytype) ?ReturnOf(f) {
            if (!self.isAlive(cx)) return null;
            const e: Entity(T) = .{ .id = self.id };
            return e.update(cx, f, args);
        }

        pub fn read(self: Self, cx: anytype) ?*const T {
            if (!self.isAlive(cx)) return null;
            return appOf(cx).entities.read(self.id, T);
        }
    };
}

/// Type-erased strong handle (gpui `AnyEntity`).
pub const AnyEntity = struct {
    id: EntityId,
    type_id: TypeId,

    /// Reinterpret as `Entity(T)` (no refcount change), or null on type mismatch.
    pub fn downcast(self: AnyEntity, comptime T: type) ?Entity(T) {
        if (self.type_id != type_id.typeId(T)) return null;
        return .{ .id = self.id };
    }

    pub fn retain(self: AnyEntity, cx: anytype) AnyEntity {
        appOf(cx).entities.retain(self.id);
        return self;
    }

    pub fn release(self: AnyEntity, cx: anytype) void {
        appOf(cx).entities.release(self.id);
    }

    pub fn downgrade(self: AnyEntity) AnyWeakEntity {
        return .{ .id = self.id, .type_id = self.type_id };
    }
};

pub const AnyWeakEntity = struct {
    id: EntityId,
    type_id: TypeId,

    pub fn upgrade(self: AnyWeakEntity, cx: anytype) ?AnyEntity {
        if (!appOf(cx).entities.tryRetain(self.id)) return null;
        return .{ .id = self.id, .type_id = self.type_id };
    }

    pub fn isAlive(self: AnyWeakEntity, cx: anytype) bool {
        return appOf(cx).entities.isAlive(self.id);
    }
};
