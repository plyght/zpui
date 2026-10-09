//! Minimal RFC 6455 WebSocket client for the engine's loopback socket.
//!
//! Scope: client role only (every outgoing frame is masked), text/binary
//! messages with fragmentation, ping→pong, and the close handshake. No
//! extensions, no TLS. The upgrade request deliberately carries no `Origin`
//! header: the engine rejects any handshake that has one with HTTP 403
//! (`crates/rpc/src/server.rs`, a guard against browser pages).
//!
//! The framing functions operate on `std.Io.Reader`/`std.Io.Writer` so they
//! can be tested against byte buffers; `Conn` binds them to a TCP stream.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const StopTimer = @import("stop_timer.zig").StopTimer;

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,

    pub fn isControl(op: Opcode) bool {
        return @intFromEnum(op) & 0x8 != 0;
    }
};

pub const Header = struct {
    fin: bool,
    opcode: Opcode,
    mask: ?[4]u8,
    len: u64,
};

pub const ProtocolError = error{
    /// Reserved bits set, unknown opcode, bad continuation, oversized control frame.
    ProtocolViolation,
    /// A message exceeded `max_message_len`.
    MessageTooLarge,
};

/// XOR `bytes` with `mask`, where `bytes[0]` sits at payload offset `offset`.
pub fn applyMask(mask: [4]u8, offset: usize, bytes: []u8) void {
    for (bytes, 0..) |*b, i| b.* ^= mask[(offset + i) & 3];
}

/// Write one frame. `mask` is required for client→server frames (RFC 6455 §5.3)
/// and `null` for server→client frames (used by the test server).
pub fn writeFrame(w: *Io.Writer, opcode: Opcode, fin: bool, payload: []const u8, mask: ?[4]u8) Io.Writer.Error!void {
    var head: [14]u8 = undefined;
    head[0] = (if (fin) @as(u8, 0x80) else 0) | @as(u8, @intFromEnum(opcode));
    const mask_bit: u8 = if (mask != null) 0x80 else 0;
    var n: usize = 2;
    if (payload.len < 126) {
        head[1] = mask_bit | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 0xFFFF) {
        head[1] = mask_bit | 126;
        std.mem.writeInt(u16, head[2..4], @intCast(payload.len), .big);
        n = 4;
    } else {
        head[1] = mask_bit | 127;
        std.mem.writeInt(u64, head[2..10], payload.len, .big);
        n = 10;
    }
    if (mask) |m| {
        @memcpy(head[n..][0..4], &m);
        n += 4;
    }
    try w.writeAll(head[0..n]);
    const m = mask orelse return w.writeAll(payload);
    // Mask through a small scratch buffer so the caller's payload stays const.
    var scratch: [1024]u8 = undefined;
    var off: usize = 0;
    while (off < payload.len) {
        const chunk = @min(scratch.len, payload.len - off);
        @memcpy(scratch[0..chunk], payload[off..][0..chunk]);
        applyMask(m, off, scratch[0..chunk]);
        try w.writeAll(scratch[0..chunk]);
        off += chunk;
    }
}

pub fn readHeader(r: *Io.Reader) (Io.Reader.Error || ProtocolError)!Header {
    const b = try r.takeArray(2);
    if (b[0] & 0x70 != 0) return error.ProtocolViolation; // RSV1-3 without extensions
    const opcode: Opcode = @enumFromInt(@as(u4, @truncate(b[0])));
    switch (opcode) {
        .continuation, .text, .binary, .close, .ping, .pong => {},
        _ => return error.ProtocolViolation,
    }
    const fin = b[0] & 0x80 != 0;
    const masked = b[1] & 0x80 != 0;
    var len: u64 = b[1] & 0x7F;
    if (len == 126) {
        len = try r.takeInt(u16, .big);
    } else if (len == 127) {
        len = try r.takeInt(u64, .big);
    }
    if (opcode.isControl() and (len > 125 or !fin)) return error.ProtocolViolation;
    const mask: ?[4]u8 = if (masked) (try r.takeArray(4)).* else null;
    return .{ .fin = fin, .opcode = opcode, .mask = mask, .len = len };
}

