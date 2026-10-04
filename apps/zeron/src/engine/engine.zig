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
};

/// A connected, ready engine and (if we started it) its child process.
pub const Engine = struct {
    gpa: Allocator,
    io: Io,
    client: *Client,
    info: std.json.Parsed(protocol.EngineInfo),
    /// `zeron headless` we spawned, if any.
    child: ?std.process.Child = null,

    pub const Error = error{ EngineUnavailable, NotAnEngine } || Allocator.Error;

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
        const path = options.zeron_path orelse return error.EngineUnavailable;
        var child = try std.process.spawn(io, .{
            .argv = &.{ path, "headless" },
            .environ_map = options.spawn_environ,
            .stdin = .ignore,
            .stdout = if (options.inherit_child_output) .inherit else .ignore,
            .stderr = if (options.inherit_child_output) .inherit else .ignore,
        });
        errdefer child.kill(io);

        const deadline: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = options.spawn_timeout, .clock = .awake } }).toDeadline(io);
        var backoff: i64 = 50;
        while (true) {
            if (tryAttach(gpa, io, address, options)) |engine_const| {
                var engine = engine_const;
                engine.child = child;
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
                var watchdog = e.io.concurrent(killAfter, .{ e.io, child.id.? }) catch null;
                _ = child.wait(e.io) catch child.kill(e.io);
                if (watchdog) |*w| w.cancel(e.io);
            }
        }
    }

    fn killAfter(io: Io, pid: std.process.Child.Id) void {
        io.sleep(.fromSeconds(10), .awake) catch return;
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
}
