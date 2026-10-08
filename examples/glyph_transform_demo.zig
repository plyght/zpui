//! Raster-time vs composite-time glyph transforms (`zig build glyph-transform-demo`).
//!
//! Two copies of a keyboard seen in 3/4 view: every key is a parallelogram on a sheared,
//! foreshortened plane, and its legend is mapped onto the key top by one 2x2 matrix
//! (`RasterTransform.fromBasis(along_the_row, up_the_key)`, the same for every key).
//!   left:  composited (`Window.paintGlyphTransformed`): the upright raster is stretched
//!          by the matrix on the GPU;
//!   right: raster-transformed (`Window.paintGlyphRasterTransformed` /
//!          `paintTextRunRasterTransformed`): the OS rasterizer (FreeType / CoreText / DirectWrite) draws
//!          the transformed outline, so the legends stay crisp at any shear.
//! Under each keyboard, a larger line of text laid out along the same matrix, and a big
//! legend under a much stronger shear.
//!
//! The scene is built from the platform layer (like `mac-window` / `linux-window`), with the
//! glyph painting of `src/window/paint.zig` inlined so the same scene can be re-rendered
//! through an offscreen renderer.
//!
//! Smoke test (CI): `ZPUI_SMOKE_FRAMES=N zig build glyph-transform-demo` renders N frames,
//! then draws the same scene through an offscreen renderer, writes
//! zig-out/glyph-transform-demo.png and exits (1 with `FAIL:` when the frames never come or
//! the image has no ink). Without a display (no platform, or `openWindow` fails) the smoke
//! test renders offscreen only and says so. `ZPUI_DEMO_SCALE=<f>` overrides the device scale of the PNG.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const assets = @import("zeron_assets");
const png = @import("png.zig");

const platform = zpui.platform;
const scene_mod = zpui.scene;
const color = zpui.color;
const text = zpui.text;
const Hsla = zpui.Hsla;
const Renderer = zpui.renderer.Renderer;
const RasterTransform = text.RasterTransform;
const Point = zpui.Point(f32);

const output_path = "zig-out/glyph-transform-demo.png";
const logical_w: f32 = 1240;
const logical_h: f32 = 500;
const watchdog_ns = 30 * std.time.ns_per_s;

const Mode = enum { composited, raster };

