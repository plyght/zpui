//! Style types for the layout engine: the subset of CSS box, flexbox and block layout that gpui
//! drives taffy with (see zui's `style.rs` / `taffy.rs`), plus small axis-generic helpers.
//!
//! Percentages are stored as fractions (`0.5` == 50%), matching gpui's `DefiniteLength::Fraction`.

const std = @import("std");

/// A width/height pair. Unlike `geometry.Size` this is not `extern`, so it can hold optionals and
/// tagged unions.
pub fn Dims(comptime T: type) type {
    return struct {
        width: T,
        height: T,

        const Self = @This();

        pub fn all(v: T) Self {
            return .{ .width = v, .height = v };
        }
        /// Builds a pair from flex-relative components (`row` selects which axis is main).
        pub fn fromMainCross(row: bool, main_v: T, cross_v: T) Self {
            return if (row) .{ .width = main_v, .height = cross_v } else .{ .width = cross_v, .height = main_v };
        }
        pub fn main(self: Self, row: bool) T {
            return if (row) self.width else self.height;
        }
        pub fn cross(self: Self, row: bool) T {
            return if (row) self.height else self.width;
        }
        pub fn setMain(self: *Self, row: bool, v: T) void {
            if (row) self.width = v else self.height = v;
        }
        pub fn setCross(self: *Self, row: bool, v: T) void {
            if (row) self.height = v else self.width = v;
        }
    };
}

/// Top/right/bottom/left values. Non-`extern` counterpart of `geometry.Edges`.
pub fn Sides(comptime T: type) type {
    return struct {
        top: T,
        right: T,
        bottom: T,
        left: T,

        const Self = @This();

        pub fn all(v: T) Self {
            return .{ .top = v, .right = v, .bottom = v, .left = v };
        }
        /// Physical start edge of the main axis (left for rows, top for columns).
        pub fn mainStart(self: Self, row: bool) T {
            return if (row) self.left else self.top;
        }
        pub fn mainEnd(self: Self, row: bool) T {
            return if (row) self.right else self.bottom;
        }
        pub fn crossStart(self: Self, row: bool) T {
            return if (row) self.top else self.left;
        }
        pub fn crossEnd(self: Self, row: bool) T {
            return if (row) self.bottom else self.right;
        }
        pub fn setMainStart(self: *Self, row: bool, v: T) void {
            if (row) self.left = v else self.top = v;
        }
        pub fn setMainEnd(self: *Self, row: bool, v: T) void {
            if (row) self.right = v else self.bottom = v;
        }
        pub fn setCrossStart(self: *Self, row: bool, v: T) void {
            if (row) self.top = v else self.left = v;
        }
        pub fn setCrossEnd(self: *Self, row: bool, v: T) void {
            if (row) self.bottom = v else self.right = v;
        }
        pub fn horizontal(self: Self) T {
            return self.left + self.right;
        }
        pub fn vertical(self: Self) T {
            return self.top + self.bottom;
        }
        pub fn mainSum(self: Self, row: bool) T {
            return if (row) self.horizontal() else self.vertical();
        }
        pub fn crossSum(self: Self, row: bool) T {
            return if (row) self.vertical() else self.horizontal();
        }
        pub fn sum(self: Self) Dims(T) {
            return .{ .width = self.horizontal(), .height = self.vertical() };
        }
        pub fn add(a: Self, b: Self) Self {
            return .{ .top = a.top + b.top, .right = a.right + b.right, .bottom = a.bottom + b.bottom, .left = a.left + b.left };
        }
    };
}

/// The space available to a node along one axis.
pub const AvailableSpace = union(enum) {
    /// A definite number of pixels.
    definite: f32,
    /// Lay out under a min-content constraint (as narrow as possible).
    min_content,
    /// Lay out under a max-content constraint (as wide as content wants).
    max_content,

    pub fn toOption(self: AvailableSpace) ?f32 {
        return switch (self) {
            .definite => |v| v,
            else => null,
        };
    }
    pub fn isDefinite(self: AvailableSpace) bool {
        return self == .definite;
    }
    /// Subtracts `v` from a definite value; intrinsic constraints are unchanged.
    pub fn sub(self: AvailableSpace, v: f32) AvailableSpace {
        return switch (self) {
            .definite => |d| .{ .definite = d - v },
            else => self,
        };
    }
    pub fn eql(a: AvailableSpace, b: AvailableSpace) bool {
        return switch (a) {
            .definite => |v| b == .definite and b.definite == v,
            .min_content => b == .min_content,
            .max_content => b == .max_content,
        };
    }
};

