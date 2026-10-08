//! macOS desktop-companion features (docs/DESKTOP_OVERLAY.md):
//!
//!   * global input monitor, two backends:
//!       - default, permissionless (`setPreciseInput(false)`): polls the HID system
//!         event counters (`CGEventSourceCounterForEventType`) from a GCD timer on the
//!         main queue. Each key-down counted becomes a `key_down`; `CGEventSourceKeyState`
//!         (when it reports real key states without permission) gives the key's class and
//!         position, else `key_x` alternates left/right. No TCC prompt, no Input
//!         Monitoring, no Accessibility. Adaptive rate: 60 Hz for 2 s after activity,
//!         20 Hz for the next 4 s, then 4 Hz, with generous timer leeway so the OS can
//!         coalesce wakeups; suspended while every overlay window is hidden.
//!       - precise (`setPreciseInput(true)`): a listen-only `CGEventTap` on the main run
//!         loop (Input Monitoring permission, `CGRequestListenEventAccess`). The tap
//!         callback only classifies the keycode into a fixed ring and schedules one drain
//!         per burst: no allocation, no AppKit.
//!   * tray: `NSStatusItem` with an `NSMenu` built from the app menu model (menu.zig);
//!   * foreground app: `NSWorkspace.frontmostApplication` + did-activate notifications;
//!   * launch at login: `SMAppService.mainApp` (macOS 13+, bundled apps), else a
//!     per-user LaunchAgent plist in `~/Library/LaunchAgents`.

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const cf = @import("cf.zig");
const pf = @import("../platform.zig");
const desktop = pf.desktop;
const menu_mod = @import("menu.zig");

const log = std.log.scoped(.mac_desktop);
const id = objc.id;
const BOOL = objc.BOOL;
const YES = objc.YES;
const NO = objc.NO;
const NSInteger = ak.NSInteger;
const NSUInteger = ak.NSUInteger;

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" const _dispatch_source_type_timer: u8;
extern "c" fn dispatch_source_set_timer(source: ak.dispatch_source_t, start: ak.dispatch_time_t, interval: u64, leeway: u64) void;
extern "c" fn dispatch_suspend(object: *anyopaque) void;

