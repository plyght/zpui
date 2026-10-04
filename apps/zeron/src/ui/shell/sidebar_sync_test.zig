//! Headless tests for custom sidebar sections, session transfers, project
//! actions, the plan-usage ring and the sync wizard / sign-out states, on
//! zpui's TestPlatform over the reference fixtures. Engine calls are captured
//! through `EngineState.test_sink`; replies are delivered by calling the
//! views' reply handlers with fabricated results.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const actions = @import("zeron_actions");
const composer_mod = @import("zeron_composer");
const input_mod = @import("zeron_input");
const ui = @import("../components/root.zig");
const prefs_mod = @import("prefs.zig");
const fixtures_mod = @import("fixtures.zig");
const shell_mod = @import("shell.zig");
const sidebar_mod = @import("../sidebar/sidebar.zig");
const sections = @import("../sidebar/sections.zig");
const sections_ui = @import("../sidebar/sections_ui.zig");
const project_actions = @import("project_actions.zig");
const sync_flow = @import("sync_flow.zig");

const testing = std.testing;
const json = std.json;
const App = zpui.App;
const Entity = zpui.Entity;
const TestWindow = zpui.core.test_platform.TestWindow;
const Sidebar = sidebar_mod.Sidebar;
const Shell = shell_mod.Shell;

const Call = struct { method: engine.Method, json: []u8 };
var calls: std.ArrayList(Call) = .empty;

fn sink(method: engine.Method, params: []const u8) void {
    calls.append(testing.allocator, .{ .method = method, .json = testing.allocator.dupe(u8, params) catch return }) catch {};
}

fn clearCalls() void {
    for (calls.items) |c| testing.allocator.free(c.json);
    calls.clearRetainingCapacity();
}

fn count(method: engine.Method) usize {
    var n: usize = 0;
    for (calls.items) |c| if (c.method == method) {
        n += 1;
    };
    return n;
}

fn expectCall(method: engine.Method, needles: []const []const u8) !void {
    var i = calls.items.len;
    const found = while (i > 0) {
        i -= 1;
        if (calls.items[i].method == method) break calls.items[i].json;
    } else {
        std.debug.print("no {t} call captured\n", .{method});
        return error.TestUnexpectedResult;
    };
    for (needles) |n| if (std.mem.indexOf(u8, found, n) == null) {
        std.debug.print("{t} params {s} lack {s}\n", .{ method, found, n });
        return error.TestUnexpectedResult;
    };
}

const Harness = struct {
    app: *App,
    fixtures: *fixtures_mod.Fixtures,
    state: Entity(model.AppState),
    handle: zpui.WindowHandle(Shell),

    fn init() !Harness {
        const gpa = testing.allocator;
        const io = testing.io;
        model.engine_state.test_sink = sink;
        const app = try App.initTest(gpa);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        try model.settings_store.initMemory(app, io);
        const f = try fixtures_mod.load(gpa, io, "apps/zeron/fixtures/reference");
        var prefs: prefs_mod.Prefs = .{ .gpa = gpa };
        fixtures_mod.applyPrefs(f, &prefs);
        try ui.theme.install(app, zt.Theme.dark());
        try prefs_mod.install(app, prefs);
        const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false, .wake_mode = .poll } });
        fixtures_mod.applyToState(f, io, app, state);
        const handle = try app.openWindow(.{
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1600, .height = 1000 } },
        }, Shell, Shell.init, .{ state, f, true });
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

    fn tw(h: *Harness) *TestWindow {
        return TestWindow.of(h.handle.window(h.app).?.platform_window);
    }

    fn shellEntity(h: *Harness) Entity(Shell) {
        return h.handle.rootView(h.app).?;
    }

    fn sidebar(h: *Harness) Entity(Sidebar) {
        return h.shellEntity().read(h.app).sidebar;
    }

    fn settle(h: *Harness) void {
        for (0..4) |_| {
            h.app.runUntilParked();
            h.tw().frame(true);
        }
    }

    fn ws(h: *Harness) *const model.WorkspaceStore {
        return h.state.read(h.app).workspace.read(h.app);
    }

    fn localSections(h: *Harness) []const sections.Section {
        const s = model.settings_store.current(h.app).?;
        return s.sidebarSectionsByProfile.map.get("local") orelse &.{};
    }

    fn setScope(h: *Harness, scope: engine.protocol.WorkspaceScope) void {
        h.state.read(h.app).workspace.update(h.app, struct {
            fn f(w: *model.WorkspaceStore, s: engine.protocol.WorkspaceScope, cx: *zpui.Context(model.WorkspaceStore)) void {
                w.workspace_scope = s;
                cx.notify();
            }
        }.f, .{scope});
    }
};

