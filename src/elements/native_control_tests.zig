//! `nativeSwitch` & co. on the headless test platform: fallbacks by default, the native
//! path once a test sets `TestWindow.native_controls` (fake AppKit sizes; user changes
//! injected with `TestWindow.simulateNativeControl`).

const std = @import("std");
const testing = std.testing;
const App = @import("../app/app.zig").App;
const Context = @import("../app/context.zig").Context;
const TestWindow = @import("../app/test_platform.zig").TestWindow;
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const elements = @import("mod.zig");
const nc = @import("native_control.zig");
const pf = @import("../platform/platform.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");
const div = elements.div;
const px = geometry.px;

const options: window_mod.WindowOptions = .{ .bounds = .{ .origin = .zero, .size = .{ .width = 400, .height = 300 } } };

const items = [_][]const u8{ "Small", "Medium", "Large" };

const FormView = struct {
    on: bool = false,
    /// Listeners record but ignore changes (an inert control).
    ignore: bool = false,
    width: f64 = 600,
    choice: u32 = 1,
    steps: f64 = 3,
    checked: bool = false,
    show: bool = true,
    in_menu: bool = false,
    events: u32 = 0,
    fallback_clicks: u32 = 0,

    pub fn render(self: *FormView, _: *Window, cx: *Context(FormView)) elements.Div {
        var root = div().size(px(400)).bg(color.white).flex().flexCol().itemsStart().child(div().h(px(20)));
        if (!self.show) return root;
        const fallback = div().id("drawn-switch").w(px(44)).h(px(28)).bg(color.blue).onClick(cx.listener(FormView.onFallbackClick));
        const sw = nc.nativeSwitch("sw", .{ .on = self.on, .label = "Compact mode", .enabled = !self.ignore }, cx.listener(FormView.onSwitch), fallback);
        if (self.in_menu) {
            root = root.child(elements.deferred(div().child(sw)));
        } else root = root.child(sw);
        return root
            .child(nc.nativeSlider("width", .{ .value = self.width, .min = 560, .max = 1200, .label = "Width", .width = px(240) }, cx.listener(FormView.onSlider), div().w(px(240)).h(px(28))))
            .child(nc.nativePopup("size", .{ .items = &items, .selected = self.choice, .label = "Size" }, cx.listener(FormView.onChoice), null))
            .child(nc.nativeSegmented("seg", .{ .items = &items, .selected = self.choice, .label = "Size segments" }, cx.listener(FormView.onChoice), null))
            .child(nc.nativeStepper("step", .{ .value = self.steps, .min = 0, .max = 10, .label = "Steps" }, cx.listener(FormView.onStepper), null))
            .child(nc.nativeCheckbox("check", .{ .on = self.checked, .title = "Run on start" }, cx.listener(FormView.onCheck), null));
    }

    fn onFallbackClick(self: *FormView, _: *const @import("../window/events.zig").ClickEvent, _: *Window, cx: *Context(FormView)) void {
        self.fallback_clicks += 1;
        self.on = !self.on;
        cx.notify();
    }
    fn onSwitch(self: *FormView, ev: *const pf.NativeControlEvent, _: *Window, cx: *Context(FormView)) void {
        self.events += 1;
        if (self.ignore) return;
        self.on = ev.on;
        cx.notify();
    }
    fn onSlider(self: *FormView, ev: *const pf.NativeControlEvent, _: *Window, cx: *Context(FormView)) void {
        self.events += 1;
        self.width = @round(ev.value);
        cx.notify();
    }
    fn onChoice(self: *FormView, ev: *const pf.NativeControlEvent, _: *Window, cx: *Context(FormView)) void {
        self.events += 1;
        self.choice = ev.index;
        cx.notify();
    }
    fn onStepper(self: *FormView, ev: *const pf.NativeControlEvent, _: *Window, cx: *Context(FormView)) void {
        self.events += 1;
        self.steps = ev.value;
        cx.notify();
    }
    fn onCheck(self: *FormView, ev: *const pf.NativeControlEvent, _: *Window, cx: *Context(FormView)) void {
        self.events += 1;
        self.checked = ev.on;
        cx.notify();
    }
};

