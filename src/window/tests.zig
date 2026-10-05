//! Window + element system tests on the headless TestPlatform / TestWindow.

const std = @import("std");
const testing = std.testing;
const app_mod = @import("../app/app.zig");
const App = app_mod.App;
const Context = @import("../app/context.zig").Context;
const entity_mod = @import("../app/entity.zig");
const Entity = entity_mod.Entity;
const EntityId = entity_mod.EntityId;
const action_mod = @import("../app/action.zig");
const TestWindow = @import("../app/test_platform.zig").TestWindow;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const element = @import("element.zig");
const AnyElement = element.AnyElement;
const GlobalElementId = element.GlobalElementId;
const LayoutId = element.LayoutId;
const elements = @import("../elements/mod.zig");
const div = elements.div;
const StyleBuilder = @import("../styled.zig").StyleBuilder;
const color = @import("../color.zig");
const zpui_scene = @import("../scene.zig");
const geometry = @import("../geometry.zig");
const input = @import("../input.zig");
const events = @import("events.zig");
const FocusHandle = @import("focus.zig").FocusHandle;

const Bounds = geometry.Bounds(f32);
const px = geometry.px;
const sb = StyleBuilder.init;

const options: window_mod.WindowOptions = .{ .bounds = .{ .origin = .zero, .size = .{ .width = 400, .height = 300 } } };

fn testWindow(w: *Window) *TestWindow {
    return TestWindow.of(w.platform_window);
}

// ---------------------------------------------------------------------------------------

const Counter = struct {
    count: u32 = 0,
    renders: u32 = 0,

    fn init(_: *Window, _: *Context(Counter)) Counter {
        return .{};
    }

    pub fn render(self: *Counter, _: *Window, cx: *Context(Counter)) elements.Div {
        self.renders += 1;
        return div().flex().flexCol().size(px(400)).p(px(10)).bg(color.white).child(
            div().id("button").w(px(100)).h(px(40)).bg(color.blue)
                .onClick(cx.listener(Counter.onClick)),
        ).child("hello");
    }

    fn onClick(self: *Counter, _: *const events.ClickEvent, _: *Window, cx: *Context(Counter)) void {
        self.count += 1;
        cx.notify();
    }
};

test "open window renders the root view and presents a scene" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Counter, Counter.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    try testing.expectEqual(@as(usize, 1), tw.present_count);
    try testing.expect(!w.dirty);
    const scene = &w.rendered_frame.scene;
    // Background of root + button quad; text glyphs as sprites.
    try testing.expect(scene.quads.items.len >= 2);
    try testing.expect(scene.monochrome_sprites.items.len >= 5);
    try testing.expectEqual(@as(u32, 1), handle.rootView(app).?.read(app).renders);
}

test "click on a stateful div fires onClick and redraws only once" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Counter, Counter.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    const root = handle.rootView(app).?;
    tw.click(50, 30); // inside the button (10px padding)
    try testing.expectEqual(@as(u32, 1), root.read(app).count);
    tw.click(300, 200); // outside
    try testing.expectEqual(@as(u32, 1), root.read(app).count);
    tw.click(15, 15);
    try testing.expectEqual(@as(u32, 2), root.read(app).count);
}

// ---------------------------------------------------------------------------------------
// Lifecycle, layout and hit testing
// ---------------------------------------------------------------------------------------

const Log = struct {
    var storage: [64][40]u8 = undefined;
    var lens: [64]usize = undefined;
    var len: usize = 0;
    fn reset() void {
        len = 0;
    }
    fn push(s: []const u8) void {
        @memcpy(storage[len][0..s.len], s);
        lens[len] = s.len;
        len += 1;
    }
    fn print(comptime f: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&storage[len], f, args) catch unreachable;
        lens[len] = s.len;
        len += 1;
    }
    fn expect(expected: []const []const u8) !void {
        errdefer for (0..len) |i| std.debug.print("log[{d}] = {s}\n", .{ i, storage[i][0..lens[i]] });
        try testing.expectEqual(expected.len, len);
        for (expected, 0..) |e, i| try testing.expectEqualStrings(e, storage[i][0..lens[i]]);
    }
};

/// A leaf element that logs its phases and records its bounds.
const Probe = struct {
    name: []const u8,
    width: f32 = 20,
    height: f32 = 10,
    out: ?*Bounds = null,

    pub fn requestLayout(self: *Probe, _: ?GlobalElementId, _: *void, window: *Window, _: *App) LayoutId {
        Log.print("layout {s}", .{self.name});
        var s: @import("../style.zig").Style = .{};
        s.size = .{ .width = .{ .definite = .{ .absolute = .{ .pixels = self.width } } }, .height = .{ .definite = .{ .absolute = .{ .pixels = self.height } } } };
        return window.requestLayout(s, &.{});
    }
    pub fn prepaint(self: *Probe, _: ?GlobalElementId, b: Bounds, _: *void, _: *void, _: *Window, _: *App) void {
        Log.print("prepaint {s}", .{self.name});
        if (self.out) |o| o.* = b;
    }
    pub fn paint(self: *Probe, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, _: *Window, _: *App) void {
        Log.print("paint {s}", .{self.name});
    }
};

const LayoutView = struct {
    a: Bounds = undefined,
    b: Bounds = undefined,
    c: Bounds = undefined,

    fn init(_: *Window, _: *Context(LayoutView)) LayoutView {
        return .{};
    }

    pub fn render(self: *LayoutView, _: *Window, _: *Context(LayoutView)) elements.Div {
        return div().flex().flexCol().p(px(10)).gap(px(5)).child(Probe{ .name = "a", .out = &self.a })
            .child(div().flex().flexRow().gap(px(4)).child(Probe{ .name = "b", .out = &self.b }).child(Probe{ .name = "c", .width = 30, .out = &self.c }));
    }
};

test "element lifecycle: layout, prepaint and paint run in tree order" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    Log.reset();
    const handle = try app.openWindow(options, LayoutView, LayoutView.init, .{});
    try Log.expect(&.{ "layout a", "layout b", "layout c", "prepaint a", "prepaint b", "prepaint c", "paint a", "paint b", "paint c" });
    const v = handle.rootView(app).?.read(app);
    try testing.expectEqual(Bounds{ .origin = .{ .x = 10, .y = 10 }, .size = .{ .width = 20, .height = 10 } }, v.a);
    try testing.expectEqual(Bounds{ .origin = .{ .x = 10, .y = 25 }, .size = .{ .width = 20, .height = 10 } }, v.b);
    try testing.expectEqual(Bounds{ .origin = .{ .x = 34, .y = 25 }, .size = .{ .width = 30, .height = 10 } }, v.c);
}

test "layout snaps to device pixels at fractional scale factors" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    Log.reset();
    const handle = try app.openWindow(options, LayoutView, LayoutView.init, .{});
    const w = handle.window(app).?;
    testWindow(w).simulateResize(.{ .width = 400, .height = 300 }, 1.5);
    try testing.expectEqual(@as(f32, 1.5), w.scale_factor);
    const v = handle.rootView(app).?.read(app);
    // 10px padding * 1.5 = 15 device px; bounds come back in logical px.
    try testing.expectEqual(@as(f32, 10), v.a.origin.x);
    // 5px gap → 7.5 device px rounds toward zero to 7 → y = (15 + 15 + 7) / 1.5
    try testing.expectApproxEqAbs(@as(f32, 37.0 / 1.5), v.b.origin.y, 0.001);
}

const HitView = struct {
    fn init(_: *Window, _: *Context(HitView)) HitView {
        return .{};
    }
    pub fn render(_: *HitView, _: *Window, _: *Context(HitView)) elements.Div {
        return div().size(px(400)).child(
            div().id("back").absolute().top(px(0)).left(px(0)).size(px(100)).cursorPointer(),
        ).child(
            div().id("front").absolute().top(px(50)).left(px(50)).size(px(100)).occlude().cursorText(),
        ).child(
            div().id("glass").absolute().top(px(0)).left(px(200)).size(px(100)).blockMouseExceptScroll().cursorPointer(),
        );
    }
};

