//! AT-SPI2 bridge for zpui's accessibility tree, over the pure-Zig D-Bus client
//! (dbus.zig). This is what `accesskit_unix` + `accesskit_atspi_common` do for zui.
//!
//! Startup (`Bridge.create`, from the Linux platform):
//!   1. On the session bus, read `org.a11y.Status.IsEnabled` / `ScreenReaderEnabled` from
//!      `org.a11y.Bus` and watch them (`PropertiesChanged`). `ZPUI_A11Y=1` forces the
//!      bridge on; `ZPUI_NO_A11Y=1` or `NO_AT_BRIDGE=1` turn it off entirely.
//!   2. When enabled: `org.a11y.Bus.GetAddress` (or `$AT_SPI_BUS_ADDRESS`), connect to the
//!      accessibility bus, `Hello`, and `org.a11y.atspi.Socket.Embed` our application root
//!      (`/org/a11y/atspi/accessible/root`) with the registry. Both sockets live in the
//!      platform's epoll loop; every call is answered on the main thread from the
//!      window's current tree.
//!   3. Every window registered with the bridge is asked to build trees
//!      (`WindowCallbacks.a11y_activation`); its frames then arrive via `update`.
//!
//! Objects: the application root, and one object per tree node at
//! `/org/a11y/atspi/accessible/<window>/<node id>` (node 0 = the window, role Frame).
//! Interfaces: Accessible, Application (root), Component, Action, Text (basic: the
//! string, characters, word/line boundaries, extents), EditableText
//! (`SetTextContents` → `set_value`), Value, plus `org.freedesktop.DBus.Properties`,
//! `Introspectable` and `Peer`.
//!
//! Events (`org.a11y.atspi.Event.Object`, body `(siiva{sv})`) from each frame's change
//! set: ChildrenChanged add/remove, PropertyChange accessible-name / -description /
//! -value, StateChanged focused / selected / expanded / checked / pressed / enabled /
//! defunct, BoundsChanged, TextChanged for text-field values, and
//! `org.a11y.atspi.Event.Focus.Focus`.
//!
//! Not implemented (see docs/PARITY.md §13): the Selection, Table, Hyperlink, Image and
//! Collection interfaces, text attributes and caret/selection tracking (zpui's text
//! inputs do not publish their caret into the tree yet), Window events (activate /
//! deactivate) and the cache interface (`org.a11y.atspi.Cache`).

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");
const a11y = platform.a11y;
const dbus = @import("dbus.zig");
const event_loop = @import("event_loop.zig");
const Common = @import("window_common.zig").Common;

const log = std.log.scoped(.atspi);

pub const root_path = "/org/a11y/atspi/accessible/root";
const path_prefix = "/org/a11y/atspi/accessible/";
const null_path = "/org/a11y/atspi/null";

const iface_accessible = "org.a11y.atspi.Accessible";
const iface_application = "org.a11y.atspi.Application";
const iface_component = "org.a11y.atspi.Component";
const iface_action = "org.a11y.atspi.Action";
const iface_text = "org.a11y.atspi.Text";
const iface_editable = "org.a11y.atspi.EditableText";
const iface_value = "org.a11y.atspi.Value";
const iface_props = "org.freedesktop.DBus.Properties";
const iface_event_object = "org.a11y.atspi.Event.Object";

// ---------------------------------------------------------------------------------------
// Roles and states (AtspiRole / AtspiStateType numbering, atspi-constants.h)
// ---------------------------------------------------------------------------------------

pub const R = struct {
    pub const alert = 2;
    pub const check_box = 7;
    pub const check_menu_item = 8;
    pub const column_header = 10;
    pub const combo_box = 11;
    pub const dialog = 16;
    pub const frame = 23;
    pub const image = 27;
    pub const label = 29;
    pub const list = 31;
    pub const list_item = 32;
    pub const menu = 33;
    pub const menu_bar = 34;
    pub const menu_item = 35;
    pub const page_tab = 37;
    pub const page_tab_list = 38;
    pub const panel = 39;
    pub const password_text = 40;
    pub const progress_bar = 42;
    pub const button = 43;
    pub const radio_button = 44;
    pub const radio_menu_item = 45;
    pub const row_header = 47;
    pub const scroll_pane = 49;
    pub const separator = 50;
    pub const slider = 51;
    pub const spin_button = 52;
    pub const status_bar = 54;
    pub const table = 55;
    pub const table_cell = 56;
    pub const terminal = 60;
    pub const toggle_button = 62;
    pub const tool_bar = 63;
    pub const tool_tip = 64;
    pub const tree = 65;
    pub const unknown = 67;
    pub const paragraph = 73;
    pub const application = 75;
    pub const entry = 79;
    pub const document_frame = 82;
    pub const heading = 83;
    pub const section = 85;
    pub const link = 88;
    pub const table_row = 90;
    pub const tree_item = 91;
    pub const comment = 97;
    pub const list_box = 98;
    pub const notification = 101;
    pub const article = 109;
    pub const landmark = 110;
    pub const static = 116;
};

/// accesskit_atspi_common `NodeWrapper::role`.
pub fn atspiRole(n: *const a11y.Node) u32 {
    return switch (n.role) {
        .unknown => R.unknown,
        .window => R.frame,
        .group, .pane, .scroll_view => R.panel,
        .generic_container => R.section,
        .label => R.label,
        .paragraph => R.paragraph,
        .heading => R.heading,
        .button => if (n.toggled != null) R.toggle_button else R.button,
        .default_button => R.button,
        .link => R.link,
        .check_box => R.check_box,
        .radio_button => R.radio_button,
        .@"switch", .toggle_button, .disclosure_triangle => R.toggle_button,
        .text_input, .multiline_text_input, .search_input => R.entry,
        .password_input => R.password_text,
        .combo_box => R.combo_box,
        .spin_button => R.spin_button,
        .slider => R.slider,
        .progress_indicator => R.progress_bar,
        .image => R.image,
        .list => R.list,
        .list_item, .list_box_option => R.list_item,
        .list_box => R.list_box,
        .menu => R.menu,
        .menu_bar => R.menu_bar,
        .menu_item => R.menu_item,
        .menu_item_check_box => R.check_menu_item,
        .menu_item_radio => R.radio_menu_item,
        .tab_list => R.page_tab_list,
        .tab => R.page_tab,
        .tab_panel => R.scroll_pane,
        .tree => R.tree,
        .tree_item => R.tree_item,
        .table, .grid => R.table,
        .row => R.table_row,
        .cell => R.table_cell,
        .column_header => R.column_header,
        .row_header => R.row_header,
        .dialog => R.dialog,
        .alert_dialog => R.alert,
        .alert => R.notification,
        .status => R.status_bar,
        .tooltip => R.tool_tip,
        .toolbar => R.tool_bar,
        .separator => R.separator,
        .navigation, .region => R.landmark,
        .document => R.document_frame,
        .article => R.article,
        .code => R.static,
        .terminal => R.terminal,
    };
}

/// `GetRoleName` strings (atspi_role_get_name).
pub fn roleName(role: u32) []const u8 {
    return switch (role) {
        R.alert => "alert",
        R.check_box => "check box",
        R.check_menu_item => "check menu item",
        R.column_header => "column header",
        R.combo_box => "combo box",
        R.dialog => "dialog",
        R.frame => "frame",
        R.image => "image",
        R.label => "label",
        R.list => "list",
        R.list_item => "list item",
        R.menu => "menu",
        R.menu_bar => "menu bar",
        R.menu_item => "menu item",
        R.page_tab => "page tab",
        R.page_tab_list => "page tab list",
        R.panel => "panel",
        R.password_text => "password text",
        R.progress_bar => "progress bar",
        R.button => "push button",
        R.radio_button => "radio button",
        R.radio_menu_item => "radio menu item",
        R.row_header => "row header",
        R.scroll_pane => "scroll pane",
        R.separator => "separator",
        R.slider => "slider",
        R.spin_button => "spin button",
        R.status_bar => "status bar",
        R.table => "table",
        R.table_cell => "table cell",
        R.terminal => "terminal",
        R.toggle_button => "toggle button",
        R.tool_bar => "tool bar",
        R.tool_tip => "tool tip",
        R.tree => "tree",
        R.paragraph => "paragraph",
        R.application => "application",
        R.entry => "entry",
        R.document_frame => "document frame",
        R.heading => "heading",
        R.section => "section",
        R.link => "link",
        R.table_row => "table row",
        R.tree_item => "tree item",
        R.list_box => "list box",
        R.notification => "notification",
        R.article => "article",
        R.landmark => "landmark",
        R.static => "static",
        else => "unknown",
    };
}

pub const State = enum(u6) {
    active = 1,
    checked = 4,
    collapsed = 5,
    defunct = 6,
    editable = 7,
    enabled = 8,
    expandable = 9,
    expanded = 10,
    focusable = 11,
    focused = 12,
    horizontal = 14,
    multi_line = 17,
    pressed = 20,
    selectable = 22,
    selected = 23,
    sensitive = 24,
    showing = 25,
    single_line = 26,
    vertical = 29,
    visible = 30,
    indeterminate = 32,
    selectable_text = 38,
    checkable = 41,
    read_only = 43,
};

pub fn stateName(s: State) []const u8 {
    return switch (s) {
        .active => "active",
        .checked => "checked",
        .collapsed => "collapsed",
        .defunct => "defunct",
        .editable => "editable",
        .enabled => "enabled",
        .expandable => "expandable",
        .expanded => "expanded",
        .focusable => "focusable",
        .focused => "focused",
        .horizontal => "horizontal",
        .multi_line => "multi-line",
        .pressed => "pressed",
        .selectable => "selectable",
        .selected => "selected",
        .sensitive => "sensitive",
        .showing => "showing",
        .single_line => "single-line",
        .vertical => "vertical",
        .visible => "visible",
        .indeterminate => "indeterminate",
        .selectable_text => "selectable-text",
        .checkable => "checkable",
        .read_only => "read-only",
    };
}