const Demo = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    plat: platform.Platform,
    ts: text.TextSystem,
    window: ?platform.Window = null,
    scene: scene_mod.Scene = .{},
    arena: std.heap.ArenaAllocator,
    legend_font: text.FontId = undefined,
    label_font: text.FontId = undefined,
    frames: u64 = 0,
    smoke_frames: ?u64,
    scale_override: ?f32,
    done: bool = false,
    exit_code: u8 = 0,

    fn hex(v: u32) Hsla {
        return color.rgb(v).toHsla();
    }

    const bg = hex(0x0f1115);
    const panel = hex(0x1a1d24);
    const plate = hex(0x2a2f3a);
    const cap_side = hex(0x9ca3af);
    const cap_top = hex(0xf4f4f5);
    const legend = hex(0x18181b);
    const label = hex(0xe5e7eb);
    const muted = hex(0x9ca3af);
    const accent = hex(0xfbbf24);

    /// Keyboard plane in logical px: one key step along the row and one row toward the viewer.
    const key_u: Point = .{ .x = 40, .y = 9 };
    const key_v: Point = .{ .x = -14, .y = 26 };
    const rows = [_][]const u8{ "1234567890", "QWERTYUIOP", "ASDFGHJKL;", "ZXCVBNM,./" };
    const stagger = [_]f32{ 0, 0.5, 0.75, 1.25 };

    /// Legend matrix: glyph x along the row, glyph up toward the far edge of the key, with the
    /// plane's foreshortening (a square key is |key_v| / |key_u| as deep as it is wide).
    fn legendTransform() RasterTransform {
        const len = @sqrt(key_u.x * key_u.x + key_u.y * key_u.y);
        return RasterTransform.fromBasis(.{ key_u.x / len, key_u.y / len }, .{ -key_v.x / len, -key_v.y / len });
    }

    fn plane(origin: Point, x: f32, y: f32) Point {
        return .{ .x = origin.x + x * key_u.x + y * key_v.x, .y = origin.y + x * key_u.y + y * key_v.y };
    }

    fn fullMask(size: zpui.Size(f32)) scene_mod.ContentMask {
        return .{ .bounds = .{ .origin = .zero, .size = size } };
    }

    fn quad(sc: *scene_mod.Scene, gpa: std.mem.Allocator, s: f32, mask: scene_mod.ContentMask, x: f32, y: f32, w: f32, h: f32, r: f32, c: Hsla) !void {
        try sc.insertQuad(gpa, .{
            .bounds = .{ .origin = .{ .x = x * s, .y = y * s }, .size = .{ .width = w * s, .height = h * s } },
            .content_mask = mask,
            .background = color.solidBackground(c),
            .corner_radii = .all(r * s),
        });
    }

    /// Filled parallelogram p0, p1, p2, p3 (logical px).
    fn parallelogram(sc: *scene_mod.Scene, gpa: std.mem.Allocator, s: f32, mask: scene_mod.ContentMask, p: [4]Point, c: Hsla) !void {
        const d = [4]Point{ p[0].scale(s), p[1].scale(s), p[2].scale(s), p[3].scale(s) };
        var path: scene_mod.Path = .init(d[0]);
        defer path.deinit(gpa);
        const inside: Point = .{ .x = 0, .y = 1 };
        try path.pushTriangle(gpa, .{ d[0], d[1], d[2] }, .{ inside, inside, inside });
        try path.pushTriangle(gpa, .{ d[0], d[2], d[3] }, .{ inside, inside, inside });
        path.content_mask = mask;
        path.color = color.solidBackground(c);
        try sc.insertPath(gpa, path);
    }

    /// One monochrome glyph with baseline origin `origin` (logical px), as `Window.paintGlyph`
    /// (identity), `paintGlyphTransformed` (composited) or `paintGlyphRasterTransformed` (raster).
    fn glyph(d: *Demo, sc: *scene_mod.Scene, atlas: *zpui.atlas.Atlas, s: f32, mask: scene_mod.ContentMask, origin: Point, font_id: text.FontId, glyph_id: text.GlyphId, size: f32, c: Hsla, t: RasterTransform, mode: Mode) !void {
        var g = text.line.glyphRenderParams(font_id, glyph_id, size, origin, s, false);
        g.params.dilation = d.ts.glyphDilation(c);
        var xf: scene_mod.TransformationMatrix = .unit;
        if (!t.isIdentity()) switch (mode) {
            .raster => g.params.raster_transform = t.canonical(),
            .composited => {
                // About the baseline origin in device px (paint.zig `compositeMatrix`).
                const o: Point = .{ .x = origin.x * s, .y = origin.y * s };
                const m: scene_mod.TransformationMatrix = .{ .rotation_scale = .{ .{ t.a, t.c }, .{ t.b, t.d } } };
                xf = scene_mod.TransformationMatrix.unit.translate(o).compose(m).translate(.{ .x = -o.x, .y = -o.y });
            },
        };
        const sprite = (try d.ts.rasterizeToAtlas(atlas, g.params, g.origin)) orelse return;
        try sc.insertMonochromeSprite(d.gpa, .{ .bounds = sprite.bounds, .content_mask = mask, .color = c, .tile = sprite.tile, .transformation = xf });
    }

    /// `str` shaped in `font_id` and laid out from the baseline `origin` along `t`
    /// (`Window.paintTextRunRasterTransformed`: positions and outlines both transformed).
    fn line(d: *Demo, sc: *scene_mod.Scene, atlas: *zpui.atlas.Atlas, s: f32, mask: scene_mod.ContentMask, origin: Point, str: []const u8, font_id: text.FontId, size: f32, c: Hsla, t: RasterTransform, mode: Mode) !f32 {
        const layout = try d.ts.platform.vtable.layoutLine(d.ts.platform.ptr, d.arena.allocator(), str, size, &.{.{ .len = str.len, .font_id = font_id }});
        for (layout.runs) |run| for (run.glyphs) |gl| {
            const p = t.apply(gl.position);
            try d.glyph(sc, atlas, s, mask, .{ .x = origin.x + p.x, .y = origin.y + p.y }, run.font_id, gl.id, size, c, t, mode);
        };
        return layout.width;
    }

    fn keyboard(d: *Demo, sc: *scene_mod.Scene, atlas: *zpui.atlas.Atlas, s: f32, mask: scene_mod.ContentMask, origin: Point, mode: Mode) !void {
        const t = legendTransform();
        // Base plate under all keys.
        try parallelogram(sc, d.gpa, s, mask, .{
            plane(origin, -0.25, -0.25), plane(origin, 11.5, -0.25), plane(origin, 11.5, 4.25), plane(origin, -0.25, 4.25),
        }, plate);
        for (rows, stagger, 0..) |row, off, r| {
            const y: f32 = @floatFromInt(r);
            for (row, 0..) |ch, k| {
                const x = off + @as(f32, @floatFromInt(k));
                const top = [4]Point{ plane(origin, x + 0.08, y + 0.08), plane(origin, x + 0.92, y + 0.08), plane(origin, x + 0.92, y + 0.86), plane(origin, x + 0.08, y + 0.86) };
                // Front face: the top's near edge dropped by the key height.
                try parallelogram(sc, d.gpa, s, mask, .{ top[3], top[2], top[2].add(.{ .x = 0, .y = 6 }), top[3].add(.{ .x = 0, .y = 6 }) }, cap_side);
                try parallelogram(sc, d.gpa, s, mask, top, cap_top);
                const gid = d.ts.platform.vtable.glyphForChar(d.ts.platform.ptr, d.legend_font, ch) orelse continue;
                try d.glyph(sc, atlas, s, mask, plane(origin, x + 0.26, y + 0.7), d.legend_font, gid, 18, legend, t, mode);
            }
        }
        // A longer line along the same matrix (advance vectors transformed too).
        _ = try d.line(sc, atlas, s, mask, plane(origin, 0.6, 5.6), "Sheared Ag Wy 1/4 Rendering", d.legend_font, 30, accent, t, mode);
    }

    fn buildScene(d: *Demo, sc: *scene_mod.Scene, atlas: *zpui.atlas.Atlas, s: f32) !void {
        _ = d.arena.reset(.retain_capacity);
        sc.clear(d.gpa);
        const mask = fullMask(.{ .width = logical_w * s, .height = logical_h * s });
        try quad(sc, d.gpa, s, mask, 0, 0, logical_w, logical_h, 0, bg);
        const panels = [_]struct { x: f32, mode: Mode, title: []const u8, sub: []const u8 }{
            .{ .x = 20, .mode = .composited, .title = "Composited", .sub = "paintGlyphTransformed: upright raster stretched by the matrix" },
            .{ .x = 630, .mode = .raster, .title = "Raster-transformed", .sub = "paintGlyphRasterTransformed: the rasterizer draws the transformed outline" },
        };
        for (panels) |p| {
            try quad(sc, d.gpa, s, mask, p.x, 20, 590, logical_h - 40, 14, panel);
            _ = try d.line(sc, atlas, s, mask, .{ .x = p.x + 20, .y = 52 }, p.title, d.label_font, 18, label, .identity, p.mode);
            _ = try d.line(sc, atlas, s, mask, .{ .x = p.x + 20, .y = 74 }, p.sub, d.legend_font, 12, muted, .identity, p.mode);
            try d.keyboard(sc, atlas, s, mask, .{ .x = p.x + 90, .y = 110 }, p.mode);
            // A large legend under a much stronger shear (and squash), where stretching an
            // upright bitmap visibly smears the strokes.
            const strong = RasterTransform.fromBasis(.{ 1, 0.08 }, .{ 0.85, -0.5 });
            _ = try d.line(sc, atlas, s, mask, .{ .x = p.x + 60, .y = 425 }, "Keycap Rg&", d.label_font, 56, label, strong, p.mode);
        }
        sc.finish();
    }

    // -- window -----------------------------------------------------------------------------

    fn onLaunch(ctx: ?*anyopaque, _: void) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        d.window = d.plat.openWindow(.{
            .bounds = .{ .origin = .{ .x = 40, .y = 40 }, .size = .{ .width = logical_w, .height = logical_h } },
            .titlebar = .{ .title = "zpui glyph transforms" },
            .app_id = "dev.zpui.glyph-transform-demo",
        }) catch |e| {
            std.debug.print("openWindow failed: {t}\n", .{e});
            if (d.smoke_frames != null) {
                std.debug.print("WARN: no window; rendering the smoke image offscreen only\n", .{});
                d.finishSmoke();
            }
            d.plat.quit();
            return;
        };
        const w = d.window.?;
        w.setCallbacks(.{ .ctx = d, .request_frame = onRequestFrame, .resize = onResize, .close = onClose });
        d.plat.vtable.activate(d.plat.ptr, true); // macOS: frames arrive for the front app
        w.requestFrame();
        if (d.smoke_frames != null) d.plat.dispatcher().dispatchAfter(watchdog_ns, .{ .ctx = d, .run = onWatchdog });
    }

    fn onRequestFrame(ctx: ?*anyopaque, _: bool) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        if (d.done) return;
        const w = d.window orelse return;
        d.buildScene(&d.scene, w.spriteAtlas(), w.scaleFactor()) catch |e| std.debug.print("scene error: {t}\n", .{e});
        w.draw(&d.scene) catch |e| std.debug.print("draw error: {t}\n", .{e});
        d.frames += 1;
        if (d.smoke_frames) |n| {
            if (d.frames >= n) {
                std.debug.print("rendered {d} frames; capturing\n", .{d.frames});
                d.finishSmoke();
                d.plat.quit();
                return;
            }
            w.requestFrame();
        }
    }

    fn onResize(ctx: ?*anyopaque, _: platform.Size, _: f32) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        if (d.window) |w| w.requestFrame();
    }

    fn onClose(ctx: ?*anyopaque) void {
        const d: *Demo = @ptrCast(@alignCast(ctx.?));
        d.window = null;
        d.plat.quit();
    }

    fn onWatchdog(ctx: *anyopaque) void {
        const d: *Demo = @ptrCast(@alignCast(ctx));
        if (d.done) return;
        std.debug.print("FAIL: only {d}/{d} frames within {d}s; rendering the smoke image offscreen\n", .{ d.frames, d.smoke_frames.?, watchdog_ns / std.time.ns_per_s });
        d.finishSmoke();
        d.exit_code = 1;
        d.plat.quit();
    }

    // -- offscreen capture ------------------------------------------------------------------

    fn finishSmoke(d: *Demo) void {
        d.done = true;
        d.captureOffscreen() catch |e| {
            std.debug.print("FAIL: offscreen capture: {t}\n", .{e});
            d.exit_code = 1;
        };
    }

    /// The same scene through an offscreen renderer (its own atlas), written as a PNG.
    fn captureOffscreen(d: *Demo) !void {
        const s = d.scale_override orelse if (d.window) |w| w.scaleFactor() else 2;
        const size: zpui.Size(zpui.DevicePixels) = .{ .width = @intFromFloat(@round(logical_w * s)), .height = @intFromFloat(@round(logical_h * s)) };
        var r = try Renderer.init(d.gpa, .{ .size = size, .validation = false });
        defer r.deinit();
        var sc: scene_mod.Scene = .{};
        defer sc.deinit(d.gpa);
        try d.buildScene(&sc, r.atlas(), s);
        try r.drawScene(&sc, size, s, bg);
        const pixels = try r.readPixels(d.gpa);
        defer d.gpa.free(pixels);
        // Opaque background: premultiplied == straight. Sanity: legend-colored (0x18181b) ink
        // made it onto the caps (no other color in the scene is that close to it).
        var dark_on_light: usize = 0;
        var i: usize = 0;
        while (i + 4 <= pixels.len) : (i += 4) {
            const px = pixels[i..][0..3];
            if (px[0] >= 20 and px[0] <= 28 and px[1] >= 20 and px[1] <= 28 and px[2] >= 23 and px[2] <= 31) dark_on_light += 1;
        }
        const encoded = try png.encode(d.gpa, @intCast(size.width), @intCast(size.height), pixels);
        defer d.gpa.free(encoded);
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(d.io, "zig-out");
        try cwd.writeFile(d.io, .{ .sub_path = output_path, .data = encoded });
        std.debug.print("wrote {s} ({d}x{d} @{d}x, {d} legend-ink pixels)\n", .{ output_path, size.width, size.height, s, dark_on_light });
        if (dark_on_light < 100) return error.NoLegendInk;
    }
};