test "hit testing: front-to-back order, block_mouse occludes, cursor follows hovered hitbox" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, HitView, HitView.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    var hit: window_mod.HitTest = .{};
    defer hit.ids.deinit(testing.allocator);
    const hb = w.rendered_frame.hitboxes.items;
    try testing.expectEqual(@as(usize, 3), hb.len);
    // Only "back".
    w.rendered_frame.hitTest(.{ .x = 10, .y = 10 }, &hit);
    try testing.expectEqualSlices(window_mod.HitboxId, &.{hb[0].id}, hit.ids.items);
    // Overlap: "front" blocks "back".
    w.rendered_frame.hitTest(.{ .x = 75, .y = 75 }, &hit);
    try testing.expectEqualSlices(window_mod.HitboxId, &.{hb[1].id}, hit.ids.items);
    try testing.expectEqual(@as(usize, 1), hit.hover_hitbox_count);
    tw.moveMouse(75, 75);
    try testing.expect(hb[1].isHovered(w) and !hb[0].isHovered(w));
    try testing.expectEqual(@import("../platform/platform.zig").CursorStyle.ibeam, app.test_platform.?.cursor);
    tw.moveMouse(10, 10);
    try testing.expectEqual(@import("../platform/platform.zig").CursorStyle.pointing_hand, app.test_platform.?.cursor);
    tw.moveMouse(390, 290);
    try testing.expectEqual(@import("../platform/platform.zig").CursorStyle.arrow, app.test_platform.?.cursor);
}

// ---------------------------------------------------------------------------------------
// Mouse dispatch, hover/active styles
// ---------------------------------------------------------------------------------------

const BubbleView = struct {
    fn init(_: *Window, _: *Context(BubbleView)) BubbleView {
        return .{};
    }
    fn outerDown(_: *const input.MouseDownEvent, _: *Window, _: *App) void {
        Log.push("outer bubble");
    }
    fn outerCapture(_: *const input.MouseDownEvent, _: *Window, _: *App) void {
        Log.push("outer capture");
    }
    fn innerDown(_: *const input.MouseDownEvent, _: *Window, _: *App) void {
        Log.push("inner bubble");
    }
    fn innerCapture(_: *const input.MouseDownEvent, _: *Window, _: *App) void {
        Log.push("inner capture");
    }
    fn outside(_: *const input.MouseDownEvent, _: *Window, _: *App) void {
        Log.push("inner out");
    }
    fn stopper(self: *BubbleView, _: *const input.MouseDownEvent, _: *Window, cx: *Context(BubbleView)) void {
        _ = self;
        Log.push("stopper");
        cx.stopPropagation();
    }
    pub fn render(_: *BubbleView, _: *Window, cx: *Context(BubbleView)) elements.Div {
        return div().size(px(300))
            .onMouseDown(.left, outerDown).captureAnyMouseDown(outerCapture)
            .child(div().size(px(100)).onMouseDown(.left, innerDown).captureAnyMouseDown(innerCapture).onMouseDownOut(outside))
            .child(div().size(px(100)).onMouseDown(.right, cx.listener(BubbleView.stopper)).onMouseDown(.left, innerDown));
    }
};

test "mouse dispatch: capture root→leaf, bubble leaf→root, stopPropagation, mouse-down-out" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, BubbleView, BubbleView.init, .{});
    const tw = testWindow(handle.window(app).?);
    Log.reset();
    _ = tw.simulateInput(.{ .mouse_down = .{ .button = .left, .position = .{ .x = 50, .y = 50 } } });
    try Log.expect(&.{ "outer capture", "inner capture", "inner bubble", "outer bubble" });
    Log.reset();
    _ = tw.simulateInput(.{ .mouse_down = .{ .button = .left, .position = .{ .x = 50, .y = 150 } } });
    try Log.expect(&.{ "outer capture", "inner out", "inner bubble", "outer bubble" });
    Log.reset();
    // Right button: the stopper ends the bubble before the outer listener (which is left-only anyway).
    _ = tw.simulateInput(.{ .mouse_down = .{ .button = .right, .position = .{ .x = 50, .y = 150 } } });
    try Log.expect(&.{ "outer capture", "inner out", "stopper" });
}

const HoverView = struct {
    fn init(_: *Window, _: *Context(HoverView)) HoverView {
        return .{};
    }
    pub fn render(_: *HoverView, _: *Window, _: *Context(HoverView)) elements.Div {
        return div().size(px(300)).child(
            div().id("btn").size(px(100)).bg(color.red).hover(sb.bg(color.green)).active(sb.bg(color.blue)),
        ).child(
            // No id: hover still updates.
            div().size(px(50)).bg(color.black).hover(sb.bg(color.white)),
        );
    }
};

fn quadColorAt(w: *Window, x: f32, y: f32) ?color.Hsla {
    var found: ?color.Hsla = null;
    for (w.rendered_frame.scene.quads.items) |q| {
        const b = q.bounds;
        if (x >= b.origin.x and x < b.right() and y >= b.origin.y and y < b.bottom()) found = q.background.solid;
    }
    return found;
}

test "hover and active styles follow the mouse" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, HoverView, HoverView.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    try testing.expect(quadColorAt(w, 50, 50).?.eql(color.red));
    tw.moveMouse(50, 50);
    try testing.expect(quadColorAt(w, 50, 50).?.eql(color.green));
    _ = tw.simulateInput(.{ .mouse_down = .{ .button = .left, .position = .{ .x = 50, .y = 50 } } });
    try testing.expect(quadColorAt(w, 50, 50).?.eql(color.blue));
    _ = tw.simulateInput(.{ .mouse_up = .{ .button = .left, .position = .{ .x = 50, .y = 50 } } });
    try testing.expect(quadColorAt(w, 50, 50).?.eql(color.green));
    tw.moveMouse(250, 250);
    try testing.expect(quadColorAt(w, 50, 50).?.eql(color.red));
    // Stateless hover.
    tw.moveMouse(20, 120);
    try testing.expect(quadColorAt(w, 20, 120).?.eql(color.white));
    tw.moveMouse(250, 250);
    try testing.expect(quadColorAt(w, 20, 120).?.eql(color.black));
    // Keyboard modality suppresses hover.
    tw.moveMouse(50, 50);
    try testing.expect(quadColorAt(w, 50, 50).?.eql(color.green));
    _ = tw.simulateInput(.{ .key_down = .{ .keystroke = .{ .key = "x" } } });
    try testing.expect(quadColorAt(w, 50, 50).?.eql(color.red));
}

// ---------------------------------------------------------------------------------------
// Focus, keyboard, actions
// ---------------------------------------------------------------------------------------

const Next = action_mod.action("test::Next");
const Save = action_mod.action("test::Save");
const SaveAll = action_mod.action("test::SaveAll");

const FocusView = struct {
    root: FocusHandle,
    a: FocusHandle,
    b: FocusHandle,
    c: FocusHandle,
    saves: u32 = 0,
    save_alls: u32 = 0,
    root_saves: u32 = 0,
    subs: @import("../app/subscriber_set.zig").Subscriptions = .{},

    fn init(window: *Window, cx: *Context(FocusView)) !FocusView {
        var v: FocusView = .{
            .root = cx.focusHandle(),
            .a = cx.focusHandle().tabStop(true),
            .b = cx.focusHandle().tabStop(true).tabIndex(-1),
            .c = cx.focusHandle().tabStop(true),
        };
        try v.subs.add(cx.gpa(), try cx.onFocus(v.a, window, FocusView.aFocused));
        try v.subs.add(cx.gpa(), try cx.onBlur(v.a, window, FocusView.aBlurred));
        window.focus(v.root);
        return v;
    }
    pub fn deinit(self: *FocusView, cx: *App) void {
        self.subs.deinit(cx.gpa);
        self.root.release(cx);
        self.a.release(cx);
        self.b.release(cx);
        self.c.release(cx);
    }
    fn aFocused(_: *FocusView, _: *Window, _: *Context(FocusView)) void {
        Log.push("a focus");
    }
    fn aBlurred(_: *FocusView, _: *Window, _: *Context(FocusView)) void {
        Log.push("a blur");
    }
    fn next(_: *FocusView, _: *const Next, window: *Window, _: *Context(FocusView)) void {
        window.focusNext();
    }
    fn save(self: *FocusView, _: *const Save, _: *Window, _: *Context(FocusView)) void {
        self.saves += 1;
    }
    fn saveAll(self: *FocusView, _: *const SaveAll, _: *Window, _: *Context(FocusView)) void {
        self.save_alls += 1;
    }
    fn rootSave(self: *FocusView, _: *const Save, _: *Window, _: *Context(FocusView)) void {
        self.root_saves += 1;
    }
    pub fn render(self: *FocusView, _: *Window, cx: *Context(FocusView)) elements.Div {
        return div().trackFocus(self.root).size(px(300)).keyContext("Root").onAction(Next, cx.listener(FocusView.next))
            .onAction(Save, cx.listener(FocusView.rootSave))
            .child(div().id("a").trackFocus(self.a).keyContext("Editor").size(px(50)).onAction(Save, cx.listener(FocusView.save)))
            .child(div().id("b").trackFocus(self.b).size(px(50)).onAction(SaveAll, cx.listener(FocusView.saveAll)))
            .child(div().id("c").trackFocus(self.c).size(px(50)));
    }
};

