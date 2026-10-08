//! The shortcut matrix: every app shortcut (keymap.zig) typed as a real keystroke into
//! the shell window with focus in each context it must work from (shell root, message
//! composer, file editor, Settings), and every menu-bar item (app_menus.zig) picked
//! and validated, on zpui's TestPlatform over the reference fixtures. An action counts
//! as fired when `dispatch.action_trace` reports it handled. The macOS CI smoke
//! (`ZERON_SMOKE_SHORTCUTS`, smoke.zig) runs the same table through real NSEvents.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const prefs_mod = @import("prefs.zig");
const fixtures_mod = @import("fixtures.zig");
const shell_mod = @import("shell.zig");
const settings_ui = @import("../settings/root.zig");
const app_menus = @import("../../lifecycle/app_menus.zig");
const files = @import("../files/root.zig");
const editor = @import("../editor/root.zig");
const rp_chats = @import("right_pane_chats.zig");
const shortcut_table = @import("../../shortcut_table.zig");

const testing = std.testing;
const TestWindow = zpui.core.test_platform.TestWindow;
const App = zpui.App;
const Entity = zpui.Entity;
const dispatch = zpui.window.dispatch_mod;
const is_mac = builtin.os.tag == .macos;

// ---- action trace ------------------------------------------------------------------------

var fired: std.ArrayList(struct { name: []const u8, handled: bool }) = .empty;

fn trace(a: *const zpui.AnyAction, handled: bool) void {
    fired.append(testing.allocator, .{ .name = a.name, .handled = handled }) catch {};
}

fn firedHandled(name: []const u8) bool {
    for (fired.items) |f| if (f.handled and std.mem.eql(u8, f.name, name)) return true;
    return false;
}

fn dumpFired() void {
    for (fired.items) |f| std.debug.print("  fired {s} handled={}\n", .{ f.name, f.handled });
}

const Harness = struct {
    app: *App,
    fixtures: *fixtures_mod.Fixtures,
    state: Entity(model.AppState),
    handle: zpui.WindowHandle(shell_mod.Shell),

    fn init() !Harness {
        const gpa = testing.allocator;
        const io = testing.io;
        const app = try App.initTest(gpa);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        const f = try fixtures_mod.load(gpa, io, "apps/zeron/fixtures/reference");
        var prefs: prefs_mod.Prefs = .{ .gpa = gpa };
        fixtures_mod.applyPrefs(f, &prefs);
        try ui.theme.install(app, zt.Theme.dark());
        try prefs_mod.install(app, prefs);
        const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false, .wake_mode = .poll } });
        fixtures_mod.applyToState(f, io, app, state);
        try app_menus.install(app);
        app_menus.refresh(app);
        const handle = try app.openWindow(.{
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1600, .height = 1000 } },
        }, shell_mod.Shell, shell_mod.Shell.init, .{ state, f, true });
        TestWindow.of(handle.window(app).?.platform_window).simulateActive(true);
        dispatch.action_trace = trace;
        var h: Harness = .{ .app = app, .fixtures = f, .state = state, .handle = handle };
        h.settle();
        return h;
    }

    fn deinit(h: *Harness) void {
        dispatch.action_trace = null;
        fired.deinit(testing.allocator);
        fired = .empty;
        h.state.release(h.app);
        h.app.deinit();
        h.fixtures.deinit();
        testing.allocator.destroy(h.fixtures);
    }

    fn window(h: *Harness) *zpui.Window {
        return h.handle.window(h.app).?;
    }

    fn tw(h: *Harness) *TestWindow {
        return TestWindow.of(h.window().platform_window);
    }

    fn shell(h: *Harness) *const shell_mod.Shell {
        return h.handle.rootView(h.app).?.read(h.app);
    }

    fn settle(h: *Harness) void {
        for (0..4) |_| {
            h.app.runUntilParked();
            h.tw().frame(true);
        }
    }

    /// Type `keys` and require `action` to be handled.
    fn expectShortcut(h: *Harness, where: []const u8, keys: []const u8, action: []const u8) !void {
        fired.clearRetainingCapacity();
        h.tw().typeKey(keys);
        h.settle();
        if (!firedHandled(action)) {
            std.debug.print("[{s}] {s} did not fire {s}\n", .{ where, keys, action });
            dumpFired();
            return error.TestUnexpectedResult;
        }
    }
};

