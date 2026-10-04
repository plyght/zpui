//! `list()` element tests on the headless test platform (ported from gpui's list.rs tests).

const std = @import("std");
const testing = std.testing;
const App = @import("../app/app.zig").App;
const Context = @import("../app/context.zig").Context;
const TestWindow = @import("../app/test_platform.zig").TestWindow;
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const elements = @import("mod.zig");
const list_mod = @import("list.zig");
const div = elements.div;
const geometry = @import("../geometry.zig");
const px = geometry.px;
const ListState = list_mod.ListState;
const ListOffset = list_mod.ListOffset;
const AnyElement = @import("../window/element.zig").AnyElement;

const Bounds = geometry.Bounds(f32);

const options: window_mod.WindowOptions = .{ .bounds = .{ .origin = .zero, .size = .{ .width = 400, .height = 400 } } };

const ListView = struct {
    state: ListState,
    viewport: f32,
    item_height: f32,
    /// Height override for one item.
    special_ix: ?usize = null,
    special_height: f32 = 0,
    /// Request an autoscroll from this item's prepaint (top 30px above its own top).
    autoscroll_ix: ?usize = null,
    renders: usize = 0,

    const Args = struct { count: usize, alignment: list_mod.ListAlignment = .top, overdraw: f32 = 10, viewport: f32 = 200, item_height: f32 = 20 };

    fn init(args: Args, _: *Window, cx: *Context(ListView)) ListView {
        return .{
            .state = ListState.init(cx.gpa(), args.count, args.alignment, args.overdraw),
            .viewport = args.viewport,
            .item_height = args.item_height,
        };
    }

    pub fn deinit(self: *ListView) void {
        self.state.release();
    }

    pub fn render(self: *ListView, _: *Window, cx: *Context(ListView)) elements.Div {
        return div().w(px(100)).h(px(self.viewport)).child(list_mod.list(self.state, cx, ListView.renderItem).wFull().hFull());
    }

    fn renderItem(self: *ListView, ix: usize, _: *Window, _: *Context(ListView)) AnyElement {
        self.renders += 1;
        const h = if (self.special_ix == ix) self.special_height else self.item_height;
        if (self.autoscroll_ix == ix) {
            return elements.canvas({}, struct {
                fn p(_: void, _: Bounds, _: *Window, _: *App) void {}
            }.p).withPrepaint(void, struct {
                fn pp(_: void, b: Bounds, w: *Window, _: *App) void {
                    w.requestAutoscroll(Bounds.fromCorners(.{ .x = b.origin.x, .y = b.origin.y - 30 }, .{ .x = b.right(), .y = b.origin.y + 5 }));
                }
            }.pp).h(px(h)).wFull().intoAnyElement();
        }
        return div().h(px(h)).wFull().intoAnyElement();
    }
};

fn open(app: *App, args: ListView.Args) !struct { w: *Window, view: *ListView, state: ListState } {
    const handle = try app.openWindow(options, ListView, ListView.init, .{args});
    const w = handle.window(app).?;
    const root = handle.rootView(app).?;
    const view: *ListView = @constCast(root.read(app));
    return .{ .w = w, .view = view, .state = view.state };
}

fn redraw(app: *App, w: *Window) void {
    w.refresh();
    _ = app.drawDirtyWindows();
}

fn expectOffset(state: ListState, ix: usize, offset: f32) !void {
    const st = state.logicalScrollTop();
    errdefer std.debug.print("scroll top = ({d}, {d}), expected ({d}, {d})\n", .{ st.item_ix, st.offset_in_item, ix, offset });
    try testing.expectEqual(ix, st.item_ix);
    try testing.expectApproxEqAbs(offset, st.offset_in_item, 0.01);
}

fn wheel(w: *Window, dy: f32) void {
    const tw = TestWindow.of(w.platform_window);
    tw.moveMouse(10, 10);
    _ = tw.simulateInput(.{ .scroll_wheel = .{ .position = .{ .x = 10, .y = 10 }, .delta = .{ .pixels = .{ .x = 0, .y = dy } } } });
}

test "list: scroll_by with positive and negative distances" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 5, .viewport = 100 });
    t.state.scrollBy(30);
    try expectOffset(t.state, 1, 10);
    t.state.scrollBy(-30);
    try expectOffset(t.state, 0, 0);
    t.state.scrollBy(0);
    try expectOffset(t.state, 0, 0);
}

