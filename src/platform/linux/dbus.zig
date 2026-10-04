//! Minimal pure-Zig D-Bus client pieces shared by the settings portal watcher
//! (appearance.zig) and the FileChooser portal (file_dialog.zig): the
//! little-endian wire format (marshalling method calls with arbitrary bodies,
//! parsing replies/signals, reading nested containers) and a session-bus
//! connection with SASL `EXTERNAL` auth.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

// ---------------------------------------------------------------------------------------
// Wire format
// ---------------------------------------------------------------------------------------

pub const MessageType = enum(u8) { invalid = 0, method_call = 1, method_return = 2, err = 3, signal = 4, _ };

pub const HeaderField = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    _,
};

/// Little-endian marshaller for method calls whose arguments are all strings.
pub const Builder = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    pub fn pad(b: *Builder, alignment: usize) !void {
        while (b.buf.items.len % alignment != 0) try b.buf.append(b.gpa, 0);
    }
    pub fn u8_(b: *Builder, v: u8) !void {
        try b.buf.append(b.gpa, v);
    }
    pub fn u32_(b: *Builder, v: u32) !void {
        try b.pad(4);
        try b.buf.appendSlice(b.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, v)));
    }
    pub fn str(b: *Builder, s: []const u8) !void {
        try b.u32_(@intCast(s.len));
        try b.buf.appendSlice(b.gpa, s);
        try b.u8_(0);
    }
    pub fn sig(b: *Builder, s: []const u8) !void {
        try b.u8_(@intCast(s.len));
        try b.buf.appendSlice(b.gpa, s);
        try b.u8_(0);
    }
    pub fn i32_(b: *Builder, v: i32) !void {
        try b.u32_(@bitCast(v));
    }
    pub fn i16_(b: *Builder, v: i16) !void {
        try b.pad(2);
        try b.buf.appendSlice(b.gpa, std.mem.asBytes(&std.mem.nativeToLittle(i16, v)));
    }
    pub fn f64_(b: *Builder, v: f64) !void {
        try b.pad(8);
        try b.buf.appendSlice(b.gpa, std.mem.asBytes(&std.mem.nativeToLittle(u64, @bitCast(v))));
    }
    pub fn field(b: *Builder, code: HeaderField, type_sig: u8, value: []const u8) !void {
        try b.pad(8);
        try b.u8_(@intFromEnum(code));
        try b.sig(&.{type_sig});
        if (type_sig == 'g') try b.sig(value) else try b.str(value);
    }
};

pub const Call = struct {
    serial: u32,
    destination: []const u8,
    path: []const u8,
    interface: []const u8,
    member: []const u8,
    /// String arguments (signature "s" × len).
    args: []const []const u8 = &.{},
    /// A pre-marshalled body (built with a `Builder` starting at offset 0) and its
    /// signature; replaces `args` when set.
    body: ?struct { bytes: []const u8, signature: []const u8 } = null,
};

/// Marshals a METHOD_CALL; caller frees.
pub fn buildCall(gpa: Allocator, call: Call) ![]u8 {
    // Body first (its length goes in the header).
    var body: Builder = .{ .gpa = gpa };
    defer body.buf.deinit(gpa);
    if (call.body) |raw| try body.buf.appendSlice(gpa, raw.bytes) else for (call.args) |a| try body.str(a);

    var b: Builder = .{ .gpa = gpa };
    errdefer b.buf.deinit(gpa);
    try b.u8_('l');
    try b.u8_(@intFromEnum(MessageType.method_call));
    try b.u8_(0);
    try b.u8_(1);
    try b.u32_(@intCast(body.buf.items.len));
    try b.u32_(call.serial);
    const fields_len_at = b.buf.items.len;
    try b.u32_(0); // patched below
    const fields_start = b.buf.items.len;
    try b.field(.path, 'o', call.path);
    try b.field(.destination, 's', call.destination);
    try b.field(.interface, 's', call.interface);
    try b.field(.member, 's', call.member);
    if (call.body) |raw| {
        if (raw.signature.len > 0) try b.field(.signature, 'g', raw.signature);
    } else if (call.args.len > 0) {
        var sig_buf: [16]u8 = undefined;
        const n = @min(call.args.len, sig_buf.len);
        @memset(sig_buf[0..n], 's');
        try b.field(.signature, 'g', sig_buf[0..n]);
    }
    const fields_len: u32 = @intCast(b.buf.items.len - fields_start);
    @memcpy(b.buf.items[fields_len_at..][0..4], std.mem.asBytes(&std.mem.nativeToLittle(u32, fields_len)));
    try b.pad(8);
    try b.buf.appendSlice(gpa, body.buf.items);
    return b.buf.toOwnedSlice(gpa);
}

