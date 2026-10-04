//! [wiring] `extras.zig` on the headless test platform: the question wizard,
//! the todo tray, queue reorder + leased edit, `@` file mentions and
//! provider slash commands. Engine calls are captured through
//! `EngineState.test_sink`; replies are fed to the callbacks directly.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const actions = @import("zeron_actions");
const input_mod = @import("zeron_input");
const composer_mod = @import("composer.zig");
const extras = @import("extras.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const TestWindow = zpui.core.test_platform.TestWindow;
const ComposerView = composer_mod.ComposerView;
const protocol = engine.protocol;
const testing = std.testing;
const div = zpui.div;
const px = zpui.px;

const chat_id = "11111111-2222-3333-4444-555555555555";

const Call = struct { method: engine.Method, json: []u8 };
var calls: std.ArrayList(Call) = .empty;

fn sink(method: engine.Method, params: []const u8) void {
    calls.append(testing.allocator, .{ .method = method, .json = testing.allocator.dupe(u8, params) catch return }) catch {};
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
        std.debug.print("no {t} call\n", .{method});
        return error.TestUnexpectedResult;
    };
    for (needles) |n| if (std.mem.indexOf(u8, json, n) == null) {
        std.debug.print("{t} {s} lacks {s}\n", .{ method, json, n });
        return error.TestUnexpectedResult;
    };
}

const Host = struct {
    composer: Entity(ComposerView),

    fn init(state: Entity(model.AppState), window: *Window, cx: *Context(Host)) !Host {
        const c = try cx.newWith(ComposerView, ComposerView.init, .{state});
        c.update(cx, ComposerView.focusInput, .{window});
        return .{ .composer = c };
    }

    pub fn deinit(self: *Host, cx: *App) void {
        self.composer.release(cx);
    }

    pub fn render(self: *Host, _: *Window, _: *Context(Host)) zpui.Div {
        return div().size(px(900)).flex().flexCol().justifyEnd().child(self.composer);
    }
};

const Fixture = struct {
    app: *App,
    state: Entity(model.AppState),
    handle: zpui.WindowHandle(Host),
    tw: *TestWindow,

    fn init() !Fixture {
        model.engine_state.test_sink = sink;
        const app = try App.initTest(testing.allocator);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        const state = try app.newWith(model.AppState, model.AppState.init, .{ testing.io, model.engine_state.Config{
            .port = 1,
            .zeron_path = null,
            .reconnect = false,
            .autoconnect = false,
            .wake_mode = .poll,
        } });
        // One chat on device "dev-1", selected.
        const chats = try std.json.parseFromSlice([]protocol.Chat, testing.allocator,
            \\[{"id":"11111111-2222-3333-4444-555555555555","deviceId":"dev-1","title":"T","archived":false,"cwd":"/repo","createdAt":"2026-10-01T00:00:00Z","config":{"harness":"claude-code","sandbox":"workspace-write"}}]
        , .{ .ignore_unknown_fields = true });
        const ws = state.read(app).workspace;
        ws.update(app, model.WorkspaceStore.applyChats, .{chats});
        ws.update(app, model.WorkspaceStore.selectChat, .{@as(?[]const u8, chat_id)});
        const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 900, .height = 900 } } }, Host, Host.init, .{state});
        const w = handle.window(app).?;
        return .{ .app = app, .state = state, .handle = handle, .tw = TestWindow.of(w.platform_window) };
    }

    fn deinit(f: *Fixture) void {
        f.state.release(f.app);
        f.app.deinit();
        for (calls.items) |c| testing.allocator.free(c.json);
        calls.deinit(testing.allocator);
        calls = .empty;
        model.engine_state.test_sink = null;
    }

    fn composer(f: *Fixture) Entity(ComposerView) {
        return f.handle.rootView(f.app).?.read(f.app).composer;
    }

    fn view(f: *Fixture) *const ComposerView {
        return f.composer().read(f.app);
    }

    fn text(f: *Fixture) []const u8 {
        return f.view().input.read(f.app).text();
    }

    fn typeChars(f: *Fixture, s: []const u8) void {
        for (s) |c| _ = f.tw.simulateInput(.{ .key_down = .{ .keystroke = .{ .key = &.{c}, .key_char = &.{c} } } });
    }

    fn settle(f: *Fixture) void {
        f.app.runUntilParked();
        f.tw.frame(true);
    }

    /// Replace the selected chat's transcript with `json` entries.
    fn setTranscript(f: *Fixture, json: []const u8) !void {
        const store = f.state.read(f.app).transcript.?;
        const parsed = try std.json.parseFromSlice([]protocol.SessionMessageEntry, testing.allocator, json, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const Apply = struct {
            fn run(s: *model.TranscriptStore, e: []protocol.SessionMessageEntry, cx: *Context(model.TranscriptStore)) void {
                s.transcript.apply(.{ .reset = e }) catch return;
                s.replayed = true;
                s.revision +%= 1;
                cx.emit(model.transcript_store.Changed{ .reset = true });
                cx.notify();
            }
        };
        store.update(f.app, Apply.run, .{parsed.value});
        f.settle();
    }

    fn ok(f: *Fixture, comptime cb: anytype, json: []const u8) !void {
        const v = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
        defer v.deinit();
        f.composer().update(f.app, cb, .{model.engine_state.CallResult{ .ok = v.value }});
        f.settle();
    }
};

