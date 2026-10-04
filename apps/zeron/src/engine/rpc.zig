//! JSON-RPC multiplexer matching `zeron_rpc` (crates/rpc/src/{lib,client}.rs).
//!
//! Wire envelopes (one JSON object per WebSocket text message, or several
//! newline-separated ones):
//! - client → server: `{id, method, params}` to invoke, `{id, cancel: true}` to stop a stream;
//! - server → client: `{id, ok}` / `{id, err}` for unary calls, `{id, item}`* then
//!   `{id, done: true}` (or `{id, err}`) for streams. `WatchCheckoutChangeRequest`
//!   alone sends a readiness `{id, ok: {stream: true}}` before its items.
//! Errors are plain strings; `"unknown method: X"` maps to `error.UnknownMethod`.
//!
//! ## Threading model
//!
//! `Client.connect` starts one reader task (`io.concurrent`, i.e. a thread on
//! `std.Io.Threaded`). It blocks on the socket, decodes frames and routes them,
//! under `Client.mutex`, into the handle that owns the request id:
//! - a `Call` (unary) gets its result slot filled;
//! - a `Subscription` (stream) gets the item appended to its FIFO queue.
//! After each routed frame the reader broadcasts `Client.cond` (for blocking
//! waiters) and invokes the optional `Options.wake` callback *without* holding
//! the lock. A UI event loop hooks `wake` to post an empty event to itself
//! (e.g. `glfwPostEmptyEvent`), then on its own thread drains every handle
//! with the non-blocking `Call.poll` / `Subscription.next`. Nothing on the UI
//! thread ever blocks on the network; `Client.call` / `Subscription.wait` are
//! blocking conveniences for CLIs, tests and startup.
//!
//! Sending (`start`, `subscribe`, cancel on `Subscription.deinit`) happens on
//! the caller's thread; writes are serialized by the connection's write lock.
//! Queues are unbounded — the engine's snapshot streams resend whole state, so
//! a consumer that falls behind may coalesce by draining and keeping the last.
//!
//! Ownership: handles are owned by the caller and must be `deinit`ed before
//! `Client.deinit`. A handle unregisters itself (under the lock) on `deinit`,
//! so the reader never touches freed memory. `gpa` must be thread-safe: the
//! reader allocates payload arenas with it.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const ws = @import("ws.zig");
const methods = @import("methods.zig");

pub const Method = methods.Method;

/// A decoded JSON value plus the arena that owns it. `deinit` frees both.
pub const Payload = json.Parsed(json.Value);

/// Lenient decode options matching serde's default (unknown fields ignored).
pub const decode_options: json.ParseOptions = .{ .ignore_unknown_fields = true };

/// Decode a payload into `T`, reusing its arena. Consumes `payload` (it is
/// freed on error); the result owns the arena.
pub fn decode(comptime T: type, payload: Payload) !json.Parsed(T) {
    errdefer payload.deinit();
    const value = try json.parseFromValueLeaky(T, payload.arena.allocator(), payload.value, decode_options);
    return .{ .arena = payload.arena, .value = value };
}

/// Callback fired from the reader thread after it delivered anything.
pub const Wake = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,

    fn fire(w: Wake) void {
        w.func(w.ctx);
    }
};

/// The text of the last remote error, copied into a caller-provided buffer.
pub const Diagnostic = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    fn set(d: *Diagnostic, msg: []const u8) void {
        d.len = @min(msg.len, d.buf.len);
        @memcpy(d.buf[0..d.len], msg[0..d.len]);
    }
};

pub const RemoteError = error{
    /// The engine does not implement the method (older engine).
    UnknownMethod,
    /// Any other error string from the engine (see `Diagnostic`).
    Remote,
    /// The connection dropped before the reply.
    Closed,
};

/// Classify an engine error string.
pub fn classifyError(msg: []const u8) RemoteError {
    return if (std.mem.startsWith(u8, msg, "unknown method: ")) error.UnknownMethod else error.Remote;
}

pub const Options = struct {
    wake: ?Wake = null,
    ws: ws.Conn.ConnectOptions = .{},
};