/// Any outgoing message (method returns, errors and signals for objects we export).
pub const OutMessage = struct {
    type: MessageType,
    serial: u32,
    flags: u8 = 0,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    signature: []const u8 = "",
    /// Marshalled body (aligned from offset 0).
    body: []const u8 = "",
};

/// Marshals any message; caller frees.
pub fn buildMessage(gpa: Allocator, m: OutMessage) ![]u8 {
    var b: Builder = .{ .gpa = gpa };
    errdefer b.buf.deinit(gpa);
    try b.u8_('l');
    try b.u8_(@intFromEnum(m.type));
    try b.u8_(m.flags);
    try b.u8_(1);
    try b.u32_(@intCast(m.body.len));
    try b.u32_(m.serial);
    const fields_len_at = b.buf.items.len;
    try b.u32_(0);
    const fields_start = b.buf.items.len;
    if (m.path) |v| try b.field(.path, 'o', v);
    if (m.interface) |v| try b.field(.interface, 's', v);
    if (m.member) |v| try b.field(.member, 's', v);
    if (m.error_name) |v| try b.field(.error_name, 's', v);
    if (m.reply_serial) |v| {
        try b.pad(8);
        try b.u8_(@intFromEnum(HeaderField.reply_serial));
        try b.sig("u");
        try b.u32_(v);
    }
    if (m.destination) |v| try b.field(.destination, 's', v);
    if (m.signature.len > 0) try b.field(.signature, 'g', m.signature);
    const fields_len: u32 = @intCast(b.buf.items.len - fields_start);
    @memcpy(b.buf.items[fields_len_at..][0..4], std.mem.asBytes(&std.mem.nativeToLittle(u32, fields_len)));
    try b.pad(8);
    try b.buf.appendSlice(gpa, m.body);
    return b.buf.toOwnedSlice(gpa);
}

/// A parsed message; slices point into the receive buffer.
pub const Message = struct {
    type: MessageType,
    big_endian: bool,
    serial: u32,
    reply_serial: ?u32 = null,
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    error_name: []const u8 = "",
    sender: []const u8 = "",
    destination: []const u8 = "",
    signature: []const u8 = "",
    body: []const u8 = "",
    /// Header flags (bit 0: NO_REPLY_EXPECTED).
    flags: u8 = 0,
};

