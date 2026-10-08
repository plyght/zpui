//! Text value types shared by the core text system and the platform shapers
//! (gpui `text_system.rs` / `line_layout.rs`).

const std = @import("std");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");

pub const Pixels = geometry.Pixels;

/// CSS-style weight, 100..900 (gpui `FontWeight(f32)`).
pub const FontWeight = f32;
pub const weight = struct {
    pub const thin: FontWeight = 100;
    pub const extra_light: FontWeight = 200;
    pub const light: FontWeight = 300;
    pub const normal: FontWeight = 400;
    pub const medium: FontWeight = 500;
    pub const semibold: FontWeight = 600;
    pub const bold: FontWeight = 700;
    pub const extra_bold: FontWeight = 800;
    pub const black: FontWeight = 900;
};

pub const FontStyle = enum { normal, italic, oblique };

/// OpenType feature tag + value, e.g. .{ .tag = "calt".*, .value = 0 }.
pub const FontFeature = struct { tag: [4]u8, value: u32 };

pub const Font = struct {
    family: []const u8,
    weight: FontWeight = weight.normal,
    style: FontStyle = .normal,
    features: []const FontFeature = &.{},
    /// Families to try (in order) for characters the primary font lacks.
    fallbacks: []const []const u8 = &.{},

    pub fn hash(self: Font, h: *std.hash.Wyhash) void {
        h.update(self.family);
        h.update(std.mem.asBytes(&self.weight));
        h.update(std.mem.asBytes(&self.style));
        for (self.features) |f| h.update(std.mem.asBytes(&f));
        for (self.fallbacks) |f| h.update(f);
    }
};

pub const FontId = enum(u32) { _ };
pub const GlyphId = u32;

/// Font-unit metrics (gpui `FontMetrics`). Scale by `font_size / units_per_em`.
pub const FontMetrics = struct {
    units_per_em: u32,
    ascent: f32,
    descent: f32, // negative
    line_gap: f32,
    underline_position: f32,
    underline_thickness: f32,
    cap_height: f32,
    x_height: f32,
    bounding_box: geometry.Bounds(f32),
};

/// A run of `len` UTF-8 bytes shaped with one font.
pub const FontRun = struct { len: usize, font_id: FontId };

pub const ShapedGlyph = struct {
    id: GlyphId,
    /// Position relative to the line origin (baseline-left), logical pixels.
    position: geometry.Point(Pixels),
    /// UTF-8 byte index into the line's text where this glyph's cluster starts.
    index: usize,
    is_emoji: bool,
};

pub const ShapedRun = struct {
    font_id: FontId,
    glyphs: []ShapedGlyph,
};

/// gpui `LineLayout`: one shaped, unwrapped line.
pub const LineLayout = struct {
    font_size: Pixels,
    width: Pixels,
    ascent: Pixels,
    descent: Pixels,
    runs: []ShapedRun,
    /// UTF-8 byte length of the text.
    len: usize,
};

/// Number of horizontal subpixel glyph variants (gpui `SUBPIXEL_VARIANTS_X`).
pub const subpixel_variants_x: u8 = 4;
pub const subpixel_variants_y: u8 = 1;

/// A 2x2 linear map applied to a glyph's outline when the backend rasterizes it (no
/// translation: the glyph's baseline origin is the fixed point). Device space, y down:
/// a glyph-space vector `(x, y)` (x right, y down, in pixels) lands at
/// `(a*x + c*y, b*x + d*y)`, the column-vector convention of `CGAffineTransform`.
/// Unlike a composite-time `scene.TransformationMatrix`, the rasterizer sees the
/// transformed outline, so sheared or squashed glyphs stay crisp and correctly
/// antialiased at any size. Part of `RenderGlyphParams` (and so of the atlas key).
pub const RasterTransform = extern struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,

    pub const identity: RasterTransform = .{};

    /// The transform taking glyph +x to `u` and glyph "up" (toward the ascender) to `v`,
    /// both in y-down device space: e.g. a keycap plane seen at an angle, where `u` runs
    /// along the key row and `v` points from a legend's baseline toward its top.
    pub fn fromBasis(u: [2]f32, v: [2]f32) RasterTransform {
        // Glyph "up" is (0, -1) in y-down space, so the y column is -v.
        return canonical(.{ .a = u[0], .b = u[1], .c = -v[0], .d = -v[1] });
    }

    /// Exactly the identity (the backends' unchanged fast path).
    pub fn isIdentity(t: RasterTransform) bool {
        return t.a == 1 and t.b == 0 and t.c == 0 and t.d == 1;
    }

    /// Same map with -0 folded to +0, so equal maps hash (byte-wise) to one atlas key.
    pub fn canonical(t: RasterTransform) RasterTransform {
        return .{ .a = t.a + 0, .b = t.b + 0, .c = t.c + 0, .d = t.d + 0 };
    }

    pub fn determinant(t: RasterTransform) f32 {
        return t.a * t.d - t.b * t.c;
    }

    pub fn apply(t: RasterTransform, p: geometry.Point(f32)) geometry.Point(f32) {
        return .{ .x = t.a * p.x + t.c * p.y, .y = t.b * p.x + t.d * p.y };
    }

    /// `t` applied after `u` (`t.compose(u).apply(p) == t.apply(u.apply(p))`).
    pub fn compose(t: RasterTransform, u: RasterTransform) RasterTransform {
        return .{
            .a = t.a * u.a + t.c * u.b,
            .b = t.b * u.a + t.d * u.b,
            .c = t.a * u.c + t.c * u.d,
            .d = t.b * u.c + t.d * u.d,
        };
    }

    /// Axis-aligned bounding box of the rectangle `[x0, x1] x [y0, y1]` (y down) after `t`:
    /// `.{ min_x, min_y, max_x, max_y }`. A linear map sends a box's corners to the corners
    /// of a parallelogram, so their extremes bound the transformed box exactly.
    pub fn mapRect(t: RasterTransform, x0: f64, y0: f64, x1: f64, y1: f64) [4]f64 {
        const corners = [4][2]f64{ .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 }, .{ x1, y1 } };
        var out: [4]f64 = .{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
        for (corners) |p| {
            const x = @as(f64, t.a) * p[0] + @as(f64, t.c) * p[1];
            const y = @as(f64, t.b) * p[0] + @as(f64, t.d) * p[1];
            out[0] = @min(out[0], x);
            out[1] = @min(out[1], y);
            out[2] = @max(out[2], x);
            out[3] = @max(out[3], y);
        }
        return out;
    }
};

