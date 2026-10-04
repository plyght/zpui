//! `layout/label_placement.rs`: collision-avoiding placement of edge center
//! and endpoint labels.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir.zig");
const util = @import("../util.zig");
const Theme = @import("../theme.zig").Theme;
const LayoutConfig = @import("../config.zig").LayoutConfig;
const t = @import("types.zig");
const sequence = @import("sequence.zig");
const Kind = ir.DiagramKind;
const EdgeLayout = t.EdgeLayout;
const NodeMap = t.NodeMap;
const SubgraphLayout = t.SubgraphLayout;
const TextBlock = t.TextBlock;
const Point = t.Point;
const Rect = t.Rect;
const INF = std.math.inf(f32);

const LABEL_OVERLAP_WIDE_THRESHOLD: f32 = 1e-4;
const LABEL_ANCHOR_FRACTIONS = [_]f32{ 0.5, 0.35, 0.65, 0.2, 0.8 };
const LABEL_ANCHOR_POS_EPS: f32 = 1.0;
const LABEL_ANCHOR_DIR_EPS: f32 = 0.02;
const LABEL_EXTRA_SEGMENT_ANCHORS: usize = 6;
const FLOWCHART_LABEL_CLEARANCE_PAD: f32 = 1.5;
const FLOWCHART_LABEL_SOFT_GAP: f32 = 6.0;

const WEIGHT_NODE_OVERLAP: f32 = 1.6;
const WEIGHT_NODE_OVERLAP_FLOWCHART: f32 = 2.6;
const WEIGHT_LABEL_OVERLAP: f32 = 1.0;
const WEIGHT_FLOWCHART_LABEL_OVERLAP: f32 = 1.5;
const WEIGHT_EDGE_OVERLAP: f32 = 0.45;
const WEIGHT_FLOWCHART_EDGE_OVERLAP: f32 = 1.15;
const WEIGHT_OUTSIDE: f32 = 1.2;
const OWN_EDGE_GAP_TARGET: f32 = 1.2;
const OWN_EDGE_GAP_TARGET_FLOWCHART: f32 = 1.8;
const OWN_EDGE_GAP_TARGET_CLASS: f32 = 0.35;
const OWN_EDGE_GAP_UNDER_WEIGHT: f32 = 0.7;
const OWN_EDGE_GAP_UNDER_WEIGHT_FLOWCHART: f32 = 1.6;
const OWN_EDGE_GAP_UNDER_WEIGHT_CLASS: f32 = 0.08;
const OWN_EDGE_GAP_OVER_WEIGHT: f32 = 0.06;
const OWN_EDGE_GAP_OVER_WEIGHT_FLOWCHART: f32 = 0.65;
const OWN_EDGE_GAP_OVER_WEIGHT_CLASS: f32 = 0.18;
const OWN_EDGE_TOUCH_HARD_PENALTY: f32 = 0.25;
const OWN_EDGE_TOUCH_HARD_PENALTY_FLOWCHART: f32 = 1.25;
const OWN_EDGE_TOUCH_HARD_PENALTY_CLASS: f32 = 0.02;
const FLOWCHART_OWN_EDGE_SOFT_MAX_GAP: f32 = 6.0;
const FLOWCHART_OWN_EDGE_HARD_MAX_GAP: f32 = 10.0;
const FLOWCHART_OWN_EDGE_SOFT_MAX_GAP_WEIGHT: f32 = 0.85;
const FLOWCHART_OWN_EDGE_HARD_MAX_GAP_WEIGHT: f32 = 4.5;
const FLOWCHART_FOREIGN_EDGE_OVERLAP_WEIGHT: f32 = 0.9;
const FLOWCHART_FOREIGN_EDGE_TOUCH_HARD_PENALTY: f32 = 2.0;
const STATE_OWN_EDGE_HARD_MAX_GAP: f32 = 7.0;
const CLASS_OWN_EDGE_HARD_MAX_GAP: f32 = 7.0;
const DEFAULT_OWN_EDGE_HARD_MAX_GAP: f32 = 8.0;

const EdgeObstacle = struct { idx: usize, rect: Rect };
const Anchor = struct { f32, f32, f32, f32 };
const Cost = struct { f32, f32 };

const OverlapScore = struct {
    count: usize,
    total: f32,
    max: f32,
    fn improvedBy(self: OverlapScore, other: OverlapScore) bool {
        return self.count < other.count or (self.count == other.count and self.max + 0.1 < other.max) or
            (self.count == other.count and @abs(self.max - other.max) <= 0.1 and self.total + 0.1 < other.total);
    }
};

fn edgeDistanceWeight(kind: Kind, pressure: f32) f32 {
    const base: f32 = switch (kind) {
        .flowchart => 0.72,
        .state => 0.38,
        .class => 0.24,
        else => 0.16,
    };
    if (pressure <= 0.025) return base;
    if (pressure <= 0.10) return switch (kind) {
        .flowchart => base * 0.92,
        .state => base * 0.80,
        else => base * 0.55,
    };
    return switch (kind) {
        .flowchart => base * 0.68,
        .state => base * 0.55,
        else => base * 0.2,
    };
}

fn centerLabelNodeObstaclePad(kind: Kind, theme: *const Theme, px: f32, py: f32) f32 {
    return switch (kind) {
        .flowchart => @max(theme.font_size * 0.55, @max(px, py + FLOWCHART_LABEL_CLEARANCE_PAD)),
        .state => @max(@max(theme.font_size * 0.22, py), 2.0),
        .class => @max(@max(theme.font_size * 0.28, py), 2.2),
        else => @max(theme.font_size * 0.45, @max(px, py)),
    };
}

fn edgeTargetDistance(kind: Kind, lh: f32, py: f32) f32 {
    return switch (kind) {
        .flowchart => @max(lh * 0.52 + py * 0.65 + 0.4, 4.8),
        else => @max(lh * 0.65 + py, 6.0),
    };
}

fn flowchartOwnGapAllowed(gap: f32, max_gap: f32) bool {
    return std.math.isFinite(gap) and gap >= OWN_EDGE_GAP_TARGET_FLOWCHART * 0.5 and gap <= max_gap;
}

fn sweepBias(kind: Kind, ts: f32, ns: f32) f32 {
    const w: [2]f32 = if (kind == .flowchart) .{ 0.018, 0.004 } else .{ 0.010, 0.003 };
    return @abs(ns) * w[0] + @abs(ts) * w[1];
}

pub fn edgeLabelPadding(kind: Kind) [2]f32 {
    return switch (kind) {
        .requirement => .{ 6.0, 3.0 },
        .state => .{ 3.0, 1.6 },
        .flowchart => .{ 4.5, 2.2 },
        else => .{ 4.0, 2.0 },
    };
}

pub fn endpointLabelPadding(kind: Kind) [2]f32 {
    return switch (kind) {
        .state => .{ 2.6, 1.4 },
        .flowchart => .{ 3.4, 1.8 },
        .class => .{ 3.2, 1.6 },
        else => .{ 3.0, 1.6 },
    };
}

