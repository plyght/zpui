//! Native popover containers (`zpui.nativePopover`, native tooltips) on the headless
//! TestPlatform (`native_popovers = true` turns popover windows on).

const std = @import("std");
const testing = std.testing;
const App = @import("../app/app.zig").App;
const Context = @import("../app/context.zig").Context;
const Entity = @import("../app/entity.zig").Entity;
const TestWindow = @import("../app/test_platform.zig").TestWindow;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const elements = @import("../elements/mod.zig");
const div = elements.div;
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");
const input = @import("../input.zig");
const FocusHandle = @import("focus.zig").FocusHandle;
const np = @import("native_popover.zig");

const Bounds = geometry.Bounds(f32);
const px = geometry.px;

const options: window_mod.WindowOptions = .{ .bounds = .{ .origin = .zero, .size = .{ .width = 400, .height = 300 } } };

fn bnds(x: f32, y: f32, w: f32, h: f32) Bounds {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

fn coreOf(tw: *TestWindow) *Window {
    return @ptrCast(@alignCast(tw.callbacks.ctx.?));
}

fn hasQuad(w: *const Window, c: @import("../color.zig").Hsla) bool {
    for (w.rendered_frame.scene.quads.items) |q| if (q.background.solid.eql(c)) return true;
    return false;
}

const Owner = struct {
    open: bool = true,
    tall: bool = false,
    native: bool = true,
    edge: np.Edge = .below,
    dismissed: u32 = 0,
    focus: FocusHandle,

    fn init(_: *Window, cx: *Context(Owner)) Owner {
        return .{ .focus = cx.focusHandle() };
    }

    pub fn deinit(self: *Owner, cx: *App) void {
        self.focus.release(cx);
    }

    pub fn render(self: *Owner, _: *Window, cx: *Context(Owner)) elements.Div {
        var trigger = div().id("trigger").absolute().left(px(20)).top(px(30)).w(px(80)).h(px(20)).bg(color.blue);
        if (self.open) trigger = trigger.child(elements.nativePopover(
            .trigger("pop"),
            .{ .focus = self.focus, .native = self.native, .edge = self.edge },
            elements.popoverContent(cx.entity(), card, onDismiss),
        ).fallback(div().absolute().top(px(20)).w(px(60)).h(px(40)).bg(color.green)));
        return div().size(px(400)).bg(color.white).child(trigger);
    }

    fn card(self: *Owner, window: *Window, _: *Context(Owner)) elements.Div {
        // The native container provides the material: no card background there.
        const bg = if (window.isNativePopover()) color.red else color.yellow;
        return div().trackFocus(self.focus).w(px(120)).h(px(if (self.tall) 200 else 80)).bg(bg);
    }

    fn onDismiss(self: *Owner, _: *Window, cx: *Context(Owner)) void {
        self.dismissed += 1;
        self.open = false;
        cx.notify();
    }
};

fn setUp(native: bool) !struct { app: *App, w: *Window, owner: Entity(Owner) } {
    const app = try App.initTest(testing.allocator);
    app.test_platform.?.native_popovers = native;
    const handle = try app.openWindow(options, Owner, Owner.init, .{});
    app.runUntilParked();
    return .{ .app = app, .w = handle.window(app).?, .owner = handle.rootView(app).? };
}

test "nativePopover renders its fallback in-window when the platform has no popovers" {
    const s = try setUp(false);
    defer s.app.deinit();
    try testing.expect(!s.w.nativePopoversAvailable());
    try testing.expect(s.app.test_platform.?.lastPopover() == null);
    try testing.expect(hasQuad(s.w, color.green));
}

test "nativePopover opens a sized, placed popover window below the trigger" {
    const s = try setUp(true);
    defer s.app.deinit();
    const tp = s.app.test_platform.?;
    try testing.expect(s.w.nativePopoversAvailable());
    try testing.expect(!hasQuad(s.w, color.green)); // no fallback in the parent
    const tw = tp.lastPopover() orelse return error.NoPopover;
    const pp = tw.popover.?;
    try testing.expect(pp.parent.ptr == s.w.platform_window.ptr);
    try testing.expectEqual(@as(@TypeOf(pp.material), .popover), pp.material);
    try testing.expect(pp.key and !pp.mouse_transparent);
    try testing.expect(tw.popover_visible);
    // Anchor (20, 30, 80, 20), 6px gap, content 120×80.
    try testing.expectEqual(bnds(20, 56, 120, 80), tw.bounds);
    const pw = coreOf(tw);
    try testing.expect(pw.isNativePopover());
    try testing.expect(hasQuad(pw, color.red));
    // The owner's focus handle is focused inside the popover.
    try testing.expect(s.owner.read(s.app).focus.isFocused(pw));
    // Popovers are not app windows.
    try testing.expectEqual(@as(usize, 1), s.app.windowCount());
    try testing.expectEqual(@as(u32, 1), s.w.native_popovers.opened_count);
}

test "nativePopover flips above when the screen bottom is too close, and resizes to content" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    app.test_platform.?.native_popovers = true;
    var low = options;
    low.bounds.origin = .{ .x = 0, .y = 900 }; // the 1080px display ends 180px down
    const handle = try app.openWindow(low, Owner, Owner.init, .{});
    app.runUntilParked();
    const tw = app.test_platform.?.lastPopover() orelse return error.NoPopover;
    // Below would need 86px of the 130 left under the trigger: fits.
    try testing.expectEqual(bnds(20, 56, 120, 80), tw.bounds);
    // A taller card no longer fits below: it opens above, re-placed and resized.
    const owner = handle.rootView(app).?;
    owner.update(app, struct {
        fn f(o: *Owner, cx: *Context(Owner)) void {
            o.tall = true;
            cx.notify();
        }
    }.f, .{});
    app.runUntilParked();
    // Above: 30 - 6 - 200 = -176 (the screen starts at -900 in content coordinates).
    try testing.expectEqual(bnds(20, -176, 120, 200), tw.bounds);
    try testing.expectEqual(@as(f32, 200), coreOf(tw).viewport_size.height);
    try testing.expect(tw.popover_visible);
}

