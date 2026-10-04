//! macOS global hotkey + frontmost-window capture (zeron `appshots/macos.rs`):
//!
//! - Hotkey: Carbon `RegisterEventHotKey` on the application event target (one
//!   `kEventHotKeyPressed` handler installed once); letters/digits resolve against the
//!   active ASCII-capable layout (`UCKeyTranslate`) so an AZERTY "a" grabs the key
//!   printing "a".
//! - Capture (worker thread): `NSWorkspace.frontmostApplication` (never ourselves),
//!   Screen Recording preflight (prompting once when missing), the frontmost visible
//!   layer-0 window from `CGWindowListCopyWindowInfo` (matched to the AX focused
//!   window's bounds when Accessibility is granted), pixels from ScreenCaptureKit's
//!   `SCScreenshotManager` (macOS 14+, loaded with `dlopen`; Retina scale capped at
//!   4096 px) with `CGWindowListCreateImage` as the fallback, then the AX tree of the
//!   focused window retained *before* capture (depth ≤ 24, ≤ 1500 nodes, ≤ 96 KiB,
//!   900 ms, secure text fields redacted).
//! - Permissions: `CGPreflight/RequestScreenCaptureAccess`, `AXIsProcessTrusted[WithOptions]`.
//!
//! ApplicationServices / HIToolbox / ScreenCaptureKit symbols are resolved with
//! `dlsym` so nothing beyond the frameworks zpui already links is required.

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const cf = @import("cf.zig");
const pf = @import("../platform.zig");
const common = @import("../capture_common.zig");
const dispatcher_mod = @import("dispatcher.zig");

const log = std.log.scoped(.window_capture);
const id = objc.id;
const NSUInteger = objc.NSUInteger;
const NSInteger = objc.NSInteger;
const CGRect = cf.CGRect;
const CGPoint = cf.CGPoint;
const CGSize = cf.CGSize;
const CFTypeRef = cf.CFTypeRef;
const CFStringRef = cf.CFStringRef;

extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn getpid() c_int;
extern "c" const _NSConcreteStackBlock: anyopaque;
extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_wait(sem: *anyopaque, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(sem: *anyopaque) isize;
extern "c" fn dispatch_release(object: *anyopaque) void;
extern "c" fn CFBooleanGetTypeID() cf.CFTypeID;
extern "c" fn CFArrayGetTypeID() cf.CFTypeID;
extern "c" fn CFDictionaryGetTypeID() cf.CFTypeID;
extern "c" fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) ?cf.CFArrayRef;
extern "c" fn CGRectMakeWithDictionaryRepresentation(dict: cf.CFDictionaryRef, rect: *CGRect) bool;
extern "c" const kCGWindowOwnerPID: CFStringRef;
extern "c" const kCGWindowLayer: CFStringRef;
extern "c" const kCGWindowNumber: CFStringRef;
extern "c" const kCGWindowBounds: CFStringRef;
extern "c" const kCGWindowIsOnscreen: CFStringRef;
extern "c" const kCGWindowAlpha: CFStringRef;
extern "c" const kCGWindowName: CFStringRef;

const kCGWindowListOptionAll: u32 = 0;
const kCGWindowListOptionIncludingWindow: u32 = 1 << 3;
const kCGWindowListExcludeDesktopElements: u32 = 1 << 4;
const kCGWindowImageBoundsIgnoreFraming: u32 = 1 << 0;
const kCGWindowImageNominalResolution: u32 = 1 << 4;

const max_ax_depth: usize = 24;
const max_ax_nodes: usize = 1_500;
const max_ax_bytes: usize = 96 * 1024;
const max_ax_value_chars: usize = 4_096;
const ax_deadline_ns: u64 = 900 * std.time.ns_per_ms;
const sck_timeout_ns: i64 = 4 * std.time.ns_per_s;
const max_sck_dimension: f64 = 4_096.0;

/// A zero-length, never-freed `[]u8` (freeing it is a no-op).
var empty_buf: [0]u8 = .{};

fn sym(comptime T: type, comptime name: [:0]const u8) ?T {
    const rtld_default: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
    const p = dlsym(rtld_default, name) orelse return null;
    return @ptrCast(@alignCast(p));
}

fn nowNs() u64 {
    return dispatcher_mod.now();
}

// ---------------------------------------------------------------------------------------
// Accessibility + screen-recording permission
// ---------------------------------------------------------------------------------------

const AXUIElementRef = *const anyopaque;

fn axTrusted() bool {
    const f = sym(*const fn () callconv(.c) u8, "AXIsProcessTrusted") orelse return false;
    return f() != 0;
}

fn screenCapturePreflight() bool {
    const f = sym(*const fn () callconv(.c) bool, "CGPreflightScreenCaptureAccess") orelse return true;
    return f();
}

pub fn requestAccess(kind: pf.CaptureAccess) void {
    switch (kind) {
        .capture => if (sym(*const fn () callconv(.c) bool, "CGRequestScreenCaptureAccess")) |f| {
            _ = f();
        },
        .semantic => {
            const f = sym(*const fn (?cf.CFDictionaryRef) callconv(.c) u8, "AXIsProcessTrustedWithOptions") orelse return;
            const key_ptr = sym(*const CFStringRef, "kAXTrustedCheckOptionPrompt") orelse return;
            const true_ptr = sym(*const CFTypeRef, "kCFBooleanTrue") orelse return;
            const keys = [_]?*const anyopaque{key_ptr.*};
            const values = [_]?*const anyopaque{true_ptr.*};
            const dict = cf.dictionary(&keys, &values) orelse return;
            defer cf.CFRelease(dict);
            _ = f(dict);
        },
    }
}

