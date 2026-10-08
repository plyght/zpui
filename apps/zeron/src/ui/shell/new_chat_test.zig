//! ⌘N (ctrl-n off macOS) starts a new chat from every context: the shell's
//! `shell::NewSession` binding is global (no key context) and handled at the
//! shell root, and `newSession` leaves whatever mode or overlay was up
//! (Settings, the command palette, the project picker, dialogs). Headless, on
//! zpui's TestPlatform over the reference fixtures.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const composer_mod = @import("zeron_composer");
const ui = @import("../components/root.zig");
const prefs_mod = @import("prefs.zig");
const fixtures_mod = @import("fixtures.zig");
const shell_mod = @import("shell.zig");
const sidebar_mod = @import("../sidebar/sidebar.zig");
const rp_chats = @import("right_pane_chats.zig");
const terminal_panel = @import("terminal_panel.zig");
const files = @import("../files/root.zig");
const editor = @import("../editor/root.zig");
const app_menus = @import("../../lifecycle/app_menus.zig");

const testing = std.testing;
const TestWindow = zpui.core.test_platform.TestWindow;
const App = zpui.App;
const Entity = zpui.Entity;
const mod_n = if (@import("builtin").os.tag == .macos) "cmd-n" else "ctrl-n";

const Harness = struct {
    app: *App,
    fixtures: *fixtures_mod.Fixtures,
    state: Entity(model.AppState),
    handle: zpui.WindowHandle(shell_mod.Shell),
    chat: []u8,

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
        const handle = try app.openWindow(.{
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1600, .height = 1000 } },
        }, shell_mod.Shell, shell_mod.Shell.init, .{ state, f, true });
        const chat = try gpa.dupe(u8, state.read(app).workspace.read(app).selected_chat.?);
        return .{ .app = app, .fixtures = f, .state = state, .handle = handle, .chat = chat };
    }

    fn deinit(h: *Harness) void {
        testing.allocator.free(h.chat);
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

    fn selected(h: *Harness) ?[]const u8 {
        return h.state.read(h.app).workspace.read(h.app).selected_chat;
    }

    /// Back on the fixture chat (the shell root focused), settled.
    fn reselect(h: *Harness) void {
        const ws = h.state.read(h.app).workspace;
        ws.update(h.app, model.WorkspaceStore.selectChat, .{@as(?[]const u8, h.chat)});
        h.settle();
    }

    /// Press ⌘N and require the new-chat canvas on the chat route, every
    /// overlay gone.
    fn expectNewChat(h: *Harness, what: []const u8) !void {
        try testing.expect(h.selected() != null);
        h.tw().typeKey(mod_n);
        h.settle();
        try expectCanvas(h, what);
    }

    fn expectCanvas(h: *Harness, what: []const u8) !void {
        const s = h.shell();
        const ok = h.selected() == null and s.settings_view == null and s.palette == null and
            s.add_project == null and s.wiring.delete_confirm == null;
        if (!ok) {
            std.debug.print("new chat from {s}: selected={?s} settings={} palette={} add_project={} delete_confirm={}\n", .{
                what, h.selected(), s.settings_view != null, s.palette != null, s.add_project != null, s.wiring.delete_confirm != null,
            });
            return error.TestUnexpectedResult;
        }
    }

    fn focusComposer(h: *Harness) void {
        const c = h.shell().main.read(h.app).slots.composer_view;
        var l = c.lease(h.app);
        defer l.end();
        l.value.focusInput(h.window(), &l.cx);
    }
};

test "mod-n starts a new chat from the transcript, composer and shell root" {
    var h = try Harness.init();
    defer h.deinit();
    h.settle();

    // Composer (a focused text input in the "Composer" context).
    h.focusComposer();
    h.settle();
    try h.expectNewChat("composer");

    // Transcript.
    h.reselect();
    h.shell().main.read(h.app).slots.transcript_view.read(h.app).focus.focus(h.window());
    h.settle();
    try h.expectNewChat("transcript");

    // The shell root itself.
    h.reselect();
    h.window().focus(h.shell().focus);
    try h.expectNewChat("shell root");

    // A window with no focused element (the dispatch root only).
    h.reselect();
    h.window().blur();
    try testing.expect(h.window().focused_id == null);
    try h.expectNewChat("no focus");

    // A focus handle that is no longer rendered (focus left dangling).
    h.reselect();
    {
        const handle = h.app.focusHandle();
        defer handle.release(h.app);
        h.window().focus(handle);
        try h.expectNewChat("unrendered focus");
    }
}

