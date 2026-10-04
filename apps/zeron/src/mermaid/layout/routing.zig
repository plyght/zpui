//! `layout/routing.rs`: edge side selection, port anchors, obstacle-aware
//! candidate routing, the A* grid router and path metrics.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir.zig");
const util = @import("../util.zig");
const LayoutConfig = @import("../config.zig").LayoutConfig;
const t = @import("types.zig");
const geometry = @import("geometry.zig");
const ranking = @import("ranking.zig");
pub const EdgeSide = geometry.EdgeSide;
const NodeLayout = t.NodeLayout;
const SubgraphLayout = t.SubgraphLayout;
const NodeMap = t.NodeMap;
const Point = t.Point;
const Direction = ir.Direction;
const StrSet = ranking.StrSet;
const pathBendCount = geometry.pathBendCount;
const pathLength = geometry.pathLength;
const segmentsIntersect = geometry.segmentsIntersect;
const FMAX = std.math.floatMax(f32);
const FMIN = -std.math.floatMax(f32);

const DIRECTION_PREF_RATIO: f32 = 1.35;
const ROUTE_DETOUR_THRESHOLD: f32 = 120.0;
const SIDE_LOAD_SOFT_CAP: f32 = 6.0;
const HUB_DIVERSIFY_GEOM_RATIO: f32 = 1.35;
const HUB_DIVERSIFY_LOAD_SUM: usize = 14;
const LOW_DEGREE_BALANCE_MIN_PRIMARY_LOAD: usize = 4;
const PORT_STUB_RATIO: f32 = 0.35;
const PORT_STUB_SIZE_CAP_RATIO: f32 = 0.35;
const PORT_STUB_DEFAULT_MAX: f32 = 18.0;
const PORT_STUB_MIN: f32 = 6.0;
const PORT_STUB_MAX: f32 = 22.0;
const ROUTING_CELL_RATIO: f32 = 0.35;
const ROUTING_CELL_MIN: f32 = 8.0;
const ROUTING_CELL_FALLBACK_SCALE: f32 = 1.45;
const GRID_MARGIN_MIN_SPACING: f32 = 24.0;
const ASTAR_COST_SCALE: f32 = 1000.0;
const ROUTING_PAD_RATIO: f32 = 0.6;
const ROUTING_PAD_MIN_SPACING: f32 = 20.0;
const ORTHO_STEP_MIN_SPACING: f32 = 16.0;
const CHANNEL_CANDIDATE_RATIO: f32 = 0.75;
const OBSTACLE_PAD_RATIO: f32 = 0.35;
const OBSTACLE_PAD_MIN: f32 = 6.0;
const OVERLAP_TRIGGER_RATIO: f32 = 0.35;
const OVERLAP_TRIGGER_MIN: f32 = 4.0;
const OVERLAP_DETOUR_MIN: f32 = 3.0;
const ROUTE_LENGTH_TIE_EPS: f32 = 2.0;
const ROUTE_CROSSING_DETOUR_RATIO: f32 = 2.0;
const ROUTE_CROSSING_DETOUR_MIN_SPACING: f32 = 40.0;
const ROUTE_CROSSING_DETOUR_RELATIVE: f32 = 1.0;
const ROUTE_VIA_TIE_EPS: f32 = 0.4;
const ROUTE_SOFT_NODE_CLEARANCE: f32 = 3.0;
const ROUTE_SOFT_LABEL_CLEARANCE: f32 = 4.0;
const ROUTE_SOFT_EDGE_CLEARANCE: f32 = 4.0;
const ROUTE_OWN_LABEL_HARD_WEIGHT: usize = 6;
const ROUTE_OWN_LABEL_NEAR_WEIGHT: usize = 3;
const EXTERIOR_FALLBACK_PAD_RATIO: f32 = 1.35;
const EXTERIOR_FALLBACK_PAD_MIN: f32 = 36.0;
const LABEL_OBSTACLE_NODE_PAD: f32 = 2.0;
const LABEL_OBSTACLE_SUB_PAD: f32 = 3.0;

pub const PortAxis = enum { x, y };

pub const EdgePortInfo = struct {
    start_side: EdgeSide = .right,
    end_side: EdgeSide = .left,
    start_offset: f32 = 0,
    end_offset: f32 = 0,
};

pub const PortCandidate = struct { edge_idx: usize, is_start: bool, other_pos: f32 };

pub const Obstacle = struct {
    id: []const u8,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    members: ?*const StrSet = null,
};

pub const ChannelAxis = enum { vertical, horizontal };

pub const ReservedRoutingChannel = struct {
    axis: ChannelAxis,
    coord: f32,
    span_min: f32,
    span_max: f32,
};

pub const Segment = struct { Point, Point };
pub const Sides = struct { EdgeSide, EdgeSide, bool };
pub const SideLoads = std.StringHashMapUnmanaged([4]usize);
pub const Degrees = ranking.Ranks;

pub fn isHorizontal(direction: Direction) bool {
    return direction == .left_right or direction == .right_left;
}

pub fn sideIsVertical(side: EdgeSide) bool {
    return side == .left or side == .right;
}

pub fn portAxis(side: EdgeSide) PortAxis {
    return if (sideIsVertical(side)) .y else .x;
}

pub fn edgeSides(from: *const NodeLayout, to: *const NodeLayout, direction: Direction) Sides {
    const fcx = from.x + from.width / 2.0;
    const fcy = from.y + from.height / 2.0;
    const tcx = to.x + to.width / 2.0;
    const tcy = to.y + to.height / 2.0;
    const dx = tcx - fcx;
    const dy = tcy - fcy;
    const x_overlap = @abs(@max(from.x, to.x) - @min(from.x + from.width, to.x + to.width)) < 1e-3 or
        (from.x < to.x + to.width and to.x < from.x + from.width);
    const y_overlap = @abs(@max(from.y, to.y) - @min(from.y + from.height, to.y + to.height)) < 1e-3 or
        (from.y < to.y + to.height and to.y < from.y + from.height);
    const ratio = @abs(dx) / @max(@abs(dy), 1e-3);
    const horiz_pref = ratio > DIRECTION_PREF_RATIO or (y_overlap and ratio > 0.9);
    const vert_pref = ratio < (1.0 / DIRECTION_PREF_RATIO) or (x_overlap and ratio < 1.1);
    const use_h = if (horiz_pref and !vert_pref) true else if (vert_pref and !horiz_pref) false else isHorizontal(direction);
    if (use_h) {
        const back = to.x + to.width < from.x;
        return if (dx >= 0.0) .{ .right, .left, back } else .{ .left, .right, back };
    }
    const back = to.y + to.height < from.y;
    return if (dy >= 0.0) .{ .bottom, .top, back } else .{ .top, .bottom, back };
}

pub fn edgeAxisIsHorizontal(side: EdgeSide) bool {
    return sideIsVertical(side);
}

pub fn sideSlot(side: EdgeSide) usize {
    return switch (side) {
        .left => 0,
        .right => 1,
        .top => 2,
        .bottom => 3,
    };
}

pub fn sideLoadForNode(loads: *const SideLoads, id: []const u8, side: EdgeSide) usize {
    const slots = loads.get(id) orelse return 0;
    return slots[sideSlot(side)];
}

pub fn bumpSideLoad(a: Allocator, loads: *SideLoads, id: []const u8, side: EdgeSide) Allocator.Error!void {
    const gop = try loads.getOrPut(a, id);
    if (!gop.found_existing) gop.value_ptr.* = .{ 0, 0, 0, 0 };
    gop.value_ptr[sideSlot(side)] += 1;
}