fn dialogInput(h: *Harness) Entity(input_mod.TextInput) {
    return h.sidebar().read(h.app).sec.dialog.?.input;
}

test "local sections: create, edit, assign (unpins), delete — persisted per profile" {
    var h = try Harness.init();
    defer h.deinit();
    h.setScope(.local);
    h.settle();
    const sb = h.sidebar();

    // An empty name keeps the dialog open; a trimmed one creates the section.
    sb.update(h.app, sections_ui.openDialog, .{@as(?[]const u8, null)});
    h.settle();
    sb.update(h.app, sections_ui.submitDialog, .{});
    try testing.expect(sb.read(h.app).sec.dialog != null);
    dialogInput(&h).update(h.app, input_mod.TextInput.setText, .{"  Review  "});
    sb.update(h.app, sections_ui.submitDialog, .{});
    try testing.expect(sb.read(h.app).sec.dialog == null);
    try testing.expectEqual(@as(usize, 1), h.localSections().len);
    try testing.expectEqualStrings("Review", h.localSections()[0].name);
    const id = try testing.allocator.dupe(u8, h.localSections()[0].id);
    defer testing.allocator.free(id);
    h.settle();

    // Edit renames in place.
    sb.update(h.app, sections_ui.openDialog, .{@as(?[]const u8, id)});
    dialogInput(&h).update(h.app, input_mod.TextInput.setText, .{"Today"});
    sb.update(h.app, sections_ui.submitDialog, .{});
    try testing.expectEqualStrings("Today", h.localSections()[0].name);

    // Assigning a pinned chat moves it out of the pins.
    const chat = try testing.allocator.dupe(u8, h.ws().chats()[0].id);
    defer testing.allocator.free(chat);
    prefs_mod.mut(h.app).setPinned(chat, true);
    try testing.expect(sb.update(h.app, sections_ui.change, .{sections.SectionChange{ .assign = .{ .sessionId = chat, .sectionId = id } }}));
    try testing.expect(!prefs_mod.get(h.app).isPinned(chat));
    try testing.expectEqualStrings(chat, h.localSections()[0].session_ids[0]);
    // An unknown target is refused locally.
    try testing.expect(!sb.update(h.app, sections_ui.change, .{sections.SectionChange{ .assign = .{ .sessionId = chat, .sectionId = "nope" } }}));
    h.settle();

    // Collapse, then delete (the chat returns to Sessions; nothing is deleted).
    try testing.expect(sb.update(h.app, sections_ui.change, .{sections.SectionChange{ .collapse = .{ .id = id, .collapsed = true } }}));
    try testing.expect(h.localSections()[0].collapsed);
    h.settle();
    try testing.expect(sb.update(h.app, sections_ui.change, .{sections.SectionChange{ .delete = .{ .id = id } }}));
    try testing.expectEqual(@as(usize, 0), h.localSections().len);
    try testing.expect(h.ws().chat(chat) != null);
    h.settle();
    try testing.expectEqual(@as(usize, 0), count(.Mutate));
}

