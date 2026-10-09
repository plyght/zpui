//! zeron engine client library: speaks the engine's loopback WebSocket +
//! JSON-RPC protocol (the same API the gpui UI uses in "remote" mode).
//! Standalone: no dependency on the UI framework.
//!
//! Layers:
//! - `ws`: minimal RFC 6455 client (no `Origin` header — the engine rejects it);
//! - `rpc`: id multiplexer with non-blocking handles + a wakeup hook (see the
//!   threading model in rpc.zig);
//! - `protocol`: Zig mirrors of the core serde types; `methods`: all 109
//!   method names (generated); `transcript`: delta-apply state;
//! - `Engine` (here): find or start an engine and complete the
//!   `EngineInfo` → `EngineReady` bootstrap.
//!
//! ```
//! var engine = try Engine.connect(gpa, io, .{ .port = engine_mod.portFromEnv(environ) });
//! defer engine.deinit();
//! const chats = try engine.client.subscribe(.WatchChats, {});
//! ```

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const ws = @import("ws.zig");
pub const rpc = @import("rpc.zig");
pub const methods = @import("methods.zig");
pub const protocol = @import("protocol.zig");
pub const transcript = @import("transcript.zig");
pub const json_util = @import("json_util.zig");
pub const StopTimer = @import("stop_timer.zig").StopTimer;

pub const Client = rpc.Client;
pub const Call = rpc.Call;
pub const Subscription = rpc.Subscription;
pub const Payload = rpc.Payload;
pub const Method = methods.Method;
pub const Wake = rpc.Wake;
pub const Diagnostic = rpc.Diagnostic;
pub const decode = rpc.decode;
pub const Transcript = transcript.Transcript;

/// The engine's IPC port unless `ZERON_IPC_PORT` overrides it.
pub const default_port: u16 = 27654;

/// `ZERON_IPC_PORT` from `environ`, else `default_port`.
pub fn portFromEnv(environ: ?*const std.process.Environ.Map) u16 {
    const map = environ orelse return default_port;
    const raw = map.get("ZERON_IPC_PORT") orelse return default_port;
    return std.fmt.parseInt(u16, std.mem.trim(u8, raw, " "), 10) catch default_port;
}

pub const ConnectOptions = struct {
    port: u16 = default_port,
    /// The `zeron` binary to run as `zeron headless` when nothing answers on
    /// `port`. `null` disables spawning.
    zeron_path: ?[]const u8 = "zeron",
    /// Environment for the spawned engine (e.g. with `ZERON_DATA_DIR` and
    /// `ZERON_IPC_PORT` set). `null` inherits ours.
    spawn_environ: ?*const std.process.Environ.Map = null,
    /// How long to keep retrying after spawning before giving up.
    spawn_timeout: Io.Duration = .fromSeconds(30),
    /// Bound on `EngineReady` (stores/journals assembly).
    ready_timeout: Io.Duration = .fromSeconds(60),
    /// Forwarded to the RPC client.
    wake: ?Wake = null,
    /// Forward the spawned engine's stdout/stderr (otherwise discarded).
    inherit_child_output: bool = false,
    /// The engine's data dir (`ZERON_DATA_DIR`, else `~/.zeron`). When set, an engine
    /// that holds `{data_dir}/engine.lock` but does not answer yet (still starting, or a
    /// Rust Zeron.app embedding it) is waited for instead of spawning a second one that
    /// would only fail on the lock; and a spawned child that lost the lock race is not
    /// treated as ours (so quitting never stops someone else's engine).
    data_dir: ?[]const u8 = null,
};

/// Who holds `{data_dir}/engine.lock` (the engine's `InstanceLock`, an exclusive
/// `flock` held for the engine's lifetime with its pid written in).
pub const LockHolder = struct {
    /// The pid stamped in the file (null when unreadable).
    pid: ?i32,
};

/// Non-blocking probe of the data dir lock (zeron `InstanceLock::holder`): null when no
/// engine holds it (or the file does not exist). Takes a shared lock for an instant,
/// which a starting engine's exclusive `flock` rides out with its 1s retry budget.
pub fn lockHolder(io: Io, data_dir: []const u8) ?LockHolder {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/engine.lock", .{data_dir}) catch return null;
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const free = file.tryLock(io, .shared) catch return null;
    if (free) {
        file.unlock(io);
        return null;
    }
    var buf: [32]u8 = undefined;
    const n = file.readPositionalAll(io, &buf, 0) catch 0;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, buf[0..n], " \t\r\n"), 10) catch null;
    return .{ .pid = pid };
}

