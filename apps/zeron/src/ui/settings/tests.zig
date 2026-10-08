//! Headless settings tests: the real Shell opens `SettingsView` on the
//! TestPlatform from the reference fixtures (in-memory SettingsStore).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const prefs_mod = @import("../shell/prefs.zig");
const fixtures_mod = @import("../shell/fixtures.zig");
const shell_mod = @import("../shell/shell.zig");
const store = @import("store.zig");
const select = @import("select.zig");
const view_mod = @import("view.zig");
const shortcuts = @import("shortcuts.zig");

const testing = std.testing;
const TestWindow = zpui.core.test_platform.TestWindow;
const SettingsView = view_mod.SettingsView;
const mod = if (builtin.os.tag == .macos) "cmd" else "ctrl";

const Harness = struct {
    app: *zpui.App,
    fixtures: *fixtures_mod.Fixtures,
    state: zpui.Entity(model.AppState),
    handle: zpui.WindowHandle(shell_mod.Shell),

    fn init() !Harness {
        const gpa = testing.allocator;
        const io = std.testing.io;
        const app = try zpui.App.initTest(gpa);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        const f = try fixtures_mod.load(gpa, io, "apps/zeron/fixtures/reference");
        var prefs: prefs_mod.Prefs = .{ .gpa = gpa };
        fixtures_mod.applyPrefs(f, &prefs);
        try ui.theme.install(app, zt.Theme.dark());
        try prefs_mod.install(app, prefs);
        store.boot(app, io, .dark);
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

    fn tw(h: *Harness) *TestWindow {
        return TestWindow.of(h.handle.window(h.app).?.platform_window);
    }

    fn view(h: *Harness) ?zpui.Entity(SettingsView) {
        const root = h.handle.rootView(h.app) orelse return null;
        return root.read(h.app).settings_view;
    }

    fn settings(h: *Harness) *const model.UiSettings {
        return store.current(h.app);
    }
};

fn openSection(v: *SettingsView, section: view_mod.Section, cx: *zpui.Context(SettingsView)) void {
    v.openSection(section, cx);
}

fn commitSelect(v: *SettingsView, id: select.SelectId, ix: usize, cx: *zpui.Context(SettingsView)) void {
    select.commit(v, id, ix, cx);
}

fn flipToggle(v: *SettingsView, which: select.Toggle, cx: *zpui.Context(SettingsView)) void {
    select.flip(v, which, cx);
}

fn startRecording(v: *SettingsView, id: model.ShortcutId, window: *zpui.Window, cx: *zpui.Context(SettingsView)) void {
    v.startRecording(id, window, cx);
}

test "mod-, opens settings over the shell and Escape closes it" {
    var h = try Harness.init();
    defer h.deinit();
    try testing.expect(h.view() == null);
    h.tw().typeKey(mod ++ "-,");
    h.app.runUntilParked();
    try testing.expect(h.view() != null);
    // Every page renders.
    const v = h.view().?;
    for (model.settings.SettingsSection.all) |s| {
        v.update(h.app, openSection, .{s});
        h.app.runUntilParked();
        try testing.expectEqual(s, v.read(h.app).section);
    }
    try testing.expectEqual(model.settings.SettingsSection.archived, h.settings().settingsSection);
    h.tw().typeKey("escape");
    h.app.runUntilParked();
    try testing.expect(h.view() == null);
}

test "appearance changes re-theme the app live" {
    var h = try Harness.init();
    defer h.deinit();
    h.tw().typeKey(mod ++ "-,");
    h.app.runUntilParked();
    const v = h.view().?;
    try testing.expect(ui.theme.get(h.app).appearance == .dark);

    // Dark theme → Dracula.
    var it = zt.registry.builtin.variantsFor(.dark);
    var ix: usize = 0;
    while (it.next()) |variant| : (ix += 1) if (std.mem.eql(u8, variant.id, "dracula")) break;
    v.update(h.app, commitSelect, .{ select.SelectId.dark_theme, ix });
    try testing.expectEqualStrings("dracula", ui.theme.get(h.app).variant_id);
    try testing.expectEqualStrings("dracula", h.settings().theme.theme_selection.dark);

    // Glass → Opaque; accent / wallpaper colors.
    v.update(h.app, commitSelect, .{ select.SelectId.surface, 2 });
    try testing.expect(ui.theme.get(h.app).surface_treatment == .opaque_);
    v.update(h.app, flipToggle, .{select.Toggle.match_wallpaper});
    try testing.expect(h.settings().theme.wallpaper_theme_colors);

    // Interface font size follows the rem size.
    v.update(h.app, commitSelect, .{ select.SelectId.ui_size, 2 });
    try testing.expectEqual(@as(u8, 14), h.settings().theme.ui_font_size.px);
}

test "the system font starts at 14 px until a size is chosen; Geist returns to 16" {
    var h = try Harness.init();
    defer h.deinit();
    h.tw().typeKey(mod ++ "-,");
    h.app.runUntilParked();
    const v = h.view().?;
    const win = h.handle.window(h.app).?;
    try testing.expect(!model.ui_font_size_choice.current(h.app));
    try testing.expectEqual(@as(u8, 16), h.settings().theme.ui_font_size.px);
    try testing.expectEqual(@as(f32, 16), win.remSize());

    // Interface font → SF Pro (System): an untouched 16 renders at 14 (the stored 16 stays).
    v.update(h.app, commitSelect, .{ select.SelectId.ui_font, 2 });
    try testing.expect(h.settings().theme.ui_font_family == .system);
    try testing.expectEqual(@as(f32, 14), win.remSize());
    try testing.expectEqual(@as(u8, 16), h.settings().theme.ui_font_size.px);
    try testing.expectEqual(@as(u8, 14), store.effectiveUiFontSize(h.app, h.settings()).px);

    // Back to Geist: 16 again.
    v.update(h.app, commitSelect, .{ select.SelectId.ui_font, 0 });
    try testing.expectEqual(@as(f32, 16), win.remSize());

    // An explicit 16 is never overridden, with the system font either.
    v.update(h.app, commitSelect, .{ select.SelectId.ui_size, 4 });
    try testing.expect(model.ui_font_size_choice.current(h.app));
    v.update(h.app, commitSelect, .{ select.SelectId.ui_font, 2 });
    try testing.expectEqual(@as(f32, 16), win.remSize());
}

test "switches write through the settings store" {
    var h = try Harness.init();
    defer h.deinit();
    h.tw().typeKey(mod ++ "-,");
    h.app.runUntilParked();
    const v = h.view().?;
    try testing.expect(!h.settings().transcriptCompactMode);
    v.update(h.app, flipToggle, .{select.Toggle.compact_mode});
    try testing.expect(h.settings().transcriptCompactMode);
    v.update(h.app, flipToggle, .{select.Toggle.sound});
    try testing.expect(!h.settings().soundEnabled);
    v.update(h.app, commitSelect, .{ select.SelectId.send_behavior, 1 });
    try testing.expect(h.settings().composerSendBehavior == .@"mod-enter");
}

test "recording a shortcut rebinds it; conflicts are refused" {
    var h = try Harness.init();
    defer h.deinit();
    h.tw().typeKey(mod ++ "-,");
    h.app.runUntilParked();
    const v = h.view().?;
    const window = h.handle.window(h.app).?;

    // Record mod-shift-b for "Toggle left sidebar".
    v.update(h.app, startRecording, .{ model.ShortcutId.toggle_sidebar, window });
    h.app.runUntilParked();
    h.tw().typeKey(mod ++ "-shift-b");
    h.app.runUntilParked();
    try testing.expect(v.read(h.app).recording == null);
    try testing.expectEqualStrings("mod-shift-b", h.settings().keymap.toggleSidebar);

    // A combo another shortcut owns is refused with a notice.
    v.update(h.app, startRecording, .{ model.ShortcutId.toggle_changes, window });
    h.app.runUntilParked();
    h.tw().typeKey(mod ++ "-e");
    h.app.runUntilParked();
    try testing.expectEqualStrings("mod-r", h.settings().keymap.toggleChanges);
    try testing.expect(std.mem.indexOf(u8, v.read(h.app).notice.items, "Toggle files panel") != null);

    // Escape cancels a recording without changing anything.
    v.update(h.app, startRecording, .{ model.ShortcutId.toggle_terminal, window });
    h.app.runUntilParked();
    h.tw().typeKey("escape");
    h.app.runUntilParked();
    try testing.expect(v.read(h.app).recording == null);
    try testing.expectEqualStrings("mod-j", h.settings().keymap.toggleTerminal);
    try testing.expect(h.view() != null);

    // The new binding drives the shell once settings is closed.
    h.tw().typeKey("escape");
    h.app.runUntilParked();
    try testing.expect(h.view() == null);
    const collapsed = prefs_mod.get(h.app).sidebar_collapsed;
    h.tw().typeKey(mod ++ "-shift-b");
    try testing.expect(prefs_mod.get(h.app).sidebar_collapsed != collapsed);
}

test "conflict owner and group lookup" {
    const km: model.KeymapConfig = .{};
    try testing.expect(shortcuts.conflictOwner(&km, .toggle_sidebar, "mod-e").? == .toggle_files);
    try testing.expect(shortcuts.conflictOwner(&km, .toggle_sidebar, "mod-shift-q") == null);
    try testing.expectEqualStrings("Voice", shortcuts.group(.toggle_dictation));
    try testing.expectEqualStrings("Jump to session", shortcuts.group(.{ .jump_session = 3 }));
}