pub const Client = struct {
    gpa: Allocator,
    io: Io,
    conn: *ws.Conn,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    slots: std.AutoHashMapUnmanaged(u64, Slot) = .empty,
    next_id: std.atomic.Value(u64) = .init(1),
    /// Live handles (Calls + Subscriptions); must be 0 at `deinit`.
    handles: usize = 0,
    alive: bool = true,
    wake: ?Wake,
    reader: Io.Future(void) = undefined,

    const Slot = union(enum) {
        call: *Call,
        stream: *Subscription,
    };

    pub const ConnectError = ws.Conn.ConnectError || Io.ConcurrentError;

    /// Dial `address`, upgrade to WebSocket and start the reader task.
    /// `io` must support `concurrent` (e.g. `std.Io.Threaded`).
    pub fn connect(gpa: Allocator, io: Io, address: Io.net.IpAddress, options: Options) ConnectError!*Client {
        const conn = try ws.Conn.connect(gpa, io, address, options.ws);
        errdefer conn.deinit();
        const c = try gpa.create(Client);
        errdefer gpa.destroy(c);
        c.* = .{ .gpa = gpa, .io = io, .conn = conn, .wake = options.wake };
        c.reader = try io.concurrent(readerMain, .{c});
        return c;
    }

    /// Close the connection, stop the reader and free. All handles must have
    /// been `deinit`ed.
    pub fn deinit(c: *Client) void {
        std.debug.assert(c.handles == 0);
        c.conn.sendClose(1000);
        c.conn.shutdown();
        c.reader.await(c.io);
        c.slots.deinit(c.gpa);
        c.conn.deinit();
        c.gpa.destroy(c);
    }

    /// False once the connection dropped; every handle then reports `closed`.
    pub fn isAlive(c: *Client) bool {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return c.alive;
    }

    // ── sending ──────────────────────────────────────────────────────────

    fn sendInvoke(c: *Client, id: u64, method: []const u8, params: anytype) !void {
        var aw: Io.Writer.Allocating = .init(c.gpa);
        defer aw.deinit();
        var s: json.Stringify = .{ .writer = &aw.writer, .options = .{ .emit_null_optional_fields = false } };
        try s.beginObject();
        try s.objectField("id");
        try s.write(id);
        try s.objectField("method");
        try s.write(method);
        const P = @TypeOf(params);
        if (P != void and P != @TypeOf(null)) {
            try s.objectField("params");
            try s.write(params);
        }
        try s.endObject();
        c.conn.sendText(aw.written()) catch return error.Closed;
    }

    fn sendCancel(c: *Client, id: u64) void {
        var buf: [64]u8 = undefined;
        const frame = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"cancel\":true}}", .{id}) catch unreachable;
        c.conn.sendText(frame) catch {};
    }

    /// Register a slot and allocate an id; fails if the connection is gone.
    fn register(c: *Client, slot: Slot) error{ Closed, OutOfMemory }!u64 {
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        if (!c.alive) return error.Closed;
        const id = c.next_id.fetchAdd(1, .monotonic);
        try c.slots.put(c.gpa, id, slot);
        c.handles += 1;
        return id;
    }

    // ── unary ────────────────────────────────────────────────────────────

    /// Start a unary call without blocking. `params` is any value
    /// `std.json.Stringify` accepts (null optionals are omitted), or `{}`/`null`
    /// for none. Poll or wait on the returned handle; `deinit` it when done.
    pub fn start(c: *Client, method: Method, params: anytype) !*Call {
        return c.startRaw(method.name(), params);
    }

    /// `start` by wire name, for methods newer than `methods.zig`.
    pub fn startRaw(c: *Client, method: []const u8, params: anytype) !*Call {
        const h = try c.gpa.create(Call);
        h.* = .{ .client = c, .id = 0 };
        // The reader cannot see the slot until the request is sent.
        h.id = c.register(.{ .call = h }) catch |err| {
            c.gpa.destroy(h);
            return err;
        };
        errdefer h.deinit();
        try c.sendInvoke(h.id, method, params);
        return h;
    }

    pub const CallOptions = struct {
        timeout: Io.Timeout = .none,
        diag: ?*Diagnostic = null,
    };

    /// Blocking unary call returning the raw `ok` value.
    pub fn call(c: *Client, method: Method, params: anytype, options: CallOptions) !Payload {
        const h = try c.start(method, params);
        defer h.deinit();
        return h.wait(options);
    }

    /// Blocking unary call decoded into `T`.
    pub fn callAs(c: *Client, comptime T: type, method: Method, params: anytype, options: CallOptions) !json.Parsed(T) {
        return decode(T, try c.call(method, params, options));
    }

    // ── streams ──────────────────────────────────────────────────────────

    /// Open a stream. Items queue up on the returned handle until drained;
    /// `deinit` cancels the server task if the stream is still open.
    pub fn subscribe(c: *Client, method: Method, params: anytype) !*Subscription {
        return c.subscribeRaw(method.name(), params);
    }

    pub fn subscribeRaw(c: *Client, method: []const u8, params: anytype) !*Subscription {
        const sub = try c.gpa.create(Subscription);
        sub.* = .{ .client = c, .id = 0 };
        sub.id = c.register(.{ .stream = sub }) catch |err| {
            c.gpa.destroy(sub);
            return err;
        };
        errdefer sub.deinit();
        try c.sendInvoke(sub.id, method, params);
        return sub;
    }

    // ── reader ───────────────────────────────────────────────────────────

    fn readerMain(c: *Client) void {
        while (true) {
            const message = c.conn.readText() catch break;
            var lines = std.mem.splitScalar(u8, message, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0) continue;
                c.route(line) catch |err| switch (err) {
                    error.OutOfMemory => {},
                    else => std.log.scoped(.zeron_rpc).warn("dropping malformed server frame: {t}", .{err}),
                };
            }
            if (c.wake) |w| w.fire();
        }
        c.mutex.lockUncancelable(c.io);
        c.alive = false;
        var it = c.slots.valueIterator();
        while (it.next()) |slot| switch (slot.*) {
            .call => |h| h.state = .closed,
            .stream => |s| {
                if (s.end == .open) s.end = .closed;
            },
        };
        c.slots.clearRetainingCapacity();
        c.cond.broadcast(c.io);
        c.mutex.unlock(c.io);
        if (c.wake) |w| w.fire();
    }

    fn route(c: *Client, line: []const u8) !void {
        const frame = try json.parseFromSlice(json.Value, c.gpa, line, .{ .allocate = .alloc_always });
        var keep = false;
        defer if (!keep) frame.deinit();
        if (frame.value != .object) return error.UnexpectedToken;
        const obj = frame.value.object;
        const id: u64 = switch (obj.get("id") orelse return error.MissingField) {
            .integer => |i| std.math.cast(u64, i) orelse return error.Overflow,
            else => return error.UnexpectedToken,
        };

        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        defer c.cond.broadcast(c.io);
        const slot = c.slots.get(id) orelse return; // canceled/unknown: drop

        if (obj.get("err")) |err_value| {
            const msg = switch (err_value) {
                .string => |s| s,
                else => "malformed error",
            };
            const owned = try c.gpa.dupe(u8, msg);
            _ = c.slots.remove(id);
            switch (slot) {
                .call => |h| h.state = .{ .err = owned },
                .stream => |s| {
                    s.end = .{ .err = owned };
                },
            }
            return;
        }
        if (obj.get("ok")) |ok| {
            switch (slot) {
                .call => |h| {
                    _ = c.slots.remove(id);
                    h.state = .{ .ok = .{ .arena = frame.arena, .value = ok } };
                    keep = true;
                },
                // `WatchCheckoutChangeRequest` readiness frame (or a legacy
                // engine's stray ok): the stream is acknowledged, not finished.
                .stream => |s| s.ready = true,
            }
            return;
        }
        if (obj.get("item")) |item| {
            switch (slot) {
                .call => {}, // matches the Rust client: items for a call are dropped
                .stream => |s| {
                    s.ready = true;
                    try s.items.pushBack(c.gpa, .{ .arena = frame.arena, .value = item });
                    keep = true;
                },
            }
            return;
        }
        if (obj.get("done")) |done| {
            if (done == .bool and done.bool) switch (slot) {
                .call => {},
                .stream => |s| {
                    _ = c.slots.remove(id);
                    s.ready = true;
                    s.end = .done;
                },
            };
        }
    }
};