/// A connected, ready engine and (if we started it) its child process.
pub const Engine = struct {
    gpa: Allocator,
    io: Io,
    client: *Client,
    info: std.json.Parsed(protocol.EngineInfo),
    /// `zeron headless` we spawned, if any.
    child: ?std.process.Child = null,

    /// `EngineBinaryNotFound`: nothing answered and the `zeron` binary to spawn does
    /// not exist (or is not executable).
    /// `EngineDataDirBusy`: another engine holds the data dir lock but never answered on
    /// `port` (a Rust Zeron.app or daemon on another `ZERON_IPC_PORT`).
    pub const Error = error{ EngineUnavailable, EngineBinaryNotFound, NotAnEngine, EngineDataDirBusy } || Allocator.Error;

    /// Probe 127.0.0.1:`port`; if no engine answers, spawn `zeron headless`
    /// (when configured) and retry with backoff. Completes the bootstrap
    /// barrier: `EngineInfo` (identity) then `EngineReady` (an older engine's
    /// `UnknownMethod` counts as ready).
    pub fn connect(gpa: Allocator, io: Io, options: ConnectOptions) !Engine {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(options.port) };
        if (tryAttach(gpa, io, address, options)) |engine| return engine else |err| switch (err) {
            error.ConnectionRefused => {},
            else => |e| return e,
        }
        // Something already owns the data dir (starting up, or embedded in a Rust
        // Zeron.app): attach to it when it starts answering, never spawn a rival.
        if (options.data_dir) |dir| if (lockHolder(io, dir) != null) return waitForOther(gpa, io, address, options, dir);
        const path = options.zeron_path orelse return error.EngineUnavailable;
        var child = std.process.spawn(io, .{
            .argv = &.{ path, "headless" },
            .environ_map = options.spawn_environ,
            .stdin = .ignore,
            .stdout = if (options.inherit_child_output) .inherit else .ignore,
            .stderr = if (options.inherit_child_output) .inherit else .ignore,
        }) catch |err| return switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.NotDir, error.InvalidExe, error.IsDir => error.EngineBinaryNotFound,
            else => |e| e,
        };
        errdefer child.kill(io);

        const deadline: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = options.spawn_timeout, .clock = .awake } }).toDeadline(io);
        var backoff: i64 = 50;
        while (true) {
            if (tryAttach(gpa, io, address, options)) |engine_const| {
                var engine = engine_const;
                if (ownsDataDir(io, options.data_dir, child.id)) {
                    engine.child = child;
                } else {
                    // Another engine won the lock (two clients raced); ours exits on
                    // its own. Reap it and attach without owning the answerer.
                    child.kill(io);
                }
                return engine;
            } else |err| switch (err) {
                // Not listening yet, or listening but mid-handshake setup.
                error.ConnectionRefused, error.ConnectionResetByPeer, error.EndOfStream, error.Closed => {},
                else => |e| return e,
            }
            if (deadline.toDurationFromNow(io)) |left| {
                if (left.raw.nanoseconds <= 0) return error.EngineUnavailable;
            }
            try io.sleep(.fromMilliseconds(backoff), .awake);
            backoff = @min(backoff * 2, 1000);
        }
    }

    /// Whether our spawned `child` is the engine holding the data dir lock (true when
    /// that cannot be told: no data dir, or an unreadable pid stamp).
    fn ownsDataDir(io: Io, data_dir: ?[]const u8, child_id: ?std.process.Child.Id) bool {
        const dir = data_dir orelse return true;
        const holder = lockHolder(io, dir) orelse return true;
        const pid = holder.pid orelse return true;
        const id = child_id orelse return true;
        if (@TypeOf(id) != i32) return true; // non-posix
        return pid == id;
    }

    /// The data dir is locked by an engine we did not start: poll the port until it
    /// answers. Gives up early when the lock is released (the next attempt may spawn).
    fn waitForOther(gpa: Allocator, io: Io, address: Io.net.IpAddress, options: ConnectOptions, dir: []const u8) !Engine {
        const deadline: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = options.spawn_timeout, .clock = .awake } }).toDeadline(io);
        var backoff: i64 = 50;
        while (true) {
            if (tryAttach(gpa, io, address, options)) |engine| return engine else |err| switch (err) {
                error.ConnectionRefused, error.ConnectionResetByPeer, error.EndOfStream, error.Closed => {},
                else => |e| return e,
            }
            if (lockHolder(io, dir) == null) return error.EngineUnavailable;
            if (deadline.toDurationFromNow(io)) |left| {
                if (left.raw.nanoseconds <= 0) return error.EngineDataDirBusy;
            }
            try io.sleep(.fromMilliseconds(backoff), .awake);
            backoff = @min(backoff * 2, 1000);
        }
    }

    fn tryAttach(gpa: Allocator, io: Io, address: Io.net.IpAddress, options: ConnectOptions) !Engine {
        const client = try Client.connect(gpa, io, address, .{ .wake = options.wake });
        errdefer client.deinit();
        const info = client.callAs(protocol.EngineInfo, .EngineInfo, {}, .{
            .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
        }) catch |err| switch (err) {
            error.UnknownMethod, error.Remote, error.UnexpectedToken, error.MissingField => return error.NotAnEngine,
            else => |e| return e,
        };
        errdefer info.deinit();
        if (client.call(.EngineReady, {}, .{
            .timeout = .{ .duration = .{ .raw = options.ready_timeout, .clock = .awake } },
        })) |ready| {
            ready.deinit();
        } else |err| switch (err) {
            error.UnknownMethod => {}, // pre-barrier engine: ready by definition
            else => |e| return e,
        }
        return .{ .gpa = gpa, .io = io, .client = client, .info = info };
    }

    pub const DeinitOptions = struct {
        /// Ask a spawned `zeron headless` to exit (`StopEngine`), then reap it.
        /// When false the engine keeps running for other viewports.
        stop_spawned: bool = true,
    };

    /// Disconnect (all handles must be closed first) and optionally stop the
    /// engine we spawned.
    pub fn deinit(e: *Engine) void {
        e.deinitWith(.{});
    }

    pub fn deinitWith(e: *Engine, options: DeinitOptions) void {
        const stop = options.stop_spawned and e.child != null;
        if (stop) {
            if (e.client.call(.StopEngine, {}, .{
                .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
            })) |reply| reply.deinit() else |_| {}
        }
        e.info.deinit();
        e.client.deinit();
        if (e.child) |*child| {
            if (stop) {
                // Reap after the drain; a watchdog SIGKILLs a child that
                // ignores StopEngine. The pid cannot be reused before we reap.
                // `StopTimer`, not `Future.cancel`, ends the watchdog: a cancel
                // from a thread with SIGIO blocked (macOS) waits the full 10 s.
                var timer: StopTimer = .{};
                var watchdog = e.io.concurrent(killAfter, .{ e.io, child.id.?, Io.Duration.fromSeconds(10), &timer }) catch null;
                _ = child.wait(e.io) catch child.kill(e.io);
                if (watchdog) |*w| timer.stopAndAwait(e.io, w);
            }
        }
    }

    /// Take ownership of the engine we spawned (if any): the connection stops treating
    /// it as its own (no `StopEngine` / reap on deinit). Pair with `terminateChild`.
    pub fn takeChild(e: *Engine) ?std.process.Child {
        const child = e.child orelse return null;
        e.child = null;
        return child;
    }

    /// Ask a spawned engine to shut down gracefully (SIGTERM: the engine's
    /// `shutdown_signal` drains like `StopEngine`). Returns at once.
    pub fn signalStop(child: *const std.process.Child) void {
        if (comptime @TypeOf(child.id) != ?std.posix.pid_t) return;
        const pid = child.id orelse return;
        std.posix.kill(pid, .TERM) catch {};
    }

    /// Reap a child after `signalStop`; SIGKILLs it if it is still alive after
    /// `grace` (an engine that ignores the request).
    pub fn reapChild(io: Io, child: *std.process.Child, grace: Io.Duration) void {
        const id = child.id orelse return;
        var timer: StopTimer = .{};
        var watchdog = io.concurrent(killAfter, .{ io, id, grace, &timer }) catch null;
        _ = child.wait(io) catch child.kill(io);
        if (watchdog) |*w| timer.stopAndAwait(io, w);
    }

    fn killAfter(io: Io, pid: std.process.Child.Id, grace: Io.Duration, timer: *StopTimer) void {
        if (!timer.sleep(io, grace)) return; // reaped in time
        std.posix.kill(pid, .KILL) catch {};
    }

    /// Typed snapshot helpers for the common streams.
    pub fn watchChats(e: *Engine) !*Subscription {
        return e.client.subscribe(.WatchChats, {});
    }

    pub fn watchTranscript(e: *Engine, chat_id: []const u8, opening_tail: bool) !*Subscription {
        return e.client.subscribe(.WatchDocMessages, protocol.params.WatchDocMessages{
            .chatId = chat_id,
            .openingTail = if (opening_tail) true else null,
        });
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("protocol_test.zig");
    _ = @import("stop_timer.zig");
}

