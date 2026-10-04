//! `layout/flowchart/objectives.rs`: whitespace compaction, label-aware edge
//! span relaxation, aspect rebalancing and node-overlap resolution.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../../ir.zig");
const util = @import("../../util.zig");
const Theme = @import("../../theme.zig").Theme;
const LayoutConfig = @import("../../config.zig").LayoutConfig;
const text = @import("../../text.zig");
const t = @import("../types.zig");
const L = @import("../layout.zig");
const ranking = @import("../ranking.zig");
const sg = @import("../subgraphs.zig");
const Graph = ir.Graph;
const Edge = ir.Edge;
const NodeMap = t.NodeMap;
const NodeLayout = t.NodeLayout;
const StrSet = ranking.StrSet;
const isHorizontal = L.isHorizontal;
const FMAX = std.math.floatMax(f32);
const FMIN = -std.math.floatMax(f32);

pub fn applyVisualObjectives(a: Allocator, graph: *const Graph, layout_edges: []const Edge, nodes: *NodeMap, theme: *const Theme, config: *const LayoutConfig, skip_compaction: bool) Allocator.Error!void {
    if (!config.flowchart.objective.enabled) return;
    if (!skip_compaction) try compactLargeFlowchartWhitespace(a, graph, nodes, config);
    try relaxEdgeSpanConstraints(a, graph, layout_edges, nodes, theme, config);
    try rebalanceTopLevelSubgraphsAspect(a, graph, nodes, config);
    const enabled = switch (graph.kind) {
        .class => true,
        .flowchart, .state, .er, .requirement => try hasVisibleNodeOverlap(a, nodes),
        else => false,
    };
    if (enabled) try resolveNodeOverlaps(a, graph, nodes, config);
}

fn mainCenter(n: *const NodeLayout, h: bool) f32 {
    return if (h) n.x + n.width / 2.0 else n.y + n.height / 2.0;
}
fn mainHalf(n: *const NodeLayout, h: bool) f32 {
    return if (h) n.width / 2.0 else n.height / 2.0;
}
fn shiftMain(n: *NodeLayout, h: bool, d: f32) void {
    if (h) n.x += d else n.y += d;
}
fn shiftCross(n: *NodeLayout, h: bool, d: f32) void {
    if (h) n.y += d else n.x += d;
}

pub fn compactLargeFlowchartWhitespace(a: Allocator, graph: *const Graph, nodes: *NodeMap, config: *const LayoutConfig) Allocator.Error!void {
    if (graph.kind != .flowchart or graph.subgraphs.items.len != 0) return;
    var visible: std.ArrayList([]const u8) = .empty;
    for (nodes.values()) |n| if (!n.hidden and n.anchor_subgraph == null) try visible.append(a, n.id);
    const node_count = visible.items.len;
    if (node_count < 16) return;
    var edge_count: usize = 0;
    for (graph.edges.items) |e| {
        if (nodes.contains(e.from) and nodes.contains(e.to)) edge_count += 1;
    }
    if (edge_count < 24) return;
    if (@as(f32, @floatFromInt(edge_count)) / @as(f32, @floatFromInt(node_count)) < 1.2) return;
    const h = isHorizontal(graph.direction);
    var min_main: f32 = FMAX;
    var max_main: f32 = FMIN;
    var min_cross: f32 = FMAX;
    var max_cross: f32 = FMIN;
    for (nodes.values()) |n| {
        if (n.hidden or n.anchor_subgraph != null) continue;
        min_main = @min(min_main, if (h) n.x else n.y);
        max_main = @max(max_main, if (h) n.x + n.width else n.y + n.height);
        min_cross = @min(min_cross, if (h) n.y else n.x);
        max_cross = @max(max_cross, if (h) n.y + n.height else n.x + n.width);
    }
    if (min_main == FMAX or min_cross == FMAX) return;
    const aspect = @max(max_main - min_main, 1.0) / @max(max_cross - min_cross, 1.0);
    if (aspect <= @max(config.flowchart.objective.max_aspect_ratio, 1.0)) return;
    const band_size = @max(config.node_spacing * 1.25, 24.0);
    const desired_gap = @max(config.node_spacing * 0.72, 10.0);
    const Ent = struct { id: []const u8, start: f32, end: f32 };
    var bands: std.AutoArrayHashMapUnmanaged(i32, std.ArrayList(Ent)) = .empty;
    for (visible.items) |id| {
        const n = nodes.get(id) orelse continue;
        const cc = if (h) n.y + n.height * 0.5 else n.x + n.width * 0.5;
        const band: i32 = @intFromFloat(@round(cc / band_size));
        const gop = try bands.getOrPut(a, band);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, .{ .id = id, .start = if (h) n.x else n.y, .end = if (h) n.x + n.width else n.y + n.height });
    }
    for (bands.values()) |*entries| {
        if (entries.items.len < 2) continue;
        std.mem.sort(Ent, entries.items, {}, struct {
            fn lt(_: void, x: Ent, y: Ent) bool {
                return x.start < y.start;
            }
        }.lt);
        var cum: f32 = 0;
        var prev_end: ?f32 = null;
        for (entries.items) |e| {
            const adj = e.start - cum;
            if (prev_end) |p| {
                const gap = adj - p;
                if (gap > desired_gap) cum += gap - desired_gap;
            }
            if (cum > 0.0) if (nodes.get(e.id)) |n| shiftMain(n, h, -cum);
            prev_end = e.end - cum;
        }
    }
}