pub fn edgeSidesBalanced(
    from_id: []const u8,
    to_id: []const u8,
    from: *const NodeLayout,
    to: *const NodeLayout,
    allow_low_degree_balancing: bool,
    prefer_outer_sides: bool,
    direction: Direction,
    degrees: *const Degrees,
    loads: *const SideLoads,
) Sides {
    const primary = edgeSides(from, to, direction);
    if (prefer_outer_sides) {
        if (isHorizontal(direction)) {
            return if ((to.y + to.height / 2.0) >= (from.y + from.height / 2.0)) .{ .bottom, .bottom, primary[2] } else .{ .top, .top, primary[2] };
        }
        return if ((to.x + to.width / 2.0) >= (from.x + from.width / 2.0)) .{ .right, .right, primary[2] } else .{ .left, .left, primary[2] };
    }
    const fd = degrees.get(from_id) orelse 0;
    const td = degrees.get(to_id) orelse 0;
    if (fd < 6 and td < 6) {
        if (!allow_low_degree_balancing) return primary;
        const pl = sideLoadForNode(loads, from_id, primary[0]) + sideLoadForNode(loads, to_id, primary[1]);
        if (pl < LOW_DEGREE_BALANCE_MIN_PRIMARY_LOAD and !prefer_outer_sides) return primary;
    }
    const dx = (to.x + to.width / 2.0) - (from.x + from.width / 2.0);
    const dy = (to.y + to.height / 2.0) - (from.y + from.height / 2.0);
    if ((fd >= 10 and td <= 4) or (td >= 10 and fd <= 4)) {
        const forced: Sides = if (isHorizontal(direction)) blk: {
            const back = to.x + to.width < from.x;
            break :blk if (dx >= 0.0) .{ .right, .left, back } else .{ .left, .right, back };
        } else blk: {
            const back = to.y + to.height < from.y;
            break :blk if (dy >= 0.0) .{ .bottom, .top, back } else .{ .top, .bottom, back };
        };
        const fl = sideLoadForNode(loads, from_id, forced[0]) + sideLoadForNode(loads, to_id, forced[1]);
        const main_axis = if (isHorizontal(direction)) @abs(dx) else @abs(dy);
        const cross_axis = if (isHorizontal(direction)) @abs(dy) else @abs(dx);
        if (!(fl >= HUB_DIVERSIFY_LOAD_SUM and cross_axis > main_axis * HUB_DIVERSIFY_GEOM_RATIO)) return forced;
    }
    const horizontal: Sides = if (dx >= 0.0) .{ .right, .left, to.x + to.width < from.x } else .{ .left, .right, to.x > from.x + from.width };
    const vertical: Sides = if (dy >= 0.0) .{ .bottom, .top, to.y + to.height < from.y } else .{ .top, .bottom, to.y > from.y + from.height };
    var options: [3]Sides = undefined;
    var n: usize = 0;
    options[n] = primary;
    n += 1;
    for ([_]Sides{ horizontal, vertical }) |o| {
        var dup = false;
        for (options[0..n]) |e| dup = dup or (e[0] == o[0] and e[1] == o[1]);
        if (!dup) {
            options[n] = o;
            n += 1;
        }
    }
    const primary_axis = edgeAxisIsHorizontal(primary[0]);
    const pfa = anchorPointForNode(from, primary[0], 0);
    const pta = anchorPointForNode(to, primary[1], 0);
    const primary_manhattan = @abs(pta[0] - pfa[0]) + @abs(pta[1] - pfa[1]);
    var best = primary;
    var best_score: f32 = FMAX;
    var best_tie: f32 = FMAX;
    for (options[0..n]) |o| {
        const from_load: f32 = @floatFromInt(sideLoadForNode(loads, from_id, o[0]));
        const to_load: f32 = @floatFromInt(sideLoadForNode(loads, to_id, o[1]));
        const load_score = from_load * from_load + to_load * to_load + (from_load + to_load) * 0.5;
        const overload = @max(from_load - SIDE_LOAD_SOFT_CAP, 0.0) + @max(to_load - SIDE_LOAD_SOFT_CAP, 0.0);
        const overload_penalty = overload * overload * 6.0;
        const fa = anchorPointForNode(from, o[0], 0);
        const ta = anchorPointForNode(to, o[1], 0);
        const manhattan = @abs(ta[0] - fa[0]) + @abs(ta[1] - fa[1]);
        const is_primary = o[0] == primary[0] and o[1] == primary[1];
        if (!is_primary and manhattan > primary_manhattan * DIRECTION_PREF_RATIO + ROUTE_DETOUR_THRESHOLD) continue;
        const same_axis = edgeAxisIsHorizontal(o[0]) == primary_axis;
        const axis_penalty: f32 = if (same_axis) 0.0 else 5.0;
        const outer_penalty: f32 = if (prefer_outer_sides and same_axis) 6.5 else 0.0;
        const primary_penalty: f32 = if (is_primary) 0.0 else 2.0;
        const backward_penalty: f32 = if (o[2] and !primary[2]) 4.0 else 0.0;
        const score = load_score * 9.0 + overload_penalty + manhattan * 0.22 + axis_penalty + outer_penalty + primary_penalty + backward_penalty;
        const tie = manhattan + from_load + to_load;
        if (score < best_score or (@abs(score - best_score) < 1e-4 and tie < best_tie)) {
            best = o;
            best_score = score;
            best_tie = tie;
        }
    }
    return best;
}

pub const RouteContext = struct {
    from_id: []const u8,
    to_id: []const u8,
    from: *const NodeLayout,
    to: *const NodeLayout,
    direction: Direction,
    config: *const LayoutConfig,
    obstacles: []const Obstacle,
    label_obstacles: []const Obstacle,
    fast_route: bool,
    base_offset: f32,
    start_side: EdgeSide,
    end_side: EdgeSide,
    start_offset: f32,
    end_offset: f32,
    stub_len: f32,
    start_inset: f32,
    end_inset: f32,
    prefer_shorter_ties: bool,
    preferred_label_id: ?[]const u8,
    preferred_label_center: ?Point,
    preferred_label_obstacle: ?*const Obstacle,
    preferred_label_clearance: f32,
    reserved_channels: []const ReservedRoutingChannel,
    force_preferred_label_via: bool,
    coarse_grid_retry: bool,
    allow_exterior_fallback: bool,
};

const RouteEndpoints = struct {
    start: Point,
    end: Point,
    route_start: Point,
    route_end: Point,

    fn directPath(self: RouteEndpoints, a: Allocator) Allocator.Error![]Point {
        return compressPath(a, &.{ self.start, self.route_start, self.route_end, self.end });
    }

    fn finish(self: RouteEndpoints, a: Allocator, ctx: *const RouteContext, routed: []const Point) Allocator.Error![]Point {
        var combined: std.ArrayList(Point) = .empty;
        try combined.append(a, self.start);
        try combined.appendSlice(a, routed);
        try combined.append(a, self.end);
        try enforcePreferredLabelVia(a, &combined, ctx);
        return applyEndpointInsets(try compressPath(a, combined.items), ctx.start_inset, ctx.end_inset);
    }
};

const PreferredLabelMetrics = struct { hard_hits: usize = 0, near_hits: usize = 0 };

const RouteCandidate = struct {
    points: []Point,
    hard_hits: usize,
    hits: usize,
    own_label: PreferredLabelMetrics,
    cross: usize,
    label_hits: usize,
    overlap: f32,
    via_dist: f32,
    bends: usize,
    len: f32,
};

const OrderKey = struct {
    hits: usize,
    own_label_score: usize,
    cross: usize,
    label_hits: usize,
    overlap: f32,
    via_dist: f32,
    bends: usize,
    len: f32,
    occupancy_score: ?u32,
};

fn expandObstacle(o: *const Obstacle, pad: f32) Obstacle {
    return .{ .id = o.id, .x = o.x - pad, .y = o.y - pad, .width = o.width + pad * 2.0, .height = o.height + pad * 2.0, .members = o.members };
}

fn preferredLabelMetrics(points: []const Point, ctx: *const RouteContext) PreferredLabelMetrics {
    const o = ctx.preferred_label_obstacle orelse return .{};
    const one: []const Obstacle = @as(*const [1]Obstacle, o);
    return .{
        .hard_hits = pathLabelIntersections(points, one, null),
        .near_hits = pathLabelNearIntersections(points, one, null, @max(ctx.preferred_label_clearance, 0.0)),
    };
}

fn ownLabelScore(m: PreferredLabelMetrics) usize {
    return m.hard_hits *| ROUTE_OWN_LABEL_HARD_WEIGHT +| m.near_hits *| ROUTE_OWN_LABEL_NEAR_WEIGHT;
}

fn candidateKey(c: *const RouteCandidate, occ: ?u32) OrderKey {
    return .{ .hits = c.hits, .own_label_score = ownLabelScore(c.own_label), .cross = c.cross, .label_hits = c.label_hits, .overlap = c.overlap, .via_dist = c.via_dist, .bends = c.bends, .len = c.len, .occupancy_score = occ };
}

fn candidateBetter(ctx: *const RouteContext, c: OrderKey, best_opt: ?OrderKey) bool {
    const best = best_opt orelse return true;
    if (c.hits != best.hits) return c.hits < best.hits;
    if (c.own_label_score != best.own_label_score) return c.own_label_score < best.own_label_score;
    if (c.cross != best.cross) {
        const fewer = if (c.cross < best.cross) c else best;
        const more = if (c.cross < best.cross) best else c;
        const avoided: f32 = @floatFromInt(more.cross -| fewer.cross);
        const extra_len = fewer.len - more.len;
        const allowance = @max(ctx.config.node_spacing, ROUTE_CROSSING_DETOUR_MIN_SPACING) * ROUTE_CROSSING_DETOUR_RATIO;
        if (extra_len > avoided * allowance and extra_len > more.len * ROUTE_CROSSING_DETOUR_RELATIVE) return c.len < best.len;
        return c.cross < best.cross;
    }
    if (c.label_hits != best.label_hits) return c.label_hits < best.label_hits;
    if (@abs(c.overlap - best.overlap) > 1e-4) return c.overlap < best.overlap;
    if (c.via_dist + ROUTE_VIA_TIE_EPS < best.via_dist) return true;
    if (@abs(c.via_dist - best.via_dist) > ROUTE_VIA_TIE_EPS) return false;
    if (ctx.prefer_shorter_ties) {
        if (c.len + ROUTE_LENGTH_TIE_EPS < best.len) return true;
        if (@abs(c.len - best.len) > ROUTE_LENGTH_TIE_EPS) return false;
        if (c.occupancy_score != null and best.occupancy_score != null and c.occupancy_score.? != best.occupancy_score.?) return c.occupancy_score.? < best.occupancy_score.?;
        return c.bends < best.bends;
    }
    if (c.bends != best.bends) return c.bends < best.bends;
    if (c.occupancy_score != null and best.occupancy_score != null and c.occupancy_score.? != best.occupancy_score.?) return c.occupancy_score.? < best.occupancy_score.?;
    return c.len < best.len;
}

