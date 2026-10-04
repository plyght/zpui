//! Native "open file" dialog on Linux (gpui_linux `prompt_for_paths`).
//!
//! First choice is the XDG desktop portal (`org.freedesktop.portal.FileChooser.OpenFile`
//! over the pure-Zig D-Bus client in dbus.zig), which works in sandboxes and on every
//! desktop that ships a portal backend. The answer arrives as a
//! `org.freedesktop.portal.Request.Response` signal on the request object; its
//! `uris` result holds `file://` URIs. When no portal answers (no session bus, no
//! FileChooser backend) `zenity --file-selection`, then `kdialog --getopenfilename`
//! are tried. Everything blocks, so the whole flow runs on its own thread and the
//! result is posted back to the main thread through the dispatcher.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");
const dbus = @import("dbus.zig");

const portal_dest = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const file_chooser = "org.freedesktop.portal.FileChooser";
const request_iface = "org.freedesktop.portal.Request";

/// Owned dialog result (null paths = canceled / unavailable).
const Result = struct {
    gpa: Allocator,
    done: platform.PathsCallback,
    paths: ?[][]u8 = null,

    fn deinit(self: *Result) void {
        if (self.paths) |ps| {
            for (ps) |p| self.gpa.free(p);
            self.gpa.free(ps);
        }
        self.gpa.destroy(self);
    }

    fn runMain(ctx: *anyopaque) void {
        const self: *Result = @ptrCast(@alignCast(ctx));
        defer self.deinit();
        if (self.paths) |ps| {
            const view: []const []const u8 = @ptrCast(ps);
            self.done.func(self.done.ctx, view);
        } else self.done.func(self.done.ctx, null);
    }

    fn drop(ctx: *anyopaque) void {
        const self: *Result = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};

const Job = struct {
    gpa: Allocator,
    dispatcher: platform.Dispatcher,
    options: platform.PathPromptOptions,
    /// Owned copies of the option strings.
    prompt: ?[]u8,
    title: ?[]u8,
    result: *Result,
    env: Env,

    fn main(self: *Job) void {
        const gpa = self.gpa;
        const paths = run(gpa, self.env, self.options) catch null;
        self.result.paths = paths;
        self.dispatcher.dispatchOnMainThread(.{ .ctx = self.result, .run = Result.runMain, .drop = Result.drop }, .high);
        if (self.prompt) |p| gpa.free(p);
        if (self.title) |t| gpa.free(t);
        gpa.destroy(self);
    }
};

pub const Env = struct {
    bus_address: ?[]const u8 = null,
    runtime_dir: ?[]const u8 = null,
    /// Skip the portal (tests / `ZPUI_NO_FILE_PORTAL`).
    portal: bool = true,
    /// Allow zenity/kdialog.
    fallback: bool = true,

    pub fn fromProcess() Env {
        const addr = std.c.getenv("DBUS_SESSION_BUS_ADDRESS");
        const rt = std.c.getenv("XDG_RUNTIME_DIR");
        return .{
            .bus_address = if (addr) |p| std.mem.span(p) else null,
            .runtime_dir = if (rt) |p| std.mem.span(p) else null,
            .portal = std.c.getenv("ZPUI_NO_FILE_PORTAL") == null,
        };
    }
};

/// Start a dialog; `done` runs on the main thread exactly once.
pub fn prompt(gpa: Allocator, dispatcher: platform.Dispatcher, options: platform.PathPromptOptions, done: platform.PathsCallback) void {
    const result = gpa.create(Result) catch return done.func(done.ctx, null);
    result.* = .{ .gpa = gpa, .done = done };
    const job = gpa.create(Job) catch {
        gpa.destroy(result);
        return done.func(done.ctx, null);
    };
    var opts = options;
    const p = if (options.prompt) |s| gpa.dupe(u8, s) catch null else null;
    const t = if (options.title) |s| gpa.dupe(u8, s) catch null else null;
    opts.prompt = p;
    opts.title = t;
    job.* = .{ .gpa = gpa, .dispatcher = dispatcher, .options = opts, .prompt = p, .title = t, .result = result, .env = Env.fromProcess() };
    const thread = std.Thread.spawn(.{}, Job.main, .{job}) catch {
        if (p) |s| gpa.free(s);
        if (t) |s| gpa.free(s);
        gpa.destroy(job);
        gpa.destroy(result);
        return done.func(done.ctx, null);
    };
    thread.detach();
}

/// Blocking dialog flow. Null = canceled; error = no dialog could be shown.
pub fn run(gpa: Allocator, env: Env, options: platform.PathPromptOptions) !?[][]u8 {
    if (env.portal) {
        if (portalOpenFile(gpa, env, options)) |outcome| switch (outcome) {
            .paths => |ps| return ps,
            .canceled => return null,
        } else |_| {}
    }
    if (!env.fallback) return error.Unavailable;
    if (try runFallback(gpa, options, .zenity)) |r| return r.paths;
    if (try runFallback(gpa, options, .kdialog)) |r| return r.paths;
    return error.Unavailable;
}

// ---------------------------------------------------------------------------------------
// Portal
// ---------------------------------------------------------------------------------------

const Outcome = union(enum) { paths: [][]u8, canceled };

/// Escapes a unique bus name for the request path (`:1.42` → `1_42`).
pub fn requestPath(buf: []u8, unique_name: []const u8, token: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(portal_path ++ "/request/") catch return null;
    const name = if (unique_name.len > 0 and unique_name[0] == ':') unique_name[1..] else unique_name;
    for (name) |ch| w.writeByte(if (ch == '.') '_' else ch) catch return null;
    w.writeByte('/') catch return null;
    w.writeAll(token) catch return null;
    return w.buffered();
}

/// Marshals the `OpenFile(s parent_window, s title, a{sv} options)` body.
pub fn openFileBody(gpa: Allocator, title: []const u8, token: []const u8, options: platform.PathPromptOptions) ![]u8 {
    var b: dbus.Builder = .{ .gpa = gpa };
    errdefer b.buf.deinit(gpa);
    try b.str("");
    try b.str(title);
    const arr = try dbus.Body.beginArray(&b, 8);
    try dbus.Body.dictEntry(&b, "handle_token", "s");
    try b.str(token);
    try dbus.Body.dictEntry(&b, "modal", "b");
    try dbus.Body.boolean(&b, true);
    try dbus.Body.dictEntry(&b, "multiple", "b");
    try dbus.Body.boolean(&b, options.multiple);
    if (options.directories and !options.files) {
        try dbus.Body.dictEntry(&b, "directory", "b");
        try dbus.Body.boolean(&b, true);
    }
    if (options.prompt) |label| {
        try dbus.Body.dictEntry(&b, "accept_label", "s");
        try b.str(label);
    }
    dbus.Body.endArray(&b, arr);
    return b.buf.toOwnedSlice(gpa);
}

/// Parses a `Response(u response, a{sv} results)` body into owned paths
/// (`.canceled` for a non-zero response code).
pub fn parseResponse(gpa: Allocator, m: dbus.Message) !Outcome {
    if (!std.mem.eql(u8, m.signature, "ua{sv}")) return error.BadMessage;
    var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
    const code = try r.u32_();
    if (code != 0) return .canceled;
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    const len = try r.u32_();
    try r.alignTo(8);
    const end = r.pos + len;
    if (end > r.bytes.len) return error.Truncated;
    while (r.pos < end) {
        try r.alignTo(8);
        const key = try r.str();
        const t = try r.sig();
        if (std.mem.eql(u8, key, "uris") and std.mem.eql(u8, t, "as")) {
            const n = try r.u32_();
            const list_end = r.pos + n;
            if (list_end > r.bytes.len) return error.Truncated;
            while (r.pos < list_end) {
                const uri = try r.str();
                if (try pathFromUri(gpa, uri)) |p| try out.append(gpa, p);
            }
        } else try r.skip(t);
    }
    return .{ .paths = try out.toOwnedSlice(gpa) };
}

/// `file:///a%20b` → `/a b` (owned); null for non-file URIs.
pub fn pathFromUri(gpa: Allocator, uri: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    var rest = uri["file://".len..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[slash..] else return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |v| {
                try out.append(gpa, v);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, rest[i]);
    }
    return try out.toOwnedSlice(gpa);
}

var token_counter: std.atomic.Value(u32) = .init(1);

const Conn = struct {
    gpa: Allocator,
    fd: linux.fd_t,
    rx: std.ArrayList(u8) = .empty,
    serial: u32 = 1,

    fn deinit(c: *Conn) void {
        _ = linux.close(c.fd);
        c.rx.deinit(c.gpa);
    }

    fn send(c: *Conn, call: dbus.Call) !u32 {
        var cl = call;
        cl.serial = c.serial;
        c.serial += 1;
        const bytes = try dbus.buildCall(c.gpa, cl);
        defer c.gpa.free(bytes);
        if (!dbus.writeAll(c.fd, bytes)) return error.WriteFailed;
        return cl.serial;
    }

    /// Next complete message (blocking up to `timeout_ms`, -1 = forever). The
    /// returned message borrows `rx` until the next call.
    fn next(c: *Conn, timeout_ms: i32, consumed: *usize) !dbus.Message {
        if (consumed.* > 0) {
            const rest = c.rx.items.len - consumed.*;
            std.mem.copyForwards(u8, c.rx.items[0..rest], c.rx.items[consumed.*..]);
            c.rx.shrinkRetainingCapacity(rest);
            consumed.* = 0;
        }
        while (true) {
            if (try dbus.messageLength(c.rx.items)) |len| {
                consumed.* = len;
                return dbus.parseMessage(c.rx.items[0..len]);
            }
            if (!dbus.waitReadable(c.fd, timeout_ms)) return error.Timeout;
            var chunk: [4096]u8 = undefined;
            const n = linux.read(c.fd, &chunk, chunk.len);
            switch (linux.errno(n)) {
                .SUCCESS => {
                    if (n == 0) return error.Closed;
                    try c.rx.appendSlice(c.gpa, chunk[0..n]);
                },
                .INTR, .AGAIN => {},
                else => return error.Closed,
            }
        }
    }

    /// Waits for the reply to `serial`, ignoring other traffic.
    fn reply(c: *Conn, serial: u32, timeout_ms: i32, consumed: *usize) !dbus.Message {
        while (true) {
            const m = try c.next(timeout_ms, consumed);
            if (m.reply_serial == serial) return m;
        }
    }
};

fn portalOpenFile(gpa: Allocator, env: Env, options: platform.PathPromptOptions) !Outcome {
    const fd = dbus.connectBus(env.bus_address, env.runtime_dir) orelse return error.NoBus;
    var c: Conn = .{ .gpa = gpa, .fd = fd };
    defer c.deinit();
    var consumed: usize = 0;

    const hello = try c.send(.{ .serial = 0, .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "Hello" });
    const hello_reply = try c.reply(hello, 2000, &consumed);
    if (hello_reply.type != .method_return) return error.NoBus;
    var name_buf: [128]u8 = undefined;
    const unique = blk: {
        var r: dbus.Reader = .{ .bytes = hello_reply.body, .pos = 0, .big = hello_reply.big_endian };
        const n = try r.str();
        if (n.len > name_buf.len) return error.BadMessage;
        @memcpy(name_buf[0..n.len], n);
        break :blk name_buf[0..n.len];
    };

    var token_buf: [32]u8 = undefined;
    const seq = token_counter.fetchAdd(1, .monotonic);
    const token = std.fmt.bufPrint(&token_buf, "zpui{d}_{d}", .{ linux.getpid(), seq }) catch unreachable;
    var path_buf: [256]u8 = undefined;
    const expected = requestPath(&path_buf, unique, token) orelse return error.BadMessage;

    var rule_buf: [512]u8 = undefined;
    const rule = std.fmt.bufPrint(&rule_buf, "type='signal',interface='{s}',member='Response',path='{s}'", .{ request_iface, expected }) catch return error.BadMessage;
    const add_match = try c.send(.{ .serial = 0, .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "AddMatch", .args = &.{rule} });
    _ = try c.reply(add_match, 2000, &consumed);

    const body = try openFileBody(gpa, options.title orelse "Open", token, options);
    defer gpa.free(body);
    const open = try c.send(.{ .serial = 0, .destination = portal_dest, .path = portal_path, .interface = file_chooser, .member = "OpenFile", .body = .{ .bytes = body, .signature = "ssa{sv}" } });

    // The handle normally equals `expected`; older portals may pick another one.
    var handle_buf: [256]u8 = undefined;
    var handle: []const u8 = expected;
    var got_reply = false;
    while (true) {
        const m = try c.next(if (got_reply) -1 else 5000, &consumed);
        if (m.reply_serial == open) {
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
            return parseResponse(gpa, m);
        }
    }
}

// ---------------------------------------------------------------------------------------
// zenity / kdialog
// ---------------------------------------------------------------------------------------

const Tool = enum { zenity, kdialog };

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const FallbackResult = struct { paths: ?[][]u8 };

/// Runs the tool; null when it is not installed (exit 127 before any output).
fn runFallback(gpa: Allocator, options: platform.PathPromptOptions, tool: Tool) !?FallbackResult {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    const title = try arena.dupeSentinel(u8, options.title orelse "Open", 0);
    switch (tool) {
        .zenity => {
            try argv.appendSlice(arena, &.{ "zenity", "--file-selection", "--separator=\n" });
            try argv.append(arena, (try std.fmt.allocPrintSentinel(arena, "--title={s}", .{title}, 0)).ptr);
            if (options.multiple) try argv.append(arena, "--multiple");
            if (options.directories and !options.files) try argv.append(arena, "--directory");
        },
        .kdialog => {
            const mode: [*:0]const u8 = if (options.directories and !options.files) "--getexistingdirectory" else "--getopenfilename";
            try argv.appendSlice(arena, &.{ "kdialog", "--title", title.ptr, mode, "." });
            if (options.multiple) try argv.appendSlice(arena, &.{ "--multiple", "--separate-output" });
        },
    }
    try argv.append(arena, null);
    const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(argv.items.ptr);

    var fds: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return error.Fork;
    }
    if (pid == 0) {
        _ = linux.dup2(fds[1], 1);
        const devnull = linux.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0);
        if (linux.errno(devnull) == .SUCCESS) _ = linux.dup2(@intCast(devnull), 2);
        _ = execvp(argv_z[0].?, argv_z);
        linux.exit(127);
    }
    _ = linux.close(fds[1]);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = linux.read(fds[0], &chunk, chunk.len);
        switch (linux.errno(n)) {
            .SUCCESS => {
                if (n == 0) break;
                try out.appendSlice(gpa, chunk[0..n]);
            },
            .INTR => continue,
            else => break,
        }
    }
    _ = linux.close(fds[0]);
    var raw_status: i32 = 0;
    while (true) {
        const rc = linux.wait4(@intCast(pid), &raw_status, 0, null);
        if (linux.errno(rc) == .INTR) continue;
        break;
    }
    const status: u32 = @bitCast(raw_status);
    const exited = (status & 0x7f) == 0;
    const code: u32 = (status >> 8) & 0xff;
    if (!exited or code == 127) return null;
    if (code != 0) return .{ .paths = null };
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |p| gpa.free(p);
        list.deinit(gpa);
    }
    var it = std.mem.tokenizeAny(u8, out.items, "\r\n");
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try list.append(gpa, try gpa.dupe(u8, line));
    }
    if (list.items.len == 0) return .{ .paths = null };
    return .{ .paths = try list.toOwnedSlice(gpa) };
}

