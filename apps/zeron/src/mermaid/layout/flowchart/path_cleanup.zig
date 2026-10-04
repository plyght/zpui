//! `layout/flowchart/path_cleanup.rs`: post-routing crossing reduction,
//! de-overlap, detours around foreign nodes/subgraphs and endpoint repairs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../../ir.zig");
const util = @import("../../util.zig");
const LayoutConfig = @import("../../config.zig").LayoutConfig;
const t = @import("../types.zig");
const geometry = @import("../geometry.zig");
const routing = @import("../routing.zig");
const Graph = ir.Graph;
const NodeMap = t.NodeMap;
const NodeLayout = t.NodeLayout;
const SubgraphLayout = t.SubgraphLayout;
const Point = t.Point;
const Obstacle = routing.Obstacle;
const Segment = routing.Segment;
const compressPath = routing.compressPath;
const pathLength = geometry.pathLength;
const pathBendCount = geometry.pathBendCount;
const segmentIntersectsRect = routing.segmentIntersectsRect;
const FMAX = std.math.floatMax(f32);
const FMIN = -std.math.floatMax(f32);
const INF = std.math.inf(f32);

fn overlapWithPrior(path: []const Point, prior: []const []Point) f32 {
    var overlap: f32 = 0;
    if (path.len < 2) return 0;
    for (0..path.len - 1) |i| for (prior) |other| {
        if (other.len < 2) continue;
        for (0..other.len - 1) |j| overlap += routing.collinearOverlapLength(path[i], path[i + 1], other[j], other[j + 1]);
    };
    return overlap;
}

fn appendSegments(a: Allocator, path: []const Point, segs: *std.ArrayList(Segment)) Allocator.Error!void {
    if (path.len < 2) return;
    for (0..path.len - 1) |i| try segs.append(a, .{ path[i], path[i + 1] });
}

fn perimeterCandidates(s: Point, e: Point, l: f32, r: f32, tp: f32, b: f32) [4][6]Point {
    return .{
        .{ s, .{ r, s[1] }, .{ r, b }, .{ l, b }, .{ l, e[1] }, e },
        .{ s, .{ r, s[1] }, .{ r, tp }, .{ l, tp }, .{ l, e[1] }, e },
        .{ s, .{ l, s[1] }, .{ l, b }, .{ r, b }, .{ r, e[1] }, e },
        .{ s, .{ l, s[1] }, .{ l, tp }, .{ r, tp }, .{ r, e[1] }, e },
    };
}

const Outer = struct { left: f32, right: f32, top: f32, bottom: f32 };

fn reduceCrossingSweep(a: Allocator, order: []const usize, graph: *const Graph, nodes: *const NodeMap, routed: [][]Point, deltas: []const f32, use_perimeter: bool, outer: Outer) Allocator.Error!bool {
    var changed = false;
    var existing: std.ArrayList(Segment) = .empty;
    const HARD: f32 = 2.8;
    const NO_GAIN: f32 = 1.12;
    const ONE_GAIN: f32 = 1.8;
    const MULTI_GAIN: f32 = 2.6;
    for (order) |idx| {
        if (routed[idx].len < 2) {
            try appendSegments(a, routed[idx], &existing);
            continue;
        }
        const from_id = graph.edges.items[idx].from;
        const to_id = graph.edges.items[idx].to;
        const base = routing.edgeCrossingsWithExisting(routed[idx], existing.items);
        if (base[0] == 0) {
            try appendSegments(a, routed[idx], &existing);
            continue;
        }
        var best_cross = base[0];
        var best_overlap = base[1];
        const base_len = pathLength(routed[idx]);
        var best_len = base_len;
        var best_points = routed[idx];
        const segs = routed[idx].len -| 1;
        for (0..segs) |si| for (deltas) |d| {
            const cand = (try bumpOrthogonalSegment(a, routed[idx], si, d)) orelse continue;
            if (flowchartPathHitsNonEndpointNodes(cand, from_id, to_id, nodes)) continue;
            const r = routing.edgeCrossingsWithExisting(cand, existing.items);
            const len = pathLength(cand);
            if (len > base_len * HARD) continue;
            if (r[0] < best_cross or (r[0] == best_cross and r[1] + 0.05 < best_overlap) or (r[0] == best_cross and @abs(r[1] - best_overlap) <= 0.05 and len + 1.0 < best_len)) {
                best_cross = r[0];
                best_overlap = r[1];
                best_len = len;
                best_points = cand;
            }
        };
        if (use_perimeter) {
            const s = routed[idx][0];
            const e = routed[idx][routed[idx].len - 1];
            for (perimeterCandidates(s, e, outer.left, outer.right, outer.top, outer.bottom)) |pc| {
                const cand = try compressPath(a, &pc);
                if (flowchartPathHitsNonEndpointNodes(cand, from_id, to_id, nodes)) continue;
                const r = routing.edgeCrossingsWithExisting(cand, existing.items);
                const len = pathLength(cand);
                if (len > base_len * HARD) continue;
                const gain = base[0] -| r[0];
                const max_ratio = if (gain >= 2) MULTI_GAIN else if (gain == 1) ONE_GAIN else NO_GAIN;
                if (len > base_len * max_ratio) continue;
                if (r[0] < best_cross or (r[0] == best_cross and r[1] + 0.05 < best_overlap) or (r[0] == best_cross and @abs(r[1] - best_overlap) <= 0.05 and len + 1.0 < best_len)) {
                    best_cross = r[0];
                    best_overlap = r[1];
                    best_len = len;
                    best_points = cand;
                }
            }
        }
        const gain = base[0] -| best_cross;
        const max_ratio = if (gain >= 2) MULTI_GAIN else if (gain == 1) ONE_GAIN else NO_GAIN;
        const allow = best_len <= base_len * max_ratio;
        if (best_cross < base[0] or (best_cross == base[0] and best_overlap + 0.05 < base[1])) {
            if (!allow) {
                try appendSegments(a, routed[idx], &existing);
                continue;
            }
            routed[idx] = best_points;
            changed = true;
        }
        try appendSegments(a, routed[idx], &existing);
    }
    return changed;
}

