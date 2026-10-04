//! Headless shell tests: the real Shell + Sidebar rendered on zpui's
//! TestPlatform from the checked-in reference fixtures (no engine).

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const prefs_mod = @import("prefs.zig");
const fixtures_mod = @import("fixtures.zig");
const shell_mod = @import("shell.zig");
const sidebar_mod = @import("../sidebar/sidebar.zig");

const testing = std.testing;
const TestWindow = zpui.core.test_platform.TestWindow;

const Harness = struct {
    app: *zpui.App,
    fixtures: *fixtures_mod.Fixtures,
    state: zpui.Entity(model.AppState),
    handle: zpui.WindowHandle(shell_mod.Shell),

    fn init(dir: []const u8) !Harness {
        const gpa = testing.allocator;
        const io = std.testing.io;
        const app = try zpui.App.initTest(gpa);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        const f = try fixtures_mod.load(gpa, io, dir);
        var prefs: prefs_mod.Prefs = .{ .gpa = gpa };
        fixtures_mod.applyPrefs(f, &prefs);
        try ui.theme.install(app, zt.Theme.dark());
        try prefs_mod.install(app, prefs);
        const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .wake_mode = .poll } });
        fixtures_mod.applyToState(f, io, app, state);
        const handle = try app.openWindow(.{
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1600, .height = 1000 } },
        }, shell_mod.Shell, shell_mod.Shell.init, .{ state, f, true });
        return .{ .app = app, .fixtures = f, .state = state, .handle = handle };
    }

    fn deinit(h: *Harness) void {
        h.state.release(h.app);
        h.app.deinit();
        h.fixtures.deinit();
        testing.allocator.destroy(h.fixtures);
    }

    fn window(h: *Harness) *zpui.Window {
        return h.handle.window(h.app).?;
    }
};

test "sidebar row heights follow the Rust metrics" {
    try testing.expectEqual(@as(f32, 29), sidebar_mod.rowHeight(true, true, true, true));
    try testing.expectEqual(@as(f32, 45), sidebar_mod.rowHeight(false, true, false, false));
    try testing.expectEqual(@as(f32, 61), sidebar_mod.rowHeight(false, true, true, false));
    try testing.expectEqual(@as(f32, 63), sidebar_mod.rowHeight(false, true, true, true));
    try testing.expectEqual(@as(f32, 45), sidebar_mod.rowHeight(false, false, true, false));
}

test "shell renders the reference fixture and toggles panes" {
    var h = try Harness.init("apps/zeron/fixtures/reference");
    defer h.deinit();
    const ws = h.state.read(h.app).workspace.read(h.app);
    try testing.expectEqual(@as(usize, 7), ws.chats().len);
    try testing.expect(ws.selected_chat != null);

    const w = h.window();
    try testing.expect(w.rendered_frame.scene.quads.items.len > 10);
    try testing.expect(w.rendered_frame.scene.monochrome_sprites.items.len > 50);

    // mod-b collapses the sidebar, mod-r opens the right pane.
    const tw = TestWindow.of(w.platform_window);
    const mod = if (@import("builtin").os.tag == .macos) "cmd" else "ctrl";
    tw.typeKey(mod ++ "-b");
    try testing.expect(prefs_mod.get(h.app).sidebar_collapsed);
    tw.typeKey(mod ++ "-b");
    try testing.expect(!prefs_mod.get(h.app).sidebar_collapsed);
    tw.typeKey(mod ++ "-r");
    try testing.expect(prefs_mod.get(h.app).right_pane_open);

}

test "clicking a sidebar row selects its chat" {
    var h = try Harness.init("apps/zeron/fixtures/reference");
    defer h.deinit();
    const w = h.window();
    const tw = TestWindow.of(w.platform_window);
    // Rows start at y=129 and are 31px apart (compact); row 0 is the most recent chat.
    tw.click(120, 129);
    h.app.runUntilParked();
    const ws = h.state.read(h.app).workspace.read(h.app);
    const first = ws.selectedChatRow().?;
    try testing.expectEqualStrings("Retry backoff helper", first.title.?);
}
