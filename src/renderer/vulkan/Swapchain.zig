//! Swapchain for a platform `VkSurfaceKHR`: creation/recreation on resize,
//! image acquisition and presentation. Prefers a UNORM BGRA format so blending
//! happens in display (gamma) space exactly like zui's Metal renderer.

const std = @import("std");
const vk = @import("vk.zig");
const c = vk.c;
const Device = @import("Device.zig");

const Swapchain = @This();

pub const max_images = 8;

handle: c.VkSwapchainKHR = null,
format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
images: [max_images]c.VkImage = @splat(null),
views: [max_images]c.VkImageView = @splat(null),
/// Signaled when rendering to image `i` finished; waited on by present.
render_done: [max_images]c.VkSemaphore = @splat(null),
image_count: u32 = 0,

/// Pick the surface format once (stable across resizes so pipelines stay valid).
pub fn chooseFormat(device: *const Device) !c.VkFormat {
    var count: u32 = 0;
    try vk.check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device.physical, device.surface, &count, null));
    var formats: [64]c.VkSurfaceFormatKHR = undefined;
    count = @min(count, formats.len);
    try vk.check(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device.physical, device.surface, &count, &formats));
    if (count == 0) return error.NoSurfaceFormats;
    for ([_]c.VkFormat{ c.VK_FORMAT_B8G8R8A8_UNORM, c.VK_FORMAT_R8G8B8A8_UNORM }) |want| {
        for (formats[0..count]) |f| if (f.format == want) return want;
    }
    return formats[0].format;
}

/// (Re)create for `width`x`height`, reusing `self.handle` as the old swapchain.
pub fn recreate(self: *Swapchain, device: *const Device, format: c.VkFormat, width: u32, height: u32, transparent: bool) !void {
    var caps: c.VkSurfaceCapabilitiesKHR = undefined;
    try vk.check(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device.physical, device.surface, &caps));
    var extent: c.VkExtent2D = .{ .width = width, .height = height };
    if (caps.currentExtent.width != std.math.maxInt(u32)) extent = caps.currentExtent;
    extent.width = std.math.clamp(extent.width, @max(caps.minImageExtent.width, 1), @max(caps.maxImageExtent.width, 1));
    extent.height = std.math.clamp(extent.height, @max(caps.minImageExtent.height, 1), @max(caps.maxImageExtent.height, 1));
    var image_count = caps.minImageCount + 1;
    if (caps.maxImageCount != 0) image_count = @min(image_count, caps.maxImageCount);
    image_count = @min(image_count, max_images);

    const alpha_modes = [_]c.VkCompositeAlphaFlagBitsKHR{
        c.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR, c.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
        c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,         c.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
    };
    var composite_alpha: c.VkCompositeAlphaFlagBitsKHR = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    for (alpha_modes[(if (transparent) 0 else 2)..]) |m| {
        if (caps.supportedCompositeAlpha & m != 0) {
            composite_alpha = m;
            break;
        }
    }
    // Backdrop blur snapshots copy out of the drawable.
    var usage: c.VkImageUsageFlags = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    if (caps.supportedUsageFlags & c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT != 0) usage |= c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;

    const old = self.handle;
    var handle: c.VkSwapchainKHR = null;
    try vk.check(c.vkCreateSwapchainKHR(device.handle, &.{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = device.surface,
        .minImageCount = image_count,
        .imageFormat = format,
        .imageColorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = usage,
        .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform,
        .compositeAlpha = composite_alpha,
        .presentMode = c.VK_PRESENT_MODE_FIFO_KHR,
        .clipped = c.VK_TRUE,
        .oldSwapchain = old,
    }, null, &handle));
    self.destroyViews(device);
    if (old != null) c.vkDestroySwapchainKHR(device.handle, old, null);
    self.handle = handle;
    self.format = format;
    self.extent = extent;
    var count: u32 = 0;
    try vk.check(c.vkGetSwapchainImagesKHR(device.handle, handle, &count, null));
    count = @min(count, max_images);
    try vk.check(c.vkGetSwapchainImagesKHR(device.handle, handle, &count, &self.images));
    self.image_count = count;
    for (0..count) |i| {
        self.views[i] = try vk.createView(device.handle, self.images[i], format);
        try vk.check(c.vkCreateSemaphore(device.handle, &.{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO }, null, &self.render_done[i]));
    }
}

fn destroyViews(self: *Swapchain, device: *const Device) void {
    for (0..self.image_count) |i| {
        c.vkDestroyImageView(device.handle, self.views[i], null);
        c.vkDestroySemaphore(device.handle, self.render_done[i], null);
        self.views[i] = null;
        self.render_done[i] = null;
    }
    self.image_count = 0;
}

pub fn deinit(self: *Swapchain, device: *const Device) void {
    self.destroyViews(device);
    if (self.handle != null) c.vkDestroySwapchainKHR(device.handle, self.handle, null);
    self.* = .{};
}

/// Index of the next image, signaling `acquired` when it is ready. `error.OutOfDate` means recreate.
pub fn acquire(self: *Swapchain, device: *const Device, acquired: c.VkSemaphore) vk.Error!u32 {
    var index: u32 = 0;
    try vk.check(c.vkAcquireNextImageKHR(device.handle, self.handle, std.math.maxInt(u64), acquired, null, &index));
    return index;
}

/// Present image `index` after `render_done[index]`. Returns false if the swapchain should be recreated.
pub fn present(self: *Swapchain, device: *const Device, index: u32) vk.Error!bool {
    const result = c.vkQueuePresentKHR(device.queue, &.{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &self.render_done[index],
        .swapchainCount = 1,
        .pSwapchains = &self.handle,
        .pImageIndices = &index,
    });
    if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR) return false;
    try vk.check(result);
    return true;
}
