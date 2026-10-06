//! Backend-agnostic frame planning: turns a `Scene3D` into what a backend
//! encodes for one viewport. Culls instances (camera frustum for the main
//! pass, light frustum for the shadow pass), sorts draws, fits the shadow
//! camera, packs `FrameData`/`DrawData`, and hashes everything so unchanged
//! frames can reuse the cached image.

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("math.zig");
const gpu = @import("gpu.zig");
const scene_mod = @import("scene3d.zig");
const gfx_mod = @import("gfx.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Aabb = math.Aabb;
const Frustum = math.Frustum;
const Scene3D = scene_mod.Scene3D;
const Instance = scene_mod.Instance;
const Material = scene_mod.Material;

pub const Cull = enum(u8) { back = 0, none = 1, front = 2 };

/// One encoded draw. `extern` so the plan hash can cover it bytewise.
pub const Draw = extern struct {
    mesh_slot: u32,
    first_index: u32,
    index_count: u32,
    /// Offset into `Plan.instances`.
    first_instance: u32,
    instance_count: u32,
    /// Gfx3D texture slots + 1 (0 = none).
    base_texture: u32,
    palette: u32,
    cull: Cull,
    depth_write: bool,
    _pad: [2]u8 = .{ 0, 0 },
    /// Constant depth bias (reverse-Z: positive pulls toward the camera), slope-scaled.
    depth_bias: f32,
    /// Blend draws: view distance for back-to-front sorting.
    sort_depth: f32,
    data: gpu.DrawData,
};

pub const Plan = struct {
    gpa: Allocator,
    frame: gpu.FrameData = undefined,
    instances: std.ArrayList(Instance) = .empty,
    shadow: std.ArrayList(Draw) = .empty,
    @"opaque": std.ArrayList(Draw) = .empty,
    blend: std.ArrayList(Draw) = .empty,
    outlines: std.ArrayList(Draw) = .empty,
    width: u32 = 0,
    height: u32 = 0,
    samples: u32 = 1,
    shadow_size: u32 = 0,
    post: scene_mod.Post = .{},
    clear: [4]f32 = .{ 0, 0, 0, 0 },
    hash: u64 = 0,
    /// Covers only what the shadow map depends on (light camera, casters and
    /// their instances), so a moving camera can reuse last frame's map.
    shadow_hash: u64 = 0,
    triangles: u64 = 0,

    pub fn init(gpa: Allocator) Plan {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Plan) void {
        self.instances.deinit(self.gpa);
        self.shadow.deinit(self.gpa);
        self.@"opaque".deinit(self.gpa);
        self.blend.deinit(self.gpa);
        self.outlines.deinit(self.gpa);
        self.* = undefined;
    }

    fn reset(self: *Plan) void {
        self.instances.clearRetainingCapacity();
        self.shadow.clearRetainingCapacity();
        self.@"opaque".clearRetainingCapacity();
        self.blend.clearRetainingCapacity();
        self.outlines.clearRetainingCapacity();
        self.triangles = 0;
    }

    pub fn shadowsEnabled(self: *const Plan) bool {
        return self.shadow_size > 0;
    }
    pub fn ssao(self: *const Plan) ?scene_mod.Ssao {
        return self.post.ssao;
    }
    pub fn tiltShift(self: *const Plan) ?scene_mod.TiltShift {
        return self.post.tilt_shift;
    }
};

pub const Options = struct {
    /// Largest MSAA sample count the device supports for color+depth (1 or 4).
    max_samples: u32 = 4,
    /// Largest 2D image size (caps the shadow map).
    max_texture_size: u32 = 8192,
};

/// Fill `plan` for drawing `scene` into a `width` x `height` target.
pub fn build(plan: *Plan, scene: *const Scene3D, width: u32, height: u32, opts: Options) Allocator.Error!void {
    plan.reset();
    const scale = std.math.clamp(scene.post.resolution_scale, 0.25, 1);
    plan.width = @max(@as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(width)) * scale))), 1);
    plan.height = @max(@as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(height)) * scale))), 1);
    plan.post = scene.post;
    plan.post.resolution_scale = scale;
    // Pixel-sized effects stay the same size on screen.
    if (plan.post.tilt_shift) |*t| t.blur *= scale;
    plan.samples = if (scene.post.msaa >= 4 and opts.max_samples >= 4) 4 else 1;
    plan.clear = scene.clear;
    // Tilt-shift on an orthographic top-down view reads as a smudge; skip it.
    if (scene.camera.isOrthographic()) plan.post.tilt_shift = null;

    const aspect = @as(f32, @floatFromInt(plan.width)) / @as(f32, @floatFromInt(plan.height));
    const view = scene.camera.view();
    const proj = scene.camera.proj(aspect, true);
    const view_proj = proj.mul(view);
    const frustum = Frustum.fromMatrix(view_proj);

    // ---- shadow camera ------------------------------------------------------
    const sun = scene.sun;
    const to_light = sun.direction.neg().normalize();
    var light_vp = Mat4.identity;
    var light_frustum: ?Frustum = null;
    var texel_world: f32 = 0;
    plan.shadow_size = 0;
    if (sun.shadow.enabled and sun.intensity > 0) {
        const region = sun.shadow.bounds orelse scene.bounds(.all);
        if (!region.isEmpty()) {
            const size = std.math.clamp(sun.shadow.map_size, 256, opts.max_texture_size);
            const fit = fitShadow(region, to_light, size);
            light_vp = fit.view_proj;
            texel_world = fit.texel_world;
            light_frustum = Frustum.fromMatrix(fit.view_proj);
            plan.shadow_size = size;
        }
    }

    // ---- frame constants ----------------------------------------------------
    const sc = sun.color;
    const hemi = scene.hemisphere;
    var f: gpu.FrameData = .{
        .view_proj = view_proj,
        .view = view,
        .proj = proj,
        .inv_proj = proj.inverse() orelse Mat4.identity,
        .light_view_proj = light_vp,
        .camera_pos = .{ scene.camera.eye.x, scene.camera.eye.y, scene.camera.eye.z, if (scene.camera.isOrthographic()) 1 else 0 },
        .sun_dir = .{ to_light.x, to_light.y, to_light.z, if (plan.shadow_size > 0) 1 else 0 },
        .sun_color = .{ sc[0] * sun.intensity, sc[1] * sun.intensity, sc[2] * sun.intensity, 0 },
        .sky = .{ hemi.sky[0] * hemi.intensity, hemi.sky[1] * hemi.intensity, hemi.sky[2] * hemi.intensity, 0 },
        .ground = .{ hemi.ground[0] * hemi.intensity, hemi.ground[1] * hemi.intensity, hemi.ground[2] * hemi.intensity, 0 },
        .fog = if (scene.fog) |fg| .{ fg.color[0], fg.color[1], fg.color[2], fg.density } else .{ 0, 0, 0, 0 },
        .shadow = .{
            sun.shadow.bias,
            sun.shadow.normal_bias * texel_world,
            if (plan.shadow_size > 0) 1 / @as(f32, @floatFromInt(plan.shadow_size)) else 0,
            @max(sun.shadow.softness, 0),
        },
        .viewport = .{ @floatFromInt(plan.width), @floatFromInt(plan.height), 1 / @as(f32, @floatFromInt(plan.width)), 1 / @as(f32, @floatFromInt(plan.height)) },
        .env = .{ 0, 0, 0, 0 },
        .sh = @splat(.{ 0, 0, 0, 0 }),
    };
    if (scene.environment) |env| {
        f.env[0] = env.intensity;
        for (env.sh, 0..) |c, i| f.sh[i] = .{ c[0], c[1], c[2], 0 };
    }
    plan.frame = f;

    // ---- draws --------------------------------------------------------------
    // Projected size for LOD selection: diameter * pixel_scale (/ distance).
    const ortho = scene.camera.isOrthographic();
    const pixel_scale: f32 = switch (scene.camera.projection) {
        .perspective => |p| @as(f32, @floatFromInt(plan.height)) / (2 * @tan(p.fov_y / 2)),
        .orthographic => |o| @as(f32, @floatFromInt(plan.height)) / @max(o.height, 1e-6),
    };
    const gfx = scene.gfx;
    for (scene.draws.items) |d| {
        const mesh = gfx.mesh(d.mesh) orelse continue;
        const mat = d.opts.material;
        const insts = scene.instances.items[d.first_instance..][0..d.instance_count];

        // Level 0 is the mesh itself; explicit index ranges never switch level.
        var levels: [1 + gfx_mod.max_lods]gfx_mod.MeshId = undefined;
        var thresholds: [gfx_mod.max_lods]f32 = undefined;
        levels[0] = d.mesh;
        var level_count: usize = 1;
        if (d.opts.first_index == 0 and d.opts.index_count == 0) for (mesh.lodSlice()) |l| {
            if (gfx.mesh(l.mesh) == null) continue;
            thresholds[level_count - 1] = l.max_pixels;
            levels[level_count] = l.mesh;
            level_count += 1;
        };
        const thr = thresholds[0 .. level_count - 1];

        for (levels[0..level_count], 0..) |level_id, level| {
            const lm = gfx.mesh(level_id).?;
            const slot = level_id.slot().?;
            const first = if (level == 0) @min(d.opts.first_index, lm.index_count) / 3 * 3 else 0;
            const count = if (level != 0 or d.opts.index_count == 0) lm.index_count - first else @min(d.opts.index_count, lm.index_count - first) / 3 * 3;
            if (count == 0) continue;
            const data = packDraw(mat, d.opts.highlight, lm, gfx);
            const base: Draw = .{
                .mesh_slot = slot,
                .first_index = first,
                .index_count = count,
                .first_instance = 0,
                .instance_count = 0,
                .base_texture = texSlot(gfx, mat.base_color_texture),
                .palette = texSlot(gfx, mat.palette),
                .cull = if (mat.double_sided) .none else .back,
                .depth_write = mat.depth_write and mat.alpha_mode != .blend,
                .depth_bias = mat.depth_bias,
                .sort_depth = 0,
                .data = data,
            };

            // Main pass: camera-visible instances.
            const main_first: u32 = @intCast(plan.instances.items.len);
            var center = Vec3.zero;
            for (insts) |inst| {
                if (inst.tint[3] <= 0 and mat.alpha_mode == .blend) continue;
                const wb = mesh.bounds.transform(inst.model);
                if (!frustum.intersectsAabb(wb)) continue;
                if (thr.len > 0) {
                    const diameter = wb.radius() * 2 * pixel_scale;
                    const px = if (ortho) diameter else diameter / @max(wb.center().sub(scene.camera.eye).length(), 1e-4);
                    if (lodLevel(thr, px) != level) continue;
                }
                try plan.instances.append(plan.gpa, inst);
                center = center.add(wb.center());
            }
            const visible: u32 = @as(u32, @intCast(plan.instances.items.len)) - main_first;
            if (visible > 0) {
                var md = base;
                md.first_instance = main_first;
                md.instance_count = visible;
                plan.triangles += @as(u64, count / 3) * visible;
                if (mat.alpha_mode == .blend) {
                    md.sort_depth = center.scale(1 / @as(f32, @floatFromInt(visible))).sub(scene.camera.eye).length();
                    try plan.blend.append(plan.gpa, md);
                } else {
                    try plan.@"opaque".append(plan.gpa, md);
                }
                if (mat.outline) |o| if (o.width > 0 and mat.alpha_mode != .blend) {
                    var od = md;
                    od.cull = .front;
                    od.depth_bias = 0;
                    od.data.outline_color = o.color;
                    od.data.outline = .{ if (o.units == .pixels) o.width * scale else o.width, 0, 0, 0 };
                    if (o.units == .pixels) od.data.flags[0] |= gpu.DrawFlags.outline_pixels;
                    try plan.outlines.append(plan.gpa, od);
                };
            }

            // Shadow pass: instances inside the light frustum. Levels follow the
            // size in shadow-map texels, so the choice (and a cached map) does
            // not depend on the camera.
            if (light_frustum) |lf| if (mat.cast_shadows and mat.alpha_mode != .blend) {
                const sh_first: u32 = @intCast(plan.instances.items.len);
                for (insts) |inst| {
                    const wb = mesh.bounds.transform(inst.model);
                    if (!lf.intersectsAabb(wb)) continue;
                    if (thr.len > 0 and lodLevel(thr, wb.radius() * 2 / @max(texel_world, 1e-9)) != level) continue;
                    try plan.instances.append(plan.gpa, inst);
                }
                const n: u32 = @as(u32, @intCast(plan.instances.items.len)) - sh_first;
                if (n > 0) {
                    var sd = base;
                    sd.first_instance = sh_first;
                    sd.instance_count = n;
                    // Shadow maps render both faces (thin tiles, open meshes).
                    sd.cull = .none;
                    sd.depth_write = true;
                    sd.depth_bias = 0;
                    try plan.shadow.append(plan.gpa, sd);
                }
            };
        }
    }

    // Opaque: group by state, then mesh (fewer rebinds). Blend: far to near.
    std.mem.sort(Draw, plan.@"opaque".items, {}, struct {
        fn lt(_: void, a: Draw, b: Draw) bool {
            const ka = (@as(u64, @intFromEnum(a.cull)) << 60) | (@as(u64, a.base_texture) << 40) | (@as(u64, a.palette) << 20) | a.mesh_slot;
            const kb = (@as(u64, @intFromEnum(b.cull)) << 60) | (@as(u64, b.base_texture) << 40) | (@as(u64, b.palette) << 20) | b.mesh_slot;
            return ka < kb;
        }
    }.lt);
    std.mem.sort(Draw, plan.blend.items, {}, struct {
        fn lt(_: void, a: Draw, b: Draw) bool {
            return a.sort_depth > b.sort_depth;
        }
    }.lt);

    plan.hash = hashPlan(plan, gfx);
    plan.shadow_hash = hashShadow(plan, gfx);
}

