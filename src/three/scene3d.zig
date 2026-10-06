//! `Scene3D`: what a `viewport3d` shows. A camera, one directional key light
//! (with an optional shadow map), hemisphere / SH9 ambient fill, fog, post
//! settings, and a per-frame draw list of (mesh, material, instances).
//!
//! The app rebuilds the draw list whenever it likes (`clear` + `draw*`), from
//! `render()` or an animation callback. Renderers hash the scene's inputs each
//! frame and skip the 3D passes when nothing changed, re-compositing the cached
//! image, so rebuilding an identical list costs no GPU time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("math.zig");
const gfx_mod = @import("gfx.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Aabb = math.Aabb;
const Ray = math.Ray;
const Gfx3D = gfx_mod.Gfx3D;
const MeshId = gfx_mod.MeshId;
const TextureId = gfx_mod.TextureId;

// ---------------------------------------------------------------------------
// Camera
// ---------------------------------------------------------------------------

pub const Projection = union(enum) {
    perspective: Perspective,
    orthographic: Orthographic,

    pub const Perspective = struct {
        /// Vertical field of view, radians.
        fov_y: f32 = std.math.pi / 4.0,
        near: f32 = 0.05,
        /// `inf` = infinite far plane (reverse-Z keeps precision).
        far: f32 = std.math.inf(f32),
    };
    pub const Orthographic = struct {
        /// World units visible vertically.
        height: f32 = 10,
        near: f32 = 0.01,
        far: f32 = 1000,
    };
};

/// A rectangle in some 2D pixel space (window or viewport), y down.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,

    pub fn aspect(r: Rect) f32 {
        return if (r.height > 0) r.width / r.height else 1;
    }
};

pub const Camera = struct {
    eye: Vec3 = .new(3, 2.5, 4),
    target: Vec3 = .zero,
    up: Vec3 = .up,
    projection: Projection = .{ .perspective = .{} },

    pub fn view(self: Camera) Mat4 {
        return Mat4.lookAt(self.eye, self.target, self.up);
    }

    /// `flip_y`: Vulkan-style clip space (NDC +y down). Both backends consume
    /// `flip_y = true` matrices; the CPU (picking) uses `false`.
    pub fn proj(self: Camera, aspect: f32, flip_y: bool) Mat4 {
        return switch (self.projection) {
            .perspective => |p| Mat4.perspectiveReverseZ(p.fov_y, aspect, p.near, p.far, flip_y),
            .orthographic => |o| Mat4.orthographicReverseZ(-o.height * aspect / 2, o.height * aspect / 2, -o.height / 2, o.height / 2, o.near, o.far, flip_y),
        };
    }

    pub fn viewProj(self: Camera, aspect: f32, flip_y: bool) Mat4 {
        return self.proj(aspect, flip_y).mul(self.view());
    }

    pub fn isOrthographic(self: Camera) bool {
        return self.projection == .orthographic;
    }

    /// World-space ray through `point` (same pixel space as `viewport`).
    pub fn ray(self: Camera, viewport: Rect, point: [2]f32) Ray {
        const ndc_x = 2 * (point[0] - viewport.x) / viewport.width - 1;
        const ndc_y = 1 - 2 * (point[1] - viewport.y) / viewport.height;
        const inv = self.viewProj(viewport.aspect(), false).inverse() orelse return .{ .origin = self.eye, .dir = self.target.sub(self.eye).normalize() };
        // Reverse-Z: depth 1 is the near plane; 0.5 is finite even for an infinite far plane.
        const near = inv.project(.new(ndc_x, ndc_y, 1));
        const far = inv.project(.new(ndc_x, ndc_y, if (self.isOrthographic()) 0 else 0.5));
        return .{ .origin = near, .dir = far.sub(near).normalize() };
    }

    /// Project a world point to `viewport` pixels; null when behind the camera.
    pub fn worldToScreen(self: Camera, viewport: Rect, p: Vec3) ?[2]f32 {
        const c = self.viewProj(viewport.aspect(), false).transformPoint(p);
        if (c[3] <= 0) return null;
        return .{
            viewport.x + (c[0] / c[3] * 0.5 + 0.5) * viewport.width,
            viewport.y + (0.5 - c[1] / c[3] * 0.5) * viewport.height,
        };
    }
};

