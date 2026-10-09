//! Tests for src/app/desktop.zig (global input, foreground app, tray, launch at login)
//! and the overlay window API (anchor, resize with a fixed corner, visibility, input
//! regions) on the TestPlatform.

const std = @import("std");
const testing = std.testing;
const app_mod = @import("app.zig");
const App = app_mod.App;
const Context = @import("context.zig").Context;
const action_mod = @import("action.zig");
const pf = @import("../platform/platform.zig");
const tp_mod = @import("test_platform.zig");
const TestWindow = tp_mod.TestWindow;
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const elements = @import("../elements/mod.zig");
const div = elements.div;
const px = @import("../geometry.zig").px;
const desktop = @import("desktop.zig");

const Quit = action_mod.action("test::DesktopQuit");
const Toggle = action_mod.action("test::DesktopToggle");

const Pet = struct {
    keys: u32 = 0,
    last: ?pf.GlobalInputEvent = null,
    fg_changes: u32 = 0,
    quits: u32 = 0,
    toggles: u32 = 0,

    fn onInput(self: *Pet, e: pf.GlobalInputEvent, _: *App) void {
        if (e.kind == .key_down) self.keys += 1;
        self.last = e;
    }
    fn onForeground(self: *Pet, _: *App) void {
        self.fg_changes += 1;
    }
    fn onQuit(self: *Pet, _: *const Quit, _: *App) void {
        self.quits += 1;
    }
    fn onToggle(self: *Pet, _: *const Toggle, _: *App) void {
        self.toggles += 1;
    }
};

test "global input monitor delivers events inside an update; stop detaches" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    var pet: Pet = .{};
    try testing.expectEqual(pf.InputMonitorStatus.ok, app.startGlobalInputMonitor(&pet, Pet.onInput));
    try testing.expect(tp.simulateGlobalInput(.{ .kind = .key_down, .key = .letter, .key_x = 0.2, .timestamp_ns = 1 }));
    try testing.expect(tp.simulateGlobalInput(.{ .kind = .key_up, .key = .letter, .timestamp_ns = 2 }));
    try testing.expectEqual(@as(u32, 1), pet.keys);
    try testing.expectEqual(pf.GlobalInputKind.key_up, pet.last.?.kind);

    app.setPreciseInput(true);
    try testing.expect(tp.precise_input);
    try testing.expectEqual(pf.InputPermission.not_applicable, app.inputPermission());
    app.requestInputPermission();
    try testing.expectEqual(@as(usize, 1), tp.permission_requests);

    app.stopGlobalInputMonitor();
    try testing.expect(!tp.simulateGlobalInput(.{ .kind = .key_down, .timestamp_ns = 3 }));

    tp.input_monitor_status = .needs_permission;
    try testing.expectEqual(pf.InputMonitorStatus.needs_permission, app.startGlobalInputMonitor(&pet, Pet.onInput));
}

test "foreground app queries and change listeners" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    var pet: Pet = .{};
    var buf: [128]u8 = undefined;
    try testing.expect(app.foregroundApp(&buf) == null);
    try app.onForegroundAppChange(&pet, Pet.onForeground);
    tp.simulateForegroundApp(.{ .id = "com.apple.Terminal", .name = "Terminal" });
    try testing.expectEqual(@as(u32, 1), pet.fg_changes);
    const fg = app.foregroundApp(&buf).?;
    try testing.expectEqualStrings("com.apple.Terminal", fg.id);
    try testing.expectEqualStrings("Terminal", fg.name);
    tp.simulateForegroundApp(null);
    try testing.expectEqual(@as(u32, 2), pet.fg_changes);
    try testing.expect(app.foregroundApp(&buf) == null);
}

