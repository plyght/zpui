//! System light/dark appearance on Linux (gpui_linux `xdg_desktop_portal.rs`).
//!
//! Source of truth is the XDG settings portal: `org.freedesktop.portal.Settings`
//! `ReadOne("org.freedesktop.appearance", "color-scheme")` (falling back to the
//! older `Read`) on the session bus, plus a `SettingChanged` signal match so a
//! desktop-wide theme flip repaints live. When no portal answers, GNOME's
//! `gsettings get org.gnome.desktop.interface color-scheme` (then `gtk-theme`
//! ending in `-dark`) is consulted. With nothing found the appearance stays
//! light, as gpui (and therefore zeron's Rust build) reports on Linux.
//!
//! The D-Bus client is a minimal pure-Zig one: a blocking-then-nonblocking
//! unix socket to the session bus, SASL `EXTERNAL` auth, and just enough of
//! the wire format to marshal string-argument method calls and read `u`
//! values out of (nested) variants. After startup the socket lives in the
//! platform's epoll loop.
//!
//!     const w = try Watcher.start(gpa, &loop, .{ .ctx = plat, .func = onChange });
//!     plat.appearance = w.current;   // initial value (light when unknown)

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");
const event_loop = @import("event_loop.zig");
const dbus = @import("dbus.zig");

pub const WindowAppearance = platform.WindowAppearance;

/// `org.freedesktop.appearance color-scheme` values.
pub const ColorScheme = enum(u32) {
    no_preference = 0,
    prefer_dark = 1,
    prefer_light = 2,
    _,
};

/// gpui `window_appearance_from_color_scheme` (no preference reads as light).
pub fn fromColorScheme(v: u32) WindowAppearance {
    return switch (@as(ColorScheme, @enumFromInt(v))) {
        .prefer_dark => .dark,
        else => .light,
    };
}

/// GNOME's `color-scheme` / `gtk-theme` strings (as `gsettings get` prints them).
pub fn fromGSettings(color_scheme: ?[]const u8, gtk_theme: ?[]const u8) ?WindowAppearance {
    if (color_scheme) |raw| {
        const v = std.mem.trim(u8, raw, " \t\r\n'\"");
        if (std.mem.eql(u8, v, "prefer-dark")) return .dark;
        if (std.mem.eql(u8, v, "prefer-light")) return .light;
    }
    if (gtk_theme) |raw| {
        const v = std.mem.trim(u8, raw, " \t\r\n'\"");
        if (v.len == 0) return null;
        var lower_buf: [128]u8 = undefined;
        const n = @min(v.len, lower_buf.len);
        const lower = std.ascii.lowerString(lower_buf[0..n], v[0..n]);
        if (std.mem.endsWith(u8, lower, "-dark") or std.mem.endsWith(u8, lower, ":dark")) return .dark;
        return .light;
    }
    if (color_scheme != null) return .light; // 'default'
    return null;
}

// Wire format + session bus: shared with the file-chooser portal (dbus.zig).
pub const MessageType = dbus.MessageType;
pub const Builder = dbus.Builder;
pub const Call = dbus.Call;
pub const buildCall = dbus.buildCall;
pub const Message = dbus.Message;
const Reader = dbus.Reader;
const HeaderField = dbus.HeaderField;
pub const ParseError = dbus.ParseError;
pub const messageLength = dbus.messageLength;
pub const parseMessage = dbus.parseMessage;
pub const sessionBusAddress = dbus.sessionBusAddress;
const ok = dbus.ok;
const waitReadable = dbus.waitReadable;
const writeAll = dbus.writeAll;
const connectBus = dbus.connectBus;

/// A `u` inside a variant (possibly nested: the old `Read` wraps twice).
fn variantU32(r: *Reader) ParseError!?u32 {
    var depth: usize = 0;
    while (depth < 4) : (depth += 1) {
        const t = try r.sig();
        if (std.mem.eql(u8, t, "u")) return try r.u32_();
        if (std.mem.eql(u8, t, "v")) continue;
        return null;
    }
    return null;
}