fn bit(s: State) u64 {
    return @as(u64, 1) << @intFromEnum(s);
}

/// accesskit_atspi_common `NodeWrapper::state`.
pub fn stateSet(tree: *const a11y.Tree, ix: u32, window_active: bool) u64 {
    const n = tree.at(ix);
    const role = atspiRole(n);
    var s: u64 = bit(.visible) | bit(.showing);
    if (ix == 0 and window_active) s |= bit(.active);
    if (n.role.isTextInput()) {
        if (!n.read_only and !n.disabled) s |= bit(.editable);
        s |= bit(.selectable_text);
        s |= if (n.role == .multiline_text_input or n.role == .terminal) bit(.multi_line) else bit(.single_line);
    }
    if (n.isFocusable()) s |= bit(.focusable);
    if (n.orientation) |o| s |= if (o == .horizontal) bit(.horizontal) else bit(.vertical);
    if (n.toggled != null and role != R.toggle_button) s |= bit(.checkable);
    if (n.selected) |sel| {
        if (!n.disabled) s |= bit(.selectable);
        if (sel) s |= bit(.selected);
    }
    if (n.expanded) |e| s |= bit(.expandable) | (if (e) bit(.expanded) else bit(.collapsed));
    if (n.role == .progress_indicator and n.numeric_value == null) s |= bit(.indeterminate);
    if (n.toggled) |t| switch (t) {
        .mixed => s |= bit(.indeterminate),
        .on => s |= if (role == R.toggle_button) bit(.pressed) else bit(.checked),
        .off => {},
    };
    if (n.disabled or (n.read_only and n.role.isTextInput())) {
        s |= bit(.read_only);
        if (!n.disabled) s |= bit(.enabled) | bit(.sensitive);
    } else s |= bit(.enabled) | bit(.sensitive);
    if (tree.finalized and tree.reported_focus == ix and ix != 0) s |= bit(.focused);
    return s;
}

/// Actions exposed through the Action interface, in order.
const action_order = [_]struct { a11y.Action, []const u8 }{
    .{ .click, "click" },
    .{ .expand, "expand" },
    .{ .collapse, "collapse" },
    .{ .increment, "increment" },
    .{ .decrement, "decrement" },
    .{ .show_context_menu, "menu" },
};

fn actionAt(n: *const a11y.Node, index: i32) ?a11y.Action {
    var k: i32 = 0;
    for (action_order) |e| if (n.actions.contains(e[0])) {
        if (k == index) return e[0];
        k += 1;
    };
    return null;
}

fn actionCount(n: *const a11y.Node) i32 {
    var k: i32 = 0;
    for (action_order) |e| if (n.actions.contains(e[0])) {
        k += 1;
    };
    return k;
}

fn actionName(a: a11y.Action) []const u8 {
    for (action_order) |e| if (e[0] == a) return e[1];
    return "";
}

fn hasText(n: *const a11y.Node) bool {
    return n.role == .label or n.role.isTextInput();
}

fn hasValue(n: *const a11y.Node) bool {
    return n.role.isRange() or n.numeric_value != null;
}

fn textOf(tree: *const a11y.Tree, n: *const a11y.Node) []const u8 {
    if (n.role.isTextInput()) return tree.str(n.value) orelse "";
    return tree.name(n) orelse "";
}

// ---------------------------------------------------------------------------------------
// Bridge
// ---------------------------------------------------------------------------------------

pub const Win = struct {
    id: u32,
    common: *Common,
    /// The platform window (screen origin for screen coordinates); null in tests.
    pw: ?platform.Window,
    tree: ?*const a11y.Tree = null,
    activation_sent: bool = false,
};

const Target = union(enum) {
    app,
    node: struct { win: *Win, ix: u32 },
    missing,
};

pub const Env = struct {
    bus_address: ?[]const u8 = null,
    runtime_dir: ?[]const u8 = null,
    at_spi_address: ?[]const u8 = null,
    force: bool = false,
    disabled: bool = false,

    pub fn fromProcess() Env {
        const get = struct {
            fn f(name: [*:0]const u8) ?[]const u8 {
                const v = std.c.getenv(name) orelse return null;
                return std.mem.span(v);
            }
        }.f;
        const truthy = struct {
            fn f(v: ?[]const u8) bool {
                const s = v orelse return false;
                return s.len > 0 and !std.mem.eql(u8, s, "0");
            }
        }.f;
        return .{
            .bus_address = get("DBUS_SESSION_BUS_ADDRESS"),
            .runtime_dir = get("XDG_RUNTIME_DIR"),
            .at_spi_address = get("AT_SPI_BUS_ADDRESS"),
            .force = truthy(get("ZPUI_A11Y")),
            .disabled = truthy(get("ZPUI_NO_A11Y")) or truthy(get("NO_AT_BRIDGE")),
        };
    }
};

