//! Linux desktop banners and sounds.
//!
//! Banners: `org.freedesktop.Notifications.Notify` over the pure-Zig D-Bus client
//! (dbus.zig) on a dedicated thread that keeps its session-bus connection open, so a
//! click (`ActionInvoked` with the "default" action) comes back as
//! `PlatformCallbacks.notification_activated(tag)` on the main thread — zeron's
//! `notify-send` path cannot report clicks. Without a session bus (or a notification
//! server) it falls back to `notify-send --app-name=<app> -- <title> <body>` like zeron.
//!
//! Sounds (zeron `sound.rs`): the WAV goes to an exclusively created temp file and the
//! first working player of `paplay`, `pw-play`, `aplay -q`, `ffplay`, `mpv` plays it on a
//! background thread (10 s cap, then killed); failures are swallowed.

const std = @import("std");
const linux = std.os.linux;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");
const dbus = @import("dbus.zig");

const log = std.log.scoped(.linux_notify);

pub const service = "org.freedesktop.Notifications";
pub const object_path = "/org/freedesktop/Notifications";
pub const interface = "org.freedesktop.Notifications";

pub const Env = struct {
    bus_address: ?[]const u8 = null,
    runtime_dir: ?[]const u8 = null,
    /// Allow the `notify-send` fallback.
    fallback: bool = true,

    pub fn fromProcess() Env {
        return .{
            .bus_address = getenv("DBUS_SESSION_BUS_ADDRESS"),
            .runtime_dir = getenv("XDG_RUNTIME_DIR"),
        };
    }
};

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    return std.mem.span(v);
}

// ---------------------------------------------------------------------------------------
// Wire helpers (pure; unit-tested)
// ---------------------------------------------------------------------------------------

/// `Notify(app_name s, replaces_id u, app_icon s, summary s, body s, actions as,
/// hints a{sv}, expire_timeout i)` body — signature `susssasa{sv}i`. A tagged
/// notification offers the "default" action (activation = click).
pub fn notifyBody(gpa: Allocator, app_name: []const u8, summary: []const u8, body: []const u8, clickable: bool) ![]u8 {
    var b: dbus.Builder = .{ .gpa = gpa };
    errdefer b.buf.deinit(gpa);
    try b.str(app_name);
    try b.u32_(0);
    try b.str("");
    try b.str(summary);
    try b.str(body);
    const actions = try dbus.Body.beginArray(&b, 4);
    if (clickable) {
        try b.str("default");
        try b.str("Open");
    }
    dbus.Body.endArray(&b, actions);
    const hints = try dbus.Body.beginArray(&b, 8);
    dbus.Body.endArray(&b, hints);
    try b.u32_(@bitCast(@as(i32, -1)));
    return b.buf.toOwnedSlice(gpa);
}

pub const notify_signature = "susssasa{sv}i";

/// `ActionInvoked(u id, s action_key)`.
pub fn parseActionInvoked(m: dbus.Message) ?struct { id: u32, action: []const u8 } {
    if (m.type != .signal or !std.mem.eql(u8, m.interface, interface) or !std.mem.eql(u8, m.member, "ActionInvoked")) return null;
    if (!std.mem.eql(u8, m.signature, "us")) return null;
    var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
    const nid = r.u32_() catch return null;
    const action = r.str() catch return null;
    return .{ .id = nid, .action = action };
}

/// `NotificationClosed(u id, u reason)` → id.
pub fn parseClosed(m: dbus.Message) ?u32 {
    if (m.type != .signal or !std.mem.eql(u8, m.interface, interface) or !std.mem.eql(u8, m.member, "NotificationClosed")) return null;
    var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
    return r.u32_() catch null;
}

/// The id in a `Notify` reply.
pub fn parseNotifyReply(m: dbus.Message) ?u32 {
    if (m.type != .method_return or !std.mem.startsWith(u8, m.signature, "u")) return null;
    var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
    return r.u32_() catch null;
}

// ---------------------------------------------------------------------------------------
// Notifier thread
// ---------------------------------------------------------------------------------------

const Owned = struct {
    title: []u8,
    body: []u8,
    app_name: []u8,
    tag: ?[]u8,

    fn deinit(o: Owned, gpa: Allocator) void {
        gpa.free(o.title);
        gpa.free(o.body);
        gpa.free(o.app_name);
        if (o.tag) |t| gpa.free(t);
    }
};

const Tracked = struct { key: u32, tag: []u8 };

