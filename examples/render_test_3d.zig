//! Golden-image harness for zpui.three (`zig build render-test-3d`).
//!
//! Renders six small cases offscreen, each through a real zpui `Scene` with a
//! `viewport3d` primitive, writes zig-out/render-test-3d-<case>.png and
//! compares with tests/golden/render-test-3d-<case>[-metal].png:
//!
//!   pbr-shadow     lit PBR meshes, directional shadow (PCF), SH9 fill, a blended glass box
//!   toon-outline   3-band toon ramp with inverted-hull outlines
//!   instanced      instanced props with per-instance tint, palette rows, vertex colors,
//!                  an id highlight, a mip-mapped texture; orthographic camera
//!   post-on        SSAO + tilt-shift + vignette + saturation + fog + FXAA (no MSAA)
//!   post-off       the same scene with 4x MSAA and no post
//!   ui-over-3d     2D UI under (transparent clear) and over (backdrop blur, HUD chip) a viewport
//!
//! Also checks: the cached frame path, picking against the rendered scene, zero
//! Vulkan validation errors, and a 30-frame headless-swapchain spin with a resize.
//!
//! Flags: `--update-golden` rewrites the goldens; `--bench` renders a
//! Carcassonne-sized board at 2560x1440 per tier and prints GPU timings, fps
//! and the idle (cached) cost; `--shots` also writes zig-out/bench-<tier>.png;
//! `--tier=low|medium|high` runs one tier; `--no-lod` draws every instance
//! at full detail; `--scale=0.75` renders the 3D image at 75% and upscales;
//! `--msaa=1|2|4` overrides the tier's MSAA.

const std = @import("std");
const zpui = @import("zpui");
const png = @import("png.zig");

const three = zpui.three;
const M = three.Mat4;
const V = three.Vec3;
const Scene = zpui.Scene;
const Hsla = zpui.Hsla;
const color = zpui.color;
const scene_mod = zpui.scene;
const Bounds = zpui.Bounds(f32);
const Renderer = zpui.renderer.Renderer;
const Size = zpui.Size(zpui.DevicePixels);

const channel_tolerance = 6;
const max_diff_fraction = 0.005;
const case_w = 400;
const case_h = 300;
const suffix = if (zpui.renderer.backend == .metal) "-metal" else "";

const Case = enum { @"pbr-shadow", @"toon-outline", instanced, @"post-on", @"post-off", @"ui-over-3d" };

