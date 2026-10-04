//! `anchored()` — position children at an anchor point, flipping or snapping to stay inside
//! the window (gpui `elements/anchored.rs`). Usually wrapped in `deferred` for popovers:
//!
//! ```zig
//! deferred(anchored().position(mouse).snapToWindow().child(menu)).withPriority(1)
//! ```

const std = @import("std");
const geometry = @import("../geometry.zig");
const App = @import("../app/app.zig").App;
const Window = @import("../window/window.zig").Window;
const element = @import("../window/element.zig");

const Pixels = geometry.Pixels;
const Point = geometry.Point(Pixels);
const Size = geometry.Size(Pixels);
const Bounds = geometry.Bounds(Pixels);
const Edges = geometry.Edges(Pixels);

/// Which corner of the child sits at the anchor point (gpui `Anchor`).
pub const Anchor = enum {
    top_left,
    top_right,
    bottom_left,
    bottom_right,

    pub fn otherSideHorizontal(self: Anchor) Anchor {
        return switch (self) {
            .top_left => .top_right,
            .top_right => .top_left,
            .bottom_left => .bottom_right,
            .bottom_right => .bottom_left,
        };
    }

    pub fn otherSideVertical(self: Anchor) Anchor {
        return switch (self) {
            .top_left => .bottom_left,
            .top_right => .bottom_right,
            .bottom_left => .top_left,
            .bottom_right => .top_right,
        };
    }
};

/// Bounds of `size` with its `anchor` corner at `origin` (gpui `Bounds::from_anchor_and_size`).
pub fn boundsFromAnchor(anchor: Anchor, origin: Point, size: Size) Bounds {
    const o: Point = switch (anchor) {
        .top_left => origin,
        .top_right => .{ .x = origin.x - size.width, .y = origin.y },
        .bottom_left => .{ .x = origin.x, .y = origin.y - size.height },
        .bottom_right => .{ .x = origin.x - size.width, .y = origin.y - size.height },
    };
    return .{ .origin = o, .size = size };
}

pub const FitMode = union(enum) {
    snap_to_window,
    snap_to_window_with_margin: Edges,
    switch_anchor,
};

pub const PositionMode = enum {
    /// `position` is in window coordinates (default: the element's own origin).
    window,
    /// `position` is relative to the element's layout origin.
    local,
};

pub fn anchored() Anchored {
    return .{};
}

pub const Anchored = struct {
    kids: element.Children = .{},
    anchor: Anchor = .top_left,
    fit_mode: FitMode = .switch_anchor,
    anchor_position: ?Point = null,
    position_mode: PositionMode = .window,
    offset_: ?Point = null,

    pub const RequestLayoutState = []element.LayoutId;

    pub fn anchorCorner(self: Anchored, a: Anchor) Anchored {
        var s = self;
        s.anchor = a;
        return s;
    }
    pub fn position(self: Anchored, p: Point) Anchored {
        var s = self;
        s.anchor_position = p;
        return s;
    }
    pub fn offset(self: Anchored, p: Point) Anchored {
        var s = self;
        s.offset_ = p;
        return s;
    }
    pub fn positionMode(self: Anchored, m: PositionMode) Anchored {
        var s = self;
        s.position_mode = m;
        return s;
    }
    pub fn snapToWindow(self: Anchored) Anchored {
        var s = self;
        s.fit_mode = .snap_to_window;
        return s;
    }
    pub fn snapToWindowWithMargin(self: Anchored, margin: Edges) Anchored {
        var s = self;
        s.fit_mode = .{ .snap_to_window_with_margin = margin };
        return s;
    }
    pub fn child(self: Anchored, c: anytype) Anchored {
        var s = self;
        s.kids.add(c);
        return s;
    }
    pub fn children(self: Anchored, list: anytype) Anchored {
        var s = self;
        s.kids.addMany(list);
        return s;
    }

    pub fn requestLayout(self: *Anchored, _: ?element.GlobalElementId, ids: *[]element.LayoutId, window: *Window, cx: *App) element.LayoutId {
        const kids = self.kids.slice();
        ids.* = @import("../window/arena.zig").frameAllocator().alloc(element.LayoutId, kids.len) catch @panic("OOM");
        for (kids, ids.*) |c, *id| id.* = c.requestLayout(window, cx);
        return window.requestLayout(.{ .position = .absolute, .display = .flex }, ids.*);
    }

    pub fn prepaint(self: *Anchored, _: ?element.GlobalElementId, bounds: Bounds, ids: *[]element.LayoutId, _: *void, window: *Window, cx: *App) void {
        if (ids.len == 0) return;
        var children_bounds = window.layoutBounds(ids.*[0]);
        for (ids.*[1..]) |id| children_bounds = children_bounds.unionWith(window.layoutBounds(id));
        const desired = computeDesired(self.*, children_bounds.size, bounds, window.viewport_size);
        const off: Point = .{ .x = @round(desired.origin.x - bounds.origin.x), .y = @round(desired.origin.y - bounds.origin.y) };
        window.pushElementOffset(off);
        defer window.popElementOffset();
        for (self.kids.slice()) |c| c.prepaint(window, cx);
    }

    pub fn paint(self: *Anchored, _: ?element.GlobalElementId, _: Bounds, _: *[]element.LayoutId, _: *void, window: *Window, cx: *App) void {
        for (self.kids.slice()) |c| c.paint(window, cx);
    }
};