fn sym(comptime T: type, comptime name: [:0]const u8) ?T {
    const rtld_default: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
    const p = dlsym(rtld_default, name) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn nowNs() u64 {
    return ak.clock_gettime_nsec_np(ak.CLOCK_UPTIME_RAW);
}

// CGEventType / CGEventSourceStateID values.
const kCGEventSourceStateHIDSystemState: i32 = 1;
const kCGAnyInputEventType: u32 = 0xFFFF_FFFF;
const ev_left_down: u32 = 1;
const ev_left_up: u32 = 2;
const ev_right_down: u32 = 3;
const ev_right_up: u32 = 4;
const ev_key_down: u32 = 10;
const ev_key_up: u32 = 11;
const ev_flags_changed: u32 = 12;
const ev_scroll: u32 = 22;
const ev_other_down: u32 = 25;
const ev_other_up: u32 = 26;
const ev_tap_disabled_timeout: u32 = 0xFFFF_FFFE;
const ev_tap_disabled_user: u32 = 0xFFFF_FFFF;
const kCGKeyboardEventAutorepeat: u32 = 8;
const kCGKeyboardEventKeycode: u32 = 9;

const CounterFn = *const fn (state: i32, event_type: u32) callconv(.c) u32;
const KeyStateFn = *const fn (state: i32, key: u16) callconv(.c) bool;

/// ANSI keycodes sampled with `CGEventSourceKeyState` (letters, digits, space, return,
/// delete, tab, arrows).
const sampled_keys = blk: {
    @setEvalBranchQuota(100_000);
    var out: [64]u16 = undefined;
    var n: usize = 0;
    for (0..127) |vk| {
        const info = desktop.macKey(vk);
        if (info.class == .other or info.class == .modifier) continue;
        if (n < out.len) {
            out[n] = vk;
            n += 1;
        }
    }
    break :blk out[0..n].*;
};

// ---------------------------------------------------------------------------------------
// Global input monitor
// ---------------------------------------------------------------------------------------

/// Set by the platform: true while the permissionless poller should run (no overlay
/// windows exist, or at least one is visible).
pub var overlay_activity_hook: ?*const fn () bool = null;

pub const InputMonitor = struct {
    cb: pf.Callback(pf.GlobalInputEvent, void) = .{},
    running: bool = false,
    precise: bool = false,
    queue: desktop.InputQueue = .{},
    drain_pending: bool = false,

    // permissionless backend: key counter poll + NSEvent global mouse monitor
    timer: ?ak.dispatch_source_t = null,
    suspended: bool = false,
    interval_ns: u64 = 0,
    last_activity_ns: u64 = 0,
    decoder: desktop.CounterDecoder = .{},
    sampler: desktop.KeySampler = .{},
    counter_fn: ?CounterFn = null,
    key_state_fn: ?KeyStateFn = null,
    mouse_monitor: ?id = null,

    // tap backend
    tap: ?*anyopaque = null,
    tap_source: ?*anyopaque = null,

    pub fn start(self: *InputMonitor, cb: pf.Callback(pf.GlobalInputEvent, void)) pf.InputMonitorStatus {
        self.stop();
        self.cb = cb;
        const status = if (self.precise) self.startTap() else self.startCounters();
        self.running = status == .ok;
        return status;
    }

    pub fn stop(self: *InputMonitor) void {
        self.stopCounters();
        self.stopTap();
        self.running = false;
    }

    /// Overlay visibility changed: the permissionless poller sleeps while every
    /// overlay is hidden (a hidden pet has nothing to animate).
    pub fn setActive(self: *InputMonitor, active: bool) void {
        const t = self.timer orelse return;
        if (active and self.suspended) {
            self.suspended = false;
            self.interval_ns = 0;
            self.last_activity_ns = nowNs();
            // Typing while hidden is not replayed.
            if (self.counter_fn) |counter| self.decoder.reset(counter(kCGEventSourceStateHIDSystemState, ev_key_down));
            ak.dispatch_resume(@ptrCast(t));
            self.retime();
        } else if (!active and !self.suspended) {
            self.suspended = true;
            dispatch_suspend(@ptrCast(t));
        }
    }

    pub fn permission(self: *const InputMonitor) pf.InputPermission {
        if (!self.precise) return .not_applicable;
        // IOHIDCheckAccess(kIOHIDRequestTypeListenEvent): granted 0, denied 1, unknown 2.
        if (sym(*const fn (u32) callconv(.c) u32, "IOHIDCheckAccess")) |f| return switch (f(1)) {
            0 => .granted,
            1 => .denied,
            else => .not_determined,
        };
        const pre = sym(*const fn () callconv(.c) bool, "CGPreflightListenEventAccess") orelse return .granted;
        return if (pre()) .granted else .not_determined;
    }

    /// Precise mode only: the Input Monitoring prompt (or System Settings when already
    /// denied). Permissionless mode needs nothing, so this is a no-op there.
    pub fn requestPermission(self: *InputMonitor) void {
        if (!self.precise) return;
        const f = sym(*const fn () callconv(.c) bool, "CGRequestListenEventAccess") orelse return;
        if (!f() and self.permission() == .denied) {
            ak.class("NSWorkspace").msg(id, "sharedWorkspace", .{}).msg(void, "openURL:", .{
                ak.class("NSURL").msg(id, "URLWithString:", .{ak.nsString("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")}),
            });
        }
    }

    fn scheduleDrain(self: *InputMonitor) void {
        if (self.drain_pending or self.queue.len == 0) return;
        self.drain_pending = true;
        ak.dispatch_async_f(ak.mainQueue(), self, drain);
    }

    fn drain(ctx: ?*anyopaque) callconv(.c) void {
        const self: *InputMonitor = @ptrCast(@alignCast(ctx.?));
        self.drain_pending = false;
        self.queue.drainTo(self.cb);
    }

    // -- permissionless: HID key counter + NSEvent global mouse monitor ----------------

    fn startCounters(self: *InputMonitor) pf.InputMonitorStatus {
        const counter = sym(CounterFn, "CGEventSourceCounterForEventType") orelse return .unsupported;
        const src = ak.dispatch_source_create(@ptrCast(&_dispatch_source_type_timer), 0, 0, ak.mainQueue()) orelse return .unsupported;
        self.counter_fn = counter;
        self.key_state_fn = sym(KeyStateFn, "CGEventSourceKeyState");
        self.decoder.reset(counter(kCGEventSourceStateHIDSystemState, ev_key_down));
        // Keep a probe verdict across restarts (it only gets more certain).
        self.sampler.down = @splat(false);
        self.timer = src;
        self.suspended = false;
        self.interval_ns = 0;
        self.last_activity_ns = nowNs();
        ak.dispatch_set_context(@ptrCast(src), self);
        ak.dispatch_source_set_event_handler_f(src, onTick);
        self.retime();
        ak.dispatch_resume(@ptrCast(src));
        self.startMouseMonitor();
        if (overlay_activity_hook) |f| self.setActive(f());
        return .ok;
    }

    fn stopCounters(self: *InputMonitor) void {
        self.stopMouseMonitor();
        const t = self.timer orelse return;
        if (self.suspended) ak.dispatch_resume(@ptrCast(t)); // a suspended source cannot be released
        ak.dispatch_source_cancel(t);
        ak.dispatch_release(@ptrCast(t));
        self.timer = null;
        self.suspended = false;
    }

    fn retime(self: *InputMonitor) void {
        const t = self.timer orelse return;
        const want = desktop.counterPollInterval(nowNs() -| self.last_activity_ns);
        if (want == self.interval_ns) return;
        self.interval_ns = want;
        // Generous leeway (half the interval) lets the OS coalesce wakeups.
        dispatch_source_set_timer(t, ak.dispatch_time(ak.DISPATCH_TIME_NOW, @intCast(want)), want, want / 2);
    }

    fn onTick(ctx: ?*anyopaque) callconv(.c) void {
        const self: *InputMonitor = @ptrCast(@alignCast(ctx.?));
        self.poll();
        self.retime();
        self.scheduleDrain();
    }

    fn poll(self: *InputMonitor) void {
        const now = nowNs();
        const counter = self.counter_fn orelse return;
        // The counter itself is the idle check (one call per tick). No
        // `CGEventSourceSecondsSinceLastEventType` gate: it need not move for posted
        // events, and a tick delayed past its window would drop the key-downs.
        const value = counter(kCGEventSourceStateHIDSystemState, ev_key_down);
        const counted = value -% self.decoder.count;
        var known: []const desktop.KeyInfo = &.{};
        if (self.key_state_fn) |key_state| if (self.sampler.shouldSample(counted != 0)) {
            self.sampler.begin();
            for (sampled_keys) |vk| self.sampler.observe(&self.queue, vk, key_state(kCGEventSourceStateHIDSystemState, vk), now);
            known = self.sampler.end(counted);
        };
        if (self.decoder.poll(&self.queue, value, known, now) > 0) self.last_activity_ns = now;
    }

    // NSEvent global monitor (mouse events need no permission). The handler is a global
    // block: it only classifies into the ring.
    var active_monitor: ?*InputMonitor = null;

    const MouseBlock = extern struct {
        isa: *const anyopaque,
        flags: c_int,
        reserved: c_int = 0,
        invoke: *const fn (block: *const MouseBlock, event: id) callconv(.c) void,
        descriptor: *const BlockDescriptor,
    };
    const BlockDescriptor = extern struct { reserved: c_ulong = 0, size: c_ulong };
    extern "c" const _NSConcreteGlobalBlock: anyopaque;
    const block_descriptor: BlockDescriptor = .{ .size = @sizeOf(MouseBlock) };
    const mouse_block: MouseBlock = .{
        .isa = &_NSConcreteGlobalBlock,
        .flags = 1 << 28, // BLOCK_IS_GLOBAL
        .invoke = onMouseEvent,
        .descriptor = &block_descriptor,
    };

    fn startMouseMonitor(self: *InputMonitor) void {
        active_monitor = self;
        const mask: u64 = (1 << ev_left_down) | (1 << ev_left_up) | (1 << ev_right_down) | (1 << ev_right_up) |
            (1 << ev_other_down) | (1 << ev_other_up) | (1 << ev_scroll);
        const m = ak.class("NSEvent").msg(?id, "addGlobalMonitorForEventsMatchingMask:handler:", .{ mask, @as(*const anyopaque, @ptrCast(&mouse_block)) }) orelse return;
        self.mouse_monitor = m.retain();
    }

    fn stopMouseMonitor(self: *InputMonitor) void {
        if (self.mouse_monitor) |m| {
            ak.class("NSEvent").msg(void, "removeMonitor:", .{m});
            m.release();
        }
        self.mouse_monitor = null;
        if (active_monitor == self) active_monitor = null;
    }

    fn onMouseEvent(_: *const MouseBlock, event: id) callconv(.c) void {
        const self = active_monitor orelse return;
        if (self.suspended) return;
        const now = nowNs();
        const kind: pf.GlobalInputKind = switch (@as(u32, @intCast(event.msg(NSUInteger, "type", .{})))) {
            ev_left_down, ev_right_down, ev_other_down => .mouse_down,
            ev_left_up, ev_right_up, ev_other_up => .mouse_up,
            ev_scroll => .scroll,
            else => return,
        };
        self.queue.push(.{ .kind = kind, .timestamp_ns = now });
        self.scheduleDrain();
    }

    // -- precise: listen-only event tap ------------------------------------------------

    const TapCallback = *const fn (proxy: ?*anyopaque, event_type: u32, event: ?*anyopaque, user: ?*anyopaque) callconv(.c) ?*anyopaque;

    fn startTap(self: *InputMonitor) pf.InputMonitorStatus {
        // Never prompt here: without Input Monitoring the app asks via requestInputPermission.
        if (sym(*const fn () callconv(.c) bool, "CGPreflightListenEventAccess")) |pre| if (!pre()) return .needs_permission;
        const create = sym(*const fn (u32, u32, u32, u64, TapCallback, ?*anyopaque) callconv(.c) ?*anyopaque, "CGEventTapCreate") orelse return .unsupported;
        const mask: u64 = (1 << ev_key_down) | (1 << ev_key_up) | (1 << ev_flags_changed) | (1 << ev_left_down) | (1 << ev_left_up) |
            (1 << ev_right_down) | (1 << ev_right_up) | (1 << ev_other_down) | (1 << ev_other_up) | (1 << ev_scroll);
        // kCGSessionEventTap = 1, kCGHeadInsertEventTap = 0, kCGEventTapOptionListenOnly = 1
        const tap = create(1, 0, 1, mask, onTapEvent, self) orelse return .needs_permission;
        const mk_source = sym(*const fn (?*anyopaque, *anyopaque, NSInteger) callconv(.c) ?*anyopaque, "CFMachPortCreateRunLoopSource") orelse return .unsupported;
        const source = mk_source(null, tap, 0) orelse {
            cf.CFRelease(tap);
            return .unsupported;
        };
        const get_main = sym(*const fn () callconv(.c) *anyopaque, "CFRunLoopGetMain") orelse return .unsupported;
        const add = sym(*const fn (*anyopaque, *anyopaque, *const anyopaque) callconv(.c) void, "CFRunLoopAddSource") orelse return .unsupported;
        const common_modes = sym(*const *const anyopaque, "kCFRunLoopCommonModes") orelse return .unsupported;
        add(get_main(), source, common_modes.*);
        self.tap = tap;
        self.tap_source = source;
        return .ok;
    }

    fn stopTap(self: *InputMonitor) void {
        const tap = self.tap orelse return;
        if (sym(*const fn (*anyopaque, bool) callconv(.c) void, "CGEventTapEnable")) |enable| enable(tap, false);
        if (self.tap_source) |s| {
            if (sym(*const fn (*anyopaque) callconv(.c) void, "CFRunLoopSourceInvalidate")) |inv| inv(s);
            cf.CFRelease(s);
        }
        if (sym(*const fn (*anyopaque) callconv(.c) void, "CFMachPortInvalidate")) |inv| inv(tap);
        cf.CFRelease(tap);
        self.tap = null;
        self.tap_source = null;
    }

    /// Main run loop. Classify into the ring, schedule one drain; never allocate.
    fn onTapEvent(_: ?*anyopaque, event_type: u32, event: ?*anyopaque, user: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *InputMonitor = @ptrCast(@alignCast(user.?));
        if (event_type == ev_tap_disabled_timeout or event_type == ev_tap_disabled_user) {
            if (self.tap) |t| if (sym(*const fn (*anyopaque, bool) callconv(.c) void, "CGEventTapEnable")) |enable| enable(t, true);
            return event;
        }
        const ev = event orelse return event;
        const field = sym(*const fn (*anyopaque, u32) callconv(.c) i64, "CGEventGetIntegerValueField") orelse return event;
        const now = nowNs();
        const e: ?pf.GlobalInputEvent = switch (event_type) {
            ev_key_down, ev_key_up => blk: {
                if (event_type == ev_key_down and field(ev, kCGKeyboardEventAutorepeat) != 0) break :blk null;
                const info = desktop.macKey(@intCast(field(ev, kCGKeyboardEventKeycode) & 0xffff));
                break :blk .{ .kind = if (event_type == ev_key_down) .key_down else .key_up, .key = info.class, .key_x = info.x, .timestamp_ns = now };
            },
            ev_flags_changed => blk: {
                const info = desktop.macKey(@intCast(field(ev, kCGKeyboardEventKeycode) & 0xffff));
                break :blk .{ .kind = .key_down, .key = .modifier, .key_x = info.x, .timestamp_ns = now };
            },
            ev_left_down, ev_right_down, ev_other_down => .{ .kind = .mouse_down, .timestamp_ns = now },
            ev_left_up, ev_right_up, ev_other_up => .{ .kind = .mouse_up, .timestamp_ns = now },
            ev_scroll => .{ .kind = .scroll, .timestamp_ns = now },
            else => null,
        };
        if (e) |x| {
            self.queue.push(x);
            self.scheduleDrain();
        }
        return event;
    }
};

// ---------------------------------------------------------------------------------------
// Status item (tray)
// ---------------------------------------------------------------------------------------

pub const StatusItem = struct {
    item: ?id = null,

    pub fn set(self: *StatusItem, tray: ?pf.TrayItem, delegate: id) !void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const t = tray orelse {
            self.remove();
            return;
        };
        if (self.item == null) {
            const bar = ak.class("NSStatusBar").msg(id, "systemStatusBar", .{});
            const item = bar.msg(?id, "statusItemWithLength:", .{@as(ak.CGFloat, -1)}) orelse return error.Unsupported; // NSVariableStatusItemLength
            self.item = item.retain();
        }
        const item = self.item.?;
        const button = item.msg(?id, "button", .{}) orelse return error.Unsupported;
        if (t.icon_png.len > 0) {
            const data = ak.class("NSData").msg(id, "dataWithBytes:length:", .{ t.icon_png.ptr, @as(NSUInteger, t.icon_png.len) });
            if (ak.class("NSImage").msg(id, "alloc", .{}).msg(?id, "initWithData:", .{data})) |img| {
                defer img.release();
                const size = img.msg(ak.NSSize, "size", .{});
                const h: ak.CGFloat = 18;
                const w: ak.CGFloat = if (size.height > 0) h * size.width / size.height else h;
                img.msg(void, "setSize:", .{ak.NSSize{ .width = w, .height = h }});
                img.msg(void, "setTemplate:", .{objc.toBOOL(t.template)});
                button.msg(void, "setImage:", .{img});
            }
        }
        button.msg(void, "setToolTip:", .{ak.nsString(t.tooltip)});
        const menu = menu_mod.buildMenu(t.menu, delegate);
        targetItems(menu, delegate);
        item.msg(void, "setMenu:", .{menu});
    }

    /// Status item menus are not in the key window's responder chain: target the
    /// app delegate (which implements the menu selectors) explicitly.
    fn targetItems(menu: id, delegate: id) void {
        const n = menu.msg(NSInteger, "numberOfItems", .{});
        var i: NSInteger = 0;
        while (i < n) : (i += 1) {
            const it = menu.msg(id, "itemAtIndex:", .{i});
            if (it.msg(?id, "submenu", .{})) |sub| targetItems(sub, delegate) else it.msg(void, "setTarget:", .{delegate});
        }
    }

    pub fn remove(self: *StatusItem) void {
        const item = self.item orelse return;
        ak.class("NSStatusBar").msg(id, "systemStatusBar", .{}).msg(void, "removeStatusItem:", .{item});
        item.release();
        self.item = null;
    }
};

