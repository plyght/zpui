//! [wiring] Transcript affordances on the headless platform: spawn chips →
//! `OpenSubagent`, "Show full output" (`FetchToolBlob`), the scroll-to-bottom
//! pill, and "Not delivered — click to retry" (`RetryDelivery`).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const view = @import("view.zig");
const subagents = @import("subagents.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const testing = std.testing;

var calls: std.ArrayList(struct { method: engine.Method, json: []u8 }) = .empty;

fn sink(method: engine.Method, params: []const u8) void {
    calls.append(testing.allocator, .{ .method = method, .json = testing.allocator.dupe(u8, params) catch return }) catch {};
}

fn freeCalls() void {
    for (calls.items) |c| testing.allocator.free(c.json);
    calls.deinit(testing.allocator);
    calls = .empty;
}

const Root = struct {
    tv: Entity(view.TranscriptView),
    sub: zpui.Subscription,
    opened: std.ArrayList(u8) = .empty,

    fn init(tv: Entity(view.TranscriptView), _: *zpui.Window, cx: *Context(Root)) !Root {
        return .{ .tv = tv, .sub = try cx.subscribe(tv, onOpen) };
    }

    fn onOpen(self: *Root, _: Entity(view.TranscriptView), ev: *const subagents.OpenSubagent, cx: *Context(Root)) void {
        self.opened.clearRetainingCapacity();
        self.opened.print(cx.gpa(), "{s}|{s}|{s}|{}", .{ ev.chat_id, ev.doc_id, ev.title, ev.frozen }) catch {};
    }

    pub fn deinit(self: *Root, app: *App) void {
        self.sub.deinit();
        self.opened.deinit(app.gpa);
        self.tv.release(app);
    }

    pub fn render(self: *Root, _: *zpui.Window, _: *Context(Root)) zpui.Div {
        return zpui.div().sizeFull().child(self.tv);
    }
};

const fixture =
    \\[
    \\ {"id":"u1","role":"user","createdAt":1782920700000,"deviceId":"d","status":"complete",
    \\  "parts":[{"kind":"text","id":"t","text":"Audit it"}]},
    \\ {"id":"a1","role":"assistant","createdAt":1782920701000,"deviceId":"d","status":"complete",
    \\  "parts":[{"kind":"tool","id":"s1","call":{"kind":"unknown","name":"Agent","input":{"description":"Agent: audit the auth flow"}},
    \\            "resolved":true,"subagentRef":"chat-1--sub--a","subagentStatus":"done"},
    \\           {"kind":"tool","id":"x","call":{"kind":"exec","command":"cargo test"},"resolved":true,"output":"line 1",
    \\            "outputRef":"chat-1/x.out","outputBytes":5000}]}
    \\]
;

test "spawn chips emit OpenSubagent; blobs fetch; retry asks RetryDelivery; jump hysteresis" {
    model.engine_state.test_sink = sink;
    defer model.engine_state.test_sink = null;
    defer freeCalls();
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const eng = try app.newWith(model.EngineState, model.EngineState.init, .{ testing.io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false } });
    defer eng.release(app);
    const store = try app.newWith(model.TranscriptStore, model.TranscriptStore.init, .{ eng, "chat-1" });
    defer store.release(app);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try view.loadEntries(store, try view.parseFixture(arena.allocator(), fixture), app);
    const tv = try app.newWith(view.TranscriptView, view.TranscriptView.initWithStore, .{store});
    defer tv.release(app);
    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 1200, .height = 900 } } }, Root, Root.init, .{tv.retain(app)});
    app.runUntilParked();

    // The tool group row holds the spawn chip (tool 0).
    var key: u64 = 0;
    var spawn_ix: usize = 0;
    for (0..tv.read(app).rowCount()) |i| if (tv.read(app).rowAt(i).kind == .tool_group) {
        for (tv.read(app).rowAt(i).kind.tool_group.tools, 0..) |t, ti| if (t.isSpawnLink()) {
            key = tv.read(app).rowAt(i).key;
            spawn_ix = ti;
        };
    };
    try testing.expect(key != 0);
    {
        var l = tv.lease(app);
        defer l.end();
        l.value.onSpawnClick(.{ key, spawn_ix }, undefined, handle.window(app).?, &l.cx);
    }
    app.runUntilParked();
    try testing.expectEqualStrings("chat-1|chat-1--sub--a|audit the auth flow|true", handle.rootView(app).?.read(app).opened.items);

    // "Show full output (5 KB)" → FetchToolBlob; the reply upgrades the body.
    {
        var l = tv.lease(app);
        defer l.end();
        l.value.requestBlob("chat-1/x.out", &l.cx);
    }
    try testing.expectEqual(engine.Method.FetchToolBlob, calls.items[calls.items.len - 1].method);
    try testing.expect(std.mem.indexOf(u8, calls.items[calls.items.len - 1].json, "\"blobRef\":\"chat-1/x.out\"") != null);
    const req_id = tv.read(app).blob_requests.items[0].id;
    {
        var l = tv.lease(app);
        defer l.end();
        l.value.landBlob("chat-1/x.out", "full 1\nfull 2\nfull 3", req_id, &l.cx);
    }
    app.runUntilParked();
    try testing.expectEqual(@as(usize, 0), tv.read(app).blob_requests.items.len);
    var item: ?@import("rows.zig").ToolItem = null;
    for (0..tv.read(app).rowCount()) |i| if (tv.read(app).rowAt(i).kind == .tool_group) {
        for (tv.read(app).rowAt(i).kind.tool_group.tools) |t| if (t.output_ref != null) {
            item = t;
        };
    };
    try testing.expectEqual(@as(usize, 3), tv.read(app).blobs.effective(item.?).?.output.lines.len);

    // Retry: RetryDelivery {chatId}.
    tv.update(app, view.TranscriptView.retrySend, .{});
    try testing.expectEqual(engine.Method.RetryDelivery, calls.items[calls.items.len - 1].method);
    try testing.expectEqualStrings("{\"chatId\":\"chat-1\"}", calls.items[calls.items.len - 1].json);

    // Jump pill: offered past 320px, kept until within 2px of the end.
    try testing.expect(!view.TranscriptView.jumpVisibility(false, 300));
    try testing.expect(view.TranscriptView.jumpVisibility(false, 321));
    try testing.expect(view.TranscriptView.jumpVisibility(true, 50));
    try testing.expect(!view.TranscriptView.jumpVisibility(true, 1));
}
