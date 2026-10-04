//! Store logic against an in-process fake engine (the engine client's
//! `test_server`): bootstrap, snapshot list updates (with change detection),
//! transcript deltas incl. desync → resubscribe, queue frames, unary request
//! callbacks, and reconnect after the engine drops the socket.

const std = @import("std");
const json = std.json;
const testing = std.testing;
const zpui = @import("zpui");
const engine_mod = @import("zeron_engine");
const test_server = @import("fake_server.zig");
const model = @import("root.zig");

const App = zpui.App;
const Entity = zpui.Entity;
const Io = std.Io;
const EngineState = model.EngineState;

const io = testing.io;

// ---------------------------------------------------------------------------
// Fake engine
// ---------------------------------------------------------------------------

const Request = struct {
    id: u64,
    method: []u8,
    params: []u8,
    cancel: bool,
    conn: u32,
    /// Arrival order across connections (ids restart per connection).
    seq: u64,
};

/// Accepts connections on a loopback port, answers the bootstrap barrier
/// (`EngineInfo`, `EngineReady`) and `LocalDevice` itself, records every
/// other request, and lets the test push replies/stream items.
const FakeEngine = struct {
    gpa: std.mem.Allocator,
    server: test_server.Server,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    peer: ?*test_server.Peer = null,
    connections: u32 = 0,
    requests: std.ArrayList(Request) = .empty,
    stopping: bool = false,
    capabilities: []const u8 = "[\"message-queue-v1\"]",
    thread: Io.Future(void) = undefined,

    fn start(gpa: std.mem.Allocator) !*FakeEngine {
        const f = try gpa.create(FakeEngine);
        f.* = .{ .gpa = gpa, .server = try test_server.Server.init(io) };
        f.thread = try io.concurrent(run, .{f});
        return f;
    }

    fn port(f: *FakeEngine) u16 {
        return f.server.address().getPort();
    }

    fn stop(f: *FakeEngine) void {
        f.mutex.lockUncancelable(io);
        f.stopping = true;
        if (f.peer) |p| p.stream.shutdown(io, .both) catch {};
        f.mutex.unlock(io);
        // Unblock accept with a throwaway connection.
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(f.port()) };
        if (addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        f.thread.await(io);
        for (f.requests.items) |r| {
            f.gpa.free(r.method);
            f.gpa.free(r.params);
        }
        f.requests.deinit(f.gpa);
        f.server.deinit();
        f.gpa.destroy(f);
    }

    fn run(f: *FakeEngine) void {
        while (true) {
            const peer = f.server.accept(f.gpa) catch return;
            f.mutex.lockUncancelable(io);
            if (f.stopping) {
                f.mutex.unlock(io);
                peer.deinit();
                return;
            }
            f.peer = peer;
            f.connections += 1;
            const conn = f.connections;
            f.cond.broadcast(io);
            f.mutex.unlock(io);
            f.serve(peer, conn);
            f.mutex.lockUncancelable(io);
            if (f.peer == peer) f.peer = null;
            const stopping = f.stopping;
            f.mutex.unlock(io);
            peer.deinit();
            if (stopping) return;
        }
    }

    fn serve(f: *FakeEngine, peer: *test_server.Peer, conn: u32) void {
        while (true) {
            const text = peer.recvText() catch return;
            const parsed = json.parseFromSlice(json.Value, f.gpa, text, .{}) catch continue;
            defer parsed.deinit();
            const obj = parsed.value.object;
            const id: u64 = @intCast(obj.get("id").?.integer);
            const method = if (obj.get("method")) |m| m.string else "";
            const cancel = if (obj.get("cancel")) |c| c.bool else false;
            if (std.mem.eql(u8, method, "EngineInfo")) {
                f.sendFmt("{{\"id\":{d},\"ok\":{{\"deviceId\":\"dev-local\",\"workspaceScope\":\"local\",\"capabilities\":{s}}}}}", .{ id, f.capabilities });
                continue;
            }
            if (std.mem.eql(u8, method, "EngineReady")) {
                f.sendFmt("{{\"id\":{d},\"ok\":{{}}}}", .{id});
                continue;
            }
            if (std.mem.eql(u8, method, "LocalDevice")) {
                f.sendFmt("{{\"id\":{d},\"ok\":{{\"deviceId\":\"dev-local\"}}}}", .{id});
                continue;
            }
            const params = if (obj.get("params")) |p| json.Stringify.valueAlloc(f.gpa, p, .{}) catch continue else f.gpa.dupe(u8, "null") catch continue;
            f.mutex.lockUncancelable(io);
            f.requests.append(f.gpa, .{
                .id = id,
                .method = f.gpa.dupe(u8, method) catch unreachable,
                .params = params,
                .cancel = cancel,
                .conn = conn,
                .seq = f.requests.items.len + 1,
            }) catch unreachable;
            f.cond.broadcast(io);
            f.mutex.unlock(io);
        }
    }

    fn sendFmt(f: *FakeEngine, comptime fmt: []const u8, args: anytype) void {
        var buf: [64 * 1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const p = f.peer orelse return;
        p.sendText(text) catch {};
    }

    /// The first request for `method` (optionally with params containing
    /// `needle`) that arrived after request `after` (a `seq`), waiting up to ~5s.
    fn waitRequest(f: *FakeEngine, method: []const u8, needle: ?[]const u8, after: u64) !Request {
        const deadline = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(5));
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        while (true) {
            for (f.requests.items) |r| {
                if (r.seq <= after or r.cancel) continue;
                if (!std.mem.eql(u8, r.method, method)) continue;
                if (needle) |n| if (std.mem.find(u8, r.params, n) == null) continue;
                return r;
            }
            if (Io.Timestamp.now(io, .awake).nanoseconds > deadline.nanoseconds) return error.Timeout;
            f.cond.waitTimeout(io, &f.mutex, .{ .duration = .{ .raw = .fromMilliseconds(50), .clock = .awake } }) catch {};
        }
    }

    fn sawCancel(f: *FakeEngine, id: u64) bool {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        for (f.requests.items) |r| if (r.cancel and r.id == id) return true;
        return false;
    }

    fn item(f: *FakeEngine, id: u64, value_json: []const u8) void {
        f.sendFmt("{{\"id\":{d},\"item\":{s}}}", .{ id, value_json });
    }

    fn ok(f: *FakeEngine, id: u64, value_json: []const u8) void {
        f.sendFmt("{{\"id\":{d},\"ok\":{s}}}", .{ id, value_json });
    }

    fn fail(f: *FakeEngine, id: u64, message: []const u8) void {
        f.sendFmt("{{\"id\":{d},\"err\":\"{s}\"}}", .{ id, message });
    }

    fn done(f: *FakeEngine, id: u64) void {
        f.sendFmt("{{\"id\":{d},\"done\":true}}", .{id});
    }

    /// Simulate the engine dying: close the socket.
    fn dropConnection(f: *FakeEngine) void {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        if (f.peer) |p| p.stream.shutdown(io, .both) catch {};
    }

    fn connectionCount(f: *FakeEngine) u32 {
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        return f.connections;
    }
};