pub const EdgeOccupancy = struct {
    cell: f32,
    weights: std.AutoArrayHashMapUnmanaged([2]i32, u16) = .empty,

    pub fn init(cell: f32) EdgeOccupancy {
        return .{ .cell = @max(cell, 8.0) };
    }

    pub fn cellIndex(self: *const EdgeOccupancy, x: f32, y: f32) [2]i32 {
        return .{ floorI32(x / self.cell), floorI32(y / self.cell) };
    }

    fn steps(self: *const EdgeOccupancy, len: f32) usize {
        return @max(ceilUsize(len / self.cell), 1);
    }

    pub fn scorePath(self: *const EdgeOccupancy, points: []const Point) u32 {
        var score: u32 = 0;
        if (points.len < 2) return 0;
        for (0..points.len - 1) |s| {
            const p1 = points[s];
            const p2 = points[s + 1];
            const dx = p2[0] - p1[0];
            const dy = p2[1] - p1[1];
            const len = @sqrt(dx * dx + dy * dy);
            const n = self.steps(len);
            const stride: usize = if (n > 32) @max(n / 32, 1) else 1;
            var i: usize = 0;
            while (i <= n) : (i += stride) {
                const tt = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
                if (self.weights.get(self.cellIndex(p1[0] + dx * tt, p1[1] + dy * tt))) |w| score +%= w;
            }
        }
        return score;
    }

    pub fn overlapCount(self: *const EdgeOccupancy, points: []const Point) u32 {
        var count: u32 = 0;
        if (points.len < 2) return 0;
        for (0..points.len - 1) |s| {
            const p1 = points[s];
            const p2 = points[s + 1];
            const dx = p2[0] - p1[0];
            const dy = p2[1] - p1[1];
            const n = self.steps(@sqrt(dx * dx + dy * dy));
            for (0..n + 1) |i| {
                const tt = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
                if (self.weights.get(self.cellIndex(p1[0] + dx * tt, p1[1] + dy * tt))) |w| {
                    if (w > 0) count +|= 1;
                }
            }
        }
        return count;
    }

    pub fn addPath(self: *EdgeOccupancy, a: Allocator, points: []const Point) Allocator.Error!void {
        return self.addPathWithWeight(a, points, 1);
    }

    pub fn addPathWithWeight(self: *EdgeOccupancy, a: Allocator, points: []const Point, mult_in: u16) Allocator.Error!void {
        const mult = @max(mult_in, 1);
        if (points.len < 2) return;
        for (0..points.len - 1) |s| {
            const p1 = points[s];
            const p2 = points[s + 1];
            const dx = p2[0] - p1[0];
            const dy = p2[1] - p1[1];
            const n = self.steps(@sqrt(dx * dx + dy * dy));
            for (0..n + 1) |i| {
                const tt = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n));
                const c = self.cellIndex(p1[0] + dx * tt, p1[1] + dy * tt);
                var cx: i32 = -1;
                while (cx <= 1) : (cx += 1) {
                    var cy: i32 = -1;
                    while (cy <= 1) : (cy += 1) {
                        const base: u16 = if (cx == 0 and cy == 0) 3 else if (cx == 0 or cy == 0) 2 else 1;
                        const w = base *| mult;
                        const gop = try self.weights.getOrPut(a, .{ c[0] + cx, c[1] + cy });
                        if (!gop.found_existing) gop.value_ptr.* = 0;
                        gop.value_ptr.* +|= w;
                    }
                }
            }
        }
    }

    pub fn mergeFrom(self: *EdgeOccupancy, a: Allocator, other: *const EdgeOccupancy) Allocator.Error!void {
        for (other.weights.keys(), other.weights.values()) |k, v| {
            const gop = try self.weights.getOrPut(a, k);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* +|= v;
        }
    }

    pub fn isEmpty(self: *const EdgeOccupancy) bool {
        return self.weights.count() == 0;
    }

    pub fn weightAt(self: *const EdgeOccupancy, x: f32, y: f32) u16 {
        return self.weights.get(self.cellIndex(x, y)) orelse 0;
    }

    pub fn clone(self: *const EdgeOccupancy, a: Allocator) Allocator.Error!EdgeOccupancy {
        return .{ .cell = self.cell, .weights = try self.weights.clone(a) };
    }
};

