//! zeron's Mermaid adapter (crates/ui/src/markdown/mermaid.rs): the engine
//! options, the palette-driven theme, complexity limits and the restyle pass
//! applied to the engine's SVG.

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util.zig");
const parser = @import("parser.zig");
const validator = @import("validator.zig");
const theme_mod = @import("theme.zig");
const LayoutConfig = @import("config.zig").LayoutConfig;
const layout_mod = @import("layout/layout.zig");
const render_mod = @import("render.zig");

pub const ENGINE_VERSION = "mermaid-rs-renderer/0.3.1";
pub const MAX_SOURCE_BYTES: usize = 16 * 1024;

/// Zeron's diagram style (hex strings, already composited like Rust's
/// `Palette::from_theme`).
pub const Palette = struct {
    dark: bool,
    font: []const u8 = "Geist",
    canvas: []const u8,
    node: []const u8,
    group: []const u8,
    text: []const u8,
    label: []const u8,
    line: []const u8,
    border: []const u8,
    grid: []const u8,
    accent_line: []const u8,
    accent_wash: []const u8,

    pub const light_palette: Palette = .{
        .dark = false,
        .canvas = "#f6f6f6",
        .node = "#ffffff",
        .group = "#efefef",
        .text = "#222222",
        .label = "#525252",
        .line = "#6d6d6d",
        .border = "#cccccc",
        .grid = "#dddddd",
        .accent_line = "#9285f6",
        .accent_wash = "#eae7fe",
    };
    pub const dark_palette: Palette = .{
        .dark = true,
        .canvas = "#0f0f0f",
        .node = "#1d1d1d",
        .group = "#161616",
        .text = "#e5e5e5",
        .label = "#a1a1a1",
        .line = "#737373",
        .border = "#303030",
        .grid = "#222222",
        .accent_line = "#51569f",
        .accent_wash = "#292a38",
    };

    pub fn forDark(is_dark: bool) Palette {
        return if (is_dark) dark_palette else light_palette;
    }

    /// The fence body color (`Palette::plate`) as 0xRRGGBB.
    pub fn plateRgb(self: Palette) u32 {
        return std.fmt.parseInt(u32, self.canvas[1..], 16) catch 0;
    }
};

pub fn layoutOptions() LayoutConfig {
    return .{ .node_spacing = 36.0, .rank_spacing = 40.0, .node_padding_x = 18.0, .node_padding_y = 10.0 };
}

pub const Result = union(enum) {
    svg: []const u8,
    err: []const u8,
};

/// Render `source` to restyled SVG; all memory comes from `a` (an arena).
pub fn render(a: Allocator, source: []const u8, palette: Palette) Allocator.Error!Result {
    if (source.len > MAX_SOURCE_BYTES or lineCount(source) > 256 or tokenCount(source) > 2048)
        return .{ .err = "Diagram exceeds preview complexity limit" };
    var theme = if (palette.dark) theme_mod.Theme.dark() else try theme_mod.Theme.modern(a);
    theme.font_family = palette.font;
    theme.font_size = 14.0;
    theme.background = palette.canvas;
    theme.primary_color = palette.node;
    theme.primary_text_color = palette.text;
    theme.primary_border_color = palette.border;
    theme.text_color = palette.label;
    theme.line_color = palette.line;
    theme.secondary_color = palette.node;
    theme.tertiary_color = palette.group;
    theme.edge_label_background = palette.canvas;
    theme.cluster_background = palette.group;
    theme.cluster_border = palette.border;
    theme.sequence_actor_fill = palette.node;
    theme.sequence_actor_border = palette.border;
    theme.sequence_actor_line = palette.border;
    theme.sequence_note_fill = palette.accent_wash;
    theme.sequence_note_border = palette.accent_line;
    theme.sequence_activation_fill = palette.accent_wash;
    theme.sequence_activation_border = palette.accent_line;
    if (diagramKeyword(source)) |kw| {
        if (std.mem.eql(u8, kw, "gantt")) theme.primary_border_color = palette.accent_line;
    }
    const config = layoutOptions();

    if (try validator.validate(a, source)) |msg| return .{ .err = msg };
    var p = parser.Parser.init(a) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .err = "Diagram could not be rendered" },
    };
    const graph = p.parse(source) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var found: []const u8 = "<empty>";
            var it = util.lines(source);
            while (it.next()) |l| if (util.trim(l).len > 0) {
                found = util.trim(l);
                break;
            };
            const msg = if (p.message.len > 0) p.message else @errorName(e);
            return .{ .err = try std.fmt.allocPrint(a, "unexpected token '{s}' at 1:1; expected {s}", .{ found, msg }) };
        },
    };
    const lay = try layout_mod.computeLayout(a, &graph, &theme, &config);
    const raw = try render_mod.renderSvg(a, &lay, &theme, &config);
    const svg = try restyle(a, raw, palette);
    if (svg.len > 2 * 1024 * 1024) return .{ .err = "Diagram output exceeds preview size limit" };
    return .{ .svg = svg };
}