test "list: scroll_by from a negative item offset" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 10, .viewport = 100 });
    t.state.scrollTo(.{ .item_ix = 3, .offset_in_item = -10 });
    t.state.scrollBy(5);
    try expectOffset(t.state, 2, 15);
}

test "list: only visible items (plus overdraw) are rendered" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 10_000, .viewport = 200, .overdraw = 0 });
    try testing.expectEqual(@as(usize, 10), t.state.lastVisibleCount());
    try testing.expect(t.state.lastRenderedCount() <= 12);
    try testing.expectEqual(@as(usize, 10_000), t.state.itemCount());
    // Scroll deep into the list: still ~10 items laid out.
    t.state.scrollTo(.{ .item_ix = 5000, .offset_in_item = 7 });
    t.view.renders = 0;
    redraw(app, t.w);
    try testing.expectEqual(@as(usize, 11), t.state.lastVisibleCount());
    try testing.expect(t.view.renders <= 12);
    try expectOffset(t.state, 5000, 7);
    const b = t.state.boundsForItem(5001).?;
    try testing.expectApproxEqAbs(@as(f32, 13), b.origin.y, 0.01);
}

test "list: wheel scrolling moves the logical scroll top and clamps" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    // Overdraw covers every item, so the whole content height is known (unmeasured items
    // count as 0px, which clamps wheel scrolling to what has been measured, as in gpui).
    const t = try open(app, .{ .count = 20, .viewport = 100, .overdraw = 1000 });
    wheel(t.w, -45);
    try expectOffset(t.state, 2, 5);
    wheel(t.w, 1000);
    try expectOffset(t.state, 0, 0);
    wheel(t.w, -10_000);
    // 20 * 20 - 100 = 300 max.
    try testing.expectApproxEqAbs(@as(f32, -300), t.state.scrollPxOffsetForScrollbar().y, 0.01);
    try testing.expectEqual(@as(?bool, true), t.state.isScrolledToEnd());
}

test "list: reset after paint drops scroll events until the next paint" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 5, .viewport = 20, .item_height = 10 });
    t.state.scrollTo(.{});
    redraw(app, t.w);
    t.state.reset(5);
    wheel(t.w, -500);
    try expectOffset(t.state, 0, 0);
}

test "list: remeasure keeps the proportional offset" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 10, .viewport = 200, .item_height = 100 });
    t.state.scrollTo(.{ .item_ix = 2, .offset_in_item = 40 });
    redraw(app, t.w);
    try expectOffset(t.state, 2, 40);
    t.view.item_height = 50;
    t.state.remeasure();
    redraw(app, t.w);
    try expectOffset(t.state, 2, 20);
}

test "list: remeasure_items keeps the absolute offset" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 20, .viewport = 200, .item_height = 100 });
    t.view.special_ix = 5;
    t.view.special_height = 100;
    t.state.scrollTo(.{ .item_ix = 5, .offset_in_item = 40 });
    redraw(app, t.w);
    t.view.special_height = 200;
    t.state.remeasureItems(.{ .start = 5, .end = 6 });
    redraw(app, t.w);
    try expectOffset(t.state, 5, 40);
}

test "list: scroll after remeasure clamps to the shrunk item instead of reverting" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 20, .viewport = 200, .item_height = 100 });
    t.view.special_ix = 5;
    t.view.special_height = 100;
    t.state.scrollTo(.{ .item_ix = 5, .offset_in_item = 80 });
    redraw(app, t.w);
    t.view.special_height = 50;
    t.state.remeasureItems(.{ .start = 5, .end = 6 });
    t.state.scrollTo(.{ .item_ix = 5, .offset_in_item = 90 });
    redraw(app, t.w);
    try expectOffset(t.state, 5, 50);
}

test "list: follow tail stays at the bottom as items grow" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 10, .viewport = 200, .item_height = 50, .overdraw = 0 });
    t.state.setFollowMode(.tail);
    redraw(app, t.w);
    try expectOffset(t.state, 6, 0);
    try testing.expect(t.state.isFollowingTail());
    t.view.item_height = 80;
    t.state.remeasure();
    redraw(app, t.w);
    try expectOffset(t.state, 7, 40);
    try testing.expect(t.state.isFollowingTail());
}

