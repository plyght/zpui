//! [wiring] Headless tests for the shell's event routing (ui/shell/wiring.zig)
//! on zpui's TestPlatform over the reference fixtures. Engine calls are
//! captured through `EngineState.test_sink` (no connection in tests).

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const actions = @import("zeron_actions");
const tr = @import("zeron_ui_transcript");
const md = @import("zeron_ui_markdown");
const composer_mod = @import("zeron_composer");
const ui = @import("../components/root.zig");
const prefs_mod = @import("prefs.zig");
const fixtures_mod = @import("fixtures.zig");
const shell_mod = @import("shell.zig");
const wiring = @import("wiring.zig");
const sidebar_mod = @import("../sidebar/sidebar.zig");
const right_pane_mod = @import("right_pane.zig");
const rp_chats = @import("right_pane_chats.zig");
const files = @import("../files/root.zig");
const editor = @import("../editor/root.zig");
const settings_ui = @import("../settings/root.zig");

const testing = std.testing;
const TestWindow = zpui.core.test_platform.TestWindow;
const App = zpui.App;
const Entity = zpui.Entity;
const mod = if (@import("builtin").os.tag == .macos) "cmd" else "ctrl";

// ---- captured engine calls ---------------------------------------------------------------

const Call = struct { method: engine.Method, json: []u8 };
var calls: std.ArrayList(Call) = .empty;

fn sink(method: engine.Method, params: []const u8) void {
    calls.append(testing.allocator, .{ .method = method, .json = testing.allocator.dupe(u8, params) catch return }) catch {};
}

fn clearCalls() void {
    for (calls.items) |c| testing.allocator.free(c.json);
    calls.clearRetainingCapacity();
}

fn lastCall(method: engine.Method) ?[]const u8 {
    var i = calls.items.len;
    while (i > 0) {
        i -= 1;
        if (calls.items[i].method == method) return calls.items[i].json;
    }
    return null;
}

fn expectCall(method: engine.Method, needles: []const []const u8) !void {
    const json = lastCall(method) orelse {
        std.debug.print("no {t} call captured\n", .{method});
        return error.TestUnexpectedResult;
    };
    for (needles) |n| if (std.mem.indexOf(u8, json, n) == null) {
        std.debug.print("{t} params {s} lack {s}\n", .{ method, json, n });
        return error.TestUnexpectedResult;
    };
}

