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
    inline for (std.meta.fields(RenderGlyphParams)) |f| sum += @sizeOf(f.type);
    try std.testing.expectEqual(sum, @sizeOf(RenderGlyphParams));
}
