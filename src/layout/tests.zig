//! Unit tests for the layout engine. Expected values follow CSS / taffy behavior.

const std = @import("std");
const layout = @import("layout.zig");
const geometry = @import("../geometry.zig");

const LayoutEngine = layout.LayoutEngine;
const NodeId = layout.NodeId;
const Style = layout.Style;
const Dims = layout.Dims;
const AvailableSpace = layout.AvailableSpace;
const Size = geometry.Size(f32);

fn px(v: f32) layout.Length {
    return .{ .px = v };
}
fn pct(v: f32) layout.Length {
    return .{ .percent = v };
}
fn sz(w: f32, h: f32) Dims(layout.Length) {
    return .{ .width = px(w), .height = px(h) };
}
fn lp(v: f32) layout.Sides(layout.LengthPercentage) {
    return .all(.{ .px = v });
}

fn definite(w: f32, h: f32) Dims(AvailableSpace) {
    return .{ .width = .{ .definite = w }, .height = .{ .definite = h } };
}

fn expectBounds(e: *LayoutEngine, id: NodeId, x: f32, y: f32, w: f32, h: f32) !void {
    const b = e.layoutBounds(id);
    const tol = 0.001;
    errdefer std.debug.print("got x={d} y={d} w={d} h={d}, expected x={d} y={d} w={d} h={d}\n", .{ b.origin.x, b.origin.y, b.size.width, b.size.height, x, y, w, h });
    try std.testing.expectApproxEqAbs(x, b.origin.x, tol);
    try std.testing.expectApproxEqAbs(y, b.origin.y, tol);
    try std.testing.expectApproxEqAbs(w, b.size.width, tol);
    try std.testing.expectApproxEqAbs(h, b.size.height, tol);
}

fn leaf(e: *LayoutEngine, style: Style) !NodeId {
    return e.requestLayout(style, &.{});
}

/// Text-like content: `words` words of `word_width` px each, wrapped into 20px lines.
const Text = struct {
    words: u32,
    word_width: f32 = 50,
    line_height: f32 = 20,
    calls: u32 = 0,

    fn measure(self: *Text, known: Dims(?f32), avail: Dims(AvailableSpace)) Size {
        self.calls += 1;
        const total = @as(f32, @floatFromInt(self.words)) * self.word_width;
        const max_w = known.width orelse switch (avail.width) {
            .definite => |v| v,
            .min_content => self.word_width,
            .max_content => total,
        };
        const per_line = @max(1, @floor(max_w / self.word_width));
        const lines = @ceil(@as(f32, @floatFromInt(self.words)) / per_line);
        const width = @min(total, per_line * self.word_width);
        return .{ .width = known.width orelse width, .height = known.height orelse lines * self.line_height };
    }
};

fn text(e: *LayoutEngine, style: Style, t: *Text) !NodeId {
    return e.requestMeasuredLayout(style, .init(Text, t, Text.measure));
}

const row: Style = .{ .display = .flex };
const column: Style = .{ .display = .flex, .flex_direction = .column };

test "row places children left to right" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(50, 20) });
    const b = try leaf(&e, .{ .size = sz(30, 40) });
    var s = row;
    s.size = sz(200, 100);
    s.align_items = .flex_start;
    const root = try e.requestLayout(s, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, root, 0, 0, 200, 100);
    try expectBounds(&e, a, 0, 0, 50, 20);
    try expectBounds(&e, b, 50, 0, 30, 40);
}

test "column stacks children and stretches width" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = .{ .width = .auto, .height = px(20) } });
    const b = try leaf(&e, .{ .size = .{ .width = .auto, .height = px(30) } });
    var s = column;
    s.size = sz(100, 200);
    const root = try e.requestLayout(s, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 0, 0, 100, 20);
    try expectBounds(&e, b, 0, 20, 100, 30);
}

test "auto-sized row fits content" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(50, 20) });
    const b = try leaf(&e, .{ .size = sz(30, 40) });
    const root = try e.requestLayout(row, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, root, 0, 0, 80, 40);
    // Default align-items is stretch, but children have definite heights.
    try expectBounds(&e, a, 0, 0, 50, 20);
}

