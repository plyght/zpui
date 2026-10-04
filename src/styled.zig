//! Tailwind-style builder methods (gpui `Styled`), as comptime mixins over any element type
//! `Self` that has `pub fn style(self: *Self) *StyleRefinement`.
//!
//! Every builder takes `Self` by value and returns the updated copy, so calls chain:
//! `div().flex().flexCol().gap(px(8)).p(px(12)).roundedLg().bg(theme.card).shadowMd()`.
//! Names are gpui's in camelCase (`p_4` → `p4`, `w_1_2` → `w1_2`, `rounded_md` → `roundedMd`).
//!
//! Zig has no `usingnamespace`, so an element exposes the methods by forwarding declarations
//! (`pub const flex = S.flex;`). `scripts/gen_styled.py --forward <file.zig>` writes them between
//! `// zpui:styled-forwarders begin(<Type>)` and `// zpui:styled-forwarders end` markers;
//! `assertStyled(T)` checks at comptime that none are missing. `StyleBuilder` is a ready-made
//! styled value over a bare `StyleRefinement` (for hover/active/focus styles and tests).
//!
//! `Styled(Self)` holds the hand-written methods from gpui `styled.rs`; the generated scales from
//! gpui_macros `styles.rs` (spacing, sizes, insets, radii, borders, shadows, cursors, overflow)
//! live in `Generated(Self)` (`src/style/styled_generated.zig`).

const std = @import("std");
const style = @import("style.zig");
const generated = @import("style/styled_generated.zig");

const StyleRefinement = style.StyleRefinement;
const TextStyleRefinement = style.TextStyleRefinement;
const AbsoluteLength = style.AbsoluteLength;
const DefiniteLength = style.DefiniteLength;
const Length = style.Length;
const Hsla = style.Hsla;

/// Generated tailwind scales; see `src/style/styled_generated.zig`.
pub const Generated = generated.Methods;
pub const shadows = generated.shadows;
pub const StyleBuilder = @import("style/builder.zig").StyleBuilder;