/// LOD level for a projected size (`thresholds` descending).
fn lodLevel(thresholds: []const f32, pixels: f32) usize {
    var level: usize = 0;
    for (thresholds) |t| {
        if (pixels > t) break;
        level += 1;
    }
    return level;
}

fn texSlot(gfx: *const gfx_mod.Gfx3D, t: gfx_mod.TextureId) u32 {
    return if (gfx.texture(t) != null) t.slot().? + 1 else 0;
}

fn packDraw(mat: Material, highlight: ?scene_mod.Highlight, mesh: *const gfx_mod.Mesh, gfx: *const gfx_mod.Gfx3D) gpu.DrawData {
    const F = gpu.DrawFlags;
    var flags: u32 = 0;
    if (mesh.has_normals) flags |= F.has_normals;
    if (mesh.has_uvs) flags |= F.has_uvs;
    if (mesh.has_colors and mat.vertex_colors) flags |= F.vertex_colors;
    if (gfx.texture(mat.base_color_texture) != null and mesh.has_uvs) flags |= F.base_texture;
    if (gfx.texture(mat.palette) != null) flags |= F.palette;
    if (mat.receive_shadows) flags |= F.receive_shadows;
    if (mat.fog) flags |= F.fog;
    if (mat.alpha_mode == .mask) flags |= F.alpha_mask;
    if (mat.alpha_mode == .blend) flags |= F.blend;
    if (mat.double_sided) flags |= F.double_sided;
    if (highlight != null) flags |= F.highlight;
    return .{
        .base_color = mat.base_color,
        .emissive = .{ mat.emissive[0], mat.emissive[1], mat.emissive[2], 0 },
        .pbr = .{ mat.metallic, std.math.clamp(mat.roughness, 0.04, 1), mat.alpha_cutoff, 0 },
        .toon = .{ @floatFromInt(@max(mat.toon.bands, 1)), mat.toon.min, mat.toon.softness, 0 },
        .detail = .{ mat.detail.scale, mat.detail.amount, 0, 0 },
        .outline_color = .{ 0, 0, 0, 0 },
        .outline = .{ 0, 0, 0, 0 },
        .highlight_color = if (highlight) |h| h.color else .{ 0, 0, 0, 0 },
        .flags = .{ flags, if (highlight) |h| h.id else 0, @intFromEnum(mat.shading), @intFromEnum(mesh.id_format) },
    };
}