const question_transcript =
    \\[{"id":"a1","role":"assistant","createdAt":1,"deviceId":"dev-1","status":"streaming","parts":[
    \\  {"kind":"input","id":"p1","requestId":"req-9","questions":[
    \\    {"id":"q1","header":"Scope","question":"Which files?","options":["All","Changed only"]},
    \\    {"id":"q2","header":"Notes","question":"Anything else?","options":["No"]}]}]}]
;

test "question wizard replaces the pill and answers with respondInput" {
    var f = try Fixture.init();
    defer f.deinit();
    f.typeChars("my draft");
    try f.setTranscript(question_transcript);
    try testing.expect(extras.wizardActive(f.view()));
    try testing.expectEqualStrings("", f.text());
    try testing.expectEqualStrings("Type your own answer, or pick an option above", f.view().input.read(f.app).placeholder.items);
    // Pick option 2 → auto-advance to page 2 after 220ms.
    f.composer().update(f.app, extras.wizardSelect, .{1});
    f.app.advanceClock(250 * std.time.ns_per_ms);
    f.settle();
    try testing.expectEqual(@as(usize, 1), f.view().ext.wizard.?.page);
    // Type a free-text answer and submit with Enter.
    f.typeChars("ship it");
    f.tw.typeKey("enter");
    f.settle();
    try testing.expect(!extras.wizardActive(f.view()));
    try expectCall(.QueueCommand, &.{ "\"respondInput\"", "\"requestId\":\"req-9\"", "\"questionId\":\"q1\"", "\"Changed only\"", "\"ship it\"" });
    // The ordinary draft comes back.
    try testing.expectEqualStrings("my draft", f.text());
    // The question still pending after 2s re-opens the panel (safety net).
    f.app.advanceClock(2100 * std.time.ns_per_ms);
    f.settle();
    try testing.expect(extras.wizardActive(f.view()));
    // Resolution elsewhere releases it.
    try f.setTranscript(
        \\[{"id":"a1","role":"assistant","createdAt":1,"deviceId":"dev-1","parts":[
        \\  {"kind":"input","id":"p1","requestId":"req-9","resolved":true,"questions":[]}]}]
    );
    try testing.expect(!extras.wizardActive(f.view()));
}

test "todo tray follows the latest list, collapses and dismisses" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.setTranscript(
        \\[{"id":"a1","role":"assistant","createdAt":1,"deviceId":"dev-1","parts":[
        \\  {"kind":"tool","id":"t1","call":{"kind":"todo","items":[
        \\    {"text":"Read code","done":true,"status":"completed"},
        \\    {"text":"Write tests","done":false,"status":"inProgress"},
        \\    {"text":"Ship","done":false}]}}]}]
    );
    {
        var l = f.composer().lease(f.app);
        defer l.end();
        try testing.expect(extras.todoView(l.value, &l.cx) != null);
        const st = l.value.ext.todo.get(testing.allocator, chat_id);
        try testing.expect(st.isExpanded(false));
        st.toggle(false);
        try testing.expect(!st.isExpanded(false));
    }
    f.settle();
    // Idle chat: dismiss hides this list until the agent writes another.
    {
        var l = f.composer().lease(f.app);
        defer l.end();
        const store = l.value.state.read(l.cx.app).transcript.?;
        const items = @import("todo_panel.zig").latestTodo(store.read(l.cx.app)).?;
        l.value.ext.todo.get(testing.allocator, chat_id).dismiss(items);
        try testing.expect(extras.todoView(l.value, &l.cx) == null);
    }
}