/// Orbit rig: yaw/pitch/distance around a target. `camera()` gives a `Camera`.
pub const Orbit = struct {
    target: Vec3 = .zero,
    /// Radians around +Y; 0 looks from +Z toward the target.
    yaw: f32 = 0.6,
    /// Radians above the horizon.
    pitch: f32 = 0.7,
    distance: f32 = 8,
    fov_y: f32 = std.math.pi / 5.0,
    min_pitch: f32 = 0.05,
    max_pitch: f32 = std.math.pi / 2.0 - 0.01,
    min_distance: f32 = 0.5,
    max_distance: f32 = 200,

    pub fn camera(self: Orbit) Camera {
        const dir = Vec3.new(@cos(self.pitch) * @sin(self.yaw), @sin(self.pitch), @cos(self.pitch) * @cos(self.yaw));
        return .{
            .eye = self.target.add(dir.scale(self.distance)),
            .target = self.target,
            .projection = .{ .perspective = .{ .fov_y = self.fov_y, .near = @max(self.distance * 0.01, 0.01) } },
        };
    }

    /// Drag by pixel deltas (`sensitivity` radians per pixel).
    pub fn rotate(self: *Orbit, dx: f32, dy: f32, sensitivity: f32) void {
        self.yaw -= dx * sensitivity;
        self.pitch = std.math.clamp(self.pitch + dy * sensitivity, self.min_pitch, self.max_pitch);
    }

    /// Multiplicative zoom (`factor` < 1 zooms in).
    pub fn zoom(self: *Orbit, factor: f32) void {
        self.distance = std.math.clamp(self.distance * factor, self.min_distance, self.max_distance);
    }
};

// ---------------------------------------------------------------------------
// Lighting, post
// ---------------------------------------------------------------------------

pub const Shadow = struct {
    enabled: bool = true,
    /// Shadow map resolution (square).
    map_size: u32 = 2048,
    /// PCF filter radius in shadow-map texels (0 = hard 2x2 bilinear).
    softness: f32 = 1.5,
    /// Depth bias in light clip space.
    bias: f32 = 0.0015,
    /// Offset along the surface normal, in shadow-map texels.
    normal_bias: f32 = 1.5,
    /// World region the map covers; null fits all shadow casters and receivers.
    bounds: ?Aabb = null,
};

pub const Sun = struct {
    /// Direction the light travels (from the light toward the scene).
    direction: Vec3 = .new(-0.4, -1, -0.3),
    /// Linear RGB.
    color: [3]f32 = .{ 1, 0.96, 0.9 },
    intensity: f32 = 3,
    shadow: Shadow = .{},

    /// From the light's position in the sky (degrees; azimuth 0 = +Z, 90 = +X).
    pub fn fromAngles(azimuth_deg: f32, elevation_deg: f32) Vec3 {
        return Vec3.fromAzimuthElevation(azimuth_deg, elevation_deg).neg();
    }
};

/// Sky/ground ambient blended by the normal's Y.
pub const Hemisphere = struct {
    sky: [3]f32 = .{ 0.9, 0.95, 1.0 },
    ground: [3]f32 = .{ 0.35, 0.3, 0.25 },
    intensity: f32 = 0.6,
};

