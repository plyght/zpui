//! Golden-image harness for the GPU renderer (`zig build render-test`).
//!
//! Builds a showcase scene at 2x scale (rounded quads with per-corner radii,
//! solid and dashed borders, sRGB/Oklab gradients, patterns, drop and inset
//! shadows, straight and wavy underlines, a vector path, monochrome glyph
//! sprites from a hand-made bitmap, a polychrome image tile, a frosted-glass
//! backdrop blur, an edge-faded scroll region, translucency over a
//! transparent framebuffer, and transformed / gaussian-blurred glyphs), renders it offscreen, writes
//! zig-out/render-test.png and compares it with tests/golden/render-test.png.
//!
//! Flags: `--update-golden` overwrites the golden image with this render.

const std = @import("std");
const zpui = @import("zpui");
const png = @import("png.zig");

const scene_mod = zpui.scene;
const Scene = zpui.Scene;
const Hsla = zpui.Hsla;
const color = zpui.color;
const atlas_mod = zpui.atlas;
const Bounds = zpui.Bounds(f32);
const Renderer = zpui.renderer.Renderer;

const scale: f32 = 2;
const logical_w = 680;
const logical_h = 600;
/// Per backend: rasterization (AA, dithering, MSAA) differs between Metal and lavapipe.
const golden_path = if (zpui.renderer.backend == .metal) "tests/golden/render-test-metal.png" else "tests/golden/render-test.png";
const output_path = "zig-out/render-test.png";
/// Max per-channel difference before a pixel counts as different.
const channel_tolerance = 4;
/// Fraction of pixels allowed to differ (gradient dither, driver rounding).
const max_diff_fraction = 0.002;

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

    var scene: Scene = .{};
    defer scene.deinit(gpa);
    try buildScene(gpa, &scene, renderer.atlas());
    scene.finish();

    // A large unused image gets its own atlas texture; evicting it between
    // frames exercises the backend releasing GPU textures.
    _ = try insertImage(renderer.atlas(), 99, 600);
    try renderer.drawScene(&scene, size, scale, color.transparent_black);
    renderer.atlas().evictImage(99, 1);
    // Render twice: the second frame exercises buffer/descriptor reuse.
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
    if (zpui.renderer.backend == .vulkan) presentFrames(gpa, &scene) catch |err| {
        std.debug.print("FAIL: swapchain path: {s}\n", .{@errorName(err)});
        failed = true;
    };
    if (renderer.validationErrors() != validation_errors) {
        std.debug.print("FAIL: {d} Vulkan validation errors on the swapchain path\n", .{renderer.validationErrors() - validation_errors});
        failed = true;
    }
    if (failed) std.process.exit(1);
}