pub const Notifier = struct {
    gpa: Allocator,
    io: Io,
    dispatcher: platform.Dispatcher,
    callbacks: *const platform.PlatformCallbacks,
    env: Env,
    mutex: Io.Mutex = .init,
    queue: std.ArrayList(Owned) = .empty,
    stopping: bool = false,
    wake_fd: linux.fd_t,
    thread: ?std.Thread = null,
    /// Number of notifications delivered to the bus (tests).
    delivered: std.atomic.Value(u32) = .init(0),

    // -- notifier-thread state --------------------------------------------------------
    conn: ?dbus.Connection = null,
    /// Notify calls awaiting their reply (serial → tag).
    awaiting: std.ArrayList(Tracked) = .empty,
    /// Shown notifications (server id → tag).
    shown: std.ArrayList(Tracked) = .empty,

    pub fn create(gpa: Allocator, io: Io, dispatcher: platform.Dispatcher, callbacks: *const platform.PlatformCallbacks, env: Env) !*Notifier {
        const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(rc) != .SUCCESS) return error.EventFd;
        const self = try gpa.create(Notifier);
        self.* = .{ .gpa = gpa, .io = io, .dispatcher = dispatcher, .callbacks = callbacks, .env = env, .wake_fd = @intCast(rc) };
        return self;
    }

    pub fn destroy(self: *Notifier) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.mutex.unlock(self.io);
        self.wake();
        if (self.thread) |t| t.join();
        for (self.queue.items) |o| o.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        self.clearTracked();
        self.awaiting.deinit(self.gpa);
        self.shown.deinit(self.gpa);
        if (self.conn) |*c| c.deinit();
        _ = linux.close(self.wake_fd);
        self.gpa.destroy(self);
    }

    fn clearTracked(self: *Notifier) void {
        for (self.awaiting.items) |t| self.gpa.free(t.tag);
        for (self.shown.items) |t| self.gpa.free(t.tag);
        self.awaiting.clearRetainingCapacity();
        self.shown.clearRetainingCapacity();
    }

    fn wake(self: *Notifier) void {
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one), 8);
    }

    /// Main thread: queue a banner (strings copied) and wake the notifier thread.
    pub fn post(self: *Notifier, n: platform.Notification) void {
        const gpa = self.gpa;
        const owned: Owned = .{
            .title = gpa.dupe(u8, n.title) catch return,
            .body = gpa.dupe(u8, n.body) catch return,
            .app_name = gpa.dupe(u8, n.app_name) catch return,
            .tag = if (n.tag) |t| gpa.dupe(u8, t) catch null else null,
        };
        self.mutex.lockUncancelable(self.io);
        self.queue.append(gpa, owned) catch {
            self.mutex.unlock(self.io);
            owned.deinit(gpa);
            return;
        };
        self.mutex.unlock(self.io);
        if (self.thread == null) {
            self.thread = std.Thread.spawn(.{}, threadMain, .{self}) catch |err| {
                log.debug("notifier thread: {t}", .{err});
                return;
            };
        }
        self.wake();
    }

    fn threadMain(self: *Notifier) void {
        while (true) {
            var fds = [2]linux.pollfd{
                .{ .fd = self.wake_fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = if (self.conn) |c| c.fd else -1, .events = linux.POLL.IN, .revents = 0 },
            };
            const rc = linux.poll(&fds, 2, -1);
            if (linux.errno(rc) != .SUCCESS) continue;
            if (fds[0].revents != 0) {
                var v: u64 = 0;
                _ = linux.read(self.wake_fd, std.mem.asBytes(&v), 8);
            }
            self.mutex.lockUncancelable(self.io);
            const stop = self.stopping;
            var batch = self.queue;
            self.queue = .empty;
            self.mutex.unlock(self.io);
            if (stop) {
                for (batch.items) |o| o.deinit(self.gpa);
                batch.deinit(self.gpa);
                return;
            }
            for (batch.items) |o| {
                self.deliver(o);
                o.deinit(self.gpa);
            }
            batch.deinit(self.gpa);
            if (self.conn != null and fds[1].revents != 0) self.readBus();
        }
    }

    fn ensureConn(self: *Notifier) bool {
        if (self.conn != null) return true;
        var c = dbus.Connection.open(self.gpa, self.env.bus_address, self.env.runtime_dir) orelse return false;
        const rules = [_][]const u8{
            "type='signal',interface='" ++ interface ++ "',member='ActionInvoked'",
            "type='signal',interface='" ++ interface ++ "',member='NotificationClosed'",
        };
        for (rules) |rule| c.addMatch(rule) catch {
            c.deinit();
            return false;
        };
        self.conn = c;
        return true;
    }

    fn dropConn(self: *Notifier) void {
        if (self.conn) |*c| c.deinit();
        self.conn = null;
        self.clearTracked();
    }

    fn deliver(self: *Notifier, o: Owned) void {
        if (self.ensureConn()) {
            const c = &self.conn.?;
            const body = notifyBody(self.gpa, o.app_name, o.title, o.body, o.tag != null) catch return;
            defer self.gpa.free(body);
            if (c.send(.{ .serial = 0, .destination = service, .path = object_path, .interface = interface, .member = "Notify", .body = .{ .bytes = body, .signature = notify_signature } })) |serial| {
                _ = self.delivered.fetchAdd(1, .monotonic);
                if (o.tag) |t| if (self.gpa.dupe(u8, t)) |copy| {
                    self.awaiting.append(self.gpa, .{ .key = serial, .tag = copy }) catch self.gpa.free(copy);
                } else |_| {};
                return;
            } else |err| {
                log.debug("Notify failed: {t}", .{err});
                self.dropConn();
            }
        }
        if (self.env.fallback) {
            const name = if (o.app_name.len > 0) o.app_name else "zpui";
            var arg_buf: [160]u8 = undefined;
            const app_arg = std.fmt.bufPrint(&arg_buf, "--app-name={s}", .{name}) catch "--app-name=zpui";
            // `--` ends option parsing: titles are model-generated (zeron notify.rs).
            spawnDetached(self.gpa, &.{ "notify-send", app_arg, "--", o.title, o.body });
        }
    }

    fn readBus(self: *Notifier) void {
        const c = &self.conn.?;
        if (!c.fill()) {
            self.dropConn();
            return;
        }
        while (true) {
            const m = (c.buffered() catch {
                self.dropConn();
                return;
            }) orelse return;
            self.handle(m);
            if (self.conn == null) return;
        }
    }

    fn handle(self: *Notifier, m: dbus.Message) void {
        if (m.reply_serial) |serial| {
            for (self.awaiting.items, 0..) |t, i| if (t.key == serial) {
                const tracked = self.awaiting.swapRemove(i);
                const nid = parseNotifyReply(m) orelse {
                    self.gpa.free(tracked.tag);
                    return;
                };
                self.shown.append(self.gpa, .{ .key = nid, .tag = tracked.tag }) catch self.gpa.free(tracked.tag);
                return;
            };
            return;
        }
        if (parseActionInvoked(m)) |ev| {
            if (!std.mem.eql(u8, ev.action, "default")) return;
            for (self.shown.items) |t| if (t.key == ev.id) {
                self.postClick(t.tag);
                return;
            };
            return;
        }
        if (parseClosed(m)) |nid| {
            for (self.shown.items, 0..) |t, i| if (t.key == nid) {
                self.gpa.free(self.shown.swapRemove(i).tag);
                return;
            };
        }
    }

    const Click = struct {
        gpa: Allocator,
        callbacks: *const platform.PlatformCallbacks,
        tag: []u8,
        fn run(ctx: *anyopaque) void {
            const click: *Click = @ptrCast(@alignCast(ctx));
            defer click.free();
            const cbs = click.callbacks;
            if (cbs.notification_activated) |f| f(cbs.ctx, click.tag);
        }
        fn drop(ctx: *anyopaque) void {
            const click: *Click = @ptrCast(@alignCast(ctx));
            click.free();
        }
        fn free(click: *Click) void {
            const gpa = click.gpa;
            gpa.free(click.tag);
            gpa.destroy(click);
        }
    };

    fn postClick(self: *Notifier, tag: []const u8) void {
        const click = self.gpa.create(Click) catch return;
        click.* = .{ .gpa = self.gpa, .callbacks = self.callbacks, .tag = self.gpa.dupe(u8, tag) catch {
            self.gpa.destroy(click);
            return;
        } };
        self.dispatcher.dispatchOnMainThread(.{ .ctx = click, .run = Click.run, .drop = Click.drop }, .high);
    }
};