test "tray menu actions dispatch like the menu bar and never collide with its tags" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    var pet: Pet = .{};
    try app.onAction(Quit, &pet, Pet.onQuit);
    try app.onAction(Toggle, &pet, Pet.onToggle);
    try app.setMenus(&.{.{ .name = "App", .items = &.{.action("Quit", Quit{})} }});
    try app.setTray(.{ .icon_png = "png", .tooltip = "typebud", .items = &.{
        .action("Hide pet", Toggle{}),
        .separator,
        .action("Quit typebud", Quit{}),
    } });
    const t = tp.tray.?;
    try testing.expectEqualStrings("typebud", t.tooltip);
    const quit_tag = tp.trayTag("Quit typebud").?;
    const toggle_tag = tp.trayTag("Hide pet").?;
    try testing.expect(quit_tag >= desktop.tray_tag_base and toggle_tag >= desktop.tray_tag_base);
    try testing.expect(quit_tag != tp.menuTag("Quit").?);

    tp.simulateMenuAction(toggle_tag);
    tp.simulateMenuAction(quit_tag);
    tp.simulateMenuAction(tp.menuTag("Quit").?);
    try testing.expectEqual(@as(u32, 1), pet.toggles);
    try testing.expectEqual(@as(u32, 2), pet.quits);
    try testing.expect(tp.simulateValidateMenu(quit_tag));
    // Replacing the menus keeps the tray working and vice versa.
    try app.setMenus(&.{});
    tp.simulateMenuAction(quit_tag);
    try testing.expectEqual(@as(u32, 3), pet.quits);
    try app.setTray(null);
    try testing.expect(tp.tray == null);
    tp.simulateMenuAction(quit_tag); // stale: ignored
    try testing.expectEqual(@as(u32, 3), pet.quits);

    tp.tray_supported = false;
    try testing.expectError(error.Unsupported, app.setTray(.{ .icon_png = "", .items = &.{} }));

    try testing.expectEqual(false, try app.launchAtLoginEnabled("typebud"));
    try app.setLaunchAtLogin("typebud", "/usr/bin/typebud", true);
    try testing.expectEqual(@as(?bool, true), tp.launch_at_login);
    try testing.expectEqual(true, try app.launchAtLoginEnabled("typebud"));
    const calls = tp.launch_at_login_calls;
    try app.setLaunchAtLogin("typebud", "/usr/bin/typebud", false);
    try testing.expectEqual(false, try app.launchAtLoginEnabled("typebud"));
    try testing.expectEqual(calls + 1, tp.launch_at_login_calls); // queries never write
    try testing.expectEqual(@as(usize, 3), tp.launch_at_login_queries);
    tp.launch_at_login_query_supported = false;
    try testing.expectError(error.Unsupported, app.launchAtLoginEnabled("typebud"));
}

const Blob = struct {
    fn init(_: *Window, _: *Context(Blob)) Blob {
        return .{};
    }
    pub fn render(_: *Blob, _: *Window, _: *Context(Blob)) elements.Div {
        return div().size(px(50));
    }
};

test "overlay windows: anchored placement, resize keeps the corner, visibility, input regions" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    const displays = [_]pf.Display{
        .{ .id = 1, .bounds = .{ .origin = .zero, .size = .{ .width = 1440, .height = 900 } }, .visible_bounds = .{ .origin = .{ .x = 0, .y = 25 }, .size = .{ .width = 1440, .height = 800 } }, .scale_factor = 2, .primary = true },
        .{ .id = 7, .bounds = .{ .origin = .{ .x = 1440, .y = 0 }, .size = .{ .width = 1920, .height = 1080 } }, .visible_bounds = .{ .origin = .{ .x = 1440, .y = 0 }, .size = .{ .width = 1920, .height = 1040 } }, .scale_factor = 1 },
    };
    tp.display_list = &displays;
    const handle = try app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 5, .y = 5 }, .size = .{ .width = 160, .height = 120 } },
        .kind = .overlay,
        .titlebar = null,
        .focus = false,
        .background = .transparent,
        .mouse_passthrough = true,
        .anchor = .{ .corner = .bottom_right, .margin = .{ .x = 16, .y = 16 } },
    }, Blob, Blob.init, .{});
    const w = handle.window(app).?;
    const tw = TestWindow.of(w.platform_window);
    try testing.expectEqual(pf.WindowKind.overlay, tw.kind);
    try testing.expect(tw.mouse_passthrough);
    // 1440 - 160 - 16, 25 + 800 - 120 - 16
    try testing.expectEqual(pf.Point{ .x = 1264, .y = 689 }, tw.bounds.origin);

    // Aspect-locked grow: the bottom-right corner stays where it was.
    w.resize(.{ .width = 200, .height = 150 });
    try testing.expectEqual(pf.Point{ .x = 1224, .y = 659 }, tw.bounds.origin);
    try testing.expectEqual(@as(f32, 200), w.viewportSize().width);

    // Dragged to the other display, snapped to its top-left corner.
    w.setAnchor(.{ .corner = .top_left, .margin = .{ .x = 30, .y = 40 } }, 7);
    try testing.expectEqual(pf.Point{ .x = 1470, .y = 40 }, tw.bounds.origin);

    w.setMousePassthrough(false);
    try testing.expect(!tw.mouse_passthrough);
    const rects = [_]pf.Bounds{.{ .origin = .{ .x = 40, .y = 30 }, .size = .{ .width = 120, .height = 100 } }};
    w.setInputRegion(&rects);
    try testing.expectEqual(@as(usize, 1), tw.input_region.?.len);
    w.setInputRegion(null);
    try testing.expect(tw.input_region == null);

    tw.moveMouse(10, 20);
    try testing.expectEqual(pf.Point{ .x = 1480, .y = 60 }, w.screenMousePosition().?);

    // Hidden: no frames are requested; showing redraws.
    tw.frame(false);
    w.setVisible(false);
    try testing.expect(!tw.visible);
    w.refresh();
    try testing.expect(!tw.frame_requested);
    w.setVisible(true);
    try testing.expect(tw.visible and tw.frame_requested);
}
