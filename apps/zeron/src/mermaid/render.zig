//! SVG emission (mermaid-rs-renderer `render.rs`), for the diagram kinds zeron
//! renders: flowchart/graph, class, state, ER, sequence, pie and gantt. Output
//! is byte-identical to the crate's `render_svg` for the same layout.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const util = @import("util.zig");
const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;
const LayoutConfig = @import("config.zig").LayoutConfig;
const TextBlock = @import("text.zig").TextBlock;
const t = @import("layout/types.zig");
const routing = @import("layout/routing.zig");
const label_placement = @import("layout/label_placement.zig");
const pie_layout = @import("layout/pie.zig");
const svg_fmt = @import("svg_fmt.zig");

const Out = svg_fmt.Out;
const Point = t.Point;
const E = Allocator.Error;
const Kind = ir.DiagramKind;

const SEQ_PAD_LEFT: f32 = 50.0;
const SEQ_PAD_RIGHT: f32 = 50.0;
const SEQ_PAD_TOP: f32 = 10.0;
const SEQ_PAD_BOTTOM: f32 = 11.0;

const JOIN = " stroke-linejoin=\"round\" stroke-linecap=\"round\"";

pub const SvgDimensions = struct {
    width: f32,
    height: f32,
    viewbox_x: f32,
    viewbox_y: f32,
    viewbox_width: f32,
    viewbox_height: f32,
};

pub fn measureSvgDimensions(layout: *const t.Layout) SvgDimensions {
    if (layout.diagram == .sequence) {
        const w = @max(layout.width + SEQ_PAD_LEFT + SEQ_PAD_RIGHT, 1.0);
        const h = @max(layout.height + SEQ_PAD_TOP + SEQ_PAD_BOTTOM, 1.0);
        return .{ .width = w, .height = h, .viewbox_x = -SEQ_PAD_LEFT, .viewbox_y = -SEQ_PAD_TOP, .viewbox_width = w, .viewbox_height = h };
    }
    const w = @max(layout.width, 1.0);
    const h = @max(layout.height, 1.0);
    return .{ .width = w, .height = h, .viewbox_x = 0, .viewbox_y = 0, .viewbox_width = w, .viewbox_height = h };
}

const Ctx = struct {
    a: Allocator,
    o: *Out,
    theme: *const Theme,
    config: *const LayoutConfig,
};

fn eql(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

pub fn renderSvg(a: Allocator, layout: *const t.Layout, theme: *const Theme, config: *const LayoutConfig) E![]const u8 {
    var out = Out.init(a);
    const o = &out;
    const c: Ctx = .{ .a = a, .o = o, .theme = theme, .config = config };
    const state_font_size = if (layout.kind == .state) theme.font_size * 0.85 else theme.font_size;
    const dims = measureSvgDimensions(layout);
    const seq_data: ?*const t.SequenceData = if (layout.diagram == .sequence) &layout.diagram.sequence else null;
    const is_sequence = seq_data != null;
    const is_state = layout.kind == .state;
    const is_class = layout.kind == .class;
    var has_links = false;
    for (layout.nodes.values()) |n| has_links = has_links or n.link != null;
    if (seq_data) |s| for (s.footboxes.items) |n| {
        has_links = has_links or n.link != null;
    };

    var wbuf: [64]u8 = undefined;
    var width_attr: []const u8 = util.writeF32(&wbuf, dims.width);
    var hbuf: [64]u8 = undefined;
    var height_attr: []const u8 = util.writeF32(&hbuf, dims.height);
    var style_attr: []const u8 = "";
    if (layout.kind == .pie and config.pie.use_max_width) {
        width_attr = "100%";
        height_attr = "";
        style_attr = try svg_fmt.print(a, " style=\"max-width: {:.3}px;\"", .{dims.viewbox_width});
    }
    try o.put("<svg xmlns=\"http://www.w3.org/2000/svg\"{} width=\"{}\"", .{ if (has_links) " xmlns:xlink=\"http://www.w3.org/1999/xlink\"" else "", width_attr });
    if (height_attr.len > 0) try o.put(" height=\"{}\"", .{height_attr});
    try o.put(" viewBox=\"{} {} {} {}\"{}>", .{ dims.viewbox_x, dims.viewbox_y, dims.viewbox_width, dims.viewbox_height, style_attr });
    try o.put("<rect x=\"{}\" y=\"{}\" width=\"{}\" height=\"{}\" fill=\"{}\"/>", .{ dims.viewbox_x, dims.viewbox_y, dims.viewbox_width, dims.viewbox_height, theme.background });

    var colors: std.ArrayList([]const u8) = .empty;
    try colors.append(a, theme.line_color);
    for (layout.edges.items) |*edge| {
        if (edge.override_style.stroke) |col| {
            var found = false;
            for (colors.items) |x| found = found or eql(x, col);
            if (!found) try colors.append(a, col);
        }
    }
    try o.str("<defs>");
    for (colors.items, 0..) |col, idx| {
        try o.put("<marker id=\"arrow-{}\" viewBox=\"0 0 10 10\" refX=\"5\" refY=\"5\" markerUnits=\"userSpaceOnUse\" markerWidth=\"8\" markerHeight=\"8\" orient=\"auto\"><path d=\"M 0 0 L 10 5 L 0 10 z\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1\" stroke-dasharray=\"1,0\"/></marker>", .{ idx, col, col });
        try o.put("<marker id=\"arrow-start-{}\" viewBox=\"0 0 10 10\" refX=\"4.5\" refY=\"5\" markerUnits=\"userSpaceOnUse\" markerWidth=\"8\" markerHeight=\"8\" orient=\"auto\"><path d=\"M 0 5 L 10 10 L 10 0 z\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1\" stroke-dasharray=\"1,0\"/></marker>", .{ idx, col, col });
        if (is_sequence) {
            try o.put("<marker id=\"arrow-seq-{}\" viewBox=\"-1 0 12 10\" refX=\"7.9\" refY=\"5\" markerUnits=\"userSpaceOnUse\" markerWidth=\"12\" markerHeight=\"12\" orient=\"auto-start-reverse\"><path d=\"M -1 0 L 10 5 L 0 10 z\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1\" stroke-dasharray=\"1,0\"/></marker>", .{ idx, col, col });
            try o.put("<marker id=\"arrow-start-seq-{}\" viewBox=\"-1 0 12 10\" refX=\"2.1\" refY=\"5\" markerUnits=\"userSpaceOnUse\" markerWidth=\"12\" markerHeight=\"12\" orient=\"auto\"><path d=\"M 11 0 L 0 5 L 11 10 z\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1\" stroke-dasharray=\"1,0\"/></marker>", .{ idx, col, col });
        }
        if (is_state) {
            try o.put("<marker id=\"arrow-state-{}\" viewBox=\"0 0 20 14\" refX=\"19\" refY=\"7\" markerUnits=\"userSpaceOnUse\" markerWidth=\"20\" markerHeight=\"14\" orient=\"auto\"><path d=\"M 19 7 L 9 13 L 14 7 L 9 1 Z\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1\" stroke-dasharray=\"1,0\"/></marker>", .{ idx, col, col });
        }
        if (is_class) {
            try o.put("<marker id=\"arrow-class-open-{}\" viewBox=\"0 0 20 14\" refX=\"1\" refY=\"7\" markerUnits=\"userSpaceOnUse\" markerWidth=\"20\" markerHeight=\"14\" orient=\"auto\"><path d=\"M 1 7 L 18 13 V 1 Z\" fill=\"none\" stroke=\"{}\" stroke-width=\"1\" stroke-dasharray=\"1,0\"/></marker>", .{ idx, col });
            try o.put("<marker id=\"arrow-class-open-start-{}\" viewBox=\"0 0 20 14\" refX=\"18\" refY=\"7\" markerUnits=\"userSpaceOnUse\" markerWidth=\"20\" markerHeight=\"14\" orient=\"auto\"><path d=\"M 1 7 L 18 13 V 1 Z\" fill=\"none\" stroke=\"{}\" stroke-width=\"1\" stroke-dasharray=\"1,0\"/></marker>", .{ idx, col });
            try o.put("<marker id=\"arrow-class-dep-{}\" viewBox=\"0 0 20 14\" refX=\"13\" refY=\"7\" markerUnits=\"userSpaceOnUse\" markerWidth=\"20\" markerHeight=\"14\" orient=\"auto\"><path d=\"M 18 7 L 9 13 L 14 7 L 9 1 Z\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1\" stroke-dasharray=\"1,0\"/></marker>", .{ idx, col, col });
            try o.put("<marker id=\"arrow-class-dep-start-{}\" viewBox=\"0 0 20 14\" refX=\"6\" refY=\"7\" markerUnits=\"userSpaceOnUse\" markerWidth=\"20\" markerHeight=\"14\" orient=\"auto\"><path d=\"M 5 7 L 9 13 L 1 7 L 9 1 Z\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1\" stroke-dasharray=\"1,0\"/></marker>", .{ idx, col, col });
        }
    }
    try o.str("</defs>");

    switch (layout.diagram) {
        .pie => |*pie| {
            try renderPie(c, pie);
            try o.str("</svg>");
            return o.items();
        },
        .gantt => |*g| {
            try renderGantt(c, g);
            try o.str("</svg>");
            return o.items();
        },
        else => {},
    }

    // Subgraphs.
    for (layout.subgraphs.items) |*sg| {
        const label_empty = util.trim(sg.label).len == 0;
        if (is_state) {
            const sub_fill = sg.style.fill orelse theme.primary_color;
            const sub_stroke = sg.style.stroke orelse theme.primary_border_color;
            const sub_sw = sg.style.stroke_width orelse 1.0;
            if (label_empty and eql(sub_fill, "none") and eql(sub_stroke, "none") and sub_sw <= 0.0) continue;
            const header_h: f32 = if (label_empty) 0.0 else @max(sg.label_block.height + theme.font_size * 0.75, theme.font_size * 1.4);
            const header_fill = if (eql(sub_fill, "none")) "none" else try theme_mod.adjustColor(a, sub_fill, 0, 0, -4);
            const body_fill = if (eql(sub_fill, "none")) theme.background else try theme_mod.adjustColor(a, sub_fill, 0, -12, 10);
            if (header_h > 0.0) {
                try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"6\" ry=\"6\" fill=\"{}\" stroke=\"none\"/>", .{ sg.x, sg.y, sg.width, header_h, header_fill });
            }
            const inner_y = sg.y + header_h;
            const inner_h = @max(sg.height - header_h, 0.0);
            if (inner_h > 0.0) {
                try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" fill=\"{}\" stroke=\"none\"/>", .{ sg.x, inner_y, sg.width, inner_h, body_fill });
            }
            if (header_h > 0.0) {
                try o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"{}\" stroke-width=\"1\"/>", .{ sg.x, inner_y, sg.x + sg.width, inner_y, sub_stroke });
            }
            try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"6\" ry=\"6\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\"/>", .{ sg.x, sg.y, sg.width, sg.height, sub_stroke, sub_sw });
            if (!label_empty) {
                const pad_x = @max(theme.font_size * 0.6, sg.label_block.height * 0.35);
                try textBlockWeight(c, sg.x + pad_x, sg.y + header_h / 2.0, &sg.label_block, state_font_size, "start", sg.style.text_color, "600", false);
            }
        } else {
            const sub_fill = sg.style.fill orelse theme.cluster_background;
            const sub_stroke = sg.style.stroke orelse theme.cluster_border;
            const sub_dash = if (sg.style.stroke_dasharray) |v| try svg_fmt.print(a, " stroke-dasharray=\"{}\"", .{v}) else "";
            const sub_sw = sg.style.stroke_width orelse 1.0;
            const invisible = label_empty and eql(sub_fill, "none") and eql(sub_stroke, "none") and sub_sw <= 0.0;
            if (!invisible) {
                try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"10\" ry=\"10\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{} />", .{ sg.x, sg.y, sg.width, sg.height, sub_fill, sub_stroke, sub_sw, sub_dash });
            }
            if (!label_empty) {
                const color = sg.style.text_color orelse theme.primary_text_color;
                try textBlock(c, sg.x + sg.width / 2.0, sg.y + 12.0 + sg.label_block.height / 2.0, &sg.label_block, color);
            }
        }
    }

    const overlay_flowchart = layout.kind == .flowchart;
    if (seq_data) |seq| {
        for (seq.boxes.items) |*bx| {
            const stroke = theme.primary_border_color;
            const fill = bx.color orelse "none";
            const opacity = if (bx.color != null and !eql(fill, "none")) " fill-opacity=\"0.12\"" else "";
            try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" fill=\"{}\"{} stroke=\"{}\" stroke-width=\"1.2\"/>", .{ bx.x, bx.y, bx.width, bx.height, fill, opacity, stroke });
            if (bx.label) |*label| {
                const pad_x = theme.font_size * 0.8;
                const pad_y = theme.font_size * 0.9;
                try textBlockFull(c, bx.x + pad_x, bx.y + pad_y + label.height / 2.0, label, theme.font_size, "start", theme.primary_text_color, false);
            }
        }
        for (seq.frames.items) |*frame| {
            const stroke = theme.primary_border_color;
            try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" fill=\"none\" stroke=\"{}\" stroke-width=\"2.0\" stroke-dasharray=\"2 2\"/>", .{ frame.x, frame.y, frame.width, frame.height, stroke });
            for (frame.dividers) |dy| {
                try o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"{}\" stroke-width=\"2.0\" stroke-dasharray=\"3 3\"/>", .{ frame.x, dy, frame.x + frame.width, dy, stroke });
            }
            const box_x, const box_y, const box_w, const box_h = frame.label_box;
            const notch_x = box_x + box_w * 0.8;
            const notch_y = box_y + box_h;
            const mid_y = box_y + box_h * 0.65;
            const end_x = box_x + box_w;
            try o.put("<polygon points=\"{:.2},{:.2} {:.2},{:.2} {:.2},{:.2} {:.2},{:.2} {:.2},{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1.1\"/>", .{ box_x, box_y, end_x, box_y, end_x, mid_y, notch_x, notch_y, box_x, notch_y, theme.primary_color, stroke });
            try textBlock(c, frame.label.x, frame.label.y, &frame.label.text, theme.primary_text_color);
            for (frame.section_labels) |*l| try textBlock(c, l.x, l.y, &l.text, null);
        }
        for (seq.lifelines.items) |l| {
            try o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"{}\" stroke-width=\"0.5\"/>", .{ l.x, l.y1, l.x, l.y2, theme.sequence_actor_line });
        }
        for (seq.activations.items) |act| {
            try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1\"/>", .{ act.x, act.y, act.width, act.height, theme.sequence_activation_fill, theme.sequence_activation_border });
        }
        for (seq.notes.items) |*note| {
            try notePath(c, note.x, note.y, note.width, note.height);
            try textBlock(c, note.x + note.width / 2.0, note.y + note.height / 2.0, &note.label, theme.primary_text_color);
        }
    }
    if (layout.diagram == .graph) {
        for (layout.diagram.graph.state_notes.items) |*note| {
            try notePath(c, note.x, note.y, note.width, note.height);
            try textBlockFull(c, note.x + note.width / 2.0, note.y + note.height / 2.0, &note.label, state_font_size, "middle", theme.primary_text_color, false);
        }
    }

    if (is_sequence) {
        try renderSequenceEdges(c, layout, colors.items);
    } else {
        try renderGraphEdges(c, layout, colors.items, overlay_flowchart, state_font_size);
    }

    if (!is_sequence) {
        for (layout.nodes.values()) |*node| {
            if (node.hidden or node.anchor_subgraph != null) continue;
            try linkOpen(c, node);
            if (layout.kind == .er) {
                try renderErNode(c, node);
                if (node.link != null) try o.str("</a>");
                continue;
            }
            try shapeSvg(c, node);
            const dlh = if (layout.kind == .class) theme.font_size * config.classLabelLineHeight() else theme.font_size * config.label_line_height;
            try dividerLines(c, node, dlh);
            const cx = node.x + node.width / 2.0;
            const cy = node.y + node.height / 2.0;
            if (!hideLabel(node)) {
                if (hasDivider(node.label.lines)) {
                    try textBlockClass(c, node, node.style.text_color);
                } else if (layout.kind == .state) {
                    try textBlockFull(c, cx, cy, &node.label, state_font_size, "middle", node.style.text_color, false);
                } else {
                    try textBlock(c, cx, cy, &node.label, node.style.text_color);
                }
            }
            if (node.link != null) try o.str("</a>");
        }
    } else {
        for (layout.nodes.values()) |*node| {
            if (node.hidden or node.anchor_subgraph != null) continue;
            try seqActor(c, node);
        }
        for (seq_data.?.footboxes.items) |*fb| try seqActor(c, fb);
    }
    try o.str("</svg>");
    return o.items();
}