/// Hand-written `Styled` methods (gpui `styled.rs`).
pub fn Styled(comptime Self: type) type {
    return struct {
        fn setText(self: Self, comptime field: []const u8, value: anytype) Self {
            var s = self;
            @field(s.style().text, field) = value;
            return s;
        }
        fn underlineMut(self: *Self) *style.UnderlineStyle {
            const t = &self.style().text;
            if (t.underline == null) t.underline = .{ .thickness = 0 };
            return &t.underline.?;
        }

        /// Mutable access to the text refinement (gpui `text_style`).
        pub fn textStyle(self: *Self) *TextStyleRefinement {
            return &self.style().text;
        }

        // ---- display ----

        pub fn block(self: Self) Self {
            var s = self;
            s.style().display = .block;
            return s;
        }
        pub fn flex(self: Self) Self {
            var s = self;
            s.style().display = .flex;
            return s;
        }
        /// `display: none`.
        pub fn hidden(self: Self) Self {
            var s = self;
            s.style().display = .none;
            return s;
        }
        pub fn scrollbarWidth(self: Self, width: anytype) Self {
            var s = self;
            s.style().scrollbar_width = AbsoluteLength.from(width);
            return s;
        }

        /// Overflow scrolling on both axes. gpui only offers these on stateful (id'd) elements.
        pub fn overflowScroll(self: Self) Self {
            var s = self;
            s.style().overflow = .{ .x = .scroll, .y = .scroll };
            return s;
        }
        pub fn overflowXScroll(self: Self) Self {
            var s = self;
            s.style().overflow.x = .scroll;
            return s;
        }
        pub fn overflowYScroll(self: Self) Self {
            var s = self;
            s.style().overflow.y = .scroll;
            return s;
        }

        // ---- text layout ----

        pub fn whitespaceNormal(self: Self) Self {
            return setText(self, "white_space", style.WhiteSpace.normal);
        }
        pub fn whitespaceNowrap(self: Self) Self {
            return setText(self, "white_space", style.WhiteSpace.nowrap);
        }
        pub fn textEllipsis(self: Self) Self {
            return setText(self, "text_overflow", style.TextOverflow{ .truncate = style.ellipsis });
        }
        pub fn textEllipsisStart(self: Self) Self {
            return setText(self, "text_overflow", style.TextOverflow{ .truncate_start = style.ellipsis });
        }
        pub fn textEllipsisMiddle(self: Self) Self {
            return setText(self, "text_overflow", style.TextOverflow{ .truncate_middle = style.ellipsis });
        }
        pub fn textOverflow(self: Self, overflow: style.TextOverflow) Self {
            return setText(self, "text_overflow", overflow);
        }
        pub fn textAlign(self: Self, a: style.TextAlign) Self {
            return setText(self, "text_align", a);
        }
        pub fn textLeft(self: Self) Self {
            return textAlign(self, .left);
        }
        pub fn textCenter(self: Self) Self {
            return textAlign(self, .center);
        }
        pub fn textRight(self: Self) Self {
            return textAlign(self, .right);
        }
        /// Single line, clipped, with a trailing ellipsis.
        pub fn truncate(self: Self) Self {
            var s = self;
            const r = s.style();
            r.overflow = .{ .x = .hidden, .y = .hidden };
            r.text.white_space = .nowrap;
            r.text.text_overflow = .{ .truncate = style.ellipsis };
            return s;
        }
        /// Shows at most `lines` lines, clipping overflow.
        pub fn lineClamp(self: Self, lines: usize) Self {
            var s = self;
            const r = s.style();
            r.text.line_clamp = lines;
            r.overflow = .{ .x = .hidden, .y = .hidden };
            return s;
        }

        // ---- flex ----

        pub fn flexCol(self: Self) Self {
            var s = self;
            s.style().flex_direction = .column;
            return s;
        }
        pub fn flexColReverse(self: Self) Self {
            var s = self;
            s.style().flex_direction = .column_reverse;
            return s;
        }
        pub fn flexRow(self: Self) Self {
            var s = self;
            s.style().flex_direction = .row;
            return s;
        }
        pub fn flexRowReverse(self: Self) Self {
            var s = self;
            s.style().flex_direction = .row_reverse;
            return s;
        }
        fn flexTriple(self: Self, grow: f32, shrink: f32, basis: Length) Self {
            var s = self;
            const r = s.style();
            r.flex_grow = grow;
            r.flex_shrink = shrink;
            r.flex_basis = basis;
            return s;
        }
        /// Grow and shrink from a zero basis.
        pub fn flex1(self: Self) Self {
            return flexTriple(self, 1, 1, .{ .definite = .{ .fraction = 0 } });
        }
        /// Grow and shrink from the intrinsic size.
        pub fn flexAuto(self: Self) Self {
            return flexTriple(self, 1, 1, .auto);
        }
        /// Shrink but don't grow.
        pub fn flexInitial(self: Self) Self {
            return flexTriple(self, 0, 1, .auto);
        }
        /// Neither grow nor shrink.
        pub fn flexNone(self: Self) Self {
            return flexTriple(self, 0, 0, .auto);
        }
        pub fn flexBasis(self: Self, basis: anytype) Self {
            var s = self;
            s.style().flex_basis = Length.from(basis);
            return s;
        }
        pub fn flexGrow(self: Self, grow: f32) Self {
            var s = self;
            s.style().flex_grow = grow;
            return s;
        }
        pub fn flexGrow0(self: Self) Self {
            return flexGrow(self, 0);
        }
        pub fn flexGrow1(self: Self) Self {
            return flexGrow(self, 1);
        }
        pub fn flexShrink(self: Self, shrink: f32) Self {
            var s = self;
            s.style().flex_shrink = shrink;
            return s;
        }
        pub fn flexShrink0(self: Self) Self {
            return flexShrink(self, 0);
        }
        pub fn flexShrink1(self: Self) Self {
            return flexShrink(self, 1);
        }
        pub fn flexWrap(self: Self) Self {
            var s = self;
            s.style().flex_wrap = .wrap;
            return s;
        }
        pub fn flexWrapReverse(self: Self) Self {
            var s = self;
            s.style().flex_wrap = .wrap_reverse;
            return s;
        }
        pub fn flexNowrap(self: Self) Self {
            var s = self;
            s.style().flex_wrap = .no_wrap;
            return s;
        }

        // ---- alignment ----

        fn alignItems(self: Self, v: style.AlignItems) Self {
            var s = self;
            s.style().align_items = v;
            return s;
        }
        pub fn itemsStart(self: Self) Self {
            return alignItems(self, .flex_start);
        }
        pub fn itemsEnd(self: Self) Self {
            return alignItems(self, .flex_end);
        }
        pub fn itemsCenter(self: Self) Self {
            return alignItems(self, .center);
        }
        pub fn itemsBaseline(self: Self) Self {
            return alignItems(self, .baseline);
        }
        pub fn itemsStretch(self: Self) Self {
            return alignItems(self, .stretch);
        }
        fn alignSelf(self: Self, v: style.AlignSelf) Self {
            var s = self;
            s.style().align_self = v;
            return s;
        }
        pub fn selfStart(self: Self) Self {
            return alignSelf(self, .start);
        }
        pub fn selfEnd(self: Self) Self {
            return alignSelf(self, .end);
        }
        pub fn selfFlexStart(self: Self) Self {
            return alignSelf(self, .flex_start);
        }
        pub fn selfFlexEnd(self: Self) Self {
            return alignSelf(self, .flex_end);
        }
        pub fn selfCenter(self: Self) Self {
            return alignSelf(self, .center);
        }
        pub fn selfBaseline(self: Self) Self {
            return alignSelf(self, .baseline);
        }
        pub fn selfStretch(self: Self) Self {
            return alignSelf(self, .stretch);
        }
        fn justify(self: Self, v: style.JustifyContent) Self {
            var s = self;
            s.style().justify_content = v;
            return s;
        }
        pub fn justifyStart(self: Self) Self {
            return justify(self, .start);
        }
        pub fn justifyEnd(self: Self) Self {
            return justify(self, .end);
        }
        pub fn justifyCenter(self: Self) Self {
            return justify(self, .center);
        }
        pub fn justifyBetween(self: Self) Self {
            return justify(self, .space_between);
        }
        pub fn justifyAround(self: Self) Self {
            return justify(self, .space_around);
        }
        pub fn justifyEvenly(self: Self) Self {
            return justify(self, .space_evenly);
        }
        fn alignContent(self: Self, v: ?style.AlignContent) Self {
            var s = self;
            s.style().align_content = v;
            return s;
        }
        /// Clears `align_content` (gpui sets it to `None`).
        pub fn contentNormal(self: Self) Self {
            return alignContent(self, null);
        }
        pub fn contentCenter(self: Self) Self {
            return alignContent(self, .center);
        }
        pub fn contentStart(self: Self) Self {
            return alignContent(self, .flex_start);
        }
        pub fn contentEnd(self: Self) Self {
            return alignContent(self, .flex_end);
        }
        pub fn contentBetween(self: Self) Self {
            return alignContent(self, .space_between);
        }
        pub fn contentAround(self: Self) Self {
            return alignContent(self, .space_around);
        }
        pub fn contentEvenly(self: Self) Self {
            return alignContent(self, .space_evenly);
        }
        pub fn contentStretch(self: Self) Self {
            return alignContent(self, .stretch);
        }

        pub fn aspectRatio(self: Self, ratio: f32) Self {
            var s = self;
            s.style().aspect_ratio = ratio;
            return s;
        }
        pub fn aspectSquare(self: Self) Self {
            return aspectRatio(self, 1);
        }

        // ---- paint ----

        /// Background fill: an `Hsla`, `Rgba` or `Background` (gradient/pattern).
        pub fn bg(self: Self, fill: anytype) Self {
            var s = self;
            s.style().background = switch (@TypeOf(fill)) {
                style.Background => fill,
                style.Hsla => style.Background.fromHsla(fill),
                @import("color.zig").Rgba => style.Background.fromRgba(fill),
                else => @compileError("bg expects Hsla, Rgba or Background"),
            };
            return s;
        }
        pub fn borderColor(self: Self, c: Hsla) Self {
            var s = self;
            s.style().border_color = c;
            return s;
        }
        pub fn borderDashed(self: Self) Self {
            var s = self;
            s.style().border_style = .dashed;
            return s;
        }
        /// Custom box shadows. The slice must outlive the frame.
        pub fn shadow(self: Self, list: []const style.BoxShadow) Self {
            var s = self;
            s.style().box_shadow = list;
            return s;
        }
        pub fn shadowNone(self: Self) Self {
            return shadow(self, &.{});
        }
        pub fn opacity(self: Self, value: f32) Self {
            var s = self;
            s.style().opacity = value;
            return s;
        }
        pub fn cursor(self: Self, c: style.CursorStyle) Self {
            var s = self;
            s.style().mouse_cursor = c;
            return s;
        }
        pub fn debug(self: Self) Self {
            var s = self;
            s.style().debug = true;
            return s;
        }
        pub fn debugBelow(self: Self) Self {
            var s = self;
            s.style().debug_below = true;
            return s;
        }

        // ---- text ----

        pub fn textColor(self: Self, c: Hsla) Self {
            return setText(self, "color", c);
        }
        pub fn textBg(self: Self, c: Hsla) Self {
            return setText(self, "background_color", c);
        }
        pub fn fontWeight(self: Self, w: style.FontWeight) Self {
            return setText(self, "font_weight", w);
        }
        /// Font size: `px(..)`, `rems(..)` or an `AbsoluteLength`.
        pub fn textSize(self: Self, size: anytype) Self {
            return setText(self, "font_size", AbsoluteLength.from(size));
        }
        pub fn textXs(self: Self) Self {
            return setText(self, "font_size", AbsoluteLength{ .rems = 0.75 });
        }
        pub fn textSm(self: Self) Self {
            return setText(self, "font_size", AbsoluteLength{ .rems = 0.875 });
        }
        pub fn textBase(self: Self) Self {
            return setText(self, "font_size", AbsoluteLength{ .rems = 1.0 });
        }
        pub fn textLg(self: Self) Self {
            return setText(self, "font_size", AbsoluteLength{ .rems = 1.125 });
        }
        pub fn textXl(self: Self) Self {
            return setText(self, "font_size", AbsoluteLength{ .rems = 1.25 });
        }
        pub fn text2xl(self: Self) Self {
            return setText(self, "font_size", AbsoluteLength{ .rems = 1.5 });
        }
        pub fn text3xl(self: Self) Self {
            return setText(self, "font_size", AbsoluteLength{ .rems = 1.875 });
        }
        pub fn italic(self: Self) Self {
            return setText(self, "font_style", style.FontStyle.italic);
        }
        pub fn notItalic(self: Self) Self {
            return setText(self, "font_style", style.FontStyle.normal);
        }
        pub fn underline(self: Self) Self {
            return setText(self, "underline", style.UnderlineStyle{ .thickness = 1 });
        }
        pub fn lineThrough(self: Self) Self {
            return setText(self, "strikethrough", style.StrikethroughStyle{ .thickness = 1 });
        }
        pub fn textDecorationNone(self: Self) Self {
            var s = self;
            s.style().text.underline = null;
            return s;
        }
        pub fn textDecorationColor(self: Self, c: Hsla) Self {
            var s = self;
            underlineMut(&s).color = c;
            return s;
        }
        pub fn textDecorationSolid(self: Self) Self {
            var s = self;
            underlineMut(&s).wavy = false;
            return s;
        }
        pub fn textDecorationWavy(self: Self) Self {
            var s = self;
            underlineMut(&s).wavy = true;
            return s;
        }
        fn decorationThickness(self: Self, t: f32) Self {
            var s = self;
            underlineMut(&s).thickness = t;
            return s;
        }
        pub fn textDecoration0(self: Self) Self {
            return decorationThickness(self, 0);
        }
        pub fn textDecoration1(self: Self) Self {
            return decorationThickness(self, 1);
        }
        pub fn textDecoration2(self: Self) Self {
            return decorationThickness(self, 2);
        }
        pub fn textDecoration4(self: Self) Self {
            return decorationThickness(self, 4);
        }
        pub fn textDecoration8(self: Self) Self {
            return decorationThickness(self, 8);
        }
        /// The string must outlive the element.
        pub fn fontFamily(self: Self, family: []const u8) Self {
            return setText(self, "font_family", family);
        }
        pub fn fontFeatures(self: Self, features: []const style.FontFeature) Self {
            return setText(self, "font_features", features);
        }
        /// Sets family, features, fallbacks, weight and style from a `Font`.
        pub fn font(self: Self, f: @import("text/types.zig").Font) Self {
            var s = self;
            const t = &s.style().text;
            t.font_family = f.family;
            t.font_features = f.features;
            t.font_fallbacks = if (f.fallbacks.len == 0) null else f.fallbacks;
            t.font_weight = f.weight;
            t.font_style = f.style;
            return s;
        }
        /// Line height: `px(..)`, `rems(..)` or `relative(..)` (fraction of the font size).
        pub fn lineHeight(self: Self, h: anytype) Self {
            return setText(self, "line_height", DefiniteLength.from(h));
        }
    };
}

