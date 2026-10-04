//! Tests for src/app/lifecycle.zig (App lifecycle listeners, quit veto, menus) and the
//! window lifecycle hooks (`onShouldClose`, `observeBounds`) on the TestPlatform.

const std = @import("std");
const testing = std.testing;
const app_mod = @import("app.zig");
const App = app_mod.App;
const Context = @import("context.zig").Context;
const action_mod = @import("action.zig");
const lifecycle = @import("lifecycle.zig");
const tp_mod = @import("test_platform.zig");
const TestWindow = tp_mod.TestWindow;
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const elements = @import("../elements/mod.zig");
const div = elements.div;
const px = @import("../geometry.zig").px;

const Quit = action_mod.action("test::Quit");
const Save = action_mod.action("test::Save");
const Unbound = action_mod.action("test::Unbound");

const Log = struct {
    quits: u32 = 0,
    reopens: u32 = 0,
    wakes: u32 = 0,
    allow_quit: bool = true,
    asked: u32 = 0,
    urls: [4][64]u8 = undefined,
    url_lens: [4]usize = @splat(0),
    url_count: usize = 0,
    clicked: [64]u8 = undefined,
    clicked_len: usize = 0,
    saves: u32 = 0,
    global_quits: u32 = 0,
    allow_close: bool = true,
    bounds_changes: u32 = 0,

    fn onQuit(self: *Log, _: *App) void {
        self.quits += 1;
    }
    fn onReopen(self: *Log, _: *App) void {
        self.reopens += 1;
    }
    fn onWake(self: *Log, _: *App) void {
        self.wakes += 1;
    }
    fn shouldQuit(self: *Log, _: *App) bool {
        self.asked += 1;
        return self.allow_quit;
    }
    fn onUrls(self: *Log, urls: []const []const u8, _: *App) void {
        for (urls) |u| {
            if (self.url_count == self.urls.len) return;
            @memcpy(self.urls[self.url_count][0..u.len], u);
            self.url_lens[self.url_count] = u.len;
            self.url_count += 1;
        }
    }
    fn url(self: *const Log, i: usize) []const u8 {
        return self.urls[i][0..self.url_lens[i]];
    }
    fn onClick(self: *Log, tag: []const u8, _: *App) void {
        @memcpy(self.clicked[0..tag.len], tag);
        self.clicked_len = tag.len;
    }
    fn onGlobalQuit(self: *Log, _: *const Quit, _: *App) void {
        self.global_quits += 1;
    }
    fn shouldClose(self: *Log, _: *Window, _: *App) bool {
        return self.allow_close;
    }
    fn onBounds(self: *Log, _: *Window, _: *App) void {
        self.bounds_changes += 1;
    }
};

test "open-url listeners get cold-launch URLs queued before they registered" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    tp.simulateOpenUrls(&.{"zeron://open/chat/a?workspace=w"});
    var log: Log = .{};
    try app.onOpenUrls(&log, Log.onUrls);
    try testing.expectEqual(@as(usize, 1), log.url_count);
    try testing.expectEqualStrings("zeron://open/chat/a?workspace=w", log.url(0));
    tp.simulateOpenUrls(&.{ "zeron://x", "zeron://y" });
    try testing.expectEqual(@as(usize, 3), log.url_count);
    try testing.expectEqualStrings("zeron://y", log.url(2));
}

test "reopen, wake and notification clicks reach their listeners" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    var log: Log = .{};
    try app.onReopen(&log, Log.onReopen);
    try app.onSystemWake(&log, Log.onWake);
    try app.onNotificationActivated(&log, Log.onClick);
    tp.simulateReopen();
    tp.simulateReopen();
    if (tp.callbacks.system_wake) |f| f(tp.callbacks.ctx);
    tp.simulateNotificationClick("chat-42");
    try testing.expectEqual(@as(u32, 2), log.reopens);
    try testing.expectEqual(@as(u32, 1), log.wakes);
    try testing.expectEqualStrings("chat-42", log.clicked[0..log.clicked_len]);
}