/// `copy_ax_value`: one attribute within the remaining budget (+1 reference).
fn copyAxValue(element: AXUIElementRef, attribute: []const u8, deadline: u64) ?CFTypeRef {
    const now = nowNs();
    if (now >= deadline) return null;
    const set_timeout = sym(*const fn (AXUIElementRef, f32) callconv(.c) i32, "AXUIElementSetMessagingTimeout") orelse return null;
    const copy = sym(*const fn (AXUIElementRef, CFStringRef, *?CFTypeRef) callconv(.c) i32, "AXUIElementCopyAttributeValue") orelse return null;
    const remaining_s: f32 = @floatCast(@as(f64, @floatFromInt(deadline - now)) / std.time.ns_per_s);
    if (set_timeout(element, @min(remaining_s, 0.25)) != 0) return null;
    const attr = cf.string(attribute) orelse return null;
    defer cf.CFRelease(attr);
    var value: ?CFTypeRef = null;
    if (copy(element, attr, &value) != 0) return null;
    return value;
}

fn cfStringDup(gpa: std.mem.Allocator, value: CFTypeRef) ?[]u8 {
    if (cf.CFGetTypeID(value) != cf.CFStringGetTypeID()) return null;
    const s: CFStringRef = @ptrCast(value);
    const len = cf.CFStringGetLength(s);
    const buf = gpa.alloc(u8, @as(usize, @intCast(len)) * 4 + 1) catch return null;
    const used = cf.stringToUtf8(s, buf);
    const out = gpa.dupe(u8, used) catch null;
    gpa.free(buf);
    return out;
}

fn axString(gpa: std.mem.Allocator, element: AXUIElementRef, attribute: []const u8, deadline: u64) ?[]u8 {
    const v = copyAxValue(element, attribute, deadline) orelse return null;
    defer cf.CFRelease(v);
    return cfStringDup(gpa, v);
}

fn axScalarString(gpa: std.mem.Allocator, element: AXUIElementRef, attribute: []const u8, deadline: u64) ?[]u8 {
    const v = copyAxValue(element, attribute, deadline) orelse return null;
    defer cf.CFRelease(v);
    if (cfStringDup(gpa, v)) |s| return s;
    if (cf.CFGetTypeID(v) == cf.CFNumberGetTypeID()) {
        var i: i64 = 0;
        if (cf.CFNumberGetValue(@ptrCast(v), cf.kCFNumberSInt64Type, &i) != 0) return std.fmt.allocPrint(gpa, "{d}", .{i}) catch null;
        var f: f64 = 0;
        if (cf.CFNumberGetValue(@ptrCast(v), cf.kCFNumberFloat64Type, &f) != 0) return std.fmt.allocPrint(gpa, "{d}", .{f}) catch null;
    }
    return null;
}

/// `is_secure_ax_element`.
pub fn isSecure(role: []const u8, subrole: ?[]const u8) bool {
    return std.mem.eql(u8, role, "AXSecureTextField") or (subrole != null and std.mem.eql(u8, subrole.?, "AXSecureTextField"));
}

const AxTraversal = struct {
    gpa: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    nodes: usize = 0,
    truncated: bool = false,
    deadline: u64,

    fn visit(self: *AxTraversal, element: AXUIElementRef, depth: usize) void {
        const gpa = self.gpa;
        if (depth > max_ax_depth or self.nodes >= max_ax_nodes or self.out.items.len >= max_ax_bytes or nowNs() >= self.deadline) {
            self.truncated = true;
            return;
        }
        self.nodes += 1;
        const role = axString(gpa, element, "AXRole", self.deadline) orelse (gpa.dupe(u8, "AXElement") catch return);
        defer gpa.free(role);
        const subrole = axString(gpa, element, "AXSubrole", self.deadline);
        defer if (subrole) |s| gpa.free(s);
        const secure = isSecure(role, subrole);
        const title = axString(gpa, element, "AXTitle", self.deadline);
        defer if (title) |s| gpa.free(s);
        const description = axString(gpa, element, "AXDescription", self.deadline);
        defer if (description) |s| gpa.free(s);
        const value = if (secure) null else axScalarString(gpa, element, "AXValue", self.deadline);
        defer if (value) |s| gpa.free(s);
        if (nowNs() >= self.deadline) {
            self.truncated = true;
            return;
        }
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        for (0..depth) |_| line.appendSlice(gpa, "  ") catch return;
        line.appendSlice(gpa, role) catch return;
        const fields = [_]struct { []const u8, ?[]u8 }{ .{ "title=", title }, .{ "description=", description }, .{ "value=", value } };
        for (fields) |f| if (f[1]) |v| if (std.mem.trim(u8, v, " \t\r\n").len > 0) {
            const c = common.compactWhitespace(gpa, v, max_ax_value_chars, true) catch return;
            defer gpa.free(c);
            line.append(gpa, ' ') catch return;
            line.appendSlice(gpa, f[0]) catch return;
            line.appendSlice(gpa, c) catch return;
        };
        line.append(gpa, '\n') catch return;
        const remaining = max_ax_bytes -| self.out.items.len;
        if (line.items.len > remaining) {
            // The largest character boundary <= remaining.
            var end: usize = 0;
            var i: usize = 0;
            while (i < line.items.len and i <= remaining) {
                end = i;
                i += std.unicode.utf8ByteSequenceLength(line.items[i]) catch 1;
            }
            self.out.appendSlice(gpa, line.items[0..end]) catch {};
            self.truncated = true;
            return;
        }
        self.out.appendSlice(gpa, line.items) catch return;
        if (secure) return;
        const children = copyAxValue(element, "AXChildren", self.deadline) orelse {
            if (nowNs() >= self.deadline) self.truncated = true;
            return;
        };
        defer cf.CFRelease(children);
        if (cf.CFGetTypeID(children) != CFArrayGetTypeID()) return;
        const arr: cf.CFArrayRef = @ptrCast(children);
        const n = cf.CFArrayGetCount(arr);
        var k: cf.CFIndex = 0;
        while (k < n) : (k += 1) {
            const child = cf.CFArrayGetValueAtIndex(arr, k) orelse continue;
            self.visit(child, depth + 1);
            if (self.truncated) break;
        }
    }
};

