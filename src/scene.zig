//! The retained display list for one frame, ported from zui's `scene.rs`.
//!
//! Elements paint by inserting primitives; each primitive gets a draw order
//! from a `BoundsTree` (or the enclosing layer's order). `finish` sorts every
//! primitive list by order and `batches` walks them in draw order, yielding
//! runs of same-kind (and same-texture) primitives for the renderer.
//!
//! Primitive structs are `extern` and laid out byte-for-byte like the GPU
//! instance structs in zui's `shaders.metal` (generated from the Rust
//! `#[repr(C)]` structs) and `shaders.wgsl`. Every field is 4-byte scalar
//! data, so Metal and C agree trivially. WGSL storage buffers additionally
//! align `vec2<f32>` (Bounds/Point) and `mat2x2<f32>` to 8 bytes, which is
//! why several structs carry an explicit `pad: u32` after `order`. None of the
//! instance structs contain `vec3/vec4` members, so the 16-byte std140/std430
//! vector alignment never applies to them (it does apply to uniforms such as
//! the blur kernel — see docs/shaders-notes.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");
const color = @import("color.zig");
const atlas = @import("atlas.zig");
const BoundsTree = @import("bounds_tree.zig").BoundsTree;
pub const three = @import("three/scene3d.zig");

pub const ScaledPixels = geometry.ScaledPixels;
pub const DevicePixels = geometry.DevicePixels;
pub const Pixels = geometry.Pixels;
pub const Hsla = color.Hsla;
pub const Background = color.Background;
pub const AtlasTile = atlas.AtlasTile;
pub const AtlasTextureId = atlas.AtlasTextureId;
pub const AtlasTextureKind = atlas.AtlasTextureKind;
pub const TileId = atlas.TileId;

const Bounds = geometry.Bounds(ScaledPixels);
const Corners = geometry.Corners(ScaledPixels);
const Edges = geometry.Edges(ScaledPixels);
const Point = geometry.Point(ScaledPixels);

/// Paint order; higher draws later. Assigned by the scene, not by callers.
pub const DrawOrder = u32;

/// A boolean stored as `u32` (0 or 1) so GPU structs contain no implicit padding.
pub const PaddedBool32 = u32;

/// Rectangular clip applied to a primitive (gpui `ContentMask`, from window.rs).
pub const ContentMask = extern struct {
    bounds: Bounds,

    pub fn scale(self: ContentMask, factor: f32) ContentMask {
        return .{ .bounds = self.bounds.scale(factor) };
    }
    pub fn intersect(a: ContentMask, b: ContentMask) ContentMask {
        return .{ .bounds = a.bounds.intersect(b.bounds) };
    }
};

const zero_bounds: Bounds = .{ .origin = .zero, .size = .zero };
const zero_corners: Corners = .{ .top_left = 0, .top_right = 0, .bottom_right = 0, .bottom_left = 0 };
const zero_edges: Edges = .{ .top = 0, .right = 0, .bottom = 0, .left = 0 };

/// Per-primitive scoped edge fade (zui `Window::with_edge_fade`): the fragment
/// shader multiplies alpha by `ramp*ramp`, where `ramp` is the min over enabled
/// edges of `clamp(distance_inside_edge / band, 0, 1)`. Window-space device
/// pixels. A zero band disables that edge; an all-zero value is a no-op.
pub const EdgeFadeParams = extern struct {
    top_y: f32 = 0,
    bottom_y: f32 = 0,
    band_top: f32 = 0,
    band_bottom: f32 = 0,
    left_x: f32 = 0,
    right_x: f32 = 0,
    band_left: f32 = 0,
    band_right: f32 = 0,

    pub fn isNone(self: EdgeFadeParams) bool {
        return self.band_top <= 0 and self.band_bottom <= 0 and self.band_left <= 0 and self.band_right <= 0;
    }
};

/// Border dash style; read by the quad shader as `u32` (`border_style == 1` is dashed).
pub const BorderStyle = enum(u32) {
    solid = 0,
    dashed = 1,
};

/// 2D affine transform: row-major 2x2 rotation/scale plus translation.
/// WGSL declares `rotation_scale` as `mat2x2<f32>` (column-major) and transposes it.
pub const TransformationMatrix = extern struct {
    rotation_scale: [2][2]f32 = .{ .{ 1, 0 }, .{ 0, 1 } },
    translation: [2]f32 = .{ 0, 0 },

    pub const unit: TransformationMatrix = .{};

    pub fn eql(a: TransformationMatrix, b: TransformationMatrix) bool {
        return std.meta.eql(a, b);
    }

    /// Move the origin by `point`.
    pub fn translate(self: TransformationMatrix, point: Point) TransformationMatrix {
        return self.compose(.{ .translation = .{ point.x, point.y } });
    }

    /// Clockwise rotation (radians) around the origin.
    pub fn rotate(self: TransformationMatrix, radians: f32) TransformationMatrix {
        const c = @cos(radians);
        const s = @sin(radians);
        return self.compose(.{ .rotation_scale = .{ .{ c, -s }, .{ s, c } } });
    }

    /// Scale around the origin.
    pub fn scale(self: TransformationMatrix, size: geometry.Size(f32)) TransformationMatrix {
        return self.compose(.{ .rotation_scale = .{ .{ size.width, 0 }, .{ 0, size.height } } });
    }

    /// Matrix product: applies `other` first, then `self`.
    pub fn compose(self: TransformationMatrix, other: TransformationMatrix) TransformationMatrix {
        if (other.eql(unit)) return self;
        const a = self.rotation_scale;
        const b = other.rotation_scale;
        return .{
            .rotation_scale = .{
                .{ a[0][0] * b[0][0] + a[0][1] * b[1][0], a[0][0] * b[0][1] + a[0][1] * b[1][1] },
                .{ a[1][0] * b[0][0] + a[1][1] * b[1][0], a[1][0] * b[0][1] + a[1][1] * b[1][1] },
            },
            .translation = .{
                self.translation[0] + a[0][0] * other.translation[0] + a[0][1] * other.translation[1],
                self.translation[1] + a[1][0] * other.translation[0] + a[1][1] * other.translation[1],
            },
        };
    }

    /// Transform a point (CPU-side; mainly for debugging and hit testing).
    pub fn apply(self: TransformationMatrix, p: geometry.Point(Pixels)) geometry.Point(Pixels) {
        const r = self.rotation_scale;
        return .{
            .x = self.translation[0] + r[0][0] * p.x + r[0][1] * p.y,
            .y = self.translation[1] + r[1][0] * p.x + r[1][1] * p.y,
        };
    }
};

// ---------------------------------------------------------------------------
// Primitives (GPU instance layouts)
// ---------------------------------------------------------------------------

