//! The engine the client spawns: started on demand (a fake `zeron-engine` script that
//! records its argv and exits on SIGTERM, plus a loopback fake engine that starts
//! answering once the script ran), stopped by the quit teardown on zpui's TestPlatform,
//! never spawned when an engine already answers, and never spawned next to an engine
//! that holds the data dir lock (waited for instead).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine_mod = @import("zeron_engine");
const fake_server = model.fake_server;

const testing = std.testing;
const io = testing.io;
const Io = std.Io;
const App = zpui.App;
const Entity = zpui.Entity;
const EngineState = model.EngineState;

const fake_engine_script =
    \\#!/bin/sh
    \\echo "$@" > "$ZERON_DATA_DIR/args"
    \\trap 'echo term > "$ZERON_DATA_DIR/stopped"; exit 0' TERM
    \\echo $$ > "$ZERON_DATA_DIR/spawned.pid"
    \\while :; do sleep 0.05; done
    \\
;

/// A loopback engine on a fixed port: answers `EngineInfo` / `EngineReady` and `{}` to
/// everything else, serving one connection. `wait_for` delays listening until that file
/// exists (the spawned script's pid file).
const MiniEngine = struct {
    port: u16,
    dir: Io.Dir,
    wait_for: ?[]const u8 = null,
    listening: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    future: Io.Future(anyerror!void) = undefined,

    fn start(m: *MiniEngine) !void {
        m.future = try io.concurrent(run, .{m});
    }

    fn finish(m: *MiniEngine) !void {
        m.stop.store(true, .release);
        // Unblock a pending accept.
        if (m.listening.load(.acquire)) {
            const addr: Io.net.IpAddress = .{ .ip4 = .loopback(m.port) };
            if (addr.connect(io, .{ .mode = .stream })) |s| s.close(io) else |_| {}
        }
        try m.future.await(io);
    }

    fn run(m: *MiniEngine) anyerror!void {
        if (m.wait_for) |name| while (true) {
            if (m.stop.load(.acquire)) return;
            if (m.dir.access(io, name, .{})) |_| break else |_| {}
            try io.sleep(.fromMilliseconds(10), .awake);
        };
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(m.port) };
        var server: fake_server.Server = .{ .io = io, .listener = try addr.listen(io, .{ .reuse_address = true }) };
        defer server.deinit();
        m.listening.store(true, .release);
        const peer = server.accept(testing.allocator) catch return;
        defer peer.deinit();
        if (m.stop.load(.acquire)) return;
        while (true) {
            var method: [64]u8 = undefined;
            const req = peer.recvRequest(&method) catch return;
            if (req.cancel) continue;
            var buf: [256]u8 = undefined;
            const name = method[0..req.method_len];
            const reply = if (std.mem.eql(u8, name, "EngineInfo"))
                try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"ok\":{{\"deviceId\":\"dev-local\",\"workspaceScope\":\"local\",\"capabilities\":[]}}}}", .{req.id})
            else
                try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"ok\":{{}}}}", .{req.id});
            peer.sendText(reply) catch return;
        }
    }
};

fn freePort() !u16 {
    var s = try fake_server.Server.init(io);
    defer s.deinit();
    return s.address().getPort();
}

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    base: []const u8,
    script: []const u8,
    env: std.process.Environ.Map,
    port: u16,

    fn init(f: *Fixture) !void {
        f.tmp = testing.tmpDir(.{});
        errdefer f.tmp.cleanup();
        f.arena = .init(testing.allocator);
        const a = f.arena.allocator();
        f.base = try f.tmp.dir.realPathFileAlloc(io, ".", a);
        try f.tmp.dir.writeFile(io, .{ .sub_path = "zeron-engine", .data = fake_engine_script, .flags = .{ .permissions = .executable_file } });
        f.script = try std.fs.path.join(a, &.{ f.base, "zeron-engine" });
        f.env = .init(testing.allocator);
        try f.env.put("ZERON_DATA_DIR", f.base);
        try f.env.put("PATH", "/usr/bin:/bin");
        f.port = try freePort();
    }

    fn deinit(f: *Fixture) void {
        f.env.deinit();
        f.arena.deinit();
        f.tmp.cleanup();
    }

    fn exists(f: *Fixture, name: []const u8) bool {
        f.tmp.dir.access(io, name, .{}) catch return false;
        return true;
    }

    fn config(f: *Fixture) model.engine_state.Config {
        return .{
            .port = f.port,
            .zeron_path = f.script,
            .spawn_environ = &f.env,
            .wake_mode = .poll,
            .reconnect = false,
            .spawn_timeout_ms = 10_000,
        };
    }
};