// ---------------------------------------------------------------------------------------
// Global hotkey (Carbon)
// ---------------------------------------------------------------------------------------

const EventTypeSpec = extern struct { event_class: u32, event_kind: u32 };
const EventHotKeyID = extern struct { signature: u32, id: u32 };
const HandlerFn = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) i32;

const command_key: u32 = 1 << 8;
const shift_key: u32 = 1 << 9;
const option_key: u32 = 1 << 11;
const control_key: u32 = 1 << 12;
const event_class_keyboard: u32 = std.mem.readInt(u32, "keyb", .big);
const event_hot_key_pressed: u32 = 5;
const hot_key_signature: u32 = std.mem.readInt(u32, "ZAPS", .big);

/// Main-thread hotkey registration state.
const HotKeyState = struct {
    installed: bool = false,
    target: ?*anyopaque = null,
    hot_key: ?*anyopaque = null,
    current: ?pf.GlobalHotkey = null,
    key_buf: [32]u8 = undefined,
    handler: ?pf.GlobalHotkeyHandler = null,
};
var hk: HotKeyState = .{};
var shortcut_ready: std.atomic.Value(bool) = .init(true);

fn onHotKey(_: ?*anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) i32 {
    if (hk.handler) |h| h.func(h.ctx);
    return 0;
}

/// `start_global_shortcut` + `refresh_global_shortcut` (main thread).
pub fn setHotkey(hotkey: ?pf.GlobalHotkey, handler: pf.GlobalHotkeyHandler) void {
    hk.handler = handler;
    if (!hk.installed) {
        const get_target = sym(*const fn () callconv(.c) ?*anyopaque, "GetApplicationEventTarget") orelse return shortcut_ready.store(false, .release);
        const install = sym(*const fn (?*anyopaque, HandlerFn, u32, *const EventTypeSpec, ?*anyopaque, ?*?*anyopaque) callconv(.c) i32, "InstallEventHandler") orelse return shortcut_ready.store(false, .release);
        const target = get_target();
        const spec: EventTypeSpec = .{ .event_class = event_class_keyboard, .event_kind = event_hot_key_pressed };
        const status = install(target, onHotKey, 1, &spec, null, null);
        if (status != 0) {
            log.warn("Appshot global shortcut handler unavailable ({d})", .{status});
            return shortcut_ready.store(false, .release);
        }
        hk.installed = true;
        hk.target = target;
    }
    const same = if (hk.current) |cur| (if (hotkey) |h| cur.eql(h) else false) else hotkey == null;
    if (same and (hk.hot_key != null or hotkey == null)) return;
    if (hk.hot_key) |ref| {
        if (sym(*const fn (?*anyopaque) callconv(.c) i32, "UnregisterEventHotKey")) |unregister| _ = unregister(ref);
        hk.hot_key = null;
    }
    hk.current = null;
    const h = hotkey orelse return;
    if (h.key.len > hk.key_buf.len) return shortcut_ready.store(false, .release);
    @memcpy(hk.key_buf[0..h.key.len], h.key);
    hk.current = h;
    hk.current.?.key = hk.key_buf[0..h.key.len];
    const key_code = common.macNamedKeycode(h.key) orelse layoutKeycode(h.key) orelse return shortcut_ready.store(false, .release);
    var mods: u32 = 0;
    if (h.control) mods |= control_key;
    if (h.alt) mods |= option_key;
    if (h.shift) mods |= shift_key;
    if (h.platform) mods |= command_key;
    const register = sym(*const fn (u32, u32, EventHotKeyID, ?*anyopaque, u32, *?*anyopaque) callconv(.c) i32, "RegisterEventHotKey") orelse return shortcut_ready.store(false, .release);
    var ref: ?*anyopaque = null;
    const status = register(key_code, mods, .{ .signature = hot_key_signature, .id = 1 }, hk.target, 0, &ref);
    shortcut_ready.store(status == 0, .release);
    if (status == 0) hk.hot_key = ref else log.warn("Appshot global shortcut unavailable ({d})", .{status});
}

/// `layout_keycode`: the virtual key printing `key` on the active ASCII-capable layout.
fn layoutKeycode(key: []const u8) ?u32 {
    if (key.len != 1) return null;
    const copy_source = sym(*const fn () callconv(.c) ?CFTypeRef, "TISCopyCurrentASCIICapableKeyboardLayoutInputSource") orelse return null;
    const get_prop = sym(*const fn (CFTypeRef, CFStringRef) callconv(.c) ?*const anyopaque, "TISGetInputSourceProperty") orelse return null;
    const layout_key = sym(*const CFStringRef, "kTISPropertyUnicodeKeyLayoutData") orelse return null;
    const translate = sym(*const fn (*const anyopaque, u16, u16, u32, u32, u32, *u32, usize, *usize, [*]u16) callconv(.c) i32, "UCKeyTranslate") orelse return null;
    const kbd_type = sym(*const fn () callconv(.c) u16, "LMGetKbdType") orelse return null;
    const source = copy_source() orelse return null;
    defer cf.CFRelease(source);
    const data = get_prop(source, layout_key.*) orelse return null;
    const layout: *const anyopaque = @ptrCast(cf.CFDataGetBytePtr(@ptrCast(data)) orelse return null);
    const want = std.ascii.toLower(key[0]);
    for ([_]u32{ 0, 2 }) |modifiers| {
        var code: u16 = 0;
        while (code < 128) : (code += 1) {
            var out: [4]u16 = undefined;
            var len: usize = 0;
            var dead: u32 = 0;
            if (translate(layout, code, 0, modifiers, kbd_type(), 1, &dead, out.len, &len, &out) == 0 and len == 1 and out[0] < 128 and std.ascii.toLower(@intCast(out[0])) == want)
                return code;
        }
    }
    return null;
}

