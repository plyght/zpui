//! Live check against the real engine binary, behind `-Dzeron-live=PATH`
//! (e.g. `zig build zeron-model-test -Dzeron-live=/home/user/zeron/target/debug/zeron`):
//! spawns `zeron headless` with a temp `ZERON_DATA_DIR` + `ZERON_IPC_PORT`
//! through `EngineState`, creates a chat with `Mutate{createChat}`, runs a
//! mock-harness turn with `QueueCommand`, and asserts the selected chat's
//! `TranscriptStore` receives the streamed messages.

const std = @import("std");
const testing = std.testing;
const options = @import("model_options");
const zpui = @import("zpui");
const engine_mod = @import("zeron_engine");
const model = @import("root.zig");

const App = zpui.App;
const Entity = zpui.Entity;
const Io = std.Io;
const protocol = engine_mod.protocol;
const EngineState = model.EngineState;
const io = testing.io;

fn pumpUntil(app: *App, engine: Entity(EngineState), seconds: i64, ctx: anytype, comptime cond: fn (@TypeOf(ctx), *App) bool) !void {
    const deadline = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(seconds));
    while (true) {
        app.runUntilParked();
        _ = EngineState.pollWake(engine, app);
        app.runUntilParked();
        if (cond(ctx, app)) return;
        if (Io.Timestamp.now(io, .awake).nanoseconds > deadline.nanoseconds) return error.Timeout;
        io.sleep(.fromMilliseconds(2), .awake) catch {};
    }
}

const Reply = struct {
    done: bool = false,
    ok: bool = false,
    pub fn on(self: *Reply, result: model.engine_state.CallResult, _: *zpui.Context(Reply)) void {
        self.done = true;
        self.ok = result == .ok;
        if (result == .err) std.debug.print("live: call failed: {s}\n", .{result.err.message});
    }
};

const Events = struct {
    changed: u32 = 0,
    text: u32 = 0,
    fn onChanged(self: *Events, _: Entity(model.TranscriptStore), _: *const model.transcript_store.Changed, _: *App) void {
        self.changed += 1;
    }
    fn onText(self: *Events, _: Entity(model.TranscriptStore), _: *const model.transcript_store.TextChanged, _: *App) void {
        self.text += 1;
    }
};

test "live: zeron headless — create chat, mock turn, transcript streams" {
    const zeron = options.live_zeron orelse return error.SkipZigTest;
    Io.Dir.cwd().access(io, zeron, .{}) catch return error.SkipZigTest;
    const gpa = testing.allocator;

    // A free loopback port (bind, read, release).
    const port = blk: {
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var server = try addr.listen(io, .{ .reuse_address = true });
        defer server.deinit(io);
        break :blk server.socket.address.getPort();
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const data_dir = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/tmp/{s}", .{ cwd, &tmp.sub_path });
    defer gpa.free(data_dir);

    var env = try testing.environ.createMap(gpa);
    defer env.deinit();
    var port_buf: [8]u8 = undefined;
    try env.put("ZERON_DATA_DIR", data_dir);
    try env.put("ZERON_IPC_PORT", try std.fmt.bufPrint(&port_buf, "{d}", .{port}));
    // Pace the mock so its reply streams as several text appends.
    try env.put("ZERON_MOCK_DELAY_MS", "5");
    try env.put("ZERON_MOCK_CHARS", "16");

    const app = try App.initTest(gpa);
    defer app.deinit();
    const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{
        .port = port,
        .zeron_path = zeron,
        .spawn_environ = &env,
        .wake_mode = .poll,
        .reconnect = false,
    } });
    defer {
        state.release(app);
        app.runUntilParked();
    }
    const engine = state.read(app).engine;
    try pumpUntil(app, engine, 60, engine, struct {
        fn f(e: Entity(EngineState), a: *App) bool {
            return e.read(a).isReady() or e.read(a).connection == .failed;
        }
    }.f);
    try testing.expect(engine.read(app).isReady());
    try testing.expect(engine.read(app).config.zeron_path != null);

    // Mutate{createChat} for a mock-harness chat.
    const reply = try app.new(Reply, .{});
    defer reply.release(app);
    try EngineState.request(engine, app, Reply, reply.entityId(), .Mutate, protocol.Mutate{ .createChat = .{
        .chatId = "live-chat-1",
        .deviceId = engine.read(app).deviceId().?,
        .config = .{ .harness = .mock, .model = "mock-1", .sandbox = .@"workspace-write" },
        .cwd = data_dir,
    } }, Reply.on);
    try pumpUntil(app, engine, 20, reply, struct {
        fn f(r: Entity(Reply), a: *App) bool {
            return r.read(a).done;
        }
    }.f);
    try testing.expect(reply.read(app).ok);

    const ws = state.read(app).workspace;
    try pumpUntil(app, engine, 20, ws, struct {
        fn f(w: Entity(model.WorkspaceStore), a: *App) bool {
            return w.read(a).chat("live-chat-1") != null;
        }
    }.f);

    // Selecting the chat opens its TranscriptStore (+ queue) watch.
    ws.update(app, model.WorkspaceStore.selectChat, .{"live-chat-1"});
    app.runUntilParked();
    const transcript = state.read(app).transcript.?;
    var events: Events = .{};
    var s1 = try app.subscribe(transcript, &events, Events.onChanged);
    defer s1.deinit();
    var s2 = try app.subscribe(transcript, &events, Events.onText);
    defer s2.deinit();
    try pumpUntil(app, engine, 20, transcript, struct {
        fn f(t: Entity(model.TranscriptStore), a: *App) bool {
            return t.read(a).replayed;
        }
    }.f);

    // A mock turn through the durable command ledger.
    try transcript.update(app, model.TranscriptStore.queueCommand, .{protocol.SessionCommandPayload{ .run = .{
        .messageId = "m-live-1",
        .request = .{
            .prompt = "hello from zig",
            .harness = .mock,
            .model = "mock-1",
            .cwd = data_dir,
            .sandbox = .@"workspace-write",
        },
    } }});
    try pumpUntil(app, engine, 60, transcript, struct {
        fn f(t: Entity(model.TranscriptStore), a: *App) bool {
            const s = t.read(a);
            if (s.len() < 2) return false;
            const last = s.entry(s.len() - 1);
            return last.role == .assistant and last.status == .complete;
        }
    }.f);
    const t = transcript.read(app);
    try testing.expectEqualStrings("m-live-1", t.entry(0).id);
    try testing.expectEqual(protocol.MessageRole.user, t.entry(0).role);
    var saw_text = false;
    for (t.entry(t.len() - 1).parts) |p| {
        if (p == .text and p.text.text.len > 0) saw_text = true;
    }
    try testing.expect(saw_text);
    // Streamed: several frames arrived (structure changes + text appends).
    try testing.expect(events.changed + events.text >= 3);
    std.debug.print("live: {d} rows, {d} structural + {d} text-append frames, {d} desyncs\n", .{
        t.len(), events.changed, events.text, t.desyncs,
    });
}