pub const Bridge = struct {
    gpa: Allocator,
    loop: ?*event_loop.EventLoop = null,
    env: Env = .{},
    session: ?dbus.Connection = null,
    session_source: ?*event_loop.Source = null,
    bus: ?dbus.Connection = null,
    bus_source: ?*event_loop.Source = null,
    /// Assistive technology wants us (org.a11y.Status or `ZPUI_A11Y`).
    enabled: bool = false,
    embed_serial: ?u32 = null,
    registered: bool = false,
    app_id: i32 = 0,
    app_name_buf: [64]u8 = undefined,
    app_name_len: usize = 0,
    windows: std.ArrayList(*Win) = .empty,
    next_win_id: u32 = 1,
    /// Without a bus (tests) messages are kept here instead of sent.
    outbox: std.ArrayList([]u8) = .empty,
    own_serial: u32 = 1,
    activation_timer: ?event_loop.TimerId = null,

    /// Connect to the session bus and, if assistive technology is enabled, the
    /// accessibility bus. Null when disabled by the environment or without a session bus.
    pub fn create(gpa: Allocator, loop: *event_loop.EventLoop, env: Env) ?*Bridge {
        if (env.disabled) return null;
        const self = gpa.create(Bridge) catch return null;
        self.* = .{ .gpa = gpa, .loop = loop, .env = env };
        self.readAppName();
        self.session = dbus.Connection.open(gpa, env.bus_address, env.runtime_dir);
        if (self.session) |*s| {
            self.enabled = env.force or queryStatus(s);
            s.addMatch("type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',path='/org/a11y/bus'") catch {};
            self.session_source = loop.addFd(s.fd, linux.EPOLL.IN, .{ .ctx = self, .func = onSessionReadable }) catch null;
        } else self.enabled = env.force;
        if (self.enabled) self.connectBus();
        return self;
    }

    /// A bridge with no sockets (tests): messages go to `outbox`.
    pub fn initDetached(gpa: Allocator) Bridge {
        var b: Bridge = .{ .gpa = gpa, .enabled = true, .registered = true };
        const name = "zpui-test";
        @memcpy(b.app_name_buf[0..name.len], name);
        b.app_name_len = name.len;
        return b;
    }

    pub fn destroy(self: *Bridge) void {
        self.deinit();
        self.gpa.destroy(self);
    }

    pub fn deinit(self: *Bridge) void {
        if (self.loop) |l| {
            if (self.session_source) |s| l.removeFd(s);
            if (self.bus_source) |s| l.removeFd(s);
            if (self.activation_timer) |t| l.cancelTimer(t);
        }
        if (self.session) |*s| s.deinit();
        if (self.bus) |*b| b.deinit();
        for (self.windows.items) |w| self.gpa.destroy(w);
        self.windows.deinit(self.gpa);
        for (self.outbox.items) |m| self.gpa.free(m);
        self.outbox.deinit(self.gpa);
    }

    fn readAppName(self: *Bridge) void {
        const fallback = "zpui";
        @memcpy(self.app_name_buf[0..fallback.len], fallback);
        self.app_name_len = fallback.len;
        const rc = linux.open("/proc/self/comm", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (!dbus.ok(rc)) return;
        const fd: linux.fd_t = @intCast(rc);
        defer _ = linux.close(fd);
        const n = linux.read(fd, &self.app_name_buf, self.app_name_buf.len);
        if (!dbus.ok(n) or n == 0) return;
        self.app_name_len = std.mem.trimEnd(u8, self.app_name_buf[0..n], "\n").len;
    }

    fn appName(self: *const Bridge) []const u8 {
        return self.app_name_buf[0..self.app_name_len];
    }

    pub fn uniqueName(self: *const Bridge) []const u8 {
        if (self.bus) |*b| return b.uniqueName();
        return ":1.0";
    }

    fn queryStatus(s: *dbus.Connection) bool {
        const serial = s.send(.{ .serial = 0, .destination = "org.a11y.Bus", .path = "/org/a11y/bus", .interface = iface_props, .member = "GetAll", .args = &.{"org.a11y.Status"} }) catch return false;
        const m = s.reply(serial, 300) catch return false;
        if (m.type != .method_return) return false;
        return parseStatus(m.body, m.big_endian, false);
    }

    /// `a{sv}` of org.a11y.Status: true when IsEnabled or ScreenReaderEnabled is true.
    fn parseStatus(body: []const u8, big: bool, skip_iface: bool) bool {
        var r: dbus.Reader = .{ .bytes = body, .pos = 0, .big = big };
        if (skip_iface) _ = r.str() catch return false;
        const len = r.u32_() catch return false;
        r.alignTo(8) catch return false;
        const end = r.pos + len;
        var on = false;
        while (r.pos < end) {
            r.alignTo(8) catch return on;
            const key = r.str() catch return on;
            const t = r.sig() catch return on;
            if (std.mem.eql(u8, t, "b")) {
                const v = (r.u32_() catch return on) != 0;
                if (std.mem.eql(u8, key, "IsEnabled") or std.mem.eql(u8, key, "ScreenReaderEnabled")) on = on or v;
            } else r.skip(t) catch return on;
        }
        return on;
    }

    fn connectBus(self: *Bridge) void {
        if (self.bus != null) return;
        var addr_buf: [512]u8 = undefined;
        const address: ?[]const u8 = if (self.env.at_spi_address) |a| a else blk: {
            const s = &(self.session orelse break :blk null);
            const serial = s.send(.{ .serial = 0, .destination = "org.a11y.Bus", .path = "/org/a11y/bus", .interface = "org.a11y.Bus", .member = "GetAddress" }) catch break :blk null;
            const m = s.reply(serial, 500) catch break :blk null;
            if (m.type != .method_return) break :blk null;
            var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
            const a = r.str() catch break :blk null;
            if (a.len > addr_buf.len) break :blk null;
            @memcpy(addr_buf[0..a.len], a);
            break :blk addr_buf[0..a.len];
        };
        const a = address orelse {
            log.info("no accessibility bus; AT-SPI bridge idle", .{});
            return;
        };
        self.bus = dbus.Connection.open(self.gpa, a, null) orelse {
            log.info("cannot connect to the accessibility bus", .{});
            return;
        };
        const bus = &self.bus.?;
        if (self.loop) |l| self.bus_source = l.addFd(bus.fd, linux.EPOLL.IN, .{ .ctx = self, .func = onBusReadable }) catch null;
        // Embed our root with the registry (the reply arrives in onBusReadable).
        var b: dbus.Builder = .{ .gpa = self.gpa };
        defer b.buf.deinit(self.gpa);
        writeAddress(&b, bus.uniqueName(), root_path) catch return;
        self.embed_serial = bus.sendMessage(.{
            .type = .method_call,
            .serial = 0,
            .destination = "org.a11y.atspi.Registry",
            .path = root_path,
            .interface = "org.a11y.atspi.Socket",
            .member = "Embed",
            .signature = "(so)",
            .body = b.buf.items,
        }) catch null;
        self.scheduleActivation();
    }

    fn setEnabled(self: *Bridge, on: bool) void {
        const was = self.enabled;
        self.enabled = on or self.env.force;
        if (self.enabled == was) return;
        if (self.enabled) self.connectBus();
        for (self.windows.items) |w| w.activation_sent = false;
        self.scheduleActivation();
    }

    /// Tell windows (on the next loop turn, outside any core callback) to start/stop
    /// building trees.
    fn scheduleActivation(self: *Bridge) void {
        const l = self.loop orelse return;
        if (self.activation_timer != null) return;
        self.activation_timer = l.addTimer(0, .{ .ctx = self, .func = onActivationTimer }) catch null;
    }

    fn onActivationTimer(ctx: ?*anyopaque, _: event_loop.TimerId) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx.?));
        self.activation_timer = null;
        const active = self.enabled and self.bus != null;
        for (self.windows.items) |w| {
            if (w.activation_sent) continue;
            w.activation_sent = true;
            if (w.common.callbacks.a11y_activation) |f| f(w.common.callbacks.ctx, active);
        }
    }

    // ---- windows ----------------------------------------------------------------------

    /// Register a window (when the core sets its callbacks). Idempotent.
    pub fn addWindow(self: *Bridge, common: *Common, pw: ?platform.Window) void {
        for (self.windows.items) |w| if (w.common == common) return;
        const w = self.gpa.create(Win) catch return;
        w.* = .{ .id = self.next_win_id, .common = common, .pw = pw };
        self.next_win_id += 1;
        self.windows.append(self.gpa, w) catch {
            self.gpa.destroy(w);
            return;
        };
        if (self.live()) self.emitChildrenChanged(root_path, "add", @intCast(self.windows.items.len - 1), w, 0);
        self.scheduleActivation();
    }

    pub fn removeWindow(self: *Bridge, common: *Common) void {
        for (self.windows.items, 0..) |w, i| if (w.common == common) {
            if (self.live()) {
                self.emitState(w, .root, .defunct, true);
                self.emitChildrenChanged(root_path, "remove", -1, w, 0);
            }
            _ = self.windows.orderedRemove(i);
            self.gpa.destroy(w);
            self.flush();
            return;
        };
    }

    fn findWindow(self: *Bridge, common: *Common) ?*Win {
        for (self.windows.items) |w| if (w.common == common) return w;
        return null;
    }

    fn live(self: *const Bridge) bool {
        return self.enabled and (self.bus != null or self.loop == null);
    }

    /// A frame's tree (`Window.VTable.a11yUpdate`): keep it and emit events for the changes.
    pub fn update(self: *Bridge, common: *Common, u: a11y.Update) void {
        const w = self.findWindow(common) orelse return;
        w.tree = u.tree;
        if (!self.live()) return;
        self.emitChanges(w, u);
        self.flush();
    }

    // ---- sockets ----------------------------------------------------------------------

    fn onSessionReadable(ctx: ?*anyopaque, _: u32) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx.?));
        const s = &(self.session orelse return);
        if (!s.fill()) {
            if (self.loop) |l| if (self.session_source) |src| l.removeFd(src);
            self.session_source = null;
            return;
        }
        while (s.buffered() catch null) |m| {
            if (m.type == .signal and std.mem.eql(u8, m.member, "PropertiesChanged")) {
                var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
                const iface = r.str() catch continue;
                if (!std.mem.eql(u8, iface, "org.a11y.Status")) continue;
                self.setEnabled(parseStatus(m.body, m.big_endian, true));
            }
        }
    }

    fn onBusReadable(ctx: ?*anyopaque, _: u32) void {
        const self: *Bridge = @ptrCast(@alignCast(ctx.?));
        const bus = &(self.bus orelse return);
        if (!bus.fill()) {
            log.info("accessibility bus closed", .{});
            if (self.loop) |l| if (self.bus_source) |src| l.removeFd(src);
            self.bus_source = null;
            bus.deinit();
            self.bus = null;
            self.registered = false;
            return;
        }
        while (bus.buffered() catch null) |m| {
            switch (m.type) {
                .method_call => self.handleCall(m),
                .method_return => if (self.embed_serial != null and m.reply_serial == self.embed_serial) {
                    self.registered = true;
                    self.embed_serial = null;
                },
                .err => if (self.embed_serial != null and m.reply_serial == self.embed_serial) {
                    log.info("AT-SPI registry refused Embed: {s}", .{m.error_name});
                    self.embed_serial = null;
                },
                else => {},
            }
        }
        self.flush();
    }

    fn nextSerial(self: *Bridge) u32 {
        if (self.bus) |*b| return b.nextSerial();
        defer self.own_serial +%= 1;
        return self.own_serial;
    }

    fn queue(self: *Bridge, m: dbus.OutMessage) void {
        var out = m;
        out.serial = self.nextSerial();
        const bytes = dbus.buildMessage(self.gpa, out) catch return;
        self.outbox.append(self.gpa, bytes) catch self.gpa.free(bytes);
    }

    /// Write queued messages to the bus (kept for inspection without one).
    pub fn flush(self: *Bridge) void {
        const bus = &(self.bus orelse return);
        for (self.outbox.items) |bytes| {
            _ = dbus.writeAll(bus.fd, bytes);
            self.gpa.free(bytes);
        }
        self.outbox.clearRetainingCapacity();
    }

    // ---- objects ----------------------------------------------------------------------

    fn resolve(self: *Bridge, path: []const u8) Target {
        if (std.mem.eql(u8, path, root_path)) return .app;
        if (!std.mem.startsWith(u8, path, path_prefix)) return .missing;
        const rest = path[path_prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .missing;
        const wid = std.fmt.parseInt(u32, rest[0..slash], 10) catch return .missing;
        const nid = std.fmt.parseInt(u64, rest[slash + 1 ..], 10) catch return .missing;
        for (self.windows.items) |w| if (w.id == wid) {
            const tree = w.tree orelse return if (nid == 0) .{ .node = .{ .win = w, .ix = 0 } } else .missing;
            if (tree.len() == 0) return if (nid == 0) .{ .node = .{ .win = w, .ix = 0 } } else .missing;
            const ix = tree.indexOf(@enumFromInt(nid)) orelse return .missing;
            return .{ .node = .{ .win = w, .ix = ix } };
        };
        return .missing;
    }

    fn nodePath(buf: []u8, w: *const Win, nid: a11y.NodeId) []const u8 {
        return std.fmt.bufPrint(buf, path_prefix ++ "{d}/{d}", .{ w.id, @intFromEnum(nid) }) catch unreachable;
    }

    fn writeAddress(b: *dbus.Builder, name: []const u8, path: []const u8) !void {
        try b.pad(8);
        try b.str(name);
        try b.str(path);
    }

    fn writeNodeAddress(self: *const Bridge, b: *dbus.Builder, w: *const Win, nid: a11y.NodeId) !void {
        var buf: [96]u8 = undefined;
        try writeAddress(b, self.uniqueName(), nodePath(&buf, w, nid));
    }

    fn reply(self: *Bridge, call: dbus.Message, signature: []const u8, body: []const u8) void {
        if (call.flags & 1 != 0) return;
        self.queue(.{ .type = .method_return, .serial = 0, .reply_serial = call.serial, .destination = if (call.sender.len > 0) call.sender else null, .signature = signature, .body = body });
    }

    fn replyError(self: *Bridge, call: dbus.Message, name: []const u8, text: []const u8) void {
        if (call.flags & 1 != 0) return;
        var b: dbus.Builder = .{ .gpa = self.gpa };
        defer b.buf.deinit(self.gpa);
        b.str(text) catch return;
        self.queue(.{ .type = .err, .serial = 0, .reply_serial = call.serial, .error_name = name, .destination = if (call.sender.len > 0) call.sender else null, .signature = "s", .body = b.buf.items });
    }

    /// Answer one method call addressed to our objects.
    pub fn handleCall(self: *Bridge, m: dbus.Message) void {
        var b: dbus.Builder = .{ .gpa = self.gpa };
        defer b.buf.deinit(self.gpa);
        const sig = self.dispatch(m, &b) catch |e| switch (e) {
            error.UnknownMethod => return self.replyError(m, "org.freedesktop.DBus.Error.UnknownMethod", m.member),
            error.UnknownObject => return self.replyError(m, "org.freedesktop.DBus.Error.UnknownObject", m.path),
            error.InvalidArgs => return self.replyError(m, "org.freedesktop.DBus.Error.InvalidArgs", m.member),
            else => return self.replyError(m, "org.freedesktop.DBus.Error.Failed", m.member),
        };
        self.reply(m, sig, b.buf.items);
    }

    const DispatchError = error{ UnknownMethod, UnknownObject, InvalidArgs, OutOfMemory, Truncated, BadSignature, Unsupported };

    fn dispatch(self: *Bridge, m: dbus.Message, b: *dbus.Builder) DispatchError![]const u8 {
        const member = m.member;
        const iface = m.interface;
        var r: dbus.Reader = .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
        if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Peer")) {
            if (std.mem.eql(u8, member, "Ping")) return "";
            return error.UnknownMethod;
        }
        const target = self.resolve(m.path);
        if (target == .missing) return error.UnknownObject;
        if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Introspectable")) {
            try b.str(introspection);
            return "s";
        }
        if (std.mem.eql(u8, iface, iface_props)) {
            const prop_iface = try r.str();
            if (std.mem.eql(u8, member, "GetAll")) {
                const a = try dbus.Body.beginArray(b, 8);
                for (propertyNames(prop_iface)) |name| {
                    try b.pad(8);
                    try b.str(name);
                    _ = self.property(target, prop_iface, name, b, true) catch |e| if (e == error.UnknownMethod) continue else return e;
                }
                dbus.Body.endArray(b, a);
                return "a{sv}";
            }
            const name = try r.str();
            if (std.mem.eql(u8, member, "Get")) {
                try self.property(target, prop_iface, name, b, true);
                return "v";
            }
            if (std.mem.eql(u8, member, "Set")) {
                const t = try r.sig();
                try self.setProperty(target, prop_iface, name, t, &r);
                return "";
            }
            return error.UnknownMethod;
        }
        return switch (target) {
            .app => self.appMethod(iface, member, &r, b),
            .node => |n| self.nodeMethod(n.win, n.ix, iface, member, &r, b),
            .missing => error.UnknownObject,
        };
    }

    fn propertyNames(iface: []const u8) []const []const u8 {
        if (std.mem.eql(u8, iface, iface_accessible)) return &.{ "Name", "Description", "Parent", "ChildCount", "Locale", "AccessibleId", "HelpText" };
        if (std.mem.eql(u8, iface, iface_application)) return &.{ "ToolkitName", "Version", "AtspiVersion", "Id" };
        if (std.mem.eql(u8, iface, iface_action)) return &.{"NActions"};
        if (std.mem.eql(u8, iface, iface_text)) return &.{ "CharacterCount", "CaretOffset" };
        if (std.mem.eql(u8, iface, iface_value)) return &.{ "MinimumValue", "MaximumValue", "MinimumIncrement", "CurrentValue", "Text" };
        return &.{};
    }

    /// Write property `name` as a variant (`v`).
    fn property(self: *Bridge, target: Target, iface: []const u8, name: []const u8, b: *dbus.Builder, _: bool) DispatchError!void {
        const eq = std.mem.eql;
        switch (target) {
            .app => {
                if (eq(u8, iface, iface_accessible)) {
                    if (eq(u8, name, "Name")) return variantStr(b, self.appName());
                    if (eq(u8, name, "Description") or eq(u8, name, "Locale") or eq(u8, name, "AccessibleId") or eq(u8, name, "HelpText")) return variantStr(b, "");
                    if (eq(u8, name, "Parent")) {
                        try b.sig("(so)");
                        return writeAddress(b, "", null_path);
                    }
                    if (eq(u8, name, "ChildCount")) {
                        try b.sig("i");
                        return b.i32_(@intCast(self.windows.items.len));
                    }
                }
                if (eq(u8, iface, iface_application)) {
                    if (eq(u8, name, "ToolkitName")) return variantStr(b, "zpui");
                    if (eq(u8, name, "Version")) return variantStr(b, "0.1");
                    if (eq(u8, name, "AtspiVersion")) return variantStr(b, "2.1");
                    if (eq(u8, name, "Id")) {
                        try b.sig("i");
                        return b.i32_(self.app_id);
                    }
                }
                return error.UnknownMethod;
            },
            .node => |t| {
                const w = t.win;
                const tree = w.tree orelse return self.emptyWindowProperty(w, iface, name, b);
                if (tree.len() == 0) return self.emptyWindowProperty(w, iface, name, b);
                const n = tree.at(t.ix);
                if (eq(u8, iface, iface_accessible)) {
                    if (eq(u8, name, "Name")) return variantStr(b, tree.name(n) orelse "");
                    if (eq(u8, name, "Description") or eq(u8, name, "HelpText")) return variantStr(b, tree.str(n.description) orelse "");
                    if (eq(u8, name, "Locale") or eq(u8, name, "AccessibleId")) return variantStr(b, "");
                    if (eq(u8, name, "Parent")) {
                        try b.sig("(so)");
                        if (tree.parentOf(t.ix)) |p| return self.writeNodeAddress(b, w, tree.at(p).id);
                        return writeAddress(b, self.uniqueName(), root_path);
                    }
                    if (eq(u8, name, "ChildCount")) {
                        try b.sig("i");
                        return b.i32_(@intCast(tree.children(t.ix).len));
                    }
                }
                if (eq(u8, iface, iface_action) and eq(u8, name, "NActions")) {
                    try b.sig("i");
                    return b.i32_(actionCount(n));
                }
                if (eq(u8, iface, iface_text)) {
                    const text = textOf(tree, n);
                    const count: i32 = @intCast(std.unicode.utf8CountCodepoints(text) catch text.len);
                    if (eq(u8, name, "CharacterCount")) {
                        try b.sig("i");
                        return b.i32_(count);
                    }
                    if (eq(u8, name, "CaretOffset")) {
                        try b.sig("i");
                        return b.i32_(if (tree.reported_focus == t.ix) count else 0);
                    }
                }
                if (eq(u8, iface, iface_value)) {
                    if (eq(u8, name, "Text")) return variantStr(b, tree.str(n.value) orelse "");
                    const v: f64 = if (eq(u8, name, "MinimumValue")) n.min_numeric_value orelse 0 else if (eq(u8, name, "MaximumValue")) n.max_numeric_value orelse 0 else if (eq(u8, name, "MinimumIncrement")) n.numeric_value_step orelse 0 else if (eq(u8, name, "CurrentValue")) n.numeric_value orelse 0 else return error.UnknownMethod;
                    try b.sig("d");
                    return b.f64_(v);
                }
                return error.UnknownMethod;
            },
            .missing => return error.UnknownObject,
        }
    }

    /// Properties of a window whose first tree has not arrived yet.
    fn emptyWindowProperty(self: *Bridge, _: *Win, iface: []const u8, name: []const u8, b: *dbus.Builder) DispatchError!void {
        const eq = std.mem.eql;
        if (!eq(u8, iface, iface_accessible)) return error.UnknownMethod;
        if (eq(u8, name, "Parent")) {
            try b.sig("(so)");
            return writeAddress(b, self.uniqueName(), root_path);
        }
        if (eq(u8, name, "ChildCount")) {
            try b.sig("i");
            return b.i32_(0);
        }
        return variantStr(b, "");
    }

    fn setProperty(self: *Bridge, target: Target, iface: []const u8, name: []const u8, t: []const u8, r: *dbus.Reader) DispatchError!void {
        const eq = std.mem.eql;
        switch (target) {
            .app => if (eq(u8, iface, iface_application) and eq(u8, name, "Id") and eq(u8, t, "i")) {
                self.app_id = @bitCast(try r.u32_());
                return;
            },
            .node => |n| if (eq(u8, iface, iface_value) and eq(u8, name, "CurrentValue") and eq(u8, t, "d")) {
                const v = try readF64(r);
                const tree = n.win.tree orelse return error.UnknownObject;
                _ = self.perform(n.win, .{ .target = tree.at(n.ix).id, .action = .set_value, .numeric = v });
                return;
            },
            .missing => return error.UnknownObject,
        }
        return error.UnknownMethod;
    }

    fn perform(_: *Bridge, w: *Win, req: a11y.ActionRequest) bool {
        const f = w.common.callbacks.a11y_action orelse return false;
        f(w.common.callbacks.ctx, req);
        return true;
    }

    fn appMethod(self: *Bridge, iface: []const u8, member: []const u8, r: *dbus.Reader, b: *dbus.Builder) DispatchError![]const u8 {
        const eq = std.mem.eql;
        if (eq(u8, iface, iface_application)) {
            if (eq(u8, member, "GetLocale")) {
                try b.str("");
                return "s";
            }
            return error.UnknownMethod;
        }
        if (!eq(u8, iface, iface_accessible)) return error.UnknownMethod;
        if (eq(u8, member, "GetChildAtIndex")) {
            const i: i32 = @bitCast(try r.u32_());
            if (i < 0 or i >= self.windows.items.len) {
                try writeAddress(b, "", null_path);
            } else try self.writeNodeAddress(b, self.windows.items[@intCast(i)], .root);
            return "(so)";
        }
        if (eq(u8, member, "GetChildren")) {
            const a = try dbus.Body.beginArray(b, 8);
            for (self.windows.items) |w| try self.writeNodeAddress(b, w, .root);
            dbus.Body.endArray(b, a);
            return "a(so)";
        }
        if (eq(u8, member, "GetIndexInParent")) {
            try b.i32_(-1);
            return "i";
        }
        if (eq(u8, member, "GetRelationSet")) {
            const a = try dbus.Body.beginArray(b, 8);
            dbus.Body.endArray(b, a);
            return "a(ua(so))";
        }
        if (eq(u8, member, "GetRole")) {
            try b.u32_(R.application);
            return "u";
        }
        if (eq(u8, member, "GetRoleName") or eq(u8, member, "GetLocalizedRoleName")) {
            try b.str("application");
            return "s";
        }
        if (eq(u8, member, "GetState")) {
            try writeStates(b, 0);
            return "au";
        }
        if (eq(u8, member, "GetAttributes")) {
            const a = try dbus.Body.beginArray(b, 8);
            dbus.Body.endArray(b, a);
            return "a{ss}";
        }
        if (eq(u8, member, "GetApplication")) {
            try writeAddress(b, self.uniqueName(), root_path);
            return "(so)";
        }
        if (eq(u8, member, "GetInterfaces")) {
            try writeStrings(b, &.{ iface_accessible, iface_application });
            return "as";
        }
        return error.UnknownMethod;
    }

    fn nodeMethod(self: *Bridge, w: *Win, ix: u32, iface: []const u8, member: []const u8, r: *dbus.Reader, b: *dbus.Builder) DispatchError![]const u8 {
        const eq = std.mem.eql;
        const empty_tree = w.tree == null or w.tree.?.len() == 0;
        if (empty_tree) {
            // The window before its first tree: a childless frame.
            if (!eq(u8, iface, iface_accessible)) return error.UnknownMethod;
            if (eq(u8, member, "GetRole")) {
                try b.u32_(R.frame);
                return "u";
            }
            if (eq(u8, member, "GetChildren")) {
                const a = try dbus.Body.beginArray(b, 8);
                dbus.Body.endArray(b, a);
                return "a(so)";
            }
            if (eq(u8, member, "GetState")) {
                try writeStates(b, bit(.visible) | bit(.showing) | bit(.enabled) | bit(.sensitive) | (if (w.common.active) bit(.active) else 0));
                return "au";
            }
            if (eq(u8, member, "GetInterfaces")) {
                try writeStrings(b, &.{ iface_accessible, iface_component });
                return "as";
            }
            if (eq(u8, member, "GetApplication")) {
                try writeAddress(b, self.uniqueName(), root_path);
                return "(so)";
            }
            if (eq(u8, member, "GetIndexInParent")) {
                try b.i32_(@intCast(std.mem.indexOfScalar(*Win, self.windows.items, w) orelse 0));
                return "i";
            }
            return error.UnknownMethod;
        }
        const tree = w.tree.?;
        const n = tree.at(ix);
        if (eq(u8, iface, iface_accessible)) return self.accessibleMethod(w, tree, ix, member, r, b);
        if (eq(u8, iface, iface_component)) return self.componentMethod(w, tree, ix, member, r, b);
        if (eq(u8, iface, iface_action)) {
            if (eq(u8, member, "DoAction")) {
                const i: i32 = @bitCast(try r.u32_());
                const a = actionAt(n, i) orelse {
                    try dbus.Body.boolean(b, false);
                    return "b";
                };
                try dbus.Body.boolean(b, self.perform(w, .{ .target = n.id, .action = a }));
                return "b";
            }
            if (eq(u8, member, "GetActions")) {
                const arr = try dbus.Body.beginArray(b, 8);
                for (action_order) |e| if (n.actions.contains(e[0])) {
                    try b.pad(8);
                    try b.str(e[1]);
                    try b.str("");
                    try b.str(if (e[0] == .click) tree.str(n.keyshortcuts) orelse "" else "");
                };
                dbus.Body.endArray(b, arr);
                return "a(sss)";
            }
            const i: i32 = @bitCast(try r.u32_());
            const a = actionAt(n, i);
            if (eq(u8, member, "GetName") or eq(u8, member, "GetLocalizedName")) {
                try b.str(if (a) |x| actionName(x) else "");
                return "s";
            }
            if (eq(u8, member, "GetDescription")) {
                try b.str("");
                return "s";
            }
            if (eq(u8, member, "GetKeyBinding")) {
                try b.str(if (a != null and a.? == .click) tree.str(n.keyshortcuts) orelse "" else "");
                return "s";
            }
            return error.UnknownMethod;
        }
        if (eq(u8, iface, iface_text) and hasText(n)) return self.textMethod(w, tree, ix, member, r, b);
        if (eq(u8, iface, iface_editable) and n.role.isTextInput()) {
            if (eq(u8, member, "SetTextContents")) {
                const s = try r.str();
                try dbus.Body.boolean(b, !n.read_only and self.perform(w, .{ .target = n.id, .action = .set_value, .value = s }));
                return "b";
            }
            if (eq(u8, member, "InsertText") or eq(u8, member, "DeleteText") or eq(u8, member, "CopyText") or eq(u8, member, "CutText") or eq(u8, member, "PasteText")) {
                try dbus.Body.boolean(b, false);
                return "b";
            }
        }
        return error.UnknownMethod;
    }

    fn accessibleMethod(self: *Bridge, w: *Win, tree: *const a11y.Tree, ix: u32, member: []const u8, r: *dbus.Reader, b: *dbus.Builder) DispatchError![]const u8 {
        const eq = std.mem.eql;
        const n = tree.at(ix);
        if (eq(u8, member, "GetChildAtIndex")) {
            const i: i32 = @bitCast(try r.u32_());
            const kids = tree.children(ix);
            if (i < 0 or i >= kids.len) {
                try writeAddress(b, "", null_path);
            } else try self.writeNodeAddress(b, w, tree.at(kids[@intCast(i)]).id);
            return "(so)";
        }
        if (eq(u8, member, "GetChildren")) {
            const a = try dbus.Body.beginArray(b, 8);
            for (tree.children(ix)) |k| try self.writeNodeAddress(b, w, tree.at(k).id);
            dbus.Body.endArray(b, a);
            return "a(so)";
        }
        if (eq(u8, member, "GetIndexInParent")) {
            const i: i32 = if (ix == 0) @intCast(std.mem.indexOfScalar(*Win, self.windows.items, w) orelse 0) else @intCast(n.index_in_parent);
            try b.i32_(i);
            return "i";
        }
        if (eq(u8, member, "GetRelationSet")) {
            const a = try dbus.Body.beginArray(b, 8);
            dbus.Body.endArray(b, a);
            return "a(ua(so))";
        }
        if (eq(u8, member, "GetRole")) {
            try b.u32_(atspiRole(n));
            return "u";
        }
        if (eq(u8, member, "GetRoleName") or eq(u8, member, "GetLocalizedRoleName")) {
            try b.str(roleName(atspiRole(n)));
            return "s";
        }
        if (eq(u8, member, "GetState")) {
            try writeStates(b, stateSet(tree, ix, w.common.active));
            return "au";
        }
        if (eq(u8, member, "GetAttributes")) {
            const a = try dbus.Body.beginArray(b, 8);
            var num: [24]u8 = undefined;
            if (tree.str(n.placeholder)) |p| try dictSS(b, "placeholder-text", p);
            if (n.position_in_set) |p| try dictSS(b, "posinset", std.fmt.bufPrint(&num, "{d}", .{p + 1}) catch unreachable);
            if (n.size_of_set) |s| try dictSS(b, "setsize", std.fmt.bufPrint(&num, "{d}", .{s}) catch unreachable);
            if (n.level) |l| try dictSS(b, "level", std.fmt.bufPrint(&num, "{d}", .{l}) catch unreachable);
            if (tree.str(n.keyshortcuts)) |k| try dictSS(b, "keyshortcuts", k);
            try dictSS(b, "toolkit", "zpui");
            dbus.Body.endArray(b, a);
            return "a{ss}";
        }
        if (eq(u8, member, "GetApplication")) {
            try writeAddress(b, self.uniqueName(), root_path);
            return "(so)";
        }
        if (eq(u8, member, "GetInterfaces")) {
            var list: [6][]const u8 = undefined;
            var k: usize = 0;
            list[k] = iface_accessible;
            k += 1;
            list[k] = iface_component;
            k += 1;
            if (actionCount(n) > 0) {
                list[k] = iface_action;
                k += 1;
            }
            if (hasText(n)) {
                list[k] = iface_text;
                k += 1;
            }
            if (n.role.isTextInput() and !n.read_only) {
                list[k] = iface_editable;
                k += 1;
            }
            if (hasValue(n)) {
                list[k] = iface_value;
                k += 1;
            }
            try writeStrings(b, list[0..k]);
            return "as";
        }
        return error.UnknownMethod;
    }

    /// Bounds in AT-SPI coordinates: 0 = screen, 1 = window, 2 = parent.
    fn extents(w: *const Win, tree: *const a11y.Tree, ix: u32, coord: u32) a11y.Bounds {
        var bnd = tree.at(ix).bounds;
        switch (coord) {
            0 => {
                const o = if (w.pw) |pw| pw.bounds().origin else a11y.Point.zero;
                bnd.origin.x += o.x;
                bnd.origin.y += o.y;
            },
            2 => if (tree.parentOf(ix)) |p| {
                const po = tree.at(p).bounds.origin;
                bnd.origin.x -= po.x;
                bnd.origin.y -= po.y;
            },
            else => {},
        }
        return bnd;
    }

    fn toWindowPoint(w: *const Win, tree: *const a11y.Tree, ix: u32, x: i32, y: i32, coord: u32) a11y.Point {
        var p: a11y.Point = .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
        switch (coord) {
            0 => {
                const o = if (w.pw) |pw| pw.bounds().origin else a11y.Point.zero;
                p.x -= o.x;
                p.y -= o.y;
            },
            2 => if (tree.parentOf(ix)) |par| {
                const po = tree.at(par).bounds.origin;
                p.x += po.x;
                p.y += po.y;
            },
            else => {},
        }
        return p;
    }

    fn componentMethod(self: *Bridge, w: *Win, tree: *const a11y.Tree, ix: u32, member: []const u8, r: *dbus.Reader, b: *dbus.Builder) DispatchError![]const u8 {
        const eq = std.mem.eql;
        const n = tree.at(ix);
        if (eq(u8, member, "GetExtents")) {
            const e = extents(w, tree, ix, try r.u32_());
            try b.pad(8);
            try b.i32_(@intFromFloat(@round(e.origin.x)));
            try b.i32_(@intFromFloat(@round(e.origin.y)));
            try b.i32_(@intFromFloat(@round(e.size.width)));
            try b.i32_(@intFromFloat(@round(e.size.height)));
            return "(iiii)";
        }
        if (eq(u8, member, "GetPosition")) {
            const e = extents(w, tree, ix, try r.u32_());
            try b.i32_(@intFromFloat(@round(e.origin.x)));
            try b.i32_(@intFromFloat(@round(e.origin.y)));
            return "ii";
        }
        if (eq(u8, member, "GetSize")) {
            try b.i32_(@intFromFloat(@round(n.bounds.size.width)));
            try b.i32_(@intFromFloat(@round(n.bounds.size.height)));
            return "ii";
        }
        if (eq(u8, member, "Contains") or eq(u8, member, "GetAccessibleAtPoint")) {
            const x: i32 = @bitCast(try r.u32_());
            const y: i32 = @bitCast(try r.u32_());
            const coord = try r.u32_();
            const p = toWindowPoint(w, tree, ix, x, y, coord);
            if (eq(u8, member, "Contains")) {
                try dbus.Body.boolean(b, n.bounds.contains(p));
                return "b";
            }
            const hit = tree.hitTest(p);
            if (hit) |h| if (h == ix or tree.isAncestor(ix, h)) {
                try self.writeNodeAddress(b, w, tree.at(h).id);
                return "(so)";
            };
            try writeAddress(b, "", null_path);
            return "(so)";
        }
        if (eq(u8, member, "GetLayer")) {
            try b.u32_(if (ix == 0) 7 else 3); // ATSPI_LAYER_WINDOW / _WIDGET
            return "u";
        }
        if (eq(u8, member, "GetMDIZOrder")) {
            try b.i16_(0);
            return "n";
        }
        if (eq(u8, member, "GrabFocus")) {
            try dbus.Body.boolean(b, n.isFocusable() and self.perform(w, .{ .target = n.id, .action = .focus }));
            return "b";
        }
        if (eq(u8, member, "GetAlpha")) {
            try b.f64_(1.0);
            return "d";
        }
        if (eq(u8, member, "ScrollTo") or eq(u8, member, "ScrollToPoint") or eq(u8, member, "SetExtents") or eq(u8, member, "SetPosition") or eq(u8, member, "SetSize")) {
            const ok = eq(u8, member, "ScrollTo") and n.actions.contains(.scroll_into_view) and self.perform(w, .{ .target = n.id, .action = .scroll_into_view });
            try dbus.Body.boolean(b, ok);
            return "b";
        }
        return error.UnknownMethod;
    }

    fn textMethod(self: *Bridge, w: *Win, tree: *const a11y.Tree, ix: u32, member: []const u8, r: *dbus.Reader, b: *dbus.Builder) DispatchError![]const u8 {
        _ = self;
        const eq = std.mem.eql;
        const n = tree.at(ix);
        const text = textOf(tree, n);
        const count: i32 = @intCast(std.unicode.utf8CountCodepoints(text) catch text.len);
        if (eq(u8, member, "GetText")) {
            const start: i32 = @bitCast(try r.u32_());
            var end: i32 = @bitCast(try r.u32_());
            if (end < 0 or end > count) end = count;
            try b.str(sliceChars(text, @max(0, start), end));
            return "s";
        }
        if (eq(u8, member, "GetCharacterAtOffset")) {
            const off: i32 = @bitCast(try r.u32_());
            const s = sliceChars(text, off, off + 1);
            const cp: i32 = if (s.len == 0) 0 else @intCast(std.unicode.utf8Decode(s) catch 0);
            try b.i32_(cp);
            return "i";
        }
        if (eq(u8, member, "GetStringAtOffset") or eq(u8, member, "GetTextAtOffset") or eq(u8, member, "GetTextBeforeOffset") or eq(u8, member, "GetTextAfterOffset")) {
            const off: i32 = @bitCast(try r.u32_());
            const gran = try r.u32_();
            // GetStringAtOffset granularity: 0 char, 1 word, 2 sentence, 3 line, 4 paragraph.
            // GetTextAtOffset boundary: 0 char, 1-2 word, 3-4 sentence, 5-6 line.
            const unit: enum { char, word, all } = if (eq(u8, member, "GetStringAtOffset"))
                (if (gran == 0) .char else if (gran == 1) .word else .all)
            else if (gran == 0) .char else if (gran <= 2) .word else .all;
            var s: i32 = 0;
            var e: i32 = count;
            switch (unit) {
                .char => {
                    s = std.math.clamp(off, 0, count);
                    e = @min(count, s + 1);
                },
                .word => {
                    const wb = wordAt(text, std.math.clamp(off, 0, count));
                    s = wb[0];
                    e = wb[1];
                },
                .all => {},
            }
            if (eq(u8, member, "GetTextBeforeOffset") or eq(u8, member, "GetTextAfterOffset")) {
                s = 0;
                e = 0;
            }
            try b.str(sliceChars(text, s, e));
            try b.i32_(s);
            try b.i32_(e);
            return "sii";
        }
        if (eq(u8, member, "GetNSelections")) {
            try b.i32_(0);
            return "i";
        }
        if (eq(u8, member, "GetSelection")) {
            try b.i32_(0);
            try b.i32_(0);
            return "ii";
        }
        if (eq(u8, member, "GetCaretOffset")) {
            try b.i32_(count);
            return "i";
        }
        if (eq(u8, member, "SetCaretOffset") or eq(u8, member, "AddSelection") or eq(u8, member, "RemoveSelection") or eq(u8, member, "SetSelection") or eq(u8, member, "ScrollSubstringTo")) {
            try dbus.Body.boolean(b, false);
            return "b";
        }
        if (eq(u8, member, "GetCharacterExtents") or eq(u8, member, "GetRangeExtents")) {
            _ = try r.u32_();
            if (eq(u8, member, "GetRangeExtents")) _ = try r.u32_();
            const e = extents(w, tree, ix, try r.u32_());
            try b.i32_(@intFromFloat(@round(e.origin.x)));
            try b.i32_(@intFromFloat(@round(e.origin.y)));
            try b.i32_(@intFromFloat(@round(e.size.width)));
            try b.i32_(@intFromFloat(@round(e.size.height)));
            return "iiii";
        }
        if (eq(u8, member, "GetDefaultAttributes")) {
            const a = try dbus.Body.beginArray(b, 8);
            dbus.Body.endArray(b, a);
            return "a{ss}";
        }
        if (eq(u8, member, "GetAttributeRun") or eq(u8, member, "GetAttributes")) {
            const a = try dbus.Body.beginArray(b, 8);
            dbus.Body.endArray(b, a);
            try b.i32_(0);
            try b.i32_(count);
            return "a{ss}ii";
        }
        return error.UnknownMethod;
    }

    // ---- events -----------------------------------------------------------------------

    fn emitChanges(self: *Bridge, w: *Win, u: a11y.Update) void {
        const tree = u.tree;
        const ch = u.changes;
        if (ch.full) {
            self.emitSignal(w, .root, iface_event_object, "PropertyChange", "accessible-name", 0, 0, .{ .str = tree.name(tree.at(0)) orelse "" });
        }
        for (ch.entries.items) |e| {
            if (e.what.removed) {
                self.emitState(w, e.id, .defunct, true);
                if (e.parent) |p| if (tree.indexOf(p) != null) self.emitChildrenChangedNode(w, p, "remove", -1, e.id);
                continue;
            }
            const ix = tree.indexOf(e.id) orelse continue;
            const n = tree.at(ix);
            if (e.what.added) {
                if (tree.parentOf(ix)) |p| if (ch.find(tree.at(p).id)) |pm| if (pm.added) continue;
                if (tree.parentOf(ix)) |p| self.emitChildrenChangedNode(w, tree.at(p).id, "add", @intCast(n.index_in_parent), e.id);
                continue;
            }
            if (e.what.name) self.emitSignal(w, e.id, iface_event_object, "PropertyChange", "accessible-name", 0, 0, .{ .str = tree.name(n) orelse "" });
            if (e.what.description) self.emitSignal(w, e.id, iface_event_object, "PropertyChange", "accessible-description", 0, 0, .{ .str = tree.str(n.description) orelse "" });
            if (e.what.numeric) self.emitSignal(w, e.id, iface_event_object, "PropertyChange", "accessible-value", 0, 0, .{ .f64 = n.numeric_value orelse 0 });
            if (e.what.value and n.role.isTextInput()) {
                const v = tree.str(n.value) orelse "";
                const len: i32 = @intCast(std.unicode.utf8CountCodepoints(v) catch v.len);
                self.emitSignal(w, e.id, iface_event_object, "TextChanged", "insert", 0, len, .{ .str = v });
            }
            if (e.what.state) {
                if (!std.meta.eql(e.was_selected, n.selected)) self.emitState(w, e.id, .selected, n.selected orelse false);
                if (!std.meta.eql(e.was_expanded, n.expanded)) self.emitState(w, e.id, .expanded, n.expanded orelse false);
                if (!std.meta.eql(e.was_toggled, n.toggled)) {
                    const st: State = if (atspiRole(n) == R.toggle_button) .pressed else .checked;
                    self.emitState(w, e.id, st, n.toggled == .on);
                    if (n.toggled == .mixed or e.was_toggled == .mixed) self.emitState(w, e.id, .indeterminate, n.toggled == .mixed);
                }
                if (e.was_disabled != n.disabled) {
                    self.emitState(w, e.id, .enabled, !n.disabled);
                    self.emitState(w, e.id, .sensitive, !n.disabled);
                }
            }
            if (e.what.bounds) self.emitSignal(w, e.id, iface_event_object, "BoundsChanged", "", 0, 0, .{ .rect = n.bounds });
        }
        if (ch.focus_changed or (ch.full and ch.new_focus != .root)) {
            if (ch.old_focus != .root and tree.indexOf(ch.old_focus) != null) self.emitState(w, ch.old_focus, .focused, false);
            if (ch.new_focus != .root) {
                self.emitState(w, ch.new_focus, .focused, true);
                self.emitSignal(w, ch.new_focus, "org.a11y.atspi.Event.Focus", "Focus", "", 0, 0, .{ .str = "" });
            }
        }
    }

    const Any = union(enum) { str: []const u8, f64: f64, rect: a11y.Bounds, addr: struct { w: *const Win, id: a11y.NodeId } };

    fn emitState(self: *Bridge, w: *const Win, id: a11y.NodeId, s: State, on: bool) void {
        self.emitSignal(w, id, iface_event_object, "StateChanged", stateName(s), @intFromBool(on), 0, .{ .str = "" });
    }

    fn emitChildrenChangedNode(self: *Bridge, w: *const Win, parent: a11y.NodeId, kind: []const u8, index: i32, child: a11y.NodeId) void {
        self.emitSignal(w, parent, iface_event_object, "ChildrenChanged", kind, index, 0, .{ .addr = .{ .w = w, .id = child } });
    }

    /// ChildrenChanged on an arbitrary path (the application root) for window `w`.
    fn emitChildrenChanged(self: *Bridge, path: []const u8, kind: []const u8, index: i32, w: *const Win, _: u64) void {
        self.emitAt(path, iface_event_object, "ChildrenChanged", kind, index, 0, .{ .addr = .{ .w = w, .id = .root } });
    }

    fn emitSignal(self: *Bridge, w: *const Win, id: a11y.NodeId, iface: []const u8, member: []const u8, kind: []const u8, d1: i32, d2: i32, any: Any) void {
        var buf: [96]u8 = undefined;
        self.emitAt(nodePath(&buf, w, id), iface, member, kind, d1, d2, any);
    }

    fn emitAt(self: *Bridge, path: []const u8, iface: []const u8, member: []const u8, kind: []const u8, d1: i32, d2: i32, any: Any) void {
        var b: dbus.Builder = .{ .gpa = self.gpa };
        defer b.buf.deinit(self.gpa);
        self.eventBody(&b, kind, d1, d2, any) catch return;
        self.queue(.{ .type = .signal, .serial = 0, .path = path, .interface = iface, .member = member, .signature = "siiva{sv}", .body = b.buf.items });
    }

    fn eventBody(self: *const Bridge, b: *dbus.Builder, kind: []const u8, d1: i32, d2: i32, any: Any) !void {
        try b.str(kind);
        try b.i32_(d1);
        try b.i32_(d2);
        switch (any) {
            .str => |s| {
                try b.sig("s");
                try b.str(s);
            },
            .f64 => |v| {
                try b.sig("d");
                try b.f64_(v);
            },
            .rect => |r| {
                try b.sig("(iiii)");
                try b.pad(8);
                try b.i32_(@intFromFloat(@round(r.origin.x)));
                try b.i32_(@intFromFloat(@round(r.origin.y)));
                try b.i32_(@intFromFloat(@round(r.size.width)));
                try b.i32_(@intFromFloat(@round(r.size.height)));
            },
            .addr => |a| {
                try b.sig("(so)");
                try self.writeNodeAddress(b, a.w, a.id);
            },
        }
        const arr = try dbus.Body.beginArray(b, 8);
        dbus.Body.endArray(b, arr);
    }
};