/// Diffuse irradiance as 9 spherical-harmonic coefficients (linear RGB, the
/// usual Ramamoorthi–Hanrahan order: L00, L1-1, L10, L11, L2-2, L2-1, L20, L21, L22).
/// Added on top of the hemisphere fill.
pub const Environment = struct {
    sh: [9][3]f32,
    intensity: f32 = 1,

    /// Uniform radiance from every direction (e.g. three.js `environment`
    /// intensity of a neutral room: `uniform(.{ 0.4, 0.4, 0.4 })`).
    pub fn uniform(radiance: [3]f32) Environment {
        return gradient(radiance, radiance);
    }

    /// Radiance varying linearly with the direction's Y: `sky` straight up,
    /// `ground` straight down. Exact in SH9 (bands 0 and 1).
    pub fn gradient(sky: [3]f32, ground: [3]f32) Environment {
        var sh: [9][3]f32 = @splat(.{ 0, 0, 0 });
        for (0..3) |k| {
            const a = (sky[k] + ground[k]) / 2;
            const b = (sky[k] - ground[k]) / 2;
            sh[0][k] = a * 2 * @sqrt(std.math.pi); // ∫ a·Y00
            sh[1][k] = b * 0.488603 * 4 * std.math.pi / 3; // ∫ b·y·Y1-1 (Y1-1 = 0.488603·y)
        }
        return .{ .sh = sh };
    }

    /// Irradiance for unit normal `n` (the shader's formula, for tests and CPU use).
    pub fn irradiance(self: Environment, n: Vec3) [3]f32 {
        const c1 = 0.429043;
        const c2 = 0.511664;
        const c3 = 0.743125;
        const c4 = 0.886227;
        const c5 = 0.247708;
        var e: [3]f32 = undefined;
        for (0..3) |k| {
            const L = struct {
                fn at(env: Environment, i: usize, ch: usize) f32 {
                    return env.sh[i][ch];
                }
            }.at;
            e[k] = c1 * L(self, 8, k) * (n.x * n.x - n.y * n.y) + c3 * L(self, 6, k) * n.z * n.z + c4 * L(self, 0, k) - c5 * L(self, 6, k) +
                2 * c1 * (L(self, 4, k) * n.x * n.y + L(self, 7, k) * n.x * n.z + L(self, 5, k) * n.y * n.z) +
                2 * c2 * (L(self, 3, k) * n.x + L(self, 1, k) * n.y + L(self, 2, k) * n.z);
            e[k] = @max(e[k], 0) * self.intensity;
        }
        return e;
    }
};

/// Exponential-squared fog: `f = 1 - exp(-(density * distance)^2)`.
pub const Fog = struct {
    color: [3]f32,
    density: f32,
};

pub const Tonemap = enum(u32) { none = 0, neutral = 1, aces = 2 };

pub const Ssao = struct {
    /// World-space sampling radius.
    radius: f32 = 0.1,
    intensity: f32 = 1,
    /// Samples per pixel (4..32).
    samples: u32 = 12,
};

pub const TiltShift = struct {
    /// Center of the sharp band, 0 = top of the viewport, 1 = bottom.
    focus: f32 = 0.45,
    /// Height of the sharp band (fraction of the viewport).
    range: f32 = 0.3,
    /// Blur strength: gaussian sigma in device pixels at full blur.
    blur: f32 = 3,
};

pub const Post = struct {
    exposure: f32 = 1,
    tonemap: Tonemap = .neutral,
    saturation: f32 = 1,
    /// Darkening toward the corners (0 = off).
    vignette: f32 = 0,
    /// 1 or 4 (clamped to what the device supports).
    msaa: u8 = 4,
    /// Post-tonemap FXAA (useful with `msaa = 1`).
    fxaa: bool = false,
    ssao: ?Ssao = null,
    tilt_shift: ?TiltShift = null,
};

/// Rendering-cost presets: `low` (no shadows, FXAA), `medium` (shadows + 4x
/// MSAA), `high` (+ SSAO + tilt-shift depth of field).
pub const Tier = enum { low, medium, high };

// ---------------------------------------------------------------------------
// Materials and draws
// ---------------------------------------------------------------------------

pub const Shading = enum(u32) {
    /// glTF metallic-roughness (GGX), lit by the sun, ambient and SH9.
    pbr = 0,
    /// N-band cel ramp; pair with `outline`.
    toon = 1,
    /// Unlit: base color only.
    flat = 2,
};

pub const AlphaMode = enum(u32) { @"opaque" = 0, mask = 1, blend = 2 };

pub const Outline = struct {
    /// Linear RGBA.
    color: [4]f32 = .{ 0.02, 0.01, 0.03, 1 },
    width: f32 = 0.006,
    units: enum { world, pixels } = .world,
};

pub const Toon = struct {
    bands: u32 = 3,
    /// Darkest band brightness (the ramp spans `min`..1).
    min: f32 = 0.35,
    /// Smoothing of the band edges (0 = hard).
    softness: f32 = 0.02,
};

/// World-space value noise that modulates the base color: `color *= 1 + amount * (n - 0.5) * 2`.
pub const Detail = struct {
    scale: f32 = 0,
    amount: f32 = 0,
};