/// Drop or inset box shadow. Metal/WGSL `Shadow`, 112 bytes.
pub const Shadow = extern struct {
    order: DrawOrder = 0,
    blur_radius: ScaledPixels = 0,
    /// Shadow rect for drop shadows; the "hole" rect for inset shadows. Offset 8 (WGSL vec2 align).
    bounds: Bounds = zero_bounds,
    corner_radii: Corners = zero_corners,
    content_mask: ContentMask = .{ .bounds = zero_bounds },
    color: Hsla = .{},
    /// Inset shadows only: the element's own rect, used as a rounded clip.
    element_bounds: Bounds = zero_bounds,
    element_corner_radii: Corners = zero_corners,
    /// 0 = drop shadow (outside the element), 1 = inset shadow.
    inset: u32 = 0,
    /// Rounds the size to a multiple of 8 for WGSL array stride.
    pad: u32 = 0,
};

/// Rounded rectangle with fill, per-edge border widths, per-corner radii,
/// optional dashed border and scoped edge fade. Metal/WGSL `Quad`, 192 bytes.
pub const Quad = extern struct {
    order: DrawOrder = 0,
    border_style: BorderStyle = .solid,
    /// Offset 8 (WGSL vec2 align).
    bounds: Bounds = zero_bounds,
    content_mask: ContentMask = .{ .bounds = zero_bounds },
    background: Background = .{},
    border_color: Hsla = .{},
    corner_radii: Corners = zero_corners,
    border_widths: Edges = zero_edges,
    fade: EdgeFadeParams = .{},
};

/// Straight or wavy text underline/strikethrough. Metal/WGSL `Underline`, 64 bytes.
pub const Underline = extern struct {
    order: DrawOrder = 0,
    /// Aligns `bounds` to 8 bytes for WGSL.
    pad: u32 = 0,
    bounds: Bounds = zero_bounds,
    content_mask: ContentMask = .{ .bounds = zero_bounds },
    color: Hsla = .{},
    thickness: ScaledPixels = 0,
    wavy: PaddedBool32 = 0,
};

/// Single-channel atlas sprite tinted with `color` (glyphs, SVG icons). 144 bytes.
pub const MonochromeSprite = extern struct {
    order: DrawOrder = 0,
    pad: u32 = 0,
    bounds: Bounds = zero_bounds,
    content_mask: ContentMask = .{ .bounds = zero_bounds },
    color: Hsla = .{},
    /// Offset 56 (WGSL AtlasTile has align 8).
    tile: AtlasTile,
    /// Offset 88 (WGSL mat2x2 has align 8).
    transformation: TransformationMatrix = .{},
    fade: EdgeFadeParams = .{},
};

/// LCD subpixel-antialiased glyph (wgpu dual-source blending). Same layout as `MonochromeSprite`.
pub const SubpixelSprite = extern struct {
    order: DrawOrder = 0,
    pad: u32 = 0,
    bounds: Bounds = zero_bounds,
    content_mask: ContentMask = .{ .bounds = zero_bounds },
    color: Hsla = .{},
    tile: AtlasTile,
    transformation: TransformationMatrix = .{},
    fade: EdgeFadeParams = .{},
};

/// GPU form of `ImageAlphaMask` in device pixels. Zero `feather` disables the mask. 40 bytes.
pub const ImageAlphaMaskParams = extern struct {
    bounds: Bounds = zero_bounds,
    radius: f32 = 0,
    feather: f32 = 0,
    clearance: f32 = 0,
    bottom_y: f32 = 0,
    bottom_feather: f32 = 0,
    /// Rounds the size to a multiple of 8 (WGSL struct align).
    pad: f32 = 0,
};

/// Smoothly exclude a rounded rectangle from an image without changing its texture.
/// Window-space logical pixels, independent of UVs.
pub const ImageAlphaMask = struct {
    bounds: geometry.Bounds(Pixels),
    /// Corner radius, clamped to half the shorter side.
    radius: Pixels,
    /// Smoothstep distance outside the exclusion. Must be positive.
    feather: Pixels,
    /// Extra transparent clearance outside the rounded rectangle.
    clearance: Pixels,
    /// Optional bottom edge (window y) and smoothstep fade-band height.
    bottom_fade: ?BottomFade = null,

    pub const BottomFade = struct { y: Pixels, feather: Pixels };

    pub fn scale(self: ImageAlphaMask, factor: f32) ImageAlphaMaskParams {
        const bf: BottomFade = self.bottom_fade orelse .{ .y = 0, .feather = 0 };
        const radius = @min(@max(self.radius, 0), @max(self.bounds.size.width, 0) * 0.5, @max(self.bounds.size.height, 0) * 0.5);
        return .{
            .bounds = self.bounds.scale(factor),
            .radius = radius * factor,
            .feather = @max(self.feather, 0) * factor,
            .clearance = @max(self.clearance, 0) * factor,
            .bottom_y = bf.y * factor,
            .bottom_feather = @max(bf.feather, 0) * factor,
        };
    }
};

/// Full-color atlas sprite (images, emoji) with rounded corners, grayscale,
/// opacity, edge fade and an optional alpha-mask exclusion. 168 bytes.
///
/// Object-fit cover is done CPU-side: the caller crops `tile.bounds` to the
/// visible fraction of the fitted box so `bounds` equals the visible rect and
/// `corner_radii` round the element's real corners (zui `paint_image_fitted`);
/// see `cropTileForFit`.
pub const PolychromeSprite = extern struct {
    order: DrawOrder = 0,
    pad: u32 = 0,
    grayscale: PaddedBool32 = 0,
    opacity: f32 = 1,
    bounds: Bounds = zero_bounds,
    content_mask: ContentMask = .{ .bounds = zero_bounds },
    corner_radii: Corners = zero_corners,
    fade: EdgeFadeParams = .{},
    alpha_mask: ImageAlphaMaskParams = .{},
    /// Offset 136 (WGSL AtlasTile align 8).
    tile: AtlasTile,
};

/// Crop an atlas tile to the `visible` sub-rect of an image laid out in `fitted`
/// (object-fit cover etc.), using proportional UV mapping as zui does.
pub fn cropTileForFit(tile: AtlasTile, visible: geometry.Bounds(Pixels), fitted: geometry.Bounds(Pixels)) AtlasTile {
    const fw = @max(fitted.size.width, 1.0);
    const fh = @max(fitted.size.height, 1.0);
    const fx = (visible.origin.x - fitted.origin.x) / fw;
    const fy = (visible.origin.y - fitted.origin.y) / fh;
    const tw: f32 = @floatFromInt(tile.bounds.size.width);
    const th: f32 = @floatFromInt(tile.bounds.size.height);
    var out = tile;
    out.bounds.origin.x += @intFromFloat(@round(fx * tw));
    out.bounds.origin.y += @intFromFloat(@round(fy * th));
    out.bounds.size.width = @intFromFloat(@max(@round(visible.size.width / fw * tw), 1.0));
    out.bounds.size.height = @intFromFloat(@max(@round(visible.size.height / fh * th), 1.0));
    return out;
}