fn initView(_: *Window, _: *Context(FormView)) FormView {
    return .{};
}

fn update(app: *App, handle: anytype, comptime f: anytype) void {
    var l = handle.rootView(app).?.lease(app);
    f(l.value);
    l.cx.notify();
    l.end();
}

const Fixture = struct {
    app: *App,
    handle: @import("../app/app.zig").WindowHandle(FormView),
    w: *Window,
    tw: *TestWindow,

    fn init(native: bool) !Fixture {
        const app = try App.initTest(testing.allocator);
        errdefer app.deinit();
        const handle = try app.openWindow(options, FormView, initView, .{});
        const w = handle.window(app).?;
        const tw = TestWindow.of(w.platform_window);
        if (native) {
            tw.native_controls = true;
            w.refresh();
            w.drawAndPresent();
        }
        return .{ .app = app, .handle = handle, .w = w, .tw = tw };
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
    }

    fn view(self: *Fixture) *FormView {
        var l = self.handle.rootView(self.app).?.lease(self.app);
        defer l.end();
        return l.value;
    }

    fn control(self: *Fixture, kind: pf.NativeControlKind, label: []const u8) pf.NativeViewId {
        return self.tw.findNativeControl(kind, label) orelse @panic("no such native control");
    }

    fn state(self: *Fixture, id: pf.NativeViewId) pf.NativeControlState {
        return self.tw.control_state[@intFromEnum(id)].?;
    }
};

test "without native controls the elements are their fallbacks" {
    var f = try Fixture.init(false);
    defer f.deinit();
    try testing.expect(!nc.nativeControlsAvailable(f.w));
    try testing.expectEqual(@as(usize, 0), f.tw.nativeControlCount());
    // The drawn switch is laid out where the native one would be and keeps its listener.
    f.tw.click(10, 30);
    f.app.runUntilParked();
    try testing.expectEqual(@as(u32, 1), f.view().fallback_clicks);
    try testing.expect(f.view().on);
}

test "a native switch is attached, placed at its intrinsic size and reports changes" {
    var f = try Fixture.init(true);
    defer f.deinit();
    try testing.expect(nc.nativeControlsAvailable(f.w));
    try testing.expectEqual(@as(usize, 6), f.tw.nativeControlCount());
    const sw = f.control(.switch_, "Compact mode");
    const i = @intFromEnum(sw);
    const p = f.tw.native_placement[i].?;
    try testing.expectEqual(@as(f32, 20), p.bounds.origin.y);
    try testing.expectEqual(@as(f32, 40), p.bounds.size.width);
    try testing.expectEqual(@as(f32, 24), p.bounds.size.height);
    try testing.expect(!f.state(sw).on);
    try testing.expect(f.state(sw).enabled);

    // The user flips it: the listener runs, the app re-renders, and the matching state
    // is not pushed back to the control.
    f.tw.simulateNativeControl(sw, .{ .kind = .switch_, .on = true });
    f.app.runUntilParked();
    f.w.drawAndPresent();
    try testing.expect(f.view().on);
    try testing.expectEqual(@as(u32, 1), f.view().events);
    try testing.expectEqual(@as(u32, 0), f.tw.control_updates[i]);
    try testing.expect(f.state(sw).on);

    // The app changes the value: pushed once.
    update(f.app, f.handle, struct {
        fn g(v: *FormView) void {
            v.on = false;
        }
    }.g);
    f.w.drawAndPresent();
    try testing.expectEqual(@as(u32, 1), f.tw.control_updates[i]);
    try testing.expect(!f.state(sw).on);
    try testing.expectEqual(@as(u32, 1), f.w.native_controls.attach_count - 5);
}

