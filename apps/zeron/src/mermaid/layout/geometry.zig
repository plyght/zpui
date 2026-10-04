//! `layout/geometry.rs`: node sides, shape polygons and segment tests.

const std = @import("std");
const Allocator = std.mem.Allocator;
const t = @import("types.zig");
const NodeLayout = t.NodeLayout;
const Point = t.Point;
const Rect = t.Rect;

const POINT_EPS: f32 = 0.5;
const GEOM_EPS: f32 = 1e-6;

pub const EdgeSide = enum { left, right, top, bottom };

pub fn hypot(x: f32, y: f32) f32 {
    return std.math.hypot(x, y);
}

pub fn nodeCenter(node: *const NodeLayout) Point {
    return .{ node.x + node.width * 0.5, node.y + node.height * 0.5 };
}

pub fn endpointSideForPoint(node: *const NodeLayout, point: Point) EdgeSide {
    const left = @abs(point[0] - node.x);
    const right = @abs(point[0] - (node.x + node.width));
    const top = @abs(point[1] - node.y);
    const bottom = @abs(point[1] - (node.y + node.height));
    var best_d = left;
    var best: EdgeSide = .left;
    for ([_]struct { f32, EdgeSide }{ .{ right, .right }, .{ top, .top }, .{ bottom, .bottom } }) |c| {
        if (c[0] < best_d) {
            best_d = c[0];
            best = c[1];
        }
    }
    return best;
}

pub fn sidePointsOutward(side: EdgeSide, endpoint: Point, outside: Point) bool {
    return switch (side) {
        .left => outside[0] <= endpoint[0] + POINT_EPS,
        .right => outside[0] >= endpoint[0] - POINT_EPS,
        .top => outside[1] <= endpoint[1] + POINT_EPS,
        .bottom => outside[1] >= endpoint[1] - POINT_EPS,
    };
}

pub fn sourceExitsOutward(side: EdgeSide, start: Point, next: Point) bool {
    return sidePointsOutward(side, start, next);
}

pub fn targetEntersFromOutside(side: EdgeSide, prev: Point, end: Point) bool {
    return sidePointsOutward(side, end, prev);
}

pub fn segmentIntrudesEndpointRect(side: EdgeSide, outside: Point, endpoint: Point, node: *const NodeLayout) bool {
    const within_y = endpoint[1] >= node.y - POINT_EPS and endpoint[1] <= node.y + node.height + POINT_EPS;
    const within_x = endpoint[0] >= node.x - POINT_EPS and endpoint[0] <= node.x + node.width + POINT_EPS;
    return switch (side) {
        .left => within_y and outside[0] > endpoint[0] + POINT_EPS,
        .right => within_y and outside[0] < endpoint[0] - POINT_EPS,
        .top => within_x and outside[1] > endpoint[1] + POINT_EPS,
        .bottom => within_x and outside[1] < endpoint[1] - POINT_EPS,
    };
}

/// Up to six polygon points; `null` for ellipse-like shapes.
pub const Poly = struct {
    pts: [6]Point = undefined,
    len: usize = 0,
    pub fn slice(self: *const Poly) []const Point {
        return self.pts[0..self.len];
    }
    fn of(points: []const Point) Poly {
        var p: Poly = .{ .len = points.len };
        @memcpy(p.pts[0..points.len], points);
        return p;
    }
};