/// Frosted-glass region: the renderer snapshots everything painted below
/// `order`, gaussian-blurs it and paints it back inside the rounded bounds.
/// Metal `BackdropBlur` instance (56 bytes); WGSL uses a separate uniform
/// (`BackdropBlurUniform`). Deliberately NOT part of the batch stream.
pub const BackdropBlur = extern struct {
    order: DrawOrder = 0,
    /// Gaussian sigma in device pixels (renderers clamp to >= 1).
    blur_radius: ScaledPixels = 0,
    bounds: Bounds = zero_bounds,
    content_mask: ContentMask = .{ .bounds = zero_bounds },
    corner_radii: Corners = zero_corners,
};

/// Native video/surface placeholder (macOS `CVPixelBuffer` in zui). Not GPU data itself;
/// see `SurfaceBounds` for the instance layout.
pub const PaintSurface = struct {
    order: DrawOrder = 0,
    bounds: Bounds,
    content_mask: ContentMask,
    /// Platform image handle (e.g. CVPixelBufferRef); opaque to the scene.
    image_buffer: ?*anyopaque = null,
};

/// A 3D viewport (zpui.three spike): the backend renders `scene3d` offscreen
/// (HDR + depth + MSAA) before the UI pass and composites it here, in draw order,
/// clipped to `content_mask` and rounded by `corner_radii`.
pub const Viewport3D = struct {
    order: DrawOrder = 0,
    bounds: Bounds,
    content_mask: ContentMask,
    corner_radii: Corners = zero_corners,
    scene3d: *const three.Scene3D,
};

/// GPU instance for the viewport3d composite pipeline (64 bytes).
pub const Viewport3DInstance = extern struct {
    bounds: Bounds,
    content_mask: ContentMask,
    corner_radii: Corners,
    exposure: f32,
    pad: [3]u32 = .{ 0, 0, 0 },
};

/// Index of a path within `Scene.paths` at insertion time.
pub const PathId = usize;

/// A path vertex. `st_position` drives the quadratic-curve SDF in the path
/// rasterization shader: (0,1) for interior fan triangles, and
/// (0,0),(0.5,0),(1,1) for curve triangles (Loop–Blinn).
pub const PathVertex = extern struct {
    xy_position: Point,
    st_position: geometry.Point(f32),
    content_mask: ContentMask,

    pub fn scale(self: PathVertex, factor: f32) PathVertex {
        return .{
            .xy_position = self.xy_position.scale(factor),
            .st_position = self.st_position,
            .content_mask = self.content_mask.scale(factor),
        };
    }
};

/// A filled vector path built from line and quadratic-curve segments,
/// triangulated as a fan around each contour's start point. Pixels and
/// ScaledPixels are both `f32`, so the same type serves both stages.
pub const Path = struct {
    id: PathId = 0,
    order: DrawOrder = 0,
    bounds: Bounds,
    content_mask: ContentMask = .{ .bounds = zero_bounds },
    vertices: std.ArrayList(PathVertex) = .empty,
    color: Background = .{},
    start: Point,
    current: Point,
    contour_count: usize = 0,

    /// A new path starting at `start`.
    pub fn init(start: Point) Path {
        return .{ .start = start, .current = start, .bounds = .{ .origin = start, .size = .zero } };
    }

    pub fn deinit(self: *Path, gpa: Allocator) void {
        self.vertices.deinit(gpa);
        self.* = undefined;
    }

    /// Returns a copy scaled by `factor` with its own vertex storage.
    pub fn scale(self: Path, gpa: Allocator, factor: f32) Allocator.Error!Path {
        var out = self;
        out.vertices = .empty;
        try out.vertices.ensureTotalCapacityPrecise(gpa, self.vertices.items.len);
        for (self.vertices.items) |v| out.vertices.appendAssumeCapacity(v.scale(factor));
        out.bounds = self.bounds.scale(factor);
        out.content_mask = self.content_mask.scale(factor);
        out.start = self.start.scale(factor);
        out.current = self.current.scale(factor);
        return out;
    }

    /// Begin a new contour at `to`.
    pub fn moveTo(self: *Path, to: Point) void {
        self.contour_count += 1;
        self.start = to;
        self.current = to;
    }

    /// Straight segment from the current point to `to`.
    pub fn lineTo(self: *Path, gpa: Allocator, to: Point) Allocator.Error!void {
        self.contour_count += 1;
        if (self.contour_count > 1) {
            try self.pushTriangle(gpa, .{ self.start, self.current, to }, .{ .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 1 } });
        }
        self.current = to;
    }

    /// Quadratic curve from the current point to `to` with control point `ctrl`.
    pub fn curveTo(self: *Path, gpa: Allocator, to: Point, ctrl: Point) Allocator.Error!void {
        self.contour_count += 1;
        if (self.contour_count > 1) {
            try self.pushTriangle(gpa, .{ self.start, self.current, to }, .{ .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 1 } });
        }
        try self.pushTriangle(gpa, .{ self.current, ctrl, to }, .{ .{ .x = 0, .y = 0 }, .{ .x = 0.5, .y = 0 }, .{ .x = 1, .y = 1 } });
        self.current = to;
    }

    /// Append one triangle and grow `bounds` to include it.
    pub fn pushTriangle(self: *Path, gpa: Allocator, xy: [3]Point, st: [3]geometry.Point(f32)) Allocator.Error!void {
        try self.vertices.ensureUnusedCapacity(gpa, 3);
        for (xy, st) |p, s| {
            self.bounds = self.bounds.unionWith(.{ .origin = p, .size = .zero });
            self.vertices.appendAssumeCapacity(.{ .xy_position = p, .st_position = s, .content_mask = .{ .bounds = zero_bounds } });
        }
    }

    pub fn clippedBounds(self: Path) Bounds {
        return self.bounds.intersect(self.content_mask.bounds);
    }
};

// ---------------------------------------------------------------------------
// Renderer-side GPU structs that are derived from scene primitives.
// ---------------------------------------------------------------------------

/// One path vertex as uploaded for the path rasterization pass (Metal + WGSL), 104 bytes.
/// `bounds` is the path's clipped bounds and doubles as the clip rect.
pub const PathRasterizationVertex = extern struct {
    xy_position: Point,
    st_position: geometry.Point(f32),
    color: Background,
    /// Offset 88 (WGSL vec2 align).
    bounds: Bounds,
};

/// Rect copied from the path intermediate texture to the drawable, 16 bytes.
pub const PathSprite = extern struct {
    bounds: Bounds,
};