test "synced sections queue changeSidebarPin writes; the ack replaces the snapshot" {
    var h = try Harness.init();
    defer h.deinit();
    h.setScope(.synced);
    h.state.read(h.app).auth.update(h.app, struct {
        fn f(a: *model.AuthStore, cx: *zpui.Context(model.AuthStore)) void {
            a.auth = .{ .signedIn = .{ .user = .{ .id = "u1", .email = "ada@example.test" }, .orgId = "org" } };
            cx.notify();
        }
    }.f, .{});
    const sb = h.sidebar();
    // Until the snapshot is authoritative, edits are refused with a notice.
    try testing.expect(!sb.update(h.app, sections_ui.change, .{sections.SectionChange{ .create = .{ .id = "s1", .name = "Focus" } }}));
    try testing.expectEqualStrings(sections.notice_syncing, sb.read(h.app).notice.?);

    const prefs_json = "{\"revision\":1,\"synced\":true,\"initialized\":true,\"pinnedSessionIds\":[],\"sections\":[]}";
    const frame = try json.parseFromSlice(engine.protocol.SidebarPreferencesState, testing.allocator, prefs_json, .{ .allocate = .alloc_always });
    h.state.read(h.app).workspace.update(h.app, model.WorkspaceStore.applySidebarPreferences, .{frame});
    clearCalls();
    try testing.expect(sb.update(h.app, sections_ui.change, .{sections.SectionChange{ .create = .{ .id = "s1", .name = "Focus" } }}));
    try testing.expect(sb.update(h.app, sections_ui.change, .{sections.SectionChange{ .rename = .{ .id = "s1", .name = "Later" } }}));
    // One write in flight; the second waits in the queue (optimistic overlay).
    try testing.expectEqual(@as(usize, 1), count(.Mutate));
    try expectCall(.Mutate, &.{ "\"op\":\"changeSidebarPin\"", "\"action\":\"section\"", "\"action\":\"create\"", "\"name\":\"Focus\"" });
    // The queued rename already shows (optimistic overlay on the snapshot).
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const shown = sb.update(h.app, struct {
        fn f(s: *Sidebar, a: std.mem.Allocator, cx: *zpui.Context(Sidebar)) []const u8 {
            const list = s.sec.ctl.active(a, sections_ui.env(s, cx)) catch return "";
            return if (list.len > 0) list[0].name else "";
        }
    }.f, .{arena.allocator()});
    try testing.expectEqualStrings("Later", shown);
    h.settle();

    // The ack sends the next intent.
    const ack = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"ok":true,"sidebarPreferences":{"revision":2,"synced":true,"initialized":true,"pinnedSessionIds":[],
        \\ "sections":[{"id":"s1","name":"Focus","session_ids":[],"collapsed":false}]}}
    , .{});
    defer ack.deinit();
    sb.update(h.app, struct {
        fn f(s: *Sidebar, v: json.Value, cx: *zpui.Context(Sidebar)) void {
            const id = s.sec.ctl.pendingId().?;
            const r = s.sec.ctl.finish(id, .{ .ok = v }, sections_ui.env(s, cx));
            std.debug.assert(r.send_next);
        }
    }.f, .{ack.value});
    try testing.expectEqual(@as(u64, 2), h.ws().sidebarPreferences().revision);
    try testing.expectEqualStrings("Focus", h.ws().sidebarPreferences().sections[0].name);
    h.settle();
}

