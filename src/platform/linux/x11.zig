//! X11 backend (gpui_linux `x11/client.rs`, `x11/window.rs`, `x11/clipboard.rs`).
//!
//! Library choice: Xlib opens the display and hands its connection to XCB
//! (`XGetXCBConnection` + `XSetEventQueueOwner(XCBOwnsEventQueue)`), so every request
//! and event goes through libxcb (and Vulkan's VK_KHR_xcb_surface), while the few
//! Xlib-only conveniences still work on the same connection: Xcursor themes
//! (`XcursorLibraryLoadCursor`), XInput2 setup via libXi (no xcb-xinput headers are
//! installed) and `XResourceManagerString` for Xft.dpi. XI2 device events are decoded
//! from the raw GenericEvent wire format.
//!
//! Features: ARGB visual for transparent windows, EWMH (_NET_WM_NAME/STATE/PID/PING,
//! _NET_WM_MOVERESIZE for CSD drags), _MOTIF_WM_HINTS to drop server decorations,
//! XKB keyboard (xkbcommon-x11, detectable auto-repeat, compose), XInput2 pointer with
//! smooth scrolling (core events as fallback), CLIPBOARD on a dedicated connection,
//! timer-driven frame requests. IME (XIM) is not implemented: compose/dead keys work,
//! input methods do not.

const std = @import("std");
const linux = std.os.linux;
const c = @import("linux_c");
const platform = @import("../platform.zig");
const input = @import("../../input.zig");
const scene_mod = @import("../../scene.zig");
const atlas_mod = @import("../../atlas.zig");
const event_loop = @import("event_loop.zig");
const keyboard = @import("keyboard.zig");
const common = @import("window_common.zig");
const util = @import("util.zig");
const Presenter = @import("presenter.zig").Presenter;
const LinuxPlatform = @import("linux.zig").LinuxPlatform;

const log = std.log.scoped(.x11);
const Allocator = std.mem.Allocator;

// Core event codes (X11/X.h).
const KEY_PRESS = 2;
const KEY_RELEASE = 3;
const BUTTON_PRESS = 4;
const BUTTON_RELEASE = 5;
const MOTION_NOTIFY = 6;
const ENTER_NOTIFY = 7;
const LEAVE_NOTIFY = 8;
const FOCUS_IN = 9;
const FOCUS_OUT = 10;
const EXPOSE = 12;
const DESTROY_NOTIFY = 17;
const UNMAP_NOTIFY = 18;
const MAP_NOTIFY = 19;
const CONFIGURE_NOTIFY = 22;
const PROPERTY_NOTIFY = 28;
const SELECTION_CLEAR = 29;
const SELECTION_REQUEST = 30;
const SELECTION_NOTIFY = 31;
const CLIENT_MESSAGE = 33;
const MAPPING_NOTIFY = 34;
const GENERIC_EVENT = 35;

// XKB event subtypes.
const XKB_NEW_KEYBOARD_NOTIFY = 0;
const XKB_MAP_NOTIFY = 1;
const XKB_STATE_NOTIFY = 2;

const ATOM_ATOM = 4;
const ATOM_CARDINAL = 6;
const ATOM_STRING = 31;
const ATOM_WM_NAME = 39;
const ATOM_WM_NORMAL_HINTS = 40;
const ATOM_WM_SIZE_HINTS = 41;
const ATOM_WM_CLASS = 67;

const atom_names = [_][:0]const u8{
    "WM_PROTOCOLS",                 "WM_DELETE_WINDOW",             "WM_CHANGE_STATE",
    "_NET_WM_NAME",                 "UTF8_STRING",                  "_NET_WM_STATE",
    "_NET_WM_STATE_MAXIMIZED_VERT", "_NET_WM_STATE_MAXIMIZED_HORZ", "_NET_WM_STATE_FULLSCREEN",
    "_NET_WM_STATE_HIDDEN",         "_NET_WM_STATE_FOCUSED",        "_NET_WM_MOVERESIZE",
    "_MOTIF_WM_HINTS",              "_NET_WM_PID",                  "_NET_WM_PING",
    "_NET_WM_WINDOW_TYPE",          "_NET_WM_WINDOW_TYPE_NORMAL",   "_NET_ACTIVE_WINDOW",
    "CLIPBOARD",                    "TARGETS",                      "TEXT",
    "_ZPUI_SELECTION",              "INCR",                         "text/plain;charset=utf-8",
    "_GTK_FRAME_EXTENTS",
};

const Atoms = struct {
    WM_PROTOCOLS: u32 = 0,
    WM_DELETE_WINDOW: u32 = 0,
    WM_CHANGE_STATE: u32 = 0,
    _NET_WM_NAME: u32 = 0,
    UTF8_STRING: u32 = 0,
    _NET_WM_STATE: u32 = 0,
    _NET_WM_STATE_MAXIMIZED_VERT: u32 = 0,
    _NET_WM_STATE_MAXIMIZED_HORZ: u32 = 0,
    _NET_WM_STATE_FULLSCREEN: u32 = 0,
    _NET_WM_STATE_HIDDEN: u32 = 0,
    _NET_WM_STATE_FOCUSED: u32 = 0,
    _NET_WM_MOVERESIZE: u32 = 0,
    _MOTIF_WM_HINTS: u32 = 0,
    _NET_WM_PID: u32 = 0,
    _NET_WM_PING: u32 = 0,
    _NET_WM_WINDOW_TYPE: u32 = 0,
    _NET_WM_WINDOW_TYPE_NORMAL: u32 = 0,
    _NET_ACTIVE_WINDOW: u32 = 0,
    CLIPBOARD: u32 = 0,
    TARGETS: u32 = 0,
    TEXT: u32 = 0,
    _ZPUI_SELECTION: u32 = 0,
    INCR: u32 = 0,
    TEXT_PLAIN_UTF8: u32 = 0,
    _GTK_FRAME_EXTENTS: u32 = 0,

    fn intern(conn: *c.xcb_connection_t) Atoms {
        var cookies: [atom_names.len]c.xcb_intern_atom_cookie_t = undefined;
        for (atom_names, 0..) |n, i| cookies[i] = c.xcb_intern_atom(conn, 0, @intCast(n.len), n.ptr);
        var out: Atoms = .{};
        const fields = @typeInfo(Atoms).@"struct".field_names;
        inline for (fields, 0..) |f, i| {
            const reply = c.xcb_intern_atom_reply(conn, cookies[i], null);
            if (reply != null) {
                @field(out, f) = reply.*.atom;
                std.c.free(reply);
            }
        }
        return out;
    }
};

/// Big-endian-agnostic reads from an event buffer.
fn rd(comptime T: type, bytes: [*]const u8, off: usize) T {
    return std.mem.readInt(T, bytes[off..][0..@sizeOf(T)], .little);
}

/// Wire offset → offset in an xcb GenericEvent buffer (xcb inserts `full_sequence` at 32).
fn geOff(wire: usize) usize {
    return if (wire >= 32) wire + 4 else wire;
}

fn fp1616(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 65536.0;
}