fn visibleNode(n: *const NodeLayout) bool {
    return !n.hidden and n.anchor_subgraph == null;
}

pub fn reduceOrthogonalPathCrossings(a: Allocator, graph: *const Graph, nodes: *const NodeMap, routed: [][]Point, config: *const LayoutConfig) Allocator.Error!void {
    if (graph.edges.items.len < 2) return;
    const bd = @max(config.node_spacing * 0.22, 8.0);
    const deltas = [_]f32{ bd, -bd, bd * 1.5, -bd * 1.5, bd * 2.0, -bd * 2.0, bd * 3.0, -bd * 3.0, bd * 4.0, -bd * 4.0 };
    var min_x: f32 = FMAX;
    var max_x: f32 = FMIN;
    var min_y: f32 = FMAX;
    var max_y: f32 = FMIN;
    for (nodes.values()) |*n| if (visibleNode(n)) {
        min_x = @min(min_x, n.x);
        max_x = @max(max_x, n.x + n.width);
        min_y = @min(min_y, n.y);
        max_y = @max(max_y, n.y + n.height);
    };
    const pad = @max(config.node_spacing * 0.8, 24.0);
    const outer: Outer = .{ .left = min_x - pad, .right = max_x + pad, .top = min_y - pad, .bottom = max_y + pad };
    const use_perimeter = graph.kind == .er or graph.kind == .state;
    const fwd = try a.alloc(usize, routed.len);
    const rev = try a.alloc(usize, routed.len);
    for (0..routed.len) |i| {
        fwd[i] = i;
        rev[i] = routed.len - 1 - i;
    }
    for (0..3) |_| {
        var changed = try reduceCrossingSweep(a, fwd, graph, nodes, routed, &deltas, use_perimeter, outer);
        changed = (try reduceCrossingSweep(a, rev, graph, nodes, routed, &deltas, use_perimeter, outer)) or changed;
        if (!changed) break;
    }
}

fn nodeRect(n: *const NodeLayout) Obstacle {
    return .{ .id = n.id, .x = n.x, .y = n.y, .width = n.width, .height = n.height };
}

fn skipNode(n: *const NodeLayout, from_id: []const u8, to_id: []const u8) bool {
    return util.eql(n.id, from_id) or util.eql(n.id, to_id) or n.hidden or n.anchor_subgraph != null;
}

pub fn flowchartPathHitsNonEndpointNodes(path: []const Point, from_id: []const u8, to_id: []const u8, nodes: *const NodeMap) bool {
    if (path.len < 2) return false;
    for (0..path.len - 1) |i| for (nodes.values()) |*n| {
        if (skipNode(n, from_id, to_id)) continue;
        const o = nodeRect(n);
        if (segmentIntersectsRect(path[i], path[i + 1], &o)) return true;
    };
    return false;
}

fn nonEndpointHitCount(path: []const Point, from_id: []const u8, to_id: []const u8, nodes: *const NodeMap) usize {
    if (path.len < 2) return 0;
    var count: usize = 0;
    for (nodes.values()) |*n| {
        if (skipNode(n, from_id, to_id)) continue;
        const o = nodeRect(n);
        for (0..path.len - 1) |i| {
            if (segmentIntersectsRect(path[i], path[i + 1], &o)) {
                count += 1;
                break;
            }
        }
    }
    return count;
}

const Hit = struct { first: usize, last: usize, obstacle: Obstacle };

