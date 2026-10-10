//! Upper-plane reuse for layered presentation (`drawLayered` on macOS): an overlay or
//! top plane whose operations are unchanged is left as presented.

const std = @import("std");
const geometry = @import("../geometry.zig");
const scene_mod = @import("../scene.zig");
const platform = @import("platform.zig");

/// The operations an upper plane last presented, and at what drawable size and scale.
/// A plane whose operations are the same next frame (draw orders aside: they come from
/// the whole scene) renders the same pixels, so its layer keeps its presented drawable:
/// no replay, sort, encode or present. During a scroll the sidebar and titlebar planes
/// stay as they are while the main surface redraws.
pub const PlaneShown = struct {
    ops: std.ArrayList(scene_mod.PaintOperation) = .empty,
    size: geometry.Size(geometry.DevicePixels) = .{ .width = 0, .height = 0 },
    scale: f32 = 0,
    valid: bool = false,

    /// `scene`'s operations in `ranges` of `plane`, in order, equal the shown ones.
    pub fn matches(self: *const PlaneShown, scene: *const scene_mod.Scene, ranges: []const platform.OverlayRange, plane: platform.OverlayPlane, size: geometry.Size(geometry.DevicePixels), scale: f32) bool {
        if (!self.valid or self.scale != scale or self.size.width != size.width or self.size.height != size.height) return false;
        const ops = scene.paint_operations.items;
        var at: usize = 0;
        for (ranges) |r| {
            if (r.plane != plane) continue;
            const start = @min(r.start, ops.len);
            const end = @min(r.end, ops.len);
            const n = end - start;
            if (at + n > self.ops.items.len) return false;
            if (!scene_mod.sameOperationsIgnoringOrder(ops[start..end], self.ops.items[at .. at + n])) return false;
            at += n;
        }
        return at == self.ops.items.len;
    }

    pub fn record(self: *PlaneShown, gpa: std.mem.Allocator, scene: *const scene_mod.Scene, ranges: []const platform.OverlayRange, plane: platform.OverlayPlane, size: geometry.Size(geometry.DevicePixels), scale: f32) void {
        self.valid = false;
        self.ops.clearRetainingCapacity();
        const ops = scene.paint_operations.items;
        for (ranges) |r| {
            if (r.plane != plane) continue;
            self.ops.appendSlice(gpa, ops[@min(r.start, ops.len)..@min(r.end, ops.len)]) catch return;
        }
        self.size = size;
        self.scale = scale;
        self.valid = true;
    }
};


/// Split `scene` into its presentation planes for `drawLayered`: each of `base`,
/// `overlay` and `top` (null: skip that plane) gets the operations of its plane, ordered
/// as if that plane alone were replayed into an empty scene, and finished. A
/// plane-ordered scene (`Scene.planes`) whose operation planes agree with `ranges`
/// already holds those orders: its operations are copied, not replayed through a
/// bounds tree.
pub fn splitPlanes(gpa: std.mem.Allocator, scene: *const scene_mod.Scene, ranges: []const platform.OverlayRange, base: *scene_mod.Scene, overlay: ?*scene_mod.Scene, top: ?*scene_mod.Scene) !void {
    const fast = scene.planes and planesAgree(scene, ranges);
    const n = scene.len();
    var at: usize = 0;
    for (ranges) |r| {
        const start = @min(r.start, n);
        const end = @min(r.end, n);
        if (start > at) try copy(gpa, fast, base, at, start, scene);
        if (end > start) if (if (r.plane == .top) top else overlay) |dst| try copy(gpa, fast, dst, start, end, scene);
        at = @max(at, end);
    }
    if (n > at) try copy(gpa, fast, base, at, n, scene);
    base.finishWith(gpa);
    if (overlay) |o| o.finishWith(gpa);
    if (top) |t| t.finishWith(gpa);
}

fn copy(gpa: std.mem.Allocator, fast: bool, dst: *scene_mod.Scene, start: usize, end: usize, src: *const scene_mod.Scene) !void {
    if (fast) try dst.appendOrdered(gpa, start, end, src) else try dst.replay(gpa, start, end, src);
}

/// Every operation was ordered on the plane `ranges` puts it on (same walk as `splitPlanes`).
fn planesAgree(scene: *const scene_mod.Scene, ranges: []const platform.OverlayRange) bool {
    const planes = scene.op_planes.items;
    const n = scene.len();
    if (planes.len != n) return false;
    var at: usize = 0;
    for (ranges) |r| {
        const start = @min(r.start, n);
        const end = @min(r.end, n);
        if (start > at) for (planes[at..start]) |p| if (p != .base) return false;
        if (end > start) {
            const want: scene_mod.Plane = if (r.plane == .top) .top else .overlay;
            for (planes[@max(start, at)..end]) |p| if (p != want) return false;
        }
        at = @max(at, end);
    }
    if (n > at) for (planes[at..n]) |p| if (p != .base) return false;
    return true;
}

const testing = std.testing;

fn quadAt(x: f32) scene_mod.Quad {
    const b: geometry.Bounds(geometry.ScaledPixels) = .{ .origin = .{ .x = x, .y = 0 }, .size = .{ .width = 10, .height = 10 } };
    return .{ .bounds = b, .content_mask = .{ .bounds = b } };
}