/// A decoded XI2 device (motion/button) event.
pub const XiDeviceEvent = struct {
    evtype: u16,
    deviceid: u16,
    sourceid: u16,
    detail: u32,
    event: u32,
    root_x: f32,
    root_y: f32,
    event_x: f32,
    event_y: f32,
    flags: u32,
    mods_effective: u32,
    buttons: []const u8,
    valuator_mask: []const u8,
    values: [*]const u8,

    /// Absolute value of valuator `n`, if present in this event.
    pub fn valuator(e: XiDeviceEvent, n: u16) ?f64 {
        const byte = n / 8;
        if (byte >= e.valuator_mask.len) return null;
        if (e.valuator_mask[byte] & (@as(u8, 1) << @intCast(n % 8)) == 0) return null;
        var index: usize = 0;
        for (0..n) |i| {
            if (e.valuator_mask[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0) index += 1;
        }
        const integral = rd(i32, e.values, index * 8);
        const frac = rd(u32, e.values, index * 8 + 4);
        return @as(f64, @floatFromInt(integral)) + @as(f64, @floatFromInt(frac)) / 4294967296.0;
    }

    pub fn buttonDown(e: XiDeviceEvent, b: u5) bool {
        const byte = b / 8;
        return byte < e.buttons.len and e.buttons[byte] & (@as(u8, 1) << @intCast(b % 8)) != 0;
    }
};

/// Decodes an XI_Motion/ButtonPress/ButtonRelease event from an xcb event buffer.
pub fn parseXiDeviceEvent(buf: [*]const u8) XiDeviceEvent {
    const buttons_len: usize = rd(u16, buf, geOff(48));
    const valuators_len: usize = rd(u16, buf, geOff(50));
    const masks = buf + geOff(80);
    return .{
        .evtype = rd(u16, buf, 8),
        .deviceid = rd(u16, buf, 10),
        .detail = rd(u32, buf, 16),
        .event = rd(u32, buf, 24),
        .root_x = fp1616(rd(i32, buf, geOff(32))),
        .root_y = fp1616(rd(i32, buf, geOff(36))),
        .event_x = fp1616(rd(i32, buf, geOff(40))),
        .event_y = fp1616(rd(i32, buf, geOff(44))),
        .sourceid = rd(u16, buf, geOff(52)),
        .flags = rd(u32, buf, geOff(56)),
        .mods_effective = rd(u32, buf, geOff(72)),
        .buttons = masks[0 .. buttons_len * 4],
        .valuator_mask = masks[buttons_len * 4 ..][0 .. valuators_len * 4],
        .values = masks + buttons_len * 4 + valuators_len * 4,
    };
}

/// Core/XI modifier mask → gpui modifiers (gpui `modifiers_from_state`).
pub fn modifiersFromMask(mask: u32) input.Modifiers {
    return .{
        .shift = mask & 1 != 0,
        .control = mask & 4 != 0,
        .alt = mask & 8 != 0,
        .platform = mask & 64 != 0,
    };
}

fn pressedButtonFromMask(mask: u32) ?input.MouseButton {
    if (mask & 0x100 != 0) return .left;
    if (mask & 0x200 != 0) return .middle;
    if (mask & 0x400 != 0) return .right;
    return null;
}

const ScrollDevice = struct {
    id: u16,
    vertical: common.XiScrollAxis = .{},
    horizontal: common.XiScrollAxis = .{},
};

/// Records core keyboard-mapping changes as they happen, on a second X connection
/// served by its own thread.
///
/// Tools like `xdotool type` bind each character missing from the layout to a spare
/// keycode, send the key press, and unbind it a few milliseconds later. The main
/// connection learns about the change from `XkbMapNotify`, but by the time its (busy, e.g.
/// rendering) loop re-reads the keymap from the server the binding is often already gone,
/// so the press translated to nothing and the character was dropped. This thread fetches
/// the changed keysyms immediately and keeps a short, server-timestamped history; key
/// events whose keycode appears in it are translated with the mapping that was current at
/// the event's time. Only small changes (<= `max_tracked_keys` keycodes, i.e. scratch
/// bindings) are tracked; a whole-layout change clears the history so XKB's own
/// level/group logic applies again.
const MappingWatcher = struct {
    gpa: Allocator,
    conn: *c.xcb_connection_t,
    xkb_base_event: u8,
    thread: std.Thread = undefined,
    lock: std.atomic.Value(bool) = .init(false),
    records: [64]Record = undefined,
    next: usize = 0,
    len: usize = 0,

    const max_tracked_keys = 8;
    const Record = struct { time: u32, keycode: u32, syms: [2]keyboard.Keysym };

    fn start(gpa: Allocator) ?*MappingWatcher {
        var screen: c_int = 0;
        const conn = c.xcb_connect(null, &screen) orelse return null;
        if (c.xcb_connection_has_error(conn) != 0) {
            c.xcb_disconnect(conn);
            return null;
        }
        var major: u16 = 0;
        var minor: u16 = 0;
        var base_event: u8 = 0;
        var base_error: u8 = 0;
        if (c.xkb_x11_setup_xkb_extension(conn, 1, 0, c.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS, &major, &minor, &base_event, &base_error) == 0) {
            c.xcb_disconnect(conn);
            return null;
        }
        const device = c.xkb_x11_get_core_keyboard_device_id(conn);
        const events: u16 = c.XCB_XKB_EVENT_TYPE_MAP_NOTIFY;
        const parts: u16 = c.XCB_XKB_MAP_PART_KEY_SYMS;
        _ = c.xcb_xkb_select_events(conn, @intCast(device), events, 0, events, parts, parts, null);
        _ = c.xcb_flush(conn);
        const self = gpa.create(MappingWatcher) catch {
            c.xcb_disconnect(conn);
            return null;
        };
        self.* = .{ .gpa = gpa, .conn = conn, .xkb_base_event = base_event };
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            c.xcb_disconnect(conn);
            gpa.destroy(self);
            return null;
        };
        return self;
    }

    fn stop(self: *MappingWatcher) void {
        // Wake the blocked xcb_wait_for_event: a shut-down socket reads EOF.
        _ = linux.shutdown(c.xcb_get_file_descriptor(self.conn), linux.SHUT.RDWR);
        self.thread.join();
        c.xcb_disconnect(self.conn);
        self.gpa.destroy(self);
    }

    fn run(self: *MappingWatcher) void {
        while (true) {
            const ev = c.xcb_wait_for_event(self.conn) orelse return;
            defer std.c.free(ev);
            const bytes: [*]const u8 = @ptrCast(ev);
            if ((bytes[0] & 0x7f) != self.xkb_base_event or bytes[1] != XKB_MAP_NOTIFY) continue;
            const e: *const c.xcb_xkb_map_notify_event_t = @ptrCast(@alignCast(ev));
            if (e.changed & c.XCB_XKB_MAP_PART_KEY_SYMS == 0 or e.nKeySyms == 0) continue;
            if (e.nKeySyms > max_tracked_keys) {
                self.acquire();
                self.len = 0;
                self.release();
                continue;
            }
            const reply = c.xcb_get_keyboard_mapping_reply(self.conn, c.xcb_get_keyboard_mapping(self.conn, e.firstKeySym, e.nKeySyms), null) orelse continue;
            defer std.c.free(reply);
            const per: usize = reply.*.keysyms_per_keycode;
            const syms: [*]const u32 = @ptrCast(c.xcb_get_keyboard_mapping_keysyms(reply));
            const have: usize = @intCast(c.xcb_get_keyboard_mapping_keysyms_length(reply));
            self.acquire();
            defer self.release();
            for (0..e.nKeySyms) |i| {
                var r: Record = .{ .time = e.time, .keycode = @as(u32, e.firstKeySym) + @as(u32, @intCast(i)), .syms = .{ 0, 0 } };
                for (0..@min(per, 2)) |l| {
                    const ix = i * per + l;
                    if (ix < have) r.syms[l] = syms[ix];
                }
                self.records[self.next] = r;
                self.next = (self.next + 1) % self.records.len;
                self.len = @min(self.len + 1, self.records.len);
            }
        }
    }

    fn acquire(self: *MappingWatcher) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(self: *MappingWatcher) void {
        self.lock.store(false, .release);
    }

    /// The keysym bound to `keycode` at server time `time`, when the history has a
    /// mapping change for it at or before that time (null: use the keymap).
    fn keysymAt(self: *MappingWatcher, keycode: u32, time: u32, shift: bool) ?keyboard.Keysym {
        self.acquire();
        defer self.release();
        return lookup(self.records[0..], self.next, self.len, keycode, time, shift);
    }

    fn lookup(records: []const Record, next: usize, len: usize, keycode: u32, time: u32, shift: bool) ?keyboard.Keysym {
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const r = records[(next + records.len - 1 - i) % records.len];
            if (r.keycode != keycode) continue;
            // Server time wraps every ~49 days.
            if (@as(i32, @bitCast(time -% r.time)) < 0) continue;
            const sym = if (shift and r.syms[1] != 0) r.syms[1] else r.syms[0];
            return if (sym != 0) sym else null;
        }
        return null;
    }
};

test "MappingWatcher history picks the binding current at the key event's time" {
    var w: MappingWatcher = undefined;
    w.next = 0;
    w.len = 0;
    const put = struct {
        fn f(m: *MappingWatcher, time: u32, kc: u32, sym: keyboard.Keysym) void {
            m.records[m.next] = .{ .time = time, .keycode = kc, .syms = .{ sym, 0 } };
            m.next = (m.next + 1) % m.records.len;
            m.len = @min(m.len + 1, m.records.len);
        }
    }.f;
    // xdotool: bind é at 100, press at 101, unbind at 117; bind 日 at 135 ...
    put(&w, 100, 255, 0xe9);
    put(&w, 117, 255, 0);
    put(&w, 135, 255, 0x10065e5);
    put(&w, 152, 255, 0);
    const L = MappingWatcher.lookup;
    try std.testing.expectEqual(@as(?keyboard.Keysym, 0xe9), L(&w.records, w.next, w.len, 255, 101, false));
    try std.testing.expectEqual(@as(?keyboard.Keysym, 0xe9), L(&w.records, w.next, w.len, 255, 100, false));
    try std.testing.expectEqual(@as(?keyboard.Keysym, null), L(&w.records, w.next, w.len, 255, 120, false)); // released after unbind
    try std.testing.expectEqual(@as(?keyboard.Keysym, 0x10065e5), L(&w.records, w.next, w.len, 255, 136, false));
    try std.testing.expectEqual(@as(?keyboard.Keysym, null), L(&w.records, w.next, w.len, 254, 136, false)); // other keys
    try std.testing.expectEqual(@as(?keyboard.Keysym, null), L(&w.records, w.next, w.len, 255, 50, false)); // before any change
    // Wrapping server time.
    w.len = 0;
    put(&w, 0xffff_fff0, 255, 0xfc);
    try std.testing.expectEqual(@as(?keyboard.Keysym, 0xfc), L(&w.records, w.next, w.len, 255, 5, false));
}

