//! zpui.three on Vulkan: persistent mesh/texture mirrors of a `Gfx3D` store,
//! per-viewport offscreen targets, and the passes that fill them before the
//! UI pass:
//!
//!   shadow   D32 shadow map (light ortho camera, standard Z)
//!   main     RGBA16F color (+4x MSAA, resolved) + D32 depth (reverse-Z);
//!            opaque draws, inverted-hull outlines, then blended draws
//!   ssao     half-res R8 from the resolved depth, blurred
//!   dof      half-res gaussian of the HDR image (tilt-shift)
//!   resolve  AO, tilt-shift mix, exposure, tonemap, grade -> RGBA8 premultiplied sRGB
//!   fxaa     optional, RGBA8 -> RGBA8
//!
//! The UI pass composites the final RGBA8 image in draw order (`composite`).
//! Viewports whose plan hash is unchanged skip every pass and re-composite the
//! cached image. Vertices are pulled through buffer device addresses (no
//! vertex-input state), like the 2D pipelines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vk = @import("vk.zig");
const c = vk.c;
const Renderer = @import("Renderer.zig");
const shaders = @import("vulkan_shaders");
const scene_mod = @import("../../scene.zig");
const three = @import("../../three/three.zig");
const gpu = three.gpu;
const Plan = three.plan.Plan;
const PlanDraw = three.plan.Draw;
const Gfx3D = three.Gfx3D;

const log = std.log.scoped(.three);

const hdr_format = c.VK_FORMAT_R16G16B16A16_SFLOAT;
const depth_format = c.VK_FORMAT_D32_SFLOAT;
const ao_format = c.VK_FORMAT_R8_UNORM;
const ldr_format = c.VK_FORMAT_R8G8B8A8_UNORM;
const frames_in_flight = Renderer.frames_in_flight;
/// Targets unused for this many frames are released.
const target_idle_frames = 120;
const queries_per_frame = 64;
const max_timed_viewports = queries_per_frame / 4;

/// Mesh pipelines' push constants; mirrors `MeshPush` in three.glsl.
const MeshPush = extern struct {
    positions: u64,
    normals: u64,
    uvs: u64,
    colors: u64,
    ids: u64,
    instances: u64,
    frame: u64,
    draw: u64,
};

/// Post pipelines' push constants; mirrors `PostParams` in post.glsl.
const PostPush = extern struct {
    params: gpu.PostParams,
    frame: u64 = 0,
};

const GpuMesh = struct {
    generation: u32 = 0,
    buffer: vk.Buffer = .{},
    positions: u64 = 0,
    normals: u64 = 0,
    uvs: u64 = 0,
    colors: u64 = 0,
    ids: u64 = 0,
    index_offset: u64 = 0,
};

const GpuTexture = struct {
    generation: u32 = 0,
    image: vk.Image = .{},
    sampler: c.VkSampler = null,
};

const Garbage = union(enum) { buffer: vk.Buffer, image: vk.Image };
const Retired = struct { frame: u64, item: Garbage };

const Samples = enum(u2) { one, two, four };

const MeshPipelines = struct {
    @"opaque": c.VkPipeline = null,
    blend: c.VkPipeline = null,
    outline: c.VkPipeline = null,
};

/// One viewport's offscreen images and its cached result.
const Target = struct {
    scene: *const three.Scene3D,
    /// Occurrence of `scene` within the frame (a scene shown twice gets two targets).
    occurrence: u32,
    last_used: u64 = 0,
    plan: Plan,
    /// Hash of the plan last rendered into `final` (0 = never rendered).
    rendered_hash: u64 = 0,
    /// `plan.shadow_hash` of the map in `shadow` (0 = stale).
    shadow_hash: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    samples: u32 = 0,
    color_msaa: vk.Image = .{},
    depth: vk.Image = .{},
    hdr: vk.Image = .{},
    depth_resolve: vk.Image = .{},
    shadow: vk.Image = .{},
    ao_a: vk.Image = .{},
    ao_b: vk.Image = .{},
    blur_a: vk.Image = .{},
    blur_b: vk.Image = .{},
    ldr: vk.Image = .{},
    ldr2: vk.Image = .{},
    /// The image the UI pass composites (`ldr` or `ldr2`).
    final: ?*vk.Image = null,
    stats: three.Scene3D.Stats = .{},

    fn images(t: *Target) [11]*vk.Image {
        return .{ &t.color_msaa, &t.depth, &t.hdr, &t.depth_resolve, &t.shadow, &t.ao_a, &t.ao_b, &t.blur_a, &t.blur_b, &t.ldr, &t.ldr2 };
    }
};

const FrameSlot = struct {
    pool: c.VkDescriptorPool = null,
    sets: std.ArrayList(SetEntry) = .empty,
    queries: c.VkQueryPool = null,
    /// Targets timed in this slot's last submission, with their first query index.
    timed: std.ArrayList(struct { target: *Target, first: u32 }) = .empty,
    query_count: u32 = 0,

    const SetEntry = struct { key: [4]usize, set: c.VkDescriptorSet };
};

