//! zpui.three on Metal: the same passes as the Vulkan backend
//! (src/renderer/vulkan/three.zig) with shaders generated from the shared GLSL
//! by SPIRV-Cross (src/renderer/metal/three/*.metal, `zig build gen-msl`),
//! compiled at runtime like shaders.metal.
//!
//! Each rendered viewport is encoded into its own command buffer, committed
//! before the frame's UI command buffer, so its GPU time can be read from
//! `GPUStartTime`/`GPUEndTime` (Metal reports the total only; the per-pass
//! split is Vulkan-only). Metal retains resources referenced by in-flight
//! command buffers, so replaced GPU objects are released immediately.

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("../../platform/mac/objc.zig");
const mtl = @import("../../platform/mac/metal.zig");
const scene_mod = @import("../../scene.zig");
const three = @import("../../three/three.zig");
const gpu = three.gpu;
const Plan = three.plan.Plan;
const PlanDraw = three.plan.Draw;
const Gfx3D = three.Gfx3D;

const id = objc.id;
const NSUInteger = objc.NSUInteger;
const log = std.log.scoped(.three);

const hdr_format: mtl.PixelFormat = .rgba16_float;
const depth_format: mtl.PixelFormat = .depth32_float;
const ao_format: mtl.PixelFormat = .r8_unorm;
const ldr_format: mtl.PixelFormat = .rgba8_unorm;
const target_idle_frames = 120;
/// Front faces after SPIRV-Cross's `--flip-vert-y` (GL-style clip space).
const front_face: mtl.Winding = .counter_clockwise;

const sources = struct {
    const mesh_vert = @embedFile("three/mesh_vert.metal");
    const mesh_frag = @embedFile("three/mesh_frag.metal");
    const mesh_mask_frag = @embedFile("three/mesh_mask_frag.metal");
    const outline_vert = @embedFile("three/outline_vert.metal");
    const outline_frag = @embedFile("three/outline_frag.metal");
    const shadow_vert = @embedFile("three/shadow_vert.metal");
    const shadow_frag = @embedFile("three/shadow_frag.metal");
    const fullscreen_vert = @embedFile("three/fullscreen_vert.metal");
    const ssao_frag = @embedFile("three/ssao_frag.metal");
    const blur_frag = @embedFile("three/blur_frag.metal");
    const resolve_frag = @embedFile("three/resolve_frag.metal");
    const fxaa_frag = @embedFile("three/fxaa_frag.metal");
    const composite_vert = @embedFile("three/composite_vert.metal");
    const composite_frag = @embedFile("three/composite_frag.metal");
};

const GpuMesh = struct {
    generation: u32 = 0,
    buffer: ?id = null,
    positions: NSUInteger = 0,
    normals: ?NSUInteger = null,
    uvs: ?NSUInteger = null,
    colors: ?NSUInteger = null,
    ids: ?NSUInteger = null,
    indices: NSUInteger = 0,
};

const GpuTexture = struct {
    generation: u32 = 0,
    texture: ?id = null,
    sampler: ?id = null,
};

const MeshPipelines = struct {
    @"opaque": ?id = null,
    /// Alpha-tested (the only mesh pipeline whose shader may discard).
    mask: ?id = null,
    blend: ?id = null,
    outline: ?id = null,
};

const Target = struct {
    scene: *const three.Scene3D,
    occurrence: u32,
    last_used: u64 = 0,
    plan: Plan,
    rendered_hash: u64 = 0,
    /// `plan.shadow_hash` of the map in `shadow` (0 = stale).
    shadow_hash: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    samples: u32 = 0,
    color_msaa: ?id = null,
    depth: ?id = null,
    hdr: ?id = null,
    depth_resolve: ?id = null,
    shadow: ?id = null,
    ao_a: ?id = null,
    ao_b: ?id = null,
    blur_a: ?id = null,
    blur_b: ?id = null,
    ldr: ?id = null,
    ldr2: ?id = null,
    final: ?id = null,
    stats: three.Scene3D.Stats = .{},
    /// Committed command buffers (retained; shadow, main, post) not yet read
    /// for their GPU time, oldest first. Several frames can be in flight.
    timings: [4]?[3]id = @splat(null),

    fn pollTimings(t: *Target) void {
        for (&t.timings) |*slot| if (slot.*) |cbs| {
            var done = true;
            var failed = false;
            for (cbs) |cb| switch (mtl.CommandBuffer.status(cb)) {
                .completed => {},
                .@"error" => failed = true,
                else => done = false,
            };
            if (!done and !failed) continue;
            if (!failed) {
                var ms: [3]f32 = undefined;
                for (cbs, &ms) |cb, *m| m.* = @floatCast(@max(mtl.CommandBuffer.gpuEndTime(cb) - mtl.CommandBuffer.gpuStartTime(cb), 0) * 1000);
                t.stats.gpu_shadow_ms = ms[0];
                t.stats.gpu_main_ms = ms[1];
                t.stats.gpu_post_ms = ms[2];
                t.stats.gpu_ms = ms[0] + ms[1] + ms[2];
            }
            for (cbs) |cb| cb.release();
            slot.* = null;
        };
    }

    fn pushTiming(t: *Target, cbs: [3]id) void {
        for (&t.timings) |*slot| if (slot.* == null) {
            slot.* = cbs;
            return;
        };
        // All four still in flight: drop the oldest.
        for (t.timings[0].?) |cb| cb.release();
        std.mem.copyForwards(?[3]id, t.timings[0..3], t.timings[1..4]);
        t.timings[3] = cbs;
    }

    fn slots(t: *Target) [11]*?id {
        return .{ &t.color_msaa, &t.depth, &t.hdr, &t.depth_resolve, &t.shadow, &t.ao_a, &t.ao_b, &t.blur_a, &t.blur_b, &t.ldr, &t.ldr2 };
    }

    fn release(t: *Target) void {
        for (t.slots()) |s| if (s.*) |tex| {
            tex.release();
            s.* = null;
        };
        for (&t.timings) |*slot| if (slot.*) |cbs| {
            for (cbs) |cb| cb.release();
            slot.* = null;
        };
        t.final = null;
    }
};