fn lineCount(s: []const u8) usize {
    var n: usize = 0;
    var it = util.lines(s);
    while (it.next()) |_| n += 1;
    return n;
}

/// `split(|c| c.is_whitespace() || ";>{}".contains(c)).count()`.
fn tokenCount(s: []const u8) usize {
    var n: usize = 1;
    var i: usize = 0;
    while (i < s.len) {
        const d = util.decodeAt(s, i);
        if (util.isWhitespace(d.cp) or d.cp == ';' or d.cp == '>' or d.cp == '{' or d.cp == '}') n += 1;
        i += d.len;
    }
    return n;
}

/// The diagram type: the first word after any front matter and comments.
pub fn diagramKeyword(source: []const u8) ?[]const u8 {
    var it = util.lines(source);
    var first = true;
    var in_fm = false;
    while (it.next()) |raw| {
        const line = util.trim(raw);
        if (line.len == 0) continue;
        if (first) {
            first = false;
            if (std.mem.eql(u8, line, "---")) {
                in_fm = true;
                continue;
            }
        }
        if (in_fm) {
            if (std.mem.eql(u8, line, "---")) in_fm = false;
            continue;
        }
        if (util.startsWith(line, "%%")) continue;
        var ws = util.splitWhitespace(line);
        return ws.next();
    }
    return null;
}

const Attr = struct { name: []const u8, value: []const u8 };

/// `name="value"` pairs of a start tag, as the engine writes them.
fn attributes(buf: []Attr, tag: []const u8) []Attr {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, tag, '"');
    while (true) {
        const name_part = it.next() orelse break;
        const value = it.next() orelse break;
        const trimmed = util.trimEnd(name_part);
        if (!util.endsWith(trimmed, "=")) continue;
        const nm = trimmed[0 .. trimmed.len - 1];
        const sp = std.mem.lastIndexOfScalar(u8, nm, ' ');
        const name = if (sp) |i| nm[i + 1 ..] else nm;
        if (n < buf.len) {
            buf[n] = .{ .name = name, .value = value };
            n += 1;
        }
    }
    return buf[0..n];
}

fn attr(attrs: []const Attr, name: []const u8) ?[]const u8 {
    for (attrs) |x| if (std.mem.eql(u8, x.name, name)) return x.value;
    return null;
}

fn isCanvas(tag: []const u8, palette: Palette) bool {
    if (!util.startsWith(tag, "<rect ")) return false;
    var buf: [64]Attr = undefined;
    var fill: ?[]const u8 = null;
    for (attributes(&buf, tag)) |x| {
        if (std.mem.eql(u8, x.name, "fill")) {
            fill = x.value;
        } else if (!(std.mem.eql(u8, x.name, "x") or std.mem.eql(u8, x.name, "y") or std.mem.eql(u8, x.name, "width") or std.mem.eql(u8, x.name, "height"))) return false;
    }
    return fill != null and std.mem.eql(u8, fill.?, palette.canvas);
}

fn isDefaultDiamond(tag: []const u8, palette: Palette) bool {
    var buf: [64]Attr = undefined;
    const attrs = attributes(&buf, tag);
    const fill = attr(attrs, "fill") orelse return false;
    const stroke = attr(attrs, "stroke") orelse return false;
    if (!std.mem.eql(u8, fill, palette.node) or !std.mem.eql(u8, stroke, palette.border)) return false;
    const points = attr(attrs, "points") orelse return false;
    var pts: [4][2]f32 = undefined;
    var n: usize = 0;
    var it = util.splitWhitespace(points);
    while (it.next()) |p| {
        const comma = std.mem.indexOfScalar(u8, p, ',') orelse continue;
        const x = std.fmt.parseFloat(f32, p[0..comma]) catch continue;
        const y = std.fmt.parseFloat(f32, p[comma + 1 ..]) catch continue;
        if (n == 4) return false;
        pts[n] = .{ x, y };
        n += 1;
    }
    if (n != 4) return false;
    const top = pts[0];
    const right = pts[1];
    const bottom = pts[2];
    const left = pts[3];
    return @abs(top[0] - bottom[0]) < 0.05 and @abs(left[1] - right[1]) < 0.05 and left[0] < top[0] and top[0] < right[0] and top[1] < left[1] and left[1] < bottom[1];
}

