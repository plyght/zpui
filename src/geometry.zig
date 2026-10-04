//! Core geometry types. Logical pixels are `f32`; device pixels are scaled by the window's scale factor.

const std = @import("std");

pub const Pixels = f32;
/// Logical pixels multiplied by the window scale factor (what the GPU sees).
pub const ScaledPixels = f32;
/// Integer physical pixels (texture/atlas coordinates, viewport sizes).
pub const DevicePixels = i32;

pub fn Point(comptime T: type) type {
    return extern struct {
        x: T,
        y: T,

        const Self = @This();
        pub const zero: Self = .{ .x = 0, .y = 0 };

        pub fn add(a: Self, b: Self) Self {
            return .{ .x = a.x + b.x, .y = a.y + b.y };
        }
        pub fn sub(a: Self, b: Self) Self {
            return .{ .x = a.x - b.x, .y = a.y - b.y };
        }
        pub fn scale(a: Self, s: T) Self {
            return .{ .x = a.x * s, .y = a.y * s };
        }
    };
}

pub fn Size(comptime T: type) type {
    return extern struct {
        width: T,
        height: T,

        const Self = @This();
        pub const zero: Self = .{ .width = 0, .height = 0 };

        pub fn scale(a: Self, s: T) Self {
            return .{ .width = a.width * s, .height = a.height * s };
        }
    };
}

pub fn Bounds(comptime T: type) type {
    return extern struct {
        origin: Point(T),
        size: Size(T),

        const Self = @This();

        pub fn fromCorners(top_left: Point(T), bottom_right: Point(T)) Self {
            return .{
                .origin = top_left,
                .size = .{ .width = bottom_right.x - top_left.x, .height = bottom_right.y - top_left.y },
            };
        }
        pub fn right(self: Self) T {
            return self.origin.x + self.size.width;
        }
        pub fn bottom(self: Self) T {
            return self.origin.y + self.size.height;
        }
        pub fn contains(self: Self, p: Point(T)) bool {
            return p.x >= self.origin.x and p.x < self.right() and p.y >= self.origin.y and p.y < self.bottom();
        }
        pub fn intersect(a: Self, b: Self) Self {
            const x0 = @max(a.origin.x, b.origin.x);
            const y0 = @max(a.origin.y, b.origin.y);
            const x1 = @max(x0, @min(a.right(), b.right()));
            const y1 = @max(y0, @min(a.bottom(), b.bottom()));
            return fromCorners(.{ .x = x0, .y = y0 }, .{ .x = x1, .y = y1 });
        }
        pub fn isEmpty(self: Self) bool {
            return self.size.width <= 0 or self.size.height <= 0;
        }
        /// True if the two bounds overlap with non-zero area (edges touching do not count).
        pub fn intersects(a: Self, b: Self) bool {
            return a.origin.x < b.right() and a.right() > b.origin.x and
                a.origin.y < b.bottom() and a.bottom() > b.origin.y;
        }
        /// Smallest bounds containing both `a` and `b`.
        pub fn unionWith(a: Self, b: Self) Self {
            return fromCorners(
                .{ .x = @min(a.origin.x, b.origin.x), .y = @min(a.origin.y, b.origin.y) },
                .{ .x = @max(a.right(), b.right()), .y = @max(a.bottom(), b.bottom()) },
            );
        }
        /// Multiplies origin and size by `s` (e.g. logical -> scaled pixels).
        pub fn scale(self: Self, s: T) Self {
            return .{ .origin = self.origin.scale(s), .size = self.size.scale(s) };
        }
    };
}

pub fn Edges(comptime T: type) type {
    return extern struct {
        top: T,
        right: T,
        bottom: T,
        left: T,

        const Self = @This();
        pub fn all(v: T) Self {
            return .{ .top = v, .right = v, .bottom = v, .left = v };
        }
    };
}

pub fn Corners(comptime T: type) type {
    return extern struct {
        top_left: T,
        top_right: T,
        bottom_right: T,
        bottom_left: T,

        const Self = @This();
        pub fn all(v: T) Self {
            return .{ .top_left = v, .top_right = v, .bottom_right = v, .bottom_left = v };
        }
    };
}

test "bounds intersect" {
    const B = Bounds(f32);
    const a: B = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 10, .height = 10 } };
    const b: B = .{ .origin = .{ .x = 5, .y = 5 }, .size = .{ .width = 10, .height = 10 } };
    const c = a.intersect(b);
    try std.testing.expectEqual(@as(f32, 5), c.size.width);
    try std.testing.expect(a.contains(.{ .x = 1, .y = 1 }));
}