fn focusComposer(h: *Harness) void {
    const c = h.shell().main.read(h.app).slots.composer_view;
    var l = c.lease(h.app);
    defer l.end();
    l.value.focusInput(h.window(), &l.cx);
}

/// Toggles fire twice (so the shell ends where it started).
fn runGlobalTable(h: *Harness, where: []const u8, refocus: *const fn (*Harness) void) !void {
    inline for (shortcut_table.global) |case| {
        if (!case.headless) continue;
        refocus(h);
        h.settle();
        const keys = comptime shortcut_table.keysFor(case, is_mac);
        try h.expectShortcut(where, keys, case.action);
        if (case.toggle) {
            refocus(h);
            h.settle();
            try h.expectShortcut(where, keys, case.action);
        }
        if (case.escape_after) {
            h.tw().typeKey("escape");
            h.settle();
        }
    }
}

fn focusShellRoot(h: *Harness) void {
    h.window().focus(h.shell().focus);
}

test "every global shortcut fires from the shell root" {
    var h = try Harness.init();
    defer h.deinit();
    try runGlobalTable(&h, "shell", focusShellRoot);
}

test "every global shortcut fires from the message composer" {
    var h = try Harness.init();
    defer h.deinit();
    try runGlobalTable(&h, "composer", focusComposer);
}

test "composer editing shortcuts and Edit menu items reach the focused input" {
    var h = try Harness.init();
    defer h.deinit();
    focusComposer(&h);
    h.settle();
    const p = if (is_mac) "cmd" else "ctrl";
    try h.expectShortcut("composer", p ++ "-a", "composer::SelectAll");
    try h.expectShortcut("composer", p ++ "-c", "composer::Copy");
    try h.expectShortcut("composer", p ++ "-z", "composer::Undo");
    // The Edit menu: every item enabled and dispatched to the composer input.
    const tp = h.app.test_platform.?;
    for (tp.menus) |m| {
        if (!std.mem.eql(u8, m.name, "Edit")) continue;
        for (m.items) |it| if (it == .action) {
            try testing.expect(tp.simulateValidateMenu(it.action.tag));
            fired.clearRetainingCapacity();
            tp.simulateMenuAction(it.action.tag);
            h.settle();
            const a = zpui.core.lifecycle.menuAction(h.app, it.action.tag).?;
            if (!firedHandled(a.name)) {
                std.debug.print("Edit > {s} not handled\n", .{it.action.name});
                dumpFired();
                return error.TestUnexpectedResult;
            }
        };
    }
}

var editor_entity: ?Entity(editor.view.FileEditor) = null;

fn focusEditor(h: *Harness) void {
    var l = editor_entity.?.lease(h.app);
    defer l.end();
    l.value.focusEditor(h.window());
}

/// Edit menu items: enabled and handled (`expect` names the action that must run).
fn expectEditMenu(h: *Harness, comptime expect: []const []const u8) !void {
    const tp = h.app.test_platform.?;
    var n: usize = 0;
    for (tp.menus) |m| {
        if (!std.mem.eql(u8, m.name, "Edit")) continue;
        for (m.items) |it| if (it == .action) {
            if (!tp.simulateValidateMenu(it.action.tag)) {
                std.debug.print("Edit > {s} disabled\n", .{it.action.name});
                return error.TestUnexpectedResult;
            }
            fired.clearRetainingCapacity();
            tp.simulateMenuAction(it.action.tag);
            h.settle();
            if (!firedHandled(expect[n])) {
                std.debug.print("Edit > {s} did not run {s}\n", .{ it.action.name, expect[n] });
                dumpFired();
                return error.TestUnexpectedResult;
            }
            n += 1;
        };
    }
    try testing.expectEqual(expect.len, n);
}