pub const Three = struct {
    gpa: Allocator,
    gfx: ?*Gfx3D = null,
    meshes: std.ArrayList(GpuMesh) = .empty,
    textures: std.ArrayList(GpuTexture) = .empty,
    retired: std.ArrayList(Retired) = .empty,
    targets: std.ArrayList(*Target) = .empty,
    /// Per `scene.viewports3d` item this frame: its target (null if not rendered).
    frame_targets: std.ArrayList(?*Target) = .empty,
    frame_number: u64 = 0,
    slot_index: usize = 0,
    slots: [frames_in_flight]FrameSlot = @splat(.{}),

    mesh_set_layout: c.VkDescriptorSetLayout = null,
    post_set_layout: c.VkDescriptorSetLayout = null,
    mesh_layout: c.VkPipelineLayout = null,
    post_layout: c.VkPipelineLayout = null,
    mesh_pipelines: [3]MeshPipelines = .{ .{}, .{}, .{} },
    two_samples: bool = false,
    shadow_pipeline: c.VkPipeline = null,
    ssao_pipeline: c.VkPipeline = null,
    blur_ao_pipeline: c.VkPipeline = null,
    blur_hdr_pipeline: c.VkPipeline = null,
    resolve_pipeline: c.VkPipeline = null,
    fxaa_pipeline: c.VkPipeline = null,
    composite_pipeline: c.VkPipeline = null,

    samplers: [4]c.VkSampler = @splat(null),
    clamp_sampler: c.VkSampler = null,
    nearest_sampler: c.VkSampler = null,
    shadow_sampler: c.VkSampler = null,
    white: vk.Image = .{},
    dummy_depth: vk.Image = .{},
    dummy_buffer: vk.Buffer = .{},

    max_samples: u32 = 1,
    timestamp_period: f32 = 0,
    initialized: bool = false,

    pub fn init(gpa: Allocator) Three {
        return .{ .gpa = gpa };
    }

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// Create layouts, pipelines, samplers and placeholder resources.
    pub fn create(self: *Three, r: *Renderer) !void {
        const dev = r.device.handle;
        const l = r.device.limits;
        const counts = l.framebufferColorSampleCounts & l.framebufferDepthSampleCounts;
        self.max_samples = if (counts & c.VK_SAMPLE_COUNT_4_BIT != 0) 4 else 1;
        self.two_samples = counts & c.VK_SAMPLE_COUNT_2_BIT != 0;

        var qcount: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(r.device.physical, &qcount, null);
        var qprops: [16]c.VkQueueFamilyProperties = undefined;
        qcount = @min(qcount, qprops.len);
        c.vkGetPhysicalDeviceQueueFamilyProperties(r.device.physical, &qcount, &qprops);
        if (r.device.queue_family < qcount and qprops[r.device.queue_family].timestampValidBits > 0 and l.timestampPeriod > 0)
            self.timestamp_period = l.timestampPeriod;

        // Descriptor layouts.
        const mesh_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = gpu.Binding.shadow_map, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            .{ .binding = gpu.Binding.base_texture, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            .{ .binding = gpu.Binding.palette, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        };
        try vk.check(c.vkCreateDescriptorSetLayout(dev, &.{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = mesh_bindings.len, .pBindings = &mesh_bindings }, null, &self.mesh_set_layout));
        const post_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = gpu.Binding.post_tex0, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            .{ .binding = gpu.Binding.post_tex1, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
            .{ .binding = gpu.Binding.post_tex2, .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT },
        };
        try vk.check(c.vkCreateDescriptorSetLayout(dev, &.{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = post_bindings.len, .pBindings = &post_bindings }, null, &self.post_set_layout));
        const stages = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
        const mesh_range: c.VkPushConstantRange = .{ .stageFlags = stages, .offset = 0, .size = @sizeOf(MeshPush) };
        try vk.check(c.vkCreatePipelineLayout(dev, &.{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &self.mesh_set_layout, .pushConstantRangeCount = 1, .pPushConstantRanges = &mesh_range }, null, &self.mesh_layout));
        const post_range: c.VkPushConstantRange = .{ .stageFlags = stages, .offset = 0, .size = @sizeOf(PostPush) };
        try vk.check(c.vkCreatePipelineLayout(dev, &.{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &self.post_set_layout, .pushConstantRangeCount = 1, .pPushConstantRanges = &post_range }, null, &self.post_layout));

        // Pipelines.
        for ([_]Samples{ .one, .two, .four }) |s| {
            const n = sampleBits(s);
            if (s == .four and self.max_samples < 4) continue;
            if (s == .two and !self.two_samples) continue;
            const p = &self.mesh_pipelines[@intFromEnum(s)];
            p.@"opaque" = try self.pipeline(r, .{ .vert = &shaders.three_mesh_vert, .frag = &shaders.three_mesh_frag, .layout = self.mesh_layout, .color = hdr_format, .depth = .reverse, .samples = n, .mesh_state = true });
            p.blend = try self.pipeline(r, .{ .vert = &shaders.three_mesh_vert, .frag = &shaders.three_mesh_frag, .layout = self.mesh_layout, .color = hdr_format, .depth = .reverse, .samples = n, .blend = .premultiplied, .mesh_state = true });
            p.outline = try self.pipeline(r, .{ .vert = &shaders.three_outline_vert, .frag = &shaders.three_outline_frag, .layout = self.mesh_layout, .color = hdr_format, .depth = .reverse, .samples = n, .mesh_state = true });
        }
        self.shadow_pipeline = try self.pipeline(r, .{ .vert = &shaders.three_shadow_vert, .frag = &shaders.three_shadow_frag, .layout = self.mesh_layout, .color = null, .depth = .standard, .mesh_state = true });
        self.ssao_pipeline = try self.pipeline(r, .{ .vert = &shaders.three_fullscreen_vert, .frag = &shaders.three_ssao_frag, .layout = self.post_layout, .color = ao_format });
        self.blur_ao_pipeline = try self.pipeline(r, .{ .vert = &shaders.three_fullscreen_vert, .frag = &shaders.three_blur_frag, .layout = self.post_layout, .color = ao_format });
        self.blur_hdr_pipeline = try self.pipeline(r, .{ .vert = &shaders.three_fullscreen_vert, .frag = &shaders.three_blur_frag, .layout = self.post_layout, .color = hdr_format });
        self.resolve_pipeline = try self.pipeline(r, .{ .vert = &shaders.three_fullscreen_vert, .frag = &shaders.three_resolve_frag, .layout = self.post_layout, .color = ldr_format });
        self.fxaa_pipeline = try self.pipeline(r, .{ .vert = &shaders.three_fullscreen_vert, .frag = &shaders.three_fxaa_frag, .layout = self.post_layout, .color = ldr_format });
        self.composite_pipeline = try self.pipeline(r, .{ .vert = &shaders.three_composite_vert, .frag = &shaders.three_composite_frag, .layout = self.post_layout, .color = r.color_format, .blend = .premultiplied });

        // Samplers: [filter][wrap] for textures, plus post/shadow samplers.
        for (0..2) |fi| for (0..2) |wi| {
            const filter: c.VkFilter = if (fi == 0) c.VK_FILTER_LINEAR else c.VK_FILTER_NEAREST;
            const mode: c.VkSamplerAddressMode = if (wi == 0) c.VK_SAMPLER_ADDRESS_MODE_REPEAT else c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
            self.samplers[fi * 2 + wi] = try createSampler(dev, filter, mode, if (fi == 0) c.VK_SAMPLER_MIPMAP_MODE_LINEAR else c.VK_SAMPLER_MIPMAP_MODE_NEAREST, 16, false);
        };
        self.clamp_sampler = try createSampler(dev, c.VK_FILTER_LINEAR, c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, c.VK_SAMPLER_MIPMAP_MODE_NEAREST, 0, false);
        self.nearest_sampler = try createSampler(dev, c.VK_FILTER_NEAREST, c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, c.VK_SAMPLER_MIPMAP_MODE_NEAREST, 0, false);
        self.shadow_sampler = try createSampler(dev, c.VK_FILTER_LINEAR, c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE, c.VK_SAMPLER_MIPMAP_MODE_NEAREST, 0, true);

        // Per-frame descriptor pools and timestamp query pools.
        for (&self.slots) |*slot| {
            const sizes = [_]c.VkDescriptorPoolSize{.{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 3 * 1024 }};
            try vk.check(c.vkCreateDescriptorPool(dev, &.{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1024, .poolSizeCount = sizes.len, .pPoolSizes = &sizes }, null, &slot.pool));
            if (self.timestamp_period > 0) {
                try vk.check(c.vkCreateQueryPool(dev, &.{ .sType = c.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = c.VK_QUERY_TYPE_TIMESTAMP, .queryCount = queries_per_frame }, null, &slot.queries));
            }
        }

        // Placeholders bound wherever a draw has no texture / no shadow map.
        const mp = &r.device.mem_props;
        self.white = try vk.Image.create(dev, mp, .{ .width = 1, .height = 1, .format = c.VK_FORMAT_R8G8B8A8_UNORM, .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT });
        self.dummy_depth = try vk.Image.create(dev, mp, .{ .width = 1, .height = 1, .format = depth_format, .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT, .aspect = c.VK_IMAGE_ASPECT_DEPTH_BIT });
        self.dummy_buffer = try vk.Buffer.create(dev, mp, 256, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        @memset(self.dummy_buffer.mapped.?[0..256], 0);
        self.initialized = true;
    }

    /// Record the one-time clears of the placeholder images (first frame).
    fn initPlaceholders(self: *Three, cmd: c.VkCommandBuffer) void {
        if (self.white.layout != c.VK_IMAGE_LAYOUT_UNDEFINED) return;
        self.white.transition(cmd, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, true);
        const one: c.VkClearColorValue = .{ .float32 = .{ 1, 1, 1, 1 } };
        c.vkCmdClearColorImage(cmd, self.white.handle, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &one, 1, &vk.color_range);
        self.white.transition(cmd, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);
        self.dummy_depth.transition(cmd, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, true);
        var range = vk.color_range;
        range.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
        const depth_one: c.VkClearDepthStencilValue = .{ .depth = 1, .stencil = 0 };
        c.vkCmdClearDepthStencilImage(cmd, self.dummy_depth.handle, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &depth_one, 1, &range);
        self.dummy_depth.transition(cmd, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);
    }

    pub fn deinit(self: *Three, dev: c.VkDevice) void {
        if (dev == null) return;
        for (self.meshes.items) |*m| m.buffer.destroy(dev);
        for (self.textures.items) |*t| t.image.destroy(dev);
        for (self.retired.items) |*g| destroyGarbage(dev, &g.item);
        for (self.targets.items) |t| {
            for (t.images()) |img| img.destroy(dev);
            t.plan.deinit();
            self.gpa.destroy(t);
        }
        self.meshes.deinit(self.gpa);
        self.textures.deinit(self.gpa);
        self.retired.deinit(self.gpa);
        self.targets.deinit(self.gpa);
        self.frame_targets.deinit(self.gpa);
        for (&self.slots) |*slot| {
            if (slot.pool != null) c.vkDestroyDescriptorPool(dev, slot.pool, null);
            if (slot.queries != null) c.vkDestroyQueryPool(dev, slot.queries, null);
            slot.sets.deinit(self.gpa);
            slot.timed.deinit(self.gpa);
        }
        for (self.allPipelines()) |p| if (p != null) c.vkDestroyPipeline(dev, p, null);
        for (self.samplers) |s| if (s != null) c.vkDestroySampler(dev, s, null);
        for ([_]c.VkSampler{ self.clamp_sampler, self.nearest_sampler, self.shadow_sampler }) |s| if (s != null) c.vkDestroySampler(dev, s, null);
        self.white.destroy(dev);
        self.dummy_depth.destroy(dev);
        self.dummy_buffer.destroy(dev);
        if (self.mesh_layout != null) c.vkDestroyPipelineLayout(dev, self.mesh_layout, null);
        if (self.post_layout != null) c.vkDestroyPipelineLayout(dev, self.post_layout, null);
        if (self.mesh_set_layout != null) c.vkDestroyDescriptorSetLayout(dev, self.mesh_set_layout, null);
        if (self.post_set_layout != null) c.vkDestroyDescriptorSetLayout(dev, self.post_set_layout, null);
        self.* = undefined;
    }

    fn allPipelines(self: *const Three) [16]c.VkPipeline {
        const a = self.mesh_pipelines[0];
        const b = self.mesh_pipelines[1];
        const d = self.mesh_pipelines[2];
        return .{ a.@"opaque", a.blend, a.outline, b.@"opaque", b.blend, b.outline, d.@"opaque", d.blend, d.outline, self.shadow_pipeline, self.ssao_pipeline, self.blur_ao_pipeline, self.blur_hdr_pipeline, self.resolve_pipeline, self.fxaa_pipeline, self.composite_pipeline };
    }

    // -----------------------------------------------------------------------
    // Per frame
    // -----------------------------------------------------------------------

    /// After the frame's fence wait: collect garbage and last timings, plan
    /// every viewport. Returns the host bytes the 3D passes will need.
    pub fn beginFrame(self: *Three, r: *Renderer, scene: *const scene_mod.Scene) !usize {
        self.frame_number += 1;
        self.slot_index = r.frame_index;
        const dev = r.device.handle;
        const slot = &self.slots[self.slot_index];

        // Garbage whose last use was at least `frames_in_flight` frames ago.
        var i: usize = 0;
        while (i < self.retired.items.len) {
            if (self.retired.items[i].frame + frames_in_flight <= self.frame_number) {
                destroyGarbage(dev, &self.retired.items[i].item);
                _ = self.retired.swapRemove(i);
            } else i += 1;
        }
        try vk.check(c.vkResetDescriptorPool(dev, slot.pool, 0));
        slot.sets.clearRetainingCapacity();
        self.collectTimings(dev, slot);

        // Plan each viewport (reusing targets keyed by scene + occurrence).
        self.frame_targets.clearRetainingCapacity();
        var total: usize = 0;
        for (scene.viewports3d.items, 0..) |v, vi| {
            const s3 = v.scene3d;
            var occurrence: u32 = 0;
            for (scene.viewports3d.items[0..vi]) |prev| {
                if (prev.scene3d == s3) occurrence += 1;
            }
            const w: u32 = @intFromFloat(std.math.clamp(@ceil(v.bounds.size.width), 1, @as(f32, @floatFromInt(r.device.limits.maxImageDimension2D))));
            const h: u32 = @intFromFloat(std.math.clamp(@ceil(v.bounds.size.height), 1, @as(f32, @floatFromInt(r.device.limits.maxImageDimension2D))));
            const t = try self.targetFor(s3, occurrence);
            t.last_used = self.frame_number;
            try self.bindStore(r, s3.gfx);
            try three.plan.build(&t.plan, s3, w, h, .{ .max_samples = self.max_samples, .two_samples = self.two_samples, .max_texture_size = r.device.limits.maxImageDimension2D });
            // Surface last frame's statistics to the app.
            v.scene3d.stats = t.stats;
            v.scene3d.stats.cached = t.plan.hash == t.rendered_hash and t.final != null;
            v.scene3d.updateDynamicResolution();
            try self.frame_targets.append(self.gpa, t);
            if (t.plan.hash != t.rendered_hash or t.final == null) total += hostBytes(&t.plan);
        }

        // Release targets nobody showed for a while.
        i = 0;
        while (i < self.targets.items.len) {
            const t = self.targets.items[i];
            if (t.last_used + target_idle_frames < self.frame_number) {
                for (t.images()) |img| self.retire(.{ .image = img.* });
                t.plan.deinit();
                self.gpa.destroy(t);
                _ = self.targets.swapRemove(i);
            } else i += 1;
        }
        return total;
    }

    fn targetFor(self: *Three, s3: *const three.Scene3D, occurrence: u32) !*Target {
        for (self.targets.items) |t| if (t.scene == s3 and t.occurrence == occurrence) return t;
        const t = try self.gpa.create(Target);
        errdefer self.gpa.destroy(t);
        t.* = .{ .scene = s3, .occurrence = occurrence, .plan = .init(self.gpa) };
        try self.targets.append(self.gpa, t);
        return t;
    }

    fn hostBytes(plan: *const Plan) usize {
        const a = Renderer.instance_align;
        var n: usize = @sizeOf(gpu.FrameData) + a;
        n += plan.instances.items.len * @sizeOf(three.Instance) + a;
        const draws = plan.shadow.items.len + plan.@"opaque".items.len + plan.blend.items.len + plan.outlines.items.len;
        n += draws * (@sizeOf(gpu.DrawData) + a);
        return n;
    }

    fn retire(self: *Three, item: Garbage) void {
        switch (item) {
            .buffer => |b| if (b.handle == null) return,
            .image => |img| if (img.handle == null) return,
        }
        self.retired.append(self.gpa, .{ .frame = self.frame_number, .item = item }) catch {
            // Out of memory: wait and free now rather than leak.
            log.warn("retire list full; freeing synchronously", .{});
        };
    }

    /// A renderer mirrors one store; switching stores drops the old mirror.
    fn bindStore(self: *Three, r: *Renderer, gfx: *Gfx3D) !void {
        if (self.gfx == gfx) return;
        if (self.gfx != null) {
            log.warn("a renderer can mirror one Gfx3D store; switching stores re-uploads everything", .{});
            r.device.waitIdle();
            for (self.meshes.items) |*m| m.buffer.destroy(r.device.handle);
            for (self.textures.items) |*t| t.image.destroy(r.device.handle);
            self.meshes.clearRetainingCapacity();
            self.textures.clearRetainingCapacity();
        }
        self.gfx = gfx;
        // Everything live in the new store needs uploading.
        gfx.pending_meshes.clearRetainingCapacity();
        gfx.pending_textures.clearRetainingCapacity();
        for (gfx.meshes.items, 0..) |m, s| if (m.live) {
            if (m.cpu == null) {
                log.err("mesh slot {d} was uploaded by another renderer and has no CPU copy; it will not draw", .{s});
                continue;
            }
            try gfx.pending_meshes.append(gfx.gpa, @intCast(s));
        };
        for (gfx.textures.items, 0..) |t, s| if (t.live) {
            if (t.cpu == null) continue;
            try gfx.pending_textures.append(gfx.gpa, @intCast(s));
        };
    }

    /// Upload pending meshes/textures and free released ones. Records copies into `cmd`.
    pub fn upload(self: *Three, r: *Renderer, cmd: c.VkCommandBuffer) !void {
        if (!self.initialized) return;
        self.initPlaceholders(cmd);
        // Timestamps are reset on the GPU (no hostQueryReset feature needed).
        const slot = &self.slots[self.slot_index];
        if (slot.queries != null) c.vkCmdResetQueryPool(cmd, slot.queries, 0, queries_per_frame);
        const gfx = self.gfx orelse return;
        const dev = r.device.handle;
        const mp = &r.device.mem_props;

        for (gfx.released.items) |rel| switch (rel) {
            .mesh => |s| if (s < self.meshes.items.len) {
                self.retire(.{ .buffer = self.meshes.items[s].buffer });
                self.meshes.items[s] = .{};
            },
            .texture => |s| if (s < self.textures.items.len) {
                self.retire(.{ .image = self.textures.items[s].image });
                self.textures.items[s] = .{};
            },
        };
        gfx.released.clearRetainingCapacity();
        if (gfx.pending_meshes.items.len == 0 and gfx.pending_textures.items.len == 0) return;

        // One staging buffer for this batch, retired with the frame.
        var staging_size: usize = 0;
        for (gfx.pending_meshes.items) |s| staging_size += gfx.meshes.items[s].cpu.?.bytes.len;
        for (gfx.pending_textures.items) |s| staging_size += std.mem.alignForward(usize, gfx.textures.items[s].cpu.?.len, 16);
        var staging = try vk.Buffer.create(dev, mp, @max(staging_size, 16), c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
        errdefer staging.destroy(dev);
        var off: usize = 0;

        while (self.meshes.items.len < gfx.meshes.items.len) try self.meshes.append(self.gpa, .{});
        for (gfx.pending_meshes.items) |s| {
            const m = &gfx.meshes.items[s];
            const data = m.cpu.?;
            const g = &self.meshes.items[s];
            self.retire(.{ .buffer = g.buffer });
            const usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
            const buf = try vk.Buffer.create(dev, mp, data.bytes.len, usage, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
            @memcpy(staging.mapped.?[off..][0..data.bytes.len], data.bytes);
            const region: c.VkBufferCopy = .{ .srcOffset = off, .dstOffset = 0, .size = data.bytes.len };
            c.vkCmdCopyBuffer(cmd, staging.handle, buf.handle, 1, &region);
            const base = @intFromPtr(data.bytes.ptr);
            const addr = struct {
                fn of(b: vk.Buffer, root: usize, slice: anytype, fallback: u64) u64 {
                    if (slice.len == 0) return fallback;
                    return b.address + (@intFromPtr(slice.ptr) - root);
                }
            }.of;
            g.* = .{
                .generation = m.generation,
                .buffer = buf,
                .positions = addr(buf, base, data.positions, self.dummy_buffer.address),
                .normals = addr(buf, base, data.normals, self.dummy_buffer.address),
                .uvs = addr(buf, base, data.uvs, self.dummy_buffer.address),
                .colors = addr(buf, base, data.colors, self.dummy_buffer.address),
                .ids = addr(buf, base, data.ids, self.dummy_buffer.address),
                .index_offset = @intFromPtr(data.indices.ptr) - base,
            };
            off += data.bytes.len;
            gfx.markMeshUploaded(s);
        }

        while (self.textures.items.len < gfx.textures.items.len) try self.textures.append(self.gpa, .{});
        for (gfx.pending_textures.items) |s| {
            const t = &gfx.textures.items[s];
            const bytes = t.cpu.?;
            const g = &self.textures.items[s];
            self.retire(.{ .image = g.image });
            var img = try vk.Image.create(dev, mp, .{
                .width = t.width,
                .height = t.height,
                .format = if (t.format == .rgba8_srgb) c.VK_FORMAT_R8G8B8A8_SRGB else c.VK_FORMAT_R8G8B8A8_UNORM,
                .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                .mip_levels = t.mip_levels,
            });
            @memcpy(staging.mapped.?[off..][0..bytes.len], bytes);
            img.transition(cmd, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, true);
            var level_off: usize = 0;
            for (0..t.mip_levels) |lvl| {
                const sz = t.mipSize(@intCast(lvl));
                const region: c.VkBufferImageCopy = .{
                    .bufferOffset = off + level_off,
                    .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = @intCast(lvl), .baseArrayLayer = 0, .layerCount = 1 },
                    .imageExtent = .{ .width = sz[0], .height = sz[1], .depth = 1 },
                };
                c.vkCmdCopyBufferToImage(cmd, staging.handle, img.handle, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
                level_off += @as(usize, sz[0]) * sz[1] * 4;
            }
            img.transition(cmd, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);
            g.* = .{
                .generation = t.generation,
                .image = img,
                .sampler = self.samplers[@as(usize, @intFromEnum(t.filter)) * 2 + @intFromEnum(t.wrap)],
            };
            off += std.mem.alignForward(usize, bytes.len, 16);
            gfx.markTextureUploaded(s);
        }
        gfx.pending_meshes.clearRetainingCapacity();
        gfx.pending_textures.clearRetainingCapacity();
        // Make the copies visible to vertex pulling, index fetch and sampling.
        const barrier: c.VkMemoryBarrier2 = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
            .srcStageMask = c.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
            .srcAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_2_VERTEX_SHADER_BIT | c.VK_PIPELINE_STAGE_2_INDEX_INPUT_BIT | c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .dstAccessMask = c.VK_ACCESS_2_SHADER_STORAGE_READ_BIT | c.VK_ACCESS_2_INDEX_READ_BIT | c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
        };
        c.vkCmdPipelineBarrier2(cmd, &.{ .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .memoryBarrierCount = 1, .pMemoryBarriers = &barrier });
        self.retire(.{ .buffer = staging });
    }

    // -----------------------------------------------------------------------
    // Rendering
    // -----------------------------------------------------------------------

    /// Render every viewport whose plan changed (before the UI pass).
    pub fn render(self: *Three, rec: *Renderer.Recorder, scene: *const scene_mod.Scene) !void {
        _ = scene;
        const slot = &self.slots[self.slot_index];
        slot.timed.clearRetainingCapacity();
        slot.query_count = 0;
        for (self.frame_targets.items) |maybe| {
            const t = maybe orelse continue;
            if (t.plan.hash == t.rendered_hash and t.final != null) {
                t.stats.cached = true;
                continue;
            }
            try self.renderTarget(rec, t);
            t.rendered_hash = t.plan.hash;
        }
    }

    fn renderTarget(self: *Three, rec: *Renderer.Recorder, t: *Target) !void {
        const r = rec.r;
        const cmd = rec.cmd;
        const plan = &t.plan;
        try self.ensureImages(r, t);
        const slot = &self.slots[self.slot_index];
        const timed = slot.queries != null and slot.timed.items.len < max_timed_viewports;
        var q: u32 = slot.query_count;
        if (timed) {
            try slot.timed.append(self.gpa, .{ .target = t, .first = q });
            slot.query_count += 4;
            c.vkCmdWriteTimestamp2(cmd, c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, slot.queries, q);
            q += 1;
        }

        const frame_addr = rec.push(std.mem.asBytes(&plan.frame));
        const inst_addr = if (plan.instances.items.len > 0) rec.push(std.mem.sliceAsBytes(plan.instances.items)) else self.dummy_buffer.address;

        // ---- shadow --------------------------------------------------------
        // Static light and casters: the map from an earlier frame is still valid.
        const shadow_cached = plan.shadowsEnabled() and t.shadow_hash == plan.shadow_hash;
        if (plan.shadowsEnabled() and !shadow_cached) {
            t.shadow.transition(cmd, c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL, true);
            const depth_att: c.VkRenderingAttachmentInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                .imageView = t.shadow.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
                .clearValue = .{ .depthStencil = .{ .depth = 1, .stencil = 0 } },
            };
            beginRendering(cmd, null, &depth_att, plan.shadow_size, plan.shadow_size);
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.shadow_pipeline);
            c.vkCmdSetDepthBiasEnable(cmd, c.VK_TRUE);
            c.vkCmdSetDepthBias(cmd, 0, 0, 1.0);
            for (plan.shadow.items) |*d| self.drawMesh(rec, d, frame_addr, inst_addr, null, false);
            c.vkCmdEndRendering(cmd);
            t.shadow.transition(cmd, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);
            t.shadow_hash = plan.shadow_hash;
        }
        if (timed) {
            c.vkCmdWriteTimestamp2(cmd, c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, slot.queries, q);
            q += 1;
        }

        // ---- main ----------------------------------------------------------
        const msaa = plan.samples > 1;
        const ssao = plan.ssao() != null;
        t.hdr.transition(cmd, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, true);
        if (msaa) t.color_msaa.transition(cmd, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, true);
        t.depth.transition(cmd, c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL, true);
        if (msaa and ssao) t.depth_resolve.transition(cmd, c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL, true);
        const cl = plan.clear;
        var color_att: c.VkRenderingAttachmentInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = t.hdr.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = .{ .color = .{ .float32 = .{ cl[0] * cl[3], cl[1] * cl[3], cl[2] * cl[3], cl[3] } } },
        };
        if (msaa) {
            color_att.imageView = t.color_msaa.view;
            color_att.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
            color_att.resolveMode = c.VK_RESOLVE_MODE_AVERAGE_BIT;
            color_att.resolveImageView = t.hdr.view;
            color_att.resolveImageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        }
        var depth_att: c.VkRenderingAttachmentInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = t.depth.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = if (ssao and !msaa) c.VK_ATTACHMENT_STORE_OP_STORE else c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .clearValue = .{ .depthStencil = .{ .depth = 0, .stencil = 0 } },
        };
        if (msaa and ssao) {
            depth_att.resolveMode = c.VK_RESOLVE_MODE_SAMPLE_ZERO_BIT;
            depth_att.resolveImageView = t.depth_resolve.view;
            depth_att.resolveImageLayout = c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL;
        }
        beginRendering(cmd, &color_att, &depth_att, plan.width, plan.height);
        const mp = self.mesh_pipelines[@intFromEnum(samplesOf(plan.samples))];
        const shadow_view = if (plan.shadowsEnabled()) t.shadow.view else self.dummy_depth.view;
        if (plan.@"opaque".items.len > 0) {
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, mp.@"opaque");
            for (plan.@"opaque".items) |*d| self.drawMesh(rec, d, frame_addr, inst_addr, shadow_view, true);
        }
        if (plan.outlines.items.len > 0) {
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, mp.outline);
            for (plan.outlines.items) |*d| self.drawMesh(rec, d, frame_addr, inst_addr, null, true);
        }
        if (plan.blend.items.len > 0) {
            c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, mp.blend);
            for (plan.blend.items) |*d| self.drawMesh(rec, d, frame_addr, inst_addr, shadow_view, true);
        }
        c.vkCmdEndRendering(cmd);
        t.hdr.transition(cmd, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);
        if (timed) {
            c.vkCmdWriteTimestamp2(cmd, c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, slot.queries, q);
            q += 1;
        }

        // ---- post ----------------------------------------------------------
        const hw = @max(plan.width / 2, 1);
        const hh = @max(plan.height / 2, 1);
        var ao_view = self.white.view;
        var ao_strength: f32 = 0;
        if (plan.ssao()) |cfg| {
            const depth_img = if (msaa) &t.depth_resolve else &t.depth;
            depth_img.transition(cmd, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);
            try self.postPass(rec, self.ssao_pipeline, &t.ao_a, hw, hh, .{ depth_img.view, self.white.view, self.white.view }, self.nearest_sampler, .{
                .p0 = .{ cfg.radius, 0, @floatFromInt(cfg.samples), 0.03 * cfg.radius },
                .p1 = .{ 1 / @as(f32, @floatFromInt(hw)), 1 / @as(f32, @floatFromInt(hh)), 0, 0 },
            }, frame_addr);
            try self.postPass(rec, self.blur_ao_pipeline, &t.ao_b, hw, hh, .{ t.ao_a.view, self.white.view, self.white.view }, self.clamp_sampler, .{
                .p0 = .{ 1, 0, 1.5, 0 },
                .p1 = .{ 1 / @as(f32, @floatFromInt(hw)), 1 / @as(f32, @floatFromInt(hh)), 1, 0 },
            }, 0);
            try self.postPass(rec, self.blur_ao_pipeline, &t.ao_a, hw, hh, .{ t.ao_b.view, self.white.view, self.white.view }, self.clamp_sampler, .{
                .p0 = .{ 0, 1, 1.5, 0 },
                .p1 = .{ 1 / @as(f32, @floatFromInt(hw)), 1 / @as(f32, @floatFromInt(hh)), 1, 0 },
            }, 0);
            ao_view = t.ao_a.view;
            ao_strength = cfg.intensity;
        }
        var blurred_view = t.hdr.view;
        var tilt_on: f32 = 0;
        var tilt: three.TiltShift = .{};
        if (plan.tiltShift()) |cfg| {
            tilt = cfg;
            tilt_on = 1;
            // Half resolution: sigma in half-res texels.
            const sigma = @max(cfg.blur / 2, 0.5);
            const skip = three.plan.tiltSkip(cfg, hh);
            const inv_hh = 1 / @as(f32, @floatFromInt(hh));
            try self.postPass(rec, self.blur_hdr_pipeline, &t.blur_a, hw, hh, .{ t.hdr.view, ao_view, self.white.view }, self.clamp_sampler, .{
                .p0 = .{ 2, 0, sigma, if (ao_strength > 0) 1 else 0 },
                .p1 = .{ 1 / @as(f32, @floatFromInt(plan.width)), 1 / @as(f32, @floatFromInt(plan.height)), 2, ao_strength },
                .p2 = .{ inv_hh, cfg.focus, skip[0], 1 },
            }, 0);
            try self.postPass(rec, self.blur_hdr_pipeline, &t.blur_b, hw, hh, .{ t.blur_a.view, self.white.view, self.white.view }, self.clamp_sampler, .{
                .p0 = .{ 0, 1, sigma, 0 },
                .p1 = .{ 1 / @as(f32, @floatFromInt(hw)), inv_hh, 1, 0 },
                .p2 = .{ inv_hh, cfg.focus, skip[1], 1 },
            }, 0);
            blurred_view = t.blur_b.view;
        }
        const post = plan.post;
        try self.postPass(rec, self.resolve_pipeline, &t.ldr, plan.width, plan.height, .{ t.hdr.view, ao_view, blurred_view }, self.clamp_sampler, .{
            .p0 = .{ post.exposure, @floatFromInt(@intFromEnum(post.tonemap)), post.saturation, post.vignette },
            .p1 = .{ ao_strength, tilt.focus, tilt.range, tilt_on },
            .p2 = .{ 1 / @as(f32, @floatFromInt(plan.width)), 1 / @as(f32, @floatFromInt(plan.height)), 0, 0 },
        }, 0);
        t.final = &t.ldr;
        if (post.fxaa) {
            try self.postPass(rec, self.fxaa_pipeline, &t.ldr2, plan.width, plan.height, .{ t.ldr.view, self.white.view, self.white.view }, self.clamp_sampler, .{
                .p2 = .{ 1 / @as(f32, @floatFromInt(plan.width)), 1 / @as(f32, @floatFromInt(plan.height)), 0, 0 },
            }, 0);
            t.final = &t.ldr2;
        }
        if (timed) c.vkCmdWriteTimestamp2(cmd, c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, slot.queries, q);

        t.stats = .{
            .draws = @intCast(plan.@"opaque".items.len + plan.blend.items.len + plan.outlines.items.len),
            .instances = @intCast(plan.instances.items.len),
            .triangles = plan.triangles,
            .shadow_draws = @intCast(plan.shadow.items.len),
            .cached = false,
            .shadow_cached = shadow_cached,
            .gpu_ms = t.stats.gpu_ms,
            .gpu_shadow_ms = t.stats.gpu_shadow_ms,
            .gpu_main_ms = t.stats.gpu_main_ms,
            .gpu_post_ms = t.stats.gpu_post_ms,
        };
        rec.bound = null;
    }

    fn drawMesh(self: *Three, rec: *Renderer.Recorder, d: *const PlanDraw, frame_addr: u64, inst_addr: u64, shadow_view: ?c.VkImageView, dynamic_state: bool) void {
        const cmd = rec.cmd;
        const m = &self.meshes.items[d.mesh_slot];
        if (m.buffer.handle == null) return;
        if (shadow_view) |sv| {
            const set = self.meshSet(rec.r, sv, d.base_texture, d.palette) catch |err| {
                log.err("descriptor set allocation failed: {t}", .{err});
                return;
            };
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.mesh_layout, 0, 1, &set, 0, null);
        }
        if (dynamic_state) {
            c.vkCmdSetCullMode(cmd, switch (d.cull) {
                .back => c.VK_CULL_MODE_BACK_BIT,
                .front => c.VK_CULL_MODE_FRONT_BIT,
                .none => c.VK_CULL_MODE_NONE,
            });
            c.vkCmdSetDepthWriteEnable(cmd, if (d.depth_write) c.VK_TRUE else c.VK_FALSE);
            c.vkCmdSetDepthBiasEnable(cmd, if (d.depth_bias != 0) c.VK_TRUE else c.VK_FALSE);
            // Reverse-Z: a positive bias moves toward the camera.
            if (d.depth_bias != 0) c.vkCmdSetDepthBias(cmd, d.depth_bias * 64, 0, d.depth_bias);
        } else {
            c.vkCmdSetCullMode(cmd, c.VK_CULL_MODE_NONE);
            c.vkCmdSetDepthWriteEnable(cmd, c.VK_TRUE);
        }
        const pc: MeshPush = .{
            .positions = m.positions,
            .normals = m.normals,
            .uvs = m.uvs,
            .colors = m.colors,
            .ids = m.ids,
            .instances = inst_addr + @as(u64, d.first_instance) * @sizeOf(three.Instance),
            .frame = frame_addr,
            .draw = rec.push(std.mem.asBytes(&d.data)),
        };
        c.vkCmdPushConstants(cmd, self.mesh_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(MeshPush), &pc);
        c.vkCmdBindIndexBuffer(cmd, m.buffer.handle, m.index_offset, c.VK_INDEX_TYPE_UINT32);
        c.vkCmdDrawIndexed(cmd, d.index_count, d.instance_count, d.first_index, 0, 0);
    }

    fn textureView(self: *const Three, slot_plus_one: u32) struct { view: c.VkImageView, sampler: c.VkSampler } {
        if (slot_plus_one > 0 and slot_plus_one - 1 < self.textures.items.len) {
            const t = &self.textures.items[slot_plus_one - 1];
            if (t.image.handle != null) return .{ .view = t.image.view, .sampler = t.sampler };
        }
        return .{ .view = self.white.view, .sampler = self.samplers[0] };
    }

    fn meshSet(self: *Three, r: *Renderer, shadow_view: c.VkImageView, base: u32, palette: u32) !c.VkDescriptorSet {
        const slot = &self.slots[self.slot_index];
        const key: [4]usize = .{ @intFromPtr(shadow_view), base, palette, 1 };
        for (slot.sets.items) |e| if (std.mem.eql(usize, &e.key, &key)) return e.set;
        var set: c.VkDescriptorSet = null;
        try vk.check(c.vkAllocateDescriptorSets(r.device.handle, &.{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = slot.pool, .descriptorSetCount = 1, .pSetLayouts = &self.mesh_set_layout }, &set));
        const b = self.textureView(base);
        const p = self.textureView(palette);
        const infos = [_]c.VkDescriptorImageInfo{
            .{ .sampler = self.shadow_sampler, .imageView = shadow_view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
            .{ .sampler = b.sampler, .imageView = b.view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
            .{ .sampler = self.nearest_sampler, .imageView = p.view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        };
        var writes: [3]c.VkWriteDescriptorSet = undefined;
        for (&writes, 0..) |*w, i| w.* = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = set,
            .dstBinding = @intCast(gpu.Binding.shadow_map + i),
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &infos[i],
        };
        c.vkUpdateDescriptorSets(r.device.handle, writes.len, &writes, 0, null);
        try slot.sets.append(self.gpa, .{ .key = key, .set = set });
        return set;
    }

    fn postSet(self: *Three, r: *Renderer, views: [3]c.VkImageView, sampler: c.VkSampler) !c.VkDescriptorSet {
        const slot = &self.slots[self.slot_index];
        var set: c.VkDescriptorSet = null;
        try vk.check(c.vkAllocateDescriptorSets(r.device.handle, &.{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = slot.pool, .descriptorSetCount = 1, .pSetLayouts = &self.post_set_layout }, &set));
        var infos: [3]c.VkDescriptorImageInfo = undefined;
        var writes: [3]c.VkWriteDescriptorSet = undefined;
        for (0..3) |i| {
            infos[i] = .{ .sampler = sampler, .imageView = views[i], .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
            writes[i] = .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = set,
                .dstBinding = @intCast(gpu.Binding.post_tex0 + i),
                .descriptorCount = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &infos[i],
            };
        }
        c.vkUpdateDescriptorSets(r.device.handle, writes.len, &writes, 0, null);
        return set;
    }

    /// One fullscreen pass into `dst` (`w` x `h`).
    fn postPass(self: *Three, rec: *Renderer.Recorder, pipeline_handle: c.VkPipeline, dst: *vk.Image, w: u32, h: u32, views: [3]c.VkImageView, sampler: c.VkSampler, params: gpu.PostParams, frame_addr: u64) !void {
        const cmd = rec.cmd;
        const set = try self.postSet(rec.r, views, sampler);
        dst.transition(cmd, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, true);
        const att: c.VkRenderingAttachmentInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = dst.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        };
        beginRendering(cmd, &att, null, w, h);
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline_handle);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.post_layout, 0, 1, &set, 0, null);
        const pc: PostPush = .{ .params = params, .frame = if (frame_addr != 0) frame_addr else self.dummy_buffer.address };
        c.vkCmdPushConstants(cmd, self.post_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PostPush), &pc);
        c.vkCmdDraw(cmd, 3, 1, 0, 0);
        c.vkCmdEndRendering(cmd);
        dst.transition(cmd, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);
    }

    /// Draw viewport `index` of the scene inside the UI pass.
    pub fn composite(self: *Three, rec: *Renderer.Recorder, v: *const scene_mod.Viewport3D, index: usize) !void {
        if (index >= self.frame_targets.items.len) return;
        const t = self.frame_targets.items[index] orelse return;
        const final = t.final orelse return;
        const set = try self.postSet(rec.r, .{ final.view, self.white.view, self.white.view }, self.clamp_sampler);
        const vs = rec.viewportSize();
        const m = v.content_mask.bounds;
        const pc: PostPush = .{ .params = .{
            .p0 = .{ v.bounds.origin.x, v.bounds.origin.y, v.bounds.size.width, v.bounds.size.height },
            .p1 = .{ m.origin.x, m.origin.y, m.size.width, m.size.height },
            .p2 = .{ v.corner_radii.top_left, v.corner_radii.top_right, v.corner_radii.bottom_right, v.corner_radii.bottom_left },
            .p3 = .{ vs[0], vs[1], v.opacity, sharpenOf(&t.plan) },
        }, .frame = self.dummy_buffer.address };
        rec.bind(self.composite_pipeline);
        c.vkCmdBindDescriptorSets(rec.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.post_layout, 0, 1, &set, 0, null);
        c.vkCmdPushConstants(rec.cmd, self.post_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PostPush), &pc);
        c.vkCmdDraw(rec.cmd, 6, 1, 0, 0);
    }

    // -----------------------------------------------------------------------
    // Resources
    // -----------------------------------------------------------------------

    fn ensureImages(self: *Three, r: *Renderer, t: *Target) !void {
        const dev = r.device.handle;
        const mp = &r.device.mem_props;
        const plan = &t.plan;
        const w = plan.width;
        const h = plan.height;
        const hw = @max(w / 2, 1);
        const hh = @max(h / 2, 1);
        const msaa = plan.samples > 1;
        const ssao = plan.ssao() != null;
        const n = sampleBits(samplesOf(plan.samples));
        if (t.width != w or t.height != h or t.samples != plan.samples) {
            for (t.images()) |img| {
                if (img == &t.shadow) continue;
                self.retire(.{ .image = img.* });
                img.* = .{};
            }
            t.width = w;
            t.height = h;
            t.samples = plan.samples;
            t.final = null;
        }
        const Want = struct { img: *vk.Image, want: bool, w: u32, h: u32, format: c.VkFormat, usage: c.VkImageUsageFlags, samples: c.VkSampleCountFlagBits, aspect: c.VkImageAspectFlags };
        const color_att: c.VkImageUsageFlags = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        const sampled: c.VkImageUsageFlags = c.VK_IMAGE_USAGE_SAMPLED_BIT;
        const transient: c.VkImageUsageFlags = c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT;
        const depth_att: c.VkImageUsageFlags = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
        const color_aspect: c.VkImageAspectFlags = c.VK_IMAGE_ASPECT_COLOR_BIT;
        const depth_aspect: c.VkImageAspectFlags = c.VK_IMAGE_ASPECT_DEPTH_BIT;
        const wants = [_]Want{
            .{ .img = &t.color_msaa, .want = msaa, .w = w, .h = h, .format = hdr_format, .usage = color_att | transient, .samples = n, .aspect = color_aspect },
            // Single-sampled: SSAO samples it directly. MSAA: resolved into `depth_resolve` instead.
            .{ .img = &t.depth, .want = true, .w = w, .h = h, .format = depth_format, .usage = depth_att | (if (msaa) transient else sampled), .samples = n, .aspect = depth_aspect },
            .{ .img = &t.hdr, .want = true, .w = w, .h = h, .format = hdr_format, .usage = color_att | sampled, .samples = c.VK_SAMPLE_COUNT_1_BIT, .aspect = color_aspect },
            .{ .img = &t.depth_resolve, .want = msaa and ssao, .w = w, .h = h, .format = depth_format, .usage = depth_att | sampled, .samples = c.VK_SAMPLE_COUNT_1_BIT, .aspect = depth_aspect },
            .{ .img = &t.shadow, .want = plan.shadowsEnabled(), .w = plan.shadow_size, .h = plan.shadow_size, .format = depth_format, .usage = depth_att | sampled, .samples = c.VK_SAMPLE_COUNT_1_BIT, .aspect = depth_aspect },
            .{ .img = &t.ao_a, .want = ssao, .w = hw, .h = hh, .format = ao_format, .usage = color_att | sampled, .samples = c.VK_SAMPLE_COUNT_1_BIT, .aspect = color_aspect },
            .{ .img = &t.ao_b, .want = ssao, .w = hw, .h = hh, .format = ao_format, .usage = color_att | sampled, .samples = c.VK_SAMPLE_COUNT_1_BIT, .aspect = color_aspect },
            .{ .img = &t.blur_a, .want = plan.tiltShift() != null, .w = hw, .h = hh, .format = hdr_format, .usage = color_att | sampled, .samples = c.VK_SAMPLE_COUNT_1_BIT, .aspect = color_aspect },
            .{ .img = &t.blur_b, .want = plan.tiltShift() != null, .w = hw, .h = hh, .format = hdr_format, .usage = color_att | sampled, .samples = c.VK_SAMPLE_COUNT_1_BIT, .aspect = color_aspect },
            .{ .img = &t.ldr, .want = true, .w = w, .h = h, .format = ldr_format, .usage = color_att | sampled, .samples = c.VK_SAMPLE_COUNT_1_BIT, .aspect = color_aspect },
            .{ .img = &t.ldr2, .want = plan.post.fxaa, .w = w, .h = h, .format = ldr_format, .usage = color_att | sampled, .samples = c.VK_SAMPLE_COUNT_1_BIT, .aspect = color_aspect },
        };
        for (wants) |want| {
            const img = want.img;
            if (img.handle != null and (!want.want or img.width != want.w or img.height != want.h)) {
                if (img == t.final) t.final = null;
                self.retire(.{ .image = img.* });
                img.* = .{};
            }
            if (want.want and img.handle == null) {
                img.* = try vk.Image.create(dev, mp, .{ .width = want.w, .height = want.h, .format = want.format, .usage = want.usage, .samples = want.samples, .aspect = want.aspect });
                if (img == &t.shadow) t.shadow_hash = 0;
            }
        }
    }

    fn collectTimings(self: *Three, dev: c.VkDevice, slot: *FrameSlot) void {
        if (slot.queries == null) return;
        if (slot.query_count > 0) {
            var results: [queries_per_frame]u64 = undefined;
            const ok = c.vkGetQueryPoolResults(dev, slot.queries, 0, slot.query_count, slot.query_count * 8, &results, 8, c.VK_QUERY_RESULT_64_BIT);
            if (ok == c.VK_SUCCESS) {
                const ms = self.timestamp_period / 1e6;
                for (slot.timed.items) |e| {
                    // Targets may have been released since; only update live ones.
                    var live = false;
                    for (self.targets.items) |t| if (t == e.target) {
                        live = true;
                    };
                    if (!live) continue;
                    const q = results[e.first..][0..4];
                    e.target.stats.gpu_shadow_ms = @as(f32, @floatFromInt(q[1] -% q[0])) * ms;
                    e.target.stats.gpu_main_ms = @as(f32, @floatFromInt(q[2] -% q[1])) * ms;
                    e.target.stats.gpu_post_ms = @as(f32, @floatFromInt(q[3] -% q[2])) * ms;
                    e.target.stats.gpu_ms = @as(f32, @floatFromInt(q[3] -% q[0])) * ms;
                }
            }
        }
        slot.timed.clearRetainingCapacity();
        slot.query_count = 0;
    }

    // -----------------------------------------------------------------------
    // Pipelines
    // -----------------------------------------------------------------------

    const PipelineDesc = struct {
        vert: []const u8,
        frag: []const u8,
        layout: c.VkPipelineLayout,
        /// Null: depth-only.
        color: ?c.VkFormat,
        depth: enum { none, reverse, standard } = .none,
        samples: c.VkSampleCountFlagBits = c.VK_SAMPLE_COUNT_1_BIT,
        blend: enum { none, premultiplied } = .none,
        /// Cull mode, depth write and depth bias are dynamic.
        mesh_state: bool = false,
    };

    fn pipeline(self: *Three, r: *Renderer, desc: PipelineDesc) !c.VkPipeline {
        _ = self;
        const dev = r.device.handle;
        const vs = try shaderModule(dev, desc.vert);
        defer c.vkDestroyShaderModule(dev, vs, null);
        const fs = try shaderModule(dev, desc.frag);
        defer c.vkDestroyShaderModule(dev, fs, null);
        const stages = [_]c.VkPipelineShaderStageCreateInfo{
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
            .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main" },
        };
        const vertex_input: c.VkPipelineVertexInputStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
        const input_assembly: c.VkPipelineInputAssemblyStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
        const viewport_state: c.VkPipelineViewportStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1 };
        const raster: c.VkPipelineRasterizationStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .polygonMode = c.VK_POLYGON_MODE_FILL,
            .cullMode = c.VK_CULL_MODE_NONE,
            .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
            .depthBiasEnable = c.VK_FALSE,
            .lineWidth = 1,
        };
        const multisample: c.VkPipelineMultisampleStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = desc.samples };
        var attachment: c.VkPipelineColorBlendAttachmentState = .{
            .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
            .colorBlendOp = c.VK_BLEND_OP_ADD,
            .alphaBlendOp = c.VK_BLEND_OP_ADD,
            .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        };
        if (desc.blend == .premultiplied) attachment.blendEnable = c.VK_TRUE;
        const blend_state: c.VkPipelineColorBlendStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .attachmentCount = if (desc.color != null) 1 else 0,
            .pAttachments = &attachment,
        };
        const mesh_dynamic = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR, c.VK_DYNAMIC_STATE_CULL_MODE, c.VK_DYNAMIC_STATE_DEPTH_WRITE_ENABLE, c.VK_DYNAMIC_STATE_DEPTH_BIAS, c.VK_DYNAMIC_STATE_DEPTH_BIAS_ENABLE };
        const dynamic: c.VkPipelineDynamicStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = if (desc.mesh_state) mesh_dynamic.len else 2,
            .pDynamicStates = &mesh_dynamic,
        };
        const color_format = desc.color orelse c.VK_FORMAT_UNDEFINED;
        const rendering: c.VkPipelineRenderingCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .colorAttachmentCount = if (desc.color != null) 1 else 0,
            .pColorAttachmentFormats = &color_format,
            .depthAttachmentFormat = if (desc.depth != .none) depth_format else c.VK_FORMAT_UNDEFINED,
        };
        const depth_state: c.VkPipelineDepthStencilStateCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
            .depthTestEnable = c.VK_TRUE,
            .depthWriteEnable = c.VK_TRUE,
            .depthCompareOp = if (desc.depth == .reverse) c.VK_COMPARE_OP_GREATER_OR_EQUAL else c.VK_COMPARE_OP_LESS_OR_EQUAL,
        };
        var handle: c.VkPipeline = null;
        try vk.check(c.vkCreateGraphicsPipelines(dev, null, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering,
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &input_assembly,
            .pViewportState = &viewport_state,
            .pRasterizationState = &raster,
            .pMultisampleState = &multisample,
            .pColorBlendState = &blend_state,
            .pDepthStencilState = if (desc.depth != .none) &depth_state else null,
            .pDynamicState = &dynamic,
            .layout = desc.layout,
        }, null, &handle));
        return handle;
    }
};