const Groups = struct {
    node_to_group: ranking.Ranks,
    group_nodes: std.AutoHashMapUnmanaged(usize, []const []const u8),
};

fn collectGroups(a: Allocator, graph: *const Graph) Allocator.Error!?Groups {
    if (graph.kind != .flowchart or graph.subgraphs.items.len == 0) return null;
    var g: Groups = .{ .node_to_group = .empty, .group_nodes = .empty };
    for (try sg.topLevelSubgraphIndices(a, graph)) |idx| {
        const sub = &graph.subgraphs.items[idx];
        if (sg.isRegionSubgraph(sub)) continue;
        for (sub.nodes.items) |id| {
            const gop = try g.node_to_group.getOrPut(a, id);
            if (gop.found_existing and gop.value_ptr.* != idx) return null;
            gop.value_ptr.* = idx;
        }
        if (sub.nodes.items.len > 0) try g.group_nodes.put(a, idx, sub.nodes.items);
    }
    if (g.group_nodes.count() == 0) return null;
    return g;
}

fn measureCached(a: Allocator, cache: *std.StringHashMapUnmanaged(t.TextBlock), label: []const u8, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!t.TextBlock {
    if (cache.get(label)) |b| return b;
    const b = try text.measureLabel(a, label, theme, config);
    try cache.put(a, label, b);
    return b;
}

fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (util.trim(v).len > 0) v else null;
}