fn replaceOnce(a: Allocator, s: []const u8, from: []const u8, to: []const u8) Allocator.Error![]const u8 {
    return util.replaceOnce(a, s, from, to);
}

pub fn restyle(a: Allocator, svg: []const u8, palette: Palette) Allocator.Error![]const u8 {
    const canvas_fill = try std.fmt.allocPrint(a, " fill=\"{s}\"", .{palette.canvas});
    const node_fill = try std.fmt.allocPrint(a, " fill=\"{s}\"", .{palette.node});
    const border_stroke = try std.fmt.allocPrint(a, " stroke=\"{s}\"", .{palette.border});
    const wash_fill = try std.fmt.allocPrint(a, " fill=\"{s}\"", .{palette.accent_wash});
    const accent_stroke = try std.fmt.allocPrint(a, " stroke=\"{s}\"", .{palette.accent_line});
    const grid_stroke = try std.fmt.allocPrint(a, " stroke=\"{s}\"", .{palette.grid});
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, svg.len);
    var rest = svg;
    while (std.mem.indexOfScalar(u8, rest, '<')) |start| {
        try out.appendSlice(a, rest[0..start]);
        rest = rest[start..];
        const end = std.mem.indexOfScalar(u8, rest, '>') orelse break;
        const tag = rest[0 .. end + 1];
        rest = rest[end + 1 ..];
        if (isCanvas(tag, palette)) continue;
        if (util.startsWith(tag, "<polygon ") and isDefaultDiamond(tag, palette)) {
            try out.appendSlice(a, try replaceOnce(a, try replaceOnce(a, tag, node_fill, wash_fill), border_stroke, accent_stroke));
        } else if (util.startsWith(tag, "<rect ")) {
            var tg = try replaceOnce(a, tag, " rx=\"3\" ry=\"3\" ", " rx=\"8\" ry=\"8\" ");
            if (util.contains(tg, border_stroke)) tg = try replaceOnce(a, tg, canvas_fill, node_fill);
            try out.appendSlice(a, tg);
        } else if (util.startsWith(tag, "<line ")) {
            try out.appendSlice(a, try replaceOnce(a, tag, " stroke=\"#E2E8F0\"", grid_stroke));
        } else {
            try out.appendSlice(a, tag);
        }
    }
    try out.appendSlice(a, rest);
    return out.items;
}

test "diagram keyword" {
    try std.testing.expectEqualStrings("gantt", diagramKeyword("gantt\n  title X").?);
    try std.testing.expectEqualStrings("gantt", diagramKeyword("---\ntitle: Plan\n---\n%% note\n\n gantt").?);
    try std.testing.expectEqualStrings("flowchart", diagramKeyword("flowchart LR; A-->B").?);
    try std.testing.expect(diagramKeyword("  \n%% only") == null);
}

test "zeron style keeps explicit colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Palette{ Palette.light_palette, Palette.dark_palette }) |pal| {
        const r = try render(a, "flowchart TD\nA[Inicio] --> B{¿Listo?}\nB --> C[Fin]\nB --> D{Otra}\nstyle D fill:#dbeafe,stroke:#2563eb", pal);
        const svg = r.svg;
        try std.testing.expect(!util.contains(svg, try std.fmt.allocPrint(a, "fill=\"{s}\"/>", .{pal.canvas})));
        try std.testing.expect(util.contains(svg, " rx=\"8\" ry=\"8\" "));
        try std.testing.expect(!util.contains(svg, " rx=\"3\" ry=\"3\" "));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, svg, try std.fmt.allocPrint(a, "fill=\"{s}\" stroke=\"{s}\"", .{ pal.accent_wash, pal.accent_line })));
        try std.testing.expect(util.contains(svg, "fill=\"#dbeafe\" stroke=\"#2563eb\""));
        const gantt = try render(a, "%% plan\ngantt\ndateFormat YYYY-MM-DD\nsection A\nTask :2026-09-08, 2d", pal);
        try std.testing.expect(!util.contains(gantt.svg, "#E2E8F0"));
    }
    try std.testing.expect((try render(a, "this is not a diagram", Palette.dark_palette)) == .err);
}