/// The engine connect as zpui's macOS background executor runs it: on a thread
/// that blocks SIGIO (a libdispatch worker), with an `Io.Threaded` whose
/// workers inherit that mask. The handshake watchdog used to be stopped with
/// `Future.cancel`, which could not interrupt the masked worker's sleep, so the
/// connect returned only after the full 5 s `handshake_timeout`.
fn connectFromMaskedThread(address: Io.net.IpAddress, elapsed: *?i96) void {
    var all = std.posix.sigfillset();
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &all, null);
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const start = Io.Timestamp.now(io, .awake).nanoseconds;
    const conn = ws.Conn.connect(std.testing.allocator, io, address, .{}) catch return;
    elapsed.* = Io.Timestamp.now(io, .awake).nanoseconds - start;
    conn.sendClose(1000);
    conn.deinit();
}

test "ws connect from a thread that blocks SIGIO does not wait out the handshake timeout" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    const test_server = @import("test_server.zig");
    var server = try test_server.Server.init(io);
    defer server.deinit();
    const Script = struct {
        fn run(srv: *test_server.Server) !void {
            const peer = try srv.accept(testing.allocator);
            defer peer.deinit();
            _ = peer.recv() catch {}; // the client's close
        }
    };
    var script = try io.concurrent(Script.run, .{&server});
    defer script.await(io) catch {};

    var elapsed: ?i96 = null;
    const th = try std.Thread.spawn(.{}, connectFromMaskedThread, .{ server.address(), &elapsed });
    th.join();
    try script.await(io);
    const ns = elapsed orelse return error.ConnectFailed;
    try testing.expect(ns < 2 * std.time.ns_per_s);
}