/// A pending or completed unary call.
pub const Call = struct {
    client: *Client,
    id: u64,
    state: State = .pending,

    pub const State = union(enum) {
        pending,
        ok: Payload,
        /// Engine error string, owned by the client's gpa.
        err: []u8,
        closed,
    };

    pub const Status = std.meta.Tag(State);

    /// Non-blocking status check.
    pub fn poll(h: *Call) Status {
        const c = h.client;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return h.state;
    }

    /// Take the result if complete: `null` while pending, the payload on
    /// success (caller owns it), or the classified error.
    pub fn take(h: *Call, diag: ?*Diagnostic) RemoteError!?Payload {
        const c = h.client;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return h.takeLocked(diag);
    }

    fn takeLocked(h: *Call, diag: ?*Diagnostic) RemoteError!?Payload {
        switch (h.state) {
            .pending => return null,
            .ok => |p| {
                h.state = .closed;
                return p;
            },
            .err => |msg| {
                if (diag) |d| d.set(msg);
                return classifyError(msg);
            },
            .closed => return error.Closed,
        }
    }

    /// Block until the reply (or timeout). Caller owns the payload.
    pub fn wait(h: *Call, options: Client.CallOptions) !Payload {
        const c = h.client;
        const deadline = options.timeout.toDeadline(c.io);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        while (true) {
            if (try h.takeLocked(options.diag)) |p| return p;
            switch (deadline) {
                .none => try c.cond.wait(c.io, &c.mutex),
                else => try c.cond.waitTimeout(c.io, &c.mutex, deadline),
            }
        }
    }

    /// Unregister (late replies are dropped) and free, including any untaken result.
    pub fn deinit(h: *Call) void {
        const c = h.client;
        c.mutex.lockUncancelable(c.io);
        if (c.slots.get(h.id)) |slot| {
            if (slot == .call and slot.call == h) _ = c.slots.remove(h.id);
        }
        c.handles -= 1;
        c.mutex.unlock(c.io);
        switch (h.state) {
            .ok => |p| p.deinit(),
            .err => |msg| c.gpa.free(msg),
            .pending, .closed => {},
        }
        c.gpa.destroy(h);
    }
};