// ---------------------------------------------------------------------------------------
// Foreground app
// ---------------------------------------------------------------------------------------

pub fn foregroundApp(buf: []u8) ?pf.ForegroundApp {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const ws = ak.class("NSWorkspace").msg(id, "sharedWorkspace", .{});
    const app = ws.msg(?id, "frontmostApplication", .{}) orelse return null;
    const name = if (app.msg(?id, "localizedName", .{})) |s| ak.stringBytes(s) else "";
    const bundle = if (app.msg(?id, "bundleIdentifier", .{})) |s| ak.stringBytes(s) else name;
    if (bundle.len + name.len > buf.len or bundle.len == 0) return null;
    @memcpy(buf[0..bundle.len], bundle);
    @memcpy(buf[bundle.len..][0..name.len], name);
    return .{ .id = buf[0..bundle.len], .name = buf[bundle.len..][0..name.len] };
}

/// Observe `NSWorkspaceDidActivateApplicationNotification` with `observer`
/// (`selector` receives the notification).
pub fn observeActivation(observer: id, comptime selector: [:0]const u8) void {
    const center = ak.class("NSWorkspace").msg(id, "sharedWorkspace", .{}).msg(id, "notificationCenter", .{});
    center.msg(void, "removeObserver:name:object:", .{ observer, objc.nsString("NSWorkspaceDidActivateApplicationNotification"), @as(?id, null) });
    center.msg(void, "addObserver:selector:name:object:", .{ observer, objc.sel(selector), objc.nsString("NSWorkspaceDidActivateApplicationNotification"), @as(?id, null) });
}