test "an ignored change is put back, and disabled controls say so" {
    var f = try Fixture.init(true);
    defer f.deinit();
    update(f.app, f.handle, struct {
        fn g(v: *FormView) void {
            v.ignore = true;
        }
    }.g);
    f.w.drawAndPresent();
    const sw = f.control(.switch_, "Compact mode");
    try testing.expect(!f.state(sw).enabled);
    const before = f.tw.control_updates[@intFromEnum(sw)];
    f.tw.simulateNativeControl(sw, .{ .kind = .switch_, .on = true });
    f.app.runUntilParked();
    f.w.refresh();
    f.w.drawAndPresent();
    try testing.expectEqual(@as(u32, 1), f.view().events);
    try testing.expect(!f.view().on);
    try testing.expect(!f.state(sw).on); // the app's value went back to the control
    try testing.expectEqual(before + 1, f.tw.control_updates[@intFromEnum(sw)]);
}

test "slider, popup, segmented, stepper and checkbox values round-trip" {
    var f = try Fixture.init(true);
    defer f.deinit();
    const slider = f.control(.slider, "Width");
    const sp = f.tw.native_placement[@intFromEnum(slider)].?;
    try testing.expectEqual(@as(f32, 240), sp.bounds.size.width);
    try testing.expectEqual(@as(f32, 22), sp.bounds.size.height);
    try testing.expectEqual(@as(f64, 560), f.state(slider).min);
    try testing.expectEqual(@as(f64, 600), f.state(slider).value);
    f.tw.simulateNativeControl(slider, .{ .kind = .slider, .value = 812.4 });
    f.app.runUntilParked();
    f.w.drawAndPresent();
    try testing.expectEqual(@as(f64, 812), f.view().width);
    try testing.expectEqual(@as(f64, 812), f.state(slider).value); // rounded by the app, pushed back

    const popup = f.control(.popup, "Size");
    try testing.expectEqual(@as(usize, 3), f.state(popup).items.len);
    try testing.expectEqualStrings("Medium", f.state(popup).items[1]);
    try testing.expectEqual(@as(?u32, 1), f.state(popup).selected);
    f.tw.simulateNativeControl(popup, .{ .kind = .popup, .index = 2 });
    f.app.runUntilParked();
    f.w.drawAndPresent();
    try testing.expectEqual(@as(u32, 2), f.view().choice);
    // The segmented control shows the same choice (pushed as an app change).
    try testing.expectEqual(@as(?u32, 2), f.state(f.control(.segmented, "Size segments")).selected);

    const stepper = f.control(.stepper, "Steps");
    f.tw.simulateNativeControl(stepper, .{ .kind = .stepper, .value = 4 });
    f.app.runUntilParked();
    try testing.expectEqual(@as(f64, 4), f.view().steps);

    const check = f.control(.checkbox, "Run on start"); // the title doubles as the label
    try testing.expectEqualStrings("Run on start", f.state(check).title);
    f.tw.simulateNativeControl(check, .{ .kind = .checkbox, .on = true });
    f.app.runUntilParked();
    try testing.expect(f.view().checked);
    // A mismatched event kind is ignored.
    f.tw.simulateNativeControl(check, .{ .kind = .slider, .value = 1 });
    f.app.runUntilParked();
    try testing.expectEqual(@as(u32, 4), f.view().events);
}

test "controls in deferred content float above the overlay plane; unmounted ones hide, then detach" {
    var f = try Fixture.init(true);
    defer f.deinit();
    const sw = f.control(.switch_, "Compact mode");
    try testing.expectEqual(window_mod.native_controls_mod.Tier.base, f.w.native_controls.findView(sw).?.tier);
    update(f.app, f.handle, struct {
        fn g(v: *FormView) void {
            v.in_menu = true;
        }
    }.g);
    f.w.drawAndPresent();
    const floating = f.control(.switch_, "Compact mode");
    try testing.expect(floating != sw); // re-attached in the floating tier
    try testing.expectEqual(window_mod.native_controls_mod.Tier.floating, f.w.native_controls.findView(floating).?.tier);

    update(f.app, f.handle, struct {
        fn g(v: *FormView) void {
            v.show = false;
        }
    }.g);
    f.w.drawAndPresent();
    try testing.expect(f.tw.native_placement[@intFromEnum(floating)] == null);
    try testing.expectEqual(@as(usize, 6), f.tw.nativeControlCount());
    for (0..window_mod.native_controls_mod.keep_idle_presents + 1) |_| f.w.drawAndPresent();
    try testing.expectEqual(@as(usize, 0), f.tw.nativeControlCount());
    try testing.expectEqual(@as(usize, 0), f.w.native_controls.entries.items.len);
}