fn firstNonEndpointNodeHit(a: Allocator, path: []const Point, from_id: []const u8, to_id: []const u8, nodes: *const NodeMap) Allocator.Error!?Hit {
    if (path.len < 2) return null;
    for (0..path.len - 1) |si| {
        for (nodes.values()) |*n| {
            if (skipNode(n, from_id, to_id)) continue;
            const o = nodeRect(n);
            if (!segmentIntersectsRect(path[si], path[si + 1], &o)) continue;
            var merged = o;
            var last = si;
            for (si..path.len - 1) |li| for (nodes.values()) |*other| {
                if (skipNode(other, from_id, to_id)) continue;
                const oo = nodeRect(other);
                if (segmentIntersectsRect(path[li], path[li + 1], &oo)) {
                    last = li;
                    try mergeObstacle(a, &merged, &oo);
                }
            };
            return .{ .first = si, .last = last, .obstacle = merged };
        }
    }
    return null;
}

fn mergeObstacle(a: Allocator, target: *Obstacle, other: *const Obstacle) Allocator.Error!void {
    const mnx = @min(target.x, other.x);
    const mny = @min(target.y, other.y);
    const mxx = @max(target.x + target.width, other.x + other.width);
    const mxy = @max(target.y + target.height, other.y + other.height);
    target.id = try std.fmt.allocPrint(a, "{s}+{s}", .{ target.id, other.id });
    target.x = mnx;
    target.y = mny;
    target.width = mxx - mnx;
    target.height = mxy - mny;
}

fn splice(a: Allocator, path: []const Point, keep_to: usize, route: []const Point, resume_at: usize) Allocator.Error![]Point {
    var c: std.ArrayList(Point) = .empty;
    try c.appendSlice(a, path[0 .. keep_to + 1]);
    if (route.len > 2) try c.appendSlice(a, route[1 .. route.len - 1]);
    try c.appendSlice(a, path[resume_at..]);
    return compressPath(a, c.items);
}

fn nodeDetourCandidates(a: Allocator, path: []const Point, first: usize, last: usize, o: *const Obstacle, clearance: f32) Allocator.Error![]const []Point {
    if (first + 1 >= path.len or last + 1 >= path.len) return &.{};
    var out: std.ArrayList([]Point) = .empty;
    for (perimeterCandidates(path[first], path[last + 1], o.x - clearance, o.x + o.width + clearance, o.y - clearance, o.y + o.height + clearance)) |r| {
        try out.append(a, try splice(a, path, first, &r, last + 1));
    }
    return out.items;
}

fn graphExtent(nodes: *const NodeMap, from_id: []const u8, to_id: []const u8) ?[4]f32 {
    var l = INF;
    var r = -INF;
    var tp = INF;
    var b = -INF;
    for (nodes.values()) |*n| {
        if (skipNode(n, from_id, to_id)) continue;
        l = @min(l, n.x);
        r = @max(r, n.x + n.width);
        tp = @min(tp, n.y);
        b = @max(b, n.y + n.height);
    }
    if (!std.math.isFinite(l) or !std.math.isFinite(r) or !std.math.isFinite(tp) or !std.math.isFinite(b)) return null;
    return .{ l, r, tp, b };
}

fn graphDetourCandidates(a: Allocator, path: []const Point, first: usize, last: usize, nodes: *const NodeMap, from_id: []const u8, to_id: []const u8, clearance: f32) Allocator.Error![]const []Point {
    if (first + 1 >= path.len or last + 1 >= path.len) return &.{};
    const ext = graphExtent(nodes, from_id, to_id) orelse return &.{};
    var out: std.ArrayList([]Point) = .empty;
    for (perimeterCandidates(path[first], path[last + 1], ext[0] - clearance, ext[1] + clearance, ext[2] - clearance, ext[3] + clearance)) |r| {
        try out.append(a, try splice(a, path, first, &r, last + 1));
    }
    return out.items;
}

fn graphPerimeterDetourCandidates(a: Allocator, path: []const Point, nodes: *const NodeMap, from_id: []const u8, to_id: []const u8, clearance: f32) Allocator.Error![]const []Point {
    if (path.len < 2) return &.{};
    const ext = graphExtent(nodes, from_id, to_id) orelse return &.{};
    var out: std.ArrayList([]Point) = .empty;
    for (perimeterCandidates(path[0], path[path.len - 1], ext[0] - clearance, ext[1] + clearance, ext[2] - clearance, ext[3] + clearance)) |r| {
        try out.append(a, try compressPath(a, &r));
    }
    return out.items;
}