/// A length that may be `auto`. Used for sizes, insets, margins and flex-basis.
pub const Length = union(enum) {
    auto,
    /// Absolute logical pixels.
    px: f32,
    /// Fraction of the relevant containing-block dimension (`0.5` == 50%).
    percent: f32,

    pub const zero: Length = .{ .px = 0 };

    /// Resolves against `basis`; `auto` and percentages of an indefinite basis yield `null`.
    pub fn resolve(self: Length, basis: ?f32) ?f32 {
        return switch (self) {
            .auto => null,
            .px => |v| v,
            .percent => |p| if (basis) |b| b * p else null,
        };
    }
    pub fn isAuto(self: Length) bool {
        return self == .auto;
    }
};

/// Sizes (`size`, `min_size`, `max_size`) use the same representation as `Length`.
pub const Dimension = Length;

/// A length that cannot be `auto`. Used for padding, border widths and gaps.
pub const LengthPercentage = union(enum) {
    px: f32,
    percent: f32,

    pub const zero: LengthPercentage = .{ .px = 0 };

    /// Resolves against `basis`; percentages of an indefinite basis resolve to zero.
    pub fn resolve(self: LengthPercentage, basis: ?f32) f32 {
        return switch (self) {
            .px => |v| v,
            .percent => |p| if (basis) |b| b * p else 0,
        };
    }
};

/// Which layout algorithm lays out a node's children. gpui's default is `block`.
pub const Display = enum { block, flex, none };

pub const Position = enum {
    /// Laid out in flow; `inset` offsets the final position without affecting siblings.
    relative,
    /// Taken out of flow and positioned against the parent's padding box.
    absolute,
};

pub const Overflow = enum {
    visible,
    clip,
    hidden,
    scroll,

    /// Scroll containers (`hidden`/`scroll`) have an automatic minimum size of zero as flex items.
    pub fn isScrollContainer(self: Overflow) bool {
        return self == .hidden or self == .scroll;
    }
};

pub const FlexDirection = enum {
    row,
    column,
    row_reverse,
    column_reverse,

    pub fn isRow(self: FlexDirection) bool {
        return self == .row or self == .row_reverse;
    }
    pub fn isReverse(self: FlexDirection) bool {
        return self == .row_reverse or self == .column_reverse;
    }
};

pub const FlexWrap = enum { no_wrap, wrap, wrap_reverse };

pub const AlignItems = enum { start, end, flex_start, flex_end, center, baseline, stretch };
pub const AlignSelf = AlignItems;

pub const AlignContent = enum { start, end, flex_start, flex_end, center, stretch, space_between, space_evenly, space_around };
pub const JustifyContent = AlignContent;

/// Per-axis overflow behavior.
pub const OverflowXY = struct {
    x: Overflow = .visible,
    y: Overflow = .visible,
};

/// The layout-relevant part of a gpui `Style`. Defaults match gpui's `Style::default()`.
pub const Style = struct {
    display: Display = .block,
    position: Position = .relative,
    overflow: OverflowXY = .{},
    /// Space reserved for a scrollbar on axes whose overflow is `scroll`.
    scrollbar_width: f32 = 0,
    inset: Sides(Length) = .all(.auto),
    size: Dims(Dimension) = .all(.auto),
    min_size: Dims(Dimension) = .all(.auto),
    max_size: Dims(Dimension) = .all(.auto),
    /// Width divided by height.
    aspect_ratio: ?f32 = null,
    margin: Sides(Length) = .all(Length.zero),
    padding: Sides(LengthPercentage) = .all(LengthPercentage.zero),
    border: Sides(LengthPercentage) = .all(LengthPercentage.zero),
    /// `width` is the gap between columns, `height` the gap between rows (as in taffy).
    gap: Dims(LengthPercentage) = .all(LengthPercentage.zero),
    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .no_wrap,
    /// `null` behaves as `stretch`.
    align_items: ?AlignItems = null,
    /// `null` inherits the parent's `align_items`.
    align_self: ?AlignSelf = null,
    /// `null` behaves as `stretch`.
    align_content: ?AlignContent = null,
    /// `null` behaves as `flex_start`.
    justify_content: ?JustifyContent = null,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: Length = .auto,
};