/// Meshes and textures shared by every case.
const Assets = struct {
    box: three.MeshId,
    sphere: three.MeshId,
    cylinder: three.MeshId,
    ground: three.MeshId,
    /// Box with per-face u8 ids (0..5) and per-vertex colors.
    tagged_box: three.MeshId,
    checker: three.TextureId,
    palette: three.TextureId,

    fn create(gpa: std.mem.Allocator, g: *three.Gfx3D) !Assets {
        var a: Assets = undefined;
        inline for (.{
            .{ "box", three.shapes.box(gpa, .{ 1, 1, 1 }) },
            .{ "sphere", three.shapes.sphere(gpa, 0.5, 16, 24) },
            .{ "cylinder", three.shapes.cylinder(gpa, 0.35, 1, 20) },
            .{ "ground", three.shapes.plane(gpa, 1, 1, 4) },
        }) |entry| {
            var s = try entry[1];
            defer s.deinit(gpa);
            var d = s.desc();
            d.keep_cpu = true;
            @field(a, entry[0]) = try g.createMesh(d);
        }
        {
            var s = try three.shapes.box(gpa, .{ 1, 1, 1 });
            defer s.deinit(gpa);
            var ids: [24]u8 = undefined;
            var colors: [24][4]u8 = undefined;
            for (0..24) |i| {
                ids[i] = @intCast(i / 4);
                const shade: u8 = @intCast(150 + (i % 4) * 30);
                colors[i] = .{ shade, shade, shade, 255 };
            }
            var d = s.desc();
            d.ids = .{ .u8 = &ids };
            d.colors = &colors;
            d.keep_cpu = true;
            a.tagged_box = try g.createMesh(d);
        }
        {
            var px: [64 * 64 * 4]u8 = undefined;
            for (0..64) |y| for (0..64) |x| {
                const on = ((x / 8) + (y / 8)) % 2 == 0;
                px[(y * 64 + x) * 4 ..][0..4].* = if (on) .{ 235, 225, 200, 255 } else .{ 120, 85, 60, 255 };
            };
            a.checker = try g.createTexture(.{ .width = 64, .height = 64, .data = &px });
        }
        {
            // 6 columns (face ids) x 3 rows (palette rows).
            const rows = [3][6][3]u8{
                .{ .{ 200, 60, 40 }, .{ 200, 60, 40 }, .{ 240, 230, 210 }, .{ 90, 60, 40 }, .{ 220, 180, 120 }, .{ 220, 180, 120 } },
                .{ .{ 60, 90, 200 }, .{ 60, 90, 200 }, .{ 240, 230, 210 }, .{ 90, 60, 40 }, .{ 150, 190, 230 }, .{ 150, 190, 230 } },
                .{ .{ 60, 160, 70 }, .{ 60, 160, 70 }, .{ 250, 240, 120 }, .{ 90, 60, 40 }, .{ 120, 200, 120 }, .{ 120, 200, 120 } },
            };
            var px: [3 * 6 * 4]u8 = undefined;
            for (0..3) |r| for (0..6) |col| {
                px[(r * 6 + col) * 4 ..][0..4].* = .{ rows[r][col][0], rows[r][col][1], rows[r][col][2], 255 };
            };
            a.palette = try g.createTexture(.{ .width = 6, .height = 3, .data = &px, .mipmaps = false, .filter = .nearest, .wrap = .clamp });
        }
        return a;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var update_golden = false;
    var bench = false;
    var shots = false;
    var lod = true;
    var scale: f32 = 1;
    var msaa: ?u8 = null;
    var only_tier: ?three.Tier = null;
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "--update-golden")) update_golden = true;
        if (std.mem.eql(u8, a, "--bench")) bench = true;
        if (std.mem.eql(u8, a, "--shots")) shots = true;
        if (std.mem.eql(u8, a, "--no-lod")) lod = false;
        if (std.mem.startsWith(u8, a, "--scale=")) scale = std.fmt.parseFloat(f32, a[8..]) catch 1;
        if (std.mem.startsWith(u8, a, "--msaa=")) msaa = std.fmt.parseInt(u8, a[7..], 10) catch null;
        if (std.mem.startsWith(u8, a, "--tier=")) only_tier = std.meta.stringToEnum(three.Tier, a[7..]);
    }
    if (bench) return runBench(gpa, io, .{ .tier = only_tier, .shots = shots, .lod = lod, .scale = scale, .msaa = msaa });

    const size: Size = .{ .width = case_w, .height = case_h };
    var renderer = try Renderer.init(gpa, .{ .size = size, .transparent = true, .validation = true });
    defer renderer.deinit();

    var g = three.Gfx3D.init(gpa);
    defer g.deinit();
    const assets = try Assets.create(gpa, &g);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, "zig-out");
    var failed = false;

    for (std.enums.values(Case)) |case| {
        var s3 = three.Scene3D.init(gpa, &g);
        defer s3.deinit();
        try build3D(&s3, assets, case, 0);
        var scene: Scene = .{};
        defer scene.deinit(gpa);
        try buildScene(gpa, &scene, &s3, case);
        scene.finish();

        try renderer.drawScene(&scene, size, 1, color.transparent_black);
        // Second frame with an identical scene must hit the cache.
        try renderer.drawScene(&scene, size, 1, color.transparent_black);
        try renderer.drawScene(&scene, size, 1, color.transparent_black);
        if (!s3.stats.cached) {
            std.debug.print("FAIL [{t}]: unchanged scene was re-rendered (cache miss)\n", .{case});
            failed = true;
        }
        const pixels = try renderer.readPixels(gpa);
        defer gpa.free(pixels);
        unpremultiply(pixels);
        const encoded = try png.encode(gpa, case_w, case_h, pixels);
        defer gpa.free(encoded);
        const out_path = try std.fmt.allocPrint(gpa, "zig-out/render-test-3d-{t}.png", .{case});
        defer gpa.free(out_path);
        try cwd.writeFile(io, .{ .sub_path = out_path, .data = encoded });
        const golden_path = try std.fmt.allocPrint(gpa, "tests/golden/render-test-3d-{t}{s}.png", .{ case, suffix });
        defer gpa.free(golden_path);
        std.debug.print("[{t}] wrote {s}; {d} draws, {d} instances, {d} triangles, gpu {d:.2} ms\n", .{ case, out_path, s3.stats.draws, s3.stats.instances, s3.stats.triangles, s3.stats.gpu_ms });

        if (update_golden) {
            try cwd.createDirPath(io, "tests/golden");
            try cwd.writeFile(io, .{ .sub_path = golden_path, .data = encoded });
            std.debug.print("[{t}] updated {s}\n", .{ case, golden_path });
        } else if (!try compareGolden(gpa, io, golden_path, pixels, case)) failed = true;

        // Picking through the rendered camera: the viewport's center sees the hero object.
        if (case == .@"pbr-shadow") {
            const hit = s3.pick(.{ .width = case_w, .height = case_h }, .{ case_w / 2, case_h / 2 + 10 });
            if (hit == null or hit.?.pick_id != 7) {
                std.debug.print("FAIL [pick]: expected pick id 7 at the viewport center, got {?}\n", .{if (hit) |h| h.pick_id else null});
                failed = true;
            } else std.debug.print("[pick] center -> id {d}, triangle {?d}, distance {d:.3}\n", .{ hit.?.pick_id, hit.?.triangle, hit.?.distance });
        }
        if (case == .instanced) {
            // Top-down orthographic: the board center is the tagged box at the origin, face +Y (id 2).
            const hit = s3.pick(.{ .width = case_w, .height = case_h }, .{ case_w / 2, case_h / 2 });
            if (hit == null or hit.?.vertex_id != 2) {
                std.debug.print("FAIL [pick-id]: expected vertex id 2 (top face), got {?}\n", .{if (hit) |h| h.vertex_id else null});
                failed = true;
            }
        }
    }

    // Resource lifecycle: destroy and recreate meshes/textures between frames
    // (deferred GPU release, slot reuse with a new generation).
    {
        var s3 = three.Scene3D.init(gpa, &g);
        defer s3.deinit();
        var scene: Scene = .{};
        defer scene.deinit(gpa);
        try buildScene(gpa, &scene, &s3, .@"pbr-shadow");
        scene.finish();
        for (0..4) |i| {
            var sph = try three.shapes.sphere(gpa, 0.3 + 0.1 * @as(f32, @floatFromInt(i)), 8, 12);
            defer sph.deinit(gpa);
            const m = try g.createMesh(sph.desc());
            var px: [16]u8 = undefined;
            for (0..4) |k| px[k * 4 ..][0..4].* = .{ 200, 100, 50, 255 };
            const tex = try g.createTexture(.{ .width = 2, .height = 2, .data = &px });
            try build3D(&s3, assets, .@"pbr-shadow", @floatFromInt(i));
            try s3.draw(m, M.translation(.new(0, 1.5, 0)), .{ .material = .{ .base_color_texture = tex } });
            try renderer.drawScene(&scene, size, 1, color.transparent_black);
            g.destroy(m);
            g.destroy(tex);
        }
        // Stale handles draw nothing; the next frames release the GPU objects.
        for (0..3) |_| try renderer.drawScene(&scene, size, 1, color.transparent_black);
        std.debug.print("[lifecycle] created/destroyed 4 meshes + 4 textures across frames\n", .{});
    }

    if (renderer.validationErrors() != 0) {
        std.debug.print("FAIL: {d} Vulkan validation errors\n", .{renderer.validationErrors()});
        failed = true;
    }
    if (zpui.renderer.backend == .vulkan) spin(gpa, &g, assets) catch |err| {
        std.debug.print("FAIL: swapchain spin: {t}\n", .{err});
        failed = true;
    };
    if (failed) std.process.exit(1);
    std.debug.print("render-test-3d: all cases passed\n", .{});
}

