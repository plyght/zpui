//! `layout/ranking.rs`: rank assignment (SCC-condensed longest path) and
//! barycentric rank ordering with transposition.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir.zig");
const Edge = ir.Edge;

pub const StrList = std.ArrayList([]const u8);
pub const Adj = std.StringHashMapUnmanaged(StrList);
pub const Ranks = std.StringHashMapUnmanaged(usize);
pub const StrSet = std.StringHashMapUnmanaged(void);

pub fn pushAdj(a: Allocator, map: *Adj, key: []const u8, v: []const u8) Allocator.Error!void {
    const gop = try map.getOrPut(a, key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    try gop.value_ptr.append(a, v);
}

pub fn rankEdgesForManualLayout(a: Allocator, graph: *const ir.Graph, layout_node_ids: []const []const u8, layout_edges: []const Edge) Allocator.Error![]const Edge {
    if (graph.kind != .flowchart or layout_edges.len < 3) return layout_edges;
    var primary: std.ArrayList(Edge) = .empty;
    for (layout_edges) |e| if (e.style != .dotted) try primary.append(a, e);
    if (primary.items.len == 0) return layout_edges;
    var covered: StrSet = .empty;
    for (primary.items) |e| {
        try covered.put(a, e.from, {});
        try covered.put(a, e.to, {});
    }
    const min_covered = (layout_node_ids.len + 1) / 2;
    if (covered.count() >= min_covered) return primary.items;
    return layout_edges;
}

fn orderOf(node_order: *const Ranks, id: []const u8) usize {
    return node_order.get(id) orelse std.math.maxInt(usize);
}

pub fn orderRankNodes(a: Allocator, rank_nodes: []std.ArrayList([]const u8), edges: []const Edge, node_order: *const Ranks, passes_in: usize) Allocator.Error!void {
    if (rank_nodes.len <= 1) return;
    var incoming: Adj = .empty;
    var outgoing: Adj = .empty;
    for (edges) |e| {
        try pushAdj(a, &outgoing, e.from, e.to);
        try pushAdj(a, &incoming, e.to, e.from);
    }
    var positions: Ranks = .empty;
    try updatePositions(a, rank_nodes, &positions);
    const passes = @max(passes_in, 1);
    for (0..passes) |_| {
        var rank: usize = 1;
        while (rank < rank_nodes.len) : (rank += 1) {
            if (rank_nodes[rank].items.len <= 1) continue;
            try sortBucket(a, rank_nodes[rank].items, &incoming, &positions, node_order);
            transposeBucket(rank_nodes[rank].items, &incoming, &positions, node_order);
            try updatePositions(a, rank_nodes, &positions);
        }
        var r = rank_nodes.len -| 1;
        while (r > 0) {
            r -= 1;
            if (rank_nodes[r].items.len <= 1) continue;
            try sortBucket(a, rank_nodes[r].items, &outgoing, &positions, node_order);
            transposeBucket(rank_nodes[r].items, &outgoing, &positions, node_order);
            try updatePositions(a, rank_nodes, &positions);
        }
    }
}

fn updatePositions(a: Allocator, rank_nodes: []std.ArrayList([]const u8), positions: *Ranks) Allocator.Error!void {
    positions.clearRetainingCapacity();
    for (rank_nodes) |bucket| for (bucket.items, 0..) |id, idx| try positions.put(a, id, idx);
}

fn sortBucket(a: Allocator, bucket: [][]const u8, neighbors: *const Adj, positions: *const Ranks, node_order: *const Ranks) Allocator.Error!void {
    var current: Ranks = .empty;
    for (bucket, 0..) |id, idx| try current.put(a, id, idx);
    const Item = struct { id: []const u8, score: f32, pos: usize, ord: usize };
    const items = try a.alloc(Item, bucket.len);
    for (bucket, 0..) |id, i| items[i] = .{
        .id = id,
        .score = try medianPosition(a, id, neighbors, positions, &current),
        .pos = current.get(id) orelse 0,
        .ord = orderOf(node_order, id),
    };
    std.mem.sort(Item, items, {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            if (x.score < y.score) return true;
            if (x.score > y.score) return false;
            if (x.pos != y.pos) return x.pos < y.pos;
            return x.ord < y.ord;
        }
    }.lt);
    for (items, 0..) |it, i| bucket[i] = it.id;
}