// ---------------------------------------------------------------------------
// Driving helpers
// ---------------------------------------------------------------------------

/// Pump the app (test dispatcher + engine wakeups) until `cond(ctx)` holds.
fn pumpUntil(app: *App, engine: Entity(EngineState), ctx: anytype, comptime cond: fn (@TypeOf(ctx), *App) bool) !void {
    const deadline = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(5));
    while (true) {
        app.runUntilParked();
        _ = EngineState.pollWake(engine, app);
        app.runUntilParked();
        if (cond(ctx, app)) return;
        if (Io.Timestamp.now(io, .awake).nanoseconds > deadline.nanoseconds) return error.Timeout;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
}

fn isReady(engine: Entity(EngineState), app: *App) bool {
    return engine.read(app).isReady();
}

const Harness = struct {
    app: *App,
    fake: *FakeEngine,
    state: Entity(model.AppState),

    fn init() !Harness {
        const app = try App.initTest(testing.allocator);
        errdefer app.deinit();
        const fake = try FakeEngine.start(testing.allocator);
        errdefer fake.stop();
        const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{
            .port = fake.port(),
            .zeron_path = null,
            .wake_mode = .poll,
        } });
        var h: Harness = .{ .app = app, .fake = fake, .state = state };
        try pumpUntil(app, h.engine(), h.engine(), isReady);
        return h;
    }

    fn deinit(h: *Harness) void {
        h.state.release(h.app);
        h.app.runUntilParked();
        h.app.deinit();
        h.fake.stop();
    }

    fn engine(h: *const Harness) Entity(EngineState) {
        return h.state.read(h.app).engine;
    }

    fn workspace(h: *const Harness) Entity(model.WorkspaceStore) {
        return h.state.read(h.app).workspace;
    }

    fn pump(h: *Harness, ctx: anytype, comptime cond: fn (@TypeOf(ctx), *App) bool) !void {
        try pumpUntil(h.app, h.engine(), ctx, cond);
    }
};

