//! `layout/pie.rs`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir.zig");
const util = @import("../util.zig");
const Theme = @import("../theme.zig").Theme;
const LayoutConfig = @import("../config.zig").LayoutConfig;
const text = @import("../text.zig");
const t = @import("types.zig");

pub fn outsideLabelBump(font_size: f32, radius: f32) f32 {
    return @max(font_size * 1.6, radius * 0.18);
}

pub fn outsideLabelPadX(font_size: f32) f32 {
    return @max(font_size * 0.35, 4.0);
}

pub fn labelIsOutside(arc_len: f32, percent_width: f32, span: f32) bool {
    return arc_len < percent_width * 1.35 or span < 0.4;
}

fn outsideLabelExtent(radius: f32, font_size: f32, label_width: f32) f32 {
    return radius + outsideLabelBump(font_size, radius) + label_width + outsideLabelPadX(font_size);
}

pub fn sanitize(v: f32) f32 {
    return if (std.math.isFinite(v)) @max(v, 0.0) else 0.0;
}

pub fn formatValue(a: Allocator, value: f32) Allocator.Error![]const u8 {
    const rounded = @round(value * 100.0) / 100.0;
    if (@abs(rounded - @round(rounded)) < 0.001) return util.fmtFixed(a, rounded, 0);
    return util.fmtFixed(a, rounded, 2);
}

/// `text_metrics::measure_text_width(..).unwrap_or(chars * size * 0.55)`;
/// system fonts are not consulted (see text.zig), so this is the fallback.
pub fn percentTextWidth(s: []const u8, size: f32) f32 {
    return @as(f32, @floatFromInt(util.charCount(s))) * size * 0.55;
}

pub fn computePieLayout(a: Allocator, graph: *const ir.Graph, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!t.Layout {
    const cfg = config.pie;
    var data: t.PieData = .{ .center = .{ 0, 0 }, .radius = 0, .title = null };
    const title_block: ?t.TextBlock = if (graph.pie_title) |tt| try text.measureLabelWithFontSize(a, tt, theme.pie_title_text_size, config, false, theme.font_family) else null;
    var total: f32 = 0;
    for (graph.pie_slices.items) |s| total += sanitize(s.value);
    const fallback_total: f32 = @floatFromInt(@max(graph.pie_slices.items.len, 1));
    if (!(total > 0.0)) total = fallback_total;
    const Datum = struct { index: usize, label: []const u8, value: f32 };
    var filtered: std.ArrayList(Datum) = .empty;
    for (graph.pie_slices.items, 0..) |s, idx| {
        const v = sanitize(s.value);
        const percent = if (total > 0.0) v / total * 100.0 else 0.0;
        if (percent >= cfg.min_percent) try filtered.append(a, .{ .index = idx, .label = s.label, .value = v });
    }
    std.mem.sort(Datum, filtered.items, {}, struct {
        fn lt(_: void, x: Datum, y: Datum) bool {
            if (x.value != y.value) return y.value < x.value;
            return x.index < y.index;
        }
    }.lt);
    var color_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    var color_index: usize = 0;
    const Resolve = struct {
        fn f(al: Allocator, m: *std.StringHashMapUnmanaged([]const u8), ci: *usize, palette: []const []const u8, label: []const u8) Allocator.Error![]const u8 {
            if (m.get(label)) |c| return c;
            const c = palette[ci.* % palette.len];
            ci.* += 1;
            try m.put(al, label, c);
            return c;
        }
    }.f;
    var angle: f32 = 0;
    for (filtered.items) |d| {
        const span = if (total > 0.0) d.value / total * std.math.pi * 2.0 else std.math.pi * 2.0 / fallback_total;
        const label = try text.measureLabelWithFontSize(a, d.label, theme.pie_section_text_size, config, false, theme.font_family);
        try data.slices.append(a, .{ .label = label, .value = d.value, .start_angle = angle, .end_angle = angle + span, .color = try Resolve(a, &color_map, &color_index, &theme.pie_colors, d.label) });
        angle += span;
    }
    var legend_width: f32 = 0;
    const Item = struct { label: t.TextBlock, color: []const u8 };
    var items: std.ArrayList(Item) = .empty;
    for (graph.pie_slices.items) |s| {
        const vt = try formatValue(a, sanitize(s.value));
        const lt = if (graph.pie_show_data) try std.fmt.allocPrint(a, "{s} [{s}]", .{ s.label, vt }) else s.label;
        const label = try text.measureLabelWithFontSize(a, lt, theme.pie_legend_text_size, config, false, theme.font_family);
        legend_width = @max(legend_width, label.width);
        try items.append(a, .{ .label = label, .color = try Resolve(a, &color_map, &color_index, &theme.pie_colors, s.label) });
    }
    const text_h = theme.pie_legend_text_size * 1.25;
    const item_h = @max(cfg.legend_rect_size + cfg.legend_spacing, text_h);
    const legend_offset = item_h * @as(f32, @floatFromInt(items.items.len)) / 2.0;
    const height = @max(cfg.height, 1.0);
    const pie_width = height;
    const radius = @max(@min(pie_width, height) / 2.0 - cfg.margin, 1.0);
    var cx = pie_width / 2.0;
    const cy = height / 2.0;
    const suppress = graph.pie_slices.items.len >= 4;
    var right_ext: f32 = 0;
    var left_ext: f32 = 0;
    if (!suppress) for (data.slices.items) |s| {
        const span = @abs(s.end_angle - s.start_angle);
        if (span <= 0.0001 or total <= 0.0) continue;
        const pt = try std.fmt.allocPrint(a, "{s}%", .{try util.fmtFixed(a, s.value / total * 100.0, 0)});
        const pw = percentTextWidth(pt, theme.pie_section_text_size);
        if (!labelIsOutside(radius * span, pw, span)) continue;
        const e = outsideLabelExtent(radius, theme.pie_section_text_size, s.label.width);
        const mid = (s.start_angle + s.end_angle) / 2.0;
        if (@cos(mid) >= 0.0) right_ext = @max(right_ext, e) else left_ext = @max(left_ext, e);
    };
    const thw: f32 = if (title_block) |tb| tb.width / 2.0 else 0.0;
    const left_needed = @max(left_ext + cfg.margin * 0.35, thw + cfg.margin * 0.25);
    cx += @max(left_needed - cx, 0.0);
    const legend_x = cx + @max(radius + cfg.margin * 0.6, right_ext + cfg.margin * 0.35);
    for (items.items, 0..) |it, idx| {
        try data.legend.append(a, .{ .x = legend_x, .y = cy + (@as(f32, @floatFromInt(idx)) * item_h - legend_offset), .label = it.label, .color = it.color, .marker_size = cfg.legend_rect_size, .value = sanitize(graph.pie_slices.items[idx].value) });
    }
    const width = @max(legend_x + cfg.legend_rect_size + cfg.legend_spacing + legend_width + cfg.margin * 0.4, cx + thw + cfg.margin * 0.25);
    if (title_block) |tb| data.title = .{ .x = cx, .y = cy - (height - 50.0) / 2.0, .text = tb };
    data.center = .{ cx, cy };
    data.radius = radius;
    return .{ .kind = graph.kind, .width = @max(width, 200.0), .height = @max(height, 1.0), .diagram = .{ .pie = data } };
}
