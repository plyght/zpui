//! zpui side of the font comparison (tools/font-compare, workflow font-compare.yml).
//!
//! Renders every case in cases.json through the real text path (WindowTextSystem shaping,
//! `GlyphPainter.paintGlyph` quantization, the platform rasterizer, the atlas and the
//! Metal sprite shader) on the case background, with the same row geometry as native.swift:
//!   <out>/zpui-s{1,2}.png   offscreen renders at 1x and 2x
//!   <out>/zpui.json         per case: line width, glyph ids and x positions
//!
//! `zig build font-compare -- tools/font-compare/cases.json zig-out/font-compare [--family NAME]`

const std = @import("std");
const zpui = @import("zpui");
const png = @import("png");

const text = zpui.text;
const scene_mod = zpui.scene;
const Scene = zpui.Scene;
const Hsla = zpui.Hsla;
const color = zpui.color;
const geometry = zpui.geometry;
const Renderer = zpui.renderer.Renderer;

const Case = struct { id: []const u8, text: []const u8, size: f32, weight: f32, fg: []const u8, bg: []const u8 };
const Cases = struct { width: f32, cases: []const Case };

/// Shared row geometry (native.swift uses the same formulas).
fn rowHeight(c: Case) f32 {
    return @ceil(c.size * 1.6) + 8;
}
fn baseline(c: Case) f32 {
    return @round(rowHeight(c) * 0.5 + c.size * 0.35);
}
const text_x: f32 = 16;

/// "#rrggbb" or "#rrggbbaa".
fn parseColor(hex: []const u8) Hsla {
    const s = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
    const v = std.fmt.parseInt(u32, s, 16) catch 0;
    if (s.len == 8) return color.rgba(v).toHsla();
    return color.rgb(v).toHsla();
}