// ---------------------------------------------------------------------------------------
// Marshalling helpers
// ---------------------------------------------------------------------------------------

fn variantStr(b: *dbus.Builder, s: []const u8) !void {
    try b.sig("s");
    try b.str(s);
}

fn writeStates(b: *dbus.Builder, s: u64) !void {
    const a = try dbus.Body.beginArray(b, 4);
    try b.u32_(@truncate(s));
    try b.u32_(@truncate(s >> 32));
    dbus.Body.endArray(b, a);
}

fn writeStrings(b: *dbus.Builder, list: []const []const u8) !void {
    const a = try dbus.Body.beginArray(b, 4);
    for (list) |s| try b.str(s);
    dbus.Body.endArray(b, a);
}

fn dictSS(b: *dbus.Builder, k: []const u8, v: []const u8) !void {
    try b.pad(8);
    try b.str(k);
    try b.str(v);
}

fn readF64(r: *dbus.Reader) !f64 {
    try r.alignTo(8);
    if (r.pos + 8 > r.bytes.len) return error.Truncated;
    defer r.pos += 8;
    const raw = std.mem.bytesToValue(u64, r.bytes[r.pos..][0..8]);
    return @bitCast(if (r.big) std.mem.bigToNative(u64, raw) else std.mem.littleToNative(u64, raw));
}