test "native popover dismissal: outside press, trigger press, Escape, platform request" {
    const s = try setUp(true);
    defer s.app.deinit();
    const tp = s.app.test_platform.?;
    const ptw = TestWindow.of(s.w.platform_window);
    // A press on the trigger is left to the trigger.
    ptw.click(30, 35);
    try testing.expectEqual(@as(u32, 0), s.owner.read(s.app).dismissed);
    // A press elsewhere in the parent dismisses; the window hides, then closes.
    ptw.click(300, 250);
    try testing.expectEqual(@as(u32, 1), s.owner.read(s.app).dismissed);
    s.app.runUntilParked();
    const tw = tp.lastPopover() orelse return error.NoPopover;
    try testing.expect(!tw.popover_visible);
    s.app.advanceClock(np.close_linger_ns + 1);
    s.app.runUntilParked();
    try testing.expect(tp.lastPopover() == null);

    // Reopen: Escape inside the popover dismisses.
    reopen(s.app, s.owner);
    const tw2 = tp.lastPopover() orelse return error.NoPopover;
    try testing.expect(tw2.popover_visible);
    tw2.typeKey("escape");
    try testing.expectEqual(@as(u32, 2), s.owner.read(s.app).dismissed);
    s.app.advanceClock(np.close_linger_ns + 1);
    s.app.runUntilParked();

    // Reopen: the platform reports an outside press (another app / window).
    reopen(s.app, s.owner);
    const tw3 = tp.lastPopover() orelse return error.NoPopover;
    ptw.mouse = .{ .x = 300, .y = 250 };
    tw3.simulatePopoverDismiss(.outside_click);
    try testing.expectEqual(@as(u32, 3), s.owner.read(s.app).dismissed);
}

fn reopen(app: *App, owner: Entity(Owner)) void {
    owner.update(app, struct {
        fn f(o: *Owner, cx: *Context(Owner)) void {
            o.open = true;
            cx.notify();
        }
    }.f, .{});
    app.runUntilParked();
}

