//! AT-SPI2 *client* (reading another application's accessibility tree) for the
//! Appshot X11 backend — zeron `appshots/linux/atspi.rs` (atspi crate) over the
//! pure-Zig D-Bus client. (atspi.zig is the other direction: zpui's own server.)
//!
//! `captureWindow(pid, title)`:
//!   1. connect to the accessibility bus (`$AT_SPI_BUS_ADDRESS` or
//!      `org.a11y.Bus.GetAddress` on the session bus);
//!   2. select the window: among the registry root's applications whose bus name's
//!      Unix PID (`org.freedesktop.DBus.GetConnectionUnixProcessID`) equals `pid`,
//!      exactly one top-level child must be named exactly `title`, and it must be
//!      Active or Focused; anything else (ambiguity, missing metadata, any D-Bus
//!      error) yields no semantics;
//!   3. walk it breadth-first (depth ≤ 24, ≤ 1500 nodes, ≤ 96 KiB, 900 ms for the
//!      whole operation) writing `"{indent}{role name}: {name | description | text}"`
//!      lines; password text is never read;
//!   4. select again and require the same (bus name, path) identity.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const dbus = @import("dbus.zig");
const common = @import("../capture_common.zig");

pub const max_depth: usize = 24;
pub const max_nodes: usize = 1_500;
pub const max_bytes: usize = 96 * 1024;
pub const max_text_chars: i32 = 4_096;
pub const deadline_ns: u64 = 900 * std.time.ns_per_ms;

const registry = "org.a11y.atspi.Registry";
const root_path = "/org/a11y/atspi/accessible/root";
const accessible_iface = "org.a11y.atspi.Accessible";
const text_iface = "org.a11y.atspi.Text";
const props_iface = "org.freedesktop.DBus.Properties";

const role_password_text: u32 = 40;
const state_active: u32 = 1;
const state_focused: u32 = 12;

/// atspi-common `Role::name()` (index = AtspiRole).
pub const role_names = [_][]const u8{
    "invalid",               "accelerator label",     "alert",                "animation",          "arrow",                 "calendar",             "canvas",              "check box",
    "check menu item",       "color chooser",         "column header",        "combo box",          "date editor",           "desktop icon",         "desktop frame",       "dial",
    "dialog",                "directory pane",        "drawing area",         "file chooser",       "filler",                "focus traversable",    "font chooser",        "frame",
    "glass pane",            "html container",        "icon",                 "image",              "internal frame",        "label",                "layered pane",        "list",
    "list item",             "menu",                  "menu bar",             "menu item",          "option pane",           "page tab",             "page tab list",       "panel",
    "password text",         "popup menu",            "progress bar",         "button",             "radio button",          "radio menu item",      "root pane",           "row header",
    "scroll bar",            "scroll pane",           "separator",            "slider",             "spin button",           "split pane",           "status bar",          "table",
    "table cell",            "table column header",   "table row header",     "tearoff menu item",  "terminal",              "text",                 "toggle button",       "tool bar",
    "tool tip",              "tree",                  "tree table",           "unknown",            "viewport",              "window",               "extended",            "header",
    "footer",                "paragraph",             "ruler",                "application",        "autocomplete",          "editbar",              "embedded",            "entry",
    "chart",                 "caption",               "document frame",       "heading",            "page",                  "section",              "redundant object",    "form",
    "link",                  "input method window",   "table row",            "tree item",          "document spreadsheet",  "document presentation", "document text",      "document web",
    "document email",        "comment",               "list box",             "grouping",           "image map",             "notification",         "info bar",            "level bar",
    "title bar",             "block quote",           "audio",                "video",              "definition",            "article",              "landmark",            "log",
    "marquee",               "math",                  "rating",               "timer",              "static",                "math fraction",        "math root",           "subscript",
    "superscript",           "description list",      "description term",     "description value",  "footnote",              "content deletion",     "content insertion",   "mark",
    "suggestion",            "push button menu",
};

pub fn roleName(role: u32) []const u8 {
    return if (role < role_names.len) role_names[role] else "invalid";
}

// ---------------------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------------------