fn compareGolden(gpa: std.mem.Allocator, io: std.Io, path: []const u8, pixels: []const u8, case: Case) !bool {
    const cwd = std.Io.Dir.cwd();
    const golden_bytes = cwd.readFileAlloc(io, path, gpa, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("[{t}] no golden at {s}; run with --update-golden to create it\n", .{ case, path });
            return true;
        },
        else => return err,
    };
    defer gpa.free(golden_bytes);
    var golden = try png.decode(gpa, golden_bytes);
    defer golden.deinit(gpa);
    if (golden.width != case_w or golden.height != case_h) {
        std.debug.print("FAIL [{t}]: golden is {d}x{d}\n", .{ case, golden.width, golden.height });
        return false;
    }
    var differing: usize = 0;
    var max_delta: u8 = 0;
    for (0..pixels.len / 4) |i| {
        var d: u8 = 0;
        for (0..4) |ch| {
            const a = pixels[i * 4 + ch];
            const b = golden.pixels[i * 4 + ch];
            d = @max(d, if (a > b) a - b else b - a);
        }
        max_delta = @max(max_delta, d);
        if (d > channel_tolerance) differing += 1;
    }
    const fraction = @as(f64, @floatFromInt(differing)) / @as(f64, @floatFromInt(pixels.len / 4));
    const ok = fraction <= max_diff_fraction;
    std.debug.print("[{t}] golden diff: {d} pixels over tolerance ({d:.4}%), max channel delta {d}{s}\n", .{ case, differing, fraction * 100, max_delta, if (ok) "" else "  FAIL" });
    return ok;
}

