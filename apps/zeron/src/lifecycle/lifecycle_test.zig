//! Lifecycle integration tests: the real Shell on zpui's TestPlatform (reference
//! fixtures, no engine) with `lifecycle.install` — menus + menu actions, the quit gate,
//! Linux last-window quit / reopen, deep links, banner clicks, session sounds and
//! banners, and geometry / pane-size persistence.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const ui = @import("../ui/components/root.zig");
const prefs_mod = @import("../ui/shell/prefs.zig");
const fixtures_mod = @import("../ui/shell/fixtures.zig");
const shell_mod = @import("../ui/shell/shell.zig");
const sidebar_mod = @import("../ui/sidebar/sidebar.zig");
const lifecycle = @import("root.zig");
const links = @import("links.zig");

const testing = std.testing;
const App = zpui.App;
const TestWindow = zpui.core.test_platform.TestWindow;

const chat_a = "10ae39a4-caa6-5efd-ae67-b939b8288656";
const chat_b = "3d082f2f-880f-5326-9b2a-522f20f41db1";

const Harness = struct {
    app: *App,
    fixtures: *fixtures_mod.Fixtures,
    state: zpui.Entity(model.AppState),
    environ: *std.process.Environ.Map,
    opens: u32 = 0,

    fn init(h: *Harness, persist_geometry: bool) !void {
        const gpa = testing.allocator;
        const io = std.testing.io;
        const app = try App.initTest(gpa);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        const f = try fixtures_mod.load(gpa, io, "apps/zeron/fixtures/reference");
        var prefs: prefs_mod.Prefs = .{ .gpa = gpa };
        fixtures_mod.applyPrefs(f, &prefs);
        try ui.theme.install(app, zt.Theme.dark());
        try prefs_mod.install(app, prefs);
        try model.settings_store.initMemory(app, io);
        const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false, .wake_mode = .poll } });
        fixtures_mod.applyToState(f, io, app, state);
        const env = try gpa.create(std.process.Environ.Map);
        env.* = .init(gpa);
        h.* = .{ .app = app, .fixtures = f, .state = state, .environ = env };
        try lifecycle.install(app, .{
            .gpa = gpa,
            .io = io,
            .environ = env,
            .state = state,
            .data_dir = null,
            .open_ctx = h,
            .open_main = open,
            .persist_geometry = persist_geometry,
        });
        _ = lifecycle.openMainWindow(app) orelse return error.NoWindow;
        app.runUntilParked();
    }

    fn open(ctx: *anyopaque, app: *App, restored: ?lifecycle.window_state.Restored) ?zpui.WindowId {
        const h: *Harness = @ptrCast(@alignCast(ctx));
        h.opens += 1;
        const handle = app.openWindow(.{
            .bounds = if (restored) |r| r.bounds else .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1600, .height = 1000 } },
            .display_id = if (restored) |r| r.display_id else null,
        }, shell_mod.Shell, shell_mod.Shell.init, .{ h.state, h.fixtures, true }) catch return null;
        return handle.id;
    }

    fn deinit(h: *Harness) void {
        h.state.release(h.app);
        h.app.deinit();
        h.fixtures.deinit();
        testing.allocator.destroy(h.fixtures);
        h.environ.deinit();
        testing.allocator.destroy(h.environ);
    }

    fn tp(h: *Harness) *zpui.core.TestPlatform {
        return h.app.test_platform.?;
    }

    fn selected(h: *Harness) ?[]const u8 {
        return h.state.read(h.app).workspace.read(h.app).selected_chat;
    }

    fn shell(h: *Harness) zpui.Entity(shell_mod.Shell) {
        return lifecycle.mainWindow(h.app).?.root.?.entity.downcast(shell_mod.Shell).?;
    }
};