/// A method reply, borrowed until the next call.
pub const Reply = struct {
    ok: bool,
    signature: []const u8,
    body: []const u8,
    big: bool = false,

    fn reader(self: Reply) dbus.Reader {
        return .{ .bytes = self.body, .pos = 0, .big = self.big };
    }
};

/// A blocking method-call transport (the accessibility bus; a fake in tests).
pub const Bus = struct {
    ctx: *anyopaque,
    callFn: *const fn (ctx: *anyopaque, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, signature: []const u8, body: []const u8, timeout_ms: i32) anyerror!Reply,
};

/// A real `dbus.Connection` as a `Bus`.
pub const ConnBus = struct {
    conn: dbus.Connection,

    pub fn bus(self: *ConnBus) Bus {
        return .{ .ctx = self, .callFn = call };
    }

    fn call(ctx: *anyopaque, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, signature: []const u8, body: []const u8, timeout_ms: i32) anyerror!Reply {
        const self: *ConnBus = @ptrCast(@alignCast(ctx));
        const serial = try self.conn.send(.{ .serial = 0, .destination = dest, .path = path, .interface = iface, .member = member, .body = .{ .bytes = body, .signature = signature } });
        const m = try self.conn.reply(serial, @max(1, timeout_ms));
        return .{ .ok = m.type == .method_return, .signature = m.signature, .body = m.body, .big = m.big_endian };
    }
};

// ---------------------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------------------

pub const ObjectRef = struct {
    name: []u8,
    path: []u8,

    pub fn eql(a: ObjectRef, b: ObjectRef) bool {
        return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.path, b.path);
    }
    fn deinit(self: ObjectRef, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.path);
    }
};

fn freeRefs(gpa: Allocator, refs: []ObjectRef) void {
    for (refs) |r| r.deinit(gpa);
    gpa.free(refs);
}

pub const Semantic = struct {
    app_name: []u8,
    content: []u8,
    truncated: bool,

    pub fn deinit(self: *Semantic, gpa: Allocator) void {
        gpa.free(self.app_name);
        gpa.free(self.content);
    }
};

fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub const Client = struct {
    gpa: Allocator,
    bus: Bus,
    started: u64,
    /// Injectable clock (tests).
    clock: *const fn () u64 = monotonicNs,

    fn elapsed(self: *const Client) u64 {
        return self.clock() -| self.started;
    }

    fn remainingMs(self: *const Client) !i32 {
        const e = self.elapsed();
        if (e >= deadline_ns) return error.Timeout;
        return @intCast(@max(1, (deadline_ns - e) / std.time.ns_per_ms));
    }

    fn call(self: *Client, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, signature: []const u8, body: []const u8) !Reply {
        const r = try self.bus.callFn(self.bus.ctx, dest, path, iface, member, signature, body, try self.remainingMs());
        if (!r.ok) return error.CallFailed;
        return r;
    }

    fn getProperty(self: *Client, ref: ObjectRef, iface: []const u8, prop: []const u8, expect: []const u8) !dbus.Reader {
        var b: dbus.Builder = .{ .gpa = self.gpa };
        defer b.buf.deinit(self.gpa);
        try b.str(iface);
        try b.str(prop);
        const r = try self.call(ref.name, ref.path, props_iface, "Get", "ss", b.buf.items);
        if (!std.mem.eql(u8, r.signature, "v")) return error.BadMessage;
        var rd = r.reader();
        const t = try rd.sig();
        if (!std.mem.eql(u8, t, expect)) return error.BadMessage;
        return rd;
    }

    fn stringProperty(self: *Client, ref: ObjectRef, iface: []const u8, prop: []const u8) ![]u8 {
        var rd = try self.getProperty(ref, iface, prop, "s");
        return self.gpa.dupe(u8, try rd.str());
    }

    pub fn name(self: *Client, ref: ObjectRef) ![]u8 {
        return self.stringProperty(ref, accessible_iface, "Name");
    }

    pub fn description(self: *Client, ref: ObjectRef) ![]u8 {
        return self.stringProperty(ref, accessible_iface, "Description");
    }

    pub fn children(self: *Client, ref: ObjectRef) ![]ObjectRef {
        const r = try self.call(ref.name, ref.path, accessible_iface, "GetChildren", "", "");
        if (!std.mem.eql(u8, r.signature, "a(so)")) return error.BadMessage;
        var rd = r.reader();
        const len = try rd.u32_();
        try rd.alignTo(8);
        const end = rd.pos + len;
        if (end > rd.bytes.len) return error.Truncated;
        var out: std.ArrayList(ObjectRef) = .empty;
        errdefer {
            for (out.items) |o| o.deinit(self.gpa);
            out.deinit(self.gpa);
        }
        while (rd.pos < end) {
            try rd.alignTo(8);
            const n = try rd.str();
            const p = try rd.str();
            const owned_name = try self.gpa.dupe(u8, n);
            errdefer self.gpa.free(owned_name);
            try out.append(self.gpa, .{ .name = owned_name, .path = try self.gpa.dupe(u8, p) });
        }
        return out.toOwnedSlice(self.gpa);
    }

    pub fn role(self: *Client, ref: ObjectRef) !u32 {
        const r = try self.call(ref.name, ref.path, accessible_iface, "GetRole", "", "");
        if (!std.mem.eql(u8, r.signature, "u")) return error.BadMessage;
        var rd = r.reader();
        return rd.u32_();
    }

    pub fn states(self: *Client, ref: ObjectRef) !u64 {
        const r = try self.call(ref.name, ref.path, accessible_iface, "GetState", "", "");
        if (!std.mem.eql(u8, r.signature, "au")) return error.BadMessage;
        var rd = r.reader();
        const len = try rd.u32_();
        const end = rd.pos + len;
        var bits: u64 = 0;
        var word: u6 = 0;
        while (rd.pos < end and word < 2) : (word += 1) bits |= @as(u64, try rd.u32_()) << (word * 32);
        return bits;
    }

    pub fn hasTextInterface(self: *Client, ref: ObjectRef) !bool {
        const r = try self.call(ref.name, ref.path, accessible_iface, "GetInterfaces", "", "");
        if (!std.mem.eql(u8, r.signature, "as")) return error.BadMessage;
        var rd = r.reader();
        const len = try rd.u32_();
        const end = rd.pos + len;
        while (rd.pos < end) if (std.mem.eql(u8, try rd.str(), text_iface)) return true;
        return false;
    }

    pub fn text(self: *Client, ref: ObjectRef) ![]u8 {
        var rd = try self.getProperty(ref, text_iface, "CharacterCount", "i");
        const raw: i32 = @bitCast(try rd.u32_());
        const count = std.math.clamp(raw, 0, max_text_chars);
        var b: dbus.Builder = .{ .gpa = self.gpa };
        defer b.buf.deinit(self.gpa);
        try b.i32_(0);
        try b.i32_(count);
        const r = try self.call(ref.name, ref.path, text_iface, "GetText", "ii", b.buf.items);
        if (!std.mem.eql(u8, r.signature, "s")) return error.BadMessage;
        var tr = r.reader();
        return self.gpa.dupe(u8, try tr.str());
    }

    pub fn pidOf(self: *Client, bus_name: []const u8) !u32 {
        var b: dbus.Builder = .{ .gpa = self.gpa };
        defer b.buf.deinit(self.gpa);
        try b.str(bus_name);
        const r = try self.call("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID", "s", b.buf.items);
        var rd = r.reader();
        return rd.u32_();
    }

    pub const Selected = struct { window: ObjectRef, app_name: []u8 };

    /// `select_window`: the unique, active top-level window of process `pid` titled
    /// exactly `title`.
    pub fn selectWindow(self: *Client, pid: u32, title: []const u8) !Selected {
        const gpa = self.gpa;
        const root: ObjectRef = .{ .name = @constCast(registry), .path = @constCast(root_path) };
        const apps = try self.children(root);
        defer freeRefs(gpa, apps);
        var found: ?Selected = null;
        var found_active = false;
        var matches: usize = 0;
        errdefer if (found) |f| {
            f.window.deinit(gpa);
            gpa.free(f.app_name);
        };
        for (apps) |app| {
            if (app.name.len == 0) continue;
            if ((try self.pidOf(app.name)) != pid) continue;
            const app_name = try self.name(app);
            defer gpa.free(app_name);
            const windows = try self.children(app);
            defer freeRefs(gpa, windows);
            for (windows) |win| {
                const n = try self.name(win);
                defer gpa.free(n);
                if (!std.mem.eql(u8, n, title)) continue;
                const st = try self.states(win);
                matches += 1;
                if (found) |f| {
                    f.window.deinit(gpa);
                    gpa.free(f.app_name);
                    found = null;
                }
                const wname = try gpa.dupe(u8, win.name);
                const wpath = gpa.dupe(u8, win.path) catch |e| {
                    gpa.free(wname);
                    return e;
                };
                const aname = gpa.dupe(u8, app_name) catch |e| {
                    gpa.free(wname);
                    gpa.free(wpath);
                    return e;
                };
                found = .{ .window = .{ .name = wname, .path = wpath }, .app_name = aname };
                found_active = st & (@as(u64, 1) << state_active) != 0 or st & (@as(u64, 1) << state_focused) != 0;
            }
        }
        if (matches != 1) return error.Ambiguous;
        if (!found_active) return error.Inactive;
        const f = found.?;
        found = null;
        return f;
    }

    /// `traverse`: breadth-first text of `root` (owned content).
    pub fn traverse(self: *Client, root: ObjectRef) !struct { content: []u8, truncated: bool } {
        const gpa = self.gpa;
        const Item = struct { ref: ObjectRef, depth: usize };
        var queue: std.ArrayList(Item) = .empty;
        defer {
            for (queue.items) |it| it.ref.deinit(gpa);
            queue.deinit(gpa);
        }
        try queue.append(gpa, .{ .ref = .{ .name = try gpa.dupe(u8, root.name), .path = try gpa.dupe(u8, root.path) }, .depth = 0 });
        var head: usize = 0;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var nodes: usize = 0;
        var truncated = false;
        while (head < queue.items.len) {
            const it = queue.items[head];
            head += 1;
            if (it.depth > max_depth or nodes >= max_nodes or out.items.len >= max_bytes or self.elapsed() >= deadline_ns) {
                truncated = true;
                break;
            }
            nodes += 1;
            const r = self.role(it.ref) catch 0;
            const nm = self.name(it.ref) catch try gpa.dupe(u8, "");
            defer gpa.free(nm);
            const desc = self.description(it.ref) catch try gpa.dupe(u8, "");
            defer gpa.free(desc);
            const has_text = r != role_password_text and (self.hasTextInterface(it.ref) catch false);
            const txt = if (has_text) (self.text(it.ref) catch try gpa.dupe(u8, "")) else try gpa.dupe(u8, "");
            defer gpa.free(txt);
            var fields: std.ArrayList([]u8) = .empty;
            defer {
                for (fields.items) |f| gpa.free(f);
                fields.deinit(gpa);
            }
            const ws = " \t\r\n\x0b\x0c";
            const name_trim = std.mem.trim(u8, nm, ws);
            if (name_trim.len > 0) try fields.append(gpa, try clean(gpa, nm));
            const desc_trim = std.mem.trim(u8, desc, ws);
            if (desc_trim.len > 0 and !std.mem.eql(u8, desc_trim, name_trim)) try fields.append(gpa, try clean(gpa, desc));
            const text_trim = std.mem.trim(u8, txt, ws);
            if (text_trim.len > 0 and !std.mem.eql(u8, text_trim, name_trim)) try fields.append(gpa, try clean(gpa, txt));
            if (fields.items.len > 0) {
                var line: std.ArrayList(u8) = .empty;
                defer line.deinit(gpa);
                for (0..it.depth) |_| try line.appendSlice(gpa, "  ");
                try line.appendSlice(gpa, roleName(r));
                try line.appendSlice(gpa, ": ");
                for (fields.items, 0..) |f, i| {
                    if (i > 0) try line.appendSlice(gpa, " | ");
                    try line.appendSlice(gpa, f);
                }
                try line.append(gpa, '\n');
                if (out.items.len + line.items.len > max_bytes) {
                    truncated = true;
                    break;
                }
                try out.appendSlice(gpa, line.items);
            }
            if (self.children(it.ref)) |kids| {
                defer gpa.free(kids);
                for (kids, 0..) |k, i| queue.append(gpa, .{ .ref = k, .depth = it.depth + 1 }) catch {
                    for (kids[i..]) |rest| rest.deinit(gpa);
                    break;
                };
            } else |_| {}
        }
        return .{ .content = try out.toOwnedSlice(gpa), .truncated = truncated };
    }

    /// `capture_window` body (connection already made).
    pub fn captureWindow(self: *Client, pid: u32, title: []const u8) !Semantic {
        if (pid == 0 or std.mem.trim(u8, title, " \t\r\n").len == 0) return error.MissingIdentity;
        const first = try self.selectWindow(pid, title);
        defer first.window.deinit(self.gpa);
        errdefer self.gpa.free(first.app_name);
        const snap = try self.traverse(first.window);
        errdefer self.gpa.free(snap.content);
        const after = try self.selectWindow(pid, title);
        defer {
            after.window.deinit(self.gpa);
            self.gpa.free(after.app_name);
        }
        if (!first.window.eql(after.window)) return error.WindowChanged;
        if (self.elapsed() >= deadline_ns) return error.Timeout;
        return .{ .app_name = first.app_name, .content = snap.content, .truncated = snap.truncated };
    }
};