/// The color-scheme value out of a `ReadOne` (`v`) or `Read` (`v` of `v`) reply.
pub fn replyColorScheme(m: Message) ?u32 {
    if (m.type != .method_return or !std.mem.eql(u8, m.signature, "v")) return null;
    var r: Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
    return variantU32(&r) catch null;
}

/// The color-scheme value of an `org.freedesktop.portal.Settings.SettingChanged`
/// signal for `org.freedesktop.appearance` / `color-scheme`, else null.
pub fn signalColorScheme(m: Message) ?u32 {
    if (m.type != .signal) return null;
    if (!std.mem.eql(u8, m.interface, portal_settings) or !std.mem.eql(u8, m.member, "SettingChanged")) return null;
    if (!std.mem.eql(u8, m.signature, "ssv")) return null;
    var r: Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
    const ns = r.str() catch return null;
    const key = r.str() catch return null;
    if (!std.mem.eql(u8, ns, appearance_ns) or !std.mem.eql(u8, key, color_scheme_key)) return null;
    return variantU32(&r) catch null;
}

const portal_dest = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const portal_settings = "org.freedesktop.portal.Settings";
const appearance_ns = "org.freedesktop.appearance";
const color_scheme_key = "color-scheme";
const match_rule = "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged',arg0='org.freedesktop.appearance',arg1='color-scheme'";

// ---------------------------------------------------------------------------------------
// GSettings fallback
// ---------------------------------------------------------------------------------------

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// `gsettings get <schema> <key>` → stdout (trimmed into `out`), or null.
fn gsettingsGet(schema: [*:0]const u8, key: [*:0]const u8, out: []u8) ?[]const u8 {
    var fds: [2]linux.fd_t = undefined;
    if (!ok(linux.pipe2(&fds, .{ .CLOEXEC = true }))) return null;
    const pid = linux.fork();
    if (!ok(pid)) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return null;
    }
    if (pid == 0) {
        _ = linux.dup2(fds[1], 1);
        const devnull = linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
        if (ok(devnull)) _ = linux.dup2(@intCast(devnull), 2);
        const argv = [_:null]?[*:0]const u8{ "gsettings", "get", schema, key };
        _ = execvp("gsettings", &argv);
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    defer _ = linux.close(fds[0]);
    var got: usize = 0;
    while (got < out.len and waitReadable(fds[0], 500)) {
        const n = linux.read(fds[0], out[got..].ptr, out.len - got);
        if (!ok(n)) {
            if (linux.errno(n) == .INTR) continue;
            break;
        }
        if (n == 0) break;
        got += n;
    }
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
    if (got == 0 or status != 0) return null;
    return std.mem.trim(u8, out[0..got], " \t\r\n");
}

/// GNOME's interface settings, or null when gsettings is unavailable.
pub fn readGSettings() ?WindowAppearance {
    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    const scheme = gsettingsGet("org.gnome.desktop.interface", "color-scheme", &a);
    if (scheme) |s| if (fromGSettings(s, null)) |v| if (v == .dark) return v;
    const theme = gsettingsGet("org.gnome.desktop.interface", "gtk-theme", &b);
    return fromGSettings(scheme, theme);
}

// ---------------------------------------------------------------------------------------
// Watcher
// ---------------------------------------------------------------------------------------

