//! Shaped lines ready for hit testing and painting (gpui `text_system/line.rs`).
//!
//! Painting goes through `GlyphPainter`, a small interface the Window implements,
//! so text does not depend on the window/scene machinery.

const std = @import("std");
const types = @import("types.zig");
const geometry = @import("../geometry.zig");
const color_mod = @import("../color.zig");
const line_layout = @import("line_layout.zig");
const text_system_mod = @import("text_system.zig");

const Allocator = std.mem.Allocator;
const Pixels = types.Pixels;
const ScaledPixels = geometry.ScaledPixels;
const Point = geometry.Point(Pixels);
const Size = geometry.Size(Pixels);
const Bounds = geometry.Bounds(Pixels);
const Hsla = color_mod.Hsla;
const FontId = types.FontId;
const GlyphId = types.GlyphId;
const LineLayout = types.LineLayout;
const RenderGlyphParams = types.RenderGlyphParams;
const UnderlineStyle = types.UnderlineStyle;
const StrikethroughStyle = types.StrikethroughStyle;
const WrapBoundary = line_layout.WrapBoundary;
const SharedLineLayout = line_layout.SharedLineLayout;
const SharedWrappedLayout = line_layout.SharedWrappedLayout;
const TextSystem = text_system_mod.TextSystem;

pub const TextAlign = enum { left, center, right };

/// Style of a span of a shaped line (gpui `DecorationRun`).
pub const DecorationRun = struct {
    len: u32,
    color: Hsla,
    background_color: ?Hsla = null,
    underline: ?UnderlineStyle = null,
    strikethrough: ?StrikethroughStyle = null,

    pub fn sameStyle(a: DecorationRun, b: types.TextRun) bool {
        return a.color.eql(b.color) and std.meta.eql(a.underline, b.underline) and
            std.meta.eql(a.strikethrough, b.strikethrough) and std.meta.eql(a.background_color, b.background_color);
    }
};

/// Paint sink for text, implemented by the Window (scene emission, atlas, content mask).
pub const GlyphPainter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// Used for `boundingBox` culling and decoration sizing.
    text_system: *TextSystem,
    scale_factor: f32 = 1,
    /// Request LCD subpixel (SubpixelSprite) instead of grayscale glyphs.
    subpixel_rendering: bool = false,
    /// Visible region in logical pixels; glyphs fully outside are skipped. Null = no culling.
    content_mask: ?Bounds = null,

    pub const VTable = struct {
        /// Paint a monochrome glyph. `origin` is the integer device-pixel baseline origin;
        /// the sprite goes at `origin + rasterBounds(params).origin` (see `TextSystem.rasterizeToAtlas`).
        paintGlyph: *const fn (ptr: *anyopaque, params: RenderGlyphParams, origin: geometry.Point(ScaledPixels), color: Hsla) anyerror!void,
        /// Paint a color emoji glyph (PolychromeSprite), same origin convention as `paintGlyph`.
        paintEmoji: *const fn (ptr: *anyopaque, params: RenderGlyphParams, origin: geometry.Point(ScaledPixels)) anyerror!void,
        /// Solid fill in logical pixels (text backgrounds).
        paintQuad: *const fn (ptr: *anyopaque, bounds: Bounds, color: Hsla) anyerror!void,
        /// Underline starting at `origin` (logical px, top edge), `width` long. `style.color` is set.
        paintUnderline: *const fn (ptr: *anyopaque, origin: Point, width: Pixels, style: UnderlineStyle) anyerror!void,
        paintStrikethrough: *const fn (ptr: *anyopaque, origin: Point, width: Pixels, style: StrikethroughStyle) anyerror!void,
    };

    /// gpui `Window::paint_glyph` quantization: snap to 1/4 device px horizontally.
    pub fn paintGlyph(self: GlyphPainter, origin: Point, font_id: FontId, glyph_id: GlyphId, font_size: Pixels, color: Hsla) !void {
        var g = glyphRenderParams(font_id, glyph_id, font_size, origin, self.scale_factor, self.subpixel_rendering);
        g.params.dilation = self.text_system.glyphDilation(color);
        try self.vtable.paintGlyph(self.ptr, g.params, g.origin, color);
    }

    pub fn paintEmoji(self: GlyphPainter, origin: Point, font_id: FontId, glyph_id: GlyphId, font_size: Pixels) !void {
        const s = self.scale_factor;
        const params: RenderGlyphParams = .{
            .font_id = font_id,
            .glyph_id = glyph_id,
            .font_size = font_size,
            .subpixel_variant_x = 0,
            .subpixel_variant_y = 0,
            .is_emoji = true,
            .subpixel_rendering = false,
            .scale_factor = s,
        };
        try self.vtable.paintEmoji(self.ptr, params, .{ .x = roundHalfTowardZero(origin.x * s), .y = roundHalfTowardZero(origin.y * s) });
    }
};