test "gap between items in row and column" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(10, 10) });
    const b = try leaf(&e, .{ .size = sz(10, 10) });
    const c = try leaf(&e, .{ .size = sz(10, 10) });
    var s = row;
    s.gap = .{ .width = .{ .px = 5 }, .height = .{ .px = 0 } };
    const r = try e.requestLayout(s, &.{ a, b, c });
    const x = try leaf(&e, .{ .size = sz(10, 10) });
    var cs = column;
    cs.gap = .{ .width = .{ .px = 0 }, .height = .{ .px = 7 } };
    const root = try e.requestLayout(cs, &.{ r, x });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, r, 0, 0, 40, 10);
    try expectBounds(&e, c, 30, 0, 10, 10);
    try expectBounds(&e, x, 0, 17, 10, 10);
    try expectBounds(&e, root, 0, 0, 40, 27);
}

test "padding and border offset children and grow auto size" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(50, 20) });
    var s = row;
    s.padding = lp(10);
    s.border = lp(2);
    const root = try e.requestLayout(s, &.{a});
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, root, 0, 0, 74, 44);
    try expectBounds(&e, a, 12, 12, 50, 20);
}

test "flex grow distributes free space" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .flex_grow = 1, .size = .{ .width = px(10), .height = px(10) } });
    const b = try leaf(&e, .{ .flex_grow = 3, .size = .{ .width = px(10), .height = px(10) } });
    var s = row;
    s.size = sz(220, 10);
    const root = try e.requestLayout(s, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 0, 0, 60, 10);
    try expectBounds(&e, b, 60, 0, 160, 10);
}

test "flex grow respects max size and redistributes" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .flex_grow = 1, .flex_basis = px(0), .max_size = .{ .width = px(50), .height = .auto } });
    const b = try leaf(&e, .{ .flex_grow = 1, .flex_basis = px(0) });
    var s = row;
    s.size = sz(300, 10);
    const root = try e.requestLayout(s, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 0, 0, 50, 10);
    try expectBounds(&e, b, 50, 0, 250, 10);
}

test "flex shrink is weighted by basis" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = .{ .width = px(100), .height = px(10) } });
    const b = try leaf(&e, .{ .size = .{ .width = px(300), .height = px(10) } });
    var s = row;
    s.size = sz(200, 10);
    const root = try e.requestLayout(s, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 0, 0, 50, 10);
    try expectBounds(&e, b, 50, 0, 150, 10);
}

test "flex shrink respects min size" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = .{ .width = px(100), .height = px(10) }, .min_size = .{ .width = px(90), .height = .auto } });
    const b = try leaf(&e, .{ .size = .{ .width = px(100), .height = px(10) } });
    var s = row;
    s.size = sz(150, 10);
    const root = try e.requestLayout(s, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 0, 0, 90, 10);
    try expectBounds(&e, b, 90, 0, 60, 10);
}

test "flex shrink zero overflows" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .flex_shrink = 0, .size = sz(80, 10) });
    const b = try leaf(&e, .{ .flex_shrink = 0, .size = sz(80, 10) });
    var s = row;
    s.size = sz(100, 10);
    const root = try e.requestLayout(s, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, b, 80, 0, 80, 10);
}

test "justify content variants" {
    const Case = struct { mode: layout.JustifyContent, a: f32, b: f32 };
    const cases = [_]Case{
        .{ .mode = .flex_start, .a = 0, .b = 20 },
        .{ .mode = .flex_end, .a = 60, .b = 80 },
        .{ .mode = .end, .a = 60, .b = 80 },
        .{ .mode = .center, .a = 30, .b = 50 },
        .{ .mode = .space_between, .a = 0, .b = 80 },
        .{ .mode = .space_around, .a = 15, .b = 65 },
        .{ .mode = .space_evenly, .a = 20, .b = 60 },
    };
    for (cases) |c| {
        var e = LayoutEngine.init(std.testing.allocator);
        defer e.deinit();
        const a = try leaf(&e, .{ .size = sz(20, 10) });
        const b = try leaf(&e, .{ .size = sz(20, 10) });
        var s = row;
        s.size = sz(100, 10);
        s.justify_content = c.mode;
        const root = try e.requestLayout(s, &.{ a, b });
        try e.computeLayout(root, definite(800, 600));
        try expectBounds(&e, a, c.a, 0, 20, 10);
        try expectBounds(&e, b, c.b, 0, 20, 10);
    }
}