fn shaderModule(dev: c.VkDevice, code: []const u8) !c.VkShaderModule {
    var module: c.VkShaderModule = null;
    try vk.check(c.vkCreateShaderModule(dev, &.{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = code.len, .pCode = @ptrCast(@alignCast(code.ptr)) }, null, &module));
    return module;
}

fn createSampler(dev: c.VkDevice, filter: c.VkFilter, mode: c.VkSamplerAddressMode, mip: c.VkSamplerMipmapMode, max_lod: f32, compare: bool) !c.VkSampler {
    var s: c.VkSampler = null;
    try vk.check(c.vkCreateSampler(dev, &.{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = filter,
        .minFilter = filter,
        .mipmapMode = mip,
        .addressModeU = mode,
        .addressModeV = mode,
        .addressModeW = mode,
        .maxLod = max_lod,
        .compareEnable = if (compare) c.VK_TRUE else c.VK_FALSE,
        .compareOp = c.VK_COMPARE_OP_LESS_OR_EQUAL,
        .borderColor = c.VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE,
    }, null, &s));
    return s;
}

fn beginRendering(cmd: c.VkCommandBuffer, color: ?*const c.VkRenderingAttachmentInfo, depth: ?*const c.VkRenderingAttachmentInfo, w: u32, h: u32) void {
    const area: c.VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = w, .height = h } };
    c.vkCmdBeginRendering(cmd, &.{
        .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = area,
        .layerCount = 1,
        .colorAttachmentCount = if (color != null) 1 else 0,
        .pColorAttachments = color,
        .pDepthAttachment = depth,
    });
    const vp: c.VkViewport = .{ .x = 0, .y = 0, .width = @floatFromInt(w), .height = @floatFromInt(h), .minDepth = 0, .maxDepth = 1 };
    c.vkCmdSetViewport(cmd, 0, 1, &vp);
    c.vkCmdSetScissor(cmd, 0, 1, &area);
}

fn destroyGarbage(dev: c.VkDevice, g: *Garbage) void {
    switch (g.*) {
        .buffer => |*b| b.destroy(dev),
        .image => |*img| img.destroy(dev),
    }
}

fn sharpenOf(plan: *const Plan) f32 {
    return if (plan.post.resolution_scale < 1) std.math.clamp(plan.post.sharpen, 0, 1) else 0;
}

fn samplesOf(n: u32) Samples {
    return switch (n) {
        4 => .four,
        2 => .two,
        else => .one,
    };
}

fn sampleBits(s: Samples) c.VkSampleCountFlagBits {
    return switch (s) {
        .one => c.VK_SAMPLE_COUNT_1_BIT,
        .two => c.VK_SAMPLE_COUNT_2_BIT,
        .four => c.VK_SAMPLE_COUNT_4_BIT,
    };
}