/// Names of every builder method an element should forward (hand-written plus generated).
pub fn methodNames(comptime Self: type) []const []const u8 {
    const a = @typeInfo(Styled(Self)).@"struct".decl_names;
    const b = @typeInfo(Generated(Self)).@"struct".decl_names;
    var out: [a.len + b.len][]const u8 = undefined;
    for (a, 0..) |n, i| out[i] = n;
    for (b, 0..) |n, i| out[a.len + i] = n;
    const final = out;
    return &final;
}

/// Compile error listing the first missing forwarder if `T` lacks any styled method.
pub fn assertStyled(comptime T: type) void {
    @setEvalBranchQuota(100_000);
    for (methodNames(T)) |name| {
        if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ " is missing styled method `" ++ name ++ "`; run scripts/gen_styled.py --forward");
    }
}

// ---- tests ----

const testing = std.testing;
const geom = @import("geometry.zig");
const color = @import("color.zig");
const px = geom.px;
const rems = geom.rems;
const relative = geom.relative;

fn build(b: StyleBuilder) style.Style {
    var s: style.Style = .{};
    style.refinement.refine(&s, b.refinement);
    return s;
}

test "StyleBuilder forwards every styled method" {
    comptime assertStyled(StyleBuilder);
    try testing.expectEqual(generated.method_count, @typeInfo(Generated(StyleBuilder)).@"struct".decl_names.len);
}