/// Bounds-checked reader over a message region (alignment is relative to `base`).
pub const Reader = struct {
    bytes: []const u8,
    pos: usize,
    big: bool,

    pub fn alignTo(r: *Reader, a: usize) !void {
        const next = std.mem.alignForward(usize, r.pos, a);
        if (next > r.bytes.len) return error.Truncated;
        r.pos = next;
    }
    pub fn byte(r: *Reader) !u8 {
        if (r.pos >= r.bytes.len) return error.Truncated;
        defer r.pos += 1;
        return r.bytes[r.pos];
    }
    pub fn u32_(r: *Reader) !u32 {
        try r.alignTo(4);
        if (r.pos + 4 > r.bytes.len) return error.Truncated;
        defer r.pos += 4;
        const v = std.mem.bytesToValue(u32, r.bytes[r.pos..][0..4]);
        return if (r.big) std.mem.bigToNative(u32, v) else std.mem.littleToNative(u32, v);
    }
    pub fn str(r: *Reader) ![]const u8 {
        const n = try r.u32_();
        if (r.pos + n + 1 > r.bytes.len) return error.Truncated;
        defer r.pos += n + 1;
        return r.bytes[r.pos..][0..n];
    }
    pub fn sig(r: *Reader) ![]const u8 {
        const n = try r.byte();
        if (r.pos + n + 1 > r.bytes.len) return error.Truncated;
        defer r.pos += @as(usize, n) + 1;
        return r.bytes[r.pos..][0..n];
    }
    /// Skips one complete value of single type `t` (enough for header fields).
    pub fn skip(r: *Reader, t: []const u8) !void {
        if (t.len == 0) return error.BadSignature;
        switch (t[0]) {
            'y' => _ = try r.byte(),
            'b', 'u', 'i', 'h' => _ = try r.u32_(),
            'n', 'q' => {
                try r.alignTo(2);
                r.pos += 2;
            },
            'x', 't', 'd' => {
                try r.alignTo(8);
                r.pos += 8;
            },
            's', 'o' => _ = try r.str(),
            'g' => _ = try r.sig(),
            'v' => {
                const inner = try r.sig();
                try r.skip(inner);
            },
            '(', '{' => {
                try r.alignTo(8);
                var rest = t[1 .. (try completeTypeLen(t)) - 1];
                while (rest.len > 0) {
                    const n = try completeTypeLen(rest);
                    try r.skip(rest[0..n]);
                    rest = rest[n..];
                }
            },
            'a' => {
                const n = try r.u32_();
                const elem_align: usize = switch (if (t.len > 1) t[1] else 'y') {
                    'x', 't', 'd', '(', '{' => 8,
                    'n', 'q' => 2,
                    'y', 'g', 'v' => 1,
                    else => 4,
                };
                try r.alignTo(elem_align);
                r.pos += n;
            },
            else => return error.Unsupported,
        }
        if (r.pos > r.bytes.len) return error.Truncated;
    }
};

/// Length of the first complete type in signature `t` (`as` → 2, `a{sv}` → 5).
pub fn completeTypeLen(t: []const u8) ParseError!usize {
    if (t.len == 0) return error.BadSignature;
    switch (t[0]) {
        'a' => return 1 + try completeTypeLen(t[1..]),
        '(', '{' => {
            const close: u8 = if (t[0] == '(') ')' else '}';
            var i: usize = 1;
            while (i < t.len and t[i] != close) i += try completeTypeLen(t[i..]);
            if (i >= t.len) return error.BadSignature;
            return i + 1;
        },
        else => return 1,
    }
}

/// Builder helpers for message bodies (all little-endian, aligned from offset 0).
pub const Body = struct {
    /// Begin an array: writes the length placeholder and pads to the element alignment.
    /// Pass the result to `endArray`.
    pub fn beginArray(b: *Builder, elem_align: usize) !struct { len_at: usize, start: usize } {
        try b.u32_(0);
        const len_at = b.buf.items.len - 4;
        try b.pad(elem_align);
        return .{ .len_at = len_at, .start = b.buf.items.len };
    }
    pub fn endArray(b: *Builder, a: anytype) void {
        const n: u32 = @intCast(b.buf.items.len - a.start);
        @memcpy(b.buf.items[a.len_at..][0..4], std.mem.asBytes(&std.mem.nativeToLittle(u32, n)));
    }
    /// One `{sv}` dict entry whose variant holds a value of type `inner_sig`; the caller
    /// writes the value right after.
    pub fn dictEntry(b: *Builder, key: []const u8, inner_sig: []const u8) !void {
        try b.pad(8);
        try b.str(key);
        try b.sig(inner_sig);
    }
    pub fn boolean(b: *Builder, v: bool) !void {
        try b.u32_(@intFromBool(v));
    }
    /// A byte string with a trailing NUL (`ay`, how portals pass labels/paths).
    pub fn byteString(b: *Builder, s: []const u8) !void {
        try b.u32_(@intCast(s.len + 1));
        try b.buf.appendSlice(b.gpa, s);
        try b.u8_(0);
    }
};

pub const ParseError = error{ Truncated, BadSignature, Unsupported, BadMessage };

/// Total length of the first message in `bytes`, or null while incomplete.
pub fn messageLength(bytes: []const u8) ParseError!?usize {
    if (bytes.len < 16) return null;
    const big = switch (bytes[0]) {
        'l' => false,
        'B' => true,
        else => return error.BadMessage,
    };
    const rd = struct {
        fn f(b: []const u8, at: usize, be: bool) u32 {
            const v = std.mem.bytesToValue(u32, b[at..][0..4]);
            return if (be) std.mem.bigToNative(u32, v) else std.mem.littleToNative(u32, v);
        }
    }.f;
    const body_len = rd(bytes, 4, big);
    const fields_len = rd(bytes, 12, big);
    if (body_len > 64 << 20 or fields_len > 64 << 20) return error.BadMessage;
    const total = std.mem.alignForward(usize, 16 + @as(usize, fields_len), 8) + body_len;
    return if (bytes.len >= total) total else null;
}