test "lifecycle installs the menu bar; menu actions reach the shell and the app" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const tp = h.tp();
    try testing.expect(tp.menu_sets >= 1);
    try testing.expectEqualStrings("Zeron", tp.menus[0].name);
    // Settings (shell::OpenSettings) opens the settings page in the focused shell.
    tp.simulateMenuAction(tp.menuTag("Settings").?);
    h.app.runUntilParked();
    try testing.expect(h.shell().read(h.app).settings_view != null);
    // Appearance: Light persists to the settings store.
    tp.simulateMenuAction(tp.menuTag("Appearance: Light").?);
    h.app.runUntilParked();
    try testing.expectEqual(zt.settings.AppearanceMode.light, model.settings_store.current(h.app).?.theme.appearance);
    try testing.expect(tp.simulateValidateMenu(tp.menuTag("Quit Zeron").?));
    // Quit with no unsaved files quits.
    tp.simulateMenuAction(tp.menuTag("Quit Zeron").?);
    h.app.runUntilParked();
    try testing.expect(tp.quit_requested);
}

test "Linux: closing the last window quits; macOS keeps the app and the dock reopens it" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const tp = h.tp();
    const w = lifecycle.mainWindow(h.app).?;
    try testing.expect(TestWindow.of(w.platform_window).simulateCloseButton());
    h.app.runUntilParked();
    try testing.expectEqual(@as(usize, 0), h.app.windowCount());
    if (builtin.os.tag == .macos) {
        try testing.expect(!tp.quit_requested);
        tp.simulateReopen();
        h.app.runUntilParked();
        try testing.expectEqual(@as(usize, 1), h.app.windowCount());
        try testing.expectEqual(@as(u32, 2), h.opens);
    } else {
        try testing.expect(tp.quit_requested);
    }
}

test "deep links select the chat in this workspace and reject foreign ones" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const ws = h.state.read(h.app).workspace.read(h.app);
    var buf: [16]u8 = undefined;
    const locator = links.workspaceLocator(&buf, ws.workspace_scope, null, ws.local_device_id).?;
    const url = try links.conversationLink(testing.allocator, chat_b, locator);
    defer testing.allocator.free(url);
    h.tp().simulateOpenUrls(&.{url});
    h.app.runUntilParked();
    try testing.expectEqualStrings(chat_b, h.selected().?);

    const foreign = try links.conversationLink(testing.allocator, chat_a, "0000000000000000");
    defer testing.allocator.free(foreign);
    zpui.lifecycle.openUrls(h.app, &.{foreign});
    h.app.runUntilParked();
    try testing.expectEqualStrings(chat_b, h.selected().?);
    const sidebar = h.shell().read(h.app).sidebar.read(h.app);
    try testing.expectEqualStrings("This conversation link belongs to another workspace", sidebar.notice.?);

    const missing = try links.conversationLink(testing.allocator, "no-such-chat", locator);
    defer testing.allocator.free(missing);
    zpui.lifecycle.openUrls(h.app, &.{missing});
    h.app.runUntilParked();
    try testing.expectEqualStrings("The linked conversation was not found", h.shell().read(h.app).sidebar.read(h.app).notice.?);
}

test "banner clicks focus the chat; agent-update banners open Settings → Agents" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    h.tp().simulateNotificationClick(chat_a);
    h.app.runUntilParked();
    try testing.expectEqualStrings(chat_a, h.selected().?);
    h.tp().simulateNotificationClick(lifecycle.notify.agent_updates_target);
    h.app.runUntilParked();
    try testing.expect(h.shell().read(h.app).settings_view != null);
    try testing.expectEqual(model.settings.SettingsSection.harnesses, model.settings_store.current(h.app).?.settingsSection);
}