fn createPlatform(gpa: std.mem.Allocator, io: std.Io) !platform.Platform {
    if (builtin.os.tag == .linux) return zpui.linux_platform.create(gpa, .{ .io = io });
    if (builtin.os.tag == .macos) return zpui.mac_platform.create(gpa);
    if (builtin.os.tag == .windows) return zpui.windows_platform.create(gpa, .{});
    return error.UnsupportedPlatform;
}

pub fn main(init: std.process.Init) !void {
    // c_allocator: the window may still be open when `run` returns (process exit cleans up).
    const gpa = std.heap.c_allocator;
    const smoke: ?u64 = if (init.environ_map.get("ZPUI_SMOKE_FRAMES")) |v| std.fmt.parseInt(u64, v, 10) catch 30 else null;
    const scale_override: ?f32 = if (init.environ_map.get("ZPUI_DEMO_SCALE")) |v| std.fmt.parseFloat(f32, v) catch null else null;

    // Without a display server the smoke test still renders offscreen (platform text system only).
    const plat: ?platform.Platform = createPlatform(gpa, init.io) catch |e| blk: {
        if (smoke == null) return e;
        std.debug.print("WARN: no platform ({t}); rendering the smoke image offscreen only\n", .{e});
        break :blk null;
    };
    var d: Demo = .{
        .gpa = gpa,
        .io = init.io,
        .plat = plat orelse undefined, // only touched from platform callbacks
        .ts = .init(gpa, if (plat) |p| p.textSystem() else try text.createPlatformTextSystem(gpa)),
        .arena = .init(gpa),
        .smoke_frames = smoke,
        .scale_override = scale_override,
    };
    for ([_]assets.Font{ .geist_regular, .geist_medium, .geist_semi_bold }) |f| try d.ts.addFont(f.info().data);
    d.legend_font = try d.ts.resolveFont(.{ .family = "Geist", .weight = 500 });
    d.label_font = try d.ts.resolveFont(.{ .family = "Geist", .weight = 600 });
    std.debug.print("zpui glyph-transform-demo: smoke={?d} raster transforms={}\n", .{ smoke, d.ts.platform.vtable.raster_transforms });

    if (plat) |p| p.run(.{ .ctx = &d, .func = Demo.onLaunch });
    if (smoke != null and !d.done) {
        // The run loop ended before a frame (e.g. no display): still produce the image.
        d.finishSmoke();
    }
    std.debug.print("exit after {d} frames (code {d})\n", .{ d.frames, d.exit_code });
    if (d.exit_code != 0) std.process.exit(d.exit_code);
}
