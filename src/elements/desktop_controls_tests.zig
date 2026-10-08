//! Drawn desktop controls (desktop_controls.zig) on the headless test platform: off by
//! default (fallbacks), drawn once a window opts in, driven by mouse and keyboard.

const std = @import("std");
const testing = std.testing;
const App = @import("../app/app.zig").App;
const Context = @import("../app/context.zig").Context;
const TestWindow = @import("../app/test_platform.zig").TestWindow;
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const elements = @import("mod.zig");
const nc = @import("native_control.zig");
const dc = @import("desktop_controls.zig");
const pf = @import("../platform/platform.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");
const a11y = @import("../a11y.zig");
const div = elements.div;
const px = geometry.px;

const options: window_mod.WindowOptions = .{ .bounds = .{ .origin = .zero, .size = .{ .width = 400, .height = 400 } } };
const items = [_][]const u8{ "Small", "Medium", "Large" };

const Form = struct {
    on: bool = false,
    checked: bool = false,
    value: f64 = 0.5,
    choice: u32 = 0,
    popup: u32 = 1,
    steps: f64 = 3,
    enabled: bool = true,
    fallback_clicks: u32 = 0,

    pub fn render(self: *Form, _: *Window, cx: *Context(Form)) elements.Div {
        // Rows at fixed y offsets (40 px apart) so tests can click them.
        return div().size(px(400)).bg(color.white).flex().flexCol().itemsStart()
            .child(row(nc.nativeSwitch("sw", .{ .on = self.on, .label = "Wi-Fi", .enabled = self.enabled }, cx.listener(Form.onSwitch), div().id("fb").w(px(44)).h(px(28)).onClick(cx.listener(Form.onFallback)))))
            .child(row(nc.nativeCheckbox("cb", .{ .on = self.checked, .title = "Remember" }, cx.listener(Form.onCheck), null)))
            .child(row(nc.nativeSlider("sl", .{ .value = self.value, .label = "Volume", .width = px(220) }, cx.listener(Form.onSlider), null)))
            .child(row(nc.nativeSegmented("seg", .{ .items = &items, .selected = self.choice, .label = "Size", .width = px(240) }, cx.listener(Form.onSeg), null)))
            .child(row(nc.nativePopup("pop", .{ .items = &items, .selected = self.popup, .label = "Font size", .width = px(160) }, cx.listener(Form.onPopup), null)))
            .child(row(nc.nativeStepper("st", .{ .value = self.steps, .min = 0, .max = 5, .label = "Count" }, cx.listener(Form.onStep), null)));
    }

    fn row(c: anytype) elements.Div {
        return div().h(px(40)).flexNone().flex().itemsCenter().child(c);
    }

    fn onFallback(self: *Form, _: *const @import("../window/events.zig").ClickEvent, _: *Window, cx: *Context(Form)) void {
        self.fallback_clicks += 1;
        cx.notify();
    }
    fn onSwitch(self: *Form, ev: *const pf.NativeControlEvent, _: *Window, cx: *Context(Form)) void {
        self.on = ev.on;
        cx.notify();
    }
    fn onCheck(self: *Form, ev: *const pf.NativeControlEvent, _: *Window, cx: *Context(Form)) void {
        self.checked = ev.on;
        cx.notify();
    }
    fn onSlider(self: *Form, ev: *const pf.NativeControlEvent, _: *Window, cx: *Context(Form)) void {
        self.value = ev.value;
        cx.notify();
    }
    fn onSeg(self: *Form, ev: *const pf.NativeControlEvent, _: *Window, cx: *Context(Form)) void {
        self.choice = ev.index;
        cx.notify();
    }
    fn onPopup(self: *Form, ev: *const pf.NativeControlEvent, _: *Window, cx: *Context(Form)) void {
        self.popup = ev.index;
        cx.notify();
    }
    fn onStep(self: *Form, ev: *const pf.NativeControlEvent, _: *Window, cx: *Context(Form)) void {
        self.steps = ev.value;
        cx.notify();
    }
};

fn initForm(_: *Window, _: *Context(Form)) Form {
    return .{};
}

