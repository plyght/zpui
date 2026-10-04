//! AppKit/Foundation constants and helpers, plus the libdispatch, CoreVideo
//! and Carbon (HIToolbox) C functions the macOS backend calls.
//!
//! Enum values are copied from the macOS SDK headers (NSWindow.h, NSEvent.h,
//! NSView.h, ...). Every selector the backend sends with a non-trivial
//! signature goes through a typed helper here so its C types live in one place.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const cf = @import("cf.zig");

pub const id = objc.id;
pub const NSInteger = objc.NSInteger;
pub const NSUInteger = objc.NSUInteger;
pub const CGFloat = objc.CGFloat;
pub const NSPoint = objc.CGPoint;
pub const NSSize = objc.CGSize;
pub const NSRect = objc.CGRect;
pub const NSRange = objc.NSRange;
pub const BOOL = objc.BOOL;
pub const YES = objc.YES;
pub const NO = objc.NO;

/// `NSNotFound` (== NSIntegerMax).
pub const NSNotFound: NSUInteger = @as(NSUInteger, std.math.maxInt(NSInteger));

// ---------------------------------------------------------------------------
// Objective-C type encodings for runtime-declared methods
// ---------------------------------------------------------------------------

/// `BOOL` encodes as `B` (C bool) on arm64 and `c` (signed char) on x86_64.
pub const enc_bool = if (builtin.cpu.arch == .aarch64) "B" else "c";
pub const enc_rect = "{CGRect={CGPoint=dd}{CGSize=dd}}";
pub const enc_point = "{CGPoint=dd}";
pub const enc_size = "{CGSize=dd}";
pub const enc_range = "{_NSRange=QQ}";

// ---------------------------------------------------------------------------
// Enums / option sets
// ---------------------------------------------------------------------------

pub const NSApplicationActivationPolicyRegular: NSInteger = 0;
pub const NSTerminateCancel: NSUInteger = 0;
pub const NSBackingStoreBuffered: NSUInteger = 2;

pub const WindowStyleMask = struct {
    pub const titled: NSUInteger = 1 << 0;
    pub const closable: NSUInteger = 1 << 1;
    pub const miniaturizable: NSUInteger = 1 << 2;
    pub const resizable: NSUInteger = 1 << 3;
    pub const nonactivating_panel: NSUInteger = 1 << 7;
    pub const full_screen: NSUInteger = 1 << 14;
    pub const full_size_content_view: NSUInteger = 1 << 15;
};

pub const NSWindowTitleHidden: NSInteger = 1;
pub const NSNormalWindowLevel: NSInteger = 0;
pub const NSFloatingWindowLevel: NSInteger = 3;
pub const NSPopUpMenuWindowLevel: NSInteger = 101;
pub const NSWindowOcclusionStateVisible: NSUInteger = 1 << 1;
pub const NSWindowAbove: NSInteger = 1;
pub const NSWindowBelow: NSInteger = -1;
pub const NSWindowCloseButton: NSUInteger = 0;
pub const NSWindowMiniaturizeButton: NSUInteger = 1;
pub const NSWindowZoomButton: NSUInteger = 2;
pub const NSWindowAnimationBehaviorUtilityWindow: NSInteger = 4;
pub const NSWindowCollectionBehaviorCanJoinAllSpaces: NSUInteger = 1 << 0;
pub const NSWindowCollectionBehaviorFullScreenAuxiliary: NSUInteger = 1 << 8;

pub const NSViewWidthSizable: NSUInteger = 2;
pub const NSViewHeightSizable: NSUInteger = 16;
pub const NSViewLayerContentsRedrawDuringViewResize: NSInteger = 2;

pub const NSTrackingMouseEnteredAndExited: NSUInteger = 0x01;
pub const NSTrackingMouseMoved: NSUInteger = 0x02;
pub const NSTrackingActiveAlways: NSUInteger = 0x80;
pub const NSTrackingInVisibleRect: NSUInteger = 0x200;