/// Parses one complete message (`bytes.len` == `messageLength`).
pub fn parseMessage(bytes: []const u8) ParseError!Message {
    const len = (try messageLength(bytes)) orelse return error.Truncated;
    const msg_bytes = bytes[0..len];
    var r: Reader = .{ .bytes = msg_bytes, .pos = 0, .big = msg_bytes[0] == 'B' };
    _ = try r.byte();
    var m: Message = .{ .type = @enumFromInt(try r.byte()), .big_endian = r.big, .serial = 0 };
    m.flags = try r.byte();
    _ = try r.byte(); // version
    const body_len = try r.u32_();
    m.serial = try r.u32_();
    const fields_len = try r.u32_();
    const fields_end = r.pos + fields_len;
    if (fields_end > msg_bytes.len) return error.Truncated;
    while (r.pos < fields_end) {
        try r.alignTo(8);
        if (r.pos >= fields_end) break;
        const code: HeaderField = @enumFromInt(try r.byte());
        const t = try r.sig();
        if (t.len != 1) {
            try r.skip(t);
            continue;
        }
        switch (code) {
            .path, .interface, .member, .error_name, .destination, .sender => {
                if (t[0] != 's' and t[0] != 'o') return error.BadMessage;
                const s = try r.str();
                switch (code) {
                    .path => m.path = s,
                    .interface => m.interface = s,
                    .member => m.member = s,
                    .error_name => m.error_name = s,
                    .sender => m.sender = s,
                    .destination => m.destination = s,
                    else => {},
                }
            },
            .reply_serial => {
                if (t[0] != 'u') return error.BadMessage;
                m.reply_serial = try r.u32_();
            },
            .signature => {
                if (t[0] != 'g') return error.BadMessage;
                m.signature = try r.sig();
            },
            else => try r.skip(t),
        }
    }
    const body_start = std.mem.alignForward(usize, fields_end, 8);
    if (body_start + body_len > msg_bytes.len) return error.Truncated;
    m.body = msg_bytes[body_start..][0..body_len];
    return m;
}

// ---------------------------------------------------------------------------------------
// Session bus connection
// ---------------------------------------------------------------------------------------

/// The session bus socket from `DBUS_SESSION_BUS_ADDRESS` (`unix:path=` /
/// `unix:abstract=`; the first unix entry wins), else `$XDG_RUNTIME_DIR/bus`.
pub fn sessionBusAddress(address: ?[]const u8, runtime_dir: ?[]const u8, out: *linux.sockaddr.un) ?linux.socklen_t {
    out.* = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    if (address) |addr| {
        var entries = std.mem.splitScalar(u8, addr, ';');
        while (entries.next()) |entry| {
            if (!std.mem.startsWith(u8, entry, "unix:")) continue;
            var kv = std.mem.splitScalar(u8, entry["unix:".len..], ',');
            while (kv.next()) |pair| {
                const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
                const key = pair[0..eq];
                const value = pair[eq + 1 ..];
                if (std.mem.eql(u8, key, "path")) {
                    if (value.len >= out.path.len) return null;
                    @memcpy(out.path[0..value.len], value);
                    return @intCast(@offsetOf(linux.sockaddr.un, "path") + value.len + 1);
                }
                if (std.mem.eql(u8, key, "abstract")) {
                    if (value.len + 1 > out.path.len) return null;
                    out.path[0] = 0;
                    @memcpy(out.path[1..][0..value.len], value);
                    return @intCast(@offsetOf(linux.sockaddr.un, "path") + 1 + value.len);
                }
            }
        }
    }
    const dir = runtime_dir orelse return null;
    const suffix = "/bus";
    if (dir.len + suffix.len >= out.path.len) return null;
    @memcpy(out.path[0..dir.len], dir);
    @memcpy(out.path[dir.len..][0..suffix.len], suffix);
    return @intCast(@offsetOf(linux.sockaddr.un, "path") + dir.len + suffix.len + 1);
}

