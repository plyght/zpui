//! `layout/flowchart/edge_pipeline.rs` (+ `roles.rs`, `plan.rs` lane planning,
//! `route_labels.rs` and `post_route.rs`): port side selection, port offset
//! distribution and refinement, routing, global optimization and cleanup.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../../ir.zig");
const util = @import("../../util.zig");
const LayoutConfig = @import("../../config.zig").LayoutConfig;
const t = @import("../types.zig");
const L = @import("../layout.zig");
const geometry = @import("../geometry.zig");
const routing = @import("../routing.zig");
const ranking = @import("../ranking.zig");
const sg = @import("../subgraphs.zig");
const pc = @import("path_cleanup.zig");
const Graph = ir.Graph;
const Edge = ir.Edge;
const NodeMap = t.NodeMap;
const NodeLayout = t.NodeLayout;
const SubgraphLayout = t.SubgraphLayout;
const EdgeLayout = t.EdgeLayout;
const TextBlock = t.TextBlock;
const Point = t.Point;
const EdgeSide = routing.EdgeSide;
const EdgePortInfo = routing.EdgePortInfo;
const Obstacle = routing.Obstacle;
const Segment = routing.Segment;
const Sides = routing.Sides;
const RouteContext = routing.RouteContext;
const isHorizontal = routing.isHorizontal;
const FMAX = std.math.floatMax(f32);
const FMIN = -std.math.floatMax(f32);
const INF = std.math.inf(f32);

// ---- roles.rs ---------------------------------------------------------------------------

pub const EdgeRole = struct {
    is_cycle_edge: bool = false,
    is_back_edge: bool = false,
    crosses_subgraph_boundary: bool = false,
    has_center_label: bool = false,
    has_endpoint_label: bool = false,
};

