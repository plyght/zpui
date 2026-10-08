//! Linux tray icon: a StatusNotifierItem (`org.kde.StatusNotifierItem`) with a
//! `com.canonical.dbusmenu` menu, exported on the session bus over the pure-Zig D-Bus
//! client (dbus.zig). Shown by KDE Plasma, the GNOME AppIndicator extension, waybar,
//! xfce4-panel's SNI plugin, ... (anything implementing `org.kde.StatusNotifierWatcher`).
//!
//!   1. Connect, check that `org.kde.StatusNotifierWatcher` has an owner (else
//!      `error.Unsupported`), take `org.kde.StatusNotifierItem-<pid>-1`.
//!   2. Export `/StatusNotifierItem` (properties: Category, Id, Title, Status, IconPixmap
//!      from the PNG as ARGB32, ToolTip, ItemIsMenu, Menu) and `/MenuBar` (dbusmenu:
//!      GetLayout, GetGroupProperties, GetProperty, Event, EventGroup, AboutToShow*).
//!   3. `RegisterStatusNotifierItem` with the watcher (again when the watcher restarts).
//!
//! A clicked menu item reports its tag through `PlatformCallbacks.menu_action`. The bus
//! socket sits in the epoll loop; nothing runs unless the host talks to us.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");
const dbus = @import("dbus.zig");
const event_loop = @import("event_loop.zig");
const image_decode = @import("../../image/decode.zig");

const log = std.log.scoped(.tray);

pub const item_path = "/StatusNotifierItem";
pub const menu_path = "/MenuBar";
const iface_item = "org.kde.StatusNotifierItem";
const iface_menu = "com.canonical.dbusmenu";
const iface_props = "org.freedesktop.DBus.Properties";
const watcher_name = "org.kde.StatusNotifierWatcher";

pub const Env = struct {
    bus_address: ?[]const u8 = null,
    runtime_dir: ?[]const u8 = null,

    pub fn fromProcess() Env {
        const get = struct {
            fn f(name: [*:0]const u8) ?[]const u8 {
                return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
            }
        }.f;
        return .{ .bus_address = get("DBUS_SESSION_BUS_ADDRESS"), .runtime_dir = get("XDG_RUNTIME_DIR") };
    }
};

const Kind = enum { root, action, separator, submenu };

/// One dbusmenu entry (id = index in `Tray.entries`; 0 is the root).
const Entry = struct {
    kind: Kind,
    label: []const u8 = "",
    tag: usize = 0,
    enabled: bool = true,
    checked: ?bool = null,
    first_child: u32 = 0,
    child_count: u32 = 0,
};

