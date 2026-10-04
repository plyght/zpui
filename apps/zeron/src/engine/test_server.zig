//! In-process fake engine endpoint for tests: a loopback WebSocket server
//! that performs the upgrade (rejecting `Origin` with 403 like the real
//! engine), then lets a test script exchange raw frames with the client.

const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;
const ws = @import("ws.zig");

pub const Server = struct {
    io: Io,
    listener: net.Server,

    pub fn init(io: Io) !Server {
        const addr: net.IpAddress = .{ .ip4 = .loopback(0) };
        return .{ .io = io, .listener = try addr.listen(io, .{ .reuse_address = true }) };
    }

    pub fn deinit(s: *Server) void {
        s.listener.deinit(s.io);
    }

    pub fn address(s: *const Server) net.IpAddress {
        return s.listener.socket.address;
    }

    /// Accept one connection and complete the upgrade. Returns
    /// `error.OriginRejected` (after answering 403) if the client sent `Origin`.
    pub fn accept(s: *Server, gpa: Allocator) !*Peer {
        const stream = try s.listener.accept(s.io);
        errdefer stream.close(s.io);
        const p = try gpa.create(Peer);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .io = s.io, .stream = stream, .reader = undefined, .writer = undefined };
        p.reader = stream.reader(s.io, &p.read_buf);
        p.writer = stream.writer(s.io, &p.write_buf);
        const r = &p.reader.interface;
        const w = &p.writer.interface;

        var key: ?[]const u8 = null;
        var key_buf: [64]u8 = undefined;
        var origin = false;
        _ = try r.takeDelimiterInclusive('\n'); // request line
        while (true) {
            const line = std.mem.trimEnd(u8, try r.takeDelimiterInclusive('\n'), "\r\n");
            if (line.len == 0) break;
            const colon = std.mem.findScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " ");
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");
            if (std.ascii.eqlIgnoreCase(name, "origin")) origin = true;
            if (std.ascii.eqlIgnoreCase(name, "sec-websocket-key")) {
                @memcpy(key_buf[0..value.len], value);
                key = key_buf[0..value.len];
            }
        }
        if (origin) {
            try w.writeAll("HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n");
            try w.flush();
            return error.OriginRejected;
        }
        const accept_key = ws.acceptKey(key orelse return error.BadHandshake);
        try w.print("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n", .{&accept_key});
        try w.flush();
        return p;
    }
};

pub const Peer = struct {
    gpa: Allocator,
    io: Io,
    stream: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    assembler: ws.Assembler = .{},
    read_buf: [16 * 1024]u8 = undefined,
    write_buf: [16 * 1024]u8 = undefined,

    pub fn deinit(p: *Peer) void {
        p.assembler.deinit(p.gpa);
        p.stream.close(p.io);
        p.gpa.destroy(p);
    }

    /// Next client event (frames arrive masked; the assembler unmasks).
    pub fn recv(p: *Peer) !ws.Event {
        return p.assembler.next(p.gpa, &p.reader.interface);
    }

    /// Next text message, failing on anything else.
    pub fn recvText(p: *Peer) ![]const u8 {
        return switch (try p.recv()) {
            .text => |t| t,
            else => error.UnexpectedFrame,
        };
    }

    /// Unmasked server frame.
    pub fn sendFrame(p: *Peer, opcode: ws.Opcode, fin: bool, payload: []const u8) !void {
        try ws.writeFrame(&p.writer.interface, opcode, fin, payload, null);
        try p.writer.interface.flush();
    }

    pub fn sendText(p: *Peer, payload: []const u8) !void {
        return p.sendFrame(.text, true, payload);
    }

    /// Read a client request and return its id (and method, if any).
    pub fn recvRequest(p: *Peer, method_out: ?*[64]u8) !struct { id: u64, method_len: usize, cancel: bool } {
        const text = try p.recvText();
        const parsed = try std.json.parseFromSlice(std.json.Value, p.gpa, text, .{});
        defer parsed.deinit();
        const obj = parsed.value.object;
        const id: u64 = @intCast(obj.get("id").?.integer);
        var len: usize = 0;
        if (obj.get("method")) |m| if (method_out) |out| {
            len = m.string.len;
            @memcpy(out[0..len], m.string);
        };
        const cancel = if (obj.get("cancel")) |cv| cv.bool else false;
        return .{ .id = id, .method_len = len, .cancel = cancel };
    }
};