fn seqActor(c: Ctx, node: *const t.NodeLayout) E!void {
    try linkOpen(c, node);
    try c.o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"3\" ry=\"3\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1.0\"/>", .{ node.x, node.y, node.width, node.height, c.theme.sequence_actor_fill, c.theme.sequence_actor_border });
    if (!hideLabel(node)) try textBlock(c, node.x + node.width / 2.0, node.y + node.height / 2.0, &node.label, node.style.text_color);
    if (node.link != null) try c.o.str("</a>");
}

fn hideLabel(node: *const t.NodeLayout) bool {
    var all_empty = true;
    for (node.label.lines) |l| all_empty = all_empty and util.trim(l).len == 0;
    return all_empty or util.startsWith(node.id, "__start_") or util.startsWith(node.id, "__end_");
}

fn linkOpen(c: Ctx, node: *const t.NodeLayout) E!void {
    const link = node.link orelse return;
    const url = try escapeXml(c.a, link.url);
    try c.o.put("<a href=\"{}\" xlink:href=\"{}\"", .{ url, url });
    if (link.target) |target_raw| {
        const target = try escapeXml(c.a, target_raw);
        try c.o.put(" target=\"{}\"", .{target});
        if (eql(target, "_blank")) try c.o.str(" rel=\"noopener noreferrer\"");
    }
    try c.o.str(">");
    if (link.title) |title| try c.o.put("<title>{}</title>", .{try escapeXml(c.a, title)});
}

fn notePath(c: Ctx, x: f32, y: f32, w: f32, h: f32) E!void {
    const fill = c.theme.sequence_note_fill;
    const stroke = c.theme.sequence_note_border;
    const fold = @min(@max(c.theme.font_size * 0.8, 8.0), @min(w, h) * 0.3);
    const x2 = x + w;
    const y2 = y + h;
    const fold_x = x2 - fold;
    const fold_y = y + fold;
    try c.o.put("<path d=\"M {:.2} {:.2} L {:.2} {:.2} L {:.2} {:.2} L {:.2} {:.2} L {:.2} {:.2} Z\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1.1\"/>", .{ x, y, fold_x, y, x2, fold_y, x2, y2, x, y2, fill, stroke });
    try c.o.put("<polyline points=\"{:.2},{:.2} {:.2},{:.2} {:.2},{:.2}\" fill=\"none\" stroke=\"{}\" stroke-width=\"1.0\"/>", .{ fold_x, y, fold_x, fold_y, x2, fold_y, stroke });
}

// ---------------------------------------------------------------------------------------
// Edges
// ---------------------------------------------------------------------------------------

fn markerIndex(colors: []const []const u8, stroke: []const u8) usize {
    for (colors, 0..) |col, i| if (eql(col, stroke)) return i;
    return 0;
}

const LabelKind = enum { center, start, end };

