//! zpui's built-in elements (gpui `elements/`). See docs/elements.md.

pub const div_mod = @import("div.zig");
pub const text = @import("text.zig");
pub const canvas_mod = @import("canvas.zig");
pub const deferred_mod = @import("deferred.zig");
pub const anchored_mod = @import("anchored.zig");
pub const img_mod = @import("img.zig");
pub const svg_mod = @import("svg.zig");
pub const list_mod = @import("list.zig");
pub const uniform_list_mod = @import("uniform_list.zig");
pub const animation = @import("animation.zig");
pub const scrollbar_mod = @import("scrollbar.zig");
pub const effects = @import("effects.zig");
pub const native_view_mod = @import("native_view.zig");
pub const nativeView = native_view_mod.nativeView;
pub const nativeViewWith = native_view_mod.nativeViewWith;
// [liquid-glass] native Liquid Glass (liquid_glass.zig)
pub const liquid_glass = @import("liquid_glass.zig");
pub const liquidGlass = liquid_glass.liquidGlass;
pub const liquidGlassGroup = liquid_glass.liquidGlassGroup;
pub const overlayPlane = liquid_glass.overlayPlane;
pub const platformSupportsLiquidGlass = liquid_glass.platformSupportsLiquidGlass;

pub const div = div_mod.div;
pub const Div = div_mod.Div;
pub const StatefulDiv = div_mod.StatefulDiv;
pub const ScrollHandle = div_mod.ScrollHandle;
pub const Interactivity = div_mod.Interactivity;
pub const InteractiveElementState = div_mod.InteractiveElementState;

pub const StyledText = text.StyledText;
pub const InteractiveText = text.InteractiveText;
pub const TextLayout = text.TextLayout;
pub const Highlight = text.Highlight;
pub const styledText = text.styledText;

pub const canvas = canvas_mod.canvas;
pub const Canvas = canvas_mod.Canvas;
pub const deferred = deferred_mod.deferred;
pub const Deferred = deferred_mod.Deferred;
pub const anchored = anchored_mod.anchored;
pub const Anchored = anchored_mod.Anchored;
pub const Anchor = anchored_mod.Anchor;
pub const img = img_mod.img;
pub const Img = img_mod.Img;
pub const ImageSource = img_mod.ImageSource;
pub const ObjectFit = img_mod.ObjectFit;
pub const svg = svg_mod.svg;
pub const Svg = svg_mod.Svg;
pub const StatefulSvg = svg_mod.StatefulSvg;
pub const SvgTransformation = svg_mod.Transformation;
pub const list = list_mod.list;
pub const List = list_mod.List;
pub const ListState = list_mod.ListState;
pub const ListOffset = list_mod.ListOffset;
pub const ListAlignment = list_mod.ListAlignment;
pub const ListScrollEvent = list_mod.ListScrollEvent;
pub const ListSizingBehavior = list_mod.ListSizingBehavior;
pub const ListHorizontalSizingBehavior = list_mod.ListHorizontalSizingBehavior;
pub const FollowMode = list_mod.FollowMode;
pub const TailReservation = list_mod.TailReservation;
pub const Range = list_mod.Range;
pub const uniformList = uniform_list_mod.uniformList;
pub const UniformList = uniform_list_mod.UniformList;
pub const UniformListScrollHandle = uniform_list_mod.UniformListScrollHandle;
pub const ScrollStrategy = uniform_list_mod.ScrollStrategy;
pub const Animation = animation.Animation;
pub const Easing = animation.Easing;
pub const easing = animation.easing;
pub const withAnimation = animation.withAnimation;
pub const withAnimationCtx = animation.withAnimationCtx;
pub const withAnimations = animation.withAnimations;
pub const scrollbar = scrollbar_mod.scrollbar;
pub const Scrollbar = scrollbar_mod.Scrollbar;
pub const ScrollbarStyle = scrollbar_mod.ScrollbarStyle;
pub const ScrollbarMode = scrollbar_mod.ScrollbarMode;
pub const ScrollbarAxis = scrollbar_mod.ScrollbarAxis;
pub const edgeFaded = effects.edgeFaded;
pub const EdgeFaded = effects.EdgeFaded;
pub const frosted = effects.frosted;
pub const Frosted = effects.Frosted;
pub const layered = effects.layered;

test {
    @import("std").testing.refAllDecls(@This());
    _ = div_mod;
    _ = text;
    _ = canvas_mod;
    _ = deferred_mod;
    _ = anchored_mod;
    _ = img_mod;
    _ = svg_mod;
    _ = list_mod;
    _ = uniform_list_mod;
    _ = animation;
    _ = scrollbar_mod;
    _ = effects;
    _ = liquid_glass;
    _ = @import("liquid_glass_tests.zig"); // [liquid-glass]
    _ = @import("list_tests.zig");
}
