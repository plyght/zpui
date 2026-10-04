//! zpui — a GPU-accelerated UI framework for Zig, ported from zui (zeronsh's gpui fork).

pub const geometry = @import("geometry.zig");

pub const Pixels = geometry.Pixels;
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Bounds = geometry.Bounds;
pub const Edges = geometry.Edges;
pub const Corners = geometry.Corners;

test {
    @import("std").testing.refAllDecls(@This());
}
