//! System-wide input monitor for Linux (docs/DESKTOP_OVERLAY.md §2). Observes key and
//! mouse activity, never consumes it, and never derives characters: keycodes become a
//! coarse `GlobalKeyClass` and a left/right position (platform/desktop.zig).
//!
//! Backends, strongest first for the session type:
//!   * XInput2 raw events (`XI_RawKeyPress/Release`, `XI_RawButtonPress/Release`) on the
//!     root window over a dedicated X connection whose fd sits in the epoll loop. X11
//!     sessions; under Wayland it only sees XWayland clients (fallback).
//!   * evdev: every readable `/dev/input/event*` with keyboard or pointer capability, read
//!     non-blocking in fixed-size batches from the epoll loop; an inotify watch on
//!     `/dev/input` picks up hotplugged devices and permission changes. Wayland sessions
//!     (any compositor). Needs read access to the devices (the `input` group); without it
//!     the status is `.needs_permission`.
//!
//! Cost: nothing runs while no input happens (all fds idle in epoll_wait). Each wakeup
//! reads everything pending, classifies into an `InputQueue` (no allocation) and drains
//! it to the callback once, so bursts coalesce into one callback round per wakeup.

const std = @import("std");
const linux = std.os.linux;
const c = @import("linux_c");
const platform = @import("../platform.zig");
const desktop = platform.desktop;
const event_loop = @import("event_loop.zig");

const log = std.log.scoped(.global_input);
const Allocator = std.mem.Allocator;

pub const Backend = enum { none, xinput2, evdev };

