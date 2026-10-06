//! The window's paint API (gpui `Window::paint_*`, including the zui fork's inset shadows,
//! backdrop blur, edge fades and masked images). Everything takes logical pixels, applies
//! the current content mask, element opacity and edge fade, snaps to device pixels and
//! inserts primitives into the next frame's scene. Paint phase only.

const std = @import("std");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");
const scene = @import("../scene.zig");
const three = @import("../three/three.zig");
const style_mod = @import("../style.zig");
const text_mod = @import("../text/text.zig");
const App = @import("../app/app.zig").App;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const image = @import("../image/image.zig");
const image_glue = @import("image.zig");

const Pixels = geometry.Pixels;
const ScaledPixels = geometry.ScaledPixels;
const Point = geometry.Point(Pixels);
const Size = geometry.Size(Pixels);
const Bounds = geometry.Bounds(Pixels);
const SBounds = geometry.Bounds(ScaledPixels);
const Edges = geometry.Edges(Pixels);
const Corners = geometry.Corners(Pixels);
const Hsla = color.Hsla;
const Background = color.Background;
const BoxShadow = style_mod.BoxShadow;
const Style = style_mod.Style;

const roundHalf = style_mod.roundHalfTowardZero;

/// Arguments of `paintQuad` (gpui `PaintQuad`); see `fill`, `outline`, `quad`.
pub const PaintQuad = struct {
    bounds: Bounds,
    corner_radii: Corners = .all(0),
    background: Background = .{},
    border_widths: Edges = .all(0),
    border_color: Hsla = .{},
    border_style: scene.BorderStyle = .solid,

    pub fn cornerRadii(self: PaintQuad, r: anytype) PaintQuad {
        var q = self;
        q.corner_radii = if (@TypeOf(r) == Corners) r else .all(r);
        return q;
    }
    pub fn borderWidths(self: PaintQuad, w: anytype) PaintQuad {
        var q = self;
        q.border_widths = if (@TypeOf(w) == Edges) w else .all(w);
        return q;
    }
    pub fn borderColor(self: PaintQuad, c: Hsla) PaintQuad {
        var q = self;
        q.border_color = c;
        return q;
    }
};

fn toBackground(bg: anytype) Background {
    return if (@TypeOf(bg) == Background) bg else color.solidBackground(bg);
}

/// A filled rectangle (gpui `fill`). `bg` is an `Hsla` or `Background`.
pub fn fill(bounds: Bounds, bg: anytype) PaintQuad {
    return .{ .bounds = bounds, .background = toBackground(bg) };
}

/// A 1px rectangle outline (gpui `outline`).
pub fn outline(bounds: Bounds, border_color: Hsla, border_style: scene.BorderStyle) PaintQuad {
    return .{ .bounds = bounds, .border_widths = .all(1), .border_color = border_color, .border_style = border_style };
}

/// gpui `quad`.
pub fn quad(bounds: Bounds, radii: Corners, bg: anytype, widths: Edges, border_color: Hsla, border_style: scene.BorderStyle) PaintQuad {
    return .{ .bounds = bounds, .corner_radii = radii, .background = toBackground(bg), .border_widths = widths, .border_color = border_color, .border_style = border_style };
}

// ---- device-pixel snapping (gpui util.rs / window.rs helpers) ------------------------

fn snapBounds(w: *const Window, b: Bounds) SBounds {
    const s = w.scale_factor;
    const l = roundHalf(b.origin.x * s);
    const t = roundHalf(b.origin.y * s);
    const r = @max(roundHalf(b.right() * s), l);
    const btm = @max(roundHalf(b.bottom() * s), t);
    return .fromCorners(.{ .x = l, .y = t }, .{ .x = r, .y = btm });
}

fn coverBounds(w: *const Window, b: Bounds) SBounds {
    const s = w.scale_factor;
    const l = @floor(b.origin.x * s);
    const t = @floor(b.origin.y * s);
    const r = @max(@ceil(b.right() * s), l);
    const btm = @max(@ceil(b.bottom() * s), t);
    return .fromCorners(.{ .x = l, .y = t }, .{ .x = r, .y = btm });
}

fn snapStroke(w: *const Window, v: Pixels) ScaledPixels {
    if (v == 0) return 0;
    return @max(roundHalf(@max(v, 0) * w.scale_factor), 1);
}

fn snappedContentMask(w: *const Window) scene.ContentMask {
    return .{ .bounds = coverBounds(w, w.contentMask().bounds) };
}