fn labelRect(cx: f32, cy: f32, lw: f32, lh: f32, px: f32, py: f32) [4]f32 {
    const w = @max(lw + px * 2.0, 0.0);
    const h = @max(lh + py * 2.0, 0.0);
    return .{ cx - w * 0.5, cy - h * 0.5, w, h };
}

fn edgeAttrs(c: Ctx, edge_idx: usize, d: []const u8, stroke: []const u8, sw: f32, marker_end: []const u8, marker_start: []const u8, dash: []const u8) E!void {
    try c.o.put("<path id=\"edge-{}\" class=\"edgePath\" data-edge-id=\"edge-{}\" d=\"{}\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\" {} {} {} stroke-linecap=\"round\" stroke-linejoin=\"round\" />", .{ edge_idx, edge_idx, d, stroke, sw, marker_end, marker_start, dash });
}

fn decorations(c: Ctx, edge: *const t.EdgeLayout, stroke: []const u8, sw: f32) E!void {
    const pts = edge.points.items;
    if (pts.len > 0) {
        if (edge.start_decoration) |dec| try edgeDecoration(c, pts[0], routing.edgeEndpointAngle(pts, true), dec, stroke, sw, true);
        if (edge.end_decoration) |dec| try edgeDecoration(c, pts[pts.len - 1], routing.edgeEndpointAngle(pts, false), dec, stroke, sw, false);
    }
}

fn renderSequenceEdges(c: Ctx, layout: *const t.Layout, colors: []const []const u8) E!void {
    const theme = c.theme;
    const o = c.o;
    for (layout.edges.items, 0..) |*edge, edge_idx| {
        const pts = edge.points.items;
        const d = try pointsToPath(c.a, pts);
        const stroke = edge.override_style.stroke orelse theme.line_color;
        const label_fill = theme.edge_label_background;
        const label_stroke = theme.primary_border_color;
        const cpad = label_placement.edgeLabelPadding(layout.kind);
        const epad = label_placement.endpointLabelPadding(layout.kind);
        const mid = markerIndex(colors, stroke);
        const marker_end = if (edge.arrow_end) try svg_fmt.print(c.a, "marker-end=\"url(#arrow-seq-{})\"", .{mid}) else "";
        const marker_start = if (edge.arrow_start) try svg_fmt.print(c.a, "marker-start=\"url(#arrow-start-seq-{})\"", .{mid}) else "";
        var dash: []const u8 = if (edge.style == .dotted) "stroke-dasharray=\"2,2\"" else "";
        if (edge.override_style.dasharray) |v| dash = try svg_fmt.print(c.a, "stroke-dasharray=\"{}\"", .{v});
        const sw = edge.override_style.stroke_width orelse 1.5;
        try edgeAttrs(c, edge_idx, d, stroke, sw, marker_end, marker_start, dash);
        try decorations(c, edge, stroke, sw);

        if (edge.label) |*label| {
            const pos: Point = edge.label_anchor orelse blk: {
                const start: Point = if (pts.len > 0) pts[0] else .{ 0, 0 };
                const end: Point = if (pts.len > 0) pts[pts.len - 1] else start;
                const mid_x = (start[0] + end[0]) / 2.0;
                const gap = if (layout.kind == .sequence) std.math.clamp(theme.font_size * 0.25, 3.0, 5.0) else @max(theme.font_size * 0.6, 8.0);
                break :blk .{ mid_x, start[1] - gap - label.height / 2.0 };
            };
            const color = edge.override_style.label_color orelse theme.primary_text_color;
            if (!eql(label_fill, "none")) {
                const r = labelRect(pos[0], pos[1], label.width, label.height, cpad[0], cpad[1]);
                const vis = labelBackgroundVisible(layout.kind, .center, pts, r);
                try o.put("<rect class=\"edgeLabel sequenceEdgeLabel\" data-edge-id=\"edge-{}\" data-label-kind=\"center\" x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"2\" ry=\"2\" fill=\"{}\" fill-opacity=\"{:.2}\" stroke=\"{}\" stroke-opacity=\"{:.2}\" stroke-width=\"0.8\"/>", .{ edge_idx, r[0], r[1], r[2], r[3], label_fill, @as(f32, if (vis) 0.90 else 0.0), label_stroke, @as(f32, if (vis) 0.30 else 0.0) });
            }
            try o.put("<g class=\"edgeLabel\" data-edge-id=\"edge-{}\" data-label-kind=\"center\">", .{edge_idx});
            try textBlock(c, pos[0], pos[1], label, color);
            try o.str("</g>");
        }

        const end_off = @max(theme.font_size * 0.6, 8.0);
        const color = edge.override_style.label_color orelse theme.primary_text_color;
        inline for (.{ LabelKind.start, LabelKind.end }) |kind| {
            const lab = if (kind == .start) edge.start_label else edge.end_label;
            const anchor = if (kind == .start) edge.start_label_anchor else edge.end_label_anchor;
            if (lab) |label| {
                if (anchor orelse label_placement.edgeEndpointLabelPosition(edge, kind == .start, end_off)) |pos| {
                    if (!eql(label_fill, "none")) {
                        const r = labelRect(pos[0], pos[1], label.width, label.height, epad[0], epad[1]);
                        const vis = labelBackgroundVisible(layout.kind, kind, pts, r);
                        try o.put("<rect class=\"edgeLabel sequenceEndpointLabel\" data-edge-id=\"edge-{}\" data-label-kind=\"{}\" x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"2\" ry=\"2\" fill=\"{}\" fill-opacity=\"{:.2}\" stroke=\"{}\" stroke-opacity=\"{:.2}\" stroke-width=\"0.75\"/>", .{ edge_idx, @tagName(kind), r[0], r[1], r[2], r[3], label_fill, @as(f32, if (vis) 0.88 else 0.0), label_stroke, @as(f32, if (vis) 0.28 else 0.0) });
                    }
                    try o.put("<g class=\"edgeLabel\" data-edge-id=\"edge-{}\" data-label-kind=\"{}\">", .{ edge_idx, @tagName(kind) });
                    try textBlock(c, pos[0], pos[1], &label, color);
                    try o.str("</g>");
                }
            }
        }
    }
    for (layout.diagram.sequence.numbers.items) |num| {
        const r = @max(theme.font_size * 0.45, 6.0);
        try o.put("<circle cx=\"{:.2}\" cy=\"{:.2}\" r=\"{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1\"/>", .{ num.x, num.y, r, theme.sequence_activation_fill, theme.sequence_activation_border });
        const s = try svg_fmt.print(c.a, "{}", .{num.value});
        try textLine(c, num.x, num.y + theme.font_size * 0.35, s, theme.font_size, theme.primary_text_color, "middle");
    }
}