test "setNativeControlsEnabled(false) switches the window back to the fallbacks" {
    var f = try Fixture.init(true);
    defer f.deinit();
    try testing.expectEqual(@as(usize, 6), f.tw.nativeControlCount());
    f.w.setNativeControlsEnabled(false);
    f.w.drawAndPresent();
    for (f.tw.native_placement, f.tw.control_state) |p, s| if (s != null) try testing.expect(p == null);
    f.tw.click(10, 30);
    f.app.runUntilParked();
    try testing.expectEqual(@as(u32, 1), f.view().fallback_clicks);
}

// A control re-attached while painting (kind or tier change) used to be removed from the
// rendered frame's native view list, shifting the paint ranges of cached views painted
// after it: their reuse sliced past the end (a ReleaseSafe panic) or placed the wrong view.
const CachedSwitchView = struct {
    pub fn render(_: *CachedSwitchView, _: *Window, _: *Context(CachedSwitchView)) elements.Div {
        return div().h(px(30)).child(nc.nativeSwitch("cached-sw", .{ .on = true, .label = "Cached" }, null, null));
    }
};

const KindFlipView = struct {
    child: @import("../app/entity.zig").Entity(CachedSwitchView),
    checkbox: bool = false,

    fn init(_: *Window, cx: *Context(KindFlipView)) !KindFlipView {
        return .{ .child = try cx.new(CachedSwitchView, .{}) };
    }
    pub fn deinit(self: *KindFlipView, app: *App) void {
        self.child.release(app);
    }
    pub fn render(self: *KindFlipView, _: *Window, _: *Context(KindFlipView)) elements.Div {
        const first = if (self.checkbox)
            nc.nativeCheckbox("flip", .{ .on = false, .label = "Flip" }, null, null)
        else
            nc.nativeSwitch("flip", .{ .on = false, .label = "Flip" }, null, null);
        return div().size(px(400)).flex().flexCol()
            .child(div().h(px(30)).flexNone().child(first))
            .child(self.child.cached(@import("../styled.zig").StyleBuilder.init.wFull().h(px(30)).refinement));
    }
};

test "a control re-attached while painting keeps cached views' native placements intact" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, KindFlipView, KindFlipView.init, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    tw.native_controls = true;
    w.refresh();
    w.drawAndPresent();
    const cached = tw.findNativeControl(.switch_, "Cached") orelse return error.NoCachedControl;
    const placed = tw.native_placement[@intFromEnum(cached)] orelse return error.NotPlaced;

    // Only the root re-renders: the switch becomes a checkbox (detached + re-attached in
    // paint) and the cached child reuses its paint from the rendered frame.
    var l = handle.rootView(app).?.lease(app);
    l.value.checkbox = true;
    l.cx.notify();
    l.end();
    w.drawAndPresent();
    try testing.expect(tw.findNativeControl(.checkbox, "Flip") != null);
    try testing.expect(tw.findNativeControl(.switch_, "Flip") == null);
    try testing.expectEqual(cached, tw.findNativeControl(.switch_, "Cached").?);
    try testing.expectEqualDeep(placed, tw.native_placement[@intFromEnum(cached)].?);
    w.drawAndPresent();
    try testing.expectEqualDeep(placed, tw.native_placement[@intFromEnum(cached)].?);
}