pub const Monitor = struct {
    gpa: Allocator,
    loop: *event_loop.EventLoop,
    cb: platform.Callback(platform.GlobalInputEvent, void),
    queue: desktop.InputQueue = .{},
    backend: Backend = .none,

    // XInput2
    dpy: ?*c.Display = null,
    xi_opcode: u8 = 0,
    xi_source: ?*event_loop.Source = null,

    // evdev
    devices: [max_devices]?Device = @splat(null),
    inotify_fd: linux.fd_t = -1,
    inotify_source: ?*event_loop.Source = null,
    saw_denied: bool = false,

    const max_devices = 64;
    const Device = struct { fd: linux.fd_t, source: *event_loop.Source, index: u8 };

    /// Starts the strongest backend for the session; `prefer_evdev` for Wayland.
    pub fn start(gpa: Allocator, loop: *event_loop.EventLoop, cb: platform.Callback(platform.GlobalInputEvent, void), prefer_evdev: bool) !struct { monitor: ?*Monitor, status: platform.InputMonitorStatus } {
        const self = try gpa.create(Monitor);
        self.* = .{ .gpa = gpa, .loop = loop, .cb = cb };
        if (prefer_evdev) {
            if (self.startEvdev()) return .{ .monitor = self, .status = .ok };
            if (self.startXi2()) {
                log.info("no readable /dev/input devices; XInput2 over XWayland sees XWayland apps only", .{});
                return .{ .monitor = self, .status = .ok };
            }
        } else {
            if (self.startXi2()) return .{ .monitor = self, .status = .ok };
            if (self.startEvdev()) return .{ .monitor = self, .status = .ok };
        }
        const status: platform.InputMonitorStatus = if (self.saw_denied) .needs_permission else .unsupported;
        self.destroy();
        return .{ .monitor = null, .status = status };
    }

    pub fn destroy(self: *Monitor) void {
        self.stopXi2();
        self.stopEvdev();
        self.gpa.destroy(self);
    }

    fn deliver(self: *Monitor) void {
        self.queue.drainTo(self.cb);
    }

    // -- XInput2 raw events -----------------------------------------------------------

    fn startXi2(self: *Monitor) bool {
        if (std.c.getenv("DISPLAY") == null) return false;
        const dpy = c.XOpenDisplay(null) orelse return false;
        var opcode: c_int = 0;
        var ev: c_int = 0;
        var err: c_int = 0;
        var major: c_int = 2;
        var minor: c_int = 0;
        if (c.XQueryExtension(dpy, "XInputExtension", &opcode, &ev, &err) == 0 or c.XIQueryVersion(dpy, &major, &minor) != 0) {
            _ = c.XCloseDisplay(dpy);
            return false;
        }
        // Only the four raw event types: nothing else is ever sent to this connection.
        var bits: [4]u8 = @splat(0);
        for ([_]c_int{ c.XI_RawKeyPress, c.XI_RawKeyRelease, c.XI_RawButtonPress, c.XI_RawButtonRelease }) |t|
            bits[@intCast(@divTrunc(t, 8))] |= @as(u8, 1) << @intCast(@mod(t, 8));
        var mask: c.XIEventMask = .{ .deviceid = c.XIAllMasterDevices, .mask_len = bits.len, .mask = &bits };
        _ = c.XISelectEvents(dpy, c.XDefaultRootWindow(dpy), &mask, 1);
        _ = c.XFlush(dpy);
        c.XSetEventQueueOwner(dpy, c.XCBOwnsEventQueue);
        const conn = c.XGetXCBConnection(dpy) orelse {
            _ = c.XCloseDisplay(dpy);
            return false;
        };
        self.xi_source = self.loop.addFd(c.xcb_get_file_descriptor(conn), linux.EPOLL.IN, .{ .ctx = self, .func = onXiReadable }) catch {
            _ = c.XCloseDisplay(dpy);
            return false;
        };
        self.dpy = dpy;
        self.xi_opcode = @intCast(opcode);
        self.backend = .xinput2;
        return true;
    }

    fn stopXi2(self: *Monitor) void {
        if (self.xi_source) |s| self.loop.removeFd(s);
        self.xi_source = null;
        if (self.dpy) |d| _ = c.XCloseDisplay(d);
        self.dpy = null;
    }

    fn onXiReadable(ctx: ?*anyopaque, _: u32) void {
        const self: *Monitor = @ptrCast(@alignCast(ctx.?));
        const conn = c.XGetXCBConnection(self.dpy orelse return) orelse return;
        while (c.xcb_poll_for_event(conn)) |ev| {
            defer std.c.free(ev);
            const bytes: [*]const u8 = @ptrCast(ev);
            if (bytes[0] & 0x7f != 35 or bytes[1] != self.xi_opcode) continue; // GenericEvent
            if (parseRawEvent(bytes, event_loop.monotonicNow())) |e| self.queue.push(e);
        }
        if (c.xcb_connection_has_error(conn) != 0) {
            log.warn("XInput2 monitor connection lost", .{});
            self.stopXi2();
        }
        self.deliver();
    }

    // -- evdev ------------------------------------------------------------------------

    fn startEvdev(self: *Monitor) bool {
        var opened = false;
        var i: u8 = 0;
        while (i < max_devices) : (i += 1) {
            if (self.openDevice(i)) opened = true;
        }
        if (!opened) {
            self.stopEvdev();
            return false;
        }
        const ifd = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(ifd) == .SUCCESS) {
            self.inotify_fd = @intCast(ifd);
            _ = linux.inotify_add_watch(self.inotify_fd, "/dev/input", linux.IN.CREATE | linux.IN.ATTRIB);
            self.inotify_source = self.loop.addFd(self.inotify_fd, linux.EPOLL.IN, .{ .ctx = self, .func = onInotify }) catch null;
        }
        self.backend = .evdev;
        return true;
    }

    fn stopEvdev(self: *Monitor) void {
        for (&self.devices) |*slot| if (slot.*) |d| {
            self.loop.removeFd(d.source);
            _ = linux.close(d.fd);
            slot.* = null;
        };
        if (self.inotify_source) |s| self.loop.removeFd(s);
        self.inotify_source = null;
        if (self.inotify_fd >= 0) _ = linux.close(self.inotify_fd);
        self.inotify_fd = -1;
    }

    /// Opens `/dev/input/event<index>` when it is a keyboard or pointer we can read.
    fn openDevice(self: *Monitor, index: u8) bool {
        if (index >= max_devices or self.devices[index] != null) return false;
        var path_buf: [32]u8 = undefined;
        const path = std.mem.printSentinel(&path_buf, "/dev/input/event{d}", .{index}, 0) catch return false;
        const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .ACCES, .PERM => {
                self.saw_denied = true;
                return false;
            },
            else => return false,
        }
        const fd: linux.fd_t = @intCast(rc);
        if (!isInteresting(fd)) {
            _ = linux.close(fd);
            return false;
        }
        const source = self.loop.addFd(fd, linux.EPOLL.IN, .{ .ctx = self, .func = onDeviceReadable }) catch {
            _ = linux.close(fd);
            return false;
        };
        self.devices[index] = .{ .fd = fd, .source = source, .index = index };
        return true;
    }

    fn closeDevice(self: *Monitor, index: u8) void {
        const d = self.devices[index] orelse return;
        self.loop.removeFd(d.source);
        _ = linux.close(d.fd);
        self.devices[index] = null;
    }

    fn onDeviceReadable(ctx: ?*anyopaque, _: u32) void {
        const self: *Monitor = @ptrCast(@alignCast(ctx.?));
        const now = event_loop.monotonicNow();
        // Which device fired is not passed in; poll all (non-blocking, cheap: a handful).
        for (self.devices) |slot| {
            const d = slot orelse continue;
            var buf: [64]InputEvent = undefined;
            while (true) {
                const n = linux.read(d.fd, @ptrCast(&buf), @sizeOf(@TypeOf(buf)));
                switch (linux.errno(n)) {
                    .SUCCESS => {},
                    .AGAIN, .INTR => break,
                    else => {
                        // Unplugged (ENODEV) or revoked.
                        self.closeDevice(d.index);
                        break;
                    },
                }
                if (n == 0) break;
                for (buf[0 .. n / @sizeOf(InputEvent)]) |ie| if (classifyEvdev(ie.type, ie.code, ie.value, now)) |e| self.queue.push(e);
                if (n < @sizeOf(@TypeOf(buf))) break;
            }
        }
        self.deliver();
    }

    fn onInotify(ctx: ?*anyopaque, _: u32) void {
        const self: *Monitor = @ptrCast(@alignCast(ctx.?));
        var buf: [1024]u8 align(@alignOf(linux.inotify_event)) = undefined;
        while (true) {
            const n = linux.read(self.inotify_fd, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS or n == 0) break;
            var off: usize = 0;
            while (off + @sizeOf(linux.inotify_event) <= n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&buf[off + @sizeOf(linux.inotify_event)]))[0..ev.len], 0);
                if (std.mem.startsWith(u8, name, "event")) {
                    if (std.fmt.parseInt(u8, name["event".len..], 10)) |idx| {
                        _ = self.openDevice(idx);
                    } else |_| {}
                }
                off += @sizeOf(linux.inotify_event) + ev.len;
            }
        }
    }
};