fn renderGraphEdges(c: Ctx, layout: *const t.Layout, colors: []const []const u8, overlay_flowchart: bool, state_font_size: f32) E!void {
    const theme = c.theme;
    const o = c.o;
    const a = c.a;
    const base_w: f32 = switch (layout.kind) {
        .class, .state, .er => 1.0,
        else => 2.0,
    };
    for (layout.edges.items, 0..) |*edge, edge_idx| {
        const pts = edge.points.items;
        const d = if (layout.kind == .flowchart and pts.len > 2) try roundedPolylinePath(a, pts, 10.0) else try pointsToPath(a, pts);
        const stroke = edge.override_style.stroke orelse theme.line_color;
        var dash: []const u8 = "";
        var sw: f32 = base_w;
        switch (edge.style) {
            .solid => {},
            .dotted => dash = "stroke-dasharray=\"4 4\"",
            .thick => sw = 3.5,
        }
        const mid = markerIndex(colors, stroke);
        var marker_end: []const u8 = "";
        if (edge.arrow_end and !overlay_flowchart) {
            marker_end = switch (layout.kind) {
                .state => try svg_fmt.print(a, "marker-end=\"url(#arrow-state-{})\"", .{mid}),
                .class => if (edge.arrow_end_kind) |k| switch (k) {
                    .open_triangle => try svg_fmt.print(a, "marker-end=\"url(#arrow-class-open-{})\"", .{mid}),
                    .class_dependency => try svg_fmt.print(a, "marker-end=\"url(#arrow-class-dep-{})\"", .{mid}),
                } else try svg_fmt.print(a, "marker-end=\"url(#arrow-{})\"", .{mid}),
                else => try svg_fmt.print(a, "marker-end=\"url(#arrow-{})\"", .{mid}),
            };
        }
        var marker_start: []const u8 = "";
        if (edge.arrow_start and !overlay_flowchart) {
            marker_start = switch (layout.kind) {
                .state => try svg_fmt.print(a, "marker-start=\"url(#arrow-state-{})\"", .{mid}),
                .class => if (edge.arrow_start_kind) |k| switch (k) {
                    .open_triangle => try svg_fmt.print(a, "marker-start=\"url(#arrow-class-open-start-{})\"", .{mid}),
                    .class_dependency => try svg_fmt.print(a, "marker-start=\"url(#arrow-class-dep-start-{})\"", .{mid}),
                } else try svg_fmt.print(a, "marker-start=\"url(#arrow-start-{})\"", .{mid}),
                else => try svg_fmt.print(a, "marker-start=\"url(#arrow-start-{})\"", .{mid}),
            };
        }
        if (edge.override_style.stroke_width) |w| sw = w;
        if (edge.override_style.dasharray) |v| dash = try svg_fmt.print(a, "stroke-dasharray=\"{}\"", .{v});
        try edgeAttrs(c, edge_idx, d, stroke, sw, marker_end, marker_start, dash);

        if (overlay_flowchart) {
            if (edge.arrow_start and pts.len > 0) try arrowhead(c, pts[0], routing.edgeEndpointAngle(pts, true) + 180.0, stroke, sw);
            if (edge.arrow_end and pts.len > 0) try arrowhead(c, pts[pts.len - 1], routing.edgeEndpointAngle(pts, false), stroke, sw);
        }
        try decorations(c, edge, stroke, sw);

        const label_scale: f32 = if (layout.kind == .state) @min(state_font_size / theme.font_size, 1.0) else 1.0;
        if (edge.label) |*label| if (edge.label_anchor) |pos| {
            const pad = label_placement.edgeLabelPadding(layout.kind);
            const op: [2]f32 = switch (layout.kind) {
                .state => .{ 0.7, 0.25 },
                .flowchart => .{ 0.95, 0.45 },
                else => .{ 0.85, 0.35 },
            };
            const r = labelRect(pos[0], pos[1], label.width * label_scale, label.height * label_scale, pad[0], pad[1]);
            const fill = theme.edge_label_background;
            if (!eql(fill, "none")) {
                const vis = labelBackgroundVisible(layout.kind, .center, pts, r);
                try o.put("<rect data-edge-id=\"edge-{}\" data-label-kind=\"center\" x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"2\" ry=\"2\" fill=\"{}\" fill-opacity=\"{:.2}\" stroke=\"{}\" stroke-opacity=\"{:.2}\" stroke-width=\"0.8\"/>", .{ edge_idx, r[0], r[1], r[2], r[3], fill, if (vis) op[0] else 0.0, theme.primary_border_color, if (vis) op[1] else 0.0 });
            }
            try o.put("<g class=\"edgeLabel\" data-edge-id=\"edge-{}\" data-label-kind=\"center\">", .{edge_idx});
            if (layout.kind == .state) {
                try textBlockFull(c, pos[0], pos[1], label, state_font_size, "middle", edge.override_style.label_color, false);
            } else {
                try textBlock(c, pos[0], pos[1], label, edge.override_style.label_color);
            }
            try o.str("</g>");
        };

        const epad = label_placement.endpointLabelPadding(layout.kind);
        const eop: [2]f32 = switch (layout.kind) {
            .state => .{ 0.7, 0.25 },
            .flowchart => .{ 0.95, 0.45 },
            .class => .{ 0.9, 0.4 },
            else => .{ 0.85, 0.35 },
        };
        const fill = theme.edge_label_background;
        const color = edge.override_style.label_color orelse theme.primary_text_color;
        inline for (.{ LabelKind.start, LabelKind.end }) |kind| {
            const lab = if (kind == .start) edge.start_label else edge.end_label;
            const anchor = if (kind == .start) edge.start_label_anchor else edge.end_label_anchor;
            if (lab) |label| if (anchor) |pos| {
                const r = labelRect(pos[0], pos[1], label.width * label_scale, label.height * label_scale, epad[0], epad[1]);
                if (!eql(fill, "none")) {
                    const vis = labelBackgroundVisible(layout.kind, kind, pts, r);
                    try o.put("<rect data-edge-id=\"edge-{}\" data-label-kind=\"{}\" x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"2\" ry=\"2\" fill=\"{}\" fill-opacity=\"{:.2}\" stroke=\"{}\" stroke-opacity=\"{:.2}\" stroke-width=\"0.8\"/>", .{ edge_idx, @tagName(kind), r[0], r[1], r[2], r[3], fill, if (vis) eop[0] else 0.0, theme.primary_border_color, if (vis) eop[1] else 0.0 });
                }
                try o.put("<g class=\"edgeLabel\" data-edge-id=\"edge-{}\" data-label-kind=\"{}\">", .{ edge_idx, @tagName(kind) });
                if (layout.kind == .state) {
                    try textBlockFull(c, pos[0], pos[1], &label, state_font_size, "middle", color, false);
                } else {
                    try textBlock(c, pos[0], pos[1], &label, color);
                }
                try o.str("</g>");
            };
        }
    }
}

fn edgeDecoration(c: Ctx, p: Point, angle_deg: f32, dec: ir.EdgeDecoration, stroke: []const u8, sw: f32, at_start: bool) E!void {
    var angle = angle_deg;
    if ((dec == .diamond or dec == .diamond_filled) and !at_start) angle += 180.0;
    const o = c.o;
    try o.put("<g transform=\"translate({:.2} {:.2}) rotate({:.2})\">", .{ p[0], p[1], angle });
    switch (dec) {
        .circle => try o.put("<circle cx=\"0\" cy=\"0\" r=\"5\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\"/>", .{ stroke, sw }),
        .cross => try o.put("<path d=\"M -5 -5 L 5 5 M -5 5 L 5 -5\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\"" ++ JOIN ++ "/>", .{ stroke, sw }),
        .diamond => try o.put("<polygon points=\"0,0 9,6 18,0 9,-6\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\"" ++ JOIN ++ "/>", .{ stroke, sw }),
        .diamond_filled => try o.put("<polygon points=\"0,0 9,6 18,0 9,-6\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"" ++ JOIN ++ "/>", .{ stroke, stroke, sw }),
        .crows_foot_one => try o.put("<path d=\"M 0 -6 L 0 6 M 5 -6 L 5 6\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\"" ++ JOIN ++ "/>", .{ stroke, sw }),
        .crows_foot_zero_one => try o.put("<g><circle cx=\"-4\" cy=\"0\" r=\"4\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\"/><path d=\"M 4 -6 L 4 6\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\"" ++ JOIN ++ "/></g>", .{ stroke, sw, stroke, sw }),
        .crows_foot_many => try o.put("<path d=\"M 0 -6 L 0 6 M 0 0 L 8 -6 M 0 0 L 8 6\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\"" ++ JOIN ++ "/>", .{ stroke, sw }),
        .crows_foot_zero_many => try o.put("<g><circle cx=\"-4\" cy=\"0\" r=\"4\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\"/><path d=\"M 4 0 L 12 -6 M 4 0 L 12 6\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\"" ++ JOIN ++ "/></g>", .{ stroke, sw, stroke, sw }),
    }
    try o.str("</g>");
}

fn arrowhead(c: Ctx, p: Point, angle: f32, stroke: []const u8, sw: f32) E!void {
    const size = std.math.clamp(sw * 1.5 + 4.5, 5.5, 10.0);
    const half = size * 0.52;
    try c.o.put("<g transform=\"translate({:.2} {:.2}) rotate({:.2})\"><polygon points=\"0,0 {:.2},{:.2} {:.2},{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"" ++ JOIN ++ "/></g>", .{ p[0], p[1], angle, -size, half, -size, -half, stroke, stroke, sw });
}

// ---------------------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------------------

fn dedupePoints(a: Allocator, pts: []const Point) E![]Point {
    var out: std.ArrayList(Point) = .empty;
    for (pts) |p| {
        if (out.items.len > 0) {
            const prev = out.items[out.items.len - 1];
            if (@abs(prev[0] - p[0]) < 1e-3 and @abs(prev[1] - p[1]) < 1e-3) continue;
        }
        try out.append(a, p);
    }
    return out.items;
}

fn pointsToPath(a: Allocator, points: []const Point) E![]const u8 {
    if (points.len == 0) return "";
    const pts = try dedupePoints(a, points);
    var o = Out.init(a);
    try o.put("M {:.3},{:.3}", .{ pts[0][0], pts[0][1] });
    for (pts[1..]) |p| try o.put(" L {:.3},{:.3}", .{ p[0], p[1] });
    return o.items();
}

fn roundedPolylinePath(a: Allocator, points: []const Point, radius: f32) E![]const u8 {
    const pts = try dedupePoints(a, points);
    if (pts.len <= 2 or radius <= 0.0) return pointsToPath(a, pts);
    var o = Out.init(a);
    try o.put("M {:.3},{:.3}", .{ pts[0][0], pts[0][1] });
    for (1..pts.len - 1) |idx| {
        const prev = pts[idx - 1];
        const cur = pts[idx];
        const next = pts[idx + 1];
        const in_v: Point = .{ cur[0] - prev[0], cur[1] - prev[1] };
        const out_v: Point = .{ next[0] - cur[0], next[1] - cur[1] };
        const in_len = std.math.hypot(in_v[0], in_v[1]);
        const out_len = std.math.hypot(out_v[0], out_v[1]);
        if (in_len <= 1e-3 or out_len <= 1e-3) continue;
        const iu: Point = .{ in_v[0] / in_len, in_v[1] / in_len };
        const ou: Point = .{ out_v[0] / out_len, out_v[1] / out_len };
        const cross = iu[0] * ou[1] - iu[1] * ou[0];
        const dot = iu[0] * ou[0] + iu[1] * ou[1];
        if (@abs(cross) <= 1e-3 or dot < -0.95) {
            try o.put(" L {:.3},{:.3}", .{ cur[0], cur[1] });
            continue;
        }
        const trim = @min(@min(radius, in_len * 0.45), out_len * 0.45);
        if (trim <= 0.5) {
            try o.put(" L {:.3},{:.3}", .{ cur[0], cur[1] });
            continue;
        }
        try o.put(" L {:.3},{:.3} Q {:.3},{:.3} {:.3},{:.3}", .{ cur[0] - iu[0] * trim, cur[1] - iu[1] * trim, cur[0], cur[1], cur[0] + ou[0] * trim, cur[1] + ou[1] * trim });
    }
    const last = pts[pts.len - 1];
    try o.put(" L {:.3},{:.3}", .{ last[0], last[1] });
    return o.items();
}

// ---------------------------------------------------------------------------------------
// Label backgrounds
// ---------------------------------------------------------------------------------------

fn labelBackgroundVisible(kind: Kind, label_kind: LabelKind, pts: []const Point, r: [4]f32) bool {
    if (pts.len < 2 or r[2] <= 0.0 or r[3] <= 0.0) return true;
    const gap = polylineRectGap(pts, r);
    return switch (label_kind) {
        .center => gap <= switch (kind) {
            .flowchart => 1.2,
            .sequence => std.math.clamp(r[3] * 0.16, 1.2, 2.4),
            .requirement => 1.0,
            else => 0.9,
        },
        .start, .end => switch (kind) {
            .sequence => gap <= std.math.clamp(r[3] * 0.12, 0.6, 1.4),
            .flowchart, .requirement => gap <= 0.35,
            else => false,
        },
    };
}

fn polylineRectGap(pts: []const Point, r: [4]f32) f32 {
    var best = std.math.inf(f32);
    for (0..pts.len - 1) |i| {
        best = @min(best, segmentRectGap(pts[i], pts[i + 1], r));
        if (best <= 1e-6) return 0.0;
    }
    return best;
}

fn corners(r: [4]f32) [4]Point {
    return .{ .{ r[0], r[1] }, .{ r[0] + r[2], r[1] }, .{ r[0] + r[2], r[1] + r[3] }, .{ r[0], r[1] + r[3] } };
}

fn segmentRectGap(p: Point, q: Point, r: [4]f32) f32 {
    if (segmentIntersectsRect(p, q, r)) return 0.0;
    var best = @min(pointRectDistance(p, r), pointRectDistance(q, r));
    for (corners(r)) |corner| best = @min(best, pointSegmentDistance(corner, p, q));
    return best;
}

fn pointRectDistance(p: Point, r: [4]f32) f32 {
    const x1 = r[0];
    const y1 = r[1];
    const x2 = r[0] + r[2];
    const y2 = r[1] + r[3];
    const dx: f32 = if (p[0] < x1) x1 - p[0] else if (p[0] > x2) p[0] - x2 else 0.0;
    const dy: f32 = if (p[1] < y1) y1 - p[1] else if (p[1] > y2) p[1] - y2 else 0.0;
    return @sqrt(dx * dx + dy * dy);
}

fn pointSegmentDistance(p: Point, s: Point, e: Point) f32 {
    const abx = e[0] - s[0];
    const aby = e[1] - s[1];
    const len_sq = abx * abx + aby * aby;
    if (len_sq <= 1e-9) {
        const dx = p[0] - s[0];
        const dy = p[1] - s[1];
        return @sqrt(dx * dx + dy * dy);
    }
    const tt = std.math.clamp(((p[0] - s[0]) * abx + (p[1] - s[1]) * aby) / len_sq, 0.0, 1.0);
    const dx = p[0] - (s[0] + abx * tt);
    const dy = p[1] - (s[1] + aby * tt);
    return @sqrt(dx * dx + dy * dy);
}

fn pointInRect(p: Point, r: [4]f32) bool {
    return p[0] >= r[0] and p[0] <= r[0] + r[2] and p[1] >= r[1] and p[1] <= r[1] + r[3];
}

fn segmentIntersectsRect(p: Point, q: Point, r: [4]f32) bool {
    if (pointInRect(p, r) or pointInRect(q, r)) return true;
    const cs = corners(r);
    for (0..4) |i| if (segmentsIntersect(p, q, cs[i], cs[(i + 1) % 4])) return true;
    return false;
}

fn orient(p: Point, q: Point, r: Point) f32 {
    return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]);
}

