//! [native-popover] The shell's rich popovers in native popover containers: the
//! TestPlatform hosts popover windows (`native_popovers`) and the setting is forced on
//! (`force_for_testing`), so the macOS code path runs headless.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const native_popover = @import("../components/native_popover.zig");
const composer_mod = @import("zeron_composer");
const prefs_mod = @import("prefs.zig");
const fixtures_mod = @import("fixtures.zig");
const shell_mod = @import("shell.zig");
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
        app.test_platform.?.native_popovers = true;
        native_popover.force_for_testing = true;
        composer_mod.native_popover.force_for_testing = true;
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
        app.runUntilParked();
        return .{ .app = app, .fixtures = f, .state = state, .handle = handle };
    }

    fn deinit(h: *Harness) void {
        native_popover.force_for_testing = false;
        composer_mod.native_popover.force_for_testing = false;
        h.state.release(h.app);
        h.app.deinit();
        h.fixtures.deinit();
        testing.allocator.destroy(h.fixtures);
    }

    fn window(h: *Harness) *zpui.Window {
        return h.handle.window(h.app).?;
    }
};

fn coreOf(tw: *TestWindow) *zpui.Window {
    return @ptrCast(@alignCast(tw.callbacks.ctx.?));
}

test "native popovers: the project picker opens in a popover window and keeps keyboard navigation" {
    var h = try Harness.init("apps/zeron/fixtures/reference");
    defer h.deinit();
    const w = h.window();
    const tp = h.app.test_platform.?;
    // The shell turns native tooltips on with the setting.
    try testing.expect(w.native_tooltips);
    const tw = TestWindow.of(w.platform_window);
    const mod = if (@import("builtin").os.tag == .macos) "cmd" else "ctrl";
    tw.typeKey(mod ++ "-n");
    h.app.runUntilParked();
    const ws_e = h.state.read(h.app).workspace;
    const shell = h.handle.rootView(h.app).?.read(h.app);
    const pickers = shell.main.read(h.app).slots.pickers;
    {
        var l = pickers.lease(h.app);
        defer l.end();
        l.value.toggle(.space, w, &l.cx);
    }
    h.app.runUntilParked();
    try testing.expectEqual(@as(?pickers_mod.Kind, .space), pickers.read(h.app).open);
    const pop = tp.lastPopover() orelse return error.NoPopoverWindow;
    try testing.expect(pop.popover_visible);
    try testing.expect(pop.popover.?.key);
    const pw = coreOf(pop);
    try testing.expect(pw.isNativePopover());
    // The card (search field + project rows) is drawn in the popover window.
    try testing.expect(pw.rendered_frame.scene.monochrome_sprites.items.len > 10);
    // Sized to the card's 280px width, next to the chip (inside the 1600×1000 window).
    try testing.expectEqual(@as(f32, 280), pop.bounds.size.width);
    // The search field is focused inside the popover: keys go there.
    pop.typeKey("down");
    pop.typeKey("enter");
    h.app.runUntilParked();
    try testing.expectEqual(@as(?pickers_mod.Kind, null), pickers.read(h.app).open);
    try testing.expect(ws_e.read(h.app).selectedSpaceRow() != null);
    try testing.expect(!pop.popover_visible);
}

test "native popovers: the model picker opens above its chip; Escape closes it" {
    var h = try Harness.init("apps/zeron/fixtures/reference");
    defer h.deinit();
    const w = h.window();
    const tp = h.app.test_platform.?;
    const shell = h.handle.rootView(h.app).?.read(h.app);
    const composer = shell.main.read(h.app).slots.composer_view;
    composer.update(h.app, composer_mod.ComposerView.toggleModelPicker, .{w});
    h.app.runUntilParked();
    const picker = composer.read(h.app).picker;
    try testing.expect(picker.read(h.app).isOpen());
    const pop = tp.lastPopover() orelse return error.NoPopoverWindow;
    try testing.expect(pop.popover_visible);
    try testing.expectEqual(@as(f32, 256), pop.bounds.size.width);
    pop.typeKey("escape");
    h.app.runUntilParked();
    try testing.expect(!picker.read(h.app).isOpen());
    try testing.expect(!pop.popover_visible);
}

test "native popovers off: the pickers stay in-window" {
    var h = try Harness.init("apps/zeron/fixtures/reference");
    defer h.deinit();
    h.app.test_platform.?.native_popovers = false;
    const w = h.window();
    const shell = h.handle.rootView(h.app).?.read(h.app);
    const composer = shell.main.read(h.app).slots.composer_view;
    composer.update(h.app, composer_mod.ComposerView.toggleModelPicker, .{w});
    h.app.runUntilParked();
    try testing.expect(h.app.test_platform.?.lastPopover() == null);
    try testing.expect(composer.read(h.app).picker.read(h.app).isOpen());
}