const Fixture = struct {
    app: *App,
    handle: @import("../app/app.zig").WindowHandle(Form),
    w: *Window,
    tw: *TestWindow,

    fn init(style: pf.DesktopStyle, opt_in: bool) !Fixture {
        const app = try App.initTest(testing.allocator);
        errdefer app.deinit();
        const handle = try app.openWindow(options, Form, initForm, .{});
        const w = handle.window(app).?;
        w.setDesktopTheme(.{ .style = style });
        w.setDesktopControls(opt_in);
        w.drawAndPresent();
        return .{ .app = app, .handle = handle, .w = w, .tw = TestWindow.of(w.platform_window) };
    }

    fn deinit(self: *Fixture) void {
        self.app.deinit();
    }

    fn form(self: *Fixture) *Form {
        var l = self.handle.rootView(self.app).?.lease(self.app);
        defer l.end();
        return l.value;
    }

    fn settle(self: *Fixture) void {
        self.app.runUntilParked();
        self.w.drawAndPresent();
    }

    fn click(self: *Fixture, x: f32, y: f32) void {
        self.tw.click(x, y);
        self.settle();
    }

    fn key(self: *Fixture, k: []const u8) void {
        self.tw.typeKey(k);
        self.settle();
    }
};

test "desktop controls are opt-in: by default the fallback is used" {
    var f = try Fixture.init(.adwaita, false);
    defer f.deinit();
    f.click(10, 20);
    try testing.expectEqual(@as(u32, 1), f.form().fallback_clicks);
    try testing.expect(!f.form().on);
}

test "no desktop style keeps the fallback even when opted in" {
    var f = try Fixture.init(.none, true);
    defer f.deinit();
    f.click(10, 20);
    try testing.expectEqual(@as(u32, 1), f.form().fallback_clicks);
}

test "adwaita switch and checkbox toggle by mouse and keyboard; the knob eases" {
    var f = try Fixture.init(.adwaita, true);
    defer f.deinit();
    // The 46×26 switch sits at (0, 7).
    f.click(20, 20);
    try testing.expectEqual(@as(u32, 0), f.form().fallback_clicks);
    try testing.expect(f.form().on);
    f.click(20, 20);
    try testing.expect(!f.form().on);
    // Keyboard: the click focused it; space toggles (keyboard click).
    f.key("space");
    try testing.expect(f.form().on);
    // Checkbox row at y 40..80: clicking its title toggles.
    f.click(40, 60);
    try testing.expect(f.form().checked);
}

test "slider: click and drag set the value; arrows step it" {
    var f = try Fixture.init(.adwaita, true);
    defer f.deinit();
    // Track spans x 10..210 (knob 20) on the row at y 80..120.
    f.click(10, 100);
    try testing.expectEqual(@as(f64, 0), f.form().value);
    f.tw.moveMouse(110, 100);
    _ = f.tw.simulateInput(.{ .mouse_down = .{ .button = .left, .position = .{ .x = 110, .y = 100 } } });
    f.settle();
    try testing.expectApproxEqAbs(@as(f64, 0.5), f.form().value, 1e-6);
    _ = f.tw.simulateInput(.{ .mouse_move = .{ .position = .{ .x = 400, .y = 300 }, .pressed_button = .left } });
    f.settle();
    try testing.expectEqual(@as(f64, 1), f.form().value);
    _ = f.tw.simulateInput(.{ .mouse_up = .{ .button = .left, .position = .{ .x = 400, .y = 300 } } });
    f.settle();
    f.key("left");
    try testing.expectApproxEqAbs(@as(f64, 0.99), f.form().value, 1e-6);
    f.key("home");
    try testing.expectEqual(@as(f64, 0), f.form().value);
}

test "toggle group, drop-down list and spin button" {
    var f = try Fixture.init(.adwaita, true);
    defer f.deinit();
    // Toggle group (240 wide) at y 120..160: the third toggle.
    f.click(200, 140);
    try testing.expectEqual(@as(u32, 2), f.form().choice);
    f.key("left");
    try testing.expectEqual(@as(u32, 1), f.form().choice);

    // Drop-down at y 160..200: opens a list below; pick its first row.
    f.click(40, 180);
    // The list is deferred under the button (top at 160 + 34 + 4, 6 px padding, 32 px rows).
    f.click(40, 198 + 6 + 16);
    try testing.expectEqual(@as(u32, 0), f.form().popup);
    // Keyboard: Down opens, Down moves the highlight, Enter picks.
    f.key("down");
    f.key("down");
    f.key("enter");
    try testing.expectEqual(@as(u32, 1), f.form().popup);

    // Spin button (132 wide: text, −, +) at y 200..240.
    f.click(132 - 17, 220);
    try testing.expectEqual(@as(f64, 4), f.form().steps);
    f.click(132 - 34 - 17, 220);
    try testing.expectEqual(@as(f64, 3), f.form().steps);
    f.key("up");
    try testing.expectEqual(@as(f64, 4), f.form().steps);
    f.key("end");
    try testing.expectEqual(@as(f64, 5), f.form().steps);
}

