//! Owns a window's Vulkan renderer (src/renderer) and its native surface target.

const std = @import("std");
const renderer_mod = @import("../../renderer/renderer.zig");
const scene_mod = @import("../../scene.zig");
const color = @import("../../color.zig");
const atlas_mod = @import("../../atlas.zig");
const vk_surface = @import("vk_surface.zig");

pub const Renderer = renderer_mod.Renderer;

pub const Presenter = struct {
    /// Heap-allocated so the renderer's surface callback context stays valid.
    target: *vk_surface.Target,
    renderer: Renderer,
    transparent: bool,

    pub fn init(gpa: std.mem.Allocator, target: vk_surface.Target, width: u32, height: u32, transparent: bool) !Presenter {
        const t = try gpa.create(vk_surface.Target);
        errdefer gpa.destroy(t);
        t.* = target;
        const r = try Renderer.init(gpa, .{
            .size = .{ .width = @intCast(@max(width, 1)), .height = @intCast(@max(height, 1)) },
            .surface = .{ .vulkan = t.vulkanSurface() },
            .transparent = transparent,
            // Validation only on request: it is slow and noisy under lavapipe.
            .validation = std.c.getenv("ZPUI_VK_VALIDATION") != null,
        });
        return .{ .target = t, .renderer = r, .transparent = transparent };
    }

    pub fn deinit(p: *Presenter, gpa: std.mem.Allocator) void {
        p.renderer.deinit();
        gpa.destroy(p.target);
    }

    /// Draws `scene` at `width`x`height` device pixels; the renderer resizes as needed.
    pub fn draw(p: *Presenter, scene: *const scene_mod.Scene, width: u32, height: u32, scale: f32) !void {
        const clear = if (p.transparent) color.transparent_black else color.black;
        try p.renderer.drawScene(scene, .{ .width = @intCast(width), .height = @intCast(height) }, scale, clear);
    }

    pub fn atlas(p: *Presenter) *atlas_mod.Atlas {
        return p.renderer.atlas();
    }
};