test "align items variants and align self override" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(10, 20) });
    const b = try leaf(&e, .{ .size = sz(10, 20), .align_self = .flex_end });
    const c = try leaf(&e, .{ .size = .{ .width = px(10), .height = .auto }, .align_self = .stretch });
    const d = try leaf(&e, .{ .size = sz(10, 20), .align_self = .flex_start });
    var s = row;
    s.size = sz(100, 100);
    s.align_items = .center;
    const root = try e.requestLayout(s, &.{ a, b, c, d });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 0, 40, 10, 20);
    try expectBounds(&e, b, 10, 80, 10, 20);
    try expectBounds(&e, c, 20, 0, 10, 100);
    try expectBounds(&e, d, 30, 0, 10, 20);
}

test "stretch is clamped by max cross size" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = .{ .width = px(10), .height = .auto }, .max_size = .{ .width = .auto, .height = px(30) } });
    var s = row;
    s.size = sz(100, 100);
    const root = try e.requestLayout(s, &.{a});
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 0, 0, 10, 30);
}

test "wrap breaks lines and stacks them" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    var kids: [5]NodeId = undefined;
    for (&kids) |*k| k.* = try leaf(&e, .{ .size = sz(30, 10) });
    var s = row;
    s.size = .{ .width = px(100), .height = .auto };
    s.flex_wrap = .wrap;
    s.gap = .{ .width = .{ .px = 5 }, .height = .{ .px = 2 } };
    const root = try e.requestLayout(s, &kids);
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, root, 0, 0, 100, 22);
    try expectBounds(&e, kids[0], 0, 0, 30, 10);
    try expectBounds(&e, kids[2], 70, 0, 30, 10);
    try expectBounds(&e, kids[3], 0, 12, 30, 10);
    try expectBounds(&e, kids[4], 35, 12, 30, 10);
}

test "wrap reverse places first line at the bottom" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(60, 10) });
    const b = try leaf(&e, .{ .size = sz(60, 10) });
    var s = row;
    s.size = sz(100, 50);
    s.flex_wrap = .wrap_reverse;
    s.align_content = .flex_start;
    const root = try e.requestLayout(s, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 0, 40, 60, 10);
    try expectBounds(&e, b, 0, 30, 60, 10);
}

test "align content center and stretch with wrapped lines" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(60, 10) });
    const b = try leaf(&e, .{ .size = .{ .width = px(60), .height = .auto } });
    var s = row;
    s.size = sz(100, 100);
    s.flex_wrap = .wrap;
    s.align_content = .center;
    const root = try e.requestLayout(s, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    // b has no height: its hypothetical height is 0, so lines are 10 and 0 tall.
    try expectBounds(&e, a, 0, 45, 60, 10);
    try expectBounds(&e, b, 0, 55, 60, 0);

    var e2 = LayoutEngine.init(std.testing.allocator);
    defer e2.deinit();
    const c = try leaf(&e2, .{ .size = sz(60, 10) });
    const d = try leaf(&e2, .{ .size = .{ .width = px(60), .height = .auto } });
    s.align_content = .stretch;
    const root2 = try e2.requestLayout(s, &.{ c, d });
    try e2.computeLayout(root2, definite(800, 600));
    // Free 90px split across both lines: 55 and 45.
    try expectBounds(&e2, c, 0, 0, 60, 10);
    try expectBounds(&e2, d, 0, 55, 60, 45);
}

test "absolute child positioned with insets against padding box" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const tl = try leaf(&e, .{ .position = .absolute, .size = sz(10, 10), .inset = .{ .top = px(5), .left = px(7), .right = .auto, .bottom = .auto } });
    const br = try leaf(&e, .{ .position = .absolute, .size = sz(10, 10), .inset = .{ .top = .auto, .left = .auto, .right = px(3), .bottom = px(4) } });
    const fill = try leaf(&e, .{ .position = .absolute, .inset = .all(px(10)) });
    const in_flow = try leaf(&e, .{ .size = sz(20, 20) });
    var s = row;
    s.size = sz(100, 80);
    s.padding = lp(8);
    s.border = lp(2);
    const root = try e.requestLayout(s, &.{ tl, br, fill, in_flow });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, tl, 9, 7, 10, 10);
    try expectBounds(&e, br, 100 - 2 - 3 - 10, 80 - 2 - 4 - 10, 10, 10);
    try expectBounds(&e, fill, 12, 12, 76, 56);
    // Absolute children take no space in flow.
    try expectBounds(&e, in_flow, 10, 10, 20, 20);
}