pub fn detourAroundNonEndpointNodes(a: Allocator, graph: *const Graph, nodes: *const NodeMap, routed: [][]Point, config: *const LayoutConfig) Allocator.Error!void {
    const clearance = @max(config.node_spacing * 0.12, 8.0);
    for (routed, 0..) |*points, idx| {
        if (idx >= graph.edges.items.len) continue;
        const edge = &graph.edges.items[idx];
        for (0..8) |_| {
            const hit = (try firstNonEndpointNodeHit(a, points.*, edge.from, edge.to, nodes)) orelse break;
            var best: ?[]Point = null;
            var best_cost = INF;
            var best_hits: usize = std.math.maxInt(usize);
            for ([_]f32{ 1.0, 1.5, 2.0, 3.0, 4.0 }) |scale| {
                const cc = clearance * scale;
                for ([_][]const []Point{
                    try nodeDetourCandidates(a, points.*, hit.first, hit.last, &hit.obstacle, cc),
                    try graphDetourCandidates(a, points.*, hit.first, hit.last, nodes, edge.from, edge.to, cc),
                }) |list| for (list) |cand| {
                    const hits = nonEndpointHitCount(cand, edge.from, edge.to, nodes);
                    const cost = pathLength(cand) + @as(f32, @floatFromInt(pathBendCount(cand))) * cc;
                    if (hits < best_hits or (hits == best_hits and cost < best_cost)) {
                        best_hits = hits;
                        best_cost = cost;
                        best = cand;
                    }
                };
            }
            if (best == null) {
                for (try graphPerimeterDetourCandidates(a, points.*, nodes, edge.from, edge.to, clearance * 2.0)) |cand| {
                    if (flowchartPathHitsNonEndpointNodes(cand, edge.from, edge.to, nodes)) continue;
                    const cost = pathLength(cand) + @as(f32, @floatFromInt(pathBendCount(cand))) * clearance;
                    if (cost < best_cost) {
                        best_cost = cost;
                        best = cand;
                    }
                }
            }
            points.* = best orelse break;
        }
    }
}

fn foreignSubgraphObstacles(a: Allocator, from: []const u8, to: []const u8, subgraphs: []const SubgraphLayout, clearance: f32) Allocator.Error![]Obstacle {
    var out: std.ArrayList(Obstacle) = .empty;
    for (subgraphs) |sub| {
        var member = false;
        for (sub.nodes) |id| member = member or util.eql(id, from) or util.eql(id, to);
        if (member) continue;
        if (util.eql(sub.label, from) or util.eql(sub.label, to)) continue;
        if (sub.width <= 0.0 or sub.height <= 0.0) continue;
        try out.append(a, .{ .id = sub.label, .x = sub.x - clearance, .y = sub.y - clearance, .width = sub.width + clearance * 2.0, .height = sub.height + clearance * 2.0 });
    }
    return out.items;
}

fn pathForeignSubgraphHits(path: []const Point, obstacles: []const Obstacle) usize {
    var hits: usize = 0;
    if (path.len < 2) return 0;
    for (obstacles) |*o| {
        for (0..path.len - 1) |i| {
            if (segmentIntersectsRect(path[i], path[i + 1], o)) {
                hits += 1;
                break;
            }
        }
    }
    return hits;
}

fn firstForeignSubgraphHit(path: []const Point, obstacles: []const Obstacle) ?Hit {
    if (path.len < 2) return null;
    for (0..path.len - 1) |si| for (obstacles) |*o| {
        if (!segmentIntersectsRect(path[si], path[si + 1], o)) continue;
        var last = si;
        for (si..path.len - 1) |li| if (segmentIntersectsRect(path[li], path[li + 1], o)) {
            last = li;
        };
        return .{ .first = si, .last = last, .obstacle = o.* };
    };
    return null;
}

pub fn detourAroundForeignSubgraphs(a: Allocator, graph: *const Graph, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, routed: [][]Point, config: *const LayoutConfig) Allocator.Error!void {
    if (subgraphs.len == 0) return;
    const clearance = @max(config.node_spacing * 0.12, 8.0);
    for (routed, 0..) |*points, idx| {
        if (idx >= graph.edges.items.len) continue;
        const edge = &graph.edges.items[idx];
        if (util.eql(edge.from, edge.to)) continue;
        const obstacles = try foreignSubgraphObstacles(a, edge.from, edge.to, subgraphs, 0.0);
        if (obstacles.len == 0) continue;
        for (0..6) |_| {
            const hit = firstForeignSubgraphHit(points.*, obstacles) orelse break;
            var best_hits = [2]usize{ pathForeignSubgraphHits(points.*, obstacles), nonEndpointHitCount(points.*, edge.from, edge.to, nodes) };
            var best: ?[]Point = null;
            var best_cost = INF;
            for ([_]f32{ 1.0, 1.5, 2.0, 3.0 }) |scale| {
                const cc = clearance * scale;
                for (try nodeDetourCandidates(a, points.*, hit.first, hit.last, &hit.obstacle, cc)) |cand| {
                    const hits = [2]usize{ pathForeignSubgraphHits(cand, obstacles), nonEndpointHitCount(cand, edge.from, edge.to, nodes) };
                    const cost = pathLength(cand) + @as(f32, @floatFromInt(pathBendCount(cand))) * cc;
                    const lt = hits[0] < best_hits[0] or (hits[0] == best_hits[0] and hits[1] < best_hits[1]);
                    const eq = hits[0] == best_hits[0] and hits[1] == best_hits[1];
                    if (lt or (eq and cost < best_cost)) {
                        best_hits = hits;
                        best_cost = cost;
                        best = cand;
                    }
                }
            }
            points.* = best orelse break;
        }
    }
}