fn pairCrossings(x: []const u8, y: []const u8, neighbors: *const Adj, positions: *const Ranks) [2]usize {
    const xl = neighbors.get(x) orelse return .{ 0, 0 };
    const yl = neighbors.get(y) orelse return .{ 0, 0 };
    var ab: usize = 0;
    var ba: usize = 0;
    var any_x = false;
    var any_y = false;
    for (xl.items) |n| if (positions.get(n) != null) {
        any_x = true;
    };
    for (yl.items) |n| if (positions.get(n) != null) {
        any_y = true;
    };
    if (!any_x or !any_y) return .{ 0, 0 };
    for (xl.items) |na| {
        const pa = positions.get(na) orelse continue;
        for (yl.items) |nb| {
            const pb = positions.get(nb) orelse continue;
            if (pa > pb) ab += 1 else if (pb > pa) ba += 1;
        }
    }
    return .{ ab, ba };
}

fn transposeBucket(bucket: [][]const u8, neighbors: *const Adj, positions: *const Ranks, node_order: *const Ranks) void {
    if (bucket.len <= 1) return;
    var improved = true;
    while (improved) {
        improved = false;
        for (0..bucket.len - 1) |i| {
            const c = pairCrossings(bucket[i], bucket[i + 1], neighbors, positions);
            const swap = if (c[1] < c[0]) true else if (c[1] > c[0]) false else orderOf(node_order, bucket[i]) > orderOf(node_order, bucket[i + 1]);
            if (swap) {
                std.mem.swap([]const u8, &bucket[i], &bucket[i + 1]);
                improved = true;
            }
        }
    }
}

pub fn medianPosition(a: Allocator, id: []const u8, neighbors: *const Adj, positions: *const Ranks, current: *const Ranks) Allocator.Error!f32 {
    const list = neighbors.get(id) orelse return @floatFromInt(current.get(id) orelse 0);
    var values: std.ArrayList(f32) = .empty;
    for (list.items) |n| if (positions.get(n)) |p| try values.append(a, @floatFromInt(p));
    if (values.items.len == 0) return @floatFromInt(current.get(id) orelse 0);
    std.mem.sort(f32, values.items, {}, std.sort.asc(f32));
    const mid = values.items.len / 2;
    if (values.items.len % 2 == 1) return values.items[mid];
    return (values.items[mid - 1] + values.items[mid]) * 0.5;
}

pub fn computeRanksSubset(a: Allocator, node_ids: []const []const u8, edges: []const Edge, node_order: *const Ranks) Allocator.Error!Ranks {
    var set: StrSet = .empty;
    for (node_ids) |id| try set.put(a, id, {});
    var subset: std.ArrayList(Edge) = .empty;
    for (edges) |e| if (set.contains(e.from) and set.contains(e.to)) try subset.append(a, e);
    var fallback: Ranks = .empty;
    for (node_ids, 0..) |id, idx| try fallback.put(a, id, idx);
    const Key = struct {
        no: *const Ranks,
        fb: *const Ranks,
        fn of(k: @This(), id: []const u8) usize {
            return k.no.get(id) orelse (k.fb.get(id) orelse std.math.maxInt(usize));
        }
    };
    const key: Key = .{ .no = node_order, .fb = &fallback };

    const components = try stronglyConnectedComponents(a, node_ids, subset.items);
    var node_comp: Ranks = .empty;
    for (components, 0..) |comp, ci| for (comp) |id| try node_comp.put(a, id, ci);

    const nc = components.len;
    const comp_adj = try a.alloc(std.ArrayList(usize), nc);
    const comp_rev = try a.alloc(std.ArrayList(usize), nc);
    for (comp_adj) |*x| x.* = .empty;
    for (comp_rev) |*x| x.* = .empty;
    for (subset.items) |e| {
        const fc = node_comp.get(e.from) orelse continue;
        const tc = node_comp.get(e.to) orelse continue;
        if (fc == tc) continue;
        try comp_adj[fc].append(a, tc);
        try comp_rev[tc].append(a, fc);
    }
    for (comp_adj) |*l| dedupSorted(l);
    for (comp_rev) |*l| dedupSorted(l);

    const comp_keys = try a.alloc(usize, nc);
    for (components, 0..) |comp, ci| {
        var m: usize = std.math.maxInt(usize);
        for (comp) |id| m = @min(m, key.of(id));
        comp_keys[ci] = m;
    }
    const component_order = try stableTopologyOrderIdx(a, nc, comp_adj, comp_rev, comp_keys);

    const local = try a.alloc(Ranks, nc);
    for (components, 0..) |comp, ci| {
        // stable_component_node_order
        var cset: StrSet = .empty;
        for (comp) |id| try cset.put(a, id, {});
        var adj: Adj = .empty;
        var rev: Adj = .empty;
        for (subset.items) |e| if (cset.contains(e.from) and cset.contains(e.to)) {
            try pushAdj(a, &adj, e.from, e.to);
            try pushAdj(a, &rev, e.to, e.from);
        };
        const keys = try a.alloc(usize, comp.len);
        for (comp, 0..) |id, i| keys[i] = key.of(id);
        const internal_order = try stableTopologyOrderStr(a, comp, &adj, &rev, keys);
        local[ci] = try layeredRanksFromOrder(a, internal_order, &adj);
    }

    const WEdge = struct { to: usize, w: isize };
    const weighted = try a.alloc(std.ArrayList(WEdge), nc);
    for (weighted) |*x| x.* = .empty;
    for (subset.items) |e| {
        const fc = node_comp.get(e.from) orelse continue;
        const tc = node_comp.get(e.to) orelse continue;
        if (fc == tc) continue;
        const fl: isize = @intCast(local[fc].get(e.from) orelse 0);
        const tl: isize = @intCast(local[tc].get(e.to) orelse 0);
        try weighted[fc].append(a, .{ .to = tc, .w = fl + 1 - tl });
    }
    const start = try a.alloc(isize, nc);
    @memset(start, 0);
    for (component_order) |ci| {
        const s = start[ci];
        for (weighted[ci].items) |we| start[we.to] = @max(start[we.to], s + we.w);
    }
    var ranks: Ranks = .empty;
    for (components, 0..) |comp, ci| {
        const base: usize = @intCast(@max(start[ci], 0));
        for (comp) |id| try ranks.put(a, id, base + (local[ci].get(id) orelse 0));
    }
    return ranks;
}