test "absolute child with auto insets uses static position and percent insets" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .position = .absolute, .size = sz(20, 20) });
    const b = try leaf(&e, .{ .position = .absolute, .size = sz(10, 10), .inset = .{ .top = pct(0.5), .left = pct(0.25), .right = .auto, .bottom = .auto } });
    var s = row;
    s.size = sz(100, 100);
    s.justify_content = .center;
    s.align_items = .center;
    const root = try e.requestLayout(s, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 40, 40, 20, 20);
    try expectBounds(&e, b, 25, 50, 10, 10);
}

test "absolute auto margins center between insets" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .position = .absolute, .size = sz(20, 10), .inset = .all(px(0)), .margin = .all(.auto) });
    var s = row;
    s.size = sz(100, 50);
    const root = try e.requestLayout(s, &.{a});
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 40, 20, 20, 10);
}

test "percentages resolve against parent content box" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = .{ .width = pct(0.5), .height = pct(0.25) } });
    var s = row;
    s.size = sz(220, 120);
    s.padding = lp(10);
    s.align_items = .flex_start;
    const root = try e.requestLayout(s, &.{a});
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 10, 10, 100, 25);
}

test "percentage padding resolves against parent width" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .padding = .all(.{ .percent = 0.1 }) });
    var s = row;
    s.size = sz(200, 100);
    s.align_items = .flex_start;
    const root = try e.requestLayout(s, &.{a});
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 0, 0, 40, 40);
}

test "auto margins center an item in both axes" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(20, 10), .margin = .all(.auto) });
    var s = row;
    s.size = sz(100, 50);
    const root = try e.requestLayout(s, &.{a});
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 40, 20, 20, 10);
}

test "auto margin pushes later items to the end" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(20, 10) });
    const b = try leaf(&e, .{ .size = sz(20, 10), .margin = .{ .left = .auto, .right = px(0), .top = px(0), .bottom = px(0) } });
    const c = try leaf(&e, .{ .size = sz(20, 10) });
    var s = row;
    s.size = sz(100, 10);
    s.gap = .{ .width = .{ .px = 5 }, .height = .{ .px = 0 } };
    const root = try e.requestLayout(s, &.{ a, b, c });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 0, 0, 20, 10);
    try expectBounds(&e, b, 55, 0, 20, 10);
    try expectBounds(&e, c, 80, 0, 20, 10);
}

test "nested containers report absolute bounds" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const inner_leaf = try leaf(&e, .{ .size = sz(10, 10) });
    var inner_style = row;
    inner_style.padding = lp(5);
    inner_style.margin = .all(px(3));
    const inner = try e.requestLayout(inner_style, &.{inner_leaf});
    const first = try leaf(&e, .{ .size = sz(40, 40) });
    var s = row;
    s.padding = lp(10);
    s.align_items = .flex_start;
    const root = try e.requestLayout(s, &.{ first, inner });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, inner, 53, 13, 20, 20);
    try expectBounds(&e, inner_leaf, 58, 18, 10, 10);
    const rel = e.layout(inner_leaf);
    try std.testing.expectEqual(@as(f32, 5), rel.location.x);
    try std.testing.expectEqual(root, e.parent(inner).?);
}

test "measured text wraps to the column width" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    var t: Text = .{ .words = 10 };
    const label = try text(&e, .{}, &t);
    var s = column;
    s.size = .{ .width = px(120), .height = .auto };
    const root = try e.requestLayout(s, &.{label});
    try e.computeLayout(root, definite(800, 600));
    // 2 words per line -> 5 lines.
    try expectBounds(&e, label, 0, 0, 120, 100);
    try expectBounds(&e, root, 0, 0, 120, 100);
}

test "measured text in a row shrinks and wraps beside fixed sibling" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const icon = try leaf(&e, .{ .size = sz(20, 20), .flex_shrink = 0 });
    var t: Text = .{ .words = 6 };
    const label = try text(&e, .{}, &t);
    var s = row;
    s.size = .{ .width = px(170), .height = .auto };
    s.align_items = .flex_start;
    const root = try e.requestLayout(s, &.{ icon, label });
    try e.computeLayout(root, definite(800, 600));
    // Text max-content is 300, shrinks to 150 -> 3 words/line, 2 lines.
    try expectBounds(&e, label, 20, 0, 150, 40);
    try expectBounds(&e, root, 0, 0, 170, 40);
}

test "text min-content prevents shrinking below longest word" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    var t: Text = .{ .words = 4 };
    const label = try text(&e, .{}, &t);
    var s = row;
    s.size = sz(30, 100);
    s.align_items = .flex_start;
    const root = try e.requestLayout(s, &.{label});
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, label, 0, 0, 50, 80);
}