test "builder chain produces expected style" {
    const card = color.hsla(0.6, 0.2, 0.1, 1);
    const s = build(StyleBuilder.init.flex().flexCol().gap(px(8)).p(px(12)).roundedLg().bg(card).shadowMd()
        .itemsCenter().justifyBetween().flex1().textColor(color.white).textSize(px(13)).fontWeight(500)
        .cursorPointer().overflowHidden().absolute().inset0().minW0().wFull().h(rems(2)).border1()
        .borderColor(color.red).opacity(0.5));
    try testing.expectEqual(style.Display.flex, s.display);
    try testing.expectEqual(style.FlexDirection.column, s.flex_direction);
    try testing.expectEqual(DefiniteLength{ .absolute = .{ .pixels = 8 } }, s.gap.width);
    try testing.expectEqual(DefiniteLength{ .absolute = .{ .pixels = 8 } }, s.gap.height);
    try testing.expectEqual(DefiniteLength{ .absolute = .{ .pixels = 12 } }, s.padding.left);
    try testing.expectEqual(AbsoluteLength{ .rems = 0.5 }, s.corner_radii.bottom_left);
    try testing.expect(s.background.?.asSolid().?.eql(card));
    try testing.expectEqual(@as(usize, 2), s.box_shadow.len);
    try testing.expectEqual(@as(?style.AlignItems, .center), s.align_items);
    try testing.expectEqual(@as(?style.JustifyContent, .space_between), s.justify_content);
    try testing.expectEqual(@as(f32, 1), s.flex_grow);
    try testing.expectEqual(Length{ .definite = .{ .fraction = 0 } }, s.flex_basis);
    try testing.expectEqual(@as(?style.FontWeight, 500), s.text.font_weight);
    try testing.expectEqual(@as(?AbsoluteLength, .{ .pixels = 13 }), s.text.font_size);
    try testing.expectEqual(@as(?style.CursorStyle, .pointing_hand), s.mouse_cursor);
    try testing.expectEqual(style.Overflow.hidden, s.overflow.y);
    try testing.expectEqual(style.Position.absolute, s.position);
    try testing.expectEqual(Length.zero, s.inset.right);
    try testing.expectEqual(Length.zero, s.min_size.width);
    try testing.expectEqual(Length{ .definite = relative(1) }, s.size.width);
    try testing.expectEqual(Length{ .definite = .{ .absolute = .{ .rems = 2 } } }, s.size.height);
    try testing.expectEqual(AbsoluteLength{ .pixels = 1 }, s.border_widths.top);
    try testing.expectEqual(@as(?f32, 0.5), s.opacity);
    try testing.expect(s.isBorderVisible());
}