test "focus: tab order, focus/blur events, click to focus" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    try app.bindKeys(&.{.init("tab", Next{}, null)});
    const handle = try app.openWindow(options, FocusView, FocusView.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    const v = handle.rootView(app).?;
    Log.reset();
    try testing.expectEqual(@as(usize, 3), w.rendered_frame.tab_stops.tabStopCount());
    // The root (not a tab stop, tab index 0) is focused. Order: b (index -1), root, a, c.
    tw.typeKey("tab");
    try testing.expectEqual(v.read(app).a.id, w.focused_id.?);
    try Log.expect(&.{"a focus"});
    tw.typeKey("tab");
    try testing.expectEqual(v.read(app).c.id, w.focused_id.?);
    try Log.expect(&.{ "a focus", "a blur" });
    try testing.expect(v.read(app).c.isFocused(w));
    try testing.expect(v.read(app).root.containsFocused(w));
    try testing.expect(v.read(app).c.withinFocused(w));
    tw.typeKey("tab"); // wraps to the lowest tab index
    try testing.expectEqual(v.read(app).b.id, w.focused_id.?);
    w.focus(v.read(app).c);
    try testing.expect(v.read(app).c.isFocused(w));
    try testing.expect(!v.read(app).a.containsFocused(w));
    // Clicking a focusable element focuses it.
    tw.click(10, 10);
    try testing.expectEqual(v.read(app).a.id, w.focused_id.?);
}

test "actions: keymap dispatch by context, bubble stops by default, multi-stroke with timeout" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    try app.bindKeys(&.{
        .init("ctrl-s", Save{}, "Editor"),
        .init("ctrl-k", Save{}, "Root"),
        .init("ctrl-k ctrl-s", SaveAll{}, null),
    });
    const handle = try app.openWindow(options, FocusView, FocusView.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    const v = handle.rootView(app).?;
    // Editor context only exists along a's path (the root is focused initially).
    tw.typeKey("ctrl-s");
    try testing.expectEqual(@as(u32, 0), v.read(app).saves);
    w.focus(v.read(app).a);
    tw.typeKey("ctrl-s");
    try testing.expectEqual(@as(u32, 1), v.read(app).saves);
    try testing.expectEqual(@as(u32, 0), v.read(app).root_saves); // bubble stopped at a
    // ctrl-k is a bound prefix of ctrl-k ctrl-s: pending until the 1s timeout.
    w.focus(v.read(app).b);
    tw.typeKey("ctrl-k");
    try testing.expect(w.hasPendingKeystrokes());
    tw.typeKey("ctrl-s");
    try testing.expect(!w.hasPendingKeystrokes());
    try testing.expectEqual(@as(u32, 1), v.read(app).save_alls);
    tw.typeKey("ctrl-k");
    app.advanceClock(999 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 0), v.read(app).root_saves);
    app.advanceClock(2 * std.time.ns_per_ms);
    try testing.expect(!w.hasPendingKeystrokes());
    try testing.expectEqual(@as(u32, 1), v.read(app).root_saves);
    try testing.expect(w.isActionAvailable(SaveAll));
    w.dispatchAction(SaveAll{});
    try testing.expectEqual(@as(u32, 2), v.read(app).save_alls);
}

// ---------------------------------------------------------------------------------------
// Element state, view caching and invalidation
// ---------------------------------------------------------------------------------------

/// Counts how many frames an element with this id has existed (custom element state).
const Ticker = struct {
    id: []const u8,
    out: *u32,

    const State = struct { frames: u32 = 0 };

    pub fn elementId(self: *Ticker) ?element.ElementId {
        return .from(self.id);
    }
    pub fn requestLayout(_: *Ticker, _: ?GlobalElementId, _: *void, window: *Window, _: *App) LayoutId {
        return window.requestLayout(.{}, &.{});
    }
    pub fn prepaint(self: *Ticker, gid: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, _: *App) void {
        const st = window.elementState(State, gid.?);
        st.frames += 1;
        self.out.* = st.frames;
    }
    pub fn paint(_: *Ticker, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, _: *Window, _: *App) void {}
};

const StateView = struct {
    show: bool = true,
    frames_a: u32 = 0,
    frames_b: u32 = 0,
    fn init(_: *Window, _: *Context(StateView)) StateView {
        return .{};
    }
    pub fn render(self: *StateView, _: *Window, _: *Context(StateView)) elements.Div {
        const d = div().child(Ticker{ .id = "b", .out = &self.frames_b });
        return if (self.show) d.child(div().id("wrap").child(Ticker{ .id = "a", .out = &self.frames_a })) else d;
    }
    fn toggle(self: *StateView, cx: *Context(StateView)) void {
        self.show = !self.show;
        cx.notify();
    }
};

test "element state persists across frames and dies with its element" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, StateView, StateView.init, .{});
    const w = handle.window(app).?;
    const v = handle.rootView(app).?;
    try testing.expectEqual(@as(u32, 1), v.read(app).frames_a);
    w.refresh();
    _ = app.drawDirtyWindows();
    w.refresh();
    _ = app.drawDirtyWindows();
    try testing.expectEqual(@as(u32, 3), v.read(app).frames_a);
    try testing.expectEqual(@as(u32, 3), v.read(app).frames_b);
    v.update(app, StateView.toggle, .{}); // "a" disappears: its state is dropped
    v.update(app, StateView.toggle, .{});
    try testing.expectEqual(@as(u32, 1), v.read(app).frames_a);
    try testing.expectEqual(@as(u32, 5), v.read(app).frames_b);
}

const Leaf = struct {
    label: []const u8,
    renders: u32 = 0,
    pub fn render(self: *Leaf, _: *Window, _: *Context(Leaf)) elements.Div {
        self.renders += 1;
        return div().h(px(20)).child(self.label);
    }
    fn setLabel(self: *Leaf, label: []const u8, cx: *Context(Leaf)) void {
        self.label = label;
        cx.notify();
    }
};

const Shell = struct {
    left: Entity(Leaf),
    right: Entity(Leaf),
    renders: u32 = 0,
    cache: bool,

    fn init(cache: bool, _: *Window, cx: *Context(Shell)) !Shell {
        return .{ .left = try cx.new(Leaf, .{ .label = "left" }), .right = try cx.new(Leaf, .{ .label = "right" }), .cache = cache };
    }
    pub fn deinit(self: *Shell, cx: *App) void {
        self.left.release(cx);
        self.right.release(cx);
    }
    pub fn render(self: *Shell, _: *Window, _: *Context(Shell)) elements.Div {
        self.renders += 1;
        const full = sb.wFull().h(px(20)).refinement;
        if (!self.cache) return div().flex().flexCol().child(self.left).child(self.right);
        return div().flex().flexCol()
            .child(self.left.cached(full))
            .child(window_mod.view.AnyView.fromEntity(self.right).cached(full));
    }
};

