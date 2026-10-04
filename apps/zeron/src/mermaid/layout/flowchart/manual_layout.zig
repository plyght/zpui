//! `layout/flowchart/manual_layout.rs` (+ the parts of `analysis.rs` it
//! reads): rank assignment, ordering and cross-axis placement.
//! Label-dummy ranks only apply to diagram kinds zeron does not lay out
//! through this path, so they are omitted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../../ir.zig");
const util = @import("../../util.zig");
const Theme = @import("../../theme.zig").Theme;
const LayoutConfig = @import("../../config.zig").LayoutConfig;
const t = @import("../types.zig");
const L = @import("../layout.zig");
const ranking = @import("../ranking.zig");
const Graph = ir.Graph;
const Edge = ir.Edge;
const NodeMap = t.NodeMap;
const TextBlock = t.TextBlock;
const Ranks = ranking.Ranks;
const StrSet = ranking.StrSet;
const isHorizontal = L.isHorizontal;

const EDGE_AWARE_CENTER_PULL_LIMIT_RATIO: f32 = 0.28;
const EDGE_AWARE_CENTER_PULL_BLEND: f32 = 0.35;
const FLOWCHART_LABEL_MAIN_GAP_PAD_RATIO: f32 = 0.35;
const FLOWCHART_LABEL_MAIN_GAP_MAX_SCALE: f32 = 3.0;

fn medianCenter(values: []f32) ?f32 {
    if (values.len == 0) return null;
    std.mem.sort(f32, values, {}, std.sort.asc(f32));
    const mid = values.len / 2;
    return if (values.len % 2 == 1) values[mid] else (values[mid - 1] + values[mid]) * 0.5;
}

const CW = struct { c: f32, w: f32 };

fn weightedMedianCenter(values: []CW) ?f32 {
    if (values.len == 0) return null;
    std.mem.sort(CW, values, {}, struct {
        fn lt(_: void, x: CW, y: CW) bool {
            return x.c < y.c;
        }
    }.lt);
    var total: f32 = 0;
    for (values) |v| total += @max(v.w, 0.0);
    if (total <= std.math.floatEps(f32)) return values[values.len / 2].c;
    const threshold = total * 0.5;
    var cumulative: f32 = 0;
    for (values, 0..) |v, idx| {
        cumulative += @max(v.w, 0.0);
        if (@abs(cumulative - threshold) <= std.math.floatEps(f32)) {
            for (values[idx + 1 ..]) |n| if (n.w > 0.0) return (v.c + n.c) * 0.5;
            return v.c;
        }
        if (cumulative > threshold) return v.c;
    }
    return values[values.len - 1].c;
}

fn boundedEdgeAwareDesiredCenter(unweighted: f32, weighted: ?f32, current: f32, node_spacing: f32) f32 {
    const w = weighted orelse return unweighted;
    const max_pull = @max(node_spacing * EDGE_AWARE_CENTER_PULL_LIMIT_RATIO, 4.0);
    const pull = std.math.clamp(w - unweighted, -max_pull, max_pull);
    const target = unweighted + pull * EDGE_AWARE_CENTER_PULL_BLEND;
    return target * 0.85 + current * 0.15;
}