/// gpui `RenderGlyphParams`: everything that determines a glyph's rasterized bitmap.
/// Also the atlas key for glyph tiles.
pub const RenderGlyphParams = extern struct {
    font_id: FontId,
    glyph_id: GlyphId,
    /// Font size in logical px, stored as bits for hashing.
    font_size: f32,
    subpixel_variant_x: u8,
    subpixel_variant_y: u8,
    is_emoji: bool,
    subpixel_rendering: bool,
    scale_factor: f32,
    /// Font smoothing (stroke dilation) level 0..4 for the fill color (gpui
    /// `RenderGlyphParams::dilation`, `glyphDilationForColor`); 0 = unsmoothed.
    dilation: u8 = 0,
    /// Explicit padding: params are hashed and compared as bytes.
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// Outline transform applied by the rasterizer (`RasterTransform`); identity takes each
    /// backend's unchanged path, so ordinary text is bit-identical with or without it.
    raster_transform: RasterTransform = .identity,
};

/// gpui `TextRun`: styling for `len` UTF-8 bytes of a styled text.
pub const TextRun = struct {
    len: usize,
    font: Font,
    color: color.Hsla,
    background_color: ?color.Hsla = null,
    underline: ?UnderlineStyle = null,
    strikethrough: ?StrikethroughStyle = null,
};

pub const UnderlineStyle = struct {
    thickness: Pixels = 1,
    color: ?color.Hsla = null,
    wavy: bool = false,
};

pub const StrikethroughStyle = struct {
    thickness: Pixels = 1,
    color: ?color.Hsla = null,
};

test "RenderGlyphParams has no implicit padding (hashed and compared as bytes)" {
    var sum: usize = 0;
    inline for (@typeInfo(RenderGlyphParams).@"struct".field_types) |T| sum += @sizeOf(T);
    try std.testing.expectEqual(sum, @sizeOf(RenderGlyphParams));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(RasterTransform));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(RenderGlyphParams, "raster_transform"));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(RenderGlyphParams));
}

test "RasterTransform basis, identity, canonical zeros and rect mapping" {
    const t = std.testing;
    try t.expect(RasterTransform.identity.isIdentity());
    // Glyph x -> u, glyph up -> v: the upright basis is the identity.
    try t.expect(RasterTransform.fromBasis(.{ 1, 0 }, .{ 0, -1 }).isIdentity());
    // -0 folds to +0 so byte-wise keys agree.
    const neg: RasterTransform = .{ .a = 1, .b = -0.0, .c = -0.0, .d = 1 };
    try t.expect(neg.isIdentity());
    try t.expectEqualSlices(u8, std.mem.asBytes(&RasterTransform.identity), std.mem.asBytes(&neg.canonical()));
    // Shear: up leans right by 0.5 per unit.
    const shear = RasterTransform.fromBasis(.{ 1, 0 }, .{ 0.5, -1 });
    const top = shear.apply(.{ .x = 0, .y = -10 }); // 10px above the baseline
    try t.expectApproxEqAbs(@as(f32, 5), top.x, 1e-6);
    try t.expectApproxEqAbs(@as(f32, -10), top.y, 1e-6);
    // Box [0,8]x[-10,0] -> x spans [0, 8 + 5], y unchanged.
    const r = shear.mapRect(0, -10, 8, 0);
    try t.expectApproxEqAbs(@as(f64, 0), r[0], 1e-9);
    try t.expectApproxEqAbs(@as(f64, -10), r[1], 1e-9);
    try t.expectApproxEqAbs(@as(f64, 13), r[2], 1e-9);
    try t.expectApproxEqAbs(@as(f64, 0), r[3], 1e-9);
    // Composition order.
    const rot: RasterTransform = .{ .a = 0, .b = 1, .c = -1, .d = 0 }; // 90 degrees clockwise (y down)
    const p = rot.compose(shear).apply(.{ .x = 2, .y = -4 });
    const q = rot.apply(shear.apply(.{ .x = 2, .y = -4 }));
    try t.expectApproxEqAbs(q.x, p.x, 1e-6);
    try t.expectApproxEqAbs(q.y, p.y, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 1), shear.determinant(), 1e-6);
}