// ---------------------------------------------------------------------------------------
// Sounds
// ---------------------------------------------------------------------------------------

var tmp_counter: std.atomic.Value(u32) = .init(0);

/// Play `wav` on a detached thread (bytes copied).
pub fn playSound(gpa: Allocator, wav: []const u8) void {
    const copy = gpa.dupe(u8, wav) catch return;
    const t = std.Thread.spawn(.{}, playThread, .{ gpa, copy }) catch {
        gpa.free(copy);
        return;
    };
    t.detach();
}

fn playThread(gpa: Allocator, wav: []u8) void {
    defer gpa.free(wav);
    playBlocking(wav) catch |err| log.debug("sound playback failed: {t}", .{err});
}

/// Write `wav` to an exclusive temp file and run the first working player.
pub fn playBlocking(wav: []const u8) !void {
    var path_buf: [256:0]u8 = undefined;
    const fd = try createTemp(&path_buf);
    const path: [:0]const u8 = std.mem.sliceTo(&path_buf, 0);
    defer _ = linux.unlink(path.ptr);
    {
        defer _ = linux.close(fd);
        var off: usize = 0;
        while (off < wav.len) {
            const n = linux.write(fd, wav[off..].ptr, wav.len - off);
            if (linux.errno(n) != .SUCCESS) return error.WriteFailed;
            off += n;
        }
    }
    const players = [_][]const []const u8{
        &.{"paplay"},
        &.{"pw-play"},
        &.{ "aplay", "-q" },
        &.{ "ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet" },
        &.{ "mpv", "--no-video", "--really-quiet" },
    };
    for (players) |argv| {
        if (runChecked(argv, path)) return;
    }
    return error.NoPlayer;
}