/// Tilt-shift blur passes (half resolution, `half_height` rows) skip rows
/// this far (in 0..1 viewport units) from the focus line: the resolve shows
/// the sharp image there. [0] = horizontal pass (needs a vertical-kernel
/// margin for the vertical pass), [1] = vertical pass (bilinear margin).
pub fn tiltSkip(t: scene_mod.TiltShift, half_height: u32) [2]f32 {
    const texel = 1 / @as(f32, @floatFromInt(@max(half_height, 1)));
    const radius: f32 = @min(@ceil(@max(t.blur / 2, 0.5) * 3), 24);
    const half = t.range * 0.5;
    return .{ half - (radius + 2) * texel, half - 2 * texel };
}

pub const ShadowFit = struct { view_proj: Mat4, texel_world: f32 };

/// Orthographic light camera enclosing `region` (its bounding sphere, so the
/// fit does not swim as the region changes shape), snapped to whole texels.
pub fn fitShadow(region: Aabb, to_light: Vec3, size: u32) ShadowFit {
    const center = region.center();
    const radius = @max(region.radius(), 1e-3);
    const up: Vec3 = if (@abs(to_light.y) > 0.99) .new(0, 0, 1) else .up;
    const eye = center.add(to_light.scale(radius * 2));
    var view = Mat4.lookAt(eye, center, up);
    const texel = 2 * radius / @as(f32, @floatFromInt(size));
    // Snap the view origin to the texel grid in light space.
    const origin = view.transformPoint3(.zero);
    view.m[3][0] -= @mod(origin.x, texel);
    view.m[3][1] -= @mod(origin.y, texel);
    const proj = Mat4.orthographic(-radius, radius, -radius, radius, radius * 0.5, radius * 3.5, true);
    return .{ .view_proj = proj.mul(view), .texel_world = texel };
}