pub fn capabilities() pf.WindowCaptureCapabilities {
    return .{
        .system = .macos,
        .global_hotkey = if (shortcut_ready.load(.acquire)) .ready else .setup_required,
        .window_capture = if (screenCapturePreflight()) .ready else .permission_required,
        .application_text = if (axTrusted()) .ready else .permission_required,
        .target = .active_window,
    };
}

// ---------------------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------------------

const FrontApp = struct {
    pid: i32,
    name: []u8,
    bundle: ?[]u8,
    icon: ?[]u8,
};

fn nsDataDup(gpa: std.mem.Allocator, data: ?id) ?[]u8 {
    const d = data orelse return null;
    const len = d.msg(NSUInteger, "length", .{});
    const ptr = d.msg(?[*]const u8, "bytes", .{}) orelse return null;
    if (len == 0) return null;
    return gpa.dupe(u8, ptr[0..len]) catch null;
}

fn nsStringDup(gpa: std.mem.Allocator, s: ?id) ?[]u8 {
    const v = s orelse return null;
    return gpa.dupe(u8, ak.stringBytes(v)) catch null;
}

/// `nsimage_png`.
fn nsImagePng(gpa: std.mem.Allocator, image: ?id) ?[]u8 {
    const img = image orelse return null;
    const tiff = img.msg(?id, "TIFFRepresentation", .{}) orelse return null;
    const rep = ak.class("NSBitmapImageRep").msg(?id, "imageRepWithData:", .{tiff}) orelse return null;
    const props = ak.class("NSDictionary").msg(id, "dictionary", .{});
    return nsDataDup(gpa, rep.msg(?id, "representationUsingType:properties:", .{ @as(NSUInteger, 4), props }));
}

fn frontmostApplication(gpa: std.mem.Allocator) ?FrontApp {
    const ws = ak.class("NSWorkspace").msg(id, "sharedWorkspace", .{});
    const app = ws.msg(?id, "frontmostApplication", .{}) orelse return null;
    const pid = app.msg(i32, "processIdentifier", .{});
    return .{
        .pid = pid,
        .name = nsStringDup(gpa, app.msg(?id, "localizedName", .{})) orelse (gpa.dupe(u8, "Application") catch return null),
        .bundle = nsStringDup(gpa, app.msg(?id, "bundleIdentifier", .{})),
        .icon = nsImagePng(gpa, app.msg(?id, "icon", .{})),
    };
}

fn dictValue(dict: cf.CFDictionaryRef, key: CFStringRef) ?*const anyopaque {
    return cf.CFDictionaryGetValue(dict, key);
}

fn dictI64(dict: cf.CFDictionaryRef, key: CFStringRef) ?i64 {
    const v = dictValue(dict, key) orelse return null;
    if (cf.CFGetTypeID(v) != cf.CFNumberGetTypeID()) return null;
    var out: i64 = 0;
    if (cf.CFNumberGetValue(@ptrCast(v), cf.kCFNumberSInt64Type, &out) == 0) return null;
    return out;
}

fn dictRect(dict: cf.CFDictionaryRef, key: CFStringRef) ?CGRect {
    const v = dictValue(dict, key) orelse return null;
    if (cf.CFGetTypeID(v) != CFDictionaryGetTypeID()) return null;
    var r: CGRect = undefined;
    if (!CGRectMakeWithDictionaryRepresentation(@ptrCast(v), &r)) return null;
    return r;
}

/// `visible_capture_window`.
pub fn visibleCaptureWindow(onscreen: bool, alpha: f64, bounds: ?CGRect) bool {
    const b = bounds orelse return false;
    return onscreen and std.math.isFinite(alpha) and alpha > 0 and std.math.isFinite(b.size.width) and
        std.math.isFinite(b.size.height) and b.size.width >= 32 and b.size.height >= 32;
}

/// `same_window_bounds`: within 2 points (AX / WindowServer rounding).
pub fn sameWindowBounds(window: CGRect, focused: CGRect) bool {
    const pairs = [_][2]f64{ .{ window.origin.x, focused.origin.x }, .{ window.origin.y, focused.origin.y }, .{ window.size.width, focused.size.width }, .{ window.size.height, focused.size.height } };
    for (pairs) |p| if (@abs(p[0] - p[1]) > 2.0) return false;
    return true;
}

/// `capture_dimensions`: Retina 2× capped so the longest side is ≤ 4096.
pub fn sckDimensions(width: f64, height: f64) [2]usize {
    const longest = @max(@max(width, height), 1.0);
    const scale = @min(2.0, max_sck_dimension / longest);
    return .{ @intFromFloat(@max(@round(width * scale), 1.0)), @intFromFloat(@max(@round(height * scale), 1.0)) };
}

fn focusedWindowBounds(pid: i32) ?CGRect {
    if (!axTrusted()) return null;
    const create = sym(*const fn (i32) callconv(.c) ?AXUIElementRef, "AXUIElementCreateApplication") orelse return null;
    const value_type_id = sym(*const fn () callconv(.c) cf.CFTypeID, "AXValueGetTypeID") orelse return null;
    const get_value = sym(*const fn (CFTypeRef, u32, *anyopaque) callconv(.c) u8, "AXValueGetValue") orelse return null;
    const app = create(pid) orelse return null;
    const deadline = nowNs() + 250 * std.time.ns_per_ms;
    const focused = copyAxValue(app, "AXFocusedWindow", deadline);
    cf.CFRelease(app);
    const win = focused orelse return null;
    defer cf.CFRelease(win);
    const pos = copyAxValue(win, "AXPosition", deadline) orelse return null;
    defer cf.CFRelease(pos);
    const size = copyAxValue(win, "AXSize", deadline) orelse return null;
    defer cf.CFRelease(size);
    if (cf.CFGetTypeID(pos) != value_type_id() or cf.CFGetTypeID(size) != value_type_id()) return null;
    var origin: CGPoint = .{ .x = 0, .y = 0 };
    var dims: CGSize = .{ .width = 0, .height = 0 };
    if (get_value(pos, 1, &origin) == 0 or get_value(size, 2, &dims) == 0) return null;
    const b: CGRect = .{ .origin = origin, .size = dims };
    return if (visibleCaptureWindow(true, 1.0, b)) b else null;
}