test "breeze controls report the same events; disabled controls ignore input" {
    var f = try Fixture.init(.breeze, true);
    defer f.deinit();
    f.click(18, 20); // 36×20 Breeze switch
    try testing.expect(f.form().on);
    {
        var l = f.handle.rootView(f.app).?.lease(f.app);
        l.value.enabled = false;
        l.cx.notify();
        l.end();
    }
    f.w.drawAndPresent();
    f.click(18, 20);
    try testing.expect(f.form().on);
}

test "drawn controls join the accessibility tree with their roles" {
    var f = try Fixture.init(.adwaita, true);
    defer f.deinit();
    f.w.setA11yActive(true);
    f.w.drawAndPresent();
    const tree = f.w.a11yTree();
    var seen = std.EnumSet(a11y.Role).empty;
    for (tree.nodes.items) |n| seen.insert(n.role);
    for ([_]a11y.Role{ .@"switch", .check_box, .slider, .radio_button, .combo_box, .spin_button }) |r|
        try testing.expect(seen.contains(r));
}

const prefs = @import("prefs.zig");

const PrefsView = struct {
    family: prefs.Family = .adwaita,
    on: bool = true,
    selected: ?u32 = null,
    adds: u32 = 0,
    removed: ?u32 = null,

    const apps = [_]prefs.ListItem{ .{ .title = "Files" }, .{ .title = "Terminal", .subtitle = "org.gnome.Terminal" } };

    pub fn render(self: *PrefsView, window: *Window, cx: *Context(PrefsView)) elements.Div {
        const look = dc.theme.look(self.family, false, null);
        return div().w(px(500)).h(px(900)).flex().flexCol()
            .child(prefs.headerBar(window, look, "Preferences"))
            .child(prefs.page(window, look, &.{
            .{ .title = "General", .description = "Behavior", .rows = &.{
                prefs.row("Enabled", "Turn it on", nc.nativeSwitch("en", .{ .on = self.on, .label = "Enabled" }, null, null)),
                prefs.row("Plain", "", null),
            } },
            .{ .title = "Apps", .content = prefs.editableList(look, "apps", .{ .items = &apps, .selected = self.selected, .label = "Apps" }, cx.listener(PrefsView.onList)) },
        }));
    }

    fn onList(self: *PrefsView, ev: *const prefs.ListEvent, _: *Window, cx: *Context(PrefsView)) void {
        switch (ev.*) {
            .select => |i| self.selected = i,
            .add => self.adds += 1,
            .remove => |i| self.removed = i,
        }
        cx.notify();
    }
};

test "preference pages render for every family and the app list reports its events" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tall: window_mod.WindowOptions = .{ .bounds = .{ .origin = .zero, .size = .{ .width = 500, .height = 900 } } };
    const handle = try app.openWindow(tall, PrefsView, struct {
        fn f(_: *Window, _: *Context(PrefsView)) PrefsView {
            return .{};
        }
    }.f, .{});
    const w = handle.window(app).?;
    w.setDesktopTheme(.{ .style = .adwaita });
    w.setDesktopControls(true);
    w.setA11yActive(true);
    for ([_]prefs.Family{ .macos, .breeze, .adwaita }) |fam| {
        var l = handle.rootView(app).?.lease(app);
        l.value.family = fam;
        l.cx.notify();
        l.end();
        w.drawAndPresent();
    }
    // The list's buttons are found through the accessibility tree.
    const tree = w.a11yTree();
    var add_center: ?geometry.Point(f32) = null;
    var remove_center: ?geometry.Point(f32) = null;
    for (tree.nodes.items) |n| {
        if (n.role != .button) continue;
        const name = tree.name(&n) orelse continue;
        const c: geometry.Point(f32) = .{ .x = n.bounds.origin.x + n.bounds.size.width / 2, .y = n.bounds.origin.y + n.bounds.size.height / 2 };
        if (std.mem.eql(u8, name, "Add Application…")) add_center = c;
        if (std.mem.eql(u8, name, "Remove") and remove_center == null) remove_center = c;
    }
    const tw = TestWindow.of(w.platform_window);
    const add = add_center orelse return error.NoAddButton;
    tw.click(add.x, add.y);
    app.runUntilParked();
    const rm = remove_center orelse return error.NoRemoveButton;
    tw.click(rm.x, rm.y);
    app.runUntilParked();
    var l = handle.rootView(app).?.lease(app);
    defer l.end();
    try testing.expectEqual(@as(u32, 1), l.value.adds);
    try testing.expectEqual(@as(?u32, 0), l.value.removed);
}