pub const Tray = struct {
    gpa: Allocator,
    loop: ?*event_loop.EventLoop = null,
    callbacks: *const platform.PlatformCallbacks,
    conn: ?dbus.Connection = null,
    source: ?*event_loop.Source = null,
    bus_name_buf: [64]u8 = undefined,
    bus_name_len: usize = 0,
    /// Without a connection (tests) messages are kept here instead of sent.
    outbox: std.ArrayList([]u8) = .empty,
    own_serial: u32 = 1,

    // The current item (owned by `arena`).
    arena: std.heap.ArenaAllocator,
    tooltip: []const u8 = "",
    app_id: []const u8 = "zpui",
    icon_w: u32 = 0,
    icon_h: u32 = 0,
    icon_argb: []const u8 = "",
    entries: std.ArrayList(Entry) = .empty,
    /// Children ids, grouped per parent (`Entry.first_child` indexes here).
    children: std.ArrayList(u32) = .empty,
    revision: u32 = 1,

    /// Connects and registers with the watcher. `error.Unsupported` without a session
    /// bus or a StatusNotifierWatcher.
    pub fn create(gpa: Allocator, loop: *event_loop.EventLoop, callbacks: *const platform.PlatformCallbacks, env: Env) !*Tray {
        var conn = dbus.Connection.open(gpa, env.bus_address, env.runtime_dir) orelse return error.Unsupported;
        errdefer conn.deinit();
        if (!try nameHasOwner(&conn, watcher_name)) return error.Unsupported;

        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .loop = loop, .callbacks = callbacks, .arena = .init(gpa) };
        const name = std.fmt.bufPrint(&self.bus_name_buf, "org.kde.StatusNotifierItem-{d}-1", .{linux.getpid()}) catch unreachable;
        self.bus_name_len = name.len;
        {
            var b: dbus.Builder = .{ .gpa = gpa };
            defer b.buf.deinit(gpa);
            try b.str(name);
            try b.u32_(4); // DBUS_NAME_FLAG_DO_NOT_QUEUE
            const serial = try conn.send(.{ .serial = 0, .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "RequestName", .body = .{ .bytes = b.buf.items, .signature = "su" } });
            const m = try conn.reply(serial, 2000);
            if (m.type == .err) self.bus_name_len = 0; // fall back to the unique name
        }
        conn.addMatch("type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='" ++ watcher_name ++ "'") catch {};
        self.conn = conn;
        self.source = try loop.addFd(conn.fd, linux.EPOLL.IN, .{ .ctx = self, .func = onReadable });
        return self;
    }

    /// A tray with no socket (tests).
    pub fn initDetached(gpa: Allocator, callbacks: *const platform.PlatformCallbacks) Tray {
        return .{ .gpa = gpa, .callbacks = callbacks, .arena = .init(gpa) };
    }

    pub fn destroy(self: *Tray) void {
        if (self.loop) |l| if (self.source) |s| l.removeFd(s);
        if (self.conn) |*c| c.deinit();
        self.deinit();
        self.gpa.destroy(self);
    }

    pub fn deinit(self: *Tray) void {
        for (self.outbox.items) |m| self.gpa.free(m);
        self.outbox.deinit(self.gpa);
        self.entries.deinit(self.gpa);
        self.children.deinit(self.gpa);
        self.arena.deinit();
    }

    fn busName(self: *const Tray) []const u8 {
        if (self.bus_name_len > 0) return self.bus_name_buf[0..self.bus_name_len];
        if (self.conn) |*c| return c.uniqueName();
        return ":test";
    }

    /// Replace the item (icon, tooltip, menu). Strings are copied.
    pub fn set(self: *Tray, app_id: []const u8, item: platform.TrayItem) !void {
        const first = self.entries.items.len == 0;
        _ = self.arena.reset(.retain_capacity);
        const a = self.arena.allocator();
        self.app_id = try a.dupe(u8, app_id);
        self.tooltip = try a.dupe(u8, item.tooltip);
        self.icon_w = 0;
        self.icon_h = 0;
        self.icon_argb = "";
        if (item.icon_png.len > 0) if (pngToArgb(a, item.icon_png)) |icon| {
            self.icon_w = icon.w;
            self.icon_h = icon.h;
            self.icon_argb = icon.argb;
        } else |e| log.warn("tray icon: {t}", .{e});
        self.entries.clearRetainingCapacity();
        self.children.clearRetainingCapacity();
        try self.entries.append(self.gpa, .{ .kind = .root });
        try self.addChildren(a, 0, item.menu);
        self.revision +%= 1;
        if (first) {
            self.register();
        } else {
            self.signal(item_path, iface_item, "NewIcon", "", "");
            self.signal(item_path, iface_item, "NewToolTip", "", "");
            var b: dbus.Builder = .{ .gpa = self.gpa };
            defer b.buf.deinit(self.gpa);
            b.u32_(self.revision) catch return;
            b.i32_(0) catch return;
            self.signal(menu_path, iface_menu, "LayoutUpdated", "ui", b.buf.items);
        }
        self.flush();
    }

    fn addChildren(self: *Tray, a: Allocator, parent: u32, items: []const platform.MenuItem) !void {
        var ids: std.ArrayList(u32) = .empty;
        defer ids.deinit(self.gpa);
        for (items) |it| {
            const id: u32 = @intCast(self.entries.items.len);
            switch (it) {
                .separator => try self.entries.append(self.gpa, .{ .kind = .separator }),
                .action => |act| try self.entries.append(self.gpa, .{
                    .kind = .action,
                    .label = try mnemonicEscape(a, act.name),
                    .tag = act.tag,
                    .enabled = !act.disabled,
                    .checked = if (act.checked) true else null,
                }),
                .submenu => |sm| {
                    try self.entries.append(self.gpa, .{ .kind = .submenu, .label = try mnemonicEscape(a, sm.name), .enabled = !sm.disabled });
                    try self.addChildren(a, id, sm.items);
                },
                .system_menu => continue,
            }
            try ids.append(self.gpa, id);
        }
        const e = &self.entries.items[parent];
        e.first_child = @intCast(self.children.items.len);
        e.child_count = @intCast(ids.items.len);
        try self.children.appendSlice(self.gpa, ids.items);
    }

    fn register(self: *Tray) void {
        var b: dbus.Builder = .{ .gpa = self.gpa };
        defer b.buf.deinit(self.gpa);
        b.str(self.busName()) catch return;
        self.queue(.{ .type = .method_call, .serial = 0, .destination = watcher_name, .path = "/StatusNotifierWatcher", .interface = watcher_name, .member = "RegisterStatusNotifierItem", .signature = "s", .body = b.buf.items });
    }

    // -- bus I/O ------------------------------------------------------------------------

    fn onReadable(ctx: ?*anyopaque, _: u32) void {
        const self: *Tray = @ptrCast(@alignCast(ctx.?));
        const conn = &(self.conn orelse return);
        if (!conn.fill()) {
            log.info("session bus closed", .{});
            if (self.loop) |l| if (self.source) |s| l.removeFd(s);
            self.source = null;
            conn.deinit();
            self.conn = null;
            return;
        }
        var clicked: [8]usize = undefined;
        var n_clicked: usize = 0;
        while (conn.buffered() catch null) |m| switch (m.type) {
            .method_call => if (self.handleCall(m)) |tag| if (n_clicked < clicked.len) {
                clicked[n_clicked] = tag;
                n_clicked += 1;
            },
            .signal => if (std.mem.eql(u8, m.member, "NameOwnerChanged")) {
                var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
                _ = r.str() catch continue;
                _ = r.str() catch continue;
                const new_owner = r.str() catch continue;
                if (new_owner.len > 0 and self.entries.items.len > 0) self.register();
            },
            .err => log.debug("bus error: {s}", .{m.error_name}),
            else => {},
        };
        self.flush();
        // Run the app's handlers after replying (they may replace the menu).
        for (clicked[0..n_clicked]) |tag| if (self.callbacks.menu_action) |f| f(self.callbacks.ctx, tag);
    }

    fn queue(self: *Tray, m: dbus.OutMessage) void {
        var out = m;
        out.serial = if (self.conn) |*c| c.nextSerial() else blk: {
            defer self.own_serial +%= 1;
            break :blk self.own_serial;
        };
        const bytes = dbus.buildMessage(self.gpa, out) catch return;
        self.outbox.append(self.gpa, bytes) catch self.gpa.free(bytes);
    }

    fn flush(self: *Tray) void {
        const conn = &(self.conn orelse return);
        for (self.outbox.items) |bytes| {
            _ = dbus.writeAll(conn.fd, bytes);
            self.gpa.free(bytes);
        }
        self.outbox.clearRetainingCapacity();
    }

    fn signal(self: *Tray, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) void {
        self.queue(.{ .type = .signal, .serial = 0, .path = path, .interface = iface, .member = member, .signature = sig, .body = body });
    }

    fn reply(self: *Tray, call: dbus.Message, sig: []const u8, body: []const u8) void {
        if (call.flags & 1 != 0) return;
        self.queue(.{ .type = .method_return, .serial = 0, .reply_serial = call.serial, .destination = if (call.sender.len > 0) call.sender else null, .signature = sig, .body = body });
    }

    fn replyError(self: *Tray, call: dbus.Message, name: []const u8) void {
        if (call.flags & 1 != 0) return;
        var b: dbus.Builder = .{ .gpa = self.gpa };
        defer b.buf.deinit(self.gpa);
        b.str(call.member) catch return;
        self.queue(.{ .type = .err, .serial = 0, .reply_serial = call.serial, .error_name = name, .destination = if (call.sender.len > 0) call.sender else null, .signature = "s", .body = b.buf.items });
    }

    const CallError = error{ UnknownMethod, UnknownObject, InvalidArgs, OutOfMemory, Truncated, BadSignature, Unsupported, BadMessage };

    /// Answers one method call; returns the tag of a clicked menu item, if any.
    pub fn handleCall(self: *Tray, m: dbus.Message) ?usize {
        var b: dbus.Builder = .{ .gpa = self.gpa };
        defer b.buf.deinit(self.gpa);
        var clicked: ?usize = null;
        const sig = self.dispatch(m, &b, &clicked) catch |e| {
            self.replyError(m, switch (e) {
                error.UnknownMethod => "org.freedesktop.DBus.Error.UnknownMethod",
                error.UnknownObject => "org.freedesktop.DBus.Error.UnknownObject",
                error.InvalidArgs, error.Truncated, error.BadSignature => "org.freedesktop.DBus.Error.InvalidArgs",
                else => "org.freedesktop.DBus.Error.Failed",
            });
            return null;
        };
        self.reply(m, sig, b.buf.items);
        return clicked;
    }

    fn dispatch(self: *Tray, m: dbus.Message, b: *dbus.Builder, clicked: *?usize) CallError![]const u8 {
        var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
        const eql = std.mem.eql;
        const member = m.member;
        if (eql(u8, m.interface, "org.freedesktop.DBus.Peer")) {
            if (eql(u8, member, "Ping")) return "";
            if (eql(u8, member, "GetMachineId")) {
                try b.str("0");
                return "s";
            }
            return error.UnknownMethod;
        }
        if (eql(u8, m.interface, "org.freedesktop.DBus.Introspectable") or (m.interface.len == 0 and eql(u8, member, "Introspect"))) {
            try b.str(if (eql(u8, m.path, item_path)) item_xml else if (eql(u8, m.path, menu_path)) menu_xml else root_xml);
            return "s";
        }
        const is_item = eql(u8, m.path, item_path);
        const is_menu = eql(u8, m.path, menu_path);
        if (!is_item and !is_menu) return error.UnknownObject;
        if (eql(u8, m.interface, iface_props) or (m.interface.len == 0 and (eql(u8, member, "Get") or eql(u8, member, "GetAll")))) {
            if (eql(u8, member, "Get")) {
                _ = try r.str();
                const name = try r.str();
                const found = if (is_item) try self.itemProperty(b, name) else try menuProperty(b, name);
                if (!found) return error.InvalidArgs;
                return "v";
            }
            if (eql(u8, member, "GetAll")) {
                const arr = try dbus.Body.beginArray(b, 8);
                const names: []const []const u8 = if (is_item) &item_props else &menu_props;
                for (names) |name| {
                    try b.pad(8);
                    try b.str(name);
                    _ = if (is_item) try self.itemProperty(b, name) else try menuProperty(b, name);
                }
                dbus.Body.endArray(b, arr);
                return "a{sv}";
            }
            if (eql(u8, member, "Set")) return error.InvalidArgs;
            return error.UnknownMethod;
        }
        if (is_item) {
            // Activate / SecondaryActivate / ContextMenu / Scroll / ProvideXdgActivationToken:
            // the menu (ItemIsMenu) is all we offer.
            for ([_][]const u8{ "Activate", "SecondaryActivate", "ContextMenu", "Scroll", "ProvideXdgActivationToken" }) |known|
                if (eql(u8, member, known)) return "";
            return error.UnknownMethod;
        }
        // dbusmenu
        if (eql(u8, member, "GetLayout")) {
            const parent: i32 = @bitCast(try r.u32_());
            const depth: i32 = @bitCast(try r.u32_());
            try b.u32_(self.revision);
            if (parent < 0 or parent >= self.entries.items.len) return error.InvalidArgs;
            try self.writeLayout(b, @intCast(parent), depth);
            return "u(ia{sv}av)";
        }
        if (eql(u8, member, "GetGroupProperties")) {
            const n = try r.u32_();
            const end = r.pos + n;
            const arr = try dbus.Body.beginArray(b, 8);
            while (r.pos < end) {
                const id = try r.u32_();
                if (id >= self.entries.items.len) continue;
                try b.pad(8);
                try b.i32_(@intCast(id));
                try self.writeProps(b, id);
            }
            dbus.Body.endArray(b, arr);
            return "a(ia{sv})";
        }
        if (eql(u8, member, "GetProperty")) {
            const id = try r.u32_();
            const name = try r.str();
            if (id >= self.entries.items.len) return error.InvalidArgs;
            if (!try self.writeProp(b, id, name, true)) return error.InvalidArgs;
            return "v";
        }
        if (eql(u8, member, "Event")) {
            const id = try r.u32_();
            const event_id = try r.str();
            if (eql(u8, event_id, "clicked")) clicked.* = self.tagOf(id);
            return "";
        }
        if (eql(u8, member, "EventGroup")) {
            const n = try r.u32_();
            try r.alignTo(8);
            const end = r.pos + n;
            while (r.pos < end) {
                try r.alignTo(8);
                const id = try r.u32_();
                const event_id = try r.str();
                try r.skip("v");
                _ = try r.u32_();
                if (clicked.* == null and eql(u8, event_id, "clicked")) clicked.* = self.tagOf(id);
            }
            const arr = try dbus.Body.beginArray(b, 4); // no id errors
            dbus.Body.endArray(b, arr);
            return "ai";
        }
        if (eql(u8, member, "AboutToShow")) {
            try dbus.Body.boolean(b, false);
            return "b";
        }
        if (eql(u8, member, "AboutToShowGroup")) {
            const a1 = try dbus.Body.beginArray(b, 4);
            dbus.Body.endArray(b, a1);
            const a2 = try dbus.Body.beginArray(b, 4);
            dbus.Body.endArray(b, a2);
            return "aiai";
        }
        return error.UnknownMethod;
    }

    fn tagOf(self: *const Tray, id: u32) ?usize {
        if (id >= self.entries.items.len) return null;
        const e = self.entries.items[id];
        return if (e.kind == .action and e.enabled) e.tag else null;
    }

    const item_props = [_][]const u8{ "Category", "Id", "Title", "Status", "WindowId", "IconName", "IconPixmap", "OverlayIconName", "AttentionIconName", "AttentionIconPixmap", "ToolTip", "ItemIsMenu", "Menu", "IconThemePath" };
    const menu_props = [_][]const u8{ "Version", "TextDirection", "Status", "IconThemePath" };

    /// Writes property `name` as a variant; false if unknown.
    fn itemProperty(self: *Tray, b: *dbus.Builder, name: []const u8) !bool {
        const eql = std.mem.eql;
        if (eql(u8, name, "Category")) return variantStr(b, "ApplicationStatus");
        if (eql(u8, name, "Id")) return variantStr(b, self.app_id);
        if (eql(u8, name, "Title")) return variantStr(b, if (self.tooltip.len > 0) self.tooltip else self.app_id);
        if (eql(u8, name, "Status")) return variantStr(b, "Active");
        if (eql(u8, name, "IconName") or eql(u8, name, "OverlayIconName") or eql(u8, name, "AttentionIconName") or eql(u8, name, "IconThemePath")) return variantStr(b, "");
        if (eql(u8, name, "WindowId")) {
            try b.sig("i");
            try b.i32_(0);
            return true;
        }
        if (eql(u8, name, "IconPixmap") or eql(u8, name, "AttentionIconPixmap")) {
            try b.sig("a(iiay)");
            try self.writePixmaps(b, eql(u8, name, "IconPixmap"));
            return true;
        }
        if (eql(u8, name, "ToolTip")) {
            try b.sig("(sa(iiay)ss)");
            try b.pad(8);
            try b.str("");
            try self.writePixmaps(b, false);
            try b.str(self.tooltip);
            try b.str("");
            return true;
        }
        if (eql(u8, name, "ItemIsMenu")) {
            try b.sig("b");
            try dbus.Body.boolean(b, true);
            return true;
        }
        if (eql(u8, name, "Menu")) {
            try b.sig("o");
            try b.str(menu_path);
            return true;
        }
        return false;
    }

    fn writePixmaps(self: *Tray, b: *dbus.Builder, with_icon: bool) !void {
        const arr = try dbus.Body.beginArray(b, 8);
        if (with_icon and self.icon_argb.len > 0) {
            try b.pad(8);
            try b.i32_(@intCast(self.icon_w));
            try b.i32_(@intCast(self.icon_h));
            try b.u32_(@intCast(self.icon_argb.len));
            try b.buf.appendSlice(self.gpa, self.icon_argb);
        }
        dbus.Body.endArray(b, arr);
    }

    fn menuProperty(b: *dbus.Builder, name: []const u8) !bool {
        const eql = std.mem.eql;
        if (eql(u8, name, "Version")) {
            try b.sig("u");
            try b.u32_(3);
            return true;
        }
        if (eql(u8, name, "TextDirection")) return variantStr(b, "ltr");
        if (eql(u8, name, "Status")) return variantStr(b, "normal");
        if (eql(u8, name, "IconThemePath")) {
            try b.sig("as");
            const arr = try dbus.Body.beginArray(b, 4);
            dbus.Body.endArray(b, arr);
            return true;
        }
        return false;
    }

    /// `(ia{sv}av)` for `id` and, while `depth != 0`, its children as `v` items.
    fn writeLayout(self: *Tray, b: *dbus.Builder, id: u32, depth: i32) !void {
        try b.pad(8);
        try b.i32_(@intCast(id));
        try self.writeProps(b, id);
        const arr = try dbus.Body.beginArray(b, 1);
        if (depth != 0) {
            const e = self.entries.items[id];
            for (self.children.items[e.first_child..][0..e.child_count]) |child| {
                try b.sig("(ia{sv}av)");
                try self.writeLayout(b, child, if (depth > 0) depth - 1 else depth);
            }
        }
        dbus.Body.endArray(b, arr);
    }

    fn writeProps(self: *Tray, b: *dbus.Builder, id: u32) !void {
        const arr = try dbus.Body.beginArray(b, 8);
        for ([_][]const u8{ "type", "label", "enabled", "toggle-type", "toggle-state", "children-display" }) |name| {
            const mark = b.buf.items.len;
            try b.pad(8);
            try b.str(name);
            if (!try self.writeProp(b, id, name, false)) b.buf.shrinkRetainingCapacity(mark);
        }
        dbus.Body.endArray(b, arr);
    }

    /// Writes menu item property `name` (a variant); false when the item has none
    /// (dbusmenu omits defaults). `explicit`: GetProperty also answers defaults.
    fn writeProp(self: *Tray, b: *dbus.Builder, id: u32, name: []const u8, explicit: bool) !bool {
        const e = self.entries.items[id];
        const eql = std.mem.eql;
        if (eql(u8, name, "type")) {
            if (e.kind == .separator) return variantStr(b, "separator");
            return if (explicit) variantStr(b, "standard") else false;
        }
        if (eql(u8, name, "label")) {
            if (e.kind != .action and e.kind != .submenu) return false;
            return variantStr(b, e.label);
        }
        if (eql(u8, name, "enabled")) {
            if (e.enabled and !explicit) return false;
            try b.sig("b");
            try dbus.Body.boolean(b, e.enabled);
            return true;
        }
        if (eql(u8, name, "toggle-type")) {
            if (e.checked == null) return false;
            return variantStr(b, "checkmark");
        }
        if (eql(u8, name, "toggle-state")) {
            const on = e.checked orelse return false;
            try b.sig("i");
            try b.i32_(@intFromBool(on));
            return true;
        }
        if (eql(u8, name, "children-display")) {
            if (e.kind != .submenu and e.kind != .root) return false;
            return variantStr(b, "submenu");
        }
        return false;
    }
};

