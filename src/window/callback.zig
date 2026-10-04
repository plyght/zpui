//! Inline closure captures for frame-owned listeners.
//!
//! gpui boxes every mouse/key/action listener closure and moves the boxes between frames
//! when cached views are reused. zpui stores a function pointer plus a fixed-size inline
//! capture blob instead, so listener records are plain values: they can be copied between
//! frames, never allocate and never dangle. Captured values must be self-contained (copy
//! semantics): ids, hitboxes, handlers, pointers to element state boxes or entities.

const std = @import("std");

pub const Captures = struct {
    /// Bytes available for captured values.
    pub const size = 160;

    bytes: [size]u8 align(16) = undefined,

    pub fn init(value: anytype) Captures {
        const T = @TypeOf(value);
        comptime check(T);
        var c: Captures = .{};
        if (@sizeOf(T) > 0) @as(*T, @ptrCast(@alignCast(&c.bytes))).* = value;
        return c;
    }

    pub fn get(self: *const Captures, comptime T: type) *const T {
        comptime check(T);
        return @ptrCast(@alignCast(&self.bytes));
    }

    pub fn getMut(self: *Captures, comptime T: type) *T {
        comptime check(T);
        return @ptrCast(@alignCast(&self.bytes));
    }

    fn check(comptime T: type) void {
        if (@sizeOf(T) > size) @compileError(std.fmt.comptimePrint(
            "listener captures of type {s} are {d} bytes; the inline limit is {d}",
            .{ @typeName(T), @sizeOf(T), size },
        ));
        if (@alignOf(T) > 16) @compileError("listener capture alignment must be <= 16");
    }
};

test "captures round-trip" {
    const V = struct { a: u64, b: f32 };
    var c = Captures.init(V{ .a = 9, .b = 1.5 });
    try std.testing.expectEqual(@as(u64, 9), c.get(V).a);
    c.getMut(V).b = 2;
    const copy = c;
    try std.testing.expectEqual(@as(f32, 2), copy.get(V).b);
}
