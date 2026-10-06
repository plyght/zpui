//! [three spike] Golden-image harness for the 3D viewport (`zig build render-test-3d`).
//!
//! A zpui scene with a wood-toned panel, a rounded `viewport3d` showing a lit
//! cube on a ground plane (fixed rotation, so the output is deterministic), and
//! 2D UI drawn *over* the viewport (a translucent HUD chip and a frosted
//! backdrop blur) to prove draw-order compositing. Renders offscreen, writes
//! zig-out/render-test-3d.png and compares it with tests/golden/render-test-3d.png.
//! Then "spins" the cube through 30 frames on a headless swapchain.
//!
//! Flags: `--update-golden` overwrites the golden image with this render.

const std = @import("std");
const zpui = @import("zpui");
const png = @import("png.zig");

const scene_mod = zpui.scene;
const three = scene_mod.three;
const M = three.math.Mat4;
const V = three.math.Vec3;
const Scene = zpui.Scene;
const Hsla = zpui.Hsla;
const color = zpui.color;
const Bounds = zpui.Bounds(f32);
const Renderer = zpui.renderer.Renderer;

const scale: f32 = 2;
const logical_w = 480;
const logical_h = 320;
const golden_path = if (zpui.renderer.backend == .metal) "tests/golden/render-test-3d-metal.png" else "tests/golden/render-test-3d.png";
const output_path = "zig-out/render-test-3d.png";
const channel_tolerance = 6;
const max_diff_fraction = 0.005;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var update_golden = false;
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--update-golden")) update_golden = true;
    }

    const size: zpui.Size(zpui.DevicePixels) = .{ .width = logical_w * scale, .height = logical_h * scale };
    var renderer = try Renderer.init(gpa, .{ .size = size, .transparent = true, .validation = true });
    defer renderer.deinit();

    var s3: three.Scene3D = .{};
    defer s3.deinit(gpa);
    try build3D(gpa, &s3, 0.6);

    var scene: Scene = .{};
    defer scene.deinit(gpa);
    try buildScene(gpa, &scene, &s3);
    scene.finish();

    try renderer.drawScene(&scene, size, scale, color.transparent_black);
    try renderer.drawScene(&scene, size, scale, color.transparent_black);
    const pixels = try renderer.readPixels(gpa);
    defer gpa.free(pixels);
    unpremultiply(pixels);

    const w: u32 = @intCast(size.width);
    const h: u32 = @intCast(size.height);
    const encoded = try png.encode(gpa, w, h, pixels);
    defer gpa.free(encoded);
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out");
    try cwd.writeFile(io, .{ .sub_path = output_path, .data = encoded });
    std.debug.print("wrote {s} ({d}x{d})\n", .{ output_path, w, h });

    var failed = false;
    const validation_errors = renderer.validationErrors();
    if (validation_errors != 0) {
        std.debug.print("FAIL: {d} Vulkan validation errors\n", .{validation_errors});
        failed = true;
    }
    // Sanity: the cube's center pixel must be lit (not background, not black).
    {
        const cx: usize = @intFromFloat(240 * scale);
        const cy: usize = @intFromFloat(150 * scale);
        const p = pixels[(cy * w + cx) * 4 ..][0..4];
        std.debug.print("center pixel rgba = {d},{d},{d},{d}\n", .{ p[0], p[1], p[2], p[3] });
        if (p[3] != 255 or (@as(u32, p[0]) + p[1] + p[2]) < 60) {
            std.debug.print("FAIL: viewport center is not a lit opaque surface\n", .{});
            failed = true;
        }
    }

    if (update_golden) {
        try cwd.createDirPath(io, "tests/golden");
        try cwd.writeFile(io, .{ .sub_path = golden_path, .data = encoded });
        std.debug.print("updated {s}\n", .{golden_path});
    } else if (cwd.readFileAlloc(io, golden_path, gpa, .limited(64 << 20))) |golden_bytes| {
        defer gpa.free(golden_bytes);
        var golden = try png.decode(gpa, golden_bytes);
        defer golden.deinit(gpa);
        if (golden.width != w or golden.height != h) {
            std.debug.print("FAIL: golden is {d}x{d}, render is {d}x{d}\n", .{ golden.width, golden.height, w, h });
            failed = true;
        } else {
            var differing: usize = 0;
            var max_delta: u8 = 0;
            for (0..pixels.len / 4) |i| {
                var px_delta: u8 = 0;
                for (0..4) |ch| {
                    const a = pixels[i * 4 + ch];
                    const b = golden.pixels[i * 4 + ch];
                    px_delta = @max(px_delta, if (a > b) a - b else b - a);
                }
                max_delta = @max(max_delta, px_delta);
                if (px_delta > channel_tolerance) differing += 1;
            }
            const fraction = @as(f64, @floatFromInt(differing)) / @as(f64, @floatFromInt(pixels.len / 4));
            std.debug.print("golden diff: {d} pixels over tolerance ({d:.4}%), max channel delta {d}\n", .{ differing, fraction * 100, max_delta });
            if (fraction > max_diff_fraction) failed = true;
        }
    } else |err| switch (err) {
        error.FileNotFound => std.debug.print("no golden at {s}; run with --update-golden to create it\n", .{golden_path}),
        else => return err,
    }

    if (zpui.renderer.backend == .vulkan) spin(gpa) catch |err| {
        std.debug.print("FAIL: swapchain spin: {s}\n", .{@errorName(err)});
        failed = true;
    };
    if (renderer.validationErrors() != 0) {
        std.debug.print("FAIL: {d} Vulkan validation errors total\n", .{renderer.validationErrors()});
        failed = true;
    }
    if (failed) std.process.exit(1);
}