/// Surface instance (Metal `SurfaceBounds`, WGSL `SurfaceParams` uniform), 32 bytes.
pub const SurfaceBounds = extern struct {
    bounds: Bounds,
    content_mask: ContentMask,
};

comptime {
    const assert = std.debug.assert;
    assert(@sizeOf(EdgeFadeParams) == 32);
    assert(@sizeOf(TransformationMatrix) == 24);
    assert(@sizeOf(ContentMask) == 16);
    assert(@sizeOf(Shadow) == 112);
    assert(@sizeOf(Quad) == 192);
    assert(@offsetOf(Quad, "background") == 40);
    assert(@offsetOf(Quad, "border_color") == 112);
    assert(@offsetOf(Quad, "fade") == 160);
    assert(@sizeOf(Underline) == 64);
    assert(@sizeOf(MonochromeSprite) == 144);
    assert(@offsetOf(MonochromeSprite, "tile") == 56);
    assert(@offsetOf(MonochromeSprite, "transformation") == 88);
    assert(@sizeOf(SubpixelSprite) == 144);
    assert(@sizeOf(ImageAlphaMaskParams) == 40);
    assert(@sizeOf(PolychromeSprite) == 168);
    assert(@offsetOf(PolychromeSprite, "alpha_mask") == 96);
    assert(@offsetOf(PolychromeSprite, "tile") == 136);
    assert(@sizeOf(BackdropBlur) == 56);
    assert(@sizeOf(PathVertex) == 32);
    assert(@sizeOf(PathRasterizationVertex) == 104);
    assert(@offsetOf(PathRasterizationVertex, "bounds") == 88);
    assert(@sizeOf(PathSprite) == 16);
    assert(@sizeOf(SurfaceBounds) == 32);
    assert(@sizeOf(Viewport3DInstance) == 64);
    // WGSL storage-buffer rules: every Bounds/AtlasTile/mat2x2 field must sit on an 8-byte boundary,
    // and every array stride (struct size) must be a multiple of the struct's 8-byte alignment.
    for (.{ Shadow, Quad, Underline, MonochromeSprite, SubpixelSprite, PolychromeSprite, PathRasterizationVertex }) |T| {
        assert(@sizeOf(T) % 8 == 0);
        const info = @typeInfo(T).@"struct";
        for (info.field_names, info.field_types) |name, FT| {
            if (FT == Bounds or FT == ContentMask or FT == AtlasTile or FT == TransformationMatrix or FT == ImageAlphaMaskParams)
                assert(@offsetOf(T, name) % 8 == 0);
        }
    }
}

// ---------------------------------------------------------------------------
// Scene
// ---------------------------------------------------------------------------

/// Primitive kinds in batch tie-break order (lower kind draws first at equal order).
pub const PrimitiveKind = enum(u8) {
    shadow,
    quad,
    path,
    underline,
    monochrome_sprite,
    subpixel_sprite,
    polychrome_sprite,
    surface,
    viewport3d,
};

/// Any batched primitive. Backdrop blurs are separate (`Scene.insertBackdropBlur`).
pub const Primitive = union(PrimitiveKind) {
    shadow: Shadow,
    quad: Quad,
    path: Path,
    underline: Underline,
    monochrome_sprite: MonochromeSprite,
    subpixel_sprite: SubpixelSprite,
    polychrome_sprite: PolychromeSprite,
    surface: PaintSurface,
    viewport3d: Viewport3D,

    pub fn bounds(self: *const Primitive) Bounds {
        return switch (self.*) {
            inline else => |p| p.bounds,
        };
    }

    pub fn contentMask(self: *const Primitive) ContentMask {
        return switch (self.*) {
            inline else => |p| p.content_mask,
        };
    }
};

/// One recorded paint call; used to `replay` cached subtrees into the next frame.
pub const PaintOperation = union(enum) {
    /// For `.path`, `vertices` aliases the copy owned by `Scene.paths`.
    primitive: Primitive,
    backdrop_blur: BackdropBlur,
    start_layer: Bounds,
    end_layer,
};

/// Half-open index range into one of the scene's primitive lists.
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end - self.start;
    }
};

/// A run of same-kind primitives (and same atlas texture for sprites) that
/// can be drawn with one pipeline/bind-group in draw order.
pub const PrimitiveBatch = union(PrimitiveKind) {
    shadow: Range,
    quad: Range,
    path: Range,
    underline: Range,
    monochrome_sprite: SpriteRange,
    subpixel_sprite: SpriteRange,
    polychrome_sprite: SpriteRange,
    surface: Range,
    viewport3d: Range,

    pub const SpriteRange = struct {
        texture_id: AtlasTextureId,
        range: Range,
    };

    pub fn range(self: PrimitiveBatch) Range {
        return switch (self) {
            .shadow, .quad, .path, .underline, .surface, .viewport3d => |r| r,
            .monochrome_sprite, .subpixel_sprite, .polychrome_sprite => |s| s.range,
        };
    }

    /// Draw order of the first primitive in this batch. Backdrop blurs with
    /// `order <= firstOrder` must be applied before drawing the batch.
    pub fn firstOrder(self: PrimitiveBatch, scene: *const Scene) DrawOrder {
        const start = self.range().start;
        return switch (self) {
            .shadow => scene.shadows.items[start].order,
            .quad => scene.quads.items[start].order,
            .path => scene.paths.items[start].order,
            .underline => scene.underlines.items[start].order,
            .monochrome_sprite => scene.monochrome_sprites.items[start].order,
            .subpixel_sprite => scene.subpixel_sprites.items[start].order,
            .polychrome_sprite => scene.polychrome_sprites.items[start].order,
            .surface => scene.surfaces.items[start].order,
            .viewport3d => scene.viewports3d.items[start].order,
        };
    }
};