/// `clean`: whitespace runs collapsed, at most 4096 characters.
pub fn clean(gpa: Allocator, value: []const u8) ![]u8 {
    return common.compactWhitespace(gpa, value, @intCast(max_text_chars), false);
}

pub const Env = struct {
    bus_address: ?[]const u8 = null,
    runtime_dir: ?[]const u8 = null,
    at_spi_address: ?[]const u8 = null,

    pub fn fromProcess() Env {
        const get = struct {
            fn f(n: [*:0]const u8) ?[]const u8 {
                return if (std.c.getenv(n)) |p| std.mem.span(p) else null;
            }
        }.f;
        return .{ .bus_address = get("DBUS_SESSION_BUS_ADDRESS"), .runtime_dir = get("XDG_RUNTIME_DIR"), .at_spi_address = get("AT_SPI_BUS_ADDRESS") };
    }
};

/// Connect to the accessibility bus and read window `(pid, title)`; null on any failure
/// (Appshots then carry the screenshot only).
pub fn captureWindow(gpa: Allocator, env: Env, pid: u32, title: []const u8) ?Semantic {
    if (pid == 0 or std.mem.trim(u8, title, " \t\r\n").len == 0) return null;
    const started = monotonicNs();
    var addr_buf: [512]u8 = undefined;
    const address: []const u8 = env.at_spi_address orelse blk: {
        var session = dbus.Connection.open(gpa, env.bus_address, env.runtime_dir) orelse return null;
        defer session.deinit();
        const serial = session.send(.{ .serial = 0, .destination = "org.a11y.Bus", .path = "/org/a11y/bus", .interface = "org.a11y.Bus", .member = "GetAddress" }) catch return null;
        const m = session.reply(serial, 500) catch return null;
        if (m.type != .method_return) return null;
        var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
        const a = r.str() catch return null;
        if (a.len > addr_buf.len) return null;
        @memcpy(addr_buf[0..a.len], a);
        break :blk addr_buf[0..a.len];
    };
    var cb: ConnBus = .{ .conn = dbus.Connection.open(gpa, address, null) orelse return null };
    defer cb.conn.deinit();
    var client: Client = .{ .gpa = gpa, .bus = cb.bus(), .started = started };
    return client.captureWindow(pid, title) catch null;
}