test "notify redraws the window; cached views re-render only when dirty" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Shell, Shell.init, .{true});
    const w = handle.window(app).?;
    const shell = handle.rootView(app).?;
    const left = shell.read(app).left;
    const right = shell.read(app).right;
    try testing.expectEqual(@as(u32, 1), left.read(app).renders);
    const glyphs_before = w.rendered_frame.scene.monochrome_sprites.items.len;
    try testing.expectEqual(@as(usize, 9), glyphs_before); // "left" + "right"

    // Notifying the left leaf re-renders it and its ancestors, but reuses the right one.
    left.update(app, Leaf.setLabel, .{"LEFT!"});
    try testing.expectEqual(@as(u32, 2), left.read(app).renders);
    try testing.expectEqual(@as(u32, 1), right.read(app).renders);
    try testing.expectEqual(@as(u32, 2), shell.read(app).renders);
    try testing.expectEqual(@as(usize, 10), w.rendered_frame.scene.monochrome_sprites.items.len);

    // A full refresh disables reuse.
    w.refresh();
    _ = app.drawDirtyWindows();
    try testing.expectEqual(@as(u32, 2), right.read(app).renders);

    // Notifying an entity the window never read does not redraw.
    const frames = w.frame_count;
    const unrelated = try app.new(Leaf, .{ .label = "x" });
    defer unrelated.release(app);
    unrelated.update(app, Leaf.setLabel, .{"y"});
    try testing.expectEqual(frames, w.frame_count);
}

test "uncached child views re-render with their parent" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Shell, Shell.init, .{false});
    const shell = handle.rootView(app).?;
    const left = shell.read(app).left;
    const right = shell.read(app).right;
    left.update(app, Leaf.setLabel, .{"L"});
    try testing.expectEqual(@as(u32, 2), right.read(app).renders);
}

// ---------------------------------------------------------------------------------------
// Deferred, text, scrolling
// ---------------------------------------------------------------------------------------

const DeferView = struct {
    fn init(_: *Window, _: *Context(DeferView)) DeferView {
        return .{};
    }
    pub fn render(_: *DeferView, _: *Window, _: *Context(DeferView)) elements.Div {
        return div().size(px(300))
            .child(div().size(px(100)).child(elements.deferred(Probe{ .name = "menu" }).withPriority(1)))
            .child(Probe{ .name = "after" })
            .child(elements.deferred(Probe{ .name = "top" }).withPriority(5))
            .child(elements.deferred(elements.anchored().position(.{ .x = 390, .y = 290 }).child(Probe{ .name = "pop", .width = 50, .height = 50 })));
    }
};

test "deferred draws paint after the tree, by priority; anchored flips to fit" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    Log.reset();
    _ = try app.openWindow(options, DeferView, DeferView.init, .{});
    try Log.expect(&.{
        "layout menu",    "layout after",  "layout top",  "layout pop",
        "prepaint after", "prepaint pop",  "prepaint menu", "prepaint top",
        "paint after",    "paint pop",     "paint menu",    "paint top",
    });
}

const TextView = struct {
    text: []const u8 = "hello world foo bar",
    width: f32 = 85,
    fn init(_: *Window, _: *Context(TextView)) TextView {
        return .{};
    }
    pub fn render(self: *TextView, _: *Window, _: *Context(TextView)) elements.Div {
        return div().flex().flexCol().child(div().id("t").w(px(self.width)).textSize(px(16)).lineHeight(px(20)).child(self.text))
            .child(div().id("u").w(px(60)).truncate().child("truncate me please"));
    }
};

test "text wraps at the container width and truncates with an ellipsis" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, TextView, TextView.init, .{});
    const w = handle.window(app).?;
    // Fake text system: 10px per char at 16px. "hello world foo bar" in 85px → 3 lines.
    var lines: f32 = 0;
    var min_y: f32 = 1e9;
    var max_y: f32 = 0;
    for (w.rendered_frame.scene.monochrome_sprites.items) |sp| {
        if (sp.bounds.origin.y > 60) continue;
        min_y = @min(min_y, sp.bounds.origin.y);
        max_y = @max(max_y, sp.bounds.origin.y);
    }
    lines = (max_y - min_y) / 20 + 1;
    try testing.expectEqual(@as(f32, 3), lines);
    // Truncated line: at most 6 glyph cells (5 letters + ellipsis) in 60px.
    var trunc: usize = 0;
    for (w.rendered_frame.scene.monochrome_sprites.items) |sp| {
        if (sp.bounds.origin.y > 60) trunc += 1;
    }
    try testing.expect(trunc > 0 and trunc <= 6);
}

const ScrollView = struct {
    handle: elements.ScrollHandle,
    fn init(_: *Window, cx: *Context(ScrollView)) ScrollView {
        return .{ .handle = elements.ScrollHandle.init(cx.gpa()) };
    }
    pub fn deinit(self: *ScrollView) void {
        self.handle.release();
    }
    pub fn render(self: *ScrollView, _: *Window, _: *Context(ScrollView)) elements.Div {
        var list = div().id("list").flex().flexCol().h(px(100)).w(px(100)).overflowYScroll().trackScroll(self.handle);
        for (0..10) |_| list = list.child(div().h(px(30)).flexShrink0());
        return div().child(list);
    }
};

test "scroll wheel moves an overflow-scroll div, clamped to its content" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, ScrollView, ScrollView.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    const sh = handle.rootView(app).?.read(app).handle;
    try testing.expectEqual(@as(usize, 10), sh.childrenCount());
    try testing.expectEqual(@as(f32, 200), sh.maxOffset().y);
    tw.moveMouse(50, 50);
    _ = tw.simulateInput(.{ .scroll_wheel = .{ .position = .{ .x = 50, .y = 50 }, .delta = .{ .pixels = .{ .x = 0, .y = -45 } } } });
    try testing.expectEqual(@as(f32, -45), sh.offset().y);
    try testing.expectEqual(@as(f32, 30), sh.boundsForItem(1).?.origin.y); // unscrolled, like gpui
    try testing.expectEqual(@as(usize, 1), sh.topItem());
    _ = tw.simulateInput(.{ .scroll_wheel = .{ .position = .{ .x = 50, .y = 50 }, .delta = .{ .lines = .{ .x = 0, .y = -100 } } } });
    try testing.expectEqual(@as(f32, -200), sh.offset().y); // clamped on the next frame
    sh.scrollToItem(0);
    w.refresh();
    _ = app.drawDirtyWindows();
    try testing.expectEqual(@as(f32, 0), sh.offset().y);
}

// ---------------------------------------------------------------------------------------
// Drag and drop, tooltips, IME, interactive text, components
// ---------------------------------------------------------------------------------------

const Card = struct { ix: u32 };

const Preview = struct {
    ix: u32,
    pub fn render(_: *Preview, _: *Window, _: *Context(Preview)) elements.Div {
        return div().size(px(30)).bg(color.yellow);
    }
};

const DragView = struct {
    dropped: ?u32 = null,
    fn init(_: *Window, _: *Context(DragView)) DragView {
        return .{};
    }
    fn buildPreview(value: *const Card, _: geometry.Point(f32), _: *Window, cx: *App) Entity(Preview) {
        return cx.new(Preview, .{ .ix = value.ix }) catch @panic("OOM");
    }
    fn onDrop(self: *DragView, card: *const Card, _: *Window, cx: *Context(DragView)) void {
        self.dropped = card.ix;
        cx.notify();
    }
    pub fn render(_: *DragView, _: *Window, cx: *Context(DragView)) elements.Div {
        return div().size(px(400))
            .child(div().id("card").absolute().top(px(0)).left(px(0)).size(px(50)).bg(color.red).onDrag(Card{ .ix = 7 }, buildPreview))
            .child(div().id("target").absolute().top(px(200)).left(px(200)).size(px(100)).bg(color.black)
                .dragOver(Card, sb.bg(color.green)).onDrop(Card, cx.listener(DragView.onDrop)));
    }
};