fn onSegment(p: Point, q: Point, r: Point, eps: f32) bool {
    return r[0] >= @min(p[0], q[0]) - eps and r[0] <= @max(p[0], q[0]) + eps and r[1] >= @min(p[1], q[1]) - eps and r[1] <= @max(p[1], q[1]) + eps;
}

fn segmentsIntersect(p: Point, q: Point, r: Point, s: Point) bool {
    const eps: f32 = 1e-6;
    const o1 = orient(p, q, r);
    const o2 = orient(p, q, s);
    const o3 = orient(r, s, p);
    const o4 = orient(r, s, q);
    if (@abs(o1) < eps and onSegment(p, q, r, eps)) return true;
    if (@abs(o2) < eps and onSegment(p, q, s, eps)) return true;
    if (@abs(o3) < eps and onSegment(r, s, p, eps)) return true;
    if (@abs(o4) < eps and onSegment(r, s, q, eps)) return true;
    return (o1 > 0.0) != (o2 > 0.0) and (o3 > 0.0) != (o4 > 0.0);
}

// ---------------------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------------------

pub fn escapeXml(a: Allocator, s: []const u8) E![]const u8 {
    var n: usize = 0;
    for (s) |ch| switch (ch) {
        '&', '<', '>', '"', '\'' => n += 1,
        else => {},
    };
    if (n == 0) return s;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(a, s.len + n * 5);
    for (s) |ch| switch (ch) {
        '&' => out.appendSliceAssumeCapacity("&amp;"),
        '<' => out.appendSliceAssumeCapacity("&lt;"),
        '>' => out.appendSliceAssumeCapacity("&gt;"),
        '"' => out.appendSliceAssumeCapacity("&quot;"),
        '\'' => out.appendSliceAssumeCapacity("&apos;"),
        else => out.appendAssumeCapacity(ch),
    };
    return out.items;
}

pub fn normalizeFontFamily(a: Allocator, family: []const u8) E![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, family, ',');
    while (it.next()) |raw| {
        const p = util.trimMatches(util.trimMatches(util.trim(raw), '\''), '"');
        if (p.len > 0) try parts.append(a, p);
    }
    if (parts.items.len == 0) return "sans-serif";
    return util.join(a, parts.items, ",");
}

fn isDividerLine(line: []const u8) bool {
    return eql(util.trim(line), "---");
}

fn hasDivider(lines: []const []const u8) bool {
    for (lines) |l| if (isDividerLine(l)) return true;
    return false;
}

fn textBlock(c: Ctx, x: f32, y: f32, label: *const TextBlock, color: ?[]const u8) E!void {
    return textBlockFull(c, x, y, label, c.theme.font_size, "middle", color, false);
}

fn textBlockFull(c: Ctx, x: f32, y: f32, label: *const TextBlock, font_size: f32, anchor: []const u8, color: ?[]const u8, baseline: bool) E!void {
    return textBlockWeight(c, x, y, label, font_size, anchor, color, null, baseline);
}

fn textBlockWeight(c: Ctx, x: f32, y: f32, label: *const TextBlock, font_size: f32, anchor: []const u8, color: ?[]const u8, weight: ?[]const u8, baseline: bool) E!void {
    const total_h = @as(f32, @floatFromInt(label.lines.len)) * font_size * c.config.label_line_height;
    const start_y = if (baseline) y else y - total_h / 2.0 + font_size;
    const fill = color orelse c.theme.primary_text_color;
    const weight_attr = if (weight) |w| (if (util.trim(w).len > 0) try svg_fmt.print(c.a, " font-weight=\"{}\"", .{w}) else "") else "";
    try c.o.put("<text x=\"{:.2}\" y=\"{:.2}\" text-anchor=\"{}\" font-family=\"{}\" font-size=\"{}\" fill=\"{}\"{}>", .{ x, start_y, anchor, try normalizeFontFamily(c.a, c.theme.font_family), font_size, fill, weight_attr });
    const lh = font_size * c.config.label_line_height;
    for (label.lines, 0..) |line, idx| {
        const dy: f32 = if (idx == 0) 0.0 else lh;
        const rendered = if (isDividerLine(line)) "" else try escapeXml(c.a, line);
        try c.o.put("<tspan x=\"{:.2}\" dy=\"{:.2}\">{}</tspan>", .{ x, dy, rendered });
    }
    try c.o.str("</text>");
}

fn textLine(c: Ctx, x: f32, y: f32, s: []const u8, font_size: f32, fill: []const u8, anchor: []const u8) E!void {
    try c.o.put("<text x=\"{:.2}\" y=\"{:.2}\" text-anchor=\"{}\" font-family=\"{}\" font-size=\"{}\" fill=\"{}\">{}</text>", .{ x, y, anchor, try normalizeFontFamily(c.a, c.theme.font_family), font_size, fill, try escapeXml(c.a, s) });
}

const IdxLine = struct { usize, []const u8 };

fn textLines(c: Ctx, lines: []const IdxLine, x: f32, start_y: f32, lh: f32, anchor: []const u8, fill: []const u8, bold: ?usize) E!void {
    if (lines.len == 0) return;
    const first_y = start_y + @as(f32, @floatFromInt(lines[0][0])) * lh;
    try c.o.put("<text x=\"{:.2}\" y=\"{:.2}\" text-anchor=\"{}\" font-family=\"{}\" font-size=\"{}\" fill=\"{}\">", .{ x, first_y, anchor, try normalizeFontFamily(c.a, c.theme.font_family), c.theme.font_size, fill });
    var prev = lines[0][0];
    for (lines, 0..) |l, pos| {
        const dy: f32 = if (pos == 0) 0.0 else @as(f32, @floatFromInt(l[0] - prev)) * lh;
        const w = if (bold != null and bold.? == pos) " font-weight=\"600\"" else "";
        try c.o.put("<tspan x=\"{:.2}\" dy=\"{:.2}\"{}>{}</tspan>", .{ x, dy, w, try escapeXml(c.a, l[1]) });
        prev = l[0];
    }
    try c.o.str("</text>");
}

fn textBlockClass(c: Ctx, node: *const t.NodeLayout, color: ?[]const u8) E!void {
    const theme = c.theme;
    const lh = theme.font_size * c.config.classLabelLineHeight();
    const total_h = @as(f32, @floatFromInt(node.label.lines.len)) * lh;
    const start_y = node.y + node.height / 2.0 - total_h / 2.0 + theme.font_size;
    const cx = node.x + node.width / 2.0;
    const left_x = node.x + @max(c.config.node_padding_x, 10.0);
    const fill = color orelse theme.primary_text_color;
    var divider_idx: ?usize = null;
    for (node.label.lines, 0..) |l, i| if (isDividerLine(l)) {
        divider_idx = i;
        break;
    };
    var title: std.ArrayList(IdxLine) = .empty;
    var members: std.ArrayList(IdxLine) = .empty;
    const di = divider_idx orelse {
        for (node.label.lines, 0..) |l, i| try title.append(c.a, .{ i, l });
        return textLines(c, title.items, cx, start_y, lh, "middle", fill, null);
    };
    for (node.label.lines[0..di], 0..) |l, i| if (util.trim(l).len > 0) try title.append(c.a, .{ i, l });
    for (node.label.lines[di + 1 ..], di + 1..) |l, i| if (util.trim(l).len > 0 and !isDividerLine(l)) try members.append(c.a, .{ i, l });
    if (title.items.len > 0) try textLines(c, title.items, cx, start_y, lh, "middle", fill, title.items.len - 1);
    if (members.items.len > 0) try textLines(c, members.items, left_x, start_y, lh, "start", fill, null);
}