pub const Material = struct {
    shading: Shading = .pbr,
    /// Linear RGBA.
    base_color: [4]f32 = .{ 1, 1, 1, 1 },
    /// Linear RGB, added after lighting.
    emissive: [3]f32 = .{ 0, 0, 0 },
    metallic: f32 = 0,
    roughness: f32 = 0.8,
    base_color_texture: TextureId = .none,
    /// Palette texture sampled at (vertex id, instance `palette_row`); multiplies the base color.
    palette: TextureId = .none,
    /// Multiply by the mesh's per-vertex colors when it has them.
    vertex_colors: bool = true,
    detail: Detail = .{},
    toon: Toon = .{},
    outline: ?Outline = null,
    alpha_mode: AlphaMode = .@"opaque",
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
    depth_write: bool = true,
    /// Pulls the surface toward the camera (decals, highlights): units of depth slope.
    depth_bias: f32 = 0,
    cast_shadows: bool = true,
    receive_shadows: bool = true,
    fog: bool = true,
};

/// Per-instance data (96 bytes, uploaded as-is).
pub const Instance = extern struct {
    model: Mat4 = Mat4.identity,
    /// Linear RGBA, multiplies the material color (alpha multiplies opacity).
    tint: [4]f32 = .{ 1, 1, 1, 1 },
    /// Returned by `pick`; 0 = not pickable.
    pick_id: u32 = 0,
    /// Row of the material's palette texture.
    palette_row: u32 = 0,
    /// Reserved for the app (passed through to shaders unused).
    user: u32 = 0,
    _pad: u32 = 0,
};

pub const Highlight = struct {
    /// Vertices whose id attribute equals this get `color` added (emissive, alpha = strength).
    id: u32,
    color: [4]f32 = .{ 1, 0.95, 0.6, 0.5 },
};

pub const DrawOpts = struct {
    material: Material = .{},
    /// Index sub-range (a glTF primitive, a geometry group); count 0 = to the end.
    first_index: u32 = 0,
    index_count: u32 = 0,
    highlight: ?Highlight = null,
    // `draw` only (instanced draws carry these per instance):
    tint: [4]f32 = .{ 1, 1, 1, 1 },
    pick_id: u32 = 0,
    palette_row: u32 = 0,
};

pub const Draw = struct {
    mesh: MeshId,
    opts: DrawOpts,
    first_instance: u32,
    instance_count: u32,
};

// ---------------------------------------------------------------------------
// Scene
// ---------------------------------------------------------------------------

