//! zpui port shims: Zig 0.16 -> 0.17 std/language API differences used by
//! the vendored libghostty-vt sources. Every call site that uses one of
//! these was rewritten mechanically (see vendor/ghostty-vt/PORTING.md and
//! tools/port017.py), so the rest of each upstream file is unchanged.
const std = @import("std");
const Type = std.builtin.Type;
const Allocator = std.mem.Allocator;

/// 0.16 `std.builtin.Type.StructField` shape.
pub const StructField = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque,
    is_comptime: bool,
    /// null = natural alignment (as in 0.16).
    alignment: ?usize,

    /// 0.16 `StructField.Attributes` (argument type of `@Struct`).
    pub const Attributes = Type.Struct.FieldAttributes;

    pub inline fn defaultValue(comptime sf: StructField) ?sf.type {
        const dp: *const sf.type = @ptrCast(@alignCast(sf.default_value_ptr orelse return null));
        return dp.*;
    }
};

/// 0.16 `std.builtin.Type.EnumField` shape.
pub const EnumField = struct {
    name: [:0]const u8,
    value: comptime_int,
};

/// 0.16 `std.builtin.Type.UnionField` shape.
pub const UnionField = struct {
    name: [:0]const u8,
    type: type,
    /// null = natural alignment (as in 0.16).
    alignment: ?usize,

    /// 0.16 `UnionField.Attributes` (argument type of `@Union`).
    pub const Attributes = Type.Union.FieldAttributes;
};

pub const Declaration = struct {
    name: [:0]const u8,
};

fn FieldsResult(comptime Info: type) type {
    return switch (Info) {
        Type.Struct => []const StructField,
        Type.Enum => []const EnumField,
        Type.Union => []const UnionField,
        else => @compileError("zig017.fields: unsupported info type " ++ @typeName(Info)),
    };
}

/// Replacement for the 0.16 `info.fields` slice on struct/enum/union type
/// info (0.17 split it into `field_names`/`field_types`/`field_attrs`...).
pub inline fn fields(comptime info: anytype) FieldsResult(@TypeOf(info)) {
    const Info = @TypeOf(info);
    comptime {
        switch (Info) {
            Type.Struct => {
                var out: [info.field_names.len]StructField = undefined;
                for (&out, info.field_names, info.field_types, info.field_attrs) |*o, n, t, a| {
                    o.* = .{
                        .name = n,
                        .type = t,
                        .default_value_ptr = a.default_value_ptr,
                        .is_comptime = a.@"comptime",
                        .alignment = a.@"align",
                    };
                }
                const final = out;
                return &final;
            },
            Type.Enum => {
                var out: [info.field_names.len]EnumField = undefined;
                for (&out, info.field_names, info.field_values) |*o, n, v| o.* = .{ .name = n, .value = v };
                const final = out;
                return &final;
            },
            Type.Union => {
                var out: [info.field_names.len]UnionField = undefined;
                for (&out, info.field_names, info.field_types, info.field_attrs) |*o, n, t, a| {
                    o.* = .{
                        .name = n,
                        .type = t,
                        .alignment = a.@"align",
                    };
                }
                const final = out;
                return &final;
            },
            else => unreachable,
        }
    }
}

/// Replacement for the 0.16 `info.decls` slice.
pub inline fn decls(comptime info: anytype) []const Declaration {
    comptime {
        var out: [info.decl_names.len]Declaration = undefined;
        for (&out, info.decl_names) |*o, n| o.* = .{ .name = n };
        const final = out;
        return &final;
    }
}

/// 0.16 `std.builtin.Type.Fn.Param` shape.
pub const Param = struct {
    is_generic: bool,
    is_noalias: bool,
    type: ?type,
};

/// Replacement for the 0.16 `fn_info.params` slice.
pub inline fn params(comptime info: Type.Fn) []const Param {
    comptime {
        var out: [info.param_types.len]Param = undefined;
        for (&out, info.param_types, info.param_attrs) |*o, t, a| {
            o.* = .{ .is_generic = t == null, .is_noalias = a.@"noalias", .type = t };
        }
        const final = out;
        return &final;
    }
}

/// Replacement for 0.16 `std.fmt.bufPrintZ`.
pub fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype) std.fmt.BufPrintError![:0]u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0);
}

/// Replacement for 0.16 `std.heap.stackFallback` (removed in 0.17; the
/// closest std type is `std.heap.BufferFirstAllocator`, which does not own
/// its buffer). Same usage: `var sfa = stackFallback(n, gpa); const a = sfa.get();`
pub fn stackFallback(comptime size: usize, fallback_allocator: Allocator) StackFallbackAllocator(size) {
    return .{
        .buffer = undefined,
        .fallback_allocator = fallback_allocator,
        .impl = undefined,
    };
}

pub fn StackFallbackAllocator(comptime size: usize) type {
    return struct {
        const Self = @This();

        buffer: [size]u8,
        fallback_allocator: Allocator,
        impl: std.heap.BufferFirstAllocator,

        /// Resets the stack buffer each time it is called, like 0.16.
        pub fn get(self: *Self) Allocator {
            self.impl = .init(&self.buffer, self.fallback_allocator);
            return self.impl.allocator();
        }
    };
}

/// Replacement for 0.16 `std.heap.memory_pool.Managed(T)` (removed in
/// 0.17): an unmanaged `std.heap.MemoryPool(T)` bundled with its allocator.
pub fn ManagedMemoryPool(comptime Item: type) type {
    return struct {
        const Self = @This();
        const Pool = std.heap.MemoryPool(Item);
        pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

        pool: Pool,
        allocator: Allocator,

        pub fn init(allocator: Allocator) Self {
            return .{ .pool = .empty, .allocator = allocator };
        }

        pub fn initCapacity(allocator: Allocator, num: usize) Allocator.Error!Self {
            return .{ .pool = try .initCapacity(allocator, num), .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn reset(self: *Self, mode: ResetMode) bool {
            return self.pool.reset(self.allocator, mode);
        }

        pub fn create(self: *Self) Allocator.Error!*Item {
            return self.pool.create(self.allocator);
        }

        pub fn destroy(self: *Self, ptr: *Item) void {
            self.pool.destroy(@alignCast(ptr));
        }
    };
}

/// Replacement for 0.16 `std.meta.fields(T)` (a compile error in 0.17).
pub inline fn metaFields(comptime T: type) switch (@typeInfo(T)) {
    .@"struct" => []const StructField,
    .@"enum" => []const EnumField,
    .@"union" => []const UnionField,
    else => @compileError("metaFields: unsupported type " ++ @typeName(T)),
} {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| fields(info),
        .@"enum" => |info| fields(info),
        .@"union" => |info| fields(info),
        else => unreachable,
    };
}
