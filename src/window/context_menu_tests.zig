//! Native context menu tests on the headless TestPlatform (src/window/context_menu.zig).

const std = @import("std");
const testing = std.testing;
const App = @import("../app/app.zig").App;
const Context = @import("../app/context.zig").Context;
const TestWindow = @import("../app/test_platform.zig").TestWindow;
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const elements = @import("../elements/mod.zig");
const div = elements.div;
const geometry = @import("../geometry.zig");
const input = @import("../input.zig");
const events = @import("events.zig");
const context_menu = @import("context_menu.zig");
const MenuItem = context_menu.MenuItem;

const px = geometry.px;
const options: window_mod.WindowOptions = .{ .bounds = .{ .origin = .zero, .size = .{ .width = 400, .height = 300 } } };

const square_svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16"><rect x="2" y="2" width="12" height="12" fill="black"/></svg>
;

const items = [_]MenuItem{
    .header("File"),
    .{ .label = "Rename", .tag = 1, .icon = square_svg, .shortcut = .{ .key = "r", .modifiers = .{ .platform = true } } },
    .{ .label = "Pin", .tag = 2, .check = .on },
    .{ .label = "Mixed", .tag = 3, .check = .mixed, .disabled = true },
    .sub("Copy", &.{ .action("Path", 10), .action("Name", 11) }),
    .separator,
    .{ .label = "Delete", .tag = 4, .destructive = true },
};

const Host = struct {
    native: bool = false,
    drawn: bool = false,
    picked: ?u32 = null,
    results: u32 = 0,
    in_update: bool = false,
    button_bounds: geometry.Bounds(geometry.Pixels) = .{ .origin = .zero, .size = .zero },

    fn init(_: *Window, _: *Context(Host)) Host {
        return .{};
    }

    pub fn render(_: *Host, _: *Window, cx: *Context(Host)) elements.Div {
        return div().size(px(400)).flex().flexCol()
            .child(div().id("target").w(px(200)).h(px(100)).onMouseDown(.right, cx.listener(Host.onRight)))
            .child(div().id("more").w(px(40)).h(px(20)).onClick(cx.listener(Host.onMore)));
    }

    fn onRight(self: *Host, ev: *const input.MouseDownEvent, window: *Window, cx: *Context(Host)) void {
        self.native = context_menu.show(window, ev.position, &items, cx.listener(Host.onPick));
        self.drawn = !self.native;
    }

    fn onMore(self: *Host, ev: *const events.ClickEvent, _: *Window, _: *Context(Host)) void {
        self.button_bounds = ev.targetBounds();
    }

    fn onPick(self: *Host, sel: *const context_menu.Selection, _: *Window, cx: *Context(Host)) void {
        self.picked = sel.tag;
        self.results += 1;
        self.in_update = cx.app.pending_updates > 0;
        cx.notify();
    }
};

fn rightClick(tw: *TestWindow, x: f32, y: f32) void {
    _ = tw.simulateInput(.{ .mouse_down = .{ .button = .right, .position = .{ .x = x, .y = y } } });
    _ = tw.simulateInput(.{ .mouse_up = .{ .button = .right, .position = .{ .x = x, .y = y } } });
}

test "context menus are unsupported by default, so callers draw theirs" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Host, Host.init, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    tw.frame(false);
    rightClick(tw, 20, 20);
    const host = handle.rootView(app).?.read(app);
    try testing.expect(host.drawn and !host.native);
    try testing.expect(tw.context_menu == null);
    try testing.expectEqual(@as(u32, 0), host.results);
}

test "a native menu copies items, icons and states and reports the chosen tag in an update" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Host, Host.init, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    tw.native_menus = true;
    tw.simulateResize(.{ .width = 400, .height = 300 }, 2);
    tw.frame(false);
    try testing.expect(context_menu.supported(w));
    rightClick(tw, 30, 40);
    const host = handle.rootView(app).?.read(app);
    try testing.expect(host.native and !host.drawn);
    const m = tw.context_menu.?;
    try testing.expectEqual(@as(f32, 30), m.position.x);
    try testing.expectEqual(@as(f32, 40), m.position.y);
    var buf: [16][]const u8 = undefined;
    const labels = m.labels(&buf);
    try testing.expectEqual(@as(usize, 7), labels.len);
    for ([_][]const u8{ "File", "Rename", "Pin", "Mixed", "Copy", "-", "Delete" }, labels) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expectEqual(.header, m.items[0].kind);
    const rename = m.find("Rename").?;
    try testing.expectEqualStrings("r", rename.shortcut.?.key);
    try testing.expect(rename.shortcut.?.modifiers.platform);
    // 16 pt at 2x: a 32 px coverage mask with the square's interior opaque.
    const icon = rename.icon.?;
    try testing.expectEqual(@as(u32, 32), icon.width);
    try testing.expectEqual(@as(f32, 2), icon.scale);
    try testing.expect(icon.alpha[16 * 32 + 16] > 200 and icon.alpha[0] == 0);
    try testing.expectEqual(.on, m.find("Pin").?.check);
    try testing.expect(m.find("Mixed").?.disabled);
    try testing.expect(m.find("Delete").?.destructive);
    try testing.expectEqual(@as(usize, 2), m.find("Copy").?.children.len);
    try testing.expectEqual(@as(usize, 5), context_menu.actionCount(&items));

    // Disabled items cannot be chosen; submenu actions can.
    try testing.expect(!tw.simulateContextMenuSelect(3));
    try testing.expect(tw.simulateContextMenuSelectLabel("Name"));
    const after = handle.rootView(app).?.read(app);
    try testing.expectEqual(@as(?u32, 11), after.picked);
    try testing.expectEqual(@as(u32, 1), after.results);
    try testing.expect(after.in_update);
    try testing.expect(tw.context_menu == null);
}

test "dismissing reports null; a second menu dismisses the first" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Host, Host.init, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    tw.native_menus = true;
    tw.frame(false);
    rightClick(tw, 10, 10);
    rightClick(tw, 12, 12);
    // The first menu's dismissal arrives on a later main-thread turn.
    tw.platform.runUntilParked();
    var host = handle.rootView(app).?.read(app);
    try testing.expectEqual(@as(u32, 1), host.results);
    try testing.expectEqual(@as(?u32, null), host.picked);
    try testing.expectEqual(@as(u32, 2), tw.context_menu_count);
    try testing.expect(tw.simulateContextMenuDismiss());
    host = handle.rootView(app).?.read(app);
    try testing.expectEqual(@as(u32, 2), host.results);
    try testing.expectEqual(@as(?u32, null), host.picked);
    try testing.expect(!tw.simulateContextMenuDismiss());
}

test "a menu still open when its window closes never reaches the listener" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Host, Host.init, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    tw.native_menus = true;
    tw.frame(false);
    rightClick(tw, 10, 10);
    try testing.expect(tw.context_menu != null);
    // The platform window outlives the core window here; choosing must be a no-op.
    w.removeWindow();
    _ = tw.simulateContextMenuSelect(1);
}

test "mouse clicks carry the clicked element's bounds" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(options, Host, Host.init, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    tw.frame(false);
    tw.click(10, 110);
    const host = handle.rootView(app).?.read(app);
    try testing.expectEqual(@as(f32, 100), host.button_bounds.origin.y);
    try testing.expectEqual(@as(f32, 40), host.button_bounds.size.width);
    try testing.expectEqual(@as(f32, 20), host.button_bounds.size.height);
}