/// The frame's display list. Unmanaged: pass the same allocator to every
/// mutating call and to `deinit`.
pub const Scene = struct {
    paint_operations: std.ArrayList(PaintOperation) = .empty,
    primitive_bounds: BoundsTree(ScaledPixels) = .{},
    layer_stack: std.ArrayList(DrawOrder) = .empty,
    shadows: std.ArrayList(Shadow) = .empty,
    quads: std.ArrayList(Quad) = .empty,
    /// Each path owns its `vertices` (freed by `clear`/`deinit`).
    paths: std.ArrayList(Path) = .empty,
    underlines: std.ArrayList(Underline) = .empty,
    monochrome_sprites: std.ArrayList(MonochromeSprite) = .empty,
    subpixel_sprites: std.ArrayList(SubpixelSprite) = .empty,
    polychrome_sprites: std.ArrayList(PolychromeSprite) = .empty,
    surfaces: std.ArrayList(PaintSurface) = .empty,
    viewports3d: std.ArrayList(Viewport3D) = .empty,
    /// Backdrop-blur regions, deliberately OUTSIDE the batch stream: the
    /// renderer breaks its render pass at each blur's order to snapshot the
    /// framebuffer, then resumes with the batch whose first order >= blur.order.
    backdrop_blurs: std.ArrayList(BackdropBlur) = .empty,

    pub fn deinit(self: *Scene, gpa: Allocator) void {
        self.freePathVertices(gpa);
        self.paint_operations.deinit(gpa);
        self.primitive_bounds.deinit(gpa);
        self.layer_stack.deinit(gpa);
        self.shadows.deinit(gpa);
        self.quads.deinit(gpa);
        self.paths.deinit(gpa);
        self.underlines.deinit(gpa);
        self.monochrome_sprites.deinit(gpa);
        self.subpixel_sprites.deinit(gpa);
        self.polychrome_sprites.deinit(gpa);
        self.surfaces.deinit(gpa);
        self.viewports3d.deinit(gpa);
        self.backdrop_blurs.deinit(gpa);
        self.* = undefined;
    }

    /// Reset for a new frame, keeping capacity.
    pub fn clear(self: *Scene, gpa: Allocator) void {
        self.freePathVertices(gpa);
        self.paint_operations.clearRetainingCapacity();
        self.primitive_bounds.clear();
        self.layer_stack.clearRetainingCapacity();
        self.shadows.clearRetainingCapacity();
        self.quads.clearRetainingCapacity();
        self.paths.clearRetainingCapacity();
        self.underlines.clearRetainingCapacity();
        self.monochrome_sprites.clearRetainingCapacity();
        self.subpixel_sprites.clearRetainingCapacity();
        self.polychrome_sprites.clearRetainingCapacity();
        self.surfaces.clearRetainingCapacity();
        self.viewports3d.clearRetainingCapacity();
        self.backdrop_blurs.clearRetainingCapacity();
    }

    fn freePathVertices(self: *Scene, gpa: Allocator) void {
        for (self.paths.items) |*p| p.vertices.deinit(gpa);
    }

    /// Whether there are no drawable operations (layer markers are ignored).
    pub fn isEmpty(self: *const Scene) bool {
        for (self.paint_operations.items) |op| switch (op) {
            .start_layer, .end_layer => {},
            else => return false,
        };
        return true;
    }

    /// Number of recorded paint operations (the unit `replay` ranges use).
    pub fn len(self: *const Scene) usize {
        return self.paint_operations.items.len;
    }

    /// Start a layer: everything inserted until `popLayer` shares one draw order,
    /// assigned from `bounds`.
    pub fn pushLayer(self: *Scene, gpa: Allocator, bounds: Bounds) Allocator.Error!void {
        try self.paint_operations.ensureUnusedCapacity(gpa, 1);
        try self.layer_stack.ensureUnusedCapacity(gpa, 1);
        const order = try self.primitive_bounds.insert(gpa, bounds);
        self.layer_stack.appendAssumeCapacity(order);
        self.paint_operations.appendAssumeCapacity(.{ .start_layer = bounds });
    }

    pub fn popLayer(self: *Scene, gpa: Allocator) Allocator.Error!void {
        _ = self.layer_stack.pop();
        try self.paint_operations.append(gpa, .end_layer);
    }

    fn nextOrder(self: *Scene, gpa: Allocator, clipped: Bounds) Allocator.Error!DrawOrder {
        if (self.layer_stack.getLastOrNull()) |order| return order;
        return self.primitive_bounds.insert(gpa, clipped);
    }

    /// Record a backdrop blur at the current order. Fully clipped blurs are dropped.
    pub fn insertBackdropBlur(self: *Scene, gpa: Allocator, blur_in: BackdropBlur) Allocator.Error!void {
        var blur = blur_in;
        const clipped = blur.bounds.intersect(blur.content_mask.bounds);
        if (clipped.isEmpty()) return;
        try self.backdrop_blurs.ensureUnusedCapacity(gpa, 1);
        try self.paint_operations.ensureUnusedCapacity(gpa, 1);
        blur.order = try self.nextOrder(gpa, clipped);
        self.backdrop_blurs.appendAssumeCapacity(blur);
        self.paint_operations.appendAssumeCapacity(.{ .backdrop_blur = blur });
    }

    /// Record a primitive; its `order` (and a path's `id`) is overwritten.
    /// Primitives fully outside their content mask are dropped. Path vertices
    /// are copied, so the caller keeps ownership of `primitive`'s vertex list.
    pub fn insertPrimitive(self: *Scene, gpa: Allocator, primitive_in: Primitive) Allocator.Error!void {
        var primitive = primitive_in;
        const clipped = primitive.bounds().intersect(primitive.contentMask().bounds);
        if (clipped.isEmpty()) return;

        try self.paint_operations.ensureUnusedCapacity(gpa, 1);
        switch (primitive) {
            inline else => |_, tag| try self.listFor(tag).ensureUnusedCapacity(gpa, 1),
        }
        if (primitive == .path) {
            primitive.path.vertices = try primitive.path.vertices.clone(gpa);
        }
        errdefer if (primitive == .path) primitive.path.vertices.deinit(gpa);
        const order = try self.nextOrder(gpa, clipped);

        switch (primitive) {
            .path => |*p| {
                p.order = order;
                p.id = self.paths.items.len;
                self.paths.appendAssumeCapacity(p.*);
            },
            inline else => |*p, tag| {
                p.order = order;
                self.listFor(tag).appendAssumeCapacity(p.*);
            },
        }
        self.paint_operations.appendAssumeCapacity(.{ .primitive = primitive });
    }

    fn ListFor(comptime kind: PrimitiveKind) type {
        return std.ArrayList(@FieldType(Primitive, @tagName(kind)));
    }

    fn listFor(self: *Scene, comptime kind: PrimitiveKind) *ListFor(kind) {
        return switch (kind) {
            .shadow => &self.shadows,
            .quad => &self.quads,
            .path => &self.paths,
            .underline => &self.underlines,
            .monochrome_sprite => &self.monochrome_sprites,
            .subpixel_sprite => &self.subpixel_sprites,
            .polychrome_sprite => &self.polychrome_sprites,
            .surface => &self.surfaces,
            .viewport3d => &self.viewports3d,
        };
    }

    pub fn insertShadow(self: *Scene, gpa: Allocator, v: Shadow) Allocator.Error!void {
        return self.insertPrimitive(gpa, .{ .shadow = v });
    }
    pub fn insertQuad(self: *Scene, gpa: Allocator, v: Quad) Allocator.Error!void {
        return self.insertPrimitive(gpa, .{ .quad = v });
    }
    /// Copies `v.vertices`; the caller still owns (and must free) its path.
    pub fn insertPath(self: *Scene, gpa: Allocator, v: Path) Allocator.Error!void {
        return self.insertPrimitive(gpa, .{ .path = v });
    }
    pub fn insertUnderline(self: *Scene, gpa: Allocator, v: Underline) Allocator.Error!void {
        return self.insertPrimitive(gpa, .{ .underline = v });
    }
    pub fn insertMonochromeSprite(self: *Scene, gpa: Allocator, v: MonochromeSprite) Allocator.Error!void {
        return self.insertPrimitive(gpa, .{ .monochrome_sprite = v });
    }
    pub fn insertSubpixelSprite(self: *Scene, gpa: Allocator, v: SubpixelSprite) Allocator.Error!void {
        return self.insertPrimitive(gpa, .{ .subpixel_sprite = v });
    }
    pub fn insertPolychromeSprite(self: *Scene, gpa: Allocator, v: PolychromeSprite) Allocator.Error!void {
        return self.insertPrimitive(gpa, .{ .polychrome_sprite = v });
    }
    pub fn insertViewport3D(self: *Scene, gpa: Allocator, v: Viewport3D) Allocator.Error!void {
        return self.insertPrimitive(gpa, .{ .viewport3d = v });
    }
    pub fn insertSurface(self: *Scene, gpa: Allocator, v: PaintSurface) Allocator.Error!void {
        return self.insertPrimitive(gpa, .{ .surface = v });
    }

    /// Re-record `prev.paint_operations[start..end]` into this scene (view caching).
    /// Orders are reassigned against this scene's bounds tree.
    pub fn replay(self: *Scene, gpa: Allocator, start: usize, end: usize, prev: *const Scene) Allocator.Error!void {
        for (prev.paint_operations.items[start..end]) |op| switch (op) {
            .primitive => |p| try self.insertPrimitive(gpa, p),
            .backdrop_blur => |b| try self.insertBackdropBlur(gpa, b),
            .start_layer => |b| try self.pushLayer(gpa, b),
            .end_layer => try self.popLayer(gpa),
        };
    }

    /// Sort every primitive list by draw order (sprites by (order, tile_id)).
    /// Stable, like Rust's `sort_by_key`.
    pub fn finish(self: *Scene) void {
        sortByOrder(Shadow, self.shadows.items);
        sortByOrder(Quad, self.quads.items);
        sortByOrder(Path, self.paths.items);
        sortByOrder(Underline, self.underlines.items);
        sortSprites(MonochromeSprite, self.monochrome_sprites.items);
        sortSprites(SubpixelSprite, self.subpixel_sprites.items);
        sortSprites(PolychromeSprite, self.polychrome_sprites.items);
        sortByOrder(PaintSurface, self.surfaces.items);
        sortByOrder(Viewport3D, self.viewports3d.items);
        sortByOrder(BackdropBlur, self.backdrop_blurs.items);
    }

    fn sortByOrder(comptime T: type, items: []T) void {
        std.mem.sort(T, items, {}, struct {
            fn lt(_: void, a: T, b: T) bool {
                return a.order < b.order;
            }
        }.lt);
    }

    fn sortSprites(comptime T: type, items: []T) void {
        std.mem.sort(T, items, {}, struct {
            fn lt(_: void, a: T, b: T) bool {
                if (a.order != b.order) return a.order < b.order;
                return a.tile.tile_id < b.tile.tile_id;
            }
        }.lt);
    }

    /// Iterate batches in draw order. Call after `finish`.
    pub fn batches(self: *const Scene) BatchIterator {
        return .{ .scene = self };
    }
};