// ---------------------------------------------------------------------------------------
// Launch at login
// ---------------------------------------------------------------------------------------

pub fn setLaunchAtLogin(app_id: []const u8, exe_path: []const u8, on: bool) !void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    if (smAppService(on)) return;
    // Unbundled (dev) runs / macOS < 13: a per-user LaunchAgent.
    var path_buf: [1024]u8 = undefined;
    const home: ?[]const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else null;
    const path = try desktop.launchAgentPath(&path_buf, home, app_id);
    var z: [1025]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const pathz: [*:0]const u8 = z[0..path.len :0];
    if (!on) {
        _ = std.c.unlink(pathz);
        return;
    }
    if (std.fs.path.dirname(path)) |dir| {
        var d: [1025]u8 = undefined;
        @memcpy(d[0..dir.len], dir);
        d[dir.len] = 0;
        _ = std.c.mkdir(d[0..dir.len :0], 0o755);
    }
    var out: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try desktop.writeLaunchAgentPlist(&w, app_id, exe_path);
    const fd = std.c.open(pathz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.WriteFailed;
    defer _ = std.c.close(fd);
    const data = w.buffered();
    if (std.c.write(fd, data.ptr, data.len) != @as(isize, @intCast(data.len))) return error.WriteFailed;
}

/// `SMAppService.mainAppService` register / unregister; false when unavailable or it
/// failed (not an app bundle, not approved, ...).
fn smAppService(on: bool) bool {
    _ = dlopen("/System/Library/Frameworks/ServiceManagement.framework/ServiceManagement", 1);
    const cls = objc.getClass("SMAppService") orelse return false;
    const svc = cls.msg(?id, "mainAppService", .{}) orelse return false;
    var err: ?id = null;
    const ok = if (on) svc.msg(BOOL, "registerAndReturnError:", .{&err}) else svc.msg(BOOL, "unregisterAndReturnError:", .{&err});
    if (ok != YES) {
        log.info("SMAppService {s} failed ({s}); using a LaunchAgent", .{ if (on) "register" else "unregister", objc.errorDescription(err) });
        return false;
    }
    return true;
}