fn endpointReentryCount(points: []const Point, node: *const NodeLayout, is_source: bool) usize {
    if (points.len < 3) return 0;
    const last_seg = points.len - 2;
    var c: usize = 0;
    for (0..points.len - 1) |i| {
        const allowed = if (is_source) i == 0 else i == last_seg;
        if (!allowed and geometry.segmentHitsNodeShapeInterior(points[i], points[i + 1], node)) c += 1;
    }
    return c;
}

pub fn flowchartEndpointReentryCount(points: []const Point, edge: *const ir.Edge, nodes: *const NodeMap) usize {
    var count: usize = 0;
    if (nodes.get(edge.from)) |f| count += endpointReentryCount(points, f, true);
    if (!util.eql(edge.to, edge.from)) if (nodes.get(edge.to)) |tn| {
        count += endpointReentryCount(points, tn, false);
    };
    return count;
}

fn firstEndpointReentrySpan(points: []const Point, node: *const NodeLayout, is_source: bool) ?[2]usize {
    if (points.len < 3) return null;
    const last_seg = points.len - 2;
    var idx: usize = 0;
    while (idx < last_seg + 1) : (idx += 1) {
        const allowed = if (is_source) idx == 0 else idx == last_seg;
        if (!allowed and geometry.segmentHitsNodeShapeInterior(points[idx], points[idx + 1], node)) {
            var last = idx;
            while (last < last_seg) {
                const n = last + 1;
                const n_allowed = if (is_source) n == 0 else n == last_seg;
                if (n_allowed or !geometry.segmentHitsNodeShapeInterior(points[n], points[n + 1], node)) break;
                last = n;
            }
            return .{ idx, last };
        }
    }
    return null;
}

pub fn flowchartEndpointDirectionViolationCount(points: []const Point, edge: *const ir.Edge, nodes: *const NodeMap) usize {
    if (points.len < 2) return 2;
    var v: usize = 0;
    if (nodes.get(edge.from)) |f| {
        const side = geometry.endpointSideForPoint(f, points[0]);
        if (!geometry.sourceExitsOutward(side, points[0], points[1])) v += 1;
        if (geometry.segmentIntrudesEndpointRect(side, points[1], points[0], f)) v += 1;
    }
    if (nodes.get(edge.to)) |tn| {
        const end = points[points.len - 1];
        const prev = points[points.len - 2];
        const side = geometry.endpointSideForPoint(tn, end);
        if (!geometry.targetEntersFromOutside(side, prev, end)) v += 1;
        if (geometry.segmentIntrudesEndpointRect(side, prev, end, tn)) v += 1;
    }
    return v;
}

fn endpointReentryDetourCandidates(a: Allocator, path: []const Point, first: usize, last: usize, o: *const Obstacle, clearance: f32, is_source: bool) Allocator.Error![]const []Point {
    if (first + 1 >= path.len or last + 1 >= path.len) return &.{};
    const start_idx = if (first > 0 and (!is_source or first > 1)) first - 1 else first;
    const end_idx = last + 1;
    if (start_idx >= end_idx or end_idx >= path.len) return &.{};
    var out: std.ArrayList([]Point) = .empty;
    for (perimeterCandidates(path[start_idx], path[end_idx], o.x - clearance, o.x + o.width + clearance, o.y - clearance, o.y + o.height + clearance)) |r| {
        try out.append(a, try splice(a, path, start_idx, &r, end_idx));
    }
    return out.items;
}

fn repairEndpointReentryOnce(a: Allocator, points: []const Point, edge: *const ir.Edge, nodes: *const NodeMap, config: *const LayoutConfig) Allocator.Error!?[]Point {
    const base_re = flowchartEndpointReentryCount(points, edge, nodes);
    if (base_re == 0 or flowchartEndpointDirectionViolationCount(points, edge, nodes) > 0) return null;
    const base_len = pathLength(points);
    const clearance = @max(config.node_spacing * 0.12, 8.0);
    var best: ?[]Point = null;
    var best_re = base_re;
    var best_cost = INF;
    const Spec = struct { node: *const NodeLayout, src: bool };
    var specs: [2]Spec = undefined;
    var ns: usize = 0;
    if (nodes.get(edge.from)) |f| {
        specs[ns] = .{ .node = f, .src = true };
        ns += 1;
    }
    if (!util.eql(edge.to, edge.from)) if (nodes.get(edge.to)) |tn| {
        specs[ns] = .{ .node = tn, .src = false };
        ns += 1;
    };
    for (specs[0..ns]) |sp| {
        const span = firstEndpointReentrySpan(points, sp.node, sp.src) orelse continue;
        const o = nodeRect(sp.node);
        for ([_]f32{ 1.0, 1.5, 2.0, 3.0, 4.0 }) |scale| {
            const cc = clearance * scale;
            for ([_][]const []Point{
                try nodeDetourCandidates(a, points, span[0], span[1], &o, cc),
                try endpointReentryDetourCandidates(a, points, span[0], span[1], &o, cc, sp.src),
            }) |list| for (list) |cand| {
                if (flowchartEndpointDirectionViolationCount(cand, edge, nodes) > 0) continue;
                if (flowchartPathHitsNonEndpointNodes(cand, edge.from, edge.to, nodes)) continue;
                const re = flowchartEndpointReentryCount(cand, edge, nodes);
                if (re >= best_re) continue;
                const len = pathLength(cand);
                if (len > base_len * 4.0 + clearance * 8.0) continue;
                const cost = len + @as(f32, @floatFromInt(pathBendCount(cand))) * clearance + @as(f32, @floatFromInt(re)) * clearance * 20.0;
                if (re < best_re or cost < best_cost) {
                    best_re = re;
                    best_cost = cost;
                    best = cand;
                }
            };
        }
    }
    if (best_re < base_re) return best;
    return null;
}