/// Walks the sorted primitive lists, merging them by (order, kind).
/// Mirrors zui's `BatchIterator`, including the backdrop-blur split rule.
pub const BatchIterator = struct {
    scene: *const Scene,
    /// Next unconsumed index per `PrimitiveKind`.
    starts: [kind_count]usize = @splat(0),
    blur_index: usize = 0,

    const kind_count = @typeInfo(PrimitiveKind).@"enum".field_names.len;
    const max_order = std.math.maxInt(DrawOrder);

    const Key = struct {
        order: DrawOrder,
        kind: PrimitiveKind,

        fn lessThan(a: Key, b: Key) bool {
            if (a.order != b.order) return a.order < b.order;
            return @backingInt(a.kind) < @backingInt(b.kind);
        }
    };

    fn peekOrder(self: *const BatchIterator, comptime kind: PrimitiveKind) ?DrawOrder {
        const items = self.list(kind);
        const i = self.starts[@backingInt(kind)];
        return if (i < items.len) items[i].order else null;
    }

    fn list(self: *const BatchIterator, comptime kind: PrimitiveKind) []const @FieldType(Primitive, @tagName(kind)) {
        const s = self.scene;
        return switch (kind) {
            .shadow => s.shadows.items,
            .quad => s.quads.items,
            .path => s.paths.items,
            .underline => s.underlines.items,
            .monochrome_sprite => s.monochrome_sprites.items,
            .subpixel_sprite => s.subpixel_sprites.items,
            .polychrome_sprite => s.polychrome_sprites.items,
            .surface => s.surfaces.items,
            .viewport3d => s.viewports3d.items,
        };
    }

    pub fn next(self: *BatchIterator) ?PrimitiveBatch {
        // Find the two smallest (order, kind) heads; missing lists sort last as (MAX, kind).
        // (zui sorts all eight heads; tracking the two smallest is equivalent.)
        var first: Key = .{ .order = max_order, .kind = .surface };
        var first_present = false;
        var second: Key = first;
        var have_first = false;
        var have_second = false;
        inline for (comptime std.enums.values(PrimitiveKind)) |kind| {
            const peeked = self.peekOrder(kind);
            const key: Key = .{ .order = peeked orelse max_order, .kind = kind };
            if (!have_first or key.lessThan(first)) {
                if (have_first) {
                    second = first;
                    have_second = true;
                }
                first = key;
                first_present = peeked != null;
                have_first = true;
            } else if (!have_second or key.lessThan(second)) {
                second = key;
                have_second = true;
            }
        }
        if (!first_present) return null;
        const head = first;
        var limit: Key = second;

        // Blurs run before primitives at their order. The invisible shadow
        // splitter can coalesce with earlier shadows, so every kind must stop
        // before the next blur, even when no other kind remains.
        const blurs = self.scene.backdrop_blurs.items;
        while (self.blur_index < blurs.len and blurs[self.blur_index].order <= head.order) self.blur_index += 1;
        if (self.blur_index < blurs.len) {
            const blur_key: Key = .{ .order = blurs[self.blur_index].order, .kind = .shadow };
            if (blur_key.lessThan(limit)) limit = blur_key;
        }

        switch (head.kind) {
            inline else => |kind| {
                const items = self.list(kind);
                const start = self.starts[@backingInt(kind)];
                var end = start + 1;
                switch (kind) {
                    .monochrome_sprite, .subpixel_sprite, .polychrome_sprite => {
                        const texture_id = items[start].tile.texture_id;
                        while (end < items.len and
                            (Key{ .order = items[end].order, .kind = kind }).lessThan(limit) and
                            items[end].tile.texture_id.eql(texture_id)) end += 1;
                        self.starts[@backingInt(kind)] = end;
                        return @unionInit(PrimitiveBatch, @tagName(kind), .{
                            .texture_id = texture_id,
                            .range = .{ .start = start, .end = end },
                        });
                    },
                    else => {
                        while (end < items.len and (Key{ .order = items[end].order, .kind = kind }).lessThan(limit)) end += 1;
                        self.starts[@backingInt(kind)] = end;
                        return @unionInit(PrimitiveBatch, @tagName(kind), .{ .start = start, .end = end });
                    },
                }
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testBounds() Bounds {
    return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 100, .height = 100 } };
}

fn rectAt(x: f32, y: f32, w: f32, h: f32) Bounds {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

fn testShadow(c: Hsla) Shadow {
    return .{
        .bounds = testBounds(),
        .content_mask = .{ .bounds = testBounds() },
        .color = c,
        .element_bounds = testBounds(),
    };
}

fn testTile(index: u32, tile_id: u32) AtlasTile {
    return .{
        .texture_id = .{ .index = index, .kind = .monochrome },
        .tile_id = tile_id,
        .padding = 0,
        .bounds = .{ .origin = .zero, .size = .zero },
    };
}

/// Matches `Window::paint_backdrop_blur`, including its invisible shadow splitter.
fn paintBlur(scene: *Scene, gpa: Allocator) !void {
    try scene.insertShadow(gpa, testShadow(color.transparent_black));
    try scene.insertBackdropBlur(gpa, .{
        .blur_radius = 10,
        .bounds = testBounds(),
        .content_mask = .{ .bounds = testBounds() },
    });
}

fn collectBatches(gpa: Allocator, scene: *const Scene) !std.ArrayList(PrimitiveBatch) {
    var out: std.ArrayList(PrimitiveBatch) = .empty;
    var it = scene.batches();
    while (it.next()) |b| try out.append(gpa, b);
    return out;
}

test "batches split shadows at nested backdrop blurs" {
    const gpa = testing.allocator;
    var scene: Scene = .{};
    defer scene.deinit(gpa);
    try scene.insertShadow(gpa, testShadow(color.black));
    try scene.pushLayer(gpa, testBounds());
    try paintBlur(&scene, gpa);
    try scene.insertShadow(gpa, testShadow(color.black));
    try scene.pushLayer(gpa, testBounds());
    try paintBlur(&scene, gpa);
    try scene.insertShadow(gpa, testShadow(color.black));
    try scene.popLayer(gpa);
    try scene.popLayer(gpa);
    scene.finish();

    const s = scene.shadows.items;
    const blurs = scene.backdrop_blurs.items;
    try testing.expect(s[0].order < blurs[0].order);
    try testing.expectEqual(blurs[0].order, s[1].order);
    try testing.expectEqual(s[1].order, s[2].order);
    try testing.expect(s[2].order < blurs[1].order);
    try testing.expectEqual(blurs[1].order, s[3].order);

    var list = try collectBatches(gpa, &scene);
    defer list.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), list.items.len);
    const want_ranges = [_]Range{ .{ .start = 0, .end = 1 }, .{ .start = 1, .end = 3 }, .{ .start = 3, .end = 5 } };
    const want_orders = [_]DrawOrder{ s[0].order, s[1].order, s[3].order };
    for (list.items, want_ranges, want_orders) |b, r, o| {
        try testing.expect(b == .shadow);
        try testing.expectEqual(r, b.shadow);
        try testing.expectEqual(o, b.firstOrder(&scene));
    }
}

test "batches coalesce shadows without backdrop blurs" {
    const gpa = testing.allocator;
    var scene: Scene = .{};
    defer scene.deinit(gpa);
    for (0..3) |_| try scene.insertShadow(gpa, testShadow(color.black));
    scene.finish();
    var list = try collectBatches(gpa, &scene);
    defer list.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), list.items.len);
    try testing.expectEqual(Range{ .start = 0, .end = 3 }, list.items[0].shadow);
}

