//! GPU-visible structs shared by both backends. Every struct mirrors a GLSL
//! declaration in `src/renderer/three/shaders/three.glsl` (scalar layout: only
//! vec4/mat4/uvec4 members, so std430, scalar and MSL agree byte for byte).

const std = @import("std");
const math = @import("math.zig");
const Mat4 = math.Mat4;

/// Per-viewport constants (`FrameData` in three.glsl).
pub const FrameData = extern struct {
    view_proj: Mat4,
    view: Mat4,
    proj: Mat4,
    inv_proj: Mat4,
    light_view_proj: Mat4,
    /// xyz eye, w = 1 for orthographic cameras.
    camera_pos: [4]f32,
    /// xyz unit vector toward the light, w = 1 when shadows are on.
    sun_dir: [4]f32,
    /// rgb * intensity.
    sun_color: [4]f32,
    sky: [4]f32,
    ground: [4]f32,
    /// rgb (linear), w = exp2 density (0 = off).
    fog: [4]f32,
    /// x depth bias, y normal offset (world units), z 1/map size, w PCF radius (texels).
    shadow: [4]f32,
    /// width, height, 1/width, 1/height.
    viewport: [4]f32,
    /// x = SH9 intensity (0 = no environment).
    env: [4]f32,
    sh: [9][4]f32,
};

pub const DrawFlags = struct {
    pub const has_normals: u32 = 1 << 0;
    pub const has_uvs: u32 = 1 << 1;
    pub const vertex_colors: u32 = 1 << 2;
    pub const base_texture: u32 = 1 << 3;
    pub const palette: u32 = 1 << 4;
    pub const receive_shadows: u32 = 1 << 5;
    pub const fog: u32 = 1 << 6;
    pub const alpha_mask: u32 = 1 << 7;
    pub const highlight: u32 = 1 << 8;
    pub const double_sided: u32 = 1 << 9;
    pub const blend: u32 = 1 << 10;
    pub const outline_pixels: u32 = 1 << 11;
};

/// Per-draw material constants (`DrawData` in three.glsl).
pub const DrawData = extern struct {
    base_color: [4]f32,
    emissive: [4]f32,
    /// x metallic, y roughness, z alpha cutoff.
    pbr: [4]f32,
    /// x bands, y min brightness, z edge softness.
    toon: [4]f32,
    /// x scale, y amount.
    detail: [4]f32,
    outline_color: [4]f32,
    /// x width (world units or pixels per `DrawFlags.outline_pixels`).
    outline: [4]f32,
    highlight_color: [4]f32,
    /// x DrawFlags, y highlight id, z shading model, w id format (0 none, 1 u8, 2 u16, 3 u32).
    flags: [4]u32,
};

/// Post/composite constants (`PostParams` in three.glsl), 64 bytes: fits
/// Vulkan push constants and Metal `setFragmentBytes`.
pub const PostParams = extern struct {
    p0: [4]f32 = .{ 0, 0, 0, 0 },
    p1: [4]f32 = .{ 0, 0, 0, 0 },
    p2: [4]f32 = .{ 0, 0, 0, 0 },
    p3: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Shader binding slots (MSL buffer/texture indices; Vulkan descriptor bindings for textures).
pub const Binding = struct {
    pub const positions = 0;
    pub const normals = 1;
    pub const uvs = 2;
    pub const colors = 3;
    pub const ids = 4;
    pub const instances = 5;
    pub const frame = 6;
    pub const draw = 7;
    pub const shadow_map = 8;
    pub const base_texture = 9;
    pub const palette = 10;
    // post / composite
    pub const post_params = 0;
    pub const post_tex0 = 1;
    pub const post_tex1 = 2;
    pub const post_tex2 = 3;
};

comptime {
    std.debug.assert(@sizeOf(FrameData) == 5 * 64 + 9 * 16 + 9 * 16);
    std.debug.assert(@sizeOf(DrawData) == 9 * 16);
    std.debug.assert(@sizeOf(PostParams) == 64);
    std.debug.assert(@sizeOf(@import("scene3d.zig").Instance) == 96);
}