pub fn repairFlowchartEndpointReentries(a: Allocator, graph: *const Graph, nodes: *const NodeMap, routed: [][]Point, config: *const LayoutConfig) Allocator.Error!void {
    for (routed, 0..) |*points, idx| {
        if (idx >= graph.edges.items.len) continue;
        for (0..6) |_| points.* = (try repairEndpointReentryOnce(a, points.*, &graph.edges.items[idx], nodes, config)) orelse break;
    }
}

fn bumpOrthogonalSegment(a: Allocator, points: []const Point, si: usize, delta: f32) Allocator.Error!?[]Point {
    if (si + 1 >= points.len) return null;
    const p = points[si];
    const q = points[si + 1];
    const horizontal = @abs(p[1] - q[1]) < 1e-3;
    const vertical = @abs(p[0] - q[0]) < 1e-3;
    if (!horizontal and !vertical) return null;
    var b: std.ArrayList(Point) = .empty;
    try b.appendSlice(a, points[0 .. si + 1]);
    if (horizontal) {
        try b.append(a, .{ p[0], p[1] + delta });
        try b.append(a, .{ q[0], p[1] + delta });
    } else {
        try b.append(a, .{ p[0] + delta, p[1] });
        try b.append(a, .{ p[0] + delta, q[1] });
    }
    try b.appendSlice(a, points[si + 1 ..]);
    return try compressPath(a, b.items);
}

pub fn deoverlapFlowchartPaths(a: Allocator, graph: *const Graph, nodes: *const NodeMap, routed: [][]Point, config: *const LayoutConfig) Allocator.Error!void {
    if (graph.edges.items.len < 2) return;
    const threshold: f32 = 0.68;
    const bd = @max(config.node_spacing * 0.25, 8.0);
    const deltas = [_]f32{ bd, -bd, bd * 1.5, -bd * 1.5, bd * 2.0, -bd * 2.0, bd * 2.8, -bd * 2.8 };
    const min_seg = @max(bd * 1.2, 6.0);
    for (0..4) |_| {
        var changed = false;
        for (1..routed.len) |idx| {
            if (routed[idx].len < 2) continue;
            const from_id = graph.edges.items[idx].from;
            const to_id = graph.edges.items[idx].to;
            const baseline = overlapWithPrior(routed[idx], routed[0..idx]);
            if (baseline < threshold) continue;
            var best_overlap = baseline;
            var best_points = routed[idx];
            const SL = struct { i: usize, len: f32 };
            var order: std.ArrayList(SL) = .empty;
            for (0..routed[idx].len - 1) |si| {
                const dx = routed[idx][si + 1][0] - routed[idx][si][0];
                const dy = routed[idx][si + 1][1] - routed[idx][si][1];
                try order.append(a, .{ .i = si, .len = @sqrt(dx * dx + dy * dy) });
            }
            std.mem.sort(SL, order.items, {}, struct {
                fn lt(_: void, x: SL, y: SL) bool {
                    return y.len < x.len;
                }
            }.lt);
            for (order.items) |sl| {
                if (sl.len < min_seg) continue;
                for (deltas) |d| {
                    const cand = (try bumpOrthogonalSegment(a, routed[idx], sl.i, d)) orelse continue;
                    if (flowchartPathHitsNonEndpointNodes(cand, from_id, to_id, nodes)) continue;
                    const ov = overlapWithPrior(cand, routed[0..idx]);
                    if (ov + 0.03 < best_overlap) {
                        best_overlap = ov;
                        best_points = cand;
                    }
                }
            }
            if (best_overlap + 0.03 < baseline) {
                routed[idx] = best_points;
                changed = true;
            }
        }
        if (!changed) break;
    }
}

fn isAxisAligned(p: Point, q: Point) bool {
    return @abs(p[0] - q[0]) <= 1e-3 or @abs(p[1] - q[1]) <= 1e-3;
}

