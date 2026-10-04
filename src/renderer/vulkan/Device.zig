//! Vulkan instance, physical/logical device and queue. Works headless (no
//! surface) or with a `VkSurfaceKHR` created by the platform layer from this
//! instance (see `SurfaceSource`). Requires Vulkan 1.3 with dynamic
//! rendering, synchronization2, buffer device address, scalar block layout
//! and shader clip distances; dual-source blending is optional.

const std = @import("std");
const vk = @import("vk.zig");
const c = vk.c;

const Device = @This();
const log = std.log.scoped(.vulkan);

instance: c.VkInstance = null,
debug_messenger: c.VkDebugUtilsMessengerEXT = null,
surface: c.VkSurfaceKHR = null,
physical: c.VkPhysicalDevice = null,
handle: c.VkDevice = null,
queue: c.VkQueue = null,
queue_family: u32 = 0,
mem_props: c.VkPhysicalDeviceMemoryProperties = undefined,
limits: c.VkPhysicalDeviceLimits = undefined,
dual_source_blend: bool = false,
validation: bool = false,

/// Lets the platform layer create a `VkSurfaceKHR` once the instance exists.
pub const SurfaceSource = @import("../renderer.zig").VulkanSurface;

/// A `SurfaceSource` backed by `VK_EXT_headless_surface`: exercises the
/// swapchain path without a display server (CI, tests).
pub const headless_surface: SurfaceSource = .{
    .instance_extensions = &.{"VK_EXT_headless_surface"},
    .create = createHeadlessSurface,
};

fn createHeadlessSurface(_: ?*anyopaque, instance_ptr: *anyopaque) anyerror!u64 {
    const instance: c.VkInstance = @ptrCast(instance_ptr);
    const create_fn: c.PFN_vkCreateHeadlessSurfaceEXT = @ptrCast(c.vkGetInstanceProcAddr(instance, "vkCreateHeadlessSurfaceEXT"));
    const f = create_fn orelse return error.HeadlessSurfaceUnsupported;
    var surface: c.VkSurfaceKHR = null;
    try vk.check(f(instance, &.{ .sType = c.VK_STRUCTURE_TYPE_HEADLESS_SURFACE_CREATE_INFO_EXT }, null, &surface));
    return @intFromPtr(surface);
}

pub const Options = struct {
    /// Enable `VK_LAYER_KHRONOS_validation` + debug messenger when installed.
    validation: bool = false,
    surface: ?SurfaceSource = null,
};

/// Validation messages of error severity seen so far (all devices).
pub var validation_error_count: std.atomic.Value(u32) = .init(0);

pub fn init(opts: Options) !Device {
    var self: Device = .{};
    errdefer self.deinit();

    // Instance.
    var layers: [1][*:0]const u8 = undefined;
    var layer_count: u32 = 0;
    var exts: [16][*:0]const u8 = undefined;
    var ext_count: usize = 0;
    if (opts.validation and hasInstanceLayer("VK_LAYER_KHRONOS_validation")) {
        layers[0] = "VK_LAYER_KHRONOS_validation";
        layer_count = 1;
        exts[ext_count] = c.VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
        ext_count += 1;
        self.validation = true;
    } else if (opts.validation) {
        log.warn("VK_LAYER_KHRONOS_validation not installed; running without validation", .{});
    }
    if (opts.surface) |s| {
        exts[ext_count] = c.VK_KHR_SURFACE_EXTENSION_NAME;
        ext_count += 1;
        for (s.instance_extensions) |e| {
            if (ext_count == exts.len) return error.TooManyExtensions;
            exts[ext_count] = e;
            ext_count += 1;
        }
    }
    const app_info: c.VkApplicationInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "zpui",
        .pEngineName = "zpui",
        .apiVersion = c.VK_API_VERSION_1_3,
    };
    const messenger_info: c.VkDebugUtilsMessengerCreateInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
            c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = debugCallback,
    };
    try vk.check(c.vkCreateInstance(&.{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = if (self.validation) &messenger_info else null,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = layer_count,
        .ppEnabledLayerNames = &layers,
        .enabledExtensionCount = @intCast(ext_count),
        .ppEnabledExtensionNames = &exts,
    }, null, &self.instance));
    if (self.validation) {
        const create_fn: c.PFN_vkCreateDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(self.instance, "vkCreateDebugUtilsMessengerEXT"));
        if (create_fn) |f| try vk.check(f(self.instance, &messenger_info, null, &self.debug_messenger));
    }
    if (opts.surface) |s| {
        const raw = try s.create(s.context, @ptrCast(self.instance.?));
        self.surface = @ptrFromInt(raw);
    }

    // Physical device: prefer discrete, then integrated, then anything (lavapipe).
    var count: u32 = 0;
    try vk.check(c.vkEnumeratePhysicalDevices(self.instance, &count, null));
    var devices: [16]c.VkPhysicalDevice = undefined;
    count = @min(count, devices.len);
    try vk.check(c.vkEnumeratePhysicalDevices(self.instance, &count, &devices));
    var best_score: i32 = -1;
    for (devices[0..count]) |pd| {
        const family = self.pickQueueFamily(pd) orelse continue;
        var props: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(pd, &props);
        if (props.apiVersion < c.VK_API_VERSION_1_3) continue;
        if (!supportsRequiredFeatures(pd)) continue;
        if (self.surface != null and !hasDeviceExtension(pd, c.VK_KHR_SWAPCHAIN_EXTENSION_NAME)) continue;
        const score: i32 = switch (props.deviceType) {
            c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 3,
            c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 2,
            c.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 1,
            else => 0,
        };
        if (score > best_score) {
            best_score = score;
            self.physical = pd;
            self.queue_family = family;
            self.limits = props.limits;
        }
    }
    if (self.physical == null) return error.NoSuitableVulkanDevice;
    c.vkGetPhysicalDeviceMemoryProperties(self.physical, &self.mem_props);
    var features: c.VkPhysicalDeviceFeatures = undefined;
    c.vkGetPhysicalDeviceFeatures(self.physical, &features);
    self.dual_source_blend = features.dualSrcBlend == c.VK_TRUE;

    // Logical device.
    var f13: c.VkPhysicalDeviceVulkan13Features = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .dynamicRendering = c.VK_TRUE,
        .synchronization2 = c.VK_TRUE,
    };
    var f12: c.VkPhysicalDeviceVulkan12Features = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
        .pNext = &f13,
        .bufferDeviceAddress = c.VK_TRUE,
        .scalarBlockLayout = c.VK_TRUE,
    };
    const f10: c.VkPhysicalDeviceFeatures2 = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &f12,
        .features = .{
            .shaderClipDistance = c.VK_TRUE,
            .dualSrcBlend = if (self.dual_source_blend) c.VK_TRUE else c.VK_FALSE,
        },
    };
    const priority: f32 = 1.0;
    const queue_info: c.VkDeviceQueueCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = self.queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    const device_exts = [_][*:0]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
    try vk.check(c.vkCreateDevice(self.physical, &.{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &f10,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledExtensionCount = if (self.surface != null) 1 else 0,
        .ppEnabledExtensionNames = &device_exts,
    }, null, &self.handle));
    c.vkGetDeviceQueue(self.handle, self.queue_family, 0, &self.queue);
    return self;
}