const Counter = struct {
    chats: u32 = 0,
    sessions: u32 = 0,
    notifies: u32 = 0,

    fn onChats(self: *Counter, _: Entity(model.WorkspaceStore), _: *const model.workspace.ChatsChanged, _: *App) void {
        self.chats += 1;
    }
    fn onSessions(self: *Counter, _: Entity(model.WorkspaceStore), _: *const model.workspace.SessionsChanged, _: *App) void {
        self.sessions += 1;
    }
    fn onNotify(self: *Counter, _: Entity(model.WorkspaceStore), _: *App) void {
        self.notifies += 1;
    }
};

const chat_a =
    \\{"id":"chat-a","deviceId":"dev-local","archived":false,"createdAt":"2026-01-01T00:00:00Z","lastMessageAt":"2026-01-02T00:00:00Z","spaceId":"s1"}
;
const chat_b =
    \\{"id":"chat-b","deviceId":"dev-local","archived":false,"createdAt":"2026-01-01T00:00:00Z","lastMessageAt":"2026-01-03T00:00:00.5+00:00","spaceId":"s1"}
;

// ---------------------------------------------------------------------------

test "bootstrap: engine info, standing watches, list updates with change detection" {
    var h = try Harness.init();
    defer h.deinit();
    const app = h.app;
    const engine = h.engine().read(app);
    try testing.expectEqual(engine_mod.protocol.WorkspaceScope.local, engine.workspaceScope().?);
    try testing.expectEqualStrings("dev-local", engine.deviceId().?);
    try testing.expect(engine.supports("message-queue-v1"));
    try testing.expectEqual(model.view.GatePhase.ready, h.state.read(app).gate(app));

    var counter: Counter = .{};
    var s1 = try app.subscribe(h.workspace(), &counter, Counter.onChats);
    defer s1.deinit();
    var s2 = try app.subscribe(h.workspace(), &counter, Counter.onSessions);
    defer s2.deinit();
    var s3 = try app.observe(h.workspace(), &counter, Counter.onNotify);
    defer s3.deinit();

    const chats = try h.fake.waitRequest("WatchChats", null, 0);
    const sessions = try h.fake.waitRequest("WatchSessions", null, 0);
    const spaces = try h.fake.waitRequest("WatchSpaces", null, 0);
    _ = try h.fake.waitRequest("WatchDevices", null, 0);
    _ = try h.fake.waitRequest("WatchSidebarPreferences", null, 0);
    _ = try h.fake.waitRequest("AuthStatus", null, 0);
    _ = try h.fake.waitRequest("WatchConnectivity", null, 0);
    _ = try h.fake.waitRequest("ListHarnesses", null, 0);

    h.fake.item(spaces.id, "[{\"id\":\"s1\",\"deviceId\":\"dev-local\",\"path\":\"/home/u/zeron\",\"createdAt\":\"2026-01-01T00:00:00Z\"}]");
    h.fake.item(chats.id, "[" ++ chat_a ++ "," ++ chat_b ++ "]");
    try h.pump(&counter, struct {
        fn f(c: *Counter, _: *App) bool {
            return c.chats >= 1;
        }
    }.f);
    {
        const ws = h.workspace().read(app);
        try testing.expect(ws.chats_synced);
        try testing.expectEqual(@as(usize, 2), ws.chats().len);
        // Sorted by recency: chat-b (Jan 3) first.
        try testing.expectEqualStrings("chat-b", ws.chats()[0].id);
        try testing.expectEqualStrings("s1", ws.selected_space.?); // healed onto the first project
        const rows = try ws.sidebarChats(testing.allocator, model.Timestamp.fromUnixMillis(1_767_500_000_000), "s1");
        defer testing.allocator.free(rows);
        try testing.expectEqual(@as(usize, 2), rows.len);
    }

    // A re-sent identical list is not a change.
    const notifies_before = counter.notifies;
    h.fake.item(chats.id, "[" ++ chat_b ++ "," ++ chat_a ++ "]");
    h.fake.item(sessions.id, "[]");
    try h.pump(&counter, struct {
        fn f(c: *Counter, _: *App) bool {
            return c.sessions >= 1;
        }
    }.f);
    try testing.expectEqual(@as(u32, 1), counter.chats);

    // Session heartbeat: only updatedAt moves (both fresh) → no SessionsChanged.
    const ws_entity = h.workspace();
    ws_entity.update(app, struct {
        fn f(ws: *model.WorkspaceStore, _: *zpui.Context(model.WorkspaceStore)) void {
            ws.now_override = model.time.parse("2026-01-05T00:00:10Z").?;
        }
    }.f, .{});
    h.fake.item(sessions.id, "[{\"chatId\":\"chat-a\",\"deviceId\":\"dev-local\",\"status\":\"working\",\"updatedAt\":\"2026-01-05T00:00:00Z\"}]");
    try h.pump(&counter, struct {
        fn f(c: *Counter, _: *App) bool {
            return c.sessions >= 2;
        }
    }.f);
    h.fake.item(sessions.id, "[{\"chatId\":\"chat-a\",\"deviceId\":\"dev-local\",\"status\":\"working\",\"updatedAt\":\"2026-01-05T00:00:05Z\"}]");
    h.fake.item(chats.id, "[" ++ chat_a ++ "]");
    try h.pump(&counter, struct {
        fn f(c: *Counter, _: *App) bool {
            return c.chats >= 2;
        }
    }.f);
    try testing.expectEqual(@as(u32, 2), counter.sessions);
    try testing.expect(counter.notifies > notifies_before);
    const ws = h.workspace().read(app);
    try testing.expectEqual(model.view.Indicator.working, ws.indicatorFor("chat-a", ws.now_override.?));
    try testing.expectEqual(model.view.Indicator.none, ws.indicatorFor("chat-a", model.time.parse("2026-01-05T00:01:00Z").?));
}