/// One step of the receive side: a complete data message or a control frame.
pub const Event = union(enum) {
    /// A complete (possibly reassembled) message; the slice is owned by the
    /// `Assembler` and valid until its next `next` call.
    text: []const u8,
    binary: []const u8,
    ping: []const u8,
    pong: []const u8,
    close: struct { code: ?u16, reason: []const u8 },
};

/// Reassembles fragmented messages; control frames may interleave fragments.
pub const Assembler = struct {
    message: std.ArrayList(u8) = .empty,
    /// Opcode of the message being reassembled, if any.
    partial: ?Opcode = null,
    control: [125]u8 = undefined,
    max_message_len: usize = 256 * 1024 * 1024,

    pub fn deinit(a: *Assembler, gpa: Allocator) void {
        a.message.deinit(gpa);
    }

    pub const Error = Io.Reader.Error || ProtocolError || Allocator.Error;

    pub fn next(a: *Assembler, gpa: Allocator, r: *Io.Reader) Error!Event {
        if (a.partial == null) a.message.clearRetainingCapacity();
        while (true) {
            const h = try readHeader(r);
            if (h.opcode.isControl()) {
                const body = a.control[0..@intCast(h.len)];
                try r.readSliceAll(body);
                if (h.mask) |m| applyMask(m, 0, body);
                switch (h.opcode) {
                    .ping => return .{ .ping = body },
                    .pong => return .{ .pong = body },
                    .close => {
                        if (body.len >= 2) return .{ .close = .{
                            .code = std.mem.readInt(u16, body[0..2], .big),
                            .reason = body[2..],
                        } };
                        return .{ .close = .{ .code = null, .reason = "" } };
                    },
                    else => unreachable,
                }
            }
            switch (h.opcode) {
                .continuation => if (a.partial == null) return error.ProtocolViolation,
                .text, .binary => {
                    if (a.partial != null) return error.ProtocolViolation;
                    a.partial = h.opcode;
                },
                else => unreachable,
            }
            if (h.len > a.max_message_len - a.message.items.len) return error.MessageTooLarge;
            const start = a.message.items.len;
            const body = try a.message.addManyAsSlice(gpa, @intCast(h.len));
            try r.readSliceAll(body);
            if (h.mask) |m| applyMask(m, 0, a.message.items[start..]);
            if (h.fin) {
                const op = a.partial.?;
                a.partial = null;
                return if (op == .text) .{ .text = a.message.items } else .{ .binary = a.message.items };
            }
        }
    }
};

pub const HandshakeError = error{
    /// The server answered with a non-101 status.
    UpgradeRejected,
    /// The engine refused the upgrade (403): an `Origin` header slipped in, or
    /// something else owns the port.
    Forbidden,
    /// The response was not a well-formed WebSocket upgrade.
    BadHandshake,
};

const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// `Sec-WebSocket-Accept` for a given `Sec-WebSocket-Key`.
pub fn acceptKey(key: []const u8) [28]u8 {
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(ws_guid);
    var digest: [20]u8 = undefined;
    sha.final(&digest);
    var out: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&out, &digest);
    return out;
}

/// Perform the client upgrade. `key` is the base64 of 16 random bytes.
/// Never sends `Origin`.
pub fn handshake(r: *Io.Reader, w: *Io.Writer, host: []const u8, path: []const u8, key: []const u8) (Io.Reader.Error || Io.Writer.Error || HandshakeError || error{StreamTooLong})!void {
    try w.print(
        "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
        .{ path, host, key },
    );
    try w.flush();

    const status = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
    // "HTTP/1.1 101 Switching Protocols"
    var it = std.mem.tokenizeScalar(u8, status, ' ');
    _ = it.next() orelse return error.BadHandshake;
    const code = it.next() orelse return error.BadHandshake;
    const ok = std.mem.eql(u8, code, "101");
    var accept_ok = false;
    var upgrade_ok = false;
    const expected = acceptKey(key);
    while (true) {
        const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
        if (line.len == 0) break;
        const colon = std.mem.findScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "sec-websocket-accept")) {
            accept_ok = std.mem.eql(u8, value, &expected);
        } else if (std.ascii.eqlIgnoreCase(name, "upgrade")) {
            upgrade_ok = std.ascii.eqlIgnoreCase(value, "websocket");
        }
    }
    if (!ok) return if (std.mem.eql(u8, code, "403")) error.Forbidden else error.UpgradeRejected;
    if (!accept_ok or !upgrade_ok) return error.BadHandshake;
}