/// Characters `[start, end)` of UTF-8 `text` (codepoint offsets, clamped).
fn sliceChars(text: []const u8, start: i32, end: i32) []const u8 {
    if (end <= start or start < 0) return "";
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var k: i32 = 0;
    var s_byte: usize = text.len;
    var e_byte: usize = text.len;
    while (true) {
        if (k == start) s_byte = it.i;
        if (k == end) {
            e_byte = it.i;
            break;
        }
        if (it.nextCodepointSlice() == null) break;
        k += 1;
    }
    if (s_byte > e_byte) return "";
    return text[s_byte..e_byte];
}

/// Word boundaries (character offsets) around `off`.
fn wordAt(text: []const u8, off: i32) [2]i32 {
    var chars: std.ArrayList(u21) = .empty;
    defer chars.deinit(std.heap.page_allocator);
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |cp| chars.append(std.heap.page_allocator, cp) catch break;
    const n: i32 = @intCast(chars.items.len);
    if (n == 0) return .{ 0, 0 };
    const isWord = struct {
        fn f(cp: u21) bool {
            return cp != ' ' and cp != '\t' and cp != '\n';
        }
    }.f;
    var s = @min(off, n - 1);
    var e = s;
    while (s > 0 and isWord(chars.items[@intCast(s - 1)])) s -= 1;
    while (e < n and isWord(chars.items[@intCast(e)])) e += 1;
    // Include trailing spaces (ATK word-start semantics).
    while (e < n and !isWord(chars.items[@intCast(e)])) e += 1;
    return .{ s, e };
}