pub fn deinit(self: *Device) void {
    if (self.handle != null) {
        _ = c.vkDeviceWaitIdle(self.handle);
        c.vkDestroyDevice(self.handle, null);
    }
    if (self.surface != null) c.vkDestroySurfaceKHR(self.instance, self.surface, null);
    if (self.debug_messenger != null) {
        const destroy_fn: c.PFN_vkDestroyDebugUtilsMessengerEXT = @ptrCast(c.vkGetInstanceProcAddr(self.instance, "vkDestroyDebugUtilsMessengerEXT"));
        if (destroy_fn) |f| f(self.instance, self.debug_messenger, null);
    }
    if (self.instance != null) c.vkDestroyInstance(self.instance, null);
    self.* = .{};
}

pub fn waitIdle(self: *const Device) void {
    _ = c.vkDeviceWaitIdle(self.handle);
}

fn pickQueueFamily(self: *const Device, pd: c.VkPhysicalDevice) ?u32 {
    var count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(pd, &count, null);
    var families: [32]c.VkQueueFamilyProperties = undefined;
    count = @min(count, families.len);
    c.vkGetPhysicalDeviceQueueFamilyProperties(pd, &count, &families);
    for (families[0..count], 0..) |f, i| {
        if (f.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) continue;
        if (self.surface != null) {
            var present: c.VkBool32 = c.VK_FALSE;
            _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(pd, @intCast(i), self.surface, &present);
            if (present != c.VK_TRUE) continue;
        }
        return @intCast(i);
    }
    return null;
}

fn supportsRequiredFeatures(pd: c.VkPhysicalDevice) bool {
    var f13: c.VkPhysicalDeviceVulkan13Features = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES };
    var f12: c.VkPhysicalDeviceVulkan12Features = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &f13 };
    var f: c.VkPhysicalDeviceFeatures2 = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &f12 };
    c.vkGetPhysicalDeviceFeatures2(pd, &f);
    return f13.dynamicRendering == c.VK_TRUE and f13.synchronization2 == c.VK_TRUE and
        f12.bufferDeviceAddress == c.VK_TRUE and f12.scalarBlockLayout == c.VK_TRUE and
        f.features.shaderClipDistance == c.VK_TRUE;
}

fn hasInstanceLayer(name: []const u8) bool {
    var count: u32 = 0;
    _ = c.vkEnumerateInstanceLayerProperties(&count, null);
    var props: [64]c.VkLayerProperties = undefined;
    count = @min(count, props.len);
    _ = c.vkEnumerateInstanceLayerProperties(&count, &props);
    for (props[0..count]) |p| {
        if (std.mem.eql(u8, std.mem.sliceTo(&p.layerName, 0), name)) return true;
    }
    return false;
}

fn hasDeviceExtension(pd: c.VkPhysicalDevice, name: [*:0]const u8) bool {
    var count: u32 = 0;
    _ = c.vkEnumerateDeviceExtensionProperties(pd, null, &count, null);
    var props: [512]c.VkExtensionProperties = undefined;
    count = @min(count, props.len);
    _ = c.vkEnumerateDeviceExtensionProperties(pd, null, &count, &props);
    for (props[0..count]) |p| {
        if (std.mem.eql(u8, std.mem.sliceTo(&p.extensionName, 0), std.mem.span(name))) return true;
    }
    return false;
}

fn debugCallback(
    severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    types: c.VkDebugUtilsMessageTypeFlagsEXT,
    data: [*c]const c.VkDebugUtilsMessengerCallbackDataEXT,
    user: ?*anyopaque,
) callconv(.c) c.VkBool32 {
    _ = types;
    _ = user;
    const msg: [*:0]const u8 = if (data != null and data.*.pMessage != null) data.*.pMessage else "(no message)";
    if (severity & c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT != 0) {
        _ = validation_error_count.fetchAdd(1, .monotonic);
        log.err("validation: {s}", .{msg});
    } else {
        log.warn("validation: {s}", .{msg});
    }
    return c.VK_FALSE;
}
