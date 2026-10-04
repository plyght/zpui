//! CPU text raster check: shapes a sample paragraph with the platform text system
//! (Geist 14px / 22px line height, bold, emoji, CJK, a JetBrains Mono line), paints it
//! through a `GlyphPainter` that blits rasterized glyphs into an RGBA bitmap, and writes
//! zig-out/text-dump.png. Panels: grayscale @1x, LCD subpixel @1x, grayscale @2x.
//!
//! `zig build text-dump`

const std = @import("std");
const zpui = @import("zpui");
const png = @import("png.zig");

const text = zpui.text;
const Hsla = zpui.Hsla;
const geometry = zpui.geometry;

const font_dir = "/home/user/zeron/crates/ui/assets/fonts/";
const output_path = "zig-out/text-dump.png";

const Canvas = struct {
    width: u32,
    height: u32,
    /// RGBA8, straight alpha (opaque background).
    pixels: []u8,

    fn blend(self: *Canvas, x: i32, y: i32, rgb: [3]f32, cov: [3]f32) void {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const p = self.pixels[(@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 4 ..][0..3];
        for (0..3) |k| {
            const d: f32 = @floatFromInt(p[k]);
            p[k] = @intFromFloat(@round(d * (1 - cov[k]) + rgb[k] * 255 * cov[k]));
        }
    }

    fn fill(self: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32, c: Hsla) void {
        const rgba = c.toRgba();
        var y: i32 = @intFromFloat(@round(y0));
        while (@as(f32, @floatFromInt(y)) < @round(y1)) : (y += 1) {
            var x: i32 = @intFromFloat(@round(x0));
            while (@as(f32, @floatFromInt(x)) < @round(x1)) : (x += 1) {
                self.blend(x, y, .{ rgba.r, rgba.g, rgba.b }, @splat(rgba.a));
            }
        }
    }
};

/// `GlyphPainter` that rasterizes through the core `TextSystem` and blits on the CPU.
const CpuPainter = struct {
    canvas: *Canvas,
    ts: *text.TextSystem,
    gpa: std.mem.Allocator,
    scale: f32,

    fn painter(self: *CpuPainter, subpixel: bool) text.GlyphPainter {
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
            .scale_factor = self.scale,
            .subpixel_rendering = subpixel,
        };
    }

    fn cast(ptr: *anyopaque) *CpuPainter {
        return @ptrCast(@alignCast(ptr));
    }

    fn paintGlyph(ptr: *anyopaque, params: text.RenderGlyphParams, origin: geometry.Point(f32), color: Hsla) anyerror!void {
        const self = cast(ptr);
        const bounds = try self.ts.rasterBounds(params);
        if (bounds.size.width <= 0 or bounds.size.height <= 0) return;
        const r = try self.ts.rasterizeGlyph(self.gpa, params);
        defer self.gpa.free(r.bytes);
        const rgba = color.toRgba();
        const ox: i32 = @as(i32, @intFromFloat(origin.x)) + bounds.origin.x;
        const oy: i32 = @as(i32, @intFromFloat(origin.y)) + bounds.origin.y;
        const w: usize = @intCast(bounds.size.width);
        for (0..@intCast(bounds.size.height)) |y| for (0..w) |x| {
            const cov: [3]f32 = if (params.subpixel_rendering) blk: {
                const p = r.bytes[(y * w + x) * 4 ..][0..4]; // BGRA coverage
                break :blk .{ f(p[2]), f(p[1]), f(p[0]) };
            } else @splat(f(r.bytes[y * w + x]));
            self.canvas.blend(ox + @as(i32, @intCast(x)), oy + @as(i32, @intCast(y)), .{ rgba.r, rgba.g, rgba.b }, .{ cov[0] * rgba.a, cov[1] * rgba.a, cov[2] * rgba.a });
        };
    }

    fn paintEmoji(ptr: *anyopaque, params: text.RenderGlyphParams, origin: geometry.Point(f32)) anyerror!void {
        const self = cast(ptr);
        const bounds = try self.ts.rasterBounds(params);
        if (bounds.size.width <= 0 or bounds.size.height <= 0) return;
        const r = try self.ts.rasterizeGlyph(self.gpa, params);
        defer self.gpa.free(r.bytes);
        const ox: i32 = @as(i32, @intFromFloat(origin.x)) + bounds.origin.x;
        const oy: i32 = @as(i32, @intFromFloat(origin.y)) + bounds.origin.y;
        const w: usize = @intCast(bounds.size.width);
        for (0..@intCast(bounds.size.height)) |y| for (0..w) |x| {
            const p = r.bytes[(y * w + x) * 4 ..][0..4]; // BGRA, straight alpha
            const a = f(p[3]);
            if (a == 0) continue;
            self.canvas.blend(ox + @as(i32, @intCast(x)), oy + @as(i32, @intCast(y)), .{ f(p[2]), f(p[1]), f(p[0]) }, @splat(a));
        };
    }

    fn paintQuad(ptr: *anyopaque, b: geometry.Bounds(f32), color: Hsla) anyerror!void {
        const self = cast(ptr);
        const s = self.scale;
        self.canvas.fill(b.origin.x * s, b.origin.y * s, (b.origin.x + b.size.width) * s, (b.origin.y + b.size.height) * s, color);
    }

    fn paintUnderline(ptr: *anyopaque, o: geometry.Point(f32), width: f32, style: text.UnderlineStyle) anyerror!void {
        const self = cast(ptr);
        const s = self.scale;
        const t = @max(@round(style.thickness * s), 1);
        const y = @round(o.y * s);
        self.canvas.fill(o.x * s, y, (o.x + width) * s, y + t, style.color.?);
    }

    fn paintStrikethrough(ptr: *anyopaque, o: geometry.Point(f32), width: f32, style: text.StrikethroughStyle) anyerror!void {
        const self = cast(ptr);
        const s = self.scale;
        const t = @max(@round(style.thickness * s), 1);
        const y = @round(o.y * s);
        self.canvas.fill(o.x * s, y, (o.x + width) * s, y + t, style.color.?);
    }

    fn f(v: u8) f32 {
        return @as(f32, @floatFromInt(v)) / 255;
    }
};