fn dividerLines(c: Ctx, node: *const t.NodeLayout, lh: f32) E!void {
    if (!hasDivider(node.label.lines)) return;
    const total_h = @as(f32, @floatFromInt(node.label.lines.len)) * lh;
    const start_y = node.y + node.height / 2.0 - total_h / 2.0 + c.theme.font_size;
    const stroke = node.style.stroke orelse c.theme.primary_border_color;
    const x1 = node.x + 6.0;
    const x2 = node.x + node.width - 6.0;
    for (node.label.lines, 0..) |l, idx| {
        if (!isDividerLine(l)) continue;
        const y = start_y + @as(f32, @floatFromInt(idx)) * lh - c.theme.font_size * 0.35;
        try c.o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"{}\" stroke-width=\"1.0\"/>", .{ x1, y, x2, y, stroke });
    }
}

// ---------------------------------------------------------------------------------------
// Shapes
// ---------------------------------------------------------------------------------------

fn shapeSvg(c: Ctx, node: *const t.NodeLayout) E!void {
    const theme = c.theme;
    const o = c.o;
    const stroke = node.style.stroke orelse theme.primary_border_color;
    const fill = node.style.fill orelse theme.primary_color;
    const dash = if (node.style.stroke_dasharray) |v| try svg_fmt.print(c.a, " stroke-dasharray=\"{}\"", .{v}) else "";
    const sw = node.style.stroke_width orelse 1.0;
    const x = node.x;
    const y = node.y;
    const w = node.width;
    const h = node.height;
    switch (node.shape) {
        .rectangle, .actor_box => try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"3\" ry=\"3\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ x, y, w, h, fill, stroke, sw, dash }),
        .fork_join => try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"2\" ry=\"2\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ x, y, w, h, fill, stroke, sw, dash }),
        .diamond => {
            const cx = x + w / 2.0;
            const cy = y + h / 2.0;
            try o.put("<polygon points=\"{:.2},{:.2} {:.2},{:.2} {:.2},{:.2} {:.2},{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ cx, y, x + w, cy, cx, y + h, x, cy, fill, stroke, sw, dash });
        },
        .circle, .double_circle => {
            var label_empty = true;
            for (node.label.lines) |l| label_empty = label_empty and util.trim(l).len == 0;
            const is_start = util.startsWith(node.id, "__start_");
            const is_end = util.startsWith(node.id, "__end_");
            var cf: []const u8 = fill;
            var cs: []const u8 = stroke;
            if (is_start) {
                cf = theme.line_color;
                cs = theme.line_color;
            } else if (is_end) {
                cf = theme.primary_border_color;
                cs = theme.primary_border_color;
            } else if (label_empty) {
                if (node.shape == .circle) {
                    cf = theme.primary_text_color;
                    cs = theme.primary_text_color;
                } else {
                    cf = theme.primary_border_color;
                    cs = theme.background;
                }
            }
            const cx = x + w / 2.0;
            const cy = y + h / 2.0;
            const r = @min(w, h) / 2.0;
            try o.put("<circle cx=\"{:.2}\" cy=\"{:.2}\" r=\"{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ cx, cy, r, cf, cs, sw, dash });
            if (node.shape == .double_circle) {
                const r2 = r - 4.0;
                if (r2 > 0.0) {
                    const solid = label_empty or is_end;
                    const inner_fill = if (solid) theme.background else "none";
                    const inner_stroke = if (solid) theme.background else cs;
                    const isw: f32 = if (solid) 1.2 else 1.0;
                    try o.put("<circle cx=\"{:.2}\" cy=\"{:.2}\" r=\"{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"" ++ JOIN ++ "/>", .{ cx, cy, r2, inner_fill, inner_stroke, isw });
                }
            }
        },
        .stadium => try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"{:.2}\" ry=\"{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ x, y, w, h, h / 2.0, h / 2.0, fill, stroke, sw, dash }),
        .round_rect => try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"10\" ry=\"10\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ x, y, w, h, fill, stroke, sw, dash }),
        .cylinder => {
            const cx = x + w / 2.0;
            const ry = std.math.clamp(h * 0.12, 6.0, 14.0);
            const rx = w / 2.0;
            try o.put("<ellipse cx=\"{:.2}\" cy=\"{:.2}\" rx=\"{:.2}\" ry=\"{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ cx, y + ry, rx, ry, fill, stroke, sw, dash });
            try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ x, y + ry, w, @max(h - 2.0 * ry, 0.0), fill, stroke, sw, dash });
            try o.put("<ellipse cx=\"{:.2}\" cy=\"{:.2}\" rx=\"{:.2}\" ry=\"{:.2}\" fill=\"none\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ cx, y + h - ry, rx, ry, stroke, sw, dash });
        },
        .subroutine => {
            try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"6\" ry=\"6\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ x, y, w, h, fill, stroke, sw, dash });
            const y1 = y + 2.0;
            const y2 = y + h - 2.0;
            const x1 = x + 6.0;
            const x2 = x + w - 6.0;
            try o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"{}\" stroke-width=\"{}\"" ++ JOIN ++ "/>", .{ x1, y1, x1, y2, stroke, sw });
            try o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"{}\" stroke-width=\"{}\"" ++ JOIN ++ "/>", .{ x2, y1, x2, y2, stroke, sw });
        },
        .hexagon => {
            const x1 = x + w * 0.25;
            const x2 = x + w * 0.75;
            const ym = y + h / 2.0;
            try o.put("<polygon points=\"{:.2},{:.2} {:.2},{:.2} {:.2},{:.2} {:.2},{:.2} {:.2},{:.2} {:.2},{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ x1, y, x2, y, x + w, ym, x2, y + h, x1, y + h, x, ym, fill, stroke, sw, dash });
        },
        .parallelogram, .parallelogram_alt, .trapezoid, .trapezoid_alt => {
            const off = w * 0.18;
            const p: [4]Point = switch (node.shape) {
                .parallelogram => .{ .{ x + off, y }, .{ x + w, y }, .{ x + w - off, y + h }, .{ x, y + h } },
                .parallelogram_alt => .{ .{ x, y }, .{ x + w - off, y }, .{ x + w, y + h }, .{ x + off, y + h } },
                .trapezoid => .{ .{ x + off, y }, .{ x + w - off, y }, .{ x + w, y + h }, .{ x, y + h } },
                else => .{ .{ x, y }, .{ x + w, y }, .{ x + w - off, y + h }, .{ x + off, y + h } },
            };
            try o.put("<polygon points=\"{:.2},{:.2} {:.2},{:.2} {:.2},{:.2} {:.2},{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ p[0][0], p[0][1], p[1][0], p[1][1], p[2][0], p[2][1], p[3][0], p[3][1], fill, stroke, sw, dash });
        },
        .asymmetric => {
            const slant = w * 0.22;
            try o.put("<polygon points=\"{:.2},{:.2} {:.2},{:.2} {:.2},{:.2} {:.2},{:.2} {:.2},{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ x, y, x + w - slant, y, x + w, y + h / 2.0, x + w - slant, y + h, x, y + h, fill, stroke, sw, dash });
        },
        else => try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"6\" ry=\"6\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"{}" ++ JOIN ++ "/>", .{ x, y, w, h, fill, stroke, sw, dash }),
    }
}

// ---------------------------------------------------------------------------------------
// ER entities
// ---------------------------------------------------------------------------------------

const ErAttribute = struct { name: []const u8, data_type: []const u8, keys: []const []const u8 };

fn isKey(s: []const u8) bool {
    return eql(s, "PK") or eql(s, "FK") or eql(s, "UK");
}

fn parseErAttributes(a: Allocator, lines: []const []const u8) E!struct { []const u8, []ErAttribute } {
    var title: []const u8 = if (lines.len > 0) util.trim(lines[0]) else "";
    var attrs: std.ArrayList(ErAttribute) = .empty;
    var in_body = false;
    if (lines.len > 1) for (lines[1..]) |line| {
        if (isDividerLine(line)) {
            in_body = true;
            continue;
        }
        if (!in_body) {
            if (util.trim(line).len > 0) title = util.trim(line);
            continue;
        }
        const trimmed = util.trim(line);
        if (trimmed.len == 0) continue;
        var keys: std.ArrayList([]const u8) = .empty;
        var parts: std.ArrayList([]const u8) = .empty;
        var it = util.splitWhitespace(trimmed);
        while (it.next()) |token| {
            const cleaned = try util.upperAscii(a, std.mem.trim(u8, token, ",;"));
            if (isKey(cleaned)) {
                try keys.append(a, cleaned);
                continue;
            }
            if (std.mem.indexOfScalar(u8, cleaned, ',') != null) {
                var handled = false;
                var pit = std.mem.splitScalar(u8, cleaned, ',');
                while (pit.next()) |piece| if (isKey(piece)) {
                    try keys.append(a, piece);
                    handled = true;
                };
                if (handled) continue;
            }
            try parts.append(a, token);
        }
        if (parts.items.len == 0) continue;
        const dt, const name = if (parts.items.len >= 2) .{ parts.items[0], try util.join(a, parts.items[1..], " ") } else .{ "", parts.items[0] };
        try attrs.append(a, .{ .name = name, .data_type = dt, .keys = keys.items });
    };
    return .{ title, attrs.items };
}

fn renderErNode(c: Ctx, node: *const t.NodeLayout) E!void {
    const theme = c.theme;
    const o = c.o;
    const a = c.a;
    const title, const attrs = try parseErAttributes(a, node.label.lines);
    const fs = theme.font_size;
    const lh = fs * c.config.label_line_height;
    const header_h = if (attrs.len == 0) node.height else @max(@min(lh + fs * 0.6, node.height * 0.5), lh + 6.0);
    const border = node.style.stroke orelse theme.primary_border_color;
    const body_fill = node.style.fill orelse theme.background;
    const grid = theme.cluster_border;
    const x = node.x;
    const y = node.y;
    const w = node.width;
    const h = node.height;
    const radius: f32 = 6.0;
    try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"{:.2}\" ry=\"{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{}\"/>", .{ x, y, w, h, radius, radius, body_fill, border, node.style.stroke_width orelse 1.2 });
    try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"{:.2}\" ry=\"{:.2}\" fill=\"{}\"/>", .{ x, y, w, header_h, radius, radius, theme.cluster_background });
    const header_lines = try a.alloc([]const u8, 1);
    header_lines[0] = title;
    try textBlockFull(c, x + w / 2.0, y + header_h / 2.0, &.{ .lines = header_lines, .width = 0, .height = 0 }, fs, "middle", theme.primary_text_color, false);
    if (attrs.len == 0) return;
    const pad_x = @max(fs * 0.8, 10.0);
    // text_metrics::measure_text_width is None without the font installed.
    const max_type_width: f32 = 0.0;
    const max_name_width: f32 = 0.0;
    var max_badge_width: f32 = 0.0;
    for (attrs) |attr| {
        if (attr.keys.len > 0) {
            var row: f32 = 0.0;
            for (attr.keys[0..@min(2, attr.keys.len)]) |_| {
                const bw = fs * 0.9 + @max(fs * 0.45, 4.0) * 2.0;
                row += bw + fs * 0.4;
            }
            if (row > 0.0) row -= fs * 0.4;
            max_badge_width = @max(max_badge_width, row);
        }
    }
    const type_col_pad = fs * 0.9;
    const available = @max(w - pad_x * 2.0, fs * 4.0);
    var type_col_width: f32 = if (max_type_width > 0.0) @min(max_type_width + type_col_pad * 2.0, available * 0.45) else 0.0;
    const min_name_width = @min(max_name_width + fs * 0.6, available * 0.7);
    const min_type_width: f32 = if (max_type_width > 0.0) @max(fs * 2.8, 36.0) else 0.0;
    if (type_col_width < min_type_width) type_col_width = min_type_width;
    var col_x = x + w - pad_x - type_col_width;
    const min_col_x = x + pad_x + max_badge_width + min_name_width;
    if (col_x < min_col_x) col_x = min_col_x;
    const show_type_col = type_col_width > 0.0 and col_x < x + w - pad_x - 8.0;
    try o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"{}\" stroke-width=\"1.0\" stroke-opacity=\"0.6\"/>", .{ x, y + header_h, x + w, y + header_h, grid });
    if (show_type_col) {
        try o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"{}\" stroke-width=\"1.0\" stroke-opacity=\"0.45\"/>", .{ col_x, y + header_h, col_x, y + h, grid });
    }
    var row_h = lh;
    const body_h = @max(h - header_h, lh);
    const n: f32 = @floatFromInt(attrs.len);
    if (n * row_h > body_h) row_h = body_h / n;
    for (attrs, 0..) |attr, idx| {
        const row_top = y + header_h + @as(f32, @floatFromInt(idx)) * row_h;
        const row_center = row_top + row_h / 2.0;
        if (idx > 0) {
            try o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"{}\" stroke-width=\"1.0\" stroke-opacity=\"0.35\"/>", .{ x, row_top, x + w, row_top, grid });
        }
        var cursor_x = x + pad_x;
        for (attr.keys[0..@min(2, attr.keys.len)]) |key| {
            const fill = if (eql(key, "PK")) "#1D4ED8" else if (eql(key, "FK")) "#0F766E" else if (eql(key, "UK")) "#7C3AED" else "#475569";
            const family = try normalizeFontFamily(a, theme.font_family);
            const bpad = @max(fs * 0.45, 4.0);
            const bw = fs * 0.9 + bpad * 2.0;
            const bh = @max(fs * 0.9, 10.0);
            const rx = @max(bh / 2.0, 4.0);
            try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"{:.2}\" ry=\"{:.2}\" fill=\"{}\"/>", .{ cursor_x, row_center - bh / 2.0, bw, bh, rx, rx, fill });
            try o.put("<text x=\"{:.2}\" y=\"{:.2}\" text-anchor=\"middle\" font-family=\"{}\" font-size=\"{:.2}\" font-weight=\"600\" fill=\"{}\">{}</text>", .{ cursor_x + bw / 2.0, row_center + fs * 0.26, family, fs * 0.72, "#FFFFFF", try escapeXml(a, key) });
            cursor_x += bw + fs * 0.4;
        }
        const nl = try a.alloc([]const u8, 1);
        nl[0] = attr.name;
        try textBlockFull(c, cursor_x, row_center, &.{ .lines = nl, .width = 0, .height = 0 }, fs, "start", theme.primary_text_color, false);
        if (show_type_col and attr.data_type.len > 0) {
            const tl = try a.alloc([]const u8, 1);
            tl[0] = attr.data_type;
            try textBlockFull(c, x + w - pad_x, row_center, &.{ .lines = tl, .width = 0, .height = 0 }, fs, "end", theme.line_color, false);
        }
    }
}