pub fn shapePolygonPoints(node: *const NodeLayout) ?Poly {
    const x = node.x;
    const y = node.y;
    const w = node.width;
    const h = node.height;
    switch (node.shape) {
        .rectangle, .fork_join, .round_rect, .actor_box, .stadium, .subroutine, .text, .mindmap_default => return Poly.of(&.{ .{ x, y }, .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h } }),
        .diamond => {
            const cx = x + w / 2.0;
            const cy = y + h / 2.0;
            return Poly.of(&.{ .{ cx, y }, .{ x + w, cy }, .{ cx, y + h }, .{ x, cy } });
        },
        .hexagon => {
            const x1 = x + w * 0.25;
            const x2 = x + w * 0.75;
            const ym = y + h / 2.0;
            return Poly.of(&.{ .{ x1, y }, .{ x2, y }, .{ x + w, ym }, .{ x2, y + h }, .{ x1, y + h }, .{ x, ym } });
        },
        .parallelogram => {
            const o = w * 0.18;
            return Poly.of(&.{ .{ x + o, y }, .{ x + w, y }, .{ x + w - o, y + h }, .{ x, y + h } });
        },
        .parallelogram_alt => {
            const o = w * 0.18;
            return Poly.of(&.{ .{ x, y }, .{ x + w - o, y }, .{ x + w, y + h }, .{ x + o, y + h } });
        },
        .trapezoid => {
            const o = w * 0.18;
            return Poly.of(&.{ .{ x + o, y }, .{ x + w - o, y }, .{ x + w, y + h }, .{ x, y + h } });
        },
        .trapezoid_alt => {
            const o = w * 0.18;
            return Poly.of(&.{ .{ x, y }, .{ x + w, y }, .{ x + w - o, y + h }, .{ x + o, y + h } });
        },
        .asymmetric => {
            const s = w * 0.22;
            return Poly.of(&.{ .{ x, y }, .{ x + w - s, y }, .{ x + w, y + h / 2.0 }, .{ x + w - s, y + h }, .{ x, y + h } });
        },
        .circle, .double_circle, .cylinder => return null,
    }
}

pub fn rayPolygonIntersection(origin: Point, dir: Point, poly: []const Point) ?Point {
    var best_t: ?f32 = null;
    const ox = origin[0];
    const oy = origin[1];
    const rx = dir[0];
    const ry = dir[1];
    if (poly.len < 2) return null;
    for (0..poly.len) |i| {
        const p1 = poly[i];
        const p2 = poly[(i + 1) % poly.len];
        const sx = p2[0] - p1[0];
        const sy = p2[1] - p1[1];
        const qx = p1[0] - ox;
        const qy = p1[1] - oy;
        const denom = rx * sy - ry * sx;
        if (@abs(denom) < GEOM_EPS) continue;
        const tt = (qx * sy - qy * sx) / denom;
        const u = (qx * ry - qy * rx) / denom;
        if (tt >= 0.0 and u >= 0.0 and u <= 1.0) {
            if (best_t) |b| {
                if (tt >= b) continue;
            }
            best_t = tt;
        }
    }
    const b = best_t orelse return null;
    return .{ ox + rx * b, oy + ry * b };
}

pub fn rayEllipseIntersection(origin: Point, dir: Point, center: Point, rx: f32, ry: f32) ?Point {
    const dx = dir[0];
    const dy = dir[1];
    const ox = origin[0] - center[0];
    const oy = origin[1] - center[1];
    const a = (dx * dx) / (rx * rx) + (dy * dy) / (ry * ry);
    const b = 2.0 * ((ox * dx) / (rx * rx) + (oy * dy) / (ry * ry));
    const c = (ox * ox) / (rx * rx) + (oy * oy) / (ry * ry) - 1.0;
    const disc = b * b - 4.0 * a * c;
    if (disc < 0.0 or @abs(a) < GEOM_EPS) return null;
    const sd = @sqrt(disc);
    const t1 = (-b - sd) / (2.0 * a);
    const t2 = (-b + sd) / (2.0 * a);
    const tt = if (t1 >= 0.0) t1 else if (t2 >= 0.0) t2 else return null;
    return .{ origin[0] + dx * tt, origin[1] + dy * tt };
}