test "an upper plane matches while its operations are unchanged, wherever they sit in the scene" {
    const gpa = testing.allocator;
    const size: geometry.Size(geometry.DevicePixels) = .{ .width = 100, .height = 50 };
    var shown: PlaneShown = .{};
    defer shown.ops.deinit(gpa);

    // Frame 1: base quad, then the overlay range [1, 3).
    var s1: scene_mod.Scene = .{};
    defer s1.deinit(gpa);
    try s1.insertQuad(gpa, quadAt(0));
    try s1.insertQuad(gpa, quadAt(5));
    try s1.insertQuad(gpa, quadAt(50));
    const r1 = [_]platform.OverlayRange{.{ .start = 1, .end = 3 }};
    try testing.expect(!shown.matches(&s1, &r1, .overlay, size, 2));
    shown.record(gpa, &s1, &r1, .overlay, size, 2);
    try testing.expect(shown.matches(&s1, &r1, .overlay, size, 2));

    // Frame 2: more base content first (the overlay ops move and get other orders).
    var s2: scene_mod.Scene = .{};
    defer s2.deinit(gpa);
    try s2.insertQuad(gpa, quadAt(0));
    try s2.insertQuad(gpa, quadAt(2));
    try s2.insertQuad(gpa, quadAt(5));
    try s2.insertQuad(gpa, quadAt(50));
    const r2 = [_]platform.OverlayRange{.{ .start = 2, .end = 4 }};
    try testing.expect(s2.quads.items[2].order != s1.quads.items[1].order);
    try testing.expect(shown.matches(&s2, &r2, .overlay, size, 2));
    // Other planes, sizes and scales do not match.
    try testing.expect(!shown.matches(&s2, &r2, .top, size, 2));
    try testing.expect(!shown.matches(&s2, &r2, .overlay, .{ .width = 101, .height = 50 }, 2));
    try testing.expect(!shown.matches(&s2, &r2, .overlay, size, 1));
    // A changed, missing or extra overlay op does not.
    const shorter = [_]platform.OverlayRange{.{ .start = 2, .end = 3 }};
    try testing.expect(!shown.matches(&s2, &shorter, .overlay, size, 2));
    const longer = [_]platform.OverlayRange{.{ .start = 1, .end = 4 }};
    try testing.expect(!shown.matches(&s2, &longer, .overlay, size, 2));
    s2.paint_operations.items[3].primitive.quad.bounds.origin.y = 1;
    try testing.expect(!shown.matches(&s2, &r2, .overlay, size, 2));
    // Invalidated: never matches.
    shown.valid = false;
    try testing.expect(!shown.matches(&s1, &r1, .overlay, size, 2));
}

test "splitting a plane-ordered scene copies orders that match a replay of each plane" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5917);
    const rnd = prng.random();
    for (0..40) |_| {
        var sc: scene_mod.Scene = .{};
        defer sc.deinit(gpa);
        sc.setPlanes(true);
        var ranges: [8]platform.OverlayRange = undefined;
        var nr: usize = 0;
        var open: ?usize = null;
        for (0..rnd.intRangeAtMost(usize, 1, 120)) |_| {
            // Open or close an upper-plane range now and then (disjoint, in order).
            if (rnd.uintLessThan(u8, 12) == 0) {
                if (open) |o| {
                    if (sc.len() > o and nr < ranges.len) {
                        ranges[nr] = .{ .start = o, .end = sc.len(), .plane = if (sc.plane == .top) .top else .overlay };
                        nr += 1;
                    }
                    open = null;
                    sc.plane = .base;
                } else if (nr < ranges.len) {
                    open = sc.len();
                    sc.plane = if (rnd.boolean()) .top else .overlay;
                }
            }
            const b: geometry.Bounds(geometry.ScaledPixels) = .{ .origin = .{ .x = rnd.float(f32) * 200, .y = rnd.float(f32) * 100 }, .size = .{ .width = 1 + rnd.float(f32) * 50, .height = 1 + rnd.float(f32) * 30 } };
            if (rnd.uintLessThan(u8, 8) == 0) try sc.pushLayer(gpa, b) else if (rnd.uintLessThan(u8, 8) == 0) try sc.popLayer(gpa) else try sc.insertQuad(gpa, .{ .bounds = b, .content_mask = .{ .bounds = b } });
        }
        if (open) |o| if (sc.len() > o and nr < ranges.len) {
            ranges[nr] = .{ .start = o, .end = sc.len(), .plane = if (sc.plane == .top) .top else .overlay };
            nr += 1;
        };
        // Operations after the last closed range but painted on an upper plane would
        // disagree with `ranges`; close every range before checking.
        if (open != null and (nr == 0 or ranges[nr - 1].end != sc.len())) continue;
        var fast: [3]scene_mod.Scene = .{ .{}, .{}, .{} };
        var slow: [3]scene_mod.Scene = .{ .{}, .{}, .{} };
        defer for (&fast, &slow) |*f, *s| {
            f.deinit(gpa);
            s.deinit(gpa);
        };
        try testing.expect(planesAgree(&sc, ranges[0..nr]));
        try splitPlanes(gpa, &sc, ranges[0..nr], &fast[0], &fast[1], &fast[2]);
        sc.planes = false; // force the replay path
        try splitPlanes(gpa, &sc, ranges[0..nr], &slow[0], &slow[1], &slow[2]);
        for (fast, slow) |f, s| try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(s.quads.items), std.mem.sliceAsBytes(f.quads.items));
    }
}
