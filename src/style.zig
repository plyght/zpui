//! Element styles (gpui `style.rs`): `Style`, its `StyleRefinement`, `TextStyle`, `BoxShadow`,
//! `HighlightStyle`, and conversion to the layout engine's resolved `layout.Style`.
//!
//! Lengths are unresolved here (`px`/`rems`/fractions/`auto`); `Style.toLayoutStyle` resolves
//! them against the window's rem size and scale factor.

const std = @import("std");
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const scene = @import("scene.zig");
const platform = @import("platform/platform.zig");
const text = @import("text/types.zig");
const layout = @import("layout/style.zig");
pub const refinement = @import("style/refine.zig");

pub const Pixels = geometry.Pixels;
pub const Rems = geometry.Rems;
pub const AbsoluteLength = geometry.AbsoluteLength;
pub const DefiniteLength = geometry.DefiniteLength;
pub const Length = geometry.Length;
pub const px = geometry.px;
pub const rems = geometry.rems;
pub const relative = geometry.relative;
pub const phi = geometry.phi;
pub const auto = geometry.auto;

pub const Hsla = color.Hsla;
pub const Background = color.Background;
pub const BorderStyle = scene.BorderStyle;
pub const CursorStyle = platform.CursorStyle;

pub const Refinement = refinement.Refinement;

// Enums shared with the layout engine (identical to gpui's taffy mirrors, minus grid).
pub const Display = layout.Display;
pub const Position = layout.Position;
pub const Overflow = layout.Overflow;
pub const FlexDirection = layout.FlexDirection;
pub const FlexWrap = layout.FlexWrap;
pub const AlignItems = layout.AlignItems;
pub const AlignSelf = layout.AlignSelf;
pub const AlignContent = layout.AlignContent;
pub const JustifyContent = layout.JustifyContent;

/// Top/right/bottom/left values (gpui `Edges<T>`; non-`extern` so it can hold unions).
pub const Edges = layout.Sides;
/// Width/height values (gpui `Size<T>`; non-`extern`).
pub const Size = layout.Dims;