const Para = struct {
    str: []const u8,
    runs: []const text.TextRun,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const platform_ts = try text.createPlatformTextSystem(gpa);
    defer text.destroyPlatformTextSystem(platform_ts);
    var ts: text.TextSystem = .init(gpa, platform_ts);
    defer ts.deinit();

    var font_bytes: std.ArrayList([]u8) = .empty;
    defer {
        for (font_bytes.items) |bytes| gpa.free(bytes);
        font_bytes.deinit(gpa);
    }
    for ([_][]const u8{ "Geist.ttf", "Geist-Bold.ttf", "Geist-SemiBold.ttf", "Geist-Italic.ttf" }) |name| {
        const path = try std.fmt.allocPrint(gpa, font_dir ++ "{s}", .{name});
        defer gpa.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 << 20));
        try font_bytes.append(gpa, bytes);
        try ts.addFont(bytes);
    }

    var wts: text.WindowTextSystem = .init(&ts);
    defer wts.deinit();

    const ink = zpui.rgb(0x1f2328).toHsla();
    const blue = zpui.rgb(0x0969da).toHsla();
    const geist: text.Font = .{ .family = "Geist" };
    const bold: text.Font = .{ .family = "Geist", .weight = text.weight.bold };
    const italic: text.Font = .{ .family = "Geist", .style = .italic };
    const mono: text.Font = .{ .family = "JetBrains Mono" };

    const p1 = "zpui renders text with HarfBuzz shaping and FreeType rasterization. Bold words, italic words, an emoji 🎉 and CJK 你好世界 fall back per character; long lines wrap at word boundaries — keeping closing punctuation (like this).";
    const bold_start = std.mem.indexOf(u8, p1, "Bold words").?;
    const italic_start = std.mem.indexOf(u8, p1, "italic words").?;
    const link_start = std.mem.indexOf(u8, p1, "word boundaries").?;
    const runs1 = [_]text.TextRun{
        .{ .len = bold_start, .font = geist, .color = ink },
        .{ .len = "Bold words".len, .font = bold, .color = ink },
        .{ .len = 2, .font = geist, .color = ink },
        .{ .len = "italic words".len, .font = italic, .color = ink },
        .{ .len = link_start - italic_start - "italic words".len, .font = geist, .color = ink },
        .{ .len = "word boundaries".len, .font = geist, .color = blue, .underline = .{ .thickness = 1 } },
        .{ .len = p1.len - link_start - "word boundaries".len, .font = geist, .color = ink },
    };
    const p2 = "const answer = items.len -> 42; // != 0 ✓";
    const runs2 = [_]text.TextRun{.{ .len = p2.len, .font = mono, .color = ink, .background_color = zpui.rgb(0xeff1f3).toHsla() }};
    const p3 = "Kerning: AVATAR Ty To Wa · office ﬁ fi — 日本語のテキスト 👩‍👩‍👧 🇯🇵";
    const runs3 = [_]text.TextRun{.{ .len = p3.len, .font = geist, .color = ink }};
    const paras = [_]Para{ .{ .str = p1, .runs = &runs1 }, .{ .str = p2, .runs = &runs2 }, .{ .str = p3, .runs = &runs3 } };

    const font_size: f32 = 14;
    const line_height: f32 = 22;
    const wrap_width: f32 = 520;
    const margin: f32 = 16;
    const panel_w: f32 = wrap_width + 2 * margin;

    // Shape once; measure height.
    var shaped: std.ArrayList([]text.WrappedLine) = .empty;
    defer {
        for (shaped.items) |lines| text.freeLines(gpa, lines);
        shaped.deinit(gpa);
    }
    var content_h: f32 = 0;
    for (paras) |p| {
        const lines = try wts.shapeText(p.str, font_size, p.runs, .{ .wrap_width = wrap_width });
        try shaped.append(gpa, lines);
        for (lines) |l| content_h += l.size(line_height).height;
        content_h += 8;
    }
    const panel_h = content_h + 2 * margin;

    const panels = [_]struct { scale: f32, subpixel: bool }{
        .{ .scale = 1, .subpixel = false },
        .{ .scale = 1, .subpixel = true },
        .{ .scale = 2, .subpixel = false },
    };
    var total_h: f32 = 0;
    var max_w: f32 = 0;
    for (panels) |p| {
        total_h += panel_h * p.scale;
        max_w = @max(max_w, panel_w * p.scale);
    }
    var canvas: Canvas = .{ .width = @intFromFloat(max_w), .height = @intFromFloat(total_h), .pixels = undefined };
    canvas.pixels = try gpa.alloc(u8, canvas.width * canvas.height * 4);
    defer gpa.free(canvas.pixels);
    @memset(canvas.pixels, 255);

    var panel_y: f32 = 0; // logical y of the panel at its scale
    for (panels) |p| {
        var cpu: CpuPainter = .{ .canvas = &canvas, .ts = &ts, .gpa = gpa, .scale = p.scale };
        const painter = cpu.painter(p.subpixel);
        const top = panel_y / p.scale;
        // Panel separator and faint line-box guides.
        canvas.fill(0, panel_y, max_w, panel_y + 1, zpui.rgb(0xd0d7de).toHsla());
        var y: f32 = top + margin;
        for (shaped.items) |lines| {
            for (lines) |l| {
                const h = l.size(line_height).height;
                var row: f32 = 0;
                while (row < h) : (row += line_height) {
                    try painter.vtable.paintQuad(painter.ptr, .{ .origin = .{ .x = margin - 6, .y = y + row }, .size = .{ .width = 2, .height = line_height - 1 } }, zpui.rgb(0xe5e9ee).toHsla());
                }
                try l.paintBackground(painter, .{ .x = margin, .y = y }, line_height, .left, null);
                try l.paint(painter, .{ .x = margin, .y = y }, line_height, .left, null);
                y += h;
            }
            y += 8;
        }
        panel_y += panel_h * p.scale;
    }

    const encoded = try png.encode(gpa, canvas.width, canvas.height, canvas.pixels);
    defer gpa.free(encoded);
    std.Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = encoded });
    std.debug.print("wrote {s} ({d}x{d})\n", .{ output_path, canvas.width, canvas.height });
}