/// `struct input_event` on 64-bit Linux.
const InputEvent = extern struct {
    sec: isize,
    usec: isize,
    type: u16,
    code: u16,
    value: i32,
};

const EV_KEY = 1;
const EV_REL = 2;
const REL_HWHEEL = 6;
const REL_WHEEL = 8;
const BTN_LEFT = 0x110;
const KEY_A = 30;

fn eviocgbit(ev: u32, len: u32) u32 {
    return (2 << 30) | (len << 16) | (@as(u32, 'E') << 8) | (0x20 + ev);
}

fn testBit(bits: []const u8, n: usize) bool {
    return n / 8 < bits.len and bits[n / 8] & (@as(u8, 1) << @intCast(n % 8)) != 0;
}

/// A keyboard (has KEY_A) or a pointer with buttons (BTN_LEFT).
fn isInteresting(fd: linux.fd_t) bool {
    var types: [4]u8 = @splat(0);
    if (linux.errno(linux.ioctl(fd, eviocgbit(0, types.len), @intFromPtr(&types))) != .SUCCESS) return false;
    if (!testBit(&types, EV_KEY)) return false;
    var keys: [96]u8 = @splat(0);
    if (linux.errno(linux.ioctl(fd, eviocgbit(EV_KEY, keys.len), @intFromPtr(&keys))) != .SUCCESS) return false;
    return testBit(&keys, KEY_A) or testBit(&keys, BTN_LEFT);
}

/// One evdev event → a global input event (null: ignored, incl. key autorepeat).
pub fn classifyEvdev(ev_type: u16, code: u16, value: i32, now_ns: u64) ?platform.GlobalInputEvent {
    switch (ev_type) {
        EV_KEY => {
            if (value == 2) return null; // autorepeat
            const down = value != 0;
            if (code >= BTN_LEFT and code < BTN_LEFT + 8)
                return .{ .kind = if (down) .mouse_down else .mouse_up, .timestamp_ns = now_ns };
            if (code >= 0x100 and code < 0x160) return null; // joystick / tool buttons
            const k = desktop.evdevKey(code);
            return .{ .kind = if (down) .key_down else .key_up, .key = k.class, .key_x = k.x, .timestamp_ns = now_ns };
        },
        EV_REL => if (code == REL_WHEEL or code == REL_HWHEEL) return .{ .kind = .scroll, .timestamp_ns = now_ns },
        else => {},
    }
    return null;
}