pub const Scene3D = struct {
    gpa: Allocator,
    gfx: *Gfx3D,
    camera: Camera = .{},
    sun: Sun = .{},
    hemisphere: Hemisphere = .{},
    environment: ?Environment = null,
    fog: ?Fog = null,
    post: Post = .{},
    /// Linear straight-alpha background; alpha 0 shows the UI beneath.
    clear: [4]f32 = .{ 0, 0, 0, 0 },
    draws: std.ArrayList(Draw) = .empty,
    instances: std.ArrayList(Instance) = .empty,
    /// Window-space bounds (logical pixels) where the scene was last painted;
    /// set by `Window.paintViewport3D`, used by `pickAt`.
    last_viewport: ?Rect = null,
    /// Renderer statistics from the last rendered frame (informational).
    stats: Stats = .{},

    pub const Stats = struct {
        draws: u32 = 0,
        instances: u32 = 0,
        triangles: u64 = 0,
        shadow_draws: u32 = 0,
        /// True when the last composite reused the cached image.
        cached: bool = false,
        /// GPU time of the 3D passes in milliseconds (0 when unavailable).
        gpu_ms: f32 = 0,
        gpu_shadow_ms: f32 = 0,
        gpu_main_ms: f32 = 0,
        gpu_post_ms: f32 = 0,
    };

    pub fn init(gpa: Allocator, gfx: *Gfx3D) Scene3D {
        return .{ .gpa = gpa, .gfx = gfx };
    }

    pub fn deinit(self: *Scene3D) void {
        self.draws.deinit(self.gpa);
        self.instances.deinit(self.gpa);
        self.* = undefined;
    }

    /// Drop the draw list (keeps camera, lights and settings).
    pub fn clearDraws(self: *Scene3D) void {
        self.draws.clearRetainingCapacity();
        self.instances.clearRetainingCapacity();
    }

    /// Draw `mesh` once with `transform`.
    pub fn draw(self: *Scene3D, mesh: MeshId, transform: Mat4, opts: DrawOpts) Allocator.Error!void {
        try self.instances.append(self.gpa, .{
            .model = transform,
            .tint = opts.tint,
            .pick_id = opts.pick_id,
            .palette_row = opts.palette_row,
        });
        try self.draws.append(self.gpa, .{
            .mesh = mesh,
            .opts = opts,
            .first_instance = @intCast(self.instances.items.len - 1),
            .instance_count = 1,
        });
    }

    /// One instanced draw: every instance shares `opts` (material, range).
    pub fn drawInstanced(self: *Scene3D, mesh: MeshId, instances: []const Instance, opts: DrawOpts) Allocator.Error!void {
        if (instances.len == 0) return;
        const first: u32 = @intCast(self.instances.items.len);
        try self.instances.appendSlice(self.gpa, instances);
        try self.draws.append(self.gpa, .{ .mesh = mesh, .opts = opts, .first_instance = first, .instance_count = @intCast(instances.len) });
    }

    /// Apply a cost preset to shadows and post (keeps colors and look settings).
    pub fn setTier(self: *Scene3D, tier: Tier) void {
        switch (tier) {
            .low => {
                self.sun.shadow.enabled = false;
                self.post.msaa = 1;
                self.post.fxaa = true;
            },
            .medium => {
                self.sun.shadow.enabled = true;
                self.post.msaa = 4;
                self.post.fxaa = false;
            },
            .high => {
                self.sun.shadow.enabled = true;
                self.post.msaa = 4;
                self.post.fxaa = false;
                if (self.post.ssao == null) self.post.ssao = .{};
                if (self.post.tilt_shift == null) self.post.tilt_shift = .{};
            },
        }
        if (tier != .high) {
            self.post.ssao = null;
            self.post.tilt_shift = null;
        }
    }

    /// World-space bounds of every draw (all instances).
    pub fn bounds(self: *const Scene3D, filter: enum { all, casters, receivers }) Aabb {
        var b: Aabb = .empty;
        for (self.draws.items) |d| {
            switch (filter) {
                .all => {},
                .casters => if (!d.opts.material.cast_shadows) continue,
                .receivers => if (!d.opts.material.receive_shadows) continue,
            }
            const m = self.gfx.mesh(d.mesh) orelse continue;
            for (self.instances.items[d.first_instance..][0..d.instance_count]) |inst| b = b.merge(m.bounds.transform(inst.model));
        }
        return b;
    }

    // -- picking ------------------------------------------------------------

    pub const Hit = struct {
        pick_id: u32,
        /// The mesh's id attribute at the hit (nearest vertex of the hit
        /// triangle); null when the mesh has no ids or no CPU copy.
        vertex_id: ?u32,
        draw_index: u32,
        /// Index within the draw's instances.
        instance_index: u32,
        /// Triangle index within the mesh; null for a bounds-only hit.
        triangle: ?u32,
        distance: f32,
        position: Vec3,
        /// Geometric normal (world space), facing the ray.
        normal: Vec3,
    };

    /// Ray through `point` in a viewport of `viewport` (both in the same pixel space).
    pub fn rayAt(self: *const Scene3D, viewport: Rect, point: [2]f32) Ray {
        return self.camera.ray(viewport, point);
    }

    /// Pick at a window position (logical pixels) using the bounds this scene
    /// was last painted at. Null before the first paint or on a miss.
    pub fn pickAt(self: *const Scene3D, window_point: [2]f32) ?Hit {
        const vp = self.last_viewport orelse return null;
        if (window_point[0] < vp.x or window_point[1] < vp.y or window_point[0] > vp.x + vp.width or window_point[1] > vp.y + vp.height) return null;
        return self.pickRay(self.rayAt(vp, window_point));
    }

    pub fn pick(self: *const Scene3D, viewport: Rect, point: [2]f32) ?Hit {
        return self.pickRay(self.rayAt(viewport, point));
    }

    /// Nearest hit among instances with a nonzero `pick_id`. Meshes created
    /// with `keep_cpu` are tested per triangle; others by their bounds.
    pub fn pickRay(self: *const Scene3D, world_ray: Ray) ?Hit {
        var best: ?Hit = null;
        var best_t: f32 = std.math.inf(f32);
        for (self.draws.items, 0..) |d, di| {
            const m = self.gfx.mesh(d.mesh) orelse continue;
            const insts = self.instances.items[d.first_instance..][0..d.instance_count];
            for (insts, 0..) |inst, ii| {
                if (inst.pick_id == 0) continue;
                const inv = inst.model.inverse() orelse continue;
                // Object-space ray; its t is comparable to world t (dir not renormalized).
                const r = world_ray.transform(inv);
                const entry = r.intersectAabb(m.bounds, best_t) orelse continue;
                if (if (m.keep_cpu) m.cpu else null) |cpu| {
                    const first = d.opts.first_index;
                    const count = if (d.opts.index_count == 0) m.index_count - @min(first, m.index_count) else d.opts.index_count;
                    var tri: u32 = first / 3;
                    while (tri * 3 + 2 < first + count) : (tri += 1) {
                        const ia = cpu.indices[tri * 3];
                        const ib = cpu.indices[tri * 3 + 1];
                        const ic = cpu.indices[tri * 3 + 2];
                        const a = Vec3.fromArray(cpu.positions[ia]);
                        const b = Vec3.fromArray(cpu.positions[ib]);
                        const c = Vec3.fromArray(cpu.positions[ic]);
                        const h = r.intersectTriangle(a, b, c) orelse continue;
                        if (h.t >= best_t) continue;
                        best_t = h.t;
                        const w = 1 - h.u - h.v;
                        const nearest = if (w >= h.u and w >= h.v) ia else if (h.u >= h.v) ib else ic;
                        var n = inv.transpose().transformDir(b.sub(a).cross(c.sub(a))).normalize();
                        if (n.dot(world_ray.dir) > 0) n = n.neg();
                        best = .{
                            .pick_id = inst.pick_id,
                            .vertex_id = if (m.id_format != .none) cpu.id(m.id_format, nearest) else null,
                            .draw_index = @intCast(di),
                            .instance_index = @intCast(ii),
                            .triangle = tri,
                            .distance = h.t,
                            .position = world_ray.at(h.t),
                            .normal = n,
                        };
                    }
                } else if (entry < best_t) {
                    best_t = entry;
                    best = .{
                        .pick_id = inst.pick_id,
                        .vertex_id = null,
                        .draw_index = @intCast(di),
                        .instance_index = @intCast(ii),
                        .triangle = null,
                        .distance = entry,
                        .position = world_ray.at(entry),
                        .normal = world_ray.dir.neg(),
                    };
                }
            }
        }
        return best;
    }
};