/// What the renderer's instance-buffer frame provides (see renderer.zig `Frame`).
pub const FrameAlloc = struct {
    ctx: *anyopaque,
    buffer: id,
    writeFn: *const fn (ctx: *anyopaque, bytes: []const u8) error{InstanceBufferOverflow}!usize,

    fn write(self: FrameAlloc, bytes: []const u8) error{InstanceBufferOverflow}!usize {
        return self.writeFn(self.ctx, bytes);
    }
};

pub const Three = struct {
    gpa: Allocator,
    device: id,
    is_apple_gpu: bool,
    unified_memory: bool,
    gfx: ?*Gfx3D = null,
    meshes: std.ArrayList(GpuMesh) = .empty,
    textures: std.ArrayList(GpuTexture) = .empty,
    targets: std.ArrayList(*Target) = .empty,
    frame_targets: std.ArrayList(?*Target) = .empty,
    pending: std.ArrayList(struct { target: *Target, cbs: [3]id }) = .empty,
    frame_number: u64 = 0,

    libraries: std.ArrayList(id) = .empty,
    mesh_pipelines: [3]MeshPipelines = .{ .{}, .{}, .{} },
    two_samples: bool = false,
    shadow_pipeline: ?id = null,
    ssao_pipeline: ?id = null,
    blur_ao_pipeline: ?id = null,
    blur_hdr_pipeline: ?id = null,
    resolve_pipeline: ?id = null,
    fxaa_pipeline: ?id = null,
    composite_pipeline: ?id = null,
    depth_reverse: ?id = null,
    depth_reverse_read: ?id = null,
    depth_standard: ?id = null,
    samplers: [4]?id = @splat(null),
    clamp_sampler: ?id = null,
    nearest_sampler: ?id = null,
    shadow_sampler: ?id = null,
    white: ?id = null,
    dummy_depth: ?id = null,
    dummy_buffer: ?id = null,
    max_samples: u32 = 4,
    failed: bool = false,

    pub fn init(gpa: Allocator, device: id, is_apple_gpu: bool, unified_memory: bool) Three {
        return .{ .gpa = gpa, .device = device, .is_apple_gpu = is_apple_gpu, .unified_memory = unified_memory };
    }

    /// Compile the shaders and create pipelines; on failure 3D viewports are skipped.
    pub fn create(self: *Three, ui_format: mtl.PixelFormat, command_queue: id) void {
        self.createInner(ui_format, command_queue) catch |err| {
            log.err("3D pipeline setup failed ({t}); viewport3d primitives will be skipped", .{err});
            self.failed = true;
        };
    }

    fn createInner(self: *Three, ui_format: mtl.PixelFormat, command_queue: id) !void {
        const d = self.device;
        for ([_]u8{ 4, 1 }) |n| {
            if (d.msg(objc.BOOL, "supportsTextureSampleCount:", .{@as(NSUInteger, n)}) != objc.NO) {
                self.max_samples = n;
                break;
            }
        }
        self.two_samples = d.msg(objc.BOOL, "supportsTextureSampleCount:", .{@as(NSUInteger, 2)}) != objc.NO;
        const lib = struct {
            fn load(t: *Three, comptime src: [:0]const u8, comptime name: [:0]const u8) !id {
                var err: ?id = null;
                const library = mtl.Device.newLibraryWithSource(t.device, objc.nsString(src), &err) orelse {
                    log.err("3D shader {s} failed to compile: {s}", .{ name, objc.errorDescription(err) });
                    return error.ShaderCompilationFailed;
                };
                try t.libraries.append(t.gpa, library);
                return mtl.newFunction(library, name) orelse {
                    log.err("3D shader function {s} missing", .{name});
                    return error.ShaderCompilationFailed;
                };
            }
        }.load;
        const f = .{
            .mesh_vert = try lib(self, sources.mesh_vert, "mesh_vert"),
            .mesh_frag = try lib(self, sources.mesh_frag, "mesh_frag"),
            .mesh_mask_frag = try lib(self, sources.mesh_mask_frag, "mesh_mask_frag"),
            .outline_vert = try lib(self, sources.outline_vert, "outline_vert"),
            .outline_frag = try lib(self, sources.outline_frag, "outline_frag"),
            .shadow_vert = try lib(self, sources.shadow_vert, "shadow_vert"),
            .shadow_frag = try lib(self, sources.shadow_frag, "shadow_frag"),
            .fullscreen_vert = try lib(self, sources.fullscreen_vert, "fullscreen_vert"),
            .ssao_frag = try lib(self, sources.ssao_frag, "ssao_frag"),
            .blur_frag = try lib(self, sources.blur_frag, "blur_frag"),
            .resolve_frag = try lib(self, sources.resolve_frag, "resolve_frag"),
            .fxaa_frag = try lib(self, sources.fxaa_frag, "fxaa_frag"),
            .composite_vert = try lib(self, sources.composite_vert, "composite_vert"),
            .composite_frag = try lib(self, sources.composite_frag, "composite_frag"),
        };
        defer inline for (@typeInfo(@TypeOf(f)).@"struct".field_names) |n| @field(f, n).release();

        const premul: mtl.Blend = .{ .src_rgb = .one, .src_alpha = .one, .dst_rgb = .one_minus_source_alpha, .dst_alpha = .one_minus_source_alpha };
        for ([_]u32{ 1, 2, 4 }, 0..) |n, i| {
            if (n > self.max_samples or (n == 2 and !self.two_samples)) continue;
            const p = &self.mesh_pipelines[i];
            p.@"opaque" = try self.pipeline("three_mesh", f.mesh_vert, f.mesh_frag, hdr_format, .depth32_float, n, null);
            p.mask = try self.pipeline("three_mesh_mask", f.mesh_vert, f.mesh_mask_frag, hdr_format, .depth32_float, n, null);
            p.blend = try self.pipeline("three_mesh_blend", f.mesh_vert, f.mesh_frag, hdr_format, .depth32_float, n, premul);
            p.outline = try self.pipeline("three_outline", f.outline_vert, f.outline_frag, hdr_format, .depth32_float, n, null);
        }
        self.shadow_pipeline = try self.pipeline("three_shadow", f.shadow_vert, f.shadow_frag, .invalid, .depth32_float, 1, null);
        self.ssao_pipeline = try self.pipeline("three_ssao", f.fullscreen_vert, f.ssao_frag, ao_format, .invalid, 1, null);
        self.blur_ao_pipeline = try self.pipeline("three_blur_ao", f.fullscreen_vert, f.blur_frag, ao_format, .invalid, 1, null);
        self.blur_hdr_pipeline = try self.pipeline("three_blur_hdr", f.fullscreen_vert, f.blur_frag, hdr_format, .invalid, 1, null);
        self.resolve_pipeline = try self.pipeline("three_resolve", f.fullscreen_vert, f.resolve_frag, ldr_format, .invalid, 1, null);
        self.fxaa_pipeline = try self.pipeline("three_fxaa", f.fullscreen_vert, f.fxaa_frag, ldr_format, .invalid, 1, null);
        self.composite_pipeline = try self.pipeline("three_composite", f.composite_vert, f.composite_frag, ui_format, .invalid, 1, premul);

        self.depth_reverse = try depthState(d, .greater_equal, true);
        self.depth_reverse_read = try depthState(d, .greater_equal, false);
        self.depth_standard = try depthState(d, .less_equal, true);
        for (0..2) |fi| for (0..2) |wi| {
            self.samplers[fi * 2 + wi] = try sampler(d, .{
                .filter = if (fi == 0) .linear else .nearest,
                .mip = if (fi == 0) .linear else .nearest,
                .address = if (wi == 0) .repeat else .clamp_to_edge,
            });
        };
        self.clamp_sampler = try sampler(d, .{});
        self.nearest_sampler = try sampler(d, .{ .filter = .nearest });
        self.shadow_sampler = try sampler(d, .{ .compare = .less_equal });

        // Placeholders.
        self.white = try self.newTexture(1, 1, .rgba8_unorm, mtl.TextureUsage.shader_read, if (self.is_apple_gpu) .shared else .managed, 1, 1);
        const px = [4]u8{ 255, 255, 255, 255 };
        mtl.Texture.replaceRegion(self.white.?, .{ .origin = .{}, .size = .{ .width = 1, .height = 1 } }, &px, 4);
        self.dummy_depth = try self.newTexture(1, 1, depth_format, mtl.TextureUsage.shader_read | mtl.TextureUsage.render_target, .private, 1, 1);
        const zeros: [256]u8 = @splat(0);
        self.dummy_buffer = mtl.Device.newBufferWithBytes(d, &zeros, zeros.len, storageOptions(self.unified_memory)) orelse return error.ResourceCreationFailed;
        // Depth textures are private: clear the placeholder to 1 with a pass.
        const cb = mtl.CommandBuffer.fromQueue(command_queue) orelse return error.CommandBufferFailed;
        const pass = mtl.RenderPassDescriptor.newWithDepth(null, .{ .texture = self.dummy_depth.?, .load = .clear, .store = .store, .clear = 1 }) orelse return error.CommandBufferFailed;
        const enc = mtl.CommandBuffer.renderCommandEncoder(cb, pass) orelse return error.CommandBufferFailed;
        mtl.RenderEncoder.endEncoding(enc);
        mtl.CommandBuffer.commit(cb);
    }

    pub fn deinit(self: *Three) void {
        for (self.meshes.items) |m| if (m.buffer) |b| b.release();
        for (self.textures.items) |t| if (t.texture) |x| x.release();
        for (self.targets.items) |t| {
            t.release();
            t.plan.deinit();
            self.gpa.destroy(t);
        }
        self.meshes.deinit(self.gpa);
        self.textures.deinit(self.gpa);
        self.targets.deinit(self.gpa);
        self.frame_targets.deinit(self.gpa);
        self.discardPending();
        self.pending.deinit(self.gpa);
        for (self.libraries.items) |l| l.release();
        self.libraries.deinit(self.gpa);
        for (&self.mesh_pipelines) |*p| inline for (.{ "opaque", "mask", "blend", "outline" }) |n| if (@field(p, n)) |x| x.release();
        inline for (.{ "shadow_pipeline", "ssao_pipeline", "blur_ao_pipeline", "blur_hdr_pipeline", "resolve_pipeline", "fxaa_pipeline", "composite_pipeline", "depth_reverse", "depth_reverse_read", "depth_standard", "clamp_sampler", "nearest_sampler", "shadow_sampler", "white", "dummy_depth", "dummy_buffer" }) |n| {
            if (@field(self, n)) |x| x.release();
        }
        for (self.samplers) |s| if (s) |x| x.release();
        self.* = undefined;
    }

    // -----------------------------------------------------------------------
    // Per frame
    // -----------------------------------------------------------------------

    /// Plan every viewport, sync the store, read finished timings.
    pub fn beginFrame(self: *Three, scene: *const scene_mod.Scene) !void {
        self.frame_number += 1;
        self.frame_targets.clearRetainingCapacity();
        if (self.failed) return;
        for (scene.viewports3d.items, 0..) |v, vi| {
            const s3 = v.scene3d;
            var occurrence: u32 = 0;
            for (scene.viewports3d.items[0..vi]) |prev| {
                if (prev.scene3d == s3) occurrence += 1;
            }
            const w: u32 = @intFromFloat(std.math.clamp(@ceil(v.bounds.size.width), 1, 16384));
            const h: u32 = @intFromFloat(std.math.clamp(@ceil(v.bounds.size.height), 1, 16384));
            const t = try self.targetFor(s3, occurrence);
            t.last_used = self.frame_number;
            try self.bindStore(s3.gfx);
            try three.plan.build(&t.plan, s3, w, h, .{ .max_samples = self.max_samples, .two_samples = self.two_samples, .max_texture_size = 16384 });
            t.pollTimings();
            v.scene3d.stats = t.stats;
            v.scene3d.stats.cached = t.plan.hash == t.rendered_hash and t.final != null;
            v.scene3d.updateDynamicResolution();
            try self.frame_targets.append(self.gpa, t);
        }
        var i: usize = 0;
        while (i < self.targets.items.len) {
            const t = self.targets.items[i];
            if (t.last_used + target_idle_frames < self.frame_number) {
                t.release();
                t.plan.deinit();
                self.gpa.destroy(t);
                _ = self.targets.swapRemove(i);
            } else i += 1;
        }
        try self.upload();
    }

    fn targetFor(self: *Three, s3: *const three.Scene3D, occurrence: u32) !*Target {
        for (self.targets.items) |t| if (t.scene == s3 and t.occurrence == occurrence) return t;
        const t = try self.gpa.create(Target);
        errdefer self.gpa.destroy(t);
        t.* = .{ .scene = s3, .occurrence = occurrence, .plan = .init(self.gpa) };
        try self.targets.append(self.gpa, t);
        return t;
    }

    fn bindStore(self: *Three, gfx: *Gfx3D) !void {
        if (self.gfx == gfx) return;
        if (self.gfx != null) {
            log.warn("a renderer can mirror one Gfx3D store; switching stores re-uploads everything", .{});
            for (self.meshes.items) |m| if (m.buffer) |b| b.release();
            for (self.textures.items) |t| if (t.texture) |x| x.release();
            self.meshes.clearRetainingCapacity();
            self.textures.clearRetainingCapacity();
        }
        self.gfx = gfx;
        gfx.pending_meshes.clearRetainingCapacity();
        gfx.pending_textures.clearRetainingCapacity();
        for (gfx.meshes.items, 0..) |m, s| if (m.live and m.cpu != null) try gfx.pending_meshes.append(gfx.gpa, @intCast(s));
        for (gfx.textures.items, 0..) |t, s| if (t.live and t.cpu != null) try gfx.pending_textures.append(gfx.gpa, @intCast(s));
    }

    fn upload(self: *Three) !void {
        const gfx = self.gfx orelse return;
        for (gfx.released.items) |rel| switch (rel) {
            .mesh => |s| if (s < self.meshes.items.len) {
                if (self.meshes.items[s].buffer) |b| b.release();
                self.meshes.items[s] = .{};
            },
            .texture => |s| if (s < self.textures.items.len) {
                if (self.textures.items[s].texture) |x| x.release();
                self.textures.items[s] = .{};
            },
        };
        gfx.released.clearRetainingCapacity();

        while (self.meshes.items.len < gfx.meshes.items.len) try self.meshes.append(self.gpa, .{});
        for (gfx.pending_meshes.items) |s| {
            const m = &gfx.meshes.items[s];
            const data = m.cpu.?;
            const g = &self.meshes.items[s];
            if (g.buffer) |b| b.release();
            const buf = mtl.Device.newBufferWithBytes(self.device, data.bytes.ptr, data.bytes.len, storageOptions(self.unified_memory)) orelse return error.ResourceCreationFailed;
            const base = @intFromPtr(data.bytes.ptr);
            const off = struct {
                fn of(root: usize, slice: anytype) ?NSUInteger {
                    return if (slice.len == 0) null else @intFromPtr(slice.ptr) - root;
                }
            }.of;
            g.* = .{
                .generation = m.generation,
                .buffer = buf,
                .positions = off(base, data.positions).?,
                .normals = off(base, data.normals),
                .uvs = off(base, data.uvs),
                .colors = off(base, data.colors),
                .ids = off(base, data.ids),
                .indices = @intFromPtr(data.indices.ptr) - base,
            };
            gfx.markMeshUploaded(s);
        }

        while (self.textures.items.len < gfx.textures.items.len) try self.textures.append(self.gpa, .{});
        for (gfx.pending_textures.items) |s| {
            const t = &gfx.textures.items[s];
            const bytes = t.cpu.?;
            const g = &self.textures.items[s];
            if (g.texture) |x| x.release();
            const tex = try self.newTexture(t.width, t.height, if (t.format == .rgba8_srgb) .rgba8_unorm_srgb else .rgba8_unorm, mtl.TextureUsage.shader_read, if (self.is_apple_gpu) .shared else .managed, 1, t.mip_levels);
            var level_off: usize = 0;
            for (0..t.mip_levels) |lvl| {
                const sz = t.mipSize(@intCast(lvl));
                mtl.Texture.replaceRegionLevel(tex, .{ .origin = .{}, .size = .{ .width = sz[0], .height = sz[1] } }, lvl, bytes.ptr + level_off, @as(NSUInteger, sz[0]) * 4);
                level_off += @as(usize, sz[0]) * sz[1] * 4;
            }
            g.* = .{ .generation = t.generation, .texture = tex, .sampler = self.samplers[@as(usize, @intFromEnum(t.filter)) * 2 + @intFromEnum(t.wrap)] };
            gfx.markTextureUploaded(s);
        }
        gfx.pending_meshes.clearRetainingCapacity();
        gfx.pending_textures.clearRetainingCapacity();
    }

    // -----------------------------------------------------------------------
    // Rendering
    // -----------------------------------------------------------------------

    /// Encode every changed viewport into its own command buffer. They are
    /// committed by `commitPending` (before the UI command buffer) or dropped by
    /// `discardPending` when the frame is re-encoded.
    pub fn render(self: *Three, queue: id, frame: FrameAlloc) !void {
        if (self.failed) return;
        self.discardPending();
        for (self.frame_targets.items) |maybe| {
            const t = maybe orelse continue;
            if (t.plan.hash == t.rendered_hash and t.final != null) {
                t.stats.cached = true;
                continue;
            }
            // One command buffer per pass (shadow, main, post) for per-pass GPU times.
            var cbs: [3]id = undefined;
            for (&cbs, 0..) |*cb, i| {
                cb.* = (mtl.CommandBuffer.fromQueue(queue) orelse {
                    for (cbs[0..i]) |prev| prev.release();
                    return error.CommandBufferFailed;
                }).retain();
            }
            try self.pending.append(self.gpa, .{ .target = t, .cbs = cbs });
            try self.renderTarget(cbs, frame, t);
        }
    }

    pub fn commitPending(self: *Three) void {
        for (self.pending.items) |p| {
            for (p.cbs) |cb| mtl.CommandBuffer.commit(cb);
            p.target.pushTiming(p.cbs);
            p.target.rendered_hash = p.target.plan.hash;
        }
        self.pending.clearRetainingCapacity();
    }

    pub fn discardPending(self: *Three) void {
        for (self.pending.items) |p| {
            for (p.cbs) |cb| cb.release();
            // Encoded but never committed: the target's images hold nothing valid.
            p.target.rendered_hash = 0;
            p.target.shadow_hash = 0;
        }
        self.pending.clearRetainingCapacity();
    }

    fn renderTarget(self: *Three, cbs: [3]id, frame: FrameAlloc, t: *Target) !void {
        const plan = &t.plan;
        try self.ensureTextures(t);
        const frame_off = try frame.write(std.mem.asBytes(&plan.frame));
        const inst_off: ?usize = if (plan.instances.items.len > 0) try frame.write(std.mem.sliceAsBytes(plan.instances.items)) else null;
        const msaa = plan.samples > 1;
        const ssao = plan.ssao() != null;

        // ---- shadow --------------------------------------------------------
        // Static light and casters: the map from an earlier frame is still valid.
        const shadow_cached = plan.shadowsEnabled() and t.shadow_hash == plan.shadow_hash;
        if (plan.shadowsEnabled() and !shadow_cached) {
            t.shadow_hash = plan.shadow_hash;
            const pass = mtl.RenderPassDescriptor.newWithDepth(null, .{ .texture = t.shadow.?, .load = .clear, .store = .store, .clear = 1 }) orelse return error.CommandBufferFailed;
            const enc = try beginPass(cbs[0], pass, plan.shadow_size, plan.shadow_size);
            defer mtl.RenderEncoder.endEncoding(enc);
            mtl.RenderEncoder.setPipeline(enc, self.shadow_pipeline.?);
            mtl.RenderEncoder.setDepthStencilState(enc, self.depth_standard.?);
            mtl.RenderEncoder.setCullMode(enc, .none);
            mtl.RenderEncoder.setDepthBias(enc, 0, 1.0, 0);
            for (plan.shadow.items) |*d| try self.drawMesh(enc, frame, d, frame_off, inst_off, null);
        }

        // ---- main ----------------------------------------------------------
        {
            const cl = plan.clear;
            const color: mtl.RenderPassDescriptor.Attachment = .{
                .texture = if (msaa) t.color_msaa.? else t.hdr.?,
                .resolve_texture = if (msaa) t.hdr.? else null,
                .load = .clear,
                .store = if (msaa) .multisample_resolve else .store,
                .clear = .{ .red = cl[0] * cl[3], .green = cl[1] * cl[3], .blue = cl[2] * cl[3], .alpha = cl[3] },
            };
            const depth: mtl.RenderPassDescriptor.DepthAttachment = .{
                .texture = t.depth.?,
                .resolve_texture = if (msaa and ssao) t.depth_resolve.? else null,
                .load = .clear,
                .store = if (msaa and ssao) .multisample_resolve else if (ssao) .store else .dont_care,
                .clear = 0,
            };
            const pass = mtl.RenderPassDescriptor.newWithDepth(color, depth) orelse return error.CommandBufferFailed;
            const enc = try beginPass(cbs[1], pass, plan.width, plan.height);
            defer mtl.RenderEncoder.endEncoding(enc);
            mtl.RenderEncoder.setFrontFacingWinding(enc, front_face);
            const mp = self.mesh_pipelines[switch (plan.samples) {
                4 => 2,
                2 => 1,
                else => 0,
            }];
            const shadow_tex = if (plan.shadowsEnabled()) t.shadow.? else self.dummy_depth.?;
            if (plan.@"opaque".items.len > 0) {
                var masked = false;
                mtl.RenderEncoder.setPipeline(enc, mp.@"opaque".?);
                for (plan.@"opaque".items) |*d| {
                    if (d.alpha_mask != masked) {
                        masked = d.alpha_mask;
                        mtl.RenderEncoder.setPipeline(enc, if (masked) mp.mask.? else mp.@"opaque".?);
                    }
                    try self.drawMesh(enc, frame, d, frame_off, inst_off, shadow_tex);
                }
            }
            if (plan.outlines.items.len > 0) {
                mtl.RenderEncoder.setPipeline(enc, mp.outline.?);
                for (plan.outlines.items) |*d| try self.drawMesh(enc, frame, d, frame_off, inst_off, shadow_tex);
            }
            if (plan.blend.items.len > 0) {
                mtl.RenderEncoder.setPipeline(enc, mp.blend.?);
                for (plan.blend.items) |*d| try self.drawMesh(enc, frame, d, frame_off, inst_off, shadow_tex);
            }
        }

        // ---- post ----------------------------------------------------------
        const cb = cbs[2];
        const hw = @max(plan.width / 2, 1);
        const hh = @max(plan.height / 2, 1);
        const fw: f32 = @floatFromInt(plan.width);
        const fh: f32 = @floatFromInt(plan.height);
        const fhw: f32 = @floatFromInt(hw);
        const fhh: f32 = @floatFromInt(hh);
        const white = self.white.?;
        var ao_tex = white;
        var ao_strength: f32 = 0;
        if (plan.ssao()) |cfg| {
            const depth_tex = if (msaa) t.depth_resolve.? else t.depth.?;
            try self.postPass(cb, frame, self.ssao_pipeline.?, t.ao_a.?, hw, hh, .{ depth_tex, white, white }, self.nearest_sampler.?, .{
                .p0 = .{ cfg.radius, 0, @floatFromInt(cfg.samples), 0.03 * cfg.radius },
                .p1 = .{ 1 / fhw, 1 / fhh, 0, 0 },
            }, frame_off);
            try self.postPass(cb, frame, self.blur_ao_pipeline.?, t.ao_b.?, hw, hh, .{ t.ao_a.?, white, white }, self.clamp_sampler.?, .{ .p0 = .{ 1, 0, 1.5, 0 }, .p1 = .{ 1 / fhw, 1 / fhh, 1, 0 } }, null);
            try self.postPass(cb, frame, self.blur_ao_pipeline.?, t.ao_a.?, hw, hh, .{ t.ao_b.?, white, white }, self.clamp_sampler.?, .{ .p0 = .{ 0, 1, 1.5, 0 }, .p1 = .{ 1 / fhw, 1 / fhh, 1, 0 } }, null);
            ao_tex = t.ao_a.?;
            ao_strength = cfg.intensity;
        }
        var blurred = t.hdr.?;
        var tilt: three.TiltShift = .{};
        var tilt_on: f32 = 0;
        if (plan.tiltShift()) |cfg| {
            tilt = cfg;
            tilt_on = 1;
            const sigma = @max(cfg.blur / 2, 0.5);
            const skip = three.plan.tiltSkip(cfg, hh);
            try self.postPass(cb, frame, self.blur_hdr_pipeline.?, t.blur_a.?, hw, hh, .{ t.hdr.?, ao_tex, white }, self.clamp_sampler.?, .{
                .p0 = .{ 2, 0, sigma, if (ao_strength > 0) 1 else 0 },
                .p1 = .{ 1 / fw, 1 / fh, 2, ao_strength },
                .p2 = .{ 1 / fhh, cfg.focus, skip[0], 1 },
            }, null);
            try self.postPass(cb, frame, self.blur_hdr_pipeline.?, t.blur_b.?, hw, hh, .{ t.blur_a.?, white, white }, self.clamp_sampler.?, .{
                .p0 = .{ 0, 1, sigma, 0 },
                .p1 = .{ 1 / fhw, 1 / fhh, 1, 0 },
                .p2 = .{ 1 / fhh, cfg.focus, skip[1], 1 },
            }, null);
            blurred = t.blur_b.?;
        }
        const post = plan.post;
        try self.postPass(cb, frame, self.resolve_pipeline.?, t.ldr.?, plan.width, plan.height, .{ t.hdr.?, ao_tex, blurred }, self.clamp_sampler.?, .{
            .p0 = .{ post.exposure, @floatFromInt(@intFromEnum(post.tonemap)), post.saturation, post.vignette },
            .p1 = .{ ao_strength, tilt.focus, tilt.range, tilt_on },
            .p2 = .{ 1 / fw, 1 / fh, 0, 0 },
        }, null);
        t.final = t.ldr;
        if (post.fxaa) {
            try self.postPass(cb, frame, self.fxaa_pipeline.?, t.ldr2.?, plan.width, plan.height, .{ t.ldr.?, white, white }, self.clamp_sampler.?, .{ .p2 = .{ 1 / fw, 1 / fh, 0, 0 } }, null);
            t.final = t.ldr2;
        }
        t.stats = .{
            .draws = @intCast(plan.@"opaque".items.len + plan.blend.items.len + plan.outlines.items.len),
            .instances = @intCast(plan.instances.items.len),
            .triangles = plan.triangles,
            .shadow_draws = @intCast(plan.shadow.items.len),
            .shadow_cached = shadow_cached,
            .gpu_ms = t.stats.gpu_ms,
            .gpu_shadow_ms = t.stats.gpu_shadow_ms,
            .gpu_main_ms = t.stats.gpu_main_ms,
            .gpu_post_ms = t.stats.gpu_post_ms,
        };
    }

    fn drawMesh(self: *Three, enc: id, frame: FrameAlloc, d: *const PlanDraw, frame_off: usize, inst_off: ?usize, shadow_tex: ?id) !void {
        const m = &self.meshes.items[d.mesh_slot];
        const buf = m.buffer orelse return;
        const dummy = self.dummy_buffer.?;
        const B = gpu.Binding;
        const E = mtl.RenderEncoder;
        E.setVertexBuffer(enc, buf, m.positions, B.positions);
        if (m.normals) |o| E.setVertexBuffer(enc, buf, o, B.normals) else E.setVertexBuffer(enc, dummy, 0, B.normals);
        if (m.uvs) |o| E.setVertexBuffer(enc, buf, o, B.uvs) else E.setVertexBuffer(enc, dummy, 0, B.uvs);
        if (m.colors) |o| E.setVertexBuffer(enc, buf, o, B.colors) else E.setVertexBuffer(enc, dummy, 0, B.colors);
        if (m.ids) |o| E.setVertexBuffer(enc, buf, o, B.ids) else E.setVertexBuffer(enc, dummy, 0, B.ids);
        if (inst_off) |o| E.setVertexBuffer(enc, frame.buffer, o + @as(usize, d.first_instance) * @sizeOf(three.Instance), B.instances) else E.setVertexBuffer(enc, dummy, 0, B.instances);
        E.setVertexBuffer(enc, frame.buffer, frame_off, B.frame);
        E.setFragmentBuffer(enc, frame.buffer, frame_off, B.frame);
        const draw_off = try frame.write(std.mem.asBytes(&d.data));
        E.setVertexBuffer(enc, frame.buffer, draw_off, B.draw);
        E.setFragmentBuffer(enc, frame.buffer, draw_off, B.draw);
        if (shadow_tex) |st| {
            E.setFragmentTexture(enc, st, B.shadow_map);
            E.setFragmentSamplerState(enc, self.shadow_sampler.?, B.shadow_map);
            const base = self.texture(d.base_texture);
            E.setFragmentTexture(enc, base.texture, B.base_texture);
            E.setFragmentSamplerState(enc, base.sampler, B.base_texture);
            E.setFragmentTexture(enc, self.texture(d.palette).texture, B.palette);
            E.setFragmentSamplerState(enc, self.nearest_sampler.?, B.palette);
            E.setCullMode(enc, switch (d.cull) {
                .back => .back,
                .front => .front,
                .none => .none,
            });
            E.setDepthStencilState(enc, if (d.depth_write) self.depth_reverse.? else self.depth_reverse_read.?);
            // Reverse-Z: positive bias moves toward the camera.
            E.setDepthBias(enc, d.depth_bias * 64, d.depth_bias, 0);
        }
        E.drawIndexed(enc, .triangle, d.index_count, .uint32, buf, m.indices + @as(usize, d.first_index) * 4, d.instance_count);
    }

    fn texture(self: *const Three, slot_plus_one: u32) struct { texture: id, sampler: id } {
        if (slot_plus_one > 0 and slot_plus_one - 1 < self.textures.items.len) {
            const t = &self.textures.items[slot_plus_one - 1];
            if (t.texture) |x| return .{ .texture = x, .sampler = t.sampler.? };
        }
        return .{ .texture = self.white.?, .sampler = self.samplers[0].? };
    }

    fn postPass(self: *Three, cb: id, frame: FrameAlloc, pipeline_state: id, dst: id, w: u32, h: u32, textures: [3]id, sampler_state: id, params: gpu.PostParams, frame_off: ?usize) !void {
        const pass = mtl.RenderPassDescriptor.new(.{ .texture = dst, .load = .dont_care, .store = .store }) orelse return error.CommandBufferFailed;
        const enc = try beginPass(cb, pass, w, h);
        defer mtl.RenderEncoder.endEncoding(enc);
        const E = mtl.RenderEncoder;
        E.setPipeline(enc, pipeline_state);
        E.setFragmentBytes(enc, &params, @sizeOf(gpu.PostParams), gpu.Binding.post_params);
        E.setVertexBytes(enc, &params, @sizeOf(gpu.PostParams), gpu.Binding.post_params);
        E.setFragmentBuffer(enc, frame.buffer, frame_off orelse 0, gpu.Binding.frame);
        for (textures, 0..) |tex, i| {
            E.setFragmentTexture(enc, tex, gpu.Binding.post_tex0 + i);
            E.setFragmentSamplerState(enc, sampler_state, gpu.Binding.post_tex0 + i);
        }
        E.draw(enc, .triangle, 0, 3);
        _ = self;
    }

    /// Draw viewport `index` inside the UI encoder.
    pub fn composite(self: *Three, enc: id, v: *const scene_mod.Viewport3D, index: usize, viewport: [2]f32) void {
        if (self.failed or index >= self.frame_targets.items.len) return;
        const t = self.frame_targets.items[index] orelse return;
        const final = t.final orelse return;
        const m = v.content_mask.bounds;
        const params: gpu.PostParams = .{
            .p0 = .{ v.bounds.origin.x, v.bounds.origin.y, v.bounds.size.width, v.bounds.size.height },
            .p1 = .{ m.origin.x, m.origin.y, m.size.width, m.size.height },
            .p2 = .{ v.corner_radii.top_left, v.corner_radii.top_right, v.corner_radii.bottom_right, v.corner_radii.bottom_left },
            .p3 = .{ viewport[0], viewport[1], v.opacity, if (t.plan.post.resolution_scale < 1) std.math.clamp(t.plan.post.sharpen, 0, 1) else 0 },
        };
        const E = mtl.RenderEncoder;
        E.setPipeline(enc, self.composite_pipeline.?);
        E.setVertexBytes(enc, &params, @sizeOf(gpu.PostParams), gpu.Binding.post_params);
        E.setFragmentBytes(enc, &params, @sizeOf(gpu.PostParams), gpu.Binding.post_params);
        E.setFragmentTexture(enc, final, gpu.Binding.post_tex0);
        E.setFragmentSamplerState(enc, self.clamp_sampler.?, gpu.Binding.post_tex0);
        E.draw(enc, .triangle, 0, 6);
    }

    // -----------------------------------------------------------------------
    // Resources
    // -----------------------------------------------------------------------

    fn ensureTextures(self: *Three, t: *Target) !void {
        const plan = &t.plan;
        const w = plan.width;
        const h = plan.height;
        const hw = @max(w / 2, 1);
        const hh = @max(h / 2, 1);
        const msaa = plan.samples > 1;
        const ssao = plan.ssao() != null;
        if (t.width != w or t.height != h or t.samples != plan.samples) {
            const shadow = t.shadow;
            t.shadow = null;
            t.release();
            t.shadow = shadow;
            t.width = w;
            t.height = h;
            t.samples = plan.samples;
        }
        const U = mtl.TextureUsage;
        const rt_read = U.render_target | U.shader_read;
        // MSAA attachments resolved in-pass never need memory on Apple GPUs.
        const transient: mtl.StorageMode = if (self.is_apple_gpu) .memoryless else .private;
        const Want = struct { slot: *?id, want: bool, w: u32, h: u32, format: mtl.PixelFormat, usage: NSUInteger, storage: mtl.StorageMode, samples: NSUInteger };
        const n: NSUInteger = plan.samples;
        const wants = [_]Want{
            .{ .slot = &t.color_msaa, .want = msaa, .w = w, .h = h, .format = hdr_format, .usage = U.render_target, .storage = transient, .samples = n },
            .{ .slot = &t.depth, .want = true, .w = w, .h = h, .format = depth_format, .usage = if (msaa) U.render_target else rt_read, .storage = if (msaa) transient else .private, .samples = n },
            .{ .slot = &t.hdr, .want = true, .w = w, .h = h, .format = hdr_format, .usage = rt_read, .storage = .private, .samples = 1 },
            .{ .slot = &t.depth_resolve, .want = msaa and ssao, .w = w, .h = h, .format = depth_format, .usage = rt_read, .storage = .private, .samples = 1 },
            .{ .slot = &t.shadow, .want = plan.shadowsEnabled(), .w = plan.shadow_size, .h = plan.shadow_size, .format = depth_format, .usage = rt_read, .storage = .private, .samples = 1 },
            .{ .slot = &t.ao_a, .want = ssao, .w = hw, .h = hh, .format = ao_format, .usage = rt_read, .storage = .private, .samples = 1 },
            .{ .slot = &t.ao_b, .want = ssao, .w = hw, .h = hh, .format = ao_format, .usage = rt_read, .storage = .private, .samples = 1 },
            .{ .slot = &t.blur_a, .want = plan.tiltShift() != null, .w = hw, .h = hh, .format = hdr_format, .usage = rt_read, .storage = .private, .samples = 1 },
            .{ .slot = &t.blur_b, .want = plan.tiltShift() != null, .w = hw, .h = hh, .format = hdr_format, .usage = rt_read, .storage = .private, .samples = 1 },
            .{ .slot = &t.ldr, .want = true, .w = w, .h = h, .format = ldr_format, .usage = rt_read, .storage = .private, .samples = 1 },
            .{ .slot = &t.ldr2, .want = plan.post.fxaa, .w = w, .h = h, .format = ldr_format, .usage = rt_read, .storage = .private, .samples = 1 },
        };
        for (wants) |want| {
            if (want.slot.*) |tex| {
                if (!want.want or mtl.Texture.width(tex) != want.w or mtl.Texture.height(tex) != want.h) {
                    if (t.final == tex) t.final = null;
                    tex.release();
                    want.slot.* = null;
                }
            }
            if (want.want and want.slot.* == null) {
                want.slot.* = try self.newTexture(want.w, want.h, want.format, want.usage, want.storage, want.samples, 1);
                if (want.slot == &t.shadow) t.shadow_hash = 0;
            }
        }
    }

    fn newTexture(self: *Three, w: u32, h: u32, format: mtl.PixelFormat, usage: NSUInteger, storage: mtl.StorageMode, samples: NSUInteger, levels: NSUInteger) !id {
        const desc = mtl.TextureDescriptor.new(.{
            .width = w,
            .height = h,
            .format = format,
            .usage = usage,
            .storage = storage,
            .texture_type = if (samples > 1) .@"2d_multisample" else .@"2d",
            .sample_count = samples,
            .mip_levels = levels,
        }) orelse return error.ResourceCreationFailed;
        defer desc.release();
        return mtl.Device.newTexture(self.device, desc) orelse error.ResourceCreationFailed;
    }

    fn pipeline(self: *Three, label: [:0]const u8, vert: id, frag: id, color: mtl.PixelFormat, depth: mtl.PixelFormat, samples: NSUInteger, blend: ?mtl.Blend) !id {
        const desc = mtl.RenderPipelineDescriptor.new() orelse return error.PipelineCreationFailed;
        defer desc.release();
        mtl.RenderPipelineDescriptor.setLabel(desc, label);
        mtl.RenderPipelineDescriptor.setVertexFunction(desc, vert);
        mtl.RenderPipelineDescriptor.setFragmentFunction(desc, frag);
        if (samples > 1) mtl.RenderPipelineDescriptor.setRasterSampleCount(desc, samples);
        if (color != .invalid) mtl.RenderPipelineDescriptor.setColorAttachment0(desc, color, blend);
        if (depth != .invalid) mtl.RenderPipelineDescriptor.setDepthAttachmentPixelFormat(desc, depth);
        var err: ?id = null;
        return mtl.Device.newRenderPipelineState(self.device, desc, &err) orelse {
            log.err("3D pipeline {s} failed: {s}", .{ label, objc.errorDescription(err) });
            return error.PipelineCreationFailed;
        };
    }
};

fn depthState(device: id, compare: mtl.CompareFunction, write: bool) !id {
    const desc = mtl.DepthStencilDescriptor.new(compare, write) orelse return error.ResourceCreationFailed;
    defer desc.release();
    return mtl.Device.newDepthStencilState(device, desc) orelse error.ResourceCreationFailed;
}

fn sampler(device: id, o: mtl.SamplerDescriptor.Options) !id {
    const desc = mtl.SamplerDescriptor.new(o) orelse return error.ResourceCreationFailed;
    defer desc.release();
    return mtl.Device.newSamplerState(device, desc) orelse error.ResourceCreationFailed;
}

fn storageOptions(unified_memory: bool) NSUInteger {
    return if (unified_memory) mtl.ResourceOptions.storage_mode_shared else mtl.ResourceOptions.storage_mode_managed;
}

fn beginPass(cb: id, pass: id, w: u32, h: u32) !id {
    const enc = mtl.CommandBuffer.renderCommandEncoder(cb, pass) orelse return error.CommandBufferFailed;
    mtl.RenderEncoder.setViewport(enc, .{ .originX = 0, .originY = 0, .width = @floatFromInt(w), .height = @floatFromInt(h), .znear = 0, .zfar = 1 });
    return enc;
}