pub const Watcher = struct {
    gpa: Allocator,
    loop: *event_loop.EventLoop,
    fd: linux.fd_t,
    source: ?*event_loop.Source = null,
    rx: std.ArrayList(u8) = .empty,
    next_serial: u32 = 1,
    read_one_serial: u32 = 0,
    read_serial: u32 = 0,
    /// Last known appearance (light until something answers).
    current: WindowAppearance = .light,
    /// Whether the portal (or gsettings) gave an answer.
    resolved: bool = false,
    on_change: event_loop.Handler(WindowAppearance),

    pub const Env = struct {
        bus_address: ?[]const u8,
        runtime_dir: ?[]const u8,
        /// Synchronous wait for the portal's first answer (avoids a light→dark
        /// flash on the first frame); later answers arrive through the loop.
        initial_wait_ms: i32 = 150,
        gsettings_fallback: bool = true,
    };

    pub fn envFromProcess() Env {
        const addr = std.c.getenv("DBUS_SESSION_BUS_ADDRESS");
        const rt = std.c.getenv("XDG_RUNTIME_DIR");
        return .{
            .bus_address = if (addr) |p| std.mem.span(p) else null,
            .runtime_dir = if (rt) |p| std.mem.span(p) else null,
        };
    }

    /// Never fails: without a bus the watcher is null and `fallback` is used.
    pub fn start(gpa: Allocator, loop: *event_loop.EventLoop, env: Env, on_change: event_loop.Handler(WindowAppearance)) struct { watcher: ?*Watcher, appearance: WindowAppearance } {
        const fd = connectBus(env.bus_address, env.runtime_dir) orelse {
            const v = if (env.gsettings_fallback) readGSettings() else null;
            return .{ .watcher = null, .appearance = v orelse .light };
        };
        const self = gpa.create(Watcher) catch {
            _ = linux.close(fd);
            return .{ .watcher = null, .appearance = .light };
        };
        self.* = .{ .gpa = gpa, .loop = loop, .fd = fd, .on_change = on_change };
        const sent = self.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", &.{}) != 0 and
            self.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "AddMatch", &.{match_rule}) != 0;
        if (sent) self.read_one_serial = self.call(portal_dest, portal_path, portal_settings, "ReadOne", &.{ appearance_ns, color_scheme_key });
        if (!sent or self.read_one_serial == 0) {
            self.destroy();
            const v = if (env.gsettings_fallback) readGSettings() else null;
            return .{ .watcher = null, .appearance = v orelse .light };
        }
        // Give the portal a moment to answer before the first frame.
        var budget = env.initial_wait_ms;
        const start_ns = event_loop.monotonicNow();
        while (!self.resolved and (self.read_one_serial != 0 or self.read_serial != 0)) {
            if (budget <= 0 or !waitReadable(self.fd, budget)) break;
            if (!self.pump(false)) break;
            const spent: i32 = @intCast((event_loop.monotonicNow() - start_ns) / std.time.ns_per_ms);
            budget = env.initial_wait_ms - spent;
        }
        if (!self.resolved and self.read_one_serial == 0 and self.read_serial == 0 and env.gsettings_fallback) {
            // The portal answered with an error: no settings portal on this desktop.
            if (readGSettings()) |v| {
                self.current = v;
                self.resolved = true;
            }
        }
        self.source = loop.addFd(self.fd, linux.EPOLL.IN, .{ .ctx = self, .func = onReadable }) catch null;
        if (self.source == null) {
            const v = self.current;
            self.destroy();
            return .{ .watcher = null, .appearance = v };
        }
        return .{ .watcher = self, .appearance = self.current };
    }

    pub fn destroy(self: *Watcher) void {
        if (self.source) |s| self.loop.removeFd(s);
        _ = linux.close(self.fd);
        self.rx.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Sends a method call; returns its serial (0 on failure).
    fn call(self: *Watcher, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, args: []const []const u8) u32 {
        const serial = self.next_serial;
        self.next_serial += 1;
        const bytes = buildCall(self.gpa, .{ .serial = serial, .destination = dest, .path = path, .interface = iface, .member = member, .args = args }) catch return 0;
        defer self.gpa.free(bytes);
        return if (writeAll(self.fd, bytes)) serial else 0;
    }

    fn onReadable(ctx: ?*anyopaque, _: u32) void {
        const self: *Watcher = @ptrCast(@alignCast(ctx.?));
        if (!self.pump(true)) {
            // Bus went away: keep the last value, stop watching.
            if (self.source) |s| self.loop.removeFd(s);
            self.source = null;
        }
    }

    /// Reads what is available and handles complete messages. False on EOF/error.
    fn pump(self: *Watcher, notify: bool) bool {
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = linux.read(self.fd, &chunk, chunk.len);
            switch (linux.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return false;
                    self.rx.appendSlice(self.gpa, chunk[0..n]) catch return false;
                    if (n < chunk.len) break;
                },
                .INTR => continue,
                .AGAIN => break,
                else => return false,
            }
        }
        while (true) {
            const len = (messageLength(self.rx.items) catch return false) orelse break;
            const m = parseMessage(self.rx.items[0..len]) catch {
                self.consume(len);
                continue;
            };
            self.handle(m, notify);
            self.consume(len);
        }
        return true;
    }

    fn consume(self: *Watcher, len: usize) void {
        const rest = self.rx.items.len - len;
        std.mem.copyForwards(u8, self.rx.items[0..rest], self.rx.items[len..]);
        self.rx.shrinkRetainingCapacity(rest);
    }

    fn handle(self: *Watcher, m: Message, notify: bool) void {
        if (m.reply_serial) |rs| {
            if (rs == self.read_one_serial) {
                self.read_one_serial = 0;
                if (replyColorScheme(m)) |v| return self.set(fromColorScheme(v), notify);
                if (m.type == .err and std.mem.endsWith(u8, m.error_name, "UnknownMethod")) {
                    // Portal < v2 has only `Read` (value wrapped in two variants).
                    self.read_serial = self.call(portal_dest, portal_path, portal_settings, "Read", &.{ appearance_ns, color_scheme_key });
                }
                return;
            }
            if (rs == self.read_serial) {
                self.read_serial = 0;
                if (replyColorScheme(m)) |v| self.set(fromColorScheme(v), notify);
                return;
            }
            return;
        }
        if (signalColorScheme(m)) |v| self.set(fromColorScheme(v), notify);
    }

    fn set(self: *Watcher, v: WindowAppearance, notify: bool) void {
        self.resolved = true;
        if (v == self.current) return;
        self.current = v;
        if (notify) self.on_change.call(v);
    }
};

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "color scheme mapping" {
    try testing.expectEqual(WindowAppearance.dark, fromColorScheme(1));
    try testing.expectEqual(WindowAppearance.light, fromColorScheme(2));
    try testing.expectEqual(WindowAppearance.light, fromColorScheme(0));
    try testing.expectEqual(WindowAppearance.light, fromColorScheme(7));
    try testing.expectEqual(@as(?WindowAppearance, .dark), fromGSettings("'prefer-dark'\n", null));
    try testing.expectEqual(@as(?WindowAppearance, .light), fromGSettings("'default'", "'Adwaita'"));
    try testing.expectEqual(@as(?WindowAppearance, .dark), fromGSettings("'default'", "'Adwaita-dark'"));
    try testing.expectEqual(@as(?WindowAppearance, .light), fromGSettings("'default'", null));
    try testing.expectEqual(@as(?WindowAppearance, null), fromGSettings(null, null));
}

