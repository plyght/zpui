//! zpui's built-in elements (gpui `elements/`). See docs/elements.md.

pub const div_mod = @import("div.zig");
pub const text = @import("text.zig");
pub const canvas_mod = @import("canvas.zig");
pub const deferred_mod = @import("deferred.zig");
pub const anchored_mod = @import("anchored.zig");
pub const img_mod = @import("img.zig");
pub const svg_mod = @import("svg.zig");

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

test {
    @import("std").testing.refAllDecls(@This());
    _ = div_mod;
    _ = text;
    _ = canvas_mod;
    _ = deferred_mod;
    _ = anchored_mod;
    _ = img_mod;
    _ = svg_mod;
}
