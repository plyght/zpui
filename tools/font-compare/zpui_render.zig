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
        const size: zpui.Size(zpui.DevicePixels) = .{
            .width = @intFromFloat(spec.width * scale),
            .height = @intFromFloat(total_h * scale),
        };
        var renderer = try Renderer.init(gpa, .{ .size = size, .transparent = false });
        defer renderer.deinit();
        var scene: Scene = .{};
        defer scene.deinit(gpa);
        const mask: scene_mod.ContentMask = .{ .bounds = .{ .origin = .zero, .size = .{ .width = spec.width * scale, .height = total_h * scale } } };
        var sp: ScenePainter = .{ .gpa = gpa, .scene = &scene, .atlas = renderer.atlas(), .ts = &ts, .mask = mask };
        const painter = sp.painter(scale);

        var y: f32 = 0;
        for (spec.cases) |c| {
            const h = rowHeight(c);
            try scene.insertQuad(gpa, .{
                .bounds = .{ .origin = .{ .x = 0, .y = y * scale }, .size = .{ .width = spec.width * scale, .height = h * scale } },
                .content_mask = mask,
                .background = color.solidBackground(parseColor(c.bg)),
            });
            const fg = parseColor(c.fg);
            const runs = [_]text.TextRun{.{ .len = c.text.len, .font = .{ .family = family, .weight = c.weight }, .color = fg }};
            const line = try wts.shapeLine(c.text, c.size, &runs, null);
            defer line.deinit(gpa);
            const by = y + baseline(c);
            for (line.lineLayout().runs) |r| for (r.glyphs) |g| {
                try painter.paintGlyph(.{ .x = text_x + g.position.x, .y = by }, r.font_id, g.id, c.size, fg);
            };
            y += h;
        }
        scene.finish();
        try renderer.drawScene(&scene, size, scale, color.transparent_black);
        const pixels = try renderer.readPixels(gpa);
        defer gpa.free(pixels);
        const w: u32 = @intCast(size.width);
        const hh: u32 = @intCast(size.height);
        for (0..pixels.len / 4) |i| pixels[i * 4 + 3] = 255;
        const encoded = try png.encode(gpa, w, hh, pixels);
        defer gpa.free(encoded);
        const path = try std.fmt.allocPrint(arena, "{s}/zpui-s{d}.png", .{ out_dir, @as(u32, @intFromFloat(scale)) });
        try cwd.writeFile(io, .{ .sub_path = path, .data = encoded });
        std.debug.print("wrote {s} ({d}x{d})\n", .{ path, w, hh });
    }
}

comptime {
    // Analyze `main` in the SDK-less object build (`zig build font-compare-check`).
    _ = &main;
}