const FrontWindow = struct { id: u32, title: ?[]u8 };

/// `frontmost_window`: the first visible layer-0 window of `pid` (front to back),
/// matching the AX focused window's bounds when known.
fn frontmostWindow(gpa: std.mem.Allocator, pid: i32) ?FrontWindow {
    const list = CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, 0) orelse return null;
    defer cf.CFRelease(list);
    const focused = focusedWindowBounds(pid);
    const n = cf.CFArrayGetCount(list);
    var i: cf.CFIndex = 0;
    while (i < n) : (i += 1) {
        const item = cf.CFArrayGetValueAtIndex(list, i) orelse continue;
        if (cf.CFGetTypeID(item) != CFDictionaryGetTypeID()) continue;
        const dict: cf.CFDictionaryRef = @ptrCast(item);
        if (dictI64(dict, kCGWindowOwnerPID) != pid or dictI64(dict, kCGWindowLayer) != 0) continue;
        const num = dictI64(dict, kCGWindowNumber) orelse return null;
        if (num < 0 or num > std.math.maxInt(u32)) return null;
        const bounds = dictRect(dict, kCGWindowBounds);
        const onscreen = if (dictValue(dict, kCGWindowIsOnscreen)) |v| (cf.CFGetTypeID(v) == CFBooleanGetTypeID() and cf.CFBooleanGetValue(@ptrCast(v)) != 0) else false;
        const alpha = if (dictValue(dict, kCGWindowAlpha)) |v| (cf.numberValue(v) orelse 0) else 0;
        if (!visibleCaptureWindow(onscreen, alpha, bounds)) continue;
        if (focused) |f| if (!sameWindowBounds(bounds.?, f)) continue;
        var title: ?[]u8 = null;
        if (dictValue(dict, kCGWindowName)) |v| if (cfStringDup(gpa, v)) |t| {
            if (std.mem.trim(u8, t, " \t\r\n").len > 0) title = t else gpa.free(t);
        };
        return .{ .id = @intCast(num), .title = title };
    }
    return null;
}

fn windowBounds(window_id: u32) ?CGRect {
    const list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, window_id) orelse return null;
    defer cf.CFRelease(list);
    if (cf.CFArrayGetCount(list) == 0) return null;
    const item = cf.CFArrayGetValueAtIndex(list, 0) orelse return null;
    if (cf.CFGetTypeID(item) != CFDictionaryGetTypeID()) return null;
    return dictRect(@ptrCast(item), kCGWindowBounds);
}

/// The PNG of a CGImage via NSBitmapImageRep (`encode_png`).
fn encodePng(gpa: std.mem.Allocator, image: cf.CGImageRef) union(enum) { ok: []u8, err: pf.WindowCaptureResult } {
    const w = cf.CGImageGetWidth(image);
    const h = cf.CGImageGetHeight(image);
    if (w > std.math.maxInt(u32) or h > std.math.maxInt(u32)) return .{ .err = common.failed(gpa, "Screenshot width exceeds the capture budget", .{}) };
    switch (common.validateDimensions(@intCast(w), @intCast(h))) {
        .ok => {},
        .err => |e| return .{ .err = common.failedDims(gpa, e) },
    }
    const rep0 = ak.class("NSBitmapImageRep").msg(?id, "alloc", .{}) orelse return .{ .err = common.failed(gpa, "The screenshot could not be encoded.", .{}) };
    const rep = rep0.msg(?id, "initWithCGImage:", .{image}) orelse return .{ .err = common.failed(gpa, "The screenshot could not be encoded.", .{}) };
    defer rep.release();
    const props = ak.class("NSDictionary").msg(id, "dictionary", .{});
    const data = rep.msg(?id, "representationUsingType:properties:", .{ @as(NSUInteger, 4), props }) orelse return .{ .err = common.failed(gpa, "The screenshot could not be encoded.", .{}) };
    const len = data.msg(NSUInteger, "length", .{});
    if (len > common.max_attachment_bytes) return .{ .err = common.failed(gpa, "The captured window is larger than Zeron's 24 MB image limit.", .{}) };
    const bytes = nsDataDup(gpa, data) orelse return .{ .err = common.failed(gpa, "The captured window was empty.", .{}) };
    return .{ .ok = bytes };
}

/// `capture_png`: the CoreGraphics fallback at nominal (1×) resolution.
fn capturePngFallback(gpa: std.mem.Allocator, window_id: u32) union(enum) { ok: []u8, err: pf.WindowCaptureResult } {
    const b = windowBounds(window_id) orelse return .{ .err = .{ .err = .no_eligible_window } };
    if (!std.math.isFinite(b.origin.x) or !std.math.isFinite(b.origin.y) or !std.math.isFinite(b.size.width) or
        !std.math.isFinite(b.size.height) or b.size.width <= 0 or b.size.height <= 0 or
        b.size.width > std.math.maxInt(u32) or b.size.height > std.math.maxInt(u32))
        return .{ .err = .{ .err = .no_eligible_window } };
    switch (common.validateDimensions(@intFromFloat(@ceil(b.size.width)), @intFromFloat(@ceil(b.size.height)))) {
        .ok => {},
        .err => |e| return .{ .err = common.failedDims(gpa, e) },
    }
    const create = cf.cgWindowListCreateImage() orelse return .{ .err = common.failed(gpa, "The application window could not be captured.", .{}) };
    const image = create(b, kCGWindowListOptionIncludingWindow, window_id, kCGWindowImageNominalResolution | kCGWindowImageBoundsIgnoreFraming) orelse
        return .{ .err = common.failed(gpa, "The application window could not be captured.", .{}) };
    defer cf.CGImageRelease(image);
    return switch (encodePng(gpa, image)) {
        .ok => |p| .{ .ok = p },
        .err => |e| .{ .err = e },
    };
}