/// Spin the cube through 30 frames on a headless swapchain (with a resize midway).
fn spin(gpa: std.mem.Allocator) !void {
    const size: zpui.Size(zpui.DevicePixels) = .{ .width = logical_w * scale, .height = logical_h * scale };
    var r = try Renderer.init(gpa, .{ .size = size, .surface = .{ .vulkan = Renderer.headless_surface }, .transparent = true, .validation = true });
    defer r.deinit();
    var s3: three.Scene3D = .{};
    defer s3.deinit(gpa);
    var scene: Scene = .{};
    defer scene.deinit(gpa);
    for (0..30) |i| {
        s3.draws.clearRetainingCapacity();
        try build3D(gpa, &s3, @as(f32, @floatFromInt(i)) * 0.1);
        scene.clear(gpa);
        try buildScene(gpa, &scene, &s3);
        scene.finish();
        const sz: zpui.Size(zpui.DevicePixels) = if (i == 15) .{ .width = 800, .height = 600 } else size;
        try r.drawScene(&scene, sz, scale, color.transparent_black);
    }
    std.debug.print("swapchain path: spun 30 frames (with resize)\n", .{});
}

fn build3D(gpa: std.mem.Allocator, s3: *three.Scene3D, angle: f32) !void {
    s3.camera = .{ .eye = .new(2.2, 1.8, 2.8), .target = .new(0, 0.35, 0), .fov_y = std.math.pi / 4.0 };
    s3.light = .{ .direction = .new(-0.5, -1, -0.35), .intensity = 3.2 };
    s3.ambient = .new(0.35, 0.37, 0.42);
    // Ground: a warm "table" plane.
    try s3.draw(gpa, .{
        .mesh = &three.plane,
        .model = M.scaling(.new(4, 1, 4)),
        .material = .{ .base_color = .{ 0.42, 0.24, 0.12, 1 }, .roughness = 0.7 },
    });
    // Cube: a "cardboard tile"-ish slab spinning about Y, resting on the table.
    try s3.draw(gpa, .{
        .mesh = &three.cube,
        .model = M.translation(.new(0, 0.5, 0)).mul(M.rotationY(angle)),
        .material = .{ .base_color = .{ 0.75, 0.62, 0.38, 1 }, .roughness = 0.45 },
    });
    // A small glossy "meeple" block.
    try s3.draw(gpa, .{
        .mesh = &three.cube,
        .model = M.translation(.new(0.9, 0.15, 0.6)).mul(M.rotationY(-angle * 2)).mul(M.scaling(.new(0.3, 0.3, 0.3))),
        .material = .{ .base_color = .{ 0.7, 0.05, 0.04, 1 }, .roughness = 0.25 },
    });
}

fn rect(x: f32, y: f32, w: f32, h: f32) Bounds {
    return .{ .origin = .{ .x = x * scale, .y = y * scale }, .size = .{ .width = w * scale, .height = h * scale } };
}

fn corners(r: f32) zpui.Corners(f32) {
    return .{ .top_left = r * scale, .top_right = r * scale, .bottom_right = r * scale, .bottom_left = r * scale };
}

const full_mask: scene_mod.ContentMask = .{ .bounds = .{ .origin = .zero, .size = .{ .width = logical_w * scale, .height = logical_h * scale } } };

fn hex(v: u32) Hsla {
    return color.rgb(v).toHsla();
}

fn buildScene(gpa: std.mem.Allocator, scene: *Scene, s3: *const three.Scene3D) !void {
    const solid = color.solidBackground;
    // Panel behind the viewport.
    try scene.insertQuad(gpa, .{
        .bounds = rect(8, 8, logical_w - 16, logical_h - 16),
        .content_mask = full_mask,
        .background = color.linearGradient(180, .{ .color = hex(0x3b2a1e), .percentage = 0 }, .{ .color = hex(0x1f1610), .percentage = 1 }),
        .corner_radii = corners(16),
    });
    // The 3D viewport, rounded, inset in the panel.
    try scene.insertViewport3D(gpa, .{
        .bounds = rect(24, 24, logical_w - 48, logical_h - 48),
        .content_mask = full_mask,
        .corner_radii = corners(12),
        .scene3d = s3,
    });
    // UI over the 3D content: frosted strip (backdrop blur; transparent shadow splitter like
    // Window.paintBackdropBlur) and a translucent HUD chip.
    try scene.insertShadow(gpa, .{ .bounds = rect(24, 236, logical_w - 48, 60), .content_mask = full_mask, .color = color.transparent_black });
    try scene.insertBackdropBlur(gpa, .{ .blur_radius = 8 * scale, .bounds = rect(24, 236, logical_w - 48, 60), .content_mask = full_mask, .corner_radii = .{ .top_left = 0, .top_right = 0, .bottom_right = 12 * scale, .bottom_left = 12 * scale } });
    try scene.insertQuad(gpa, .{
        .bounds = rect(40, 40, 120, 32),
        .content_mask = full_mask,
        .background = solid(hex(0xffffff).opacity(0.75)),
        .corner_radii = corners(8),
    });
}

/// Premultiplied framebuffer -> straight-alpha PNG pixels.
fn unpremultiply(pixels: []u8) void {
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        const a = pixels[i + 3];
        if (a == 0 or a == 255) continue;
        for (pixels[i..][0..3]) |*ch| {
            ch.* = @intCast(@min(255, (@as(u32, ch.*) * 255 + a / 2) / a));
        }
    }
}