test "generated scales use gpui values" {
    const s = build(StyleBuilder.init.p4().mxAuto().mtNeg2().w1_2().size1_12().gapX0p5().roundedFull().roundedTlNone()
        .borderT2().topPx().leftNeg1_3().text2xl().pt(4));
    try testing.expectEqual(DefiniteLength{ .absolute = .{ .rems = 1 } }, s.padding.bottom);
    try testing.expectEqual(DefiniteLength{ .absolute = .{ .pixels = 4 } }, s.padding.top);
    try testing.expectEqual(Length.auto, s.margin.left);
    try testing.expectEqual(Length{ .definite = .{ .absolute = .{ .rems = -0.5 } } }, s.margin.top);
    try testing.expectEqual(Length{ .definite = relative(1.0 / 12.0) }, s.size.height);
    try testing.expectEqual(DefiniteLength{ .absolute = .{ .rems = 0.125 } }, s.gap.width);
    try testing.expectEqual(DefiniteLength.zero, s.gap.height);
    try testing.expectEqual(AbsoluteLength{ .pixels = 9999 }, s.corner_radii.top_right);
    try testing.expectEqual(AbsoluteLength{ .pixels = 0 }, s.corner_radii.top_left);
    try testing.expectEqual(AbsoluteLength{ .pixels = 2 }, s.border_widths.top);
    try testing.expectEqual(AbsoluteLength.zero, s.border_widths.left);
    try testing.expectEqual(Length{ .definite = .{ .absolute = .{ .pixels = 1 } } }, s.inset.top);
    try testing.expectEqual(Length{ .definite = relative(-1.0 / 3.0) }, s.inset.left);
    try testing.expectEqual(@as(?AbsoluteLength, .{ .rems = 1.5 }), s.text.font_size);
}