fn createTemp(out: *[256:0]u8) !linux.fd_t {
    const dir = getenv("TMPDIR") orelse "/tmp";
    var tries: usize = 0;
    while (tries < 128) : (tries += 1) {
        const id = tmp_counter.fetchAdd(1, .monotonic);
        const p = std.fmt.bufPrintSentinel(out, "{s}/zeron-sound-{d}-{d}.wav", .{ dir, linux.getpid(), id }, 0) catch return error.NameTooLong;
        const rc = linux.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .EXIST => continue,
            else => return error.CreateFailed,
        }
    }
    return error.CreateFailed;
}

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Run `argv + path`, waiting up to 10 s (then kill). True on exit status 0.
fn runChecked(argv: []const []const u8, path: [:0]const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv_z = arena.allocSentinel(?[*:0]const u8, argv.len + 1, null) catch return false;
    for (argv, 0..) |a, i| argv_z[i] = (arena.dupeSentinel(u8, a, 0) catch return false).ptr;
    argv_z[argv.len] = path.ptr;
    const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = false }, 0);
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return false;
    if (pid == 0) {
        if (linux.errno(devnull) == .SUCCESS) {
            const nfd: i32 = @intCast(devnull);
            _ = linux.dup2(nfd, 0);
            _ = linux.dup2(nfd, 1);
            _ = linux.dup2(nfd, 2);
        }
        _ = execvp(argv_z[0].?, argv_z.ptr);
        linux.exit(127);
    }
    if (linux.errno(devnull) == .SUCCESS) _ = linux.close(@intCast(devnull));
    const child: linux.pid_t = @intCast(pid);
    var waited: u32 = 0;
    while (true) {
        var status: i32 = 0;
        const rc = linux.waitpid(child, &status, linux.W.NOHANG);
        if (linux.errno(rc) != .SUCCESS) return false;
        if (rc == child) {
            const st: u32 = @bitCast(status);
            return linux.W.IFEXITED(st) and linux.W.EXITSTATUS(st) == 0;
        }
        if (waited >= 400) { // 400 × 25 ms = 10 s
            _ = linux.kill(child, linux.SIG.KILL);
            _ = linux.waitpid(child, &status, 0);
            return false;
        }
        const ts: linux.timespec = .{ .sec = 0, .nsec = 25 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
        waited += 1;
    }
}