test "list: follow tail disengages on user scroll and re-engages at the bottom" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 10, .viewport = 200, .item_height = 50, .overdraw = 1000 });
    t.state.setFollowMode(.tail);
    redraw(app, t.w);
    try testing.expect(t.state.isFollowingTail());
    wheel(t.w, 100); // scroll up
    try testing.expect(!t.state.isFollowingTail());
    try expectOffset(t.state, 4, 0);
    // Append: not following → the view stays where it is.
    t.state.splice(.{ .start = 10, .end = 10 }, 2);
    redraw(app, t.w);
    try expectOffset(t.state, 4, 0);
    wheel(t.w, -10_000); // back to the bottom
    redraw(app, t.w);
    try testing.expect(t.state.isFollowingTail());
    t.state.splice(.{ .start = 12, .end = 12 }, 1);
    redraw(app, t.w);
    try expectOffset(t.state, 9, 0); // 13 items * 50 - 200 = 450
}

test "list: bottom alignment starts at the end and reports the scrollbar offset" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 10, .viewport = 200, .item_height = 50, .alignment = .bottom, .overdraw = 1000 });
    try testing.expectApproxEqAbs(@as(f32, -300), t.state.scrollPxOffsetForScrollbar().y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 300), t.state.maxOffsetForScrollbar().y, 0.01);
    // Short content is pinned to the bottom of the viewport.
    const s = try open(app, .{ .count = 2, .viewport = 200, .item_height = 50, .alignment = .bottom });
    try testing.expectEqual(@as(usize, 2), s.state.lastVisibleCount());
    try testing.expectApproxEqAbs(@as(f32, 0), s.state.scrollPxOffsetForScrollbar().y, 0.01);
}

test "list: splicing above the viewport keeps the anchor item" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 100, .viewport = 200 });
    t.state.scrollTo(.{ .item_ix = 50, .offset_in_item = 5 });
    redraw(app, t.w);
    t.state.splice(.{ .start = 0, .end = 0 }, 3);
    try expectOffset(t.state, 53, 5);
    t.state.splice(.{ .start = 10, .end = 20 }, 0);
    try expectOffset(t.state, 43, 5);
    t.state.splice(.{ .start = 40, .end = 50 }, 1); // removes the anchor
    try expectOffset(t.state, 40, 0);
}

test "list: scroll_to_reveal_item scrolls minimally" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 100, .viewport = 200, .overdraw = 1000 });
    t.state.scrollToRevealItem(20); // bottom of item 20 = 420 → top 220 (left bias: item 10 + 20)
    try expectOffset(t.state, 10, 20);
    redraw(app, t.w);
    t.state.scrollToRevealItem(5);
    try expectOffset(t.state, 5, 0);
}

test "list: autoscroll above an item's top walks into earlier items" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 5, .viewport = 60, .overdraw = 10 });
    t.view.autoscroll_ix = 2;
    t.state.scrollTo(.{ .item_ix = 2, .offset_in_item = 0 });
    redraw(app, t.w);
    try expectOffset(t.state, 0, 10);
}

test "list: tail reservation reserves a viewport from the start item" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 5, .viewport = 200, .overdraw = 0 });
    t.state.setTailReservation(.{ .start = 3, .inset = 0 });
    t.state.scrollToEnd();
    redraw(app, t.w);
    // Items 3 and 4 (40px) plus 160px of reserved tail: item 3 sits at the top (60px down;
    // like gpui the logical offset may run past the first item's own height).
    try testing.expectApproxEqAbs(@as(f32, -60), t.state.scrollPxOffsetForScrollbar().y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 260), t.state.contentHeight(), 0.01);
    try testing.expect(!t.state.tailReservationFilled());
    // Appending rows consumes the reservation.
    t.state.splice(.{ .start = 5, .end = 5 }, 2);
    t.state.scrollToEnd();
    redraw(app, t.w);
    try testing.expectApproxEqAbs(@as(f32, -60), t.state.scrollPxOffsetForScrollbar().y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 260), t.state.contentHeight(), 0.01);
    t.state.splice(.{ .start = 7, .end = 7 }, 10);
    t.state.scrollToEnd();
    redraw(app, t.w);
    try testing.expect(t.state.tailReservationFilled());
    try testing.expectApproxEqAbs(@as(f32, 340), t.state.contentHeight(), 0.01);
}