test "text helpers" {
    const b = StyleBuilder.init.truncate().textDecorationWavy().textDecorationColor(color.red).italic().lineHeight(relative(1.5)).textCenter();
    const t = b.refinement.text;
    try testing.expectEqual(@as(?style.WhiteSpace, .nowrap), t.white_space);
    try testing.expectEqualStrings(style.ellipsis, t.text_overflow.?.truncate);
    try testing.expect(t.underline.?.wavy);
    try testing.expectEqual(@as(f32, 0), t.underline.?.thickness);
    try testing.expectEqual(@as(?style.FontStyle, .italic), t.font_style);
    try testing.expectEqual(@as(?DefiniteLength, .{ .fraction = 1.5 }), t.line_height);
    try testing.expectEqual(@as(?style.TextAlign, .center), t.text_align);
    try testing.expectEqual(@as(?style.Overflow, .hidden), b.refinement.overflow.x);
    const c = StyleBuilder.init.lineClamp(2).underline().textDecoration2();
    try testing.expectEqual(@as(?usize, 2), c.refinement.text.line_clamp);
    try testing.expectEqual(@as(f32, 2), c.refinement.text.underline.?.thickness);
}

test "shadow presets match gpui" {
    const sm = shadows.sm;
    try testing.expectEqual(@as(f32, 3), sm[0].blur_radius);
    try testing.expectEqual(@as(f32, -1), sm[1].spread_radius);
    try testing.expectEqual(@as(f32, 0.1), sm[1].color.a);
    const lg = shadows.lg;
    try testing.expectEqual(@as(f32, 10), lg[0].offset.y);
    try testing.expectEqual(@as(f32, 15), lg[0].blur_radius);
    try testing.expectEqual(@as(f32, -3), lg[0].spread_radius);
    try testing.expectEqual(@as(f32, -4), lg[1].spread_radius);
    try testing.expectEqual(@as(f32, 0.25), shadows.@"2xl"[0].color.a);
    try testing.expectEqual(@as(f32, 50), shadows.@"2xl"[0].blur_radius);
    try testing.expectEqual(@as(f32, 0.05), shadows.@"2xs"[0].color.a);
    try testing.expect(!shadows.md[0].inset);
    try testing.expectEqual(@as(usize, 0), StyleBuilder.init.shadowXl().shadowNone().refinement.box_shadow.?.len);
}