/// An XI2 raw event (xcb GenericEvent buffer) → a global input event.
pub fn parseRawEvent(bytes: [*]const u8, now_ns: u64) ?platform.GlobalInputEvent {
    const evtype = std.mem.readInt(u16, bytes[8..10], .little);
    const detail = std.mem.readInt(u32, bytes[16..20], .little);
    const flags = std.mem.readInt(u32, bytes[24..28], .little);
    switch (evtype) {
        c.XI_RawKeyPress, c.XI_RawKeyRelease => {
            if (flags & c.XIKeyRepeat != 0) return null;
            const k = desktop.evdevKey(if (detail >= 8) @intCast(@min(detail - 8, 0xffff)) else 0xffff);
            return .{ .kind = if (evtype == c.XI_RawKeyPress) .key_down else .key_up, .key = k.class, .key_x = k.x, .timestamp_ns = now_ns };
        },
        c.XI_RawButtonPress, c.XI_RawButtonRelease => {
            if (detail >= 4 and detail <= 7) return if (evtype == c.XI_RawButtonPress) .{ .kind = .scroll, .timestamp_ns = now_ns } else null;
            return .{ .kind = if (evtype == c.XI_RawButtonPress) .mouse_down else .mouse_up, .timestamp_ns = now_ns };
        },
        else => return null,
    }
}

/// Whether any `/dev/input/event*` is readable (the Wayland "permission").
pub fn evdevReadable() platform.InputPermission {
    var denied = false;
    var i: u8 = 0;
    while (i < 64) : (i += 1) {
        var path_buf: [32]u8 = undefined;
        const path = std.mem.printSentinel(&path_buf, "/dev/input/event{d}", .{i}, 0) catch continue;
        const rc = linux.open(path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                _ = linux.close(@intCast(rc));
                return .granted;
            },
            .ACCES, .PERM => denied = true,
            else => {},
        }
    }
    return if (denied) .denied else .not_determined;
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "classifyEvdev maps keys, buttons and wheels; skips autorepeat" {
    const a = classifyEvdev(EV_KEY, 30, 1, 5).?;
    try testing.expectEqual(platform.GlobalInputKind.key_down, a.kind);
    try testing.expectEqual(platform.GlobalKeyClass.letter, a.key);
    try testing.expectEqual(@as(u64, 5), a.timestamp_ns);
    try testing.expectEqual(platform.GlobalInputKind.key_up, classifyEvdev(EV_KEY, 57, 0, 0).?.kind);
    try testing.expect(classifyEvdev(EV_KEY, 30, 2, 0) == null);
    try testing.expectEqual(platform.GlobalInputKind.mouse_down, classifyEvdev(EV_KEY, BTN_LEFT, 1, 0).?.kind);
    try testing.expectEqual(platform.GlobalInputKind.mouse_up, classifyEvdev(EV_KEY, BTN_LEFT + 1, 0, 0).?.kind);
    try testing.expectEqual(platform.GlobalInputKind.scroll, classifyEvdev(EV_REL, REL_WHEEL, -1, 0).?.kind);
    try testing.expect(classifyEvdev(EV_REL, 0, 3, 0) == null); // REL_X motion
    try testing.expect(classifyEvdev(0, 0, 0, 0) == null); // SYN
}

test "parseRawEvent decodes XI2 raw key / button events" {
    var buf: [64]u8 align(4) = @splat(0);
    buf[0] = 35;
    std.mem.writeInt(u16, buf[8..10], c.XI_RawKeyPress, .little);
    std.mem.writeInt(u32, buf[16..20], 38 + 8, .little); // X keycode of KEY_L
    const e = parseRawEvent(&buf, 9).?;
    try testing.expectEqual(platform.GlobalInputKind.key_down, e.kind);
    try testing.expectEqual(platform.GlobalKeyClass.letter, e.key);
    try testing.expect(e.key_x > 0.6);
    std.mem.writeInt(u32, buf[24..28], c.XIKeyRepeat, .little);
    try testing.expect(parseRawEvent(&buf, 9) == null);
    std.mem.writeInt(u32, buf[24..28], 0, .little);
    std.mem.writeInt(u16, buf[8..10], c.XI_RawButtonPress, .little);
    std.mem.writeInt(u32, buf[16..20], 5, .little);
    try testing.expectEqual(platform.GlobalInputKind.scroll, parseRawEvent(&buf, 0).?.kind);
    std.mem.writeInt(u16, buf[8..10], c.XI_RawButtonRelease, .little);
    try testing.expect(parseRawEvent(&buf, 0) == null);
    std.mem.writeInt(u32, buf[16..20], 1, .little);
    try testing.expectEqual(platform.GlobalInputKind.mouse_up, parseRawEvent(&buf, 0).?.kind);
}