test "list: item viewport queries" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const s = ListState.init(testing.allocator, 5, .top, 0);
    defer s.release();
    try testing.expectEqual(@as(?bool, null), s.itemIsAboveViewport(0));
    const t = try open(app, .{ .count = 20, .viewport = 100 });
    t.state.scrollTo(.{ .item_ix = 5, .offset_in_item = 0 });
    redraw(app, t.w);
    try testing.expectEqual(@as(?bool, true), t.state.itemIsAboveViewport(2));
    try testing.expectEqual(@as(?bool, false), t.state.itemIsBelowViewport(2));
    try testing.expectEqual(@as(?bool, false), t.state.itemIsAboveViewport(6));
    try testing.expectEqual(@as(?bool, false), t.state.itemIsBelowViewport(6));
    try testing.expectEqual(@as(?bool, true), t.state.itemIsBelowViewport(10));
}

test "list: scrollbar drag maps offsets and resumes following at the end" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 10, .viewport = 200, .item_height = 50, .overdraw = 1000 });
    t.state.setFollowMode(.tail);
    redraw(app, t.w);
    t.state.scrollbarDragStarted();
    t.state.setOffsetFromScrollbar(.{ .x = 0, .y = -100 });
    try testing.expect(!t.state.isFollowingTail());
    try expectOffset(t.state, 2, 0);
    t.state.setOffsetFromScrollbar(.{ .x = 0, .y = -300 });
    try testing.expect(t.state.isFollowingTail());
    t.state.scrollbarDragEnded();
    try testing.expect(!t.state.isScrollbarDragging());
}

// ---------------------------------------------------------------------------------------
// uniform_list
// ---------------------------------------------------------------------------------------

const ul = @import("uniform_list.zig");

const UniformView = struct {
    scroll: ul.UniformListScrollHandle,
    count: usize,
    last_range: list_mod.Range = .{ .start = 0, .end = 0 },

    fn init(count: usize, _: *Window, cx: *Context(UniformView)) UniformView {
        return .{ .scroll = ul.UniformListScrollHandle.init(cx.gpa()), .count = count };
    }

    pub fn deinit(self: *UniformView) void {
        self.scroll.release();
    }

    pub fn render(self: *UniformView, _: *Window, cx: *Context(UniformView)) elements.Div {
        return div().w(px(100)).h(px(100)).child(ul.uniformList("rows", self.count, cx, UniformView.rows).trackScroll(self.scroll).sizeFull());
    }

    fn rows(self: *UniformView, range: list_mod.Range, _: *Window, _: *Context(UniformView)) []AnyElement {
        if (range.len() > 1) self.last_range = range;
        const out = @import("../window/arena.zig").frameAllocator().alloc(AnyElement, range.len()) catch @panic("OOM");
        for (out) |*o| o.* = div().h(px(20)).wFull().intoAnyElement();
        return out;
    }
};

test "uniform_list: renders only the visible range and scrolls with strategies" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, UniformView, UniformView.init, .{1000});
    const w = handle.window(app).?;
    const view: *UniformView = @constCast(handle.rootView(app).?.read(app));
    try testing.expectEqual(@as(usize, 0), view.last_range.start);
    try testing.expectEqual(@as(usize, 5), view.last_range.end);
    try testing.expect(view.scroll.isScrollable());

    view.scroll.scrollToItem(10, .nearest); // below → bottom: 11*20 - 100 = 120
    redraw(app, w);
    try testing.expectApproxEqAbs(@as(f32, -120), view.scroll.offset().y, 0.01);
    try testing.expectEqual(@as(usize, 6), view.last_range.start);
    view.scroll.scrollToItem(8, .nearest); // visible → no scroll
    redraw(app, w);
    try testing.expectApproxEqAbs(@as(f32, -120), view.scroll.offset().y, 0.01);
    view.scroll.scrollToItem(2, .nearest); // above → top
    redraw(app, w);
    try testing.expectApproxEqAbs(@as(f32, -40), view.scroll.offset().y, 0.01);
    view.scroll.scrollToItemStrict(50, .center); // 50*20+10 - 50 = 960
    redraw(app, w);
    try testing.expectApproxEqAbs(@as(f32, -960), view.scroll.offset().y, 0.01);
    view.scroll.scrollToBottom();
    redraw(app, w);
    try testing.expectApproxEqAbs(@as(f32, -19_900), view.scroll.offset().y, 0.01);
    try testing.expectEqual(@as(?bool, true), view.scroll.isScrolledToEnd());
    try testing.expectEqual(@as(usize, 1000), view.last_range.end);
    wheel(w, 50);
    try testing.expectApproxEqAbs(@as(f32, -19_850), view.scroll.offset().y, 0.01);
    try testing.expectEqual(@as(usize, 992), view.scroll.logicalScrollTopIndex());
}