/// Rust `as i32` of a floored float (saturating, NaN → 0).
pub fn floorI32(v: f32) i32 {
    const f = @floor(v);
    if (std.math.isNan(f)) return 0;
    if (f >= 2147483647.0) return std.math.maxInt(i32);
    if (f <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(f);
}

/// Rust `x as i32` (truncation, saturating).
pub fn toI32(v: f32) i32 {
    if (std.math.isNan(v)) return 0;
    if (v >= 2147483647.0) return std.math.maxInt(i32);
    if (v <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(v);
}

/// Rust `x.ceil() as usize` (saturating, negatives → 0).
pub fn ceilUsize(v: f32) usize {
    return toUsize(@ceil(v));
}

pub fn toUsize(v: f32) usize {
    if (std.math.isNan(v) or v <= 0) return 0;
    if (v >= 1.8e19) return std.math.maxInt(usize);
    return @intFromFloat(v);
}

pub fn toU32(v: f32) u32 {
    if (std.math.isNan(v) or v <= 0) return 0;
    if (v >= 4294967295.0) return std.math.maxInt(u32);
    return @intFromFloat(v);
}

pub const RoutingGrid = struct {
    cell: f32,
    min_x: f32,
    min_y: f32,
    cols: i32,
    rows: i32,
    cell_obstacles: []std.ArrayList(usize),

    fn init(a: Allocator, obstacles: []const Obstacle, cell_in: f32, margin: f32, max_cells: usize) Allocator.Error!?RoutingGrid {
        var min_x: f32 = FMAX;
        var min_y: f32 = FMAX;
        var max_x: f32 = FMIN;
        var max_y: f32 = FMIN;
        for (obstacles) |o| {
            min_x = @min(min_x, o.x);
            min_y = @min(min_y, o.y);
            max_x = @max(max_x, o.x + o.width);
            max_y = @max(max_y, o.y + o.height);
        }
        if (min_x == FMAX) return null;
        min_x -= margin;
        min_y -= margin;
        max_x += margin;
        max_y += margin;
        const cell = @max(cell_in, 6.0);
        const cols = toI32(@ceil((max_x - min_x) / cell)) + 1;
        const rows = toI32(@ceil((max_y - min_y) / cell)) + 1;
        if (cols <= 1 or rows <= 1) return null;
        const total = @as(usize, @intCast(cols)) *| @as(usize, @intCast(rows));
        if (total > max_cells) return null;
        const co = try a.alloc(std.ArrayList(usize), total);
        for (co) |*c| c.* = .empty;
        for (obstacles, 0..) |o, idx| {
            const sx = toI32(@max(@floor((o.x - min_x) / cell), 0.0));
            const ex = toI32(@min(@floor((o.x + o.width - min_x) / cell), @as(f32, @floatFromInt(cols - 1))));
            const sy = toI32(@max(@floor((o.y - min_y) / cell), 0.0));
            const ey = toI32(@min(@floor((o.y + o.height - min_y) / cell), @as(f32, @floatFromInt(rows - 1))));
            var iy = sy;
            while (iy <= ey) : (iy += 1) {
                var ix = sx;
                while (ix <= ex) : (ix += 1) try co[@intCast(iy * cols + ix)].append(a, idx);
            }
        }
        return .{ .cell = cell, .min_x = min_x, .min_y = min_y, .cols = cols, .rows = rows, .cell_obstacles = co };
    }

    fn cellForPoint(self: *const RoutingGrid, x: f32, y: f32) ?[2]i32 {
        const ix = floorI32((x - self.min_x) / self.cell);
        const iy = floorI32((y - self.min_y) / self.cell);
        if (ix < 0 or iy < 0 or ix >= self.cols or iy >= self.rows) return null;
        return .{ ix, iy };
    }

    fn cellCenter(self: *const RoutingGrid, ix: i32, iy: i32) Point {
        return .{ self.min_x + (@as(f32, @floatFromInt(ix)) + 0.5) * self.cell, self.min_y + (@as(f32, @floatFromInt(iy)) + 0.5) * self.cell };
    }

    fn cellObstacleIndices(self: *const RoutingGrid, ix: i32, iy: i32) []const usize {
        return self.cell_obstacles[@intCast(iy * self.cols + ix)].items;
    }
};

const GridState = struct { x: i32, y: i32, dir: u8 };
const GridEntry = struct { est: u32, cost: u32, state: GridState };

fn gridEntryOrder(_: void, a: GridEntry, b: GridEntry) std.math.Order {
    // Rust's max-heap pops the smallest est, then smallest cost, then the
    // largest y, x and dir.
    if (a.est != b.est) return std.math.order(a.est, b.est);
    if (a.cost != b.cost) return std.math.order(a.cost, b.cost);
    if (a.state.y != b.state.y) return std.math.order(b.state.y, a.state.y);
    if (a.state.x != b.state.x) return std.math.order(b.state.x, a.state.x);
    return std.math.order(b.state.dir, a.state.dir);
}

pub fn applyPortOffset(p: Point, side: EdgeSide, offset: f32) Point {
    return switch (side) {
        .left, .right => .{ p[0], p[1] + offset },
        .top, .bottom => .{ p[0] + offset, p[1] },
    };
}

pub fn portStubLength(config: *const LayoutConfig, from: *const NodeLayout, to: *const NodeLayout) f32 {
    const base = config.node_spacing * PORT_STUB_RATIO;
    const size_cap = @min(@min(from.width, from.height), @min(to.width, to.height)) * PORT_STUB_SIZE_CAP_RATIO;
    const max_len = if (std.math.isFinite(size_cap) and size_cap > 0.0) size_cap else PORT_STUB_DEFAULT_MAX;
    return std.math.clamp(@min(base, max_len), PORT_STUB_MIN, PORT_STUB_MAX);
}

pub fn portStubPoint(p: Point, side: EdgeSide, len: f32) Point {
    return switch (side) {
        .left => .{ p[0] - len, p[1] },
        .right => .{ p[0] + len, p[1] },
        .top => .{ p[0], p[1] - len },
        .bottom => .{ p[0], p[1] + len },
    };
}

pub fn idealPortPos(remote: Point, node: *const NodeLayout, side: EdgeSide) f32 {
    const cx = node.x + node.width / 2.0;
    const cy = node.y + node.height / 2.0;
    if (sideIsVertical(side)) {
        const edge_x = if (side == .left) node.x else node.x + node.width;
        const dx = cx - remote[0];
        if (@abs(dx) < 1.0) return cy;
        const tt = (edge_x - remote[0]) / dx;
        return remote[1] + tt * (cy - remote[1]);
    }
    const edge_y = if (side == .top) node.y else node.y + node.height;
    const dy = cy - remote[1];
    if (@abs(dy) < 1.0) return cx;
    const tt = (edge_y - remote[1]) / dy;
    return remote[0] + tt * (cx - remote[0]);
}

pub fn anchorPointForNode(node: *const NodeLayout, side: EdgeSide, offset: f32) Point {
    const cx = node.x + node.width / 2.0;
    const cy = node.y + node.height / 2.0;
    const dir: Point, const perp: Point, const max_offset: f32 = switch (side) {
        .left => .{ .{ -1, 0 }, .{ 0, 1 }, node.height / 2.0 - 1.0 },
        .right => .{ .{ 1, 0 }, .{ 0, 1 }, node.height / 2.0 - 1.0 },
        .top => .{ .{ 0, -1 }, .{ 1, 0 }, node.width / 2.0 - 1.0 },
        .bottom => .{ .{ 0, 1 }, .{ 1, 0 }, node.width / 2.0 - 1.0 },
    };
    const clamp: f32 = if (max_offset > 0.0) std.math.clamp(offset, -max_offset, max_offset) else 0.0;
    const origin = Point{ cx + perp[0] * clamp, cy + perp[1] * clamp };
    if (node.shape == .circle or node.shape == .double_circle) {
        if (geometry.rayEllipseIntersection(origin, dir, .{ cx, cy }, node.width / 2.0, node.height / 2.0)) |p| return p;
    }
    if (geometry.shapePolygonPoints(node)) |poly| {
        if (geometry.rayPolygonIntersection(origin, dir, poly.slice())) |p| return p;
    }
    const base: Point = switch (side) {
        .left => .{ node.x, cy },
        .right => .{ node.x + node.width, cy },
        .top => .{ cx, node.y },
        .bottom => .{ cx, node.y + node.height },
    };
    return applyPortOffset(base, side, clamp);
}

pub fn routingCellSize(config: *const LayoutConfig) f32 {
    var cell = config.flowchart.routing.grid_cell;
    if (cell <= 0.0) cell = config.node_spacing * ROUTING_CELL_RATIO;
    return @max(cell, ROUTING_CELL_MIN);
}

pub fn buildRoutingGrid(a: Allocator, obstacles: []const Obstacle, config: *const LayoutConfig) Allocator.Error!?RoutingGrid {
    const margin = @max(config.node_spacing, GRID_MARGIN_MIN_SPACING) * 2.0;
    return RoutingGrid.init(a, obstacles, routingCellSize(config), margin, @max(config.flowchart.routing.max_steps / 16, 3000));
}

fn buildFallbackRoutingGrid(a: Allocator, obstacles: []const Obstacle, config: *const LayoutConfig, base_cell: f32) Allocator.Error!?RoutingGrid {
    const fallback = @max(@max(base_cell * ROUTING_CELL_FALLBACK_SCALE, base_cell + 2.0), ROUTING_CELL_MIN);
    if (fallback <= base_cell + 0.5) return null;
    const margin = @max(config.node_spacing, GRID_MARGIN_MIN_SPACING) * 2.0;
    return RoutingGrid.init(a, obstacles, fallback, margin, @max(config.flowchart.routing.max_steps / 14, 3000));
}

fn membersHit(o: *const Obstacle, from_id: []const u8, to_id: []const u8) bool {
    const m = o.members orelse return false;
    return m.contains(from_id) or m.contains(to_id);
}

fn cellBlocked(grid: *const RoutingGrid, obstacles: []const Obstacle, ix: i32, iy: i32, ctx: *const RouteContext) bool {
    const c = grid.cellCenter(ix, iy);
    for (grid.cellObstacleIndices(ix, iy)) |oi| {
        const o = &obstacles[oi];
        if (util.eql(o.id, ctx.from_id) or util.eql(o.id, ctx.to_id)) continue;
        if (membersHit(o, ctx.from_id, ctx.to_id)) continue;
        if (c[0] >= o.x and c[0] <= o.x + o.width and c[1] >= o.y and c[1] <= o.y + o.height) return true;
    }
    if (ctx.preferred_label_obstacle) |po| {
        const e = expandObstacle(po, @max(ctx.preferred_label_clearance, 0.0));
        if (c[0] >= e.x and c[0] <= e.x + e.width and c[1] >= e.y and c[1] <= e.y + e.height) return true;
    }
    return false;
}

pub fn insertLabelViaPoint(a: Allocator, points: *std.ArrayList(Point), via: Point) Allocator.Error!void {
    if (points.items.len < 2) return;
    if (polylinePointDistance(points.items, via) <= 0.6) return;
    var best_idx: ?usize = null;
    var best_delta = std.math.inf(f32);
    for (1..points.items.len) |i| {
        const pa = points.items[i - 1];
        const pb = points.items[i];
        const base = @sqrt((pb[0] - pa[0]) * (pb[0] - pa[0]) + (pb[1] - pa[1]) * (pb[1] - pa[1]));
        if (base <= 1e-4) continue;
        const la = @sqrt((via[0] - pa[0]) * (via[0] - pa[0]) + (via[1] - pa[1]) * (via[1] - pa[1]));
        const lb = @sqrt((via[0] - pb[0]) * (via[0] - pb[0]) + (via[1] - pb[1]) * (via[1] - pb[1]));
        const delta = @max(la + lb - base, 0.0);
        if (delta < best_delta) {
            best_delta = delta;
            best_idx = i;
        }
    }
    if (best_idx) |i| {
        const pa = points.items[i - 1];
        const pb = points.items[i];
        const da = @sqrt((via[0] - pa[0]) * (via[0] - pa[0]) + (via[1] - pa[1]) * (via[1] - pa[1]));
        const db = @sqrt((via[0] - pb[0]) * (via[0] - pb[0]) + (via[1] - pb[1]) * (via[1] - pb[1]));
        if (da > 2.0 and db > 2.0) try points.insert(a, i, via);
        return;
    }
    try points.insert(a, points.items.len / 2, via);
}

pub fn compressPath(a: Allocator, points: []const Point) Allocator.Error![]Point {
    if (points.len <= 2) return a.dupe(Point, points);
    var out: std.ArrayList(Point) = .empty;
    try out.append(a, points[0]);
    for (1..points.len - 1) |idx| {
        const prev = out.items[out.items.len - 1];
        const curr = points[idx];
        if (@abs(curr[0] - prev[0]) <= 1e-4 and @abs(curr[1] - prev[1]) <= 1e-4) continue;
        if (idx == 1 or idx == points.len - 2) {
            try out.append(a, curr);
            continue;
        }
        const next = points[idx + 1];
        const dx1 = curr[0] - prev[0];
        const dy1 = curr[1] - prev[1];
        const dx2 = next[0] - curr[0];
        const dy2 = next[1] - curr[1];
        if ((@abs(dx1) <= 1e-4 and @abs(dx2) <= 1e-4) or (@abs(dy1) <= 1e-4 and @abs(dy2) <= 1e-4)) {
            if (dx1 * dx2 + dy1 * dy2 >= 0.0) continue;
        }
        try out.append(a, curr);
    }
    const last = points[points.len - 1];
    const tail = out.items[out.items.len - 1];
    if (@abs(last[0] - tail[0]) > 1e-4 or @abs(last[1] - tail[1]) > 1e-4) try out.append(a, last);
    return out.items;
}

pub fn routeEdgeWithGrid(a: Allocator, ctx: *const RouteContext, grid: *const RoutingGrid, occupancy: ?*const EdgeOccupancy, start: Point, end: Point) Allocator.Error!?[]Point {
    if (!ctx.config.flowchart.routing.enable_grid_router) return null;
    const s = grid.cellForPoint(start[0], start[1]) orelse return null;
    const e = grid.cellForPoint(end[0], end[1]) orelse return null;
    if (s[0] == e[0] and s[1] == e[1]) return try a.dupe(Point, &.{ start, end });
    const dirs = [4][2]i32{ .{ 0, -1 }, .{ 0, 1 }, .{ -1, 0 }, .{ 1, 0 } };
    const step_cost = toU32(@round(grid.cell * ASTAR_COST_SCALE));
    const manhattan_cells: i32 = @intCast(@abs(e[0] - s[0]) + @abs(e[1] - s[1]));
    const mcf: f32 = @floatFromInt(manhattan_cells);
    const turn_scale: f32 = if (manhattan_cells <= 8) 0.85 else if (manhattan_cells >= 42) 1.35 else 0.85 + (mcf - 8.0) * (0.50 / 34.0);
    const occ_scale: f32 = if (manhattan_cells <= 10) 0.90 else if (manhattan_cells >= 36) 0.60 else 0.90 - (mcf - 10.0) * (0.30 / 26.0);
    const turn_penalty = toU32(@round(ctx.config.flowchart.routing.turn_penalty * turn_scale * grid.cell * ASTAR_COST_SCALE));
    const occ_weight = @max(toU32(@round(ctx.config.flowchart.routing.occupancy_weight * occ_scale * grid.cell * ASTAR_COST_SCALE)), 1);
    const max_steps = @max(ctx.config.flowchart.routing.max_steps, 10_000);
    const cols = grid.cols;
    const rows = grid.rows;
    const nstates: usize = @intCast(cols * rows * 4);
    const best_cost = try a.alloc(u32, nstates);
    @memset(best_cost, std.math.maxInt(u32));
    const prev = try a.alloc(?GridState, nstates);
    @memset(prev, null);
    var heap = std.PriorityQueue(GridEntry, void, gridEntryOrder).empty;
    for (0..4) |d| {
        const idx: usize = @as(usize, @intCast(s[1] * cols + s[0])) * 4 + d;
        best_cost[idx] = 0;
        try heap.push(a, .{ .est = 0, .cost = 0, .state = .{ .x = s[0], .y = s[1], .dir = @intCast(d) } });
    }
    var end_state: ?GridState = null;
    var steps: usize = 0;
    while (heap.pop()) |entry| {
        steps += 1;
        if (steps > max_steps) break;
        const st = entry.state;
        const sidx: usize = @as(usize, @intCast(st.y * cols + st.x)) * 4 + st.dir;
        if (entry.cost != best_cost[sidx]) continue;
        if (st.x == e[0] and st.y == e[1]) {
            end_state = st;
            break;
        }
        for (dirs, 0..) |d, di| {
            const nx = st.x + d[0];
            const ny = st.y + d[1];
            if (nx < 0 or ny < 0 or nx >= cols or ny >= rows) continue;
            if ((nx != e[0] or ny != e[1]) and (nx != s[0] or ny != s[1]) and cellBlocked(grid, ctx.obstacles, nx, ny, ctx)) continue;
            var next_cost = entry.cost +| step_cost;
            if (st.dir != di) next_cost +|= turn_penalty;
            if (occupancy) |occ| {
                const c = grid.cellCenter(nx, ny);
                const raw: f32 = @floatFromInt(occ.weightAt(c[0], c[1]));
                if (raw > 0.0) {
                    const compressed = toU32(@round(@max(@sqrt(raw), 1.0)));
                    next_cost +|= compressed *| occ_weight;
                }
            }
            const nidx: usize = @as(usize, @intCast(ny * cols + nx)) * 4 + di;
            if (next_cost >= best_cost[nidx]) continue;
            best_cost[nidx] = next_cost;
            prev[nidx] = st;
            const manhattan: u32 = @intCast(@abs(nx - e[0]) + @abs(ny - e[1]));
            try heap.push(a, .{ .est = next_cost +| (manhattan *| step_cost), .cost = next_cost, .state = .{ .x = nx, .y = ny, .dir = @intCast(di) } });
        }
    }
    const es = end_state orelse return null;
    var cells: std.ArrayList([2]i32) = .empty;
    var cur = es;
    while (true) {
        try cells.append(a, .{ cur.x, cur.y });
        const ci: usize = @as(usize, @intCast(cur.y * cols + cur.x)) * 4 + cur.dir;
        cur = prev[ci] orelse break;
    }
    std.mem.reverse([2]i32, cells.items);
    if (cells.items.len == 0) return null;
    var pts: std.ArrayList(Point) = .empty;
    try pts.append(a, start);
    {
        const f = cells.items[0];
        const c = grid.cellCenter(f[0], f[1]);
        switch (ctx.start_side) {
            .left, .right => try pts.append(a, .{ c[0], start[1] }),
            .top, .bottom => try pts.append(a, .{ start[0], c[1] }),
        }
        try pts.append(a, c);
    }
    for (cells.items[1..]) |cl| try pts.append(a, grid.cellCenter(cl[0], cl[1]));
    {
        const l = cells.items[cells.items.len - 1];
        const c = grid.cellCenter(l[0], l[1]);
        switch (ctx.end_side) {
            .left, .right => try pts.append(a, .{ c[0], end[1] }),
            .top, .bottom => try pts.append(a, .{ end[0], c[1] }),
        }
    }
    try pts.append(a, end);
    return try compressPath(a, pts.items);
}

const Candidates = std.ArrayList(RouteCandidate);

fn pushCandidate(a: Allocator, points: []const Point, ctx: *const RouteContext, existing: []const Segment, use_existing: bool, cands: *Candidates) Allocator.Error!void {
    if (points.len < 2 or !pathCoordsReasonable(points)) return;
    const hard_hits = pathObstacleIntersections(points, ctx.obstacles, ctx.from_id, ctx.to_id);
    const endpoint_hits = pathEndpointIntrusions(points, ctx);
    const soft = pathObstacleNearIntersections(points, ctx.obstacles, ctx.from_id, ctx.to_id, ROUTE_SOFT_NODE_CLEARANCE);
    const hits = hard_hits *| 4 +| endpoint_hits *| 16 +| soft;
    const own = preferredLabelMetrics(points, ctx);
    const hard_labels = pathLabelIntersections(points, ctx.label_obstacles, ctx.preferred_label_id);
    const soft_labels = pathLabelNearIntersections(points, ctx.label_obstacles, ctx.preferred_label_id, ROUTE_SOFT_LABEL_CLEARANCE);
    const via_dist: f32 = if (ctx.preferred_label_center) |c| polylinePointDistance(points, c) else 0.0;
    var cross: usize = 0;
    var overlap: f32 = 0;
    if (use_existing) {
        const r = edgeCrossingsWithExisting(points, existing);
        cross = r[0];
        overlap = r[1] + pathExistingProximityPenalty(points, existing, ROUTE_SOFT_EDGE_CLEARANCE);
    }
    try cands.append(a, .{
        .points = try a.dupe(Point, points),
        .hard_hits = hard_hits +| endpoint_hits,
        .hits = hits,
        .own_label = own,
        .cross = cross,
        .label_hits = hard_labels *| 4 +| soft_labels,
        .overlap = overlap,
        .via_dist = via_dist,
        .bends = pathBendCount(points),
        .len = pathLength(points),
    });
}

pub fn pathCoordsReasonable(points: []const Point) bool {
    for (points) |p| {
        if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1]) or @abs(p[0]) > 100_000.0 or @abs(p[1]) > 100_000.0) return false;
    }
    return true;
}

