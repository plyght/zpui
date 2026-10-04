//! Texture-atlas handle types referenced by sprite primitives (gpui `platform.rs`).
//! The atlas allocator itself lives elsewhere; these are plain GPU-visible data.

const std = @import("std");
const geometry = @import("geometry.zig");

/// What a given atlas texture stores; selects pixel format and shader path.
pub const AtlasTextureKind = enum(u32) {
    /// Single-channel coverage (glyphs, SVG masks). Metal: A8, wgpu: R8.
    monochrome = 0,
    /// Full-color BGRA/RGBA (images, emoji).
    polychrome = 1,
    /// Per-channel LCD coverage for subpixel text (wgpu only).
    subpixel = 2,
};

/// Identifies one texture inside an atlas. `u32` index (not usize) for shader compatibility.
pub const AtlasTextureId = extern struct {
    index: u32,
    kind: AtlasTextureKind,

    pub fn eql(a: AtlasTextureId, b: AtlasTextureId) bool {
        return a.index == b.index and a.kind == b.kind;
    }
};

/// Allocation id of a tile within its texture (serialized etagere `AllocId` in gpui).
pub const TileId = u32;

/// A rectangle of an atlas texture holding one rasterized glyph/image/SVG.
/// 32 bytes; WGSL `AtlasTile` (align 8 due to `vec2<i32>` bounds) has the same layout.
pub const AtlasTile = extern struct {
    texture_id: AtlasTextureId,
    tile_id: TileId,
    /// Padding (in device pixels) around the tile content.
    padding: u32,
    /// Bounds of the tile within the texture, in device pixels.
    bounds: geometry.Bounds(geometry.DevicePixels),

    comptime {
        std.debug.assert(@sizeOf(AtlasTile) == 32);
        std.debug.assert(@offsetOf(AtlasTile, "bounds") == 16);
    }
};
