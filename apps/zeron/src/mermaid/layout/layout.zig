//! `layout/mod.rs`: layout entry point, the flowchart-family pipeline (also
//! used for class, state and ER diagrams) and the shared helpers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir.zig");
const util = @import("../util.zig");
const Theme = @import("../theme.zig").Theme;
const LayoutConfig = @import("../config.zig").LayoutConfig;
const text = @import("../text.zig");
pub const t = @import("types.zig");
const routing = @import("routing.zig");
const ranking = @import("ranking.zig");
const sg = @import("subgraphs.zig");
const policy = @import("flowchart/policy.zig");
const manual = @import("flowchart/manual_layout.zig");
const spacing = @import("flowchart/subgraph_spacing.zig");
const objectives = @import("flowchart/objectives.zig");
const pipeline = @import("flowchart/edge_pipeline.zig");
const label_placement = @import("label_placement.zig");
const sequence = @import("sequence.zig");
const pie = @import("pie.zig");
const gantt = @import("gantt.zig");
const Graph = ir.Graph;
const NodeMap = t.NodeMap;
const NodeLayout = t.NodeLayout;
const EdgeLayout = t.EdgeLayout;
const SubgraphLayout = t.SubgraphLayout;
const Layout = t.Layout;
const TextBlock = t.TextBlock;
const Point = t.Point;
const FMAX = std.math.floatMax(f32);
const FMIN = -std.math.floatMax(f32);

pub const isHorizontal = routing.isHorizontal;
pub const edgeLabelPadding = label_placement.edgeLabelPadding;

pub const LAYOUT_BOUNDARY_PAD: f32 = 8.0;
pub const STATE_MARKER_FONT_SCALE: f32 = 0.75;
pub const STATE_MARKER_MIN_SIZE: f32 = 10.0;
pub const STATE_DEFAULT_HEIGHT_SCALE: f32 = 2.4;
pub const STATE_MARKER_DIV: f32 = 3.0;
pub const STATE_MARKER_MIN_SCALE: f32 = 0.5;
pub const STATE_MARKER_MAX_SCALE: f32 = 0.95;
pub const STATE_NOTE_PAD_X_SCALE: f32 = 0.75;
pub const STATE_NOTE_PAD_Y_SCALE: f32 = 0.5;
pub const STATE_NOTE_GAP_SCALE: f32 = 0.9;
pub const STATE_NOTE_GAP_MIN: f32 = 10.0;
pub const STATE_PAD_X_SCALE: f32 = 0.9;
pub const STATE_PAD_Y_SCALE: f32 = 0.65;
pub const STATE_PAD_X_LABEL_RATIO: f32 = 0.12;
pub const STATE_PAD_Y_LABEL_RATIO: f32 = 0.22;
pub const FLOWCHART_PAD_MAIN: f32 = 40.0;
pub const FLOWCHART_PAD_CROSS: f32 = 30.0;
pub const FLOWCHART_PORT_ROUTE_BIAS_RATIO: f32 = 0.5;
pub const FLOWCHART_PORT_ROUTE_BIAS_MAX_RATIO: f32 = 0.8;
pub const STATE_SUBGRAPH_BASE_PAD: f32 = 16.0;
pub const GENERIC_SUBGRAPH_BASE_PAD: f32 = 24.0;
pub const SUBGRAPH_LABEL_GAP_FLOWCHART: f32 = 6.0;
pub const SUBGRAPH_LABEL_GAP_GENERIC: f32 = 8.0;
pub const STATE_SUBGRAPH_TOP_LABEL_SCALE: f32 = 0.75;
pub const STATE_SUBGRAPH_TOP_MIN_SCALE: f32 = 1.4;
pub const DIAMOND_SCALE: f32 = 0.95;
pub const FORK_JOIN_MIN_WIDTH: f32 = 50.0;
pub const FORK_JOIN_HEIGHT_SCALE: f32 = 0.4;
pub const FORK_JOIN_MIN_HEIGHT: f32 = 8.0;
pub const CIRCLE_EMPTY_HEIGHT_SCALE: f32 = 1.4;
pub const CIRCLE_EMPTY_MIN_SIZE: f32 = 14.0;
pub const ROUND_RECT_WIDTH_SCALE: f32 = 1.1;
pub const ROUND_RECT_HEIGHT_SCALE: f32 = 1.05;
pub const CYLINDER_SCALE: f32 = 1.1;
pub const HEXAGON_WIDTH_SCALE: f32 = 1.2;
pub const HEXAGON_HEIGHT_SCALE: f32 = 1.1;
pub const TRAPEZOID_WIDTH_SCALE: f32 = 1.2;
pub const CLASS_MIN_HEIGHT_SCALE: f32 = 6.5;
pub const EDGE_LABEL_PAD_SCALE: f32 = 0.35;
pub const ENDPOINT_LABEL_PAD_SCALE: f32 = 0.2;
pub const DUAL_ENDPOINT_EXTRA_PAD_SCALE: f32 = 0.45;
pub const EDGE_RELAX_STEP_MIN: f32 = 24.0;
pub const EDGE_RELAX_GAP_TOLERANCE: f32 = 0.5;
pub const MAX_MAIN_GAP_FACTOR: f32 = 6.0;
pub const FLOWCHART_EDGE_LABEL_WRAP_TRIGGER_CHARS: usize = 34;
pub const FLOWCHART_EDGE_LABEL_WRAP_MAX_CHARS: usize = 18;
pub const OVERLAP_RESOLVE_PASSES: usize = 6;
pub const OVERLAP_MIN_GAP_RATIO: f32 = 0.2;
pub const OVERLAP_MIN_GAP_FLOOR: f32 = 4.0;
pub const OVERLAP_CENTER_THRESHOLD: f32 = 0.5;
pub const SUBGRAPH_DESIRED_GAP_RATIO: f32 = 1.6;
pub const MIN_NODE_SPACING_FLOOR: f32 = 16.0;
pub const EDGE_OCCUPANCY_CELL_RATIO: f32 = 0.6;
pub const MULTI_EDGE_OFFSET_RATIO: f32 = 0.35;
pub const STATE_RANK_SPACING_BOOST: f32 = 25.0;