fn variantStr(b: *dbus.Builder, s: []const u8) !bool {
    try b.sig("s");
    try b.str(s);
    return true;
}

fn nameHasOwner(conn: *dbus.Connection, name: []const u8) !bool {
    const serial = try conn.send(.{ .serial = 0, .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "NameHasOwner", .args = &.{name} });
    const m = try conn.reply(serial, 2000);
    if (m.type != .method_return) return false;
    var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
    return (try r.u32_()) != 0;
}

/// dbusmenu labels use `_` for mnemonics: show literal underscores.
fn mnemonicEscape(a: Allocator, s: []const u8) ![]const u8 {
    const n = std.mem.count(u8, s, "_");
    if (n == 0) return a.dupe(u8, s);
    const out = try a.alloc(u8, s.len + n);
    var i: usize = 0;
    for (s) |ch| {
        out[i] = ch;
        i += 1;
        if (ch == '_') {
            out[i] = '_';
            i += 1;
        }
    }
    return out;
}

/// PNG → SNI pixmap (ARGB32, network byte order), downscaled to at most 64 px.
pub fn pngToArgb(a: Allocator, png: []const u8) !struct { w: u32, h: u32, argb: []u8 } {
    var img = try image_decode.decode(a, png, .{ .max_dimension = 64, .animate = false, .apply_orientation = false });
    defer img.deinit(a);
    if (img.frames.len == 0) return error.InvalidImage;
    const f = img.frames[0];
    const out = try a.alloc(u8, f.pixels.len);
    var i: usize = 0;
    while (i + 4 <= f.pixels.len) : (i += 4) {
        // BGRA → ARGB (big-endian bytes A, R, G, B)
        out[i] = f.pixels[i + 3];
        out[i + 1] = f.pixels[i + 2];
        out[i + 2] = f.pixels[i + 1];
        out[i + 3] = f.pixels[i];
    }
    return .{ .w = f.width, .h = f.height, .argb = out };
}