// ---------------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------------

fn tabletopLights(s3: *three.Scene3D) void {
    s3.sun = .{
        .direction = three.Sun.fromAngles(-145, 48),
        .color = .{ 1, 0.94, 0.85 },
        .intensity = 2.2,
        .shadow = .{ .map_size = 1024, .softness = 1.5 },
    };
    s3.hemisphere = .{ .sky = .{ 0.92, 0.92, 0.89 }, .ground = .{ 0.2, 0.17, 0.12 }, .intensity = 0.9 };
    s3.post.exposure = 0.92;
}

fn build3D(s3: *three.Scene3D, a: Assets, case: Case, t: f32) !void {
    s3.clearDraws();
    s3.clear = .{ 0.82, 0.83, 0.84, 1 };
    s3.camera = .{ .eye = .new(3.2, 2.6, 4.2), .target = .new(0, 0.4, 0), .projection = .{ .perspective = .{ .fov_y = std.math.pi / 4.5 } } };
    tabletopLights(s3);
    const table: three.Material = .{ .base_color = three.rgb(0xe9eaea), .roughness = 0.95 };
    switch (case) {
        .@"pbr-shadow" => {
            s3.environment = .{ .sh = skySh(), .intensity = 0.6 };
            try s3.draw(a.ground, M.scaling(.new(8, 1, 8)), .{ .material = table });
            try s3.draw(a.box, M.translation(.new(0, 0.5, 0)).mul(M.rotationY(0.5 + t)), .{
                .material = .{ .base_color = three.rgb(0xe3cfa6), .roughness = 0.88 },
                .pick_id = 7,
            });
            try s3.draw(a.sphere, M.translation(.new(1.3, 0.5, 0.4)), .{ .material = .{ .base_color = three.rgb(0xd0261c), .roughness = 0.35 }, .pick_id = 8 });
            try s3.draw(a.sphere, M.translation(.new(-1.2, 0.5, 0.9)), .{ .material = .{ .base_color = .{ 0.95, 0.75, 0.4, 1 }, .metallic = 1, .roughness = 0.3 } });
            try s3.draw(a.cylinder, M.translation(.new(-0.9, 0, -1.2)).mul(M.scaling(.new(1, 1.4, 1))), .{ .material = .{ .base_color = three.rgb(0x2650c0), .roughness = 0.6 } });
            // Translucent glass box: blended, double-sided, no shadow.
            try s3.draw(a.box, M.translation(.new(0.9, 0.35, 1.6)).mul(M.scaling(.new(0.7, 0.7, 0.7))), .{ .material = .{
                .base_color = .{ 0.6, 0.85, 1.0, 0.35 },
                .roughness = 0.1,
                .alpha_mode = .blend,
                .double_sided = true,
                .cast_shadows = false,
            } });
        },
        .@"toon-outline" => {
            s3.clear = three.rgb(0x9fd8f5);
            s3.sun = .{ .direction = three.Sun.fromAngles(40, 60), .intensity = 2.6, .shadow = .{ .map_size = 1024, .softness = 1 } };
            s3.hemisphere = .{ .sky = .{ 1, 1, 1 }, .ground = three.rgb(0xb5a27a)[0..3].*, .intensity = 1.3 };
            s3.post.exposure = 1;
            const toon = struct {
                fn mat(c: [4]f32) three.Material {
                    return .{ .shading = .toon, .base_color = c, .toon = .{ .bands = 3, .min = 0.35, .softness = 0.01 }, .outline = .{ .width = 0.025, .color = .{ 0.01, 0.005, 0.015, 1 } } };
                }
            }.mat;
            var ground = toon(three.rgb(0xf6d9a0));
            ground.outline = null;
            try s3.draw(a.ground, M.scaling(.new(8, 1, 8)), .{ .material = ground });
            try s3.draw(a.box, M.translation(.new(0, 0.5, 0)).mul(M.rotationY(0.5 + t)), .{ .material = toon(three.rgb(0xffd789)) });
            try s3.draw(a.sphere, M.translation(.new(1.3, 0.5, 0.4)), .{ .material = toon(three.rgb(0xff3030)) });
            try s3.draw(a.sphere, M.translation(.new(-1.2, 0.5, 0.9)), .{ .material = toon(three.rgb(0x21c045)) });
            var pixel_outline = toon(three.rgb(0x2e6bff));
            pixel_outline.outline = .{ .width = 2.5, .units = .pixels };
            try s3.draw(a.cylinder, M.translation(.new(-0.9, 0, -1.2)).mul(M.scaling(.new(1, 1.4, 1))), .{ .material = pixel_outline });
        },
        .instanced => {
            s3.camera = .{ .eye = .new(0, 10, 0.001), .target = .zero, .projection = .{ .orthographic = .{ .height = 7.5 } } };
            try s3.draw(a.ground, M.scaling(.new(10, 1, 8)), .{ .material = .{ .base_color_texture = a.checker, .roughness = 0.9 } });
            var instances: [9 * 7]three.Instance = undefined;
            var n: usize = 0;
            for (0..9) |i| for (0..7) |j| {
                const x = (@as(f32, @floatFromInt(i)) - 4) * 1.05;
                const z = (@as(f32, @floatFromInt(j)) - 3) * 1.05;
                if (i == 4 and j == 3) continue; // the center belongs to the highlighted box
                const hue: f32 = @floatFromInt((i * 7 + j) % 5);
                instances[n] = .{
                    .model = M.translation(.new(x, 0.2, z)).mul(M.rotationY(hue * 0.3)).mul(M.scaling(.new(0.5, 0.4 + 0.1 * hue, 0.5))),
                    .tint = .{ 1 - hue * 0.12, 0.85, 0.7 + hue * 0.06, 1 },
                    .palette_row = @intCast((i + j) % 3),
                    .pick_id = @intCast(100 + n),
                };
                n += 1;
            };
            try s3.drawInstanced(a.tagged_box, instances[0..n], .{ .material = .{ .palette = a.palette, .roughness = 0.7 } });
            try s3.draw(a.tagged_box, M.translation(.new(0, 0.3, 0)).mul(M.scaling(.new(0.8, 0.6, 0.8))), .{
                .material = .{ .palette = a.palette, .roughness = 0.7 },
                .palette_row = 1,
                .highlight = .{ .id = 2, .color = .{ 1, 0.85, 0.2, 0.6 } },
                .pick_id = 1,
            });
        },
        .@"post-on", .@"post-off" => {
            s3.clear = three.rgb(0xdfe9ef);
            s3.fog = .{ .color = three.rgb(0xdfe9ef)[0..3].*, .density = 0.05 };
            try s3.draw(a.ground, M.scaling(.new(14, 1, 14)), .{ .material = .{ .base_color = three.rgb(0x9ccc84), .roughness = 0.92, .detail = .{ .scale = 6, .amount = 0.15 } } });
            for (0..5) |i| for (0..4) |j| {
                const x = (@as(f32, @floatFromInt(i)) - 2) * 1.1;
                const z = (@as(f32, @floatFromInt(j)) - 2) * 1.6;
                const h = 0.4 + @as(f32, @floatFromInt((i * 3 + j) % 4)) * 0.25;
                try s3.draw(a.box, M.translation(.new(x, h / 2, z)).mul(M.scaling(.new(0.6, h, 0.6))), .{ .material = .{ .base_color = three.rgb(0xfbf5ea), .roughness = 0.9 } });
                try s3.draw(a.sphere, M.translation(.new(x + 0.45, 0.18, z + 0.45)).mul(M.scaling(.new(0.4, 0.4, 0.4))), .{ .material = .{ .base_color = three.rgb(0x5e9e6a), .roughness = 0.9 } });
            };
            s3.camera = .{ .eye = .new(2.5, 3.2, 6.5), .target = .new(0, 0, -0.5), .projection = .{ .perspective = .{ .fov_y = std.math.pi / 5.0 } } };
            if (case == .@"post-on") {
                s3.post = .{
                    .exposure = 0.85,
                    .saturation = 1.15,
                    .vignette = 0.25,
                    .msaa = 1,
                    .fxaa = true,
                    .ssao = .{ .radius = 0.35, .intensity = 1, .samples = 12 },
                    .tilt_shift = .{ .focus = 0.5, .range = 0.2, .blur = 4 },
                };
            } else {
                s3.post = .{ .exposure = 0.85, .msaa = 4 };
            }
        },
        .@"ui-over-3d" => {
            // Transparent clear: the 2D panel underneath shows around the objects.
            s3.clear = .{ 0, 0, 0, 0 };
            try s3.draw(a.box, M.translation(.new(0, 0.5, 0)).mul(M.rotationY(0.5)), .{ .material = .{ .base_color = three.rgb(0xe3cfa6), .roughness = 0.8 } });
            try s3.draw(a.sphere, M.translation(.new(1.3, 0.5, 0.4)), .{ .material = .{ .base_color = three.rgb(0xd0261c), .roughness = 0.3 } });
            try s3.draw(a.cylinder, M.translation(.new(-1.1, 0, -0.6)), .{ .material = .{ .base_color = three.rgb(0x2650c0) } });
        },
    }
}