test "drag and drop: drag threshold, preview, drag-over style, typed drop" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, DragView, DragView.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    tw.moveMouse(10, 10);
    _ = tw.simulateInput(.{ .mouse_down = .{ .button = .left, .position = .{ .x = 10, .y = 10 } } });
    tw.moveMouse(11, 11); // below the threshold
    try testing.expect(!app.hasActiveDrag());
    _ = tw.simulateInput(.{ .mouse_move = .{ .position = .{ .x = 20, .y = 20 }, .pressed_button = .left } });
    try testing.expect(app.hasActiveDrag());
    try testing.expectEqual(@as(u32, 7), app.activeDrag(Card).?.ix);
    _ = tw.simulateInput(.{ .mouse_move = .{ .position = .{ .x = 250, .y = 250 }, .pressed_button = .left } });
    try testing.expect(quadColorAt(w, 220, 220).?.eql(color.green)); // drag-over style
    try testing.expect(quadColorAt(w, 245, 245).?.eql(color.yellow)); // preview at mouse - offset
    _ = tw.simulateInput(.{ .mouse_up = .{ .button = .left, .position = .{ .x = 250, .y = 250 } } });
    try testing.expect(!app.hasActiveDrag());
    try testing.expectEqual(@as(?u32, 7), handle.rootView(app).?.read(app).dropped);
    try testing.expect(quadColorAt(w, 220, 220).?.eql(color.black));
}

const TipView = struct {
    fn init(_: *Window, _: *Context(TipView)) TipView {
        return .{};
    }
    fn tip(label: []const u8, _: *Window, cx: *App) Entity(Leaf) {
        return cx.new(Leaf, .{ .label = label }) catch @panic("OOM");
    }
    pub fn render(_: *TipView, _: *Window, _: *Context(TipView)) elements.Div {
        return div().size(px(400)).child(div().id("btn").size(px(50)).tooltipWith(@as([]const u8, "tip!"), tip));
    }
};

test "tooltips show after the delay and hide when the mouse leaves" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, TipView, TipView.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    tw.moveMouse(10, 10);
    try testing.expect(w.tooltip_bounds == null);
    app.advanceClock(499 * std.time.ns_per_ms);
    try testing.expect(w.tooltip_bounds == null);
    app.advanceClock(2 * std.time.ns_per_ms);
    try testing.expect(w.tooltip_bounds != null);
    try testing.expectEqual(@as(f32, 11), w.tooltip_bounds.?.bounds.origin.x);
    try testing.expectEqual(@as(usize, 4), w.rendered_frame.scene.monochrome_sprites.items.len); // "tip!"
    tw.moveMouse(300, 300);
    try testing.expect(w.tooltip_bounds == null);
}

/// zeron's `text_tooltip_above`: a zero-height, end-justified column so the card
/// overflows upward, lifted 20px by `relative().bottom(20)`.
const AboveTip = struct {
    pub fn render(_: *AboveTip, _: *Window, _: *Context(AboveTip)) elements.Div {
        return div().h(px(0)).flex().flexCol().justifyEnd()
            .child(div().relative().bottom(px(20)).child(div().w(px(40)).h(px(30)).bg(color.red)));
    }
};

const AboveTipView = struct {
    fn init(_: *Window, _: *Context(AboveTipView)) AboveTipView {
        return .{};
    }
    fn tip(_: *Window, cx: *App) Entity(AboveTip) {
        return cx.new(AboveTip, .{}) catch @panic("OOM");
    }
    pub fn render(_: *AboveTipView, _: *Window, _: *Context(AboveTipView)) elements.Div {
        return div().size(px(400)).child(div().id("btn").mt(px(100)).size(px(50)).tooltip(tip));
    }
};

test "tooltip anchored at mouse + 1; an end-justified zero-height tooltip overflows upward" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, AboveTipView, AboveTipView.init, .{});
    const w = handle.window(app).?;
    testWindow(w).moveMouse(10, 120);
    app.advanceClock(501 * std.time.ns_per_ms);
    const tb = w.tooltip_bounds.?.bounds;
    try testing.expectEqual(@as(f32, 11), tb.origin.x);
    try testing.expectEqual(@as(f32, 121), tb.origin.y);
    // gpui/taffy: justify-content: flex-end is unsafe alignment, so the 30px card sits
    // above the zero-height box (121 - 30), then 20px higher.
    var card: ?zpui_scene.Quad = null;
    for (w.rendered_frame.scene.quads.items) |q| if (q.background.solid.eql(color.red)) {
        card = q;
    };
    try testing.expectEqual(@as(f32, 121 - 30 - 20), card.?.bounds.origin.y / w.scaleFactor());
}

const Editor = struct {
    text: [64]u8 = undefined,
    len: usize = 0,
    focus: FocusHandle,
    fn init(window: *Window, cx: *Context(Editor)) Editor {
        const f = cx.focusHandle();
        window.focus(f);
        return .{ .focus = f };
    }
    pub fn deinit(self: *Editor, cx: *App) void {
        self.focus.release(cx);
    }
    pub fn replaceTextInRange(self: *Editor, _: ?window_mod.input_handler.Range, text: []const u8, _: *Window, cx: *Context(Editor)) void {
        @memcpy(self.text[self.len..][0..text.len], text);
        self.len += text.len;
        cx.notify();
    }
    pub fn render(self: *Editor, _: *Window, cx: *Context(Editor)) elements.Div {
        return div().trackFocus(self.focus).size(px(200)).child(InputCatcher{ .view = cx.weakEntity().id, .focus = self.focus })
            .child(self.text[0..self.len]);
    }
};

/// Registers the editor as the window's text input handler while focused.
const InputCatcher = struct {
    view: EntityId,
    focus: FocusHandle,
    pub fn requestLayout(_: *InputCatcher, _: ?GlobalElementId, _: *void, window: *Window, _: *App) LayoutId {
        return window.requestLayout(.{}, &.{});
    }
    pub fn prepaint(_: *InputCatcher, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, _: *Window, _: *App) void {}
    pub fn paint(self: *InputCatcher, _: ?GlobalElementId, b: Bounds, _: *void, _: *void, window: *Window, _: *App) void {
        window.handleInput(self.focus, .init(Entity(Editor){ .id = self.view }, b));
    }
};

test "IME bridge: unhandled printable keys reach the focused element's input handler" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Editor, Editor.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    try testing.expect(tw.input_handler != null);
    _ = tw.simulateInput(.{ .key_down = .{ .keystroke = .{ .key = "h", .key_char = "h" } } });
    _ = tw.simulateInput(.{ .key_down = .{ .keystroke = .{ .key = "i", .key_char = "i" } } });
    try testing.expectEqualStrings("hi", handle.rootView(app).?.read(app).text[0..2]);
    // Platform IME calls go through the window bridge.
    const h = tw.input_handler.?;
    h.vtable.replaceTextInRange(h.ptr, null, "!");
    try testing.expectEqual(@as(usize, 3), handle.rootView(app).?.read(app).len);
}

const LinkView = struct {
    clicked: ?usize = null,
    hovered: ?usize = null,
    fn init(_: *Window, _: *Context(LinkView)) LinkView {
        return .{};
    }
    fn onLink(self: *LinkView, ix: *const usize, _: *Window, cx: *Context(LinkView)) void {
        self.clicked = ix.*;
        cx.notify();
    }
    fn onHover(self: *LinkView, ix: *const ?usize, _: *Window, _: *Context(LinkView)) void {
        self.hovered = ix.*;
    }
    pub fn render(_: *LinkView, _: *Window, cx: *Context(LinkView)) elements.Div {
        const st = elements.styledText("see docs here").withHighlights(&.{.{ .start = 4, .end = 8, .style = .{ .color = color.blue } }});
        return div().textSize(px(16)).child(elements.InteractiveText.init("link", st)
            .onClick(&.{.{ 4, 8 }}, cx.listener(LinkView.onLink)).onHover(cx.listener(LinkView.onHover)));
    }
};

test "interactive text: clickable ranges and hover index" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, LinkView, LinkView.init, .{});
    const tw = testWindow(handle.window(app).?);
    tw.click(5, 5); // "s" of "see": not a link
    try testing.expectEqual(@as(?usize, null), handle.rootView(app).?.read(app).clicked);
    tw.click(55, 5); // "d" of "docs" (10px per char)
    try testing.expectEqual(@as(?usize, 0), handle.rootView(app).?.read(app).clicked);
    try testing.expectEqual(@as(?usize, 5), handle.rootView(app).?.read(app).hovered);
    try testing.expectEqual(@import("../platform/platform.zig").CursorStyle.pointing_hand, app.test_platform.?.cursor);
}