test "element mixin: by-value chaining keeps element fields" {
    const Elem = struct {
        id: u32 = 0,
        base: StyleRefinement = .{},
        hover: StyleRefinement = .{},

        const Self = @This();
        pub fn style(self: *Self) *StyleRefinement {
            return &self.base;
        }
        pub fn onHover(self: Self, b: StyleBuilder) Self {
            var s = self;
            s.hover = b.refinement;
            return s;
        }
        const S = Styled(Self);
        const G = Generated(Self);
        pub const flex = S.flex;
        pub const bg = S.bg;
        pub const p2 = G.p2;
        pub const size = G.size;
    };
    const e = (Elem{ .id = 7 }).flex().p2().size(px(20)).onHover(StyleBuilder.init.bg(color.red)).bg(color.blue);
    try testing.expectEqual(@as(u32, 7), e.id);
    var s: style.Style = .{};
    style.refinement.refine(&s, e.base);
    style.refinement.refine(&s, e.hover);
    try testing.expect(s.background.?.asSolid().?.eql(color.red));
    try testing.expectEqual(Length{ .definite = .{ .absolute = .{ .pixels = 20 } } }, s.size.height);
    try testing.expectEqual(DefiniteLength{ .absolute = .{ .rems = 0.5 } }, s.padding.right);
    // Layout conversion of a built style.
    const l = s.toLayoutStyle(16, 1);
    try testing.expectEqual(@import("layout/style.zig").LengthPercentage{ .px = 8 }, l.padding.right);
}