/// Per-corner values (gpui `Corners<T>`; non-`extern` counterpart of `geometry.Corners`).
pub fn Corners(comptime T: type) type {
    return struct {
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

/// Per-axis values (gpui `Point<T>`, used for `overflow`).
pub fn Axes(comptime T: type) type {
    return struct {
        x: T,
        y: T,

        pub fn all(v: T) @This() {
            return .{ .x = v, .y = v };
        }
    };
}

/// Whether an element is painted (it still takes up layout space when hidden).
pub const Visibility = enum { visible, hidden };

/// gpui `BoxShadow`, including the zui fork's inset shadows.
pub const BoxShadow = struct {
    color: Hsla,
    offset: geometry.Point(Pixels),
    blur_radius: Pixels = 0,
    spread_radius: Pixels = 0,
    /// Drawn inside the element's bounds (zui fork).
    inset: bool = false,

    /// Offset and color in CSS `box-shadow` order; set blur/spread/inset with the field defaults.
    pub fn init(offset_x: Pixels, offset_y: Pixels, c: Hsla) BoxShadow {
        return .{ .color = c, .offset = .{ .x = offset_x, .y = offset_y } };
    }
};

pub const WhiteSpace = enum {
    /// Wrap lines that overflow the element's width.
    normal,
    /// Never wrap.
    nowrap,
};

/// How text that overflows its element's width is truncated. The payload is the marker string.
pub const TextOverflow = union(enum) {
    /// "very long te…"
    truncate: []const u8,
    /// "…ong text here"
    truncate_start: []const u8,
    /// "long fi…name.rs"
    truncate_middle: []const u8,
};

pub const ellipsis = "…";

pub const TextAlign = enum { left, center, right };

pub const FontWeight = text.FontWeight;
pub const FontStyle = text.FontStyle;
pub const FontFeature = text.FontFeature;
pub const UnderlineStyle = text.UnderlineStyle;
pub const StrikethroughStyle = text.StrikethroughStyle;

/// Text properties; inherited down the element tree via `TextStyleRefinement`s.
pub const TextStyle = struct {
    color: Hsla = color.black,
    font_family: []const u8 = ".SystemUIFont",
    font_features: []const FontFeature = &.{},
    font_fallbacks: ?[]const []const u8 = null,
    font_size: AbsoluteLength = .{ .rems = 1 },
    /// Fractions are relative to `font_size`.
    line_height: DefiniteLength = .{ .fraction = 1.618034 },
    font_weight: FontWeight = text.weight.normal,
    font_style: FontStyle = .normal,
    background_color: ?Hsla = null,
    underline: ?UnderlineStyle = null,
    strikethrough: ?StrikethroughStyle = null,
    white_space: WhiteSpace = .normal,
    text_overflow: ?TextOverflow = null,
    text_align: TextAlign = .left,
    /// Number of lines to show before truncating.
    line_clamp: ?usize = null,

    pub fn font(self: TextStyle) text.Font {
        return .{
            .family = self.font_family,
            .weight = self.font_weight,
            .style = self.font_style,
            .features = self.font_features,
            .fallbacks = self.font_fallbacks orelse &.{},
        };
    }

    /// The line height in pixels, rounded.
    pub fn lineHeightInPixels(self: TextStyle, rem_size: Pixels) Pixels {
        return @round(self.line_height.toPixels(self.font_size, rem_size));
    }

    /// A `TextRun` covering `len` bytes in this style.
    pub fn toRun(self: TextStyle, len: usize) text.TextRun {
        return .{
            .len = len,
            .font = self.font(),
            .color = self.color,
            .background_color = self.background_color,
            .underline = self.underline,
            .strikethrough = self.strikethrough,
        };
    }

    /// Applies a highlight: colors blend, fade dims, everything else set overrides.
    pub fn highlight(self: TextStyle, h: HighlightStyle) TextStyle {
        var out = self;
        if (h.font_weight) |w| out.font_weight = w;
        if (h.font_style) |s| out.font_style = s;
        if (h.color) |c| out.color = out.color.blend(c);
        if (h.fade_out) |f| out.color.fadeOut(f);
        if (h.background_color) |c| out.background_color = c;
        if (h.underline) |u| out.underline = u;
        if (h.strikethrough) |s| out.strikethrough = s;
        return out;
    }
};

pub const TextStyleRefinement = Refinement(TextStyle);

/// A partial text style for a single font, e.g. syntax highlighting (gpui `HighlightStyle`).
pub const HighlightStyle = struct {
    color: ?Hsla = null,
    font_weight: ?FontWeight = null,
    font_style: ?FontStyle = null,
    background_color: ?Hsla = null,
    underline: ?UnderlineStyle = null,
    strikethrough: ?StrikethroughStyle = null,
    /// Like CSS `opacity`: makes the text less vibrant.
    fade_out: ?f32 = null,

    /// Layers `other` on top of `self`.
    pub fn highlight(self: HighlightStyle, other: HighlightStyle) HighlightStyle {
        return .{
            .color = if (other.color) |oc| (if (self.color) |c| c.blend(oc) else oc) else self.color,
            .font_weight = other.font_weight orelse self.font_weight,
            .font_style = other.font_style orelse self.font_style,
            .background_color = other.background_color orelse self.background_color,
            .underline = other.underline orelse self.underline,
            .strikethrough = other.strikethrough orelse self.strikethrough,
            .fade_out = if (other.fade_out) |src|
                (if (self.fade_out) |dst| std.math.clamp(dst * (1 + src), 0, 1) else src)
            else
                self.fade_out,
        };
    }
};

/// The CSS styling of an element (gpui `Style`). Defaults match gpui's `Style::default()`.
pub const Style = struct {
    /// Fields refined per sub-field (gpui `#[refineable]`).
    pub const refinable = .{ "overflow", "inset", "size", "min_size", "max_size", "margin", "padding", "border_widths", "gap", "corner_radii", "text" };

    display: Display = .block,
    visibility: Visibility = .visible,
    overflow: Axes(Overflow) = .all(.visible),
    /// Space reserved for scrollbars on `scroll` axes.
    scrollbar_width: AbsoluteLength = .zero,
    /// Whether both axes may scroll at once.
    allow_concurrent_scroll: bool = false,
    /// Plain wheel scrolls only Y; Shift+wheel scrolls X (web behavior).
    restrict_scroll_to_axis: bool = false,

    position: Position = .relative,
    inset: Edges(Length) = .all(.auto),

    size: Size(Length) = .all(.auto),
    min_size: Size(Length) = .all(.auto),
    max_size: Size(Length) = .all(.auto),
    /// Width divided by height.
    aspect_ratio: ?f32 = null,

    margin: Edges(Length) = .all(.zero),
    padding: Edges(DefiniteLength) = .all(.zero),
    border_widths: Edges(AbsoluteLength) = .all(.zero),

    align_items: ?AlignItems = null,
    /// Falls back to the parent's `align_items`.
    align_self: ?AlignSelf = null,
    align_content: ?AlignContent = null,
    justify_content: ?JustifyContent = null,
    /// `width` is the column gap, `height` the row gap.
    gap: Size(DefiniteLength) = .all(.zero),

    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .no_wrap,
    flex_basis: Length = .auto,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,

    background: ?Background = null,
    border_color: ?Hsla = null,
    border_style: BorderStyle = .solid,
    corner_radii: Corners(AbsoluteLength) = .all(.zero),
    /// Must outlive the frame (presets are static).
    box_shadow: []const BoxShadow = &.{},

    /// Text properties this element overrides for its subtree.
    text: TextStyleRefinement = .{},

    mouse_cursor: ?CursorStyle = null,
    opacity: ?f32 = null,

    /// Draw a debug outline around this element.
    debug: bool = false,
    /// Draw debug outlines around this element and all its descendants.
    debug_below: bool = false,

    /// True if the background is a visible, non-transparent fill.
    pub fn hasOpaqueBackground(self: *const Style) bool {
        const bg = self.background orelse return false;
        return !bg.isTransparent();
    }

    /// The text refinement if any text property is set.
    pub fn textStyle(self: *const Style) ?*const TextStyleRefinement {
        return if (refinement.isEmpty(self.text)) null else &self.text;
    }

    /// Corner radii in pixels, clamped to half the smaller side of `size`.
    pub fn cornerRadiiPixels(self: *const Style, size: geometry.Size(Pixels), rem_size: Pixels) geometry.Corners(Pixels) {
        const max = @min(size.width, size.height) / 2;
        const c = self.corner_radii;
        return .{
            .top_left = @min(c.top_left.toPixels(rem_size), max),
            .top_right = @min(c.top_right.toPixels(rem_size), max),
            .bottom_right = @min(c.bottom_right.toPixels(rem_size), max),
            .bottom_left = @min(c.bottom_left.toPixels(rem_size), max),
        };
    }

    pub fn borderWidthsPixels(self: *const Style, rem_size: Pixels) geometry.Edges(Pixels) {
        const b = self.border_widths;
        return .{
            .top = b.top.toPixels(rem_size),
            .right = b.right.toPixels(rem_size),
            .bottom = b.bottom.toPixels(rem_size),
            .left = b.left.toPixels(rem_size),
        };
    }

    /// True if a non-transparent border color and a non-zero width are set.
    pub fn isBorderVisible(self: *const Style) bool {
        const c = self.border_color orelse return false;
        if (c.isTransparent()) return false;
        const b = self.border_widths;
        return !(b.top.isZero() and b.right.isZero() and b.bottom.isZero() and b.left.isZero());
    }

    /// The clip bounds for children (gpui `overflow_mask`), or null when both axes are visible.
    /// Clipped axes are inset by the border when the border is visible.
    pub fn overflowMask(self: *const Style, bounds: geometry.Bounds(Pixels), rem_size: Pixels) ?geometry.Bounds(Pixels) {
        const clip_x = self.overflow.x != .visible;
        const clip_y = self.overflow.y != .visible;
        if (!clip_x and !clip_y) return null;
        var min = bounds.origin;
        var max: geometry.Point(Pixels) = .{ .x = bounds.right(), .y = bounds.bottom() };
        if (self.border_color) |c| if (!c.isTransparent()) {
            const b = self.borderWidthsPixels(rem_size);
            min.x += b.left;
            max.x -= b.right;
            min.y += b.top;
            max.y -= b.bottom;
        };
        if (!clip_x) {
            min.x = bounds.origin.x;
            max.x = bounds.right();
        }
        if (!clip_y) {
            min.y = bounds.origin.y;
            max.y = bounds.bottom();
        }
        return geometry.Bounds(Pixels).fromCorners(min, max);
    }

    /// Converts to the layout engine's style (gpui `to_taffy`). As in gpui, lengths come out in
    /// device pixels (logical × `scale_factor`, rounded half toward zero; non-zero borders round
    /// to at least one device pixel), so layout bounds must be divided by `scale_factor`.
    pub fn toLayoutStyle(self: *const Style, rem_size: Pixels, scale_factor: f32) layout.Style {
        const cv: Converter = .{ .rem_size = rem_size, .scale = scale_factor };
        return .{
            .display = self.display,
            .position = self.position,
            .overflow = .{ .x = self.overflow.x, .y = self.overflow.y },
            .scrollbar_width = cv.abs(self.scrollbar_width),
            .inset = cv.sides(layout.Length, self.inset, Converter.length),
            .size = cv.dims(self.size),
            .min_size = cv.dims(self.min_size),
            .max_size = cv.dims(self.max_size),
            .aspect_ratio = self.aspect_ratio,
            .margin = cv.sides(layout.Length, self.margin, Converter.length),
            .padding = cv.sides(layout.LengthPercentage, self.padding, Converter.definite),
            .border = cv.sides(layout.LengthPercentage, self.border_widths, Converter.border),
            .gap = .{ .width = cv.definite(self.gap.width), .height = cv.definite(self.gap.height) },
            .flex_direction = self.flex_direction,
            .flex_wrap = self.flex_wrap,
            .align_items = self.align_items,
            .align_self = self.align_self,
            .align_content = self.align_content,
            .justify_content = self.justify_content,
            .flex_grow = self.flex_grow,
            .flex_shrink = self.flex_shrink,
            .flex_basis = cv.length(self.flex_basis),
        };
    }
};

pub const StyleRefinement = Refinement(Style);

/// Rounds to the nearest integer with .5 ties toward zero (gpui `round_half_toward_zero`).
pub fn roundHalfTowardZero(v: f32) f32 {
    return std.math.copysign(@ceil(@abs(v) - 0.5), v);
}

const Converter = struct {
    rem_size: Pixels,
    scale: f32,

    fn abs(cv: Converter, l: AbsoluteLength) f32 {
        return roundHalfTowardZero(l.toPixels(cv.rem_size) * cv.scale);
    }
    fn border(cv: Converter, l: AbsoluteLength) layout.LengthPercentage {
        const logical = l.toPixels(cv.rem_size);
        if (logical == 0) return .{ .px = 0 };
        return .{ .px = @max(roundHalfTowardZero(@max(logical, 0) * cv.scale), 1) };
    }
    fn definite(cv: Converter, l: DefiniteLength) layout.LengthPercentage {
        return switch (l) {
            .absolute => |a| .{ .px = cv.abs(a) },
            .fraction => |f| .{ .percent = f },
        };
    }
    fn length(cv: Converter, l: Length) layout.Length {
        return switch (l) {
            .auto => .auto,
            .definite => |d| switch (cv.definite(d)) {
                .px => |v| .{ .px = v },
                .percent => |v| .{ .percent = v },
            },
        };
    }
    fn dims(cv: Converter, d: Size(Length)) layout.Dims(layout.Length) {
        return .{ .width = cv.length(d.width), .height = cv.length(d.height) };
    }
    fn sides(cv: Converter, comptime Out: type, s: anytype, comptime f: anytype) layout.Sides(Out) {
        return .{ .top = f(cv, s.top), .right = f(cv, s.right), .bottom = f(cv, s.bottom), .left = f(cv, s.left) };
    }
};

// ---- tests ----

const testing = std.testing;

test "style defaults match gpui" {
    const s: Style = .{};
    try testing.expectEqual(Display.block, s.display);
    try testing.expectEqual(@as(f32, 1), s.flex_shrink);
    try testing.expectEqual(Length.auto, s.inset.top);
    try testing.expectEqual(Length.zero, s.margin.left);
    try testing.expect(s.textStyle() == null);
    const t: TextStyle = .{};
    try testing.expectEqual(@as(Pixels, 26), t.lineHeightInPixels(16)); // 16 * phi = 25.9
}

test "style refinement: text size then weight (gpui test_text_style_refinement)" {
    var s: Style = .{};
    refinement.refine(&s, StyleRefinement{ .text = .{ .font_size = .{ .pixels = 20 } } });
    refinement.refine(&s, StyleRefinement{ .text = .{ .font_weight = text.weight.semibold } });
    const t = s.textStyle().?;
    try testing.expectEqual(@as(?AbsoluteLength, .{ .pixels = 20 }), t.font_size);
    try testing.expectEqual(@as(?FontWeight, text.weight.semibold), t.font_weight);
}

test "refinement cascades: hover over base" {
    const base: StyleRefinement = .{ .padding = .{ .left = .{ .absolute = .{ .pixels = 4 } } }, .opacity = 0.5 };
    const hover: StyleRefinement = .{ .padding = .{ .right = .{ .absolute = .{ .pixels = 8 } } }, .opacity = 1 };
    var s: Style = .{};
    refinement.refine(&s, base);
    refinement.refine(&s, hover);
    try testing.expectEqual(DefiniteLength{ .absolute = .{ .pixels = 4 } }, s.padding.left);
    try testing.expectEqual(DefiniteLength{ .absolute = .{ .pixels = 8 } }, s.padding.right);
    try testing.expectEqual(@as(?f32, 1), s.opacity);
    // Refining a refinement merges.
    const m = refinement.merged(Style, base, hover);
    try testing.expect(m.padding.left != null and m.padding.right != null);
    try testing.expectEqual(@as(?f32, 1), m.opacity);
}

test "toLayoutStyle resolves rems, fractions, auto, scale and stroke snapping" {
    var s: Style = .{ .display = .flex, .flex_direction = .column };
    s.size.width = .{ .definite = .{ .absolute = .{ .rems = 2 } } };
    s.size.height = .{ .definite = relative(0.5) };
    s.padding = .all(.{ .absolute = .{ .pixels = 3.5 } });
    s.border_widths = .{ .top = .zero, .right = .{ .pixels = 0.4 }, .bottom = .{ .pixels = 0.5 }, .left = .{ .pixels = 1.6 } };
    s.gap.width = .{ .absolute = .{ .rems = 0.5 } };
    s.align_items = .center;
    const l = s.toLayoutStyle(16, 2);
    try testing.expectEqual(layout.Display.flex, l.display);
    try testing.expectEqual(layout.FlexDirection.column, l.flex_direction);
    try testing.expectEqual(layout.Length{ .px = 64 }, l.size.width);
    try testing.expectEqual(layout.Length{ .percent = 0.5 }, l.size.height);
    try testing.expectEqual(layout.Length.auto, l.min_size.width);
    try testing.expectEqual(layout.LengthPercentage{ .px = 7 }, l.padding.top);
    try testing.expectEqual(layout.LengthPercentage{ .px = 16 }, l.gap.width);
    try testing.expectEqual(@as(?layout.AlignItems, .center), l.align_items);
    const b = (Style{ .border_widths = s.border_widths }).toLayoutStyle(16, 1).border;
    try testing.expectEqual(layout.LengthPercentage{ .px = 0 }, b.top);
    try testing.expectEqual(layout.LengthPercentage{ .px = 1 }, b.right);
    try testing.expectEqual(layout.LengthPercentage{ .px = 1 }, b.bottom);
    try testing.expectEqual(layout.LengthPercentage{ .px = 2 }, b.left);
    try testing.expectEqual(@as(f32, 2), roundHalfTowardZero(2.5));
    try testing.expectEqual(@as(f32, -2), roundHalfTowardZero(-2.5));
}

test "overflow mask insets visible borders" {
    var s: Style = .{ .overflow = .{ .x = .visible, .y = .hidden } };
    s.border_widths = .all(.{ .pixels = 2 });
    s.border_color = color.red;
    const bounds: geometry.Bounds(Pixels) = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 100, .height = 50 } };
    const m = s.overflowMask(bounds, 16).?;
    try testing.expectEqual(@as(f32, 0), m.origin.x);
    try testing.expectEqual(@as(f32, 2), m.origin.y);
    try testing.expectEqual(@as(f32, 100), m.size.width);
    try testing.expectEqual(@as(f32, 46), m.size.height);
    try testing.expect((Style{}).overflowMask(bounds, 16) == null);
    try testing.expect(s.isBorderVisible());
    const r = (Style{ .corner_radii = .all(.{ .pixels = 9999 }) }).cornerRadiiPixels(bounds.size, 16);
    try testing.expectEqual(@as(f32, 25), r.top_left);
}

test "highlight style layering" {
    const a: HighlightStyle = .{ .color = color.red, .fade_out = 0.5 };
    const b: HighlightStyle = .{ .font_weight = text.weight.bold, .fade_out = 0.5 };
    const c = a.highlight(b);
    try testing.expectEqual(@as(?f32, 0.75), c.fade_out);
    try testing.expectEqual(@as(?FontWeight, text.weight.bold), c.font_weight);
    try testing.expect(c.color.?.eql(color.red));
    const t = (TextStyle{}).highlight(.{ .font_style = .italic });
    try testing.expectEqual(FontStyle.italic, t.font_style);
    try testing.expectEqual(@as(usize, 3), t.toRun(3).len);
}