// ---------------------------------------------------------------------------------------
// Pie
// ---------------------------------------------------------------------------------------

const PieLabel = struct {
    text: []const u8,
    font_size: f32,
    outside: bool,
    side: i32,
    x: f32,
    y: f32,
    edge_x: f32,
    edge_y: f32,
    line_color: []const u8,
};

fn distribute(indices: []usize, labels: []PieLabel, min_y: f32, max_y: f32, min_gap: f32) void {
    const Ctx2 = struct {
        labels: []PieLabel,
        fn lt(cx: @This(), x: usize, y: usize) bool {
            return cx.labels[x].y < cx.labels[y].y;
        }
    };
    std.mem.sort(usize, indices, Ctx2{ .labels = labels }, Ctx2.lt);
    var prev = min_y - min_gap;
    for (indices) |i| {
        const y = @max(labels[i].y, prev + min_gap);
        labels[i].y = y;
        prev = y;
    }
    if (indices.len > 0) {
        const overflow = labels[indices[indices.len - 1]].y - max_y;
        if (overflow > 0.0) for (indices) |i| {
            labels[i].y -= overflow;
        };
        const underflow = min_y - labels[indices[0]].y;
        if (underflow > 0.0) for (indices) |i| {
            labels[i].y += underflow;
        };
    }
}