test "project actions: load, run, add — the titlebar control drives the RPCs" {
    var h = try Harness.init();
    defer h.deinit();
    // A chat in a project on this device.
    const ws = h.ws();
    var chat_id: ?[]const u8 = null;
    for (ws.chats()) |c| if (c.spaceId != null) if (ws.space(c.spaceId.?)) |sp| if (std.mem.eql(u8, sp.deviceId, c.deviceId)) {
        chat_id = c.id;
        break;
    };
    const id = try testing.allocator.dupe(u8, chat_id orelse return error.SkipZigTest);
    defer testing.allocator.free(id);
    h.state.read(h.app).workspace.update(h.app, model.WorkspaceStore.selectChat, .{@as(?[]const u8, id)});
    clearCalls();
    h.settle();
    // The control asked for the project's actions (possibly while the fixture
    // booted on this chat, before the captured calls were cleared).
    try testing.expect(h.shellEntity().read(h.app).wiring.project_actions.?.loads.items.len >= 1);

    // Deliver a snapshot: the preferred action is the first non-setup one.
    const snap = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"spaceId":"x","actions":[{"id":"setup","name":"Setup","command":"make","icon":"configure","runOnWorktreeCreate":true},
        \\ {"id":"dev","name":"Dev","command":"npm run dev","icon":"play","runOnWorktreeCreate":false}],
        \\ "importableActions":[{"name":"Lint","command":"eslint .","icon":"lint"}]}
    , .{});
    defer snap.deinit();
    const shell = h.shellEntity();
    shell.update(h.app, struct {
        fn f(s: *Shell, v: json.Value, cx: *zpui.Context(Shell)) void {
            const c = &s.wiring.project_actions.?;
            const l = c.loads.orderedRemove(0);
            defer c.gpa.free(l.key.device_id);
            defer c.gpa.free(l.key.space_id);
            const parsed = json.parseFromValue(project_actions.Snapshot, c.gpa, v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch unreachable;
            std.debug.assert(c.acceptLoad(l.key, l.generation, project_actions.LoadResult{ .ok = parsed }));
            cx.notify();
        }
    }.f, .{snap.value});
    h.settle();
    const c = &shell.read(h.app).wiring.project_actions.?;
    try testing.expect(@constCast(c).activeStatus().?.canRun());

    // Run: `RunProjectAction` for the chat's project.
    clearCalls();
    shell.update(h.app, project_actions.runAction, .{ @as([]const u8, "dev"), h.handle.window(h.app).? });
    try expectCall(.RunProjectAction, &.{ "\"actionId\":\"dev\"", "\"cols\":80", "\"rows\":24" });
    try testing.expect(std.mem.indexOf(u8, calls.items[0].json, id) != null);

    // The editor validates, then upserts.
    shell.update(h.app, project_actions.openEditor, .{ null, null });
    try testing.expect(project_actions.editorOpen(shell.read(h.app)));
    h.settle();
    shell.update(h.app, project_actions.save, .{});
    try testing.expectEqualStrings("Action name is required", shell.read(h.app).wiring.project_actions.?.editor.?.err.?);
    const ed = shell.read(h.app).wiring.project_actions.?.editor.?;
    ed.name.update(h.app, input_mod.TextInput.setText, .{"Test"});
    ed.command.update(h.app, input_mod.TextInput.setText, .{"zig build test"});
    shell.update(h.app, project_actions.save, .{});
    try expectCall(.UpsertProjectAction, &.{ "\"name\":\"Test\"", "\"command\":\"zig build test\"", "\"icon\":\"play\"" });
    try testing.expect(shell.read(h.app).wiring.project_actions.?.editor.?.saving);
    h.settle();
}

test "sign out asks first, then SignOut and StopEngine; a signed-out synced runtime leaves on its own" {
    var h = try Harness.init();
    defer h.deinit();
    h.setScope(.synced);
    h.settle();
    const shell = h.shellEntity();
    shell.update(h.app, sync_flow.requestSignOut, .{});
    try testing.expect(shell.read(h.app).wiring.sync_flow == .sign_out_confirm);
    h.settle();
    clearCalls();
    shell.update(h.app, sync_flow.startLocalTransition, .{true});
    try testing.expect(shell.read(h.app).wiring.sync_flow == .signing_out);
    try testing.expectEqual(@as(usize, 1), count(.SignOut));
    h.settle();

    // Signed out while synced: the fallback page, with Retry local mode.
    shell.update(h.app, sync_flow.set, .{sync_flow.SyncFlow.signed_out_restart_required});
    h.settle();
    try testing.expectEqual(@as(?sync_flow.AccountMenuAction, null), sync_flow.accountMenuAction(.synced, sync_flow.current(h.app)));
}