pub fn pointInPolygonStrict(point: Point, polygon: []const Point) bool {
    if (polygon.len < 3) return false;
    for (0..polygon.len) |i| {
        if (pointNearSegment(point, polygon[i], polygon[(i + 1) % polygon.len], POINT_EPS)) return false;
    }
    var inside = false;
    const px = point[0];
    const py = point[1];
    var prev = polygon[polygon.len - 1];
    for (polygon) |curr| {
        if ((curr[1] > py) != (prev[1] > py)) {
            const denom = prev[1] - curr[1];
            if (@abs(denom) > GEOM_EPS) {
                const x_at_y = (prev[0] - curr[0]) * (py - curr[1]) / denom + curr[0];
                if (px < x_at_y) inside = !inside;
            }
        }
        prev = curr;
    }
    return inside;
}

pub fn pointInsideNodeShapeStrict(node: *const NodeLayout, point: Point) bool {
    switch (node.shape) {
        .circle, .double_circle => {
            const c = nodeCenter(node);
            const rx = @max(node.width * 0.5 - POINT_EPS, 1.0);
            const ry = @max(node.height * 0.5 - POINT_EPS, 1.0);
            const nx = (point[0] - c[0]) / rx;
            const ny = (point[1] - c[1]) / ry;
            return nx * nx + ny * ny < 1.0;
        },
        else => {
            if (shapePolygonPoints(node)) |poly| return pointInPolygonStrict(point, poly.slice());
            return pointInsideNodeBoundsStrict(node, point);
        },
    }
}

pub fn segmentHitsNodeShapeInterior(a: Point, b: Point, node: *const NodeLayout) bool {
    const steps: usize = @max(@as(usize, @intFromFloat(@max(0, @ceil(hypot(b[0] - a[0], b[1] - a[1]) / 4.0)))), 2);
    var i: usize = 1;
    while (i < steps) : (i += 1) {
        const tt = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        if (pointInsideNodeShapeStrict(node, .{ a[0] + (b[0] - a[0]) * tt, a[1] + (b[1] - a[1]) * tt })) return true;
    }
    return false;
}

pub fn pathLength(points: []const Point) f32 {
    var sum: f32 = 0;
    if (points.len < 2) return 0;
    for (0..points.len - 1) |i| sum += hypot(points[i + 1][0] - points[i][0], points[i + 1][1] - points[i][1]);
    return sum;
}

pub fn pathPointAtProgress(points: []const Point, progress: f32) ?Point {
    if (points.len < 2) return null;
    const total = pathLength(points);
    if (!std.math.isFinite(total) or total <= GEOM_EPS) return points[0];
    var remain = total * std.math.clamp(progress, 0.0, 1.0);
    for (0..points.len - 1) |i| {
        const a = points[i];
        const b = points[i + 1];
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const seg = @sqrt(dx * dx + dy * dy);
        if (seg <= GEOM_EPS) continue;
        if (remain <= seg) {
            const tt = remain / seg;
            return .{ a[0] + dx * tt, a[1] + dy * tt };
        }
        remain -= seg;
    }
    return points[points.len - 1];
}

pub fn pathBendCount(points: []const Point) usize {
    if (points.len < 3) return 0;
    var bends: usize = 0;
    for (1..points.len - 1) |idx| {
        const p0 = points[idx - 1];
        const p1 = points[idx];
        const p2 = points[idx + 1];
        const dx1 = p1[0] - p0[0];
        const dy1 = p1[1] - p0[1];
        const dx2 = p2[0] - p1[0];
        const dy2 = p2[1] - p1[1];
        if ((@abs(dx1) <= 1e-4 and @abs(dy1) <= 1e-4) or (@abs(dx2) <= 1e-4 and @abs(dy2) <= 1e-4)) continue;
        if (@abs(dx1 * dy2 - dy1 * dx2) > 1e-4) bends += 1;
    }
    return bends;
}

pub fn pathIntersectsRectBounds(points: []const Point, rect: Rect) bool {
    if (points.len < 2) return false;
    for (0..points.len - 1) |i| if (segmentIntersectsRectBounds(points[i], points[i + 1], rect)) return true;
    return false;
}