fn hashShadow(plan: *const Plan, gfx: *const gfx_mod.Gfx3D) u64 {
    if (!plan.shadowsEnabled()) return 0;
    var h = std.hash.Wyhash.init(0x5d);
    h.update(std.mem.asBytes(&plan.frame.light_view_proj));
    h.update(std.mem.asBytes(&plan.shadow_size));
    h.update(std.mem.asBytes(&gfx.revision));
    for (plan.shadow.items) |d| {
        var key = d;
        key.first_instance = 0;
        h.update(std.mem.asBytes(&key));
        h.update(std.mem.sliceAsBytes(plan.instances.items[d.first_instance..][0..d.instance_count]));
    }
    return h.final();
}

fn hashPlan(plan: *const Plan, gfx: *const gfx_mod.Gfx3D) u64 {
    var h = std.hash.Wyhash.init(0x3d);
    h.update(std.mem.asBytes(&plan.frame));
    h.update(std.mem.sliceAsBytes(plan.instances.items));
    inline for (.{ "shadow", "opaque", "blend", "outlines" }) |name| {
        const list = @field(plan, name).items;
        h.update(std.mem.asBytes(&list.len));
        h.update(std.mem.sliceAsBytes(list));
    }
    const p = plan.post;
    const words = [_]f32{
        p.exposure,                                  @floatFromInt(@intFromEnum(p.tonemap)),
        p.saturation,                                p.vignette,
        @floatFromInt(plan.samples),                 if (p.fxaa) 1 else 0,
        if (p.ssao) |s| s.radius else -1,            if (p.ssao) |s| s.intensity else 0,
        if (p.ssao) |s| @floatFromInt(s.samples) else 0, if (p.tilt_shift) |t| t.focus else -1,
        if (p.tilt_shift) |t| t.range else 0,        if (p.tilt_shift) |t| t.blur else 0,
        @floatFromInt(plan.shadow_size),             @floatFromInt(plan.width),
        @floatFromInt(plan.height),                  plan.clear[0],
        plan.clear[1],                               plan.clear[2],
        plan.clear[3],                               p.resolution_scale,
        p.sharpen,
    };
    h.update(std.mem.sliceAsBytes(&words));
    h.update(std.mem.asBytes(&gfx.revision));
    return h.final();
}