/// `GlyphPainter` that inserts sprites into a Scene, like `window/paint.zig` does.
const ScenePainter = struct {
    gpa: std.mem.Allocator,
    scene: *Scene,
    atlas: *zpui.atlas.Atlas,
    ts: *text.TextSystem,
    mask: scene_mod.ContentMask,

    fn painter(self: *ScenePainter, scale: f32) text.GlyphPainter {
        return .{
            .ptr = self,
            .vtable = &.{
                .paintGlyph = paintGlyph,
                .paintEmoji = paintEmoji,
                .paintQuad = paintQuad,
                .paintUnderline = paintUnderline,
                .paintStrikethrough = paintStrikethrough,
            },
            .text_system = self.ts,
            .scale_factor = scale,
            .subpixel_rendering = false,
        };
    }

    fn cast(ptr: *anyopaque) *ScenePainter {
        return @ptrCast(@alignCast(ptr));
    }

    fn paintGlyph(ptr: *anyopaque, params: text.RenderGlyphParams, origin: geometry.Point(geometry.ScaledPixels), c: Hsla) anyerror!void {
        const self = cast(ptr);
        const sprite = (try self.ts.rasterizeToAtlas(self.atlas, params, origin)) orelse return;
        try self.scene.insertMonochromeSprite(self.gpa, .{ .bounds = sprite.bounds, .content_mask = self.mask, .color = c, .tile = sprite.tile });
    }
    fn paintEmoji(_: *anyopaque, _: text.RenderGlyphParams, _: geometry.Point(geometry.ScaledPixels)) anyerror!void {}
    fn paintQuad(_: *anyopaque, _: zpui.Bounds(f32), _: Hsla) anyerror!void {}
    fn paintUnderline(_: *anyopaque, _: geometry.Point(f32), _: f32, _: text.UnderlineStyle) anyerror!void {}
    fn paintStrikethrough(_: *anyopaque, _: geometry.Point(f32), _: f32, _: text.StrikethroughStyle) anyerror!void {}
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    // Positional: cases.json, out dir. `--family NAME` renders another family (the app
    // rendered its "system" choice as Helvetica before the fix; see font-compare.yml).
    var family: []const u8 = ".SystemUIFont";
    var positional: std.ArrayList([]const u8) = .empty;
    var ai: usize = 1;
    while (ai < argv.len) : (ai += 1) {
        if (std.mem.eql(u8, argv[ai], "--family") and ai + 1 < argv.len) {
            ai += 1;
            family = argv[ai];
        } else try positional.append(arena, argv[ai]);
    }
    const cases_path = if (positional.items.len > 0) positional.items[0] else "tools/font-compare/cases.json";
    const out_dir = if (positional.items.len > 1) positional.items[1] else "zig-out/font-compare";

    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(io, cases_path, arena, .limited(1 << 20));
    const spec = try std.json.parseFromSliceLeaky(Cases, arena, bytes, .{ .ignore_unknown_fields = true });
    try cwd.createDirPath(io, out_dir);

    const pts = try text.createPlatformTextSystem(gpa);
    defer text.destroyPlatformTextSystem(pts);
    var ts = text.TextSystem.init(gpa, pts);
    defer ts.deinit();
    var wts = text.WindowTextSystem.init(&ts);
    defer wts.deinit();

    var total_h: f32 = 0;
    for (spec.cases) |c| total_h += rowHeight(c);

    // Metrics (scale independent).
    var json: std.ArrayList(u8) = .empty;
    try json.appendSlice(arena, "{\"cases\":[");
    for (spec.cases, 0..) |c, ci| {
        const runs = [_]text.TextRun{.{ .len = c.text.len, .font = .{ .family = family, .weight = c.weight }, .color = parseColor(c.fg) }};
        const line = try wts.shapeLine(c.text, c.size, &runs, null);
        defer line.deinit(gpa);
        const layout = line.lineLayout();
        if (ci > 0) try json.append(arena, ',');
        try json.print(arena, "{{\"id\":\"{s}\",\"width\":{d:.4},\"ascent\":{d:.4},\"descent\":{d:.4},\"x\":[", .{ c.id, layout.width, layout.ascent, layout.descent });
        var first = true;
        for (layout.runs) |r| for (r.glyphs) |g| {
            if (!first) try json.append(arena, ',');
            first = false;
            try json.print(arena, "{d:.4}", .{g.position.x});
        };
        try json.appendSlice(arena, "],\"glyphs\":[");
        first = true;
        for (layout.runs) |r| for (r.glyphs) |g| {
            if (!first) try json.append(arena, ',');
            first = false;
            try json.print(arena, "{d}", .{g.id});
        };
        try json.print(arena, "],\"font_ids\":[", .{});
        for (layout.runs, 0..) |r, ri| {
            if (ri > 0) try json.append(arena, ',');
            try json.print(arena, "{d}", .{@intFromEnum(r.font_id)});
        }
        try json.appendSlice(arena, "]}");
    }
    try json.appendSlice(arena, "]}\n");
    const json_path = try std.fmt.allocPrint(arena, "{s}/zpui.json", .{out_dir});
    try cwd.writeFile(io, .{ .sub_path = json_path, .data = json.items });
    std.debug.print("wrote {s}\n", .{json_path});

    for ([_]f32{ 1, 2 }) |scale| {
        const w: u32 = @intFromFloat(spec.width * scale);
        const hh: u32 = @intFromFloat(total_h * scale);
        // Apple Silicon CI runners expose no Metal device: composite on the CPU there
        // (same rasterizer and glyph quantization; straight-alpha blend like the sprite shader).
        const pixels = renderGpu(gpa, &ts, &wts, spec, family, scale, w, hh) catch |err| blk: {
            std.debug.print("Metal unavailable ({t}); compositing on the CPU\n", .{err});
            break :blk try renderCpu(gpa, &ts, &wts, spec, family, scale, w, hh);
        };
        defer gpa.free(pixels);
        for (0..pixels.len / 4) |i| pixels[i * 4 + 3] = 255;
        const encoded = try png.encode(gpa, w, hh, pixels);
        defer gpa.free(encoded);
        const path = try std.fmt.allocPrint(arena, "{s}/zpui-s{d}.png", .{ out_dir, @as(u32, @intFromFloat(scale)) });
        try cwd.writeFile(io, .{ .sub_path = path, .data = encoded });
        std.debug.print("wrote {s} ({d}x{d})\n", .{ path, w, hh });
    }
}

/// Paint every case's glyphs through `painter` (row backgrounds are the caller's).
fn paintCases(gpa: std.mem.Allocator, wts: *text.WindowTextSystem, spec: Cases, family: []const u8, painter: text.GlyphPainter) !void {
    var y: f32 = 0;
    for (spec.cases) |c| {
        const fg = parseColor(c.fg);
        const runs = [_]text.TextRun{.{ .len = c.text.len, .font = .{ .family = family, .weight = c.weight }, .color = fg }};
        const line = try wts.shapeLine(c.text, c.size, &runs, null);
        defer line.deinit(gpa);
        const by = y + baseline(c);
        for (line.lineLayout().runs) |r| for (r.glyphs) |g| {
            try painter.paintGlyph(.{ .x = text_x + g.position.x, .y = by }, r.font_id, g.id, c.size, fg);
        };
        y += rowHeight(c);
    }
}

fn renderGpu(gpa: std.mem.Allocator, ts: *text.TextSystem, wts: *text.WindowTextSystem, spec: Cases, family: []const u8, scale: f32, w: u32, hh: u32) ![]u8 {
    const size: zpui.Size(zpui.DevicePixels) = .{ .width = @intCast(w), .height = @intCast(hh) };
    var renderer = try Renderer.init(gpa, .{ .size = size, .transparent = false });
    defer renderer.deinit();
    var scene: Scene = .{};
    defer scene.deinit(gpa);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(hh);
    const mask: scene_mod.ContentMask = .{ .bounds = .{ .origin = .zero, .size = .{ .width = fw, .height = fh } } };
    var y: f32 = 0;
    for (spec.cases) |c| {
        const h = rowHeight(c);
        try scene.insertQuad(gpa, .{
            .bounds = .{ .origin = .{ .x = 0, .y = y * scale }, .size = .{ .width = fw, .height = h * scale } },
            .content_mask = mask,
            .background = color.solidBackground(parseColor(c.bg)),
        });
        y += h;
    }
    var sp: ScenePainter = .{ .gpa = gpa, .scene = &scene, .atlas = renderer.atlas(), .ts = ts, .mask = mask };
    try paintCases(gpa, wts, spec, family, sp.painter(scale));
    scene.finish();
    try renderer.drawScene(&scene, size, scale, color.transparent_black);
    return renderer.readPixels(gpa);
}