pub fn roundHalfTowardZero(x: f32) f32 {
    return if (x > 0) @ceil(x - 0.5) else @floor(x + 0.5);
}

pub const GlyphRender = struct { params: RenderGlyphParams, origin: geometry.Point(ScaledPixels) };

/// RenderGlyphParams and integer device origin for a glyph whose baseline origin is `origin` (logical px).
pub fn glyphRenderParams(font_id: FontId, glyph_id: GlyphId, font_size: Pixels, origin: Point, scale_factor: f32, subpixel_rendering: bool) GlyphRender {
    const vx: f32 = @floatFromInt(types.subpixel_variants_x);
    const vy: f32 = @floatFromInt(types.subpixel_variants_y);
    const qx = roundHalfTowardZero(origin.x * scale_factor * vx) / vx;
    const qy = roundHalfTowardZero(origin.y * scale_factor * vy) / vy;
    const fx = @max(qx - @trunc(qx), 0);
    const fy = @max(qy - @trunc(qy), 0);
    return .{
        .params = .{
            .font_id = font_id,
            .glyph_id = glyph_id,
            .font_size = font_size,
            .subpixel_variant_x = @intFromFloat(@min(fx * vx, vx - 1)),
            .subpixel_variant_y = @intFromFloat(@min(fy * vy, vy - 1)),
            .is_emoji = false,
            .subpixel_rendering = subpixel_rendering,
            .scale_factor = scale_factor,
        },
        .origin = .{ .x = @trunc(qx), .y = @trunc(qy) },
    };
}

/// gpui `ShapedLine`: one shaped line plus its decoration runs. Owns its text and
/// runs and a reference to the layout; call `deinit`.
pub const ShapedLine = struct {
    layout: *SharedLineLayout,
    text: []const u8,
    decoration_runs: []DecorationRun,

    pub fn deinit(self: ShapedLine, gpa: Allocator) void {
        self.layout.release();
        gpa.free(self.text);
        gpa.free(self.decoration_runs);
    }

    pub fn lineLayout(self: ShapedLine) *const LineLayout {
        return &self.layout.layout;
    }
    pub fn len(self: ShapedLine) usize {
        return self.layout.layout.len;
    }
    pub fn width(self: ShapedLine) Pixels {
        return self.layout.layout.width;
    }
    pub fn xForIndex(self: ShapedLine, index: usize) Pixels {
        return line_layout.xForIndex(self.lineLayout(), index);
    }
    pub fn indexForX(self: ShapedLine, x: Pixels) ?usize {
        return line_layout.indexForX(self.lineLayout(), x);
    }
    pub fn closestIndexForX(self: ShapedLine, x: Pixels) usize {
        return line_layout.closestIndexForX(self.lineLayout(), x);
    }

    pub fn paint(self: ShapedLine, painter: GlyphPainter, origin: Point, line_height: Pixels, alignment: TextAlign, align_width: ?Pixels) !void {
        try paintLine(painter, origin, self.lineLayout(), line_height, alignment, align_width, self.decoration_runs, &.{});
    }

    pub fn paintBackground(self: ShapedLine, painter: GlyphPainter, origin: Point, line_height: Pixels, alignment: TextAlign, align_width: ?Pixels) !void {
        try paintLineBackground(painter, origin, self.lineLayout(), line_height, alignment, align_width, self.decoration_runs, &.{});
    }
};