/// A plausible sky/ground SH9 (bluish above, warm below).
fn skySh() [9][3]f32 {
    var sh: [9][3]f32 = @splat(.{ 0, 0, 0 });
    sh[0] = .{ 0.75, 0.8, 0.9 };
    sh[1] = .{ 0.25, 0.28, 0.35 }; // L1-1 ~ y
    sh[6] = .{ -0.05, -0.05, -0.03 };
    return sh;
}

fn rect(x: f32, y: f32, w: f32, h: f32) Bounds {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

fn corners(r: f32) zpui.Corners(f32) {
    return .{ .top_left = r, .top_right = r, .bottom_right = r, .bottom_left = r };
}

const full_mask: scene_mod.ContentMask = .{ .bounds = .{ .origin = .zero, .size = .{ .width = case_w, .height = case_h } } };

fn hex(v: u32) Hsla {
    return color.rgb(v).toHsla();
}

fn buildScene(gpa: std.mem.Allocator, scene: *Scene, s3: *three.Scene3D, case: Case) !void {
    if (case != .@"ui-over-3d") {
        try scene.insertViewport3D(gpa, .{ .bounds = rect(0, 0, case_w, case_h), .content_mask = full_mask, .scene3d = s3 });
        return;
    }
    try scene.insertQuad(gpa, .{
        .bounds = rect(6, 6, case_w - 12, case_h - 12),
        .content_mask = full_mask,
        .background = color.linearGradient(180, .{ .color = hex(0x3b2a1e), .percentage = 0 }, .{ .color = hex(0x1f1610), .percentage = 1 }),
        .corner_radii = corners(14),
    });
    try scene.insertViewport3D(gpa, .{ .bounds = rect(18, 18, case_w - 36, case_h - 36), .content_mask = full_mask, .corner_radii = corners(12), .scene3d = s3 });
    // Frosted strip (transparent shadow splitter, as Window.paintBackdropBlur does) and a HUD chip.
    const strip = rect(18, case_h - 78, case_w - 36, 60);
    try scene.insertShadow(gpa, .{ .bounds = strip, .content_mask = full_mask, .color = color.transparent_black });
    try scene.insertBackdropBlur(gpa, .{ .blur_radius = 10, .bounds = strip, .content_mask = full_mask, .corner_radii = .{ .top_left = 0, .top_right = 0, .bottom_right = 12, .bottom_left = 12 } });
    try scene.insertQuad(gpa, .{ .bounds = strip, .content_mask = full_mask, .background = color.solidBackground(hex(0xffffff).opacity(0.18)), .corner_radii = .{ .top_left = 0, .top_right = 0, .bottom_right = 12, .bottom_left = 12 } });
    try scene.insertQuad(gpa, .{ .bounds = rect(32, 32, 110, 30), .content_mask = full_mask, .background = color.solidBackground(hex(0xffffff).opacity(0.75)), .corner_radii = corners(8) });
}

/// Premultiplied framebuffer -> straight-alpha PNG pixels.
fn unpremultiply(pixels: []u8) void {
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        const a = pixels[i + 3];
        if (a == 0 or a == 255) continue;
        for (pixels[i..][0..3]) |*ch| ch.* = @intCast(@min(255, (@as(u32, ch.*) * 255 + a / 2) / a));
    }
}