test "session bus address" {
    var sa: linux.sockaddr.un = undefined;
    const len = sessionBusAddress("unix:path=/run/user/1000/bus,guid=abc", null, &sa).?;
    try testing.expectEqualStrings("/run/user/1000/bus", std.mem.sliceTo(&sa.path, 0));
    try testing.expectEqual(@as(linux.socklen_t, @intCast(2 + 18 + 1)), len);
    const alen = sessionBusAddress("tcp:host=x;unix:abstract=/tmp/dbus-xyz", null, &sa).?;
    try testing.expectEqual(@as(u8, 0), sa.path[0]);
    try testing.expectEqualStrings("/tmp/dbus-xyz", std.mem.sliceTo(sa.path[1..], 0));
    try testing.expectEqual(@as(linux.socklen_t, @intCast(2 + 1 + 13)), alen);
    _ = sessionBusAddress(null, "/run/user/7", &sa).?;
    try testing.expectEqualStrings("/run/user/7/bus", std.mem.sliceTo(&sa.path, 0));
    try testing.expect(sessionBusAddress(null, null, &sa) == null);
}

/// Test helper: marshals a reply/signal like a bus would.
fn testMessage(gpa: Allocator, t: MessageType, reply_serial: ?u32, iface: []const u8, member: []const u8, signature: []const u8, body: []const u8) ![]u8 {
    var b: Builder = .{ .gpa = gpa };
    errdefer b.buf.deinit(gpa);
    try b.u8_('l');
    try b.u8_(@intFromEnum(t));
    try b.u8_(0);
    try b.u8_(1);
    try b.u32_(@intCast(body.len));
    try b.u32_(99);
    const at = b.buf.items.len;
    try b.u32_(0);
    const start = b.buf.items.len;
    if (iface.len > 0) try b.field(.interface, 's', iface);
    if (member.len > 0) try b.field(.member, 's', member);
    if (reply_serial) |rs| {
        try b.pad(8);
        try b.u8_(@intFromEnum(HeaderField.reply_serial));
        try b.sig("u");
        try b.u32_(rs);
    }
    if (signature.len > 0) try b.field(.signature, 'g', signature);
    const flen: u32 = @intCast(b.buf.items.len - start);
    @memcpy(b.buf.items[at..][0..4], std.mem.asBytes(&flen));
    try b.pad(8);
    try b.buf.appendSlice(gpa, body);
    return b.buf.toOwnedSlice(gpa);
}

