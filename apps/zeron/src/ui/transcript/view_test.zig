//! Headless `TranscriptView` tests (zpui test platform, offline store).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const view = @import("view.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;

const fixture =
    \\[
    \\ {"id":"u1","role":"user","createdAt":1782920700000,"deviceId":"d","status":"complete",
    \\  "parts":[{"kind":"text","id":"t","text":"Hello there"}]},
    \\ {"id":"a1","role":"assistant","createdAt":1782920701000,"deviceId":"d","status":"complete",
    \\  "parts":[{"kind":"reasoning","id":"r","text":"Let me look"},
    \\           {"kind":"tool","id":"x","call":{"kind":"exec","command":"ls -la"},"resolved":true,"output":"a\nb"},
    \\           {"kind":"tool","id":"e","call":{"kind":"editFile","path":"src/a.zig"},"resolved":true,
    \\            "diff":{"path":"src/a.zig","oldText":"a\nb\n","newText":"a\nc\n"}},
    \\           {"kind":"text","id":"p","text":"# Done\n\nSome `code` and a [link](https://x.dev).\n\n```zig\nconst x = 1;\n```"}]}
    \\]
;

const Root = struct {
    tv: Entity(view.TranscriptView),

    pub fn deinit(self: *Root, app: *App) void {
        self.tv.release(app);
    }

    pub fn render(self: *Root, _: *zpui.Window, _: *Context(Root)) zpui.Div {
        return zpui.div().sizeFull().child(self.tv);
    }
};

fn makeStore(app: *App) !struct { Entity(model.EngineState), Entity(model.TranscriptStore) } {
    const engine = try app.newWith(model.EngineState, model.EngineState.init, .{ std.testing.io, model.engine_state.Config{
        .port = 1,
        .zeron_path = null,
        .reconnect = false,
    } });
    const store = try app.newWith(model.TranscriptStore, model.TranscriptStore.init, .{ engine, "chat-1" });
    return .{ engine, store };
}

test "transcript view builds rows from a fixture and renders" {
    const app = try App.initTest(std.testing.allocator);
    defer app.deinit();
    const es = try makeStore(app);
    defer es[0].release(app);
    defer es[1].release(app);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try view.parseFixture(arena.allocator(), fixture);
    try view.loadEntries(es[1], entries, app);

    const tv = try app.newWith(view.TranscriptView, view.TranscriptView.initWithStore, .{es[1]});
    defer tv.release(app);
    const Init = struct {
        fn f(t: Entity(view.TranscriptView), _: *zpui.Window, _: *Context(Root)) Root {
            return .{ .tv = t };
        }
    };
    const w = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 1200, .height = 900 } } }, Root, Init.f, .{tv.retain(app)});
    _ = w;
    app.runUntilParked();
    const v = tv.read(app);
    // user bubble, tool group, heading, paragraph, code block.
    try std.testing.expectEqual(@as(usize, 5), v.rowCount());
    try std.testing.expect(v.rowAt(1).kind == .tool_group);
    try std.testing.expectEqualStrings("Thought process · Ran 1 command · edited 1 file", v.rowAt(1).kind.tool_group.summary);
}