pub fn ok(rc: usize) bool {
    return linux.errno(rc) == .SUCCESS;
}

/// Waits up to `timeout_ms` for `fd` to become readable.
pub fn waitReadable(fd: linux.fd_t, timeout_ms: i32) bool {
    var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    const rc = linux.poll(&pfd, 1, timeout_ms);
    return ok(rc) and rc > 0 and (pfd[0].revents & linux.POLL.IN) != 0;
}

pub fn writeAll(fd: linux.fd_t, bytes: []const u8) bool {
    var off: usize = 0;
    var spins: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => {},
            .AGAIN => {
                spins += 1;
                if (spins > 50) return false;
                var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
                _ = linux.poll(&pfd, 1, 20);
            },
            else => return false,
        }
    }
    return true;
}

/// Connects + authenticates (SASL EXTERNAL). Returns a nonblocking fd or null.
pub fn connectBus(address: ?[]const u8, runtime_dir: ?[]const u8) ?linux.fd_t {
    var sa: linux.sockaddr.un = undefined;
    const sa_len = sessionBusAddress(address, runtime_dir, &sa) orelse return null;
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (!ok(rc)) return null;
    const fd: linux.fd_t = @intCast(rc);
    const crc = linux.connect(fd, &sa, sa_len);
    if (!ok(crc)) {
        if (linux.errno(crc) != .INPROGRESS and linux.errno(crc) != .AGAIN) {
            _ = linux.close(fd);
            return null;
        }
        var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
        if (!ok(linux.poll(&pfd, 1, 200)) or (pfd[0].revents & linux.POLL.OUT) == 0) {
            _ = linux.close(fd);
            return null;
        }
    }
    // "\0AUTH EXTERNAL <hex(uid as decimal text)>\r\n"
    var uid_buf: [16]u8 = undefined;
    const uid_txt = std.fmt.bufPrint(&uid_buf, "{d}", .{linux.getuid()}) catch unreachable;
    var auth_buf: [80]u8 = undefined;
    var w: usize = 0;
    const head = "\x00AUTH EXTERNAL ";
    @memcpy(auth_buf[0..head.len], head);
    w = head.len;
    for (uid_txt) |ch| {
        _ = std.fmt.bufPrint(auth_buf[w..][0..2], "{x:0>2}", .{ch}) catch unreachable;
        w += 2;
    }
    auth_buf[w] = '\r';
    auth_buf[w + 1] = '\n';
    w += 2;
    if (!writeAll(fd, auth_buf[0..w])) {
        _ = linux.close(fd);
        return null;
    }
    var line: [256]u8 = undefined;
    var got: usize = 0;
    while (std.mem.indexOf(u8, line[0..got], "\r\n") == null) {
        if (got == line.len or !waitReadable(fd, 300)) {
            _ = linux.close(fd);
            return null;
        }
        const n = linux.read(fd, line[got..].ptr, line.len - got);
        if (!ok(n) or n == 0) {
            if (linux.errno(n) == .AGAIN or linux.errno(n) == .INTR) continue;
            _ = linux.close(fd);
            return null;
        }
        got += n;
    }
    if (!std.mem.startsWith(u8, line[0..got], "OK ")) {
        _ = linux.close(fd);
        return null;
    }
    if (!writeAll(fd, "BEGIN\r\n")) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}


// ---------------------------------------------------------------------------------------
// Blocking connection helper (shared by file_dialog.zig's portal flow and
// notifications.zig): serials, buffered receive, reply matching.
// ---------------------------------------------------------------------------------------