/// A WebSocket connection over TCP. Heap-allocated (the stream reader/writer
/// hold pointers into its buffers). Reading is single-consumer; `sendText`,
/// `sendPong` and `close` are thread-safe with respect to each other and to
/// a concurrent reader.
pub const Conn = struct {
    gpa: Allocator,
    io: Io,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    write_mutex: Io.Mutex = .init,
    assembler: Assembler = .{},
    close_sent: bool = false,
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [16 * 1024]u8 = undefined,

    pub const ConnectOptions = struct {
        /// `Host` header value; defaults to the dialed address.
        host: ?[]const u8 = null,
        path: []const u8 = "/",
        /// Bound on the upgrade exchange. A stranger holding the port that
        /// accepts TCP but never answers would otherwise hang the caller.
        handshake_timeout: Io.Duration = .fromSeconds(5),
        max_message_len: usize = 256 * 1024 * 1024,
    };

    pub const ConnectError = net.IpAddress.ConnectError || Allocator.Error || HandshakeError ||
        net.Stream.Reader.Error || net.Stream.Writer.Error || error{ EndOfStream, StreamTooLong, HandshakeTimeout };

    pub fn connect(gpa: Allocator, io: Io, address: net.IpAddress, options: ConnectOptions) ConnectError!*Conn {
        // Loopback connect is immediate (accept or refuse); the Threaded
        // backend does not implement connect timeouts in 0.17 anyway.
        const stream = try address.connect(io, .{ .mode = .stream });
        errdefer stream.close(io);

        const c = try gpa.create(Conn);
        errdefer gpa.destroy(c);
        c.* = .{
            .gpa = gpa,
            .io = io,
            .stream = stream,
            .reader = undefined,
            .writer = undefined,
        };
        c.assembler.max_message_len = options.max_message_len;
        c.reader = stream.reader(io, &c.read_buf);
        c.writer = stream.writer(io, &c.write_buf);

        var host_buf: [64]u8 = undefined;
        const host = options.host orelse std.fmt.bufPrint(&host_buf, "{f}", .{address}) catch unreachable;
        var raw_key: [16]u8 = undefined;
        io.random(&raw_key);
        var key: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key, &raw_key);

        // Watchdog: shut the socket down if the upgrade stalls, which turns
        // the blocked read into EndOfStream. Stopped through `StopTimer`, never
        // `Future.cancel`: on a thread with SIGIO blocked (any connect started
        // from zpui's macOS background executor) `cancel` waited out the whole
        // timeout, 5 s on every boot (stop_timer.zig).
        var fired = std.atomic.Value(bool).init(false);
        var timer: StopTimer = .{};
        var watchdog: ?Io.Future(void) = io.concurrent(watchdogMain, .{ io, stream, options.handshake_timeout, &fired, &timer }) catch null;
        defer if (watchdog) |*w| timer.stopAndAwait(io, w);

        handshake(&c.reader.interface, &c.writer.interface, host, options.path, &key) catch |err| {
            if (fired.load(.acquire)) return error.HandshakeTimeout;
            return switch (err) {
                error.ReadFailed => c.reader.err.?,
                error.WriteFailed => c.writer.err.?,
                else => |e| e,
            };
        };
        return c;
    }

    fn watchdogMain(io: Io, stream: net.Stream, timeout: Io.Duration, fired: *std.atomic.Value(bool), timer: *StopTimer) void {
        if (!timer.sleep(io, timeout)) return; // stopped: handshake finished
        fired.store(true, .release);
        stream.shutdown(io, .both) catch {};
    }

    /// Close the socket and free. Call only after any reader has stopped.
    pub fn deinit(c: *Conn) void {
        c.assembler.deinit(c.gpa);
        c.stream.close(c.io);
        c.gpa.destroy(c);
    }

    pub const SendError = error{ ConnectionClosed, WriteFailed };

    fn send(c: *Conn, opcode: Opcode, payload: []const u8) SendError!void {
        c.write_mutex.lockUncancelable(c.io);
        defer c.write_mutex.unlock(c.io);
        if (c.close_sent) return error.ConnectionClosed;
        var mask: [4]u8 = undefined;
        c.io.random(&mask);
        writeFrame(&c.writer.interface, opcode, true, payload, mask) catch return error.WriteFailed;
        c.writer.interface.flush() catch return error.WriteFailed;
    }

    pub fn sendText(c: *Conn, payload: []const u8) SendError!void {
        return c.send(.text, payload);
    }

    pub fn sendPong(c: *Conn, payload: []const u8) SendError!void {
        return c.send(.pong, payload);
    }

    /// Send a close frame (once), best effort.
    pub fn sendClose(c: *Conn, code: u16) void {
        c.write_mutex.lockUncancelable(c.io);
        defer c.write_mutex.unlock(c.io);
        if (c.close_sent) return;
        c.close_sent = true;
        var body: [2]u8 = undefined;
        std.mem.writeInt(u16, &body, code, .big);
        var mask: [4]u8 = undefined;
        c.io.random(&mask);
        writeFrame(&c.writer.interface, .close, true, &body, mask) catch return;
        c.writer.interface.flush() catch {};
    }

    /// Unblock a concurrent `readText` (it returns `error.ConnectionClosed`).
    pub fn shutdown(c: *Conn) void {
        c.stream.shutdown(c.io, .both) catch {};
    }

    pub const ReadError = Allocator.Error || ProtocolError || error{ ConnectionClosed, ReadFailed };

    /// Block until the next text message. Answers pings, skips binary/pong
    /// frames, and completes the close handshake. The returned slice is valid
    /// until the next call.
    pub fn readText(c: *Conn) ReadError![]const u8 {
        while (true) {
            const ev = c.assembler.next(c.gpa, &c.reader.interface) catch |err| switch (err) {
                error.EndOfStream => return error.ConnectionClosed,
                error.ReadFailed => return if (c.reader.err) |e| switch (e) {
                    error.Canceled => error.ConnectionClosed,
                    else => error.ReadFailed,
                } else error.ReadFailed,
                else => |e| return e,
            };
            switch (ev) {
                .text => |t| return t,
                .binary, .pong => {},
                .ping => |p| c.sendPong(p) catch {},
                .close => |cl| {
                    c.sendClose(cl.code orelse 1000);
                    return error.ConnectionClosed;
                },
            }
        }
    }
};

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "mask is an involution and offset-aware" {
    const mask = [4]u8{ 0x37, 0xfa, 0x21, 0x3d };
    var buf = "Hello, WebSocket!".*;
    applyMask(mask, 0, &buf);
    try testing.expect(!std.mem.eql(u8, &buf, "Hello, WebSocket!"));
    // Unmask in two pieces at different offsets.
    applyMask(mask, 0, buf[0..5]);
    applyMask(mask, 5, buf[5..]);
    try testing.expectEqualStrings("Hello, WebSocket!", &buf);
}

