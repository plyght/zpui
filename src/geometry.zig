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

// ---- CSS-style lengths (gpui `Rems`, `AbsoluteLength`, `DefiniteLength`, `Length`) ----

/// A length relative to the window's root font size (gpui `Rems`).
pub const Rems = struct {
    value: f32,

    pub fn toPixels(self: Rems, rem_size: Pixels) Pixels {
        return self.value * rem_size;
    }
};

/// Logical pixels (gpui `px`). `Pixels` is a plain `f32`, so this is the identity.
pub fn px(v: f32) Pixels {
    return v;
}

/// A length in rems (gpui `rems`).
pub fn rems(v: f32) Rems {
    return .{ .value = v };
}

/// A fraction of the parent's size, `1.0` == 100% (gpui `relative`).
pub fn relative(fraction: f32) DefiniteLength {
    return .{ .fraction = fraction };
}

/// The golden ratio as a relative length; gpui's default text line height.
pub fn phi() DefiniteLength {
    return relative(1.618034);
}

/// An automatically determined length (gpui `auto()`).
pub const auto: Length = .auto;

/// A length in pixels or rems (gpui `AbsoluteLength`).
pub const AbsoluteLength = union(enum) {
    pixels: Pixels,
    rems: f32,

    pub const zero: AbsoluteLength = .{ .pixels = 0 };

    /// Converts `Pixels` (any float/int), `Rems` or `AbsoluteLength`.
    pub fn from(v: anytype) AbsoluteLength {
        const T = @TypeOf(v);
        if (T == AbsoluteLength) return v;
        if (T == Rems) return .{ .rems = v.value };
        return switch (@typeInfo(T)) {
            .float, .comptime_float => .{ .pixels = v },
            .int, .comptime_int => .{ .pixels = @floatFromInt(v) },
            else => @compileError("cannot convert " ++ @typeName(T) ++ " to AbsoluteLength"),
        };
    }
    pub fn toPixels(self: AbsoluteLength, rem_size: Pixels) Pixels {
        return switch (self) {
            .pixels => |p| p,
            .rems => |r| r * rem_size,
        };
    }
    pub fn toRems(self: AbsoluteLength, rem_size: Pixels) Rems {
        return switch (self) {
            .pixels => |p| .{ .value = p / rem_size },
            .rems => |r| .{ .value = r },
        };
    }
    pub fn isZero(self: AbsoluteLength) bool {
        return switch (self) {
            inline else => |v| v == 0,
        };
    }
    pub fn neg(self: AbsoluteLength) AbsoluteLength {
        return switch (self) {
            .pixels => |p| .{ .pixels = -p },
            .rems => |r| .{ .rems = -r },
        };
    }
};

/// An absolute length or a fraction of the parent (gpui `DefiniteLength`).
pub const DefiniteLength = union(enum) {
    absolute: AbsoluteLength,
    /// `0.5` == 50%.
    fraction: f32,

    pub const zero: DefiniteLength = .{ .absolute = .zero };

    /// Converts anything `AbsoluteLength.from` accepts, or a `DefiniteLength`.
    pub fn from(v: anytype) DefiniteLength {
        if (@TypeOf(v) == DefiniteLength) return v;
        return .{ .absolute = AbsoluteLength.from(v) };
    }
    /// Resolves to pixels; fractions are taken of `base_size` (e.g. the font size for line height).
    pub fn toPixels(self: DefiniteLength, base_size: AbsoluteLength, rem_size: Pixels) Pixels {
        return switch (self) {
            .absolute => |a| a.toPixels(rem_size),
            .fraction => |f| base_size.toPixels(rem_size) * f,
        };
    }
    pub fn isZero(self: DefiniteLength) bool {
        return switch (self) {
            .absolute => |a| a.isZero(),
            .fraction => |f| f == 0,
        };
    }
    pub fn neg(self: DefiniteLength) DefiniteLength {
        return switch (self) {
            .absolute => |a| .{ .absolute = a.neg() },
            .fraction => |f| .{ .fraction = -f },
        };
    }
};

/// A definite length or `auto` (gpui `Length`).
pub const Length = union(enum) {
    definite: DefiniteLength,
    auto,

    pub const zero: Length = .{ .definite = .zero };

    /// Converts anything `DefiniteLength.from` accepts, or a `Length`.
    pub fn from(v: anytype) Length {
        if (@TypeOf(v) == Length) return v;
        if (@TypeOf(v) == @TypeOf(.auto)) return .auto;
        return .{ .definite = DefiniteLength.from(v) };
    }
    pub fn neg(self: Length) Length {
        return switch (self) {
            .definite => |d| .{ .definite = d.neg() },
            .auto => .auto,
        };
    }
};

test "length resolution" {
    try std.testing.expectEqual(@as(Pixels, 24), AbsoluteLength.from(rems(1.5)).toPixels(16));
    try std.testing.expectEqual(@as(Pixels, 7), AbsoluteLength.from(7).toPixels(16));
    try std.testing.expectEqual(@as(Pixels, 8), relative(0.5).toPixels(.{ .pixels = 16 }, 10));
    try std.testing.expectEqual(@as(Pixels, 10), relative(0.5).toPixels(.{ .rems = 2 }, 10));
    try std.testing.expectEqual(Length.auto, Length.from(auto));
    try std.testing.expectEqual(Length{ .definite = .{ .absolute = .{ .rems = -0.25 } } }, Length.from(rems(0.25)).neg());
    try std.testing.expectEqual(@as(f32, 0.5), AbsoluteLength.from(px(8)).toRems(16).value);
}