test "portFromEnv" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expectEqual(default_port, portFromEnv(&env));
    try env.put("ZERON_IPC_PORT", "31000");
    try std.testing.expectEqual(@as(u16, 31000), portFromEnv(&env));
    try env.put("ZERON_IPC_PORT", "junk");
    try std.testing.expectEqual(default_port, portFromEnv(&env));
    try std.testing.expectEqual(default_port, portFromEnv(null));
}

test "Engine.connect: bootstrap against a fake engine; no engine and no spawn fails" {
    const testing = std.testing;
    const io = testing.io;
    const test_server = @import("test_server.zig");
    var server = try test_server.Server.init(io);
    defer server.deinit();

    const Script = struct {
        fn run(srv: *test_server.Server) !void {
            const peer = try srv.accept(testing.allocator);
            defer peer.deinit();
            var buf: [256]u8 = undefined;
            var method: [64]u8 = undefined;
            const a = try peer.recvRequest(&method);
            try testing.expectEqualStrings("EngineInfo", method[0..a.method_len]);
            try peer.sendText(try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"ok\":{{\"deviceId\":\"dev\",\"workspaceScope\":\"development\",\"capabilities\":[\"message-queue-v1\"]}}}}", .{a.id}));
            const b = try peer.recvRequest(&method);
            try testing.expectEqualStrings("EngineReady", method[0..b.method_len]);
            // An older engine: no readiness barrier.
            try peer.sendText(try std.fmt.bufPrint(&buf, "{{\"id\":{d},\"err\":\"unknown method: EngineReady\"}}", .{b.id}));
            _ = peer.recv() catch {}; // wait for the client's close
        }
    };
    var script = try io.concurrent(Script.run, .{&server});
    defer script.await(io) catch {};

    var engine = try Engine.connect(testing.allocator, io, .{
        .port = server.address().getPort(),
        .zeron_path = null,
    });
    try testing.expectEqual(protocol.WorkspaceScope.development, engine.info.value.workspaceScope);
    try testing.expect(engine.info.value.supports(protocol.capabilities.message_queue_v1));
    engine.deinit();
    try script.await(io);

    // Nothing listens on the (now closed) port and spawning is disabled.
    server.deinit();
    server = try test_server.Server.init(io); // keep the deferred deinit valid
    try testing.expectError(error.EngineUnavailable, Engine.connect(testing.allocator, io, .{
        .port = 1,
        .zeron_path = null,
    }));
    // Nothing listens and the binary to spawn is missing.
    try testing.expectError(error.EngineBinaryNotFound, Engine.connect(testing.allocator, io, .{
        .port = 1,
        .zeron_path = "/nonexistent/zeron-engine-binary",
    }));
}