/// An open stream: a FIFO of item payloads plus its end state.
pub const Subscription = struct {
    client: *Client,
    id: u64,
    items: std.Deque(Payload) = .empty,
    /// The server acknowledged the stream (first ok/item/done). Mirrors
    /// `subscribe_checked`: an error before readiness means the method failed
    /// outright (e.g. `UnknownMethod` on an older engine).
    ready: bool = false,
    end: End = .open,

    pub const End = union(enum) {
        open,
        /// `{id, done: true}`.
        done,
        /// `{id, err}`; owned by the client's gpa.
        err: []u8,
        /// Connection dropped.
        closed,
    };

    /// Pop the next item without blocking. `null` when the queue is empty;
    /// check `status` to tell "nothing yet" from "ended". Caller owns the payload.
    pub fn next(s: *Subscription) ?Payload {
        const c = s.client;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return s.items.popFront();
    }

    pub const Status = std.meta.Tag(End);

    pub fn status(s: *Subscription, diag: ?*Diagnostic) Status {
        const c = s.client;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        if (s.end == .err) if (diag) |d| d.set(s.end.err);
        return s.end;
    }

    /// The stream's terminal error, if it ended with one.
    pub fn endError(s: *Subscription, diag: ?*Diagnostic) RemoteError!void {
        const c = s.client;
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        return s.endErrorLocked(diag);
    }

    fn endErrorLocked(s: *Subscription, diag: ?*Diagnostic) RemoteError!void {
        switch (s.end) {
            .open, .done => {},
            .err => |msg| {
                if (diag) |d| d.set(msg);
                return classifyError(msg);
            },
            .closed => return error.Closed,
        }
    }

    /// Block for the next item; `null` once the stream ended cleanly
    /// (`done`). An error end is returned as an error after queued items drain.
    pub fn wait(s: *Subscription, options: Client.CallOptions) !?Payload {
        const c = s.client;
        const deadline = options.timeout.toDeadline(c.io);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        while (true) {
            if (s.items.popFront()) |p| return p;
            if (s.end != .open) {
                try s.endErrorLocked(options.diag);
                return null;
            }
            switch (deadline) {
                .none => try c.cond.wait(c.io, &c.mutex),
                else => try c.cond.waitTimeout(c.io, &c.mutex, deadline),
            }
        }
    }

    /// Block until the server acknowledged the stream or failed it.
    pub fn waitReady(s: *Subscription, options: Client.CallOptions) !void {
        const c = s.client;
        const deadline = options.timeout.toDeadline(c.io);
        c.mutex.lockUncancelable(c.io);
        defer c.mutex.unlock(c.io);
        while (!s.ready) {
            if (s.end != .open) {
                try s.endErrorLocked(options.diag);
                return;
            }
            switch (deadline) {
                .none => try c.cond.wait(c.io, &c.mutex),
                else => try c.cond.waitTimeout(c.io, &c.mutex, deadline),
            }
        }
    }

    /// Cancel server-side if still open, drop queued items, free.
    pub fn deinit(s: *Subscription) void {
        const c = s.client;
        c.mutex.lockUncancelable(c.io);
        var cancel = false;
        if (c.slots.get(s.id)) |slot| {
            if (slot == .stream and slot.stream == s) {
                _ = c.slots.remove(s.id);
                cancel = c.alive;
            }
        }
        c.handles -= 1;
        c.mutex.unlock(c.io);
        if (cancel) c.sendCancel(s.id);
        while (s.items.popFront()) |p| p.deinit();
        s.items.deinit(c.gpa);
        if (s.end == .err) c.gpa.free(s.end.err);
        c.gpa.destroy(s);
    }
};

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const test_server = @import("test_server.zig");

