//! Compile-only check of the Metal renderer for cross builds without a macOS
//! SDK: `zig build metal-check -Dtarget=aarch64-macos` emits an object file,
//! which needs no framework linking. The exported function forces semantic
//! analysis and codegen of the renderer's public API and of the shared
//! render test (examples/render_test.zig, whose `main` is not otherwise
//! analyzed in an object build).

const std = @import("std");
const zpui = @import("zpui");
const render_test = @import("render_test.zig");

const Renderer = zpui.renderer.Renderer;

fn run(gpa: std.mem.Allocator, layer: ?*anyopaque) !void {
    const size: zpui.Size(zpui.DevicePixels) = .{ .width = 64, .height = 64 };
    var r = try Renderer.init(gpa, .{ .size = size, .surface = if (layer) |l| .{ .metal_layer = l } else null });
    defer r.deinit();
    var scene: zpui.Scene = .{};
    defer scene.deinit(gpa);
    scene.finish();
    try r.drawScene(&scene, size, 1, zpui.color.white);
    gpa.free(try r.readPixels(gpa));
    r.setPresentsWithTransaction(true);
    r.setTransparent(true);
    r.trimIdleResources();
    _ = r.layer();
    try r.resize(.{ .width = 1, .height = 1 });
}

export fn zpui_metal_check(layer: ?*anyopaque) callconv(.c) c_int {
    const main_ptr: *const anyopaque = @ptrCast(&render_test.main);
    std.mem.doNotOptimizeAway(main_ptr);
    run(std.heap.c_allocator, layer) catch return 1;
    return 0;
}