test "overflow scroll container does not grow to fit content" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const content = try leaf(&e, .{ .size = .{ .width = .auto, .height = px(500) }, .flex_shrink = 0 });
    var scroll = column;
    // gpui's `flex_1()`: grow 1, shrink 1, basis 0%.
    scroll.flex_grow = 1;
    scroll.flex_basis = pct(0);
    scroll.overflow = .{ .y = .scroll };
    const scroller = try e.requestLayout(scroll, &.{content});
    const header = try leaf(&e, .{ .size = .{ .width = .auto, .height = px(20) } });
    var s = column;
    s.size = sz(100, 100);
    const root = try e.requestLayout(s, &.{ header, scroller });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, scroller, 0, 20, 100, 80);
    try expectBounds(&e, content, 0, 20, 100, 500);
}

test "visible overflow item keeps content-based minimum size" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const content = try leaf(&e, .{ .size = .{ .width = .auto, .height = px(500) } });
    var inner = column;
    inner.flex_grow = 1;
    inner.flex_basis = pct(0);
    const box = try e.requestLayout(inner, &.{content});
    var s = column;
    s.size = sz(100, 100);
    const root = try e.requestLayout(s, &.{box});
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, box, 0, 0, 100, 500);
}

test "reverse directions" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(20, 10) });
    const b = try leaf(&e, .{ .size = sz(30, 10) });
    var s = row;
    s.flex_direction = .row_reverse;
    s.size = sz(100, 10);
    const r = try e.requestLayout(s, &.{ a, b });
    const c = try leaf(&e, .{ .size = sz(10, 20) });
    const d = try leaf(&e, .{ .size = sz(10, 30) });
    var cs = column;
    cs.flex_direction = .column_reverse;
    cs.size = sz(10, 100);
    cs.justify_content = .flex_end;
    const col = try e.requestLayout(cs, &.{ c, d });
    var root_style = column;
    root_style.align_items = .flex_start;
    const root = try e.requestLayout(root_style, &.{ r, col });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 80, 0, 20, 10);
    try expectBounds(&e, b, 50, 0, 30, 10);
    // column-reverse + flex-end packs items at the physical top, last child first.
    try expectBounds(&e, d, 0, 10, 10, 30);
    try expectBounds(&e, c, 0, 40, 10, 20);
}

test "display none removes node from layout" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const hidden_child = try leaf(&e, .{ .size = sz(5, 5) });
    const hidden = try e.requestLayout(.{ .display = .none, .size = sz(50, 50) }, &.{hidden_child});
    const b = try leaf(&e, .{ .size = sz(20, 10) });
    const root = try e.requestLayout(row, &.{ hidden, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, hidden, 0, 0, 0, 0);
    try expectBounds(&e, hidden_child, 0, 0, 0, 0);
    try expectBounds(&e, b, 0, 0, 20, 10);
}

test "relative inset offsets without affecting siblings" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(20, 10), .inset = .{ .left = px(5), .top = px(3), .right = .auto, .bottom = .auto } });
    const b = try leaf(&e, .{ .size = sz(20, 10) });
    const root = try e.requestLayout(row, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 5, 3, 20, 10);
    try expectBounds(&e, b, 20, 0, 20, 10);
}

test "flex basis and aspect ratio" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .flex_basis = px(40), .size = .{ .width = px(10), .height = px(10) } });
    const b = try leaf(&e, .{ .size = .{ .width = px(30), .height = .auto }, .aspect_ratio = 1.5 });
    var s = row;
    s.align_items = .flex_start;
    const root = try e.requestLayout(s, &.{ a, b });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, a, 0, 0, 40, 10);
    try expectBounds(&e, b, 40, 0, 30, 20);
}

test "block layout stacks, fills width, collapses margins and centers auto margins" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = .{ .width = .auto, .height = px(20) }, .margin = .{ .top = px(0), .bottom = px(10), .left = px(0), .right = px(0) } });
    const b = try leaf(&e, .{ .size = sz(50, 20), .margin = .{ .top = px(15), .bottom = px(0), .left = .auto, .right = .auto } });
    var t: Text = .{ .words = 5 };
    const c = try text(&e, .{}, &t);
    const root = try e.requestLayout(.{ .padding = lp(5) }, &.{ a, b, c });
    try e.computeLayout(root, definite(210, 600));
    // Block roots stretch to the available width.
    try expectBounds(&e, a, 5, 5, 200, 20);
    try expectBounds(&e, b, 80, 40, 50, 20);
    // 200px wide -> 4 words per line -> 2 lines.
    try expectBounds(&e, c, 5, 60, 200, 40);
    try expectBounds(&e, root, 0, 0, 210, 105);
}