pub const Connection = struct {
    gpa: Allocator,
    fd: linux.fd_t,
    rx: std.ArrayList(u8) = .empty,
    serial: u32 = 1,
    /// Bytes of `rx` consumed by the message last returned from `next`.
    consumed: usize = 0,
    /// The bus-assigned unique name (after `hello`).
    unique_name_buf: [128]u8 = undefined,
    unique_name_len: usize = 0,

    /// Connect + authenticate + `Hello`. Null when there is no session bus.
    pub fn open(gpa: Allocator, address: ?[]const u8, runtime_dir: ?[]const u8) ?Connection {
        const fd = connectBus(address, runtime_dir) orelse return null;
        var c: Connection = .{ .gpa = gpa, .fd = fd };
        c.hello() catch {
            c.deinit();
            return null;
        };
        return c;
    }

    pub fn deinit(c: *Connection) void {
        _ = linux.close(c.fd);
        c.rx.deinit(c.gpa);
    }

    pub fn uniqueName(c: *const Connection) []const u8 {
        return c.unique_name_buf[0..c.unique_name_len];
    }

    fn hello(c: *Connection) !void {
        const serial = try c.send(.{ .serial = 0, .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "Hello" });
        const m = try c.reply(serial, 2000);
        if (m.type != .method_return) return error.NoBus;
        var r: Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
        const name = try r.str();
        if (name.len > c.unique_name_buf.len) return error.BadMessage;
        @memcpy(c.unique_name_buf[0..name.len], name);
        c.unique_name_len = name.len;
    }

    /// Send a method call (its `serial` is assigned here); returns the serial.
    pub fn send(c: *Connection, call: Call) !u32 {
        var cl = call;
        cl.serial = c.serial;
        c.serial +%= 1;
        if (c.serial == 0) c.serial = 1;
        const bytes = try buildCall(c.gpa, cl);
        defer c.gpa.free(bytes);
        if (!writeAll(c.fd, bytes)) return error.WriteFailed;
        return cl.serial;
    }

    /// Next outgoing serial.
    pub fn nextSerial(c: *Connection) u32 {
        const s = c.serial;
        c.serial +%= 1;
        if (c.serial == 0) c.serial = 1;
        return s;
    }

    /// Send any message (its serial is assigned here); returns the serial.
    pub fn sendMessage(c: *Connection, m: OutMessage) !u32 {
        var out = m;
        out.serial = c.nextSerial();
        const bytes = try buildMessage(c.gpa, out);
        defer c.gpa.free(bytes);
        if (!writeAll(c.fd, bytes)) return error.WriteFailed;
        return out.serial;
    }

    /// `org.freedesktop.DBus.AddMatch(rule)`, waiting for the reply.
    pub fn addMatch(c: *Connection, rule: []const u8) !void {
        const serial = try c.send(.{ .serial = 0, .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "AddMatch", .args = &.{rule} });
        const m = try c.reply(serial, 2000);
        if (m.type == .err) return error.AddMatchFailed;
    }

    /// A complete message already buffered, without reading the socket.
    pub fn buffered(c: *Connection) !?Message {
        c.compact();
        const len = (try messageLength(c.rx.items)) orelse return null;
        c.consumed = len;
        return try parseMessage(c.rx.items[0..len]);
    }

    /// Read whatever the socket has now (nonblocking). Returns false on EOF / error.
    pub fn fill(c: *Connection) bool {
        c.compact();
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = linux.read(c.fd, &chunk, chunk.len);
            switch (linux.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return false;
                    c.rx.appendSlice(c.gpa, chunk[0..n]) catch return false;
                    if (n < chunk.len) return true;
                },
                .INTR => {},
                .AGAIN => return true,
                else => return false,
            }
        }
    }

    fn compact(c: *Connection) void {
        if (c.consumed == 0) return;
        const rest = c.rx.items.len - c.consumed;
        std.mem.copyForwards(u8, c.rx.items[0..rest], c.rx.items[c.consumed..]);
        c.rx.shrinkRetainingCapacity(rest);
        c.consumed = 0;
    }

    /// Next complete message (blocking up to `timeout_ms`, -1 = forever). The returned
    /// message borrows the receive buffer until the next call.
    pub fn next(c: *Connection, timeout_ms: i32) !Message {
        while (true) {
            if (try c.buffered()) |m| return m;
            if (!waitReadable(c.fd, timeout_ms)) return error.Timeout;
            if (!c.fill()) return error.Closed;
        }
    }

    /// Waits for the reply to `serial`, ignoring other traffic.
    pub fn reply(c: *Connection, serial: u32, timeout_ms: i32) !Message {
        while (true) {
            const m = try c.next(timeout_ms);
            if (m.reply_serial == serial) return m;
        }
    }
};