// ---------------------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "request path escapes the unique name" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("/org/freedesktop/portal/desktop/request/1_42/zpui7", requestPath(&buf, ":1.42", "zpui7").?);
}

test "OpenFile body marshals ssa{sv}" {
    const gpa = testing.allocator;
    const body = try openFileBody(gpa, "Attach", "tok", .{ .multiple = true, .prompt = "Attach" });
    defer gpa.free(body);
    var r: dbus.Reader = .{ .bytes = body, .pos = 0, .big = false };
    try testing.expectEqualStrings("", try r.str());
    try testing.expectEqualStrings("Attach", try r.str());
    const n = try r.u32_();
    try r.alignTo(8);
    const end = r.pos + n;
    var keys: usize = 0;
    var multiple = false;
    while (r.pos < end) {
        try r.alignTo(8);
        const key = try r.str();
        const t = try r.sig();
        if (std.mem.eql(u8, key, "multiple")) multiple = (try r.u32_()) == 1 else try r.skip(t);
        keys += 1;
    }
    try testing.expectEqual(@as(usize, 4), keys);
    try testing.expect(multiple);
    try testing.expectEqual(body.len, r.pos);
}

test "Response parsing extracts file URIs" {
    const gpa = testing.allocator;
    var b: dbus.Builder = .{ .gpa = gpa };
    defer b.buf.deinit(gpa);
    try b.u32_(0);
    const arr = try dbus.Body.beginArray(&b, 8);
    try dbus.Body.dictEntry(&b, "current_filter", "(sa(us))");
    try b.pad(8);
    try b.str("Images");
    const inner = try dbus.Body.beginArray(&b, 8);
    try b.pad(8);
    try b.u32_(0);
    try b.str("*.png");
    dbus.Body.endArray(&b, inner);
    try dbus.Body.dictEntry(&b, "uris", "as");
    const uris = try dbus.Body.beginArray(&b, 4);
    try b.str("file:///tmp/a%20b.png");
    try b.str("file://host/tmp/c.jpg");
    try b.str("https://example.com/x");
    dbus.Body.endArray(&b, uris);
    dbus.Body.endArray(&b, arr);
    const m: dbus.Message = .{ .type = .signal, .big_endian = false, .serial = 1, .signature = "ua{sv}", .body = b.buf.items };
    const outcome = try parseResponse(gpa, m);
    const ps = outcome.paths;
    defer {
        for (ps) |p| gpa.free(p);
        gpa.free(ps);
    }
    try testing.expectEqual(@as(usize, 2), ps.len);
    try testing.expectEqualStrings("/tmp/a b.png", ps[0]);
    try testing.expectEqualStrings("/tmp/c.jpg", ps[1]);

    var cb: dbus.Builder = .{ .gpa = gpa };
    defer cb.buf.deinit(gpa);
    try cb.u32_(1);
    const empty = try dbus.Body.beginArray(&cb, 8);
    dbus.Body.endArray(&cb, empty);
    const canceled = try parseResponse(gpa, .{ .type = .signal, .big_endian = false, .serial = 2, .signature = "ua{sv}", .body = cb.buf.items });
    try testing.expect(canceled == .canceled);
}