/// The two facts of `FlowchartRelationshipAnalysis` the placement reads.
const Analysis = struct {
    degree: Ranks = .empty,
    label_area: std.StringHashMapUnmanaged(f32) = .empty,
    pair_weight: std.StringHashMapUnmanaged(f32) = .empty,

    fn pairKey(a: Allocator, from: []const u8, to: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(a, "{s}\x00{s}", .{ from, to });
    }

    fn analyze(a: Allocator, graph: *const Graph, node_ids: []const []const u8, edges: []const Edge, labels: []const ?TextBlock, ranks: *const Ranks) Allocator.Error!?Analysis {
        if (graph.kind != .flowchart or node_ids.len == 0) return null;
        var node_set: StrSet = .empty;
        for (node_ids) |id| try node_set.put(a, id, {});
        var filtered: std.ArrayList(Edge) = .empty;
        for (edges) |e| if (node_set.contains(e.from) and node_set.contains(e.to)) try filtered.append(a, e);
        const comps = try ranking.stronglyConnectedComponents(a, node_ids, filtered.items);
        var comp_of: Ranks = .empty;
        for (comps, 0..) |c, ci| for (c) |id| try comp_of.put(a, id, ci);
        // memberships
        var member: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
        for (graph.subgraphs.items, 0..) |sub, si| for (sub.nodes.items) |id| {
            const gop = try member.getOrPut(a, id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            if (std.mem.indexOfScalar(usize, gop.value_ptr.items, si) == null) try gop.value_ptr.append(a, si);
        };
        var an: Analysis = .{};
        for (node_ids) |id| {
            try an.degree.put(a, id, 0);
            try an.label_area.put(a, id, 0);
        }
        for (edges, 0..) |e, idx| {
            if (!node_set.contains(e.from) or !node_set.contains(e.to)) continue;
            const fr = ranks.get(e.from) orelse 0;
            const tr = ranks.get(e.to) orelse 0;
            const fc = comp_of.get(e.from);
            const tc = comp_of.get(e.to);
            const is_cycle = util.eql(e.from, e.to) or (fc != null and tc != null and fc.? == tc.?);
            const is_back = tr <= fr;
            const fs = member.get(e.from);
            const ts = member.get(e.to);
            const crosses = blk: {
                if (fs == null and ts == null) break :blk false;
                if (fs == null or ts == null) break :blk true;
                break :blk !std.mem.eql(usize, fs.?.items, ts.?.items);
            };
            const has_center = if (e.label) |l| util.trim(l).len > 0 else false;
            const has_end = (if (e.start_label) |l| util.trim(l).len > 0 else false) or (if (e.end_label) |l| util.trim(l).len > 0 else false);
            const area: f32 = if (idx < labels.len) (if (labels[idx]) |l| l.width * l.height else 0) else 0;
            var chars: usize = 0;
            if (e.label) |l| chars += util.charCount(l);
            if (e.start_label) |l| chars += util.charCount(l);
            if (e.end_label) |l| chars += util.charCount(l);
            const style_w: f32 = switch (e.style) {
                .dotted => 0.72,
                .thick => 1.25,
                .solid => 1.0,
            };
            const label_w = @min(@sqrt(area) / 110.0, 0.9) + @min(@as(f32, @floatFromInt(chars)) / 36.0, 0.55) +
                @as(f32, if (has_center) 0.22 else 0.0) + @as(f32, if (has_end) 0.18 else 0.0);
            const struct_w = @as(f32, if (crosses) 0.35 else 0.0) + @as(f32, if (is_cycle) 0.18 else 0.0) + @as(f32, if (is_back) 0.16 else 0.0);
            const weight = std.math.clamp(style_w + label_w + struct_w, 0.45, 3.25);
            if (an.degree.getPtr(e.from)) |d| d.* += 1;
            if (an.label_area.getPtr(e.from)) |x| x.* += area;
            if (an.degree.getPtr(e.to)) |d| d.* += 1;
            if (an.label_area.getPtr(e.to)) |x| x.* += area;
            const gop = try an.pair_weight.getOrPut(a, try pairKey(a, e.from, e.to));
            gop.value_ptr.* = if (gop.found_existing) @max(gop.value_ptr.*, weight) else weight;
        }
        return an;
    }

    fn edgeWeightBetween(an: *const Analysis, a: Allocator, from: []const u8, to: []const u8) Allocator.Error!f32 {
        return an.pair_weight.get(try pairKey(a, from, to)) orelse 1.0;
    }

    fn extraCrossPadding(an: *const Analysis, id: []const u8, config: *const LayoutConfig) f32 {
        const degree = an.degree.get(id) orelse return 0;
        if (degree <= 3) return 0;
        const area = an.label_area.get(id) orelse 0;
        const fanout = @min(@as(f32, @floatFromInt(degree - 3)) * config.node_spacing * 0.06, config.node_spacing * 0.24);
        const label_pad = @min(@sqrt(area) * 0.04, config.node_spacing * 0.12);
        return @min(@min(fanout + label_pad, config.node_spacing * 0.32), 24.0);
    }
};

fn labelMainGapBudgets(a: Allocator, graph: *const Graph, edges: []const Edge, labels: []const ?TextBlock, ranks: *const Ranks, config: *const LayoutConfig) Allocator.Error!std.AutoHashMapUnmanaged(usize, f32) {
    var budgets: std.AutoHashMapUnmanaged(usize, f32) = .empty;
    if (graph.kind != .flowchart) return budgets;
    const horizontal = isHorizontal(graph.direction);
    const pad = L.edgeLabelPadding(graph.kind);
    var counts: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    for (edges, 0..) |e, idx| {
        const label = (if (idx < labels.len) labels[idx] else null) orelse continue;
        if (label.width <= 0.0 or label.height <= 0.0) continue;
        const fr = ranks.get(e.from) orelse continue;
        const tr = ranks.get(e.to) orelse continue;
        const lo = @min(fr, tr);
        const hi = @max(fr, tr);
        if (hi <= lo) continue;
        const gap_after = lo + (hi - lo - 1) / 2;
        const main = if (horizontal) label.width + 2.0 * pad[0] else label.height + 2.0 * pad[1];
        const cross = if (horizontal) label.height + 2.0 * pad[1] else label.width + 2.0 * pad[0];
        const sgop = try counts.getOrPut(a, gap_after);
        if (!sgop.found_existing) sgop.value_ptr.* = 0;
        const stacked = @as(f32, @floatFromInt(sgop.value_ptr.*)) * cross * 0.35;
        sgop.value_ptr.* += 1;
        const desired = @max(@min(main + config.node_spacing * FLOWCHART_LABEL_MAIN_GAP_PAD_RATIO + stacked, config.rank_spacing * FLOWCHART_LABEL_MAIN_GAP_MAX_SCALE), config.rank_spacing);
        const extra = @max(desired - config.rank_spacing, 0.0);
        const gop = try budgets.getOrPut(a, gap_after);
        gop.value_ptr.* = if (gop.found_existing) @max(gop.value_ptr.*, extra) else extra;
    }
    return budgets;
}

fn buildOrderingEdges(a: Allocator, edges: []const Edge, ranks: *const Ranks, rank_nodes: [](std.ArrayList([]const u8)), order_map: *Ranks, dummy_counter: *usize) Allocator.Error![]const Edge {
    var out: std.ArrayList(Edge) = .empty;
    for (edges) |e| {
        const fr = ranks.get(e.from) orelse continue;
        const tr = ranks.get(e.to) orelse continue;
        if (tr <= fr or tr - fr <= 1) {
            try out.append(a, e);
            continue;
        }
        const span = tr - fr;
        var prev = e.from;
        for (1..span) |step| {
            const cur_rank = fr + step;
            const id = try std.fmt.allocPrint(a, "__dummy_{d}__", .{dummy_counter.*});
            dummy_counter.* += 1;
            try order_map.put(a, id, order_map.count());
            if (cur_rank < rank_nodes.len) try rank_nodes[cur_rank].append(a, id);
            try out.append(a, .{ .from = prev, .to = id, .directed = true });
            prev = id;
        }
        try out.append(a, .{ .from = prev, .to = e.to, .directed = true });
    }
    return out.items;
}

pub const ManualLayoutRanks = struct { rank_nodes: []std.ArrayList([]const u8) };

const Adj = ranking.Adj;
const WAdj = std.StringHashMapUnmanaged(std.ArrayList(struct { []const u8, f32 }));

pub fn assignPositionsManual(
    a: Allocator,
    graph: *const Graph,
    layout_node_ids: []const []const u8,
    layout_set: *const StrSet,
    nodes: *NodeMap,
    config: *const LayoutConfig,
    layout_edges_in: []const Edge,
    theme: *const Theme,
    pre_measured: []const ?TextBlock,
) Allocator.Error!ManualLayoutRanks {
    _ = theme;
    var labels: std.ArrayList(?TextBlock) = .empty;
    var layout_edges: std.ArrayList(Edge) = .empty;
    for (layout_edges_in, 0..) |e, i| if (layout_set.contains(e.from) and layout_set.contains(e.to)) {
        try labels.append(a, if (i < pre_measured.len) pre_measured[i] else null);
        try layout_edges.append(a, e);
    };
    const rank_edges = try ranking.rankEdgesForManualLayout(a, graph, layout_node_ids, layout_edges.items);
    var ranks = try ranking.computeRanksSubset(a, layout_node_ids, rank_edges, &graph.node_order);
    const analysis = try Analysis.analyze(a, graph, layout_node_ids, layout_edges.items, labels.items, &ranks);
    if (graph.kind == .class) {
        var hier: StrSet = .empty;
        for (layout_edges.items) |e| if (e.arrow_start_kind == .open_triangle or e.arrow_end_kind == .open_triangle) {
            try hier.put(a, e.from, {});
            try hier.put(a, e.to, {});
        };
        if (hier.count() > 0) {
            var min_h: ?usize = null;
            var hit = hier.keyIterator();
            while (hit.next()) |k| if (ranks.get(k.*)) |r| {
                min_h = if (min_h) |m| @min(m, r) else r;
            };
            const min_hier = min_h orelse 0;
            const Upd = struct { id: []const u8, r: usize };
            var pending: std.ArrayList(Upd) = .empty;
            for (layout_node_ids) |id| {
                if (hier.contains(id)) continue;
                var sum: f32 = 0;
                var count: usize = 0;
                for (layout_edges.items) |e| {
                    if (util.eql(e.from, id)) {
                        if (ranks.get(e.to)) |r| {
                            sum += @floatFromInt(r);
                            count += 1;
                        }
                    } else if (util.eql(e.to, id)) {
                        if (ranks.get(e.from)) |r| {
                            sum += @floatFromInt(r);
                            count += 1;
                        }
                    }
                }
                if (count == 0) continue;
                const avg: usize = @intFromFloat(@max(@round(sum / @as(f32, @floatFromInt(count))), 0.0));
                const target = @max(avg, min_hier + 1);
                if (target > (ranks.get(id) orelse 0)) try pending.append(a, .{ .id = id, .r = target });
            }
            for (pending.items) |u| try ranks.put(a, u.id, u.r);
        }
    }
    var max_rank: usize = 0;
    var rit = ranks.valueIterator();
    while (rit.next()) |r| max_rank = @max(max_rank, r.*);
    const rank_nodes = try a.alloc(std.ArrayList([]const u8), max_rank + 1);
    for (rank_nodes) |*b| b.* = .empty;
    for (layout_node_ids) |id| {
        const r = ranks.get(id) orelse 0;
        if (r < rank_nodes.len) try rank_nodes[r].append(a, id);
    }

    var order_map: Ranks = try graph.node_order.clone(a);
    var dummy_counter: usize = 0;
    const budgets = try labelMainGapBudgets(a, graph, layout_edges.items, labels.items, &ranks, config);
    const ordering_edges = try buildOrderingEdges(a, layout_edges.items, &ranks, rank_nodes, &order_map, &dummy_counter);
    for (rank_nodes) |*bucket| {
        std.mem.sort([]const u8, bucket.items, &order_map, struct {
            fn lt(m: *Ranks, x: []const u8, y: []const u8) bool {
                return (m.get(x) orelse std.math.maxInt(usize)) < (m.get(y) orelse std.math.maxInt(usize));
            }
        }.lt);
    }
    try ranking.orderRankNodes(a, rank_nodes, ordering_edges, &order_map, config.flowchart.order_passes);

    const horizontal = isHorizontal(graph.direction);
    var main_cursor: f32 = 0;
    for (rank_nodes, 0..) |bucket, rank_idx| {
        var max_main: f32 = 0;
        for (bucket.items) |id| if (nodes.get(id)) |n| {
            if (horizontal) {
                n.x = main_cursor;
                max_main = @max(max_main, n.width);
            } else {
                n.y = main_cursor;
                max_main = @max(max_main, n.height);
            }
        };
        if (max_main > 0.0) main_cursor += max_main + (config.rank_spacing + (budgets.get(rank_idx) orelse 0));
    }

    var incoming: Adj = .empty;
    var outgoing: Adj = .empty;
    var incoming_w: WAdj = .empty;
    var outgoing_w: WAdj = .empty;
    for (ordering_edges) |e| {
        try ranking.pushAdj(a, &incoming, e.to, e.from);
        try ranking.pushAdj(a, &outgoing, e.from, e.to);
        const w: f32 = if (analysis) |*an| try an.edgeWeightBetween(a, e.from, e.to) else 1.0;
        const gi = try incoming_w.getOrPut(a, e.to);
        if (!gi.found_existing) gi.value_ptr.* = .empty;
        try gi.value_ptr.append(a, .{ e.from, w });
        const go = try outgoing_w.getOrPut(a, e.from);
        if (!go.found_existing) go.value_ptr.* = .empty;
        try go.value_ptr.append(a, .{ e.to, w });
    }
    var cross_pos: std.StringHashMapUnmanaged(f32) = .empty;
    for (rank_nodes) |bucket| for (bucket.items, 0..) |id, idx| if (nodes.get(id)) |n| {
        const center = if (horizontal) n.y + n.height / 2.0 else n.x + n.width / 2.0;
        try cross_pos.put(a, id, center + @as(f32, @floatFromInt(idx)) * 0.01);
    };

    const Ctx = struct {
        a: Allocator,
        rank_nodes: []std.ArrayList([]const u8),
        incoming: *const Adj,
        outgoing: *const Adj,
        incoming_w: *const WAdj,
        outgoing_w: *const WAdj,
        cross_pos: *std.StringHashMapUnmanaged(f32),
        analysis: ?*const Analysis,
        config: *const LayoutConfig,
        horizontal: bool,

        const Entry = struct { id: []const u8, desired: f32, half: f32, idx: usize };

        fn place(c: *@This(), rank_idx: usize, use_incoming: bool, ns: *NodeMap) Allocator.Error!void {
            const bucket = c.rank_nodes[rank_idx].items;
            if (bucket.len == 0) return;
            const neighbors = if (use_incoming) c.incoming else c.outgoing;
            const wneighbors = if (use_incoming) c.incoming_w else c.outgoing_w;
            var entries: std.ArrayList(Entry) = .empty;
            for (bucket, 0..) |id, idx| {
                const node = ns.get(id) orelse continue;
                var centers: std.ArrayList(f32) = .empty;
                var wcenters: std.ArrayList(CW) = .empty;
                if (neighbors.get(id)) |list| for (list.items) |nid| if (c.cross_pos.get(nid)) |cc| try centers.append(c.a, cc);
                if (wneighbors.get(id)) |list| for (list.items) |nw| if (c.cross_pos.get(nw[0])) |cc| try wcenters.append(c.a, .{ .c = cc, .w = nw[1] });
                var desired = if (centers.items.len == 0)
                    c.cross_pos.get(id) orelse 0
                else
                    medianCenter(centers.items) orelse (c.cross_pos.get(id) orelse 0);
                if (c.cross_pos.get(id)) |current| {
                    if (centers.items.len > 0) {
                        desired = boundedEdgeAwareDesiredCenter(desired, weightedMedianCenter(wcenters.items), current, c.config.node_spacing);
                    } else desired = current;
                }
                const visual_half = if (c.horizontal) node.height / 2.0 else node.width / 2.0;
                const extra: f32 = if (c.analysis) |an| an.extraCrossPadding(id, c.config) else 0;
                try entries.append(c.a, .{ .id = id, .desired = desired, .half = visual_half + extra, .idx = idx });
            }
            std.mem.sort(Entry, entries.items, {}, struct {
                fn lt(_: void, x: Entry, y: Entry) bool {
                    if (x.desired < y.desired) return true;
                    if (x.desired > y.desired) return false;
                    return x.idx < y.idx;
                }
            }.lt);
            if (entries.items.len == 0) return;
            var desired_sum: f32 = 0;
            for (entries.items) |e| desired_sum += e.desired;
            const desired_mean = desired_sum / @as(f32, @floatFromInt(entries.items.len));
            const centers = try c.a.alloc(f32, entries.items.len);
            var prev_center: ?f32 = null;
            var prev_half: f32 = 0;
            for (entries.items, 0..) |e, i| {
                const center = if (prev_center) |p| blk: {
                    const min_center = p + prev_half + e.half + c.config.node_spacing;
                    break :blk if (e.desired < min_center) min_center else e.desired;
                } else e.desired;
                centers[i] = center;
                prev_center = center;
                prev_half = e.half;
            }
            var actual_sum: f32 = 0;
            for (centers) |v| actual_sum += v;
            const delta = desired_mean - actual_sum / @as(f32, @floatFromInt(centers.len));
            for (entries.items, 0..) |e, i| {
                const center = centers[i] + delta;
                if (ns.get(e.id)) |n| {
                    if (c.horizontal) n.y = center - n.height / 2.0 else n.x = center - n.width / 2.0;
                }
                try c.cross_pos.put(c.a, e.id, center);
            }
        }
    };
    var ctx: Ctx = .{
        .a = a,
        .rank_nodes = rank_nodes,
        .incoming = &incoming,
        .outgoing = &outgoing,
        .incoming_w = &incoming_w,
        .outgoing_w = &outgoing_w,
        .cross_pos = &cross_pos,
        .analysis = if (analysis) |*an| an else null,
        .config = config,
        .horizontal = horizontal,
    };
    for (0..@max(config.flowchart.order_passes, 1)) |_| {
        for (0..rank_nodes.len) |r| try ctx.place(r, true, nodes);
        var r = rank_nodes.len;
        while (r > 0) {
            r -= 1;
            try ctx.place(r, false, nodes);
        }
    }
    return .{ .rank_nodes = rank_nodes };
}