test "RFC 6455 §5.7 masked 'Hello' example" {
    var out: [32]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    try writeFrame(&w, .text, true, "Hello", .{ 0x37, 0xfa, 0x21, 0x3d });
    try testing.expectEqualSlices(u8, &.{ 0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58 }, w.buffered());

    var r: Io.Reader = .fixed(w.buffered());
    var a: Assembler = .{};
    defer a.deinit(testing.allocator);
    const ev = try a.next(testing.allocator, &r);
    try testing.expectEqualStrings("Hello", ev.text);
}

test "fragmented message with interleaved ping" {
    // RFC example: unmasked "Hel" + "lo" with a ping between.
    var r: Io.Reader = .fixed(&.{
        0x01, 0x03, 'H', 'e', 'l', // text, !fin
        0x89, 0x02, 'h', 'i', // ping "hi"
        0x80, 0x02, 'l', 'o', // continuation, fin
    });
    var a: Assembler = .{};
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("hi", (try a.next(testing.allocator, &r)).ping);
    try testing.expectEqualStrings("Hello", (try a.next(testing.allocator, &r)).text);
}

test "extended lengths round trip (16- and 64-bit)" {
    const gpa = testing.allocator;
    for ([_]usize{ 125, 126, 65535, 65536, 70000 }) |len| {
        const payload = try gpa.alloc(u8, len);
        defer gpa.free(payload);
        for (payload, 0..) |*b, i| b.* = @truncate(i *% 31);
        var aw: Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        // Split in three fragments, masked like a client would.
        const third = len / 3;
        try writeFrame(&aw.writer, .binary, false, payload[0..third], .{ 1, 2, 3, 4 });
        try writeFrame(&aw.writer, .continuation, false, payload[third .. 2 * third], .{ 5, 6, 7, 8 });
        try writeFrame(&aw.writer, .continuation, true, payload[2 * third ..], .{ 9, 10, 11, 12 });
        var r: Io.Reader = .fixed(aw.written());
        var a: Assembler = .{};
        defer a.deinit(gpa);
        const ev = try a.next(gpa, &r);
        try testing.expectEqualSlices(u8, payload, ev.binary);
    }
}