pub const NSVisualEffectMaterialUnderWindowBackground: NSInteger = 21;
pub const NSVisualEffectBlendingModeBehindWindow: NSInteger = 0;
pub const NSVisualEffectStateActive: NSInteger = 1;

pub const NSDragOperationNone: NSUInteger = 0;
pub const NSDragOperationCopy: NSUInteger = 1;

pub const NSEventModifierFlags = struct {
    pub const caps_lock: NSUInteger = 1 << 16;
    pub const shift: NSUInteger = 1 << 17;
    pub const control: NSUInteger = 1 << 18;
    pub const option: NSUInteger = 1 << 19;
    pub const command: NSUInteger = 1 << 20;
    pub const function: NSUInteger = 1 << 23;
};

/// `NSEventType` raw values.
pub const NSEventType = struct {
    pub const left_mouse_down: NSUInteger = 1;
    pub const left_mouse_up: NSUInteger = 2;
    pub const right_mouse_down: NSUInteger = 3;
    pub const right_mouse_up: NSUInteger = 4;
    pub const mouse_moved: NSUInteger = 5;
    pub const left_mouse_dragged: NSUInteger = 6;
    pub const right_mouse_dragged: NSUInteger = 7;
    pub const mouse_entered: NSUInteger = 8;
    pub const mouse_exited: NSUInteger = 9;
    pub const key_down: NSUInteger = 10;
    pub const key_up: NSUInteger = 11;
    pub const flags_changed: NSUInteger = 12;
    pub const application_defined: NSUInteger = 15;
    pub const scroll_wheel: NSUInteger = 22;
    pub const other_mouse_down: NSUInteger = 25;
    pub const other_mouse_up: NSUInteger = 26;
    pub const other_mouse_dragged: NSUInteger = 27;
    pub const magnify: NSUInteger = 30;
    pub const swipe: NSUInteger = 31;
    pub const pressure: NSUInteger = 34;
};

/// `NSEventPhase` bits.
pub const NSEventPhase = struct {
    pub const began: NSUInteger = 0x1;
    pub const ended: NSUInteger = 0x8;
    pub const may_begin: NSUInteger = 0x20;
};

/// `NS*FunctionKey` private-use code points (NSEvent.h).
pub const FunctionKey = struct {
    pub const up: u16 = 0xF700;
    pub const down: u16 = 0xF701;
    pub const left: u16 = 0xF702;
    pub const right: u16 = 0xF703;
    pub const f1: u16 = 0xF704;
    pub const f35: u16 = 0xF726;
    pub const delete: u16 = 0xF728;
    pub const home: u16 = 0xF729;
    pub const end: u16 = 0xF72B;
    pub const page_up: u16 = 0xF72C;
    pub const page_down: u16 = 0xF72D;
    pub const help: u16 = 0xF746;
    pub const mode_switch: u16 = 0xF747;
};

// ---------------------------------------------------------------------------
// AppKit globals
// ---------------------------------------------------------------------------

pub extern "c" const NSAppearanceNameAqua: id;
pub extern "c" const NSAppearanceNameDarkAqua: id;
pub extern "c" const NSAppearanceNameVibrantLight: id;
pub extern "c" const NSAppearanceNameVibrantDark: id;
pub extern "c" const NSPasteboardTypeString: id;
/// Deprecated alias of the legacy file-list pasteboard type; still what drag
/// sources put on the pasteboard for Finder file drags (zui uses it too).
pub extern "c" const NSFilenamesPboardType: id;
/// `orderFrontStandardAboutPanelWithOptions:` keys (AppKit, macOS 10.13+).
pub extern "c" const NSAboutPanelOptionApplicationName: id;
pub extern "c" const NSAboutPanelOptionApplicationVersion: id;
pub extern "c" const NSAboutPanelOptionVersion: id;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