/// 30 animated frames on a headless swapchain (resize midway): exercises
/// re-rendering every frame, target resizes and resource reuse.
fn spin(gpa: std.mem.Allocator, g: *three.Gfx3D, a: Assets) !void {
    const size: Size = .{ .width = case_w, .height = case_h };
    var r = try Renderer.init(gpa, .{ .size = size, .surface = .{ .vulkan = Renderer.headless_surface }, .transparent = true, .validation = true });
    defer r.deinit();
    var s3 = three.Scene3D.init(gpa, g);
    defer s3.deinit();
    var scene: Scene = .{};
    defer scene.deinit(gpa);
    for (0..30) |i| {
        try build3D(&s3, a, if (i % 10 < 5) .@"pbr-shadow" else .@"post-on", @as(f32, @floatFromInt(i)) * 0.1);
        scene.clear(gpa);
        try buildScene(gpa, &scene, &s3, .@"ui-over-3d");
        scene.finish();
        const sz: Size = if (i >= 15) .{ .width = 520, .height = 340 } else size;
        try r.drawScene(&scene, sz, 1, color.transparent_black);
    }
    if (r.validationErrors() != 0) return error.ValidationErrors;
    std.debug.print("swapchain path: spun 30 frames (with resize)\n", .{});
}

// ---------------------------------------------------------------------------
// Benchmark: a Carcassonne-sized board
// ---------------------------------------------------------------------------