fn pathEndpointIntrusions(points: []const Point, ctx: *const RouteContext) usize {
    if (points.len < 2 or util.eql(ctx.from_id, ctx.to_id)) return 0;
    var hits: usize = 0;
    for (0..points.len - 1) |i| {
        if (geometry.segmentHitsNodeShapeInterior(points[i], points[i + 1], ctx.from)) hits += 1;
        if (geometry.segmentHitsNodeShapeInterior(points[i], points[i + 1], ctx.to)) hits += 1;
    }
    return hits;
}

fn resolveRouteEndpoints(ctx: *const RouteContext) RouteEndpoints {
    const start = anchorPointForNode(ctx.from, ctx.start_side, ctx.start_offset);
    const end = anchorPointForNode(ctx.to, ctx.end_side, ctx.end_offset);
    var route_start = portStubPoint(start, ctx.start_side, ctx.stub_len);
    var route_end = portStubPoint(end, ctx.end_side, ctx.stub_len);
    if (ctx.obstacles.len <= 10) {
        const hits = struct {
            fn f(c: *const RouteContext, pa: Point, pb: Point) bool {
                for (c.obstacles) |*o| {
                    if (o.members != null) continue;
                    if (util.eql(o.id, c.from_id) or util.eql(o.id, c.to_id)) continue;
                    if (segmentIntersectsRect(pa, pb, o)) return true;
                }
                return false;
            }
        }.f;
        if (hits(ctx, start, route_start)) route_start = start;
        if (hits(ctx, route_end, end)) route_end = end;
    }
    return .{ .start = start, .end = end, .route_start = route_start, .route_end = route_end };
}

pub fn pointSegmentDistance(a: Point, b: Point, p: Point) f32 {
    const vx = b[0] - a[0];
    const vy = b[1] - a[1];
    const wx = p[0] - a[0];
    const wy = p[1] - a[1];
    const vv = vx * vx + vy * vy;
    if (vv <= 1e-6) {
        const dx = p[0] - a[0];
        const dy = p[1] - a[1];
        return @sqrt(dx * dx + dy * dy);
    }
    const tt = std.math.clamp((wx * vx + wy * vy) / vv, 0.0, 1.0);
    const dx = p[0] - (a[0] + tt * vx);
    const dy = p[1] - (a[1] + tt * vy);
    return @sqrt(dx * dx + dy * dy);
}

pub fn polylinePointDistance(points: []const Point, p: Point) f32 {
    if (points.len == 0) return std.math.inf(f32);
    if (points.len == 1) {
        const dx = points[0][0] - p[0];
        const dy = points[0][1] - p[1];
        return @sqrt(dx * dx + dy * dy);
    }
    var best = std.math.inf(f32);
    for (0..points.len - 1) |i| best = @min(best, pointSegmentDistance(points[i], points[i + 1], p));
    return best;
}

fn enforcePreferredLabelVia(a: Allocator, points: *std.ArrayList(Point), ctx: *const RouteContext) Allocator.Error!void {
    if (!ctx.force_preferred_label_via) return;
    const via = ctx.preferred_label_center orelse return;
    if (points.items.len < 2) return;
    if (polylinePointDistance(points.items, via) <= 0.6) return;
    try insertLabelViaPoint(a, points, via);
}

fn pushPreferredLabelDetourCandidates(a: Allocator, ctx: *const RouteContext, rs: Point, re: Point, existing: []const Segment, use_existing: bool, cands: *Candidates) Allocator.Error!void {
    const o = ctx.preferred_label_obstacle orelse return;
    const e = expandObstacle(o, @max(ctx.preferred_label_clearance, 0.0));
    const left = e.x;
    const right = e.x + e.width;
    const top = e.y;
    const bottom = e.y + e.height;
    if (isHorizontal(ctx.direction)) {
        const forward = re[0] >= rs[0];
        const near_x = if (forward) left else right;
        const far_x = if (forward) right else left;
        for ([_]f32{ top, bottom }) |y| try pushCandidate(a, &.{ rs, .{ near_x, rs[1] }, .{ near_x, y }, .{ far_x, y }, .{ far_x, re[1] }, re }, ctx, existing, use_existing, cands);
    } else {
        const forward = re[1] >= rs[1];
        const near_y = if (forward) top else bottom;
        const far_y = if (forward) bottom else top;
        for ([_]f32{ left, right }) |x| try pushCandidate(a, &.{ rs, .{ rs[0], near_y }, .{ x, near_y }, .{ x, far_y }, .{ re[0], far_y }, re }, ctx, existing, use_existing, cands);
    }
}