const testing = std.testing;
const shapes = @import("shapes.zig");

test "camera ray goes through the target at the viewport center" {
    const cam: Camera = .{ .eye = .new(0, 5, 5), .target = .zero };
    const r = cam.ray(.{ .x = 100, .y = 50, .width = 400, .height = 200 }, .{ 300, 150 });
    const p = r.intersectGround(0).?;
    try testing.expectApproxEqAbs(@as(f32, 0), p.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 0), p.z, 1e-4);
    // Right of center hits +X; above center hits further away (-Z).
    try testing.expect(cam.ray(.{ .width = 400, .height = 200 }, .{ 300, 100 }).intersectGround(0).?.x > 0.1);
    try testing.expect(cam.ray(.{ .width = 400, .height = 200 }, .{ 200, 60 }).intersectGround(0).?.z < -0.1);
    const s = cam.worldToScreen(.{ .x = 100, .y = 50, .width = 400, .height = 200 }, .zero).?;
    try testing.expectApproxEqAbs(@as(f32, 300), s[0], 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 150), s[1], 1e-3);
}

test "orthographic camera rays are parallel" {
    const cam: Camera = .{ .eye = .new(0, 10, 0.001), .target = .zero, .projection = .{ .orthographic = .{ .height = 4 } } };
    const vp: Rect = .{ .width = 100, .height = 100 };
    const a = cam.ray(vp, .{ 0, 50 });
    const b = cam.ray(vp, .{ 100, 50 });
    try testing.expectApproxEqAbs(a.dir.y, b.dir.y, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -2), a.intersectGround(0).?.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 2), b.intersectGround(0).?.x, 1e-3);
}