test "requestQuit asks should-quit listeners; a veto keeps the app alive; quit listeners run once" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    var log: Log = .{ .allow_quit = false };
    try app.onShouldQuit(&log, Log.shouldQuit);
    try app.onQuit(&log, Log.onQuit);

    app.requestQuit();
    app.runUntilParked();
    try testing.expectEqual(@as(u32, 1), log.asked);
    try testing.expect(!tp.quit_requested);
    try testing.expectEqual(@as(u32, 0), log.quits);

    // An OS termination request is canceled and routed through the same veto.
    try testing.expect(!tp.simulateTerminate());
    try testing.expectEqual(@as(u32, 2), log.asked);
    try testing.expect(!tp.quit_requested);

    log.allow_quit = true;
    app.requestQuit();
    app.runUntilParked();
    try testing.expect(tp.quit_requested);
    try testing.expectEqual(@as(u32, 1), log.quits);
    // `quit()` itself is never vetoed and the quit listeners never run twice.
    try testing.expect(tp.simulateTerminate());
    app.quit();
    try testing.expectEqual(@as(u32, 1), log.quits);
}

const Drain = struct {
    drained: *std.atomic.Value(u32),
    pub fn run(self: *Drain) void {
        _ = self.drained.fetchAdd(1, .acq_rel);
    }
};

const AsyncQuit = struct {
    drained: std.atomic.Value(u32) = .init(0),
    sync_ran: bool = false,
    order_ok: bool = true,
    fn sync(self: *AsyncQuit, _: *App) void {
        self.sync_ran = true;
    }
    fn teardown(self: *AsyncQuit, app: *App) lifecycle.QuitTeardown {
        // gpui runs every quit observer before awaiting the futures.
        if (!self.sync_ran) self.order_ok = false;
        const task = app.backgroundExecutor().spawn(Drain{ .drained = &self.drained }) catch return .none;
        return .of(task);
    }
    fn nothing(_: *AsyncQuit, _: *App) lifecycle.QuitTeardown {
        return .none;
    }
};

test "onQuitAsync: the exit waits for every teardown task's background phase, once" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var q: AsyncQuit = .{};
    try app.onQuit(&q, AsyncQuit.sync);
    try app.onQuitAsync(&q, AsyncQuit.teardown);
    try app.onQuitAsync(&q, AsyncQuit.nothing);
    try app.onQuitAsync(&q, AsyncQuit.teardown);
    app.quit();
    // `quit` returns after the teardowns drained (no runUntilParked needed).
    try testing.expectEqual(@as(u32, 2), q.drained.load(.acquire));
    try testing.expect(q.order_ok);
    app.quit();
    app.runUntilParked();
    try testing.expectEqual(@as(u32, 2), q.drained.load(.acquire));
}

const MenuView = struct {
    focus: @import("../window/focus.zig").FocusHandle,
    saves: *u32,
    fn init(saves: *u32, _: *Window, cx: *Context(MenuView)) MenuView {
        return .{ .focus = cx.app.focusHandle(), .saves = saves };
    }
    pub fn deinit(self: *MenuView, app: *App) void {
        self.focus.release(app);
    }
    pub fn render(self: *MenuView, _: *Window, cx: *Context(MenuView)) elements.Div {
        return div().trackFocus(self.focus).size(px(100)).onAction(Save, cx.listener(MenuView.save));
    }
    fn save(self: *MenuView, _: *const Save, _: *Window, _: *Context(MenuView)) void {
        self.saves.* += 1;
    }
};