/// The anchored content's window bounds (the positioning math, testable on its own).
pub fn computeDesired(a: Anchored, size: Size, bounds: Bounds, viewport: Size) Bounds {
    const off = a.offset_ orelse Point.zero;
    var origin: Point = undefined;
    var desired: Bounds = undefined;
    switch (a.position_mode) {
        .window => {
            origin = a.anchor_position orelse bounds.origin;
            desired = boundsFromAnchor(a.anchor, origin.add(off), size);
        },
        .local => {
            origin = a.anchor_position orelse Point.zero;
            desired = boundsFromAnchor(a.anchor, bounds.origin.add(origin).add(off), size);
        },
    }
    const limits: Bounds = .{ .origin = .zero, .size = viewport };
    if (a.fit_mode == .switch_anchor) {
        var anchor = a.anchor;
        if (desired.origin.x < limits.origin.x or desired.right() > limits.right()) {
            const switched = boundsFromAnchor(anchor.otherSideHorizontal(), origin, size);
            if (!(switched.origin.x < limits.origin.x or switched.right() > limits.right())) {
                anchor = anchor.otherSideHorizontal();
                desired = switched;
            }
        }
        if (desired.origin.y < limits.origin.y or desired.bottom() > limits.bottom()) {
            const switched = boundsFromAnchor(anchor.otherSideVertical(), origin, size);
            if (!(switched.origin.y < limits.origin.y or switched.bottom() > limits.bottom())) desired = switched;
        }
    }
    const edges: Edges = switch (a.fit_mode) {
        .snap_to_window_with_margin => |e| e,
        else => .all(0),
    };
    if (desired.right() > limits.right()) desired.origin.x -= desired.right() - limits.right() + edges.right;
    if (desired.origin.x < limits.origin.x) desired.origin.x = limits.origin.x + edges.left;
    if (desired.bottom() > limits.bottom()) desired.origin.y -= desired.bottom() - limits.bottom() + edges.bottom;
    if (desired.origin.y < limits.origin.y) desired.origin.y = limits.origin.y + edges.top;
    return desired;
}

test "anchored: switch anchor flips to fit, snap clamps" {
    const vp: Size = .{ .width = 800, .height = 600 };
    const el: Bounds = .{ .origin = .zero, .size = .zero };
    const size: Size = .{ .width = 200, .height = 300 };
    // Fits as-is.
    var d = computeDesired(anchored().position(.{ .x = 100, .y = 100 }), size, el, vp);
    try std.testing.expectEqual(@as(f32, 100), d.origin.x);
    // Overflows right and bottom: flips to the other corner.
    d = computeDesired(anchored().position(.{ .x = 700, .y = 500 }), size, el, vp);
    try std.testing.expectEqual(@as(f32, 500), d.origin.x);
    try std.testing.expectEqual(@as(f32, 200), d.origin.y);
    // Snap mode clamps instead of flipping.
    d = computeDesired(anchored().position(.{ .x = 700, .y = 500 }).snapToWindow(), size, el, vp);
    try std.testing.expectEqual(@as(f32, 600), d.origin.x);
    try std.testing.expectEqual(@as(f32, 300), d.origin.y);
    // Margins.
    d = computeDesired(anchored().position(.{ .x = 700, .y = 0 }).snapToWindowWithMargin(.all(8)), size, el, vp);
    try std.testing.expectEqual(@as(f32, 592), d.origin.x);
    // Local mode is relative to the element.
    d = computeDesired(anchored().positionMode(.local).position(.{ .x = 10, .y = 10 }), size, .{ .origin = .{ .x = 50, .y = 60 }, .size = .zero }, vp);
    try std.testing.expectEqual(@as(f32, 60), d.origin.x);
    try std.testing.expectEqual(@as(f32, 70), d.origin.y);
}