const introspection =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\  <interface name="org.a11y.atspi.Accessible"/>
    \\  <interface name="org.a11y.atspi.Component"/>
    \\  <interface name="org.a11y.atspi.Action"/>
    \\  <interface name="org.a11y.atspi.Text"/>
    \\  <interface name="org.a11y.atspi.EditableText"/>
    \\  <interface name="org.a11y.atspi.Value"/>
    \\  <interface name="org.freedesktop.DBus.Properties"/>
    \\</node>
;

// ---------------------------------------------------------------------------------------
// Tests (no sockets: calls are fed to `handleCall`, replies/signals read from `outbox`)
// ---------------------------------------------------------------------------------------

const testing = std.testing;

const Fixture = struct {
    tree: a11y.Tree,
    common: Common = .{},
    bridge: Bridge,
    requests: [8]a11y.ActionRequest = undefined,
    request_count: usize = 0,
    /// Copy of the last string value (requests borrow the D-Bus message).
    value_buf: [64]u8 = undefined,

    fn init(self: *Fixture) void {
        self.* = .{ .tree = .init(testing.allocator), .bridge = .initDetached(testing.allocator) };
        const t = &self.tree;
        t.begin("Zeron", .{ .origin = .zero, .size = .{ .width = 400, .height = 300 } });
        _ = t.push(.{ .id = @enumFromInt(10), .role = .button, .bounds = .{ .origin = .{ .x = 10, .y = 20 }, .size = .{ .width = 80, .height = 30 } }, .info = .{ .actions = .initOne(.click) } });
        t.appendText("Save", .{ .origin = .zero, .size = .zero });
        t.pop();
        _ = t.push(.{ .id = @enumFromInt(11), .role = .@"switch", .bounds = .{ .origin = .{ .x = 10, .y = 60 }, .size = .{ .width = 40, .height = 20 } }, .info = .{ .label = "Sync", .toggled = .on }, .focus_id = 3 });
        t.pop();
        _ = t.push(.{ .id = @enumFromInt(12), .role = .text_input, .bounds = .{ .origin = .{ .x = 10, .y = 90 }, .size = .{ .width = 200, .height = 20 } }, .info = .{ .value = "héllo world", .placeholder = "Message", .actions = .initOne(.set_value) } });
        t.pop();
        t.finalize(3);
        self.common.callbacks = .{ .ctx = self, .a11y_action = onAction };
        self.bridge.addWindow(&self.common, null);
        self.bridge.update(&self.common, .{ .tree = t, .changes = &empty_changes });
        self.clearOutbox();
    }

    var empty_changes: a11y.Changes = .{};

    fn deinit(self: *Fixture) void {
        self.bridge.deinit();
        self.tree.deinit();
    }

    fn onAction(ctx: ?*anyopaque, req: a11y.ActionRequest) void {
        const self: *Fixture = @ptrCast(@alignCast(ctx.?));
        var r = req;
        if (req.value) |v| {
            @memcpy(self.value_buf[0..v.len], v);
            r.value = self.value_buf[0..v.len];
        }
        self.requests[self.request_count] = r;
        self.request_count += 1;
    }

    fn clearOutbox(self: *Fixture) void {
        for (self.bridge.outbox.items) |m| testing.allocator.free(m);
        self.bridge.outbox.clearRetainingCapacity();
    }

    /// Call `member` on `path`; returns the parsed reply (valid until the next call).
    fn call(self: *Fixture, path: []const u8, iface: []const u8, member: []const u8, signature: []const u8, body: []const u8) !dbus.Message {
        self.clearOutbox();
        const bytes = try dbus.buildMessage(testing.allocator, .{ .type = .method_call, .serial = 77, .path = path, .interface = iface, .member = member, .signature = signature, .body = body });
        defer testing.allocator.free(bytes);
        const m = try dbus.parseMessage(bytes);
        self.bridge.handleCall(m);
        try testing.expectEqual(@as(usize, 1), self.bridge.outbox.items.len);
        const r = try dbus.parseMessage(self.bridge.outbox.items[0]);
        try testing.expectEqual(@as(?u32, 77), r.reply_serial);
        return r;
    }
};

