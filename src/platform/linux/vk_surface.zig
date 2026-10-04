//! `VkSurfaceKHR` creation for Wayland and XCB windows, handed to the renderer as a
//! `renderer.VulkanSurface` callback (the renderer owns the `VkInstance`).
//!
//! The shared `vk_c` translation of vulkan.h is built without the platform WSI macros,
//! so the two `VK_KHR_*_surface` entry points and create-info structs are declared here.

const std = @import("std");
const vk = @import("vk_c");
const renderer = @import("../../renderer/renderer.zig");

const VkWaylandSurfaceCreateInfoKHR = extern struct {
    sType: vk.VkStructureType = 1000006000, // VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    display: *anyopaque,
    surface: *anyopaque,
};

const VkXcbSurfaceCreateInfoKHR = extern struct {
    sType: vk.VkStructureType = 1000005000, // VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR
    pNext: ?*const anyopaque = null,
    flags: u32 = 0,
    connection: *anyopaque,
    window: u32,
};

extern fn vkCreateWaylandSurfaceKHR(instance: vk.VkInstance, info: *const VkWaylandSurfaceCreateInfoKHR, allocator: ?*const vk.VkAllocationCallbacks, surface: *vk.VkSurfaceKHR) vk.VkResult;
extern fn vkCreateXcbSurfaceKHR(instance: vk.VkInstance, info: *const VkXcbSurfaceCreateInfoKHR, allocator: ?*const vk.VkAllocationCallbacks, surface: *vk.VkSurfaceKHR) vk.VkResult;

/// A native window the renderer can present to. Must outlive the renderer.
pub const Target = union(enum) {
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    xcb: struct { connection: *anyopaque, window: u32 },

    const wayland_exts = [_][*:0]const u8{"VK_KHR_wayland_surface"};
    const xcb_exts = [_][*:0]const u8{"VK_KHR_xcb_surface"};

    pub fn vulkanSurface(t: *Target) renderer.VulkanSurface {
        return .{
            .instance_extensions = switch (t.*) {
                .wayland => &wayland_exts,
                .xcb => &xcb_exts,
            },
            .context = t,
            .create = create,
        };
    }

    fn create(ctx: ?*anyopaque, instance: *anyopaque) anyerror!u64 {
        const t: *Target = @ptrCast(@alignCast(ctx.?));
        const inst: vk.VkInstance = @ptrCast(instance);
        var surface: vk.VkSurfaceKHR = null;
        const rc = switch (t.*) {
            .wayland => |w| vkCreateWaylandSurfaceKHR(inst, &.{ .display = w.display, .surface = w.surface }, null, &surface),
            .xcb => |x| vkCreateXcbSurfaceKHR(inst, &.{ .connection = x.connection, .window = x.window }, null, &surface),
        };
        if (rc != vk.VK_SUCCESS or surface == null) return error.VulkanSurfaceCreationFailed;
        return @intFromPtr(surface);
    }
};