const Badge = struct {
    label: []const u8,
    pub fn render(self: Badge, _: *Window, _: *App) elements.Div {
        return div().px(px(4)).bg(color.red).child(self.label);
    }
};

const MiscView = struct {
    picked: u32 = 0,
    painted: bool = false,
    fn init(_: *Window, _: *Context(MiscView)) MiscView {
        return .{};
    }
    fn pick(self: *MiscView, ix: u32, _: *const events.ClickEvent, _: *Window, cx: *Context(MiscView)) void {
        self.picked = ix;
        cx.notify();
    }
    fn paintCanvas(self: *MiscView, b: Bounds, window: *Window, _: *App) void {
        self.painted = true;
        window.paintQuad(window_mod.paint_mod.fill(b, color.green));
    }
    pub fn render(self: *MiscView, _: *Window, cx: *Context(MiscView)) elements.Div {
        var row = div().flex();
        for (0..3) |i| row = row.child(div().id(.{ "item", i }).size(px(20)).onClick(cx.listenerWith(@as(u32, @intCast(i)), MiscView.pick)));
        return div().flex().flexCol().child(row)
            .child(Badge{ .label = "new" })
            .child(elements.canvas(self, MiscView.paintCanvas).size(px(10)))
            .child(@as(?elements.Div, null))
            .when(self.picked == 2, elements.Div.bg, .{color.blue})
            .opacity(0.5);
    }
};

test "listenerWith data, RenderOnce components, canvas, when(), opacity" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, MiscView, MiscView.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    const v = handle.rootView(app).?;
    try testing.expect(v.read(app).painted);
    tw.click(45, 5);
    try testing.expectEqual(@as(u32, 2), v.read(app).picked);
    // Root background now blue at half opacity.
    const q = w.rendered_frame.scene.quads.items[0];
    try testing.expect(q.background.solid.eql(color.blue.opacity(0.5)));
    // Badge text rendered: "new" = 3 glyphs.
    try testing.expect(w.rendered_frame.scene.monochrome_sprites.items.len >= 3);
}

test "closing a window and deinit with open windows release everything" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const a = try app.openWindow(options, Counter, Counter.init, .{});
    _ = try app.openWindow(options, FocusView, FocusView.init, .{});
    try testing.expectEqual(@as(usize, 2), app.windowCount());
    testWindow(a.window(app).?).simulateClose();
    try testing.expectEqual(@as(usize, 1), app.windowCount());
    try testing.expect(a.window(app) == null);
    app.runUntilParked(); // destroys the closed window
    try testing.expect(a.update(app, Counter.onClick, .{&events.ClickEvent{ .keyboard = .{} }}) == null);
}

const Clicks = struct { n: u32 = 0 };

/// A component with its own reactive state via `useKeyedState`.
const ClickCounter = struct {
    pub fn render(_: ClickCounter, window: *Window, cx: *App) elements.StatefulDiv {
        const gid = window.pushElementId(.from("clicks"));
        defer window.popElementId();
        const st = window.useKeyedState(Clicks, gid, struct {
            fn f(_: *App) Clicks {
                return .{};
            }
        }.f);
        rendered_clicks = st.read(cx).n;
        return div().id("cc").size(px(40)).child(zpui_fmt("{d}", .{st.read(cx).n})).onClick(Listener(events.ClickEvent){
            .func = struct {
                fn f(d: *const @import("../app/context.zig").ListenerData, _: *const events.ClickEvent, _: ?*Window, a: *App) void {
                    const e: Entity(Clicks) = .{ .id = .fromKey(d.entity) };
                    var l = e.lease(a);
                    defer l.end();
                    l.value.n += 1;
                    l.cx.notify();
                }
            }.f,
            .data = .{ .entity = st.id.toKey() },
        });
    }
};
const zpui_fmt = @import("arena.zig").fmt;
var rendered_clicks: u32 = 0;
const Listener = @import("../app/context.zig").Listener;

const KeyedView = struct {
    fn init(_: *Window, _: *Context(KeyedView)) KeyedView {
        return .{};
    }
    pub fn render(_: *KeyedView, _: *Window, _: *Context(KeyedView)) elements.Div {
        return div().child(ClickCounter{});
    }
};

test "useKeyedState gives components entity state that survives re-renders" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, KeyedView, KeyedView.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    try testing.expectEqual(@as(usize, 1), w.rendered_frame.scene.monochrome_sprites.items.len); // "0"
    tw.click(5, 5);
    tw.click(5, 5);
    // The Clicks entity was notified; the window read it during render, so it redrew.
    try testing.expectEqual(@as(u32, 2), rendered_clicks);
}

// ---------------------------------------------------------------------------------------
// Images and SVG
// ---------------------------------------------------------------------------------------

const tiny_svg = "<svg width=\"8\" height=\"4\" xmlns=\"http://www.w3.org/2000/svg\"><rect width=\"8\" height=\"4\" fill=\"#00ff00\"/></svg>";

const ImageView = struct {
    fn init(_: *Window, _: *Context(ImageView)) ImageView {
        return .{};
    }
    pub fn render(_: *ImageView, _: *Window, _: *Context(ImageView)) elements.Div {
        const image = @import("../image/image.zig");
        return div().flex().flexCol()
            .child(elements.img(image.EncodedImage.fromBytes(tiny_svg)).roundedSm())
            .child(elements.svg().source("tiny", tiny_svg).size(px(16)).textColor(color.red));
    }
};

test "img decodes on a worker and paints when ready; svg paints a tinted mask" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, ImageView, ImageView.init, .{});
    const w = handle.window(app).?;
    const scene = &w.rendered_frame.scene;
    try testing.expectEqual(@as(usize, 0), scene.polychrome_sprites.items.len); // still decoding
    try testing.expectEqual(@as(usize, 1), scene.monochrome_sprites.items.len); // the svg icon
    try testing.expect(scene.monochrome_sprites.items[0].color.eql(color.red));
    app.runUntilParked(); // background decode + finish → refresh
    try testing.expectEqual(@as(usize, 1), w.rendered_frame.scene.polychrome_sprites.items.len);
    const sprite = w.rendered_frame.scene.polychrome_sprites.items[0];
    // Natural size of the decoded SVG image: 8x4 logical px.
    try testing.expectEqual(@as(f32, 8), sprite.bounds.size.width);
    try testing.expectEqual(@as(f32, 4), sprite.bounds.size.height);
}

const SvgInteractView = struct {
    fn init(_: *Window, _: *Context(SvgInteractView)) SvgInteractView {
        return .{};
    }
    pub fn render(_: *SvgInteractView, _: *Window, _: *Context(SvgInteractView)) elements.Div {
        return div().sizeFull().child(
            div().group("row").absolute().left(px(100)).top(px(40)).w(px(100)).h(px(20)).child(
                elements.svg().source("tiny", tiny_svg).size(px(16)).textColor(color.red)
                    .groupHover("row", sb.textColor(color.green))
                    .withTransformation(elements.SvgTransformation.rotate(std.math.pi / 2.0)),
            ),
        );
    }
};

test "svg: transformation rotates about the bounds center; groupHover restyles it" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, SvgInteractView, SvgInteractView.init, .{});
    const w = handle.window(app).?;
    var sprites = w.rendered_frame.scene.monochrome_sprites.items;
    try testing.expectEqual(@as(usize, 1), sprites.len);
    try testing.expect(sprites[0].color.eql(color.red));
    // The center of the svg (108, 48) must be a fixed point of the transform (gpui
    // `Transformation::into_matrix`), so the icon spins in place.
    const m = sprites[0].transformation;
    const s = w.scaleFactor();
    const cx: f32 = 108 * s;
    const cy: f32 = 48 * s;
    const tx = m.rotation_scale[0][0] * cx + m.rotation_scale[0][1] * cy + m.translation[0];
    const ty = m.rotation_scale[1][0] * cx + m.rotation_scale[1][1] * cy + m.translation[1];
    try testing.expectApproxEqAbs(cx, tx, 1e-3);
    try testing.expectApproxEqAbs(cy, ty, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 0), m.rotation_scale[0][0], 1e-6);
    // Hovering the group (outside the svg's own bounds) applies the group hover style.
    testWindow(w).moveMouse(180, 50);
    sprites = w.rendered_frame.scene.monochrome_sprites.items;
    try testing.expectEqual(@as(usize, 1), sprites.len);
    try testing.expect(sprites[0].color.eql(color.green));
    testWindow(w).moveMouse(10, 10);
    try testing.expect(w.rendered_frame.scene.monochrome_sprites.items[0].color.eql(color.red));
}