test "batches split quads at direct scene blur" {
    const gpa = testing.allocator;
    var scene: Scene = .{};
    defer scene.deinit(gpa);
    const quad: Quad = .{ .bounds = testBounds(), .content_mask = .{ .bounds = testBounds() } };
    try scene.insertQuad(gpa, quad);
    try scene.insertBackdropBlur(gpa, .{ .blur_radius = 10, .bounds = testBounds(), .content_mask = .{ .bounds = testBounds() } });
    try scene.insertQuad(gpa, quad);
    scene.finish();

    try testing.expect(scene.quads.items[0].order < scene.backdrop_blurs.items[0].order);
    try testing.expect(scene.quads.items[1].order > scene.backdrop_blurs.items[0].order);
    var list = try collectBatches(gpa, &scene);
    defer list.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqual(Range{ .start = 0, .end = 1 }, list.items[0].quad);
    try testing.expectEqual(Range{ .start = 1, .end = 2 }, list.items[1].quad);
    try testing.expectEqual(scene.quads.items[1].order, list.items[1].firstOrder(&scene));
}

test "batches preserve sprite texture boundaries" {
    const gpa = testing.allocator;
    var scene: Scene = .{};
    defer scene.deinit(gpa);
    for ([_]u32{ 0, 0, 1, 1, 0 }) |index| {
        try scene.insertMonochromeSprite(gpa, .{
            .bounds = testBounds(),
            .content_mask = .{ .bounds = testBounds() },
            .color = color.black,
            .tile = testTile(index, 0),
        });
    }
    scene.finish();
    var list = try collectBatches(gpa, &scene);
    defer list.deinit(gpa);
    const want = [_]struct { u32, Range }{
        .{ 0, .{ .start = 0, .end = 2 } },
        .{ 1, .{ .start = 2, .end = 4 } },
        .{ 0, .{ .start = 4, .end = 5 } },
    };
    try testing.expectEqual(want.len, list.items.len);
    for (list.items, want) |b, w| {
        try testing.expectEqual(w[0], b.monochrome_sprite.texture_id.index);
        try testing.expectEqual(w[1], b.monochrome_sprite.range);
    }
}