// ---------------------------------------------------------------------------------------
// Tests (a fake accessibility bus)
// ---------------------------------------------------------------------------------------

const testing = std.testing;

const FakeNode = struct {
    bus: []const u8,
    path: []const u8,
    name: []const u8 = "",
    description: []const u8 = "",
    role: u32 = 39,
    states: u32 = 0,
    text: ?[]const u8 = null,
    children: []const usize = &.{},
};

const FakeBus = struct {
    gpa: Allocator,
    nodes: []const FakeNode,
    pids: []const struct { []const u8, u32 },
    /// Registry root children.
    apps: []const usize,
    out: std.ArrayList(u8) = .empty,
    calls: usize = 0,
    text_reads: usize = 0,

    fn find(self: *FakeBus, bus: []const u8, path: []const u8) ?*const FakeNode {
        for (self.nodes) |*n| if (std.mem.eql(u8, n.bus, bus) and std.mem.eql(u8, n.path, path)) return n;
        return null;
    }

    fn writeRefs(self: *FakeBus, b: *dbus.Builder, ixs: []const usize) !void {
        const arr = try dbus.Body.beginArray(b, 8);
        for (ixs) |ix| {
            try b.pad(8);
            try b.str(self.nodes[ix].bus);
            try b.str(self.nodes[ix].path);
        }
        dbus.Body.endArray(b, arr);
    }

    fn call(ctx: *anyopaque, dest: []const u8, path: []const u8, iface: []const u8, member: []const u8, _: []const u8, body: []const u8, _: i32) anyerror!Reply {
        const self: *FakeBus = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.out.clearRetainingCapacity();
        var b: dbus.Builder = .{ .gpa = self.gpa, .buf = self.out };
        defer self.out = b.buf;
        var in: dbus.Reader = .{ .bytes = body, .pos = 0, .big = false };
        if (std.mem.eql(u8, member, "GetConnectionUnixProcessID")) {
            const n = try in.str();
            for (self.pids) |p| if (std.mem.eql(u8, p[0], n)) {
                try b.u32_(p[1]);
                return .{ .ok = true, .signature = "u", .body = b.buf.items };
            };
            return .{ .ok = false, .signature = "", .body = "" };
        }
        if (std.mem.eql(u8, dest, registry) and std.mem.eql(u8, member, "GetChildren")) {
            try self.writeRefs(&b, self.apps);
            return .{ .ok = true, .signature = "a(so)", .body = b.buf.items };
        }
        const node = self.find(dest, path) orelse return .{ .ok = false, .signature = "", .body = "" };
        if (std.mem.eql(u8, member, "Get")) {
            const ifc = try in.str();
            const prop = try in.str();
            if (std.mem.eql(u8, prop, "CharacterCount")) {
                const t = node.text orelse return .{ .ok = false, .signature = "", .body = "" };
                try b.sig("i");
                try b.i32_(@intCast(t.len));
            } else {
                _ = ifc;
                try b.sig("s");
                try b.str(if (std.mem.eql(u8, prop, "Name")) node.name else node.description);
            }
            return .{ .ok = true, .signature = "v", .body = b.buf.items };
        }
        if (std.mem.eql(u8, member, "GetChildren")) {
            try self.writeRefs(&b, node.children);
            return .{ .ok = true, .signature = "a(so)", .body = b.buf.items };
        }
        if (std.mem.eql(u8, member, "GetRole")) {
            try b.u32_(node.role);
            return .{ .ok = true, .signature = "u", .body = b.buf.items };
        }
        if (std.mem.eql(u8, member, "GetState")) {
            const arr = try dbus.Body.beginArray(&b, 4);
            try b.u32_(node.states);
            try b.u32_(0);
            dbus.Body.endArray(&b, arr);
            return .{ .ok = true, .signature = "au", .body = b.buf.items };
        }
        if (std.mem.eql(u8, member, "GetInterfaces")) {
            const arr = try dbus.Body.beginArray(&b, 4);
            try b.str(accessible_iface);
            if (node.text != null) try b.str(text_iface);
            dbus.Body.endArray(&b, arr);
            return .{ .ok = true, .signature = "as", .body = b.buf.items };
        }
        if (std.mem.eql(u8, member, "GetText") and std.mem.eql(u8, iface, text_iface)) {
            self.text_reads += 1;
            try b.str(node.text.?);
            return .{ .ok = true, .signature = "s", .body = b.buf.items };
        }
        return .{ .ok = false, .signature = "", .body = "" };
    }
};