// ---------------------------------------------------------------------------------------
// API coverage: every builder and window API used at least once (Zig compiles lazily).
// ---------------------------------------------------------------------------------------

const CoverageView = struct {
    focus: FocusHandle,
    scroll: elements.ScrollHandle,
    fn init(_: *Window, cx: *Context(CoverageView)) CoverageView {
        return .{ .focus = cx.focusHandle(), .scroll = elements.ScrollHandle.init(cx.gpa()) };
    }
    pub fn deinit(self: *CoverageView, cx: *App) void {
        self.focus.release(cx);
        self.scroll.release();
    }
    fn onKeyDown(_: *const input.KeyDownEvent, _: *Window, _: *App) void {}
    fn onKeyUp(_: *const input.KeyUpEvent, _: *Window, _: *App) void {}
    fn onMods(_: *const input.ModifiersChangedEvent, _: *Window, _: *App) void {}
    fn onUp(_: *const input.MouseUpEvent, _: *Window, _: *App) void {}
    fn onMove(_: *const input.MouseMoveEvent, _: *Window, _: *App) void {}
    fn onExit(_: *const input.MouseExitEvent, _: *Window, _: *App) void {}
    fn onWheel(_: *const input.ScrollWheelEvent, _: *Window, _: *App) void {}
    fn onClickFree(_: *const events.ClickEvent, _: *Window, _: *App) void {}
    fn onHoverFree(_: *const bool, _: *Window, _: *App) void {}
    fn onSave(_: *const Save, _: *Window, _: *App) void {}
    fn onCard(_: *const Card, _: *Window, _: *App) void {}
    fn onCardMove(_: *const events.DragMoveEvent(Card), _: *Window, _: *App) void {}
    fn onKids(_: *const []const Bounds, _: *Window, _: *App) void {}
    fn canDropAll(_: *const anyopaque, _: @import("../app/type_id.zig").TypeId, _: *Window, _: *App) bool {
        return true;
    }
    fn tip(_: *Window, cx: *App) Entity(Leaf) {
        return cx.new(Leaf, .{ .label = "t" }) catch @panic("OOM");
    }
    fn paintAll(_: *CoverageView, b: Bounds, w: *Window, _: *App) void {
        const paint = window_mod.paint_mod;
        w.paintQuad(paint.outline(b, color.red, .dashed));
        w.paintQuad(paint.quad(b, .all(2), color.blue, .all(1), color.black, .solid).cornerRadii(@as(f32, 3)).borderWidths(@as(f32, 1)).borderColor(color.green));
        w.paintShadows(b, .all(4), &.{.{ .color = color.black, .offset = .zero, .blur_radius = 2, .inset = true }});
        w.paintBackdropBlur(b, .all(4), 8);
        var path = @import("../scene.zig").Path.init(.{ .x = 0, .y = 0 });
        defer path.deinit(w.gpa);
        path.lineTo(w.gpa, .{ .x = 5, .y = 0 }) catch {};
        path.lineTo(w.gpa, .{ .x = 5, .y = 5 }) catch {};
        w.paintPath(path, color.red);
        w.paintUnderline(b.origin, 10, .{ .thickness = 1, .color = color.red, .wavy = true });
        w.paintStrikethrough(b.origin, 10, .{ .thickness = 1, .color = color.red });
        const layer = w.pushLayer(b);
        w.popLayer(layer);
        const fade = w.pushEdgeFade(.{ .bounds = b, .band = 4, .top = true });
        w.paintQuad(paint.fill(b, color.white));
        w.popEdgeFade(fade);
        const op = w.pushOpacity(0.5);
        w.popOpacity(op);
        w.pushContentMask(.{ .bounds = b });
        w.popContentMask(.{ .bounds = b });
        _ = w.elementOpacityAt(b.origin);
        w.setWindowCursorStyle(.arrow);
        _ = w.glyphPainter();
    }
    fn prepaintAll(_: *CoverageView, b: Bounds, w: *Window, _: *App) void {
        const idx = w.prepaintIndex();
        _ = w.insertHitbox(b, .normal);
        w.truncatePrepaint(idx);
    }
    pub fn render(self: *CoverageView, w: *Window, cx: *Context(CoverageView)) elements.StatefulDiv {
        _ = w.viewportSize();
        _ = w.bounds();
        _ = w.scaleFactor();
        _ = w.windowAppearance();
        _ = w.isWindowActive();
        _ = w.isWindowHovered();
        _ = w.prefersReducedMotion();
        _ = w.currentModifiers();
        _ = w.lastInputWasKeyboard();
        _ = w.lineHeight();
        _ = w.isDirty();
        _ = w.focusedId();
        _ = w.pendingKeystrokes();
        const anchored = elements.anchored().anchorCorner(.bottom_right).offset(.{ .x = 1, .y = 1 })
            .positionMode(.local).snapToWindowWithMargin(.all(2)).children(.{ div(), "x" });
        const runs = [_]@import("../text/text.zig").TextRun{w.textStyle().toRun(3)};
        const st = elements.styledText("abc").withRuns(&runs);
        _ = st.textLayout();
        return div().id("root").child(
            div().id("all")
                .hover(sb.bg(color.red)).groupHover("g", sb.bg(color.red)).active(sb.bg(color.red))
                .groupActive("g", sb.bg(color.red)).focusStyle(sb.bg(color.red)).inFocus(sb.bg(color.red))
                .focusVisible(sb.bg(color.red)).dragOver(Card, sb.bg(color.red)).groupDragOver("g", Card, sb.bg(color.red))
                .group("g").keyContext("Coverage").trackFocus(self.focus).focusable().tabIndex(1).tabStop(true).tabGroup()
                .onKeyDown(onKeyDown).captureKeyDown(onKeyDown).onKeyUp(onKeyUp).captureKeyUp(onKeyUp).onModifiersChanged(onMods)
                .onAction(Save, onSave).captureAction(Save, onSave)
                .onMouseDown(.left, BubbleView.innerDown).onAnyMouseDown(BubbleView.innerDown).captureAnyMouseDown(BubbleView.innerDown)
                .onMouseDownOut(BubbleView.innerDown).onMouseUp(.left, onUp).onAnyMouseUp(onUp).captureAnyMouseUp(onUp)
                .onMouseUpOut(.left, onUp).onMouseMove(onMove).onMouseExit(onExit).onScrollWheel(onWheel)
                .occlude().blockMouseExceptScroll()
                .onDrop(Card, onCard).canDrop(canDropAll).onDragMove(Card, onCardMove).onDrag(Card{ .ix = 1 }, DragView.buildPreview)
                .onClick(onClickFree).onAuxClick(onClickFree).onHover(onHoverFree)
                .tooltip(tip).hoverableTooltip(tip).tooltipShowDelay(1000)
                .overflowYScroll().trackScroll(self.scroll).onChildrenPrepainted(onKids)
                .refineStyle(sb.p1()).refineStyleIf(true, sb.p2()).when(true, elements.StatefulDiv.bg, .{color.green})
                .children(&[_]AnyElement{ element.empty(), element.intoAnyElement("y") })
                .child(elements.deferred(anchored))
                .child(elements.canvas(self, CoverageView.paintAll).withPrepaint(*CoverageView, CoverageView.prepaintAll).size(px(10)))
                .child(elements.img(@as([]const u8, "missing.png")).objectFit(.cover).grayscale(true).size(px(4)))
                .child(elements.svg().path("missing.svg").withTransformation(.identity).size(px(4)))
                .child(st)
                .child(if (cx.weakEntity().id == cx.entityId()) "same" else "different"),
        );
    }
};