pub fn class(comptime name: [:0]const u8) *objc.Class {
    return objc.getClass(name) orelse std.debug.panic("Objective-C class {s} not found (framework not linked?)", .{name});
}

pub fn sharedApp() id {
    return class("NSApplication").msg(id, "sharedApplication", .{});
}

/// Send a message returning a struct, using `objc_msgSend_stret` where the ABI needs it.
pub inline fn msgStruct(comptime Ret: type, target: anytype, comptime selector: [:0]const u8, args: anytype) Ret {
    return objc.msgSendStret(Ret, target, objc.cachedSel(selector), args);
}

pub fn frame(view_or_window: id) NSRect {
    return msgStruct(NSRect, view_or_window, "frame", .{});
}

pub fn bounds(view: id) NSRect {
    return msgStruct(NSRect, view, "bounds", .{});
}

pub fn nsString(bytes: []const u8) id {
    const s = class("NSString").msg(?id, "alloc", .{}).?;
    const init = s.msg(?id, "initWithBytes:length:encoding:", .{ bytes.ptr, @as(NSUInteger, bytes.len), @as(NSUInteger, 4) }) orelse
        return class("NSString").msg(id, "string", .{});
    return init.autorelease();
}

/// UTF-8 bytes of an NSString (borrowed; valid for the current autorelease pool).
pub fn stringBytes(str: id) []const u8 {
    const ptr = str.msg(?[*:0]const u8, "UTF8String", .{}) orelse return "";
    return std.mem.span(ptr);
}

pub fn isEqualToString(a: id, b: id) bool {
    return a.msg(BOOL, "isEqualToString:", .{b}) == YES;
}

pub fn arrayCount(array: id) NSUInteger {
    return array.msg(NSUInteger, "count", .{});
}

pub fn arrayAt(array: id, index: NSUInteger) id {
    return array.msg(id, "objectAtIndex:", .{index});
}

/// `NSScreenNumber` from a screen's device description (its CGDirectDisplayID).
pub fn displayIdForScreen(screen: ?id) ?u32 {
    const s = screen orelse return null;
    const desc = s.msg(?id, "deviceDescription", .{}) orelse return null;
    const num = desc.msg(?id, "objectForKey:", .{objc.nsString("NSScreenNumber")}) orelse return null;
    return @truncate(num.msg(NSUInteger, "unsignedIntegerValue", .{}));
}

/// The NSScreen whose display id is `display_id`, if connected.
pub fn screenForDisplayId(display_id: u32) ?id {
    const screens = class("NSScreen").msg(id, "screens", .{});
    var i: NSUInteger = 0;
    while (i < arrayCount(screens)) : (i += 1) {
        const screen = arrayAt(screens, i);
        if (displayIdForScreen(screen) == display_id) return screen;
    }
    return null;
}

/// `CGDisplayCreateUUIDFromDisplayID` (ColorSync, re-exported through
/// ApplicationServices) looked up at runtime so no extra framework is linked; raw bytes.
pub fn displayUuid(display_id: u32) ?[16]u8 {
    const Fn = *const fn (u32) callconv(.c) ?*anyopaque;
    const CFUUIDBytes = extern struct { bytes: [16]u8 };
    const BytesFn = *const fn (?*anyopaque) callconv(.c) CFUUIDBytes;
    const S = struct {
        extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
        extern "c" fn CFRelease(cf: *anyopaque) void;
    };
    const rtld_default: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
    const create: Fn = @ptrCast(@alignCast(S.dlsym(rtld_default, "CGDisplayCreateUUIDFromDisplayID") orelse return null));
    const get_bytes: BytesFn = @ptrCast(@alignCast(S.dlsym(rtld_default, "CFUUIDGetUUIDBytes") orelse return null));
    const uuid = create(display_id) orelse return null;
    defer S.CFRelease(uuid);
    return get_bytes(uuid).bytes;
}

