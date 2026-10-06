//! zpui.three spike: a CPU-side 3D scene description that a `viewport3d`
//! primitive points at. Backends render it offscreen (HDR color + depth,
//! MSAA) before the main UI pass and composite it in draw order.
//!
//! Spike limitations: meshes are re-uploaded into the per-frame host buffer
//! every frame (no persistent GPU resource store yet), one directional light,
//! no textures, no shadow map.

const std = @import("std");
pub const math = @import("math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

/// 24 bytes, scalar layout (pulled through a buffer address on Vulkan).
pub const Vertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
};

pub const Mesh = struct {
    vertices: []const Vertex,
    indices: []const u32,
};

pub const Material = struct {
    base_color: [4]f32 = .{ 0.8, 0.8, 0.8, 1 },
    metallic: f32 = 0,
    roughness: f32 = 0.6,
};

pub const Draw = struct {
    mesh: *const Mesh,
    model: Mat4 = Mat4.identity,
    material: Material = .{},
};

pub const Camera = struct {
    eye: Vec3 = .new(3, 2.5, 4),
    target: Vec3 = .new(0, 0, 0),
    up: Vec3 = .new(0, 1, 0),
    fov_y: f32 = std.math.pi / 4.0,
    near: f32 = 0.05,
};

pub const DirectionalLight = struct {
    /// Direction the light travels (from the light toward the scene).
    direction: Vec3 = .new(-0.4, -1, -0.3),
    color: Vec3 = .new(1, 0.95, 0.85),
    intensity: f32 = 3,
};

pub const Scene3D = struct {
    camera: Camera = .{},
    light: DirectionalLight = .{},
    ambient: Vec3 = .new(0.08, 0.09, 0.11),
    /// Linear HDR clear color; alpha 0 lets the UI underneath show through.
    clear: [4]f32 = .{ 0, 0, 0, 0 },
    exposure: f32 = 1,
    draws: std.ArrayList(Draw) = .empty,

    pub fn deinit(self: *Scene3D, gpa: std.mem.Allocator) void {
        self.draws.deinit(gpa);
    }

    pub fn draw(self: *Scene3D, gpa: std.mem.Allocator, d: Draw) !void {
        try self.draws.append(gpa, d);
    }

    /// `flip_y` = Vulkan clip space (NDC +y down).
    pub fn frameUniforms(self: *const Scene3D, aspect: f32, flip_y: bool) FrameUniforms {
        const view = Mat4.lookAt(self.camera.eye, self.camera.target, self.camera.up);
        const proj = Mat4.perspectiveReverseZ(self.camera.fov_y, aspect, self.camera.near, flip_y);
        const to_light = self.light.direction.scale(-1).normalize();
        const lc = self.light.color.scale(self.light.intensity);
        return .{
            .view_proj = proj.mul(view),
            .camera_pos = .{ self.camera.eye.x, self.camera.eye.y, self.camera.eye.z, 1 },
            .light_dir = .{ to_light.x, to_light.y, to_light.z, 0 },
            .light_color = .{ lc.x, lc.y, lc.z, 0 },
            .ambient = .{ self.ambient.x, self.ambient.y, self.ambient.z, 0 },
        };
    }
};

/// Per-viewport uniforms (128 bytes); mirrors `FrameUniforms` in shaders/three_common.glsl.
pub const FrameUniforms = extern struct {
    view_proj: Mat4,
    camera_pos: [4]f32,
    light_dir: [4]f32,
    light_color: [4]f32,
    ambient: [4]f32,
};

/// Per-draw data (96 bytes); mirrors `DrawData` in shaders/three_common.glsl.
pub const DrawData = extern struct {
    model: Mat4,
    base_color: [4]f32,
    /// x = metallic, y = roughness.
    params: [4]f32,
};

comptime {
    std.debug.assert(@sizeOf(Vertex) == 24);
    std.debug.assert(@sizeOf(FrameUniforms) == 128);
    std.debug.assert(@sizeOf(DrawData) == 96);
}

/// Unit cube centered at the origin with per-face normals (24 vertices, 36 indices).
pub const cube: Mesh = blk: {
    const faces = [6][2][3]f32{
        .{ .{ 1, 0, 0 }, .{ 0, 1, 0 } },  .{ .{ -1, 0, 0 }, .{ 0, 1, 0 } },
        .{ .{ 0, 1, 0 }, .{ 0, 0, 1 } },  .{ .{ 0, -1, 0 }, .{ 0, 0, 1 } },
        .{ .{ 0, 0, 1 }, .{ 0, 1, 0 } },  .{ .{ 0, 0, -1 }, .{ 0, 1, 0 } },
    };
    var verts: [24]Vertex = undefined;
    var idx: [36]u32 = undefined;
    for (faces, 0..) |f, i| {
        const n = Vec3.new(f[0][0], f[0][1], f[0][2]);
        const up = Vec3.new(f[1][0], f[1][1], f[1][2]);
        const right = up.cross(n);
        const corners = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
        for (corners, 0..) |cr, j| {
            const p = n.scale(0.5).add(right.scale(0.5 * cr[0])).add(up.scale(0.5 * cr[1]));
            verts[i * 4 + j] = .{ .pos = .{ p.x, p.y, p.z }, .normal = .{ n.x, n.y, n.z } };
        }
        const b: u32 = @intCast(i * 4);
        // Counter-clockwise seen from outside (right, up, n is right-handed).
        idx[i * 6 ..][0..6].* = .{ b, b + 1, b + 2, b, b + 2, b + 3 };
    }
    const fv = verts;
    const fi = idx;
    break :blk .{ .vertices = &fv, .indices = &fi };
};

/// Unit square in the XZ plane facing +Y.
pub const plane: Mesh = .{
    .vertices = &.{
        .{ .pos = .{ -0.5, 0, -0.5 }, .normal = .{ 0, 1, 0 } },
        .{ .pos = .{ -0.5, 0, 0.5 }, .normal = .{ 0, 1, 0 } },
        .{ .pos = .{ 0.5, 0, 0.5 }, .normal = .{ 0, 1, 0 } },
        .{ .pos = .{ 0.5, 0, -0.5 }, .normal = .{ 0, 1, 0 } },
    },
    .indices = &.{ 0, 1, 2, 0, 2, 3 },
};

test {
    _ = math;
}

test "cube winding is counter-clockwise from outside" {
    for (0..12) |t| {
        const a = cube.vertices[cube.indices[t * 3]];
        const b = cube.vertices[cube.indices[t * 3 + 1]];
        const c = cube.vertices[cube.indices[t * 3 + 2]];
        const pa = Vec3.new(a.pos[0], a.pos[1], a.pos[2]);
        const n = Vec3.new(b.pos[0], b.pos[1], b.pos[2]).sub(pa).cross(Vec3.new(c.pos[0], c.pos[1], c.pos[2]).sub(pa));
        try std.testing.expect(n.dot(.new(a.normal[0], a.normal[1], a.normal[2])) > 0);
    }
}
