//! Thin helpers over the raw Vulkan C API (translate-c'd `vulkan/vulkan.h`,
//! provided by build.zig as the named `vk_c` module): result checking, memory
//! type selection, buffers, images and layout transitions.

const std = @import("std");
pub const c = @import("vk_c");

const log = std.log.scoped(.vulkan);

pub const Error = error{
    VulkanFailed,
    OutOfDate,
    DeviceLost,
    OutOfDeviceMemory,
    OutOfHostMemory,
    NoSuitableMemoryType,
};

/// Map a `VkResult` to an error. Non-negative codes (e.g. `VK_SUBOPTIMAL_KHR`) succeed.
pub fn check(result: c.VkResult) Error!void {
    if (result >= 0) return;
    return switch (result) {
        c.VK_ERROR_OUT_OF_DATE_KHR => error.OutOfDate,
        c.VK_ERROR_DEVICE_LOST => error.DeviceLost,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.OutOfDeviceMemory,
        c.VK_ERROR_OUT_OF_HOST_MEMORY => error.OutOfHostMemory,
        else => {
            log.err("vulkan call failed: VkResult {d}", .{result});
            return error.VulkanFailed;
        },
    };
}

pub fn findMemoryType(props: *const c.VkPhysicalDeviceMemoryProperties, type_bits: u32, want: c.VkMemoryPropertyFlags) Error!u32 {
    for (0..props.memoryTypeCount) |i| {
        if (type_bits & (@as(u32, 1) << @intCast(i)) != 0 and props.memoryTypes[i].propertyFlags & want == want)
            return @intCast(i);
    }
    return error.NoSuitableMemoryType;
}

/// A buffer with its own memory allocation. Host-visible buffers stay mapped.
pub const Buffer = struct {
    handle: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    size: usize = 0,
    mapped: ?[*]u8 = null,
    /// Device address (`VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT` buffers only).
    address: u64 = 0,

    pub fn create(
        device: c.VkDevice,
        mem_props: *const c.VkPhysicalDeviceMemoryProperties,
        size: usize,
        usage: c.VkBufferUsageFlags,
        properties: c.VkMemoryPropertyFlags,
    ) Error!Buffer {
        var self: Buffer = .{ .size = size };
        errdefer self.destroy(device);
        try check(c.vkCreateBuffer(device, &.{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = size,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        }, null, &self.handle));
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(device, self.handle, &req);
        const wants_address = usage & c.VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT != 0;
        const flags_info: c.VkMemoryAllocateFlagsInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO,
            .flags = c.VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT,
        };
        try check(c.vkAllocateMemory(device, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = if (wants_address) &flags_info else null,
            .allocationSize = req.size,
            .memoryTypeIndex = try findMemoryType(mem_props, req.memoryTypeBits, properties),
        }, null, &self.memory));
        try check(c.vkBindBufferMemory(device, self.handle, self.memory, 0));
        if (properties & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT != 0) {
            var ptr: ?*anyopaque = null;
            try check(c.vkMapMemory(device, self.memory, 0, c.VK_WHOLE_SIZE, 0, &ptr));
            self.mapped = @ptrCast(ptr);
        }
        if (wants_address) {
            self.address = c.vkGetBufferDeviceAddress(device, &.{
                .sType = c.VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO,
                .buffer = self.handle,
            });
        }
        return self;
    }

    pub fn destroy(self: *Buffer, device: c.VkDevice) void {
        if (self.handle != null) c.vkDestroyBuffer(device, self.handle, null);
        if (self.memory != null) c.vkFreeMemory(device, self.memory, null);
        self.* = .{};
    }
};