const TranscriptCounter = struct {
    changed: u32 = 0,
    text: u32 = 0,
    fn onChanged(self: *TranscriptCounter, _: Entity(model.TranscriptStore), _: *const model.transcript_store.Changed, _: *App) void {
        self.changed += 1;
    }
    fn onText(self: *TranscriptCounter, _: Entity(model.TranscriptStore), _: *const model.transcript_store.TextChanged, _: *App) void {
        self.text += 1;
    }
};

fn entryJson(comptime id: []const u8, comptime text: []const u8) []const u8 {
    return "{\"id\":\"" ++ id ++ "\",\"role\":\"assistant\",\"createdAt\":1,\"deviceId\":\"d\",\"parts\":[{\"kind\":\"text\",\"id\":\"p1\",\"text\":\"" ++ text ++ "\"}]}";
}

test "transcript: opening tail, deltas, text appends, desync → resubscribe, queue frames" {
    var h = try Harness.init();
    defer h.deinit();
    const app = h.app;
    const chats = try h.fake.waitRequest("WatchChats", null, 0);
    h.fake.item(chats.id, "[" ++ chat_a ++ "]");
    try h.pump(h.workspace(), struct {
        fn f(ws: Entity(model.WorkspaceStore), a: *App) bool {
            return ws.read(a).chats().len == 1;
        }
    }.f);

    h.workspace().update(app, model.WorkspaceStore.selectChat, .{"chat-a"});
    app.runUntilParked();
    const t = h.state.read(app).transcript.?;
    try testing.expect(h.state.read(app).queue != null);
    var counter: TranscriptCounter = .{};
    var s1 = try app.subscribe(t, &counter, TranscriptCounter.onChanged);
    defer s1.deinit();
    var s2 = try app.subscribe(t, &counter, TranscriptCounter.onText);
    defer s2.deinit();

    _ = try h.fake.waitRequest("FocusChat", "chat-a", 0);
    const watch = try h.fake.waitRequest("WatchDocMessages", "\"openingTail\":true", 0);
    const queue = try h.fake.waitRequest("WatchQueue", "chat-a", 0);

    // Provisional tail, then the full reset.
    h.fake.item(watch.id, "{\"reset\":[" ++ comptime entryJson("e2", "tail") ++ "],\"historyPending\":true}");
    try h.pump(t, struct {
        fn f(s: Entity(model.TranscriptStore), a: *App) bool {
            return s.read(a).len() == 1;
        }
    }.f);
    try testing.expect(!t.read(app).replayed);
    h.fake.item(watch.id, "{\"reset\":[" ++ comptime entryJson("e1", "hello") ++ "," ++ entryJson("e2", "tail") ++ "],\"contextUsage\":{\"tokens\":10,\"window\":100}}");
    try h.pump(t, struct {
        fn f(s: Entity(model.TranscriptStore), a: *App) bool {
            return s.read(a).len() == 2;
        }
    }.f);
    try testing.expect(t.read(app).replayed);
    try testing.expectEqual(@as(?u64, 10), t.read(app).context_usage.?.tokens);
    // A late provisional preview never replaces the complete view.
    h.fake.item(watch.id, "{\"reset\":[],\"historyPending\":true}");
    // Streaming text append: TextChanged, not Changed.
    const changed_before = counter.changed;
    h.fake.item(watch.id, "{\"upsert\":[],\"append\":[{\"entry\":\"e2\",\"part\":\"p1\",\"text\":\" more\",\"len\":9}],\"remove\":[],\"count\":2,\"contextUsage\":{\"tokens\":10,\"window\":100}}");
    try h.pump(&counter, struct {
        fn f(c: *TranscriptCounter, _: *App) bool {
            return c.text >= 1;
        }
    }.f);
    try testing.expectEqual(changed_before, counter.changed);
    try testing.expectEqual(@as(usize, 2), t.read(app).len());
    try testing.expectEqualStrings("tail more", t.read(app).entry(1).parts[0].text.text);

    // A delta with a wrong count desyncs → immediate resubscribe (cancel + new watch).
    h.fake.item(watch.id, "{\"upsert\":[{\"after\":\"e2\",\"entry\":" ++ comptime entryJson("e3", "x") ++ "}],\"append\":[],\"remove\":[],\"count\":7}");
    try h.pump(t, struct {
        fn f(s: Entity(model.TranscriptStore), a: *App) bool {
            return s.read(a).desyncs == 1;
        }
    }.f);
    const again = try h.fake.waitRequest("WatchDocMessages", "chat-a", watch.seq);
    try testing.expect(again.id > watch.id);
    try testing.expect(h.fake.sawCancel(watch.id));
    try testing.expectEqual(@as(u32, 1), t.read(app).desyncs);
    // The fresh stream's reset heals the copy.
    h.fake.item(again.id, "{\"reset\":[" ++ comptime entryJson("e1", "hello") ++ "," ++ entryJson("e2", "tail more") ++ "," ++ entryJson("e3", "x") ++ "]}");
    // (The failed delta already upserted e3; the reset also clears contextUsage.)
    try h.pump(t, struct {
        fn f(s: Entity(model.TranscriptStore), a: *App) bool {
            return s.read(a).len() == 3 and s.read(a).context_usage == null;
        }
    }.f);
    try testing.expectEqualStrings("tail more", t.read(app).entry(1).parts[0].text.text);

    // Queue frames; a queued id supersedes its optimistic echo.
    t.update(app, model.TranscriptStore.pushEcho, .{engine_mod.protocol.SessionMessageEntry{
        .id = "m-1",
        .role = .user,
        .parts = &.{},
        .createdAt = 5,
        .deviceId = "dev-local",
    }}) catch unreachable;
    try testing.expectEqual(@as(usize, 1), t.read(app).pendingEchoes().len);
    h.fake.item(queue.id, "{\"items\":[{\"id\":\"m-1\",\"text\":\"later\",\"issuedBy\":\"dev-local\",\"issuedAt\":5}]}");
    const q = h.state.read(app).queue.?;
    try h.pump(q, struct {
        fn f(s: Entity(model.QueueStore), a: *App) bool {
            return s.read(a).items().len == 1;
        }
    }.f);
    try testing.expectEqualStrings("later", q.read(app).items()[0].text);
    try testing.expectEqual(@as(usize, 0), t.read(app).pendingEchoes().len);

    // Stream end → resubscribe after the 2s retry delay.
    h.fake.done(again.id);
    try h.pump(t, struct {
        fn f(s: Entity(model.TranscriptStore), a: *App) bool {
            return !s.read(a).watch.isOpen();
        }
    }.f);
    app.advanceClock(2 * std.time.ns_per_s + 1);
    const third = try h.fake.waitRequest("WatchDocMessages", "chat-a", again.seq);
    try testing.expect(third.id > again.id);
}

