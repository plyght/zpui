//! Themes (mermaid-rs-renderer `theme.rs`): the `modern` and `dark` presets
//! zeron starts from, and the color helpers (`adjust_color`,
//! `parse_color_to_hsl`) the layout uses.

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util.zig");

pub const Theme = struct {
    font_family: []const u8,
    font_size: f32,
    primary_color: []const u8,
    primary_text_color: []const u8,
    primary_border_color: []const u8,
    line_color: []const u8,
    secondary_color: []const u8,
    tertiary_color: []const u8,
    edge_label_background: []const u8,
    cluster_background: []const u8,
    cluster_border: []const u8,
    background: []const u8,
    sequence_actor_fill: []const u8,
    sequence_actor_border: []const u8,
    sequence_actor_line: []const u8,
    sequence_note_fill: []const u8,
    sequence_note_border: []const u8,
    sequence_activation_fill: []const u8,
    sequence_activation_border: []const u8,
    text_color: []const u8,
    pie_colors: [12][]const u8,
    pie_title_text_size: f32,
    pie_title_text_color: []const u8,
    pie_section_text_size: f32,
    pie_section_text_color: []const u8,
    pie_legend_text_size: f32,
    pie_legend_text_color: []const u8,
    pie_stroke_color: []const u8,
    pie_stroke_width: f32,
    pie_outer_stroke_width: f32,
    pie_outer_stroke_color: []const u8,
    pie_opacity: f32,

    pub fn modern(a: Allocator) Allocator.Error!Theme {
        const primary = "#F8FAFC";
        const secondary = "#E2E8F0";
        const tertiary = "#FFFFFF";
        return .{
            .font_family = "Inter, ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", \"DejaVu Sans\", \"Liberation Sans\", sans-serif, \"Noto Color Emoji\", \"Apple Color Emoji\", \"Segoe UI Emoji\"",
            .font_size = 14.0,
            .primary_color = primary,
            .primary_text_color = "#0F172A",
            .primary_border_color = "#94A3B8",
            .line_color = "#64748B",
            .secondary_color = secondary,
            .tertiary_color = tertiary,
            .edge_label_background = "#FFFFFF",
            .cluster_background = "#F1F5F9",
            .cluster_border = "#CBD5E1",
            .background = "#FFFFFF",
            .sequence_actor_fill = "#F8FAFC",
            .sequence_actor_border = "#94A3B8",
            .sequence_actor_line = "#64748B",
            .sequence_note_fill = "#FFF7ED",
            .sequence_note_border = "#FDBA74",
            .sequence_activation_fill = "#E2E8F0",
            .sequence_activation_border = "#94A3B8",
            .text_color = "#0F172A",
            .pie_colors = try defaultPieColors(a, primary, secondary, tertiary),
            .pie_title_text_size = 25.0,
            .pie_title_text_color = "#0F172A",
            .pie_section_text_size = 17.0,
            .pie_section_text_color = "#0F172A",
            .pie_legend_text_size = 17.0,
            .pie_legend_text_color = "#0F172A",
            .pie_stroke_color = "#334155",
            .pie_stroke_width = 1.6,
            .pie_outer_stroke_width = 1.6,
            .pie_outer_stroke_color = "#CBD5E1",
            .pie_opacity = 0.85,
        };
    }

    /// Mermaid `dark` (theme-dark.js with precomputed derived values).
    pub fn dark() Theme {
        const secondary = "#474949";
        return .{
            .font_family = "'trebuchet ms', verdana, arial, \"DejaVu Sans\", \"Liberation Sans\", sans-serif, \"Noto Color Emoji\", \"Apple Color Emoji\", \"Segoe UI Emoji\"",
            .font_size = 16.0,
            .primary_color = "#1f2020",
            .primary_text_color = "#e0dfdf",
            .primary_border_color = "#cccccc",
            .line_color = "lightgrey",
            .secondary_color = secondary,
            .tertiary_color = "#201f1f",
            .edge_label_background = "#585858",
            .cluster_background = "#302f3d",
            .cluster_border = "rgba(255, 255, 255, 0.25)",
            .background = "#333333",
            .sequence_actor_fill = "#1f2020",
            .sequence_actor_border = "#cccccc",
            .sequence_actor_line = "#cccccc",
            .sequence_note_fill = secondary,
            .sequence_note_border = "#626262",
            .sequence_activation_fill = secondary,
            .sequence_activation_border = "#cccccc",
            .text_color = "#ccc",
            .pie_colors = .{ "#0b0000", "#4d1037", "#3f5258", "#4f2f1b", "#6e0a0a", "#3b0048", "#995a01", "#154706", "#161722", "#00296f", "#01629c", "#010029" },
            .pie_title_text_size = 25.0,
            .pie_title_text_color = "lightgrey",
            .pie_section_text_size = 17.0,
            .pie_section_text_color = "#ccc",
            .pie_legend_text_size = 17.0,
            .pie_legend_text_color = "lightgrey",
            .pie_stroke_color = "#000000",
            .pie_stroke_width = 2.0,
            .pie_outer_stroke_width = 2.0,
            .pie_outer_stroke_color = "#000000",
            .pie_opacity = 0.7,
        };
    }
};

