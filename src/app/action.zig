//! Actions (gpui `action.rs`): named commands dispatched through the element tree and bound
//! to keystrokes by the keymap.
//!
//! An action type is any struct with `pub const action_name = "namespace::Name"`. Fields are
//! the action's data (they need default values to be buildable by name).
//!
//! ```zig
//! pub const Undo = action("editor::Undo");                       // unit action
//! pub const MoveLines = struct {                                 // action with data
//!     pub const action_name = "editor::MoveLines";
//!     delta: i32 = 1,
//! };
//! ```
//!
//! `AnyAction` is the type-erased, owned form stored in key bindings and dispatched to
//! listeners. Slice fields are borrowed, not deep-copied: keep them static or long-lived.

const std = @import("std");
const Allocator = std.mem.Allocator;
const type_id = @import("type_id.zig");
const TypeId = type_id.TypeId;

/// Declare a unit action type: `pub const Undo = action("editor::Undo");`.
pub fn action(comptime name: []const u8) type {
    comptime validateName(name);
    return struct {
        pub const action_name = name;
    };
}

fn validateName(comptime name: []const u8) void {
    if (std.mem.find(u8, name, "::") == null)
        @compileError("action name must look like \"namespace::Name\", got \"" ++ name ++ "\"");
}

pub fn isAction(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "action_name");
}

pub fn assertAction(comptime T: type) void {
    if (!isAction(T)) @compileError(@typeName(T) ++ " is not an action (missing `pub const action_name`)");
}

/// Special action that disables the bindings it shadows (gpui `zed::NoAction`).
pub const NoAction = action("zed::NoAction");

/// Unbinds lower-precedence bindings of the same keystrokes that dispatch the named action
/// (gpui `zed::Unbind`).
pub const Unbind = struct {
    pub const action_name = "zed::Unbind";
    target: []const u8 = "",
};

/// Structural equality: slices of `u8` compare by content, other pointers by address.
pub fn deepEql(a: anytype, b: @TypeOf(a)) bool {
    const T = @TypeOf(a);
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (@hasDecl(T, "eql")) return a.eql(b);
            inline for (s.field_names) |n| {
                if (!deepEql(@field(a, n), @field(b, n))) return false;
            }
            return true;
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return std.mem.eql(u8, a, b);
            if (p.size == .slice) {
                if (a.len != b.len) return false;
                for (a, b) |x, y| if (!deepEql(x, y)) return false;
                return true;
            }
            return a == b;
        },
        .optional => {
            if (a == null or b == null) return a == null and b == null;
            return deepEql(a.?, b.?);
        },
        .array => {
            for (a, b) |x, y| if (!deepEql(x, y)) return false;
            return true;
        },
        else => return std.meta.eql(a, b),
    }
}

pub const AnyAction = struct {
    type_id: TypeId,
    name: []const u8,
    /// Heap copy of the value; null for zero-sized actions.
    data: ?*anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        eql: *const fn (a: ?*const anyopaque, b: ?*const anyopaque) bool,
        clone: *const fn (gpa: Allocator, data: ?*const anyopaque) Allocator.Error!?*anyopaque,
        destroy: *const fn (gpa: Allocator, data: ?*anyopaque) void,
    };

    pub fn init(gpa: Allocator, value: anytype) Allocator.Error!AnyAction {
        const T = @TypeOf(value);
        comptime assertAction(T);
        const data: ?*anyopaque = if (@sizeOf(T) == 0) null else blk: {
            const p = try gpa.create(T);
            p.* = value;
            break :blk p;
        };
        return .{ .type_id = type_id.typeId(T), .name = T.action_name, .data = data, .vtable = vtableFor(T) };
    }

    pub fn deinit(self: *AnyAction, gpa: Allocator) void {
        self.vtable.destroy(gpa, self.data);
        self.data = null;
    }

    pub fn clone(self: AnyAction, gpa: Allocator) Allocator.Error!AnyAction {
        var copy = self;
        copy.data = try self.vtable.clone(gpa, self.data);
        return copy;
    }

    pub fn is(self: AnyAction, comptime T: type) bool {
        return self.type_id == type_id.typeId(T);
    }

    /// The typed value, or null if this action is not a `T`.
    pub fn downcast(self: AnyAction, comptime T: type) ?*const T {
        if (!self.is(T)) return null;
        if (@sizeOf(T) == 0) return &zst(T).value;
        return @ptrCast(@alignCast(self.data.?));
    }

    /// Same type and equal data (gpui `partial_eq`).
    pub fn eql(a: AnyAction, b: AnyAction) bool {
        return a.type_id == b.type_id and a.vtable.eql(a.data, b.data);
    }

    pub fn isNoAction(self: AnyAction) bool {
        return self.is(NoAction);
    }

    pub fn isUnbind(self: AnyAction) bool {
        return self.is(Unbind);
    }

    fn zst(comptime T: type) type {
        return struct {
            const value: T = .{};
        };
    }

    fn vtableFor(comptime T: type) *const VTable {
        return &struct {
            const vt: VTable = .{ .eql = eqlFn, .clone = cloneFn, .destroy = destroyFn };
            fn eqlFn(a: ?*const anyopaque, b: ?*const anyopaque) bool {
                if (@sizeOf(T) == 0) return true;
                const x: *const T = @ptrCast(@alignCast(a.?));
                const y: *const T = @ptrCast(@alignCast(b.?));
                return deepEql(x.*, y.*);
            }
            fn cloneFn(gpa: Allocator, data: ?*const anyopaque) Allocator.Error!?*anyopaque {
                if (@sizeOf(T) == 0) return null;
                const p = try gpa.create(T);
                p.* = @as(*const T, @ptrCast(@alignCast(data.?))).*;
                return p;
            }
            fn destroyFn(gpa: Allocator, data: ?*anyopaque) void {
                if (@sizeOf(T) == 0) return;
                gpa.destroy(@as(*T, @ptrCast(@alignCast(data orelse return))));
            }
        }.vt;
    }
};

