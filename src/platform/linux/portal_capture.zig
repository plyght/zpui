//! XDG desktop portal pieces of the Appshot backend (zeron `appshots/linux/portal.rs`,
//! which uses ashpd), over the pure-Zig D-Bus client in dbus.zig:
//!
//! - `org.freedesktop.portal.Screenshot`: the `version` / `AvailableTargets` (v3)
//!   properties and `Screenshot(s parent_window, a{sv} options)` with `target`
//!   (1 screen, 2 window, 4 area, 8 active window), `interactive` and `modal`; the
//!   result arrives as `org.freedesktop.portal.Request.Response(u, a{sv})` with `uri`.
//! - `org.freedesktop.portal.GlobalShortcuts`: `CreateSession(a{sv})`,
//!   `BindShortcuts(o session, a(sa{sv}) shortcuts, s parent_window, a{sv})`,
//!   `ConfigureShortcuts(o, s, a{sv})` (v2) and the `Activated(o, s, t, a{sv})` signal;
//!   `org.freedesktop.portal.Session.Close`.
//!
//! Message builders and parsers are pure (unit-tested below); `Portal` drives a
//! blocking `dbus.Connection` on the caller's thread, with an optional wake fd so a
//! long wait (a consent dialog) can be abandoned.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const dbus = @import("dbus.zig");
const file_dialog = @import("file_dialog.zig");

pub const dest = "org.freedesktop.portal.Desktop";
pub const path = "/org/freedesktop/portal/desktop";
pub const screenshot_iface = "org.freedesktop.portal.Screenshot";
pub const shortcuts_iface = "org.freedesktop.portal.GlobalShortcuts";
pub const request_iface = "org.freedesktop.portal.Request";
pub const session_iface = "org.freedesktop.portal.Session";

/// `AvailableTargets` bits.
pub const Target = struct {
    pub const screen: u32 = 1;
    pub const window: u32 = 2;
    pub const area: u32 = 4;
    pub const active_window: u32 = 8;
};

// ---------------------------------------------------------------------------------------
// Message bodies
// ---------------------------------------------------------------------------------------

/// `Screenshot(s parent_window, a{sv} options)`.
pub fn screenshotBody(gpa: Allocator, token: []const u8, target: u32, interactive: bool) ![]u8 {
    var b: dbus.Builder = .{ .gpa = gpa };
    errdefer b.buf.deinit(gpa);
    try b.str("");
    const arr = try dbus.Body.beginArray(&b, 8);
    try dbus.Body.dictEntry(&b, "handle_token", "s");
    try b.str(token);
    try dbus.Body.dictEntry(&b, "modal", "b");
    try dbus.Body.boolean(&b, false);
    try dbus.Body.dictEntry(&b, "interactive", "b");
    try dbus.Body.boolean(&b, interactive);
    try dbus.Body.dictEntry(&b, "target", "u");
    try b.u32_(target);
    dbus.Body.endArray(&b, arr);
    return b.buf.toOwnedSlice(gpa);
}

/// `CreateSession(a{sv} options)`.
pub fn createSessionBody(gpa: Allocator, handle_token: []const u8, session_token: []const u8) ![]u8 {
    var b: dbus.Builder = .{ .gpa = gpa };
    errdefer b.buf.deinit(gpa);
    const arr = try dbus.Body.beginArray(&b, 8);
    try dbus.Body.dictEntry(&b, "handle_token", "s");
    try b.str(handle_token);
    try dbus.Body.dictEntry(&b, "session_handle_token", "s");
    try b.str(session_token);
    dbus.Body.endArray(&b, arr);
    return b.buf.toOwnedSlice(gpa);
}