const root_xml =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node><node name="StatusNotifierItem"/><node name="MenuBar"/></node>
;
const item_xml =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\ <interface name="org.kde.StatusNotifierItem">
    \\  <property name="Category" type="s" access="read"/>
    \\  <property name="Id" type="s" access="read"/>
    \\  <property name="Title" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="WindowId" type="i" access="read"/>
    \\  <property name="IconName" type="s" access="read"/>
    \\  <property name="IconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="OverlayIconName" type="s" access="read"/>
    \\  <property name="AttentionIconName" type="s" access="read"/>
    \\  <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    \\  <property name="ItemIsMenu" type="b" access="read"/>
    \\  <property name="Menu" type="o" access="read"/>
    \\  <property name="IconThemePath" type="s" access="read"/>
    \\  <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
    \\  <signal name="NewIcon"/>
    \\  <signal name="NewToolTip"/>
    \\  <signal name="NewStatus"><arg name="status" type="s"/></signal>
    \\ </interface>
    \\ <interface name="org.freedesktop.DBus.Properties"/>
    \\</node>
;
const menu_xml =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\ <interface name="com.canonical.dbusmenu">
    \\  <property name="Version" type="u" access="read"/>
    \\  <property name="TextDirection" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="IconThemePath" type="as" access="read"/>
    \\  <method name="GetLayout"><arg type="i" name="parentId" direction="in"/><arg type="i" name="recursionDepth" direction="in"/><arg type="as" name="propertyNames" direction="in"/><arg type="u" name="revision" direction="out"/><arg type="(ia{sv}av)" name="layout" direction="out"/></method>
    \\  <method name="GetGroupProperties"><arg type="ai" name="ids" direction="in"/><arg type="as" name="propertyNames" direction="in"/><arg type="a(ia{sv})" name="properties" direction="out"/></method>
    \\  <method name="GetProperty"><arg type="i" name="id" direction="in"/><arg type="s" name="name" direction="in"/><arg type="v" name="value" direction="out"/></method>
    \\  <method name="Event"><arg type="i" name="id" direction="in"/><arg type="s" name="eventId" direction="in"/><arg type="v" name="data" direction="in"/><arg type="u" name="timestamp" direction="in"/></method>
    \\  <method name="EventGroup"><arg type="a(isvu)" name="events" direction="in"/><arg type="ai" name="idErrors" direction="out"/></method>
    \\  <method name="AboutToShow"><arg type="i" name="id" direction="in"/><arg type="b" name="needUpdate" direction="out"/></method>
    \\  <method name="AboutToShowGroup"><arg type="ai" name="ids" direction="in"/><arg type="ai" name="updatesNeeded" direction="out"/><arg type="ai" name="idErrors" direction="out"/></method>
    \\  <signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})" name="updatedProps"/><arg type="a(ia{sv})" name="removedProps"/></signal>
    \\  <signal name="LayoutUpdated"><arg type="u" name="revision"/><arg type="i" name="parent"/></signal>
    \\ </interface>
    \\ <interface name="org.freedesktop.DBus.Properties"/>
    \\</node>