test "block child of flex row sizes to content" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(30, 10) });
    const b = try leaf(&e, .{ .size = sz(60, 10) });
    const blk = try e.requestLayout(.{}, &.{ a, b });
    var s = row;
    s.align_items = .flex_start;
    const root = try e.requestLayout(s, &.{blk});
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, blk, 0, 0, 60, 20);
    try expectBounds(&e, b, 0, 10, 60, 10);
}

test "min and max size on container" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const a = try leaf(&e, .{ .size = sz(500, 10) });
    var s = row;
    s.max_size = .{ .width = px(200), .height = .auto };
    s.min_size = .{ .width = .auto, .height = px(50) };
    const root = try e.requestLayout(s, &.{a});
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, root, 0, 0, 200, 50);
    try expectBounds(&e, a, 0, 0, 200, 10);
}

test "measure results are cached across recomputes" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    var t: Text = .{ .words = 8 };
    const label = try text(&e, .{}, &t);
    var s = column;
    s.size = .{ .width = px(100), .height = .auto };
    const root = try e.requestLayout(s, &.{label});
    try e.computeLayout(root, definite(800, 600));
    const first = t.calls;
    try std.testing.expect(first > 0);
    try e.computeLayout(root, definite(800, 600));
    try std.testing.expectEqual(first, t.calls);
    try expectBounds(&e, label, 0, 0, 100, 80);
}

test "clear reuses the engine for the next frame" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    for (0..3) |frame| {
        e.clear();
        const w: f32 = @floatFromInt(10 * (frame + 1));
        const a = try leaf(&e, .{ .size = sz(w, 10) });
        const root = try e.requestLayout(row, &.{a});
        try std.testing.expectEqual(@as(usize, 0), a.index());
        try e.computeLayout(root, definite(800, 600));
        try expectBounds(&e, root, 0, 0, w, 10);
    }
}

test "stretchAutoSizeToFill and intrinsic available space" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    var t: Text = .{ .words = 3 };
    const label = try text(&e, .{}, &t);
    const root = try e.requestLayout(row, &.{label});
    try e.computeLayout(root, .{ .width = .max_content, .height = .max_content });
    try expectBounds(&e, root, 0, 0, 150, 20);
    try e.computeLayout(root, .{ .width = .min_content, .height = .max_content });
    try expectBounds(&e, root, 0, 0, 50, 60);
    e.stretchAutoSizeToFill(root, .{ .width = 400, .height = 300 });
    try e.computeLayout(root, definite(400, 300));
    try expectBounds(&e, root, 0, 0, 400, 300);
    try expectBounds(&e, label, 0, 0, 150, 300);
}

test "app shell: header, sidebar and scrolling content" {
    var e = LayoutEngine.init(std.testing.allocator);
    defer e.deinit();
    const header = try leaf(&e, .{ .size = .{ .width = .auto, .height = px(40) }, .flex_shrink = 0 });
    const sidebar = try leaf(&e, .{ .size = .{ .width = px(200), .height = .auto }, .flex_shrink = 0 });
    var t: Text = .{ .words = 100 };
    const body_text = try text(&e, .{}, &t);
    var content_style = column;
    content_style.flex_grow = 1;
    content_style.flex_basis = pct(0);
    content_style.overflow = .{ .y = .scroll };
    content_style.padding = lp(10);
    const content = try e.requestLayout(content_style, &.{body_text});
    var body_style = row;
    body_style.flex_grow = 1;
    body_style.flex_basis = pct(0);
    body_style.overflow = .{ .y = .hidden };
    const body = try e.requestLayout(body_style, &.{ sidebar, content });
    var root_style = column;
    root_style.size = .all(pct(1));
    const root = try e.requestLayout(root_style, &.{ header, body });
    try e.computeLayout(root, definite(800, 600));
    try expectBounds(&e, header, 0, 0, 800, 40);
    try expectBounds(&e, body, 0, 40, 800, 560);
    try expectBounds(&e, sidebar, 0, 40, 200, 560);
    try expectBounds(&e, content, 200, 40, 600, 560);
    // 580px of text width -> 11 words per line -> 10 lines.
    try expectBounds(&e, body_text, 210, 50, 580, 200);
}