fn channelCandidateScore(ch: *const ReservedRoutingChannel, rs: Point, re: Point, config: *const LayoutConfig) ?f32 {
    const pad = @max(config.node_spacing * 1.2, 24.0);
    const span_min, const span_max, const mid = switch (ch.axis) {
        .vertical => .{ @min(rs[1], re[1]), @max(rs[1], re[1]), (rs[0] + re[0]) * 0.5 },
        .horizontal => .{ @min(rs[0], re[0]), @max(rs[0], re[0]), (rs[1] + re[1]) * 0.5 },
    };
    const miss: f32 = if (span_max < ch.span_min - pad) ch.span_min - pad - span_max else if (span_min > ch.span_max + pad) span_min - ch.span_max - pad else 0.0;
    if (miss > pad * 2.0) return null;
    return @abs(ch.coord - mid) + miss * 1.5;
}

fn pushReservedChannelCandidates(a: Allocator, ctx: *const RouteContext, rs: Point, re: Point, existing: []const Segment, use_existing: bool, cands: *Candidates) Allocator.Error!void {
    if (ctx.reserved_channels.len == 0) return;
    const direct = @abs(re[0] - rs[0]) + @abs(re[1] - rs[1]);
    const max_detour = direct * 2.4 + ctx.config.node_spacing * 5.0;
    const SC = struct { s: f32, ch: ReservedRoutingChannel };
    var chans: std.ArrayList(SC) = .empty;
    for (ctx.reserved_channels) |*ch| if (channelCandidateScore(ch, rs, re, ctx.config)) |s| try chans.append(a, .{ .s = s, .ch = ch.* });
    std.mem.sort(SC, chans.items, {}, struct {
        fn lt(_: void, x: SC, y: SC) bool {
            return x.s < y.s;
        }
    }.lt);
    for (chans.items[0..@min(8, chans.items.len)]) |sc| {
        const pts: [4]Point = switch (sc.ch.axis) {
            .vertical => .{ rs, .{ sc.ch.coord, rs[1] }, .{ sc.ch.coord, re[1] }, re },
            .horizontal => .{ rs, .{ rs[0], sc.ch.coord }, .{ re[0], sc.ch.coord }, re },
        };
        if (pathLength(&pts) > max_detour) continue;
        try pushCandidate(a, &pts, ctx, existing, use_existing, cands);
    }
}

fn pushExteriorFallbackCandidates(a: Allocator, ctx: *const RouteContext, rs: Point, re: Point, existing: []const Segment, use_existing: bool, cands: *Candidates) Allocator.Error!void {
    var min_x = @min(rs[0], re[0]);
    var max_x = @max(rs[0], re[0]);
    var min_y = @min(rs[1], re[1]);
    var max_y = @max(rs[1], re[1]);
    var any = false;
    for ([_][]const Obstacle{ ctx.obstacles, ctx.label_obstacles }) |list| for (list) |o| {
        if (!std.math.isFinite(o.x) or !std.math.isFinite(o.y) or !std.math.isFinite(o.width) or !std.math.isFinite(o.height) or o.width <= 0.0 or o.height <= 0.0) continue;
        min_x = @min(min_x, o.x);
        max_x = @max(max_x, o.x + o.width);
        min_y = @min(min_y, o.y);
        max_y = @max(max_y, o.y + o.height);
        any = true;
    };
    if (!any) return;
    const pad = @max(ctx.config.node_spacing * EXTERIOR_FALLBACK_PAD_RATIO, EXTERIOR_FALLBACK_PAD_MIN);
    const left = min_x - pad;
    const right = max_x + pad;
    const top = min_y - pad;
    const bottom = max_y + pad;
    for ([_]f32{ left, right }) |x| try pushCandidate(a, &.{ rs, .{ x, rs[1] }, .{ x, re[1] }, re }, ctx, existing, use_existing, cands);
    for ([_]f32{ top, bottom }) |y| try pushCandidate(a, &.{ rs, .{ rs[0], y }, .{ re[0], y }, re }, ctx, existing, use_existing, cands);
    for ([_]f32{ left, right }) |x| for ([_]f32{ top, bottom }) |y| {
        try pushCandidate(a, &.{ rs, .{ x, rs[1] }, .{ x, y }, .{ re[0], y }, re }, ctx, existing, use_existing, cands);
        try pushCandidate(a, &.{ rs, .{ rs[0], y }, .{ x, y }, .{ x, re[1] }, re }, ctx, existing, use_existing, cands);
    };
}

fn pickBest(ctx: *const RouteContext, cands: []const RouteCandidate, occupancy: ?*const EdgeOccupancy) ?usize {
    var best_idx: ?usize = null;
    var best_key: ?OrderKey = null;
    for (cands, 0..) |*c, idx| {
        const key = candidateKey(c, if (occupancy) |o| o.scorePath(c.points) else null);
        if (candidateBetter(ctx, key, best_key)) {
            best_key = key;
            best_idx = idx;
        }
    }
    return best_idx;
}