const BenchOpts = struct { tier: ?three.Tier, shots: bool, lod: bool, scale: f32, msaa: ?u8 };

fn runBench(gpa: std.mem.Allocator, io: std.Io, o: BenchOpts) !void {
    const only_tier = o.tier;
    const shots = o.shots;
    const lod = o.lod;
    const scale = o.scale;
    const size: Size = .{ .width = 2560, .height = 1440 };
    var renderer = try Renderer.init(gpa, .{ .size = size, .transparent = false, .validation = false });
    defer renderer.deinit();
    var g = three.Gfx3D.init(gpa);
    defer g.deinit();

    // 80 tiles: a 48x48 relief grid each (with vertex colors), plus slabs.
    // With LOD (default; `--no-lod` disables) distant tiles and props use
    // coarser meshes, as an app would supply (e.g. relief encoded at 24/12).
    const tile_mesh = try reliefTile(gpa, &g, 48);
    var bush_s = try three.shapes.sphere(gpa, 0.03, 8, 12);
    defer bush_s.deinit(gpa);
    const bush = try g.createMesh(bush_s.desc());
    if (lod) {
        try g.setLods(tile_mesh, &.{
            .{ .mesh = try reliefTile(gpa, &g, 24), .max_pixels = 384 },
            .{ .mesh = try reliefTile(gpa, &g, 12), .max_pixels = 160 },
        });
        var bush_m = try three.shapes.sphere(gpa, 0.03, 6, 8);
        defer bush_m.deinit(gpa);
        var bush_l = try three.shapes.sphere(gpa, 0.03, 4, 6);
        defer bush_l.deinit(gpa);
        try g.setLods(bush, &.{
            .{ .mesh = try g.createMesh(bush_m.desc()), .max_pixels = 24 },
            .{ .mesh = try g.createMesh(bush_l.desc()), .max_pixels = 12 },
        });
    }
    var slab = try three.shapes.box(gpa, .{ 1, 0.09, 1 });
    defer slab.deinit(gpa);
    const slab_mesh = try g.createMesh(slab.desc());
    var house_s = try three.shapes.box(gpa, .{ 0.11, 0.07, 0.07 });
    defer house_s.deinit(gpa);
    const house = try g.createMesh(house_s.desc());
    var fig_s = try three.shapes.cylinder(gpa, 0.06, 0.26, 16);
    defer fig_s.deinit(gpa);
    const figure = try g.createMesh(fig_s.desc());

    var s3 = three.Scene3D.init(gpa, &g);
    defer s3.deinit();
    tabletopLights(&s3);
    s3.sun.shadow.map_size = 2048;
    var houses: std.ArrayList(three.Instance) = .empty;
    defer houses.deinit(gpa);
    var bushes: std.ArrayList(three.Instance) = .empty;
    defer bushes.deinit(gpa);
    var figs: std.ArrayList(three.Instance) = .empty;
    defer figs.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    for (0..10) |i| for (0..8) |j| {
        const x = @as(f32, @floatFromInt(i)) - 4.5;
        const z = @as(f32, @floatFromInt(j)) - 3.5;
        try s3.draw(tile_mesh, M.translation(.new(x, 0.1, z)), .{ .material = .{ .roughness = 0.88, .detail = .{ .scale = 40, .amount = 0.1 } } });
        try s3.draw(slab_mesh, M.translation(.new(x, 0.045, z)), .{ .material = .{ .base_color = three.rgb(0xe3cfa6) } });
        for (0..8) |_| try houses.append(gpa, .{ .model = M.translation(.new(x + rand.float(f32) - 0.5, 0.125, z + rand.float(f32) - 0.5)).mul(M.rotationY(rand.float(f32) * 6)), .tint = three.rgb(0xad452b) });
        for (0..14) |_| try bushes.append(gpa, .{ .model = M.translation(.new(x + rand.float(f32) - 0.5, 0.11, z + rand.float(f32) - 0.5)), .tint = three.rgb(0x26562b) });
    };
    for (0..25) |k| try figs.append(gpa, .{ .model = M.translation(.new(@as(f32, @floatFromInt(k % 10)) - 4.5, 0.09, @as(f32, @floatFromInt(k / 10)) - 3.5)), .tint = three.rgb(0xd0261c) });
    try s3.drawInstanced(house, houses.items, .{});
    try s3.drawInstanced(bush, bushes.items, .{});
    try s3.drawInstanced(figure, figs.items, .{ .material = .{ .roughness = 0.72 } });

    var scene: Scene = .{};
    defer scene.deinit(gpa);
    try scene.insertViewport3D(gpa, .{ .bounds = rect(0, 0, 2560, 1440), .content_mask = .{ .bounds = rect(0, 0, 2560, 1440) }, .scene3d = &s3 });
    scene.finish();

    var orbit: three.Orbit = .{ .distance = 11, .pitch = 0.75, .fov_y = std.math.pi / 5.0 };
    std.debug.print("bench: 2560x1440 (3D at {d:.0}%), {s}{s}\n", .{ scale * 100, @tagName(zpui.renderer.backend), if (lod) "" else ", no LOD" });
    for ([_]three.Tier{ .low, .medium, .high }) |tier| {
        if (only_tier) |t| if (t != tier) continue;
        s3.setTier(tier);
        s3.post.resolution_scale = scale;
        if (o.msaa) |m| s3.post.msaa = m;
        var sum: f64 = 0;
        var parts: [3]f64 = .{ 0, 0, 0 };
        var samples: u32 = 0;
        const warmup = 12;
        const frames = warmup + 10;
        var t0 = nowNs();
        // Moving camera: every frame re-renders (the interactive worst case).
        for (0..frames) |f| {
            if (f == warmup) t0 = nowNs();
            orbit.yaw = 0.6 + @as(f32, @floatFromInt(f)) * 0.01;
            s3.camera = orbit.camera();
            try renderer.drawScene(&scene, size, 1, color.transparent_black);
            if (f >= warmup and s3.stats.gpu_ms > 0) {
                sum += s3.stats.gpu_ms;
                parts[0] += s3.stats.gpu_shadow_ms;
                parts[1] += s3.stats.gpu_main_ms;
                parts[2] += s3.stats.gpu_post_ms;
                samples += 1;
            }
        }
        const wall = @as(f64, @floatFromInt(nowNs() - t0)) / 1e6 / (frames - warmup);
        // Idle: same scene again (render on demand; only the composite runs).
        var idle_cached = true;
        for (0..3) |_| try renderer.drawScene(&scene, size, 1, color.transparent_black);
        const ti = nowNs();
        const idle_frames = 10;
        for (0..idle_frames) |_| {
            try renderer.drawScene(&scene, size, 1, color.transparent_black);
            idle_cached = idle_cached and s3.stats.cached;
        }
        const idle = @as(f64, @floatFromInt(nowNs() - ti)) / 1e6 / idle_frames;
        const n: f64 = @floatFromInt(@max(samples, 1));
        const gpu = sum / n;
        std.debug.print("  {t:<6} {d} draws, {d} instances, {d:.2}M tris | gpu {d:.2} ms = {d:.0} fps (shadow {d:.2}, main {d:.2}, post {d:.2}) | wall {d:.1} ms | idle {d:.2} ms/frame{s}\n", .{
            tier,                                       s3.stats.draws, s3.stats.instances,
            @as(f64, @floatFromInt(s3.stats.triangles)) / 1e6, gpu,            if (gpu > 0) 1000 / gpu else 0,
            parts[0] / n,                               parts[1] / n,   parts[2] / n,
            wall,                                       idle,           if (idle_cached) " (cached)" else " (NOT cached)",
        });
        if (shots) {
            orbit.yaw = 0.6;
            s3.camera = orbit.camera();
            try renderer.drawScene(&scene, size, 1, color.transparent_black);
            const px = try renderer.readPixels(gpa);
            defer gpa.free(px);
            const enc = try png.encode(gpa, 2560, 1440, px);
            defer gpa.free(enc);
            var name_buf: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "zig-out/bench-{t}.png", .{tier});
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = enc });
        }
    }
}

/// A 1x1 relief tile on a res x res grid; heights and colors are functions of
/// position, so every resolution shows the same surface.
fn reliefTile(gpa: std.mem.Allocator, g: *three.Gfx3D, res: u32) !three.MeshId {
    var tile = try three.shapes.plane(gpa, 1, 1, res);
    defer tile.deinit(gpa);
    const colors = try gpa.alloc([4]u8, tile.positions.len);
    defer gpa.free(colors);
    for (tile.positions, colors) |*p, *col| {
        p[1] = 0.01 * @sin(p[0] * 17) * @cos(p[2] * 13);
        const v = 0.5 + 0.5 * @sin(p[0] * 23 + p[2] * 31);
        col.* = .{ @intFromFloat(60 + 39 * v), 140, 50, 255 };
    }
    var desc = tile.desc();
    desc.colors = colors;
    return g.createMesh(desc);
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}
