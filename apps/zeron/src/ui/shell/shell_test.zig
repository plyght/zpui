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
const right_pane_mod = @import("right_pane.zig");
const pickers_mod = @import("../pickers/root.zig");

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
        const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false, .wake_mode = .poll } });
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
    try testing.expect(rightOpen(&h));
    tw.typeKey(mod ++ "-r");
    try testing.expect(!rightOpen(&h));
}

fn rightOpen(h: *Harness) bool {
    var l = h.handle.rootView(h.app).?.lease(h.app);
    defer l.end();
    return l.value.rightOpen(h.app);
}

fn rightTabs(h: *Harness) ?*const right_pane_mod.ChatTabs {
    const shell = h.handle.rootView(h.app).?.read(h.app);
    return shell.right_pane.read(h.app).peek(h.app);
}

test "right pane hosts surfaces per chat: launcher, tabs, + menu, close" {
    var h = try Harness.init("apps/zeron/fixtures/reference");
    defer h.deinit();
    const w = h.window();
    const tw = TestWindow.of(w.platform_window);
    const mod = if (@import("builtin").os.tag == .macos) "cmd" else "ctrl";
    tw.typeKey(mod ++ "-r");
    h.app.advanceClock(400 * std.time.ns_per_ms);
    h.app.runUntilParked();
    try testing.expect(rightOpen(&h));
    // The launcher's "Diffs" card (pane spans x 1080..1600, cards are 44px
    // rows centered vertically: Browser, Terminal, Diffs, History).
    tw.click(1340, 544);
    h.app.runUntilParked();
    const tabs = rightTabs(&h).?;
    try testing.expectEqual(@as(usize, 1), tabs.tabs.items.len);
    try testing.expect(tabs.tabs.items[0].surface == .changes);
    // `+` → History.
    tw.click(1215, 20);
    h.app.runUntilParked();
    try testing.expect(h.handle.rootView(h.app).?.read(h.app).right_pane.read(h.app).plus_open);
    tw.click(1260, 204);
    h.app.runUntilParked();
    try testing.expectEqual(@as(usize, 2), rightTabs(&h).?.tabs.items.len);
    try testing.expect(rightTabs(&h).?.tabs.items[1].surface == .history);
    try testing.expectEqual(rightTabs(&h).?.tabs.items[1].id, rightTabs(&h).?.resolvedActive().?);
    // The other chat has its own (empty, closed) host.
    tw.click(120, 129);
    h.app.runUntilParked();
    try testing.expect(!rightOpen(&h));
    tw.click(120, 160);
    h.app.runUntilParked();
    try testing.expect(rightOpen(&h));
    try testing.expectEqual(@as(usize, 2), rightTabs(&h).?.tabs.items.len);
}

test "new-session pickers open from the canvas chips and pick" {
    var h = try Harness.init("apps/zeron/fixtures/reference");
    defer h.deinit();
    const w = h.window();
    const tw = TestWindow.of(w.platform_window);
    const mod = if (@import("builtin").os.tag == .macos) "cmd" else "ctrl";
    tw.typeKey(mod ++ "-n");
    h.app.runUntilParked();
    const ws_e = h.state.read(h.app).workspace;
    try testing.expect(ws_e.read(h.app).selected_chat == null);
    const shell = h.handle.rootView(h.app).?.read(h.app);
    const pickers = shell.main.read(h.app).slots.pickers;
    // Open the project picker programmatically, navigate with the keyboard.
    {
        var l = pickers.lease(h.app);
        defer l.end();
        l.value.toggle(.space, w, &l.cx);
    }
    h.app.runUntilParked();
    try testing.expectEqual(@as(?pickers_mod.Kind, .space), pickers.read(h.app).open);
    tw.typeKey("down");
    tw.typeKey("enter");
    h.app.runUntilParked();
    try testing.expectEqual(@as(?pickers_mod.Kind, null), pickers.read(h.app).open);
    try testing.expect(ws_e.read(h.app).selectedSpaceRow() != null);
    // The opt-out row is last: up from the top wraps to it.
    {
        var l = pickers.lease(h.app);
        defer l.end();
        l.value.toggle(.space, w, &l.cx);
        l.value.active = null;
    }
    h.app.runUntilParked();
    tw.typeKey("up");
    tw.typeKey("enter");
    h.app.runUntilParked();
    try testing.expect(ws_e.read(h.app).no_project);
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

const FadeProbe = struct {
    width: f32,
    fn init(width: f32, _: *zpui.Window, _: *zpui.Context(FadeProbe)) FadeProbe {
        return .{ .width = width };
    }
    pub fn render(self: *FadeProbe, _: *zpui.Window, _: *zpui.Context(FadeProbe)) zpui.Div {
        // The fake text system lays every character out 10px wide: "abcdefghij" is 100px.
        return zpui.div().flex().w(zpui.px(self.width)).child(ui.effects.fadedText("abcdefghij", .{}));
    }
};

fn fadeOf(width: f32) !zpui.scene.EdgeFadeParams {
    const app = try zpui.App.initTest(testing.allocator);
    defer app.deinit();
    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 400, .height = 100 } } }, FadeProbe, FadeProbe.init, .{width});
    const w = handle.window(app).?;
    const sprites = w.rendered_frame.scene.monochrome_sprites.items;
    try testing.expect(sprites.len > 0);
    var f = sprites[sprites.len - 1].fade;
    const s = w.scaleFactor();
    f.right_x /= s;
    f.band_right /= s;
    return f;
}

test "faded label eases its right-edge fade in with the overflow (zeron label_fade_outset)" {
    // Fits: no fade at all.
    try testing.expect((try fadeOf(120)).isNone());
    // Barely clipped (2px over a 20px band): the ramp ends almost a band past the clip,
    // so the last glyphs stay nearly opaque (Rust `fade_label_overflow`).
    const barely = try fadeOf(98);
    try testing.expectApproxEqAbs(@as(f32, 20), barely.band_right, 0.01);
    try testing.expectApproxEqAbs(98 + zpui.effects.labelFadeOutset(2, 20), barely.right_x, 0.01);
    try testing.expect(barely.right_x > 98 + 19);
    // Clipped by more than a band: the ramp reaches zero exactly at the clip edge.
    const deep = try fadeOf(60);
    try testing.expectApproxEqAbs(@as(f32, 60), deep.right_x, 0.01);
}