var fake_now: u64 = 0;
fn fakeClock() u64 {
    return fake_now;
}

fn fixtureNodes() [7]FakeNode {
    return .{
        .{ .bus = ":1.5", .path = "/app", .name = "gedit", .role = 75, .children = &.{ 1, 6 } },
        .{ .bus = ":1.5", .path = "/w1", .name = "notes.txt - gedit", .role = 23, .states = 1 << state_active, .children = &.{ 2, 3, 4 } },
        .{ .bus = ":1.5", .path = "/b", .name = "Save", .description = "Save   the\nfile", .role = 43 },
        .{ .bus = ":1.5", .path = "/t", .name = "", .role = 61, .text = "hello\t\tworld", .children = &.{5} },
        .{ .bus = ":1.5", .path = "/pw", .name = "Password", .role = role_password_text, .text = "hunter2" },
        .{ .bus = ":1.5", .path = "/deep", .name = "Same", .description = "Same", .role = 29 },
        .{ .bus = ":1.5", .path = "/w2", .name = "Other window", .role = 23 },
    };
}

test "AT-SPI client selects the unique active window and walks it breadth-first" {
    const gpa = testing.allocator;
    const nodes = fixtureNodes();
    var fake: FakeBus = .{ .gpa = gpa, .nodes = &nodes, .pids = &.{.{ ":1.5", 4242 }}, .apps = &.{0} };
    defer fake.out.deinit(gpa);
    fake_now = 0;
    var client: Client = .{ .gpa = gpa, .bus = .{ .ctx = &fake, .callFn = FakeBus.call }, .started = 0, .clock = fakeClock };
    var sem = try client.captureWindow(4242, "notes.txt - gedit");
    defer sem.deinit(gpa);
    try testing.expectEqualStrings("gedit", sem.app_name);
    try testing.expect(!sem.truncated);
    try testing.expectEqualStrings(
        "frame: notes.txt - gedit\n" ++
            "  button: Save | Save the file\n" ++
            "  text: hello world\n" ++
            "  password text: Password\n" ++
            "    label: Same\n",
        sem.content,
    );
    // Password text is never read.
    try testing.expectEqual(@as(usize, 1), fake.text_reads);
}