test "protocol violations" {
    var a: Assembler = .{};
    defer a.deinit(testing.allocator);
    {
        var r: Io.Reader = .fixed(&.{ 0x80, 0x01, 'x' }); // continuation with nothing open
        try testing.expectError(error.ProtocolViolation, a.next(testing.allocator, &r));
    }
    {
        var r: Io.Reader = .fixed(&.{ 0x09, 0x00 }); // fragmented ping
        try testing.expectError(error.ProtocolViolation, a.next(testing.allocator, &r));
    }
    {
        var r: Io.Reader = .fixed(&.{ 0xC1, 0x00 }); // RSV1 set
        try testing.expectError(error.ProtocolViolation, a.next(testing.allocator, &r));
    }
    {
        a.max_message_len = 4;
        a.partial = null;
        var r: Io.Reader = .fixed(&.{ 0x81, 0x05, 'h', 'e', 'l', 'l', 'o' });
        try testing.expectError(error.MessageTooLarge, a.next(testing.allocator, &r));
    }
}

test "close frame decodes code and reason" {
    var r: Io.Reader = .fixed(&.{ 0x88, 0x04, 0x03, 0xE8, 'o', 'k' });
    var a: Assembler = .{};
    defer a.deinit(testing.allocator);
    const ev = try a.next(testing.allocator, &r);
    try testing.expectEqual(@as(?u16, 1000), ev.close.code);
    try testing.expectEqualStrings("ok", ev.close.reason);
}

test "handshake: request has no Origin, accept key verified" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    try testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", &acceptKey(key));

    var req: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&req);
    var r: Io.Reader = .fixed("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n" ++
        "Connection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n");
    try handshake(&r, &w, "127.0.0.1:27654", "/", key);
    const sent = w.buffered();
    try testing.expect(std.mem.startsWith(u8, sent, "GET / HTTP/1.1\r\n"));
    try testing.expect(std.ascii.findIgnoreCase(sent, "origin") == null);
    try testing.expect(std.mem.find(u8, sent, "Sec-WebSocket-Key: " ++ key) != null);
}

test "handshake: 403 maps to Forbidden, bad accept rejected" {
    var req: [512]u8 = undefined;
    {
        var w: Io.Writer = .fixed(&req);
        var r: Io.Reader = .fixed("HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n");
        try testing.expectError(error.Forbidden, handshake(&r, &w, "h", "/", "dGhlIHNhbXBsZSBub25jZQ=="));
    }
    {
        var w: Io.Writer = .fixed(&req);
        var r: Io.Reader = .fixed("HTTP/1.1 101 OK\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: nope\r\n\r\n");
        try testing.expectError(error.BadHandshake, handshake(&r, &w, "h", "/", "dGhlIHNhbXBsZSBub25jZQ=="));
    }
}