fn fmtBuf(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch unreachable;
}

const WakeCounter = struct {
    n: std.atomic.Value(u32) = .init(0),
    fn bump(ctx: ?*anyopaque) void {
        const self: *WakeCounter = @ptrCast(@alignCast(ctx.?));
        _ = self.n.fetchAdd(1, .monotonic);
    }
};

test "unary ok, unknown method, remote error" {
    const io = testing.io;
    const gpa = testing.allocator;
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
            try peer.sendText(fmtBuf(&buf, "{{\"id\":{d},\"ok\":{{\"deviceId\":\"dev-1\",\"workspaceScope\":\"local\"}}}}", .{a.id}));
            const b = try peer.recvRequest(null);
            try peer.sendText(fmtBuf(&buf, "{{\"id\":{d},\"err\":\"unknown method: Nope\"}}", .{b.id}));
            const c = try peer.recvRequest(null);
            try peer.sendText(fmtBuf(&buf, "{{\"id\":{d},\"err\":\"chat not found\"}}", .{c.id}));
        }
    };
    var script = try io.concurrent(Script.run, .{&server});
    defer script.await(io) catch {};

    var wakes: WakeCounter = .{};
    const client = try Client.connect(gpa, io, server.address(), .{ .wake = .{ .ctx = &wakes, .func = WakeCounter.bump } });
    defer client.deinit();

    const Info = struct { deviceId: []const u8, workspaceScope: []const u8 };
    const info = try client.callAs(Info, .EngineInfo, {}, .{});
    defer info.deinit();
    try testing.expectEqualStrings("dev-1", info.value.deviceId);

    try testing.expectError(error.UnknownMethod, client.call(.EngineReady, .{ .x = 1 }, .{}));
    var diag: Diagnostic = .{};
    try testing.expectError(error.Remote, client.call(.FocusChat, .{ .chatId = "c" }, .{ .diag = &diag }));
    try testing.expectEqualStrings("chat not found", diag.message());
    try script.await(io);
    // `wake` fires right after waiters are signaled; allow it to land.
    var spins: usize = 0;
    while (wakes.n.load(.monotonic) < 3 and spins < 200) : (spins += 1) try io.sleep(.fromMilliseconds(5), .awake);
    try testing.expect(wakes.n.load(.monotonic) >= 3);
}

test "stream: batched ndjson items, fragmented message, ping, done" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server = try test_server.Server.init(io);
    defer server.deinit();

    const Script = struct {
        fn run(srv: *test_server.Server) !void {
            const peer = try srv.accept(testing.allocator);
            defer peer.deinit();
            var buf: [256]u8 = undefined;
            const r = try peer.recvRequest(null);
            // Two frames in one message (ndjson batching).
            try peer.sendText(fmtBuf(&buf, "{{\"id\":{d},\"item\":1}}\n{{\"id\":{d},\"item\":2}}\n", .{ r.id, r.id }));
            // A ping must be answered with a pong carrying the same payload.
            try peer.sendFrame(.ping, true, "beat");
            const pong = try peer.recv();
            try testing.expectEqualStrings("beat", pong.pong);
            // One frame split over three WebSocket fragments.
            const msg = fmtBuf(&buf, "{{\"id\":{d},\"item\":3}}", .{r.id});
            try peer.sendFrame(.text, false, msg[0..3]);
            try peer.sendFrame(.continuation, false, msg[3..7]);
            try peer.sendFrame(.continuation, true, msg[7..]);
            try peer.sendText(fmtBuf(&buf, "{{\"id\":{d},\"done\":true}}", .{r.id}));
        }
    };
    var script = try io.concurrent(Script.run, .{&server});
    defer script.await(io) catch {};

    const client = try Client.connect(gpa, io, server.address(), .{});
    defer client.deinit();
    const sub = try client.subscribe(.WatchChats, {});
    defer sub.deinit();
    var got: [3]i64 = undefined;
    for (&got) |*g| {
        const p = (try sub.wait(.{})).?;
        defer p.deinit();
        g.* = p.value.integer;
    }
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, &got);
    try testing.expectEqual(@as(?Payload, null), try sub.wait(.{}));
    try testing.expectEqual(Subscription.Status.done, sub.status(null));
    try script.await(io);
}

