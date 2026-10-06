//! Vulkan 1.3 renderer for zpui scenes (dynamic rendering, buffer device
//! addresses, push constants). Implements the interface documented in
//! `src/renderer/renderer.zig`; output matches zui's Metal renderer
//! (`gpui_macos/src/metal_renderer.rs` + `shaders.metal`).
//!
//! Per frame: wait the frame's fence, sync atlas textures and uploads, copy
//! every batch's instances into a host-visible buffer and draw one instanced
//! unit quad per primitive with the batch's pipeline. Paths rasterize into a
//! 4x MSAA intermediate first; backdrop blurs break the pass to snapshot,
//! blur (two separable passes) and composite, exactly where the scene order
//! puts them. The framebuffer is UNORM (gamma-space blending, like Metal) and
//! holds premultiplied color: shaders output straight alpha and blend with
//! `SrcAlpha, 1-SrcAlpha` (color) / `One, 1-SrcAlpha` (alpha), i.e. Porter-Duff
//! source-over, so transparent targets composite correctly.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const vk = @import("vk.zig");
const c = vk.c;
const Device = @import("Device.zig");
const Swapchain = @import("Swapchain.zig");
const shaders = @import("vulkan_shaders");
const iface = @import("../renderer.zig");
const geometry = @import("../../geometry.zig");
const scene_mod = @import("../../scene.zig");
const atlas_mod = @import("../../atlas.zig");
const color = @import("../../color.zig");

const Scene = scene_mod.Scene;
const three = scene_mod.three;
const Atlas = atlas_mod.Atlas;
const AtlasTextureId = atlas_mod.AtlasTextureId;
const AtlasTextureKind = atlas_mod.AtlasTextureKind;
const Size = geometry.Size(geometry.DevicePixels);
const Hsla = color.Hsla;

const Renderer = @This();
const log = std.log.scoped(.vulkan);

pub const SurfaceSource = Device.SurfaceSource;
/// `VK_EXT_headless_surface` source for testing the swapchain path without a display.
pub const headless_surface = Device.headless_surface;

const frames_in_flight = 2;
const offscreen_format = c.VK_FORMAT_R8G8B8A8_UNORM;
const path_sample_count = 4;
const kind_count = @typeInfo(AtlasTextureKind).@"enum".field_names.len;

gpa: Allocator,
device: Device,
sprite_atlas: Atlas,
transparent: bool,
color_format: c.VkFormat,
size: Size,
/// Offscreen render target (null when presenting to a surface).
offscreen: ?vk.Image = null,
swapchain: Swapchain = .{},
/// Whether the drawable can be copied from (backdrop blur snapshots).
can_snapshot: bool = true,
sampler: c.VkSampler = null,
set_layout: c.VkDescriptorSetLayout = null,
pipeline_layout: c.VkPipelineLayout = null,
pipelines: Pipelines = .{},
command_pool: c.VkCommandPool = null,
frames: [frames_in_flight]Frame = @splat(.{}),
frame_index: usize = 0,
atlas_textures: [kind_count]std.ArrayList(GpuTexture) = @splat(.empty),
path_msaa: vk.Image = .{},
path_resolve: vk.Image = .{},
blur_scratch: vk.Image = .{},
blur_a: vk.Image = .{},
blur_b: vk.Image = .{},
readback: vk.Buffer = .{},
warned_surface: bool = false,
/// [three spike] pipeline layout for mesh pipelines (push constants only).
three_layout: c.VkPipelineLayout = null,
/// [three spike] offscreen targets, one per `scene.viewports3d` index.
three_targets: std.ArrayList(Target3D) = .empty,

const Frame = struct {
    cmd: c.VkCommandBuffer = null,
    fence: c.VkFence = null,
    acquired: c.VkSemaphore = null,
    descriptor_pool: c.VkDescriptorPool = null,
    instances: vk.Buffer = .{},
    staging: vk.Buffer = .{},
    sets: std.ArrayList(SetEntry) = .empty,

    const SetEntry = struct { view: c.VkImageView, set: c.VkDescriptorSet };
};

/// [three spike] Offscreen 3D target: HDR color (MSAA) + depth (MSAA) + 1x resolve.
const Target3D = struct {
    color: vk.Image = .{},
    depth: vk.Image = .{},
    resolve: vk.Image = .{},

    fn destroy(t: *Target3D, dev: c.VkDevice) void {
        t.color.destroy(dev);
        t.depth.destroy(dev);
        t.resolve.destroy(dev);
    }
};

const hdr_format = c.VK_FORMAT_R16G16B16A16_SFLOAT;
const depth_format = c.VK_FORMAT_D32_SFLOAT;

/// [three spike] Push constants for mesh pipelines; mirrors `Push3D` in three_common.glsl.
const Push3D = extern struct {
    vertices: u64,
    indices: u64,
    frame: u64,
    draw: u64,
};

const GpuTexture = struct {
    image: vk.Image = .{},
    generation: u32 = 0,
    /// Created since the last frame: clear before the first upload.
    fresh: bool = false,
};

const Pipelines = struct {
    quad: c.VkPipeline = null,
    shadow: c.VkPipeline = null,
    underline: c.VkPipeline = null,
    mono_sprite: c.VkPipeline = null,
    subpixel_sprite: c.VkPipeline = null,
    poly_sprite: c.VkPipeline = null,
    path_rasterization: c.VkPipeline = null,
    path_sprite: c.VkPipeline = null,
    blur_pass: c.VkPipeline = null,
    backdrop_blur: c.VkPipeline = null,
    mesh: c.VkPipeline = null,
    viewport3d: c.VkPipeline = null,
};

/// Push constants shared by every pipeline; mirrors `PUSH_CONSTANTS` in shaders/common.glsl.
const PushConstants = extern struct {
    instances: u64 = 0,
    viewport_size: [2]f32 = .{ 0, 0 },
    texture_size: [2]f32 = .{ 0, 0 },
    params0: [4]f32 = .{ 0, 0, 0, 0 },
    params1: [4]f32 = .{ 0, 0, 0, 0 },
};

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

/// Shared-interface constructor (see `renderer.zig`). `options.surface`
/// selects presentation; null renders offscreen.
pub fn init(gpa: Allocator, options: iface.Options) !Renderer {
    const surface: ?SurfaceSource = if (options.surface) |s| switch (s) {
        .vulkan => |v| v,
        else => return error.UnsupportedSurface,
    } else null;
    return create(gpa, .{
        .size = options.size,
        .surface = surface,
        .transparent = options.transparent,
        .validation = options.validation,
        .atlas = options.atlas,
    });
}