// -- ScreenCaptureKit -----------------------------------------------------------------------

const BlockDescriptor = extern struct { reserved: c_ulong = 0, size: c_ulong };

/// Shared between the waiting thread and a completion block (which may fire after a
/// timeout): whoever drops the last reference frees it.
const Waiter = struct {
    refs: std.atomic.Value(u32) = .init(2),
    sem: *anyopaque,
    /// +1 object (SCShareableContent / CGImage), or null.
    object: ?*anyopaque = null,
    is_cf: bool = false,
    err: [256]u8 = undefined,
    err_len: usize = 0,
    abandoned: std.atomic.Value(bool) = .init(false),

    fn create(is_cf: bool) ?*Waiter {
        const sem = dispatch_semaphore_create(0) orelse return null;
        const w = std.heap.c_allocator.create(Waiter) catch {
            dispatch_release(sem);
            return null;
        };
        w.* = .{ .sem = sem, .is_cf = is_cf };
        return w;
    }

    fn releaseObject(self: *Waiter) void {
        const o = self.object orelse return;
        if (self.is_cf) cf.CFRelease(o) else @as(id, @ptrCast(o)).release();
        self.object = null;
    }

    fn unref(self: *Waiter) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.releaseObject();
        dispatch_release(self.sem);
        std.heap.c_allocator.destroy(self);
    }

    fn complete(self: *Waiter, object: ?*anyopaque, err: ?id, fallback: []const u8) void {
        if (object) |o| {
            if (self.is_cf) _ = cf.CFRetain(o) else _ = @as(id, @ptrCast(@constCast(o))).retain();
            self.object = @constCast(o);
        } else {
            const msg: []const u8 = if (err) |e| (if (e.msg(?id, "localizedDescription", .{})) |d| ak.stringBytes(d) else fallback) else fallback;
            const n = @min(msg.len, self.err.len);
            @memcpy(self.err[0..n], msg[0..n]);
            self.err_len = n;
        }
        if (self.abandoned.load(.acquire)) self.releaseObject();
        _ = dispatch_semaphore_signal(self.sem);
        self.unref();
    }

    /// Waits up to 4 s; returns the +1 object (ownership moves to the caller).
    fn wait(self: *Waiter) union(enum) { ok: *anyopaque, err: []const u8, timeout } {
        const deadline = ak.dispatch_time(ak.DISPATCH_TIME_NOW, sck_timeout_ns);
        if (dispatch_semaphore_wait(self.sem, deadline) != 0) {
            self.abandoned.store(true, .release);
            return .timeout;
        }
        if (self.object) |o| {
            self.object = null;
            return .{ .ok = o };
        }
        return .{ .err = self.err[0..self.err_len] };
    }
};