// ---- Resolution helpers shared by the algorithms ----

pub fn resolveDims(d: Dims(Length), basis: Dims(?f32)) Dims(?f32) {
    return .{ .width = d.width.resolve(basis.width), .height = d.height.resolve(basis.height) };
}

/// Resolves sides against a width basis (CSS resolves all margin/padding percentages against width).
pub fn resolveSidesOpt(s: Sides(Length), basis: ?f32) Sides(?f32) {
    return .{ .top = s.top.resolve(basis), .right = s.right.resolve(basis), .bottom = s.bottom.resolve(basis), .left = s.left.resolve(basis) };
}

pub fn orZero(s: Sides(?f32)) Sides(f32) {
    return .{ .top = s.top orelse 0, .right = s.right orelse 0, .bottom = s.bottom orelse 0, .left = s.left orelse 0 };
}

pub fn resolveSidesLP(s: Sides(LengthPercentage), basis: ?f32) Sides(f32) {
    return .{ .top = s.top.resolve(basis), .right = s.right.resolve(basis), .bottom = s.bottom.resolve(basis), .left = s.left.resolve(basis) };
}

/// Padding plus border, resolved against `basis` (the containing block's width).
pub fn paddingBorder(style: *const Style, basis: ?f32) Sides(f32) {
    return resolveSidesLP(style.padding, basis).add(resolveSidesLP(style.border, basis));
}

/// Space reserved for scrollbars: `width` is a right-side gutter, `height` a bottom gutter.
pub fn scrollbarGutter(style: *const Style) Dims(f32) {
    return .{
        .width = if (style.overflow.y == .scroll) style.scrollbar_width else 0,
        .height = if (style.overflow.x == .scroll) style.scrollbar_width else 0,
    };
}

/// Fills in a missing dimension from the other one using `ratio` (width / height).
pub fn applyAspectRatio(d: Dims(?f32), ratio: ?f32) Dims(?f32) {
    const r = ratio orelse return d;
    if (d.width != null and d.height == null) return .{ .width = d.width, .height = d.width.? / r };
    if (d.height != null and d.width == null) return .{ .width = d.height.? * r, .height = d.height };
    return d;
}

/// Clamps `v` to `[min, max]`; `min` wins when they conflict (as in CSS).
pub fn clamp(v: f32, min: ?f32, max: ?f32) f32 {
    var r = v;
    if (max) |m| r = @min(r, m);
    if (min) |m| r = @max(r, m);
    return r;
}

pub fn clampOpt(v: ?f32, min: ?f32, max: ?f32) ?f32 {
    return if (v) |x| clamp(x, min, max) else null;
}

pub fn clampDims(d: Dims(?f32), min: Dims(?f32), max: Dims(?f32)) Dims(?f32) {
    return .{ .width = clampOpt(d.width, min.width, max.width), .height = clampOpt(d.height, min.height, max.height) };
}

/// `max(a, b)` when `a` is set; `null` otherwise.
pub fn maxOpt(a: ?f32, b: f32) ?f32 {
    return if (a) |x| @max(x, b) else null;
}

pub fn subOpt(a: ?f32, b: f32) ?f32 {
    return if (a) |x| x - b else null;
}

test "length resolution" {
    try std.testing.expectEqual(@as(?f32, 50), (Length{ .percent = 0.5 }).resolve(100));
    try std.testing.expectEqual(@as(?f32, null), (Length{ .percent = 0.5 }).resolve(null));
    try std.testing.expectEqual(@as(f32, 5), clamp(1, 5, 3));
}