/// Headless renderer drawing into an RGBA8 image; read it with `readPixels`.
pub fn createOffscreen(gpa: Allocator, size: Size) !Renderer {
    return create(gpa, .{ .size = size });
}

/// Renderer presenting to a platform surface created from our instance.
pub fn createForSurface(gpa: Allocator, surface: SurfaceSource, size: Size, transparent: bool) !Renderer {
    return create(gpa, .{ .size = size, .surface = surface, .transparent = transparent });
}

pub const CreateOptions = struct {
    size: Size,
    surface: ?SurfaceSource = null,
    transparent: bool = false,
    validation: bool = builtin.mode == .debug,
    atlas: Atlas.Options = .{},
};

pub fn create(gpa: Allocator, opts: CreateOptions) !Renderer {
    var device = try Device.init(.{ .validation = opts.validation, .surface = opts.surface });
    errdefer device.deinit();
    var atlas_opts = opts.atlas;
    atlas_opts.max_size = @min(atlas_opts.max_size, @as(i32, @intCast(@min(device.limits.maxImageDimension2D, 16384))));

    var self: Renderer = .{
        .gpa = gpa,
        .device = device,
        .sprite_atlas = .init(gpa, atlas_opts),
        .transparent = opts.transparent,
        .color_format = if (opts.surface != null) try Swapchain.chooseFormat(&device) else offscreen_format,
        .size = .{ .width = @max(opts.size.width, 1), .height = @max(opts.size.height, 1) },
    };
    errdefer self.destroyResources();
    try self.createSharedObjects();
    if (opts.surface != null) {
        try self.swapchain.recreate(&self.device, self.color_format, self.extentW(), self.extentH(), self.transparent);
        self.syncSurfaceState();
    } else {
        try self.createOffscreenTarget();
    }
    return self;
}

pub fn deinit(self: *Renderer) void {
    self.destroyResources();
    self.* = undefined;
}

fn destroyResources(self: *Renderer) void {
    const dev = self.device.handle;
    if (dev != null) {
        self.device.waitIdle();
        for (&self.frames) |*f| {
            f.instances.destroy(dev);
            f.staging.destroy(dev);
            if (f.descriptor_pool != null) c.vkDestroyDescriptorPool(dev, f.descriptor_pool, null);
            if (f.fence != null) c.vkDestroyFence(dev, f.fence, null);
            if (f.acquired != null) c.vkDestroySemaphore(dev, f.acquired, null);
            f.sets.deinit(self.gpa);
        }
        for (&self.atlas_textures) |*list| {
            for (list.items) |*t| t.image.destroy(dev);
            list.deinit(self.gpa);
        }
        if (self.offscreen) |*img| img.destroy(dev);
        self.swapchain.deinit(&self.device);
        self.path_msaa.destroy(dev);
        self.path_resolve.destroy(dev);
        self.blur_scratch.destroy(dev);
        self.blur_a.destroy(dev);
        self.blur_b.destroy(dev);
        self.readback.destroy(dev);
        for (self.three_targets.items) |*t| t.destroy(dev);
        self.three_targets.deinit(self.gpa);
        inline for (@typeInfo(Pipelines).@"struct".field_names) |name| {
            const p = @field(self.pipelines, name);
            if (p != null) c.vkDestroyPipeline(dev, p, null);
        }
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(dev, self.pipeline_layout, null);
        if (self.three_layout != null) c.vkDestroyPipelineLayout(dev, self.three_layout, null);
        if (self.set_layout != null) c.vkDestroyDescriptorSetLayout(dev, self.set_layout, null);
        if (self.sampler != null) c.vkDestroySampler(dev, self.sampler, null);
        if (self.command_pool != null) c.vkDestroyCommandPool(dev, self.command_pool, null);
    }
    self.sprite_atlas.deinit();
    self.device.deinit();
}

/// The sprite atlas; the renderer uploads its pending tiles every frame.
pub fn atlas(self: *Renderer) *Atlas {
    return &self.sprite_atlas;
}

/// Number of validation-layer errors reported so far (0 without validation).
pub fn validationErrors(self: *const Renderer) u32 {
    _ = self;
    return Device.validation_error_count.load(.monotonic);
}

/// Resize the offscreen target or swapchain.
pub fn resize(self: *Renderer, size: Size) !void {
    if (size.width <= 0 or size.height <= 0) return;
    self.device.waitIdle();
    self.size = size;
    if (self.offscreen) |*img| {
        img.destroy(self.device.handle);
        self.offscreen = null;
        try self.createOffscreenTarget();
    } else {
        try self.swapchain.recreate(&self.device, self.color_format, self.extentW(), self.extentH(), self.transparent);
        self.syncSurfaceState();
    }
}

fn syncSurfaceState(self: *Renderer) void {
    // The surface may impose its own extent.
    self.size = .{ .width = @intCast(self.swapchain.extent.width), .height = @intCast(self.swapchain.extent.height) };
    var caps: c.VkSurfaceCapabilitiesKHR = undefined;
    if (c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.device.physical, self.device.surface, &caps) == c.VK_SUCCESS)
        self.can_snapshot = caps.supportedUsageFlags & c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT != 0;
}

fn extentW(self: *const Renderer) u32 {
    return @intCast(self.size.width);
}
fn extentH(self: *const Renderer) u32 {
    return @intCast(self.size.height);
}

fn createOffscreenTarget(self: *Renderer) !void {
    self.offscreen = try vk.Image.create(self.device.handle, &self.device.mem_props, .{
        .width = self.extentW(),
        .height = self.extentH(),
        .format = offscreen_format,
        .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
    });
}

fn createSharedObjects(self: *Renderer) !void {
    const dev = self.device.handle;
    try vk.check(c.vkCreateCommandPool(dev, &.{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self.device.queue_family,
    }, null, &self.command_pool));
    try vk.check(c.vkCreateSampler(dev, &.{
        .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = c.VK_FILTER_LINEAR,
        .minFilter = c.VK_FILTER_LINEAR,
        .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .maxLod = 0,
    }, null, &self.sampler));
    const binding: c.VkDescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    try vk.check(c.vkCreateDescriptorSetLayout(dev, &.{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &binding,
    }, null, &self.set_layout));
    const range: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(PushConstants),
    };
    try vk.check(c.vkCreatePipelineLayout(dev, &.{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &self.set_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &range,
    }, null, &self.pipeline_layout));
    const range3d: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(Push3D),
    };
    try vk.check(c.vkCreatePipelineLayout(dev, &.{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &range3d,
    }, null, &self.three_layout));
    try self.createPipelines();

    for (&self.frames) |*f| {
        try vk.check(c.vkAllocateCommandBuffers(dev, &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        }, &f.cmd));
        try vk.check(c.vkCreateFence(dev, &.{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        }, null, &f.fence));
        try vk.check(c.vkCreateSemaphore(dev, &.{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO }, null, &f.acquired));
        const pool_size: c.VkDescriptorPoolSize = .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 256 };
        try vk.check(c.vkCreateDescriptorPool(dev, &.{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 256,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        }, null, &f.descriptor_pool));
    }
}