fn dedupSorted(l: *std.ArrayList(usize)) void {
    std.mem.sort(usize, l.items, {}, std.sort.asc(usize));
    var w: usize = 0;
    for (l.items, 0..) |v, i| {
        if (i > 0 and v == l.items[w - 1]) continue;
        l.items[w] = v;
        w += 1;
    }
    l.items.len = w;
}

fn layeredRanksFromOrder(a: Allocator, order: []const []const u8, adj: *const Adj) Allocator.Error!Ranks {
    var idx: Ranks = .empty;
    for (order, 0..) |id, i| try idx.put(a, id, i);
    var ranks: Ranks = .empty;
    for (order) |node| {
        const rank = ranks.get(node) orelse 0;
        if (!ranks.contains(node)) try ranks.put(a, node, rank);
        if (adj.get(node)) |nexts| {
            const from_idx = idx.get(node) orelse 0;
            for (nexts.items) |next| {
                const to_idx = idx.get(next) orelse from_idx;
                if (to_idx <= from_idx) continue;
                const gop = try ranks.getOrPut(a, next);
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* = @max(gop.value_ptr.*, rank + 1);
            }
        }
    }
    return ranks;
}

/// `stable_topology_order` over component indices (min-heap on (key, index)).
fn stableTopologyOrderIdx(a: Allocator, n: usize, adj: []const std.ArrayList(usize), rev: []const std.ArrayList(usize), keys: []const usize) Allocator.Error![]usize {
    const indeg = try a.alloc(usize, n);
    for (0..n) |i| indeg[i] = rev[i].items.len;
    const processed = try a.alloc(bool, n);
    @memset(processed, false);
    const Ent = struct { k: usize, i: usize };
    const Ctx = struct {
        fn order(_: void, x: Ent, y: Ent) std.math.Order {
            if (x.k != y.k) return std.math.order(x.k, y.k);
            return std.math.order(x.i, y.i);
        }
    };
    var ready = std.PriorityQueue(Ent, void, Ctx.order).empty;
    for (0..n) |i| if (indeg[i] == 0) try ready.push(a, .{ .k = keys[i], .i = i });
    var ordered: std.ArrayList(usize) = .empty;
    var count: usize = 0;
    while (true) {
        while (ready.pop()) |e| {
            if (processed[e.i]) continue;
            try ordered.append(a, e.i);
            processed[e.i] = true;
            count += 1;
            for (adj[e.i].items) |next| {
                if (processed[next]) continue;
                indeg[next] -|= 1;
                if (indeg[next] == 0) try ready.push(a, .{ .k = keys[next], .i = next });
            }
        }
        if (count >= n) break;
        var best: ?Ent = null;
        for (0..n) |i| if (!processed[i]) {
            if (best == null or keys[i] < best.?.k) best = .{ .k = keys[i], .i = i };
        };
        if (best) |b| try ready.push(a, b) else break;
    }
    return ordered.items;
}