test "marshal method call and parse it back" {
    const gpa = testing.allocator;
    const bytes = try buildCall(gpa, .{ .serial = 3, .destination = portal_dest, .path = portal_path, .interface = portal_settings, .member = "ReadOne", .args = &.{ appearance_ns, color_scheme_key } });
    defer gpa.free(bytes);
    try testing.expectEqual(@as(?usize, bytes.len), try messageLength(bytes));
    try testing.expectEqual(@as(?usize, null), try messageLength(bytes[0 .. bytes.len - 1]));
    const m = try parseMessage(bytes);
    try testing.expectEqual(MessageType.method_call, m.type);
    try testing.expectEqual(@as(u32, 3), m.serial);
    try testing.expectEqualStrings(portal_path, m.path);
    try testing.expectEqualStrings(portal_settings, m.interface);
    try testing.expectEqualStrings("ReadOne", m.member);
    try testing.expectEqualStrings("ss", m.signature);
    var r: Reader = .{ .bytes = m.body, .pos = 0, .big = false };
    try testing.expectEqualStrings(appearance_ns, try r.str());
    try testing.expectEqualStrings(color_scheme_key, try r.str());
}

test "ReadOne / Read replies and SettingChanged signals" {
    const gpa = testing.allocator;
    // ReadOne → v(u 1)
    const one = try testMessage(gpa, .method_return, 3, "", "", "v", &.{ 1, 'u', 0, 0, 1, 0, 0, 0 });
    defer gpa.free(one);
    const m1 = try parseMessage(one);
    try testing.expectEqual(@as(?u32, 3), m1.reply_serial);
    try testing.expectEqual(@as(?u32, 1), replyColorScheme(m1));
    // Read → v(v(u 2))
    const two = try testMessage(gpa, .method_return, 4, "", "", "v", &.{ 1, 'v', 0, 1, 'u', 0, 0, 0, 2, 0, 0, 0 });
    defer gpa.free(two);
    try testing.expectEqual(@as(?u32, 2), replyColorScheme(try parseMessage(two)));
    // SettingChanged(ssv)
    var body: Builder = .{ .gpa = gpa };
    defer body.buf.deinit(gpa);
    try body.str(appearance_ns);
    try body.str(color_scheme_key);
    try body.sig("u");
    try body.u32_(1);
    const sig_bytes = try testMessage(gpa, .signal, null, portal_settings, "SettingChanged", "ssv", body.buf.items);
    defer gpa.free(sig_bytes);
    try testing.expectEqual(@as(?u32, 1), signalColorScheme(try parseMessage(sig_bytes)));
    // A different key is ignored.
    var other: Builder = .{ .gpa = gpa };
    defer other.buf.deinit(gpa);
    try other.str(appearance_ns);
    try other.str("accent-color");
    try other.sig("u");
    try other.u32_(1);
    const other_bytes = try testMessage(gpa, .signal, null, portal_settings, "SettingChanged", "ssv", other.buf.items);
    defer gpa.free(other_bytes);
    try testing.expectEqual(@as(?u32, null), signalColorScheme(try parseMessage(other_bytes)));
    // An error reply carries no value.
    const e = try testMessage(gpa, .err, 3, "", "", "s", &.{ 0, 0, 0, 0, 0 });
    defer gpa.free(e);
    try testing.expectEqual(@as(?u32, null), replyColorScheme(try parseMessage(e)));
}