// ---------------------------------------------------------------------------
// Pipelines
// ---------------------------------------------------------------------------

const Blend = enum { none, straight, premultiplied, dual_source };

const PipelineDesc = struct {
    vert: []const u8,
    frag: []const u8,
    blend: Blend,
    samples: c.VkSampleCountFlagBits = c.VK_SAMPLE_COUNT_1_BIT,
    // [three spike] overrides for 3D pipelines.
    layout: c.VkPipelineLayout = null,
    color_format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    depth: bool = false,
    cull_back: bool = false,
};

fn createPipelines(self: *Renderer) !void {
    const msaa: c.VkSampleCountFlagBits = if (self.pathSampleCount() == path_sample_count) c.VK_SAMPLE_COUNT_4_BIT else c.VK_SAMPLE_COUNT_1_BIT;
    const p = &self.pipelines;
    p.quad = try self.createPipeline(.{ .vert = &shaders.quad_vert, .frag = &shaders.quad_frag, .blend = .straight });
    p.shadow = try self.createPipeline(.{ .vert = &shaders.shadow_vert, .frag = &shaders.shadow_frag, .blend = .straight });
    p.underline = try self.createPipeline(.{ .vert = &shaders.underline_vert, .frag = &shaders.underline_frag, .blend = .straight });
    p.mono_sprite = try self.createPipeline(.{ .vert = &shaders.mono_sprite_vert, .frag = &shaders.mono_sprite_frag, .blend = .straight });
    p.subpixel_sprite = if (self.device.dual_source_blend)
        try self.createPipeline(.{ .vert = &shaders.mono_sprite_vert, .frag = &shaders.subpixel_sprite_frag, .blend = .dual_source })
    else
        try self.createPipeline(.{ .vert = &shaders.mono_sprite_vert, .frag = &shaders.subpixel_sprite_fallback_frag, .blend = .straight });
    p.poly_sprite = try self.createPipeline(.{ .vert = &shaders.poly_sprite_vert, .frag = &shaders.poly_sprite_frag, .blend = .straight });
    p.path_rasterization = try self.createPipeline(.{
        .vert = &shaders.path_rasterization_vert,
        .frag = &shaders.path_rasterization_frag,
        .blend = .premultiplied,
        .samples = msaa,
    });
    p.path_sprite = try self.createPipeline(.{ .vert = &shaders.path_sprite_vert, .frag = &shaders.path_sprite_frag, .blend = .premultiplied });
    p.blur_pass = try self.createPipeline(.{ .vert = &shaders.blur_pass_vert, .frag = &shaders.blur_pass_frag, .blend = .none });
    p.backdrop_blur = try self.createPipeline(.{ .vert = &shaders.backdrop_blur_vert, .frag = &shaders.backdrop_blur_frag, .blend = .none });
    p.mesh = try self.createPipeline(.{
        .vert = &shaders.mesh_vert,
        .frag = &shaders.mesh_frag,
        .blend = .none,
        .samples = self.threeSamples(),
        .layout = self.three_layout,
        .color_format = hdr_format,
        .depth = true,
        .cull_back = true,
    });
    p.viewport3d = try self.createPipeline(.{ .vert = &shaders.viewport3d_vert, .frag = &shaders.viewport3d_frag, .blend = .premultiplied });
}

fn threeSamples(self: *const Renderer) c.VkSampleCountFlagBits {
    const l = self.device.limits;
    return if (l.framebufferColorSampleCounts & l.framebufferDepthSampleCounts & c.VK_SAMPLE_COUNT_4_BIT != 0) c.VK_SAMPLE_COUNT_4_BIT else c.VK_SAMPLE_COUNT_1_BIT;
}

fn pathSampleCount(self: *const Renderer) u32 {
    return if (self.device.limits.framebufferColorSampleCounts & c.VK_SAMPLE_COUNT_4_BIT != 0) path_sample_count else 1;
}

fn createShaderModule(self: *Renderer, code: []const u8) !c.VkShaderModule {
    var module: c.VkShaderModule = null;
    try vk.check(c.vkCreateShaderModule(self.device.handle, &.{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = @ptrCast(@alignCast(code.ptr)),
    }, null, &module));
    return module;
}

fn createPipeline(self: *Renderer, desc: PipelineDesc) !c.VkPipeline {
    const dev = self.device.handle;
    const vs = try self.createShaderModule(desc.vert);
    defer c.vkDestroyShaderModule(dev, vs, null);
    const fs = try self.createShaderModule(desc.frag);
    defer c.vkDestroyShaderModule(dev, fs, null);
    const stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "main" },
        .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "main" },
    };
    const vertex_input: c.VkPipelineVertexInputStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    const input_assembly: c.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    };
    const viewport_state: c.VkPipelineViewportStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };
    const raster: c.VkPipelineRasterizationStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .cullMode = if (desc.cull_back) c.VK_CULL_MODE_BACK_BIT else c.VK_CULL_MODE_NONE,
        .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1,
    };
    const multisample: c.VkPipelineMultisampleStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = desc.samples,
    };
    var attachment: c.VkPipelineColorBlendAttachmentState = .{
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        .colorBlendOp = c.VK_BLEND_OP_ADD,
        .alphaBlendOp = c.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
    };
    switch (desc.blend) {
        .none => {},
        .straight => {
            attachment.blendEnable = c.VK_TRUE;
            attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA;
            attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        },
        .premultiplied => {
            attachment.blendEnable = c.VK_TRUE;
            attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE;
            attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        },
        .dual_source => {
            attachment.blendEnable = c.VK_TRUE;
            attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC1_COLOR;
            attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC1_COLOR;
        },
    }
    const blend_state: c.VkPipelineColorBlendStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &attachment,
    };
    const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    const dynamic: c.VkPipelineDynamicStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };
    const color_format = if (desc.color_format != c.VK_FORMAT_UNDEFINED) desc.color_format else self.color_format;
    const rendering: c.VkPipelineRenderingCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
        .colorAttachmentCount = 1,
        .pColorAttachmentFormats = &color_format,
        .depthAttachmentFormat = if (desc.depth) depth_format else c.VK_FORMAT_UNDEFINED,
    };
    // Reverse-Z: clear to 0, nearer fragments have larger depth.
    const depth_state: c.VkPipelineDepthStencilStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = c.VK_TRUE,
        .depthWriteEnable = c.VK_TRUE,
        .depthCompareOp = c.VK_COMPARE_OP_GREATER,
    };
    var pipeline: c.VkPipeline = null;
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
        .pDepthStencilState = if (desc.depth) &depth_state else null,
        .pDynamicState = &dynamic,
        .layout = if (desc.layout != null) desc.layout else self.pipeline_layout,
    }, null, &pipeline));
    return pipeline;
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