/// gpui `WrappedLine`: a soft-wrapped logical line (one paragraph between '\n's).
pub const WrappedLine = struct {
    layout: *SharedWrappedLayout,
    text: []const u8,
    decoration_runs: []DecorationRun,

    pub fn deinit(self: WrappedLine, gpa: Allocator) void {
        self.layout.release();
        gpa.free(self.text);
        gpa.free(self.decoration_runs);
    }

    pub fn len(self: WrappedLine) usize {
        return self.layout.len();
    }
    pub fn width(self: WrappedLine) Pixels {
        return self.layout.width();
    }
    pub fn size(self: WrappedLine, line_height: Pixels) Size {
        return self.layout.size(line_height);
    }
    pub fn wrapBoundaries(self: WrappedLine) []const WrapBoundary {
        return self.layout.wrap_boundaries;
    }
    pub fn positionForIndex(self: WrappedLine, index: usize, line_height: Pixels) ?Point {
        return self.layout.positionForIndex(index, line_height);
    }
    pub fn indexForPosition(self: WrappedLine, position: Point, line_height: Pixels) SharedWrappedLayout.PositionIndex {
        return self.layout.indexForPosition(position, line_height);
    }
    pub fn closestIndexForPosition(self: WrappedLine, position: Point, line_height: Pixels) SharedWrappedLayout.PositionIndex {
        return self.layout.closestIndexForPosition(position, line_height);
    }

    pub fn paint(self: WrappedLine, painter: GlyphPainter, origin: Point, line_height: Pixels, alignment: TextAlign, bounds: ?Bounds) !void {
        const align_width = if (bounds) |b| b.size.width else self.layout.wrap_width;
        try paintLine(painter, origin, self.layout.layout(), line_height, alignment, align_width, self.decoration_runs, self.layout.wrap_boundaries);
    }

    pub fn paintBackground(self: WrappedLine, painter: GlyphPainter, origin: Point, line_height: Pixels, alignment: TextAlign, bounds: ?Bounds) !void {
        const align_width = if (bounds) |b| b.size.width else self.layout.wrap_width;
        try paintLineBackground(painter, origin, self.layout.layout(), line_height, alignment, align_width, self.decoration_runs, self.layout.wrap_boundaries);
    }
};

fn alignedOriginX(origin: Point, align_width: Pixels, last_glyph_x: Pixels, alignment: TextAlign, layout: *const LineLayout, wrap: ?WrapBoundary) Pixels {
    const end_of_line = if (wrap) |w| line_layout.glyphAt(layout, w).position.x else layout.width;
    const line_width = end_of_line - last_glyph_x;
    return switch (alignment) {
        .left => origin.x,
        .center => (origin.x * 2 + align_width - line_width) / 2,
        .right => origin.x + align_width - line_width,
    };
}

const PendingUnderline = struct { origin: Point, style: UnderlineStyle };
const PendingStrike = struct { origin: Point, style: StrikethroughStyle };

/// Iterates decoration runs alongside glyphs (the shared "style run" walk of gpui's paint functions).
const StyleCursor = struct {
    runs: []const DecorationRun,
    next_ix: usize = 0,
    run_end: usize = 0,

    /// Advance past runs that end at or before `glyph_index`; returns the run covering it,
    /// or null when runs are exhausted (gpui sets `run_end = layout.len` then).
    fn advance(self: *StyleCursor, glyph_index: usize, layout_len: usize) ?DecorationRun {
        while (self.next_ix < self.runs.len) {
            const run = self.runs[self.next_ix];
            self.next_ix += 1;
            if (glyph_index < self.run_end + run.len) {
                self.run_end += run.len;
                return run;
            }
            self.run_end += run.len;
        }
        self.run_end = layout_len;
        return null;
    }
};