fn scaleCorners(c: Corners, s: f32) geometry.Corners(ScaledPixels) {
    return .{ .top_left = c.top_left * s, .top_right = c.top_right * s, .bottom_right = c.bottom_right * s, .bottom_left = c.bottom_left * s };
}

fn dilate(b: Bounds, amount: Pixels) Bounds {
    return .{
        .origin = .{ .x = b.origin.x - amount, .y = b.origin.y - amount },
        .size = .{ .width = b.size.width + 2 * amount, .height = b.size.height + 2 * amount },
    };
}

/// Device-pixel edge-fade parameters for the shaders (gpui `scaled_edge_fade`).
fn scaledEdgeFade(w: *const Window) scene.EdgeFadeParams {
    const f = w.edge_fade orelse return .{};
    if (!(f.top or f.bottom or f.left or f.right)) return .{};
    const s = w.scale_factor;
    return .{
        .top_y = f.bounds.origin.y * s,
        .bottom_y = f.bounds.bottom() * s,
        .band_top = if (f.top) f.topBand() * s else 0,
        .band_bottom = if (f.bottom) f.bottomBand() * s else 0,
        .left_x = f.bounds.origin.x * s,
        .right_x = f.bounds.right() * s,
        .band_left = if (f.left) f.leftBand() * s else 0,
        .band_right = if (f.right) f.rightBand() * s else 0,
    };
}

fn assertPaint(w: *const Window) void {
    if (w.phase != .paint) std.debug.panic("paint API used outside the paint phase (phase = {t})", .{w.phase});
}

fn sceneOf(w: *Window) *scene.Scene {
    return &w.next_frame.scene;
}

// ---- primitives ------------------------------------------------------------------------

/// Paint a rectangle with optional rounded corners, fill and border (gpui `paint_quad`).
pub fn paintQuad(w: *Window, q: PaintQuad) void {
    assertPaint(w);
    const s = w.scale_factor;
    const opacity = w.element_opacity;
    const sq: scene.Quad = .{
        .bounds = snapBounds(w, q.bounds),
        .content_mask = snappedContentMask(w),
        .background = q.background.opacity(opacity),
        .border_color = q.border_color.opacity(opacity),
        .corner_radii = scaleCorners(q.corner_radii, s),
        .border_widths = .{
            .top = snapStroke(w, q.border_widths.top),
            .right = snapStroke(w, q.border_widths.right),
            .bottom = snapStroke(w, q.border_widths.bottom),
            .left = snapStroke(w, q.border_widths.left),
        },
        .border_style = q.border_style,
        .fade = scaledEdgeFade(w),
    };
    const gpa = w.gpa;
    if (!sq.background.isTransparent()) {
        sceneOf(w).insertQuad(gpa, sq) catch @panic("OOM");
        return;
    }
    // Border without fill: paint four strips instead of running the shader over the
    // transparent interior (gpui does the same).
    const r = sq.corner_radii;
    const bw = sq.border_widths;
    const outer = sq.bounds;
    const tl: geometry.Point(f32) = .{ .x = outer.origin.x + bw.left + 1, .y = outer.origin.y + @max(bw.top, r.top_left, r.top_right) + 1 };
    const br: geometry.Point(f32) = .{ .x = outer.right() - bw.right - 1, .y = outer.bottom() - @max(bw.bottom, r.bottom_left, r.bottom_right) - 1 };
    if (br.x <= tl.x or br.y <= tl.y) {
        sceneOf(w).insertQuad(gpa, sq) catch @panic("OOM");
        return;
    }
    const inner: SBounds = .fromCorners(tl, br);
    const strips = [_]SBounds{
        .fromCorners(outer.origin, .{ .x = outer.right(), .y = inner.origin.y }),
        .fromCorners(.{ .x = outer.origin.x, .y = inner.bottom() }, .{ .x = outer.right(), .y = outer.bottom() }),
        .fromCorners(.{ .x = outer.origin.x, .y = inner.origin.y }, .{ .x = inner.origin.x, .y = inner.bottom() }),
        .fromCorners(.{ .x = inner.right(), .y = inner.origin.y }, .{ .x = outer.right(), .y = inner.bottom() }),
    };
    for (strips) |strip| {
        const mask = sq.content_mask.bounds.intersect(strip);
        if (mask.isEmpty()) continue;
        var part = sq;
        part.content_mask = .{ .bounds = mask };
        sceneOf(w).insertQuad(gpa, part) catch @panic("OOM");
    }
}