/// Draw `scene` (already `finish`ed) and present it (surface) or keep it for
/// `readPixels` (offscreen). Primitives are in device pixels already, so
/// `scale_factor` is informational. `clear` is premultiplied before clearing;
/// opaque renderers force alpha to 1.
pub fn drawScene(self: *Renderer, scene: *const Scene, viewport: Size, scale_factor: f32, clear: Hsla) !void {
    _ = scale_factor;
    if (viewport.width <= 0 or viewport.height <= 0) return;
    if (viewport.width != self.size.width or viewport.height != self.size.height) try self.resize(viewport);

    const dev = self.device.handle;
    const frame = &self.frames[self.frame_index];
    try vk.check(c.vkWaitForFences(dev, 1, &frame.fence, c.VK_TRUE, std.math.maxInt(u64)));

    var image_index: u32 = 0;
    var target: vk.Image = undefined;
    if (self.offscreen) |img| {
        target = img;
    } else {
        image_index = self.swapchain.acquire(&self.device, frame.acquired) catch |err| switch (err) {
            error.OutOfDate => {
                try self.resize(self.size);
                return;
            },
            else => return err,
        };
        target = .{
            .handle = self.swapchain.images[image_index],
            .view = self.swapchain.views[image_index],
            .width = self.swapchain.extent.width,
            .height = self.swapchain.extent.height,
            .format = self.color_format,
        };
    }
    try vk.check(c.vkResetFences(dev, 1, &frame.fence));

    try self.syncAtlasTextures();
    try self.ensureHostBuffer(&frame.staging, self.uploadBytes(), c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    try self.ensureHostBuffer(&frame.instances, instanceBytesUpperBound(scene), c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
    try vk.check(c.vkResetDescriptorPool(dev, frame.descriptor_pool, 0));
    frame.sets.clearRetainingCapacity();

    const cmd = frame.cmd;
    try vk.check(c.vkResetCommandBuffer(cmd, 0));
    try vk.check(c.vkBeginCommandBuffer(cmd, &.{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    }));
    self.recordUploads(cmd, frame);

    const rgba = clear.toRgba();
    const alpha: f32 = if (self.transparent or self.offscreen != null) rgba.a else 1;
    var rec: Recorder = .{
        .r = self,
        .frame = frame,
        .cmd = cmd,
        .target = &target,
        .clear = .{ rgba.r * alpha, rgba.g * alpha, rgba.b * alpha, alpha },
    };
    // [three spike] 3D viewports render offscreen before the UI pass (they don't
    // depend on 2D content), then composite in draw order inside it.
    try rec.renderViewports3D(scene);
    target.transition(cmd, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, true);
    rec.beginMain(true);
    try rec.drawBatches(scene);
    rec.endMain();
    target.transition(cmd, if (self.offscreen != null) c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL else c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, false);
    if (self.offscreen) |*img| img.layout = target.layout;
    try vk.check(c.vkEndCommandBuffer(cmd));

    const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    const presenting = self.offscreen == null;
    try vk.check(c.vkQueueSubmit(self.device.queue, 1, &.{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = if (presenting) 1 else 0,
        .pWaitSemaphores = &frame.acquired,
        .pWaitDstStageMask = &wait_stage,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
        .signalSemaphoreCount = if (presenting) 1 else 0,
        .pSignalSemaphores = if (presenting) &self.swapchain.render_done[image_index] else null,
    }, frame.fence));
    self.frame_index = (self.frame_index + 1) % frames_in_flight;
    if (presenting and !try self.swapchain.present(&self.device, image_index)) try self.resize(self.size);
}

/// The last offscreen frame as tightly packed RGBA8 rows (top row first),
/// premultiplied alpha. Caller owns the slice.
pub fn readPixels(self: *Renderer, gpa: Allocator) ![]u8 {
    const img = &(self.offscreen orelse return error.NotOffscreen);
    const dev = self.device.handle;
    self.device.waitIdle();
    const len: usize = @as(usize, img.width) * img.height * 4;
    if (self.readback.size < len) {
        self.readback.destroy(dev);
        self.readback = try vk.Buffer.create(dev, &self.device.mem_props, len, c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    }
    var cmd: c.VkCommandBuffer = null;
    try vk.check(c.vkAllocateCommandBuffers(dev, &.{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = self.command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    }, &cmd));
    defer c.vkFreeCommandBuffers(dev, self.command_pool, 1, &cmd);
    try vk.check(c.vkBeginCommandBuffer(cmd, &.{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT }));
    img.transition(cmd, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, img.layout == c.VK_IMAGE_LAYOUT_UNDEFINED);
    const region: c.VkBufferImageCopy = .{
        .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
        .imageExtent = .{ .width = img.width, .height = img.height, .depth = 1 },
    };
    c.vkCmdCopyImageToBuffer(cmd, img.handle, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, self.readback.handle, 1, &region);
    const host_barrier: c.VkMemoryBarrier2 = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
        .srcStageMask = c.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
        .srcAccessMask = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        .dstStageMask = c.VK_PIPELINE_STAGE_2_HOST_BIT,
        .dstAccessMask = c.VK_ACCESS_2_HOST_READ_BIT,
    };
    c.vkCmdPipelineBarrier2(cmd, &.{ .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .memoryBarrierCount = 1, .pMemoryBarriers = &host_barrier });
    try vk.check(c.vkEndCommandBuffer(cmd));
    try vk.check(c.vkQueueSubmit(self.device.queue, 1, &.{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd }, null));
    try vk.check(c.vkQueueWaitIdle(self.device.queue));
    return gpa.dupe(u8, self.readback.mapped.?[0..len]);
}

fn ensureHostBuffer(self: *Renderer, buffer: *vk.Buffer, needed: usize, usage: c.VkBufferUsageFlags) !void {
    if (buffer.size >= needed and buffer.handle != null) return;
    const dev = self.device.handle;
    buffer.destroy(dev);
    // Grow geometrically to avoid reallocating every frame.
    const size = @max(std.math.ceilPowerOfTwo(usize, @max(needed, 64 * 1024)) catch needed, 64 * 1024);
    buffer.* = try vk.Buffer.create(dev, &self.device.mem_props, size, usage, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
}

const instance_align = 16;

fn instanceBytesUpperBound(scene: *const Scene) usize {
    var total: usize = 0;
    var count: usize = 1;
    inline for (.{ "shadows", "quads", "underlines", "monochrome_sprites", "subpixel_sprites", "polychrome_sprites", "backdrop_blurs" }) |name| {
        const items = @field(scene, name).items;
        total += items.len * @sizeOf(@TypeOf(items[0]));
        count += items.len;
    }
    for (scene.paths.items) |p| total += p.vertices.items.len * @sizeOf(scene_mod.PathRasterizationVertex) + @sizeOf(scene_mod.PathSprite);
    count += 2 * scene.paths.items.len;
    // [three spike] per viewport: frame uniforms + composite instance; per draw: data + mesh copy.
    for (scene.viewports3d.items) |v| {
        total += @sizeOf(three.FrameUniforms) + @sizeOf(scene_mod.Viewport3DInstance);
        count += 2;
        for (v.scene3d.draws.items) |d| {
            total += @sizeOf(three.DrawData) + d.mesh.vertices.len * @sizeOf(three.Vertex) + d.mesh.indices.len * 4;
            count += 3;
        }
    }
    return total + count * instance_align;
}

// ---------------------------------------------------------------------------
// Atlas textures
// ---------------------------------------------------------------------------

fn atlasFormat(kind: AtlasTextureKind) c.VkFormat {
    return switch (kind) {
        .monochrome => c.VK_FORMAT_R8_UNORM,
        .polychrome, .subpixel => c.VK_FORMAT_B8G8R8A8_UNORM,
    };
}

/// Create/destroy GPU textures to mirror the atlas' live slots.
fn syncAtlasTextures(self: *Renderer) !void {
    const dev = self.device.handle;
    var waited = false;
    inline for (comptime std.enums.values(AtlasTextureKind)) |kind| {
        const list = &self.atlas_textures[@backingInt(kind)];
        const slots = self.sprite_atlas.textureSlots(kind);
        while (list.items.len < slots) try list.append(self.gpa, .{});
        for (list.items, 0..) |*gpu, i| {
            const info = self.sprite_atlas.textureInfo(.{ .index = @intCast(i), .kind = kind });
            const want_gen: u32 = if (info) |inf| inf.generation else 0;
            if (gpu.generation == want_gen) continue;
            if (gpu.image.handle != null) {
                // Rare (texture freed or slot reused): make sure no frame still samples it.
                if (!waited) self.device.waitIdle();
                waited = true;
                gpu.image.destroy(dev);
            }
            gpu.* = .{};
            if (info) |inf| {
                gpu.image = try vk.Image.create(dev, &self.device.mem_props, .{
                    .width = @intCast(inf.size.width),
                    .height = @intCast(inf.size.height),
                    .format = atlasFormat(kind),
                    .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                });
                gpu.generation = inf.generation;
                gpu.fresh = true;
            }
        }
    }
}

fn uploadBytes(self: *const Renderer) usize {
    var total: usize = 0;
    for (self.sprite_atlas.pendingUploads()) |u| total += std.mem.alignForward(usize, u.data.len, 4);
    return total;
}

/// Copy pending atlas uploads into the staging buffer and record the copies.
fn recordUploads(self: *Renderer, cmd: c.VkCommandBuffer, frame: *Frame) void {
    const uploads = self.sprite_atlas.pendingUploads();
    for (&self.atlas_textures, 0..) |*list, kind_index| {
        for (list.items, 0..) |*gpu, slot| {
            if (gpu.image.handle == null) continue;
            const id: AtlasTextureId = .{ .index = @intCast(slot), .kind = @fromBackingInt(@intCast(kind_index)) };
            var has_uploads = false;
            for (uploads) |u| {
                if (u.texture_id.eql(id)) has_uploads = true;
            }
            if (!has_uploads and !gpu.fresh) continue;
            gpu.image.transition(cmd, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, gpu.fresh);
            if (gpu.fresh) {
                const zero: c.VkClearColorValue = .{ .float32 = .{ 0, 0, 0, 0 } };
                c.vkCmdClearColorImage(cmd, gpu.image.handle, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &zero, 1, &vk.color_range);
                gpu.fresh = false;
            }
            var offset: usize = 0;
            for (uploads) |u| {
                const len = std.mem.alignForward(usize, u.data.len, 4);
                defer offset += len;
                if (!u.texture_id.eql(id)) continue;
                @memcpy(frame.staging.mapped.?[offset..][0..u.data.len], u.data);
                const region: c.VkBufferImageCopy = .{
                    .bufferOffset = offset,
                    .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
                    .imageOffset = .{ .x = u.bounds.origin.x, .y = u.bounds.origin.y, .z = 0 },
                    .imageExtent = .{ .width = @intCast(u.bounds.size.width), .height = @intCast(u.bounds.size.height), .depth = 1 },
                };
                c.vkCmdCopyBufferToImage(cmd, frame.staging.handle, gpu.image.handle, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
            }
            gpu.image.transition(cmd, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);
        }
    }
    self.sprite_atlas.clearUploads();
}

fn textureSet(self: *Renderer, frame: *Frame, view: c.VkImageView) !c.VkDescriptorSet {
    for (frame.sets.items) |e| if (e.view == view) return e.set;
    var set: c.VkDescriptorSet = null;
    try vk.check(c.vkAllocateDescriptorSets(self.device.handle, &.{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = frame.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.set_layout,
    }, &set));
    const image_info: c.VkDescriptorImageInfo = .{
        .sampler = self.sampler,
        .imageView = view,
        .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    c.vkUpdateDescriptorSets(self.device.handle, 1, &.{
        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = set,
        .dstBinding = 0,
        .descriptorCount = 1,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &image_info,
    }, 0, null);
    try frame.sets.append(self.gpa, .{ .view = view, .set = set });
    return set;
}

/// Viewport-sized intermediates, (re)created lazily when the size changes.
fn ensureImage(self: *Renderer, img: *vk.Image, usage: c.VkImageUsageFlags, samples: c.VkSampleCountFlagBits) !void {
    const w = self.extentW();
    const h = self.extentH();
    if (img.handle != null and img.width == w and img.height == h) return;
    img.destroy(self.device.handle);
    img.* = try vk.Image.create(self.device.handle, &self.device.mem_props, .{
        .width = w,
        .height = h,
        .format = self.color_format,
        .usage = usage,
        .samples = samples,
    });
}

// ---------------------------------------------------------------------------
// Command recording
// ---------------------------------------------------------------------------

const Recorder = struct {
    r: *Renderer,
    frame: *Frame,
    cmd: c.VkCommandBuffer,
    target: *vk.Image,
    clear: [4]f32,
    offset: usize = 0,
    rendering: bool = false,
    bound: c.VkPipeline = null,

    fn viewportSize(rec: *const Recorder) [2]f32 {
        return .{ @floatFromInt(rec.target.width), @floatFromInt(rec.target.height) };
    }

    /// Reserve instance memory; returns the mapped slice and its device address.
    fn alloc(rec: *Recorder, len: usize) struct { bytes: []u8, address: u64 } {
        rec.offset = std.mem.alignForward(usize, rec.offset, instance_align);
        const buf = &rec.frame.instances;
        std.debug.assert(rec.offset + len <= buf.size);
        defer rec.offset += len;
        return .{ .bytes = buf.mapped.?[rec.offset..][0..len], .address = buf.address + rec.offset };
    }

    fn push(rec: *Recorder, bytes: []const u8) u64 {
        const a = rec.alloc(bytes.len);
        @memcpy(a.bytes, bytes);
        return a.address;
    }

    fn beginRendering(rec: *Recorder, attachment: c.VkRenderingAttachmentInfo, area: c.VkRect2D, viewport: [2]f32) void {
        c.vkCmdBeginRendering(rec.cmd, &.{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
            .renderArea = area,
            .layerCount = 1,
            .colorAttachmentCount = 1,
            .pColorAttachments = &attachment,
        });
        const vp: c.VkViewport = .{ .x = 0, .y = 0, .width = viewport[0], .height = viewport[1], .minDepth = 0, .maxDepth = 1 };
        c.vkCmdSetViewport(rec.cmd, 0, 1, &vp);
        c.vkCmdSetScissor(rec.cmd, 0, 1, &area);
        rec.bound = null;
    }

    fn fullArea(rec: *const Recorder) c.VkRect2D {
        return .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = rec.target.width, .height = rec.target.height } };
    }

    /// Start (clear) or resume (load) rendering into the drawable.
    fn beginMain(rec: *Recorder, clear: bool) void {
        std.debug.assert(!rec.rendering);
        rec.beginRendering(.{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = rec.target.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = if (clear) c.VK_ATTACHMENT_LOAD_OP_CLEAR else c.VK_ATTACHMENT_LOAD_OP_LOAD,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = .{ .color = .{ .float32 = rec.clear } },
        }, rec.fullArea(), rec.viewportSize());
        rec.rendering = true;
    }

    fn endMain(rec: *Recorder) void {
        if (!rec.rendering) return;
        c.vkCmdEndRendering(rec.cmd);
        rec.rendering = false;
    }

    fn bind(rec: *Recorder, pipeline: c.VkPipeline) void {
        if (rec.bound == pipeline) return;
        c.vkCmdBindPipeline(rec.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        rec.bound = pipeline;
    }

    fn draw(rec: *Recorder, pipeline: c.VkPipeline, view: ?c.VkImageView, pc: PushConstants, vertex_count: u32, instance_count: u32) !void {
        rec.bind(pipeline);
        if (view) |v| {
            const set = try rec.r.textureSet(rec.frame, v);
            c.vkCmdBindDescriptorSets(rec.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, rec.r.pipeline_layout, 0, 1, &set, 0, null);
        }
        c.vkCmdPushConstants(rec.cmd, rec.r.pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PushConstants), &pc);
        c.vkCmdDraw(rec.cmd, vertex_count, instance_count, 0, 0);
    }

    /// One instanced unit-quad draw per primitive in `items`.
    fn drawInstances(rec: *Recorder, pipeline: c.VkPipeline, comptime T: type, items: []const T, texture: ?*const vk.Image) !void {
        if (items.len == 0) return;
        var pc: PushConstants = .{ .instances = rec.push(std.mem.sliceAsBytes(items)), .viewport_size = rec.viewportSize() };
        if (texture) |t| pc.texture_size = .{ @floatFromInt(t.width), @floatFromInt(t.height) };
        try rec.draw(pipeline, if (texture) |t| t.view else null, pc, 6, @intCast(items.len));
    }

    fn atlasTexture(rec: *Recorder, id: AtlasTextureId) ?*const vk.Image {
        const list = &rec.r.atlas_textures[@backingInt(id.kind)];
        if (id.index >= list.items.len) return null;
        const t = &list.items[id.index].image;
        return if (t.handle != null) t else null;
    }

    fn drawBatches(rec: *Recorder, scene: *const Scene) !void {
        const r = rec.r;
        const p = &r.pipelines;
        var blur_index: usize = 0;
        var it = scene.batches();
        while (it.next()) |batch| {
            // Backdrop blurs interleave by draw order outside the batch stream (MR:999).
            const first = batch.firstOrder(scene);
            while (blur_index < scene.backdrop_blurs.items.len and scene.backdrop_blurs.items[blur_index].order <= first) : (blur_index += 1) {
                try rec.drawBackdropBlur(&scene.backdrop_blurs.items[blur_index]);
            }
            const range = batch.range();
            switch (batch) {
                .shadow => try rec.drawInstances(p.shadow, scene_mod.Shadow, scene.shadows.items[range.start..range.end], null),
                .quad => try rec.drawInstances(p.quad, scene_mod.Quad, scene.quads.items[range.start..range.end], null),
                .underline => try rec.drawInstances(p.underline, scene_mod.Underline, scene.underlines.items[range.start..range.end], null),
                .monochrome_sprite => |s| if (rec.atlasTexture(s.texture_id)) |t|
                    try rec.drawInstances(p.mono_sprite, scene_mod.MonochromeSprite, scene.monochrome_sprites.items[range.start..range.end], t),
                .subpixel_sprite => |s| if (rec.atlasTexture(s.texture_id)) |t|
                    try rec.drawInstances(p.subpixel_sprite, scene_mod.SubpixelSprite, scene.subpixel_sprites.items[range.start..range.end], t),
                .polychrome_sprite => |s| if (rec.atlasTexture(s.texture_id)) |t|
                    try rec.drawInstances(p.poly_sprite, scene_mod.PolychromeSprite, scene.polychrome_sprites.items[range.start..range.end], t),
                .path => try rec.drawPaths(scene.paths.items[range.start..range.end]),
                .viewport3d => for (range.start..range.end) |i| {
                    if (i >= r.three_targets.items.len) continue;
                    const v = scene.viewports3d.items[i];
                    const inst: scene_mod.Viewport3DInstance = .{
                        .bounds = v.bounds,
                        .content_mask = v.content_mask,
                        .corner_radii = v.corner_radii,
                        .exposure = v.scene3d.exposure,
                    };
                    try rec.drawInstances(p.viewport3d, scene_mod.Viewport3DInstance, &.{inst}, &r.three_targets.items[i].resolve);
                },
                .surface => if (!r.warned_surface) {
                    r.warned_surface = true;
                    log.warn("surfaces are not supported by the Vulkan renderer yet; skipping", .{});
                },
            }
        }
        // Blurs after the last batch still apply (they blur everything painted so far).
        while (blur_index < scene.backdrop_blurs.items.len) : (blur_index += 1) {
            try rec.drawBackdropBlur(&scene.backdrop_blurs.items[blur_index]);
        }
    }

    /// [three spike] Render every viewport's Scene3D into its offscreen HDR
    /// target: MSAA color + depth, resolved to a 1x RGBA16F texture that the
    /// `viewport3d` pipeline composites (tonemap + sRGB) in the main pass.
    fn renderViewports3D(rec: *Recorder, scene: *const Scene) !void {
        const r = rec.r;
        const dev = r.device.handle;
        const samples = r.threeSamples();
        const msaa = samples != c.VK_SAMPLE_COUNT_1_BIT;
        while (r.three_targets.items.len < scene.viewports3d.items.len) try r.three_targets.append(r.gpa, .{});
        for (scene.viewports3d.items, 0..) |v, vi| {
            const t = &r.three_targets.items[vi];
            const w: u32 = @intFromFloat(@max(@ceil(v.bounds.size.width), 1));
            const h: u32 = @intFromFloat(@max(@ceil(v.bounds.size.height), 1));
            if (t.resolve.handle == null or t.resolve.width != w or t.resolve.height != h) {
                if (t.resolve.handle != null) r.device.waitIdle();
                t.destroy(dev);
                const mp = &r.device.mem_props;
                t.resolve = try vk.Image.create(dev, mp, .{ .width = w, .height = h, .format = hdr_format, .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT });
                if (msaa) t.color = try vk.Image.create(dev, mp, .{ .width = w, .height = h, .format = hdr_format, .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT, .samples = samples });
                t.depth = try vk.Image.create(dev, mp, .{ .width = w, .height = h, .format = depth_format, .usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT, .samples = samples, .aspect = c.VK_IMAGE_ASPECT_DEPTH_BIT });
            }
            const s3 = v.scene3d;
            const aspect = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(h));
            const frame_addr = rec.push(std.mem.asBytes(&s3.frameUniforms(aspect, true)));

            t.resolve.transition(rec.cmd, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, true);
            if (msaa) t.color.transition(rec.cmd, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, true);
            t.depth.transition(rec.cmd, c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL, true);
            var color_att: c.VkRenderingAttachmentInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                .imageView = t.resolve.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
                .clearValue = .{ .color = .{ .float32 = s3.clear } },
            };
            if (msaa) {
                color_att.imageView = t.color.view;
                color_att.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
                color_att.resolveMode = c.VK_RESOLVE_MODE_AVERAGE_BIT;
                color_att.resolveImageView = t.resolve.view;
                color_att.resolveImageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            }
            const depth_att: c.VkRenderingAttachmentInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                .imageView = t.depth.view,
                .imageLayout = c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL,
                .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
                .clearValue = .{ .depthStencil = .{ .depth = 0, .stencil = 0 } },
            };
            const area: c.VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = w, .height = h } };
            c.vkCmdBeginRendering(rec.cmd, &.{
                .sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO,
                .renderArea = area,
                .layerCount = 1,
                .colorAttachmentCount = 1,
                .pColorAttachments = &color_att,
                .pDepthAttachment = &depth_att,
            });
            const vp: c.VkViewport = .{ .x = 0, .y = 0, .width = @floatFromInt(w), .height = @floatFromInt(h), .minDepth = 0, .maxDepth = 1 };
            c.vkCmdSetViewport(rec.cmd, 0, 1, &vp);
            c.vkCmdSetScissor(rec.cmd, 0, 1, &area);
            c.vkCmdBindPipeline(rec.cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, r.pipelines.mesh);
            rec.bound = r.pipelines.mesh;

            // Spike: meshes are copied into the frame buffer (deduplicated per viewport).
            const Uploaded = struct { mesh: *const three.Mesh, vertices: u64, indices: u64 };
            var uploaded: [64]Uploaded = undefined;
            var uploaded_len: usize = 0;
            for (s3.draws.items) |d| {
                var found: ?Uploaded = null;
                for (uploaded[0..uploaded_len]) |u| if (u.mesh == d.mesh) {
                    found = u;
                };
                const u = found orelse blk: {
                    const nu: Uploaded = .{
                        .mesh = d.mesh,
                        .vertices = rec.push(std.mem.sliceAsBytes(d.mesh.vertices)),
                        .indices = rec.push(std.mem.sliceAsBytes(d.mesh.indices)),
                    };
                    if (uploaded_len < uploaded.len) {
                        uploaded[uploaded_len] = nu;
                        uploaded_len += 1;
                    }
                    break :blk nu;
                };
                const data: three.DrawData = .{
                    .model = d.model,
                    .base_color = d.material.base_color,
                    .params = .{ d.material.metallic, d.material.roughness, 0, 0 },
                };
                const pc: Push3D = .{ .vertices = u.vertices, .indices = u.indices, .frame = frame_addr, .draw = rec.push(std.mem.asBytes(&data)) };
                c.vkCmdPushConstants(rec.cmd, r.three_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(Push3D), &pc);
                c.vkCmdDraw(rec.cmd, @intCast(d.mesh.indices.len), 1, 0, 0);
            }
            c.vkCmdEndRendering(rec.cmd);
            rec.bound = null;
            t.resolve.transition(rec.cmd, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);
        }
    }

    /// Rasterize paths into the MSAA intermediate, then composite (MR:1120-1160).
    fn drawPaths(rec: *Recorder, paths: []const scene_mod.Path) !void {
        if (paths.len == 0) return;
        const r = rec.r;
        const msaa = r.pathSampleCount() > 1;
        rec.endMain();
        try r.ensureImage(&r.path_resolve, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT, c.VK_SAMPLE_COUNT_1_BIT);
        if (msaa) try r.ensureImage(&r.path_msaa, c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT, c.VK_SAMPLE_COUNT_4_BIT);

        var vertex_count: usize = 0;
        for (paths) |path| vertex_count += path.vertices.items.len;
        const V = scene_mod.PathRasterizationVertex;
        const a = rec.alloc(vertex_count * @sizeOf(V));
        var out: [*]align(1) V = @ptrCast(a.bytes.ptr);
        for (paths) |path| {
            const clipped = path.clippedBounds();
            for (path.vertices.items) |v| {
                out[0] = .{ .xy_position = v.xy_position, .st_position = v.st_position, .color = path.color, .bounds = clipped };
                out += 1;
            }
        }

        r.path_resolve.transition(rec.cmd, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, true);
        var attachment: c.VkRenderingAttachmentInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = r.path_resolve.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .clearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } },
        };
        if (msaa) {
            r.path_msaa.transition(rec.cmd, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, true);
            attachment.imageView = r.path_msaa.view;
            attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
            attachment.resolveMode = c.VK_RESOLVE_MODE_AVERAGE_BIT;
            attachment.resolveImageView = r.path_resolve.view;
            attachment.resolveImageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        }
        rec.beginRendering(attachment, rec.fullArea(), rec.viewportSize());
        if (vertex_count > 0) {
            try rec.draw(r.pipelines.path_rasterization, null, .{ .instances = a.address, .viewport_size = rec.viewportSize() }, @intCast(vertex_count), 1);
        }
        c.vkCmdEndRendering(rec.cmd);
        r.path_resolve.transition(rec.cmd, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);

        rec.beginMain(false);
        // Copy each pixel once: per-path rects when all orders match (disjoint), else their union.
        const S = scene_mod.PathSprite;
        if (paths[paths.len - 1].order == paths[0].order) {
            const sprites = rec.alloc(paths.len * @sizeOf(S));
            const dst: [*]align(1) S = @ptrCast(sprites.bytes.ptr);
            for (paths, 0..) |path, i| dst[i] = .{ .bounds = path.clippedBounds() };
            try rec.draw(r.pipelines.path_sprite, r.path_resolve.view, .{ .instances = sprites.address, .viewport_size = rec.viewportSize() }, 6, @intCast(paths.len));
        } else {
            var bounds = paths[0].clippedBounds();
            for (paths[1..]) |path| bounds = bounds.unionWith(path.clippedBounds());
            const sprite: S = .{ .bounds = bounds };
            try rec.drawInstances(r.pipelines.path_sprite, S, &.{sprite}, &r.path_resolve);
        }
    }

    /// Snapshot the padded blur region, blur it (horizontal pass with
    /// downsampling, then vertical) and composite inside the rounded bounds.
    fn drawBackdropBlur(rec: *Recorder, blur: *const scene_mod.BackdropBlur) !void {
        const r = rec.r;
        if (!r.can_snapshot) return;
        const w: f32 = @floatFromInt(rec.target.width);
        const h: f32 = @floatFromInt(rec.target.height);
        const sigma = @max(blur.blur_radius, 1.0);
        const downsample = std.math.clamp(@floor(sigma / 8.0), 1.0, 4.0);
        const sigma_t = @max(sigma / downsample, 0.5);
        // Metal's padding (ceil(3σ)+2) plus two downsampled texels so the
        // separable passes never read outside the copied region.
        const pad = @ceil(sigma * 3.0) + 2.0 + 2.0 * downsample;
        const visible = blur.bounds.intersect(blur.content_mask.bounds);
        const x0 = @max(@floor(visible.origin.x - pad), 0);
        const y0 = @max(@floor(visible.origin.y - pad), 0);
        const x1 = @min(@ceil(visible.right() + pad), w);
        const y1 = @min(@ceil(visible.bottom() + pad), h);
        if (x1 <= x0 or y1 <= y0 or visible.isEmpty()) return;

        rec.endMain();
        const usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
        try r.ensureImage(&r.blur_scratch, c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT, c.VK_SAMPLE_COUNT_1_BIT);
        try r.ensureImage(&r.blur_a, usage, c.VK_SAMPLE_COUNT_1_BIT);
        try r.ensureImage(&r.blur_b, usage, c.VK_SAMPLE_COUNT_1_BIT);

        // 1. Snapshot.
        rec.target.transition(rec.cmd, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, false);
        r.blur_scratch.transition(rec.cmd, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, true);
        const ix0: i32 = @intFromFloat(x0);
        const iy0: i32 = @intFromFloat(y0);
        const subresource: c.VkImageSubresourceLayers = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
        const copy: c.VkImageCopy = .{
            .srcSubresource = subresource,
            .srcOffset = .{ .x = ix0, .y = iy0, .z = 0 },
            .dstSubresource = subresource,
            .dstOffset = .{ .x = ix0, .y = iy0, .z = 0 },
            .extent = .{ .width = @intFromFloat(x1 - x0), .height = @intFromFloat(y1 - y0), .depth = 1 },
        };
        c.vkCmdCopyImage(rec.cmd, rec.target.handle, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, r.blur_scratch.handle, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
        rec.target.transition(rec.cmd, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, false);
        r.blur_scratch.transition(rec.cmd, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);

        // 2. Separable gaussian in a `downsample`-scaled grid.
        const bw = @ceil(w / downsample);
        const bh = @ceil(h / downsample);
        const bx0 = @max(@floor(x0 / downsample), 0);
        const by0 = @max(@floor(y0 / downsample), 0);
        const bx1 = @min(@ceil(x1 / downsample), bw);
        const by1 = @min(@ceil(y1 / downsample), bh);
        const area: c.VkRect2D = .{
            .offset = .{ .x = @intFromFloat(bx0), .y = @intFromFloat(by0) },
            .extent = .{ .width = @intFromFloat(bx1 - bx0), .height = @intFromFloat(by1 - by0) },
        };
        const tex_size: [2]f32 = .{ w, h };
        try rec.blurPass(&r.blur_a, &r.blur_scratch, area, .{ bw, bh }, .{
            .texture_size = tex_size,
            .params0 = .{ 1, 0, sigma_t, downsample },
            .params1 = .{ downsample, w, h, 0 },
        });
        try rec.blurPass(&r.blur_b, &r.blur_a, area, .{ bw, bh }, .{
            .texture_size = tex_size,
            .params0 = .{ 0, 1, sigma_t, 1 },
            .params1 = .{ 1, bw, bh, 0 },
        });

        // 3. Composite (blending disabled; the shader discards outside the rounded rect).
        rec.beginMain(false);
        try rec.draw(r.pipelines.backdrop_blur, r.blur_b.view, .{
            .instances = rec.push(std.mem.asBytes(blur)),
            .viewport_size = rec.viewportSize(),
            .texture_size = tex_size,
            .params0 = .{ downsample, bw, bh, 0 },
        }, 6, 1);
    }

    fn blurPass(rec: *Recorder, dst: *vk.Image, src: *const vk.Image, area: c.VkRect2D, viewport: [2]f32, pc: PushConstants) !void {
        dst.transition(rec.cmd, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, true);
        rec.beginRendering(.{
            .sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
            .imageView = dst.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        }, area, viewport);
        try rec.draw(rec.r.pipelines.blur_pass, src.view, pc, 3, 1);
        c.vkCmdEndRendering(rec.cmd);
        dst.transition(rec.cmd, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, false);
    }
};