pub const Client = struct {
    gpa: Allocator,
    plat: *LinuxPlatform,
    dpy: *c.Display,
    conn: *c.xcb_connection_t,
    screen: *c.xcb_screen_t,
    atoms: Atoms,
    source: ?*event_loop.Source = null,
    broken: bool = false,
    scale: f32 = 1,
    refresh_ns: u64 = std.time.ns_per_s / 60,

    xkb_base_event: u8 = 0,
    xkb_device: i32 = -1,
    keyboard: keyboard.Keyboard,
    modifiers: input.Modifiers = .{},
    capslock: bool = false,
    last_key: ?u32 = null,

    xi_opcode: ?u8 = null,
    scroll_devices: std.ArrayList(ScrollDevice) = .empty,

    windows: std.ArrayList(*Window) = .empty,
    mouse_focus: ?*Window = null,
    keyboard_focus: ?*Window = null,
    click: common.ClickState = .{},
    root_position: platform.Point = .zero,
    cursor_style: platform.CursorStyle = .arrow,
    cursors: [@typeInfo(platform.CursorStyle).@"enum".field_names.len]u32 = @splat(0),
    cursor_font: u32 = 0,

    clipboard: ?Clipboard = null,
    mapping_watcher: ?*MappingWatcher = null,

    pub fn create(gpa: Allocator, plat: *LinuxPlatform) !*Client {
        const dpy = c.XOpenDisplay(null) orelse return error.X11ConnectFailed;
        errdefer _ = c.XCloseDisplay(dpy);
        const conn = c.XGetXCBConnection(dpy) orelse return error.X11ConnectFailed;
        c.XSetEventQueueOwner(dpy, c.XCBOwnsEventQueue);

        var it = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn));
        var n = c.XDefaultScreen(dpy);
        while (n > 0) : (n -= 1) c.xcb_screen_next(&it);

        const self = try gpa.create(Client);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .plat = plat,
            .dpy = dpy,
            .conn = conn,
            .screen = it.data,
            .atoms = Atoms.intern(conn),
            .keyboard = try keyboard.Keyboard.init(),
        };
        errdefer self.keyboard.deinit();
        self.scale = readXftScale(dpy);
        if (std.c.getenv("ZPUI_X11_REFRESH_HZ")) |hz| {
            const v = std.fmt.parseInt(u64, std.mem.span(hz), 10) catch 60;
            self.refresh_ns = std.time.ns_per_s / @max(v, 1);
        }
        try self.setupXkb();
        self.mapping_watcher = MappingWatcher.start(gpa);
        self.setupXInput();
        self.clipboard = Clipboard.init(gpa, self) catch |e| blk: {
            log.warn("clipboard unavailable: {t}", .{e});
            break :blk null;
        };

        self.source = try plat.loop.addFd(c.xcb_get_file_descriptor(conn), linux.EPOLL.IN, .{ .ctx = self, .func = onReadable });
        plat.loop.hooks = .{ .ctx = self, .before_wait = beforeWait, .after_dispatch = afterDispatch };
        _ = c.xcb_flush(conn);
        return self;
    }

    pub fn destroy(self: *Client) void {
        while (self.windows.items.len > 0) self.windows.items[self.windows.items.len - 1].closeWindow();
        self.windows.deinit(self.gpa);
        if (self.clipboard) |*cb| cb.deinit();
        if (self.source) |s| self.plat.loop.removeFd(s);
        self.plat.loop.hooks = .{};
        self.scroll_devices.deinit(self.gpa);
        if (self.mapping_watcher) |mw| mw.stop();
        self.keyboard.deinit();
        _ = c.XCloseDisplay(self.dpy);
        self.gpa.destroy(self);
    }

    /// Xft.dpi / 96 from the RESOURCE_MANAGER string (gpui reads the same resource).
    fn readXftScale(dpy: *c.Display) f32 {
        if (std.c.getenv("ZPUI_SCALE")) |s| return std.fmt.parseFloat(f32, std.mem.span(s)) catch 1;
        const rm = c.XResourceManagerString(dpy);
        if (rm == null) return 1;
        var lines = std.mem.splitScalar(u8, std.mem.span(rm), '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "Xft.dpi:")) continue;
            const v = std.mem.trim(u8, line["Xft.dpi:".len..], " \t");
            const dpi = std.fmt.parseFloat(f32, v) catch return 1;
            return @max(1, dpi / 96.0);
        }
        return 1;
    }

    fn setupXkb(self: *Client) !void {
        var major: u16 = 0;
        var minor: u16 = 0;
        var base_error: u8 = 0;
        if (c.xkb_x11_setup_xkb_extension(self.conn, 1, 0, c.XKB_X11_SETUP_XKB_EXTENSION_NO_FLAGS, &major, &minor, &self.xkb_base_event, &base_error) == 0)
            return error.XkbUnavailable;
        self.xkb_device = c.xkb_x11_get_core_keyboard_device_id(self.conn);
        try self.reloadKeymap();
        const events: u16 = c.XCB_XKB_EVENT_TYPE_NEW_KEYBOARD_NOTIFY | c.XCB_XKB_EVENT_TYPE_MAP_NOTIFY | c.XCB_XKB_EVENT_TYPE_STATE_NOTIFY;
        const map_parts: u16 = c.XCB_XKB_MAP_PART_KEY_TYPES | c.XCB_XKB_MAP_PART_KEY_SYMS | c.XCB_XKB_MAP_PART_MODIFIER_MAP |
            c.XCB_XKB_MAP_PART_EXPLICIT_COMPONENTS | c.XCB_XKB_MAP_PART_KEY_ACTIONS | c.XCB_XKB_MAP_PART_VIRTUAL_MODS | c.XCB_XKB_MAP_PART_VIRTUAL_MOD_MAP;
        _ = c.xcb_xkb_select_events(self.conn, @intCast(self.xkb_device), events, 0, events, map_parts, map_parts, null);
        // Held keys repeat as press, press, ..., release (no synthetic releases).
        const flag = c.XCB_XKB_PER_CLIENT_FLAG_DETECTABLE_AUTO_REPEAT;
        const reply = c.xcb_xkb_per_client_flags_reply(self.conn, c.xcb_xkb_per_client_flags(self.conn, @intCast(self.xkb_device), flag, flag, 0, 0, 0), null);
        if (reply != null) std.c.free(reply);
    }

    fn reloadKeymap(self: *Client) !void {
        const keymap = c.xkb_x11_keymap_new_from_device(self.keyboard.context, self.conn, self.xkb_device, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.XkbKeymap;
        if (self.keyboard.state) |old| {
            // Keep the modifier/layout state we have tracked through the event stream. The
            // server's current state is ahead of the events still queued (e.g. Shift
            // already down for the next `xdotool type` character), and queued
            // XkbStateNotify events bring ours up to date in order.
            const depressed = c.xkb_state_serialize_mods(old, c.XKB_STATE_MODS_DEPRESSED);
            const latched = c.xkb_state_serialize_mods(old, c.XKB_STATE_MODS_LATCHED);
            const locked = c.xkb_state_serialize_mods(old, c.XKB_STATE_MODS_LOCKED);
            const l_dep = c.xkb_state_serialize_layout(old, c.XKB_STATE_LAYOUT_DEPRESSED);
            const l_lat = c.xkb_state_serialize_layout(old, c.XKB_STATE_LAYOUT_LATCHED);
            const l_lock = c.xkb_state_serialize_layout(old, c.XKB_STATE_LAYOUT_LOCKED);
            try self.keyboard.setKeymap(keymap, null);
            self.keyboard.updateMask(depressed, latched, locked, l_dep, l_lat, l_lock);
        } else {
            const state = c.xkb_x11_state_new_from_device(keymap, self.conn, self.xkb_device);
            try self.keyboard.setKeymap(keymap, state);
        }
        self.modifiers = self.keyboard.modifiers();
    }

    fn setupXInput(self: *Client) void {
        if (std.c.getenv("ZPUI_X11_NO_XI2") != null) return;
        var opcode: c_int = 0;
        var ev: c_int = 0;
        var err: c_int = 0;
        if (c.XQueryExtension(self.dpy, "XInputExtension", &opcode, &ev, &err) == 0) return;
        var major: c_int = 2;
        var minor: c_int = 1;
        if (c.XIQueryVersion(self.dpy, &major, &minor) != 0 or (major == 2 and minor < 1)) return;
        self.xi_opcode = @intCast(opcode);
        self.refreshScrollDevices();
    }

    /// Scroll valuators per slave device (gpui `current_pointer_device_states`).
    fn refreshScrollDevices(self: *Client) void {
        self.scroll_devices.clearRetainingCapacity();
        var count: c_int = 0;
        const infos = c.XIQueryDevice(self.dpy, c.XIAllDevices, &count);
        if (infos == null) return;
        defer c.XIFreeDeviceInfo(infos);
        for (infos[0..@intCast(count)]) |info| {
            var dev: ScrollDevice = .{ .id = @intCast(info.deviceid) };
            var any = false;
            for (info.classes[0..@intCast(info.num_classes)]) |cls| {
                if (cls.*.type != c.XIScrollClass) continue;
                const sc: *const c.XIScrollClassInfo = @ptrCast(@alignCast(cls));
                const axis: common.XiScrollAxis = .{
                    .valuator = @intCast(sc.number),
                    .multiplier = common.scroll_lines / @as(f32, @floatCast(if (sc.increment != 0) sc.increment else 1)),
                };
                if (sc.scroll_type == c.XIScrollTypeVertical) dev.vertical = axis else dev.horizontal = axis;
                any = true;
            }
            if (any) self.scroll_devices.append(self.gpa, dev) catch {};
        }
    }

    fn scrollDevice(self: *Client, id: u16) ?*ScrollDevice {
        for (self.scroll_devices.items) |*d| if (d.id == id) return d;
        return null;
    }

    fn resetScrollPositions(self: *Client) void {
        for (self.scroll_devices.items) |*d| {
            d.vertical.last = null;
            d.horizontal.last = null;
        }
    }

    // -- event loop integration ---------------------------------------------------------

    fn beforeWait(ctx: ?*anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        // Events may already sit in xcb's buffer (read while waiting for a reply).
        self.drain(c.xcb_poll_for_queued_event);
        _ = c.xcb_flush(self.conn);
    }

    fn onReadable(ctx: ?*anyopaque, _: u32) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        self.drain(c.xcb_poll_for_event);
    }

    fn afterDispatch(ctx: ?*anyopaque) void {
        const self: *Client = @ptrCast(@alignCast(ctx.?));
        self.drain(c.xcb_poll_for_queued_event);
        _ = c.xcb_flush(self.conn);
    }

    fn drain(self: *Client, comptime poll_fn: anytype) void {
        if (self.broken) return;
        while (true) {
            const ev = poll_fn(self.conn);
            if (ev == null) break;
            defer std.c.free(ev);
            self.handleEvent(@ptrCast(ev));
        }
        if (c.xcb_connection_has_error(self.conn) != 0) {
            self.broken = true;
            log.err("X11 connection lost", .{});
            self.plat.requestQuit();
        }
    }

    fn windowFor(self: *Client, xid: u32) ?*Window {
        for (self.windows.items) |w| if (w.xid == xid) return w;
        return null;
    }

    fn logical(self: *const Client, v: f32) f32 {
        return v / self.scale;
    }

    fn handleEvent(self: *Client, ev: [*]const u8) void {
        const kind = ev[0] & 0x7f;
        if (kind == 0) {
            const code = ev[1];
            const major = ev[10];
            log.debug("X error {d} (request {d})", .{ code, major });
            return;
        }
        if (kind == self.xkb_base_event) return self.handleXkbEvent(ev);
        switch (kind) {
            KEY_PRESS, KEY_RELEASE => {
                const e: *const c.xcb_key_press_event_t = @ptrCast(@alignCast(ev));
                const w = self.windowFor(e.event) orelse return;
                self.handleKey(w, e.detail, kind == KEY_PRESS, e.time);
            },
            BUTTON_PRESS, BUTTON_RELEASE => {
                const e: *const c.xcb_button_press_event_t = @ptrCast(@alignCast(ev));
                const w = self.windowFor(e.event) orelse return;
                self.root_position = .{ .x = @floatFromInt(e.root_x), .y = @floatFromInt(e.root_y) };
                const pos: platform.Point = .{ .x = self.logical(@floatFromInt(e.event_x)), .y = self.logical(@floatFromInt(e.event_y)) };
                self.handleButton(w, e.detail, kind == BUTTON_PRESS, pos, modifiersFromMask(e.state), false);
            },
            MOTION_NOTIFY => {
                const e: *const c.xcb_motion_notify_event_t = @ptrCast(@alignCast(ev));
                const w = self.windowFor(e.event) orelse return;
                self.root_position = .{ .x = @floatFromInt(e.root_x), .y = @floatFromInt(e.root_y) };
                const pos: platform.Point = .{ .x = self.logical(@floatFromInt(e.event_x)), .y = self.logical(@floatFromInt(e.event_y)) };
                w.common.mouse_position = pos;
                w.common.handleInput(.{ .mouse_move = .{ .position = pos, .pressed_button = pressedButtonFromMask(e.state), .modifiers = modifiersFromMask(e.state) } });
            },
            ENTER_NOTIFY, LEAVE_NOTIFY => {
                const e: *const c.xcb_enter_notify_event_t = @ptrCast(@alignCast(ev));
                const w = self.windowFor(e.event) orelse return;
                const pos: platform.Point = .{ .x = self.logical(@floatFromInt(e.event_x)), .y = self.logical(@floatFromInt(e.event_y)) };
                self.handleCrossing(w, kind == ENTER_NOTIFY, pos, modifiersFromMask(e.state), pressedButtonFromMask(e.state));
            },
            FOCUS_IN, FOCUS_OUT => {
                const e: *const c.xcb_focus_in_event_t = @ptrCast(@alignCast(ev));
                // NotifyPointer (5) focus events describe the pointer, not our window.
                if (e.detail == 5) return;
                const w = self.windowFor(e.event) orelse return;
                if (kind == FOCUS_IN) {
                    self.keyboard_focus = w;
                    if (!w.common.active) w.common.setActive(true);
                } else {
                    if (self.keyboard_focus == w) self.keyboard_focus = null;
                    self.last_key = null;
                    self.keyboard.resetCompose();
                    w.common.handleIme(.delete_text);
                    if (w.common.active) w.common.setActive(false);
                }
            },
            EXPOSE => {
                const e: *const c.xcb_expose_event_t = @ptrCast(@alignCast(ev));
                if (e.count != 0) return;
                const w = self.windowFor(e.window) orelse return;
                w.mapped = true;
                w.common.requestFrame(true);
            },
            CONFIGURE_NOTIFY => {
                const e: *const c.xcb_configure_notify_event_t = @ptrCast(@alignCast(ev));
                const w = self.windowFor(e.window) orelse return;
                w.handleConfigure(e);
            },
            MAP_NOTIFY => if (self.windowFor(rd(u32, ev, 8))) |w| {
                w.mapped = true;
            },
            UNMAP_NOTIFY => if (self.windowFor(rd(u32, ev, 8))) |w| {
                w.mapped = false;
            },
            PROPERTY_NOTIFY => {
                const e: *const c.xcb_property_notify_event_t = @ptrCast(@alignCast(ev));
                if (e.atom != self.atoms._NET_WM_STATE) return;
                if (self.windowFor(e.window)) |w| w.readWmState();
            },
            CLIENT_MESSAGE => {
                const e: *const c.xcb_client_message_event_t = @ptrCast(@alignCast(ev));
                if (e.type != self.atoms.WM_PROTOCOLS) return;
                const proto = e.data.data32[0];
                if (proto == self.atoms.WM_DELETE_WINDOW) {
                    const w = self.windowFor(e.window) orelse return;
                    if (w.common.shouldClose()) w.closeWindow();
                } else if (proto == self.atoms._NET_WM_PING) {
                    var reply = e.*;
                    reply.window = self.screen.root;
                    _ = c.xcb_send_event(self.conn, 0, self.screen.root, c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT, @ptrCast(&reply));
                }
            },
            MAPPING_NOTIFY => {},
            GENERIC_EVENT => if (self.xi_opcode) |op| if (ev[1] == op) self.handleXiEvent(ev),
            else => {},
        }
    }

    fn handleXkbEvent(self: *Client, ev: [*]const u8) void {
        switch (ev[1]) {
            XKB_STATE_NOTIFY => {
                const e: *const c.xcb_xkb_state_notify_event_t = @ptrCast(@alignCast(ev));
                const old_layout = self.keyboard.layoutIndex();
                self.keyboard.updateMask(e.baseMods, e.latchedMods, e.lockedMods, @bitCast(@as(i32, e.baseGroup)), @bitCast(@as(i32, e.latchedGroup)), e.lockedGroup);
                self.modifiers = self.keyboard.modifiers();
                self.capslock = self.keyboard.capslock();
                if (self.keyboard_focus) |w| {
                    w.common.modifiers = self.modifiers;
                    w.common.handleInput(.{ .modifiers_changed = .{ .modifiers = self.modifiers, .capslock = self.capslock } });
                }
                if (old_layout != self.keyboard.layoutIndex()) self.layoutChanged();
            },
            XKB_MAP_NOTIFY, XKB_NEW_KEYBOARD_NOTIFY => {
                self.reloadKeymap() catch |e| log.err("keymap reload failed: {t}", .{e});
                self.layoutChanged();
            },
            else => {},
        }
    }

    fn layoutChanged(self: *Client) void {
        if (self.plat.callbacks.keyboard_layout_change) |f| f(self.plat.callbacks.ctx);
    }

    fn handleKey(self: *Client, w: *Window, keycode: u32, pressed: bool, time: u32) void {
        const sym = self.keyboard.keysym(keycode);
        // The keycode was remapped around this event (`xdotool type` binds a spare keycode
        // per character and unbinds it right after the press): translate with the
        // mapping in effect at the event's server time, not the keymap we have now.
        const remapped: ?keyboard.Keysym = if (self.mapping_watcher) |mw| mw.keysymAt(keycode, time, self.modifiers.shift) else null;
        if (keyboard.isModifierKey(remapped orelse sym)) return;
        if (pressed) {
            const held = self.last_key == keycode;
            self.last_key = keycode;
            var r: keyboard.PressResult = undefined;
            if (remapped != null and remapped.? != sym) {
                r = .{ .keystroke = self.keyboard.keystrokeForKeysym(self.modifiers, remapped.?, keycode) };
            } else self.keyboard.press(self.modifiers, keycode, &r);
            if (r.ime_insert) |t| w.common.handleIme(.{ .insert_text = t });
            if (r.ime_marked) |t| w.common.handleIme(.{ .set_marked_text = t });
            w.common.handleInput(.{ .key_down = .{ .keystroke = r.keystroke.keystroke(), .is_held = held } });
        } else {
            if (self.last_key == keycode) self.last_key = null;
            const ks = if (remapped != null and remapped.? != sym)
                self.keyboard.keystrokeForKeysym(self.modifiers, remapped.?, keycode)
            else
                self.keyboard.keystroke(self.modifiers, keycode);
            w.common.handleInput(.{ .key_up = .{ .keystroke = ks.keystroke() } });
        }
    }

    fn handleButton(self: *Client, w: *Window, detail: u32, pressed: bool, pos: platform.Point, mods: input.Modifiers, emulated: bool) void {
        w.common.mouse_position = pos;
        if (detail >= 4 and detail <= 7) {
            // XI2 smooth scrolling already delivered emulated wheel clicks as valuator motion.
            if (!pressed or emulated) return;
            const d = common.x11ButtonScroll(@intCast(detail), mods.shift).?;
            w.common.handleInput(.{ .scroll_wheel = .{ .position = pos, .delta = .{ .lines = d }, .modifiers = mods } });
            return;
        }
        const b = common.x11Button(@intCast(@min(detail, 255))) orelse return;
        if (pressed) {
            const count = self.click.press(b, pos, event_loop.monotonicNow());
            w.common.handleInput(.{ .mouse_down = .{ .button = b, .position = pos, .modifiers = mods, .click_count = count } });
        } else {
            w.common.handleInput(.{ .mouse_up = .{ .button = b, .position = pos, .modifiers = mods, .click_count = self.click.count } });
        }
    }

    fn handleCrossing(self: *Client, w: *Window, entered: bool, pos: platform.Point, mods: input.Modifiers, pressed: ?input.MouseButton) void {
        w.common.mouse_position = pos;
        if (entered) {
            self.mouse_focus = w;
            w.applyCursor(self.cursor_style);
            w.common.setHovered(true);
            w.common.handleInput(.{ .mouse_move = .{ .position = pos, .pressed_button = pressed, .modifiers = mods } });
        } else {
            // Valuators are global: avoid a huge delta when scrolling resumes elsewhere.
            self.resetScrollPositions();
            if (self.mouse_focus == w) self.mouse_focus = null;
            w.common.handleInput(.{ .mouse_exited = .{ .position = pos, .pressed_button = pressed, .modifiers = mods } });
            w.common.setHovered(false);
        }
    }

    fn handleXiEvent(self: *Client, ev: [*]const u8) void {
        const evtype = rd(u16, ev, 8);
        switch (evtype) {
            c.XI_Motion, c.XI_ButtonPress, c.XI_ButtonRelease => {
                const e = parseXiDeviceEvent(ev);
                const w = self.windowFor(e.event) orelse return;
                self.root_position = .{ .x = e.root_x, .y = e.root_y };
                const pos: platform.Point = .{ .x = self.logical(e.event_x), .y = self.logical(e.event_y) };
                const mods = modifiersFromMask(e.mods_effective);
                if (evtype == c.XI_Motion) {
                    const pressed: ?input.MouseButton = if (e.buttonDown(1)) .left else if (e.buttonDown(2)) .middle else if (e.buttonDown(3)) .right else null;
                    // Valuators 0/1 are x/y; anything else is a pure scroll update.
                    if (e.valuator_mask.len > 0 and e.valuator_mask[0] & 3 != 0) {
                        w.common.mouse_position = pos;
                        w.common.handleInput(.{ .mouse_move = .{ .position = pos, .pressed_button = pressed, .modifiers = mods } });
                    }
                    if (self.scrollDevice(e.sourceid)) |dev| {
                        var delta: ?platform.Point = null;
                        if (dev.horizontal.valuator) |v| if (e.valuator(v)) |val| if (dev.horizontal.update(val)) |d| {
                            delta = .{ .x = d, .y = if (delta) |p| p.y else 0 };
                        };
                        if (dev.vertical.valuator) |v| if (e.valuator(v)) |val| if (dev.vertical.update(val)) |d| {
                            delta = .{ .x = if (delta) |p| p.x else 0, .y = d };
                        };
                        if (delta) |d| w.common.handleInput(.{ .scroll_wheel = .{ .position = pos, .delta = .{ .lines = common.applyShift(d, mods.shift) }, .modifiers = mods } });
                    }
                } else {
                    const emulated = e.flags & c.XIPointerEmulated != 0;
                    self.handleButton(w, e.detail, evtype == c.XI_ButtonPress, pos, mods, emulated);
                }
            },
            c.XI_Enter, c.XI_Leave => {
                const win = rd(u32, ev, 24);
                const w = self.windowFor(win) orelse return;
                const pos: platform.Point = .{ .x = self.logical(fp1616(rd(i32, ev, geOff(40)))), .y = self.logical(fp1616(rd(i32, ev, geOff(44)))) };
                const mods = modifiersFromMask(rd(u32, ev, geOff(68)));
                self.handleCrossing(w, evtype == c.XI_Enter, pos, mods, null);
            },
            c.XI_DeviceChanged, c.XI_HierarchyChanged => self.refreshScrollDevices(),
            else => {},
        }
    }

    // -- cursors ------------------------------------------------------------------------

    pub fn setCursorStyle(self: *Client, style: platform.CursorStyle) void {
        if (style == self.cursor_style) return;
        self.cursor_style = style;
        if (self.mouse_focus) |w| w.applyCursor(style);
        _ = c.xcb_flush(self.conn);
    }

    fn cursorFor(self: *Client, style: platform.CursorStyle) u32 {
        const slot = &self.cursors[@backingInt(style)];
        if (slot.* != 0) return slot.*;
        if (style == .none) {
            // 1x1 empty pixmap cursor = hidden.
            const pix = c.xcb_generate_id(self.conn);
            _ = c.xcb_create_pixmap(self.conn, 1, pix, self.screen.root, 1, 1);
            const cur = c.xcb_generate_id(self.conn);
            _ = c.xcb_create_cursor(self.conn, cur, pix, pix, 0, 0, 0, 0, 0, 0, 0, 0);
            _ = c.xcb_free_pixmap(self.conn, pix);
            slot.* = cur;
            return cur;
        }
        for (util.cursorNames(style)) |name| {
            const cur = c.XcursorLibraryLoadCursor(self.dpy, name);
            if (cur != 0) {
                slot.* = @intCast(cur);
                return slot.*;
            }
        }
        // Core cursor font fallback.
        if (self.cursor_font == 0) {
            self.cursor_font = c.xcb_generate_id(self.conn);
            _ = c.xcb_open_font(self.conn, self.cursor_font, 6, "cursor");
        }
        const glyph = util.cursorFontGlyph(style);
        const cur = c.xcb_generate_id(self.conn);
        _ = c.xcb_create_glyph_cursor(self.conn, cur, self.cursor_font, self.cursor_font, glyph, glyph + 1, 0, 0, 0, 0xffff, 0xffff, 0xffff);
        slot.* = cur;
        return cur;
    }

    // -- clipboard / displays / windows -------------------------------------------------

    pub fn writeClipboard(self: *Client, text: []const u8) void {
        if (self.clipboard) |*cb| cb.write(text);
    }

    pub fn readClipboard(self: *Client, gpa: Allocator) ?[]u8 {
        return if (self.clipboard) |*cb| cb.read(gpa) else null;
    }

    pub fn displays(self: *Client, out: []platform.Display) usize {
        if (out.len == 0) return 0;
        const b: platform.Bounds = .{ .origin = .zero, .size = .{
            .width = self.logical(@floatFromInt(self.screen.width_in_pixels)),
            .height = self.logical(@floatFromInt(self.screen.height_in_pixels)),
        } };
        out[0] = .{ .id = 0, .bounds = b, .visible_bounds = b, .scale_factor = self.scale };
        return 1;
    }

    pub fn openWindow(self: *Client, params: platform.WindowParams) !platform.Window {
        const w = try Window.create(self, params);
        return w.window();
    }

    fn removeWindow(self: *Client, w: *Window) void {
        for (self.windows.items, 0..) |item, i| if (item == w) {
            _ = self.windows.orderedRemove(i);
            break;
        };
        if (self.mouse_focus == w) self.mouse_focus = null;
        if (self.keyboard_focus == w) self.keyboard_focus = null;
    }

    fn findArgbVisual(self: *Client) ?u32 {
        var dit = c.xcb_screen_allowed_depths_iterator(self.screen);
        while (dit.rem > 0) : (c.xcb_depth_next(&dit)) {
            if (dit.data.*.depth != 32) continue;
            var vit = c.xcb_depth_visuals_iterator(dit.data);
            while (vit.rem > 0) : (c.xcb_visualtype_next(&vit)) {
                if (vit.data.*._class == c.XCB_VISUAL_CLASS_TRUE_COLOR) return vit.data.*.visual_id;
            }
        }
        return null;
    }

    fn setProperty(self: *Client, win: u32, prop: u32, ty: u32, format: u8, data: []const u8) void {
        const elems: u32 = @intCast(data.len / (format / 8));
        _ = c.xcb_change_property(self.conn, c.XCB_PROP_MODE_REPLACE, win, prop, ty, format, elems, data.ptr);
    }

    fn setProperty32(self: *Client, win: u32, prop: u32, ty: u32, values: []const u32) void {
        self.setProperty(win, prop, ty, 32, std.mem.sliceAsBytes(values));
    }

    /// EWMH client message to the root window on behalf of `win`.
    fn sendRootMessage(self: *Client, win: u32, msg_type: u32, data: [5]u32) void {
        var ev: c.xcb_client_message_event_t = .{ .response_type = CLIENT_MESSAGE, .format = 32, .window = win, .type = msg_type };
        ev.data.data32 = data;
        _ = c.xcb_send_event(self.conn, 0, self.screen.root, c.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY | c.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT, @ptrCast(&ev));
        _ = c.xcb_flush(self.conn);
    }
};