/// Maps action names to builders (gpui `ActionRegistry`), so keymaps loaded from data can
/// refer to actions by name. Built-ins (`NoAction`, `Unbind`) are always registered.
pub const ActionRegistry = struct {
    gpa: Allocator,
    by_name: std.StringHashMapUnmanaged(Entry) = .empty,

    pub const Entry = struct {
        type_id: TypeId,
        name: []const u8,
        /// Build a default-valued instance; null if the type has fields without defaults.
        build: ?*const fn (gpa: Allocator) Allocator.Error!AnyAction,
    };

    pub fn init(gpa: Allocator) ActionRegistry {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ActionRegistry) void {
        self.by_name.deinit(self.gpa);
    }

    pub fn register(self: *ActionRegistry, comptime T: type) Allocator.Error!void {
        comptime assertAction(T);
        const Builder = struct {
            fn build(gpa: Allocator) Allocator.Error!AnyAction {
                return AnyAction.init(gpa, T{});
            }
        };
        const buildable = comptime blk: {
            const s = @typeInfo(T).@"struct";
            for (s.field_attrs) |fa| if (fa.default_value_ptr == null) break :blk false;
            break :blk true;
        };
        try self.by_name.put(self.gpa, T.action_name, .{
            .type_id = type_id.typeId(T),
            .name = T.action_name,
            .build = if (buildable) Builder.build else null,
        });
    }

    /// Register a tuple of action types: `try registry.registerAll(.{ Undo, Redo })`.
    pub fn registerAll(self: *ActionRegistry, comptime types: anytype) Allocator.Error!void {
        inline for (types) |T| try self.register(T);
    }

    pub fn get(self: *const ActionRegistry, name: []const u8) ?Entry {
        if (self.by_name.get(name)) |e| return e;
        if (std.mem.eql(u8, name, NoAction.action_name)) return builtin(NoAction);
        if (std.mem.eql(u8, name, Unbind.action_name)) return builtin(Unbind);
        return null;
    }

    fn builtin(comptime T: type) Entry {
        return .{ .type_id = type_id.typeId(T), .name = T.action_name, .build = struct {
            fn build(gpa: Allocator) Allocator.Error!AnyAction {
                return AnyAction.init(gpa, T{});
            }
        }.build };
    }

    pub const BuildError = Allocator.Error || error{ UnknownAction, ActionRequiresData };

    pub fn build(self: *const ActionRegistry, gpa: Allocator, name: []const u8) BuildError!AnyAction {
        const e = self.get(name) orelse return error.UnknownAction;
        const b = e.build orelse return error.ActionRequiresData;
        return b(gpa);
    }
};

const testing = std.testing;

const Undo = action("editor::Undo");
const MoveLines = struct {
    pub const action_name = "editor::MoveLines";
    delta: i32 = 1,
};
const Open = struct {
    pub const action_name = "workspace::Open";
    path: []const u8,
};

test "AnyAction: equality, clone, downcast" {
    const gpa = testing.allocator;
    var a = try AnyAction.init(gpa, MoveLines{ .delta = 3 });
    defer a.deinit(gpa);
    var b = try a.clone(gpa);
    defer b.deinit(gpa);
    var c = try AnyAction.init(gpa, MoveLines{ .delta = 4 });
    defer c.deinit(gpa);
    var u = try AnyAction.init(gpa, Undo{});
    defer u.deinit(gpa);

    try testing.expect(a.eql(b));
    try testing.expect(!a.eql(c));
    try testing.expect(!a.eql(u));
    try testing.expectEqual(@as(i32, 3), a.downcast(MoveLines).?.delta);
    try testing.expect(a.downcast(Undo) == null);
    try testing.expect(u.downcast(Undo) != null);
    try testing.expectEqualStrings("editor::Undo", u.name);

    var unbind1 = try AnyAction.init(gpa, Unbind{ .target = "editor::Undo" });
    defer unbind1.deinit(gpa);
    var buf: [12]u8 = "editor::Undo".*;
    var unbind2 = try AnyAction.init(gpa, Unbind{ .target = &buf });
    defer unbind2.deinit(gpa);
    try testing.expect(unbind1.eql(unbind2));
    try testing.expect(unbind1.isUnbind());
}

test "ActionRegistry builds by name" {
    const gpa = testing.allocator;
    var reg = ActionRegistry.init(gpa);
    defer reg.deinit();
    try reg.registerAll(.{ Undo, MoveLines, Open });

    var u = try reg.build(gpa, "editor::Undo");
    defer u.deinit(gpa);
    try testing.expect(u.is(Undo));
    var m = try reg.build(gpa, "editor::MoveLines");
    defer m.deinit(gpa);
    try testing.expectEqual(@as(i32, 1), m.downcast(MoveLines).?.delta);
    try testing.expectError(error.ActionRequiresData, reg.build(gpa, "workspace::Open"));
    try testing.expectError(error.UnknownAction, reg.build(gpa, "nope::Nope"));
    var n = try reg.build(gpa, "zed::NoAction");
    defer n.deinit(gpa);
    try testing.expect(n.isNoAction());
}