fn paintLine(
    painter: GlyphPainter,
    origin: Point,
    layout: *const LineLayout,
    line_height: Pixels,
    alignment: TextAlign,
    align_width: ?Pixels,
    decoration_runs: []const DecorationRun,
    wrap_boundaries: []const WrapBoundary,
) !void {
    const padding_top = (line_height - layout.ascent - layout.descent) / 2;
    const baseline_y = padding_top + layout.ascent;
    var styles: StyleCursor = .{ .runs = decoration_runs };
    var wrap_ix: usize = 0;
    var color: Hsla = color_mod.black;
    var current_underline: ?PendingUnderline = null;
    var current_strike: ?PendingStrike = null;
    const aw = align_width orelse layout.width;
    var glyph_origin: Point = .{
        .x = alignedOriginX(origin, aw, 0, alignment, layout, peekWrap(wrap_boundaries, wrap_ix)),
        .y = origin.y,
    };
    var prev_glyph_position: Point = .zero;
    var max_glyph_size: Size = .zero;
    var first_glyph_x = origin.x;

    for (layout.runs, 0..) |run, run_ix| {
        max_glyph_size = painter.text_system.boundingBox(run.font_id, layout.font_size).size;
        for (run.glyphs, 0..) |glyph, glyph_ix| {
            glyph_origin.x += glyph.position.x - prev_glyph_position.x;
            if (glyph_ix == 0 and run_ix == 0) first_glyph_x = glyph_origin.x;

            if (peekWrap(wrap_boundaries, wrap_ix)) |w| if (w.eql(.{ .run_ix = run_ix, .glyph_ix = glyph_ix })) {
                wrap_ix += 1;
                if (current_underline) |*u| {
                    if (glyph_origin.x == u.origin.x) u.origin.x -= max_glyph_size.width / 2;
                    try painter.vtable.paintUnderline(painter.ptr, u.origin, glyph_origin.x - u.origin.x, u.style);
                    if (glyph.index < styles.run_end) {
                        u.origin.x = origin.x;
                        u.origin.y += line_height;
                    } else current_underline = null;
                }
                if (current_strike) |*s| {
                    if (glyph_origin.x == s.origin.x) s.origin.x -= max_glyph_size.width / 2;
                    try painter.vtable.paintStrikethrough(painter.ptr, s.origin, glyph_origin.x - s.origin.x, s.style);
                    if (glyph.index < styles.run_end) {
                        s.origin.x = origin.x;
                        s.origin.y += line_height;
                    } else current_strike = null;
                }
                glyph_origin.x = alignedOriginX(origin, aw, glyph.position.x, alignment, layout, peekWrap(wrap_boundaries, wrap_ix));
                glyph_origin.y += line_height;
            };
            prev_glyph_position = glyph.position;

            var finished_underline: ?PendingUnderline = null;
            var finished_strike: ?PendingStrike = null;
            if (glyph.index >= styles.run_end) {
                if (styles.advance(glyph.index, layout.len)) |style_run| {
                    if (current_underline) |u| {
                        if (style_run.underline == null or !std.meta.eql(withColor(style_run.underline.?, style_run.color), u.style)) {
                            finished_underline = u;
                            current_underline = null;
                        }
                    }
                    if (style_run.underline) |ul| if (current_underline == null) {
                        current_underline = .{
                            .origin = .{ .x = glyph_origin.x, .y = glyph_origin.y + baseline_y + layout.descent * 0.618 },
                            .style = withColor(ul, style_run.color),
                        };
                    };
                    if (current_strike) |s| {
                        if (style_run.strikethrough == null or !std.meta.eql(strikeWithColor(style_run.strikethrough.?, style_run.color), s.style)) {
                            finished_strike = s;
                            current_strike = null;
                        }
                    }
                    if (style_run.strikethrough) |st| if (current_strike == null) {
                        current_strike = .{
                            .origin = .{ .x = glyph_origin.x, .y = glyph_origin.y + ((layout.ascent * 0.5) + baseline_y) * 0.5 },
                            .style = strikeWithColor(st, style_run.color),
                        };
                    };
                    color = style_run.color;
                } else {
                    finished_underline = current_underline;
                    finished_strike = current_strike;
                    current_underline = null;
                    current_strike = null;
                }
            }

            if (finished_underline) |fu| {
                var u = fu;
                if (u.origin.x == glyph_origin.x) u.origin.x -= max_glyph_size.width / 2;
                try painter.vtable.paintUnderline(painter.ptr, u.origin, glyph_origin.x - u.origin.x, u.style);
            }
            if (finished_strike) |fs| {
                var s = fs;
                if (s.origin.x == glyph_origin.x) s.origin.x -= max_glyph_size.width / 2;
                try painter.vtable.paintStrikethrough(painter.ptr, s.origin, glyph_origin.x - s.origin.x, s.style);
            }

            const max_glyph_bounds: Bounds = .{ .origin = glyph_origin, .size = max_glyph_size };
            const visible = if (painter.content_mask) |mask| max_glyph_bounds.intersects(mask) else true;
            if (visible) {
                const p: Point = .{ .x = glyph_origin.x, .y = glyph_origin.y + baseline_y + glyph.position.y };
                if (glyph.is_emoji) {
                    try painter.paintEmoji(p, run.font_id, glyph.id, layout.font_size);
                } else {
                    try painter.paintGlyph(p, run.font_id, glyph.id, layout.font_size, color);
                }
            }
        }
    }

    var last_line_end_x = first_glyph_x + layout.width;
    if (wrap_boundaries.len > 0) last_line_end_x -= line_layout.glyphAt(layout, wrap_boundaries[wrap_boundaries.len - 1]).position.x;

    if (current_underline) |cu| {
        var u = cu;
        if (last_line_end_x == u.origin.x) u.origin.x -= max_glyph_size.width / 2;
        try painter.vtable.paintUnderline(painter.ptr, u.origin, last_line_end_x - u.origin.x, u.style);
    }
    if (current_strike) |cs| {
        var s = cs;
        if (last_line_end_x == s.origin.x) s.origin.x -= max_glyph_size.width / 2;
        try painter.vtable.paintStrikethrough(painter.ptr, s.origin, last_line_end_x - s.origin.x, s.style);
    }
}