fn reader(m: dbus.Message) dbus.Reader {
    return .{ .bytes = m.body, .pos = 0, .big = m.big_endian };
}

test "roles, names, children and states over Accessible" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var m = try f.call(path_prefix ++ "1/10", iface_accessible, "GetRole", "", "");
    var r = reader(m);
    try testing.expectEqual(@as(u32, R.button), try r.u32_());

    var b: dbus.Builder = .{ .gpa = testing.allocator };
    defer b.buf.deinit(testing.allocator);
    try b.str(iface_accessible);
    try b.str("Name");
    m = try f.call(path_prefix ++ "1/10", iface_props, "Get", "ss", b.buf.items);
    r = reader(m);
    try testing.expectEqualStrings("s", try r.sig());
    try testing.expectEqualStrings("Save", try r.str());

    m = try f.call(path_prefix ++ "1/0", iface_accessible, "GetChildren", "", "");
    try testing.expectEqualStrings("a(so)", m.signature);
    r = reader(m);
    _ = try r.u32_();
    try r.alignTo(8);
    try testing.expectEqualStrings(":1.0", try r.str());
    try testing.expectEqualStrings(path_prefix ++ "1/10", try r.str());

    m = try f.call(path_prefix ++ "1/11", iface_accessible, "GetState", "", "");
    r = reader(m);
    _ = try r.u32_();
    const lo: u64 = try r.u32_();
    const hi: u64 = try r.u32_();
    const states = lo | (hi << 32);
    try testing.expect(states & bit(.focused) != 0);
    try testing.expect(states & bit(.pressed) != 0); // switch → toggle button, pressed
    try testing.expect(states & bit(.focusable) != 0);
    try testing.expectEqual(@as(u32, R.toggle_button), atspiRole(f.tree.get(@enumFromInt(11)).?));

    // The application root lists the window.
    m = try f.call(root_path, iface_accessible, "GetChildAtIndex", "i", &.{ 0, 0, 0, 0 });
    r = reader(m);
    try r.alignTo(8);
    _ = try r.str();
    try testing.expectEqualStrings(path_prefix ++ "1/0", try r.str());

    // Unknown objects get an error.
    f.clearOutbox();
    const bytes = try dbus.buildMessage(testing.allocator, .{ .type = .method_call, .serial = 5, .path = path_prefix ++ "1/999", .interface = iface_accessible, .member = "GetRole" });
    defer testing.allocator.free(bytes);
    f.bridge.handleCall(try dbus.parseMessage(bytes));
    try testing.expectEqual(dbus.MessageType.err, (try dbus.parseMessage(f.bridge.outbox.items[0])).type);
}