pub fn routeEdgeWithAvoidance(a: Allocator, ctx: *const RouteContext, occupancy: ?*const EdgeOccupancy, grid: ?*const RoutingGrid, existing_opt: ?[]const Segment) Allocator.Error![]Point {
    const existing: []const Segment = existing_opt orelse &.{};
    const use_existing = existing.len > 0;
    var cands: Candidates = .empty;
    if (util.eql(ctx.from_id, ctx.to_id)) {
        const pad = @max(ctx.config.node_spacing, ROUTING_PAD_MIN_SPACING) * ROUTING_PAD_RATIO;
        for (routeSelfLoopCandidates(ctx.from, pad)) |pts| try pushCandidate(a, &pts, ctx, existing, use_existing, &cands);
        const loop = routeSelfLoop(ctx.from, ctx.direction, ctx.config);
        try pushCandidate(a, &loop, ctx, existing, use_existing, &cands);
        if (cands.items.len == 0) return a.dupe(Point, &loop);
        const bi = pickBest(ctx, cands.items, occupancy) orelse unreachable;
        var best: std.ArrayList(Point) = .fromOwnedSlice(try compressPath(a, cands.items[bi].points));
        try enforcePreferredLabelVia(a, &best, ctx);
        return applyEndpointInsets(try compressPath(a, best.items), ctx.start_inset, ctx.end_inset);
    }
    const is_backward = edgeSides(ctx.from, ctx.to, ctx.direction)[2];
    const ep = resolveRouteEndpoints(ctx);
    const start = ep.start;
    const end = ep.end;
    const rs = ep.route_start;
    const re = ep.route_end;
    if (ctx.fast_route) {
        var fast: std.ArrayList(Point) = .fromOwnedSlice(try ep.directPath(a));
        try enforcePreferredLabelVia(a, &fast, ctx);
        return applyEndpointInsets(try compressPath(a, fast.items), ctx.start_inset, ctx.end_inset);
    }
    if (is_backward) {
        const pad = @max(ctx.config.node_spacing, 30.0);
        var min_left: f32 = FMAX;
        var max_right: f32 = 0.0;
        var min_top: f32 = FMAX;
        var max_bottom: f32 = 0.0;
        for (ctx.obstacles) |*o| {
            if (util.eql(o.id, ctx.from_id) or util.eql(o.id, ctx.to_id)) continue;
            if (membersHit(o, ctx.from_id, ctx.to_id)) continue;
            const ot = o.y;
            const ob = o.y + o.height;
            if (ot < @max(start[1], end[1]) and ob > @min(end[1], start[1])) {
                min_left = @min(min_left, o.x);
                max_right = @max(max_right, o.x + o.width);
            }
            const ol = o.x;
            const orr = o.x + o.width;
            if (ol < @max(start[0], end[0]) and orr > @min(start[0], end[0])) {
                min_top = @min(min_top, ot);
                max_bottom = @max(max_bottom, ob);
            }
        }
        if (max_right > 0.0) {
            const x = max_right + pad;
            try pushCandidate(a, &.{ rs, .{ x, rs[1] }, .{ x, re[1] }, re }, ctx, existing, use_existing, &cands);
        }
        if (max_bottom > 0.0) {
            const y = max_bottom + pad;
            try pushCandidate(a, &.{ rs, .{ rs[0], y }, .{ re[0], y }, re }, ctx, existing, use_existing, &cands);
        }
        if (min_top < FMAX) {
            const y = min_top - pad;
            try pushCandidate(a, &.{ rs, .{ rs[0], y }, .{ re[0], y }, re }, ctx, existing, use_existing, &cands);
        }
        if (min_left < FMAX) {
            const x = min_left - pad;
            try pushCandidate(a, &.{ rs, .{ x, rs[1] }, .{ x, re[1] }, re }, ctx, existing, use_existing, &cands);
        }
    }
    const direct_axis_aligned = @abs(rs[0] - re[0]) <= 1e-3 or @abs(rs[1] - re[1]) <= 1e-3;
    if (direct_axis_aligned or !(is_backward and ctx.start_side == ctx.end_side)) try pushCandidate(a, &.{ rs, re }, ctx, existing, use_existing, &cands);
    try pushPreferredLabelDetourCandidates(a, ctx, rs, re, existing, use_existing, &cands);
    try pushReservedChannelCandidates(a, ctx, rs, re, existing, use_existing, &cands);
    if (ctx.preferred_label_center) |via| {
        try pushCandidate(a, &.{ rs, .{ via[0], rs[1] }, via, .{ via[0], re[1] }, re }, ctx, existing, use_existing, &cands);
        try pushCandidate(a, &.{ rs, .{ rs[0], via[1] }, via, .{ re[0], via[1] }, re }, ctx, existing, use_existing, &cands);
    }
    const step = @max(ctx.config.node_spacing, ORTHO_STEP_MIN_SPACING) * ROUTING_PAD_RATIO;
    var offsets: [13]f32 = undefined;
    offsets[0] = ctx.base_offset;
    for (1..7) |i| {
        const delta = step * @as(f32, @floatFromInt(i));
        offsets[2 * i - 1] = ctx.base_offset + delta;
        offsets[2 * i] = ctx.base_offset - delta;
    }
    const horizontal = isHorizontal(ctx.direction);
    const cross_delta = if (horizontal) @abs(re[1] - rs[1]) else @abs(re[0] - rs[0]);
    const use_channels = (cross_delta > step * CHANNEL_CANDIDATE_RATIO and ctx.obstacles.len > 10) or is_backward or (ctx.start_side == ctx.end_side and ctx.obstacles.len > 4);
    for (offsets, 0..) |offset, rank| {
        if (horizontal) {
            const mid_x = (rs[0] + re[0]) / 2.0 + offset;
            try pushCandidate(a, &.{ rs, .{ mid_x, rs[1] }, .{ mid_x, re[1] }, re }, ctx, existing, use_existing, &cands);
            const mid_y = (rs[1] + re[1]) / 2.0 + offset;
            try pushCandidate(a, &.{ rs, .{ rs[0], mid_y }, .{ re[0], mid_y }, re }, ctx, existing, use_existing, &cands);
            if (use_channels and rank <= 3) {
                const nsx = rs[0] + offset;
                try pushCandidate(a, &.{ rs, .{ nsx, rs[1] }, .{ nsx, re[1] }, re }, ctx, existing, use_existing, &cands);
                const nex = re[0] + offset;
                try pushCandidate(a, &.{ rs, .{ nex, rs[1] }, .{ nex, re[1] }, re }, ctx, existing, use_existing, &cands);
            }
        } else {
            const mid_y = (rs[1] + re[1]) / 2.0 + offset;
            try pushCandidate(a, &.{ rs, .{ rs[0], mid_y }, .{ re[0], mid_y }, re }, ctx, existing, use_existing, &cands);
            const mid_x = (rs[0] + re[0]) / 2.0 + offset;
            try pushCandidate(a, &.{ rs, .{ mid_x, rs[1] }, .{ mid_x, re[1] }, re }, ctx, existing, use_existing, &cands);
            if (use_channels and rank <= 3) {
                const nsy = rs[1] + offset;
                try pushCandidate(a, &.{ rs, .{ rs[0], nsy }, .{ re[0], nsy }, re }, ctx, existing, use_existing, &cands);
                const ney = re[1] + offset;
                try pushCandidate(a, &.{ rs, .{ rs[0], ney }, .{ re[0], ney }, re }, ctx, existing, use_existing, &cands);
            }
        }
    }
    var min_hits: usize = std.math.maxInt(usize);
    var min_own: usize = std.math.maxInt(usize);
    var min_cross: usize = std.math.maxInt(usize);
    var min_label: usize = std.math.maxInt(usize);
    var min_overlap = std.math.inf(f32);
    for (cands.items) |c| {
        min_hits = @min(min_hits, c.hits);
        min_own = @min(min_own, ownLabelScore(c.own_label));
        min_cross = @min(min_cross, c.cross);
        min_label = @min(min_label, c.label_hits);
        min_overlap = @min(min_overlap, c.overlap);
    }
    if (cands.items.len == 0) {
        min_hits = 0;
        min_own = 0;
        min_cross = 0;
        min_label = 0;
    }
    var needs_detour = min_cross > 0 or min_own > 0 or min_label > 0 or (std.math.isFinite(min_overlap) and min_overlap >= OVERLAP_DETOUR_MIN);
    if (min_hits == 0) if (occupancy) |occ| {
        var bi: usize = 0;
        var bs: u32 = std.math.maxInt(u32);
        var bb: usize = std.math.maxInt(usize);
        var bl: f32 = FMAX;
        for (cands.items, 0..) |c, idx| {
            const score = occ.scorePath(c.points);
            const better = if (ctx.prefer_shorter_ties)
                score < bs or (score == bs and c.len + ROUTE_LENGTH_TIE_EPS < bl) or (score == bs and @abs(c.len - bl) <= ROUTE_LENGTH_TIE_EPS and c.bends < bb)
            else
                score < bs or (score == bs and c.bends < bb) or (score == bs and c.bends == bb and c.len < bl);
            if (better) {
                bs = score;
                bb = c.bends;
                bl = c.len;
                bi = idx;
            }
        }
        if (bi < cands.items.len) {
            const c = cands.items[bi];
            const ov = occ.overlapCount(c.points);
            const trigger = toU32(@ceil(@max((c.len / occ.cell) * OVERLAP_TRIGGER_RATIO, OVERLAP_TRIGGER_MIN)));
            if (ov >= trigger) needs_detour = true;
        }
    };
    if (min_hits > 0 or needs_detour) {
        for (7..10) |i| {
            const delta = step * @as(f32, @floatFromInt(i));
            for ([_]f32{ 1.0, -1.0 }) |sign| {
                const offset = ctx.base_offset + sign * delta;
                if (horizontal) {
                    const mid_x = (rs[0] + re[0]) / 2.0 + offset;
                    try pushCandidate(a, &.{ rs, .{ mid_x, rs[1] }, .{ mid_x, re[1] }, re }, ctx, existing, use_existing, &cands);
                } else {
                    const mid_y = (rs[1] + re[1]) / 2.0 + offset;
                    try pushCandidate(a, &.{ rs, .{ rs[0], mid_y }, .{ re[0], mid_y }, re }, ctx, existing, use_existing, &cands);
                }
            }
        }
    }
    min_hits = std.math.maxInt(usize);
    for (cands.items) |c| min_hits = @min(min_hits, c.hits);
    if (cands.items.len == 0) min_hits = 0;
    if (min_hits > 0 or needs_detour) if (grid) |g| {
        var coarse_retry = false;
        if (try routeEdgeWithGrid(a, ctx, g, occupancy, rs, re)) |pts| {
            const before = cands.items.len;
            try pushCandidate(a, pts, ctx, existing, use_existing, &cands);
            if (cands.items.len > before) {
                const c = cands.items[cands.items.len - 1];
                coarse_retry = c.hits > 0 or ownLabelScore(c.own_label) > 0 or c.label_hits > 0 or c.cross > 0 or c.overlap >= OVERLAP_DETOUR_MIN;
            }
        } else coarse_retry = true;
        if (coarse_retry and ctx.coarse_grid_retry) {
            if (try buildFallbackRoutingGrid(a, ctx.obstacles, ctx.config, g.cell)) |coarse| {
                if (try routeEdgeWithGrid(a, ctx, &coarse, occupancy, rs, re)) |pts| try pushCandidate(a, pts, ctx, existing, use_existing, &cands);
            }
        }
    };
    var min_hard: usize = std.math.maxInt(usize);
    for (cands.items) |c| min_hard = @min(min_hard, c.hard_hits);
    if (ctx.allow_exterior_fallback and occupancy == null and (cands.items.len == 0 or min_hard > 0)) try pushExteriorFallbackCandidates(a, ctx, rs, re, existing, use_existing, &cands);
    const bi = pickBest(ctx, cands.items, occupancy) orelse return ep.finish(a, ctx, &.{ rs, re });
    return ep.finish(a, ctx, cands.items[bi].points);
}

pub fn pathObstacleIntersections(points: []const Point, obstacles: []const Obstacle, from_id: []const u8, to_id: []const u8) usize {
    if (points.len < 2) return 0;
    var count: usize = 0;
    for (0..points.len - 1) |i| for (obstacles) |*o| {
        if (util.eql(o.id, from_id) or util.eql(o.id, to_id)) continue;
        if (membersHit(o, from_id, to_id)) continue;
        if (segmentIntersectsRect(points[i], points[i + 1], o)) count += 1;
    };
    return count;
}

pub fn pathLabelIntersections(points: []const Point, labels: []const Obstacle, ignore: ?[]const u8) usize {
    if (points.len < 2 or labels.len == 0) return 0;
    var count: usize = 0;
    for (0..points.len - 1) |i| for (labels) |*o| {
        if (ignore) |id| if (util.eql(id, o.id)) continue;
        if (segmentIntersectsRect(points[i], points[i + 1], o)) count += 1;
    };
    return count;
}

fn pathObstacleNearIntersections(points: []const Point, obstacles: []const Obstacle, from_id: []const u8, to_id: []const u8, pad: f32) usize {
    if (points.len < 2 or obstacles.len == 0 or pad <= 0.0) return 0;
    var count: usize = 0;
    for (0..points.len - 1) |i| for (obstacles) |*o| {
        if (util.eql(o.id, from_id) or util.eql(o.id, to_id)) continue;
        if (membersHit(o, from_id, to_id)) continue;
        if (segmentIntersectsRect(points[i], points[i + 1], o)) continue;
        const e = expandObstacle(o, pad);
        if (segmentIntersectsRect(points[i], points[i + 1], &e)) count += 1;
    };
    return count;
}

fn pathLabelNearIntersections(points: []const Point, labels: []const Obstacle, ignore: ?[]const u8, pad: f32) usize {
    if (points.len < 2 or labels.len == 0 or pad <= 0.0) return 0;
    var count: usize = 0;
    for (0..points.len - 1) |i| for (labels) |*o| {
        if (ignore) |id| if (util.eql(id, o.id)) continue;
        if (segmentIntersectsRect(points[i], points[i + 1], o)) continue;
        const e = expandObstacle(o, pad);
        if (segmentIntersectsRect(points[i], points[i + 1], &e)) count += 1;
    };
    return count;
}

fn segmentToSegmentDistance(a1: Point, a2: Point, b1: Point, b2: Point) f32 {
    if (segmentsIntersect(a1, a2, b1, b2)) return 0.0;
    return @min(@min(pointSegmentDistance(a1, a2, b1), pointSegmentDistance(a1, a2, b2)), @min(pointSegmentDistance(b1, b2, a1), pointSegmentDistance(b1, b2, a2)));
}

