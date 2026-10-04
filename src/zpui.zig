//! zpui — a GPU-accelerated UI framework for Zig, ported from zui (zeronsh's gpui fork).

pub const geometry = @import("geometry.zig");

pub const Pixels = geometry.Pixels;
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Bounds = geometry.Bounds;
pub const Edges = geometry.Edges;
pub const Corners = geometry.Corners;
pub const ScaledPixels = geometry.ScaledPixels;
pub const DevicePixels = geometry.DevicePixels;

pub const color = @import("color.zig");
pub const Hsla = color.Hsla;
pub const Rgba = color.Rgba;
pub const Background = color.Background;
pub const rgb = color.rgb;
pub const rgba = color.rgba;
pub const hsla = color.hsla;

pub const atlas = @import("atlas.zig");
pub const bounds_tree = @import("bounds_tree.zig");
pub const scene = @import("scene.zig");
pub const Scene = scene.Scene;

test {
    @import("std").testing.refAllDecls(@This());
}