/// `BindShortcuts(o session, a(sa{sv}) shortcuts, s parent_window, a{sv} options)` with
/// one shortcut carrying `description` and `preferred_trigger`.
pub fn bindShortcutsBody(gpa: Allocator, session: []const u8, id: []const u8, description: []const u8, trigger: []const u8, token: []const u8) ![]u8 {
    var b: dbus.Builder = .{ .gpa = gpa };
    errdefer b.buf.deinit(gpa);
    try b.str(session); // 'o' marshals like 's'
    const list = try dbus.Body.beginArray(&b, 8);
    try b.pad(8);
    try b.str(id);
    const info = try dbus.Body.beginArray(&b, 8);
    try dbus.Body.dictEntry(&b, "description", "s");
    try b.str(description);
    try dbus.Body.dictEntry(&b, "preferred_trigger", "s");
    try b.str(trigger);
    dbus.Body.endArray(&b, info);
    dbus.Body.endArray(&b, list);
    try b.str("");
    const opts = try dbus.Body.beginArray(&b, 8);
    try dbus.Body.dictEntry(&b, "handle_token", "s");
    try b.str(token);
    dbus.Body.endArray(&b, opts);
    return b.buf.toOwnedSlice(gpa);
}

/// `ConfigureShortcuts(o session, s parent_window, a{sv} options)`.
pub fn configureShortcutsBody(gpa: Allocator, session: []const u8) ![]u8 {
    var b: dbus.Builder = .{ .gpa = gpa };
    errdefer b.buf.deinit(gpa);
    try b.str(session);
    try b.str("");
    const opts = try dbus.Body.beginArray(&b, 8);
    dbus.Body.endArray(&b, opts);
    return b.buf.toOwnedSlice(gpa);
}