/// Paint the non-inset `shadows` (before the background).
pub fn paintDropShadows(w: *Window, bounds: Bounds, radii: Corners, shadows: []const BoxShadow) void {
    paintShadowList(w, bounds, radii, shadows, false);
}

/// Paint the inset `shadows` (after the background).
pub fn paintInsetShadows(w: *Window, bounds: Bounds, radii: Corners, shadows: []const BoxShadow) void {
    paintShadowList(w, bounds, radii, shadows, true);
}

/// Drop then inset shadows (for elements without a fill between them).
pub fn paintShadows(w: *Window, bounds: Bounds, radii: Corners, shadows: []const BoxShadow) void {
    paintDropShadows(w, bounds, radii, shadows);
    paintInsetShadows(w, bounds, radii, shadows);
}

fn paintShadowList(w: *Window, bounds: Bounds, radii: Corners, shadows: []const BoxShadow, inset: bool) void {
    assertPaint(w);
    const s = w.scale_factor;
    const mask = snappedContentMask(w);
    const opacity = w.elementOpacityForBounds(bounds);
    const element_bounds = coverBounds(w, bounds);
    const element_radii = scaleCorners(radii, s);
    for (shadows) |sh| {
        if (sh.inset != inset) continue;
        const moved: Bounds = .{ .origin = bounds.origin.add(sh.offset), .size = bounds.size };
        var prim: scene.Shadow = .{
            .blur_radius = sh.blur_radius * s,
            .content_mask = mask,
            .color = sh.color.opacity(opacity),
            .element_bounds = element_bounds,
            .element_corner_radii = element_radii,
            .inset = @intFromBool(inset),
        };
        if (inset) {
            const sp = sh.spread_radius;
            prim.bounds = coverBounds(w, dilate(moved, -sp));
            prim.corner_radii = scaleCorners(.{
                .top_left = @max(radii.top_left - sp, 0),
                .top_right = @max(radii.top_right - sp, 0),
                .bottom_right = @max(radii.bottom_right - sp, 0),
                .bottom_left = @max(radii.bottom_left - sp, 0),
            }, s);
        } else {
            prim.bounds = coverBounds(w, dilate(moved, sh.spread_radius));
            prim.corner_radii = element_radii;
        }
        sceneOf(w).insertShadow(w.gpa, prim) catch @panic("OOM");
    }
}

/// Blur what was painted beneath `bounds` (frosted glass; zui fork `paint_backdrop_blur`).
pub fn paintBackdropBlur(w: *Window, bounds: Bounds, radii: Corners, blur_radius: Pixels) void {
    assertPaint(w);
    const s = w.scale_factor;
    const mask: scene.ContentMask = .{ .bounds = w.contentMask().bounds.scale(s) };
    const sb = bounds.scale(s);
    const sr = scaleCorners(radii, s);
    // Invisible splitter so the renderer can break its pass exactly here.
    sceneOf(w).insertShadow(w.gpa, .{
        .bounds = sb,
        .corner_radii = sr,
        .content_mask = mask,
        .color = color.transparent_black,
        .element_bounds = sb,
        .element_corner_radii = sr,
    }) catch @panic("OOM");
    sceneOf(w).insertBackdropBlur(w.gpa, .{ .blur_radius = blur_radius * s, .bounds = sb, .content_mask = mask, .corner_radii = sr }) catch @panic("OOM");
}

/// Paint a vector path given in logical pixels (gpui `paint_path`). The window copies the
/// vertices; the caller keeps ownership of `path`.
pub fn paintPath(w: *Window, path: scene.Path, bg: anytype) void {
    assertPaint(w);
    const s = w.scale_factor;
    var p = path;
    p.content_mask = .{ .bounds = w.contentMask().bounds };
    const opacity = w.elementOpacityForBounds(p.bounds);
    p.color = toBackground(bg).opacity(opacity);
    var scaled = p.scale(w.gpa, s) catch @panic("OOM");
    defer scaled.deinit(w.gpa);
    sceneOf(w).insertPath(w.gpa, scaled) catch @panic("OOM");
}

