//! Terminal render check: runs a shell command under a real PTY (forkpty),
//! feeds its output through the zeron terminal emulator (vendored Ghostty VT
//! core), builds the paint plan and rasterizes it on the CPU with zpui's
//! text system (FreeType/HarfBuzz, Geist Mono like zeron's terminal panel,
//! system fallback for CJK/emoji) using zeron's theme terminal palette.
//! Writes zig-out/term-dump.png.
//!
//!   zig build term-dump                       # built-in demo script
//!   zig build term-dump -- ls --color=always -la /usr
//!   zig build term-dump -- --light --cols 100 --rows 30 -- htop
const std = @import("std");
const zpui = @import("zpui");
const term = @import("zeron_terminal");
const theme_pkg = @import("zeron_theme");
const png = @import("png.zig");

const text = zpui.text;
const Hsla = zpui.Hsla;
const geometry = zpui.geometry;

pub const std_options: std.Options = .{ .log_level = .warn };

const font_dir = "/home/user/zeron/crates/ui/assets/fonts/";
const output_path = "zig-out/term-dump.png";

/// zeron view.rs metrics: 13px font, 18px rows, 12px padding.
const font_size: f32 = 13;
const line_height: f32 = 18;
const padding: f32 = 12;
const scale: f32 = 2;