test "pick returns the nearest instance and the vertex id" {
    var g = Gfx3D.init(testing.allocator);
    defer g.deinit();
    var box = try shapes.box(testing.allocator, .{ 1, 1, 1 });
    defer box.deinit(testing.allocator);
    // Ids: one per face (4 vertices each).
    var ids: [24]u16 = undefined;
    for (&ids, 0..) |*v, i| v.* = @intCast(100 + i / 4);
    var desc = box.desc();
    desc.ids = .{ .u16 = &ids };
    desc.keep_cpu = true;
    const mesh = try g.createMesh(desc);
    const bounds_only = try g.createMesh(box.desc());

    var s = Scene3D.init(testing.allocator, &g);
    defer s.deinit();
    s.camera = .{ .eye = .new(0, 10, 0), .target = .zero, .up = .new(0, 0, -1) };
    try s.drawInstanced(mesh, &.{
        .{ .model = Mat4.translation(.new(0, 0, 0)), .pick_id = 1 },
        .{ .model = Mat4.translation(.new(0, 3, 0)), .pick_id = 2 },
        .{ .model = Mat4.translation(.new(0, 6, 0)), .pick_id = 0 }, // not pickable
    }, .{});
    const down: Ray = .{ .origin = .new(0.1, 20, 0.2), .dir = .new(0, -1, 0) };
    const hit = s.pickRay(down).?;
    try testing.expectEqual(@as(u32, 2), hit.pick_id);
    try testing.expectEqual(@as(u32, 1), hit.instance_index);
    try testing.expectApproxEqAbs(@as(f32, 3.5), hit.position.y, 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1), hit.normal.y, 1e-5);
    // Top face (+Y) is face index 2 in `shapes.box`.
    try testing.expectEqual(@as(?u32, 102), hit.vertex_id);

    const side: Ray = .{ .origin = .new(-10, 0, 0), .dir = .new(1, 0, 0) };
    try testing.expectEqual(@as(u32, 1), s.pickRay(side).?.pick_id);
    try testing.expect(s.pickRay(.{ .origin = .new(10, 10, 10), .dir = .new(0, 1, 0) }) == null);

    s.clearDraws();
    try s.draw(bounds_only, Mat4.translation(.new(5, 0, 0)), .{ .pick_id = 9 });
    const h2 = s.pickRay(.{ .origin = .new(5, 10, 0), .dir = .new(0, -1, 0) }).?;
    try testing.expectEqual(@as(u32, 9), h2.pick_id);
    try testing.expect(h2.vertex_id == null and h2.triangle == null);
}

test "pick respects index ranges and non-uniform scale" {
    var g = Gfx3D.init(testing.allocator);
    defer g.deinit();
    var plane = try shapes.plane(testing.allocator, 2, 2, 1);
    defer plane.deinit(testing.allocator);
    var d = plane.desc();
    d.keep_cpu = true;
    const mesh = try g.createMesh(d);
    var s = Scene3D.init(testing.allocator, &g);
    defer s.deinit();
    try s.draw(mesh, Mat4.scaling(.new(4, 1, 1)), .{ .pick_id = 3, .first_index = 0, .index_count = 3 });
    // The first triangle covers one half of the quad only.
    var hits: u32 = 0;
    for ([_]f32{ -3, 3 }) |x| {
        if (s.pickRay(.{ .origin = .new(x, 1, if (x < 0) -0.6 else 0.6), .dir = .new(0, -1, 0) }) != null) hits += 1;
    }
    try testing.expectEqual(@as(u32, 1), hits);
}

test "SH9 gradient environment is exact irradiance" {
    const env = Environment.gradient(.{ 1, 1, 1 }, .{ 0.2, 0.2, 0.2 });
    // E(n) = pi*a + (2pi/3)*b*n.y for L = a + b*y.
    const up = env.irradiance(.up);
    try testing.expectApproxEqAbs(@as(f32, std.math.pi * 0.6 + 2 * std.math.pi / 3.0 * 0.4), up[0], 1e-4);
    const side = env.irradiance(.new(1, 0, 0));
    try testing.expectApproxEqAbs(@as(f32, std.math.pi * 0.6), side[1], 1e-4);
    const u = Environment.uniform(.{ 0.4, 0.4, 0.4 });
    try testing.expectApproxEqAbs(@as(f32, std.math.pi * 0.4), u.irradiance(.new(0, 0, -1))[2], 1e-4);
}

test "tier presets" {
    var g = Gfx3D.init(testing.allocator);
    defer g.deinit();
    var s = Scene3D.init(testing.allocator, &g);
    defer s.deinit();
    s.setTier(.high);
    try testing.expect(s.post.ssao != null and s.sun.shadow.enabled);
    s.setTier(.low);
    try testing.expect(s.post.ssao == null and !s.sun.shadow.enabled and s.post.fxaa and s.post.msaa == 1);
}