/// Present a few frames through a headless-surface swapchain, including a resize.
fn presentFrames(gpa: std.mem.Allocator, scene: *const Scene) !void {
    const size: zpui.Size(zpui.DevicePixels) = .{ .width = logical_w * scale, .height = logical_h * scale };
    var r = try Renderer.init(gpa, .{ .size = size, .surface = .{ .vulkan = Renderer.headless_surface }, .transparent = true, .validation = true });
    defer r.deinit();
    // Same atlas content as the offscreen renderer.
    var throwaway: Scene = .{};
    defer throwaway.deinit(gpa);
    try buildScene(gpa, &throwaway, r.atlas());
    for (0..3) |_| try r.drawScene(scene, size, scale, color.transparent_black);
    try r.drawScene(scene, .{ .width = 800, .height = 600 }, scale, color.transparent_black);
    try r.drawScene(scene, size, scale, color.transparent_black);
    std.debug.print("swapchain path: presented 5 frames (with resize)\n", .{});
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

// ---------------------------------------------------------------------------
// Scene construction (logical pixels, scaled to device pixels here)
// ---------------------------------------------------------------------------

fn rect(x: f32, y: f32, w: f32, h: f32) Bounds {
    return .{ .origin = .{ .x = x * scale, .y = y * scale }, .size = .{ .width = w * scale, .height = h * scale } };
}

fn corners(tl: f32, tr: f32, br: f32, bl: f32) zpui.Corners(f32) {
    return .{ .top_left = tl * scale, .top_right = tr * scale, .bottom_right = br * scale, .bottom_left = bl * scale };
}

fn edges(v: f32) zpui.Edges(f32) {
    return .all(v * scale);
}

const full_mask: scene_mod.ContentMask = .{ .bounds = .{ .origin = .zero, .size = .{ .width = logical_w * scale, .height = logical_h * scale } } };

fn hex(v: u32) Hsla {
    return color.rgb(v).toHsla();
}

fn hexa(v: u32, a: f32) Hsla {
    return color.rgb(v).toHsla().opacity(a);
}

fn quad(bounds: Bounds, bg: color.Background, radii: zpui.Corners(f32)) scene_mod.Quad {
    return .{ .bounds = bounds, .content_mask = full_mask, .background = bg, .corner_radii = radii };
}

fn buildScene(gpa: std.mem.Allocator, scene: *Scene, atlas: *atlas_mod.Atlas) !void {
    const solid = color.solidBackground;

    // Window: rounded panel over a transparent framebuffer (corners stay transparent).
    try scene.insertShadow(gpa, .{
        .bounds = rect(12, 12, logical_w - 24, logical_h - 24),
        .corner_radii = corners(18, 18, 18, 18),
        .content_mask = full_mask,
        .color = hexa(0x000000, 0.35),
        .blur_radius = 8 * scale,
    });
    try scene.insertQuad(gpa, quad(rect(12, 12, logical_w - 24, logical_h - 24), color.linearGradient(180, .{ .color = hex(0xf7f8fb), .percentage = 0 }, .{ .color = hex(0xe6e9f2), .percentage = 1 }), corners(18, 18, 18, 18)));

    // Row 1: per-corner radii + drop shadow, solid border, dashed borders, gradients.
    try scene.insertShadow(gpa, .{
        .bounds = rect(36, 40 + 6, 110, 90),
        .corner_radii = corners(0, 12, 28, 44),
        .content_mask = full_mask,
        .color = hexa(0x1e3a8a, 0.45),
        .blur_radius = 10 * scale,
    });
    try scene.insertQuad(gpa, quad(rect(36, 40, 110, 90), solid(hex(0x3b82f6)), corners(0, 12, 28, 44)));

    var bordered = quad(rect(166, 40, 110, 90), solid(hex(0xffffff)), corners(16, 16, 16, 16));
    bordered.border_widths = edges(3);
    bordered.border_color = hex(0xef4444);
    try scene.insertQuad(gpa, bordered);

    var uneven = quad(rect(296, 40, 110, 90), solid(hex(0xfef3c7)), corners(24, 4, 24, 4));
    uneven.border_widths = .{ .top = 2 * scale, .right = 8 * scale, .bottom = 2 * scale, .left = 8 * scale };
    uneven.border_color = hex(0xd97706);
    try scene.insertQuad(gpa, uneven);

    var dashed = quad(rect(426, 40, 100, 90), solid(hexa(0x10b981, 0.12)), corners(14, 14, 14, 14));
    dashed.border_widths = edges(2);
    dashed.border_style = .dashed;
    dashed.border_color = hex(0x059669);
    try scene.insertQuad(gpa, dashed);

    var dashed_square = quad(rect(546, 40, 100, 90), solid(hexa(0x8b5cf6, 0.10)), corners(0, 0, 0, 0));
    dashed_square.border_widths = edges(3);
    dashed_square.border_style = .dashed;
    dashed_square.border_color = hex(0x7c3aed);
    try scene.insertQuad(gpa, dashed_square);

    // Row 2: gradients (sRGB vs Oklab), patterns.
    const from: color.LinearColorStop = .{ .color = hex(0xff0055), .percentage = 0 };
    const to: color.LinearColorStop = .{ .color = hex(0x0055ff), .percentage = 1 };
    try scene.insertQuad(gpa, quad(rect(36, 150, 200, 34), color.linearGradient(90, from, to), corners(10, 10, 10, 10)));
    try scene.insertQuad(gpa, quad(rect(36, 192, 200, 34), color.linearGradient(90, from, to).colorSpace(.oklab), corners(10, 10, 10, 10)));
    try scene.insertQuad(gpa, quad(rect(256, 150, 76, 76), color.linearGradient(135, .{ .color = hex(0xfde047), .percentage = 0.1 }, .{ .color = hex(0x16a34a), .percentage = 0.9 }).colorSpace(.oklab), corners(38, 38, 38, 38)));
    try scene.insertQuad(gpa, quad(rect(346, 150, 76, 76), color.patternSlash(hex(0x64748b), 2, 4), corners(8, 8, 8, 8)));
    var checker = quad(rect(436, 150, 76, 76), color.checkerboard(hex(0x94a3b8), 8 * scale), corners(8, 8, 8, 8));
    checker.border_widths = edges(1);
    checker.border_color = hex(0x475569);
    try scene.insertQuad(gpa, checker);

    // Inset shadow well.
    try scene.insertQuad(gpa, quad(rect(526, 150, 120, 76), solid(hex(0xe2e8f0)), corners(14, 14, 14, 14)));
    try scene.insertShadow(gpa, .{
        .bounds = rect(526, 150 + 4, 120, 76),
        .corner_radii = corners(14, 14, 14, 14),
        .content_mask = full_mask,
        .color = hexa(0x0f172a, 0.45),
        .blur_radius = 6 * scale,
        .element_bounds = rect(526, 150, 120, 76),
        .element_corner_radii = corners(14, 14, 14, 14),
        .inset = 1,
    });

    // Row 3: vector path (star with curved inner edges), glyphs, underlines, image.
    try insertStar(gpa, scene, 76, 312, 46, 19);
    try insertHeart(gpa, scene, 150, 310);
    try insertText(gpa, scene, atlas, "ZPUI", 196, 262, hex(0x0f172a), .{});
    try scene.insertUnderline(gpa, .{ .bounds = rect(196, 296, 112, 2), .content_mask = full_mask, .color = hex(0x0f172a), .thickness = 2 * scale });
    try insertText(gpa, scene, atlas, "VK", 196, 312, hex(0xdc2626), .{});
    try insertText(gpa, scene, atlas, "VK", 262, 312, hex(0x1d4ed8), .{ .subpixel = true });
    try scene.insertUnderline(gpa, .{ .bounds = rect(196, 344, 60, 8), .content_mask = full_mask, .color = hex(0xdc2626), .thickness = 1.5 * scale, .wavy = 1 });

    const image_tile = try insertImage(atlas, 1, 96);
    try scene.insertPolychromeSprite(gpa, .{
        .bounds = rect(330, 256, 96, 96),
        .content_mask = full_mask,
        .corner_radii = corners(20, 20, 20, 20),
        .tile = image_tile,
    });
    try scene.insertPolychromeSprite(gpa, .{
        .bounds = rect(440, 256, 96, 96),
        .content_mask = full_mask,
        .corner_radii = corners(48, 48, 48, 48),
        .grayscale = 1,
        .opacity = 0.8,
        .tile = image_tile,
    });
    // Translucent RGB discs (straight-alpha source-over).
    for ([_]struct { f32, f32, u32 }{ .{ 556, 262, 0xff0000 }, .{ 590, 262, 0x00c000 }, .{ 573, 292, 0x0000ff } }) |d| {
        try scene.insertQuad(gpa, quad(rect(d[0], d[1], 56, 56), solid(hexa(d[2], 0.5)), corners(28, 28, 28, 28)));
    }

    // Row 4 left: colorful content under a frosted-glass card.
    const stripe_colors = [_]u32{ 0xf43f5e, 0xf59e0b, 0x84cc16, 0x06b6d4, 0x6366f1, 0xd946ef };
    for (stripe_colors, 0..) |c, i| {
        const x: f32 = 36 + @as(f32, @floatFromInt(i)) * 52;
        try scene.insertQuad(gpa, quad(rect(x, 372, 40, 124), solid(hex(c)), corners(6, 6, 6, 6)));
    }
    try scene.insertQuad(gpa, quad(rect(150, 400, 70, 70), solid(hex(0xffffff)), corners(35, 35, 35, 35)));
    try insertText(gpa, scene, atlas, "ZPUI", 60, 392, hex(0x111827), .{});

    const card = rect(70, 420, 250, 70);
    try scene.insertShadow(gpa, .{ .bounds = card, .corner_radii = corners(16, 16, 16, 16), .content_mask = full_mask, .color = hexa(0x000000, 0.25), .blur_radius = 8 * scale });
    // zui's paint_backdrop_blur: transparent shadow splitter, then the blur.
    try scene.insertShadow(gpa, .{ .bounds = card, .content_mask = full_mask, .color = color.transparent_black });
    try scene.insertBackdropBlur(gpa, .{ .bounds = card, .content_mask = full_mask, .corner_radii = corners(16, 16, 16, 16), .blur_radius = 10 * scale });
    var glass = quad(card, solid(hexa(0xffffff, 0.28)), corners(16, 16, 16, 16));
    glass.border_widths = edges(1);
    glass.border_color = hexa(0xffffff, 0.7);
    try scene.insertQuad(gpa, glass);
    try insertText(gpa, scene, atlas, "UI", 90, 440, hex(0xffffff), .{});

    // Row 4 right: edge-faded scroll region (clipped list with fades at top and bottom).
    const region = rect(356, 372, 290, 124);
    try scene.insertQuad(gpa, quad(region, solid(hex(0xffffff)), corners(12, 12, 12, 12)));
    const region_mask: scene_mod.ContentMask = .{ .bounds = region };
    const fade: scene_mod.EdgeFadeParams = .{
        .top_y = region.origin.y,
        .bottom_y = region.bottom(),
        .band_top = 28 * scale,
        .band_bottom = 28 * scale,
    };
    for (0..6) |i| {
        const y: f32 = 360 + @as(f32, @floatFromInt(i)) * 26;
        var item = quad(rect(368, y, 266, 20), solid(hex(if (i % 2 == 0) 0x6366f1 else 0x0ea5e9)), corners(6, 6, 6, 6));
        item.content_mask = region_mask;
        item.fade = fade;
        try scene.insertQuad(gpa, item);
        try insertText(gpa, scene, atlas, if (i % 2 == 0) "ZP" else "UI", 376, y + 3, hex(0xffffff), .{ .mask = region_mask, .fade = fade, .size = 0.5 });
    }
    var outline = quad(region, solid(color.transparent_black), corners(12, 12, 12, 12));
    outline.border_widths = edges(1);
    outline.border_color = hex(0xcbd5e1);
    try scene.insertQuad(gpa, outline);

    // Row 5: transformed and blurred monochrome glyphs (zui 0966d06 `paint_glyph_transformed`):
    // crisp, rotated and scaled about the glyph center, blurred at sigma 1/3/6 (6 hits the 12-tap
    // radius cap), rotated + blurred, and a blurred glow under a crisp copy.
    try scene.insertQuad(gpa, quad(rect(36, 512, 610, 64), solid(hex(0xffffff)), corners(12, 12, 12, 12)));
    const ink = hex(0x0f172a);
    const big: TextOptions = .{ .size = 2 };
    try insertText(gpa, scene, atlas, "ZP", 52, 524, ink, big);
    try insertGlyphFx(gpa, scene, atlas, 'Z', 140, 524, hex(0x7c3aed), .{ .rotate = 0.35 });
    try insertGlyphFx(gpa, scene, atlas, 'P', 204, 524, hex(0x059669), .{ .scale = 1.3 });
    try insertGlyphFx(gpa, scene, atlas, 'U', 270, 524, ink, .{ .blur = 1 });
    try insertGlyphFx(gpa, scene, atlas, 'U', 334, 524, ink, .{ .blur = 3 });
    try insertGlyphFx(gpa, scene, atlas, 'I', 398, 524, hex(0xdc2626), .{ .blur = 6 });
    try insertGlyphFx(gpa, scene, atlas, 'Z', 462, 524, hex(0x2563eb), .{ .rotate = -0.3, .blur = 2 });
    try insertGlyphFx(gpa, scene, atlas, 'P', 532, 524, hex(0x0ea5e9), .{ .blur = 4 });
    try insertGlyphFx(gpa, scene, atlas, 'P', 532, 524, hex(0xffffff), .{});
}

const GlyphFx = struct {
    /// Clockwise rotation about the glyph center, radians.
    rotate: f32 = 0,
    /// Uniform scale about the glyph center.
    scale: f32 = 1,
    /// Gaussian sigma, logical px.
    blur: f32 = 0,
};

/// One 2x-size glyph built like `Window.paintGlyphTransformed`: the matrix is applied at composite
/// time in device px, and the quad is inflated by 3 * sigma per side for the blur halo.
fn insertGlyphFx(gpa: std.mem.Allocator, scene: *Scene, atlas: *atlas_mod.Atlas, ch: u8, x: f32, y: f32, c: Hsla, fx: GlyphFx) !void {
    const gw = glyph_logical_w * 2;
    const gh = glyph_logical_h * 2;
    const w: i32 = @intFromFloat(gw * scale);
    const h: i32 = @intFromFloat(gh * scale);
    var buf: [64 * 64 * 4]u8 = undefined;
    var builder: GlyphBuilder = .{ .ch = ch, .w = w, .h = h, .buf = buf[0..@intCast(w * h)] };
    const tile = (try atlas.getOrInsertWith(.{ .glyph = .init(0, ch, gh, scale) }, &builder)) orelse return;
    const glyph = rect(x, y, gw, gh);
    const center: zpui.Point(f32) = .{ .x = glyph.origin.x + glyph.size.width / 2, .y = glyph.origin.y + glyph.size.height / 2 };
    const xf = scene_mod.TransformationMatrix.unit
        .translate(center)
        .rotate(fx.rotate)
        .scale(.{ .width = fx.scale, .height = fx.scale })
        .translate(.{ .x = -center.x, .y = -center.y });
    const sigma = fx.blur * scale;
    const pad = 3 * sigma;
    try scene.insertMonochromeSprite(gpa, .{
        .bounds = .{
            .origin = .{ .x = glyph.origin.x - pad, .y = glyph.origin.y - pad },
            .size = .{ .width = glyph.size.width + 2 * pad, .height = glyph.size.height + 2 * pad },
        },
        .content_mask = full_mask,
        .color = c,
        .tile = tile,
        .transformation = xf,
        .blur = sigma,
    });
}

/// A five-pointed star, triangulated around its center (as gpui's lyon
/// tessellation would) and pushed with `pushTriangle`.
fn insertStar(gpa: std.mem.Allocator, scene: *Scene, cx: f32, cy: f32, outer: f32, inner: f32) !void {
    var path: scene_mod.Path = .init(point(cx, cy));
    defer path.deinit(gpa);
    const step = std.math.pi / 5.0;
    const interior: zpui.Point(f32) = .{ .x = 0, .y = 1 };
    for (0..10) |i| {
        const a0 = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * step;
        const a1 = a0 + step;
        const r0 = if (i % 2 == 0) outer else inner;
        const r1 = if (i % 2 == 0) inner else outer;
        try path.pushTriangle(gpa, .{
            point(cx, cy),
            point(cx + r0 * @cos(a0), cy + r0 * @sin(a0)),
            point(cx + r1 * @cos(a1), cy + r1 * @sin(a1)),
        }, .{ interior, interior, interior });
    }
    path.content_mask = full_mask;
    path.color = color.linearGradient(160, .{ .color = hex(0xfacc15), .percentage = 0 }, .{ .color = hex(0xf97316), .percentage = 1 });
    try scene.insertPath(gpa, path);
}

/// A heart made of convex quadratic curves (Loop-Blinn edges).
fn insertHeart(gpa: std.mem.Allocator, scene: *Scene, cx: f32, cy: f32) !void {
    var path: scene_mod.Path = .init(point(cx, cy + 30));
    defer path.deinit(gpa);
    try path.curveTo(gpa, point(cx - 32, cy - 6), point(cx - 36, cy + 14));
    try path.curveTo(gpa, point(cx, cy - 12), point(cx - 26, cy - 38));
    try path.curveTo(gpa, point(cx + 32, cy - 6), point(cx + 26, cy - 38));
    try path.curveTo(gpa, point(cx, cy + 30), point(cx + 36, cy + 14));
    path.content_mask = full_mask;
    path.color = color.solidBackground(hexa(0xe11d48, 0.85));
    try scene.insertPath(gpa, path);
}

fn point(x: f32, y: f32) zpui.Point(f32) {
    return .{ .x = x * scale, .y = y * scale };
}

// ---------------------------------------------------------------------------
// Hand-made glyphs: strokes rasterized as an antialiased distance field.
// ---------------------------------------------------------------------------

const Segment = [4]f32; // x0, y0, x1, y1 on a 10x14 grid

fn glyphSegments(ch: u8) []const Segment {
    return switch (ch) {
        'Z' => &.{ .{ 1.5, 1.5, 8.5, 1.5 }, .{ 8.5, 1.5, 1.5, 12.5 }, .{ 1.5, 12.5, 8.5, 12.5 } },
        'P' => &.{ .{ 2, 12.5, 2, 1.5 }, .{ 2, 1.5, 6.5, 1.5 }, .{ 6.5, 1.5, 8.5, 3 }, .{ 8.5, 3, 8.5, 5.5 }, .{ 8.5, 5.5, 6.5, 7 }, .{ 6.5, 7, 2, 7 } },
        'U' => &.{ .{ 2, 1.5, 2, 9.5 }, .{ 2, 9.5, 3.5, 12.5 }, .{ 3.5, 12.5, 6.5, 12.5 }, .{ 6.5, 12.5, 8, 9.5 }, .{ 8, 9.5, 8, 1.5 } },
        'I' => &.{ .{ 5, 1.5, 5, 12.5 }, .{ 2.5, 1.5, 7.5, 1.5 }, .{ 2.5, 12.5, 7.5, 12.5 } },
        'V' => &.{ .{ 1.5, 1.5, 5, 12.5 }, .{ 5, 12.5, 8.5, 1.5 } },
        'K' => &.{ .{ 2, 1.5, 2, 12.5 }, .{ 8.5, 1.5, 2, 7.5 }, .{ 4, 6, 8.5, 12.5 } },
        else => &.{},
    };
}

const glyph_logical_w = 14;
const glyph_logical_h = 20;

fn segmentDistance(px: f32, py: f32, s: Segment) f32 {
    const dx = s[2] - s[0];
    const dy = s[3] - s[1];
    const len2 = dx * dx + dy * dy;
    const t = if (len2 == 0) 0 else std.math.clamp(((px - s[0]) * dx + (py - s[1]) * dy) / len2, 0, 1);
    const ex = px - (s[0] + t * dx);
    const ey = py - (s[1] + t * dy);
    return @sqrt(ex * ex + ey * ey);
}

const GlyphBuilder = struct {
    ch: u8,
    w: i32,
    h: i32,
    buf: []u8,
    subpixel: bool = false,

    fn coverage(segs: []const Segment, grid: f32, x: f32, y: f32) f32 {
        var d: f32 = std.math.inf(f32);
        for (segs) |s| d = @min(d, segmentDistance(x / grid, y / grid, s));
        return std.math.clamp(0.5 - (d * grid - 0.85 * grid), 0, 1);
    }

    pub fn build(self: *GlyphBuilder) !?atlas_mod.BuiltTile {
        const segs = glyphSegments(self.ch);
        if (segs.len == 0) return null;
        const grid: f32 = @as(f32, @floatFromInt(self.h)) / 14.0;
        const w: usize = @intCast(self.w);
        for (0..@intCast(self.h)) |y| for (0..w) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            if (self.subpixel) {
                // BGRA texel: R/G/B coverage sampled at the left/center/right subpixel.
                const o = (y * w + x) * 4;
                self.buf[o + 0] = @intFromFloat(@round(coverage(segs, grid, px + 1.0 / 3.0, py) * 255));
                self.buf[o + 1] = @intFromFloat(@round(coverage(segs, grid, px, py) * 255));
                self.buf[o + 2] = @intFromFloat(@round(coverage(segs, grid, px - 1.0 / 3.0, py) * 255));
                self.buf[o + 3] = 255;
            } else {
                self.buf[y * w + x] = @intFromFloat(@round(coverage(segs, grid, px, py) * 255));
            }
        };
        return .{ .size = .{ .width = self.w, .height = self.h }, .bytes = self.buf };
    }
};