fn sessionsFrame(json: []const u8) !std.json.Parsed([]@import("zeron_engine").protocol.Session) {
    return std.json.parseFromSlice([]@import("zeron_engine").protocol.Session, testing.allocator, json, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

test "session transitions chime and post banners per the settings" {
    var h: Harness = undefined;
    try h.init(false);
    defer h.deinit();
    const tp = h.tp();
    const notifier = h.app.global(lifecycle.Lifecycle).notifier.?;
    // A frozen clock right at the sessions' update time keeps them fresh.
    const now = model.time.parse("2026-10-04T07:30:00Z").?;
    notifier.update(h.app, struct {
        fn f(n: *lifecycle.notify.Notifier, t: model.time.Timestamp, _: *zpui.Context(lifecycle.notify.Notifier)) void {
            n.now_override = t;
        }
    }.f, .{now});
    const ws = h.state.read(h.app).workspace;
    ws.update(h.app, struct {
        fn f(w: *model.WorkspaceStore, t: model.time.Timestamp, _: *zpui.Context(model.WorkspaceStore)) void {
            w.now_override = t;
        }
    }.f, .{now});
    const Apply = struct {
        fn f(w: *model.WorkspaceStore, frame: std.json.Parsed([]@import("zeron_engine").protocol.Session), cx: *zpui.Context(model.WorkspaceStore)) void {
            w.applySessions(frame, cx);
        }
    };
    const working =
        \\[{"chatId":"10ae39a4-caa6-5efd-ae67-b939b8288656","deviceId":"d","status":"working","updatedAt":"2026-10-04T07:30:00Z"}]
    ;
    ws.update(h.app, Apply.f, .{try sessionsFrame(working)});
    h.app.runUntilParked();
    try testing.expectEqual(@as(usize, 0), tp.sounds_played); // first sight seeds silently

    // Background-only banners: the window is key, so only the chime.
    const waiting =
        \\[{"chatId":"10ae39a4-caa6-5efd-ae67-b939b8288656","deviceId":"d","status":"awaitingInput","updatedAt":"2026-10-04T07:30:00Z"}]
    ;
    ws.update(h.app, Apply.f, .{try sessionsFrame(waiting)});
    h.app.runUntilParked();
    try testing.expectEqual(@as(usize, 1), tp.sounds_played);
    try testing.expectEqual(@as(usize, 0), tp.notifications.items.len);

    // In the background the banner posts too, tagged with the chat id.
    TestWindow.of(lifecycle.mainWindow(h.app).?.platform_window).simulateActive(false);
    const done =
        \\[{"chatId":"10ae39a4-caa6-5efd-ae67-b939b8288656","deviceId":"d","status":"idle","updatedAt":"2026-10-04T07:30:00Z","lastCompletedTurn":"t1"}]
    ;
    ws.update(h.app, Apply.f, .{try sessionsFrame(done)});
    h.app.runUntilParked();
    try testing.expectEqual(@as(usize, 2), tp.sounds_played);
    try testing.expectEqual(@as(usize, 1), tp.notifications.items.len);
    try testing.expectEqualStrings("Fix flaky Button snapshot test", tp.notifications.items[0][0]);
    try testing.expectEqualStrings(chat_a, tp.notifications.items[0][1]);

    // Sounds off: no chime (banners still follow their own switch).
    const Off = struct {
        fn f(_: void, s: *model.UiSettings, _: std.mem.Allocator) void {
            s.soundEnabled = false;
        }
    };
    _ = model.settings_store.update(h.app, .immediate, {}, Off.f);
    const failed =
        \\[{"chatId":"10ae39a4-caa6-5efd-ae67-b939b8288656","deviceId":"d","status":"errored","updatedAt":"2026-10-04T07:30:00Z","lastCompletedTurn":"t1"}]
    ;
    ws.update(h.app, Apply.f, .{try sessionsFrame(failed)});
    h.app.runUntilParked();
    try testing.expectEqual(@as(usize, 2), tp.sounds_played);
    try testing.expectEqual(@as(usize, 2), tp.notifications.items.len);
}

test "window geometry and pane sizes are written back to ui-settings" {
    var h: Harness = undefined;
    try h.init(true);
    defer h.deinit();
    const w = lifecycle.mainWindow(h.app).?;
    const tw = TestWindow.of(w.platform_window);
    tw.simulateMove(.{ .x = 40, .y = 60 });
    h.app.runUntilParked();
    const g = model.settings_store.current(h.app).?.windowGeometry.?;
    try testing.expectEqual(@as(f32, 40), g.x);
    try testing.expectEqual(@as(f32, 60), g.y);
    // ⌘B / ctrl-B collapses the sidebar; the flag lands in the settings.
    const mod = if (builtin.os.tag == .macos) "cmd" else "ctrl";
    tw.typeKey(mod ++ "-b");
    h.app.runUntilParked();
    try testing.expect(model.settings_store.current(h.app).?.sidebarCollapsed);
}