test "API coverage render" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, CoverageView, CoverageView.init, .{});
    const w = handle.window(app).?;
    testWindow(w).moveMouse(5, 5);
    testWindow(w).click(5, 5);
    w.setTitle("t");
    w.setBackgroundAppearance(.transparent);
    w.activateWindow();
    w.minimizeWindow();
    w.zoomWindow();
    w.toggleFullscreen();
    w.startWindowMove();
    w.requestAnimationFrame();
    testWindow(w).frame(false);
    w.blur();
    w.focusPrev();
    w.removeWindow();
}

// ---- native child views + overlay plane ------------------------------------------------

const NativeHost = struct {
    id: ?@import("../platform/platform.zig").NativeViewId = null,
    show: bool = true,
    menu: bool = false,
    cached_child: ?Entity(NativeLeaf) = null,

    fn init(window: *Window, cx: *Context(NativeHost)) NativeHost {
        var dummy: u8 = 0;
        const id = window.attachNativeView(@ptrCast(&dummy), .{}) catch null;
        return .{ .id = id, .cached_child = cx.app.new(NativeLeaf, .{ .id = id.? }) catch null };
    }

    pub fn deinit(self: *NativeHost, app: *App) void {
        if (self.cached_child) |c| c.release(app);
    }

    pub fn render(self: *NativeHost, _: *Window, _: *Context(NativeHost)) elements.Div {
        var root = div().size(px(400)).bg(color.white).child(div().h(px(20)));
        if (self.show) root = root.child(div().w(px(200)).h(px(100)).overflowHidden()
            .child(self.cached_child.?.cached(sb.w(px(300)).h(px(100)).refinement)));
        if (self.menu) root = root.child(elements.deferred(div().size(px(30)).bg(color.blue)));
        return root;
    }
};

const NativeLeaf = struct {
    id: @import("../platform/platform.zig").NativeViewId,
    pub fn render(self: *NativeLeaf, _: *Window, _: *Context(NativeLeaf)) elements.Canvas {
        return elements.nativeViewWith(self.id, .{ .corner_radius = 6 }).w(px(300)).h(px(100));
    }
};

test "native views are placed at their bounds, clipped, hidden when not painted; overlay holds deferred draws" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, NativeHost, NativeHost.init, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    const id = handle.rootView(app).?.read(app).id.?;
    const i = @intFromEnum(id);
    const p = tw.native_placement[i].?;
    try testing.expectEqual(@as(f32, 20), p.bounds.origin.y);
    try testing.expectEqual(@as(f32, 300), p.bounds.size.width);
    try testing.expectEqual(@as(f32, 200), p.clip.size.width); // clipped by overflowHidden
    try testing.expectEqual(@as(f32, 6), p.corner_radius);
    try testing.expectEqual(@as(usize, 0), tw.last_overlay_len);

    // A deferred menu goes to the overlay plane and captures input; the cached leaf keeps its placement.
    {
        var l = handle.rootView(app).?.lease(app);
        l.value.menu = true;
        l.cx.notify();
        l.end();
    }
    try testing.expect(tw.native_placement[i] != null);
    try testing.expectEqual(@as(usize, 1), tw.last_overlay_len);
    try testing.expect(tw.last_capture_input);
    const scene_len = w.rendered_frame.scene.len();
    try testing.expectEqual(scene_len, tw.last_overlay[0].end);
    try testing.expect(tw.last_overlay[0].start < scene_len);

    // Not painted → hidden.
    {
        var l = handle.rootView(app).?.lease(app);
        l.value.show = false;
        l.cx.notify();
        l.end();
    }
    try testing.expect(tw.native_placement[i] == null);
    try testing.expect(tw.native_attached[i]);
    w.detachNativeView(id);
    try testing.expect(!tw.native_attached[i]);
}

/// A frosted (backdrop-blurred) deferred menu over high-contrast content, optionally
/// next to a native child view.
const FrostHost = struct {
    id: ?@import("../platform/platform.zig").NativeViewId = null,
    native: bool,

    fn init(native: bool) fn (*Window, *Context(FrostHost)) FrostHost {
        return if (native) struct {
            fn f(window: *Window, _: *Context(FrostHost)) FrostHost {
                var dummy: u8 = 0;
                return .{ .id = window.attachNativeView(@ptrCast(&dummy), .{}) catch null, .native = true };
            }
        }.f else struct {
            fn f(_: *Window, _: *Context(FrostHost)) FrostHost {
                return .{ .native = false };
            }
        }.f;
    }

    pub fn render(self: *FrostHost, _: *Window, _: *Context(FrostHost)) elements.Div {
        var root = div().size(px(400)).bg(color.white).child(div().w(px(100)).h(px(20)).bg(color.black));
        if (self.id) |id| root = root.child(elements.nativeView(id).w(px(100)).h(px(50)));
        return root.child(elements.deferred(elements.frosted(px(6), elements.effects.menu_blur, div().size(px(60)).bg(color.white.opacity(0.5)))));
    }
};

fn frostedMenuBlurOps(scene: *const zpui_scene.Scene, start: usize, end: usize) usize {
    var n: usize = 0;
    for (scene.paint_operations.items[start..end]) |op| {
        if (op == .backdrop_blur) n += 1;
    }
    return n;
}

test "without native views a frosted deferred menu paints on the main plane (its blur sees the content beneath)" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, FrostHost, FrostHost.init(false), .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    const scene = &w.rendered_frame.scene;
    try testing.expectEqual(@as(usize, 1), scene.backdrop_blurs.items.len);
    // The deferred draw was still recorded for the overlay plane...
    try testing.expect(w.rendered_frame.overlay_ranges.items.len >= 1);
    // ...but with nothing native to sit above, the backend gets one plane, no capture.
    try testing.expectEqual(@as(usize, 0), tw.last_overlay_len);
    try testing.expect(!tw.last_capture_input);
}

test "with a native view, overlay-plane ranges holding a backdrop blur sample the lower planes" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, FrostHost, FrostHost.init(true), .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    const scene = &w.rendered_frame.scene;
    try testing.expect(handle.rootView(app).?.read(app).id != null);
    try testing.expectEqual(@as(usize, 1), tw.last_overlay_len);
    const r = tw.last_overlay[0];
    try testing.expectEqual(@import("../platform/platform.zig").OverlayPlane.overlay, r.plane);
    try testing.expectEqual(@as(usize, 1), frostedMenuBlurOps(scene, r.start, r.end));
    try testing.expect(r.samples_lower_planes);
    try testing.expect(tw.last_capture_input);
    // The page beneath (main plane) holds no blur and is not flagged.
    try testing.expectEqual(@as(usize, 0), frostedMenuBlurOps(scene, 0, r.start));
}

// A platform frame request from inside a frame (macOS `displayLayer:` fired by the Core
// Animation flush in present, or AppKit redisplaying while a render changes the window
// background) must not nest a second draw + present; it schedules the next frame instead.
const ReentrantFrameView = struct {
    renders: u32 = 0,
    reenter: bool = true,
    in_render: bool = false,
    nested: bool = false,

    pub fn render(self: *ReentrantFrameView, window: *Window, _: *Context(ReentrantFrameView)) elements.Div {
        if (self.in_render) self.nested = true;
        self.in_render = true;
        defer self.in_render = false;
        self.renders += 1;
        if (self.reenter) {
            self.reenter = false;
            testWindow(window).frame(true); // nested request while drawing
        }
        return div().size(px(100)).bg(color.red);
    }
};

fn initReentrantFrameView(_: *Window, _: *Context(ReentrantFrameView)) ReentrantFrameView {
    return .{};
}

test "a frame requested from inside a frame does not nest; it redraws afterwards" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, ReentrantFrameView, initReentrantFrameView, .{});
    const w = handle.window(app).?;
    const tw = testWindow(w);
    if (w.dirty) tw.frame(false);
    const v = handle.rootView(app).?.read(app);
    try testing.expect(!v.nested);
    try testing.expect(!w.in_frame);
    try testing.expectEqual(@as(u32, 2), v.renders); // the dropped request redrew once
    try testing.expect(!w.dirty);
}