const demo_script =
    \\printf '\033]0;term-dump: zeron terminal demo\007'
    \\printf '\033[1mzeron terminal\033[0m \033[2m·\033[0m Ghostty VT core on Zig 0.17 \033[2m(forkpty → feed → snapshot → paint)\033[0m\n\n'
    \\printf ' ansi   '; for i in 0 1 2 3 4 5 6 7; do printf '\033[4%sm %s \033[0m' $i $i; done; printf '\n        '
    \\for i in 0 1 2 3 4 5 6 7; do printf '\033[10%sm %s \033[0m' $i $((i+8)); done; printf '\n'
    \\printf ' fg     '; for i in 1 2 3 4 5 6; do printf '\033[3%smcolor%s \033[0m' $i $i; done; printf '\n'
    \\printf ' 256    '; for i in $(seq 16 6 231); do printf '\033[48;5;%sm \033[0m' $i; done; printf '\n'
    \\printf ' gray   '; for i in $(seq 232 255); do printf '\033[48;5;%sm  \033[0m' $i; done; printf '\n'
    \\printf ' rgb    '; for i in $(seq 0 2 70); do printf '\033[48;2;%s;%s;%sm \033[0m' $((i*3)) $((120+i)) $((255-i*3)); done; printf '\n\n'
    \\printf ' \033[1mbold\033[0m \033[2mfaint\033[0m \033[3mitalic\033[0m \033[4munderline\033[0m \033[4:3;58;2;255;80;80mcurly\033[0m \033[9mstrike\033[0m \033[7minverse\033[0m \033[1;3;38;5;214mbold-italic-214\033[0m \033]8;;https://zeron.sh\033\\link (osc 8)\033]8;;\033\\\n'
    \\printf ' ┌──────────────┬─────────┐  unicode: 你好世界 · café · e\314\201 · 🎉 · 👩‍👩‍👧 · 🇯🇵 · → ✓ ✗\n'
    \\printf ' │ box drawing  │ ▁▂▃▅▆▇█ │  wide chars stay on the grid: |宽|w|\n'
    \\printf ' └──────────────┴─────────┘\n\n'
    \\cd /tmp/zeron-term-dump-demo 2>/dev/null || { mkdir -p /tmp/zeron-term-dump-demo/src /tmp/zeron-term-dump-demo/docs && cd /tmp/zeron-term-dump-demo && touch README.md Cargo.toml && printf '#!/bin/sh\n' > run.sh && chmod +x run.sh && ln -sf README.md link.md; }
    \\printf '\033[32m~/zeron\033[0m \033[2m$\033[0m ls --color=always -l\n'
    \\ls --color=always -l | head -8
    \\printf '\033[32m~/zeron\033[0m \033[2m$\033[0m printf "\\033[6 q"   \033[2m# bar cursor (DECSCUSR)\033[0m\n'
    \\printf '\033[32m~/zeron\033[0m \033[2m$\033[0m '
    \\printf '\033[6 q'
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // ---- args ----
    var cols: u16 = 100;
    var rows: u16 = 28;
    var light = false;
    var cmd: std.ArrayList([:0]const u8) = .empty;
    defer cmd.deinit(gpa);
    {
        var it = try init.minimal.args.iterateAllocator(gpa);
        defer it.deinit();
        _ = it.next();
        var rest = false;
        while (it.next()) |arg| {
            if (!rest and std.mem.eql(u8, arg, "--")) {
                rest = true;
            } else if (!rest and std.mem.eql(u8, arg, "--light")) {
                light = true;
            } else if (!rest and std.mem.eql(u8, arg, "--cols")) {
                cols = try std.fmt.parseInt(u16, it.next() orelse return error.MissingValue, 10);
            } else if (!rest and std.mem.eql(u8, arg, "--rows")) {
                rows = try std.fmt.parseInt(u16, it.next() orelse return error.MissingValue, 10);
            } else {
                rest = true;
                try cmd.append(gpa, try gpa.dupeSentinel(u8, arg, 0));
            }
        }
    }
    defer for (cmd.items) |a| gpa.free(a);
    const argv: []const [:0]const u8 = if (cmd.items.len > 0) cmd.items else &.{ "bash", "-c", demo_script };

    // ---- theme ----
    const theme: theme_pkg.Theme = if (light) .light() else .dark();
    var pal = term.Palette.fromTheme(theme.terminal, if (light) .light else .dark);
    const cursor_rgba = theme.cursor.toRgba();
    pal.cursor = .{ .r = to8(cursor_rgba.r), .g = to8(cursor_rgba.g), .b = to8(cursor_rgba.b) };

    // ---- run under a PTY ----
    const emu = try term.Emulator.create(gpa, .{ .cols = cols, .rows = rows, .io = io });
    defer emu.destroy();
    try emu.setPalette(&pal); // OSC 10/11/4 queries answer with the theme
    const code = term.pty.run(gpa, emu, argv, .{ .timeout_ms = 8000, .steps = if (cmd.items.len > 0) &.{.{ .delay_ms = 1500, .input = "q" }} else &.{} }) catch |err| switch (err) {
        error.Timeout => @as(u8, 124),
        else => return err,
    };
    if (cmd.items.len == 0) {
        // Show the selection overlay: select the word "Ghostty" on row 0.
        try emu.startSelection(.semantic, .{ .row = 0, .col = 18 }, .left);
    }
    std.debug.print("exit={d} title={s}\n", .{ code, emu.title() orelse "(none)" });

    // ---- text system ----
    const platform_ts = try text.createPlatformTextSystem(gpa);
    defer text.destroyPlatformTextSystem(platform_ts);
    var ts: text.TextSystem = .init(gpa, platform_ts);
    defer ts.deinit();
    var font_bytes: std.ArrayList([]u8) = .empty;
    defer {
        for (font_bytes.items) |b| gpa.free(b);
        font_bytes.deinit(gpa);
    }
    for ([_][]const u8{ "GeistMono.ttf", "GeistMono-Bold.ttf", "GeistMono-Italic.ttf", "GeistMono-BoldItalic.ttf" }) |name| {
        const path = try std.fmt.allocPrint(gpa, font_dir ++ "{s}", .{name});
        defer gpa.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(8 << 20));
        try font_bytes.append(gpa, bytes);
        try ts.addFont(bytes);
    }
    var wts: text.WindowTextSystem = .init(&ts);
    defer wts.deinit();

    const mono: text.Font = .{ .family = theme_pkg.typography.font_mono };
    const mono_id = try ts.resolveFont(mono);
    const cell_w = try ts.emAdvance(mono_id, font_size);

    // ---- paint plan ----
    const snap = try emu.snapshot();
    var plan = try term.paint.build(gpa, snap, &pal);
    defer plan.deinit();

    const width_l = padding * 2 + cell_w * @as(f32, @floatFromInt(snap.cols));
    const height_l = padding * 2 + line_height * @as(f32, @floatFromInt(snap.rows));
    var canvas: Canvas = .{
        .width = @intFromFloat(@ceil(width_l * scale)),
        .height = @intFromFloat(@ceil(height_l * scale)),
        .pixels = undefined,
    };
    canvas.pixels = try gpa.alloc(u8, canvas.width * canvas.height * 4);
    defer gpa.free(canvas.pixels);
    // Panel background (terminal.background).
    const bg = pal.background;
    var i: usize = 0;
    while (i < canvas.pixels.len) : (i += 4) {
        canvas.pixels[i..][0..4].* = .{ bg.r, bg.g, bg.b, 255 };
    }

    var cpu: CpuPainter = .{ .canvas = &canvas, .ts = &ts, .gpa = gpa, .scale = scale };
    const painter = cpu.painter();

    const cellRect = struct {
        fn f(row: u16, col: u16, len: u16, cw: f32) geometry.Bounds(f32) {
            return .{
                .origin = .{ .x = padding + cw * @as(f32, @floatFromInt(col)), .y = padding + line_height * @as(f32, @floatFromInt(row)) },
                .size = .{ .width = cw * @as(f32, @floatFromInt(len)), .height = line_height },
            };
        }
    }.f;

    for (plan.backgrounds) |q| try painter.vtable.paintQuad(painter.ptr, cellRect(q.row, q.col, q.len, cell_w), hsla(q.color, 255));
    for (plan.selections) |q| try painter.vtable.paintQuad(painter.ptr, cellRect(q.row, q.col, q.len, cell_w), hsla(q.color, q.alpha));

    var runs: std.ArrayList(text.TextRun) = .empty;
    defer runs.deinit(gpa);
    for (plan.segments) |seg| {
        runs.clearRetainingCapacity();
        for (seg.runs) |r| {
            const color = hslaF(r.style.color, r.style.alpha);
            try runs.append(gpa, .{
                .len = r.len,
                .font = .{
                    .family = mono.family,
                    .weight = if (r.style.bold) text.weight.bold else text.weight.normal,
                    .style = if (r.style.italic) .italic else .normal,
                },
                .color = color,
                .underline = if (r.style.underline != .none) .{
                    .thickness = if (r.style.underline == .double) 2 else 1,
                    .color = if (r.style.underline_color) |uc| hsla(uc, 255) else color,
                    .wavy = r.style.underline == .curly,
                } else null,
                .strikethrough = if (r.style.strikethrough) .{ .thickness = 1, .color = color } else null,
            });
        }
        const line = try wts.shapeLine(seg.text, font_size, runs.items, null);
        defer line.deinit(gpa);
        const o = cellRect(seg.row, seg.col, 1, cell_w).origin;
        try line.paint(painter, .{ .x = o.x, .y = o.y }, line_height, .left, null);
    }

    if (plan.cursor) |cur| {
        const r = cellRect(cur.row, cur.col, cur.width, cell_w);
        const c = hsla(cur.color, 255);
        switch (cur.style) {
            .block => try painter.vtable.paintQuad(painter.ptr, r, c),
            .bar => try painter.vtable.paintQuad(painter.ptr, .{ .origin = r.origin, .size = .{ .width = 2, .height = r.size.height } }, c),
            .underline => try painter.vtable.paintQuad(painter.ptr, .{ .origin = .{ .x = r.origin.x, .y = r.origin.y + r.size.height - 2 }, .size = .{ .width = r.size.width, .height = 2 } }, c),
            .block_hollow => {
                const t: f32 = 1;
                try painter.vtable.paintQuad(painter.ptr, .{ .origin = r.origin, .size = .{ .width = r.size.width, .height = t } }, c);
                try painter.vtable.paintQuad(painter.ptr, .{ .origin = .{ .x = r.origin.x, .y = r.origin.y + r.size.height - t }, .size = .{ .width = r.size.width, .height = t } }, c);
                try painter.vtable.paintQuad(painter.ptr, .{ .origin = r.origin, .size = .{ .width = t, .height = r.size.height } }, c);
                try painter.vtable.paintQuad(painter.ptr, .{ .origin = .{ .x = r.origin.x + r.size.width - t, .y = r.origin.y }, .size = .{ .width = t, .height = r.size.height } }, c);
            },
        }
    }

    const encoded = try png.encode(gpa, canvas.width, canvas.height, canvas.pixels);
    defer gpa.free(encoded);
    std.Io.Dir.cwd().createDirPath(io, "zig-out") catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = encoded });
    std.debug.print("wrote {s} ({d}x{d}, {d}x{d} cells, cell {d:.2}x{d}px)\n", .{ output_path, canvas.width, canvas.height, snap.cols, snap.rows, cell_w, line_height });
}