fn renderPie(c: Ctx, pie: *const t.PieData) E!void {
    const theme = c.theme;
    const o = c.o;
    const a = c.a;
    const cx, const cy = pie.center;
    const radius = pie.radius;
    if (radius <= 0.0) return;
    const cfg = &c.config.pie;
    var total: f32 = 0.0;
    for (pie.legend.items) |s| total += @max(s.value, 0.0);
    if (total <= 0.0) {
        total = 0.0;
        for (pie.slices.items) |s| total += @max(s.value, 0.0);
    }
    const slice_stroke = theme.background;
    const slice_sw = @max(theme.pie_stroke_width, 1.2);
    for (pie.slices.items) |slice| {
        const span = @abs(slice.end_angle - slice.start_angle);
        if (span <= 0.0001) continue;
        if (span >= std.math.pi * 2.0 - 0.001) {
            try o.put("<circle cx=\"{:.2}\" cy=\"{:.2}\" r=\"{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{:.3}\" opacity=\"{:.3}\"/>", .{ cx, cy, radius, try escapeXml(a, slice.color), try escapeXml(a, slice_stroke), slice_sw, theme.pie_opacity });
            continue;
        }
        const path = try pieSlicePath(a, cx, cy, radius, slice.start_angle, slice.end_angle);
        try o.put("<path d=\"{}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{:.3}\" opacity=\"{:.3}\"/>", .{ try escapeXml(a, path), try escapeXml(a, slice.color), try escapeXml(a, slice_stroke), slice_sw, theme.pie_opacity });
    }
    if (theme.pie_outer_stroke_width > 0.0) {
        try o.put("<circle cx=\"{:.2}\" cy=\"{:.2}\" r=\"{:.2}\" fill=\"none\" stroke=\"{}\" stroke-width=\"{:.3}\"/>", .{ cx, cy, radius + theme.pie_outer_stroke_width / 2.0, try escapeXml(a, theme.pie_outer_stroke_color), theme.pie_outer_stroke_width });
    }
    var labels: std.ArrayList(PieLabel) = .empty;
    const suppress_outside = pie.legend.items.len >= 4;
    for (pie.slices.items) |slice| {
        const span = @abs(slice.end_angle - slice.start_angle);
        if (span <= 0.0001 or total <= 0.0) continue;
        const percent = slice.value / total * 100.0;
        if (percent < cfg.min_percent) continue;
        const percent_text = try svg_fmt.print(a, "{:.0}%", .{percent});
        const mid = (slice.start_angle + slice.end_angle) / 2.0;
        const fs = theme.pie_section_text_size;
        const arc_len = radius * span;
        const percent_width = pie_layout.percentTextWidth(percent_text, fs);
        const outside = !suppress_outside and pie_layout.labelIsOutside(arc_len, percent_width, span);
        const label_text = if (outside) try util.join(a, slice.label.lines, " ") else percent_text;
        const edge_x = cx + radius * @cos(mid);
        const edge_y = cy + radius * @sin(mid);
        const bump = pie_layout.outsideLabelBump(fs, radius);
        const lr = if (outside) radius + bump else radius * cfg.text_position;
        try labels.append(a, .{
            .text = label_text,
            .font_size = fs,
            .outside = outside,
            .side = if (@cos(mid) >= 0.0) 1 else -1,
            .x = cx + lr * @cos(mid),
            .y = cy + lr * @sin(mid),
            .edge_x = edge_x,
            .edge_y = edge_y,
            .line_color = slice.color,
        });
    }
    const min_y = cy - radius * 1.1;
    const max_y = cy + radius * 1.1;
    const min_gap = theme.pie_section_text_size * 1.2;
    var left: std.ArrayList(usize) = .empty;
    var right: std.ArrayList(usize) = .empty;
    for (labels.items, 0..) |l, i| if (l.outside) {
        if (l.side >= 0) try right.append(a, i) else try left.append(a, i);
    };
    distribute(left.items, labels.items, min_y, max_y, min_gap);
    distribute(right.items, labels.items, min_y, max_y, min_gap);
    const family = try normalizeFontFamily(a, theme.font_family);
    for (labels.items) |l| {
        var anchor: []const u8 = "middle";
        var lx = l.x;
        if (l.outside) {
            const bump = pie_layout.outsideLabelBump(l.font_size, radius);
            if (l.side >= 0) {
                lx = cx + radius + bump;
                anchor = "start";
            } else {
                lx = cx - radius - bump;
                anchor = "end";
            }
            const elbow_x = if (l.side >= 0) lx - 6.0 else lx + 6.0;
            try o.put("<path d=\"M {:.2},{:.2} L {:.2},{:.2} L {:.2},{:.2}\" fill=\"none\" stroke=\"{}\" stroke-width=\"1\"/>", .{ l.edge_x, l.edge_y, elbow_x, l.y, lx, l.y, try escapeXml(a, l.line_color) });
            const lw = pie_layout.percentTextWidth(l.text, l.font_size);
            const pad_x = pie_layout.outsideLabelPadX(l.font_size);
            const pad_y = @max(l.font_size * 0.25, 2.5);
            const rw = lw + pad_x * 2.0;
            const rh = l.font_size + pad_y * 2.0;
            const rx = if (l.side >= 0) lx - pad_x else lx - rw + pad_x;
            const bg = if (eql(theme.edge_label_background, "none")) theme.background else theme.edge_label_background;
            try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"2\" ry=\"2\" fill=\"{}\" stroke=\"none\"/>", .{ rx, l.y - rh / 2.0, rw, rh, try escapeXml(a, bg) });
        }
        try o.put("<text x=\"{:.2}\" y=\"{:.2}\" text-anchor=\"{}\" dominant-baseline=\"middle\" font-family=\"{}\" font-size=\"{}\" fill=\"{}\">{}</text>", .{ lx, l.y, anchor, family, l.font_size, try escapeXml(a, theme.pie_section_text_color), l.text });
    }
    for (pie.legend.items) |*item| {
        try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"{:.3}\"/>", .{ item.x, item.y, item.marker_size, item.marker_size, try escapeXml(a, item.color), try escapeXml(a, item.color), theme.pie_stroke_width });
        try textBlockFull(c, item.x + item.marker_size + cfg.legend_spacing, item.y + item.marker_size / 2.0, &item.label, theme.pie_legend_text_size, "start", theme.pie_legend_text_color, true);
    }
    if (pie.title) |*title| {
        try textBlockFull(c, title.x, title.y, &title.text, theme.pie_title_text_size, "middle", theme.pie_title_text_color, true);
    }
}

fn pieSlicePath(a: Allocator, cx: f32, cy: f32, r: f32, s: f32, e: f32) E![]const u8 {
    const sx = cx + r * @cos(s);
    const sy = cy + r * @sin(s);
    const ex = cx + r * @cos(e);
    const ey = cy + r * @sin(e);
    const large: u8 = if (@abs(e - s) > std.math.pi) 1 else 0;
    return svg_fmt.print(a, "M {:.2} {:.2} L {:.2} {:.2} A {:.2} {:.2} 0 {} {} {:.2} {:.2} Z", .{ cx, cy, sx, sy, r, r, large, @as(u8, 1), ex, ey });
}

// ---------------------------------------------------------------------------------------
// Gantt
// ---------------------------------------------------------------------------------------

fn renderGantt(c: Ctx, g: *const t.GanttLayout) E!void {
    const theme = c.theme;
    const o = c.o;
    const a = c.a;
    const chart_left = g.chart_x;
    const chart_right = g.chart_x + g.chart_width;
    const full_width = chart_right + g.label_x;
    const bar_h = @max(@min(g.row_height * 0.82, g.row_height - 4.0), theme.font_size * 1.1);
    if (g.title) |*title| try textBlock(c, g.chart_x + g.chart_width / 2.0, g.title_y, title, theme.primary_text_color);
    const axis_y = g.chart_y + g.chart_height + g.row_height * 0.85;
    const tick_font = theme.font_size * 0.8;
    for (g.ticks.items) |tick| {
        try o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"#E2E8F0\" stroke-width=\"1\"/>", .{ tick.x, g.chart_y, tick.x, g.chart_y + g.chart_height });
        if (util.trim(tick.label).len > 0) try textLine(c, tick.x, axis_y, tick.label, tick_font, theme.text_color, "middle");
    }
    try o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"{}\" stroke-width=\"1\"/>", .{ chart_left, g.chart_y + g.chart_height, chart_right, g.chart_y + g.chart_height, theme.line_color });
    try o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"#E2E8F0\" stroke-width=\"1\"/>", .{ chart_left, g.chart_y, chart_left, g.chart_y + g.chart_height });
    const section_font = theme.font_size * 0.9;
    const task_font = theme.font_size * 0.85;
    for (g.sections.items) |*s| {
        try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" fill=\"{}\" fill-opacity=\"0.22\" stroke=\"none\"/>", .{ @as(f32, 0.0), s.y, g.chart_x, s.height, s.band_color });
        try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" fill=\"{}\" fill-opacity=\"0.12\" stroke=\"none\"/>", .{ g.chart_x, s.y, g.chart_width, s.height, s.band_color });
        try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" fill=\"{}\" fill-opacity=\"0.9\" stroke=\"none\"/>", .{ @as(f32, 0.0), s.y, @max(theme.font_size * 0.3, 3.0), s.height, s.color });
        const label_y = @min(s.y + g.row_height * 0.55, s.y + s.height - g.row_height * 0.45);
        try textBlockFull(c, g.section_label_x, label_y, &s.label, section_font, "start", theme.primary_text_color, false);
    }
    var rows: std.ArrayList(f32) = .empty;
    try rows.append(a, g.chart_y);
    for (g.sections.items) |s| {
        try rows.append(a, s.y);
        try rows.append(a, s.y + s.height);
    }
    for (g.tasks.items) |tk| try rows.append(a, tk.y);
    try rows.append(a, g.chart_y + g.chart_height);
    std.mem.sort(f32, rows.items, {}, std.sort.asc(f32));
    var kept: std.ArrayList(f32) = .empty;
    for (rows.items) |y| {
        if (kept.items.len > 0 and @abs(y - kept.items[kept.items.len - 1]) < 0.5) continue;
        try kept.append(a, y);
    }
    for (kept.items) |y| {
        try o.put("<line x1=\"{:.2}\" y1=\"{:.2}\" x2=\"{:.2}\" y2=\"{:.2}\" stroke=\"#E2E8F0\" stroke-width=\"1\"/>", .{ @as(f32, 0.0), y, full_width, y });
    }
    const family = try normalizeFontFamily(a, theme.font_family);
    for (g.tasks.items) |*tk| {
        const row_center = tk.y + g.row_height / 2.0;
        const bar_y = row_center - bar_h / 2.0;
        var inside = false;
        const milestone = tk.status != null and tk.status.? == .milestone;
        if (milestone) {
            const size = bar_h * 0.6;
            try o.put("<polygon points=\"{:.2},{:.2} {:.2},{:.2} {:.2},{:.2} {:.2},{:.2}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1\"/>", .{ tk.x, row_center - size, tk.x + size, row_center, tk.x, row_center + size, tk.x - size, row_center, tk.color, theme.primary_border_color });
        } else {
            try o.put("<rect x=\"{:.2}\" y=\"{:.2}\" width=\"{:.2}\" height=\"{:.2}\" rx=\"3\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1\"/>", .{ tk.x, bar_y, tk.width, bar_h, tk.color, theme.primary_border_color });
            var label_text: []const u8 = "";
            for (tk.label.lines) |l| if (util.trim(l).len > 0) {
                label_text = l;
                break;
            };
            if (label_text.len > 0) {
                const fs = task_font * 0.95;
                const tw = @as(f32, @floatFromInt(util.charCount(label_text))) * fs * 0.55;
                const pad = @max(fs * 0.6, 6.0);
                if (tk.width >= tw + pad * 2.0 and bar_h >= fs * 1.1) {
                    const lc = if (theme_mod.parseColorToHsl(tk.color)) |hsl| (if (hsl[2] < 55.0) "#FFFFFF" else "#0F172A") else theme.primary_text_color;
                    try o.put("<text x=\"{:.2}\" y=\"{:.2}\" text-anchor=\"middle\" dominant-baseline=\"middle\" font-family=\"{}\" font-size=\"{:.2}\" fill=\"{}\">{}</text>", .{ tk.x + tk.width / 2.0, row_center, family, fs, try escapeXml(a, lc), try escapeXml(a, label_text) });
                    inside = true;
                }
            }
        }
        if (!inside) {
            var lx = g.task_label_x;
            if (g.compact) {
                const gap = theme.font_size * 0.4;
                lx = if (milestone) tk.x + bar_h * 0.6 + gap else tk.x + tk.width + gap;
            }
            try textBlockFull(c, lx, row_center, &tk.label, task_font, "start", theme.primary_text_color, false);
        }
    }
}