/// Fire-and-forget `fork`+`execvp` (double fork: no zombie).
fn spawnDetached(gpa: Allocator, argv: []const []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv_z = arena.allocSentinel(?[*:0]const u8, argv.len, null) catch return;
    for (argv, 0..) |a, i| argv_z[i] = (arena.dupeSentinel(u8, a, 0) catch return).ptr;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return;
    if (pid == 0) {
        if (linux.fork() == 0) {
            _ = execvp(argv_z[0].?, argv_z.ptr);
        }
        linux.exit(0);
    }
    var status: i32 = 0;
    _ = linux.waitpid(@intCast(pid), &status, 0);
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "Notify body marshals susssasa{sv}i and parses back" {
    const gpa = testing.allocator;
    const body = try notifyBody(gpa, "Zeron", "Run finished", "My chat", true);
    defer gpa.free(body);
    var r: dbus.Reader = .{ .bytes = body, .pos = 0, .big = false };
    try testing.expectEqualStrings("Zeron", try r.str());
    try testing.expectEqual(@as(u32, 0), try r.u32_());
    try testing.expectEqualStrings("", try r.str());
    try testing.expectEqualStrings("Run finished", try r.str());
    try testing.expectEqualStrings("My chat", try r.str());
    const actions_len = try r.u32_();
    const actions_end = r.pos + actions_len;
    try testing.expectEqualStrings("default", try r.str());
    try testing.expectEqualStrings("Open", try r.str());
    try testing.expectEqual(actions_end, r.pos);
    try testing.expectEqual(@as(u32, 0), try r.u32_()); // empty hints
    try r.alignTo(8);
    try testing.expectEqual(@as(u32, @bitCast(@as(i32, -1))), try r.u32_());
    try testing.expectEqual(body.len, r.pos);
    // The whole call is a valid D-Bus message.
    const msg = try dbus.buildCall(gpa, .{ .serial = 7, .destination = service, .path = object_path, .interface = interface, .member = "Notify", .body = .{ .bytes = body, .signature = notify_signature } });
    defer gpa.free(msg);
    const m = try dbus.parseMessage(msg);
    try testing.expectEqualStrings("Notify", m.member);
    try testing.expectEqualStrings(notify_signature, m.signature);
}

test "ActionInvoked / NotificationClosed / Notify reply parsing" {
    const gpa = testing.allocator;
    var b: dbus.Builder = .{ .gpa = gpa };
    defer b.buf.deinit(gpa);
    try b.u32_(42);
    try b.str("default");
    const m: dbus.Message = .{ .type = .signal, .big_endian = false, .serial = 3, .interface = interface, .member = "ActionInvoked", .signature = "us", .body = b.buf.items };
    const ev = parseActionInvoked(m).?;
    try testing.expectEqual(@as(u32, 42), ev.id);
    try testing.expectEqualStrings("default", ev.action);
    var closed = m;
    closed.member = "NotificationClosed";
    try testing.expectEqual(@as(?u32, 42), parseClosed(closed));
    try testing.expect(parseActionInvoked(closed) == null);
    const reply: dbus.Message = .{ .type = .method_return, .big_endian = false, .serial = 4, .reply_serial = 7, .signature = "u", .body = b.buf.items[0..4] };
    try testing.expectEqual(@as(?u32, 42), parseNotifyReply(reply));
}

// Integration test against a real bus: set ZPUI_TEST_NOTIFY_BUS to a session bus address
// that runs an org.freedesktop.Notifications server which answers Notify and then emits
// ActionInvoked(id, "default") (scripts/notify-stub.py does).
test "Notifier posts over D-Bus and reports the click (opt-in: ZPUI_TEST_NOTIFY_BUS)" {
    const address = getenv("ZPUI_TEST_NOTIFY_BUS") orelse return error.SkipZigTest;
    const gpa = testing.allocator;
    const tp_mod = @import("../../app/test_platform.zig");
    var td = tp_mod.TestDispatcher.init(gpa);
    defer td.deinit();
    const Sink = struct {
        var clicked: [64]u8 = undefined;
        var len: usize = 0;
        fn onClick(_: ?*anyopaque, tag: []const u8) void {
            @memcpy(clicked[0..tag.len], tag);
            len = tag.len;
        }
    };
    const cbs: platform.PlatformCallbacks = .{ .notification_activated = Sink.onClick };
    const n = try Notifier.create(gpa, testing.io, td.dispatcher(), &cbs, .{ .bus_address = address, .fallback = false });
    defer n.destroy();
    n.post(.{ .title = "Run finished", .body = "Fix flaky Button snapshot test", .tag = "chat-42", .app_name = "Zeron" });
    var waited: usize = 0;
    while (Sink.len == 0 and waited < 100) : (waited += 1) {
        const ts: linux.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = linux.nanosleep(&ts, null);
        td.runUntilParked();
    }
    try testing.expectEqual(@as(u32, 1), n.delivered.load(.monotonic));
    try testing.expectEqualStrings("chat-42", Sink.clicked[0..Sink.len]);
}