test "sync wizard: offer, import progress and summary" {
    var h = try Harness.init();
    defer h.deinit();
    h.setScope(.local);
    const shell = h.shellEntity();
    shell.update(h.app, sync_flow.set, .{sync_flow.SyncFlow{ .switch_offer = true }});
    h.settle();
    try testing.expectEqual(@as(?sync_flow.AccountMenuAction, .restart_pending), sync_flow.accountMenuAction(.local, sync_flow.current(h.app)));
    shell.update(h.app, sync_flow.postpone, .{});
    try testing.expect(shell.read(h.app).wiring.sync_flow.eql(.{ .switch_offer = false }));
    shell.update(h.app, sync_flow.reopen, .{});
    try testing.expect(shell.read(h.app).wiring.sync_flow.eql(.{ .switch_offer = true }));

    const events = [_][]const u8{
        "{\"kind\":\"start\",\"chats\":3}",
        "{\"kind\":\"chat\",\"index\":1,\"total\":3,\"title\":\"Fix flaky test\"}",
        "{\"kind\":\"summary\",\"importedChats\":2,\"skippedChats\":1,\"errors\":[]}",
    };
    for (events, 0..) |e, i| {
        const v = try json.parseFromSlice(json.Value, testing.allocator, e, .{});
        defer v.deinit();
        shell.update(h.app, sync_flow.applyImportEvent, .{v.value});
        h.settle();
        if (i == 1) try testing.expectEqualStrings("Fix flaky test", shell.read(h.app).wiring.runtime.import_current.?);
    }
    try testing.expect(shell.read(h.app).wiring.sync_flow.eql(.{ .import_done = .{ .imported = 2, .skipped = 1 } }));
    const bad = try json.parseFromSlice(json.Value, testing.allocator, "{\"kind\":\"summary\",\"importedChats\":1,\"errors\":[\"disk full\"]}", .{});
    defer bad.deinit();
    shell.update(h.app, sync_flow.applyImportEvent, .{bad.value});
    try testing.expect(shell.read(h.app).wiring.sync_flow.eql(.{ .import_failed = true }));
    try testing.expectEqualStrings("1 imported, 1 failure: disk full", shell.read(h.app).wiring.runtime.err.?);
    h.settle();
}

test "plan-usage ring: loads on first sight of a device and reads the shared cache" {
    var h = try Harness.init();
    defer h.deinit();
    const theme = composer_mod.chrome.defaultTheme(.dark);
    const v = composer_mod.account_usage.ring(h.app, h.state, .codex, null, &theme).?;
    // A fresh device target loads (plain list first, then the forced probe).
    clearCalls();
    _ = composer_mod.account_usage.ring(h.app, h.state, .codex, "remote-device", &theme).?;
    try testing.expectEqual(@as(usize, 2), count(.ListAgentAccounts));
    try expectCall(.ListAgentAccounts, &.{ "\"forceUsage\":true", "\"targetDeviceId\":\"remote-device\"" });
    _ = composer_mod.account_usage.ring(h.app, h.state, .codex, null, &theme).?;
    const snap = try json.parseFromSlice(json.Value, testing.allocator,
        \\{"accounts":[{"id":"a","harness":"codex","active":true,"switchable":true,"usageWindows":[{"label":"5h","usedFraction":0.42}]},
        \\ {"id":"b","harness":"codex","active":false,"switchable":true,"usageWindows":[]}],"warnings":[]}
    , .{});
    defer snap.deinit();
    try testing.expect(composer_mod.account_usage.publish(h.app, null, snap.value));
    h.settle();
    _ = v;
    clearCalls();
}