test "setMenus renders key equivalents from the keymap and dispatches/validates through actions" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    try app.bindKeys(&.{ .init("cmd-q", Quit{}, null), .init("cmd-s", Save{}, "Editor"), .init("cmd-k cmd-u", Unbound{}, null) });
    var log: Log = .{};
    try app.onAction(Quit, &log, Log.onGlobalQuit);
    var saves: u32 = 0;
    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 200, .height = 200 } } }, MenuView, MenuView.init, .{&saves});
    const w = handle.window(app).?;
    w.focus(handle.rootView(app).?.read(app).focus);
    app.runUntilParked();

    try app.setMenus(&.{
        .{ .name = "App", .items = &.{
            .action("Quit App", Quit{}),
            .separator,
            .osSubmenu("Services", .services),
        } },
        .{ .name = "File", .items = &.{
            .action("Save", Save{}),
            .action("Chord", Unbound{}),
            .{ .submenu = .{ .name = "More", .items = &.{.action("Save Again", Save{})} } },
        } },
    });
    try testing.expectEqual(@as(usize, 1), tp.menu_sets);
    try testing.expectEqual(@as(usize, 2), tp.menus.len);
    const quit_item = tp.menus[0].items[0].action;
    try testing.expectEqualStrings("Quit App", quit_item.name);
    try testing.expectEqualStrings("q", quit_item.key_equivalent.?.key);
    try testing.expect(quit_item.key_equivalent.?.modifiers.platform);
    try testing.expect(tp.menus[0].items[1] == .separator);
    try testing.expect(tp.menus[0].items[2] == .system_menu);
    // Context-only bindings still show; multi-stroke chords cannot be key equivalents.
    try testing.expectEqualStrings("s", tp.menus[1].items[0].action.key_equivalent.?.key);
    try testing.expect(tp.menus[1].items[1].action.key_equivalent == null);

    tp.simulateMenuAction(tp.menuTag("Quit App").?);
    try testing.expectEqual(@as(u32, 1), log.global_quits);
    tp.simulateMenuAction(tp.menuTag("Save Again").?);
    try testing.expectEqual(@as(u32, 1), saves);
    try testing.expect(tp.simulateValidateMenu(tp.menuTag("Save").?));
    try testing.expect(!tp.simulateValidateMenu(tp.menuTag("Chord").?));
    try testing.expect(app.isActionAvailable(Quit));

    // Without an active window only global listeners are available.
    tp_mod.TestWindow.of(w.platform_window).simulateActive(false);
    try testing.expect(app.activeWindow() == null);
    try testing.expect(!tp.simulateValidateMenu(tp.menuTag("Save").?));
    try testing.expect(tp.simulateValidateMenu(tp.menuTag("Quit App").?));
}

test "app commands, notifications and sounds reach the platform" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    app.hide();
    app.hideOtherApps();
    app.unhideOtherApps();
    try testing.expectEqualSlices(@import("../platform/platform.zig").AppCommand, &.{ .hide, .hide_other_apps, .unhide_other_apps }, tp.app_commands.items);
    app.postNotification(.{ .title = "Run finished", .body = "x", .tag = "chat-1" });
    app.playSound("RIFF");
    try testing.expectEqualStrings("Run finished", tp.notifications.items[0][0]);
    try testing.expectEqualStrings("chat-1", tp.notifications.items[0][1]);
    try testing.expectEqual(@as(usize, 1), tp.sounds_played);
}

const Plain = struct {
    fn init(_: *Window, _: *Context(Plain)) Plain {
        return .{};
    }
    pub fn render(_: *Plain, _: *Window, _: *Context(Plain)) elements.Div {
        return div().size(px(50));
    }
};

test "window close veto, bounds observers and quit when the last window closes" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const tp = app.test_platform.?;
    app.quit_when_last_window_closes = true;
    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 200, .height = 200 } } }, Plain, Plain.init, .{});
    const w = handle.window(app).?;
    var log: Log = .{ .allow_close = false };
    try w.onShouldClose(&log, Log.shouldClose);
    try w.observeBounds(&log, Log.onBounds);
    const tw = TestWindow.of(w.platform_window);

    tw.simulateMove(.{ .x = 10, .y = 20 });
    tw.simulateResize(.{ .width = 300, .height = 200 }, 1);
    try testing.expectEqual(@as(u32, 2), log.bounds_changes);

    try testing.expect(!tw.simulateCloseButton());
    app.runUntilParked();
    try testing.expectEqual(@as(usize, 1), app.windowCount());
    try testing.expect(!tp.quit_requested);

    log.allow_close = true;
    try testing.expect(tw.simulateCloseButton());
    app.runUntilParked();
    try testing.expectEqual(@as(usize, 0), app.windowCount());
    try testing.expect(tp.quit_requested);
}
