//! `layout/flowchart/subgraph_spacing.rs`.

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
const NodeMap = t.NodeMap;
const StrSet = ranking.StrSet;
const isHorizontal = L.isHorizontal;
const FMAX = std.math.floatMax(f32);
const FMIN = -std.math.floatMax(f32);

const Box = struct { min_x: f32 = FMAX, min_y: f32 = FMAX, max_x: f32 = FMIN, max_y: f32 = FMIN };

fn boxOf(ids: []const []const u8, nodes: *const NodeMap) Box {
    var b: Box = .{};
    for (ids) |id| if (nodes.get(id)) |n| {
        b.min_x = @min(b.min_x, n.x);
        b.min_y = @min(b.min_y, n.y);
        b.max_x = @max(b.max_x, n.x + n.width);
        b.max_y = @max(b.max_y, n.y + n.height);
    };
    return b;
}

fn shiftNodes(ids: []const []const u8, nodes: *NodeMap, dx: f32, dy: f32) void {
    for (ids) |id| if (nodes.get(id)) |n| {
        n.x += dx;
        n.y += dy;
    };
}

pub fn applyFlowchartNodeLayoutCleanup(a: Allocator, graph: *const Graph, nodes: *NodeMap, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!void {
    if (graph.kind != .flowchart) return;
    try compressLinearSubgraphs(a, graph, nodes, config);
    if (graph.subgraphs.items.len == 0) {
        try alignDisconnectedComponents(a, graph, nodes, config);
        return;
    }
    try enforceTopLevelSubgraphGap(a, graph, nodes, theme, config);
    try separateSiblingSubgraphs(a, graph, nodes, theme, config);
    try alignSingleEntryTopLevelSubgraphs(a, graph, nodes, config);
    try alignDisconnectedTopLevelSubgraphs(a, graph, nodes);
    try evictNonMemberNodesFromSubgraphs(a, graph, nodes, theme, config);
}

pub fn evictNonMemberNodesFromSubgraphs(a: Allocator, graph: *const Graph, nodes: *NodeMap, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!void {
    if (graph.kind != .flowchart or graph.subgraphs.items.len == 0) return;
    const horizontal = isHorizontal(graph.direction);
    const clearance = @max(config.node_spacing * 0.5, L.MIN_NODE_SPACING_FLOOR);
    var members: StrSet = .empty;
    for (graph.subgraphs.items) |sub| for (sub.nodes.items) |id| try members.put(a, id, {});
    var free: std.ArrayList([]const u8) = .empty;
    for (nodes.values()) |n| if (!n.hidden and n.anchor_subgraph == null and !members.contains(n.id)) try free.append(a, n.id);
    if (free.items.len == 0) return;
    for (0..4) |_| {
        const subs = try sg.buildSubgraphLayouts(a, graph, nodes, theme, config);
        var rects: std.ArrayList([4]f32) = .empty;
        for (subs.items) |s| if (s.width > 0 and s.height > 0) try rects.append(a, .{ s.x, s.y, s.x + s.width, s.y + s.height });
        const overlapsAny = struct {
            fn f(rs: []const [4]f32, x1: f32, y1: f32, x2: f32, y2: f32) usize {
                var c: usize = 0;
                for (rs) |r| {
                    if (@min(x2, r[2]) - @max(x1, r[0]) > 0.0 and @min(y2, r[3]) - @max(y1, r[1]) > 0.0) c += 1;
                }
                return c;
            }
        }.f;
        var moved = false;
        for (free.items) |id| {
            const node = nodes.get(id) orelse continue;
            const nx1 = node.x;
            const ny1 = node.y;
            const nx2 = node.x + node.width;
            const ny2 = node.y + node.height;
            if (overlapsAny(rects.items, nx1, ny1, nx2, ny2) == 0) continue;
            var best: ?struct { usize, f32, f32, f32 } = null;
            for (rects.items) |r| {
                const ox = @min(nx2, r[2]) - @max(nx1, r[0]);
                const oy = @min(ny2, r[3]) - @max(ny1, r[1]);
                if (ox <= 0.0 or oy <= 0.0) continue;
                const cands = [_][2]f32{
                    .{ -(nx2 - r[0] + clearance), 0 },
                    .{ r[2] - nx1 + clearance, 0 },
                    .{ 0, -(ny2 - r[1] + clearance) },
                    .{ 0, r[3] - ny1 + clearance },
                };
                for (cands) |c| {
                    const remaining = overlapsAny(rects.items, nx1 + c[0], ny1 + c[1], nx2 + c[0], ny2 + c[1]);
                    const disp = @abs(c[0]) + @abs(c[1]);
                    const main_move = if (horizontal) c[0] != 0.0 else c[1] != 0.0;
                    const score = disp * @as(f32, if (main_move) 1.25 else 1.0);
                    const better = if (best) |b| remaining < b[0] or (remaining == b[0] and score < b[1]) else true;
                    if (better) best = .{ remaining, score, c[0], c[1] };
                }
            }
            if (best) |b| {
                node.x += b[2];
                node.y += b[3];
                moved = true;
            }
        }
        if (!moved) break;
    }
}

pub fn compressLinearSubgraphs(a: Allocator, graph: *const Graph, nodes: *NodeMap, config: *const LayoutConfig) Allocator.Error!void {
    if (graph.kind != .flowchart or graph.subgraphs.items.len == 0) return;
    const gap = config.flowchart.auto_spacing.min_spacing;
    const horizontal = isHorizontal(graph.direction);
    for (graph.subgraphs.items) |*sub| {
        if (sub.nodes.items.len < 3) continue;
        var in_deg: ranking.Ranks = .empty;
        var out_deg: ranking.Ranks = .empty;
        var next_map: std.StringHashMapUnmanaged([]const u8) = .empty;
        var edges_in: usize = 0;
        for (sub.nodes.items) |id| {
            try in_deg.put(a, id, 0);
            try out_deg.put(a, id, 0);
        }
        for (graph.edges.items) |e| {
            if (!sub.containsNode(e.from) or !sub.containsNode(e.to)) continue;
            edges_in += 1;
            const o = try out_deg.getOrPut(a, e.from);
            if (!o.found_existing) o.value_ptr.* = 0;
            o.value_ptr.* += 1;
            if (o.value_ptr.* == 1) try next_map.put(a, e.from, e.to) else _ = next_map.remove(e.from);
            const i = try in_deg.getOrPut(a, e.to);
            if (!i.found_existing) i.value_ptr.* = 0;
            i.value_ptr.* += 1;
        }
        if (edges_in + 1 != sub.nodes.items.len) continue;
        var bad = false;
        var it1 = in_deg.valueIterator();
        while (it1.next()) |d| bad = bad or d.* > 1;
        var it2 = out_deg.valueIterator();
        while (it2.next()) |d| bad = bad or d.* > 1;
        if (bad) continue;
        var starts: std.ArrayList([]const u8) = .empty;
        for (sub.nodes.items) |id| if ((in_deg.get(id) orelse 0) == 0) try starts.append(a, id);
        if (starts.items.len != 1) continue;
        var order: std.ArrayList([]const u8) = .empty;
        var visited: StrSet = .empty;
        var current = starts.items[0];
        while (!(try visited.getOrPut(a, current)).found_existing) {
            try order.append(a, current);
            current = next_map.get(current) orelse break;
        }
        if (order.items.len != sub.nodes.items.len) continue;
        var cursor: f32 = FMAX;
        for (order.items) |id| if (nodes.get(id)) |n| {
            cursor = @min(cursor, if (horizontal) n.x else n.y);
        };
        for (order.items) |id| if (nodes.get(id)) |n| {
            if (horizontal) {
                n.x = cursor;
                cursor += n.width + gap;
            } else {
                n.y = cursor;
                cursor += n.height + gap;
            }
        };
    }
}

fn topLevelDisjoint(a: Allocator, graph: *const Graph, top: []const usize) Allocator.Error!bool {
    var seen: StrSet = .empty;
    for (top) |idx| for (graph.subgraphs.items[idx].nodes.items) |id| {
        if ((try seen.getOrPut(a, id)).found_existing) return false;
    };
    return true;
}

fn subgraphPadding(a: Allocator, graph: *const Graph, sub: *const ir.Subgraph, theme: *const Theme, config: *const LayoutConfig, zero_empty: bool) Allocator.Error![3]f32 {
    var lb = try text.measureLabel(a, sub.label, theme, config);
    if (zero_empty and util.trim(sub.label).len == 0) {
        lb.width = 0;
        lb.height = 0;
    }
    return sg.subgraphPaddingFromLabel(graph, sub, theme, &lb);
}

pub fn enforceTopLevelSubgraphGap(a: Allocator, graph: *const Graph, nodes: *NodeMap, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!void {
    if (graph.kind != .flowchart or graph.subgraphs.items.len < 2) return;
    const top = try sg.topLevelSubgraphIndices(a, graph);
    if (top.len < 2) return;
    if (!try topLevelDisjoint(a, graph, top)) return;
    var node_top: ranking.Ranks = .empty;
    for (top) |idx| for (graph.subgraphs.items[idx].nodes.items) |id| try node_top.put(a, id, idx);
    var cross = false;
    for (graph.edges.items) |e| {
        const f = node_top.get(e.from) orelse continue;
        const tt = node_top.get(e.to) orelse continue;
        if (f != tt) cross = true;
    }
    if (!cross) return;
    const B = struct { idx: usize, b: Box, pad_main: f32 };
    const horizontal = isHorizontal(graph.direction);
    var bounds: std.ArrayList(B) = .empty;
    for (top) |idx| {
        const sub = &graph.subgraphs.items[idx];
        if (sg.isRegionSubgraph(sub) or sub.nodes.items.len == 0) continue;
        const b = boxOf(sub.nodes.items, nodes);
        if (b.min_x == FMAX) continue;
        const p = try subgraphPadding(a, graph, sub, theme, config, true);
        try bounds.append(a, .{ .idx = idx, .b = .{ .min_x = b.min_x - p[0], .min_y = b.min_y - p[2], .max_x = b.max_x + p[0], .max_y = b.max_y + p[1] }, .pad_main = if (horizontal) p[0] else p[1] });
    }
    if (bounds.items.len < 2) return;
    std.mem.sort(B, bounds.items, horizontal, struct {
        fn lt(h: bool, x: B, y: B) bool {
            const xk = if (h) x.b.min_x else x.b.min_y;
            const yk = if (h) y.b.min_x else y.b.min_y;
            if (xk != yk) return xk < yk;
            return x.idx < y.idx;
        }
    }.lt);
    var pad_main: f32 = 0;
    for (bounds.items) |b| pad_main = @max(pad_main, b.pad_main);
    const desired_gap = @max(config.node_spacing * L.SUBGRAPH_DESIRED_GAP_RATIO, pad_main * 2.0);
    var prev_max: ?f32 = null;
    for (bounds.items) |*b| {
        const min_main = if (horizontal) b.b.min_x else b.b.min_y;
        var max_main = if (horizontal) b.b.max_x else b.b.max_y;
        var delta: f32 = 0;
        if (prev_max) |pm| {
            const req = pm + desired_gap;
            if (min_main < req) delta = req - min_main;
        }
        if (delta > 0.0) {
            const ids = graph.subgraphs.items[b.idx].nodes.items;
            if (horizontal) shiftNodes(ids, nodes, delta, 0) else shiftNodes(ids, nodes, 0, delta);
            if (horizontal) {
                b.b.min_x += delta;
                b.b.max_x += delta;
            } else {
                b.b.min_y += delta;
                b.b.max_y += delta;
            }
            max_main += delta;
        }
        prev_max = max_main;
    }
}

pub fn separateSiblingSubgraphs(a: Allocator, graph: *const Graph, nodes: *NodeMap, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!void {
    const n = graph.subgraphs.items.len;
    if (n < 2) return;
    const tree = try sg.SubgraphTree.build(a, graph);
    var groups: std.ArrayList(std.ArrayList(usize)) = .empty;
    const assigned = try a.alloc(bool, n);
    @memset(assigned, false);
    for (0..n) |i| {
        if (assigned[i]) continue;
        var group: std.ArrayList(usize) = .empty;
        try group.append(a, i);
        assigned[i] = true;
        for (i + 1..n) |j| {
            if (assigned[j]) continue;
            var sib = true;
            for (group.items) |k| sib = sib and tree.areSiblings(j, k);
            if (sib) {
                try group.append(a, j);
                assigned[j] = true;
            }
        }
        if (group.items.len > 1) try groups.append(a, group);
    }
    const horizontal = isHorizontal(graph.direction);
    const B = struct { idx: usize, x1: f32, y1: f32, x2: f32, y2: f32 };
    for (groups.items) |group| {
        var bounds: std.ArrayList(B) = .empty;
        for (group.items) |idx| {
            const sub = &graph.subgraphs.items[idx];
            const b = boxOf(sub.nodes.items, nodes);
            if (b.min_x == FMAX) continue;
            const p = try subgraphPadding(a, graph, sub, theme, config, false);
            try bounds.append(a, .{ .idx = idx, .x1 = b.min_x - p[0], .y1 = b.min_y - p[2], .x2 = b.max_x + p[0], .y2 = b.max_y + p[1] });
        }
        if (bounds.items.len < 2) continue;
        std.mem.sort(B, bounds.items, horizontal, struct {
            fn lt(h: bool, x: B, y: B) bool {
                return if (h) x.y1 < y.y1 else x.x1 < y.x1;
            }
        }.lt);
        const gap = @max(config.node_spacing, 8.0);
        const ov = struct {
            fn f(a_min: f32, a_max: f32, b_min: f32, b_max: f32) bool {
                return a_min < b_max and b_min < a_max;
            }
        }.f;
        var placed: std.ArrayList(B) = .empty;
        for (bounds.items) |b| {
            var shift: f32 = 0;
            for (placed.items) |p| {
                const other = if (horizontal) ov(b.x1, b.x2, p.x1, p.x2) else ov(b.y1, b.y2, p.y1, p.y2);
                if (!other) continue;
                const smin = if (horizontal) b.y1 + shift else b.x1 + shift;
                const smax = if (horizontal) b.y2 + shift else b.x2 + shift;
                const pmin = if (horizontal) p.y1 else p.x1;
                const pmax = if (horizontal) p.y2 else p.x2;
                if (ov(smin, smax, pmin, pmax)) {
                    const needed = pmax + gap - smin;
                    if (needed > shift) shift = needed;
                }
            }
            if (shift > 0.0) {
                const ids = graph.subgraphs.items[b.idx].nodes.items;
                if (horizontal) shiftNodes(ids, nodes, 0, shift) else shiftNodes(ids, nodes, shift, 0);
            }
            try placed.append(a, if (horizontal) .{ .idx = b.idx, .x1 = b.x1, .y1 = b.y1 + shift, .x2 = b.x2, .y2 = b.y2 + shift } else .{ .idx = b.idx, .x1 = b.x1 + shift, .y1 = b.y1, .x2 = b.x2 + shift, .y2 = b.y2 });
        }
    }
}

pub fn alignDisconnectedTopLevelSubgraphs(a: Allocator, graph: *const Graph, nodes: *NodeMap) Allocator.Error!void {
    if (graph.kind != .flowchart or graph.subgraphs.items.len < 2) return;
    const top = try sg.topLevelSubgraphIndices(a, graph);
    if (top.len < 2) return;
    var seen: StrSet = .empty;
    var union_count: usize = 0;
    for (top) |idx| {
        const sub = &graph.subgraphs.items[idx];
        for (sub.nodes.items) |id| {
            if ((try seen.getOrPut(a, id)).found_existing) return;
            union_count += 1;
        }
        if (sg.subgraphAnchorId(sub, nodes)) |anc| {
            if ((try seen.getOrPut(a, anc)).found_existing) return;
            union_count += 1;
        }
    }
    if (union_count != graph.nodes.len()) return;
    var node_top: ranking.Ranks = .empty;
    for (top) |idx| {
        const sub = &graph.subgraphs.items[idx];
        for (sub.nodes.items) |id| try node_top.put(a, id, idx);
        if (sg.subgraphAnchorId(sub, nodes)) |anc| try node_top.put(a, anc, idx);
    }
    for (graph.edges.items) |e| {
        const f = node_top.get(e.from) orelse continue;
        const tt = node_top.get(e.to) orelse continue;
        if (f != tt) return;
    }
    const B = struct { idx: usize, b: Box, anchor: ?[]const u8 };
    var bounds: std.ArrayList(B) = .empty;
    for (top) |idx| {
        const sub = &graph.subgraphs.items[idx];
        if (sub.nodes.items.len == 0) continue;
        var b = boxOf(sub.nodes.items, nodes);
        const anchor = sg.subgraphAnchorId(sub, nodes);
        if (anchor) |id| if (nodes.get(id)) |an| {
            b.min_x = @min(b.min_x, an.x);
            b.min_y = @min(b.min_y, an.y);
            b.max_x = @max(b.max_x, an.x + an.width);
            b.max_y = @max(b.max_y, an.y + an.height);
        };
        if (b.min_x == FMAX) continue;
        try bounds.append(a, .{ .idx = idx, .b = b, .anchor = anchor });
    }
    if (bounds.items.len < 2) return;
    const horizontal = isHorizontal(graph.direction);
    std.mem.sort(B, bounds.items, horizontal, struct {
        fn lt(h: bool, x: B, y: B) bool {
            const xk = if (h) x.b.min_x else x.b.min_y;
            const yk = if (h) y.b.min_x else y.b.min_y;
            if (xk != yk) return xk < yk;
            return x.idx < y.idx;
        }
    }.lt);
    var prev: ?f32 = null;
    for (bounds.items) |b| {
        const mn = if (horizontal) b.b.min_x else b.b.min_y;
        const mx = if (horizontal) b.b.max_x else b.b.max_y;
        if (prev) |p| if (mn < p) return;
        prev = mx;
    }
    var target: f32 = FMAX;
    for (bounds.items) |b| target = @min(target, if (horizontal) b.b.min_y else b.b.min_x);
    for (bounds.items) |b| {
        const cur = if (horizontal) b.b.min_y else b.b.min_x;
        const delta = target - cur;
        if (@abs(delta) < 0.5) continue;
        const ids = graph.subgraphs.items[b.idx].nodes.items;
        if (horizontal) shiftNodes(ids, nodes, 0, delta) else shiftNodes(ids, nodes, delta, 0);
        if (b.anchor) |id| if (nodes.get(id)) |n| {
            if (horizontal) n.y += delta else n.x += delta;
        };
    }
}

pub fn alignSingleEntryTopLevelSubgraphs(a: Allocator, graph: *const Graph, nodes: *NodeMap, config: *const LayoutConfig) Allocator.Error!void {
    if (graph.kind != .flowchart or graph.subgraphs.items.len == 0) return;
    const outer_h = isHorizontal(graph.direction);
    const limit = @max(config.node_spacing * 0.75, 10.0);
    for (try sg.topLevelSubgraphIndices(a, graph)) |idx| {
        const sub = &graph.subgraphs.items[idx];
        if (sub.nodes.items.len == 0 or sg.isRegionSubgraph(sub)) continue;
        const inner_h = isHorizontal(sub.direction orelse graph.direction);
        if (inner_h == outer_h) continue;
        var incoming: ?ir.Edge = null;
        var n_in: usize = 0;
        var n_out: usize = 0;
        for (graph.edges.items) |e| {
            const fi = sub.containsNode(e.from);
            const ti = sub.containsNode(e.to);
            if (!fi and ti) {
                n_in += 1;
                if (incoming == null) incoming = e;
            }
            if (fi and !ti) n_out += 1;
        }
        if (n_in != 1 or n_out != 0) continue;
        const feeder = incoming.?;
        const source = nodes.get(feeder.from) orelse continue;
        const target = nodes.get(feeder.to) orelse continue;
        const sc = if (outer_h) source.y + source.height * 0.5 else source.x + source.width * 0.5;
        const tc = if (outer_h) target.y + target.height * 0.5 else target.x + target.width * 0.5;
        const delta = sc - tc;
        if (@abs(delta) < 0.5 or @abs(delta) > limit) continue;
        var extreme: f32 = FMAX;
        for (sub.nodes.items) |id| if (nodes.get(id)) |n| {
            extreme = @min(extreme, if (inner_h) n.x else n.y);
        };
        const is_edge_member = @abs((if (inner_h) target.x else target.y) - extreme) <= 1.0;
        if (!is_edge_member) continue;
        if (outer_h) shiftNodes(sub.nodes.items, nodes, 0, delta) else shiftNodes(sub.nodes.items, nodes, delta, 0);
        if (sg.subgraphAnchorId(sub, nodes)) |anc| if (nodes.get(anc)) |n| {
            if (outer_h) n.y += delta else n.x += delta;
        };
    }
}

pub fn alignDisconnectedComponents(a: Allocator, graph: *const Graph, nodes: *NodeMap, config: *const LayoutConfig) Allocator.Error!void {
    if (graph.kind != .flowchart or graph.subgraphs.items.len != 0) return;
    var visible: std.ArrayList([]const u8) = .empty;
    for (nodes.values()) |n| if (!n.hidden) try visible.append(a, n.id);
    if (visible.items.len < 2) return;
    // nodes are already sorted by id (BTreeMap order).
    var adj: ranking.Adj = .empty;
    for (visible.items) |id| try adj.put(a, id, .empty);
    for (graph.edges.items) |e| {
        if (!adj.contains(e.from) or !adj.contains(e.to)) continue;
        try ranking.pushAdj(a, &adj, e.from, e.to);
        try ranking.pushAdj(a, &adj, e.to, e.from);
    }
    var visited: StrSet = .empty;
    var comps: std.ArrayList([]const []const u8) = .empty;
    for (visible.items) |id| {
        if (visited.contains(id)) continue;
        var stack: std.ArrayList([]const u8) = .empty;
        var comp: std.ArrayList([]const u8) = .empty;
        try stack.append(a, id);
        try visited.put(a, id, {});
        while (stack.pop()) |cur| {
            try comp.append(a, cur);
            if (adj.get(cur)) |ns| for (ns.items) |nx| {
                if (!(try visited.getOrPut(a, nx)).found_existing) try stack.append(a, nx);
            };
        }
        if (comp.items.len > 0) try comps.append(a, comp.items);
    }
    if (comps.items.len < 2) return;
    const B = struct { ids: []const []const u8, b: Box };
    var bounds: std.ArrayList(B) = .empty;
    for (comps.items) |c| {
        const b = boxOf(c, nodes);
        if (b.min_x == FMAX) continue;
        try bounds.append(a, .{ .ids = c, .b = b });
    }
    if (bounds.items.len < 2) return;
    const horizontal = isHorizontal(graph.direction);
    std.mem.sort(B, bounds.items, horizontal, struct {
        fn lt(h: bool, x: B, y: B) bool {
            return if (h) x.b.min_x < y.b.min_x else x.b.min_y < y.b.min_y;
        }
    }.lt);
    var target: f32 = FMAX;
    var cursor: f32 = FMAX;
    for (bounds.items) |b| {
        target = @min(target, if (horizontal) b.b.min_y else b.b.min_x);
        cursor = @min(cursor, if (horizontal) b.b.min_x else b.b.min_y);
    }
    const spacing = @max(config.node_spacing, L.MIN_NODE_SPACING_FLOOR);
    for (bounds.items) |b| {
        const mn = if (horizontal) b.b.min_x else b.b.min_y;
        const mx = if (horizontal) b.b.max_x else b.b.max_y;
        const cc = if (horizontal) b.b.min_y else b.b.min_x;
        const dm = cursor - mn;
        const dc = target - cc;
        if (horizontal) shiftNodes(b.ids, nodes, dm, dc) else shiftNodes(b.ids, nodes, dc, dm);
        cursor += @max(mx - mn, 1.0) + spacing;
    }
}