const testing = std.testing;
const shapes = @import("shapes.zig");

test "plan culls, splits passes and hashes stably" {
    var g = gfx_mod.Gfx3D.init(testing.allocator);
    defer g.deinit();
    var b = try shapes.box(testing.allocator, .{ 1, 1, 1 });
    defer b.deinit(testing.allocator);
    const mesh = try g.createMesh(b.desc());

    var s = Scene3D.init(testing.allocator, &g);
    defer s.deinit();
    s.camera = .{ .eye = .new(0, 4, 6), .target = .zero };
    try s.drawInstanced(mesh, &.{
        .{ .model = Mat4.identity },
        .{ .model = Mat4.translation(.new(2, 0, 0)) },
        .{ .model = Mat4.translation(.new(0, 0, 50)) }, // behind the camera
    }, .{ .material = .{ .outline = .{} } });
    try s.draw(mesh, Mat4.translation(.new(0, 1, 0)), .{ .material = .{ .alpha_mode = .blend, .base_color = .{ 1, 1, 1, 0.5 } } });

    var plan = Plan.init(testing.allocator);
    defer plan.deinit();
    try build(&plan, &s, 640, 480, .{});
    try testing.expectEqual(@as(usize, 1), plan.@"opaque".items.len);
    try testing.expectEqual(@as(u32, 2), plan.@"opaque".items[0].instance_count);
    try testing.expectEqual(@as(usize, 1), plan.blend.items.len);
    try testing.expectEqual(@as(usize, 1), plan.outlines.items.len);
    try testing.expectEqual(Cull.front, plan.outlines.items[0].cull);
    // All three opaque instances cast shadows into the fitted region; blend draws don't cast.
    try testing.expectEqual(@as(usize, 1), plan.shadow.items.len);
    try testing.expectEqual(@as(u32, 3), plan.shadow.items[0].instance_count);
    try testing.expect(plan.shadowsEnabled());
    try testing.expectEqual(@as(u32, 4), plan.samples);
    try testing.expect(!plan.blend.items[0].depth_write);

    const h1 = plan.hash;
    try build(&plan, &s, 640, 480, .{});
    try testing.expectEqual(h1, plan.hash);
    s.camera.eye.x += 0.01;
    try build(&plan, &s, 640, 480, .{});
    try testing.expect(plan.hash != h1);
    s.camera.eye.x -= 0.01;
    try build(&plan, &s, 640, 480, .{ .max_samples = 1 });
    try testing.expectEqual(@as(u32, 1), plan.samples);
    try testing.expect(plan.hash != h1);
}