/// Underline starting at `origin` (top edge), `width` long (gpui `paint_underline`).
pub fn paintUnderline(w: *Window, origin: Point, width: Pixels, st: text_mod.UnderlineStyle) void {
    assertPaint(w);
    const s = w.scale_factor;
    const thickness = snapStroke(w, st.thickness);
    const height = if (st.wavy) thickness * 3 else thickness;
    sceneOf(w).insertUnderline(w.gpa, .{
        .bounds = .{ .origin = .{ .x = roundHalf(origin.x * s), .y = roundHalf(origin.y * s) }, .size = .{ .width = snapStroke(w, width), .height = height } },
        .content_mask = snappedContentMask(w),
        .color = (st.color orelse Hsla{}).opacity(w.elementOpacityAt(origin)),
        .thickness = thickness,
        .wavy = @intFromBool(st.wavy),
    }) catch @panic("OOM");
}

pub fn paintStrikethrough(w: *Window, origin: Point, width: Pixels, st: text_mod.StrikethroughStyle) void {
    assertPaint(w);
    const s = w.scale_factor;
    sceneOf(w).insertUnderline(w.gpa, .{
        .bounds = .{ .origin = .{ .x = roundHalf(origin.x * s), .y = roundHalf(origin.y * s) }, .size = .{ .width = snapStroke(w, width), .height = snapStroke(w, st.thickness) } },
        .content_mask = snappedContentMask(w),
        .color = (st.color orelse Hsla{}).opacity(w.elementOpacityAt(origin)),
        .thickness = snapStroke(w, st.thickness),
        .wavy = 0,
    }) catch @panic("OOM");
}

fn shouldUseSubpixel(w: *const Window) bool {
    // Grayscale AA like gpui on transparent windows; LCD text needs per-platform tuning.
    _ = w;
    return false;
}

/// Paint one shaped glyph whose baseline origin is `origin` (gpui `paint_glyph`).
pub fn paintGlyph(w: *Window, origin: Point, font_id: text_mod.FontId, glyph_id: text_mod.GlyphId, font_size: Pixels, c: Hsla) void {
    const g = text_mod.line.glyphRenderParams(font_id, glyph_id, font_size, origin, w.scale_factor, shouldUseSubpixel(w));
    insertGlyph(w, g.params, g.origin, c);
}

fn insertGlyph(w: *Window, params: text_mod.RenderGlyphParams, origin: geometry.Point(ScaledPixels), c: Hsla) void {
    assertPaint(w);
    const ts = w.text_system.text_system;
    const sprite = (ts.rasterizeToAtlas(w.sprite_atlas, params, origin) catch |err| {
        std.log.warn("glyph raster failed: {t}", .{err});
        return;
    }) orelse return;
    const mask = snappedContentMask(w);
    const col = c.opacity(w.element_opacity);
    if (params.subpixel_rendering) {
        sceneOf(w).insertSubpixelSprite(w.gpa, .{ .bounds = sprite.bounds, .content_mask = mask, .color = col, .tile = sprite.tile, .fade = scaledEdgeFade(w) }) catch @panic("OOM");
    } else {
        sceneOf(w).insertMonochromeSprite(w.gpa, .{ .bounds = sprite.bounds, .content_mask = mask, .color = col, .tile = sprite.tile, .fade = scaledEdgeFade(w) }) catch @panic("OOM");
    }
}

/// Paint a color emoji glyph (gpui `paint_emoji`).
pub fn paintEmoji(w: *Window, origin: Point, font_id: text_mod.FontId, glyph_id: text_mod.GlyphId, font_size: Pixels) void {
    const s = w.scale_factor;
    insertEmoji(w, .{
        .font_id = font_id,
        .glyph_id = glyph_id,
        .font_size = font_size,
        .subpixel_variant_x = 0,
        .subpixel_variant_y = 0,
        .is_emoji = true,
        .subpixel_rendering = false,
        .scale_factor = s,
    }, .{ .x = roundHalf(origin.x * s), .y = roundHalf(origin.y * s) });
}

fn insertEmoji(w: *Window, params: text_mod.RenderGlyphParams, origin: geometry.Point(ScaledPixels)) void {
    assertPaint(w);
    const ts = w.text_system.text_system;
    const sprite = (ts.rasterizeToAtlas(w.sprite_atlas, params, origin) catch return) orelse return;
    sceneOf(w).insertPolychromeSprite(w.gpa, .{
        .bounds = sprite.bounds,
        .content_mask = snappedContentMask(w),
        .tile = sprite.tile,
        .opacity = w.element_opacity,
        .fade = scaledEdgeFade(w),
    }) catch @panic("OOM");
}