fn collapseNearAxisAlignedPath(a: Allocator, points: []const Point) Allocator.Error!?[]Point {
    if (points.len < 3) return null;
    var min_x: f32 = FMAX;
    var max_x: f32 = FMIN;
    var min_y: f32 = FMAX;
    var max_y: f32 = FMIN;
    for (points) |p| {
        min_x = @min(min_x, p[0]);
        max_x = @max(max_x, p[0]);
        min_y = @min(min_y, p[1]);
        max_y = @max(max_y, p[1]);
    }
    const eps: f32 = 1.0;
    var nv = true;
    var nh = true;
    for (0..points.len - 1) |i| {
        nv = nv and @abs(points[i + 1][0] - points[i][0]) <= eps;
        nh = nh and @abs(points[i + 1][1] - points[i][1]) <= eps;
    }
    if (max_x - min_x <= eps and max_y - min_y > eps and nv) {
        const x = (min_x + max_x) * 0.5;
        return try a.dupe(Point, &.{ .{ x, points[0][1] }, .{ x, points[points.len - 1][1] } });
    }
    if (max_y - min_y <= eps and max_x - min_x > eps and nh) {
        const y = (min_y + max_y) * 0.5;
        return try a.dupe(Point, &.{ .{ points[0][0], y }, .{ points[points.len - 1][0], y } });
    }
    return null;
}

fn collapseAxisAlignedRuns(a: Allocator, points: []const Point) Allocator.Error![]Point {
    if (points.len <= 2) return a.dupe(Point, points);
    var c: std.ArrayList(Point) = .empty;
    try c.append(a, points[0]);
    var idx: usize = 0;
    while (idx + 1 < points.len) {
        const cur = points[idx];
        const next = points[idx + 1];
        const same_x = @abs(next[0] - cur[0]) <= 1e-3;
        const same_y = @abs(next[1] - cur[1]) <= 1e-3;
        const tail = c.items[c.items.len - 1];
        if (!same_x and !same_y) {
            if (@abs(next[0] - tail[0]) > 1e-3 or @abs(next[1] - tail[1]) > 1e-3) try c.append(a, next);
            idx += 1;
            continue;
        }
        var end_idx = idx + 1;
        while (end_idx + 1 < points.len) {
            const cand = points[end_idx + 1];
            const cont = if (same_x) @abs(cand[0] - cur[0]) <= 1e-3 else @abs(cand[1] - cur[1]) <= 1e-3;
            if (!cont) break;
            end_idx += 1;
        }
        const term = points[end_idx];
        if (@abs(term[0] - tail[0]) > 1e-3 or @abs(term[1] - tail[1]) > 1e-3) try c.append(a, term);
        idx = end_idx;
    }
    return compressPath(a, c.items);
}

pub fn simplifyAxisOscillations(a: Allocator, routed: [][]Point) Allocator.Error!void {
    for (routed) |*path| {
        const collapsed = try collapseAxisAlignedRuns(a, path.*);
        path.* = (try collapseNearAxisAlignedPath(a, collapsed)) orelse collapsed;
    }
}

fn verticalPattern(points: []const Point, out: *[5]bool) void {
    for (0..5) |i| out[i] = @abs(points[i][0] - points[i + 1][0]) <= 1e-3;
}

fn detourRectangleCandidates(a: Allocator, points: []const Point, out: *std.ArrayList([]Point)) Allocator.Error!void {
    if (points.len != 6) return;
    for (0..5) |i| if (!isAxisAligned(points[i], points[i + 1])) return;
    const vf = @abs(points[0][0] - points[1][0]) <= 1e-3;
    var pat: [5]bool = undefined;
    verticalPattern(points, &pat);
    for (pat, 0..) |v, i| if (v != (if (i % 2 == 0) vf else !vf)) return;
    if (vf) {
        for ([_]f32{ points[1][1], points[3][1] }) |cy| try out.append(a, try compressPath(a, &.{ points[0], .{ points[0][0], cy }, .{ points[5][0], cy }, points[5] }));
    } else {
        for ([_]f32{ points[1][0], points[3][0] }) |cx| try out.append(a, try compressPath(a, &.{ points[0], .{ cx, points[0][1] }, .{ cx, points[5][1] }, points[5] }));
    }
}

fn shoulderCandidates(a: Allocator, points: []const Point, out: *std.ArrayList([]Point)) Allocator.Error!void {
    if (points.len != 6) return;
    var pat: [5]bool = undefined;
    verticalPattern(points, &pat);
    if (std.mem.eql(bool, &pat, &.{ true, false, true, false, true })) {
        try out.append(a, try compressPath(a, &.{ points[0], points[1], points[2], .{ points[2][0], points[5][1] }, points[5] }));
        try out.append(a, try compressPath(a, &.{ points[0], .{ points[0][0], points[3][1] }, points[3], points[4], points[5] }));
    } else if (std.mem.eql(bool, &pat, &.{ false, true, false, true, false })) {
        try out.append(a, try compressPath(a, &.{ points[0], points[1], points[2], .{ points[5][0], points[2][1] }, points[5] }));
        try out.append(a, try compressPath(a, &.{ points[0], .{ points[3][0], points[0][1] }, points[3], points[4], points[5] }));
    }
}

