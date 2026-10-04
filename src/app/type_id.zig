//! Runtime type identity (gpui `TypeId`), used to key globals, events, actions and
//! type-erased entity storage. Comptime-known, comparable with `==`.

const std = @import("std");

/// Opaque, process-unique id for a Zig type. Obtained with `typeId(T)`.
pub const TypeId = *const anyopaque;

pub fn typeId(comptime T: type) TypeId {
    return @ptrCast(&Holder(T).byte);
}

/// Map key for a TypeId.
pub fn key(id: TypeId) u64 {
    return @intFromPtr(id);
}

fn Holder(comptime T: type) type {
    return struct {
        // Referencing T makes each instantiation (and thus `byte`'s address) unique per type.
        comptime {
            _ = T;
        }
        var byte: u8 = 0;
    };
}

/// Short type name for diagnostics (`@typeName` without the namespace path).
pub fn shortName(comptime T: type) []const u8 {
    const full = @typeName(T);
    const idx = std.mem.findScalarLast(u8, full, '.') orelse return full;
    return full[idx + 1 ..];
}

test "TypeId is unique per type and stable" {
    const A = struct { a: u8 };
    const B = struct { a: u8 };
    try std.testing.expect(typeId(A) == typeId(A));
    try std.testing.expect(typeId(A) != typeId(B));
    try std.testing.expect(typeId(u32) != typeId(i32));
    const comptime_id = comptime typeId(A);
    try std.testing.expect(comptime_id == typeId(A));
    try std.testing.expectEqualStrings("u32", shortName(u32));
}