;

// ---------------------------------------------------------------------------------------
// Tests (no sockets: calls go to `handleCall`, replies are read from `outbox`)
// ---------------------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    callbacks: platform.PlatformCallbacks = .{},
    tray: Tray = undefined,

    fn init(self: *Fixture) !void {
        self.tray = .initDetached(testing.allocator, &self.callbacks);
        try self.tray.set("typebud", .{
            .icon_png = "",
            .tooltip = "type_bud",
            .menu = &.{
                .{ .action = .{ .name = "Show_pet", .tag = 7, .checked = true } },
                .separator,
                .{ .submenu = .{ .name = "More", .items = &.{.{ .action = .{ .name = "Off", .tag = 9, .disabled = true } }} } },
                .{ .action = .{ .name = "Quit", .tag = 1 << 30 } },
            },
        });
        self.clear();
    }

    fn clear(self: *Fixture) void {
        for (self.tray.outbox.items) |m| testing.allocator.free(m);
        self.tray.outbox.clearRetainingCapacity();
    }

    fn call(self: *Fixture, path: []const u8, iface: []const u8, member: []const u8, sig: []const u8, body: []const u8) !struct { msg: dbus.Message, clicked: ?usize } {
        self.clear();
        const bytes = try dbus.buildMessage(testing.allocator, .{ .type = .method_call, .serial = 42, .path = path, .interface = iface, .member = member, .signature = sig, .body = body });
        defer testing.allocator.free(bytes);
        const clicked = self.tray.handleCall(try dbus.parseMessage(bytes));
        try testing.expectEqual(@as(usize, 1), self.tray.outbox.items.len);
        const r = try dbus.parseMessage(self.tray.outbox.items[0]);
        try testing.expectEqual(@as(?u32, 42), r.reply_serial);
        return .{ .msg = r, .clicked = clicked };
    }
};