pub const Window = struct {
    client: *Client,
    common: common.Common = .{},
    xid: u32,
    colormap: u32 = 0,
    presenter: ?Presenter = null,
    mapped: bool = false,
    origin: platform.Point = .zero,
    frame_timer: ?event_loop.TimerId = null,

    fn create(client: *Client, params: platform.WindowParams) !*Window {
        const gpa = client.gpa;
        const conn = client.conn;
        const transparent = params.background != .opaque_;
        const argb = if (transparent) client.findArgbVisual() else null;
        const depth: u8 = if (argb != null) 32 else client.screen.root_depth;
        const visual = argb orelse client.screen.root_visual;

        const xid = c.xcb_generate_id(conn);
        var colormap: u32 = 0;
        if (argb) |v| {
            colormap = c.xcb_generate_id(conn);
            _ = c.xcb_create_colormap(conn, c.XCB_COLORMAP_ALLOC_NONE, colormap, client.screen.root, v);
        }
        const event_mask: u32 = c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_STRUCTURE_NOTIFY | c.XCB_EVENT_MASK_FOCUS_CHANGE |
            c.XCB_EVENT_MASK_KEY_PRESS | c.XCB_EVENT_MASK_KEY_RELEASE | c.XCB_EVENT_MASK_BUTTON_PRESS | c.XCB_EVENT_MASK_BUTTON_RELEASE |
            c.XCB_EVENT_MASK_POINTER_MOTION | c.XCB_EVENT_MASK_ENTER_WINDOW | c.XCB_EVENT_MASK_LEAVE_WINDOW | c.XCB_EVENT_MASK_PROPERTY_CHANGE;
        // Value order follows the CW bit order: BACK_PIXEL, BORDER_PIXEL, EVENT_MASK, COLORMAP.
        var values: [4]u32 = .{ 0, 0, event_mask, colormap };
        var mask: u32 = c.XCB_CW_BACK_PIXEL | c.XCB_CW_BORDER_PIXEL | c.XCB_CW_EVENT_MASK;
        if (argb != null) mask |= c.XCB_CW_COLORMAP;

        const scale = client.scale;
        const dw: u16 = @intFromFloat(@max(1, @round(params.bounds.size.width * scale)));
        const dh: u16 = @intFromFloat(@max(1, @round(params.bounds.size.height * scale)));
        _ = c.xcb_create_window(conn, depth, xid, client.screen.root, @intFromFloat(params.bounds.origin.x * scale), @intFromFloat(params.bounds.origin.y * scale), dw, dh, 0, c.XCB_WINDOW_CLASS_INPUT_OUTPUT, visual, mask, &values);

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{ .client = client, .xid = xid, .colormap = colormap, .origin = params.bounds.origin };
        self.common.size = params.bounds.size;
        self.common.scale = scale;
        self.common.background = params.background;

        const a = &client.atoms;
        client.setProperty32(xid, a.WM_PROTOCOLS, ATOM_ATOM, &.{ a.WM_DELETE_WINDOW, a._NET_WM_PING });
        client.setProperty32(xid, a._NET_WM_PID, ATOM_CARDINAL, &.{@intCast(linux.getpid())});
        client.setProperty32(xid, a._NET_WM_WINDOW_TYPE, ATOM_ATOM, &.{a._NET_WM_WINDOW_TYPE_NORMAL});
        if (params.titlebar) |tb| self.setTitleImpl(tb.title);
        const app_id = params.app_id orelse "zpui";
        var class_buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&class_buf, "{s}\x00{s}\x00", .{ app_id, app_id })) |cls| client.setProperty(xid, ATOM_WM_CLASS, ATOM_STRING, 8, cls) else |_| {}
        if (params.decorations == .client) {
            // _MOTIF_WM_HINTS { flags = DECORATIONS, functions, decorations = 0, input_mode, status }
            client.setProperty32(xid, a._MOTIF_WM_HINTS, a._MOTIF_WM_HINTS, &.{ 2, 0, 0, 0, 0 });
        }
        self.setSizeHints(params.min_size);

        if (client.xi_opcode != null) {
            var bits: [4]u8 = @splat(0);
            for ([_]c_int{ c.XI_Motion, c.XI_ButtonPress, c.XI_ButtonRelease, c.XI_Enter, c.XI_Leave }) |t| bits[@intCast(@divTrunc(t, 8))] |= @as(u8, 1) << @intCast(@mod(t, 8));
            var m: c.XIEventMask = .{ .deviceid = c.XIAllMasterDevices, .mask_len = bits.len, .mask = &bits };
            _ = c.XISelectEvents(client.dpy, xid, &m, 1);
            var dbits: [4]u8 = @splat(0);
            for ([_]c_int{ c.XI_DeviceChanged, c.XI_HierarchyChanged }) |t| dbits[@intCast(@divTrunc(t, 8))] |= @as(u8, 1) << @intCast(@mod(t, 8));
            var dm: c.XIEventMask = .{ .deviceid = c.XIAllDevices, .mask_len = dbits.len, .mask = &dbits };
            _ = c.XISelectEvents(client.dpy, xid, &dm, 1);
            _ = c.XFlush(client.dpy);
        }

        try client.windows.append(gpa, self);
        errdefer _ = client.windows.pop();
        if (params.show) _ = c.xcb_map_window(conn, xid);
        _ = c.xcb_flush(conn);

        self.presenter = Presenter.init(gpa, .{ .xcb = .{ .connection = conn, .window = xid } }, dw, dh, transparent) catch |e| blk: {
            log.err("renderer init failed: {t}; window will not draw", .{e});
            break :blk null;
        };
        return self;
    }

    fn setSizeHints(self: *Window, min_size: ?platform.Size) void {
        // WM_SIZE_HINTS: flags, pad[4], min_w, min_h, max_w, max_h, inc_w, inc_h, aspect[4], base_w, base_h, gravity.
        var hints: [18]u32 = @splat(0);
        hints[0] = 1 | 4; // USPosition | PPosition
        if (min_size) |m| {
            hints[0] |= 16; // PMinSize
            hints[5] = @intFromFloat(m.width * self.client.scale);
            hints[6] = @intFromFloat(m.height * self.client.scale);
        }
        self.client.setProperty32(self.xid, ATOM_WM_NORMAL_HINTS, ATOM_WM_SIZE_HINTS, &hints);
    }

    fn setTitleImpl(self: *Window, title: []const u8) void {
        const a = &self.client.atoms;
        self.client.setProperty(self.xid, a._NET_WM_NAME, a.UTF8_STRING, 8, title);
        self.client.setProperty(self.xid, ATOM_WM_NAME, ATOM_STRING, 8, title);
        _ = c.xcb_flush(self.client.conn);
    }

    fn closeWindow(self: *Window) void {
        const client = self.client;
        client.removeWindow(self);
        if (self.frame_timer) |t| client.plat.loop.cancelTimer(t);
        if (self.presenter) |*p| p.deinit(client.gpa);
        _ = c.xcb_destroy_window(client.conn, self.xid);
        if (self.colormap != 0) _ = c.xcb_free_colormap(client.conn, self.colormap);
        _ = c.xcb_flush(client.conn);
        self.common.notifyClosed();
        client.gpa.destroy(self);
    }

    fn handleConfigure(self: *Window, e: *const c.xcb_configure_notify_event_t) void {
        const client = self.client;
        const size: platform.Size = .{ .width = client.logical(@floatFromInt(e.width)), .height = client.logical(@floatFromInt(e.height)) };
        const origin: platform.Point = .{ .x = client.logical(@floatFromInt(e.x)), .y = client.logical(@floatFromInt(e.y)) };
        if (origin.x != self.origin.x or origin.y != self.origin.y) {
            self.origin = origin;
            self.common.moved();
        }
        if (self.common.setSizeAndScale(size, client.scale) and self.mapped) self.common.requestFrame(true);
    }

    fn readWmState(self: *Window) void {
        const client = self.client;
        const a = &client.atoms;
        const reply = c.xcb_get_property_reply(client.conn, c.xcb_get_property(client.conn, 0, self.xid, a._NET_WM_STATE, ATOM_ATOM, 0, 64), null);
        if (reply == null) return;
        defer std.c.free(reply);
        const n: usize = @intCast(@divTrunc(c.xcb_get_property_value_length(reply), 4));
        const vals: [*]const u32 = @ptrCast(@alignCast(c.xcb_get_property_value(reply) orelse return));
        var max_v = false;
        var max_h = false;
        var full = false;
        for (vals[0..n]) |v| {
            if (v == a._NET_WM_STATE_MAXIMIZED_VERT) max_v = true;
            if (v == a._NET_WM_STATE_MAXIMIZED_HORZ) max_h = true;
            if (v == a._NET_WM_STATE_FULLSCREEN) full = true;
        }
        self.common.maximized = max_v and max_h;
        self.common.fullscreen = full;
    }

    fn applyCursor(self: *Window, style: platform.CursorStyle) void {
        const cur = self.client.cursorFor(style);
        _ = c.xcb_change_window_attributes(self.client.conn, self.xid, c.XCB_CW_CURSOR, &cur);
    }

    /// _NET_WM_STATE add/remove/toggle (action 0/1/2).
    fn changeWmState(self: *Window, action: u32, a1: u32, a2: u32) void {
        self.client.sendRootMessage(self.xid, self.client.atoms._NET_WM_STATE, .{ action, a1, a2, 1, 0 });
    }

    fn onFrameTimer(ctx: ?*anyopaque, _: event_loop.TimerId) void {
        const self: *Window = @ptrCast(@alignCast(ctx.?));
        self.frame_timer = null;
        self.common.requestFrame(false);
    }

    // -- platform.Window vtable ---------------------------------------------------------

    fn window(self: *Window) platform.Window {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ptr: *anyopaque) *Window {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable: platform.Window.VTable = .{
        .setCallbacks = setCallbacks,
        .bounds = bounds,
        .contentSize = contentSize,
        .resize = resize,
        .scaleFactor = scaleFactor,
        .appearance = appearance,
        .mousePosition = mousePosition,
        .modifiers = modifiersFn,
        .isActive = isActive,
        .isHovered = isHovered,
        .isFullscreen = isFullscreen,
        .isMaximized = isMaximized,
        .setInputHandler = setInputHandler,
        .setTitle = setTitle,
        .setBackgroundAppearance = setBackgroundAppearance,
        .activate = activate,
        .minimize = minimize,
        .zoom = zoom,
        .toggleFullscreen = toggleFullscreen,
        .startWindowMove = startWindowMove,
        .startWindowResize = startWindowResize,
        .setClientInset = setClientInset,
        .requestFrame = requestFrame,
        .draw = draw,
        .spriteAtlas = spriteAtlas,
        .updateImePosition = updateImePosition,
        .close = close,
    };

    fn setCallbacks(ptr: *anyopaque, cbs: platform.WindowCallbacks) void {
        cast(ptr).common.callbacks = cbs;
    }
    fn bounds(ptr: *anyopaque) platform.Bounds {
        const self = cast(ptr);
        return .{ .origin = self.origin, .size = self.common.size };
    }
    fn contentSize(ptr: *anyopaque) platform.Size {
        return cast(ptr).common.size;
    }
    fn resize(ptr: *anyopaque, size: platform.Size) void {
        const self = cast(ptr);
        const s = self.client.scale;
        const vals = [_]u32{ @intFromFloat(@max(1, size.width * s)), @intFromFloat(@max(1, size.height * s)) };
        _ = c.xcb_configure_window(self.client.conn, self.xid, c.XCB_CONFIG_WINDOW_WIDTH | c.XCB_CONFIG_WINDOW_HEIGHT, &vals);
        _ = c.xcb_flush(self.client.conn);
    }
    fn scaleFactor(ptr: *anyopaque) f32 {
        return cast(ptr).common.scale;
    }
    fn appearance(_: *anyopaque) platform.WindowAppearance {
        return .light;
    }
    fn mousePosition(ptr: *anyopaque) platform.Point {
        return cast(ptr).common.mouse_position;
    }
    fn modifiersFn(ptr: *anyopaque) input.Modifiers {
        return cast(ptr).client.modifiers;
    }
    fn isActive(ptr: *anyopaque) bool {
        return cast(ptr).common.active;
    }
    fn isHovered(ptr: *anyopaque) bool {
        return cast(ptr).common.hovered;
    }
    fn isFullscreen(ptr: *anyopaque) bool {
        return cast(ptr).common.fullscreen;
    }
    fn isMaximized(ptr: *anyopaque) bool {
        return cast(ptr).common.maximized;
    }
    fn setInputHandler(ptr: *anyopaque, h: ?platform.InputHandler) void {
        cast(ptr).common.input_handler = h;
    }
    fn setTitle(ptr: *anyopaque, title: []const u8) void {
        cast(ptr).setTitleImpl(title);
    }
    fn setBackgroundAppearance(ptr: *anyopaque, bg: platform.WindowBackgroundAppearance) void {
        // The visual is fixed at creation; blur needs a compositor protocol X11 lacks.
        cast(ptr).common.background = bg;
    }
    fn activate(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.client.sendRootMessage(self.xid, self.client.atoms._NET_ACTIVE_WINDOW, .{ 1, 0, 0, 0, 0 });
    }
    fn minimize(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.client.sendRootMessage(self.xid, self.client.atoms.WM_CHANGE_STATE, .{ 3, 0, 0, 0, 0 }); // IconicState
    }
    fn zoom(ptr: *anyopaque) void {
        const self = cast(ptr);
        const a = &self.client.atoms;
        self.changeWmState(2, a._NET_WM_STATE_MAXIMIZED_VERT, a._NET_WM_STATE_MAXIMIZED_HORZ);
    }
    fn toggleFullscreen(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.changeWmState(2, self.client.atoms._NET_WM_STATE_FULLSCREEN, 0);
    }
    fn moveResize(self: *Window, direction: u32) void {
        const client = self.client;
        // The WM takes over the pointer grab started by our button press.
        _ = c.xcb_ungrab_pointer(client.conn, 0);
        client.sendRootMessage(self.xid, client.atoms._NET_WM_MOVERESIZE, .{
            @intFromFloat(client.root_position.x), @intFromFloat(client.root_position.y), direction, 1, 1,
        });
    }
    fn startWindowMove(ptr: *anyopaque) void {
        cast(ptr).moveResize(8); // _NET_WM_MOVERESIZE_MOVE
    }
    fn startWindowResize(ptr: *anyopaque, edge: platform.ResizeEdge) void {
        cast(ptr).moveResize(switch (edge) {
            .top_left => 0,
            .top => 1,
            .top_right => 2,
            .right => 3,
            .bottom_right => 4,
            .bottom => 5,
            .bottom_left => 6,
            .left => 7,
        });
    }
    fn setClientInset(ptr: *anyopaque, inset: f32) void {
        // Tell compositing WMs which part of the window is shadow (gpui `_GTK_FRAME_EXTENTS`).
        const self = cast(ptr);
        const i: u32 = @intFromFloat(inset * self.client.scale);
        self.client.setProperty32(self.xid, self.client.atoms._GTK_FRAME_EXTENTS, ATOM_CARDINAL, &.{ i, i, i, i });
        _ = c.xcb_flush(self.client.conn);
    }
    fn requestFrame(ptr: *anyopaque) void {
        // No vsync event on X11 without Present: tick at the refresh rate (the FIFO
        // swapchain still paces the actual presents).
        const self = cast(ptr);
        if (self.frame_timer != null) return;
        self.frame_timer = self.client.plat.loop.addTimer(self.client.refresh_ns, .{ .ctx = self, .func = onFrameTimer }) catch null;
    }
    fn draw(ptr: *anyopaque, scene: *const scene_mod.Scene) anyerror!void {
        const self = cast(ptr);
        const p = if (self.presenter) |*p| p else return error.NoRenderer;
        const dev = self.common.deviceSize();
        try p.draw(scene, dev.width, dev.height, self.common.scale);
    }
    fn spriteAtlas(ptr: *anyopaque) *atlas_mod.Atlas {
        const self = cast(ptr);
        if (self.presenter) |*p| return p.atlas();
        @panic("window has no renderer");
    }
    fn updateImePosition(_: *anyopaque, _: platform.Bounds) void {}
    fn close(ptr: *anyopaque) void {
        cast(ptr).closeWindow();
    }
};