pub fn segmentIntersectsRectBounds(a: Point, b: Point, rect: Rect) bool {
    const rx = rect[0];
    const ry = rect[1];
    const rw = rect[2];
    const rh = rect[3];
    if (rw <= 0.0 or rh <= 0.0) return false;
    const min_x = @min(a[0], b[0]);
    const max_x = @max(a[0], b[0]);
    const min_y = @min(a[1], b[1]);
    const max_y = @max(a[1], b[1]);
    if (max_x < rx or min_x > rx + rw or max_y < ry or min_y > ry + rh) return false;
    if (pointInRect(a, rect) or pointInRect(b, rect)) return true;
    const c = [4]Point{ .{ rx, ry }, .{ rx + rw, ry }, .{ rx + rw, ry + rh }, .{ rx, ry + rh } };
    for (0..4) |i| if (segmentsIntersect(a, b, c[i], c[(i + 1) % 4])) return true;
    return false;
}

pub fn segmentsShareEndpoint(a1: Point, a2: Point, b1: Point, b2: Point) bool {
    return pointsNear(a1, b1) or pointsNear(a1, b2) or pointsNear(a2, b1) or pointsNear(a2, b2);
}

pub fn segmentsIntersect(a: Point, b: Point, c: Point, d: Point) bool {
    const o1 = orient(a, b, c);
    const o2 = orient(a, b, d);
    const o3 = orient(c, d, a);
    const o4 = orient(c, d, b);
    if (((o1 > 0.0 and o2 < 0.0) or (o1 < 0.0 and o2 > 0.0)) and ((o3 > 0.0 and o4 < 0.0) or (o3 < 0.0 and o4 > 0.0))) return true;
    if (@abs(o1) <= GEOM_EPS and onSegment(a, b, c)) return true;
    if (@abs(o2) <= GEOM_EPS and onSegment(a, b, d)) return true;
    if (@abs(o3) <= GEOM_EPS and onSegment(c, d, a)) return true;
    if (@abs(o4) <= GEOM_EPS and onSegment(c, d, b)) return true;
    return false;
}

fn pointInsideNodeBoundsStrict(node: *const NodeLayout, p: Point) bool {
    return p[0] > node.x + POINT_EPS and p[0] < node.x + node.width - POINT_EPS and p[1] > node.y + POINT_EPS and p[1] < node.y + node.height - POINT_EPS;
}

fn pointInRect(p: Point, r: Rect) bool {
    return p[0] >= r[0] and p[0] <= r[0] + r[2] and p[1] >= r[1] and p[1] <= r[1] + r[3];
}

fn pointNearSegment(point: Point, a: Point, b: Point, eps: f32) bool {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    if (len2 <= GEOM_EPS) return pointsNear(point, a);
    const tt = ((point[0] - a[0]) * dx + (point[1] - a[1]) * dy) / len2;
    if (!(tt >= -GEOM_EPS and tt <= 1.0 + GEOM_EPS)) return false;
    const ct = std.math.clamp(tt, 0.0, 1.0);
    return hypot(point[0] - (a[0] + dx * ct), point[1] - (a[1] + dy * ct)) <= eps;
}

fn pointsNear(a: Point, b: Point) bool {
    return @abs(a[0] - b[0]) <= POINT_EPS and @abs(a[1] - b[1]) <= POINT_EPS;
}

fn orient(a: Point, b: Point, c: Point) f32 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

fn onSegment(a: Point, b: Point, p: Point) bool {
    return p[0] >= @min(a[0], b[0]) - GEOM_EPS and p[0] <= @max(a[0], b[0]) + GEOM_EPS and
        p[1] >= @min(a[1], b[1]) - GEOM_EPS and p[1] <= @max(a[1], b[1]) + GEOM_EPS;
}