test "a popover hidden and requested again within the linger reuses its window" {
    const s = try setUp(true);
    defer s.app.deinit();
    const tp = s.app.test_platform.?;
    const tw = tp.lastPopover() orelse return error.NoPopover;
    s.owner.update(s.app, struct {
        fn f(o: *Owner, cx: *Context(Owner)) void {
            o.open = false;
            cx.notify();
        }
    }.f, .{});
    s.app.runUntilParked();
    try testing.expect(!tw.popover_visible);
    reopen(s.app, s.owner);
    try testing.expect(tp.lastPopover().? == tw);
    try testing.expect(tw.popover_visible);
    s.app.advanceClock(np.close_linger_ns + 1);
    s.app.runUntilParked();
    try testing.expect(tp.lastPopover().? == tw);
    try testing.expectEqual(@as(u32, 1), s.w.native_popovers.opened_count);
}

test "options.native = false keeps the in-window fallback even where popovers exist" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    app.test_platform.?.native_popovers = true;
    const handle = try app.openWindow(options, Owner, struct {
        fn f(window: *Window, cx: *Context(Owner)) Owner {
            var o = Owner.init(window, cx);
            o.native = false;
            return o;
        }
    }.f, .{});
    app.runUntilParked();
    try testing.expect(app.test_platform.?.lastPopover() == null);
    try testing.expect(hasQuad(handle.window(app).?, color.green));
}

test "closing the parent window closes its popovers" {
    const s = try setUp(true);
    const tp = s.app.test_platform.?;
    try testing.expect(tp.lastPopover() != null);
    TestWindow.of(s.w.platform_window).simulateClose();
    s.app.runUntilParked();
    s.app.runUntilParked();
    try testing.expect(tp.lastPopover() == null);
    s.app.deinit();
}

const Leaf = struct {
    label: []const u8,
    pub fn render(self: *Leaf, _: *Window, _: *Context(Leaf)) elements.Div {
        return div().w(px(50)).h(px(16)).child(self.label);
    }
};

const TipView = struct {
    fn init(window: *Window, _: *Context(TipView)) TipView {
        window.setNativeTooltips(true);
        return .{};
    }
    fn tip(label: []const u8, _: *Window, cx: *App) Entity(Leaf) {
        return cx.new(Leaf, .{ .label = label }) catch @panic("OOM");
    }
    pub fn render(_: *TipView, _: *Window, _: *Context(TipView)) elements.Div {
        return div().size(px(400)).child(div().id("btn").size(px(50)).tooltipWith(@as([]const u8, "tip!"), tip));
    }
};

test "native tooltips: a non-key, mouse-transparent tooltip window under the cursor" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    tp.native_popovers = true;
    const handle = try app.openWindow(options, TipView, TipView.init, .{});
    const w = handle.window(app).?;
    const ptw = TestWindow.of(w.platform_window);
    ptw.moveMouse(10, 10);
    app.advanceClock(501 * std.time.ns_per_ms);
    app.runUntilParked();
    const tw = tp.lastPopover() orelse return error.NoPopover;
    const pp = tw.popover.?;
    try testing.expectEqual(@as(@TypeOf(pp.material), .tooltip), pp.material);
    try testing.expect(!pp.key and pp.mouse_transparent);
    try testing.expect(tw.popover_visible);
    try testing.expectEqual(bnds(10, 28, 50, 16), tw.bounds);
    // The text is drawn in the tooltip window, not on the parent's overlay plane.
    try testing.expectEqual(@as(usize, 0), w.rendered_frame.scene.monochrome_sprites.items.len);
    try testing.expectEqual(@as(usize, 4), coreOf(tw).rendered_frame.scene.monochrome_sprites.items.len);
    try testing.expect(w.tooltip_bounds != null);
    ptw.moveMouse(300, 300);
    app.runUntilParked();
    try testing.expect(w.tooltip_bounds == null);
    try testing.expect(!tw.popover_visible);
}

test "native tooltips off: drawn in-window as before" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    app.test_platform.?.native_popovers = true;
    const handle = try app.openWindow(options, TipView, TipView.init, .{});
    const w = handle.window(app).?;
    w.setNativeTooltips(false);
    TestWindow.of(w.platform_window).moveMouse(10, 10);
    app.advanceClock(501 * std.time.ns_per_ms);
    app.runUntilParked();
    try testing.expect(app.test_platform.?.lastPopover() == null);
    try testing.expectEqual(@as(usize, 4), w.rendered_frame.scene.monochrome_sprites.items.len);
}