/// Paint a tinted monochrome SVG (gpui `paint_svg`). `path` identifies the document (atlas
/// and parse cache key); `bytes` supplies it, or null to load `path` from the asset source.
pub fn paintSvg(w: *Window, bounds: Bounds, path: []const u8, bytes: ?[]const u8, transformation: scene.TransformationMatrix, c: Hsla) void {
    assertPaint(w);
    const sb = snapBounds(w, bounds);
    if (sb.size.width <= 0 or sb.size.height <= 0) return;
    const svc = image_glue.services(w.app);
    const params = image.RenderSvgParams.forDeviceBounds(path, sb.size);
    var builder = svc.svg.maskBuilder(params, bytes);
    defer builder.deinit();
    const tile = (w.sprite_atlas.getOrInsertWith(params.atlasKey(), &builder) catch |err| {
        std.log.warn("svg raster failed: {t}", .{err});
        return;
    }) orelse return;
    const k = image.SMOOTH_SVG_SCALE_FACTOR;
    const tw: f32 = @floatFromInt(tile.bounds.size.width);
    const th: f32 = @floatFromInt(tile.bounds.size.height);
    const center: geometry.Point(f32) = .{ .x = sb.origin.x + sb.size.width / 2, .y = sb.origin.y + sb.size.height / 2 };
    const final: SBounds = .{
        .origin = .{ .x = roundHalf(center.x - tw / k / 2), .y = roundHalf(center.y - th / k / 2) },
        .size = .{ .width = @ceil(tw / k), .height = @ceil(th / k) },
    };
    sceneOf(w).insertMonochromeSprite(w.gpa, .{
        .bounds = final,
        .content_mask = snappedContentMask(w),
        .color = c.opacity(w.element_opacity),
        .tile = tile,
        .transformation = transformation,
        .fade = scaledEdgeFade(w),
    }) catch @panic("OOM");
}

/// Paint a decoded image (gpui `paint_image`).
pub fn paintImage(w: *Window, bounds: Bounds, radii: Corners, img: *const image.RenderImage, frame_index: usize, grayscale: bool) void {
    paintImageFitted(w, bounds, bounds, radii, img, frame_index, grayscale, null);
}

/// Paint the `visible` part of an image fitted into `fitted` (object-fit cover), with an
/// optional rounded alpha mask (zui fork `paint_image_fitted_masked`).
pub fn paintImageFitted(w: *Window, visible: Bounds, fitted: Bounds, radii: Corners, img: *const image.RenderImage, frame_index: usize, grayscale: bool, alpha_mask: ?scene.ImageAlphaMask) void {
    assertPaint(w);
    var tile = (w.sprite_atlas.getOrInsertWith(img.atlasKey(frame_index), img.tileBuilder(frame_index)) catch |err| {
        std.log.warn("image upload failed: {t}", .{err});
        return;
    }) orelse return;
    if (!std.meta.eql(visible, fitted)) tile = scene.cropTileForFit(tile, visible, fitted);
    sceneOf(w).insertPolychromeSprite(w.gpa, .{
        .grayscale = @intFromBool(grayscale),
        .alpha_mask = if (alpha_mask) |m| m.scale(w.scale_factor) else .{},
        .bounds = snapBounds(w, visible),
        .content_mask = snappedContentMask(w),
        .corner_radii = scaleCorners(radii, w.scale_factor),
        .fade = scaledEdgeFade(w),
        .tile = tile,
        .opacity = w.element_opacity,
    }) catch @panic("OOM");
}

/// Options for `paintViewport3D`.
pub const Viewport3DOptions = struct {
    corner_radii: Corners = .all(0),
};

/// Paint a zpui.three scene into `bounds` (logical px): the renderer draws it
/// offscreen before the UI pass and composites it here in draw order, clipped to
/// the content mask, rounded and faded by the element opacity. Bounds snap to
/// device pixels so the offscreen image maps 1:1. Records the bounds on the
/// scene for `Scene3D.pickAt`.
pub fn paintViewport3D(w: *Window, bounds: Bounds, s3: *three.Scene3D, opts: Viewport3DOptions) void {
    assertPaint(w);
    const sb = snapBounds(w, bounds);
    if (sb.size.width < 1 or sb.size.height < 1) return;
    s3.last_viewport = .{ .x = bounds.origin.x, .y = bounds.origin.y, .width = bounds.size.width, .height = bounds.size.height };
    sceneOf(w).insertViewport3D(w.gpa, .{
        .bounds = sb,
        .content_mask = snappedContentMask(w),
        .corner_radii = scaleCorners(opts.corner_radii, w.scale_factor),
        .opacity = w.element_opacity,
        .scene3d = s3,
    }) catch @panic("OOM");
}