/// `GlyphPainter` that rasterizes through the TextSystem and blends into an RGBA buffer.
const CpuPainter = struct {
    gpa: std.mem.Allocator,
    ts: *text.TextSystem,
    pixels: []u8,
    w: u32,
    h: u32,

    fn cast(ptr: *anyopaque) *CpuPainter {
        return @ptrCast(@alignCast(ptr));
    }

    fn paintGlyph(ptr: *anyopaque, params: text.RenderGlyphParams, origin: geometry.Point(geometry.ScaledPixels), c: Hsla) anyerror!void {
        const self = cast(ptr);
        const r = try self.ts.rasterizeGlyph(self.gpa, params);
        defer self.gpa.free(r.bytes);
        const rgba = c.toRgba();
        const ox: i32 = @as(i32, @intFromFloat(origin.x)) + r.bounds.origin.x;
        const oy: i32 = @as(i32, @intFromFloat(origin.y)) + r.bounds.origin.y;
        const bw: usize = @intCast(r.bounds.size.width);
        for (0..@intCast(r.bounds.size.height)) |gy| for (0..bw) |gx| {
            const cov = @as(f32, @floatFromInt(r.bytes[gy * bw + gx])) / 255 * rgba.a;
            if (cov == 0) continue;
            const x = ox + @as(i32, @intCast(gx));
            const y = oy + @as(i32, @intCast(gy));
            if (x < 0 or y < 0 or x >= self.w or y >= self.h) continue;
            const p = self.pixels[(@as(usize, @intCast(y)) * self.w + @as(usize, @intCast(x))) * 4 ..][0..3];
            for (p, [3]f32{ rgba.r, rgba.g, rgba.b }) |*ch, fc| {
                const d: f32 = @floatFromInt(ch.*);
                ch.* = @intFromFloat(@round(d * (1 - cov) + fc * 255 * cov));
            }
        };
    }
    fn paintEmoji(_: *anyopaque, _: text.RenderGlyphParams, _: geometry.Point(geometry.ScaledPixels)) anyerror!void {}
    fn paintQuad(_: *anyopaque, _: zpui.Bounds(f32), _: Hsla) anyerror!void {}
    fn paintUnderline(_: *anyopaque, _: geometry.Point(f32), _: f32, _: text.UnderlineStyle) anyerror!void {}
    fn paintStrikethrough(_: *anyopaque, _: geometry.Point(f32), _: f32, _: text.StrikethroughStyle) anyerror!void {}
};

fn renderCpu(gpa: std.mem.Allocator, ts: *text.TextSystem, wts: *text.WindowTextSystem, spec: Cases, family: []const u8, scale: f32, w: u32, hh: u32) ![]u8 {
    const pixels = try gpa.alloc(u8, @as(usize, w) * hh * 4);
    errdefer gpa.free(pixels);
    var y: f32 = 0;
    for (spec.cases) |c| {
        const bg = parseColor(c.bg).toRgba();
        const y0: usize = @intFromFloat(y * scale);
        const y1: usize = @min(hh, @as(usize, @intFromFloat((y + rowHeight(c)) * scale)));
        for (y0..y1) |py| for (0..w) |px| {
            const o = (py * w + px) * 4;
            pixels[o..][0..4].* = .{ @intFromFloat(@round(bg.r * 255)), @intFromFloat(@round(bg.g * 255)), @intFromFloat(@round(bg.b * 255)), 255 };
        };
        y += rowHeight(c);
    }
    var cp: CpuPainter = .{ .gpa = gpa, .ts = ts, .pixels = pixels, .w = w, .h = hh };
    const painter: text.GlyphPainter = .{
        .ptr = &cp,
        .vtable = &.{
            .paintGlyph = CpuPainter.paintGlyph,
            .paintEmoji = CpuPainter.paintEmoji,
            .paintQuad = CpuPainter.paintQuad,
            .paintUnderline = CpuPainter.paintUnderline,
            .paintStrikethrough = CpuPainter.paintStrikethrough,
        },
        .text_system = ts,
        .scale_factor = scale,
    };
    try paintCases(gpa, wts, spec, family, painter);
    return pixels;
}

comptime {
    // Analyze `main` in the SDK-less object build (`zig build font-compare-check`).
    _ = &main;
}
