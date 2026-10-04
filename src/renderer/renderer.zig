//! Backend-agnostic renderer interface. `Renderer` is selected at compile
//! time by target OS: Metal on Apple platforms, Vulkan elsewhere. Every
//! backend exposes the same API:
//!
//!   init(gpa, options) !Renderer
//!   deinit(*Renderer) void
//!   atlas(*Renderer) *Atlas                 // backend owns the GPU textures
//!   drawScene(*Renderer, scene: *const Scene, viewport: Size(DevicePixels),
//!             scale_factor: f32, clear: Hsla) !void
//!   readPixels(*Renderer, gpa) ![]u8        // RGBA8, offscreen targets only
//!   resize(*Renderer, size: Size(DevicePixels)) !void
//!
//! The framebuffer holds premultiplied color: primitives are composited with
//! source-over and `clear` is premultiplied before clearing. `readPixels`
//! returns that premultiplied RGBA8 data, rows top-down, tightly packed.
//! Scene primitives are already in device pixels; `scale_factor` is
//! informational.
//!
//! Vulkan extras (src/renderer/vulkan/Renderer.zig): `createOffscreen(gpa,
//! size)`, `createForSurface(gpa, VulkanSurface, size, transparent)`,
//! `validationErrors()`.

const std = @import("std");
const builtin = @import("builtin");
const geometry = @import("../geometry.zig");
const Atlas = @import("../atlas.zig").Atlas;

pub const Backend = enum { metal, vulkan };

pub const backend: Backend = if (builtin.os.tag.isDarwin()) .metal else .vulkan;

pub const Renderer = switch (backend) {
    .metal => @import("metal/renderer.zig").MetalRenderer,
    .vulkan => @import("vulkan/Renderer.zig"),
};

/// Options shared by every backend.
pub const Options = struct {
    /// Initial target size in device pixels (offscreen texture or drawable).
    size: geometry.Size(geometry.DevicePixels),
    /// Window surface to present to; null renders offscreen (see `readPixels`).
    surface: ?Surface = null,
    /// Keep alpha in the output (transparent windows). Opaque targets let the
    /// compositor skip blending.
    transparent: bool = false,
    /// Atlas texture sizes (backends clamp `max_size` to the device limit).
    atlas: Atlas.Options = .{},
    /// Enable API validation when available (Vulkan: VK_LAYER_KHRONOS_validation).
    validation: bool = builtin.mode == .debug,
};

/// Native presentation targets.
pub const Surface = union(enum) {
    /// macOS: an existing `CAMetalLayer*` to render into, or null to have the
    /// renderer create one (fetch it with `Renderer.layer()` and attach it to a view).
    metal_layer: ?*anyopaque,
    /// Linux/Windows: the platform layer creates a `VkSurfaceKHR` from the renderer's instance.
    vulkan: VulkanSurface,
};

/// How the Vulkan renderer obtains its `VkSurfaceKHR` (it owns the instance,
/// so the platform layer supplies a callback instead of a finished surface).
pub const VulkanSurface = struct {
    /// Instance extensions the surface needs besides `VK_KHR_surface`
    /// (e.g. `VK_KHR_xcb_surface`, `VK_KHR_wayland_surface`, `VK_KHR_win32_surface`).
    instance_extensions: []const [*:0]const u8,
    context: ?*anyopaque = null,
    /// Returns the `VkSurfaceKHR` (as an integer handle) for `instance` (a `VkInstance`).
    create: *const fn (context: ?*anyopaque, instance: *anyopaque) anyerror!u64,
};

test {
    if (backend == .metal) _ = Renderer;
    if (backend == .vulkan) std.testing.refAllDecls(Renderer);
    _ = @import("metal/instance_buffer_pool.zig");
    _ = @import("metal/backdrop.zig");
}