test "actions, component, text and editable text" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var m = try f.call(path_prefix ++ "1/10", iface_action, "DoAction", "i", &.{ 0, 0, 0, 0 });
    var r = reader(m);
    try testing.expect(try r.u32_() == 1);
    try testing.expectEqual(@as(usize, 1), f.request_count);
    try testing.expectEqual(a11y.Action.click, f.requests[0].action);
    try testing.expectEqual(@as(a11y.NodeId, @enumFromInt(10)), f.requests[0].target);

    m = try f.call(path_prefix ++ "1/10", iface_component, "GetExtents", "u", &.{ 1, 0, 0, 0 });
    r = reader(m);
    try testing.expectEqual(@as(u32, 10), try r.u32_());
    try testing.expectEqual(@as(u32, 20), try r.u32_());
    try testing.expectEqual(@as(u32, 80), try r.u32_());
    try testing.expectEqual(@as(u32, 30), try r.u32_());

    m = try f.call(path_prefix ++ "1/12", iface_text, "GetText", "ii", &.{ 1, 0, 0, 0, 5, 0, 0, 0 });
    r = reader(m);
    try testing.expectEqualStrings("éllo", try r.str());

    m = try f.call(path_prefix ++ "1/12", iface_text, "GetStringAtOffset", "iu", &.{ 7, 0, 0, 0, 1, 0, 0, 0 });
    r = reader(m);
    try testing.expectEqualStrings("world", try r.str());

    var b: dbus.Builder = .{ .gpa = testing.allocator };
    defer b.buf.deinit(testing.allocator);
    try b.str("new text");
    m = try f.call(path_prefix ++ "1/12", iface_editable, "SetTextContents", "s", b.buf.items);
    try testing.expectEqual(a11y.Action.set_value, f.requests[1].action);
    try testing.expectEqualStrings("new text", f.requests[1].value.?);

    m = try f.call(path_prefix ++ "1/12", iface_accessible, "GetInterfaces", "", "");
    r = reader(m);
    const n = try r.u32_();
    try testing.expect(n > 0);
    var found_text = false;
    var seen: u32 = 0;
    while (r.pos < 4 + n) : (seen += 1) {
        const name = try r.str();
        if (std.mem.eql(u8, name, iface_editable)) found_text = true;
    }
    try testing.expect(found_text);

    m = try f.call(path_prefix ++ "1/11", iface_component, "GrabFocus", "", "");
    try testing.expectEqual(a11y.Action.focus, f.requests[2].action);
}

test "frame changes become AT-SPI events" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var next = a11y.Tree.init(testing.allocator);
    defer next.deinit();
    next.begin("Zeron", .{ .origin = .zero, .size = .{ .width = 400, .height = 300 } });
    _ = next.push(.{ .id = @enumFromInt(10), .role = .button, .bounds = .{ .origin = .{ .x = 10, .y = 20 }, .size = .{ .width = 80, .height = 30 } }, .info = .{ .label = "Saved" } });
    next.pop();
    _ = next.push(.{ .id = @enumFromInt(11), .role = .@"switch", .bounds = .{ .origin = .{ .x = 10, .y = 60 }, .size = .{ .width = 40, .height = 20 } }, .info = .{ .label = "Sync", .toggled = .off }, .focus_id = 3 });
    next.pop();
    _ = next.push(.{ .id = @enumFromInt(13), .role = .link, .bounds = .{ .origin = .zero, .size = .zero } });
    next.pop();
    next.finalize(null);
    var ch: a11y.Changes = .{};
    defer ch.deinit(testing.allocator);
    a11y.diff(testing.allocator, &f.tree, &next, &ch);
    f.bridge.update(&f.common, .{ .tree = &next, .changes = &ch });

    var seen_name = false;
    var seen_pressed = false;
    var seen_add = false;
    var seen_remove = false;
    var seen_unfocus = false;
    for (f.bridge.outbox.items) |bytes| {
        const m = try dbus.parseMessage(bytes);
        try testing.expectEqual(dbus.MessageType.signal, m.type);
        try testing.expectEqualStrings("siiva{sv}", m.signature);
        var r = reader(m);
        const kind = try r.str();
        const d1 = try r.u32_();
        if (std.mem.eql(u8, m.member, "PropertyChange") and std.mem.eql(u8, m.path, path_prefix ++ "1/10")) seen_name = true;
        if (std.mem.eql(u8, m.member, "StateChanged") and std.mem.eql(u8, kind, "pressed") and d1 == 0) seen_pressed = true;
        if (std.mem.eql(u8, m.member, "StateChanged") and std.mem.eql(u8, kind, "focused") and d1 == 0) seen_unfocus = true;
        if (std.mem.eql(u8, m.member, "ChildrenChanged") and std.mem.eql(u8, kind, "add")) seen_add = true;
        if (std.mem.eql(u8, m.member, "ChildrenChanged") and std.mem.eql(u8, kind, "remove")) seen_remove = true;
    }
    try testing.expect(seen_name);
    try testing.expect(seen_pressed);
    try testing.expect(seen_add);
    try testing.expect(seen_remove);
    try testing.expect(seen_unfocus);
}

test "status parsing" {
    var b: dbus.Builder = .{ .gpa = testing.allocator };
    defer b.buf.deinit(testing.allocator);
    const a = try dbus.Body.beginArray(&b, 8);
    try dbus.Body.dictEntry(&b, "IsEnabled", "b");
    try dbus.Body.boolean(&b, false);
    try dbus.Body.dictEntry(&b, "ScreenReaderEnabled", "b");
    try dbus.Body.boolean(&b, true);
    dbus.Body.endArray(&b, a);
    try testing.expect(Bridge.parseStatus(b.buf.items, false, false));
}