fn memberships(a: Allocator, graph: *const Graph) Allocator.Error!std.StringHashMapUnmanaged(std.ArrayList(usize)) {
    var m: std.StringHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    for (graph.subgraphs.items, 0..) |sub, si| for (sub.nodes.items) |id| {
        const gop = try m.getOrPut(a, id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (std.mem.indexOfScalar(usize, gop.value_ptr.items, si) == null) try gop.value_ptr.append(a, si);
    };
    return m;
}

fn sameMembership(m: *const std.StringHashMapUnmanaged(std.ArrayList(usize)), x: []const u8, y: []const u8) bool {
    const fx = m.get(x);
    const fy = m.get(y);
    if (fx == null and fy == null) return true;
    if (fx == null or fy == null) return false;
    return std.mem.eql(usize, fx.?.items, fy.?.items);
}

fn nonEmpty(s: ?[]const u8) bool {
    return if (s) |v| util.trim(v).len > 0 else false;
}

pub fn classifyEdgeRoles(a: Allocator, graph: *const Graph) Allocator.Error![]EdgeRole {
    const roles = try a.alloc(EdgeRole, graph.edges.items.len);
    if (roles.len == 0) return roles;
    const ids = graph.nodes.keys.items;
    const ranks = try ranking.computeRanksSubset(a, ids, graph.edges.items, &graph.node_order);
    const comps = try ranking.stronglyConnectedComponents(a, ids, graph.edges.items);
    var comp_of: ranking.Ranks = .empty;
    for (comps, 0..) |c, ci| for (c) |id| try comp_of.put(a, id, ci);
    var mem = try memberships(a, graph);
    for (graph.edges.items, 0..) |e, i| {
        const fc = comp_of.get(e.from);
        const tc = comp_of.get(e.to);
        const fr = ranks.get(e.from);
        const tr = ranks.get(e.to);
        roles[i] = .{
            .is_cycle_edge = util.eql(e.from, e.to) or (fc != null and tc != null and fc.? == tc.?),
            .is_back_edge = fr != null and tr != null and tr.? <= fr.?,
            .crosses_subgraph_boundary = !sameMembership(&mem, e.from, e.to),
            .has_center_label = nonEmpty(e.label),
            .has_endpoint_label = nonEmpty(e.start_label) or nonEmpty(e.end_label),
        };
    }
    return roles;
}

// ---- plan.rs (lanes) ------------------------------------------------------------------------

pub const LaneAssignments = struct {
    pair_counts: std.StringHashMapUnmanaged(usize),
    pair_index: []usize,
    pair_total: []usize,
    cross_edge_offsets: []f32,

    pub fn effectiveOffsets(self: *const LaneAssignments, a: Allocator, ports: []const EdgePortInfo, kind: ir.DiagramKind, config: *const LayoutConfig) Allocator.Error![]f32 {
        const out = try a.alloc(f32, ports.len);
        for (ports, 0..) |p, idx| {
            const total = if (idx < self.pair_total.len) self.pair_total[idx] else 1;
            const lane = if (idx < self.pair_index.len) self.pair_index[idx] else 0;
            const base: f32 = if (total > 1) (@as(f32, @floatFromInt(lane)) - (@as(f32, @floatFromInt(total)) - 1.0) / 2.0) * (config.node_spacing * L.MULTI_EDGE_OFFSET_RATIO) else 0.0;
            var offset = base + (if (idx < self.cross_edge_offsets.len) self.cross_edge_offsets[idx] else 0);
            if (kind == .flowchart) {
                const raw = (p.start_offset - p.end_offset) * L.FLOWCHART_PORT_ROUTE_BIAS_RATIO;
                const max_bias = @max(config.node_spacing * L.FLOWCHART_PORT_ROUTE_BIAS_MAX_RATIO, 8.0);
                offset += std.math.clamp(raw, -max_bias, max_bias);
            }
            out[idx] = offset;
        }
        return out;
    }
};

pub fn effectiveEdgeEndpointLayouts(graph: *const Graph, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, edge: *const Edge) ?[2]NodeLayout {
    const fl = nodes.get(edge.from) orelse return null;
    const tl = nodes.get(edge.to) orelse return null;
    const from = if (fl.anchor_subgraph) |ai| (if (ai < subgraphs.len) sg.anchorLayoutForEdgeTowards(fl, &subgraphs[ai], tl, graph.direction, true) else fl.*) else fl.*;
    const to = if (tl.anchor_subgraph) |ai| (if (ai < subgraphs.len) sg.anchorLayoutForEdgeTowards(tl, &subgraphs[ai], fl, graph.direction, false) else tl.*) else tl.*;
    return .{ from, to };
}

pub fn planEdgeLanes(a: Allocator, graph: *const Graph, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, config: *const LayoutConfig) Allocator.Error!LaneAssignments {
    const n = graph.edges.items.len;
    var counts: std.StringHashMapUnmanaged(usize) = .empty;
    const keys = try a.alloc([]const u8, n);
    for (graph.edges.items, 0..) |*e, i| {
        keys[i] = try routing.edgePairKey(a, e);
        const gop = try counts.getOrPut(a, keys[i]);
        gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
    }
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    const idx_arr = try a.alloc(usize, n);
    const total = try a.alloc(usize, n);
    for (0..n) |i| {
        total[i] = counts.get(keys[i]) orelse 1;
        const gop = try seen.getOrPut(a, keys[i]);
        if (!gop.found_existing) gop.value_ptr.* = 0;
        idx_arr[i] = gop.value_ptr.*;
        gop.value_ptr.* += 1;
    }
    const cross = try a.alloc(f32, n);
    @memset(cross, 0);
    if (graph.kind == .flowchart) {
        const h = isHorizontal(graph.direction);
        const band = @max(config.node_spacing * 2.0, 30.0);
        const G = struct { idx: usize, key: f32 };
        var groups: std.AutoArrayHashMapUnmanaged(i32, std.ArrayList(G)) = .empty;
        for (graph.edges.items, 0..) |*e, i| {
            const ft = effectiveEdgeEndpointLayouts(graph, nodes, subgraphs, e) orelse continue;
            const fc = geometry.nodeCenter(&ft[0]);
            const tc = geometry.nodeCenter(&ft[1]);
            const dx = tc[0] - fc[0];
            const dy = tc[1] - fc[1];
            const cross_axis = if (h) @abs(dy) else @abs(dx);
            const main_axis = if (h) @abs(dx) else @abs(dy);
            const secondary = e.style == .dotted or e.label != null;
            if (!secondary or cross_axis <= main_axis * 1.2) continue;
            const coord = if (h) (fc[0] + tc[0]) * 0.5 else (fc[1] + tc[1]) * 0.5;
            const bucket: i32 = routing.toI32(@round(coord / band));
            const sk = if (h) (fc[1] + tc[1]) * 0.5 else (fc[0] + tc[0]) * 0.5;
            const gop = try groups.getOrPut(a, bucket);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(a, .{ .idx = i, .key = sk });
        }
        const spacing = @max(config.node_spacing * 0.45, 8.0);
        for (groups.values()) |*grp| {
            if (grp.items.len <= 1) continue;
            std.mem.sort(G, grp.items, {}, struct {
                fn lt(_: void, x: G, y: G) bool {
                    return x.key < y.key;
                }
            }.lt);
            const center = (@as(f32, @floatFromInt(grp.items.len)) - 1.0) * 0.5;
            for (grp.items, 0..) |g, pos| cross[g.idx] = (@as(f32, @floatFromInt(pos)) - center) * spacing;
        }
    }
    return .{ .pair_counts = counts, .pair_index = idx_arr, .pair_total = total, .cross_edge_offsets = cross };
}

// ---- route_labels.rs ----------------------------------------------------------------------

pub const RouteLabelPlan = struct { obstacle_id: []const u8, obstacle_index: usize, progress: f32, center: Point };

const LabelState = struct {
    plans: []?RouteLabelPlan,
    obstacles: std.ArrayList(Obstacle),
    anchors: []?Point,
};

fn shouldRouteLabelsVia(graph: *const Graph, nodes: *const NodeMap) bool {
    for (nodes.keys.items) |id| if (util.startsWith(id, "__elabel_") and util.endsWith(id, "__")) return false;
    return graph.kind != .er;
}

fn labelNeedsReservedGap(label: *const TextBlock, config: *const LayoutConfig) bool {
    if (label.lines.len > 1) return true;
    var chars: usize = 0;
    for (label.lines) |l| chars += util.charCount(l);
    return label.width >= config.node_spacing * 0.9 or chars >= 14;
}

fn provisionalRouteLabelCenter(graph: *const Graph, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, ports: []const EdgePortInfo, pair_index: []const usize, lane_offsets: []const f32, pad_x: f32, pad_y: f32, config: *const LayoutConfig, idx: usize, label: *const TextBlock) ?Point {
    const edge = &graph.edges.items[idx];
    const ft = effectiveEdgeEndpointLayouts(graph, nodes, subgraphs, edge) orelse return null;
    const port = if (idx < ports.len) ports[idx] else EdgePortInfo{};
    const start = routing.anchorPointForNode(&ft[0], port.start_side, port.start_offset);
    const end = routing.anchorPointForNode(&ft[1], port.end_side, port.end_offset);
    const base = if (idx < lane_offsets.len) lane_offsets[idx] else 0;
    const h = isHorizontal(graph.direction);
    var center = Point{ (start[0] + end[0]) * 0.5, (start[1] + end[1]) * 0.5 };
    if (h) center[0] += base else center[1] += base;
    if (graph.kind == .flowchart) {
        const main_span = if (h) @abs(end[0] - start[0]) else @abs(end[1] - start[1]);
        const label_main = if (h) label.width + 2.0 * pad_x else label.height + 2.0 * pad_y;
        const label_cross = if (h) label.height + 2.0 * pad_y else label.width + 2.0 * pad_x;
        const margin = @max(config.node_spacing * 0.35, 14.0);
        const pi = if (idx < pair_index.len) pair_index[idx] else 0;
        const d = if (h) end[1] - start[1] else end[0] - start[0];
        const sign: f32 = if (@abs(d) > 2.0) (if (d >= 0) 1.0 else -1.0) else if (pi % 2 == 0) -1.0 else 1.0;
        if (label_main + margin * 2.0 >= @max(main_span, 1.0)) {
            const lift: f32 = if (label.lines.len > 1) label_cross * 0.75 else 0.0;
            const clearance = label_cross * 0.5 + margin + lift;
            for ([_]f32{ sign, -sign }) |s| {
                var c = center;
                if (h) c[1] += s * clearance else c[0] += s * clearance;
                const hw = label.width * 0.5 + pad_x;
                const hh = label.height * 0.5 + pad_y;
                const os = start[0] >= c[0] - hw and start[0] <= c[0] + hw and start[1] >= c[1] - hh and start[1] <= c[1] + hh;
                const oe = end[0] >= c[0] - hw and end[0] <= c[0] + hw and end[1] >= c[1] - hh and end[1] <= c[1] + hh;
                if (!os and !oe) {
                    center = c;
                    break;
                }
            }
        }
    }
    return center;
}

fn pathHitsObstacle(points: []const Point, o: *const Obstacle) bool {
    if (points.len < 2) return false;
    for (0..points.len - 1) |i| if (routing.segmentIntersectsRect(points[i], points[i + 1], o)) return true;
    return false;
}

fn detourAroundLabel(a: Allocator, points: []const Point, o: *const Obstacle, clearance: f32) Allocator.Error!?[]Point {
    if (points.len < 2 or !pathHitsObstacle(points, o)) return null;
    var first: usize = 0;
    var last: usize = 0;
    var found = false;
    for (0..points.len - 1) |i| if (routing.segmentIntersectsRect(points[i], points[i + 1], o)) {
        if (!found) first = i;
        found = true;
        last = i;
    };
    const entry = points[first];
    const exit = points[last + 1];
    const left = o.x - clearance;
    const right = o.x + o.width + clearance;
    const top = o.y - clearance;
    const bottom = o.y + o.height + clearance;
    var best: ?[]Point = null;
    var best_len = INF;
    const xs: [2]f32 = if (@abs(entry[0] - left) + @abs(exit[0] - left) <= @abs(entry[0] - right) + @abs(exit[0] - right)) .{ left, right } else .{ right, left };
    const ys: [2]f32 = if (@abs(entry[1] - top) + @abs(exit[1] - top) <= @abs(entry[1] - bottom) + @abs(exit[1] - bottom)) .{ top, bottom } else .{ bottom, top };
    var cands: [4][2]Point = undefined;
    for (xs, 0..) |x, i| cands[i] = .{ .{ x, entry[1] }, .{ x, exit[1] } };
    for (ys, 0..) |y, i| cands[2 + i] = .{ .{ entry[0], y }, .{ exit[0], y } };
    for (cands) |mid| {
        var c: std.ArrayList(Point) = .empty;
        try c.appendSlice(a, points[0 .. first + 1]);
        try c.appendSlice(a, &mid);
        try c.appendSlice(a, points[last + 1 ..]);
        const cand = try routing.compressPath(a, c.items);
        if (pathHitsObstacle(cand, o)) continue;
        const len = geometry.pathLength(cand);
        if (best == null or len < best_len) {
            best = cand;
            best_len = len;
        }
    }
    return best;
}

const SyncCtx = struct {
    direction: ir.Direction,
    kind: ir.DiagramKind,
    st: *LabelState,
    labels: []const ?TextBlock,
    pad_x: f32,
    pad_y: f32,
    update_obstacle: bool,
};

fn syncRouteLabelPlan(a: Allocator, idx: usize, points: *[]Point, ctx: SyncCtx) Allocator.Error!void {
    if (idx >= ctx.st.plans.len) return;
    const plan = &(ctx.st.plans[idx] orelse return);
    _ = plan;
    const p = &ctx.st.plans[idx].?;
    if (points.len < 2) return;
    const preserve = ctx.kind == .flowchart;
    const center = if (preserve) p.center else (geometry.pathPointAtProgress(points.*, p.progress) orelse routing.edgeLabelAnchorFromPoints(points.*) orelse p.center);
    p.center = center;
    ctx.st.anchors[idx] = center;
    const label = if (idx < ctx.labels.len) ctx.labels[idx] else null;
    if (preserve) if (label) |l| {
        const o = Obstacle{ .id = p.obstacle_id, .x = center[0] - l.width / 2.0 - ctx.pad_x, .y = center[1] - l.height / 2.0 - ctx.pad_y, .width = l.width + 2.0 * ctx.pad_x, .height = l.height + 2.0 * ctx.pad_y };
        if (try detourAroundLabel(a, points.*, &o, @max(@max(ctx.pad_y, ctx.pad_x) * 0.5, 8.0))) |d| points.* = d;
    };
    if (!preserve and ctx.kind != .flowchart and ctx.kind != .state) {
        var list: std.ArrayList(Point) = .fromOwnedSlice(points.*);
        try routing.insertLabelViaPoint(a, &list, center);
        points.* = list.items;
    }
    if (!ctx.update_obstacle) return;
    if (label) |l| if (p.obstacle_index < ctx.st.obstacles.items.len) {
        const o = &ctx.st.obstacles.items[p.obstacle_index];
        o.x = center[0] - l.width / 2.0 - ctx.pad_x;
        o.y = center[1] - l.height / 2.0 - ctx.pad_y;
        o.width = l.width + 2.0 * ctx.pad_x;
        o.height = l.height + 2.0 * ctx.pad_y;
    };
}

// ---- edge_pipeline.rs -------------------------------------------------------------------------

const TrackKind = enum { side, axis };
const PortTrack = struct { kind: TrackKind, side: EdgeSide = .left, axis: routing.PortAxis = .x };

fn isBranchingPortShape(n: *const NodeLayout) bool {
    return switch (n.shape) {
        .diamond, .hexagon, .parallelogram, .parallelogram_alt, .trapezoid, .trapezoid_alt, .asymmetric => true,
        else => false,
    };
}

fn oppositeSide(s: EdgeSide) EdgeSide {
    return switch (s) {
        .left => .right,
        .right => .left,
        .top => .bottom,
        .bottom => .top,
    };
}

fn portTrackForAssignment(n: *const NodeLayout, side: EdgeSide, degree: usize, counts: [4]usize) PortTrack {
    const axis_wide = blk: {
        if (degree <= 2) break :blk false;
        const sc = counts[routing.sideSlot(side)];
        const oc = counts[routing.sideSlot(oppositeSide(side))];
        if (sc + oc <= 2) break :blk false;
        break :blk sc > 1 or oc > 1 or (isBranchingPortShape(n) and sc + oc >= 3);
    };
    return if (axis_wide) .{ .kind = .axis, .axis = routing.portAxis(side) } else .{ .kind = .side, .side = side };
}

fn trackNodeLen(n: *const NodeLayout, tr: PortTrack) f32 {
    return switch (tr.kind) {
        .side => if (routing.sideIsVertical(tr.side)) n.height else n.width,
        .axis => if (tr.axis == .x) n.width else n.height,
    };
}

fn trackNodeStart(n: *const NodeLayout, tr: PortTrack) f32 {
    return switch (tr.kind) {
        .side => if (routing.sideIsVertical(tr.side)) n.y else n.x,
        .axis => if (tr.axis == .x) n.x else n.y,
    };
}

const NodeBounds = struct { min_x: f32, max_x: f32, min_y: f32, max_y: f32 };

const MAX_RESERVED_ROUTING_CHANNELS: usize = 36;
const RANK_CHANNEL_MIN_GAP_RATIO: f32 = 0.70;
const HUB_CHANNEL_MIN_DEGREE: usize = 4;
const HUB_CHANNEL_PAD_RATIO: f32 = 0.78;

fn pushReservedChannel(a: Allocator, chans: *std.ArrayList(routing.ReservedRoutingChannel), ch: routing.ReservedRoutingChannel) Allocator.Error!void {
    if (!std.math.isFinite(ch.coord) or !std.math.isFinite(ch.span_min) or !std.math.isFinite(ch.span_max) or ch.span_max <= ch.span_min) return;
    for (chans.items) |e| {
        if (e.axis == ch.axis and @abs(e.coord - ch.coord) <= 3.0 and e.span_min <= ch.span_max and ch.span_min <= e.span_max) return;
    }
    try chans.append(a, ch);
}

fn visibleNodeBounds(nodes: *const NodeMap) ?NodeBounds {
    var b: NodeBounds = .{ .min_x = FMAX, .max_x = FMIN, .min_y = FMAX, .max_y = FMIN };
    var any = false;
    for (nodes.values()) |n| {
        if (n.hidden or n.anchor_subgraph != null) continue;
        any = true;
        b.min_x = @min(b.min_x, n.x);
        b.max_x = @max(b.max_x, n.x + n.width);
        b.min_y = @min(b.min_y, n.y);
        b.max_y = @max(b.max_y, n.y + n.height);
    }
    return if (any) b else null;
}

fn buildReservedChannels(a: Allocator, graph: *const Graph, nodes: *const NodeMap, config: *const LayoutConfig) Allocator.Error![]routing.ReservedRoutingChannel {
    var chans: std.ArrayList(routing.ReservedRoutingChannel) = .empty;
    if (graph.kind != .flowchart or nodes.len() < 4) return chans.items;
    const bounds = visibleNodeBounds(nodes) orelse return chans.items;
    const h = isHorizontal(graph.direction);
    const span_pad = @max(config.node_spacing * 0.9, 24.0);
    const min_gap = @max(config.node_spacing * RANK_CHANNEL_MIN_GAP_RATIO, 18.0);
    const Iv = struct { s: f32, e: f32 };
    var ivs: std.ArrayList(Iv) = .empty;
    for (nodes.values()) |n| {
        if (n.hidden or n.anchor_subgraph != null) continue;
        try ivs.append(a, if (h) .{ .s = n.x, .e = n.x + n.width } else .{ .s = n.y, .e = n.y + n.height });
    }
    std.mem.sort(Iv, ivs.items, {}, struct {
        fn lt(_: void, x: Iv, y: Iv) bool {
            return x.s < y.s;
        }
    }.lt);
    var prev_end: ?f32 = null;
    for (ivs.items) |iv| {
        if (prev_end) |prev| {
            if (iv.s - prev >= min_gap) {
                const coord = (iv.s + prev) * 0.5;
                try pushReservedChannel(a, &chans, if (h)
                    .{ .axis = .vertical, .coord = coord, .span_min = bounds.min_y - span_pad, .span_max = bounds.max_y + span_pad }
                else
                    .{ .axis = .horizontal, .coord = coord, .span_min = bounds.min_x - span_pad, .span_max = bounds.max_x + span_pad });
            }
            prev_end = @max(prev, iv.e);
        } else prev_end = iv.e;
    }
    var deg: ranking.Ranks = .empty;
    for (graph.edges.items) |e| for ([_][]const u8{ e.from, e.to }) |id| {
        const gop = try deg.getOrPut(a, id);
        gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
    };
    const hub_pad = @max(config.node_spacing * HUB_CHANNEL_PAD_RATIO, 24.0);
    const Hub = struct { n: *const NodeLayout, d: usize };
    var hubs: std.ArrayList(Hub) = .empty;
    for (nodes.values()) |*n| {
        if (n.hidden or n.anchor_subgraph != null) continue;
        const d = deg.get(n.id) orelse 0;
        if (d >= HUB_CHANNEL_MIN_DEGREE) try hubs.append(a, .{ .n = n, .d = d });
    }
    std.mem.sort(Hub, hubs.items, {}, struct {
        fn lt(_: void, x: Hub, y: Hub) bool {
            if (x.d != y.d) return x.d > y.d;
            return std.mem.order(u8, x.n.id, y.n.id) == .lt;
        }
    }.lt);
    for (hubs.items[0..@min(8, hubs.items.len)]) |hub| {
        const n = hub.n;
        for ([_]f32{ n.x - hub_pad, n.x + n.width + hub_pad }) |c| try pushReservedChannel(a, &chans, .{ .axis = .vertical, .coord = c, .span_min = n.y - hub_pad, .span_max = n.y + n.height + hub_pad });
        for ([_]f32{ n.y - hub_pad, n.y + n.height + hub_pad }) |c| try pushReservedChannel(a, &chans, .{ .axis = .horizontal, .coord = c, .span_min = n.x - hub_pad, .span_max = n.x + n.width + hub_pad });
        if (chans.items.len >= MAX_RESERVED_ROUTING_CHANNELS) {
            chans.items.len = MAX_RESERVED_ROUTING_CHANNELS;
            break;
        }
    }
    if (chans.items.len > MAX_RESERVED_ROUTING_CHANNELS) chans.items.len = MAX_RESERVED_ROUTING_CHANNELS;
    return chans.items;
}

fn insertAt(a: Allocator, points: []Point, at: usize, p: Point) Allocator.Error![]Point {
    var l: std.ArrayList(Point) = .empty;
    try l.appendSlice(a, points[0..at]);
    try l.append(a, p);
    try l.appendSlice(a, points[at..]);
    return l.items;
}

fn enforceEndpointPorts(a: Allocator, graph: *const Graph, nodes: *const NodeMap, ports: []const EdgePortInfo, routed: [][]Point, config: *const LayoutConfig) Allocator.Error!void {
    const stub_len = @min(@max(routing.routingCellSize(config) * 0.6, 6.0), @max(config.node_spacing, L.MIN_NODE_SPACING_FLOOR) * 0.35);
    for (graph.edges.items, 0..) |e, idx| {
        if (idx >= routed.len) continue;
        var pts = routed[idx];
        if (pts.len < 2) continue;
        if (util.eql(e.from, e.to)) {
            if (nodes.get(e.from)) |node| {
                const ss = geometry.endpointSideForPoint(node, pts[0]);
                if (!geometry.sidePointsOutward(ss, pts[0], pts[1])) {
                    const stub = routing.portStubPoint(pts[0], ss, stub_len);
                    if (@abs(stub[0] - pts[1][0]) > 0.5 or @abs(stub[1] - pts[1][1]) > 0.5) pts = try insertAt(a, pts, 1, stub);
                }
                const len = pts.len;
                if (len >= 2) {
                    const end = pts[len - 1];
                    const prev = pts[len - 2];
                    const es = geometry.endpointSideForPoint(node, end);
                    if (!geometry.sidePointsOutward(es, end, prev)) {
                        const stub = routing.portStubPoint(end, es, stub_len);
                        if (@abs(stub[0] - prev[0]) > 0.5 or @abs(stub[1] - prev[1]) > 0.5) pts = try insertAt(a, pts, len - 1, stub);
                    }
                }
                routed[idx] = try routing.compressPath(a, pts);
            }
            continue;
        }
        if (idx >= ports.len) continue;
        const port = ports[idx];
        if (nodes.contains(e.from) and !geometry.sidePointsOutward(port.start_side, pts[0], pts[1])) {
            const stub = routing.portStubPoint(pts[0], port.start_side, stub_len);
            if (@abs(stub[0] - pts[1][0]) > 0.5 or @abs(stub[1] - pts[1][1]) > 0.5) pts = try insertAt(a, pts, 1, stub);
        }
        const len = pts.len;
        if (len >= 2 and nodes.contains(e.to) and !geometry.sidePointsOutward(port.end_side, pts[len - 1], pts[len - 2])) {
            const stub = routing.portStubPoint(pts[len - 1], port.end_side, stub_len);
            if (@abs(stub[0] - pts[len - 2][0]) > 0.5 or @abs(stub[1] - pts[len - 2][1]) > 0.5) pts = try insertAt(a, pts, len - 1, stub);
        }
        routed[idx] = try routing.compressPath(a, pts);
    }
}

fn collectOtherSegments(a: Allocator, routed: []const []Point, excluded: usize) Allocator.Error![]Segment {
    var segs: std.ArrayList(Segment) = .empty;
    for (routed, 0..) |pts, i| {
        if (i == excluded or pts.len < 2) continue;
        for (0..pts.len - 1) |j| try segs.append(a, .{ pts[j], pts[j + 1] });
    }
    return segs.items;
}

const RepairScore = struct { hard: usize, reentries: usize, crossings: usize, overlap: f32, bends: usize, len: f32 };

fn repairScore(points: []const Point, edge: *const Edge, nodes: *const NodeMap, others: []const Segment) RepairScore {
    const r = routing.edgeCrossingsWithExisting(points, others);
    return .{
        .hard = pc.flowchartEndpointDirectionViolationCount(points, edge, nodes) + @intFromBool(pc.flowchartPathHitsNonEndpointNodes(points, edge.from, edge.to, nodes)),
        .reentries = pc.flowchartEndpointReentryCount(points, edge, nodes),
        .crossings = r[0],
        .overlap = r[1],
        .bends = geometry.pathBendCount(points),
        .len = geometry.pathLength(points),
    };
}

fn repairScoreBetter(c: RepairScore, b: RepairScore) bool {
    if (c.hard != b.hard) return c.hard < b.hard;
    if (c.reentries != b.reentries) return c.reentries < b.reentries;
    if (c.crossings != b.crossings) return c.crossings < b.crossings;
    if (@abs(c.overlap - b.overlap) > 0.05) return c.overlap < b.overlap;
    if (c.bends != b.bends) return c.bends < b.bends;
    return c.len + 1.0 < b.len;
}

const Common = struct {
    a: Allocator,
    graph: *const Graph,
    nodes: *const NodeMap,
    subgraphs: []const SubgraphLayout,
    obstacles: []const Obstacle,
    grid: ?*const routing.RoutingGrid,
    config: *const LayoutConfig,

    fn insets(c: *const Common, e: *const Edge) [2]f32 {
        return .{
            if (e.arrow_start) routing.arrowheadInset(c.graph.kind, e.arrow_start_kind) else 0.0,
            if (e.arrow_end) routing.arrowheadInset(c.graph.kind, e.arrow_end_kind) else 0.0,
        };
    }

    fn baseCtx(c: *const Common, e: *const Edge, from: *const NodeLayout, to: *const NodeLayout, port: EdgePortInfo, labels: []const Obstacle) RouteContext {
        const ins = c.insets(e);
        return .{
            .from_id = e.from,
            .to_id = e.to,
            .from = from,
            .to = to,
            .direction = c.graph.direction,
            .config = c.config,
            .obstacles = c.obstacles,
            .label_obstacles = labels,
            .fast_route = false,
            .base_offset = 0,
            .start_side = port.start_side,
            .end_side = port.end_side,
            .start_offset = port.start_offset,
            .end_offset = port.end_offset,
            .stub_len = routing.portStubLength(c.config, from, to),
            .start_inset = ins[0],
            .end_inset = ins[1],
            .prefer_shorter_ties = true,
            .preferred_label_id = null,
            .preferred_label_center = null,
            .preferred_label_obstacle = null,
            .preferred_label_clearance = 0,
            .reserved_channels = &.{},
            .force_preferred_label_via = false,
            .coarse_grid_retry = true,
            .allow_exterior_fallback = false,
        };
    }
};

fn repairEndpointReentriesByRerouting(c: *const Common, labels: []const Obstacle, lane_offsets: []const f32, channels: []const routing.ReservedRoutingChannel, ports: []EdgePortInfo, routed: [][]Point) Allocator.Error!void {
    const sides = [_]EdgeSide{ .left, .right, .top, .bottom };
    for (0..routed.len) |idx| {
        if (idx >= c.graph.edges.items.len) continue;
        const edge = &c.graph.edges.items[idx];
        if (util.eql(edge.from, edge.to) or routed[idx].len < 2) continue;
        const others = try collectOtherSegments(c.a, routed, idx);
        const baseline = repairScore(routed[idx], edge, c.nodes, others);
        if (baseline.hard == 0 and baseline.reentries == 0) continue;
        const ft = effectiveEdgeEndpointLayouts(c.graph, c.nodes, c.subgraphs, edge) orelse continue;
        const current = if (idx < ports.len) ports[idx] else EdgePortInfo{};
        var best_score = baseline;
        var best_points: ?[]Point = null;
        var best_port = current;
        for (sides) |ss| for (sides) |es| {
            const cand_port = EdgePortInfo{
                .start_side = ss,
                .end_side = es,
                .start_offset = if (ss == current.start_side) current.start_offset else 0.0,
                .end_offset = if (es == current.end_side) current.end_offset else 0.0,
            };
            var ctx = c.baseCtx(edge, &ft[0], &ft[1], cand_port, labels);
            ctx.base_offset = if (idx < lane_offsets.len) lane_offsets[idx] else 0;
            ctx.reserved_channels = channels;
            const cand = try routing.routeEdgeWithAvoidance(c.a, &ctx, null, c.grid, others);
            const score = repairScore(cand, edge, c.nodes, others);
            if (!(score.hard < baseline.hard or (score.hard == baseline.hard and score.reentries < baseline.reentries))) continue;
            if (score.len > baseline.len * 4.0 + c.config.node_spacing * 4.0) continue;
            if (repairScoreBetter(score, best_score)) {
                best_score = score;
                best_points = cand;
                best_port = cand_port;
            }
        };
        if (best_points) |p| {
            routed[idx] = p;
            if (idx < ports.len) ports[idx] = best_port;
        }
    }
}

fn chooseOuterBackEdgeSides(from: *const NodeLayout, to: *const NodeLayout, direction: ir.Direction, bounds_opt: ?NodeBounds, fallback: Sides) Sides {
    const b = bounds_opt orelse return fallback;
    if (isHorizontal(direction)) {
        const upper = @min(from.y, to.y) - b.min_y;
        const lower = b.max_y - @max(from.y + from.height, to.y + to.height);
        const side: EdgeSide = if (@abs(upper - lower) <= 1.0) blk: {
            const avg = (from.y + from.height * 0.5 + to.y + to.height * 0.5) * 0.5;
            break :blk if (avg <= (b.min_y + b.max_y) * 0.5) .top else .bottom;
        } else if (upper <= lower) .top else .bottom;
        return .{ side, side, fallback[2] };
    }
    const left = @min(from.x, to.x) - b.min_x;
    const right = b.max_x - @max(from.x + from.width, to.x + to.width);
    const side: EdgeSide = if (@abs(left - right) <= 1.0) blk: {
        const avg = (from.x + from.width * 0.5 + to.x + to.width * 0.5) * 0.5;
        break :blk if (avg <= (b.min_x + b.max_x) * 0.5) .left else .right;
    } else if (left <= right) .left else .right;
    return .{ side, side, fallback[2] };
}

fn sideDirection(s: EdgeSide) Point {
    return switch (s) {
        .left => .{ -1, 0 },
        .right => .{ 1, 0 },
        .top => .{ 0, -1 },
        .bottom => .{ 0, 1 },
    };
}

fn sideAlignmentPenalty(s: EdgeSide, from: *const NodeLayout, to: *const NodeLayout) f32 {
    const f = geometry.nodeCenter(from);
    const tc = geometry.nodeCenter(to);
    const dx = tc[0] - f[0];
    const dy = tc[1] - f[1];
    const len = @max(@sqrt(dx * dx + dy * dy), 1.0);
    const d = sideDirection(s);
    return @max(1.0 - (d[0] * dx + d[1] * dy) / len, 0.0);
}

fn candidateHorizontalSides(from: *const NodeLayout, to: *const NodeLayout) Sides {
    if (geometry.nodeCenter(to)[0] >= geometry.nodeCenter(from)[0]) return .{ .right, .left, to.x + to.width < from.x };
    return .{ .left, .right, to.x > from.x + from.width };
}

fn candidateVerticalSides(from: *const NodeLayout, to: *const NodeLayout) Sides {
    if (geometry.nodeCenter(to)[1] >= geometry.nodeCenter(from)[1]) return .{ .bottom, .top, to.y + to.height < from.y };
    return .{ .top, .bottom, to.y > from.y + from.height };
}

const SearchProfile = struct {
    max_candidates: usize,
    port_offset_candidates: usize,
    max_refined_edges: ?usize,
    fast_route: bool,
    use_grid: bool,
    use_existing_segments: bool,
};

const Tier = enum { disabled, exact, bounded, linear };

const PerfProfile = struct {
    tier: Tier,
    side_search: ?SearchProfile,
    global_route_passes: usize,
    negotiated_congestion_passes: usize,
    use_route_occupancy: bool,
    allow_exterior_fallback: bool,
};

fn performanceProfile(graph: *const Graph, layout_node_count: usize, tiny: bool) PerfProfile {
    const ec = graph.edges.items.len;
    const use_occ = !tiny and ec > 2;
    if (graph.kind != .flowchart or ec == 0) return .{ .tier = .disabled, .side_search = null, .global_route_passes = 0, .negotiated_congestion_passes = 0, .use_route_occupancy = use_occ, .allow_exterior_fallback = false };
    const nc = @max(layout_node_count, 1);
    const dense = ec *| 2 >= nc *| 3;
    const compound = graph.subgraphs.items.len > 0;
    var tier: Tier = undefined;
    var ss: SearchProfile = undefined;
    if (ec <= 64) {
        tier = .exact;
        ss = .{ .max_candidates = 5, .port_offset_candidates = if (ec <= 32) 4 else 3, .max_refined_edges = null, .fast_route = tiny, .use_grid = !tiny, .use_existing_segments = true };
    } else if (ec > 320) {
        tier = .linear;
        ss = .{ .max_candidates = 3, .port_offset_candidates = 2, .max_refined_edges = 320, .fast_route = true, .use_grid = false, .use_existing_segments = false };
    } else if (ec <= 160 or compound or dense) {
        tier = .bounded;
        ss = .{ .max_candidates = 4, .port_offset_candidates = 3, .max_refined_edges = null, .fast_route = true, .use_grid = false, .use_existing_segments = ec <= 160 };
    } else {
        tier = .linear;
        ss = .{ .max_candidates = 3, .port_offset_candidates = 2, .max_refined_edges = 320, .fast_route = true, .use_grid = false, .use_existing_segments = false };
    }
    const grp: usize = switch (tier) {
        .exact => if (ec >= 3 and ec <= 48) 2 else if (ec >= 3) 1 else 0,
        .bounded => if (ec >= 3 and ec <= 128) 1 else 0,
        else => 0,
    };
    const density = @as(f32, @floatFromInt(ec)) / @as(f32, @floatFromInt(nc));
    const ncp: usize = switch (tier) {
        .exact => if (ec >= 12 and density >= 1.1) 2 else 0,
        .bounded => if (ec <= 160 and density >= 1.35) 1 else 0,
        else => 0,
    };
    return .{ .tier = tier, .side_search = ss, .global_route_passes = grp, .negotiated_congestion_passes = ncp, .use_route_occupancy = use_occ, .allow_exterior_fallback = true };
}

const SideCands = struct {
    items: [5]Sides = undefined,
    len: usize = 0,

    fn has(self: *const SideCands, c: Sides) bool {
        for (self.items[0..self.len]) |e| if (e[0] == c[0] and e[1] == c[1]) return true;
        return false;
    }
    fn pushUnique(self: *SideCands, c: Sides, limit: usize) void {
        if (self.has(c)) return;
        if (self.len < @max(limit, 1) and self.len < 5) {
            self.items[self.len] = c;
            self.len += 1;
        }
    }
    fn pushPriority(self: *SideCands, c: Sides, limit: usize) void {
        if (self.has(c)) return;
        if (self.len < @max(limit, 1) and self.len < 5) {
            self.items[self.len] = c;
            self.len += 1;
        } else if (self.len > 0) self.items[self.len - 1] = c;
    }
};

fn collectRoutedSideCandidates(from: *const NodeLayout, to: *const NodeLayout, primary: Sides, balanced: Sides, role: EdgeRole, direction: ir.Direction, bounds: ?NodeBounds, limit: usize) SideCands {
    var c: SideCands = .{};
    c.pushUnique(primary, limit);
    c.pushUnique(balanced, limit);
    const hz = candidateHorizontalSides(from, to);
    const vt = candidateVerticalSides(from, to);
    const fc = geometry.nodeCenter(from);
    const tc = geometry.nodeCenter(to);
    if (@abs(tc[0] - fc[0]) >= @abs(tc[1] - fc[1])) {
        c.pushUnique(hz, limit);
        c.pushUnique(vt, limit);
    } else {
        c.pushUnique(vt, limit);
        c.pushUnique(hz, limit);
    }
    if (role.is_back_edge) c.pushPriority(chooseOuterBackEdgeSides(from, to, direction, bounds, balanced), limit);
    return c;
}

fn allowLowDegreeBalancing(e: *const Edge, role: EdgeRole, fd: usize, td: usize) bool {
    return fd <= 4 and td <= 4 and (e.style == .dotted or role.is_back_edge or role.crosses_subgraph_boundary);
}

const SideChoiceCtx = struct {
    direction: ir.Direction,
    bounds: ?NodeBounds,
    degrees: *const ranking.Ranks,
    loads: *const routing.SideLoads,
    labels: []const Obstacle,
    existing: []const Segment,
    profile: SearchProfile,
};

fn routedSideCandidateScore(c: *const Common, sc: *const SideChoiceCtx, edge: *const Edge, from: *const NodeLayout, to: *const NodeLayout, cand: Sides, primary: Sides, role: EdgeRole) Allocator.Error!f32 {
    var ctx = c.baseCtx(edge, from, to, .{ .start_side = cand[0], .end_side = cand[1] }, sc.labels);
    ctx.fast_route = sc.profile.fast_route;
    ctx.start_inset = 0;
    ctx.end_inset = 0;
    const existing: ?[]const Segment = if (sc.existing.len > 0) sc.existing else null;
    const grid = if (sc.profile.use_grid) c.grid else null;
    const pts = try routing.routeEdgeWithAvoidance(c.a, &ctx, null, grid, existing);
    const hard: f32 = @floatFromInt(routing.pathObstacleIntersections(pts, c.obstacles, edge.from, edge.to));
    const label_hits: f32 = @floatFromInt(routing.pathLabelIntersections(pts, sc.labels, null));
    const r = if (sc.existing.len == 0) .{ @as(usize, 0), @as(f32, 0) } else routing.edgeCrossingsWithExisting(pts, sc.existing);
    const bends: f32 = @floatFromInt(geometry.pathBendCount(pts));
    const len = geometry.pathLength(pts);
    const fl: f32 = @floatFromInt(routing.sideLoadForNode(sc.loads, edge.from, cand[0]));
    const tl: f32 = @floatFromInt(routing.sideLoadForNode(sc.loads, edge.to, cand[1]));
    const congestion = fl * fl + tl * tl + (fl + tl) * 0.5;
    const fd = sc.degrees.get(edge.from) orelse 0;
    const td = sc.degrees.get(edge.to) orelse 0;
    const low = fd <= 4 and td <= 4;
    const deviation: f32 = if (cand[0] == primary[0] and cand[1] == primary[1]) 0.0 else if (low) 24.0 else 8.0;
    const alignment = sideAlignmentPenalty(cand[0], from, to) + sideAlignmentPenalty(cand[1], to, from);
    const backward: f32 = if (cand[2] and !primary[2]) 8.0 else 0.0;
    const outer_bonus: f32 = if (role.is_back_edge and cand[0] == cand[1] and routing.edgeAxisIsHorizontal(cand[0]) != routing.edgeAxisIsHorizontal(primary[0])) -10.0 else 0.0;
    return hard * 100_000.0 + label_hits * 20_000.0 + @as(f32, @floatFromInt(r[0])) * 1_600.0 + r[1] * 70.0 + bends * 42.0 + len * 0.09 + congestion * 5.5 + alignment * 34.0 + deviation + backward + outer_bonus;
}

fn chooseRoutedSides(c: *const Common, sc: *const SideChoiceCtx, edge: *const Edge, from: *const NodeLayout, to: *const NodeLayout, primary: Sides, balanced: Sides, role: EdgeRole) Allocator.Error!Sides {
    const cands = collectRoutedSideCandidates(from, to, primary, balanced, role, sc.direction, sc.bounds, sc.profile.max_candidates);
    var scoring = sc.*;
    if (!sc.profile.use_existing_segments) scoring.existing = &.{};
    var best = primary;
    var best_score = INF;
    for (cands.items[0..cands.len]) |cand| {
        const s = try routedSideCandidateScore(c, &scoring, edge, from, to, cand, primary, role);
        if (s < best_score) {
            best_score = s;
            best = cand;
        }
    }
    return best;
}

const PortScore = struct {
    hard: usize,
    reentries: usize,
    non_endpoint_hits: usize,
    label_hits: usize,
    collisions: usize,
    crossings: usize,
    overlap: f32,
    bends: usize,
    len: f32,
    drift: f32,
};

fn portScoreBetter(c: PortScore, b: PortScore) bool {
    if (c.hard != b.hard) return c.hard < b.hard;
    if (c.reentries != b.reentries) return c.reentries < b.reentries;
    if (c.non_endpoint_hits != b.non_endpoint_hits) return c.non_endpoint_hits < b.non_endpoint_hits;
    if (c.bends != b.bends) return c.bends < b.bends;
    if (@abs(c.len - b.len) > 1.0) return c.len < b.len;
    if (@abs(c.drift - b.drift) > 0.5) return c.drift < b.drift;
    if (c.label_hits != b.label_hits) return c.label_hits < b.label_hits;
    if (c.crossings != b.crossings) return c.crossings < b.crossings;
    if (@abs(c.overlap - b.overlap) > 0.05) return c.overlap < b.overlap;
    if (c.collisions != b.collisions) return c.collisions < b.collisions;
    return false;
}

fn portAxisCenter(n: *const NodeLayout, s: EdgeSide) f32 {
    return if (routing.sideIsVertical(s)) n.y + n.height / 2.0 else n.x + n.width / 2.0;
}

fn maxPortOffset(n: *const NodeLayout, s: EdgeSide) f32 {
    return if (routing.sideIsVertical(s)) @max(n.height / 2.0 - 1.0, 0.0) else @max(n.width / 2.0 - 1.0, 0.0);
}

fn clampPortOffset(n: *const NodeLayout, s: EdgeSide, o: f32) f32 {
    const m = maxPortOffset(n, s);
    return if (m > 0.0) std.math.clamp(o, -m, m) else 0.0;
}

fn idealOffset(remote: Point, n: *const NodeLayout, s: EdgeSide) f32 {
    return clampPortOffset(n, s, routing.idealPortPos(remote, n, s) - portAxisCenter(n, s));
}

fn portOffsetCandidates(n: *const NodeLayout, s: EdgeSide, current_in: f32, remote: Point, config: *const LayoutConfig, limit: usize, out: *[5]f32) usize {
    var len: usize = 0;
    const push = struct {
        fn f(o: *[5]f32, l: *usize, v: f32, lim: usize) void {
            for (o[0..l.*]) |e| if (@abs(e - v) <= 0.75) return;
            if (l.* < @max(lim, 1) and l.* < 5) {
                o[l.*] = v;
                l.* += 1;
            }
        }
    }.f;
    const current = clampPortOffset(n, s, current_in);
    const ideal = idealOffset(remote, n, s);
    const step = @min(@max(routing.routingCellSize(config), config.node_spacing * 0.18), @max(maxPortOffset(n, s), 1.0));
    push(out, &len, current, limit);
    push(out, &len, ideal, limit);
    push(out, &len, 0.0, limit);
    if (limit > 3 and step > 0.5) {
        push(out, &len, clampPortOffset(n, s, ideal + step), limit);
        push(out, &len, clampPortOffset(n, s, ideal - step), limit);
    }
    return len;
}

fn collectPortChoiceSegments(a: Allocator, graph: *const Graph, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, ports: []const EdgePortInfo, excluded: usize) Allocator.Error![]Segment {
    var segs: std.ArrayList(Segment) = .empty;
    for (graph.edges.items, 0..) |*e, idx| {
        if (idx == excluded or util.eql(e.from, e.to) or idx >= ports.len) continue;
        const ft = effectiveEdgeEndpointLayouts(graph, nodes, subgraphs, e) orelse continue;
        const p = ports[idx];
        try segs.append(a, .{ routing.anchorPointForNode(&ft[0], p.start_side, p.start_offset), routing.anchorPointForNode(&ft[1], p.end_side, p.end_offset) });
    }
    return segs.items;
}

fn portCollisionCount(graph: *const Graph, nodes: *const NodeMap, ports: []const EdgePortInfo, idx: usize, cand: EdgePortInfo, config: *const LayoutConfig) usize {
    if (idx >= graph.edges.items.len) return 0;
    const edge = &graph.edges.items[idx];
    const min_sep = @min(@max(routing.routingCellSize(config), config.node_spacing * 0.22), 28.0);
    var collisions: usize = 0;
    for (graph.edges.items, 0..) |*other_e, oi| {
        if (oi == idx or oi >= ports.len) continue;
        const other = ports[oi];
        const mine = [_]struct { []const u8, EdgeSide, f32 }{ .{ edge.from, cand.start_side, cand.start_offset }, .{ edge.to, cand.end_side, cand.end_offset } };
        const theirs = [_]struct { []const u8, EdgeSide, f32 }{ .{ other_e.from, other.start_side, other.start_offset }, .{ other_e.to, other.end_side, other.end_offset } };
        for (mine) |m| {
            const node = nodes.get(m[0]) orelse continue;
            const ca = portAxisCenter(node, m[1]) + clampPortOffset(node, m[1], m[2]);
            for (theirs) |o| {
                if (util.eql(o[0], m[0]) and o[1] == m[1]) {
                    const oa = portAxisCenter(node, o[1]) + clampPortOffset(node, o[1], o[2]);
                    if (@abs(ca - oa) < min_sep) collisions += 1;
                }
            }
        }
    }
    return collisions;
}

fn scorePortCandidate(points: []const Point, edge: *const Edge, nodes: *const NodeMap, obstacles: []const Obstacle, labels: []const Obstacle, existing: []const Segment, current: EdgePortInfo, cand: EdgePortInfo, collisions: usize) PortScore {
    const r = if (existing.len == 0) .{ @as(usize, 0), @as(f32, 0) } else routing.edgeCrossingsWithExisting(points, existing);
    const sd = (if (cand.start_side == current.start_side) @abs(cand.start_offset - current.start_offset) else 32.0 + @abs(cand.start_offset) * 0.25) +
        (if (cand.end_side == current.end_side) @abs(cand.end_offset - current.end_offset) else 32.0 + @abs(cand.end_offset) * 0.25);
    return .{
        .hard = pc.flowchartEndpointDirectionViolationCount(points, edge, nodes) + routing.pathObstacleIntersections(points, obstacles, edge.from, edge.to),
        .reentries = pc.flowchartEndpointReentryCount(points, edge, nodes),
        .non_endpoint_hits = @intFromBool(pc.flowchartPathHitsNonEndpointNodes(points, edge.from, edge.to, nodes)),
        .label_hits = routing.pathLabelIntersections(points, labels, null),
        .collisions = collisions,
        .crossings = r[0],
        .overlap = r[1],
        .bends = geometry.pathBendCount(points),
        .len = geometry.pathLength(points),
        .drift = sd,
    };
}

fn refinePorts(c: *const Common, labels: []const Obstacle, roles: []const EdgeRole, bounds: ?NodeBounds, degrees: *const ranking.Ranks, loads: *const routing.SideLoads, profile: SearchProfile, ports: []EdgePortInfo) Allocator.Error!void {
    const a = c.a;
    const graph = c.graph;
    const offset_limit = @max(profile.port_offset_candidates, 1);
    const lanes = try planEdgeLanes(a, graph, c.nodes, c.subgraphs, c.config);
    const predicted = try lanes.effectiveOffsets(a, ports, graph.kind, c.config);
    var refined: usize = 0;
    for (graph.edges.items, 0..) |*edge, idx| {
        if (util.eql(edge.from, edge.to)) continue;
        if (profile.max_refined_edges) |lim| if (refined >= lim) break;
        if (idx >= ports.len) continue;
        const current = ports[idx];
        const ft = effectiveEdgeEndpointLayouts(graph, c.nodes, c.subgraphs, edge) orelse continue;
        const from = &ft[0];
        const to = &ft[1];
        const base_offset = if (idx < predicted.len) predicted[idx] else 0;
        const fd = degrees.get(edge.from) orelse 0;
        const td = degrees.get(edge.to) orelse 0;
        const role = if (idx < roles.len) roles[idx] else EdgeRole{};
        const primary = routing.edgeSides(from, to, graph.direction);
        const balanced = routing.edgeSidesBalanced(edge.from, edge.to, from, to, allowLowDegreeBalancing(edge, role, fd, td), role.is_back_edge, graph.direction, degrees, loads);
        var sides = collectRoutedSideCandidates(from, to, primary, balanced, role, graph.direction, bounds, profile.max_candidates);
        if (role.is_back_edge) {
            var kept: SideCands = .{};
            for (sides.items[0..sides.len]) |s| if (s[0] == current.start_side and s[1] == current.end_side) {
                kept.items[kept.len] = s;
                kept.len += 1;
            };
            if (kept.len == 0) {
                kept.items[0] = .{ current.start_side, current.end_side, true };
                kept.len = 1;
            }
            sides = kept;
        }
        const existing: []const Segment = if (profile.use_existing_segments) try collectPortChoiceSegments(a, graph, c.nodes, c.subgraphs, ports, idx) else &.{};
        const routeFor = struct {
            fn f(cc: *const Common, e: *const Edge, fr: *const NodeLayout, tt: *const NodeLayout, lbl: []const Obstacle, prof: SearchProfile, port: EdgePortInfo, bo: f32) Allocator.Error![]Point {
                var ctx = cc.baseCtx(e, fr, tt, port, lbl);
                ctx.fast_route = prof.fast_route;
                ctx.base_offset = bo;
                return routing.routeEdgeWithAvoidance(cc.a, &ctx, null, if (prof.use_grid) cc.grid else null, null);
            }
        }.f;
        const baseline_pts = try routeFor(c, edge, from, to, labels, profile, current, base_offset);
        var best_score = scorePortCandidate(baseline_pts, edge, c.nodes, c.obstacles, labels, existing, current, current, portCollisionCount(graph, c.nodes, ports, idx, current, c.config));
        var best_port = current;
        const remote_to = geometry.nodeCenter(to);
        const remote_from = geometry.nodeCenter(from);
        for (sides.items[0..sides.len]) |s| {
            const sc = if (s[0] == current.start_side) current.start_offset else idealOffset(remote_to, from, s[0]);
            const ec = if (s[1] == current.end_side) current.end_offset else idealOffset(remote_from, to, s[1]);
            var so: [5]f32 = undefined;
            var eo: [5]f32 = undefined;
            const sn = portOffsetCandidates(from, s[0], sc, remote_to, c.config, offset_limit, &so);
            const en = portOffsetCandidates(to, s[1], ec, remote_from, c.config, offset_limit, &eo);
            for (so[0..sn]) |sof| for (eo[0..en]) |eof| {
                const cp = EdgePortInfo{ .start_side = s[0], .end_side = s[1], .start_offset = sof, .end_offset = eof };
                const pts = try routeFor(c, edge, from, to, labels, profile, cp, base_offset);
                const score = scorePortCandidate(pts, edge, c.nodes, c.obstacles, labels, existing, current, cp, portCollisionCount(graph, c.nodes, ports, idx, cp, c.config));
                if (best_score.hard == 0 and score.hard > 0) continue;
                if (best_score.non_endpoint_hits == 0 and score.non_endpoint_hits > 0) continue;
                if (score.reentries > best_score.reentries) continue;
                if (score.len > best_score.len * 3.0 + c.config.node_spacing * 4.0) continue;
                if (portScoreBetter(score, best_score)) {
                    best_score = score;
                    best_port = cp;
                }
            };
        }
        ports[idx] = best_port;
        refined += 1;
    }
}

const GlobalScore = struct { hard: usize, reentries: usize, non_endpoint_hits: usize, label_hits: usize, crossings: usize, overlap: f32, bends: usize, len: f32 };

fn globalScoreBetter(c: GlobalScore, b: GlobalScore) bool {
    if (c.hard != b.hard) return c.hard < b.hard;
    if (c.reentries != b.reentries) return c.reentries < b.reentries;
    if (c.non_endpoint_hits != b.non_endpoint_hits) return c.non_endpoint_hits < b.non_endpoint_hits;
    if (c.label_hits != b.label_hits) return c.label_hits < b.label_hits;
    if (c.crossings != b.crossings) return c.crossings < b.crossings;
    if (@abs(c.overlap - b.overlap) > 0.05) return c.overlap < b.overlap;
    if (c.bends != b.bends) return c.bends < b.bends;
    return c.len + 1.0 < b.len;
}

fn scoreGlobal(points: []const Point, edge: *const Edge, nodes: *const NodeMap, obstacles: []const Obstacle, labels: []const Obstacle, existing: []const Segment, preferred: ?[]const u8) GlobalScore {
    const r = if (existing.len == 0) .{ @as(usize, 0), @as(f32, 0) } else routing.edgeCrossingsWithExisting(points, existing);
    return .{
        .hard = pc.flowchartEndpointDirectionViolationCount(points, edge, nodes) + routing.pathObstacleIntersections(points, obstacles, edge.from, edge.to),
        .reentries = pc.flowchartEndpointReentryCount(points, edge, nodes),
        .non_endpoint_hits = @intFromBool(pc.flowchartPathHitsNonEndpointNodes(points, edge.from, edge.to, nodes)),
        .label_hits = routing.pathLabelIntersections(points, labels, preferred),
        .crossings = r[0],
        .overlap = r[1],
        .bends = geometry.pathBendCount(points),
        .len = geometry.pathLength(points),
    };
}

fn occCell(config: *const LayoutConfig) f32 {
    return @max(config.node_spacing, L.MIN_NODE_SPACING_FLOOR) * L.EDGE_OCCUPANCY_CELL_RATIO;
}

fn avoidShortTie(e: *const Edge) bool {
    var max_chars: usize = 0;
    for ([_]?[]const u8{ e.label, e.start_label, e.end_label }) |l| if (l) |s| {
        max_chars = @max(max_chars, util.charCount(s));
    };
    return e.start_label != null or e.end_label != null or max_chars >= L.FLOWCHART_EDGE_LABEL_WRAP_TRIGGER_CHARS;
}

const RerouteShared = struct {
    st: *LabelState,
    edge_labels: []const ?TextBlock,
    pad_x: f32,
    pad_y: f32,
    route_labels_via: bool,
    ports: []const EdgePortInfo,
    lane_offsets: []const f32,
    channels: []const routing.ReservedRoutingChannel,
};

fn rerouteCandidate(c: *const Common, rs: *const RerouteShared, idx: usize, edge: *const Edge, from: *const NodeLayout, to: *const NodeLayout, occupancy: ?*const routing.EdgeOccupancy, existing: []const Segment, preferred_id: ?[]const u8, preferred_index: ?usize) Allocator.Error![]Point {
    const port = if (idx < rs.ports.len) rs.ports[idx] else EdgePortInfo{};
    var ctx = c.baseCtx(edge, from, to, port, rs.st.obstacles.items);
    ctx.base_offset = if (idx < rs.lane_offsets.len) rs.lane_offsets[idx] else 0;
    ctx.prefer_shorter_ties = !avoidShortTie(edge);
    ctx.preferred_label_id = preferred_id;
    ctx.preferred_label_obstacle = if (preferred_index) |pi| (if (pi < rs.st.obstacles.items.len) &rs.st.obstacles.items[pi] else null) else null;
    ctx.preferred_label_clearance = @max(@max(rs.pad_x, rs.pad_y) + c.config.node_spacing * 0.25, 8.0);
    ctx.reserved_channels = rs.channels;
    var cand = try routing.routeEdgeWithAvoidance(c.a, &ctx, occupancy, c.grid, existing);
    if (rs.route_labels_via) try syncRouteLabelPlan(c.a, idx, &cand, .{ .direction = c.graph.direction, .kind = c.graph.kind, .st = rs.st, .labels = rs.edge_labels, .pad_x = rs.pad_x, .pad_y = rs.pad_y, .update_obstacle = true });
    return cand;
}

fn preferredFor(st: *const LabelState, idx: usize) struct { ?[]const u8, ?usize } {
    if (idx < st.plans.len) if (st.plans[idx]) |p| return .{ p.obstacle_id, p.obstacle_index };
    return .{ null, null };
}

fn optimizeGlobally(c: *const Common, rs: *const RerouteShared, passes: usize, order: []const usize, routed: [][]Point) Allocator.Error!void {
    if (passes == 0) return;
    for (0..passes) |_| {
        var changed = false;
        for (order) |idx| {
            if (idx >= c.graph.edges.items.len) continue;
            const edge = &c.graph.edges.items[idx];
            if (util.eql(edge.from, edge.to) or routed[idx].len < 2) continue;
            const ft = effectiveEdgeEndpointLayouts(c.graph, c.nodes, c.subgraphs, edge) orelse continue;
            const existing = try collectOtherSegments(c.a, routed, idx);
            const pref = preferredFor(rs.st, idx);
            const baseline = scoreGlobal(routed[idx], edge, c.nodes, c.obstacles, rs.st.obstacles.items, existing, pref[0]);
            var occ_store: routing.EdgeOccupancy = undefined;
            var occ: ?*const routing.EdgeOccupancy = null;
            if (routed.len > 2) {
                occ_store = routing.EdgeOccupancy.init(occCell(c.config));
                var any = false;
                for (routed, 0..) |p, i| {
                    if (i == idx or p.len < 2) continue;
                    try occ_store.addPath(c.a, p);
                    any = true;
                }
                if (any) occ = &occ_store;
            }
            const cand = try rerouteCandidate(c, rs, idx, edge, &ft[0], &ft[1], occ, existing, pref[0], pref[1]);
            const score = scoreGlobal(cand, edge, c.nodes, c.obstacles, rs.st.obstacles.items, existing, pref[0]);
            if (baseline.hard == 0 and score.hard > 0) continue;
            if (baseline.non_endpoint_hits == 0 and score.non_endpoint_hits > 0) continue;
            if (score.reentries > baseline.reentries) continue;
            if (score.bends > baseline.bends + 2 and score.len > baseline.len * 1.8) continue;
            if (score.len > baseline.len * 3.0 + c.config.node_spacing * 4.0) continue;
            if (globalScoreBetter(score, baseline)) {
                routed[idx] = cand;
                changed = true;
            }
        }
        if (!changed) break;
    }
}

fn congestionTrigger(points: []const Point, occ: *const routing.EdgeOccupancy) u32 {
    return routing.toU32(@ceil(@max((geometry.pathLength(points) / occ.cell) * 0.22, 3.0)));
}

fn congestionImprovesEnough(c: GlobalScore, b: GlobalScore, cc: u32, bc: u32, config: *const LayoutConfig) bool {
    if (b.hard == 0 and c.hard > 0) return false;
    if (b.non_endpoint_hits == 0 and c.non_endpoint_hits > 0) return false;
    if (c.reentries > b.reentries) return false;
    if (c.label_hits > b.label_hits) return false;
    if (c.len > b.len * 2.2 + config.node_spacing * 4.0) return false;
    if (c.bends > b.bends) return false;
    if (c.len > b.len * 1.15 + config.node_spacing) return false;
    if (globalScoreBetter(c, b)) return true;
    if (bc -| cc < 5) return false;
    return c.crossings < b.crossings or c.overlap + 0.05 < b.overlap or cc *| 2 < bc;
}

fn negotiateCongestion(c: *const Common, rs: *const RerouteShared, passes: usize, order: []const usize, routed: [][]Point) Allocator.Error!void {
    if (passes == 0) return;
    var history = routing.EdgeOccupancy.init(occCell(c.config));
    for (0..passes) |_| {
        var changed = false;
        for (order) |idx| {
            if (idx >= c.graph.edges.items.len) continue;
            const edge = &c.graph.edges.items[idx];
            if (util.eql(edge.from, edge.to) or routed[idx].len < 2) continue;
            var occ = routing.EdgeOccupancy.init(occCell(c.config));
            if (!history.isEmpty()) try occ.mergeFrom(c.a, &history);
            for (routed, 0..) |p, i| {
                if (i == idx or p.len < 2) continue;
                try occ.addPath(c.a, p);
            }
            if (occ.isEmpty()) continue;
            const base_cong = occ.scorePath(routed[idx]);
            const base_overlap = occ.overlapCount(routed[idx]);
            if (base_overlap < congestionTrigger(routed[idx], &occ) and base_cong < 18) continue;
            const ft = effectiveEdgeEndpointLayouts(c.graph, c.nodes, c.subgraphs, edge) orelse continue;
            const existing = try collectOtherSegments(c.a, routed, idx);
            const pref = preferredFor(rs.st, idx);
            const baseline = scoreGlobal(routed[idx], edge, c.nodes, c.obstacles, rs.st.obstacles.items, existing, pref[0]);
            const cand = try rerouteCandidate(c, rs, idx, edge, &ft[0], &ft[1], &occ, existing, pref[0], pref[1]);
            const score = scoreGlobal(cand, edge, c.nodes, c.obstacles, rs.st.obstacles.items, existing, pref[0]);
            const cand_cong = occ.scorePath(cand);
            if (congestionImprovesEnough(score, baseline, cand_cong, base_cong, c.config)) {
                if (cand_cong >= base_cong) try history.addPathWithWeight(c.a, cand, 2);
                routed[idx] = cand;
                changed = true;
            } else if (base_overlap >= congestionTrigger(routed[idx], &occ)) {
                try history.addPathWithWeight(c.a, routed[idx], 2);
            }
        }
        if (!changed) break;
    }
}

// ---- post_route.rs ---------------------------------------------------------------------------

fn applyEdgePathCleanup(a: Allocator, graph: *const Graph, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, routed: [][]Point, config: *const LayoutConfig) Allocator.Error!void {
    if (graph.kind == .flowchart) {
        try pc.reduceOrthogonalPathCrossings(a, graph, nodes, routed, config);
        try pc.deoverlapFlowchartPaths(a, graph, nodes, routed, config);
        try pc.simplifyDetourRectangles(a, graph, nodes, routed);
        try pc.simplifyAxisOscillations(a, routed);
        try pc.detourAroundNonEndpointNodes(a, graph, nodes, routed, config);
        try pc.detourAroundForeignSubgraphs(a, graph, nodes, subgraphs, routed, config);
        try pc.simplifyAxisOscillations(a, routed);
    } else if (graph.kind == .class or graph.kind == .er or graph.kind == .state) {
        try pc.reduceOrthogonalPathCrossings(a, graph, nodes, routed, config);
        if (graph.kind == .er) try pc.deoverlapFlowchartPaths(a, graph, nodes, routed, config);
        try pc.simplifyAxisOscillations(a, routed);
    }
}

fn liangBarsky(p: Point, q: Point, rect: t.Rect) bool {
    const dx = q[0] - p[0];
    const dy = q[1] - p[1];
    const ps = [4]f32{ -dx, dx, -dy, dy };
    const qs = [4]f32{ p[0] - rect[0], rect[0] + rect[2] - p[0], p[1] - rect[1], rect[1] + rect[3] - p[1] };
    var uu1: f32 = 0;
    var uu2: f32 = 1;
    for (ps, qs) |pi, qi| {
        if (@abs(pi) <= std.math.floatEps(f32)) {
            if (qi < 0.0) return false;
            continue;
        }
        const tt = qi / pi;
        if (pi < 0.0) {
            if (tt > uu2) return false;
            uu1 = @max(uu1, tt);
        } else {
            if (tt < uu1) return false;
            uu2 = @min(uu2, tt);
        }
    }
    return true;
}

fn adjustedFlowchartLabelAnchor(anchor_opt: ?Point, label_opt: ?TextBlock, points: []const Point) ?Point {
    const anchor = anchor_opt orelse return anchor_opt;
    const label = label_opt orelse return anchor_opt;
    const cl: f32 = 8.0;
    const overlaps = struct {
        fn f(c: Point, l: TextBlock, pts: []const Point) bool {
            const rect = t.Rect{ c[0] - l.width / 2.0 - 8.0, c[1] - l.height / 2.0 - 8.0, l.width + 16.0, l.height + 16.0 };
            if (pts.len < 2) return false;
            for (0..pts.len - 1) |i| if (liangBarsky(pts[i], pts[i + 1], rect)) return true;
            return false;
        }
    }.f;
    if (!overlaps(anchor, label, points) and label.height < 80.0) return anchor;
    if (label.height >= 80.0) return .{ anchor[0], anchor[1] - label.height - cl * 3.0 };
    const oy = label.height + cl * 3.0;
    const ox = label.width * 0.5 + cl * 3.0;
    const cands = [_]Point{
        .{ anchor[0], anchor[1] - oy },      .{ anchor[0], anchor[1] + oy },
        .{ anchor[0] - ox, anchor[1] },      .{ anchor[0] + ox, anchor[1] },
        .{ anchor[0] - ox, anchor[1] - oy }, .{ anchor[0] + ox, anchor[1] - oy },
        .{ anchor[0] - ox, anchor[1] + oy }, .{ anchor[0] + ox, anchor[1] + oy },
    };
    for (cands) |c| if (!overlaps(c, label, points)) return c;
    return anchor;
}

// ---- build_routed_edges ------------------------------------------------------------------------

pub const BuildContext = struct {
    graph: *const Graph,
    nodes: *const NodeMap,
    subgraphs: []const SubgraphLayout,
    config: *const LayoutConfig,
    layout_node_count: usize,
    edge_route_labels: []const ?TextBlock,
    edge_start_labels: []const ?TextBlock,
    edge_end_labels: []const ?TextBlock,
    tiny_graph: bool,
};

const RouteOrder = struct { prio: u8, cross: f32, main: f32, idx: usize };

pub fn buildRoutedEdges(a: Allocator, bc: BuildContext) Allocator.Error!std.ArrayList(EdgeLayout) {
    const graph = bc.graph;
    const nodes = bc.nodes;
    const subgraphs = bc.subgraphs;
    const config = bc.config;
    const n_edges = graph.edges.items.len;
    const obstacles = try routing.buildObstacles(a, nodes, subgraphs, config);
    const label_obstacles = try routing.buildLabelObstaclesForRouting(a, nodes, subgraphs);
    var grid_store: ?routing.RoutingGrid = null;
    if (config.flowchart.routing.enable_grid_router and !bc.tiny_graph) grid_store = try routing.buildRoutingGrid(a, obstacles, config);
    const grid: ?*const routing.RoutingGrid = if (grid_store) |*g| g else null;
    const channels = try buildReservedChannels(a, graph, nodes, config);
    const common: Common = .{ .a = a, .graph = graph, .nodes = nodes, .subgraphs = subgraphs, .obstacles = obstacles, .grid = grid, .config = config };

    const bounds = visibleNodeBounds(nodes);
    var degrees: ranking.Ranks = .empty;
    for (graph.edges.items) |e| for ([_][]const u8{ e.from, e.to }) |id| {
        const gop = try degrees.getOrPut(a, id);
        gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
    };
    const roles = try classifyEdgeRoles(a, graph);
    var loads: routing.SideLoads = .empty;
    const perf = performanceProfile(graph, bc.layout_node_count, bc.tiny_graph);
    const ports = try a.alloc(EdgePortInfo, n_edges);
    for (ports) |*p| p.* = .{};
    const selected = try a.alloc([2]EdgeSide, n_edges);
    for (selected) |*s| s.* = .{ .right, .left };
    var side_segments: std.ArrayList(Segment) = .empty;
    for (graph.edges.items, 0..) |*edge, idx| {
        const ft = effectiveEdgeEndpointLayouts(graph, nodes, subgraphs, edge) orelse continue;
        const from = &ft[0];
        const to = &ft[1];
        const fd = degrees.get(edge.from) orelse 0;
        const td = degrees.get(edge.to) orelse 0;
        const role = roles[idx];
        const allow_low = allowLowDegreeBalancing(edge, role, fd, td);
        const primary = routing.edgeSides(from, to, graph.direction);
        const balanced = routing.edgeSidesBalanced(edge.from, edge.to, from, to, allow_low, role.is_back_edge, graph.direction, &degrees, &loads);
        var sel: Sides = if (!util.eql(edge.from, edge.to) and perf.side_search != null) blk: {
            const sc: SideChoiceCtx = .{ .direction = graph.direction, .bounds = bounds, .degrees = &degrees, .loads = &loads, .labels = label_obstacles.items, .existing = side_segments.items, .profile = perf.side_search.? };
            break :blk try chooseRoutedSides(&common, &sc, edge, from, to, primary, balanced, role);
        } else if (role.is_back_edge) chooseOuterBackEdgeSides(from, to, graph.direction, bounds, balanced) else balanced;
        if (!role.is_back_edge and (sel[0] != primary[0] or sel[1] != primary[1])) {
            const cp = [_]Point{ routing.anchorPointForNode(from, sel[0], 0), routing.anchorPointForNode(to, sel[1], 0) };
            const pp = [_]Point{ routing.anchorPointForNode(from, primary[0], 0), routing.anchorPointForNode(to, primary[1], 0) };
            if (routing.edgeCrossingsWithExisting(&cp, side_segments.items)[0] > routing.edgeCrossingsWithExisting(&pp, side_segments.items)[0]) sel = primary;
        }
        try routing.bumpSideLoad(a, &loads, edge.from, sel[0]);
        try routing.bumpSideLoad(a, &loads, edge.to, sel[1]);
        ports[idx] = .{ .start_side = sel[0], .end_side = sel[1] };
        selected[idx] = .{ sel[0], sel[1] };
        try side_segments.append(a, .{ routing.anchorPointForNode(from, sel[0], 0), routing.anchorPointForNode(to, sel[1], 0) });
    }
    var side_counts: routing.SideLoads = .empty;
    for (graph.edges.items, 0..) |e, idx| {
        try routing.bumpSideLoad(a, &side_counts, e.from, selected[idx][0]);
        try routing.bumpSideLoad(a, &side_counts, e.to, selected[idx][1]);
    }
    const TrackKey = struct { id: []const u8, track: PortTrack };
    const PCand = routing.PortCandidate;
    var track_keys: std.ArrayList(TrackKey) = .empty;
    var track_cands: std.ArrayList(std.ArrayList(PCand)) = .empty;
    const findTrack = struct {
        fn f(keys: []const TrackKey, id: []const u8, tr: PortTrack) ?usize {
            for (keys, 0..) |k, i| if (util.eql(k.id, id) and k.track.kind == tr.kind and (if (tr.kind == .side) k.track.side == tr.side else k.track.axis == tr.axis)) return i;
            return null;
        }
    }.f;
    for (graph.edges.items, 0..) |*edge, idx| {
        const ft = effectiveEdgeEndpointLayouts(graph, nodes, subgraphs, edge) orelse continue;
        const from = &ft[0];
        const to = &ft[1];
        const ss = selected[idx][0];
        const es = selected[idx][1];
        const sc = side_counts.get(edge.from) orelse [4]usize{ 0, 0, 0, 0 };
        const ec = side_counts.get(edge.to) orelse [4]usize{ 0, 0, 0, 0 };
        const fa = routing.anchorPointForNode(from, ss, 0);
        const ta = routing.anchorPointForNode(to, es, 0);
        const entries = [_]struct { []const u8, PortTrack, PCand }{
            .{ edge.from, portTrackForAssignment(from, ss, degrees.get(edge.from) orelse 0, sc), .{ .edge_idx = idx, .is_start = true, .other_pos = routing.idealPortPos(ta, from, ss) } },
            .{ edge.to, portTrackForAssignment(to, es, degrees.get(edge.to) orelse 0, ec), .{ .edge_idx = idx, .is_start = false, .other_pos = routing.idealPortPos(fa, to, es) } },
        };
        for (entries) |en| {
            const ti = findTrack(track_keys.items, en[0], en[1]) orelse blk: {
                try track_keys.append(a, .{ .id = en[0], .track = en[1] });
                try track_cands.append(a, .empty);
                break :blk track_keys.items.len - 1;
            };
            try track_cands.items[ti].append(a, en[2]);
        }
    }
    const cell = routing.routingCellSize(config);
    for (track_keys.items, track_cands.items) |key, cands_list| {
        const node = nodes.get(key.id) orelse continue;
        const cands = cands_list.items;
        var min_o: f32 = FMAX;
        var max_o: f32 = FMIN;
        for (cands) |c| {
            min_o = @min(min_o, c.other_pos);
            max_o = @max(max_o, c.other_pos);
        }
        const span = @max(max_o - min_o, 0.0);
        const order = try a.alloc(usize, cands.len);
        for (order, 0..) |*o, i| o.* = i;
        std.mem.sort(usize, order, cands, struct {
            fn lt(cs: []const PCand, x: usize, y: usize) bool {
                return cs[x].other_pos < cs[y].other_pos;
            }
        }.lt);
        const node_len = trackNodeLen(node, key.track);
        const pad = @max(@min(node_len * config.flowchart.port_pad_ratio, config.flowchart.port_pad_max), config.flowchart.port_pad_min);
        const usable = @max(node_len - 2.0 * pad, 1.0);
        const nf: f32 = @floatFromInt(cands.len);
        const nominal = usable / (nf + 1.0);
        var labeled: f32 = 0;
        for (cands) |c| {
            const e = graph.edges.items[c.edge_idx];
            if (nonEmpty(e.label) or nonEmpty(e.start_label) or nonEmpty(e.end_label)) labeled += 1;
        }
        const boost = 1.0 + @min(labeled * 0.07, 0.35) + @min(@max(nf - 3.0, 0.0) * 0.03, 0.25);
        const grid_floor: f32 = if (cell > 0.0) cell * 0.85 else 0.0;
        const desired_sep = @max(nominal * boost, grid_floor);
        const feasible = if (cands.len <= 1) usable else usable / (nf - 0.15);
        const min_sep = @min(desired_sep, @max(feasible, nominal));
        const snap = config.flowchart.routing.snap_ports_to_grid and cell > 0.0 and min_sep >= cell * 0.75;
        const node_start = trackNodeStart(node, key.track);
        const span_frac: f32 = if (usable > 1.0) @min(span / usable, 2.0) else 1.0;
        const pos_w = std.math.clamp(0.5 + 0.35 * span_frac, 0.50, 0.85);
        const rank_w = 1.0 - pos_w;
        const desired = try a.alloc(f32, cands.len);
        for (order, 0..) |ci, rank| {
            const tp = std.math.clamp((cands[ci].other_pos - node_start - pad) / usable, 0.0, 1.0);
            const tr = (@as(f32, @floatFromInt(rank)) + 0.5) / nf;
            desired[rank] = pad + (tp * pos_w + tr * rank_w) * usable;
        }
        const assigned = try a.alloc(f32, cands.len);
        @memset(assigned, 0);
        var prev = pad;
        for (order, 0..) |ci, oi| {
            var p = desired[oi];
            p = if (oi == 0) @max(p, pad) else @max(p, prev + min_sep);
            assigned[ci] = p;
            prev = p;
        }
        var next = pad + usable;
        var oi = order.len;
        while (oi > 0) {
            oi -= 1;
            const ci = order[oi];
            var p = assigned[ci];
            p = if (oi + 1 == order.len) @min(p, next) else @min(p, next - min_sep);
            assigned[ci] = p;
            next = p;
        }
        for (order, 0..) |ci, rank| {
            const c = cands[ci];
            var offset = assigned[ci] - node_len / 2.0;
            if (snap) offset = @round(offset / cell) * cell;
            if (config.flowchart.port_side_bias != 0.0) {
                const scale: f32 = if (cands.len > 2) 1.0 + @min((nf - 2.0) * 0.08, 0.6) else 1.0;
                offset += config.flowchart.port_side_bias * scale * (@as(f32, @floatFromInt(rank)) - (nf - 1.0) / 2.0);
            }
            if (c.is_start) ports[c.edge_idx].start_offset = offset else ports[c.edge_idx].end_offset = offset;
        }
    }
    if (perf.side_search) |profile| try refinePorts(&common, label_obstacles.items, roles, bounds, &degrees, &loads, profile, ports);

    const lanes = try planEdgeLanes(a, graph, nodes, subgraphs, config);
    const lane_offsets = try lanes.effectiveOffsets(a, ports, graph.kind, config);

    var route_order: std.ArrayList(RouteOrder) = .empty;
    const dense = graph.kind == .flowchart and n_edges >= 18 and n_edges * 2 >= bc.layout_node_count * 3;
    const h = isHorizontal(graph.direction);
    for (graph.edges.items, 0..) |*edge, idx| {
        const ft = effectiveEdgeEndpointLayouts(graph, nodes, subgraphs, edge) orelse continue;
        const fc = geometry.nodeCenter(&ft[0]);
        const tc = geometry.nodeCenter(&ft[1]);
        const dx = tc[0] - fc[0];
        const dy = tc[1] - fc[1];
        const backward = routing.edgeSides(&ft[0], &ft[1], graph.direction)[2];
        const dotted = edge.style == .dotted;
        const has_label = edge.label != null;
        const open_tri = edge.arrow_start_kind == .open_triangle or edge.arrow_end_kind == .open_triangle;
        const prio: u8 = if (graph.kind == .class)
            (if (open_tri) 0 else if (dotted or has_label or backward) 1 else 2)
        else if (graph.kind == .state)
            (if (backward) 0 else if (has_label or dotted) 1 else 2)
        else if (dotted)
            (if (dense) 1 else 2)
        else if (has_label or backward) 1 else 0;
        try route_order.append(a, .{ .prio = prio, .cross = if (h) @abs(dy) else @abs(dx), .main = if (h) @abs(dx) else @abs(dy), .idx = idx });
    }
    var steep: usize = 0;
    for (route_order.items) |r| {
        if (r.cross > r.main * 0.8) steep += 1;
    }
    const use_cross_order = n_edges >= 10 and steep * 4 >= n_edges;
    const SortCtx = struct { cross: bool, pre: bool, dense: bool };
    std.mem.sort(RouteOrder, route_order.items, SortCtx{ .cross = use_cross_order, .pre = n_edges >= 10, .dense = dense }, struct {
        fn lt(c: SortCtx, x: RouteOrder, y: RouteOrder) bool {
            if (c.cross) {
                if (x.prio != y.prio) return x.prio < y.prio;
                if (x.cross != y.cross) return x.cross < y.cross;
                if (x.main != y.main) return y.main < x.main;
                return x.idx < y.idx;
            }
            const lx = x.cross * x.cross + x.main * x.main;
            const ly = y.cross * y.cross + y.main * y.main;
            if (c.pre) {
                if (x.prio != y.prio) return x.prio < y.prio;
                if (lx != ly) return if (c.dense) lx < ly else ly < lx;
                return x.idx < y.idx;
            }
            if (lx != ly) return ly < lx;
            return x.idx < y.idx;
        }
    }.lt);

    const routed = try a.alloc([]Point, n_edges);
    for (routed) |*r| r.* = &.{};
    var occupancy: ?routing.EdgeOccupancy = if (perf.use_route_occupancy) routing.EdgeOccupancy.init(occCell(config)) else null;
    const via = shouldRouteLabelsVia(graph, nodes);
    const pad = L.edgeLabelPadding(graph.kind);
    var st: LabelState = .{ .plans = try a.alloc(?RouteLabelPlan, n_edges), .obstacles = label_obstacles, .anchors = try a.alloc(?Point, n_edges) };
    @memset(st.plans, null);
    @memset(st.anchors, null);
    if (via) {
        for (0..n_edges) |idx| {
            const label = (if (idx < bc.edge_route_labels.len) bc.edge_route_labels[idx] else null) orelse continue;
            if (label.width <= 0.0 or label.height <= 0.0) continue;
            if (graph.kind == .flowchart and !labelNeedsReservedGap(&label, config)) continue;
            const center = provisionalRouteLabelCenter(graph, nodes, subgraphs, ports, lanes.pair_index, lane_offsets, pad[0], pad[1], config, idx, &label) orelse continue;
            const oid = try std.fmt.allocPrint(a, "edge-label-reserved:{d}", .{idx});
            const oi = st.obstacles.items.len;
            try st.obstacles.append(a, .{ .id = oid, .x = center[0] - label.width / 2.0 - pad[0], .y = center[1] - label.height / 2.0 - pad[1], .width = label.width + 2.0 * pad[0], .height = label.height + 2.0 * pad[1] });
            st.plans[idx] = .{ .obstacle_id = oid, .obstacle_index = oi, .progress = 0.5, .center = center };
        }
    }
    var existing: std.ArrayList(Segment) = .empty;
    for (route_order.items) |ro| {
        const idx = ro.idx;
        const edge = &graph.edges.items[idx];
        const key = try routing.edgePairKey(a, edge);
        const total: f32 = @floatFromInt(lanes.pair_counts.get(key) orelse 1);
        const in_pair: f32 = @floatFromInt(lanes.pair_index[idx]);
        const base_offset = if (graph.kind == .flowchart)
            lane_offsets[idx]
        else if (total > 1.0)
            (in_pair - (total - 1.0) / 2.0) * (config.node_spacing * L.MULTI_EDGE_OFFSET_RATIO) + lanes.cross_edge_offsets[idx]
        else
            lanes.cross_edge_offsets[idx];
        const ft = effectiveEdgeEndpointLayouts(graph, nodes, subgraphs, edge) orelse continue;
        const from = &ft[0];
        const to = &ft[1];
        const port = ports[idx];
        const stub_len: f32 = switch (graph.kind) {
            .class, .er, .requirement => 0.0,
            else => routing.portStubLength(config, from, to),
        };
        const avoid_short = graph.kind == .flowchart and avoidShortTie(edge);
        const plan = st.plans[idx];
        var ctx = common.baseCtx(edge, from, to, port, st.obstacles.items);
        ctx.fast_route = bc.tiny_graph;
        ctx.base_offset = base_offset;
        ctx.stub_len = stub_len;
        ctx.prefer_shorter_ties = !avoid_short;
        ctx.preferred_label_id = if (plan) |p| p.obstacle_id else null;
        ctx.preferred_label_obstacle = if (plan) |p| (if (p.obstacle_index < st.obstacles.items.len) &st.obstacles.items[p.obstacle_index] else null) else null;
        ctx.preferred_label_clearance = if (graph.kind == .flowchart) @max(@max(pad[0], pad[1]) + config.node_spacing * 0.25, 8.0) else 0.0;
        ctx.preferred_label_center = switch (graph.kind) {
            .state, .er, .flowchart, .class => null,
            else => if (plan) |p| p.center else null,
        };
        ctx.reserved_channels = channels;
        ctx.force_preferred_label_via = graph.kind != .flowchart;
        ctx.coarse_grid_retry = graph.kind == .flowchart;
        ctx.allow_exterior_fallback = perf.allow_exterior_fallback;
        const use_existing = !((graph.kind == .class or graph.kind == .er) and edge.style == .dotted);
        const ex: ?[]const Segment = if (use_existing) existing.items else null;
        const occ_ptr: ?*const routing.EdgeOccupancy = if (occupancy) |*o| o else null;
        var points = try routing.routeEdgeWithAvoidance(a, &ctx, occ_ptr, grid, ex);
        if (graph.kind == .class or graph.kind == .er) {
            var fast = ctx;
            fast.fast_route = true;
            fast.allow_exterior_fallback = false;
            const fp = try routing.routeEdgeWithAvoidance(a, &fast, null, null, ex);
            const fh = routing.pathObstacleIntersections(fp, ctx.obstacles, ctx.from_id, ctx.to_id);
            const flh = routing.pathLabelIntersections(fp, ctx.label_obstacles, ctx.preferred_label_id);
            if (fh == 0 and flh == 0) {
                const fr = routing.edgeCrossingsWithExisting(fp, existing.items);
                const cr = routing.edgeCrossingsWithExisting(points, existing.items);
                if (fr[0] < cr[0] or (fr[0] == cr[0] and fr[1] + 0.25 < cr[1])) points = fp;
            }
        }
        if (via) try syncRouteLabelPlan(a, idx, &points, .{ .direction = graph.direction, .kind = graph.kind, .st = &st, .labels = bc.edge_route_labels, .pad_x = pad[0], .pad_y = pad[1], .update_obstacle = true });
        if (occupancy) |*o| try o.addPath(a, points);
        if (points.len >= 2) for (0..points.len - 1) |i| try existing.append(a, .{ points[i], points[i + 1] });
        routed[idx] = points;
    }

    if (graph.kind == .flowchart) {
        var order: std.ArrayList(usize) = .empty;
        for (route_order.items) |r| try order.append(a, r.idx);
        if (order.items.len != n_edges) {
            order.clearRetainingCapacity();
            for (0..n_edges) |i| try order.append(a, i);
        }
        const rs: RerouteShared = .{ .st = &st, .edge_labels = bc.edge_route_labels, .pad_x = pad[0], .pad_y = pad[1], .route_labels_via = via, .ports = ports, .lane_offsets = lane_offsets, .channels = channels };
        try optimizeGlobally(&common, &rs, perf.global_route_passes, order.items, routed);
        try negotiateCongestion(&common, &rs, perf.negotiated_congestion_passes, order.items, routed);
    }
    try applyEdgePathCleanup(a, graph, nodes, subgraphs, routed, config);
    if (via) for (0..routed.len) |idx| try syncRouteLabelPlan(a, idx, &routed[idx], .{ .direction = graph.direction, .kind = graph.kind, .st = &st, .labels = bc.edge_route_labels, .pad_x = pad[0], .pad_y = pad[1], .update_obstacle = false });
    if (graph.kind == .flowchart) {
        try pc.detourAroundNonEndpointNodes(a, graph, nodes, routed, config);
        try pc.simplifyAxisOscillations(a, routed);
        try pc.detourAroundNonEndpointNodes(a, graph, nodes, routed, config);
        // apply_label_dummy_anchors: no label dummies for these kinds.
        try pc.detourAroundNonEndpointNodes(a, graph, nodes, routed, config);
        try pc.detourAroundForeignSubgraphs(a, graph, nodes, subgraphs, routed, config);
        try pc.simplifyAxisOscillations(a, routed);
        try enforceEndpointPorts(a, graph, nodes, ports, routed, config);
        try pc.repairFlowchartEndpointReentries(a, graph, nodes, routed, config);
        try repairEndpointReentriesByRerouting(&common, st.obstacles.items, lane_offsets, channels, ports, routed);
        try pc.repairFlowchartEndpointReentries(a, graph, nodes, routed, config);
    }

    var edges: std.ArrayList(EdgeLayout) = .empty;
    for (graph.edges.items, 0..) |e, idx| {
        const label = if (idx < bc.edge_route_labels.len) bc.edge_route_labels[idx] else null;
        const anchor = if (graph.kind == .flowchart) adjustedFlowchartLabelAnchor(st.anchors[idx], label, routed[idx]) else st.anchors[idx];
        var pts: std.ArrayList(Point) = .empty;
        try pts.appendSlice(a, routed[idx]);
        try edges.append(a, .{
            .from = e.from,
            .to = e.to,
            .label = label,
            .start_label = if (idx < bc.edge_start_labels.len) bc.edge_start_labels[idx] else null,
            .end_label = if (idx < bc.edge_end_labels.len) bc.edge_end_labels[idx] else null,
            .points = pts,
            .directed = e.directed,
            .arrow_start = e.arrow_start,
            .arrow_end = e.arrow_end,
            .arrow_start_kind = e.arrow_start_kind,
            .arrow_end_kind = e.arrow_end_kind,
            .start_decoration = e.start_decoration,
            .end_decoration = e.end_decoration,
            .style = e.style,
            .override_style = L.resolveEdgeStyle(idx, graph),
            .label_anchor = anchor,
        });
    }
    return edges;
}