const ObjBlock = extern struct {
    isa: *const anyopaque,
    flags: c_int = 0,
    reserved: c_int = 0,
    invoke: *const fn (*const ObjBlock, ?*anyopaque, ?id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
    waiter: *Waiter,
};
const obj_block_descriptor: BlockDescriptor = .{ .size = @sizeOf(ObjBlock) };

fn onShareableContent(block: *const ObjBlock, content: ?*anyopaque, err: ?id) callconv(.c) void {
    block.waiter.complete(content, err, "ScreenCaptureKit could not enumerate windows");
}

fn onScreenshot(block: *const ObjBlock, image: ?*anyopaque, err: ?id) callconv(.c) void {
    block.waiter.complete(image, err, "ScreenCaptureKit returned no screenshot");
}

fn loadScreenCaptureKit() bool {
    const S = struct {
        var state: std.atomic.Value(u8) = .init(0);
    };
    switch (S.state.load(.acquire)) {
        1 => return true,
        2 => return false,
        else => {},
    }
    const ok = dlopen("/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit", 1) != null;
    S.state.store(if (ok) 1 else 2, .release);
    return ok;
}

const SckOutcome = union(enum) { unavailable, ok: struct { png: []u8, title: ?[]u8 }, err: []u8 };

/// `capture_with_screen_capture_kit` for the preserved window id.
fn captureWithScreenCaptureKit(gpa: std.mem.Allocator, pid: i32, window_id: u32) SckOutcome {
    if (!loadScreenCaptureKit()) return .unavailable;
    const shareable = objc.getClass("SCShareableContent") orelse return .unavailable;
    const filter_class = objc.getClass("SCContentFilter") orelse return .unavailable;
    const config_class = objc.getClass("SCStreamConfiguration") orelse return .unavailable;
    const manager = objc.getClass("SCScreenshotManager") orelse return .unavailable;

    const cw = Waiter.create(false) orelse return .{ .err = gpa.dupe(u8, "ScreenCaptureKit is unavailable") catch &empty_buf };
    defer cw.unref();
    const content_block: ObjBlock = .{ .isa = &_NSConcreteStackBlock, .invoke = onShareableContent, .descriptor = &obj_block_descriptor, .waiter = cw };
    shareable.msg(void, "getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:", .{ objc.toBOOL(true), objc.toBOOL(false), @as(*const anyopaque, @ptrCast(&content_block)) });
    const content: id = switch (cw.wait()) {
        .ok => |o| @ptrCast(o),
        .err => |m| return .{ .err = gpa.dupe(u8, m) catch &empty_buf },
        .timeout => return .{ .err = gpa.dupe(u8, "Timed out while enumerating capturable windows") catch &empty_buf },
    };
    defer content.release();

    // `select_screen_capture_kit_window`.
    const windows = content.msg(id, "windows", .{});
    var selected: ?id = null;
    var title: ?[]u8 = null;
    var size: [2]f64 = .{ 1920, 1080 };
    var i: NSUInteger = 0;
    const count = ak.arrayCount(windows);
    while (i < count) : (i += 1) {
        const w = ak.arrayAt(windows, i);
        const owner = w.msg(?id, "owningApplication", .{}) orelse continue;
        if (owner.msg(i32, "processID", .{}) != pid or w.msg(NSInteger, "windowLayer", .{}) != 0) continue;
        if (w.msg(u32, "windowID", .{}) != window_id) continue;
        if (windowBounds(window_id)) |b| size = .{ @max(b.size.width, 1.0), @max(b.size.height, 1.0) };
        title = nsStringDup(gpa, w.msg(?id, "title", .{}));
        selected = w;
        break;
    }
    const window = selected orelse return .{ .err = gpa.dupe(u8, "The frontmost application has no ScreenCaptureKit window") catch &empty_buf };
    const dims = sckDimensions(size[0], size[1]);
    const filter = (filter_class.msg(?id, "alloc", .{}) orelse return .{ .err = gpa.dupe(u8, "ScreenCaptureKit filter failed") catch &empty_buf })
        .msg(?id, "initWithDesktopIndependentWindow:", .{window}) orelse return .{ .err = gpa.dupe(u8, "ScreenCaptureKit filter failed") catch &empty_buf };
    defer filter.release();
    const config = config_class.msg(?id, "new", .{}) orelse return .{ .err = gpa.dupe(u8, "ScreenCaptureKit configuration failed") catch &empty_buf };
    defer config.release();
    config.msg(void, "setWidth:", .{@as(usize, dims[0])});
    config.msg(void, "setHeight:", .{@as(usize, dims[1])});
    config.msg(void, "setScalesToFit:", .{objc.toBOOL(true)});
    config.msg(void, "setPreservesAspectRatio:", .{objc.toBOOL(true)});
    config.msg(void, "setShowsCursor:", .{objc.toBOOL(false)});
    config.msg(void, "setIgnoreShadowsSingleWindow:", .{objc.toBOOL(true)});

    const iw = Waiter.create(true) orelse return .{ .err = gpa.dupe(u8, "ScreenCaptureKit is unavailable") catch &empty_buf };
    defer iw.unref();
    const image_block: ObjBlock = .{ .isa = &_NSConcreteStackBlock, .invoke = onScreenshot, .descriptor = &obj_block_descriptor, .waiter = iw };
    manager.msg(void, "captureImageWithFilter:configuration:completionHandler:", .{ filter, config, @as(*const anyopaque, @ptrCast(&image_block)) });
    const image: cf.CGImageRef = switch (iw.wait()) {
        .ok => |o| @ptrCast(o),
        .err => |m| {
            if (title) |t| gpa.free(t);
            return .{ .err = gpa.dupe(u8, m) catch &empty_buf };
        },
        .timeout => {
            if (title) |t| gpa.free(t);
            return .{ .err = gpa.dupe(u8, "Timed out while capturing the frontmost window") catch &empty_buf };
        },
    };
    defer cf.CGImageRelease(image);
    return switch (encodePng(gpa, image)) {
        .ok => |png| .{ .ok = .{ .png = png, .title = title } },
        .err => |e| blk: {
            if (title) |t| gpa.free(t);
            var r = e;
            const msg = if (r.err == .failed) (gpa.dupe(u8, r.err.failed) catch &empty_buf) else (gpa.dupe(u8, "The captured window was empty.") catch &empty_buf);
            r.deinit(gpa);
            break :blk .{ .err = msg };
        },
    };
}

/// `preserved_accessibility_window`: the AX focused window, only while the CG
/// frontmost window is still `window_id` (+1 reference).
fn preservedAccessibilityWindow(gpa: std.mem.Allocator, pid: i32, window_id: u32) ?CFTypeRef {
    if (!axTrusted()) return null;
    const create = sym(*const fn (i32) callconv(.c) ?AXUIElementRef, "AXUIElementCreateApplication") orelse return null;
    const app = create(pid) orelse return null;
    const deadline = nowNs() + 250 * std.time.ns_per_ms;
    const focused = copyAxValue(app, "AXFocusedWindow", deadline);
    cf.CFRelease(app);
    const win = focused orelse return null;
    const front = frontmostWindow(gpa, pid) orelse {
        cf.CFRelease(win);
        return null;
    };
    if (front.title) |t| gpa.free(t);
    if (front.id != window_id) {
        cf.CFRelease(win);
        return null;
    }
    return win;
}

const CaptureJob = struct {
    gpa: std.mem.Allocator,
    done: pf.WindowCaptureCallback,
    result: pf.WindowCaptureResult = undefined,

    fn pixelsReady(ctx: ?*anyopaque) callconv(.c) void {
        const job: *CaptureJob = @ptrCast(@alignCast(ctx.?));
        if (job.done.pixels_ready) |f| f(job.done.ctx);
    }

    fn finish(ctx: ?*anyopaque) callconv(.c) void {
        const job: *CaptureJob = @ptrCast(@alignCast(ctx.?));
        job.done.done(job.done.ctx, job.gpa, &job.result);
        job.gpa.destroy(job);
    }

    fn main(job: *CaptureJob) void {
        const pool = objc.AutoreleasePool.push();
        job.result = captureFrontmost(job);
        pool.pop();
        dispatcher_mod.onMain(job, finish);
    }
};

/// Capture the frontmost window on a worker thread; `done` runs on the main thread.
pub fn capture(gpa: std.mem.Allocator, done: pf.WindowCaptureCallback) void {
    const job = gpa.create(CaptureJob) catch {
        var r = common.failed(gpa, "Could not start the capture.", .{});
        return done.done(done.ctx, gpa, &r);
    };
    job.* = .{ .gpa = gpa, .done = done };
    const t = std.Thread.spawn(.{}, CaptureJob.main, .{job}) catch {
        gpa.destroy(job);
        var r = common.failed(gpa, "Could not start the capture.", .{});
        return done.done(done.ctx, gpa, &r);
    };
    t.detach();
}

/// `capture_frontmost_window`.
fn captureFrontmost(job: *CaptureJob) pf.WindowCaptureResult {
    const gpa = job.gpa;
    const app = frontmostApplication(gpa) orelse return .{ .err = .no_eligible_window };
    var app_owned = true;
    defer if (app_owned) {
        gpa.free(app.name);
        if (app.bundle) |b| gpa.free(b);
        if (app.icon) |i| gpa.free(i);
    };
    if (app.pid == getpid()) return .{ .err = .self_capture };
    if (!screenCapturePreflight()) {
        requestAccess(.capture);
        return .{ .err = .permission_required };
    }
    // Resolve the front-to-back window once, before asynchronous capture can let
    // focus move; every path stays bound to this exact window id.
    const preserved = frontmostWindow(gpa, app.pid) orelse return .{ .err = .no_eligible_window };
    var title = preserved.title;
    errdefer if (title) |t| gpa.free(t);
    // Retain the AX window before capture; never resolve focus again afterwards.
    const ax_window = preservedAccessibilityWindow(gpa, app.pid, preserved.id);
    defer if (ax_window) |w| cf.CFRelease(w);
    const png: []u8 = switch (captureWithScreenCaptureKit(gpa, app.pid, preserved.id)) {
        .ok => |o| blk: {
            if (title) |t| gpa.free(t);
            title = o.title;
            break :blk o.png;
        },
        .unavailable => switch (capturePngFallback(gpa, preserved.id)) {
            .ok => |p| p,
            .err => |e| {
                if (title) |t| gpa.free(t);
                return e;
            },
        },
        .err => |msg| blk: {
            log.warn("ScreenCaptureKit Appshot failed ({s}); using CoreGraphics fallback", .{msg});
            gpa.free(msg);
            break :blk switch (capturePngFallback(gpa, preserved.id)) {
                .ok => |p| p,
                .err => |e| {
                    if (title) |t| gpa.free(t);
                    return e;
                },
            };
        },
    };
    // Pixels are saved: acknowledge before the (slower) semantic enrichment.
    dispatcher_mod.onMain(job, CaptureJob.pixelsReady);
    var ax: AxTraversal = .{ .gpa = gpa, .deadline = nowNs() + ax_deadline_ns };
    if (ax_window) |w| ax.visit(w, 0);
    const content = ax.out.toOwnedSlice(gpa) catch &empty_buf;
    app_owned = false;
    return .{ .ok = .{
        .png = png,
        .app_name = app.name,
        .bundle_identifier = app.bundle,
        .window_title = title,
        .accessibility = content,
        .accessibility_truncated = ax.truncated,
        .icon_png = app.icon,
    } };
}

/// `foreground_after_capture`: LaunchServices activation (main thread). A bare,
/// unbundled binary keeps the ordinary window activation instead.
pub fn foregroundAfterCapture() void {
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    const ws = ak.class("NSWorkspace").msg(id, "sharedWorkspace", .{});
    const bundle = ak.class("NSBundle").msg(id, "mainBundle", .{});
    const url = bundle.msg(?id, "bundleURL", .{}) orelse return;
    const ext = url.msg(?id, "pathExtension", .{}) orelse return;
    if (!std.mem.eql(u8, ak.stringBytes(ext), "app")) return;
    const config_class = objc.getClass("NSWorkspaceOpenConfiguration") orelse return;
    const config = config_class.msg(?id, "configuration", .{}) orelse return;
    config.msg(void, "setActivates:", .{objc.toBOOL(true)});
    config.msg(void, "setCreatesNewApplicationInstance:", .{objc.toBOOL(false)});
    ws.msg(void, "openApplicationAtURL:configuration:completionHandler:", .{ url, config, @as(?*const anyopaque, null) });
}

const testing = std.testing;

test "capture geometry helpers" {
    const r = struct {
        fn f(x: f64, y: f64, w: f64, h: f64) CGRect {
            return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
        }
    }.f;
    const focused = r(80, 40, 1000, 700);
    const candidates = [_]CGRect{ r(0, 0, 128, 128), r(0, 0, 1400, 900), focused };
    var hit: ?usize = null;
    for (candidates, 0..) |c, ix| if (sameWindowBounds(c, focused)) {
        hit = ix;
        break;
    };
    try testing.expectEqual(@as(?usize, 2), hit);
    try testing.expect(!visibleCaptureWindow(true, 1.0, r(0, 0, 1, 1)));
    const b = r(0, 0, 200, 120);
    try testing.expect(!visibleCaptureWindow(false, 1.0, b));
    try testing.expect(!visibleCaptureWindow(true, 0.0, b));
    try testing.expect(!visibleCaptureWindow(true, std.math.nan(f64), b));
    try testing.expect(!visibleCaptureWindow(true, 1.0, null));
    try testing.expect(visibleCaptureWindow(true, 1.0, b));
    try testing.expectEqual([2]usize{ 2880, 1800 }, sckDimensions(1440, 900));
    try testing.expectEqual([2]usize{ 4096, 2304 }, sckDimensions(5120, 2880));
    try testing.expect(isSecure("AXTextField", "AXSecureTextField"));
    try testing.expect(isSecure("AXSecureTextField", null));
    try testing.expect(!isSecure("AXTextField", "AXSearchField"));
}