fn pumpUntilReady(app: *App, engine: Entity(EngineState)) !void {
    const deadline = Io.Timestamp.now(io, .awake).addDuration(.fromSeconds(15));
    while (true) {
        app.runUntilParked();
        _ = EngineState.pollWake(engine, app);
        app.runUntilParked();
        const s = engine.read(app);
        if (s.isReady()) return;
        if (s.connection == .failed) {
            std.debug.print("engine failed: {s}\n", .{s.connection.failed});
            return error.EngineFailed;
        }
        if (Io.Timestamp.now(io, .awake).nanoseconds > deadline.nanoseconds) return error.Timeout;
        io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
}

const QuitHook = struct {
    engine: Entity(EngineState),
    fn teardown(self: *QuitHook, app: *App) zpui.QuitTeardown {
        return EngineState.quitTeardown(self.engine, app);
    }
};

test "no engine answering: the bundled engine is spawned (`headless`) and stopped on quit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var mini: MiniEngine = .{ .port = f.port, .dir = f.tmp.dir, .wait_for = "spawned.pid" };
    try mini.start();
    defer mini.finish() catch {};

    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const engine = try app.newWith(EngineState, EngineState.init, .{ io, f.config() });
    try pumpUntilReady(app, engine);

    // Spawned exactly once, as `<engine> headless`, with the data dir it will lock.
    try testing.expect(f.exists("spawned.pid"));
    var buf: [64]u8 = undefined;
    const args = try f.tmp.dir.readFile(io, "args", &buf);
    try testing.expectEqualStrings("headless", std.mem.trim(u8, args, "\n"));
    try testing.expectEqualStrings(f.base, engine.read(app).config.data_dir.?);
    const pid_text = try f.tmp.dir.readFile(io, "spawned.pid", &buf);
    const pid = try std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_text, "\n"), 10);

    // Quit (macOS and Linux alike): the teardown signals and reaps the child.
    var hook: QuitHook = .{ .engine = engine };
    try app.onQuitAsync(&hook, QuitHook.teardown);
    app.quit();
    try testing.expect(f.exists("stopped"));
    // Reaped: the pid no longer names a process (not even a zombie).
    if (builtin.os.tag == .linux) {
        var proc_buf: [32]u8 = undefined;
        const proc = try std.fmt.bufPrint(&proc_buf, "/proc/{d}", .{pid});
        try testing.expectError(error.FileNotFound, Io.Dir.accessAbsolute(io, proc, .{}));
    }
    // No reconnect / respawn after quit.
    try testing.expect(engine.read(app).quitting);

    engine.release(app);
    app.runUntilParked();
}

test "an engine already answering is attached to; nothing is spawned or stopped" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    var mini: MiniEngine = .{ .port = f.port, .dir = f.tmp.dir };
    try mini.start();
    defer mini.finish() catch {};
    while (!mini.listening.load(.acquire)) try io.sleep(.fromMilliseconds(5), .awake);

    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    const engine = try app.newWith(EngineState, EngineState.init, .{ io, f.config() });
    try pumpUntilReady(app, engine);
    try testing.expect(!f.exists("spawned.pid"));
    // Not ours: the quit teardown has nothing to stop.
    const t = EngineState.quitTeardown(engine, app);
    try testing.expect(t.header == null);

    engine.release(app);
    app.runUntilParked();
}

test "a data dir locked by another engine is waited for, never double-spawned" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // Another engine (say a Rust Zeron.app still starting) holds engine.lock.
    const lock = try f.tmp.dir.createFile(io, "engine.lock", .{ .read = true });
    defer lock.close(io);
    try testing.expect(try lock.tryLock(io, .exclusive));
    try lock.writeStreamingAll(io, "4242");
    const held = engine_mod.lockHolder(io, f.base) orelse return error.TestExpectedLockHolder;
    try testing.expectEqual(@as(?i32, 4242), held.pid);

    const options: engine_mod.ConnectOptions = .{
        .port = f.port,
        .zeron_path = f.script,
        .spawn_environ = &f.env,
        .spawn_timeout = .fromMilliseconds(300),
        .data_dir = f.base,
    };
    // It never answers on our port: a clear error, and no rival spawned.
    try testing.expectError(error.EngineDataDirBusy, engine_mod.Engine.connect(testing.allocator, io, options));
    try testing.expect(!f.exists("spawned.pid"));
    const msg = EngineState.failureMessage(testing.allocator, error.EngineDataDirBusy, null).?;
    defer testing.allocator.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "ZERON_IPC_PORT") != null);

    // It starts answering a little later: attached, still nothing spawned, not owned.
    var mini: MiniEngine = .{ .port = f.port, .dir = f.tmp.dir };
    try mini.start();
    defer mini.finish() catch {};
    var opts = options;
    opts.spawn_timeout = .fromSeconds(10);
    var engine = try engine_mod.Engine.connect(testing.allocator, io, opts);
    try testing.expect(engine.child == null);
    engine.deinit();
    try testing.expect(!f.exists("spawned.pid"));

    // Once released, the lock no longer blocks a spawn.
    lock.unlock(io);
    try testing.expect(engine_mod.lockHolder(io, f.base) == null);
}