/// `org.freedesktop.DBus.Properties.Get(s interface, s name)`.
pub fn propertyGetBody(gpa: Allocator, iface: []const u8, name: []const u8) ![]u8 {
    var b: dbus.Builder = .{ .gpa = gpa };
    errdefer b.buf.deinit(gpa);
    try b.str(iface);
    try b.str(name);
    return b.buf.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------------------
// Parsers
// ---------------------------------------------------------------------------------------

/// A `Properties.Get` reply holding a `u` variant (portal `version`, `AvailableTargets`).
pub fn parseU32Variant(m: dbus.Message) !u32 {
    if (m.type != .method_return or !std.mem.eql(u8, m.signature, "v")) return error.BadMessage;
    var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
    const t = try r.sig();
    if (!std.mem.eql(u8, t, "u")) return error.BadMessage;
    return r.u32_();
}

pub const Response = struct {
    /// 0 success, 1 cancelled by the user, 2 other failure.
    code: u32,
    /// The `uri` (Screenshot) or `session_handle` (CreateSession) result, borrowed
    /// from the message.
    value: ?[]const u8 = null,
};

/// `Request.Response(u response, a{sv} results)`, picking the string result `key`.
pub fn parseResponse(m: dbus.Message, key: []const u8) !Response {
    if (!std.mem.eql(u8, m.signature, "ua{sv}")) return error.BadMessage;
    var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
    var out: Response = .{ .code = try r.u32_() };
    const len = try r.u32_();
    try r.alignTo(8);
    const end = r.pos + len;
    if (end > r.bytes.len) return error.Truncated;
    while (r.pos < end) {
        try r.alignTo(8);
        const k = try r.str();
        const t = try r.sig();
        if (std.mem.eql(u8, k, key) and (std.mem.eql(u8, t, "s") or std.mem.eql(u8, t, "o"))) {
            out.value = try r.str();
        } else try r.skip(t);
    }
    return out;
}

/// `GlobalShortcuts.Activated(o session_handle, s shortcut_id, t timestamp, a{sv})`.
pub fn parseActivated(m: dbus.Message) !struct { session: []const u8, id: []const u8 } {
    if (m.signature.len < 2 or m.signature[0] != 'o' or m.signature[1] != 's') return error.BadMessage;
    var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
    const session = try r.str();
    const id = try r.str();
    return .{ .session = session, .id = id };
}

/// The `file://` path of a screenshot URI (owned); null for other schemes.
pub fn pathFromUri(gpa: Allocator, uri: []const u8) !?[]u8 {
    return file_dialog.pathFromUri(gpa, uri);
}

// ---------------------------------------------------------------------------------------
// Blocking portal client
// ---------------------------------------------------------------------------------------

var token_counter: std.atomic.Value(u32) = .init(1);

pub fn nextToken(buf: []u8) []const u8 {
    const seq = token_counter.fetchAdd(1, .monotonic);
    return std.fmt.bufPrint(buf, "zpui_appshot{d}_{d}", .{ linux.getpid(), seq }) catch unreachable;
}

/// `/org/freedesktop/portal/desktop/session/<sender>/<token>`.
pub fn sessionPath(buf: []u8, unique_name: []const u8, token: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(path ++ "/session/") catch return null;
    const name = if (unique_name.len > 0 and unique_name[0] == ':') unique_name[1..] else unique_name;
    for (name) |ch| w.writeByte(if (ch == '.') '_' else ch) catch return null;
    w.writeByte('/') catch return null;
    w.writeAll(token) catch return null;
    return w.buffered();
}

pub const Error = error{ NoBus, NoPortal, Stopped, Woken, Timeout, Closed, BadMessage, Truncated, BadSignature, Unsupported, OutOfMemory, WriteFailed, AddMatchFailed, NoBusReply };

pub const Portal = struct {
    conn: dbus.Connection,
    /// When set, a readable wake fd aborts blocking waits with `error.Stopped`
    /// (after `should_stop` says so).
    wake_fd: ?linux.fd_t = null,
    should_stop: ?*const fn (ctx: ?*anyopaque) bool = null,
    stop_ctx: ?*anyopaque = null,

    pub fn open(gpa: Allocator, bus_address: ?[]const u8, runtime_dir: ?[]const u8) ?Portal {
        const c = dbus.Connection.open(gpa, bus_address, runtime_dir) orelse return null;
        return .{ .conn = c };
    }

    pub fn deinit(self: *Portal) void {
        self.conn.deinit();
    }

    /// Next message, also waking on `wake_fd` (`error.Woken`, or `error.Stopped` when
    /// `should_stop` says so). `timeout_ms` -1 = forever.
    pub fn next(self: *Portal, timeout_ms: i32) Error!dbus.Message {
        while (true) {
            if (self.conn.buffered() catch return error.BadMessage) |m| return m;
            var fds = [2]linux.pollfd{
                .{ .fd = self.conn.fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd orelse -1, .events = linux.POLL.IN, .revents = 0 },
            };
            const rc = linux.poll(&fds, 2, timeout_ms);
            if (linux.errno(rc) == .INTR) continue;
            if (linux.errno(rc) != .SUCCESS) return error.Closed;
            if (rc == 0) return error.Timeout;
            if (fds[1].revents != 0) {
                if (self.should_stop) |f| if (f(self.stop_ctx)) return error.Stopped;
            }
            if (fds[0].revents != 0) {
                if (!self.conn.fill()) return error.Closed;
            } else if (fds[1].revents != 0) {
                // The wake was not a stop: the caller re-checks its own state.
                return error.Woken;
            }
        }
    }

    pub fn reply(self: *Portal, serial: u32, timeout_ms: i32) Error!dbus.Message {
        while (true) {
            const m = self.next(timeout_ms) catch |e| if (e == error.Woken) continue else return e;
            if (m.reply_serial == serial) return m;
        }
    }

    fn call(self: *Portal, p: []const u8, iface: []const u8, member: []const u8, signature: []const u8, body: []const u8) Error!u32 {
        return self.conn.send(.{ .serial = 0, .destination = dest, .path = p, .interface = iface, .member = member, .body = .{ .bytes = body, .signature = signature } }) catch error.WriteFailed;
    }

    /// `Properties.Get` of a `u` property on the portal object.
    pub fn getU32(self: *Portal, iface: []const u8, name: []const u8) Error!u32 {
        const body = try propertyGetBody(self.conn.gpa, iface, name);
        defer self.conn.gpa.free(body);
        const serial = try self.call(path, "org.freedesktop.DBus.Properties", "Get", "ss", body);
        const m = try self.reply(serial, 2000);
        if (m.type != .method_return) return error.NoPortal;
        return parseU32Variant(m);
    }

    /// A portal Request: subscribe to the request's `Response`, call, and wait (forever,
    /// or until stopped) for the response. Returns the message (borrowed until the next
    /// receive).
    pub fn request(self: *Portal, iface: []const u8, member: []const u8, signature: []const u8, body: []const u8, token: []const u8) Error!dbus.Message {
        var path_buf: [256]u8 = undefined;
        const expected = file_dialog.requestPath(&path_buf, self.conn.uniqueName(), token) orelse return error.BadMessage;
        var rule_buf: [512]u8 = undefined;
        const rule = std.fmt.bufPrint(&rule_buf, "type='signal',interface='{s}',member='Response',path='{s}'", .{ request_iface, expected }) catch return error.BadMessage;
        try self.addMatch(rule);
        const serial = try self.call(path, iface, member, signature, body);
        var handle_buf: [256]u8 = undefined;
        var handle: []const u8 = expected;
        var got_reply = false;
        while (true) {
            const m = self.next(if (got_reply) -1 else 5000) catch |e| if (e == error.Woken) continue else return e;
            if (m.reply_serial == serial) {
                if (m.type == .err) return error.NoPortal;
                got_reply = true;
                var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
                const h = r.str() catch continue;
                if (h.len <= handle_buf.len) {
                    @memcpy(handle_buf[0..h.len], h);
                    handle = handle_buf[0..h.len];
                }
                continue;
            }
            if (m.type == .signal and std.mem.eql(u8, m.interface, request_iface) and std.mem.eql(u8, m.member, "Response")) {
                if (!std.mem.eql(u8, m.path, handle) and !std.mem.eql(u8, m.path, expected)) continue;
                return m;
            }
        }
    }

    pub fn addMatch(self: *Portal, rule: []const u8) Error!void {
        const serial = self.conn.send(.{ .serial = 0, .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "AddMatch", .args = &.{rule} }) catch return error.WriteFailed;
        const m = try self.reply(serial, 2000);
        if (m.type == .err) return error.AddMatchFailed;
    }

    /// `Session.Close` (fire and forget).
    pub fn closeSession(self: *Portal, session: []const u8) void {
        _ = self.conn.send(.{ .serial = 0, .destination = dest, .path = session, .interface = session_iface, .member = "Close" }) catch {};
    }

    // -- Screenshot ---------------------------------------------------------------------

    /// Screenshot portal version and (v3+) available targets; null without a portal.
    pub fn screenshotTargets(self: *Portal) ?struct { version: u32, targets: u32 } {
        const version = self.getU32(screenshot_iface, "version") catch return null;
        if (version < 3) return .{ .version = version, .targets = 0 };
        const targets = self.getU32(screenshot_iface, "AvailableTargets") catch return .{ .version = version, .targets = 0 };
        return .{ .version = version, .targets = targets };
    }

    pub const ShotOutcome = union(enum) { path: []u8, cancelled, failed: []const u8 };

    /// Take a screenshot of `target`; the image path is owned.
    pub fn screenshot(self: *Portal, target: u32, interactive: bool) Error!ShotOutcome {
        const gpa = self.conn.gpa;
        var token_buf: [48]u8 = undefined;
        const token = nextToken(&token_buf);
        const body = try screenshotBody(gpa, token, target, interactive);
        defer gpa.free(body);
        const m = try self.request(screenshot_iface, "Screenshot", "sa{sv}", body, token);
        const resp = try parseResponse(m, "uri");
        switch (resp.code) {
            0 => {},
            1 => return .cancelled,
            else => return .{ .failed = "Screenshot portal failed: the request did not succeed." },
        }
        const uri = resp.value orelse return .{ .failed = "Screenshot portal failed: no image URI." };
        const p = (pathFromUri(gpa, uri) catch return error.OutOfMemory) orelse return .{ .failed = "Screenshot portal returned a non-file URI." };
        return .{ .path = p };
    }
};

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

const testing = std.testing;

fn readDict(r: *dbus.Reader, visit: anytype) !usize {
    const n = try r.u32_();
    try r.alignTo(8);
    const end = r.pos + n;
    var keys: usize = 0;
    while (r.pos < end) {
        try r.alignTo(8);
        const key = try r.str();
        const t = try r.sig();
        try visit.f(r, key, t);
        keys += 1;
    }
    return keys;
}

test "Screenshot body asks for the active window, non-interactive and non-modal" {
    const gpa = testing.allocator;
    const body = try screenshotBody(gpa, "tok", Target.active_window, false);
    defer gpa.free(body);
    var r: dbus.Reader = .{ .bytes = body, .pos = 0, .big = false };
    try testing.expectEqualStrings("", try r.str());
    const V = struct {
        var target: u32 = 0;
        var interactive: ?bool = null;
        var modal: ?bool = null;
        var token: []const u8 = "";
        fn f(rr: *dbus.Reader, key: []const u8, t: []const u8) !void {
            if (std.mem.eql(u8, key, "target")) target = try rr.u32_() else if (std.mem.eql(u8, key, "interactive")) interactive = (try rr.u32_()) == 1 else if (std.mem.eql(u8, key, "modal")) modal = (try rr.u32_()) == 1 else if (std.mem.eql(u8, key, "handle_token")) token = try rr.str() else try rr.skip(t);
        }
    };
    try testing.expectEqual(@as(usize, 4), try readDict(&r, V));
    try testing.expectEqual(Target.active_window, V.target);
    try testing.expectEqual(@as(?bool, false), V.interactive);
    try testing.expectEqual(@as(?bool, false), V.modal);
    try testing.expectEqualStrings("tok", V.token);
    try testing.expectEqual(body.len, r.pos);
}

test "Screenshot response yields the uri, and code 1 is a cancellation" {
    const gpa = testing.allocator;
    var b: dbus.Builder = .{ .gpa = gpa };
    defer b.buf.deinit(gpa);
    try b.u32_(0);
    const arr = try dbus.Body.beginArray(&b, 8);
    try dbus.Body.dictEntry(&b, "uri", "s");
    try b.str("file:///tmp/Screenshot%20from%20now.png");
    dbus.Body.endArray(&b, arr);
    const ok = try parseResponse(.{ .type = .signal, .big_endian = false, .serial = 1, .signature = "ua{sv}", .body = b.buf.items }, "uri");
    try testing.expectEqual(@as(u32, 0), ok.code);
    const p = (try pathFromUri(gpa, ok.value.?)).?;
    defer gpa.free(p);
    try testing.expectEqualStrings("/tmp/Screenshot from now.png", p);

    var c: dbus.Builder = .{ .gpa = gpa };
    defer c.buf.deinit(gpa);
    try c.u32_(1);
    const empty = try dbus.Body.beginArray(&c, 8);
    dbus.Body.endArray(&c, empty);
    const cancelled = try parseResponse(.{ .type = .signal, .big_endian = false, .serial = 2, .signature = "ua{sv}", .body = c.buf.items }, "uri");
    try testing.expectEqual(@as(u32, 1), cancelled.code);
    try testing.expect(cancelled.value == null);
}

test "AvailableTargets property reply" {
    const gpa = testing.allocator;
    var b: dbus.Builder = .{ .gpa = gpa };
    defer b.buf.deinit(gpa);
    try b.sig("u");
    try b.u32_(Target.window | Target.active_window);
    const v = try parseU32Variant(.{ .type = .method_return, .big_endian = false, .serial = 3, .signature = "v", .body = b.buf.items });
    try testing.expect(v & Target.active_window != 0);
    try testing.expectError(error.BadMessage, parseU32Variant(.{ .type = .err, .big_endian = false, .serial = 3, .signature = "v", .body = b.buf.items }));
}

test "GlobalShortcuts session, bind and activation messages" {
    const gpa = testing.allocator;
    const cs = try createSessionBody(gpa, "h1", "s1");
    defer gpa.free(cs);
    {
        var r: dbus.Reader = .{ .bytes = cs, .pos = 0, .big = false };
        const V = struct {
            var session: []const u8 = "";
            fn f(rr: *dbus.Reader, key: []const u8, t: []const u8) !void {
                if (std.mem.eql(u8, key, "session_handle_token")) session = try rr.str() else try rr.skip(t);
            }
        };
        try testing.expectEqual(@as(usize, 2), try readDict(&r, V));
        try testing.expectEqualStrings("s1", V.session);
    }

    const session = "/org/freedesktop/portal/desktop/session/1_42/s1";
    var pbuf: [128]u8 = undefined;
    try testing.expectEqualStrings(session, sessionPath(&pbuf, ":1.42", "s1").?);
    const bind = try bindShortcutsBody(gpa, session, "capture-appshot", "Capture an Appshot", "CTRL+ALT+space", "h2");
    defer gpa.free(bind);
    var r: dbus.Reader = .{ .bytes = bind, .pos = 0, .big = false };
    try testing.expectEqualStrings(session, try r.str());
    const list_len = try r.u32_();
    try r.alignTo(8);
    const list_end = r.pos + list_len;
    try testing.expectEqualStrings("capture-appshot", try r.str());
    const V = struct {
        var trigger: []const u8 = "";
        var description: []const u8 = "";
        fn f(rr: *dbus.Reader, key: []const u8, t: []const u8) !void {
            if (std.mem.eql(u8, key, "preferred_trigger")) trigger = try rr.str() else if (std.mem.eql(u8, key, "description")) description = try rr.str() else try rr.skip(t);
        }
    };
    _ = try readDict(&r, V);
    try testing.expectEqual(list_end, r.pos);
    try testing.expectEqualStrings("CTRL+ALT+space", V.trigger);
    try testing.expectEqualStrings("Capture an Appshot", V.description);
    try testing.expectEqualStrings("", try r.str());
    try r.skip("a{sv}");
    try testing.expectEqual(bind.len, r.pos);

    // CreateSession's Response carries the session handle.
    var resp: dbus.Builder = .{ .gpa = gpa };
    defer resp.buf.deinit(gpa);
    try resp.u32_(0);
    const arr = try dbus.Body.beginArray(&resp, 8);
    try dbus.Body.dictEntry(&resp, "session_handle", "o");
    try resp.str(session);
    dbus.Body.endArray(&resp, arr);
    const parsed = try parseResponse(.{ .type = .signal, .big_endian = false, .serial = 4, .signature = "ua{sv}", .body = resp.buf.items }, "session_handle");
    try testing.expectEqualStrings(session, parsed.value.?);

    // Activated(o, s, t, a{sv}).
    var act: dbus.Builder = .{ .gpa = gpa };
    defer act.buf.deinit(gpa);
    try act.str(session);
    try act.str("capture-appshot");
    try act.pad(8);
    try act.buf.appendSlice(gpa, &std.mem.toBytes(@as(u64, 1234)));
    const empty = try dbus.Body.beginArray(&act, 8);
    dbus.Body.endArray(&act, empty);
    const a = try parseActivated(.{ .type = .signal, .big_endian = false, .serial = 5, .signature = "osta{sv}", .body = act.buf.items });
    try testing.expectEqualStrings(session, a.session);
    try testing.expectEqualStrings("capture-appshot", a.id);

    const cfg = try configureShortcutsBody(gpa, session);
    defer gpa.free(cfg);
    var cr: dbus.Reader = .{ .bytes = cfg, .pos = 0, .big = false };
    try testing.expectEqualStrings(session, try cr.str());
    try testing.expectEqualStrings("", try cr.str());
}