/// CLIPBOARD selection on its own XCB connection (like gpui's x11 clipboard thread), so
/// a blocking read never has to pump or reorder the main connection's events.
const Clipboard = struct {
    gpa: Allocator,
    client: *Client,
    conn: *c.xcb_connection_t,
    window: u32,
    atoms: Atoms,
    source: ?*event_loop.Source = null,
    text: ?[]u8 = null,

    fn init(gpa: Allocator, client: *Client) !Clipboard {
        const conn = c.xcb_connect(null, null) orelse return error.X11ConnectFailed;
        if (c.xcb_connection_has_error(conn) != 0) {
            c.xcb_disconnect(conn);
            return error.X11ConnectFailed;
        }
        var it = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn));
        const win = c.xcb_generate_id(conn);
        const mask: u32 = c.XCB_EVENT_MASK_PROPERTY_CHANGE;
        _ = c.xcb_create_window(conn, 0, win, it.data.*.root, 0, 0, 1, 1, 0, c.XCB_WINDOW_CLASS_INPUT_ONLY, 0, c.XCB_CW_EVENT_MASK, &mask);
        var self: Clipboard = .{ .gpa = gpa, .client = client, .conn = conn, .window = win, .atoms = Atoms.intern(conn) };
        _ = c.xcb_flush(conn);
        self.source = client.plat.loop.addFd(c.xcb_get_file_descriptor(conn), linux.EPOLL.IN, .{ .ctx = client, .func = onReadable }) catch null;
        _ = &it;
        return self;
    }

    fn deinit(self: *Clipboard) void {
        if (self.source) |s| self.client.plat.loop.removeFd(s);
        if (self.text) |t| self.gpa.free(t);
        c.xcb_disconnect(self.conn);
    }

    fn onReadable(ctx: ?*anyopaque, _: u32) void {
        const client: *Client = @ptrCast(@alignCast(ctx.?));
        const self = if (client.clipboard) |*cb| cb else return;
        while (true) {
            const ev = c.xcb_poll_for_event(self.conn);
            if (ev == null) break;
            defer std.c.free(ev);
            self.handleEvent(@ptrCast(ev));
        }
        _ = c.xcb_flush(self.conn);
    }

    fn handleEvent(self: *Clipboard, ev: [*]const u8) void {
        switch (ev[0] & 0x7f) {
            SELECTION_REQUEST => self.serve(@ptrCast(@alignCast(ev))),
            SELECTION_CLEAR => {
                if (self.text) |t| self.gpa.free(t);
                self.text = null;
            },
            else => {},
        }
    }

    fn serve(self: *Clipboard, req: *const c.xcb_selection_request_event_t) void {
        const a = &self.atoms;
        var property = if (req.property == 0) req.target else req.property;
        if (self.text) |text| {
            if (req.target == a.TARGETS) {
                const targets = [_]u32{ a.TARGETS, a.UTF8_STRING, a.TEXT_PLAIN_UTF8, ATOM_STRING, a.TEXT };
                _ = c.xcb_change_property(self.conn, c.XCB_PROP_MODE_REPLACE, req.requestor, property, ATOM_ATOM, 32, targets.len, &targets);
            } else if (req.target == a.UTF8_STRING or req.target == a.TEXT_PLAIN_UTF8 or req.target == ATOM_STRING or req.target == a.TEXT) {
                // TODO: INCR for payloads larger than the server's max request size.
                _ = c.xcb_change_property(self.conn, c.XCB_PROP_MODE_REPLACE, req.requestor, property, req.target, 8, @intCast(text.len), text.ptr);
            } else property = 0;
        } else property = 0;
        var notify: c.xcb_selection_notify_event_t = .{
            .response_type = SELECTION_NOTIFY,
            .time = req.time,
            .requestor = req.requestor,
            .selection = req.selection,
            .target = req.target,
            .property = property,
        };
        _ = c.xcb_send_event(self.conn, 0, req.requestor, 0, @ptrCast(&notify));
        _ = c.xcb_flush(self.conn);
    }

    fn write(self: *Clipboard, text: []const u8) void {
        const copy = self.gpa.dupe(u8, text) catch return;
        if (self.text) |t| self.gpa.free(t);
        self.text = copy;
        _ = c.xcb_set_selection_owner(self.conn, self.window, self.atoms.CLIPBOARD, 0);
        _ = c.xcb_flush(self.conn);
    }

    fn read(self: *Clipboard, gpa: Allocator) ?[]u8 {
        if (self.text) |t| return gpa.dupe(u8, t) catch null;
        const a = &self.atoms;
        _ = c.xcb_convert_selection(self.conn, self.window, a.CLIPBOARD, a.UTF8_STRING, a._ZPUI_SELECTION, 0);
        _ = c.xcb_flush(self.conn);
        const deadline = event_loop.monotonicNow() + @as(u64, @intCast(util.read_timeout_ms)) * std.time.ns_per_ms;
        const fd = c.xcb_get_file_descriptor(self.conn);
        while (event_loop.monotonicNow() < deadline) {
            while (true) {
                const ev = c.xcb_poll_for_event(self.conn);
                if (ev == null) break;
                defer std.c.free(ev);
                const bytes: [*]const u8 = @ptrCast(ev);
                if (bytes[0] & 0x7f == SELECTION_NOTIFY) {
                    const n: *const c.xcb_selection_notify_event_t = @ptrCast(@alignCast(bytes));
                    if (n.property == 0) return null;
                    return self.takeProperty(gpa);
                }
                self.handleEvent(bytes);
            }
            if (c.xcb_connection_has_error(self.conn) != 0) return null;
            var pfd = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&pfd, 1, 50);
        }
        return null;
    }

    fn takeProperty(self: *Clipboard, gpa: Allocator) ?[]u8 {
        const reply = c.xcb_get_property_reply(self.conn, c.xcb_get_property(self.conn, 1, self.window, self.atoms._ZPUI_SELECTION, 0, 0, std.math.maxInt(u32) / 4), null);
        if (reply == null) return null;
        defer std.c.free(reply);
        if (reply.*.type == self.atoms.INCR) return null; // TODO: incremental transfers
        const len: usize = @intCast(c.xcb_get_property_value_length(reply));
        const ptr: [*]const u8 = @ptrCast(c.xcb_get_property_value(reply) orelse return null);
        return gpa.dupe(u8, ptr[0..len]) catch null;
    }
};

// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "parseXiDeviceEvent decodes the xcb GenericEvent layout" {
    // XI_Motion with 1 button-mask word and 1 valuator-mask word, valuators 0, 1 and 3 set.
    var buf: [128]u8 align(4) = @splat(0);
    buf[0] = GENERIC_EVENT;
    std.mem.writeInt(u16, buf[8..10], c.XI_Motion, .little);
    std.mem.writeInt(u16, buf[10..12], 2, .little); // deviceid
    std.mem.writeInt(u32, buf[24..28], 0x400001, .little); // event window
    std.mem.writeInt(i32, buf[geOff(40)..][0..4], 100 << 16, .little); // event_x = 100.0
    std.mem.writeInt(i32, buf[geOff(44)..][0..4], (50 << 16) | 0x8000, .little); // event_y = 50.5
    std.mem.writeInt(u16, buf[geOff(48)..][0..2], 1, .little); // buttons_len
    std.mem.writeInt(u16, buf[geOff(50)..][0..2], 1, .little); // valuators_len
    std.mem.writeInt(u16, buf[geOff(52)..][0..2], 11, .little); // sourceid
    std.mem.writeInt(u32, buf[geOff(72)..][0..4], 1 | 4, .little); // shift+ctrl
    const masks = geOff(80);
    buf[masks] = 0b10; // button 1 down
    buf[masks + 4] = 0b1011; // valuators 0, 1, 3
    const vals = masks + 8;
    std.mem.writeInt(i32, buf[vals + 16 ..][0..4], 240, .little); // valuator 3 integral
    std.mem.writeInt(u32, buf[vals + 20 ..][0..4], 0x80000000, .little); // .5

    const e = parseXiDeviceEvent(&buf);
    try testing.expectEqual(@as(u16, c.XI_Motion), e.evtype);
    try testing.expectEqual(@as(u16, 11), e.sourceid);
    try testing.expectEqual(@as(u32, 0x400001), e.event);
    try testing.expectEqual(@as(f32, 100), e.event_x);
    try testing.expectEqual(@as(f32, 50.5), e.event_y);
    try testing.expect(e.buttonDown(1));
    try testing.expect(!e.buttonDown(2));
    try testing.expectEqual(@as(f64, 240.5), e.valuator(3).?);
    try testing.expect(e.valuator(2) == null);
    const m = modifiersFromMask(e.mods_effective);
    try testing.expect(m.shift and m.control and !m.alt);
}