test "the file editor: global shortcuts and the Edit menu" {
    var h = try Harness.init();
    defer h.deinit();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    {
        const rp = h.shell().right_pane;
        var l = rp.lease(h.app);
        defer l.end();
        const t = l.value.current(&l.cx).?;
        t.files = try l.cx.newWith(files.WorkspaceFiles, files.WorkspaceFiles.init, .{ io, files.client.Source{ .local = buf[0..n] } });
        rp_chats.openFileAt(l.value, "a.txt", 1, 1, &l.cx);
    }
    h.settle();
    editor_entity = rp_chats.activeFileEditor(h.shell().right_pane.read(h.app), h.app).?;
    defer editor_entity = null;
    focusEditor(&h);
    h.settle();
    try expectEditMenu(&h, &.{ "composer::Undo", "composer::Redo", "composer::Cut", "composer::Copy", "composer::Paste", "composer::SelectAll" });
    try runGlobalTable(&h, "editor", focusEditor);
}

test "menu bar: items validate and dispatch; key equivalents follow custom bindings" {
    var h = try Harness.init();
    defer h.deinit();
    focusShellRoot(&h);
    h.settle();
    const tp = h.app.test_platform.?;
    // Global verbs are always enabled (the app menu works with any focus).
    for (tp.menus) |m| for (m.items) |it| if (it == .action) {
        const a = zpui.core.lifecycle.menuAction(h.app, it.action.tag).?;
        const global = std.mem.startsWith(u8, a.name, "zeron::") or std.mem.eql(u8, a.name, "shell::OpenSettings");
        if (global) try testing.expect(tp.simulateValidateMenu(it.action.tag));
    };
    // Settings from the menu opens Settings.
    for (tp.menus[0].items) |it| if (it == .action and std.mem.eql(u8, it.action.name, "Settings")) {
        tp.simulateMenuAction(it.action.tag);
    };
    h.settle();
    try testing.expect(h.shell().settings_view != null);
    // A custom binding moves the menu key equivalent (and the keymap) live.
    {
        const v = h.shell().settings_view.?;
        var l = v.lease(h.app);
        defer l.end();
        settings_ui.view.setShortcut(&l.cx, .toggle_sidebar, "mod-shift-y");
    }
    h.settle();
    const p = if (is_mac) "cmd" else "ctrl";
    try h.expectShortcut("settings", p ++ "-shift-y", "shell::ToggleSidebar");
}

test "shortcuts survive a blur and a focused element unmounting (Rust restore_mounted_focus)" {
    var h = try Harness.init();
    defer h.deinit();
    const p = if (is_mac) "cmd" else "ctrl";
    // A click outside the composer blurs it (TextInput.onMouseDownOut → window.blur()).
    focusComposer(&h);
    h.settle();
    h.window().blur();
    h.settle();
    try testing.expect(h.window().focusedId() != null);
    try h.expectShortcut("after blur", p ++ "-b", "shell::ToggleSidebar");
    try h.expectShortcut("after blur", p ++ "-b", "shell::ToggleSidebar");
    // The menu's Settings item stays enabled.
    const tp = h.app.test_platform.?;
    for (tp.menus[0].items) |it| if (it == .action and std.mem.eql(u8, it.action.name, "Settings")) {
        try testing.expect(tp.simulateValidateMenu(it.action.tag));
    };
    // A focused handle that is no longer drawn (a closed popup) falls back to the composer.
    const stale = h.app.focusHandle();
    defer stale.release(h.app);
    h.window().focus(stale);
    h.settle();
    try h.expectShortcut("after unmount", p ++ "-k", "shell::ToggleCommandPalette");
    try h.expectShortcut("palette", p ++ "-k", "shell::ToggleCommandPalette");
}

test "Settings: global shortcuts still fire with Settings open" {
    var h = try Harness.init();
    defer h.deinit();
    focusShellRoot(&h);
    const p = if (is_mac) "cmd" else "ctrl";
    try h.expectShortcut("shell", p ++ "-,", "shell::OpenSettings");
    try testing.expect(h.shell().settings_view != null);
    try h.expectShortcut("settings", p ++ "-k", "shell::ToggleCommandPalette");
    h.tw().typeKey("escape");
    h.settle();
    try h.expectShortcut("settings", p ++ "-,", "shell::OpenSettings");
    try testing.expect(h.shell().settings_view == null);
}

test {
    _ = shortcut_table;
}