pub const OperatingSystemVersion = extern struct { major: NSInteger, minor: NSInteger, patch: NSInteger };

pub fn osAtLeast(major: NSInteger, minor: NSInteger, patch: NSInteger) bool {
    const info = class("NSProcessInfo").msg(id, "processInfo", .{});
    return info.msg(BOOL, "isOperatingSystemAtLeastVersion:", .{OperatingSystemVersion{ .major = major, .minor = minor, .patch = patch }}) == YES;
}

/// Maps an `NSAppearance` to the platform enum (zui `window_appearance_from_native`).
pub fn appearanceFromNative(appearance: ?id) @import("../platform.zig").WindowAppearance {
    const a = appearance orelse return .light;
    const name = a.msg(?id, "name", .{}) orelse return .light;
    if (isEqualToString(name, NSAppearanceNameVibrantLight)) return .vibrant_light;
    if (isEqualToString(name, NSAppearanceNameVibrantDark)) return .vibrant_dark;
    if (isEqualToString(name, NSAppearanceNameDarkAqua)) return .dark;
    if (isEqualToString(name, NSAppearanceNameAqua)) return .light;
    // Accessibility high-contrast variants etc.: classify by "Dark" in the name.
    if (std.mem.indexOf(u8, stringBytes(name), "Dark") != null) return .dark;
    return .light;
}

// ---------------------------------------------------------------------------
// libdispatch (libSystem)
// ---------------------------------------------------------------------------

pub const dispatch_queue_t = *opaque {};
pub const dispatch_source_t = *opaque {};
pub const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;
pub const dispatch_time_t = u64;
pub const DISPATCH_TIME_NOW: dispatch_time_t = 0;

/// `qos_class_t` values (sys/qos.h) accepted by `dispatch_get_global_queue`.
pub const QOS_CLASS_USER_INTERACTIVE: isize = 0x21;
pub const QOS_CLASS_USER_INITIATED: isize = 0x19;
pub const QOS_CLASS_DEFAULT: isize = 0x15;
pub const QOS_CLASS_UTILITY: isize = 0x11;

/// `dispatch_get_main_queue()` is a macro for `&_dispatch_main_q`.
extern "c" var _dispatch_main_q: u8;
/// `DISPATCH_SOURCE_TYPE_DATA_ADD` is a macro for `&_dispatch_source_type_data_add`.
extern "c" const _dispatch_source_type_data_add: u8;

pub fn mainQueue() dispatch_queue_t {
    return @ptrCast(&_dispatch_main_q);
}

pub fn sourceTypeDataAdd() *const anyopaque {
    return @ptrCast(&_dispatch_source_type_data_add);
}

pub extern "c" fn dispatch_get_global_queue(identifier: isize, flags: usize) dispatch_queue_t;
pub extern "c" fn dispatch_async_f(queue: dispatch_queue_t, context: ?*anyopaque, work: dispatch_function_t) void;
pub extern "c" fn dispatch_after_f(when: dispatch_time_t, queue: dispatch_queue_t, context: ?*anyopaque, work: dispatch_function_t) void;
pub extern "c" fn dispatch_time(when: dispatch_time_t, delta: i64) dispatch_time_t;
pub extern "c" fn dispatch_source_create(source_type: *const anyopaque, handle: usize, mask: usize, queue: ?dispatch_queue_t) ?dispatch_source_t;
pub extern "c" fn dispatch_set_context(object: *anyopaque, context: ?*anyopaque) void;
pub extern "c" fn dispatch_source_set_event_handler_f(source: dispatch_source_t, handler: ?dispatch_function_t) void;
pub extern "c" fn dispatch_source_merge_data(source: dispatch_source_t, value: usize) void;
pub extern "c" fn dispatch_source_cancel(source: dispatch_source_t) void;
pub extern "c" fn dispatch_resume(object: *anyopaque) void;
pub extern "c" fn dispatch_release(object: *anyopaque) void;