/// Start a paint layer: primitives until `popLayer` share one draw order (gpui
/// `paint_layer`). Returns whether a layer was pushed (pass it to `popLayer`).
pub fn pushLayer(w: *Window, bounds: Bounds) bool {
    assertPaint(w);
    const clipped = bounds.intersect(w.contentMask().bounds);
    if (clipped.isEmpty()) return false;
    sceneOf(w).pushLayer(w.gpa, coverBounds(w, clipped)) catch @panic("OOM");
    return true;
}

pub fn popLayer(w: *Window, pushed: bool) void {
    if (pushed) sceneOf(w).popLayer(w.gpa) catch @panic("OOM");
}

// ---- style painting (gpui `Style::paint`) ------------------------------------------------

/// Paint drop shadows, background and inset shadows of `style` (the part of gpui's
/// `Style::paint` before its continuation). Paint children, then `paintStyleBorder`.
pub fn paintStyle(w: *Window, style: *const Style, bounds: Bounds) void {
    if (style.debug) paintQuad(w, outline(bounds, color.red, .solid));
    const radii = style.cornerRadiiPixels(bounds.size, w.remSize());
    paintDropShadows(w, bounds, radii, style.box_shadow);
    if (style.background) |bg| if (!bg.isTransparent()) {
        var border_color = switch (bg.tag) {
            .linear_gradient => bg.colors[0].color,
            else => bg.solid,
        };
        border_color.a = 0;
        paintQuad(w, quad(bounds, radii, bg, .all(0), border_color, style.border_style));
    };
    paintInsetShadows(w, bounds, radii, style.box_shadow);
}

/// Paint `style`'s border on top of the element's children.
pub fn paintStyleBorder(w: *Window, style: *const Style, bounds: Bounds) void {
    if (!style.isBorderVisible()) return;
    const radii = style.cornerRadiiPixels(bounds.size, w.remSize());
    var bg = style.border_color orelse Hsla{};
    bg.a = 0;
    paintQuad(w, quad(bounds, radii, bg, style.borderWidthsPixels(w.remSize()), style.border_color orelse Hsla{}, style.border_style));
}

// ---- GlyphPainter for the text system --------------------------------------------------

/// The `text.GlyphPainter` that paints shaped lines into this window.
pub fn glyphPainter(w: *Window) text_mod.GlyphPainter {
    return .{
        .ptr = w,
        .vtable = &painter_vtable,
        .text_system = w.text_system.text_system,
        .scale_factor = w.scale_factor,
        .subpixel_rendering = shouldUseSubpixel(w),
        .content_mask = w.contentMask().bounds,
    };
}

const painter_vtable: text_mod.GlyphPainter.VTable = .{
    .paintGlyph = gpGlyph,
    .paintEmoji = gpEmoji,
    .paintQuad = gpQuad,
    .paintUnderline = gpUnderline,
    .paintStrikethrough = gpStrike,
};

fn gpWindow(p: *anyopaque) *Window {
    return @ptrCast(@alignCast(p));
}
fn gpGlyph(p: *anyopaque, params: text_mod.RenderGlyphParams, origin: geometry.Point(ScaledPixels), c: Hsla) anyerror!void {
    insertGlyph(gpWindow(p), params, origin, c);
}
fn gpEmoji(p: *anyopaque, params: text_mod.RenderGlyphParams, origin: geometry.Point(ScaledPixels)) anyerror!void {
    insertEmoji(gpWindow(p), params, origin);
}
fn gpQuad(p: *anyopaque, b: Bounds, c: Hsla) anyerror!void {
    paintQuad(gpWindow(p), fill(b, c));
}
fn gpUnderline(p: *anyopaque, origin: Point, width: Pixels, st: text_mod.UnderlineStyle) anyerror!void {
    paintUnderline(gpWindow(p), origin, width, st);
}
fn gpStrike(p: *anyopaque, origin: Point, width: Pixels, st: text_mod.StrikethroughStyle) anyerror!void {
    paintStrikethrough(gpWindow(p), origin, width, st);
}