fn pathExistingProximityPenalty(points: []const Point, existing: []const Segment, clearance: f32) f32 {
    if (points.len < 2 or existing.len == 0 or clearance <= 0.0) return 0.0;
    var penalty: f32 = 0;
    for (0..points.len - 1) |i| for (existing) |s| {
        const d = segmentToSegmentDistance(points[i], points[i + 1], s[0], s[1]);
        if (d < clearance) penalty += (clearance - d) / clearance;
    };
    return penalty;
}

pub fn edgeLabelAnchorFromPoints(points: []const Point) ?Point {
    return geometry.pathPointAtProgress(points, 0.5);
}

pub fn routeSelfLoop(node: *const NodeLayout, direction: Direction, config: *const LayoutConfig) [5]Point {
    const pad = @max(config.node_spacing, ROUTING_PAD_MIN_SPACING) * ROUTING_PAD_RATIO;
    if (isHorizontal(direction)) return .{
        .{ node.x + node.width, node.y + node.height / 2.0 },
        .{ node.x + node.width + pad, node.y + node.height / 2.0 },
        .{ node.x + node.width + pad, node.y - pad },
        .{ node.x + node.width / 2.0, node.y - pad },
        .{ node.x + node.width / 2.0, node.y },
    };
    return .{
        .{ node.x + node.width / 2.0, node.y + node.height },
        .{ node.x + node.width / 2.0, node.y + node.height + pad },
        .{ node.x + node.width + pad, node.y + node.height + pad },
        .{ node.x + node.width + pad, node.y + node.height / 2.0 },
        .{ node.x + node.width, node.y + node.height / 2.0 },
    };
}

pub fn routeSelfLoopCandidates(node: *const NodeLayout, pad: f32) [8][5]Point {
    const x = node.x;
    const y = node.y;
    const w = node.width;
    const h = node.height;
    const cx = x + w / 2.0;
    const cy = y + h / 2.0;
    const left = Point{ x, cy };
    const right = Point{ x + w, cy };
    const top = Point{ cx, y };
    const bottom = Point{ cx, y + h };
    const lx = x - pad;
    const rx = x + w + pad;
    const ty = y - pad;
    const by = y + h + pad;
    return .{
        .{ right, .{ rx, cy }, .{ rx, ty }, .{ cx, ty }, top },
        .{ right, .{ rx, cy }, .{ rx, by }, .{ cx, by }, bottom },
        .{ left, .{ lx, cy }, .{ lx, ty }, .{ cx, ty }, top },
        .{ left, .{ lx, cy }, .{ lx, by }, .{ cx, by }, bottom },
        .{ top, .{ cx, ty }, .{ rx, ty }, .{ rx, cy }, right },
        .{ top, .{ cx, ty }, .{ lx, ty }, .{ lx, cy }, left },
        .{ bottom, .{ cx, by }, .{ rx, by }, .{ rx, cy }, right },
        .{ bottom, .{ cx, by }, .{ lx, by }, .{ lx, cy }, left },
    };
}

pub fn buildObstacles(a: Allocator, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, config: *const LayoutConfig) Allocator.Error![]Obstacle {
    var out: std.ArrayList(Obstacle) = .empty;
    const pad = @max(config.node_spacing * OBSTACLE_PAD_RATIO, OBSTACLE_PAD_MIN);
    for (nodes.values()) |n| {
        if (n.hidden or n.anchor_subgraph != null) continue;
        try out.append(a, .{ .id = n.id, .x = n.x - pad, .y = n.y - pad, .width = n.width + pad * 2.0, .height = n.height + pad * 2.0 });
    }
    for (subgraphs, 0..) |sub, idx| {
        const invisible = util.trim(sub.label).len == 0 and eqlOpt(sub.style.stroke, "none") and eqlOpt(sub.style.fill, "none");
        if (invisible) continue;
        const members = try a.create(StrSet);
        members.* = .empty;
        for (sub.nodes) |id| try members.put(a, id, {});
        for (nodes.values()) |n| if (n.anchor_subgraph == idx) try members.put(a, n.id, {});
        try out.append(a, .{ .id = try std.fmt.allocPrint(a, "subgraph:{s}", .{sub.label}), .x = sub.x - pad, .y = sub.y - pad, .width = sub.width + pad * 2.0, .height = sub.height + pad * 2.0, .members = members });
    }
    return out.items;
}

pub fn eqlOpt(v: ?[]const u8, s: []const u8) bool {
    return if (v) |x| util.eql(x, s) else false;
}

pub fn buildLabelObstaclesForRouting(a: Allocator, nodes: *const NodeMap, subgraphs: []const SubgraphLayout) Allocator.Error!std.ArrayList(Obstacle) {
    var out: std.ArrayList(Obstacle) = .empty;
    for (nodes.values()) |n| {
        if (n.hidden or n.anchor_subgraph != null) continue;
        var all_empty = true;
        for (n.label.lines) |l| all_empty = all_empty and util.trim(l).len == 0;
        if (n.label.width <= 0.0 or n.label.height <= 0.0 or all_empty) continue;
        const p = LABEL_OBSTACLE_NODE_PAD;
        try out.append(a, .{ .id = try std.fmt.allocPrint(a, "node-label:{s}", .{n.id}), .x = n.x + (n.width - n.label.width) / 2.0 - p, .y = n.y + (n.height - n.label.height) / 2.0 - p, .width = n.label.width + p * 2.0, .height = n.label.height + p * 2.0 });
    }
    for (subgraphs) |sub| {
        if (util.trim(sub.label).len == 0 or sub.label_block.width <= 0.0 or sub.label_block.height <= 0.0) continue;
        const p = LABEL_OBSTACLE_SUB_PAD;
        try out.append(a, .{ .id = try std.fmt.allocPrint(a, "subgraph-label:{s}", .{sub.label}), .x = sub.x + 12.0 - p, .y = sub.y + 6.0 - p, .width = sub.label_block.width + p * 2.0, .height = sub.label_block.height + p * 2.0 });
    }
    return out;
}

/// `edge_pair_key` joined into one string.
pub fn edgePairKey(a: Allocator, e: *const ir.Edge) Allocator.Error![]const u8 {
    const lo, const hi = if (std.mem.order(u8, e.from, e.to) != .gt) .{ e.from, e.to } else .{ e.to, e.from };
    return std.fmt.allocPrint(a, "{s}\x00{s}", .{ lo, hi });
}

pub fn segmentIntersectsRect(p: Point, q: Point, r: *const Obstacle) bool {
    return geometry.segmentIntersectsRectBounds(p, q, .{ r.x, r.y, r.width, r.height });
}

pub fn collinearOverlapLength(a: Point, b: Point, c: Point, d: Point) f32 {
    const c1 = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
    const c2 = (b[0] - a[0]) * (d[1] - a[1]) - (b[1] - a[1]) * (d[0] - a[0]);
    if (@abs(c1) > 1e-6 or @abs(c2) > 1e-6) return 0.0;
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const sq = dx * dx + dy * dy;
    if (sq < 1e-6) return 0.0;
    const t1 = ((c[0] - a[0]) * dx + (c[1] - a[1]) * dy) / sq;
    const t2 = ((d[0] - a[0]) * dx + (d[1] - a[1]) * dy) / sq;
    return @max(@min(@max(t1, t2), 1.0) - @max(@min(t1, t2), 0.0), 0.0) * @sqrt(sq);
}

pub fn edgeCrossingsWithExisting(points: []const Point, existing: []const Segment) struct { usize, f32 } {
    if (points.len < 2 or existing.len == 0) return .{ 0, 0.0 };
    var crossings: usize = 0;
    var overlap: f32 = 0;
    for (0..points.len - 1) |i| {
        const a1 = points[i];
        const a2 = points[i + 1];
        for (existing) |s| {
            const b1 = s[0];
            const b2 = s[1];
            if ((@abs(a1[0] - b1[0]) < 1e-6 and @abs(a1[1] - b1[1]) < 1e-6) or
                (@abs(a1[0] - b2[0]) < 1e-6 and @abs(a1[1] - b2[1]) < 1e-6) or
                (@abs(a2[0] - b1[0]) < 1e-6 and @abs(a2[1] - b1[1]) < 1e-6) or
                (@abs(a2[0] - b2[0]) < 1e-6 and @abs(a2[1] - b2[1]) < 1e-6)) continue;
            overlap += collinearOverlapLength(a1, a2, b1, b2);
            if (segmentsIntersect(a1, a2, b1, b2)) crossings += 1;
        }
    }
    return .{ crossings, overlap };
}

// ---- edge_geometry.rs ----------------------------------------------------------------------

pub fn arrowheadInset(kind: ir.DiagramKind, arrow: ?ir.EdgeArrowhead) f32 {
    if (kind != .class) return 0.0;
    const k = arrow orelse return 4.0;
    return switch (k) {
        .open_triangle => 17.0,
        .class_dependency => 5.0,
    };
}

pub fn applyEndpointInsets(path: []Point, start_inset: f32, end_inset: f32) []Point {
    if (start_inset > 0.0 and path.len >= 2) {
        const dx = path[0][0] - path[1][0];
        const dy = path[0][1] - path[1][1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len > start_inset) {
            const r = start_inset / len;
            path[0] = .{ path[0][0] - dx * r, path[0][1] - dy * r };
        }
    }
    if (end_inset > 0.0 and path.len >= 2) {
        const n = path.len;
        const dx = path[n - 1][0] - path[n - 2][0];
        const dy = path[n - 1][1] - path[n - 2][1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len > end_inset) {
            const r = end_inset / len;
            path[n - 1] = .{ path[n - 1][0] - dx * r, path[n - 1][1] - dy * r };
        }
    }
    return path;
}

pub fn edgeEndpointAngle(points: []const Point, start: bool) f32 {
    if (points.len < 2) return 0.0;
    const p0 = if (start) points[0] else points[points.len - 2];
    const p1 = if (start) points[1] else points[points.len - 1];
    return std.math.radiansToDegrees(std.math.atan2(p1[1] - p0[1], p1[0] - p0[0]));
}