fn withColor(u: UnderlineStyle, fallback_color: Hsla) UnderlineStyle {
    return .{ .color = u.color orelse fallback_color, .thickness = u.thickness, .wavy = u.wavy };
}

fn strikeWithColor(s: StrikethroughStyle, fallback_color: Hsla) StrikethroughStyle {
    return .{ .color = s.color orelse fallback_color, .thickness = s.thickness };
}

fn peekWrap(wraps: []const WrapBoundary, ix: usize) ?WrapBoundary {
    return if (ix < wraps.len) wraps[ix] else null;
}

fn paintLineBackground(
    painter: GlyphPainter,
    origin: Point,
    layout: *const LineLayout,
    line_height: Pixels,
    alignment: TextAlign,
    align_width: ?Pixels,
    decoration_runs: []const DecorationRun,
    wrap_boundaries: []const WrapBoundary,
) !void {
    const Bg = struct { origin: Point, color: Hsla };
    var styles: StyleCursor = .{ .runs = decoration_runs };
    var wrap_ix: usize = 0;
    var current: ?Bg = null;
    const aw = align_width orelse layout.width;
    var glyph_origin: Point = .{
        .x = alignedOriginX(origin, aw, 0, alignment, layout, peekWrap(wrap_boundaries, wrap_ix)),
        .y = origin.y,
    };
    var prev_glyph_position: Point = .zero;
    var max_glyph_size: Size = .zero;

    for (layout.runs, 0..) |run, run_ix| {
        max_glyph_size = painter.text_system.boundingBox(run.font_id, layout.font_size).size;
        for (run.glyphs, 0..) |glyph, glyph_ix| {
            glyph_origin.x += glyph.position.x - prev_glyph_position.x;
            if (peekWrap(wrap_boundaries, wrap_ix)) |w| if (w.eql(.{ .run_ix = run_ix, .glyph_ix = glyph_ix })) {
                wrap_ix += 1;
                if (current) |*bg| {
                    if (glyph_origin.x == bg.origin.x) bg.origin.x -= max_glyph_size.width / 2;
                    try painter.vtable.paintQuad(painter.ptr, .{ .origin = bg.origin, .size = .{ .width = glyph_origin.x - bg.origin.x, .height = line_height } }, bg.color);
                    if (glyph.index < styles.run_end) {
                        bg.origin.x = origin.x;
                        bg.origin.y += line_height;
                    } else current = null;
                }
                glyph_origin.x = alignedOriginX(origin, aw, glyph.position.x, alignment, layout, peekWrap(wrap_boundaries, wrap_ix));
                glyph_origin.y += line_height;
            };
            prev_glyph_position = glyph.position;

            var finished: ?Bg = null;
            if (glyph.index >= styles.run_end) {
                if (styles.advance(glyph.index, layout.len)) |style_run| {
                    if (current) |bg| {
                        if (style_run.background_color == null or !style_run.background_color.?.eql(bg.color)) {
                            finished = bg;
                            current = null;
                        }
                    }
                    if (style_run.background_color) |c| if (current == null) {
                        current = .{ .origin = glyph_origin, .color = c };
                    };
                } else {
                    finished = current;
                    current = null;
                }
            }
            if (finished) |f| {
                var bg = f;
                const w = glyph_origin.x - bg.origin.x;
                if (bg.origin.x == glyph_origin.x) bg.origin.x -= max_glyph_size.width / 2;
                try painter.vtable.paintQuad(painter.ptr, .{ .origin = bg.origin, .size = .{ .width = w, .height = line_height } }, bg.color);
            }
        }
    }

    var last_line_end_x = origin.x + layout.width;
    if (wrap_boundaries.len > 0) last_line_end_x -= line_layout.glyphAt(layout, wrap_boundaries[wrap_boundaries.len - 1]).position.x;
    if (current) |cb| {
        var bg = cb;
        if (last_line_end_x == bg.origin.x) bg.origin.x -= max_glyph_size.width / 2;
        try painter.vtable.paintQuad(painter.ptr, .{ .origin = bg.origin, .size = .{ .width = last_line_end_x - bg.origin.x, .height = line_height } }, bg.color);
    }
}