fn relaxEdgeSpanConstraints(a: Allocator, graph: *const Graph, edges: []const Edge, nodes: *NodeMap, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!void {
    if (edges.len == 0) return;
    switch (graph.kind) {
        .class, .flowchart, .state, .er, .requirement => {},
        else => return,
    }
    const h = isHorizontal(graph.direction);
    const obj = config.flowchart.objective;
    const step_limit = @max(config.rank_spacing + config.node_spacing, L.EDGE_RELAX_STEP_MIN);
    var cache: std.StringHashMapUnmanaged(t.TextBlock) = .empty;
    const groups = try collectGroups(a, graph);
    for (0..@max(obj.edge_relax_passes, 1)) |_| {
        var changed = false;
        for (edges) |e| {
            const from = nodes.get(e.from) orelse continue;
            const to = nodes.get(e.to) orelse continue;
            if (from.hidden or to.hidden) continue;
            const fm = mainCenter(from, h);
            const tm = mainCenter(to, h);
            const fh = mainHalf(from, h);
            const th = mainHalf(to, h);
            const main_delta = tm - fm;
            const current_gap = if (main_delta >= 0.0) (tm - th) - (fm + fh) else (fm - fh) - (tm + th);
            const center = nonEmpty(e.label);
            const start = nonEmpty(e.start_label);
            const end = nonEmpty(e.end_label);
            if (graph.kind == .flowchart and e.style == .dotted) continue;
            if (center == null and start == null and end == null) continue;
            var required = @max(config.node_spacing * obj.edge_gap_floor_ratio, 8.0);
            if (center) |l| {
                const b = try measureCached(a, &cache, l, theme, config);
                required += (if (h) b.width else b.height) * obj.edge_label_weight;
                required += theme.font_size * L.EDGE_LABEL_PAD_SCALE;
            }
            if (start) |l| {
                const b = try measureCached(a, &cache, l, theme, config);
                required += (if (h) b.width else b.height) * obj.endpoint_label_weight;
                required += theme.font_size * L.ENDPOINT_LABEL_PAD_SCALE;
            }
            if (end) |l| {
                const b = try measureCached(a, &cache, l, theme, config);
                required += (if (h) b.width else b.height) * obj.endpoint_label_weight;
                required += theme.font_size * L.ENDPOINT_LABEL_PAD_SCALE;
            }
            if (start != null and end != null) required += theme.font_size * L.DUAL_ENDPOINT_EXTRA_PAD_SCALE;
            required = @min(required, (config.rank_spacing + config.node_spacing) * L.MAX_MAIN_GAP_FACTOR);
            if (current_gap + L.EDGE_RELAX_GAP_TOLERANCE < required) {
                const delta = @min(required - current_gap, step_limit);
                if (groups) |*g| shift: {
                    const fg = g.node_to_group.get(e.from) orelse break :shift;
                    const tg = g.node_to_group.get(e.to) orelse break :shift;
                    if (fg == tg) break :shift;
                    const ahead = if (main_delta >= 0.0) tg else fg;
                    const ids = g.group_nodes.get(ahead) orelse break :shift;
                    for (ids) |id| if (nodes.get(id)) |n| shiftMain(n, h, delta);
                    changed = true;
                    continue;
                }
                const ahead_id = if (main_delta >= 0.0) e.to else e.from;
                if (nodes.get(ahead_id)) |n| {
                    shiftMain(n, h, delta);
                    changed = true;
                }
            }
        }
        if (!changed) break;
    }
}

fn resolveNodeOverlaps(a: Allocator, graph: *const Graph, nodes: *NodeMap, config: *const LayoutConfig) Allocator.Error!void {
    const h = isHorizontal(graph.direction);
    const min_gap = @max(config.node_spacing * L.OVERLAP_MIN_GAP_RATIO, L.OVERLAP_MIN_GAP_FLOOR);
    const groups = try collectGroups(a, graph);
    var ids: std.ArrayList([]const u8) = .empty;
    for (nodes.values()) |n| if (!n.hidden) try ids.append(a, n.id);
    if (ids.items.len < 2) return;
    std.mem.sort([]const u8, ids.items, graph, struct {
        fn lt(g: *const Graph, x: []const u8, y: []const u8) bool {
            return g.orderOf(x) < g.orderOf(y);
        }
    }.lt);
    for (0..L.OVERLAP_RESOLVE_PASSES) |_| {
        var moved = false;
        for (0..ids.items.len) |i| {
            for (i + 1..ids.items.len) |j| {
                const id_a = ids.items[i];
                const id_b = ids.items[j];
                const na = nodes.get(id_a) orelse continue;
                const nb = nodes.get(id_b) orelse continue;
                const ox = @min(na.x + na.width, nb.x + nb.width) - @max(na.x, nb.x);
                const oy = @min(na.y + na.height, nb.y + nb.height) - @max(na.y, nb.y);
                if (ox <= 0.0 or oy <= 0.0) continue;
                const ca = if (h) na.y + na.height / 2.0 else na.x + na.width / 2.0;
                const cb = if (h) nb.y + nb.height / 2.0 else nb.x + nb.width / 2.0;
                var sign: f32 = if (cb >= ca) 1.0 else -1.0;
                if (@abs(cb - ca) < L.OVERLAP_CENTER_THRESHOLD) sign = if (graph.orderOf(id_b) >= graph.orderOf(id_a)) 1.0 else -1.0;
                const delta = if (h) oy + min_gap else ox + min_gap;
                if (groups) |*g| shift: {
                    const sgp = g.node_to_group.get(id_a) orelse break :shift;
                    const tgp = g.node_to_group.get(id_b) orelse break :shift;
                    if (sgp == tgp) break :shift;
                    const gn = g.group_nodes.get(tgp) orelse break :shift;
                    for (gn) |id| if (nodes.get(id)) |n| shiftCross(n, h, sign * delta);
                    moved = true;
                    continue;
                }
                shiftCross(nb, h, sign * delta);
                moved = true;
            }
        }
        if (!moved) break;
    }
}

fn hasVisibleNodeOverlap(a: Allocator, nodes: *const NodeMap) Allocator.Error!bool {
    var vis: std.ArrayList(*const NodeLayout) = .empty;
    for (nodes.values()) |*n| if (!n.hidden) try vis.append(a, n);
    if (vis.items.len < 2) return false;
    std.mem.sort(*const NodeLayout, vis.items, {}, struct {
        fn lt(_: void, x: *const NodeLayout, y: *const NodeLayout) bool {
            return x.x < y.x;
        }
    }.lt);
    for (vis.items, 0..) |na, i| {
        for (vis.items[i + 1 ..]) |nb| {
            if (nb.x >= na.x + na.width) break;
            const ox = @min(na.x + na.width, nb.x + nb.width) - @max(na.x, nb.x);
            const oy = @min(na.y + na.height, nb.y + nb.height) - @max(na.y, nb.y);
            if (ox > 0.0 and oy > 0.0) return true;
        }
    }
    return false;
}

const VisualGroup = struct { sub_idx: usize, nodes: []const []const u8, min_main: f32, max_main: f32, min_cross: f32, max_cross: f32 };

fn rebalanceTopLevelSubgraphsAspect(a: Allocator, graph: *const Graph, nodes: *NodeMap, config: *const LayoutConfig) Allocator.Error!void {
    if (graph.kind != .flowchart or graph.subgraphs.items.len < 2 or graph.nodes.len() < 120) return;
    const h = isHorizontal(graph.direction);
    const groups = try collectTopLevelVisualGroups(a, graph, nodes, h);
    const obj = config.flowchart.objective;
    if (groups.len < obj.wrap_min_groups) return;
    var min_main: f32 = FMAX;
    var max_main: f32 = FMIN;
    var min_cross: f32 = FMAX;
    var max_cross: f32 = FMIN;
    for (groups) |g| {
        min_main = @min(min_main, g.min_main);
        max_main = @max(max_main, g.max_main);
        min_cross = @min(min_cross, g.min_cross);
        max_cross = @max(max_cross, g.max_cross);
    }
    if (min_main == FMAX or min_cross == FMAX) return;
    const target_aspect = @max(obj.max_aspect_ratio, 1.0);
    const aspect = @max(max_main - min_main, 1.0) / @max(max_cross - min_cross, 1.0);
    if (aspect <= target_aspect) return;
    const raw: usize = if (try chainLike(a, graph, groups))
        @intFromFloat(@ceil(aspect / target_aspect))
    else
        @intFromFloat(@ceil(@sqrt(aspect / target_aspect)));
    const row_count = std.math.clamp(raw, 2, groups.len);
    const base = groups.len / row_count;
    const extra = groups.len % row_count;
    const gap_main = @max(config.node_spacing, 12.0) * @max(obj.wrap_main_gap_scale, 0.1);
    const gap_cross = @max(config.rank_spacing, 12.0) * @max(obj.wrap_cross_gap_scale, 0.1);
    var row_start: usize = 0;
    var cursor_cross = min_cross;
    for (0..row_count) |row| {
        const len = base + @intFromBool(row < extra);
        if (len == 0) continue;
        const row_end = row_start + len;
        var cursor_main = min_main;
        var span: f32 = 0;
        for (groups[row_start..row_end]) |*g| {
            const dm = cursor_main - g.min_main;
            const dc = cursor_cross - g.min_cross;
            for (g.nodes) |id| if (nodes.get(id)) |n| {
                shiftMain(n, h, dm);
                shiftCross(n, h, dc);
            };
            g.min_main += dm;
            g.max_main += dm;
            g.min_cross += dc;
            g.max_cross += dc;
            cursor_main = g.max_main + gap_main;
            span = @max(span, g.max_cross - g.min_cross);
        }
        cursor_cross += span + gap_cross;
        row_start = row_end;
    }
}

fn collectTopLevelVisualGroups(a: Allocator, graph: *const Graph, nodes: *const NodeMap, h: bool) Allocator.Error![]VisualGroup {
    const top = try sg.topLevelSubgraphIndices(a, graph);
    if (top.len < 2) return &.{};
    var seen: StrSet = .empty;
    for (top) |idx| for (graph.subgraphs.items[idx].nodes.items) |id| {
        if ((try seen.getOrPut(a, id)).found_existing) return &.{};
    };
    var groups: std.ArrayList(VisualGroup) = .empty;
    for (top) |idx| {
        const sub = &graph.subgraphs.items[idx];
        if (sg.isRegionSubgraph(sub)) continue;
        var ids: std.ArrayList([]const u8) = .empty;
        var g: VisualGroup = .{ .sub_idx = idx, .nodes = &.{}, .min_main = FMAX, .max_main = FMIN, .min_cross = FMAX, .max_cross = FMIN };
        for (sub.nodes.items) |id| {
            const n = nodes.get(id) orelse continue;
            if (n.hidden) continue;
            try ids.append(a, id);
            g.min_main = @min(g.min_main, if (h) n.x else n.y);
            g.max_main = @max(g.max_main, if (h) n.x + n.width else n.y + n.height);
            g.min_cross = @min(g.min_cross, if (h) n.y else n.x);
            g.max_cross = @max(g.max_cross, if (h) n.y + n.height else n.x + n.width);
        }
        if (ids.items.len == 0) continue;
        g.nodes = ids.items;
        try groups.append(a, g);
    }
    std.mem.sort(VisualGroup, groups.items, {}, struct {
        fn lt(_: void, x: VisualGroup, y: VisualGroup) bool {
            return x.min_main < y.min_main;
        }
    }.lt);
    return groups.items;
}

fn chainLike(a: Allocator, graph: *const Graph, groups: []const VisualGroup) Allocator.Error!bool {
    if (groups.len < 3) return false;
    var n2s: ranking.Ranks = .empty;
    for (groups) |g| for (g.nodes) |id| try n2s.put(a, id, g.sub_idx);
    var indeg: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    var outdeg: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    var cross: usize = 0;
    for (graph.edges.items) |e| {
        const f = n2s.get(e.from) orelse continue;
        const tt = n2s.get(e.to) orelse continue;
        if (f == tt) continue;
        cross += 1;
        const o = try outdeg.getOrPut(a, f);
        o.value_ptr.* = (if (o.found_existing) o.value_ptr.* else 0) + 1;
        const i = try indeg.getOrPut(a, tt);
        i.value_ptr.* = (if (i.found_existing) i.value_ptr.* else 0) + 1;
    }
    if (cross < groups.len -| 1) return false;
    for (groups) |g| {
        if ((indeg.get(g.sub_idx) orelse 0) > 1) return false;
        if ((outdeg.get(g.sub_idx) orelse 0) > 1) return false;
    }
    return true;
}
