//! Headless `TranscriptView` tests (zpui test platform, offline store).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine_mod = @import("zeron_engine");
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
        .autoconnect = false,
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

test "compact mode folds the work into one header that opens in place" {
    const app = try App.initTest(std.testing.allocator);
    defer app.deinit();
    const es = try makeStore(app);
    defer es[0].release(app);
    defer es[1].release(app);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try view.parseFixture(arena.allocator(), fixture);
    entries[1].durationMs = 12_400;
    try view.loadEntries(es[1], entries, app);

    const tv = try app.newWith(view.TranscriptView, view.TranscriptView.initWithStore, .{es[1]});
    defer tv.release(app);
    const Set = struct {
        fn on(t: *view.TranscriptView, _: *Context(view.TranscriptView)) void {
            t.setCompactMode(true);
        }
        fn toggle(t: *view.TranscriptView, cx: *Context(view.TranscriptView)) void {
            // Reduced motion: the body mounts / unmounts instantly.
            t.toggleCompactFold(t.rowAt(1).key, true, cx);
        }
    };
    tv.update(app, Set.on, .{});
    const Init = struct {
        fn f(t: Entity(view.TranscriptView), _: *zpui.Window, _: *Context(Root)) Root {
            return .{ .tv = t };
        }
    };
    _ = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 1200, .height = 900 } } }, Root, Init.f, .{tv.retain(app)});
    app.runUntilParked();
    // user bubble, the work header, then the reply's three blocks.
    try std.testing.expectEqual(@as(usize, 5), tv.read(app).rowCount());
    const hdr = tv.read(app).rowAt(1).kind.tool_group;
    try std.testing.expect(hdr.compact_shell);
    try std.testing.expectEqual(@as(?i64, 12), hdr.worked_secs);
    tv.update(app, Set.toggle, .{});
    app.runUntilParked();
    // Open: the ordinary tool group for the work parts sits under the header.
    try std.testing.expectEqual(@as(usize, 6), tv.read(app).rowCount());
    try std.testing.expect(tv.read(app).rowAt(2).compact_fold != null);
    tv.update(app, Set.toggle, .{});
    app.runUntilParked();
    try std.testing.expectEqual(@as(usize, 5), tv.read(app).rowCount());
}

const stream_fixture =
    \\[
    \\ {"id":"u1","role":"user","createdAt":1782920700000,"deviceId":"d","status":"complete",
    \\  "parts":[{"kind":"text","id":"t","text":"Tell me a story"}]},
    \\ {"id":"a1","role":"assistant","createdAt":1782920701000,"deviceId":"d","status":"streaming",
    \\  "parts":[{"kind":"text","id":"p","text":"Once"}]}
    \\]
;

const StreamRun = struct { draws: usize, commits: usize };

/// Stream a reply for 4 s of 60 Hz vsyncs with a doc commit every ~117 ms
/// (the engine's cadence) and count the frames drawn.
fn streamFor4s(reduced: bool) !StreamRun {
    const app = try App.initTest(std.testing.allocator);
    defer app.deinit();
    const es = try makeStore(app);
    defer es[0].release(app);
    defer es[1].release(app);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try view.parseFixture(arena.allocator(), stream_fixture);
    try view.loadEntries(es[1], entries, app);

    const tv = try app.newWith(view.TranscriptView, view.TranscriptView.initWithStore, .{es[1]});
    defer tv.release(app);
    const Init = struct {
        fn f(t: Entity(view.TranscriptView), _: *zpui.Window, _: *Context(Root)) Root {
            return .{ .tv = t };
        }
    };
    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 1200, .height = 900 } } }, Root, Init.f, .{tv.retain(app)});
    const w = handle.window(app).?;
    w.prefers_reduced_motion = reduced;
    const tw = zpui.core.test_platform.TestWindow.of(w.platform_window);
    app.runUntilParked();

    const gpa = std.testing.allocator;
    const vsync_ns: u64 = 16_666_667;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "Once");
    // Let the entrance fade settle, then count.
    for (0..40) |_| {
        app.advanceClock(vsync_ns);
        if (tw.frame_requested) tw.frame(false);
    }
    const before = tw.present_count;
    var commits: usize = 0;
    for (0..240) |i| {
        app.advanceClock(vsync_ns);
        if (i % 7 == 0) {
            const start = text.items.len;
            try text.appendSlice(gpa, " upon a time, a word or two more.");
            const ap = [_]engine_mod.protocol.TextAppend{.{ .entry = "a1", .part = "p", .text = text.items[start..], .len = text.items.len }};
            view.applyFrame(es[1], .{ .delta = .{ .append = &ap, .count = 2 } }, app);
            commits += 1;
        }
        if (tw.frame_requested) tw.frame(false);
    }
    return .{ .draws = tw.present_count - before, .commits = commits };
}

test "a streaming reply redraws at the pulse and commit cadence, not every vsync" {
    // docs/BENCHMARKS.md: the Working trailer's spinner and the streaming veil
    // asked for a frame on every vsync, so a 4 s reply drew a frame per vsync
    // (240 here). They now share the pulse clock (veil 30 Hz, spinner 15 Hz),
    // so the window draws on pulse ticks plus commits that miss one.
    const run = try streamFor4s(false);
    try std.testing.expect(run.draws >= run.commits);
    try std.testing.expect(run.draws <= 4 * 30 + run.commits + 4);
    try std.testing.expect(run.draws < 200);
}

test "a streaming reply under reduced motion draws once per commit" {
    // No veil, the spinner at rest: only the commits redraw.
    const run = try streamFor4s(true);
    try std.testing.expect(run.draws >= run.commits);
    try std.testing.expect(run.draws <= run.commits + 4);
}