fn to8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

fn hsla(c: term.snapshot.Rgb, alpha: u8) Hsla {
    var h = zpui.rgb((@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b).toHsla();
    h.a = @as(f32, @floatFromInt(alpha)) / 255;
    return h;
}

fn hslaF(c: term.snapshot.Rgb, alpha: f32) Hsla {
    var h = hsla(c, 255);
    h.a = alpha;
    return h;
}

const Canvas = struct {
    width: u32,
    height: u32,
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

/// `GlyphPainter` that rasterizes through the core `TextSystem` and blits on
/// the CPU (same approach as examples/text_dump.zig).
const CpuPainter = struct {
    canvas: *Canvas,
    ts: *text.TextSystem,
    gpa: std.mem.Allocator,
    scale: f32,

    fn painter(self: *CpuPainter) text.GlyphPainter {
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
            .subpixel_rendering = false,
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
            const cov = f(r.bytes[y * w + x]) * rgba.a;
            self.canvas.blend(ox + @as(i32, @intCast(x)), oy + @as(i32, @intCast(y)), .{ rgba.r, rgba.g, rgba.b }, @splat(cov));
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
            const p = r.bytes[(y * w + x) * 4 ..][0..4];
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
        if (style.wavy) {
            // Simple zigzag for curly underlines.
            var x = o.x * s;
            var k: usize = 0;
            while (x < (o.x + width) * s) : ({
                x += 1;
                k += 1;
            }) {
                const phase: f32 = @floatFromInt(k % 8);
                const dy = if (phase < 4) phase else 8 - phase;
                self.canvas.fill(x, y + dy - 2, x + 1, y + dy - 2 + t, style.color.?);
            }
            return;
        }
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