fn onVerticalEdge(p: Point, n: *const NodeLayout) bool {
    const on = @abs(p[1] - n.y) <= 3.0 or @abs(p[1] - (n.y + n.height)) <= 3.0;
    return on and p[0] >= n.x - 3.0 and p[0] <= n.x + n.width + 3.0;
}

fn onHorizontalEdge(p: Point, n: *const NodeLayout) bool {
    const on = @abs(p[0] - n.x) <= 3.0 or @abs(p[0] - (n.x + n.width)) <= 3.0;
    return on and p[1] >= n.y - 3.0 and p[1] <= n.y + n.height + 3.0;
}

fn sortedLevels(a: Allocator, vals: []f32) Allocator.Error![]f32 {
    std.mem.sort(f32, vals, {}, std.sort.asc(f32));
    var out: std.ArrayList(f32) = .empty;
    for (vals) |v| {
        if (out.items.len > 0 and @abs(v - out.items[out.items.len - 1]) <= 1e-3) continue;
        try out.append(a, v);
    }
    return out.items;
}

fn spineCandidates(a: Allocator, points: []const Point, from: *const NodeLayout, to: *const NodeLayout, out: *std.ArrayList([]Point)) Allocator.Error!void {
    if (points.len < 4) return;
    const fc = Point{ from.x + from.width * 0.5, from.y + from.height * 0.5 };
    const tc = Point{ to.x + to.width * 0.5, to.y + to.height * 0.5 };
    const dom_v = @abs(tc[1] - fc[1]) >= @abs(tc[0] - fc[0]);
    const last = points[points.len - 1];
    const fov = onVerticalEdge(points[0], from);
    const lov = onVerticalEdge(last, to);
    const foh = onHorizontalEdge(points[0], from);
    const loh = onHorizontalEdge(last, to);
    const first_v = fov or (!foh and dom_v);
    const last_v = lov or (!loh and dom_v);
    const first_h = foh or (!fov and !dom_v);
    const last_h = loh or (!lov and !dom_v);
    const inner = points[1 .. points.len - 1];
    if (first_v and last_v) {
        const vals = try a.alloc(f32, inner.len);
        for (inner, 0..) |p, i| vals[i] = p[1];
        for (try sortedLevels(a, vals)) |cy| try out.append(a, try compressPath(a, &.{ points[0], .{ points[0][0], cy }, .{ last[0], cy }, last }));
    } else if (first_h and last_h) {
        const vals = try a.alloc(f32, inner.len);
        for (inner, 0..) |p, i| vals[i] = p[0];
        for (try sortedLevels(a, vals)) |cx| try out.append(a, try compressPath(a, &.{ points[0], .{ cx, points[0][1] }, .{ cx, last[1] }, last }));
    }
}

pub fn simplifyDetourRectangles(a: Allocator, graph: *const Graph, nodes: *const NodeMap, routed: [][]Point) Allocator.Error!void {
    if (graph.edges.items.len < 2) return;
    for (0..routed.len) |idx| {
        const baseline = routed[idx];
        const base_bends = pathBendCount(baseline);
        if (base_bends < 4) continue;
        const from_id = graph.edges.items[idx].from;
        const to_id = graph.edges.items[idx].to;
        var others: std.ArrayList(Segment) = .empty;
        for (routed, 0..) |p, oi| if (oi != idx) try appendSegments(a, p, &others);
        const base = routing.edgeCrossingsWithExisting(baseline, others.items);
        var best = baseline;
        var best_bends = base_bends;
        var best_cross = base[0];
        var best_overlap = base[1];
        var best_len = pathLength(baseline);
        const from = nodes.get(from_id) orelse continue;
        const to = nodes.get(to_id) orelse continue;
        var cands: std.ArrayList([]Point) = .empty;
        try detourRectangleCandidates(a, baseline, &cands);
        try shoulderCandidates(a, baseline, &cands);
        try spineCandidates(a, baseline, from, to, &cands);
        for (cands.items) |c| {
            if (c.len >= baseline.len) continue;
            if (flowchartPathHitsNonEndpointNodes(c, from_id, to_id, nodes)) continue;
            const bends = pathBendCount(c);
            if (bends >= best_bends) continue;
            const r = routing.edgeCrossingsWithExisting(c, others.items);
            const len = pathLength(c);
            const better = r[0] < best_cross or (r[0] == best_cross and r[1] <= best_overlap + 0.05 and bends < best_bends) or
                (r[0] == best_cross and @abs(r[1] - best_overlap) <= 0.05 and bends == best_bends and len + 1.0 < best_len);
            if (better) {
                best = c;
                best_bends = bends;
                best_cross = r[0];
                best_overlap = r[1];
                best_len = len;
            }
        }
        if (best_bends < base_bends and best_cross <= base[0]) routed[idx] = best;
    }
}