/// A 2D color image with its own memory, one view, and its tracked layout.
pub const Image = struct {
    handle: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    width: u32 = 0,
    height: u32 = 0,
    format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    aspect: c.VkImageAspectFlags = c.VK_IMAGE_ASPECT_COLOR_BIT,
    mip_levels: u32 = 1,

    pub const Options = struct {
        width: u32,
        height: u32,
        format: c.VkFormat,
        usage: c.VkImageUsageFlags,
        samples: c.VkSampleCountFlagBits = c.VK_SAMPLE_COUNT_1_BIT,
        aspect: c.VkImageAspectFlags = c.VK_IMAGE_ASPECT_COLOR_BIT,
        mip_levels: u32 = 1,
    };

    pub fn create(device: c.VkDevice, mem_props: *const c.VkPhysicalDeviceMemoryProperties, opts: Options) Error!Image {
        var self: Image = .{ .width = opts.width, .height = opts.height, .format = opts.format, .aspect = opts.aspect, .mip_levels = opts.mip_levels };
        errdefer self.destroy(device);
        try check(c.vkCreateImage(device, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = opts.format,
            .extent = .{ .width = opts.width, .height = opts.height, .depth = 1 },
            .mipLevels = opts.mip_levels,
            .arrayLayers = 1,
            .samples = opts.samples,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = opts.usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        }, null, &self.handle));
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(device, self.handle, &req);
        try check(c.vkAllocateMemory(device, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = req.size,
            .memoryTypeIndex = try findMemoryType(mem_props, req.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
        }, null, &self.memory));
        try check(c.vkBindImageMemory(device, self.handle, self.memory, 0));
        self.view = try createViewLevels(device, self.handle, opts.format, opts.aspect, opts.mip_levels);
        return self;
    }

    pub fn destroy(self: *Image, device: c.VkDevice) void {
        if (self.view != null) c.vkDestroyImageView(device, self.view, null);
        if (self.handle != null) c.vkDestroyImage(device, self.handle, null);
        if (self.memory != null) c.vkFreeMemory(device, self.memory, null);
        self.* = .{};
    }

    /// Record a layout transition from the tracked layout. `discard` treats the old contents as undefined.
    pub fn transition(self: *Image, cmd: c.VkCommandBuffer, new_layout: c.VkImageLayout, discard: bool) void {
        // Even when discarding, wait on the previous use (write-after-read hazards).
        const old_layout: c.VkImageLayout = if (discard) c.VK_IMAGE_LAYOUT_UNDEFINED else self.layout;
        barrierAspect(cmd, self.handle, self.aspect, layoutScope(self.layout), old_layout, new_layout);
        self.layout = new_layout;
    }
};

pub fn createView(device: c.VkDevice, image: c.VkImage, format: c.VkFormat) Error!c.VkImageView {
    return createViewAspect(device, image, format, c.VK_IMAGE_ASPECT_COLOR_BIT);
}

pub fn createViewAspect(device: c.VkDevice, image: c.VkImage, format: c.VkFormat, aspect: c.VkImageAspectFlags) Error!c.VkImageView {
    return createViewLevels(device, image, format, aspect, 1);
}

pub fn createViewLevels(device: c.VkDevice, image: c.VkImage, format: c.VkFormat, aspect: c.VkImageAspectFlags, levels: u32) Error!c.VkImageView {
    var range = color_range;
    range.aspectMask = aspect;
    range.levelCount = levels;
    var view: c.VkImageView = null;
    try check(c.vkCreateImageView(device, &.{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .subresourceRange = range,
    }, null, &view));
    return view;
}

pub const color_range: c.VkImageSubresourceRange = .{
    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
    .baseMipLevel = 0,
    .levelCount = 1,
    .baseArrayLayer = 0,
    .layerCount = 1,
};

const StageAccess = struct { stage: c.VkPipelineStageFlags2, access: c.VkAccessFlags2 };

fn layoutScope(layout: c.VkImageLayout) StageAccess {
    return switch (layout) {
        c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL => .{
            .stage = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            .access = c.VK_ACCESS_2_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        },
        c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL => .{
            .stage = c.VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
            .access = c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_READ_BIT | c.VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        },
        c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL => .{
            .stage = c.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            .access = c.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
        },
        c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL => .{
            .stage = c.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
            .access = c.VK_ACCESS_2_TRANSFER_READ_BIT,
        },
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL => .{
            .stage = c.VK_PIPELINE_STAGE_2_ALL_TRANSFER_BIT,
            .access = c.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        },
        // UNDEFINED / PRESENT_SRC: nothing to wait for or make available, but
        // chain with the acquire semaphore wait stage.
        else => .{ .stage = c.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT, .access = 0 },
    };
}

/// Full-image layout transition with stage/access masks derived from the layouts.
pub fn barrier(cmd: c.VkCommandBuffer, image: c.VkImage, old_layout: c.VkImageLayout, new_layout: c.VkImageLayout) void {
    barrierFrom(cmd, image, layoutScope(old_layout), old_layout, new_layout);
}

fn barrierFrom(cmd: c.VkCommandBuffer, image: c.VkImage, src: StageAccess, old_layout: c.VkImageLayout, new_layout: c.VkImageLayout) void {
    barrierAspect(cmd, image, c.VK_IMAGE_ASPECT_COLOR_BIT, src, old_layout, new_layout);
}

fn barrierAspect(cmd: c.VkCommandBuffer, image: c.VkImage, aspect: c.VkImageAspectFlags, src: StageAccess, old_layout: c.VkImageLayout, new_layout: c.VkImageLayout) void {
    var range = color_range;
    range.aspectMask = aspect;
    range.levelCount = c.VK_REMAINING_MIP_LEVELS;
    var dst = layoutScope(new_layout);
    if (new_layout == c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR) dst = .{ .stage = c.VK_PIPELINE_STAGE_2_NONE, .access = 0 };
    const b: c.VkImageMemoryBarrier2 = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = src.stage,
        .srcAccessMask = src.access,
        .dstStageMask = dst.stage,
        .dstAccessMask = dst.access,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = range,
    };
    c.vkCmdPipelineBarrier2(cmd, &.{
        .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &b,
    });
}