pub extern "c" fn pthread_main_np() c_int;
/// Monotonic nanoseconds (`CLOCK_UPTIME_RAW` = 8 stops during sleep, like mach_absolute_time).
pub extern "c" fn clock_gettime_nsec_np(clock_id: u32) u64;
pub const CLOCK_UPTIME_RAW: u32 = 8;

pub const UnfairLock = extern struct {
    raw: u32 = 0,
    extern "c" fn os_unfair_lock_lock(lock: *UnfairLock) void;
    extern "c" fn os_unfair_lock_unlock(lock: *UnfairLock) void;
    pub fn lock(self: *UnfairLock) void {
        os_unfair_lock_lock(self);
    }
    pub fn unlock(self: *UnfairLock) void {
        os_unfair_lock_unlock(self);
    }
};

// ---------------------------------------------------------------------------
// CoreVideo
// ---------------------------------------------------------------------------

pub const CVDisplayLinkRef = *opaque {};
pub const CVReturn = i32;
/// Opaque here: the output callback never reads the timestamps.
pub const CVTimeStamp = opaque {};
pub const CVDisplayLinkOutputCallback = *const fn (
    link: CVDisplayLinkRef,
    now: *const CVTimeStamp,
    output_time: *const CVTimeStamp,
    flags_in: u64,
    flags_out: *u64,
    context: ?*anyopaque,
) callconv(.c) CVReturn;

pub extern "c" fn CVDisplayLinkCreateWithActiveCGDisplays(link_out: *?CVDisplayLinkRef) CVReturn;
pub extern "c" fn CVDisplayLinkSetCurrentCGDisplay(link: CVDisplayLinkRef, display_id: u32) CVReturn;
pub extern "c" fn CVDisplayLinkSetOutputCallback(link: CVDisplayLinkRef, callback: CVDisplayLinkOutputCallback, user_info: ?*anyopaque) CVReturn;
pub extern "c" fn CVDisplayLinkStart(link: CVDisplayLinkRef) CVReturn;
pub extern "c" fn CVDisplayLinkStop(link: CVDisplayLinkRef) CVReturn;
pub extern "c" fn CVDisplayLinkIsRunning(link: CVDisplayLinkRef) cf.Boolean;
pub extern "c" fn CVDisplayLinkRelease(link: CVDisplayLinkRef) void;

// ---------------------------------------------------------------------------
// Carbon / HIToolbox (keyboard layouts)
// ---------------------------------------------------------------------------

pub const TISInputSourceRef = *opaque {};

pub extern "c" fn TISCopyCurrentKeyboardLayoutInputSource() ?TISInputSourceRef;
pub extern "c" fn TISCopyCurrentKeyboardInputSource() ?TISInputSourceRef;
pub extern "c" fn TISGetInputSourceProperty(source: TISInputSourceRef, key: cf.CFStringRef) ?*const anyopaque;
pub extern "c" const kTISPropertyUnicodeKeyLayoutData: cf.CFStringRef;
pub extern "c" const kTISPropertyInputSourceIsASCIICapable: cf.CFStringRef;
pub extern "c" const kTISPropertyInputSourceType: cf.CFStringRef;
pub extern "c" const kTISTypeKeyboardInputMode: cf.CFStringRef;
/// `UInt8 LMGetKbdType(void)`.
pub extern "c" fn LMGetKbdType() u8;
/// `OSStatus UCKeyTranslate(...)`; `UniCharCount` is `unsigned long`.
pub extern "c" fn UCKeyTranslate(
    key_layout: *const anyopaque,
    virtual_key_code: u16,
    key_action: u16,
    modifier_key_state: u32,
    keyboard_type: u32,
    key_translate_options: u32,
    dead_key_state: *u32,
    max_string_length: usize,
    actual_string_length: *usize,
    unicode_string: [*]u16,
) i32;