test "checked stream: ok{stream:true} readiness quirk, cancel on deinit" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server = try test_server.Server.init(io);
    defer server.deinit();

    const Script = struct {
        fn run(srv: *test_server.Server) !void {
            const peer = try srv.accept(testing.allocator);
            defer peer.deinit();
            var buf: [256]u8 = undefined;
            const r = try peer.recvRequest(null);
            try peer.sendText(fmtBuf(&buf, "{{\"id\":{d},\"ok\":{{\"stream\":true}}}}", .{r.id}));
            try peer.sendText(fmtBuf(&buf, "{{\"id\":{d},\"item\":{{\"checkoutId\":\"k\"}}}}", .{r.id}));
            const cancel = try peer.recvRequest(null);
            try testing.expect(cancel.cancel);
            try testing.expectEqual(r.id, cancel.id);
            // An unknown-method stream fails before readiness.
            const u = try peer.recvRequest(null);
            try peer.sendText(fmtBuf(&buf, "{{\"id\":{d},\"err\":\"unknown method: WatchFuture\"}}", .{u.id}));
        }
    };
    var script = try io.concurrent(Script.run, .{&server});
    defer script.await(io) catch {};

    const client = try Client.connect(gpa, io, server.address(), .{});
    defer client.deinit();
    {
        const sub = try client.subscribe(.WatchCheckoutChangeRequest, .{ .cwd = "/tmp" });
        defer sub.deinit();
        try sub.waitReady(.{});
        const item = (try sub.wait(.{})).?;
        defer item.deinit();
        try testing.expectEqualStrings("k", item.value.object.get("checkoutId").?.string);
        try testing.expectEqual(Subscription.Status.open, sub.status(null));
    }
    {
        const sub = try client.subscribeRaw("WatchFuture", {});
        defer sub.deinit();
        try testing.expectError(error.UnknownMethod, sub.waitReady(.{}));
    }
    try script.await(io);
}

test "non-blocking poll and connection drop fails pending work" {
    const io = testing.io;
    const gpa = testing.allocator;
    var server = try test_server.Server.init(io);
    defer server.deinit();

    const Script = struct {
        fn run(srv: *test_server.Server) !void {
            const peer = try srv.accept(testing.allocator);
            defer peer.deinit();
            var buf: [128]u8 = undefined;
            const a = try peer.recvRequest(null);
            _ = try peer.recvRequest(null); // the subscription
            try peer.sendText(fmtBuf(&buf, "{{\"id\":{d},\"ok\":null}}", .{a.id}));
            _ = try peer.recvRequest(null); // a call that never gets answered
            // Drop the connection.
        }
    };
    var script = try io.concurrent(Script.run, .{&server});

    const client = try Client.connect(gpa, io, server.address(), .{});
    defer client.deinit();
    const a = try client.start(.ProbeSync, {});
    defer a.deinit();
    const sub = try client.subscribe(.WatchSessions, {});
    defer sub.deinit();
    try testing.expectEqual(@as(?Payload, null), sub.next());
    const ok = try a.wait(.{});
    ok.deinit();
    const b = try client.start(.SyncStatus, {});
    defer b.deinit();
    try script.await(io);
    try testing.expectError(error.Closed, b.wait(.{}));
    try testing.expectError(error.Closed, sub.wait(.{}));
    try testing.expect(!client.isAlive());
    try testing.expectError(error.Closed, client.start(.SyncStatus, {}));
}

test "classifyError" {
    try testing.expectEqual(error.UnknownMethod, classifyError("unknown method: X"));
    try testing.expectEqual(error.Remote, classifyError("bad params: missing field"));
}

test {
    _ = methods;
}