/// `stable_topology_order` over node ids (min-heap on (key, id)).
fn stableTopologyOrderStr(a: Allocator, items: []const []const u8, adj: *const Adj, rev: *const Adj, keys: []const usize) Allocator.Error![]const []const u8 {
    var index: Ranks = .empty;
    for (items, 0..) |id, i| try index.put(a, id, i);
    const n = items.len;
    const indeg = try a.alloc(usize, n);
    for (items, 0..) |id, i| indeg[i] = if (rev.get(id)) |l| l.items.len else 0;
    const processed = try a.alloc(bool, n);
    @memset(processed, false);
    const Ent = struct { k: usize, id: []const u8, i: usize };
    const Ctx = struct {
        fn order(_: void, x: Ent, y: Ent) std.math.Order {
            if (x.k != y.k) return std.math.order(x.k, y.k);
            return std.mem.order(u8, x.id, y.id);
        }
    };
    var ready = std.PriorityQueue(Ent, void, Ctx.order).empty;
    for (0..n) |i| if (indeg[i] == 0) try ready.push(a, .{ .k = keys[i], .id = items[i], .i = i });
    var ordered: std.ArrayList([]const u8) = .empty;
    var count: usize = 0;
    while (true) {
        while (ready.pop()) |e| {
            if (processed[e.i]) continue;
            try ordered.append(a, e.id);
            processed[e.i] = true;
            count += 1;
            if (adj.get(e.id)) |nexts| for (nexts.items) |next| {
                const ni = index.get(next) orelse continue;
                if (processed[ni]) continue;
                indeg[ni] -|= 1;
                if (indeg[ni] == 0) try ready.push(a, .{ .k = keys[ni], .id = next, .i = ni });
            };
        }
        if (count >= n) break;
        var best: ?Ent = null;
        for (0..n) |i| if (!processed[i]) {
            if (best == null or keys[i] < best.?.k or (keys[i] == best.?.k and std.mem.order(u8, items[i], best.?.id) == .lt)) best = .{ .k = keys[i], .id = items[i], .i = i };
        };
        if (best) |b| try ready.push(a, b) else break;
    }
    return ordered.items;
}

pub fn stronglyConnectedComponents(a: Allocator, node_ids: []const []const u8, edges: []const Edge) Allocator.Error![]const []const []const u8 {
    var adj: Adj = .empty;
    var rev: Adj = .empty;
    for (edges) |e| {
        try pushAdj(a, &adj, e.from, e.to);
        try pushAdj(a, &rev, e.to, e.from);
    }
    var visited: StrSet = .empty;
    var finish: std.ArrayList([]const u8) = .empty;
    for (node_ids) |id| try dfsFinishOrder(a, id, &adj, &visited, &finish);
    var assigned: StrSet = .empty;
    var comps: std.ArrayList([]const []const u8) = .empty;
    while (finish.pop()) |id| {
        if ((try assigned.getOrPut(a, id)).found_existing) continue;
        var comp: std.ArrayList([]const u8) = .empty;
        var stack: std.ArrayList([]const u8) = .empty;
        try stack.append(a, id);
        while (stack.pop()) |cur| {
            try comp.append(a, cur);
            if (rev.get(cur)) |prevs| for (prevs.items) |p| {
                if (!(try assigned.getOrPut(a, p)).found_existing) try stack.append(a, p);
            };
        }
        try comps.append(a, comp.items);
    }
    return comps.items;
}

fn dfsFinishOrder(a: Allocator, id: []const u8, adj: *const Adj, visited: *StrSet, finish: *std.ArrayList([]const u8)) Allocator.Error!void {
    if ((try visited.getOrPut(a, id)).found_existing) return;
    if (adj.get(id)) |nexts| for (nexts.items) |n| try dfsFinishOrder(a, n, adj, visited, finish);
    try finish.append(a, id);
}