fn defaultPieColors(a: Allocator, primary: []const u8, secondary: []const u8, tertiary: []const u8) Allocator.Error![12][]const u8 {
    return .{
        primary,
        secondary,
        try adjustColor(a, tertiary, 0, 0, -40),
        try adjustColor(a, primary, 0, 0, -10),
        try adjustColor(a, secondary, 0, 0, -30),
        try adjustColor(a, tertiary, 0, 0, -20),
        try adjustColor(a, primary, 60, 0, -20),
        try adjustColor(a, primary, -60, 0, -40),
        try adjustColor(a, primary, 120, 0, -40),
        try adjustColor(a, primary, 60, 0, -40),
        try adjustColor(a, primary, -90, 0, -40),
        try adjustColor(a, primary, 120, 0, -30),
    };
}

/// `adjust_color`: shift HSL and print `hsl(h, s%, l%)` with 10 decimals.
pub fn adjustColor(a: Allocator, color: []const u8, dh: f32, ds: f32, dl: f32) Allocator.Error![]const u8 {
    const hsl = parseColorToHsl(color) orelse return color;
    var h = hsl[0] + dh;
    if (h < 0.0) {
        h = @rem(h, 360.0) + 360.0;
    } else if (h >= 360.0) {
        h = @rem(h, 360.0);
    }
    const s = std.math.clamp(hsl[1] + ds, 0.0, 100.0);
    const l = std.math.clamp(hsl[2] + dl, 0.0, 100.0);
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    return std.fmt.allocPrint(a, "hsl({s}, {s}%, {s}%)", .{ util.writeFixed(&b1, h, 10), util.writeFixed(&b2, s, 10), util.writeFixed(&b3, l, 10) });
}

pub fn parseColorToHsl(color_in: []const u8) ?[3]f32 {
    const color = util.trim(color_in);
    if (parseHsl(color)) |v| return v;
    const rgb = parseHex(color) orelse return null;
    return rgbToHsl(rgb[0], rgb[1], rgb[2]);
}

fn parseHsl(value_in: []const u8) ?[3]f32 {
    const value = util.trim(value_in);
    const open = std.mem.indexOfScalar(u8, value, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, value, ')') orelse return null;
    if (close < open + 1) return null;
    const prefix = util.trim(value[0..open]);
    if (!std.ascii.eqlIgnoreCase(prefix, "hsl") and !std.ascii.eqlIgnoreCase(prefix, "hsla")) return null;
    const inner = value[open + 1 .. close];
    var parts: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |p| {
        if (n == parts.len) break;
        parts[n] = p;
        n += 1;
    }
    if (n < 3) return null;
    const h = util.parseF32(util.trim(parts[0])) orelse return null;
    const s = util.parseF32(std.mem.trimEnd(u8, util.trim(parts[1]), "%")) orelse return null;
    const l = util.parseF32(std.mem.trimEnd(u8, util.trim(parts[2]), "%")) orelse return null;
    return .{ h, s, l };
}

pub fn parseHex(value: []const u8) ?[3]f32 {
    if (value.len == 0 or value[0] != '#') return null;
    const hex = value[1..];
    if (!util.isAscii(hex)) return null;
    var digits: [6]u8 = undefined;
    switch (hex.len) {
        3 => for (hex, 0..) |c, i| {
            digits[i * 2] = c;
            digits[i * 2 + 1] = c;
        },
        6, 8 => @memcpy(&digits, hex[0..6]),
        else => return null,
    }
    const r = std.fmt.parseInt(u8, digits[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, digits[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, digits[4..6], 16) catch return null;
    return .{ @as(f32, @floatFromInt(r)) / 255.0, @as(f32, @floatFromInt(g)) / 255.0, @as(f32, @floatFromInt(b)) / 255.0 };
}

fn rgbToHsl(r: f32, g: f32, b: f32) [3]f32 {
    const max = @max(r, @max(g, b));
    const min = @min(r, @min(g, b));
    var h: f32 = 0.0;
    const l = (max + min) / 2.0;
    const d = max - min;
    const s: f32 = if (d == 0.0) 0.0 else d / (1.0 - @abs(2.0 * l - 1.0));
    if (d != 0.0) {
        if (max == r) {
            h = @rem((g - b) / d, 6.0);
        } else if (max == g) {
            h = (b - r) / d + 2.0;
        } else {
            h = (r - g) / d + 4.0;
        }
        h *= 60.0;
        if (h < 0.0) h += 360.0;
    }
    return .{ h, s * 100.0, l * 100.0 };
}

test "modern pie colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try Theme.modern(arena.allocator());
    try std.testing.expectEqualStrings("#F8FAFC", t.pie_colors[0]);
    try std.testing.expect(std.mem.startsWith(u8, t.pie_colors[2], "hsl("));
}
