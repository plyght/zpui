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
