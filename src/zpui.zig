//! zpui — a GPU-accelerated UI framework for Zig, ported from zui (zeronsh's gpui fork).

pub const geometry = @import("geometry.zig");
pub const layout = @import("layout/layout.zig");

pub const Pixels = geometry.Pixels;
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Bounds = geometry.Bounds;
pub const Edges = geometry.Edges;
pub const Corners = geometry.Corners;
pub const ScaledPixels = geometry.ScaledPixels;
pub const DevicePixels = geometry.DevicePixels;
pub const Rems = geometry.Rems;
pub const AbsoluteLength = geometry.AbsoluteLength;
pub const DefiniteLength = geometry.DefiniteLength;
pub const Length = geometry.Length;
pub const px = geometry.px;
pub const rems = geometry.rems;
pub const relative = geometry.relative;
pub const auto = geometry.auto;

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

pub const input = @import("input.zig");
pub const platform = @import("platform/platform.zig");
pub const renderer = @import("renderer/renderer.zig");
pub const text = @import("text/types.zig");

pub const style = @import("style.zig");
pub const Style = style.Style;
pub const StyleRefinement = style.StyleRefinement;
pub const TextStyle = style.TextStyle;
pub const TextStyleRefinement = style.TextStyleRefinement;
pub const BoxShadow = style.BoxShadow;
pub const Refinement = style.Refinement;
pub const styled = @import("styled.zig");
pub const Styled = styled.Styled;
pub const StyleBuilder = styled.StyleBuilder;

test {
    @import("std").testing.refAllDecls(@This());
}