test "mod-n starts a new chat from the Files explorer, editor and terminal" {
    var h = try Harness.init();
    defer h.deinit();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];
    h.settle();

    // Files explorer + an editor tab on the chat's (temp) workspace.
    {
        const rp = h.shell().right_pane;
        var l = rp.lease(h.app);
        defer l.end();
        const t = l.value.current(&l.cx).?;
        t.files = try l.cx.newWith(files.WorkspaceFiles, files.WorkspaceFiles.init, .{ io, files.client.Source{ .local = root } });
        rp_chats.openFileAt(l.value, "a.txt", 1, 1, &l.cx);
    }
    h.settle();
    const ed = rp_chats.activeFileEditor(h.shell().right_pane.read(h.app), h.app).?;
    {
        var l = ed.lease(h.app);
        defer l.end();
        l.value.focusEditor(h.window());
    }
    h.settle();
    try h.expectNewChat("editor");

    h.reselect();
    {
        var l = h.handle.rootView(h.app).?.lease(h.app);
        defer l.end();
        if (!l.value.filesOpen(&l.cx)) l.value.toggleFiles(h.window(), &l.cx);
        l.value.files_tween = null; // the column at full width now (no clock in tests)
    }
    h.settle();
    const explorer = h.shell().right_pane.read(h.app).peek(h.app).?.explorer.?;
    {
        var l = explorer.lease(h.app);
        defer l.end();
        l.value.focusTree(h.window());
    }
    h.settle();
    try testing.expect(h.window().rendered_frame.dispatch_tree.focusableNodeId(h.window().focused_id.?) != null);
    try h.expectNewChat("files explorer");

    // Terminal drawer (a placeholder tab: no PTY in tests).
    h.reselect();
    const panel = h.shell().main.read(h.app).terminal;
    const key = panel.update(h.app, terminal_panel.TerminalPanel.reserveTab, .{ h.chat, "Smoke" }).?;
    prefs_mod.mut(h.app).terminal_open = true;
    h.handle.rootView(h.app).?.update(h.app, struct {
        fn f(_: *shell_mod.Shell, cx: *zpui.Context(shell_mod.Shell)) void {
            cx.notify();
        }
    }.f, .{});
    h.settle();
    // The drawer at full height now (no clock in tests).
    h.shell().main.update(h.app, struct {
        fn f(m: *@import("main_panel.zig").MainPanel, cx: *zpui.Context(@import("main_panel.zig").MainPanel)) void {
            m.terminal_tween = null;
            cx.notify();
        }
    }.f, .{});
    h.settle();
    const dock = blk: {
        const tabs = panel.read(h.app).chats.getPtr(h.chat).?;
        for (tabs.tabs.items) |t| if (t.key == key) break :blk t.dock;
        return error.TestUnexpectedResult;
    };
    dock.read(h.app).focusHandle().focus(h.window());
    h.settle();
    try testing.expect(dock.read(h.app).focusHandle().isFocused(h.window()));
    try testing.expect(h.window().rendered_frame.dispatch_tree.focusableNodeId(h.window().focused_id.?) != null);
    try h.expectNewChat("terminal");
    prefs_mod.mut(h.app).terminal_open = false;

    // The browser pane is not opened here: its page helper (WebKitGTK / WKWebView)
    // keeps the executor busy. The real ⌘N through a focused WKWebView is the macOS
    // CI smoke (`ZERON_SMOKE_NEW_CHAT`, smoke_new_chat.zig).
}

test "mod-n closes Settings, the palette, the project picker and dialogs onto a new chat" {
    var h = try Harness.init();
    defer h.deinit();
    h.settle();

    // Settings (its page holds the focus).
    {
        var l = h.handle.rootView(h.app).?.lease(h.app);
        defer l.end();
        l.value.openSettings(h.window(), &l.cx);
    }
    h.settle();
    try testing.expect(h.shell().settings_view != null);
    try h.expectNewChat("settings");

    // The command palette (its search input focused).
    h.reselect();
    h.tw().typeKey(if (@import("builtin").os.tag == .macos) "cmd-k" else "ctrl-k");
    h.settle();
    try testing.expect(h.shell().palette != null);
    try h.expectNewChat("command palette");

    // The New project picker.
    h.reselect();
    {
        var l = h.handle.rootView(h.app).?.lease(h.app);
        defer l.end();
        l.value.openAddProject(h.window(), &l.cx);
    }
    h.settle();
    try testing.expect(h.shell().add_project != null);
    try h.expectNewChat("project picker");

    // The delete-chat confirmation dialog.
    h.reselect();
    h.shell().sidebar.update(h.app, struct {
        fn f(_: *sidebar_mod.Sidebar, chat: []const u8, cx: *zpui.Context(sidebar_mod.Sidebar)) void {
            cx.emit(sidebar_mod.DeleteChat{ .chat_id = chat });
        }
    }.f, .{h.chat});
    h.settle();
    try testing.expect(h.shell().wiring.delete_confirm != null);
    try h.expectNewChat("delete dialog");

    // A composer popover (the model menu, mod-/).
    h.reselect();
    h.window().focus(h.shell().focus);
    h.tw().typeKey(if (@import("builtin").os.tag == .macos) "cmd-/" else "ctrl-/");
    h.settle();
    const composer = h.shell().main.read(h.app).slots.composer_view;
    try testing.expect(composer.read(h.app).picker.read(h.app).isOpen());
    try h.expectNewChat("model picker");
    try testing.expect(!composer.read(h.app).picker.read(h.app).isOpen());
}

test "File > New Chat carries the mod-n key equivalent and starts a new chat from the menu" {
    var h = try Harness.init();
    defer h.deinit();
    app_menus.refresh(h.app);
    h.settle();
    const tp = h.app.test_platform.?;
    const item = blk: {
        for (tp.menus) |m| for (m.items) |it| if (it == .action and std.mem.eql(u8, it.action.name, "New Chat")) break :blk it.action;
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings("n", item.key_equivalent.?.key);
    const mac = @import("builtin").os.tag == .macos;
    try testing.expectEqual(mac, item.key_equivalent.?.modifiers.platform);
    try testing.expectEqual(!mac, item.key_equivalent.?.modifiers.control);
    // The menu pick reaches the shell even with Settings up and nothing focused.
    {
        var l = h.handle.rootView(h.app).?.lease(h.app);
        defer l.end();
        l.value.openSettings(h.window(), &l.cx);
    }
    h.settle();
    h.window().blur();
    tp.simulateMenuAction(item.tag);
    h.settle();
    try h.expectCanvas("File > New Chat");
}