test "AT-SPI client refuses ambiguous, inactive or unknown windows" {
    const gpa = testing.allocator;
    var nodes = fixtureNodes();
    var fake: FakeBus = .{ .gpa = gpa, .nodes = &nodes, .pids = &.{.{ ":1.5", 4242 }}, .apps = &.{0} };
    defer fake.out.deinit(gpa);
    fake_now = 0;
    var client: Client = .{ .gpa = gpa, .bus = .{ .ctx = &fake, .callFn = FakeBus.call }, .started = 0, .clock = fakeClock };
    try testing.expectError(error.Ambiguous, client.captureWindow(4242, "no such window"));
    try testing.expectError(error.Ambiguous, client.captureWindow(7, "notes.txt - gedit"));
    try testing.expectError(error.Inactive, client.captureWindow(4242, "Other window"));
    nodes[6].name = "notes.txt - gedit"; // duplicate title
    try testing.expectError(error.Ambiguous, client.captureWindow(4242, "notes.txt - gedit"));
    try testing.expectError(error.MissingIdentity, client.captureWindow(0, "x"));
}

test "AT-SPI client gives up after its deadline" {
    const gpa = testing.allocator;
    const nodes = fixtureNodes();
    var fake: FakeBus = .{ .gpa = gpa, .nodes = &nodes, .pids = &.{.{ ":1.5", 4242 }}, .apps = &.{0} };
    defer fake.out.deinit(gpa);
    fake_now = deadline_ns;
    var client: Client = .{ .gpa = gpa, .bus = .{ .ctx = &fake, .callFn = FakeBus.call }, .started = 0, .clock = fakeClock };
    try testing.expectError(error.Timeout, client.captureWindow(4242, "notes.txt - gedit"));
    try testing.expectEqual(@as(usize, 0), fake.calls);
}

test "role names follow the atspi crate" {
    try testing.expectEqualStrings("button", roleName(43));
    try testing.expectEqualStrings("password text", roleName(40));
    try testing.expectEqualStrings("push button menu", roleName(129));
    try testing.expectEqualStrings("invalid", roleName(500));
}