// ---------------------------------------------------------------------------------------
// animation
// ---------------------------------------------------------------------------------------

const anim_mod = @import("animation.zig");

const AnimView = struct {
    deltas: std.ArrayList(f32) = .empty,
    gpa: std.mem.Allocator,
    oneshot: bool = false,

    fn init(oneshot: bool, _: *Window, cx: *Context(AnimView)) AnimView {
        return .{ .gpa = cx.gpa(), .oneshot = oneshot };
    }
    pub fn deinit(self: *AnimView) void {
        self.deltas.deinit(self.gpa);
    }
    pub fn render(self: *AnimView, _: *Window, _: *Context(AnimView)) elements.Div {
        const a = if (self.oneshot) anim_mod.Animation.ms(100) else anim_mod.Animation.ms(1000).repeat();
        return div().sizeFull().child(div().id("x").withAnimationCtx("anim", a, self, struct {
            fn f(v: *AnimView, el: elements.StatefulDiv, t: f32) elements.StatefulDiv {
                v.deltas.append(v.gpa, t) catch {};
                return el.opacity(t);
            }
        }.f).child("hi"));
    }
};

test "animation: repeating animations schedule frames; reduced motion renders one static frame" {
    {
        const app = try App.initTest(testing.allocator);
        defer app.deinit();
        const handle = try app.openWindow(options, AnimView, AnimView.init, .{false});
        const w = handle.window(app).?;
        const tw = TestWindow.of(w.platform_window);
        const view: *AnimView = @constCast(handle.rootView(app).?.read(app));
        try testing.expectEqual(@as(usize, 1), view.deltas.items.len);
        app.advanceClock(250 * anim_mod.ns_per_ms);
        tw.frame(false);
        try testing.expectEqual(@as(usize, 2), view.deltas.items.len);
        try testing.expectApproxEqAbs(@as(f32, 0.25), view.deltas.items[1], 0.01);
        tw.frame(false);
        try testing.expectEqual(@as(usize, 3), view.deltas.items.len);
    }
    {
        const app = try App.initTest(testing.allocator);
        defer app.deinit();
        const handle = try app.openWindow(options, AnimView, AnimView.init, .{true});
        const w = handle.window(app).?;
        const tw = TestWindow.of(w.platform_window);
        const view: *AnimView = @constCast(handle.rootView(app).?.read(app));
        app.advanceClock(150 * anim_mod.ns_per_ms);
        tw.frame(false);
        try testing.expectEqual(@as(f32, 1), view.deltas.items[view.deltas.items.len - 1]);
        const n = view.deltas.items.len;
        tw.frame(false); // done: no more frames requested
        try testing.expectEqual(n, view.deltas.items.len);
    }
    {
        const app = try App.initTest(testing.allocator);
        defer app.deinit();
        const handle = try app.openWindow(options, AnimView, AnimView.init, .{false});
        const w = handle.window(app).?;
        w.prefers_reduced_motion = true;
        const view: *AnimView = @constCast(handle.rootView(app).?.read(app));
        const tw = TestWindow.of(w.platform_window);
        tw.frame(false); // drains the frame requested by the first (animated) render
        view.deltas.clearRetainingCapacity();
        redraw(app, w);
        tw.frame(false);
        try testing.expectEqual(@as(usize, 1), view.deltas.items.len);
        try testing.expectEqual(@as(f32, 0), view.deltas.items[0]);
    }
}

// ---------------------------------------------------------------------------------------
// scrollbar + effects
// ---------------------------------------------------------------------------------------

const sb_mod = @import("scrollbar.zig");
const fx = @import("effects.zig");
const color = @import("../color.zig");

const ChromeView = struct {
    state: ListState,

    fn init(_: *Window, cx: *Context(ChromeView)) ChromeView {
        return .{ .state = ListState.init(cx.gpa(), 50, .top, 2000) };
    }
    pub fn deinit(self: *ChromeView) void {
        self.state.release();
    }
    pub fn render(self: *ChromeView, _: *Window, cx: *Context(ChromeView)) elements.Div {
        return div().w(px(200)).h(px(200)).relative()
            .child(fx.edgeFaded(24, true, true, list_mod.list(self.state, cx, ChromeView.row).sizeFull()).fadeOverflowY(self.state))
            .child(sb_mod.scrollbar(self.state).withStyle(.{ .thumb = color.red }))
            .child(div().absolute().top(px(150)).left(px(0)).w(px(100)).h(px(40))
            .child(fx.frosted(8, 16, div().sizeFull().roundedLg().bg(color.white.opacity(0.5)))));
    }
    fn row(_: *ChromeView, _: usize, _: *Window, _: *Context(ChromeView)) elements.Div {
        return div().h(px(20)).wFull().bg(color.blue);
    }
};