test "tray exports StatusNotifierItem properties" {
    var f: Fixture = .{};
    try f.init();
    defer f.tray.deinit();
    var b: dbus.Builder = .{ .gpa = testing.allocator };
    defer b.buf.deinit(testing.allocator);
    try b.str(iface_item);
    try b.str("Menu");
    var res = try f.call(item_path, iface_props, "Get", "ss", b.buf.items);
    try testing.expectEqual(dbus.MessageType.method_return, res.msg.type);
    var r: dbus.Reader = .{ .bytes = res.msg.body, .pos = 0, .big = false };
    try testing.expectEqualStrings("o", try r.sig());
    try testing.expectEqualStrings(menu_path, try r.str());

    b.buf.clearRetainingCapacity();
    try b.str(iface_item);
    res = try f.call(item_path, iface_props, "GetAll", "s", b.buf.items);
    try testing.expectEqualStrings("a{sv}", res.msg.signature);
    // Walk every entry: the body must parse completely.
    r = .{ .bytes = res.msg.body, .pos = 0, .big = false };
    const n = try r.u32_();
    try r.alignTo(8);
    const end = r.pos + n;
    var seen: usize = 0;
    while (r.pos < end) : (seen += 1) {
        try r.alignTo(8);
        const key = try r.str();
        const t = try r.sig();
        if (std.mem.eql(u8, key, "Id")) try testing.expectEqualStrings("typebud", try r.str()) else try r.skip(t);
    }
    try testing.expectEqual(end, r.pos);
    try testing.expectEqual(Tray.item_props.len, seen);

    res = try f.call(item_path, "org.freedesktop.DBus.Introspectable", "Introspect", "", "");
    r = .{ .bytes = res.msg.body, .pos = 0, .big = false };
    try testing.expect(std.mem.indexOf(u8, try r.str(), "StatusNotifierItem") != null);
}

