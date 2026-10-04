//! [appshots] Headless Appshot flow tests: the real Shell + composer on zpui's
//! TestPlatform (reference fixtures, no engine) with the Appshot service installed.
//! The TestPlatform stands in for the OS: `simulateGlobalHotkey` presses the
//! registered hotkey, `finishCapture` completes the pending capture.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const composer_mod = @import("zeron_composer");
const ui = @import("../ui/components/root.zig");
const prefs_mod = @import("../ui/shell/prefs.zig");
const fixtures_mod = @import("../ui/shell/fixtures.zig");
const shell_mod = @import("../ui/shell/shell.zig");
const lifecycle = @import("../lifecycle/root.zig");
const service = @import("service.zig");

const testing = std.testing;
const App = zpui.App;
const pf = zpui.platform;
const TestWindow = zpui.core.test_platform.TestWindow;
const png = model.appshots.png;

const chat_a = "10ae39a4-caa6-5efd-ae67-b939b8288656";

const Harness = struct {
    app: *App,
    fixtures: *fixtures_mod.Fixtures,
    state: zpui.Entity(model.AppState),
    environ: *std.process.Environ.Map,

    fn init(h: *Harness) !void {
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
        try lifecycle.install(app, .{ .gpa = gpa, .io = io, .environ = env, .state = state, .data_dir = null, .open_ctx = h, .open_main = open, .persist_geometry = false });
        try service.install(app, .{ .io = io });
        _ = lifecycle.openMainWindow(app) orelse return error.NoWindow;
        app.runUntilParked();
    }

    fn open(ctx: *anyopaque, app: *App, _: ?lifecycle.window_state.Restored) ?zpui.WindowId {
        const h: *Harness = @ptrCast(@alignCast(ctx));
        const handle = app.openWindow(.{ .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1600, .height = 1000 } } }, shell_mod.Shell, shell_mod.Shell.init, .{ h.state, h.fixtures, true }) catch return null;
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

    fn composer(h: *Harness) *const composer_mod.ComposerView {
        const sh = lifecycle.mainWindow(h.app).?.root.?.entity.downcast(shell_mod.Shell).?;
        return sh.read(h.app).main.read(h.app).slots.composer_view.read(h.app);
    }

    fn selected(h: *Harness) ?[]const u8 {
        return h.state.read(h.app).workspace.read(h.app).selected_chat;
    }

    fn select(h: *Harness, id: ?[]const u8) void {
        h.state.read(h.app).workspace.update(h.app, model.WorkspaceStore.selectChat, .{id});
        h.app.runUntilParked();
    }

    /// Another application has focus.
    fn blur(h: *Harness) void {
        TestWindow.of(lifecycle.mainWindow(h.app).?.platform_window).simulateActive(false);
        h.app.runUntilParked();
    }

    fn setEnabled(h: *Harness, on: bool) void {
        _ = model.settings_store.update(h.app, .debounced, on, struct {
            fn f(v: bool, s: *model.UiSettings, _: std.mem.Allocator) void {
                s.appshotsEnabled = v;
            }
        }.f);
        h.app.runUntilParked();
    }

    fn setDestination(h: *Harness, d: model.settings.AppshotDestination) void {
        _ = model.settings_store.update(h.app, .debounced, d, struct {
            fn f(v: model.settings.AppshotDestination, s: *model.UiSettings, _: std.mem.Allocator) void {
                s.appshotDestination = v;
            }
        }.f);
        h.app.runUntilParked();
    }

    /// Complete the pending capture with a padded 6×4 PNG (visible 4×4).
    fn finishOk(h: *Harness, app_name: []const u8, title: ?[]const u8) !void {
        const gpa = h.tp().gpa;
        var pixels: [6 * 4 * 4]u8 = @splat(0);
        for (0..4) |y| for (0..4) |x| @memcpy(pixels[(y * 6 + x) * 4 ..][0..4], &[_]u8{ 10, 20, 30, 255 });
        const bytes = try png.fixturePng(gpa, 6, 4, &pixels, 8);
        try testing.expect(h.tp().finishCapture(.{ .ok = .{
            .png = bytes,
            .app_name = try gpa.dupe(u8, app_name),
            .bundle_identifier = try gpa.dupe(u8, "com.example.app"),
            .window_title = if (title) |t| try gpa.dupe(u8, t) else null,
            .accessibility = try gpa.dupe(u8, "AXStaticText: hello"),
        } }));
        h.app.runUntilParked();
    }
};

test "the hotkey follows Capture Appshots, the combo and shortcut recording" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const tp = h.tp();
    // Off by default (`appshotsEnabled = false`).
    try testing.expect(tp.hotkey == null);
    try testing.expect(!tp.simulateGlobalHotkey());
    h.setEnabled(true);
    const hk = tp.hotkey.?;
    try testing.expectEqualStrings("space", hk.key);
    try testing.expect(hk.alt);
    try testing.expect(hk.control or hk.platform);
    // A new combo re-registers.
    _ = model.settings_store.update(h.app, .debounced, {}, struct {
        fn f(_: void, s: *model.UiSettings, arena: std.mem.Allocator) void {
            s.keymap.captureAppshot = arena.dupe(u8, "ctrl-shift-k") catch return;
        }
    }.f);
    h.app.runUntilParked();
    try testing.expectEqualStrings("k", tp.hotkey.?.key);
    try testing.expect(tp.hotkey.?.shift and tp.hotkey.?.control);
    // Recording a shortcut suspends the hotkey, and a capture is not allowed.
    service.setRecording(h.app, true);
    try testing.expect(tp.hotkey == null);
    service.setRecording(h.app, false);
    try testing.expect(tp.hotkey != null);
    h.setEnabled(false);
    try testing.expect(tp.hotkey == null);
}