fn redQuads(w: *Window) ?Bounds {
    for (w.rendered_frame.scene.quads.items) |q| {
        const c = q.background.solid;
        if (c.h < 0.02 and c.s > 0.9 and c.a > 0.5) {
            const s = w.scale_factor;
            return .{ .origin = .{ .x = q.bounds.origin.x / s, .y = q.bounds.origin.y / s }, .size = .{ .width = q.bounds.size.width / s, .height = q.bounds.size.height / s } };
        }
    }
    return null;
}

test "scrollbar: appears on scroll, drags the list; edge fade gates on overflow; frost blurs" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, ChromeView, ChromeView.init, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    const view: *ChromeView = @constCast(handle.rootView(app).?.read(app));
    // Idle: no thumb painted. Frost painted a backdrop blur.
    try testing.expect(redQuads(w) == null);
    try testing.expectEqual(@as(usize, 1), w.rendered_frame.scene.backdrop_blurs.items.len);
    // At the top: only the bottom edge fades.
    var top_fade = false;
    var bottom_fade = false;
    for (w.rendered_frame.scene.quads.items) |q| {
        if (q.fade.band_top > 0) top_fade = true;
        if (q.fade.band_bottom > 0) bottom_fade = true;
    }
    try testing.expect(!top_fade and bottom_fade);

    wheel(w, -100);
    _ = app.drawDirtyWindows();
    const thumb = redQuads(w) orelse return error.NoThumb;
    // 1000px content in 200px: thumb 48px min vs 40 → 48; scrolled 100/800 of the track.
    try testing.expectApproxEqAbs(@as(f32, 6), thumb.size.width, 0.01);
    try testing.expect(thumb.origin.x > 180);
    top_fade = false;
    for (w.rendered_frame.scene.quads.items) |q| if (q.fade.band_top > 0) {
        top_fade = true;
    };
    try testing.expect(top_fade);

    // Drag the thumb to the bottom.
    const grab: geometry.Point(f32) = .{ .x = thumb.origin.x + 2, .y = thumb.origin.y + 5 };
    tw.moveMouse(grab.x, grab.y);
    _ = tw.simulateInput(.{ .mouse_down = .{ .button = .left, .position = grab, .click_count = 1 } });
    try testing.expect(view.state.isScrollbarDragging());
    app.advanceClock(20 * anim_mod.ns_per_ms);
    _ = tw.simulateInput(.{ .mouse_move = .{ .position = .{ .x = grab.x, .y = 400 }, .pressed_button = .left } });
    _ = tw.simulateInput(.{ .mouse_up = .{ .button = .left, .position = .{ .x = grab.x, .y = 400 }, .click_count = 1 } });
    try testing.expect(!view.state.isScrollbarDragging());
    try testing.expectApproxEqAbs(@as(f32, -800), view.state.scrollPxOffsetForScrollbar().y, 0.01);
    try testing.expectEqual(@as(?bool, true), view.state.isScrolledToEnd());

    // After the idle delay plus fade the thumb is gone.
    app.advanceClock(3500 * anim_mod.ns_per_ms);
    tw.frame(false);
    _ = app.drawDirtyWindows();
    w.refresh();
    _ = app.drawDirtyWindows();
    try testing.expect(redQuads(w) == null);
}

test "list: scroll_by from the pinned end of a bottom-aligned list moves immediately" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const t = try open(app, .{ .count = 50, .viewport = 200, .alignment = .bottom, .overdraw = 1000 });
    t.state.setFollowMode(.tail);
    redraw(app, t.w);
    try testing.expectApproxEqAbs(@as(f32, -800), t.state.scrollPxOffsetForScrollbar().y, 0.01);
    t.state.scrollBy(-30);
    redraw(app, t.w);
    try testing.expect(!t.state.isFollowingTail());
    try testing.expectApproxEqAbs(@as(f32, -770), t.state.scrollPxOffsetForScrollbar().y, 0.01);
}