const Probe = struct {
    calls: u32 = 0,
    last_ok: bool = false,
    pub fn onReply(self: *Probe, result: model.engine_state.CallResult, _: *zpui.Context(Probe)) void {
        self.calls += 1;
        self.last_ok = result == .ok;
    }
};

test "unary requests deliver callbacks; engine drop → reconnect and resubscribe" {
    var h = try Harness.init();
    defer h.deinit();
    const app = h.app;

    const probe = try app.new(Probe, .{});
    defer probe.release(app);
    try EngineState.request(h.engine(), app, Probe, probe.entityId(), .SyncStatus, {}, Probe.onReply);
    const req = try h.fake.waitRequest("SyncStatus", null, 0);
    h.fake.ok(req.id, "{\"deviceId\":\"dev-local\"}");
    try h.pump(probe, struct {
        fn f(p: Entity(Probe), a: *App) bool {
            return p.read(a).calls == 1;
        }
    }.f);
    try testing.expect(probe.read(app).last_ok);
    try EngineState.request(h.engine(), app, Probe, probe.entityId(), .SyncStatus, {}, Probe.onReply);
    const req2 = try h.fake.waitRequest("SyncStatus", null, req.seq);
    h.fake.fail(req2.id, "boom");
    try h.pump(probe, struct {
        fn f(p: Entity(Probe), a: *App) bool {
            return p.read(a).calls == 2;
        }
    }.f);
    try testing.expect(!probe.read(app).last_ok);

    // Drop the socket: the state flips to connecting and stores close watches.
    const chats1 = try h.fake.waitRequest("WatchChats", null, 0);
    h.fake.dropConnection();
    try h.pump(h.engine(), struct {
        fn f(e: Entity(EngineState), a: *App) bool {
            return e.read(a).connection == .connecting and e.read(a).conn == null;
        }
    }.f);
    try testing.expect(!h.workspace().read(app).watch_chats.isOpen());
    try testing.expectEqual(model.view.GatePhase.loading, h.state.read(app).gate(app));
    // Backoff (500ms) elapses → reconnect on a fresh socket → watches reopen.
    app.advanceClock(600 * std.time.ns_per_ms);
    try h.pump(h.engine(), isReady);
    try testing.expectEqual(@as(u32, 2), h.fake.connectionCount());
    try testing.expectEqual(@as(u64, 2), h.engine().read(app).generation);
    const chats2 = try h.fake.waitRequest("WatchChats", null, chats1.seq);
    try testing.expectEqual(@as(u32, 2), chats2.conn);
    h.fake.item(chats2.id, "[" ++ chat_b ++ "]");
    try h.pump(h.workspace(), struct {
        fn f(ws: Entity(model.WorkspaceStore), a: *App) bool {
            const c = ws.read(a).chats();
            return c.len == 1 and std.mem.eql(u8, c[0].id, "chat-b");
        }
    }.f);
}