const TextOptions = struct {
    mask: scene_mod.ContentMask = full_mask,
    fade: scene_mod.EdgeFadeParams = .{},
    /// Glyph size relative to the default 14x20 logical box.
    size: f32 = 1,
    /// Rasterize LCD (RGB-stripe) coverage into the subpixel atlas.
    subpixel: bool = false,
};

fn insertText(gpa: std.mem.Allocator, scene: *Scene, atlas: *atlas_mod.Atlas, text: []const u8, x: f32, y: f32, c: Hsla, opts: TextOptions) !void {
    const gw = glyph_logical_w * opts.size;
    const gh = glyph_logical_h * opts.size;
    const w: i32 = @intFromFloat(gw * scale);
    const h: i32 = @intFromFloat(gh * scale);
    var buf: [64 * 64 * 4]u8 = undefined;
    const bpp: i32 = if (opts.subpixel) 4 else 1;
    for (text, 0..) |ch, i| {
        var builder: GlyphBuilder = .{ .ch = ch, .w = w, .h = h, .buf = buf[0..@intCast(w * h * bpp)], .subpixel = opts.subpixel };
        var glyph: atlas_mod.GlyphKey = .init(0, ch, gh, scale);
        glyph.subpixel_rendering = opts.subpixel;
        const tile = (try atlas.getOrInsertWith(.{ .glyph = glyph }, &builder)) orelse continue;
        const sprite: scene_mod.MonochromeSprite = .{
            .bounds = rect(x + @as(f32, @floatFromInt(i)) * (gw + 2 * opts.size), y, gw, gh),
            .content_mask = opts.mask,
            .color = c,
            .tile = tile,
            .fade = opts.fade,
        };
        if (opts.subpixel) {
            try scene.insertSubpixelSprite(gpa, @as(*const scene_mod.SubpixelSprite, @ptrCast(&sprite)).*);
        } else {
            try scene.insertMonochromeSprite(gpa, sprite);
        }
    }
}