const Harness = struct {
    app: *App,
    fixtures: *fixtures_mod.Fixtures,
    state: Entity(model.AppState),
    handle: zpui.WindowHandle(shell_mod.Shell),

    fn init() !Harness {
        const gpa = testing.allocator;
        const io = testing.io;
        model.engine_state.test_sink = sink;
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
        clearCalls();
        return .{ .app = app, .fixtures = f, .state = state, .handle = handle };
    }

    fn deinit(h: *Harness) void {
        h.state.release(h.app);
        h.app.deinit();
        h.fixtures.deinit();
        testing.allocator.destroy(h.fixtures);
        clearCalls();
        calls.deinit(testing.allocator);
        calls = .empty;
        model.engine_state.test_sink = null;
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

    fn tabs(h: *Harness) ?*const right_pane_mod.ChatTabs {
        return h.shell().right_pane.read(h.app).peek(h.app);
    }

    fn composer(h: *Harness) Entity(composer_mod.ComposerView) {
        return h.shell().main.read(h.app).slots.composer_view;
    }
};

fn hasEditorBinding(app: *App) !bool {
    const any = try zpui.AnyAction.init(testing.allocator, editor.actions.Backspace{});
    var a = any;
    defer a.deinit(testing.allocator);
    var list = try app.keymap.bindingsForAction(testing.allocator, a);
    defer list.deinit(testing.allocator);
    return list.items.len > 0;
}

test "editor keymap is installed with the app keymap and survives rebuilds" {
    var h = try Harness.init();
    defer h.deinit();
    try testing.expect(try hasEditorBinding(h.app));
    // A settings-driven rebuild (shortcut edit / send key) keeps it.
    settings_ui.store.applyKeymap(h.app);
    try testing.expect(try hasEditorBinding(h.app));
}

test "shell::SaveFile saves the active file tab; arrows move the editor caret" {
    var h = try Harness.init();
    defer h.deinit();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(io, &buf);
    const root = buf[0..n];
    // Point the chat's files service at the temp folder, then open a tab.
    {
        const rp = h.shell().right_pane;
        var l = rp.lease(h.app);
        defer l.end();
        const t = l.value.current(&l.cx).?;
        t.files = try l.cx.newWith(files.WorkspaceFiles, files.WorkspaceFiles.init, .{ io, files.client.Source{ .local = root } });
        rp_chats.openFileAt(l.value, "a.txt", 1, 3, &l.cx);
    }
    h.settle();
    const ed = rp_chats.activeFileEditor(h.shell().right_pane.read(h.app), h.app).?;
    try testing.expectEqual(editor.view.Phase.ready, ed.read(h.app).phase);
    // `:1:3` landed after the file loaded.
    try testing.expectEqual(@as(usize, 2), ed.read(h.app).core.cursor());
    // Editor keys work in the app keymap: focus the editor, press right.
    {
        var l = ed.lease(h.app);
        defer l.end();
        l.value.focusEditor(h.window());
    }
    h.settle();
    h.tw().typeKey("right");
    try testing.expectEqual(@as(usize, 3), ed.read(h.app).core.cursor());
    _ = h.tw().simulateInput(.{ .key_down = .{ .keystroke = .{ .key = "x", .key_char = "x" } } });
    try testing.expect(ed.read(h.app).hasUnsavedChanges());
    // SaveFile from the shell root (focus outside the editor).
    h.window().focus(h.shell().focus);
    h.tw().typeKey(mod ++ "-s");
    h.settle();
    const saved = try tmp.dir.readFileAlloc(io, "a.txt", testing.allocator, .limited(1024));
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("helxlo\n", saved);
    try testing.expect(!ed.read(h.app).hasUnsavedChanges());
}

test "ArchiveSession and OpenModelPicker shortcuts" {
    var h = try Harness.init();
    defer h.deinit();
    const id = try testing.allocator.dupe(u8, h.selected().?);
    defer testing.allocator.free(id);
    h.window().focus(h.shell().focus);
    h.tw().typeKey(mod ++ "-shift-a");
    try expectCall(.Mutate, &.{ "\"setChatArchived\"", id, "\"archived\":true" });
    try testing.expect(h.state.read(h.app).workspace.read(h.app).chat(id).?.archived);
    // mod-/ opens the composer's model menu.
    h.tw().typeKey(mod ++ "-/");
    h.settle();
    try testing.expect(h.composer().read(h.app).picker.read(h.app).isOpen());
}

test "sidebar Rename edits the title inline and commits renameChat" {
    var h = try Harness.init();
    defer h.deinit();
    const id = try testing.allocator.dupe(u8, h.selected().?);
    defer testing.allocator.free(id);
    const sb = h.shell().sidebar;
    sb.update(h.app, sidebar_mod.Sidebar.beginRename, .{ id, h.window() });
    h.settle();
    const rn = sb.read(h.app).rename.?;
    try testing.expectEqualStrings("Add backpressure to stream pipeline", rn.input.read(h.app).text());
    // The whole title is selected: typing replaces it.
    for ("Renamed") |c| _ = h.tw().simulateInput(.{ .key_down = .{ .keystroke = .{ .key = &.{c}, .key_char = &.{c} } } });
    h.tw().typeKey("enter");
    try testing.expect(sb.read(h.app).rename == null);
    try expectCall(.Mutate, &.{ "\"renameChat\"", id, "\"title\":\"Renamed\"" });
    // Escape drops an edit.
    clearCalls();
    sb.update(h.app, sidebar_mod.Sidebar.beginRename, .{ id, h.window() });
    h.settle();
    h.tw().typeKey("escape");
    try testing.expect(sb.read(h.app).rename == null);
    try testing.expect(lastCall(.Mutate) == null);
}

test "sidebar Delete asks for confirmation, then deleteChat and leave the chat" {
    var h = try Harness.init();
    defer h.deinit();
    const id = try testing.allocator.dupe(u8, h.selected().?);
    defer testing.allocator.free(id);
    const sb = h.shell().sidebar;
    sb.update(h.app, struct {
        fn f(_: *sidebar_mod.Sidebar, chat: []const u8, cx: *zpui.Context(sidebar_mod.Sidebar)) void {
            cx.emit(sidebar_mod.DeleteChat{ .chat_id = chat });
        }
    }.f, .{id});
    h.settle();
    try testing.expectEqualStrings(id, h.shell().wiring.delete_confirm.?);
    try testing.expect(lastCall(.Mutate) == null);
    // The dialog is up: Cancel / Delete buttons. Confirm through the API.
    {
        var l = h.handle.rootView(h.app).?.lease(h.app);
        defer l.end();
        const confirm = l.value.wiring.delete_confirm.?;
        l.value.wiring.delete_confirm = null;
        wiring.deleteChat(l.value, confirm, &l.cx);
        testing.allocator.free(confirm);
    }
    try expectCall(.Mutate, &.{ "\"deleteChat\"", id });
    try testing.expect(h.selected() == null);
}

test "composer slash commands run in the shell; Add to chat inserts a file reference" {
    var h = try Harness.init();
    defer h.deinit();
    // `/settings` → settings mode.
    h.composer().update(h.app, struct {
        fn f(_: *composer_mod.ComposerView, cx: *zpui.Context(composer_mod.ComposerView)) void {
            cx.emit(composer_mod.ComposerEvent{ .workspace_command = .settings });
        }
    }.f, .{});
    h.settle();
    try testing.expect(h.shell().settings_view != null);
    {
        var l = h.handle.rootView(h.app).?.lease(h.app);
        defer l.end();
        l.value.closeSettings(h.window(), &l.cx);
    }
    h.settle();
    // Explorer "Add to chat" → `[architecture.md](zeron-file:docs/architecture.md)`.
    h.shell().right_pane.update(h.app, struct {
        fn f(_: *right_pane_mod.RightPane, cx: *zpui.Context(right_pane_mod.RightPane)) void {
            cx.emit(right_pane_mod.AddToChat{ .path = "docs/architecture.md", .is_directory = false });
        }
    }.f, .{});
    h.settle();
    try testing.expectEqualStrings("[architecture.md](zeron-file:docs/architecture.md) ", h.composer().read(h.app).text(h.app));
}

test "transcript file links open the right-pane editor at the line" {
    var h = try Harness.init();
    defer h.deinit();
    const cwd = h.state.read(h.app).workspace.read(h.app).selectedChatRow().?.cwd.?;
    var buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(&buf, "file://{s}/src/lib.rs:2", .{cwd});
    md.rich_text.openLink(url, h.window(), h.app);
    h.settle();
    const t = h.tabs().?;
    try testing.expect(t.open);
    const tab = t.tabs.items[t.tabs.items.len - 1];
    try testing.expect(tab.surface == .file);
    try testing.expectEqualStrings("src/lib.rs", tab.surface.file.read(h.app).filePath());
    // Web links still go to the system opener.
    const before = h.app.test_platform.?.opened_urls;
    md.rich_text.openLink("https://example.com", h.window(), h.app);
    try testing.expectEqual(before + 1, h.app.test_platform.?.opened_urls);
}

test "spawn chips open subagent tabs (frozen ones fetch their blob); retry asks RetryDelivery" {
    var h = try Harness.init();
    defer h.deinit();
    const chat = try testing.allocator.dupe(u8, h.selected().?);
    defer testing.allocator.free(chat);
    const tv = h.shell().main.read(h.app).slots.transcript_view;
    tv.update(h.app, struct {
        fn f(_: *tr.TranscriptView, c: []const u8, cx: *zpui.Context(tr.TranscriptView)) void {
            cx.emit(tr.subagents.OpenSubagent{ .chat_id = c, .doc_id = "doc-1", .title = "scan repo", .frozen = true });
        }
    }.f, .{chat});
    h.settle();
    const t = h.tabs().?;
    try testing.expect(t.open);
    const tab = t.tabs.items[t.tabs.items.len - 1];
    try testing.expect(tab.surface == .subagent);
    try testing.expectEqualStrings("scan repo", tab.surface.subagent.read(h.app).tabTitle());
    var ref_buf: [128]u8 = undefined;
    try expectCall(.FetchToolBlob, &.{try std.fmt.bufPrint(&ref_buf, "\"blobRef\":\"{s}/doc-1\"", .{chat})});
    // The same doc focuses the existing tab.
    const count = t.tabs.items.len;
    tv.update(h.app, struct {
        fn f(_: *tr.TranscriptView, c: []const u8, cx: *zpui.Context(tr.TranscriptView)) void {
            cx.emit(tr.subagents.OpenSubagent{ .chat_id = c, .doc_id = "doc-1", .title = "scan repo", .frozen = false });
        }
    }.f, .{chat});
    try testing.expectEqual(count, h.tabs().?.tabs.items.len);
    // A blob reply loads the frozen transcript.
    const sub = h.tabs().?.tabs.items[count - 1].surface.subagent;
    const reply =
        \\{"text":"[{\"id\":\"m1\",\"role\":\"assistant\",\"parts\":[{\"kind\":\"text\",\"id\":\"p\",\"text\":\"done\"}],\"createdAt\":1,\"deviceId\":\"d\"}]"}
    ;
    const v = try std.json.parseFromSlice(std.json.Value, testing.allocator, reply, .{});
    defer v.deinit();
    try testing.expect(@import("surfaces.zig").loadSnapshot(sub.read(h.app).store, v.value, h.app));
    try testing.expectEqual(@as(usize, 1), sub.read(h.app).store.read(h.app).len());
    // "Not delivered — click to retry".
    tv.update(h.app, tr.TranscriptView.retrySend, .{});
    try expectCall(.RetryDelivery, &.{chat});
}

test "side chats: fork asks ForkSideChat; a new side chat is written on its first send" {
    var h = try Harness.init();
    defer h.deinit();
    const parent = try testing.allocator.dupe(u8, h.selected().?);
    defer testing.allocator.free(parent);
    {
        const rp = h.shell().right_pane;
        var l = rp.lease(h.app);
        defer l.end();
        rp_chats.forkSideChat(l.value, &l.cx);
        rp_chats.newChildChat(l.value, &l.cx);
    }
    try expectCall(.ForkSideChat, &.{ "\"sourceChatId\"", parent, "\"parentChatId\"", "\"targetDeviceId\"" });
    h.settle();
    const t = h.tabs().?;
    const tab = t.tabs.items[t.tabs.items.len - 1];
    try testing.expect(tab.surface == .side_chat);
    const side = tab.surface.side_chat;
    try testing.expectEqualStrings("New side chat", side.read(h.app).tabTitle(h.app));
    try testing.expect(lastCall(.Mutate) == null);
    side.read(h.app).input.update(h.app, composer_mod.TextInput.setText, .{"hello side"});
    side.update(h.app, @import("surfaces.zig").SideChatSurface.send, .{});
    try expectCall(.Mutate, &.{ "\"createChat\"", "\"parentChatId\"", parent });
    try expectCall(.QueueCommand, &.{ side.read(h.app).chat_id, "hello side" });
    try testing.expect(side.read(h.app).unsaved_parent == null);
}

test "explorer footer lists the chat's subagents and side chats" {
    var h = try Harness.init();
    defer h.deinit();
    const parent = try testing.allocator.dupe(u8, h.selected().?);
    defer testing.allocator.free(parent);
    const store = h.state.read(h.app).transcript.?;
    var parts = [_]engine.protocol.MessagePart{.{ .tool = .{ .id = "t1", .call = .{ .unknown = .{ .name = "Agent: audit auth" } }, .subagentRef = "doc-a", .subagentStatus = .running } }};
    var entries = [_]engine.protocol.SessionMessageEntry{.{ .id = "e1", .role = .assistant, .parts = &parts, .createdAt = 1_759_000_000_000, .deviceId = "d" }};
    try tr.loadEntries(store, &entries, h.app);
    {
        var l = h.handle.rootView(h.app).?.lease(h.app);
        defer l.end();
        l.value.toggleFiles(h.window(), &l.cx);
    }
    h.settle();
    {
        const rp = h.shell().right_pane;
        var l = rp.lease(h.app);
        defer l.end();
        rp_chats.syncSections(l.value, &l.cx);
    }
    const explorer = h.tabs().?.explorer.?;
    try testing.expectEqual(@as(usize, 1), explorer.read(h.app).subagents.items.len);
    try testing.expectEqualStrings("audit auth", explorer.read(h.app).subagents.items[0].title);
    try testing.expectEqual(files.panel.RowStatus.working, explorer.read(h.app).subagents.items[0].status);
}

test "sign-in URLs open in the browser; Enable sync shows its dialog" {
    var h = try Harness.init();
    defer h.deinit();
    const auth = h.state.read(h.app).auth;
    const before = h.app.test_platform.?.opened_urls;
    auth.update(h.app, struct {
        fn f(_: *model.AuthStore, cx: *zpui.Context(model.AuthStore)) void {
            cx.emit(model.status.SignInUrl{ .url = "https://zeron.sh/login?x=1" });
        }
    }.f, .{});
    try testing.expectEqual(before + 1, h.app.test_platform.?.opened_urls);
    h.shell().sidebar.update(h.app, struct {
        fn f(_: *sidebar_mod.Sidebar, cx: *zpui.Context(sidebar_mod.Sidebar)) void {
            cx.emit(sidebar_mod.EnableSync{});
        }
    }.f, .{});
    h.settle();
    try expectCall(.SignIn, &.{"{}"});
}

test {
    _ = @import("../sidebar/chat_menu.zig");
    _ = wiring;
}

test "project rows: Rename… dialog sends renameSpace; Remove… confirms deleteSpace" {
    var h = try Harness.init();
    defer h.deinit();
    const ws = h.state.read(h.app).workspace.read(h.app);
    const space_id = try testing.allocator.dupe(u8, ws.spaces()[0].id);
    defer testing.allocator.free(space_id);
    {
        var l = h.handle.rootView(h.app).?.lease(h.app);
        defer l.end();
        wiring.openRenameSpace(l.value, space_id, &l.cx);
    }
    h.settle();
    const in = h.shell().wiring.rename_space.?.input;
    try testing.expectEqualStrings(@import("zeron_model").view.spaceDisplayName(&ws.spaces()[0]), in.read(h.app).text());
    in.update(h.app, composer_mod.TextInput.setText, .{"Aurora v2"});
    h.tw().typeKey("enter");
    h.settle();
    try testing.expect(h.shell().wiring.rename_space == null);
    try expectCall(.Mutate, &.{ "\"renameSpace\"", space_id, "\"name\":\"Aurora v2\"" });
    h.shell().sidebar.update(h.app, struct {
        fn f(_: *sidebar_mod.Sidebar, id: []const u8, cx: *zpui.Context(sidebar_mod.Sidebar)) void {
            cx.emit(sidebar_mod.DeleteSpace{ .space_id = id });
        }
    }.f, .{space_id});
    h.settle();
    try testing.expectEqualStrings(space_id, h.shell().wiring.delete_space.?);
    {
        var l = h.handle.rootView(h.app).?.lease(h.app);
        defer l.end();
        wiring.onDeleteSpaceConfirm(l.value, undefined, h.window(), &l.cx);
    }
    try expectCall(.Mutate, &.{ "\"deleteSpace\"", space_id });
}

test "spaces menu: right-clicking a project row opens Rename… / Remove…" {
    var h = try Harness.init();
    defer h.deinit();
    h.tw().click(110, 60);
    h.settle();
    try testing.expect(h.shell().sidebar.read(h.app).spaces_menu_open);
    _ = h.tw().simulateInput(.{ .mouse_down = .{ .button = .right, .position = .{ .x = 110, .y = 131 } } });
    _ = h.tw().simulateInput(.{ .mouse_up = .{ .button = .right, .position = .{ .x = 110, .y = 131 } } });
    h.settle();
    try testing.expect(h.shell().sidebar.read(h.app).space_ctx != null);
}