test "plan picks LOD levels per instance; shadow map survives camera moves" {
    var g = gfx_mod.Gfx3D.init(testing.allocator);
    defer g.deinit();
    var fine = try shapes.sphere(testing.allocator, 1, 16, 24);
    defer fine.deinit(testing.allocator);
    var coarse = try shapes.sphere(testing.allocator, 1, 4, 6);
    defer coarse.deinit(testing.allocator);
    const hi = try g.createMesh(fine.desc());
    const lo = try g.createMesh(coarse.desc());
    try g.setLods(hi, &.{.{ .mesh = lo, .max_pixels = 100 }});

    var s = Scene3D.init(testing.allocator, &g);
    defer s.deinit();
    s.camera = .{ .eye = .new(0, 0, 10), .target = .zero };
    // Near sphere: large on screen. Far sphere: a few pixels.
    try s.drawInstanced(hi, &.{
        .{ .model = Mat4.translation(.new(0, 0, 5)) },
        .{ .model = Mat4.translation(.new(0, 0, -200)) },
    }, .{});
    var plan = Plan.init(testing.allocator);
    defer plan.deinit();
    try build(&plan, &s, 640, 480, .{});
    try testing.expectEqual(@as(usize, 2), plan.@"opaque".items.len);
    var slots: [2]u32 = undefined;
    for (plan.@"opaque".items, 0..) |d, i| {
        try testing.expectEqual(@as(u32, 1), d.instance_count);
        slots[i] = d.mesh_slot;
    }
    std.mem.sort(u32, &slots, {}, std.sort.asc(u32));
    try testing.expectEqual([2]u32{ hi.slot().?, lo.slot().? }, slots);

    // Shadow levels and hash do not depend on the camera.
    const sh = plan.shadow_hash;
    s.camera.eye = .new(3, 4, 12);
    try build(&plan, &s, 640, 480, .{});
    try testing.expectEqual(sh, plan.shadow_hash);
    s.sun.direction = .new(0.2, -1, 0.1);
    try build(&plan, &s, 640, 480, .{});
    try testing.expect(plan.shadow_hash != sh);

    // An explicit index range pins the mesh itself.
    s.clearDraws();
    try s.draw(hi, Mat4.translation(.new(0, 0, -200)), .{ .index_count = 30 });
    try build(&plan, &s, 640, 480, .{});
    try testing.expectEqual(hi.slot().?, plan.@"opaque".items[0].mesh_slot);
}