test "tray dbusmenu layout, labels and clicks" {
    var f: Fixture = .{};
    try f.init();
    defer f.tray.deinit();
    var b: dbus.Builder = .{ .gpa = testing.allocator };
    defer b.buf.deinit(testing.allocator);
    try b.i32_(0);
    try b.i32_(-1);
    const a = try dbus.Body.beginArray(&b, 4);
    dbus.Body.endArray(&b, a);
    const res = try f.call(menu_path, iface_menu, "GetLayout", "iias", b.buf.items);
    try testing.expectEqualStrings("u(ia{sv}av)", res.msg.signature);
    var r: dbus.Reader = .{ .bytes = res.msg.body, .pos = 0, .big = false };
    _ = try r.u32_();
    try r.alignTo(8);
    try testing.expectEqual(@as(u32, 0), try r.u32_()); // root id
    try r.skip("a{sv}");
    const children_len = try r.u32_();
    try testing.expect(children_len > 0);
    // First child: Show_pet, label with the underscore doubled, checkmark on.
    try testing.expectEqualStrings("(ia{sv}av)", try r.sig());
    try r.alignTo(8);
    try testing.expectEqual(@as(u32, 1), try r.u32_());
    const props_len = try r.u32_();
    try r.alignTo(8);
    const props_end = r.pos + props_len;
    var label: []const u8 = "";
    var toggle: ?u32 = null;
    while (r.pos < props_end) {
        try r.alignTo(8);
        const key = try r.str();
        const t = try r.sig();
        if (std.mem.eql(u8, key, "label")) label = try r.str() else if (std.mem.eql(u8, key, "toggle-state")) toggle = try r.u32_() else try r.skip(t);
    }
    try testing.expectEqualStrings("Show__pet", label);
    try testing.expectEqual(@as(?u32, 1), toggle);

    // Clicking id 1 reports tag 7; the disabled item (id 4) reports nothing.
    b.buf.clearRetainingCapacity();
    try b.i32_(1);
    try b.str("clicked");
    try b.sig("i");
    try b.i32_(0);
    try b.u32_(0);
    var ev = try f.call(menu_path, iface_menu, "Event", "isvu", b.buf.items);
    try testing.expectEqual(@as(?usize, 7), ev.clicked);
    b.buf.clearRetainingCapacity();
    try b.i32_(4);
    try b.str("clicked");
    try b.sig("i");
    try b.i32_(0);
    try b.u32_(0);
    ev = try f.call(menu_path, iface_menu, "Event", "isvu", b.buf.items);
    try testing.expectEqual(@as(?usize, null), ev.clicked);
    // Quit (id 5) via EventGroup.
    b.buf.clearRetainingCapacity();
    const ga = try dbus.Body.beginArray(&b, 8);
    try b.pad(8);
    try b.i32_(5);
    try b.str("clicked");
    try b.sig("s");
    try b.str("");
    try b.u32_(0);
    dbus.Body.endArray(&b, ga);
    ev = try f.call(menu_path, iface_menu, "EventGroup", "a(isvu)", b.buf.items);
    try testing.expectEqual(@as(?usize, 1 << 30), ev.clicked);
}

test "tray replaces the menu and signals LayoutUpdated" {
    var f: Fixture = .{};
    try f.init();
    defer f.tray.deinit();
    const before = f.tray.revision;
    try f.tray.set("typebud", .{ .icon_png = "", .menu = &.{.{ .action = .{ .name = "Quit", .tag = 3 } }} });
    try testing.expect(f.tray.revision != before);
    var saw_layout = false;
    for (f.tray.outbox.items) |bytes| {
        const m = try dbus.parseMessage(bytes);
        if (m.type == .signal and std.mem.eql(u8, m.member, "LayoutUpdated")) saw_layout = true;
    }
    try testing.expect(saw_layout);
    try testing.expectEqual(@as(usize, 2), f.tray.entries.items.len);
}

test "mnemonicEscape doubles underscores" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("a__b", try mnemonicEscape(arena.allocator(), "a_b"));
    try testing.expectEqualStrings("ab", try mnemonicEscape(arena.allocator(), "ab"));
}