test "a press captures only while another app is focused, coalesces, and stages in the composer" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const tp = h.tp();
    h.setEnabled(true);
    h.select(chat_a);
    // Zeron focused: no capture (portals cannot tell which window they captured).
    TestWindow.of(lifecycle.mainWindow(h.app).?.platform_window).simulateActive(true);
    h.app.runUntilParked();
    try testing.expect(tp.simulateGlobalHotkey());
    try testing.expectEqual(@as(usize, 0), tp.captures_requested);
    h.blur();
    try testing.expect(tp.simulateGlobalHotkey());
    try testing.expect(tp.simulateGlobalHotkey()); // in flight: coalesced
    try testing.expectEqual(@as(usize, 1), tp.captures_requested);
    const sounds_before = tp.sounds_played;
    try h.finishOk("Safari", "Docs");
    try testing.expectEqual(sounds_before + 1, tp.sounds_played);
    const c = h.composer();
    const shots = c.appshotsFor(chat_a);
    try testing.expectEqual(@as(usize, 1), shots.len);
    try testing.expectEqualStrings("Safari", shots[0].app_name);
    try testing.expectEqualStrings("Docs", shots[0].window_title.?);
    try testing.expectEqualStrings("Safari Appshot.png", shots[0].screenshot.name);
    // Transparent padding is trimmed before staging.
    try testing.expectEqual([2]u32{ 4, 4 }, shots[0].dimensions.?);
    try testing.expect(shots[0].screenshot.image != null);
    try testing.expectEqual(@as(usize, 1), tp.foreground_requests);
    try testing.expectEqualStrings(chat_a, h.selected().?);
    // A new press after delivery captures again.
    h.blur();
    try testing.expect(tp.simulateGlobalHotkey());
    try testing.expectEqual(@as(usize, 2), tp.captures_requested);
    try h.finishOk("Terminal", null);
    try testing.expectEqual(@as(usize, 2), h.composer().appshotsFor(chat_a).len);
}

test "capture failures show in the composer; cancellations stay silent" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const tp = h.tp();
    h.setEnabled(true);
    h.blur();
    try testing.expect(tp.simulateGlobalHotkey());
    try testing.expect(tp.finishCapture(.{ .err = .cancelled }));
    h.app.runUntilParked();
    try testing.expectEqual(@as(usize, 0), h.composer().failure.items.len);
    try testing.expectEqual(@as(usize, 0), tp.foreground_requests);
    h.blur();
    try testing.expect(tp.simulateGlobalHotkey());
    try testing.expect(tp.finishCapture(.{ .err = .permission_required }));
    h.app.runUntilParked();
    try testing.expect(std.mem.startsWith(u8, h.composer().failure.items, "Window capture permission is required."));
    // An undecodable capture fails at staging with Rust's message.
    h.blur();
    try testing.expect(tp.simulateGlobalHotkey());
    const gpa = tp.gpa;
    try testing.expect(tp.finishCapture(.{ .ok = .{ .png = try gpa.dupe(u8, "not a png"), .app_name = try gpa.dupe(u8, "X") } }));
    h.app.runUntilParked();
    try testing.expectEqualStrings("The captured window is not a valid PNG image.", h.composer().failure.items);
}

test "destinations: automatic, last session and new session" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const tp = h.tp();
    h.setEnabled(true);
    // Last session: the canvas is open, the last selected chat receives it.
    h.select(chat_a);
    h.select(null);
    h.setDestination(.@"last-session");
    h.blur();
    try testing.expect(tp.simulateGlobalHotkey());
    try h.finishOk("Notes", null);
    try testing.expectEqualStrings(chat_a, h.selected().?);
    try testing.expectEqual(@as(usize, 1), h.composer().appshotsFor(chat_a).len);
    // New session: a chat is open, the capture goes to a fresh canvas.
    h.setDestination(.@"new-session");
    h.blur();
    try testing.expect(tp.simulateGlobalHotkey());
    try h.finishOk("Mail", null);
    try testing.expect(h.selected() == null);
    try testing.expectEqual(@as(usize, 1), h.composer().appshotsFor("").len);
    try testing.expectEqual(@as(usize, 1), h.composer().stagedAppshots().len);
    // Automatic on the canvas stays on the canvas.
    h.setDestination(.automatic);
    h.blur();
    try testing.expect(tp.simulateGlobalHotkey());
    try h.finishOk("Finder", null);
    try testing.expect(h.selected() == null);
    try testing.expectEqual(@as(usize, 2), h.composer().appshotsFor("").len);
}

test "settings close when a capture arrives" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const tp = h.tp();
    h.setEnabled(true);
    const sh = lifecycle.mainWindow(h.app).?.root.?.entity.downcast(shell_mod.Shell).?;
    _ = (zpui.WindowHandle(shell_mod.Shell){ .id = lifecycle.mainWindow(h.app).?.id }).update(h.app, shell_mod.Shell.openSettings, .{});
    h.app.runUntilParked();
    try testing.expect(sh.read(h.app).settings_view != null);
    h.blur();
    try testing.expect(tp.simulateGlobalHotkey());
    try h.finishOk("Preview", null);
    try testing.expect(sh.read(h.app).settings_view == null);
}