test "resolution scale shrinks the target; dynamic resolution steps toward the budget" {
    var g = gfx_mod.Gfx3D.init(testing.allocator);
    defer g.deinit();
    var s = Scene3D.init(testing.allocator, &g);
    defer s.deinit();
    var plan = Plan.init(testing.allocator);
    defer plan.deinit();
    s.post.resolution_scale = 0.5;
    try build(&plan, &s, 1000, 600, .{});
    try testing.expectEqual(@as(u32, 500), plan.width);
    try testing.expectEqual(@as(u32, 300), plan.height);

    s.post.resolution_scale = 1;
    s.dynamic_resolution = .{ .target_ms = 8 };
    s.stats = .{ .gpu_ms = 12 };
    s.updateDynamicResolution();
    try testing.expectEqual(@as(f32, 0.875), s.post.resolution_scale);
    s.stats = .{ .gpu_ms = 12, .cached = true }; // stale numbers: no change
    s.updateDynamicResolution();
    try testing.expectEqual(@as(f32, 0.875), s.post.resolution_scale);
    for (0..10) |_| {
        s.stats = .{ .gpu_ms = 20 };
        s.updateDynamicResolution();
    }
    try testing.expectEqual(@as(f32, 0.5), s.post.resolution_scale);
    s.stats = .{ .gpu_ms = 2 };
    s.updateDynamicResolution();
    try testing.expectEqual(@as(f32, 0.625), s.post.resolution_scale);
}

test "shadow fit contains the region" {
    const region: Aabb = .{ .min = .new(-3, 0, -2), .max = .new(5, 1, 4) };
    const fit = fitShadow(region, Vec3.new(0.3, 1, 0.2).normalize(), 1024);
    for (0..8) |i| {
        const p = fit.view_proj.project(region.corner(i));
        try testing.expect(@abs(p.x) <= 1 and @abs(p.y) <= 1);
        try testing.expect(p.z >= 0 and p.z <= 1);
    }
}