test "draw order interleaves kinds and finish sorts by order" {
    const gpa = testing.allocator;
    var scene: Scene = .{};
    defer scene.deinit(gpa);
    const b = testBounds();
    const mask: ContentMask = .{ .bounds = rectAt(0, 0, 1000, 1000) };
    // Overlapping: quad(1) shadow(2) quad(3) -> three batches in that order.
    try scene.insertQuad(gpa, .{ .bounds = b, .content_mask = mask });
    try scene.insertShadow(gpa, .{ .bounds = b, .content_mask = mask, .element_bounds = b });
    try scene.insertQuad(gpa, .{ .bounds = b, .content_mask = mask });
    // Disjoint quad reuses order 1 -> sorts first and coalesces into the first quad batch.
    try scene.insertQuad(gpa, .{ .bounds = rectAt(500, 500, 10, 10), .content_mask = mask });
    // Fully clipped primitive is dropped.
    try scene.insertQuad(gpa, .{ .bounds = rectAt(2000, 0, 10, 10), .content_mask = mask });
    try testing.expectEqual(@as(usize, 3), scene.quads.items.len);
    try testing.expectEqual(@as(usize, 4), scene.len());
    scene.finish();

    const orders = [_]DrawOrder{ scene.quads.items[0].order, scene.quads.items[1].order, scene.quads.items[2].order };
    try testing.expectEqualSlices(DrawOrder, &.{ 1, 1, 3 }, &orders);
    try testing.expectEqual(@as(DrawOrder, 2), scene.shadows.items[0].order);

    var list = try collectBatches(gpa, &scene);
    defer list.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expectEqual(Range{ .start = 0, .end = 2 }, list.items[0].quad);
    try testing.expectEqual(Range{ .start = 0, .end = 1 }, list.items[1].shadow);
    try testing.expectEqual(Range{ .start = 2, .end = 3 }, list.items[2].quad);
}

test "equal order breaks ties by kind" {
    const gpa = testing.allocator;
    var scene: Scene = .{};
    defer scene.deinit(gpa);
    const b = testBounds();
    const mask: ContentMask = .{ .bounds = b };
    try scene.pushLayer(gpa, b);
    try scene.insertUnderline(gpa, .{ .bounds = b, .content_mask = mask });
    try scene.insertQuad(gpa, .{ .bounds = b, .content_mask = mask });
    try scene.insertShadow(gpa, .{ .bounds = b, .content_mask = mask, .element_bounds = b });
    try scene.popLayer(gpa);
    scene.finish();
    var list = try collectBatches(gpa, &scene);
    defer list.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), list.items.len);
    try testing.expect(list.items[0] == .shadow);
    try testing.expect(list.items[1] == .quad);
    try testing.expect(list.items[2] == .underline);
}

test "paths own vertices, replay re-records operations" {
    const gpa = testing.allocator;
    var path = Path.init(.{ .x = 0, .y = 0 });
    defer path.deinit(gpa);
    try path.lineTo(gpa, .{ .x = 10, .y = 0 });
    try path.lineTo(gpa, .{ .x = 10, .y = 10 });
    try path.curveTo(gpa, .{ .x = 0, .y = 10 }, .{ .x = 5, .y = 15 });
    try testing.expectEqual(@as(usize, 9), path.vertices.items.len);
    try testing.expectEqual(@as(f32, 15), path.bounds.bottom());
    path.content_mask = .{ .bounds = testBounds() };

    var scaled = try path.scale(gpa, 2);
    defer scaled.deinit(gpa);
    try testing.expectEqual(@as(f32, 30), scaled.bounds.bottom());
    try testing.expectEqual(@as(f32, 20), scaled.vertices.items[1].xy_position.x);

    var prev: Scene = .{};
    defer prev.deinit(gpa);
    try prev.pushLayer(gpa, testBounds());
    try prev.insertPath(gpa, path);
    try prev.insertBackdropBlur(gpa, .{ .bounds = testBounds(), .content_mask = .{ .bounds = testBounds() } });
    try prev.popLayer(gpa);
    try testing.expect(!prev.isEmpty());

    var next: Scene = .{};
    defer next.deinit(gpa);
    try next.replay(gpa, 0, prev.len(), &prev);
    next.finish();
    try testing.expectEqual(@as(usize, 1), next.paths.items.len);
    try testing.expectEqual(@as(usize, 1), next.backdrop_blurs.items.len);
    try testing.expectEqual(@as(usize, 9), next.paths.items[0].vertices.items.len);
    try testing.expect(next.paths.items[0].vertices.items.ptr != prev.paths.items[0].vertices.items.ptr);

    next.clear(gpa);
    try testing.expect(next.isEmpty());
    var empty_layers: Scene = .{};
    defer empty_layers.deinit(gpa);
    try empty_layers.pushLayer(gpa, testBounds());
    try empty_layers.popLayer(gpa);
    try testing.expect(empty_layers.isEmpty());
}

test "transformation matrix and image helpers" {
    const t = TransformationMatrix.unit.translate(.{ .x = 10, .y = 5 }).scale(.{ .width = 2, .height = 3 });
    const p = t.apply(.{ .x = 1, .y = 1 });
    try testing.expectEqual(@as(f32, 12), p.x);
    try testing.expectEqual(@as(f32, 8), p.y);
    const r = TransformationMatrix.unit.rotate(std.math.pi / 2.0).apply(.{ .x = 1, .y = 0 });
    try testing.expectApproxEqAbs(@as(f32, 0), r.x, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), r.y, 1e-6);

    const mask: ImageAlphaMask = .{
        .bounds = .{ .origin = .{ .x = 40.25, .y = 300.5 }, .size = .{ .width = 500, .height = 100 } },
        .radius = 80,
        .feather = 220,
        .clearance = 8,
        .bottom_fade = .{ .y = 480, .feather = 96.8 },
    };
    for ([_]f32{ 1.0, 1.25, 2.0 }) |factor| {
        const s = mask.scale(factor);
        try testing.expectEqual(mask.bounds.scale(factor), s.bounds);
        try testing.expectEqual(50.0 * factor, s.radius);
        try testing.expectEqual(220.0 * factor, s.feather);
        try testing.expectEqual(8.0 * factor, s.clearance);
        try testing.expectEqual(480.0 * factor, s.bottom_y);
        try testing.expectEqual(96.8 * factor, s.bottom_feather);
    }

    // Cover: a 200x100 fitted box showing its middle 100x100 crops the tile's middle half.
    var tile = testTile(0, 0);
    tile.bounds = .{ .origin = .{ .x = 10, .y = 20 }, .size = .{ .width = 400, .height = 200 } };
    const cropped = cropTileForFit(tile, rectAt(50, 0, 100, 100), rectAt(0, 0, 200, 100));
    try testing.expectEqual(@as(i32, 110), cropped.bounds.origin.x);
    try testing.expectEqual(@as(i32, 20), cropped.bounds.origin.y);
    try testing.expectEqual(@as(i32, 200), cropped.bounds.size.width);
    try testing.expectEqual(@as(i32, 200), cropped.bounds.size.height);
}