/// A procedural landscape (sky gradient, sun, hills) as a straight-alpha BGRA tile.
fn insertImage(atlas: *atlas_mod.Atlas, id: u64, n: i32) !atlas_mod.AtlasTile {
    const dim: usize = @intCast(n * @as(i32, @intFromFloat(scale)));
    const pixels = try atlas.gpa.alloc(u8, dim * dim * 4);
    defer atlas.gpa.free(pixels);
    const fdim: f32 = @floatFromInt(dim);
    for (0..dim) |y| for (0..dim) |x| {
        const u = @as(f32, @floatFromInt(x)) / fdim;
        const v = @as(f32, @floatFromInt(y)) / fdim;
        var rgb = [3]f32{ 0.35 + 0.4 * v, 0.55 + 0.3 * v, 0.95 - 0.2 * v };
        const sun = @sqrt((u - 0.7) * (u - 0.7) + (v - 0.3) * (v - 0.3));
        if (sun < 0.14) rgb = .{ 1.0, 0.85, 0.3 } else if (sun < 0.2) {
            const k = (sun - 0.14) / 0.06;
            rgb = .{ rgb[0] + (1.0 - rgb[0]) * (1 - k) * 0.6, rgb[1] + (0.85 - rgb[1]) * (1 - k) * 0.6, rgb[2] * (0.6 + 0.4 * k) };
        }
        const hill1 = 0.68 + 0.08 * @sin(u * 7.0);
        const hill2 = 0.8 + 0.05 * @sin(u * 11.0 + 1.0);
        if (v > hill2) rgb = .{ 0.13, 0.45, 0.2 } else if (v > hill1) rgb = .{ 0.25, 0.6, 0.3 };
        const o = (y * dim + x) * 4;
        pixels[o + 0] = @intFromFloat(rgb[2] * 255);
        pixels[o + 1] = @intFromFloat(rgb[1] * 255);
        pixels[o + 2] = @intFromFloat(rgb[0] * 255);
        pixels[o + 3] = 255;
    };
    const d: i32 = @intCast(dim);
    return atlas.insert(.{ .image = .{ .image_id = id } }, .{ .width = d, .height = d }, pixels[0 .. dim * dim * 4]);
}