test "connect failure without an engine reports failed and retries" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    // A port nobody listens on (bind, then close).
    var probe_server = try test_server.Server.init(io);
    const port = probe_server.address().getPort();
    probe_server.deinit();
    const engine = try app.newWith(EngineState, EngineState.init, .{ io, model.engine_state.Config{
        .port = port,
        .zeron_path = null,
        .wake_mode = .poll,
    } });
    defer engine.release(app);
    app.runUntilParked();
    try testing.expect(engine.read(app).connection == .failed);
    try testing.expectEqualStrings("EngineUnavailable", engine.read(app).connection.failed);
    const gate = model.view.gatePhase(engine.read(app).connection, null, null);
    try testing.expect(gate == .failed);
    // A retry is scheduled with backoff; it fails again the same way.
    app.advanceClock(600 * std.time.ns_per_ms);
    try testing.expect(engine.read(app).connection == .failed);
    try testing.expectEqual(@as(u32, 2), engine.read(app).attempt);
}

test "settings store: debounced and immediate saves" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer testing.allocator.free(dir);
    try model.settings_store.init(app, io, dir);
    const Set = struct {
        fn collapse(v: bool, s: *model.UiSettings, _: std.mem.Allocator) void {
            s.sidebarCollapsed = v;
        }
    };
    try testing.expect(model.settings_store.update(app, .debounced, true, Set.collapse));
    try testing.expect(!model.settings_store.update(app, .debounced, true, Set.collapse)); // no-op
    try testing.expect(model.settings_store.current(app).?.sidebarCollapsed);
    // Not on disk until the debounce elapses.
    {
        var l = try model.settings.load(testing.allocator, io, dir);
        defer l.deinit();
        try testing.expect(!l.value.sidebarCollapsed);
    }
    app.advanceClock(model.settings.save_debounce_ms * std.time.ns_per_ms);
    {
        var l = try model.settings.load(testing.allocator, io, dir);
        defer l.deinit();
        try testing.expect(l.value.sidebarCollapsed);
    }
    _ = model.settings_store.update(app, .immediate, false, Set.collapse);
    var l = try model.settings.load(testing.allocator, io, dir);
    defer l.deinit();
    try testing.expect(!l.value.sidebarCollapsed);
}