test "queue rows reorder optimistically and edit under the host's lease" {
    var f = try Fixture.init();
    defer f.deinit();
    const q = f.state.read(f.app).queue.?;
    const snap = try std.json.parseFromSlice(protocol.QueueSnapshot, testing.allocator,
        \\{"items":[{"id":"q-a","text":"first","issuedBy":"d","issuedAt":1},{"id":"q-b","text":"second","issuedBy":"d","issuedAt":2},{"id":"q-c","text":"third","issuedBy":"d","issuedAt":3}]}
    , .{ .ignore_unknown_fields = true });
    q.update(f.app, model.QueueStore.applyQueue, .{snap});
    f.settle();
    f.composer().update(f.app, extras.moveQueued, .{ 0, 2 });
    try expectCall(.MoveQueuedMessage, &.{ "\"id\":\"q-a\"", "\"toIndex\":2" });
    try testing.expectEqualStrings("q-b", q.read(f.app).items()[0].id);
    try testing.expectEqualStrings("q-a", q.read(f.app).items()[2].id);
    // Without the lease capability the edit is refused with Rust's notice.
    f.composer().update(f.app, extras.beginQueueEdit, .{0});
    try testing.expectEqualStrings("Update the chat host to edit queued messages safely", f.view().failure.items);
    // An acquired lease moves the row into the composer; Enter commits it.
    f.typeChars("draft");
    {
        var l = f.composer().lease(f.app);
        defer l.end();
        l.value.ext.edit_pending = try testing.allocator.dupe(u8, "q-b");
    }
    try f.ok(extras.onBeginEdit,
        \\{"outcome":"acquired","leaseId":"L1","baseTextHash":"H1","text":"second","attachments":[]}
    );
    try testing.expectEqualStrings("second", f.text());
    try testing.expect(extras.isEditingQueued(f.view()));
    f.typeChars("!");
    f.tw.typeKey("enter");
    try expectCall(.FinishQueuedMessageEdit, &.{ "\"leaseId\":\"L1\"", "\"action\":\"commit\"", "\"text\":\"second!\"", "\"expectedTextHash\":\"H1\"", "\"targetDeviceId\":\"dev-1\"" });
    try f.ok(extras.onFinished, "{\"outcome\":\"committed\"}");
    try testing.expect(!extras.isEditingQueued(f.view()));
    try testing.expectEqualStrings("draft", f.text());
    // The heartbeat renews the lease every 20s while editing.
    {
        var l = f.composer().lease(f.app);
        defer l.end();
        l.value.ext.edit_pending = try testing.allocator.dupe(u8, "q-c");
    }
    try f.ok(extras.onBeginEdit,
        \\{"outcome":"acquired","leaseId":"L2","baseTextHash":"H2","text":"third","attachments":[]}
    );
    f.app.advanceClock(20_100 * std.time.ns_per_ms);
    try expectCall(.RenewQueuedMessageEdit, &.{"\"leaseId\":\"L2\""});
    f.tw.typeKey("escape");
    try expectCall(.FinishQueuedMessageEdit, &.{ "\"leaseId\":\"L2\"", "\"action\":\"cancel\"" });
}

test "@ mentions search the workspace and insert a file reference" {
    var f = try Fixture.init();
    defer f.deinit();
    f.typeChars("see @sr");
    f.app.advanceClock(100 * std.time.ns_per_ms);
    f.settle();
    try expectCall(.SearchFiles, &.{ "\"chatId\":\"" ++ chat_id ++ "\"", "\"targetDeviceId\":\"dev-1\"", "\"cwd\":\"/repo\"", "\"query\":\"sr\"" });
    try testing.expectEqual(extras.Mode.mention, extras.mode(f.view(), f.app));
    try f.ok(extras.onSearchResult,
        \\[{"path":"src/main.rs","isDir":false},{"path":"src/","isDir":true},{"path":"../evil","isDir":false}]
    );
    try testing.expectEqual(@as(usize, 2), f.view().ext.mention.results.len);
    try testing.expect(f.view().input.read(f.app).mention_has_selection);
    f.tw.typeKey("down");
    f.tw.typeKey("up");
    f.tw.typeKey("enter");
    try testing.expectEqualStrings("see [main.rs](zeron-file:src/main.rs) ", f.text());
    try testing.expectEqual(extras.Mode.none, extras.mode(f.view(), f.app));
}

test "provider slash commands and skills join Zeron's commands" {
    var f = try Fixture.init();
    defer f.deinit();
    f.typeChars("/re");
    f.settle();
    try expectCall(.ListCommands, &.{ "\"chatId\":\"" ++ chat_id ++ "\"", "\"harness\":\"claude-code\"" });
    try expectCall(.ListSkills, &.{"\"harness\":\"claude-code\""});
    try f.ok(extras.onCommands, "[{\"name\":\"review\",\"description\":\"Review the diff\"}]");
    try f.ok(extras.onSkills, "[{\"name\":\"release-notes\",\"path\":\"/sk/rn/SKILL.md\",\"description\":\"Notes\",\"enabled\":true}]");
    var buf: [64]usize = undefined;
    const rows = extras.slashRows(f.view(), f.app, &buf);
    // Prefix matches: review, then Zeron's /resume and /rename, then the skill.
    try testing.expect(rows.len >= 3);
    try testing.expectEqualStrings("review", f.view().ext.catalog.rows[rows[0]].name);
    f.tw.typeKey("enter");
    // The host lacks composer-references-v1 here: plain `/review `.
    try testing.expectEqualStrings("/review ", f.text());
}