pub fn resolveAllLabelPositions(a: Allocator, layout: *t.Layout, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!void {
    _ = config;
    if (layout.kind == .sequence or layout.kind == .zen_uml) {
        try sequence.resolveSequenceLabelPositions(a, layout, theme);
        return;
    }
    const bounds: ?[2]f32 = .{ layout.width, layout.height };
    const center_bounds = if (layout.kind == .flowchart) null else bounds;
    try resolveCenterLabels(a, layout.edges.items, &layout.nodes, layout.subgraphs.items, center_bounds, layout.kind, theme);
    if (layout.kind == .flowchart) moveFlowchartLabelsOffOwnEdges(layout.edges.items);
    try resolveEndpointLabels(a, layout.edges.items, &layout.nodes, layout.subgraphs.items, bounds, layout.kind, theme);
}

fn coreRect(c: Point, w: f32, h: f32) Rect {
    return .{ c[0] - w / 2.0, c[1] - h / 2.0, w, h };
}

fn padRect(c: Point, w: f32, h: f32, px: f32, py: f32) Rect {
    return .{ c[0] - w / 2.0 - px, c[1] - h / 2.0 - py, w + 2.0 * px, h + 2.0 * py };
}

fn moveFlowchartLabelsOffOwnEdges(edges: []EdgeLayout) void {
    for (edges) |*e| {
        const label = e.label orelse continue;
        const anchor = e.label_anchor orelse continue;
        if (polylineRectDistance(e.points.items, coreRect(anchor, label.width, label.height)) > 0.0) continue;
        const dy = label.height + 24.0;
        const dx = label.width * 0.5 + 24.0;
        const cands = [_]Point{
            .{ anchor[0], anchor[1] - dy },      .{ anchor[0], anchor[1] + dy },
            .{ anchor[0] - dx, anchor[1] },      .{ anchor[0] + dx, anchor[1] },
            .{ anchor[0] - dx, anchor[1] - dy }, .{ anchor[0] + dx, anchor[1] - dy },
            .{ anchor[0] - dx, anchor[1] + dy }, .{ anchor[0] + dx, anchor[1] + dy },
        };
        for (cands) |c| if (polylineRectDistance(e.points.items, coreRect(c, label.width, label.height)) > 0.0) {
            e.label_anchor = c;
            break;
        };
    }
}

const PenaltyCtx = struct {
    kind: Kind,
    occupied: []const Rect,
    occupied_grid: *const ObstacleGrid,
    node_obstacle_count: usize,
    edge_obstacles: []const EdgeObstacle,
    edge_grid: *const ObstacleGrid,
    edge_idx: usize,
    own_points: []const Point,
    bounds: ?[2]f32,
};

fn resolveCenterLabels(a: Allocator, edges: []EdgeLayout, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, bounds: ?[2]f32, kind: Kind, theme: *const Theme) Allocator.Error!void {
    const pad = edgeLabelPadding(kind);
    const px = pad[0];
    const py = pad[1];
    const node_pad = centerLabelNodeObstaclePad(kind, theme, px, py);
    const edge_pad = @max(theme.font_size * 0.35, py);
    const step_normal_pad = @max(theme.font_size * 0.22, py);
    const step_tangent_pad = @max(theme.font_size * 0.28, px);
    const sub_pad = @max(theme.font_size * 0.35, 3.0);
    var occupied = try buildLabelObstacles(a, nodes, subgraphs, kind, theme, node_pad, sub_pad);
    if (kind == .flowchart) try occupied.appendSlice(a, try buildNodeTextObstacles(a, nodes, @max(theme.font_size * 0.2, 2.0)));
    const node_obstacle_count = occupied.items.len;
    const edge_obstacles = try buildEdgeObstacles(a, edges, edge_pad);
    const edge_grid = try ObstacleGrid.initEdges(a, 48.0, edge_obstacles);
    var occupied_grid = try ObstacleGrid.init(a, 48.0, occupied.items);
    const bundle = if (kind == .flowchart) try edgeLabelBundleFractions(a, edges) else blk: {
        const v = try a.alloc(?f32, edges.len);
        @memset(v, null);
        break :blk v;
    };
    var fixed: std.AutoHashMapUnmanaged(usize, void) = .empty;
    for (edges, 0..) |*e, idx| {
        const label = e.label orelse continue;
        const anchor = e.label_anchor orelse continue;
        const clamped = if (bounds) |b| clampLabelCenterToBounds(anchor, label.width, label.height, px, py, b) else anchor;
        const rect = padRect(clamped, label.width, label.height, px, py);
        const occ_rect = if (kind == .flowchart) inflateRect(rect, FLOWCHART_LABEL_CLEARANCE_PAD) else rect;
        e.label_anchor = clamped;
        if (kind == .flowchart) continue;
        try occupied_grid.insert(a, occupied.items.len, occ_rect);
        try occupied.append(a, occ_rect);
        try fixed.put(a, idx, {});
    }
    var order: std.ArrayList(usize) = .empty;
    for (edges, 0..) |e, i| if (e.label != null and !fixed.contains(i)) try order.append(a, i);
    std.mem.sort(usize, order.items, edges, struct {
        fn lt(es: []EdgeLayout, x: usize, y: usize) bool {
            const xf = es[x].label_anchor != null;
            const yf = es[y].label_anchor != null;
            if (xf != yf) return xf;
            const ax = if (es[x].label) |l| l.width * l.height else 0;
            const ay = if (es[y].label) |l| l.width * l.height else 0;
            if (@abs(ax - ay) > 1e-3) return ay < ax;
            return polylinePathLength(es[x].points.items) < polylinePathLength(es[y].points.items);
        }
    }.lt);

    const center_max_gap = centerLabelHardMaxGap(kind);
    const steps = switch (kind) {
        .flowchart => [2][]const f32{ &.{ 0.6, -0.6, 1.0, -1.0, 1.4, -1.4, 0.35, -0.35, 2.0, -2.0, 2.8, -2.8, 0.0 }, &.{ 0.0, 0.3, -0.3, 0.8, -0.8, 1.4, -1.4, 2.2, -2.2, 3.2, -3.2 } },
        .state => [2][]const f32{ &.{ 0.0, 0.12, -0.12, 0.22, -0.22, 0.35, -0.35, 0.45, -0.45, 0.5, -0.5, 0.55, -0.55, 0.6, -0.6, 1.0, -1.0, 2.0, -2.0, 3.0, -3.0 }, &.{ 0.0, 0.12, -0.12, 0.2, -0.2, 0.35, -0.35, 0.6, -0.6, 1.2, -1.2, 2.0, -2.0, 3.0, -3.0 } },
        else => [2][]const f32{ &.{ 0.0, 0.15, -0.15, 0.35, -0.35, 0.6, -0.6, 1.0, -1.0, 2.0, -2.0, 3.0, -3.0 }, &.{ 0.0, 0.2, -0.2, 0.6, -0.6, 1.2, -1.2, 2.0, -2.0, 3.0, -3.0 } },
    };
    const wide = switch (kind) {
        .flowchart => [2][]const f32{ &.{ 0.6, -0.6, 1.2, -1.2, 2.0, -2.0, 3.0, -3.0, 4.0, -4.0, 5.2, -5.2, 6.5, -6.5, 0.0 }, &.{ 0.0, 0.8, -0.8, 1.6, -1.6, 2.6, -2.6, 3.8, -3.8, 5.2, -5.2, 6.6, -6.6, 8.0, -8.0, 10.0, -10.0 } },
        .state => [2][]const f32{ &.{ 0.0, 0.45, -0.45, 0.5, -0.5, 0.55, -0.55, 1.0, -1.0, 2.0, -2.0, 3.0, -3.0, 4.0, -4.0, 5.0, -5.0 }, &.{ 0.0, 0.12, -0.12, 0.35, -0.35, 0.8, -0.8, 1.6, -1.6, 2.4, -2.4, 3.2, -3.2, 4.2, -4.2, 5.4, -5.4 } },
        else => [2][]const f32{ &.{ 0.0, 1.0, -1.0, 2.0, -2.0, 3.0, -3.0, 4.0, -4.0, 5.0, -5.0 }, &.{ 0.0, 0.8, -0.8, 1.6, -1.6, 2.4, -2.4, 3.2, -3.2, 4.2, -4.2, 5.4, -5.4 } },
    };
    const gap_bands = switch (kind) {
        .flowchart => [2][]const f32{ &.{ 0.8, 1.4, 2.0, 3.0, 4.4, 6.2 }, &.{ 0.0, 0.3, -0.3, 0.8, -0.8, 1.4, -1.4 } },
        .state => [2][]const f32{ &.{ 0.8, 1.3, 1.9, 2.8, 3.9, 5.3 }, &.{ 0.0, 0.12, -0.12, 0.35, -0.35, 0.8, -0.8 } },
        else => [2][]const f32{ &.{ 0.8, 1.4, 2.1, 3.0, 4.1, 5.6 }, &.{ 0.0, 0.2, -0.2, 0.6, -0.6, 1.2, -1.2 } },
    };

    for (order.items) |idx| {
        const label = edges[idx].label orelse continue;
        const edge = &edges[idx];
        var anchors: std.ArrayList(Anchor) = .empty;
        if (edge.label_anchor) |la| if (edgeLabelAnchorFromPoint(edge, la)) |c| try pushAnchorUnique(a, &anchors, c);
        if (bundle[idx]) |bf| for ([_]f32{ 0.0, -0.08, 0.08 }) |d| {
            if (edgeLabelAnchorAtFraction(edge, std.math.clamp(bf + d, 0.05, 0.95))) |c| try pushAnchorUnique(a, &anchors, c);
        };
        for (LABEL_ANCHOR_FRACTIONS) |f| if (edgeLabelAnchorAtFraction(edge, f)) |c| try pushAnchorUnique(a, &anchors, c);
        for (try edgeSegmentAnchors(a, edge, LABEL_EXTRA_SEGMENT_ANCHORS)) |c| try pushAnchorUnique(a, &anchors, c);
        if (kind == .flowchart) for (edgeTerminalSegmentAnchors(edge, 2).slice()) |c| try pushAnchorUnique(a, &anchors, c);
        if (anchors.items.len == 0) try anchors.append(a, edgeLabelAnchor(edge)) else try pushAnchorUnique(a, &anchors, edgeLabelAnchor(edge));

        const pctx: PenaltyCtx = .{ .kind = kind, .occupied = occupied.items, .occupied_grid = &occupied_grid, .node_obstacle_count = node_obstacle_count, .edge_obstacles = edge_obstacles, .edge_grid = &edge_grid, .edge_idx = idx, .own_points = edge.points.items, .bounds = bounds };
        var ev: CenterEval = .{ .label = label, .px = px, .py = py, .pad_w = label.width + 2.0 * px, .pad_h = label.height + 2.0 * py, .snp = step_normal_pad, .stp = step_tangent_pad, .kind = kind, .bounds = bounds, .points = edge.points.items, .pctx = &pctx, .gap_targets = gap_bands[0], .tangent_focus = gap_bands[1], .best_pos = .{ anchors.items[0][0], anchors.items[0][1] }, .best = .{ INF, INF } };
        var evaluated = false;
        for (anchors.items) |an| evaluated = ev.run(an, steps[1], steps[0], center_max_gap) or evaluated;
        if (!evaluated and center_max_gap != null) for (anchors.items) |an| {
            _ = ev.run(an, steps[1], steps[0], null);
        };
        if (ev.best[0] > LABEL_OVERLAP_WIDE_THRESHOLD) {
            var ew = false;
            for (anchors.items) |an| ew = ev.run(an, wide[1], wide[0], center_max_gap) or ew;
            if (!ew and center_max_gap != null) for (anchors.items) |an| {
                _ = ev.run(an, wide[1], wide[0], null);
            };
        }
        const cp = if (bounds) |b| clampLabelCenterToBounds(ev.best_pos, label.width, label.height, px, py, b) else ev.best_pos;
        const rect = padRect(cp, label.width, label.height, px, py);
        const occ_rect = if (kind == .flowchart) inflateRect(rect, FLOWCHART_LABEL_CLEARANCE_PAD) else rect;
        try occupied_grid.insert(a, occupied.items.len, occ_rect);
        try occupied.append(a, occ_rect);
        edges[idx].label_anchor = cp;
    }
    if (kind == .flowchart) try deoverlapFlowchartCenterLabels(a, edges, nodes, subgraphs, bounds, theme, px, py, &fixed);
    try tightenCenterLabelGaps(a, edges, nodes, subgraphs, bounds, kind, theme, px, py, &fixed);
    try enforceCenterLabelAttachmentCaps(a, edges, nodes, subgraphs, bounds, kind, theme, px, py, &fixed);
    if (kind == .flowchart) {
        try nudgeFlowchartLabelsClearOfOwnPaths(a, edges, bounds);
        const before = centerLabelOverlapScore(a, edges, px, py);
        const cand = try a.dupe(EdgeLayout, edges);
        try deoverlapFlowchartCenterLabels(a, cand, nodes, subgraphs, bounds, theme, px, py, &fixed);
        const after = centerLabelOverlapScore(a, cand, px, py);
        if (after.improvedBy(before)) @memcpy(edges, cand);
        try nudgeFlowchartLabelsClearOfOwnPaths(a, edges, bounds);
    }
}

const CenterEval = struct {
    label: TextBlock,
    px: f32,
    py: f32,
    pad_w: f32,
    pad_h: f32,
    snp: f32,
    stp: f32,
    kind: Kind,
    bounds: ?[2]f32,
    points: []const Point,
    pctx: *const PenaltyCtx,
    gap_targets: []const f32,
    tangent_focus: []const f32,
    best_pos: Point,
    best: Cost,
    evaluated: bool = false,
    anchor: Anchor = undefined,
    max_gap: ?f32 = null,

    fn score(self: *CenterEval, x: f32, y: f32, tm: f32, nm: f32) void {
        const center = if (self.bounds) |b| clampLabelCenterToBounds(.{ x, y }, self.label.width, self.label.height, self.px, self.py, b) else Point{ x, y };
        const rect = Rect{ center[0] - self.label.width / 2.0 - self.px, center[1] - self.label.height / 2.0 - self.py, self.pad_w, self.pad_h };
        if (self.max_gap) |mg| {
            const own = polylineRectDistance(self.points, rect);
            if (self.kind == .flowchart) {
                if (!flowchartOwnGapAllowed(own, mg)) return;
            } else if (std.math.isFinite(own) and own > mg) return;
        }
        self.evaluated = true;
        const p = labelPenalties(rect, .{ self.anchor[0], self.anchor[1] }, self.label.width, self.label.height, self.pctx);
        const ed = pointPolylineDistance(center, self.points);
        const target = edgeTargetDistance(self.kind, self.label.height, self.py);
        const edp = (@max(ed - target, 0.0) / target) * edgeDistanceWeight(self.kind, p[0]);
        const pen = Cost{ p[0] + edp + sweepBias(self.kind, tm, nm), p[1] };
        if (candidateBetter(pen, self.best)) {
            self.best = pen;
            self.best_pos = center;
        }
    }

    fn run(self: *CenterEval, an: Anchor, tangents: []const f32, normals: []const f32, max_gap: ?f32) bool {
        self.evaluated = false;
        self.anchor = an;
        self.max_gap = max_gap;
        const ax = an[0];
        const ay = an[1];
        const dx = an[2];
        const dy = an[3];
        const nx = -dy;
        const ny = dx;
        const lw = self.label.width;
        const lh = self.label.height;
        const step_n = if (@abs(nx) > @abs(ny)) lw + self.px + self.snp else lh + self.py + self.snp;
        const step_t = if (@abs(dx) > @abs(dy)) lw + self.px + self.stp else lh + self.py + self.stp;
        const hw = lw * 0.5 + self.px;
        const hh = lh * 0.5 + self.py;
        const ne = @abs(nx) * hw + @abs(ny) * hh;
        for (self.tangent_focus) |tt| {
            const bx = ax + dx * step_t * tt;
            const by = ay + dy * step_t * tt;
            for (self.gap_targets) |g| {
                const off = ne + g;
                const an_ = off / @max(step_n, 1.0);
                self.score(bx + nx * off, by + ny * off, tt, an_);
                self.score(bx - nx * off, by - ny * off, tt, -an_);
            }
        }
        for (tangents) |tt| {
            const bx = ax + dx * step_t * tt;
            const by = ay + dy * step_t * tt;
            for (normals) |n| self.score(bx + nx * step_n * n, by + ny * step_n * n, tt, n);
        }
        return self.evaluated;
    }
};

fn centerLabelOverlapScore(a: Allocator, edges: []const EdgeLayout, px: f32, py: f32) OverlapScore {
    _ = a;
    var s: OverlapScore = .{ .count = 0, .total = 0, .max = 0 };
    for (edges, 0..) |ei, i| {
        const li = ei.label orelse continue;
        const ci = ei.label_anchor orelse continue;
        const ri = padRect(ci, li.width, li.height, px, py);
        for (edges[i + 1 ..]) |ej| {
            const lj = ej.label orelse continue;
            const cj = ej.label_anchor orelse continue;
            const ov = overlapArea(ri, padRect(cj, lj.width, lj.height, px, py));
            if (ov > LABEL_OVERLAP_WIDE_THRESHOLD) {
                s.count += 1;
                s.total += ov;
                s.max = @max(s.max, ov);
            }
        }
    }
    return s;
}

fn pathIntersectsRect(points: []const Point, r: Rect) bool {
    if (points.len < 2) return false;
    for (0..points.len - 1) |i| if (segmentIntersectsRect(points[i], points[i + 1], r)) return true;
    return false;
}

fn nudgeFlowchartLabelsClearOfOwnPaths(a: Allocator, edges: []EdgeLayout, bounds: ?[2]f32) Allocator.Error!void {
    const rects = try a.alloc(?Rect, edges.len);
    for (edges, 0..) |e, i| rects[i] = if (e.label != null and e.label_anchor != null) coreRect(e.label_anchor.?, e.label.?.width, e.label.?.height) else null;
    const dirs = [_]Point{ .{ 0, -1 }, .{ 0, 1 }, .{ -1, 0 }, .{ 1, 0 }, .{ -0.707, -0.707 }, .{ 0.707, -0.707 }, .{ -0.707, 0.707 }, .{ 0.707, 0.707 } };
    for (edges, 0..) |*e, idx| {
        const label = e.label orelse continue;
        const center = e.label_anchor orelse continue;
        if (!pathIntersectsRect(e.points.items, coreRect(center, label.width, label.height))) continue;
        var best: ?Point = null;
        var best_cost = INF;
        for ([_]f32{ 2.0, 4.0, 6.0, 8.0, 12.0, 16.0, 24.0, 32.0 }) |step| {
            for (dirs) |d| {
                var cand = Point{ center[0] + d[0] * step, center[1] + d[1] * step };
                if (bounds) |b| cand = clampLabelCenterToBounds(cand, label.width, label.height, 0, 0, b);
                const r = coreRect(cand, label.width, label.height);
                if (pathIntersectsRect(e.points.items, r)) continue;
                var ov: f32 = 0;
                for (rects, 0..) |o, oi| {
                    if (oi == idx) continue;
                    if (o) |orr| ov += overlapArea(r, orr);
                }
                const outside = if (bounds) |b| outsideArea(r, b) else 0;
                const cost = step + ov * 10.0 + outside * 20.0;
                if (cost < best_cost) {
                    best_cost = cost;
                    best = cand;
                }
            }
            if (best != null) break;
        }
        if (best) |c| {
            e.label_anchor = c;
            rects[idx] = coreRect(c, label.width, label.height);
        }
    }
}

const Entry = struct {
    edge_idx: usize,
    label_w: f32,
    label_h: f32,
    initial_center: Point,
    initial_s_norm: f32,
    initial_d_signed: f32,
    current_center: Point,
    edge_points: []const Point,
    candidates: []const Point,
};

const Candidate = struct {
    center: Point,
    rect: Rect,
    cost: Cost,
    own_gap: f32,
    center_dist: f32,
    center_target: f32,
    center_soft_max: f32,
    center_hard_max: f32,
    fixed_overlap_count: u32,
    fixed_overlap_area: f32,
    s_norm: f32,
    d_signed: f32,
};

fn fcRect(c: Point, w: f32, h: f32, px: f32, py: f32) Rect {
    return padRect(c, w, h, px, py);
}

fn fcObstacleRect(c: Point, w: f32, h: f32, px: f32, py: f32) Rect {
    return inflateRect(padRect(c, w, h, px, py), FLOWCHART_LABEL_CLEARANCE_PAD);
}

fn deoverlapFlowchartCenterLabels(a: Allocator, edges: []EdgeLayout, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, bounds: ?[2]f32, theme: *const Theme, px: f32, py: f32, locked: *const std.AutoHashMapUnmanaged(usize, void)) Allocator.Error!void {
    const snp = @max(theme.font_size * 0.25, py);
    const stp = @max(theme.font_size * 0.35, px);
    var entries: std.ArrayList(Entry) = .empty;
    for (edges, 0..) |*e, idx| {
        if (locked.contains(idx)) continue;
        const label = e.label orelse continue;
        const anchor = e.label_anchor orelse continue;
        const cur = if (bounds) |b| clampLabelCenterToBounds(anchor, label.width, label.height, px, py, b) else anchor;
        const init_c: Point = if (edgeLabelAnchorFromPoint(e, cur)) |an| .{ an[0], an[1] } else blk: {
            const an = edgeLabelAnchor(e);
            break :blk .{ an[0], an[1] };
        };
        const pose = edgeRelativePose(e.points.items, init_c) orelse Point{ 0.5, 0.0 };
        try entries.append(a, .{
            .edge_idx = idx,
            .label_w = label.width,
            .label_h = label.height,
            .initial_center = init_c,
            .initial_s_norm = pose[0],
            .initial_d_signed = pose[1],
            .current_center = cur,
            .edge_points = e.points.items,
            .candidates = try flowchartCenterLabelCandidates(a, e, cur, label.width, label.height, px, py, snp, stp, bounds),
        });
    }
    if (entries.items.len < 2) return;
    const node_pad = @max(theme.font_size * 0.55, @max(px, py + FLOWCHART_LABEL_CLEARANCE_PAD));
    const sub_pad = @max(theme.font_size * 0.35, 3.0);
    var fixed = try buildLabelObstacles(a, nodes, subgraphs, .flowchart, theme, node_pad, sub_pad);
    try fixed.appendSlice(a, try buildNodeTextObstacles(a, nodes, @max(theme.font_size * 0.2, 2.0)));
    for (edges, 0..) |e, idx| {
        if (!locked.contains(idx)) continue;
        const l = e.label orelse continue;
        const c = e.label_anchor orelse continue;
        try fixed.append(a, inflateRect(padRect(c, l.width, l.height, px, py), FLOWCHART_LABEL_CLEARANCE_PAD));
    }
    const edge_obstacles = try buildEdgeObstacles(a, edges, @max(theme.font_size * 0.35, py));
    const edge_grid = try ObstacleGrid.initEdges(a, 48.0, edge_obstacles);
    const ents = entries.items;
    try applyComponentAssignment(a, ents, px, py, fixed.items, edge_obstacles, &edge_grid);

    for (0..10) |_| {
        const rects = try a.alloc(Rect, ents.len);
        for (ents, 0..) |e, i| rects[i] = fcObstacleRect(e.current_center, e.label_w, e.label_h, px, py);
        const CO = struct { s: f32, i: usize };
        var co: std.ArrayList(CO) = .empty;
        for (rects, 0..) |r, i| {
            var s: f32 = 0;
            for (rects, 0..) |o, j| {
                if (i == j) continue;
                const ov = overlapArea(r, o);
                if (ov > 0.0) s += ov + 1.0;
            }
            for (fixed.items) |o| {
                const ov = overlapArea(r, o);
                if (ov > 0.0) s += ov * 1.6 + 1.0;
            }
            if (s > 0.0) try co.append(a, .{ .s = s, .i = i });
        }
        if (co.items.len == 0) break;
        std.mem.sort(CO, co.items, {}, struct {
            fn lt(_: void, x: CO, y: CO) bool {
                return y.s < x.s;
            }
        }.lt);
        var moved = false;
        for (co.items) |c| {
            const snap = ents[c.i];
            var others: std.ArrayList(Rect) = .empty;
            for (ents, 0..) |e, i| if (i != c.i) try others.append(a, fcObstacleRect(e.current_center, e.label_w, e.label_h, px, py));
            var best_center = snap.current_center;
            var best_cost = refineCost(&snap, snap.current_center, px, py, others.items, fixed.items, edge_obstacles, &edge_grid);
            const Eval = struct {
                fn f(sn: *const Entry, gap: bool, band: bool, pxx: f32, pyy: f32, oth: []const Rect, fx: []const Rect, eo: []const EdgeObstacle, eg: *const ObstacleGrid, bc: *Point, bcost: *Cost) bool {
                    var considered = false;
                    for (sn.candidates) |cand| {
                        if (@abs(cand[0] - sn.current_center[0]) <= 0.2 and @abs(cand[1] - sn.current_center[1]) <= 0.2) continue;
                        if (band) {
                            const cd = pointPolylineDistance(cand, sn.edge_points);
                            const hm = poseCenterHardMax(sn.edge_points, cand, sn.label_w, sn.label_h, pxx, pyy);
                            if (std.math.isFinite(cd) and cd > hm) continue;
                        }
                        if (gap) {
                            const own = polylineRectDistance(sn.edge_points, fcRect(cand, sn.label_w, sn.label_h, pxx, pyy));
                            if (!flowchartOwnGapAllowed(own, FLOWCHART_OWN_EDGE_HARD_MAX_GAP)) continue;
                        }
                        considered = true;
                        const cost = refineCost(sn, cand, pxx, pyy, oth, fx, eo, eg);
                        if (candidateBetter(cost, bcost.*)) {
                            bcost.* = cost;
                            bc.* = cand;
                        }
                    }
                    return considered;
                }
            }.f;
            if (!Eval(&snap, true, true, px, py, others.items, fixed.items, edge_obstacles, &edge_grid, &best_center, &best_cost)) {
                if (!Eval(&snap, true, false, px, py, others.items, fixed.items, edge_obstacles, &edge_grid, &best_center, &best_cost)) {
                    _ = Eval(&snap, false, false, px, py, others.items, fixed.items, edge_obstacles, &edge_grid, &best_center, &best_cost);
                }
            }
            if (@abs(best_center[0] - ents[c.i].current_center[0]) > 0.2 or @abs(best_center[1] - ents[c.i].current_center[1]) > 0.2) {
                ents[c.i].current_center = best_center;
                moved = true;
            }
        }
        if (!moved) break;
    }

    const residual = entryOverlapScore(ents, px, py);
    var horiz: usize = 0;
    for (ents) |e| {
        const sp = pathSpan(e.edge_points);
        if (sp[0] >= sp[1]) horiz += 1;
    }
    const use_pair = horiz * 2 >= ents.len and residual.count > 0 and residual.total >= 10.0;
    for (0..6) |_| {
        const rects = try a.alloc(Rect, ents.len);
        for (ents, 0..) |e, i| rects[i] = fcObstacleRect(e.current_center, e.label_w, e.label_h, px, py);
        var adjusted = false;
        search: for (0..ents.len) |i| {
            for (i + 1..ents.len) |j| {
                if (overlapArea(rects[i], rects[j]) <= LABEL_OVERLAP_WIDE_THRESHOLD) continue;
                for ([_]usize{ i, j }) |mi| {
                    const snap = ents[mi];
                    const blocking = rects[if (mi == i) j else i];
                    var cands: std.ArrayList(Point) = .empty;
                    try cands.appendSlice(a, snap.candidates);
                    if (use_pair) for (pairSeparationCandidates(&snap, blocking, px, py, bounds).slice()) |c| try pushCenterUnique(a, &cands, c);
                    var others: std.ArrayList(Rect) = .empty;
                    for (rects, 0..) |r, k| if (k != mi) try others.append(a, r);
                    var st: PairEval = .{ .snap = &snap, .cands = cands.items, .others = others.items, .fixed = fixed.items, .eo = edge_obstacles, .eg = &edge_grid, .px = px, .py = py };
                    if (!st.run(true, true, true)) {
                        if (use_pair) {
                            if (!st.run(true, true, false)) if (!st.run(false, true, false)) if (!st.run(true, false, true)) if (!st.run(true, false, false)) {
                                _ = st.run(false, false, false);
                            };
                        } else {
                            if (!st.run(true, false, true)) if (!st.run(true, false, false)) {
                                _ = st.run(false, false, false);
                            };
                        }
                    }
                    if (st.best_center) |c| if (@abs(c[0] - ents[mi].current_center[0]) > 0.2 or @abs(c[1] - ents[mi].current_center[1]) > 0.2) {
                        ents[mi].current_center = c;
                        adjusted = true;
                        break :search;
                    };
                }
            }
        }
        if (!adjusted) break;
    }
    for (ents) |e| edges[e.edge_idx].label_anchor = e.current_center;
}

const PairEval = struct {
    snap: *const Entry,
    cands: []const Point,
    others: []const Rect,
    fixed: []const Rect,
    eo: []const EdgeObstacle,
    eg: *const ObstacleGrid,
    px: f32,
    py: f32,
    best_center: ?Point = null,
    best_cost: Cost = .{ INF, INF },

    fn run(self: *PairEval, gap: bool, no_overlap: bool, band: bool) bool {
        const sn = self.snap;
        const area = @max(sn.label_w * sn.label_h, 1.0);
        var considered = false;
        for (self.cands) |cand| {
            if (band) {
                const cd = pointPolylineDistance(cand, sn.edge_points);
                const hm = poseCenterHardMax(sn.edge_points, cand, sn.label_w, sn.label_h, self.px, self.py);
                if (std.math.isFinite(cd) and cd > hm) continue;
            }
            const rect = fcRect(cand, sn.label_w, sn.label_h, self.px, self.py);
            const orect = fcObstacleRect(cand, sn.label_w, sn.label_h, self.px, self.py);
            var penalty: f32 = 0;
            var has = false;
            for (self.others) |o| {
                const ov = overlapArea(orect, o);
                if (ov > LABEL_OVERLAP_WIDE_THRESHOLD) {
                    has = true;
                    penalty += (ov / area) * 140.0;
                }
            }
            for (self.fixed) |o| {
                const ov = overlapArea(orect, o);
                if (ov > LABEL_OVERLAP_WIDE_THRESHOLD) {
                    has = true;
                    penalty += (ov / area) * 180.0;
                }
            }
            if (no_overlap and has) continue;
            if (gap and !flowchartOwnGapAllowed(polylineRectDistance(sn.edge_points, rect), FLOWCHART_OWN_EDGE_HARD_MAX_GAP)) continue;
            considered = true;
            const c = refineCost(sn, cand, self.px, self.py, self.others, self.fixed, self.eo, self.eg);
            const cost = Cost{ c[0] + penalty, c[1] };
            if (self.best_center == null or candidateBetter(cost, self.best_cost)) {
                self.best_center = cand;
                self.best_cost = cost;
            }
        }
        return considered;
    }
};

fn centerLabelGapLimits(kind: Kind) [3]f32 {
    return switch (kind) {
        .flowchart => .{ OWN_EDGE_GAP_TARGET_FLOWCHART, FLOWCHART_OWN_EDGE_SOFT_MAX_GAP, FLOWCHART_OWN_EDGE_HARD_MAX_GAP },
        .state => .{ 1.7, 4.8, STATE_OWN_EDGE_HARD_MAX_GAP },
        .class => .{ 1.6, 4.6, CLASS_OWN_EDGE_HARD_MAX_GAP },
        else => .{ 1.5, 5.0, DEFAULT_OWN_EDGE_HARD_MAX_GAP },
    };
}

fn centerLabelObstacleRect(kind: Kind, c: Point, w: f32, h: f32, px: f32, py: f32) Rect {
    const r = padRect(c, w, h, px, py);
    return if (kind == .flowchart) inflateRect(r, FLOWCHART_LABEL_CLEARANCE_PAD) else r;
}

fn centerLabelGapPenalty(gap: f32, target_gap: f32, soft: f32, hard: f32) f32 {
    if (!std.math.isFinite(gap)) return 120.0;
    const target = @max(target_gap, 1e-3);
    var p: f32 = 0;
    if (gap <= 0.35) p += 28.0;
    const dev = (gap - target) / target;
    p += dev * dev * 0.8;
    if (gap > soft) p += (gap - soft) * (gap - soft) * 2.0;
    if (gap > hard) p += (gap - hard) * 10.0;
    return p;
}

fn collectAnchors(a: Allocator, edge: *const EdgeLayout, center: Point, terminal: bool) Allocator.Error![]Anchor {
    var anchors: std.ArrayList(Anchor) = .empty;
    if (edgeLabelAnchorFromPoint(edge, center)) |an| try pushAnchorUnique(a, &anchors, an);
    for (LABEL_ANCHOR_FRACTIONS) |f| if (edgeLabelAnchorAtFraction(edge, f)) |an| try pushAnchorUnique(a, &anchors, an);
    for (try edgeSegmentAnchors(a, edge, LABEL_EXTRA_SEGMENT_ANCHORS)) |an| try pushAnchorUnique(a, &anchors, an);
    if (terminal) for (edgeTerminalSegmentAnchors(edge, 2).slice()) |an| try pushAnchorUnique(a, &anchors, an);
    if (anchors.items.len == 0) try anchors.append(a, edgeLabelAnchor(edge)) else try pushAnchorUnique(a, &anchors, edgeLabelAnchor(edge));
    return anchors.items;
}

fn tightenCandidates(a: Allocator, edge: *const EdgeLayout, cur: Point, lw: f32, lh: f32, px: f32, py: f32, kind: Kind, bounds: ?[2]f32) Allocator.Error![]Point {
    var cands: std.ArrayList(Point) = .empty;
    const push = struct {
        fn f(al: Allocator, cs: *std.ArrayList(Point), c_in: Point, w: f32, h: f32, ppx: f32, ppy: f32, b: ?[2]f32) Allocator.Error!void {
            const c = if (b) |bb| clampLabelCenterToBounds(c_in, w, h, ppx, ppy, bb) else c_in;
            try pushCenterUnique(al, cs, c);
        }
    }.f;
    try push(a, &cands, cur, lw, lh, px, py, bounds);
    const anchors = try collectAnchors(a, edge, cur, kind == .flowchart or kind == .state);
    const gt: []const f32, const ts: []const f32 = switch (kind) {
        .flowchart => .{ &.{ 0.9, 1.4, 1.9, 2.6, 3.6, 4.8, 6.2 }, &.{ 0.0, 0.25, -0.25, 0.7, -0.7, 1.3, -1.3, 2.1, -2.1, 3.2, -3.2, 4.4, -4.4 } },
        .state => .{ &.{ 0.9, 1.4, 1.9, 2.5, 3.4, 4.4, 5.8 }, &.{ 0.0, 0.18, -0.18, 0.5, -0.5, 1.0, -1.0, 1.8, -1.8, 2.8, -2.8, 4.0, -4.0, 5.5, -5.5 } },
        else => .{ &.{ 0.8, 1.3, 1.8, 2.4, 3.2, 4.2, 5.6 }, &.{ 0.0, 0.2, -0.2, 0.6, -0.6, 1.2, -1.2, 2.0, -2.0, 3.0, -3.0 } },
    };
    const lts = [_]f32{ 0.0, 0.35, -0.35, 0.8, -0.8 };
    const lns = [_]f32{ 0.0, 0.2, -0.2, 0.45, -0.45 };
    for (anchors) |an| {
        const nx = -an[3];
        const ny = an[2];
        const step_n = if (@abs(nx) > @abs(ny)) lw + px else lh + py;
        const step_t = if (@abs(an[2]) > @abs(an[3])) lw + px else lh + py;
        const ne = @abs(nx) * (lw * 0.5 + px) + @abs(ny) * (lh * 0.5 + py);
        for (ts) |tt| {
            const bx = an[0] + an[2] * step_t * tt;
            const by = an[1] + an[3] * step_t * tt;
            for (gt) |g| {
                const off = ne + g;
                try push(a, &cands, .{ bx + nx * off, by + ny * off }, lw, lh, px, py, bounds);
                try push(a, &cands, .{ bx - nx * off, by - ny * off }, lw, lh, px, py, bounds);
            }
        }
        for (lts) |tt| {
            const bx = an[0] + an[2] * step_t * tt;
            const by = an[1] + an[3] * step_t * tt;
            for (lns) |n| try push(a, &cands, .{ bx + nx * step_n * n, by + ny * step_n * n }, lw, lh, px, py, bounds);
        }
    }
    return cands.items;
}

fn tightenCenterLabelGaps(a: Allocator, edges: []EdgeLayout, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, bounds: ?[2]f32, kind: Kind, theme: *const Theme, px: f32, py: f32, locked: *const std.AutoHashMapUnmanaged(usize, void)) Allocator.Error!void {
    var any = false;
    for (edges) |e| any = any or (e.label != null and e.label_anchor != null);
    if (!any) return;
    const lim = centerLabelGapLimits(kind);
    const iterations: usize = switch (kind) {
        .state, .class => 6,
        else => 4,
    };
    var static_obs = try buildLabelObstacles(a, nodes, subgraphs, kind, theme, centerLabelNodeObstaclePad(kind, theme, px, py), @max(theme.font_size * 0.35, 3.0));
    if (kind == .flowchart) try static_obs.appendSlice(a, try buildNodeTextObstacles(a, nodes, @max(theme.font_size * 0.2, 2.0)));
    const node_count = static_obs.items.len;
    const edge_obstacles = try buildEdgeObstacles(a, edges, @max(theme.font_size * 0.35, py));
    const edge_grid = try ObstacleGrid.initEdges(a, 48.0, edge_obstacles);
    for (0..iterations) |_| {
        const OG = struct { idx: usize, gap: f32 };
        var order: std.ArrayList(OG) = .empty;
        for (edges, 0..) |e, idx| {
            if (locked.contains(idx)) continue;
            const l = e.label orelse continue;
            const c = e.label_anchor orelse continue;
            const gap = polylineRectDistance(e.points.items, padRect(c, l.width, l.height, px, py));
            if (std.math.isFinite(gap) and gap > lim[0] + 0.3) try order.append(a, .{ .idx = idx, .gap = gap });
        }
        if (order.items.len == 0) break;
        std.mem.sort(OG, order.items, {}, struct {
            fn lt(_: void, x: OG, y: OG) bool {
                return y.gap < x.gap;
            }
        }.lt);
        var moved = false;
        for (order.items) |o| {
            const idx = o.idx;
            const label = edges[idx].label orelse continue;
            const cur = edges[idx].label_anchor orelse continue;
            const pts = edges[idx].points.items;
            if (pts.len < 2) continue;
            var occupied: std.ArrayList(Rect) = .empty;
            try occupied.appendSlice(a, static_obs.items);
            for (edges, 0..) |oe, oi| {
                if (oi == idx) continue;
                const ol = oe.label orelse continue;
                const oc = oe.label_anchor orelse continue;
                try occupied.append(a, centerLabelObstacleRect(kind, oc, ol.width, ol.height, px, py));
            }
            const occ_grid = try ObstacleGrid.init(a, 48.0, occupied.items);
            const cur_rect = padRect(cur, label.width, label.height, px, py);
            const cur_anchor = edgeLabelAnchorFromPoint(&edges[idx], cur) orelse edgeLabelAnchor(&edges[idx]);
            const cur_gap = polylineRectDistance(pts, cur_rect);
            const pctx: PenaltyCtx = .{ .kind = kind, .occupied = occupied.items, .occupied_grid = &occ_grid, .node_obstacle_count = node_count, .edge_obstacles = edge_obstacles, .edge_grid = &edge_grid, .edge_idx = idx, .own_points = pts, .bounds = bounds };
            var cur_cost = labelPenalties(cur_rect, .{ cur_anchor[0], cur_anchor[1] }, label.width, label.height, &pctx);
            cur_cost[0] += centerLabelGapPenalty(cur_gap, lim[0], lim[1], lim[2]);
            const cands = try tightenCandidates(a, &edges[idx], cur, label.width, label.height, px, py, kind, bounds);
            var best_center = cur;
            var best_cost = cur_cost;
            var best_gap = cur_gap;
            for ([_]bool{ false, true }) |allow_above| {
                if (allow_above and !(@abs(best_center[0] - cur[0]) <= 0.2 and @abs(best_center[1] - cur[1]) <= 0.2)) break;
                for (cands) |c| {
                    if (@abs(c[0] - cur[0]) <= 0.2 and @abs(c[1] - cur[1]) <= 0.2) continue;
                    const r = padRect(c, label.width, label.height, px, py);
                    const gap = polylineRectDistance(pts, r);
                    if (!allow_above and std.math.isFinite(gap) and gap > lim[2]) continue;
                    const an = edgeLabelAnchorFromPoint(&edges[idx], c) orelse edgeLabelAnchor(&edges[idx]);
                    var cost = labelPenalties(r, .{ an[0], an[1] }, label.width, label.height, &pctx);
                    cost[0] += centerLabelGapPenalty(gap, lim[0], lim[1], lim[2]);
                    const dx = c[0] - cur[0];
                    const dy = c[1] - cur[1];
                    cost[1] += @sqrt(dx * dx + dy * dy) / (label.width + label.height + 1.0) * 0.35;
                    if (candidateBetter(cost, best_cost)) {
                        best_center = c;
                        best_cost = cost;
                        best_gap = gap;
                    }
                }
            }
            if (@abs(best_center[0] - cur[0]) <= 0.2 and @abs(best_center[1] - cur[1]) <= 0.2) continue;
            const gap_improved = best_gap + 0.05 < cur_gap;
            const needs = cur_gap > lim[1] + 0.2;
            const cost_improved = candidateBetter(best_cost, cur_cost);
            const acceptable = gap_improved and best_cost[0] <= cur_cost[0] + 0.35;
            if ((cost_improved and (gap_improved or needs)) or acceptable) {
                edges[idx].label_anchor = best_center;
                moved = true;
            }
        }
        if (!moved) break;
    }
}

fn centerLabelAttachmentCap(kind: Kind) ?f32 {
    return switch (kind) {
        .flowchart, .sequence, .zen_uml => null,
        .er => 12.0,
        .class => 10.0,
        .state => 11.0,
        else => 12.0,
    };
}

fn enforceCenterLabelAttachmentCaps(a: Allocator, edges: []EdgeLayout, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, bounds: ?[2]f32, kind: Kind, theme: *const Theme, px: f32, py: f32, locked: *const std.AutoHashMapUnmanaged(usize, void)) Allocator.Error!void {
    const max_gap = centerLabelAttachmentCap(kind) orelse return;
    var any = false;
    for (edges) |e| any = any or (e.label != null and e.label_anchor != null);
    if (!any) return;
    const static_obs = try buildLabelObstacles(a, nodes, subgraphs, kind, theme, centerLabelNodeObstaclePad(kind, theme, px, py), @max(theme.font_size * 0.35, 3.0));
    const nudge_w: f32 = if (kind == .er) 0.04 else 0.06;
    for (0..2) |_| {
        const rects = try a.alloc(?Rect, edges.len);
        for (edges, 0..) |e, i| rects[i] = if (e.label != null and e.label_anchor != null) padRect(e.label_anchor.?, e.label.?.width, e.label.?.height, px, py) else null;
        for (edges, 0..) |*e, idx| {
            if (locked.contains(idx)) continue;
            const label = e.label orelse continue;
            const center = e.label_anchor orelse continue;
            const cg = polylineRectDistance(e.points.items, padRect(center, label.width, label.height, px, py));
            const ccd = pointPolylineDistance(center, e.points.items);
            if (!std.math.isFinite(cg) or !std.math.isFinite(ccd)) continue;
            if (cg <= max_gap + 0.05 and ccd <= max_gap + 0.05) continue;
            const an = edgeLabelAnchorFromPoint(e, center) orelse edgeLabelAnchor(e);
            const nx = -an[3];
            const ny = an[2];
            const sign: f32 = if ((center[0] - an[0]) * nx + (center[1] - an[1]) * ny >= 0.0) 1.0 else -1.0;
            const tg = std.math.clamp(edgeTargetDistance(kind, label.height, py), 1.2, max_gap * 0.75);
            const offsets = [_]f32{ tg, @max(tg * 0.72, 0.9), @min(tg * 1.24, max_gap * 0.92), 0.0 };
            var cands: std.ArrayList(Point) = .empty;
            for (offsets) |off| for ([_]f32{ sign, -sign }) |side| {
                var c = Point{ an[0] + nx * off * side, an[1] + ny * off * side };
                if (bounds) |b| c = clampLabelCenterToBounds(c, label.width, label.height, px, py, b);
                try pushCenterUnique(a, &cands, c);
            };
            try pushCenterUnique(a, &cands, center);
            var best = center;
            var best_score = INF;
            for (cands.items) |c| {
                const r = padRect(c, label.width, label.height, px, py);
                const gap = polylineRectDistance(e.points.items, r);
                const cd = pointPolylineDistance(c, e.points.items);
                if (!std.math.isFinite(gap)) continue;
                var overlap: f32 = 0;
                for (static_obs.items) |o| overlap += overlapArea(r, o);
                for (rects, 0..) |o, oi| {
                    if (oi == idx) continue;
                    if (o) |orr| overlap += overlapArea(r, orr);
                }
                if (bounds) |b| overlap += outsideArea(r, b);
                const mdx = c[0] - center[0];
                const mdy = c[1] - center[1];
                const sc = @max(gap - max_gap, 0.0) * 32.0 + @max(cd - max_gap, 0.0) * 40.0 + @abs(gap - tg) * 0.9 + overlap * 0.06 + @sqrt(mdx * mdx + mdy * mdy) * nudge_w;
                if (sc < best_score) {
                    best_score = sc;
                    best = c;
                }
            }
            e.label_anchor = best;
        }
    }
}

fn applyComponentAssignment(a: Allocator, entries: []Entry, px: f32, py: f32, fixed: []const Rect, eo: []const EdgeObstacle, eg: *const ObstacleGrid) Allocator.Error!void {
    if (entries.len == 0) return;
    const table = try a.alloc([]Candidate, entries.len);
    for (entries, 0..) |*e, i| table[i] = try buildCandidateSet(a, e, px, py, fixed, eo, eg);
    for (try entryComponents(a, entries, px, py)) |comp| {
        if (comp.len == 0 or comp.len > 12) continue;
        const asg = (try solveAssignment(a, comp, table, entries, true)) orelse (try solveAssignment(a, comp, table, entries, false)) orelse continue;
        for (asg) |pr| entries[pr.e].current_center = pr.c;
    }
}

const Assign = struct { e: usize, c: Point };
const Beam = struct { assignments: []const [2]usize, rects: []const Rect, primary: f32, drift: f32 };

fn countWhere(cands: []const Candidate, comptime mode: u8) usize {
    var n: usize = 0;
    for (cands) |c| {
        const ok = switch (mode) {
            0 => c.center_dist <= c.center_hard_max,
            1 => c.fixed_overlap_count == 0,
            else => c.fixed_overlap_count == 0 and c.center_dist <= c.center_hard_max,
        };
        if (ok) n += 1;
    }
    return n;
}

fn solveAssignment(a: Allocator, component: []const usize, table: []const []Candidate, entries: []const Entry, band: bool) Allocator.Error!?[]Assign {
    const order = try a.dupe(usize, component);
    const Ctx = struct { table: []const []Candidate, entries: []const Entry };
    std.mem.sort(usize, order, Ctx{ .table = table, .entries = entries }, struct {
        fn lt(c: Ctx, x: usize, y: usize) bool {
            const xc = countWhere(c.table[x], 0);
            const yc = countWhere(c.table[y], 0);
            if (xc != yc) return xc < yc;
            const xs = countWhere(c.table[x], 1);
            const ys = countWhere(c.table[y], 1);
            if (xs != ys) return xs < ys;
            const xb = countWhere(c.table[x], 2);
            const yb = countWhere(c.table[y], 2);
            if (xb != yb) return xb < yb;
            if (c.table[x].len != c.table[y].len) return c.table[x].len < c.table[y].len;
            const ax = c.entries[x].label_w * c.entries[x].label_h;
            const ay = c.entries[y].label_w * c.entries[y].label_h;
            if (ax != ay) return ay < ax;
            return c.entries[x].edge_idx < c.entries[y].edge_idx;
        }
    }.lt);
    const n = component.len;
    const beam_width: usize = if (n <= 1) 1 else if (n == 2) 36 else if (n <= 4) 64 else if (n <= 6) 84 else 108;
    const cand_limit: usize = if (n <= 1) 48 else if (n <= 4) 72 else if (n <= 7) 92 else 112;
    var beam: std.ArrayList(Beam) = .empty;
    try beam.append(a, .{ .assignments = &.{}, .rects = &.{}, .primary = 0, .drift = 0 });
    for (order) |ei| {
        const cands = table[ei];
        if (cands.len == 0) return null;
        var next: std.ArrayList(Beam) = .empty;
        for (beam.items) |st| {
            for (cands[0..@min(cand_limit, cands.len)], 0..) |c, ci| {
                if (band and std.math.isFinite(c.center_dist) and c.center_dist > c.center_hard_max) continue;
                var clash = false;
                for (st.rects) |r| clash = clash or overlapArea(r, c.rect) > LABEL_OVERLAP_WIDE_THRESHOLD;
                if (clash) continue;
                var primary = st.primary + c.cost[0];
                const drift = st.drift + c.cost[1];
                if (std.math.isFinite(c.own_gap)) {
                    if (c.own_gap > 3.5) primary += (c.own_gap - 3.5) * (c.own_gap - 3.5) * 1.2;
                    if (c.own_gap < 1.1) primary += (1.1 - c.own_gap) * (1.1 - c.own_gap) * 16.0;
                    if (c.own_gap <= 0.35) primary += 48.0;
                }
                if (std.math.isFinite(c.center_dist)) {
                    const norm = @max(c.center_dist / @max(c.center_target, 1e-3), 0.0);
                    if (norm < 0.92) primary += (0.92 - norm) * (0.92 - norm) * 4.5;
                    if (c.center_dist > c.center_soft_max) primary += (c.center_dist - c.center_soft_max) * (c.center_dist - c.center_soft_max) * 2.0;
                    if (c.center_dist > c.center_hard_max) primary += (c.center_dist - c.center_hard_max) * 14.0;
                    if (norm > 1.0) primary += (norm - 1.0) * (norm - 1.0) * 0.75;
                }
                primary += @abs(c.s_norm - entries[ei].initial_s_norm) * 0.26;
                primary += @abs(c.d_signed - entries[ei].initial_d_signed) * 0.02;
                if (c.fixed_overlap_count > 0) {
                    primary += @as(f32, @floatFromInt(c.fixed_overlap_count)) * 2.0;
                    primary += c.fixed_overlap_area * 0.005;
                }
                for (st.rects) |r| {
                    const g = rectGap(r, c.rect);
                    if (g < 4.0) primary += (4.0 - g) * (4.0 - g) * 0.08;
                }
                var asg: std.ArrayList([2]usize) = .empty;
                try asg.appendSlice(a, st.assignments);
                try asg.append(a, .{ ei, ci });
                std.mem.sort([2]usize, asg.items, {}, struct {
                    fn lt(_: void, x: [2]usize, y: [2]usize) bool {
                        return x[0] < y[0];
                    }
                }.lt);
                var rects: std.ArrayList(Rect) = .empty;
                try rects.appendSlice(a, st.rects);
                try rects.append(a, c.rect);
                try next.append(a, .{ .assignments = asg.items, .rects = rects.items, .primary = primary, .drift = drift });
            }
        }
        if (next.items.len == 0) return null;
        std.mem.sort(Beam, next.items, {}, struct {
            fn lt(_: void, x: Beam, y: Beam) bool {
                if (x.primary != y.primary) return x.primary < y.primary;
                if (x.drift != y.drift) return x.drift < y.drift;
                const n_ = @min(x.assignments.len, y.assignments.len);
                for (0..n_) |i| {
                    if (x.assignments[i][0] != y.assignments[i][0]) return x.assignments[i][0] < y.assignments[i][0];
                    if (x.assignments[i][1] != y.assignments[i][1]) return x.assignments[i][1] < y.assignments[i][1];
                }
                return x.assignments.len < y.assignments.len;
            }
        }.lt);
        if (next.items.len > beam_width) next.items.len = beam_width;
        beam = next;
    }
    if (beam.items.len == 0) return null;
    const best = beam.items[0];
    const out = try a.alloc(Assign, best.assignments.len);
    for (best.assignments, 0..) |pr, i| out[i] = .{ .e = pr[0], .c = table[pr[0]][pr[1]].center };
    return out;
}

fn buildCandidateSet(a: Allocator, e: *const Entry, px: f32, py: f32, fixed: []const Rect, eo: []const EdgeObstacle, eg: *const ObstacleGrid) Allocator.Error![]Candidate {
    var centers: std.ArrayList(Point) = .empty;
    try centers.appendSlice(a, e.candidates);
    try pushCenterUnique(a, &centers, e.current_center);
    try pushCenterUnique(a, &centers, e.initial_center);
    const lim = centerDistanceLimits(e.label_h, py);
    const soft_d = @max(lim[1] - lim[0], 0.0);
    const hard_d = @max(lim[2] - lim[1], 0.0);
    var scored: std.ArrayList(Candidate) = .empty;
    for (centers.items) |c| {
        const core = fcRect(c, e.label_w, e.label_h, px, py);
        const orect = fcObstacleRect(c, e.label_w, e.label_h, px, py);
        const own = polylineRectDistance(e.edge_points, core);
        if (std.math.isFinite(own) and own > FLOWCHART_OWN_EDGE_HARD_MAX_GAP + 4.0) continue;
        const cd = pointPolylineDistance(c, e.edge_points);
        const ct = poseCenterTarget(e.edge_points, c, e.label_w, e.label_h, px, py) orelse lim[0];
        const soft = ct + soft_d;
        const hard = soft + hard_d;
        const os = overlapStats(orect, fixed, LABEL_OVERLAP_WIDE_THRESHOLD);
        var cost = refineCost(e, c, px, py, &.{}, fixed, eo, eg);
        if (std.math.isFinite(own) and own > 4.0) cost[0] += (own - 4.0) * (own - 4.0) * 2.0;
        if (std.math.isFinite(cd)) {
            if (cd > soft) cost[0] += (cd - soft) * (cd - soft) * 2.2;
            if (cd > hard) cost[0] += (cd - hard) * 18.0;
        }
        cost[0] += @as(f32, @floatFromInt(os[0])) * 1.5 + os[1] * 0.002;
        const pose = edgeRelativePose(e.edge_points, c) orelse Point{ 0.5, 0.0 };
        cost[0] += @abs(pose[0] - e.initial_s_norm) * 0.045 + @abs(pose[1] - e.initial_d_signed) * 0.012;
        try scored.append(a, .{ .center = c, .rect = orect, .cost = cost, .own_gap = own, .center_dist = cd, .center_target = ct, .center_soft_max = soft, .center_hard_max = hard, .fixed_overlap_count = os[0], .fixed_overlap_area = os[1], .s_norm = pose[0], .d_signed = pose[1] });
    }
    std.mem.sort(Candidate, scored.items, {}, struct {
        fn lt(_: void, x: Candidate, y: Candidate) bool {
            if (x.cost[0] != y.cost[0]) return x.cost[0] < y.cost[0];
            const xg = @abs(x.own_gap - OWN_EDGE_GAP_TARGET_FLOWCHART);
            const yg = @abs(y.own_gap - OWN_EDGE_GAP_TARGET_FLOWCHART);
            if (xg != yg) return xg < yg;
            if (x.cost[1] != y.cost[1]) return x.cost[1] < y.cost[1];
            if (x.center[0] != y.center[0]) return x.center[0] < y.center[0];
            return x.center[1] < y.center[1];
        }
    }.lt);
    if (scored.items.len > 220) scored.items.len = 220;
    return scored.items;
}

fn entryComponents(a: Allocator, entries: []const Entry, px: f32, py: f32) Allocator.Error![]const []const usize {
    const n = entries.len;
    const rects = try a.alloc(Rect, n);
    for (entries, 0..) |e, i| rects[i] = fcObstacleRect(e.current_center, e.label_w, e.label_h, px, py);
    const nb = try a.alloc(std.ArrayList(usize), n);
    for (nb) |*x| x.* = .empty;
    for (0..n) |i| for (i + 1..n) |j| {
        if (overlapArea(rects[i], rects[j]) > LABEL_OVERLAP_WIDE_THRESHOLD or rectGap(rects[i], rects[j]) <= 24.0) {
            try nb[i].append(a, j);
            try nb[j].append(a, i);
        }
    };
    var comps: std.ArrayList([]const usize) = .empty;
    const seen = try a.alloc(bool, n);
    @memset(seen, false);
    for (0..n) |s| {
        if (seen[s]) continue;
        seen[s] = true;
        var stack: std.ArrayList(usize) = .empty;
        var comp: std.ArrayList(usize) = .empty;
        try stack.append(a, s);
        try comp.append(a, s);
        while (stack.pop()) |idx| for (nb[idx].items) |nx| {
            if (seen[nx]) continue;
            seen[nx] = true;
            try stack.append(a, nx);
            try comp.append(a, nx);
        };
        std.mem.sort(usize, comp.items, {}, std.sort.asc(usize));
        try comps.append(a, comp.items);
    }
    return comps.items;
}

fn edgeRelativePose(points: []const Point, center: Point) ?Point {
    if (points.len < 2) return null;
    var total: f32 = 0;
    for (0..points.len - 1) |i| total += @sqrt((points[i + 1][0] - points[i][0]) * (points[i + 1][0] - points[i][0]) + (points[i + 1][1] - points[i][1]) * (points[i + 1][1] - points[i][1]));
    if (total <= 1e-6) return null;
    var best_d2 = INF;
    var best_proj = center;
    var best_t: f32 = 0;
    var best_prefix: f32 = 0;
    var best_len: f32 = 1;
    var bdx: f32 = 1;
    var bdy: f32 = 0;
    var prefix: f32 = 0;
    for (0..points.len - 1) |i| {
        const p1 = points[i];
        const p2 = points[i + 1];
        const dx = p2[0] - p1[0];
        const dy = p2[1] - p1[1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len <= 1e-6) continue;
        const tt = std.math.clamp(((center[0] - p1[0]) * dx + (center[1] - p1[1]) * dy) / (len * len), 0.0, 1.0);
        const proj = Point{ p1[0] + dx * tt, p1[1] + dy * tt };
        const d2 = (center[0] - proj[0]) * (center[0] - proj[0]) + (center[1] - proj[1]) * (center[1] - proj[1]);
        if (d2 < best_d2) {
            best_d2 = d2;
            best_proj = proj;
            best_t = tt;
            best_prefix = prefix;
            best_len = len;
            bdx = dx / len;
            bdy = dy / len;
        }
        prefix += len;
    }
    const s = std.math.clamp((best_prefix + best_t * best_len) / total, 0.0, 1.0);
    const d = (center[0] - best_proj[0]) * -bdy + (center[1] - best_proj[1]) * bdx;
    return .{ s, d };
}

fn centerDistanceLimits(lh: f32, py: f32) [3]f32 {
    const target = @max(edgeTargetDistance(.flowchart, lh, py), 2.0);
    const soft = target + std.math.clamp(lh * 0.18 + py * 0.5 + 1.8, 3.0, 6.0);
    const hard = soft + std.math.clamp(lh * 0.26 + py * 0.8 + 3.2, 5.0, 10.0);
    return .{ target, soft, hard };
}

fn nearestSegmentTangent(points: []const Point, center: Point) ?Point {
    if (points.len < 2) return null;
    var best_d2 = INF;
    var best: ?Point = null;
    for (0..points.len - 1) |i| {
        const p1 = points[i];
        const p2 = points[i + 1];
        const dx = p2[0] - p1[0];
        const dy = p2[1] - p1[1];
        const l2 = dx * dx + dy * dy;
        if (l2 <= 1e-6) continue;
        const tt = std.math.clamp(((center[0] - p1[0]) * dx + (center[1] - p1[1]) * dy) / l2, 0.0, 1.0);
        const qx = p1[0] + dx * tt;
        const qy = p1[1] + dy * tt;
        const d2 = (center[0] - qx) * (center[0] - qx) + (center[1] - qy) * (center[1] - qy);
        if (d2 < best_d2) {
            best_d2 = d2;
            const l = @max(@sqrt(l2), 1e-3);
            best = .{ dx / l, dy / l };
        }
    }
    return best;
}

fn poseCenterTarget(points: []const Point, center: Point, lw: f32, lh: f32, px: f32, py: f32) ?f32 {
    const tg = nearestSegmentTangent(points, center) orelse return null;
    const nx = -tg[1];
    const ny = tg[0];
    const hw = lw * 0.5 + px;
    const hh = lh * 0.5 + py;
    const oe = @abs(nx) * hw + @abs(ny) * hh;
    return edgeTargetDistance(.flowchart, lh, py) + @max(oe - hh, 0.0) * 0.45;
}

fn poseCenterHardMax(points: []const Point, center: Point, lw: f32, lh: f32, px: f32, py: f32) f32 {
    const lim = centerDistanceLimits(lh, py);
    const target = poseCenterTarget(points, center, lw, lh, px, py) orelse lim[0];
    return target + @max(lim[1] - lim[0], 0.0) + @max(lim[2] - lim[1], 0.0);
}

fn pushCenterUnique(a: Allocator, centers: *std.ArrayList(Point), c: Point) Allocator.Error!void {
    for (centers.items) |e| if (@abs(e[0] - c[0]) <= 0.35 and @abs(e[1] - c[1]) <= 0.35) return;
    try centers.append(a, c);
}

fn pathSpan(points: []const Point) Point {
    if (points.len == 0) return .{ 0, 0 };
    var mnx = INF;
    var mny = INF;
    var mxx = -INF;
    var mxy = -INF;
    for (points) |p| {
        mnx = @min(mnx, p[0]);
        mny = @min(mny, p[1]);
        mxx = @max(mxx, p[0]);
        mxy = @max(mxy, p[1]);
    }
    return .{ @max(mxx - mnx, 0.0), @max(mxy - mny, 0.0) };
}

fn entryOverlapScore(entries: []const Entry, px: f32, py: f32) OverlapScore {
    var s: OverlapScore = .{ .count = 0, .total = 0, .max = 0 };
    for (entries, 0..) |ei, i| for (entries[i + 1 ..]) |ej| {
        const ov = overlapArea(fcRect(ei.current_center, ei.label_w, ei.label_h, px, py), fcRect(ej.current_center, ej.label_w, ej.label_h, px, py));
        if (ov > LABEL_OVERLAP_WIDE_THRESHOLD) {
            s.count += 1;
            s.total += ov;
            s.max = @max(s.max, ov);
        }
    };
    return s;
}

const Pts8 = struct {
    items: [8]Point = undefined,
    len: usize = 0,
    fn slice(self: *const Pts8) []const Point {
        return self.items[0..self.len];
    }
};

fn pairSeparationCandidates(e: *const Entry, blocking: Rect, px: f32, py: f32, bounds: ?[2]f32) Pts8 {
    var out: Pts8 = .{};
    const hw = e.label_w * 0.5 + px + FLOWCHART_LABEL_CLEARANCE_PAD;
    const hh = e.label_h * 0.5 + py + FLOWCHART_LABEL_CLEARANCE_PAD;
    const gap: f32 = 2.0;
    const lx = blocking[0] - gap - hw;
    const rx = blocking[0] + blocking[2] + gap + hw;
    const ay = blocking[1] - gap - hh;
    const by = blocking[1] + blocking[3] + gap + hh;
    const push = struct {
        fn f(o: *Pts8, c_in: Point, ent: *const Entry, ppx: f32, ppy: f32, b: ?[2]f32) void {
            const c = if (b) |bb| clampLabelCenterToBounds(c_in, ent.label_w, ent.label_h, ppx, ppy, bb) else c_in;
            for (o.items[0..o.len]) |x| if (@abs(x[0] - c[0]) <= 0.35 and @abs(x[1] - c[1]) <= 0.35) return;
            o.items[o.len] = c;
            o.len += 1;
        }
    }.f;
    for ([_]f32{ e.current_center[1], e.initial_center[1] }) |y| {
        push(&out, .{ lx, y }, e, px, py, bounds);
        push(&out, .{ rx, y }, e, px, py, bounds);
    }
    for ([_]f32{ e.current_center[0], e.initial_center[0] }) |x| {
        push(&out, .{ x, ay }, e, px, py, bounds);
        push(&out, .{ x, by }, e, px, py, bounds);
    }
    return out;
}

fn flowchartCenterLabelCandidates(a: Allocator, edge: *const EdgeLayout, init_c: Point, lw: f32, lh: f32, px: f32, py: f32, snp: f32, stp: f32, bounds: ?[2]f32) Allocator.Error![]const Point {
    var cands: std.ArrayList(Point) = .empty;
    const push = struct {
        fn f(al: Allocator, cs: *std.ArrayList(Point), c_in: Point, w: f32, h: f32, ppx: f32, ppy: f32, b: ?[2]f32) Allocator.Error!void {
            const c = if (b) |bb| clampLabelCenterToBounds(c_in, w, h, ppx, ppy, bb) else c_in;
            try pushCenterUnique(al, cs, c);
        }
    }.f;
    try push(a, &cands, init_c, lw, lh, px, py, bounds);
    var anchors = try collectAnchors(a, edge, init_c, true);
    if (edgeRelativePose(edge.points.items, init_c)) |pose| {
        const SA = struct { an: Anchor, d: f32 };
        const sa = try a.alloc(SA, anchors.len);
        for (anchors, 0..) |an, i| {
            const s = if (edgeRelativePose(edge.points.items, .{ an[0], an[1] })) |p| p[0] else pose[0];
            sa[i] = .{ .an = an, .d = @abs(s - pose[0]) };
        }
        std.mem.sort(SA, sa, {}, struct {
            fn lt(_: void, x: SA, y: SA) bool {
                return x.d < y.d;
            }
        }.lt);
        var filtered: std.ArrayList(Anchor) = .empty;
        for (sa) |s| {
            if (s.d <= 0.18 or filtered.items.len < 3) try filtered.append(a, s.an);
            if (filtered.items.len >= 6) break;
        }
        if (filtered.items.len > 0) anchors = filtered.items;
    }
    const ns = [_]f32{ 0.45, -0.45, 0.8, -0.8, 1.2, -1.2, 0.25, -0.25, 1.8, -1.8, 2.5, -2.5, 3.4, -3.4, 4.4, -4.4, 5.6, -5.6, 7.0, -7.0, 0.0 };
    const ts = [_]f32{ 0.0, 0.22, -0.22, 0.55, -0.55, 1.0, -1.0, 1.6, -1.6, 2.3, -2.3, 2.8, -2.8 };
    for (anchors) |an| {
        const nx = -an[3];
        const ny = an[2];
        const step_n = if (@abs(nx) > @abs(ny)) lw + px + snp else lh + py + snp;
        const step_t = if (@abs(an[2]) > @abs(an[3])) lw + px + stp else lh + py + stp;
        for (ts) |tt| {
            const bx = an[0] + an[2] * step_t * tt;
            const by = an[1] + an[3] * step_t * tt;
            for (ns) |n| try push(a, &cands, .{ bx + nx * step_n * n, by + ny * step_n * n }, lw, lh, px, py, bounds);
        }
    }
    return cands.items;
}

fn refineCost(e: *const Entry, c: Point, px: f32, py: f32, others: []const Rect, fixed: []const Rect, eo: []const EdgeObstacle, eg: *const ObstacleGrid) Cost {
    const core = fcRect(c, e.label_w, e.label_h, px, py);
    const orect = fcObstacleRect(c, e.label_w, e.label_h, px, py);
    const area = @max(e.label_w * e.label_h, 1.0);
    var ov_sum: f32 = 0;
    var ov_count: u32 = 0;
    var near_sum: f32 = 0;
    for (others) |o| {
        const ov = overlapArea(orect, o);
        if (ov > 0.0) {
            ov_sum += ov;
            ov_count += 1;
            continue;
        }
        const g = rectGap(orect, o);
        if (g < FLOWCHART_LABEL_SOFT_GAP) near_sum += FLOWCHART_LABEL_SOFT_GAP - g;
    }
    var fx_area: f32 = 0;
    var fx_count: u32 = 0;
    var fx_near: f32 = 0;
    for (fixed) |o| {
        const ov = overlapArea(orect, o);
        if (ov > 0.0) {
            fx_area += ov;
            fx_count += 1;
            continue;
        }
        const g = rectGap(orect, o);
        if (g < FLOWCHART_LABEL_SOFT_GAP) fx_near += FLOWCHART_LABEL_SOFT_GAP - g;
    }
    const own = polylineRectDistance(e.edge_points, core);
    var own_pen: f32 = 0;
    const pose = edgeRelativePose(e.edge_points, c);
    if (pose) |p| {
        const sd = @abs(p[0] - e.initial_s_norm);
        own_pen += sd * sd * 2.2;
        const nd = @abs(p[1] - e.initial_d_signed) / @max(e.label_h + 2.0 * py, 1.0);
        own_pen += nd * nd * 1.6;
    }
    if (std.math.isFinite(own)) {
        const tg = @max(OWN_EDGE_GAP_TARGET_FLOWCHART, 1e-3);
        if (own < tg) {
            const sh = (tg - own) / tg;
            own_pen += sh * sh * 7.8;
            if (own < 1.0) own_pen += (1.0 - own) * (1.0 - own) * 8.0;
        } else {
            const ex = (own - tg) / tg;
            own_pen += ex * ex * 1.35;
            if (ex > 2.0) own_pen += (ex - 2.0) * 2.8;
        }
        if (own > FLOWCHART_OWN_EDGE_SOFT_MAX_GAP) own_pen += (own - FLOWCHART_OWN_EDGE_SOFT_MAX_GAP) * (own - FLOWCHART_OWN_EDGE_SOFT_MAX_GAP) * FLOWCHART_OWN_EDGE_SOFT_MAX_GAP_WEIGHT;
        if (own > FLOWCHART_OWN_EDGE_HARD_MAX_GAP) own_pen += (own - FLOWCHART_OWN_EDGE_HARD_MAX_GAP) * FLOWCHART_OWN_EDGE_HARD_MAX_GAP_WEIGHT;
        if (own <= 0.35) own_pen += 80.0;
    }
    var fe_area: f32 = 0;
    var fe_touch = false;
    var fe_near: f32 = 0;
    var qit = eg.query(orect);
    while (qit.next()) |oi| {
        const ob = eo[oi];
        if (ob.idx == e.edge_idx) continue;
        const ov = overlapArea(orect, ob.rect);
        if (ov > 0.0) {
            fe_area += ov;
            fe_touch = true;
            continue;
        }
        const g = rectGap(orect, ob.rect);
        if (g < FLOWCHART_LABEL_SOFT_GAP) fe_near += FLOWCHART_LABEL_SOFT_GAP - g;
    }
    const fe_pen = (fe_area / area) * 48.0 + @as(f32, if (fe_touch) 130.0 else 0.0) + fe_near * 6.5;
    const ecd = pointPolylineDistance(c, e.edge_points);
    const lim = centerDistanceLimits(e.label_h, py);
    const et = poseCenterTarget(e.edge_points, c, e.label_w, e.label_h, px, py) orelse lim[0];
    const soft = et + @max(lim[1] - lim[0], 0.0);
    const hard = soft + @max(lim[2] - lim[1], 0.0);
    var ec_pen: f32 = 0;
    if (ecd < et) {
        const sh = (et - ecd) / @max(et, 1e-3);
        ec_pen += sh * sh * 2.4;
    }
    if (ecd > et) {
        const ex = (ecd - et) / @max(et, 1e-3);
        ec_pen += ex * ex * 1.3;
    }
    if (ecd > soft) ec_pen += (ecd - soft) * (ecd - soft) * 2.8;
    if (ecd > hard) ec_pen += (ecd - hard) * 20.0;
    if (pose) |p| {
        const plen = @max(polylinePathLength(e.edge_points), 1.0);
        const tsp = @abs(p[0] - e.initial_s_norm) * plen;
        const tsoft = @min(std.math.clamp(e.label_w * 0.95 + e.label_h * 0.35 + 8.0, 10.0, 28.0), plen * 0.28 + 2.0);
        const thard = @max(tsoft * 2.2, tsoft + 10.0);
        if (tsp > tsoft) {
            const r = (tsp - tsoft) / @max(tsoft, 1.0);
            ec_pen += r * r * 12.0;
        }
        if (tsp > thard) ec_pen += (tsp - thard) * 0.45;
        ec_pen += @abs(p[1] - e.initial_d_signed) * 0.03;
    }
    const primary = @as(f32, @floatFromInt(fx_count)) * 130.0 + (fx_area / area) * 48.0 + fx_near * 6.0 +
        @as(f32, @floatFromInt(ov_count)) * 115.0 + (ov_sum / area) * 42.0 + near_sum * 5.0 + own_pen + fe_pen + ec_pen;
    const dx = c[0] - e.initial_center[0];
    const dy = c[1] - e.initial_center[1];
    return .{ primary, @sqrt(dx * dx + dy * dy) / (e.label_w + e.label_h + 1.0) };
}

const EndpointCtx = struct {
    kind: Kind,
    offset: f32,
    occupied: []const Rect,
    occupied_grid: *const ObstacleGrid,
    node_obstacle_count: usize,
    edge_obstacles: []const EdgeObstacle,
    edge_grid: *const ObstacleGrid,
    bounds: ?[2]f32,
};

fn resolveEndpointLabels(a: Allocator, edges: []EdgeLayout, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, bounds: ?[2]f32, kind: Kind, theme: *const Theme) Allocator.Error!void {
    var has = false;
    for (edges) |e| has = has or e.start_label != null or e.end_label != null;
    if (!has) return;
    const cp = edgeLabelPadding(kind);
    const node_pad: f32 = if (kind == .class) @max(theme.font_size * 0.12, 1.5) else @max(theme.font_size * 0.45, @max(cp[0], cp[1]));
    const edge_pad = @max(theme.font_size * 0.35, cp[1]);
    const sub_pad = @max(theme.font_size * 0.35, 3.0);
    const ep = endpointLabelPadding(kind);
    const edge_obstacles = try buildEdgeObstacles(a, edges, edge_pad);
    const edge_grid = try ObstacleGrid.initEdges(a, 48.0, edge_obstacles);
    const enp: f32 = switch (kind) {
        .class => node_pad * 0.4,
        .state => node_pad * 0.65,
        else => node_pad,
    };
    var occupied = try buildLabelObstacles(a, nodes, subgraphs, kind, theme, enp, sub_pad);
    const node_count = occupied.items.len;
    for (edges) |e| {
        const l = e.label orelse continue;
        const c = e.label_anchor orelse continue;
        const r = padRect(c, l.width, l.height, cp[0], cp[1]);
        try occupied.append(a, if (kind == .flowchart) inflateRect(r, FLOWCHART_LABEL_CLEARANCE_PAD) else r);
    }
    const offset: f32 = switch (kind) {
        .class => @max(theme.font_size * 0.18, 2.8),
        .flowchart => @max(theme.font_size * 0.75, 9.0),
        else => @max(theme.font_size * 0.6, 8.0),
    };
    const scale: f32 = if (kind == .state) @min(theme.font_size * 0.85 / theme.font_size, 1.0) else 1.0;
    var grid = try ObstacleGrid.init(a, 48.0, occupied.items);
    for (0..edges.len) |idx| {
        for ([_]bool{ true, false }) |start| {
            const label = (if (start) edges[idx].start_label else edges[idx].end_label) orelse continue;
            const lw = label.width * scale;
            const lh = label.height * scale;
            const ctx: EndpointCtx = .{ .kind = kind, .offset = offset, .occupied = occupied.items, .occupied_grid = &grid, .node_obstacle_count = node_count, .edge_obstacles = edge_obstacles, .edge_grid = &edge_grid, .bounds = bounds };
            const pos = endpointLabelPositionWithAvoid(&edges[idx], idx, start, lw, lh, ep[0], ep[1], &ctx) orelse continue;
            if (start) edges[idx].start_label_anchor = pos else edges[idx].end_label_anchor = pos;
            const r = Rect{ pos[0] - lw / 2.0 - ep[0], pos[1] - lh / 2.0 - ep[1], lw + ep[0] * 2.0, lh + ep[1] * 2.0 };
            const orr = if (kind == .flowchart) inflateRect(r, FLOWCHART_LABEL_CLEARANCE_PAD) else r;
            try grid.insert(a, occupied.items.len, orr);
            try occupied.append(a, orr);
        }
    }
}

fn polylinePathLength(points: []const Point) f32 {
    var total: f32 = 0;
    if (points.len < 2) return 0;
    for (0..points.len - 1) |i| {
        const dx = points[i + 1][0] - points[i][0];
        const dy = points[i + 1][1] - points[i][1];
        total += @sqrt(dx * dx + dy * dy);
    }
    return total;
}

fn pointSegmentDistance(p: Point, a: Point, b: Point) f32 {
    const vx = b[0] - a[0];
    const vy = b[1] - a[1];
    const l2 = vx * vx + vy * vy;
    if (l2 <= 1e-6) return @sqrt((p[0] - a[0]) * (p[0] - a[0]) + (p[1] - a[1]) * (p[1] - a[1]));
    const tt = std.math.clamp(((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / l2, 0.0, 1.0);
    const dx = p[0] - (a[0] + vx * tt);
    const dy = p[1] - (a[1] + vy * tt);
    return @sqrt(dx * dx + dy * dy);
}

fn pointPolylineDistance(p: Point, points: []const Point) f32 {
    if (points.len < 2) return 0.0;
    var best = INF;
    for (0..points.len - 1) |i| best = @min(best, pointSegmentDistance(p, points[i], points[i + 1]));
    return if (std.math.isFinite(best)) best else 0.0;
}

fn pointRectDistance(p: Point, r: Rect) f32 {
    const dx: f32 = if (p[0] < r[0]) r[0] - p[0] else if (p[0] > r[0] + r[2]) p[0] - (r[0] + r[2]) else 0.0;
    const dy: f32 = if (p[1] < r[1]) r[1] - p[1] else if (p[1] > r[1] + r[3]) p[1] - (r[1] + r[3]) else 0.0;
    return @sqrt(dx * dx + dy * dy);
}

fn pointInsideRect(p: Point, r: Rect) bool {
    return p[0] >= r[0] and p[0] <= r[0] + r[2] and p[1] >= r[1] and p[1] <= r[1] + r[3];
}

fn orientation(a: Point, b: Point, c: Point) f32 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

fn pointOnSegment(p: Point, a: Point, b: Point, eps: f32) bool {
    return p[0] >= @min(a[0], b[0]) - eps and p[0] <= @max(a[0], b[0]) + eps and p[1] >= @min(a[1], b[1]) - eps and p[1] <= @max(a[1], b[1]) + eps;
}

fn segmentsIntersect(a: Point, b: Point, c: Point, d: Point) bool {
    const eps: f32 = 1e-4;
    const o1 = orientation(a, b, c);
    const o2 = orientation(a, b, d);
    const o3 = orientation(c, d, a);
    const o4 = orientation(c, d, b);
    if (((o1 > eps and o2 < -eps) or (o1 < -eps and o2 > eps)) and ((o3 > eps and o4 < -eps) or (o3 < -eps and o4 > eps))) return true;
    if (@abs(o1) <= eps and pointOnSegment(c, a, b, eps)) return true;
    if (@abs(o2) <= eps and pointOnSegment(d, a, b, eps)) return true;
    if (@abs(o3) <= eps and pointOnSegment(a, c, d, eps)) return true;
    if (@abs(o4) <= eps and pointOnSegment(b, c, d, eps)) return true;
    return false;
}

fn segmentIntersectsRect(a: Point, b: Point, r: Rect) bool {
    if (pointInsideRect(a, r) or pointInsideRect(b, r)) return true;
    const c = [4]Point{ .{ r[0], r[1] }, .{ r[0] + r[2], r[1] }, .{ r[0] + r[2], r[1] + r[3] }, .{ r[0], r[1] + r[3] } };
    for (0..4) |i| if (segmentsIntersect(a, b, c[i], c[(i + 1) % 4])) return true;
    return false;
}

fn segmentRectDistance(a: Point, b: Point, r: Rect) f32 {
    if (segmentIntersectsRect(a, b, r)) return 0.0;
    var best = @min(pointRectDistance(a, r), pointRectDistance(b, r));
    for ([_]Point{ .{ r[0], r[1] }, .{ r[0] + r[2], r[1] }, .{ r[0] + r[2], r[1] + r[3] }, .{ r[0], r[1] + r[3] } }) |c| best = @min(best, pointSegmentDistance(c, a, b));
    return best;
}

fn polylineRectDistance(points: []const Point, r: Rect) f32 {
    if (points.len < 2) return INF;
    var best = INF;
    for (0..points.len - 1) |i| {
        best = @min(best, segmentRectDistance(points[i], points[i + 1], r));
        if (best <= 0.0) break;
    }
    return best;
}

fn subgraphLabelRect(sub: *const SubgraphLayout, kind: Kind, theme: *const Theme) ?Rect {
    if (util.trim(sub.label).len == 0) return null;
    const w = sub.label_block.width;
    const h = sub.label_block.height;
    if (w <= 0.0 or h <= 0.0) return null;
    if (kind == .state) {
        const header = @max(h + theme.font_size * 0.75, theme.font_size * 1.4);
        const lpx = @max(theme.font_size * 0.6, h * 0.35);
        return .{ sub.x + lpx, sub.y + header / 2.0 - h / 2.0, w, h };
    }
    return .{ sub.x + sub.width / 2.0 - w / 2.0, sub.y + 12.0, w, h };
}

fn buildLabelObstacles(a: Allocator, nodes: *const NodeMap, subgraphs: []const SubgraphLayout, kind: Kind, theme: *const Theme, node_pad: f32, sub_pad: f32) Allocator.Error!std.ArrayList(Rect) {
    var occ: std.ArrayList(Rect) = .empty;
    for (nodes.values()) |n| {
        if (n.anchor_subgraph != null or n.hidden) continue;
        try occ.append(a, .{ n.x - node_pad, n.y - node_pad, n.width + 2.0 * node_pad, n.height + 2.0 * node_pad });
    }
    for (subgraphs) |*s| if (subgraphLabelRect(s, kind, theme)) |r| try occ.append(a, .{ r[0] - sub_pad, r[1] - sub_pad, r[2] + sub_pad * 2.0, r[3] + sub_pad * 2.0 });
    return occ;
}

fn buildNodeTextObstacles(a: Allocator, nodes: *const NodeMap, pad: f32) Allocator.Error![]const Rect {
    var occ: std.ArrayList(Rect) = .empty;
    for (nodes.values()) |n| {
        if (n.anchor_subgraph != null or n.hidden) continue;
        if (n.label.width <= 0.0 or n.label.height <= 0.0) continue;
        const cx = n.x + n.width * 0.5;
        const cy = n.y + n.height * 0.5;
        try occ.append(a, .{ cx - n.label.width * 0.5 - pad, cy - n.label.height * 0.5 - pad, n.label.width + pad * 2.0, n.label.height + pad * 2.0 });
    }
    return occ.items;
}

fn buildEdgeObstacles(a: Allocator, edges: []const EdgeLayout, pad: f32) Allocator.Error![]const EdgeObstacle {
    var out: std.ArrayList(EdgeObstacle) = .empty;
    for (edges, 0..) |e, idx| {
        const p = e.points.items;
        if (p.len < 2) continue;
        for (0..p.len - 1) |i| {
            const mnx = @min(p[i][0], p[i + 1][0]) - pad;
            const mxx = @max(p[i][0], p[i + 1][0]) + pad;
            const mny = @min(p[i][1], p[i + 1][1]) - pad;
            const mxy = @max(p[i][1], p[i + 1][1]) + pad;
            try out.append(a, .{ .idx = idx, .rect = .{ mnx, mny, mxx - mnx, mxy - mny } });
        }
    }
    return out.items;
}

fn edgeLabelAnchor(edge: *const EdgeLayout) Anchor {
    const p = edge.points.items;
    if (p.len < 2) return .{ 0, 0, 1, 0 };
    const sc = p.len - 1;
    var best_idx: ?usize = null;
    var best_len: f32 = 0;
    const s0: usize, const s1: usize = if (sc >= 3) .{ 1, sc - 1 } else .{ 0, sc };
    for (s0..s1) |i| {
        const dx = p[i + 1][0] - p[i][0];
        const dy = p[i + 1][1] - p[i][1];
        const l = dx * dx + dy * dy;
        if (l > best_len) {
            best_len = l;
            best_idx = i;
        }
    }
    if (best_idx == null) for (0..sc) |i| {
        const dx = p[i + 1][0] - p[i][0];
        const dy = p[i + 1][1] - p[i][1];
        const l = dx * dx + dy * dy;
        if (l > best_len) {
            best_len = l;
            best_idx = i;
        }
    };
    const i = best_idx orelse 0;
    const dx = p[i + 1][0] - p[i][0];
    const dy = p[i + 1][1] - p[i][1];
    const len = @max(@sqrt(dx * dx + dy * dy), 1e-3);
    return .{ (p[i][0] + p[i + 1][0]) / 2.0, (p[i][1] + p[i + 1][1]) / 2.0, dx / len, dy / len };
}

fn innerRange(sc: usize) [2]usize {
    var s0: usize = 0;
    var s1: usize = sc;
    if (sc >= 3) {
        s0 = 1;
        s1 = sc - 1;
    }
    if (s0 >= s1) return .{ 0, sc };
    return .{ s0, s1 };
}

fn edgeLabelAnchorAtFraction(edge: *const EdgeLayout, frac: f32) ?Anchor {
    const p = edge.points.items;
    if (p.len < 2) return null;
    const r = innerRange(p.len - 1);
    var total: f32 = 0;
    for (r[0]..r[1]) |i| total += @sqrt((p[i + 1][0] - p[i][0]) * (p[i + 1][0] - p[i][0]) + (p[i + 1][1] - p[i][1]) * (p[i + 1][1] - p[i][1]));
    if (total <= 1e-3) return edgeLabelAnchor(edge);
    var remaining = total * std.math.clamp(frac, 0.0, 1.0);
    for (r[0]..r[1]) |i| {
        const dx = p[i + 1][0] - p[i][0];
        const dy = p[i + 1][1] - p[i][1];
        const sl = @sqrt(dx * dx + dy * dy);
        if (sl <= 1e-6) continue;
        if (remaining <= sl) {
            const al = std.math.clamp(remaining / sl, 0.0, 1.0);
            return .{ p[i][0] + dx * al, p[i][1] + dy * al, dx / sl, dy / sl };
        }
        remaining -= sl;
    }
    return edgeLabelAnchor(edge);
}

fn edgeLabelAnchorFromPoint(edge: *const EdgeLayout, pt: Point) ?Anchor {
    const p = edge.points.items;
    if (p.len < 2) return null;
    var best_d2 = INF;
    var proj: ?Point = null;
    var dir: Point = .{ 0, 0 };
    for (0..p.len - 1) |i| {
        const dx = p[i + 1][0] - p[i][0];
        const dy = p[i + 1][1] - p[i][1];
        const l2 = dx * dx + dy * dy;
        if (l2 <= 1e-6) continue;
        const tt = std.math.clamp(((pt[0] - p[i][0]) * dx + (pt[1] - p[i][1]) * dy) / l2, 0.0, 1.0);
        const qx = p[i][0] + dx * tt;
        const qy = p[i][1] + dy * tt;
        const d2 = (pt[0] - qx) * (pt[0] - qx) + (pt[1] - qy) * (pt[1] - qy);
        if (d2 < best_d2) {
            best_d2 = d2;
            proj = .{ qx, qy };
            dir = .{ dx, dy };
        }
    }
    const q = proj orelse return null;
    const len = @max(@sqrt(dir[0] * dir[0] + dir[1] * dir[1]), 1e-3);
    return .{ q[0], q[1], dir[0] / len, dir[1] / len };
}

fn edgeSegmentAnchors(a: Allocator, edge: *const EdgeLayout, max_count: usize) Allocator.Error![]const Anchor {
    const p = edge.points.items;
    if (p.len < 2 or max_count == 0) return &.{};
    const r = innerRange(p.len - 1);
    const S = struct { len: f32, an: Anchor };
    var scored: std.ArrayList(S) = .empty;
    for (r[0]..r[1]) |i| {
        const dx = p[i + 1][0] - p[i][0];
        const dy = p[i + 1][1] - p[i][1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len <= 1.0) continue;
        try scored.append(a, .{ .len = len, .an = .{ (p[i][0] + p[i + 1][0]) * 0.5, (p[i][1] + p[i + 1][1]) * 0.5, dx / len, dy / len } });
    }
    std.mem.sort(S, scored.items, {}, struct {
        fn lt(_: void, x: S, y: S) bool {
            return y.len < x.len;
        }
    }.lt);
    const out = try a.alloc(Anchor, @min(max_count, scored.items.len));
    for (out, 0..) |*o, i| o.* = scored.items[i].an;
    return out;
}

const Anchors2 = struct {
    items: [2]Anchor = undefined,
    len: usize = 0,
    fn slice(self: *const Anchors2) []const Anchor {
        return self.items[0..self.len];
    }
};

fn edgeTerminalSegmentAnchors(edge: *const EdgeLayout, max_count: usize) Anchors2 {
    var out: Anchors2 = .{};
    const p = edge.points.items;
    if (p.len < 2 or max_count == 0) return out;
    const sc = p.len - 1;
    for ([_]usize{ 0, sc -| 1 }) |si| {
        if (out.len >= max_count) break;
        if (si >= sc) continue;
        const dx = p[si + 1][0] - p[si][0];
        const dy = p[si + 1][1] - p[si][1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len <= 8.0) continue;
        const an = Anchor{ (p[si][0] + p[si + 1][0]) * 0.5, (p[si][1] + p[si + 1][1]) * 0.5, dx / len, dy / len };
        var dup = false;
        for (out.items[0..out.len]) |e| dup = dup or anchorNear(e, an);
        if (!dup) {
            out.items[out.len] = an;
            out.len += 1;
        }
    }
    return out;
}

fn anchorNear(x: Anchor, y: Anchor) bool {
    return @abs(x[0] - y[0]) <= LABEL_ANCHOR_POS_EPS and @abs(x[1] - y[1]) <= LABEL_ANCHOR_POS_EPS and
        @abs(x[2] - y[2]) <= LABEL_ANCHOR_DIR_EPS and @abs(x[3] - y[3]) <= LABEL_ANCHOR_DIR_EPS;
}

fn pushAnchorUnique(a: Allocator, anchors: *std.ArrayList(Anchor), c: Anchor) Allocator.Error!void {
    for (anchors.items) |e| if (anchorNear(e, c)) return;
    try anchors.append(a, c);
}

fn edgeLabelBundleFractions(a: Allocator, edges: []const EdgeLayout) Allocator.Error![]?f32 {
    const out = try a.alloc(?f32, edges.len);
    @memset(out, null);
    var map: std.StringArrayHashMapUnmanaged(std.ArrayList(usize)) = .empty;
    for (edges, 0..) |e, idx| {
        if (e.label == null) continue;
        const key = try std.fmt.allocPrint(a, "{s}\x00{s}", .{ e.from, e.to });
        const gop = try map.getOrPut(a, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, idx);
    }
    for (map.values()) |list| {
        if (list.items.len <= 1) continue;
        const count = list.items.len;
        for (list.items, 0..) |ei, rank| {
            const f: f32 = if (count == 2) (if (rank == 0) 0.34 else 0.66) else 0.16 + 0.68 * (@as(f32, @floatFromInt(rank)) / @as(f32, @floatFromInt(count - 1)));
            out[ei] = std.math.clamp(f, 0.05, 0.95);
        }
    }
    return out;
}

fn overlapArea(x: Rect, y: Rect) f32 {
    const x0 = @max(x[0], y[0]);
    const y0 = @max(x[1], y[1]);
    const x1 = @min(x[0] + x[2], y[0] + y[2]);
    const y1 = @min(x[1] + x[3], y[1] + y[3]);
    return @max(x1 - x0, 0.0) * @max(y1 - y0, 0.0);
}

fn overlapStats(r: Rect, obstacles: []const Rect, threshold: f32) struct { u32, f32 } {
    var c: u32 = 0;
    var area: f32 = 0;
    for (obstacles) |o| {
        const ov = overlapArea(r, o);
        if (ov > threshold) {
            c += 1;
            area += ov;
        }
    }
    return .{ c, area };
}

fn rectGap(x: Rect, y: Rect) f32 {
    const dx: f32 = if (x[0] + x[2] < y[0]) y[0] - (x[0] + x[2]) else if (y[0] + y[2] < x[0]) x[0] - (y[0] + y[2]) else 0.0;
    const dy: f32 = if (x[1] + x[3] < y[1]) y[1] - (x[1] + x[3]) else if (y[1] + y[3] < x[1]) x[1] - (y[1] + y[3]) else 0.0;
    return @sqrt(dx * dx + dy * dy);
}

fn inflateRect(r: Rect, pad: f32) Rect {
    if (pad <= 0.0) return r;
    return .{ r[0] - pad, r[1] - pad, r[2] + pad * 2.0, r[3] + pad * 2.0 };
}

fn outsideArea(r: Rect, b: [2]f32) f32 {
    const area = @max(r[2], 0.0) * @max(r[3], 0.0);
    if (area <= 0.0) return 0.0;
    const iw = @max(@min(r[0] + r[2], b[0]) - @max(r[0], 0.0), 0.0);
    const ih = @max(@min(r[1] + r[3], b[1]) - @max(r[1], 0.0), 0.0);
    return area - iw * ih;
}

pub fn clampLabelCenterToBounds(c: Point, lw: f32, lh: f32, px: f32, py: f32, b: [2]f32) Point {
    if (b[0] <= 0.0 or b[1] <= 0.0) return c;
    const mnx = lw * 0.5 + px;
    const mny = lh * 0.5 + py;
    const mxx = b[0] - lw * 0.5 - px;
    const mxy = b[1] - lh * 0.5 - py;
    return .{ if (mxx < mnx) c[0] else std.math.clamp(c[0], mnx, mxx), if (mxy < mny) c[1] else std.math.clamp(c[1], mny, mxy) };
}

const ObstacleGrid = struct {
    cell: f32,
    cells: std.AutoHashMapUnmanaged([2]i32, std.ArrayList(usize)) = .empty,

    fn init(a: Allocator, cell: f32, rects: []const Rect) Allocator.Error!ObstacleGrid {
        var g: ObstacleGrid = .{ .cell = @max(cell, 16.0) };
        for (rects, 0..) |r, i| try g.insert(a, i, r);
        return g;
    }

    fn initEdges(a: Allocator, cell: f32, obs: []const EdgeObstacle) Allocator.Error!ObstacleGrid {
        var g: ObstacleGrid = .{ .cell = @max(cell, 16.0) };
        for (obs, 0..) |o, i| try g.insert(a, i, o.rect);
        return g;
    }

    fn range(self: *const ObstacleGrid, r: Rect) [4]i32 {
        const f = @import("routing.zig").floorI32;
        return .{ f(r[0] / self.cell), f(r[1] / self.cell), f((r[0] + r[2]) / self.cell), f((r[1] + r[3]) / self.cell) };
    }

    fn insert(self: *ObstacleGrid, a: Allocator, idx: usize, r: Rect) Allocator.Error!void {
        const rg = self.range(r);
        var ix = rg[0];
        while (ix <= rg[2]) : (ix += 1) {
            var iy = rg[1];
            while (iy <= rg[3]) : (iy += 1) {
                const gop = try self.cells.getOrPut(a, .{ ix, iy });
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(a, idx);
            }
        }
    }

    const Query = struct {
        grid: *const ObstacleGrid,
        rg: [4]i32,
        ix: i32,
        iy: i32,
        list: []const usize = &.{},
        pos: usize = 0,
        seen: [2048]usize = undefined,
        seen_len: usize = 0,

        fn isSeen(q: *Query, v: usize) bool {
            for (q.seen[0..q.seen_len]) |s| if (s == v) return true;
            return false;
        }

        fn next(q: *Query) ?usize {
            while (true) {
                while (q.pos < q.list.len) {
                    const v = q.list[q.pos];
                    q.pos += 1;
                    if (q.isSeen(v)) continue;
                    if (q.seen_len < q.seen.len) {
                        q.seen[q.seen_len] = v;
                        q.seen_len += 1;
                    }
                    return v;
                }
                if (q.ix > q.rg[2]) return null;
                q.list = if (q.grid.cells.get(.{ q.ix, q.iy })) |l| l.items else &.{};
                q.pos = 0;
                q.iy += 1;
                if (q.iy > q.rg[3]) {
                    q.iy = q.rg[1];
                    q.ix += 1;
                }
            }
        }
    };

    fn query(self: *const ObstacleGrid, r: Rect) Query {
        const rg = self.range(r);
        return .{ .grid = self, .rg = rg, .ix = rg[0], .iy = rg[1] };
    }
};

fn centerLabelHardMaxGap(kind: Kind) ?f32 {
    return switch (kind) {
        .flowchart => FLOWCHART_OWN_EDGE_HARD_MAX_GAP,
        .state => STATE_OWN_EDGE_HARD_MAX_GAP,
        .class => CLASS_OWN_EDGE_HARD_MAX_GAP,
        .sequence, .zen_uml => null,
        else => DEFAULT_OWN_EDGE_HARD_MAX_GAP,
    };
}

fn labelPenalties(rect: Rect, anchor: Point, lw: f32, lh: f32, ctx: *const PenaltyCtx) Cost {
    const kind = ctx.kind;
    const area = @max(lw * lh, 1.0);
    var overlap: f32 = 0;
    const label_w: f32 = if (kind == .flowchart) WEIGHT_FLOWCHART_LABEL_OVERLAP else WEIGHT_LABEL_OVERLAP;
    const edge_w: f32 = if (kind == .flowchart) WEIGHT_FLOWCHART_EDGE_OVERLAP else WEIGHT_EDGE_OVERLAP;
    var fe: f32 = 0;
    var touch = false;
    var q = ctx.occupied_grid.query(rect);
    while (q.next()) |i| {
        const ov = overlapArea(rect, ctx.occupied[i]);
        if (ov > 0.0) {
            const w: f32 = if (i < ctx.node_obstacle_count) (if (kind == .flowchart) WEIGHT_NODE_OVERLAP_FLOWCHART else WEIGHT_NODE_OVERLAP) else label_w;
            overlap += ov * w;
        }
    }
    var eq = ctx.edge_grid.query(rect);
    while (eq.next()) |i| {
        const ob = ctx.edge_obstacles[i];
        if (ob.idx == ctx.edge_idx) continue;
        const ov = overlapArea(rect, ob.rect);
        overlap += ov * edge_w;
        if (kind == .flowchart and ov > 0.0) {
            fe += ov;
            touch = true;
        }
    }
    if (kind == .flowchart) {
        overlap += fe * FLOWCHART_FOREIGN_EDGE_OVERLAP_WEIGHT;
        if (touch) overlap += area * FLOWCHART_FOREIGN_EDGE_TOUCH_HARD_PENALTY;
    }
    if (ctx.bounds) |b| overlap += outsideArea(rect, b) * WEIGHT_OUTSIDE;
    const own_rect: Rect = if (kind == .state) .{ rect[0] + @max(rect[2] - lw, 0.0) * 0.5, rect[1] + @max(rect[3] - lh, 0.0) * 0.5, lw, lh } else rect;
    const own = polylineRectDistance(ctx.own_points, own_rect);
    if (std.math.isFinite(own)) {
        const p: [4]f32 = if (kind == .flowchart)
            .{ OWN_EDGE_GAP_TARGET_FLOWCHART, OWN_EDGE_GAP_UNDER_WEIGHT_FLOWCHART, OWN_EDGE_GAP_OVER_WEIGHT_FLOWCHART, OWN_EDGE_TOUCH_HARD_PENALTY_FLOWCHART }
        else if (kind == .class)
            .{ OWN_EDGE_GAP_TARGET_CLASS, OWN_EDGE_GAP_UNDER_WEIGHT_CLASS, OWN_EDGE_GAP_OVER_WEIGHT_CLASS, OWN_EDGE_TOUCH_HARD_PENALTY_CLASS }
        else
            .{ OWN_EDGE_GAP_TARGET, OWN_EDGE_GAP_UNDER_WEIGHT, OWN_EDGE_GAP_OVER_WEIGHT, OWN_EDGE_TOUCH_HARD_PENALTY };
        if (own < p[0]) {
            const s = (p[0] - own) / @max(p[0], 1e-3);
            overlap += area * (s * s * p[1]);
        }
        if (own > p[0]) {
            const e = (own - p[0]) / @max(p[0], 1e-3);
            overlap += area * (e * e * p[2]);
        }
        if (kind == .flowchart and own > FLOWCHART_OWN_EDGE_SOFT_MAX_GAP) {
            const o = own - FLOWCHART_OWN_EDGE_SOFT_MAX_GAP;
            overlap += area * (o * o * FLOWCHART_OWN_EDGE_SOFT_MAX_GAP_WEIGHT);
        }
        if (kind == .flowchart and own > FLOWCHART_OWN_EDGE_HARD_MAX_GAP) overlap += area * ((own - FLOWCHART_OWN_EDGE_HARD_MAX_GAP) * FLOWCHART_OWN_EDGE_HARD_MAX_GAP_WEIGHT);
        if (own <= 0.35) overlap += area * p[3];
    }
    const dx = (rect[0] + rect[2] * 0.5) - anchor[0];
    const dy = (rect[1] + rect[3] * 0.5) - anchor[1];
    return .{ overlap / area, @sqrt(dx * dx + dy * dy) / (lw + lh + 1.0) };
}

fn candidateBetter(c: Cost, b: Cost) bool {
    if (c[0] + 1e-6 < b[0]) return true;
    return @abs(c[0] - b[0]) <= 1e-6 and c[1] + 1e-6 < b[1];
}

pub fn edgeEndpointLabelPosition(edge: *const EdgeLayout, start: bool, offset: f32) ?Point {
    const p = edge.points.items;
    if (p.len < 2) return null;
    const p0 = if (start) p[0] else p[p.len - 1];
    const p1 = if (start) p[1] else p[p.len - 2];
    const dx = p1[0] - p0[0];
    const dy = p1[1] - p0[1];
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= std.math.floatEps(f32)) return null;
    const ux = dx / len;
    const uy = dy / len;
    return .{ p0[0] + ux * offset * 1.4 + -uy * offset, p0[1] + uy * offset * 1.4 + ux * offset };
}

fn endpointLabelPositionWithAvoid(edge: *const EdgeLayout, edge_idx: usize, start: bool, lw: f32, lh: f32, px: f32, py: f32, ctx: *const EndpointCtx) ?Point {
    const p = edge.points.items;
    if (p.len < 2) return null;
    const p0 = if (start) p[0] else p[p.len - 1];
    const p1 = if (start) p[1] else p[p.len - 2];
    const dx = p1[0] - p0[0];
    const dy = p1[1] - p0[1];
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= std.math.floatEps(f32)) return null;
    const kind = ctx.kind;
    const off = ctx.offset;
    const ux = dx / len;
    const uy = dy / len;
    const nx = -uy;
    const ny = ux;
    const along_f: f32 = switch (kind) {
        .class => 0.55,
        .flowchart => 1.4,
        .requirement => 1.1,
        else => 1.0,
    };
    const ax = p0[0] + ux * off * along_f;
    const ay = p0[1] + uy * off * along_f;
    const along_steps: []const f32 = if (kind == .class) &.{ 0.0, 0.15, -0.15, 0.35, -0.35, 0.55, -0.55 } else &.{ 0.0, 0.8, -0.8, 1.6, -1.6 };
    const perp_steps: []const f32 = if (kind == .class) &.{ 0.0, 0.35, -0.35, 0.7, -0.7, 1.05, -1.05, 1.5, -1.5 } else &.{ 1.0, -1.0, 1.7, -1.7, 2.4, -2.4, 3.2, -3.2, 3.9, -3.9, 4.6, -4.6 };
    var best_pos = Point{ ax, ay };
    var best = Cost{ INF, INF };
    const pctx: PenaltyCtx = .{ .kind = kind, .occupied = ctx.occupied, .occupied_grid = ctx.occupied_grid, .node_obstacle_count = ctx.node_obstacle_count, .edge_obstacles = ctx.edge_obstacles, .edge_grid = ctx.edge_grid, .edge_idx = edge_idx, .own_points = p, .bounds = ctx.bounds };
    const w: [3]f32 = switch (kind) {
        .class => .{ off * 0.9, 0.45, 1.2 },
        .state => .{ off * 1.3, 0.28, 0.7 },
        .flowchart => .{ off * 2.6, 0.14, 0.28 },
        else => .{ off * 1.7, 0.22, 0.45 },
    };
    for (along_steps) |al| {
        const bx = p0[0] + ux * off * (1.4 + al);
        const by = p0[1] + uy * off * (1.4 + al);
        for (perp_steps) |s| {
            const x = bx + nx * off * s;
            const y = by + ny * off * s;
            const rect = Rect{ x - lw / 2.0 - px, y - lh / 2.0 - py, lw + px * 2.0, lh + py * 2.0 };
            var pen = labelPenalties(rect, .{ ax, ay }, lw, lh, &pctx);
            const along = (x - p0[0]) * ux + (y - p0[1]) * uy;
            const under = @max(0.0 - along, 0.0);
            const over = @max(along - w[0], 0.0);
            if (under > 0.0 or over > 0.0) pen[0] += (under * under * w[1] + over * over * w[2]) / @max(lw + lh + 1.0, 1.0);
            if (candidateBetter(pen, best)) {
                best = pen;
                best_pos = .{ x, y };
            }
        }
    }
    if (ctx.bounds) |b| return clampLabelCenterToBounds(best_pos, lw, lh, px, py, b);
    return best_pos;
}