pub fn computeLayout(a: Allocator, graph_in: *const Graph, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!Layout {
    const graph = try normalizeGraphForLayout(a, graph_in);
    var layout = switch (graph.kind) {
        .sequence, .zen_uml => try sequence.computeSequenceLayout(a, graph, theme, config),
        .pie => try pie.computePieLayout(a, graph, theme, config),
        .gantt => try gantt.computeGanttLayout(a, graph, theme, config),
        else => try computeFlowchartLayout(a, graph, theme, config),
    };
    try label_placement.resolveAllLabelPositions(a, &layout, theme, config);
    switch (layout.diagram) {
        .sequence => sequence.finalizeSequenceLayoutBounds(&layout),
        .graph => finalizeGraphLabelBounds(&layout, config),
        else => {},
    }
    return layout;
}

fn normalizeGraphForLayout(a: Allocator, graph: *const Graph) Allocator.Error!*const Graph {
    var needs = false;
    for (graph.edges.items) |e| needs = needs or !graph.nodes.contains(e.from) or !graph.nodes.contains(e.to);
    const seq = graph.kind == .sequence or graph.kind == .zen_uml;
    if (seq) for (graph.sequence_participants.items) |id| {
        needs = needs or !graph.nodes.contains(id);
    };
    if (!needs) return graph;
    const g = try a.create(Graph);
    g.* = graph.*;
    g.nodes = try graph.nodes.clone(a);
    g.node_order = try graph.node_order.clone(a);
    for (graph.edges.items) |e| {
        try g.ensureNode(a, e.from, null, null);
        try g.ensureNode(a, e.to, null, null);
    }
    if (seq) for (graph.sequence_participants.items) |id| try g.ensureNode(a, id, null, null);
    return g;
}

fn includeRect(b: *[4]f32, x: f32, y: f32, w: f32, h: f32) void {
    b[0] = @min(b[0], x);
    b[1] = @min(b[1], y);
    b[2] = @max(b[2], x + w);
    b[3] = @max(b[3], y + h);
}

pub fn translateGraphLayout(layout: *Layout, dx: f32, dy: f32) void {
    if (dx == 0.0 and dy == 0.0) return;
    for (layout.nodes.values()) |*n| {
        n.x += dx;
        n.y += dy;
    }
    for (layout.subgraphs.items) |*s| {
        s.x += dx;
        s.y += dy;
    }
    for (layout.edges.items) |*e| {
        for (e.points.items) |*p| p.* = .{ p[0] + dx, p[1] + dy };
        inline for (.{ "label_anchor", "start_label_anchor", "end_label_anchor" }) |f| {
            if (@field(e, f)) |*p| p.* = .{ p[0] + dx, p[1] + dy };
        }
    }
    if (layout.diagram == .graph) for (layout.diagram.graph.state_notes.items) |*n| {
        n.x += dx;
        n.y += dy;
    };
}

fn finalizeGraphLabelBounds(layout: *Layout, config: *const LayoutConfig) void {
    _ = config;
    var b = [4]f32{ 0, 0, layout.width, layout.height };
    const pad = edgeLabelPadding(layout.kind);
    for (layout.nodes.values()) |n| includeRect(&b, n.x, n.y, n.width, n.height);
    for (layout.subgraphs.items) |s| includeRect(&b, s.x, s.y, s.width, s.height);
    for (layout.edges.items) |e| {
        for (e.points.items) |p| includeRect(&b, p[0], p[1], 0, 0);
        const pairs = [_]struct { ?TextBlock, ?Point }{ .{ e.label, e.label_anchor }, .{ e.start_label, e.start_label_anchor }, .{ e.end_label, e.end_label_anchor } };
        for (pairs) |pr| {
            const l = pr[0] orelse continue;
            const c = pr[1] orelse continue;
            includeRect(&b, c[0] - l.width / 2.0 - pad[0], c[1] - l.height / 2.0 - pad[1], l.width + pad[0] * 2.0, l.height + pad[1] * 2.0);
        }
    }
    if (layout.diagram == .graph) for (layout.diagram.graph.state_notes.items) |n| includeRect(&b, n.x, n.y, n.width, n.height);
    const dx: f32 = if (b[0] < 0.0) -b[0] + LAYOUT_BOUNDARY_PAD else 0.0;
    const dy: f32 = if (b[1] < 0.0) -b[1] + LAYOUT_BOUNDARY_PAD else 0.0;
    translateGraphLayout(layout, dx, dy);
    layout.width = @max(b[2] + dx + LAYOUT_BOUNDARY_PAD, layout.width + dx);
    layout.height = @max(b[3] + dy + LAYOUT_BOUNDARY_PAD, layout.height + dy);
}

fn computeFlowchartLayout(a: Allocator, graph: *const Graph, theme: *const Theme, config_in: *const LayoutConfig) Allocator.Error!Layout {
    var effective = policy.applyInitialConfigHeuristics(graph, config_in);
    const tiny = try policy.isTinyGraphLayout(a, graph);
    var nodes: NodeMap = .{};
    const measure_font_size = theme.font_size;
    var label_config = effective;
    if (graph.kind == .class) label_config.label_line_height = label_config.classLabelLineHeight();
    var marker_ids: std.ArrayList([]const u8) = .empty;
    var state_h_total: f32 = 0;
    var state_h_count: usize = 0;
    for (graph.nodes.values()) |*node| {
        const label = try text.measureLabelWithFontSize(a, node.label, measure_font_size, &label_config, true, theme.font_family);
        const label_empty = label.isEmptyLabel();
        var size = shapeSize(node.shape, &label, &effective, theme, graph.kind);
        if (graph.kind == .state and label_empty and (node.shape == .circle or node.shape == .double_circle)) {
            const s = @max(theme.font_size * STATE_MARKER_FONT_SCALE, STATE_MARKER_MIN_SIZE);
            size = .{ s, s };
            try marker_ids.append(a, node.id);
        } else if (graph.kind == .state) {
            state_h_total += size[1];
            state_h_count += 1;
        }
        var style = resolveNodeStyle(node.id, graph);
        if (graph.kind == .state and node.shape == .fork_join and label_empty) {
            if (style.fill == null) style.fill = theme.line_color;
            if (style.stroke == null) style.stroke = theme.line_color;
            if (style.stroke_width == null) style.stroke_width = 1.0;
        }
        try nodes.put(a, node.id, .{ .id = node.id, .width = size[0], .height = size[1], .label = label, .shape = node.shape, .style = style, .link = graph.node_links.get(node.id) });
    }
    if (graph.kind == .state and marker_ids.items.len > 0) {
        const avg = if (state_h_count > 0) state_h_total / @as(f32, @floatFromInt(state_h_count)) else theme.font_size * STATE_DEFAULT_HEIGHT_SCALE;
        const m = std.math.clamp(avg / STATE_MARKER_DIV, theme.font_size * STATE_MARKER_MIN_SCALE, theme.font_size * STATE_MARKER_MAX_SCALE);
        for (marker_ids.items) |id| if (nodes.get(id)) |n| {
            n.width = m;
            n.height = m;
        };
    }
    try policy.applyMeasuredSpacingHeuristics(a, graph, theme, &effective, &nodes);
    const config = &effective;

    var anchor_ids = try sg.markSubgraphAnchorNodesHidden(a, graph, &nodes);
    var anchor_info = try sg.applySubgraphAnchorSizes(a, graph, &nodes, theme, config);
    var anchored_nodes: ranking.StrSet = .empty;
    for (anchor_info.values()) |info| if (info.sub_idx < graph.subgraphs.items.len) for (graph.subgraphs.items[info.sub_idx].nodes.items) |id| try anchored_nodes.put(a, id, {});
    var anchored_indices: sg.IndexSet = .empty;
    for (anchor_info.values()) |info| try anchored_indices.put(a, info.sub_idx, {});
    var redirects: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (graph.subgraphs.items, 0..) |*sub, idx| {
        const anchor = sg.subgraphAnchorId(sub, &nodes) orelse continue;
        if (anchored_indices.contains(idx)) continue;
        if (try sg.pickSubgraphAnchorChild(a, sub, graph, &anchor_ids)) |child| {
            if (!util.eql(child, anchor)) try redirects.put(a, anchor, child);
        }
    }
    var layout_edges: std.ArrayList(ir.Edge) = .empty;
    for (graph.edges.items) |e| {
        var le = e;
        if (redirects.get(le.from)) |f| le.from = f;
        if (redirects.get(le.to)) |tt| le.to = tt;
        try layout_edges.append(a, le);
    }
    var ids: std.ArrayList([]const u8) = .empty;
    try ids.appendSlice(a, graph.nodes.keys.items);
    std.mem.sort([]const u8, ids.items, graph, struct {
        fn lt(g: *const Graph, x: []const u8, y: []const u8) bool {
            const ox = g.orderOf(x);
            const oy = g.orderOf(y);
            if (ox != oy) return ox < oy;
            return std.mem.order(u8, x, y) == .lt;
        }
    }.lt);
    const retain = struct {
        fn f(list: *std.ArrayList([]const u8), drop: *const ranking.StrSet) void {
            var w: usize = 0;
            for (list.items) |id| {
                if (drop.contains(id)) continue;
                list.items[w] = id;
                w += 1;
            }
            list.items.len = w;
        }
    }.f;
    if (anchored_nodes.count() > 0) retain(&ids, &anchored_nodes);
    var layout_set: ranking.StrSet = .empty;
    for (ids.items) |id| try layout_set.put(a, id, {});
    if (anchor_info.count() == 0) {
        anchor_info = try sg.applySubgraphAnchorSizes(a, graph, &nodes, theme, config);
        anchored_nodes.clearRetainingCapacity();
        for (anchor_info.values()) |info| if (info.sub_idx < graph.subgraphs.items.len) for (graph.subgraphs.items[info.sub_idx].nodes.items) |id| try anchored_nodes.put(a, id, {});
        if (anchored_nodes.count() > 0) retain(&ids, &anchored_nodes);
        layout_set.clearRetainingCapacity();
        for (ids.items) |id| try layout_set.put(a, id, {});
    }

    const n_edges = graph.edges.items.len;
    const route_labels = try a.alloc(?TextBlock, n_edges);
    const start_labels = try a.alloc(?TextBlock, n_edges);
    const end_labels = try a.alloc(?TextBlock, n_edges);
    for (graph.edges.items, 0..) |e, i| {
        route_labels[i] = try measureEdgeField(a, graph, theme, config, e.label);
        start_labels[i] = try measureEdgeField(a, graph, theme, config, e.start_label);
        end_labels[i] = try measureEdgeField(a, graph, theme, config, e.end_label);
    }
    _ = try manual.assignPositionsManual(a, graph, ids.items, &layout_set, &nodes, config, layout_edges.items, theme, route_labels);
    // aspect_fold: no-op without `preferred_aspect_ratio`.
    try sg.applySubgraphNodeLayoutPasses(a, graph, &nodes, config, &anchored_indices, &anchor_info);
    try spacing.applyFlowchartNodeLayoutCleanup(a, graph, &nodes, theme, config);
    try objectives.applyVisualObjectives(a, graph, layout_edges.items, &nodes, theme, &effective, false);
    try sg.applySubgraphDirectionOverrides(a, graph, &nodes, config, &anchored_indices);
    try spacing.enforceTopLevelSubgraphGap(a, graph, &nodes, theme, config);
    try spacing.separateSiblingSubgraphs(a, graph, &nodes, theme, config);
    try spacing.evictNonMemberNodesFromSubgraphs(a, graph, &nodes, theme, config);
    if (graph.kind == .state and graph.subgraphs.items.len > 0) try pushNonMembersOutOfSubgraphs(a, graph, &nodes, theme, config);
    if (graph.kind == .state) try separateStatePseudostateMarkers(a, graph, &nodes, config);
    var subgraphs = try sg.buildSubgraphLayouts(a, graph, &nodes, theme, config);
    sg.applySubgraphAnchors(graph, subgraphs.items, &nodes);
    var edges = try pipeline.buildRoutedEdges(a, .{
        .graph = graph,
        .nodes = &nodes,
        .subgraphs = subgraphs.items,
        .config = config,
        .layout_node_count = ids.items.len,
        .edge_route_labels = route_labels,
        .edge_start_labels = start_labels,
        .edge_end_labels = end_labels,
        .tiny_graph = tiny,
    });
    return finalizeGraphLayout(a, graph, &nodes, &edges, &subgraphs, theme, config);
}

fn measureEdgeField(a: Allocator, graph: *const Graph, theme: *const Theme, config: *const LayoutConfig, field: ?[]const u8) Allocator.Error!?TextBlock {
    const label = field orelse return null;
    if (graph.kind == .flowchart and !util.containsChar(label, '\n') and !util.contains(label, "<br") and util.charCount(label) >= FLOWCHART_EDGE_LABEL_WRAP_TRIGGER_CHARS) {
        var wc = config.*;
        wc.max_label_width_chars = @min(wc.max_label_width_chars, FLOWCHART_EDGE_LABEL_WRAP_MAX_CHARS);
        return try text.measureLabelWithFontSize(a, label, @max(theme.font_size, 16.0), &wc, true, theme.font_family);
    }
    return try text.measureLabel(a, label, theme, config);
}

pub fn resolveEdgeStyle(idx: usize, graph: *const Graph) ir.EdgeStyleOverride {
    var style = graph.edge_style_default orelse ir.EdgeStyleOverride{};
    if (graph.edge_styles.get(idx)) |es| mergeEdgeStyle(&style, &es);
    return style;
}

fn sanitizeStrokeWidth(w: f32) ?f32 {
    return if (std.math.isFinite(w)) @max(w, 0.0) else null;
}

fn mergeEdgeStyle(target: *ir.EdgeStyleOverride, src: *const ir.EdgeStyleOverride) void {
    if (src.stroke) |s| target.stroke = s;
    if (src.stroke_width) |w| if (sanitizeStrokeWidth(w)) |v| {
        target.stroke_width = v;
    };
    if (src.dasharray) |d| target.dasharray = d;
    if (src.label_color) |c| target.label_color = c;
}

pub fn assignPositions(a: Allocator, node_ids: []const []const u8, ranks: *const ranking.Ranks, direction: ir.Direction, config: *const LayoutConfig, nodes: *NodeMap, origin_x: f32, origin_y: f32) Allocator.Error!void {
    var max_rank: usize = 0;
    var it = ranks.valueIterator();
    while (it.next()) |r| max_rank = @max(max_rank, r.*);
    const buckets = try a.alloc(std.ArrayList([]const u8), max_rank + 1);
    for (buckets) |*b| b.* = .empty;
    for (node_ids) |id| {
        const r = ranks.get(id) orelse 0;
        if (r < buckets.len) try buckets[r].append(a, id);
    }
    // Buckets are filled in `node_ids` order already (the sort by that order is a no-op).
    var main_cursor: f32 = 0;
    for (buckets) |b| {
        var cross_cursor: f32 = 0;
        var max_main: f32 = 0;
        for (b.items) |id| if (nodes.get(id)) |n| {
            if (isHorizontal(direction)) {
                n.x = origin_x + main_cursor;
                n.y = origin_y + cross_cursor;
                cross_cursor += n.height + config.node_spacing;
                max_main = @max(max_main, n.width);
            } else {
                n.x = origin_x + cross_cursor;
                n.y = origin_y + main_cursor;
                cross_cursor += n.width + config.node_spacing;
                max_main = @max(max_main, n.height);
            }
        };
        main_cursor += max_main + config.rank_spacing;
    }
}

pub fn boundsWithEdges(nodes: *const NodeMap, subgraphs: []const SubgraphLayout, edges: []const EdgeLayout) [2]f32 {
    var mx: f32 = 0;
    var my: f32 = 0;
    for (nodes.values()) |n| {
        mx = @max(mx, n.x + n.width);
        my = @max(my, n.y + n.height);
    }
    for (subgraphs) |s| {
        const invisible = util.trim(s.label).len == 0 and routing.eqlOpt(s.style.stroke, "none") and routing.eqlOpt(s.style.fill, "none");
        if (invisible) continue;
        mx = @max(mx, s.x + s.width);
        my = @max(my, s.y + s.height);
    }
    for (edges) |e| for (e.points.items) |p| {
        mx = @max(mx, p[0]);
        my = @max(my, p[1]);
    };
    return .{ mx, my };
}

pub fn applyDirectionMirror(direction: ir.Direction, nodes: *NodeMap, edges: []EdgeLayout, subgraphs: []SubgraphLayout) void {
    const m = boundsWithEdges(nodes, subgraphs, &.{});
    if (direction == .right_left) {
        for (nodes.values()) |*n| n.x = m[0] - n.x - n.width;
        for (edges) |*e| {
            for (e.points.items) |*p| p[0] = m[0] - p[0];
            if (e.label_anchor) |*p| p[0] = m[0] - p[0];
        }
        for (subgraphs) |*s| s.x = m[0] - s.x - s.width;
    }
    if (direction == .bottom_top) {
        for (nodes.values()) |*n| n.y = m[1] - n.y - n.height;
        for (edges) |*e| {
            for (e.points.items) |*p| p[1] = m[1] - p[1];
            if (e.label_anchor) |*p| p[1] = m[1] - p[1];
        }
        for (subgraphs) |*s| s.y = m[1] - s.y - s.height;
    }
}

pub fn normalizeLayout(nodes: *NodeMap, edges: []EdgeLayout, subgraphs: []SubgraphLayout) void {
    var min_x: f32 = FMAX;
    var min_y: f32 = FMAX;
    for (nodes.values()) |n| {
        min_x = @min(min_x, n.x);
        min_y = @min(min_y, n.y);
    }
    for (subgraphs) |s| {
        min_x = @min(min_x, s.x);
        min_y = @min(min_y, s.y);
    }
    for (edges) |e| for (e.points.items) |p| {
        min_x = @min(min_x, p[0]);
        min_y = @min(min_y, p[1]);
    };
    if (!std.math.isFinite(min_x) or !std.math.isFinite(min_y) or min_x == FMAX) return;
    const sx = LAYOUT_BOUNDARY_PAD - min_x;
    const sy = LAYOUT_BOUNDARY_PAD - min_y;
    if (@abs(sx) < 1e-3 and @abs(sy) < 1e-3) return;
    for (nodes.values()) |*n| {
        n.x += sx;
        n.y += sy;
    }
    for (edges) |*e| {
        for (e.points.items) |*p| p.* = .{ p[0] + sx, p[1] + sy };
        if (e.label_anchor) |*p| p.* = .{ p[0] + sx, p[1] + sy };
    }
    for (subgraphs) |*s| {
        s.x += sx;
        s.y += sy;
    }
}

pub fn resolveNodeStyle(id: []const u8, graph: *const Graph) ir.NodeStyle {
    var style: ir.NodeStyle = .{};
    if (graph.node_classes.get(id)) |classes| for (classes.items) |cn| {
        if (graph.class_defs.get(cn)) |cs| mergeNodeStyle(&style, &cs);
    };
    if (graph.node_styles.get(id)) |ns| mergeNodeStyle(&style, &ns);
    return style;
}

pub fn mergeNodeStyle(target: *ir.NodeStyle, src: *const ir.NodeStyle) void {
    if (src.fill) |v| target.fill = v;
    if (src.stroke) |v| target.stroke = v;
    if (src.text_color) |v| target.text_color = v;
    if (src.stroke_width) |w| if (sanitizeStrokeWidth(w)) |v| {
        target.stroke_width = v;
    };
    if (src.stroke_dasharray) |v| target.stroke_dasharray = v;
    if (src.line_color) |v| target.line_color = v;
}

fn separateStatePseudostateMarkers(a: Allocator, graph: *const Graph, nodes: *NodeMap, config: *const LayoutConfig) Allocator.Error!void {
    const isMarker = struct {
        fn f(id: []const u8) bool {
            return (util.startsWith(id, "__start_") or util.startsWith(id, "__end_")) and util.endsWith(id, "__");
        }
    }.f;
    var obstacles: std.ArrayList(t.Rect) = .empty;
    for (nodes.values()) |n| if (!n.hidden and !isMarker(n.id)) try obstacles.append(a, .{ n.x, n.y, n.width, n.height });
    if (obstacles.items.len == 0) return;
    const horizontal = isHorizontal(graph.direction);
    const gap = @max(config.node_spacing * 0.4, 8.0);
    for (nodes.values()) |*n| {
        if (!isMarker(n.id) or n.hidden) continue;
        var mx = n.x;
        var my = n.y;
        for (obstacles.items) |o| {
            if (!(mx < o[0] + o[2] and o[0] < mx + n.width and my < o[1] + o[3] and o[1] < my + n.height)) continue;
            if (horizontal) {
                const nx = o[0] + o[2] + gap;
                if (nx > mx) mx = nx;
            } else {
                const ny = o[1] + o[3] + gap;
                if (ny > my) my = ny;
            }
        }
        n.x = mx;
        n.y = my;
    }
}

fn pushNonMembersOutOfSubgraphs(a: Allocator, graph: *const Graph, nodes: *NodeMap, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!void {
    if (graph.subgraphs.items.len == 0) return;
    var members: ranking.StrSet = .empty;
    var sub_ids: ranking.StrSet = .empty;
    for (graph.subgraphs.items) |sub| {
        for (sub.nodes.items) |id| try members.put(a, id, {});
        if (sub.id) |id| try sub_ids.put(a, id, {});
        if (sub.label.len > 0) try sub_ids.put(a, sub.label, {});
    }
    const gap = config.node_spacing * 0.5;
    var bounds: std.ArrayList([4]f32) = .empty;
    for (graph.subgraphs.items) |*sub| {
        var b = [4]f32{ FMAX, FMAX, FMIN, FMIN };
        for (sub.nodes.items) |id| if (nodes.get(id)) |n| includeRect(&b, n.x, n.y, n.width, n.height);
        const lb = try text.measureLabel(a, sub.label, theme, config);
        const p = sg.subgraphPaddingFromLabel(graph, sub, theme, &lb);
        if (b[0] < FMAX) try bounds.append(a, .{ b[0] - p[0], b[1] - p[2], b[2] + p[0], b[3] + p[1] }) else try bounds.append(a, .{ 0, 0, 0, 0 });
    }
    for (nodes.values()) |*n| {
        if (members.contains(n.id) or sub_ids.contains(n.id)) continue;
        for (bounds.items) |b| {
            if (n.x + n.width > b[0] and n.x < b[2] and n.y + n.height > b[1] and n.y < b[3]) {
                n.y = b[3] + gap;
                break;
            }
        }
    }
}

fn shapePaddingFactors(shape: ir.NodeShape) [2]f32 {
    return switch (shape) {
        .stadium => .{ 0.43, 0.5 },
        .subroutine => .{ 0.54, 0.5 },
        .parallelogram => .{ 0.894, 0.5 },
        .parallelogram_alt => .{ 0.904, 0.5 },
        else => .{ 1.0, 1.0 },
    };
}

fn hasDividerLine(label: *const TextBlock) bool {
    for (label.lines) |l| if (util.eql(util.trim(l), "---")) return true;
    return false;
}

pub fn shapeSize(shape: ir.NodeShape, label: *const TextBlock, config: *const LayoutConfig, theme: *const Theme, kind: ir.DiagramKind) [2]f32 {
    const pf = shapePaddingFactors(shape);
    const ks: [2]f32 = switch (kind) {
        .class => .{ if (hasDividerLine(label)) 0.85 else 0.4, 0.8 },
        .er => .{ 1.05, 1.15 },
        .kanban => .{ 2.3, 0.67 },
        .requirement => .{ 0.1, 1.0 },
        .block => .{ 0.5, 0.35 },
        else => .{ 1.0, 1.0 },
    };
    var pad_x = config.node_padding_x * pf[0] * ks[0];
    var pad_y = config.node_padding_y * pf[1] * ks[1];
    if (kind == .state) {
        pad_x = @max(theme.font_size * STATE_PAD_X_SCALE, label.width * STATE_PAD_X_LABEL_RATIO);
        pad_y = @max(theme.font_size * STATE_PAD_Y_SCALE, label.height * STATE_PAD_Y_LABEL_RATIO);
    }
    const bw = label.width + pad_x * 2.0;
    const bh = label.height + pad_y * 2.0;
    var w = bw;
    var h = bh;
    switch (shape) {
        .diamond => {
            const s = @max(bw, bh) * DIAMOND_SCALE;
            w = s;
            h = s;
        },
        .fork_join => {
            w = @max(w, FORK_JOIN_MIN_WIDTH);
            h = @max(config.node_padding_y * FORK_JOIN_HEIGHT_SCALE, FORK_JOIN_MIN_HEIGHT);
        },
        .circle, .double_circle => {
            const s = if (label.isEmptyLabel()) @max(config.node_padding_y * CIRCLE_EMPTY_HEIGHT_SCALE, CIRCLE_EMPTY_MIN_SIZE) else @max(w, h);
            w = s;
            h = s;
        },
        .round_rect => {
            w *= ROUND_RECT_WIDTH_SCALE;
            h *= ROUND_RECT_HEIGHT_SCALE;
        },
        .cylinder => {
            w *= CYLINDER_SCALE;
            h *= CYLINDER_SCALE;
        },
        .hexagon => {
            w *= HEXAGON_WIDTH_SCALE;
            h *= HEXAGON_HEIGHT_SCALE;
        },
        .trapezoid, .trapezoid_alt, .asymmetric => w *= TRAPEZOID_WIDTH_SCALE,
        else => {},
    }
    if (kind == .class) h = @max(h, theme.font_size * CLASS_MIN_HEIGHT_SCALE);
    if (kind == .requirement) w = @max(w, theme.font_size * 9.5);
    if (kind == .kanban) {
        w = @max(w, theme.font_size * 11.0);
        h = @max(h, theme.font_size * 2.6);
    }
    return .{ w, h };
}

fn finalizeGraphLayout(a: Allocator, graph: *const Graph, nodes: *NodeMap, edges: *std.ArrayList(EdgeLayout), subgraphs: *std.ArrayList(SubgraphLayout), theme: *const Theme, config: *const LayoutConfig) Allocator.Error!Layout {
    if (graph.direction == .right_left or graph.direction == .bottom_top) applyDirectionMirror(graph.direction, nodes, edges.items, subgraphs.items);
    normalizeLayout(nodes, edges.items, subgraphs.items);
    var notes: std.ArrayList(t.StateNoteLayout) = .empty;
    if (graph.kind == .state and graph.state_notes.items.len > 0) {
        const px = theme.font_size * STATE_NOTE_PAD_X_SCALE;
        const py = theme.font_size * STATE_NOTE_PAD_Y_SCALE;
        const gap = @max(theme.font_size * STATE_NOTE_GAP_SCALE, STATE_NOTE_GAP_MIN);
        for (graph.state_notes.items) |note| {
            const target = nodes.get(note.target) orelse continue;
            const label = try text.measureLabel(a, note.label, theme, config);
            const w = label.width + px * 2.0;
            const h = label.height + py * 2.0;
            try notes.append(a, .{
                .x = switch (note.position) {
                    .left_of => target.x - gap - w,
                    .right_of => target.x + target.width + gap,
                },
                .y = target.y + target.height / 2.0 - h / 2.0,
                .width = w,
                .height = h,
                .label = label,
                .position = note.position,
                .target = note.target,
            });
        }
    }
    var m = boundsWithEdges(nodes, subgraphs.items, edges.items);
    for (notes.items) |n| {
        m[0] = @max(m[0], n.x + n.width);
        m[1] = @max(m[1], n.y + n.height);
    }
    return .{
        .kind = graph.kind,
        .nodes = nodes.*,
        .edges = edges.*,
        .subgraphs = subgraphs.*,
        .width = m[0] + LAYOUT_BOUNDARY_PAD,
        .height = m[1] + LAYOUT_BOUNDARY_PAD,
        .diagram = .{ .graph = .{ .state_notes = notes } },
    };
}
