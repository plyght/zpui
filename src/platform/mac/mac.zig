//! macOS `platform.Platform` (port of zui `gpui_macos/src/platform.rs`):
//! NSApplication + a runtime-declared app delegate, a minimal app menu
//! (Hide / Hide Others / Show All / Quit, so cmd-q works), NSPasteboard
//! clipboard, NSCursor, NSWorkspace URL/reveal/reduced-motion, NSScreen
//! displays, GCD dispatcher and the CoreText text system.
//!
//! `run` returns: termination requests (cmd-q, `quit`, logout) are answered
//! with `NSTerminateCancel` after `[NSApp stop:]`, so `run` unwinds normally
//! and callers can clean up (GLFW does the same) instead of AppKit calling
//! `exit()` from inside `-terminate:`.

const std = @import("std");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const pf = @import("../platform.zig");
const dispatcher_mod = @import("dispatcher.zig");
const display_link = @import("display_link.zig");
const window_mod = @import("window.zig");
const file_dialog = @import("file_dialog.zig");
const menu_mod = @import("menu.zig");
const notify = @import("notify.zig");
pub const window_capture = @import("window_capture.zig");
const CoreTextSystem = @import("../../text/coretext.zig").CoreTextSystem;

pub const MacWindow = window_mod.MacWindow;
pub const MacDispatcher = dispatcher_mod.MacDispatcher;
pub const events = @import("events.zig");
pub const cf = @import("cf.zig");
pub const appkit = ak;
pub const objc_runtime = objc;
/// [glass-lab] Liquid Glass diagnostics (accessibility, layer-tree dump, reference views).
pub const glass_debug = @import("glass_debug.zig");

const log = std.log.scoped(.mac_platform);

const id = objc.id;
const SEL = objc.SEL;
const BOOL = objc.BOOL;
const YES = objc.YES;
const NO = objc.NO;
const NSUInteger = ak.NSUInteger;
const NSInteger = ak.NSInteger;

const platform_ivar = "zpuiPlatform";

pub const MacPlatform = struct {
    gpa: std.mem.Allocator,
    dispatcher_impl: MacDispatcher = .{},
    text_system: *CoreTextSystem,
    callbacks: pf.PlatformCallbacks = .{},
    on_launch: pf.Callback(void, void) = .{},
    app: id,
    delegate: ?id = null,
    quit_notified: bool = false,
    /// `setMenus` installed the app's own menu bar (skip the minimal default).
    menus_set: bool = false,

    /// Create the platform (main thread). Instantiates `NSApplication`.
    pub fn create(gpa: std.mem.Allocator) !*MacPlatform {
        if (!dispatcher_mod.isMainThread()) return error.NotMainThread;
        const self = try gpa.create(MacPlatform);
        errdefer gpa.destroy(self);
        const text_system = try CoreTextSystem.create(gpa);
        self.* = .{ .gpa = gpa, .text_system = text_system, .app = ak.sharedApp() };
        window_mod.registerClasses();
        return self;
    }

    pub fn platform(self: *MacPlatform) pf.Platform {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn cast(ptr: *anyopaque) *MacPlatform {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable: pf.Platform.VTable = .{
        .dispatcher = vDispatcher,
        .textSystem = vTextSystem,
        .setCallbacks = vSetCallbacks,
        .run = vRun,
        .quit = vQuit,
        .activate = vActivate,
        .openWindow = vOpenWindow,
        .displays = vDisplays,
        .windowAppearance = vWindowAppearance,
        .setCursorStyle = vSetCursorStyle,
        .writeClipboard = vWriteClipboard,
        .readClipboard = vReadClipboard,
        .openUrl = vOpenUrl,
        .revealPath = vRevealPath,
        .prefersReducedMotion = vPrefersReducedMotion,
        .deinit = vDeinit,
        .readClipboardImage = vReadClipboardImage,
        .promptForPaths = vPromptForPaths,
        .setMenus = vSetMenus,
        .appCommand = vAppCommand,
        .showAboutPanel = vShowAboutPanel,
        .postNotification = vPostNotification,
        .playSound = vPlaySound,
        .supportsLiquidGlass = vSupportsLiquidGlass, // [liquid-glass]
        .liquidGlassRevision = vLiquidGlassRevision, // [liquid-glass]
        .setGlobalHotkey = vSetGlobalHotkey,
        .windowCaptureCapabilities = vWindowCaptureCapabilities,
        .captureActiveWindow = vCaptureActiveWindow,
        .requestCaptureAccess = vRequestCaptureAccess,
        .foregroundAfterCapture = vForegroundAfterCapture,
        .renderSystemSymbol = vRenderSystemSymbol,
        .supportsNativePopovers = vSupportsNativePopovers,
    };

    fn vRenderSystemSymbol(_: *anyopaque, gpa: std.mem.Allocator, request: pf.SystemSymbolRequest) ?pf.SystemSymbolMask {
        return @import("system_symbol.zig").render(gpa, request);
    }

    /// [native-popover] Borderless glass panels (popover.zig).
    fn vSupportsNativePopovers(_: *anyopaque) bool {
        return true;
    }

    fn vSetGlobalHotkey(_: *anyopaque, hotkey: ?pf.GlobalHotkey, handler: pf.GlobalHotkeyHandler) void {
        window_capture.setHotkey(hotkey, handler);
    }
    fn vWindowCaptureCapabilities(_: *anyopaque) pf.WindowCaptureCapabilities {
        return window_capture.capabilities();
    }
    fn vCaptureActiveWindow(_: *anyopaque, gpa: std.mem.Allocator, done: pf.WindowCaptureCallback) void {
        window_capture.capture(gpa, done);
    }
    fn vRequestCaptureAccess(_: *anyopaque, kind: pf.CaptureAccess) void {
        window_capture.requestAccess(kind);
    }
    fn vForegroundAfterCapture(_: *anyopaque) void {
        window_capture.foregroundAfterCapture();
    }

    /// [liquid-glass] 26 (Tahoe), 27 (Golden Gate), ...; 0 without NSGlassEffectView.
    fn vLiquidGlassRevision(_: *anyopaque) u32 {
        return @import("native_views.zig").glassRevision();
    }

    /// [liquid-glass] macOS 26+ with NSGlassEffectView (runtime check, cached).
    fn vSupportsLiquidGlass(_: *anyopaque) bool {
        return @import("native_views.zig").glassSupported();
    }

    fn vSetMenus(ptr: *anyopaque, menus: []const pf.Menu) void {
        const self = cast(ptr);
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        // The delegate exists only inside `run`; before that, build against a placeholder
        // owner (items target the responder chain, so only `menuWillOpen:` is lost).
        const delegate = self.delegate orelse ensureDelegate(self);
        self.app.msg(void, "setMainMenu:", .{menu_mod.build(menus, delegate)});
        self.menus_set = true;
    }

    fn vAppCommand(ptr: *anyopaque, command: pf.AppCommand) void {
        const app = cast(ptr).app;
        switch (command) {
            .hide => app.msg(void, "hide:", .{@as(?id, null)}),
            .hide_other_apps => app.msg(void, "hideOtherApplications:", .{@as(?id, null)}),
            .unhide_other_apps => app.msg(void, "unhideAllApplications:", .{@as(?id, null)}),
        }
    }

    fn vShowAboutPanel(ptr: *anyopaque, options: pf.AboutPanelOptions) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        // Empty build version: CFBundleVersion equals the marketing version, and AppKit
        // would otherwise render "Version 0.2.61 (0.2.61)" (zeron `about_panel`).
        const keys = [_]id{ ak.NSAboutPanelOptionApplicationName, ak.NSAboutPanelOptionApplicationVersion, ak.NSAboutPanelOptionVersion };
        const values = [_]id{ ak.nsString(options.application_name), ak.nsString(options.version), ak.nsString("") };
        const dict = ak.class("NSDictionary").msg(id, "dictionaryWithObjects:forKeys:count:", .{ &values, &keys, @as(NSUInteger, keys.len) });
        cast(ptr).app.msg(void, "orderFrontStandardAboutPanelWithOptions:", .{dict});
    }

    fn vPostNotification(ptr: *anyopaque, n: pf.Notification) void {
        notify.callbacks = &cast(ptr).callbacks;
        notify.post(n, n.bundle_id);
    }

    fn vPlaySound(_: *anyopaque, bytes: []const u8) void {
        notify.playSound(bytes);
    }

    fn vReadClipboardImage(_: *anyopaque, gpa: std.mem.Allocator) ?pf.ClipboardImage {
        return file_dialog.readClipboardImage(gpa);
    }

    fn vPromptForPaths(ptr: *anyopaque, options: pf.PathPromptOptions, done: pf.PathsCallback) void {
        file_dialog.prompt(cast(ptr).gpa, options, done);
    }

    fn vDispatcher(ptr: *anyopaque) pf.Dispatcher {
        return cast(ptr).dispatcher_impl.dispatcher();
    }

    fn vTextSystem(ptr: *anyopaque) pf.TextSystem {
        return cast(ptr).text_system.textSystem();
    }

    fn vSetCallbacks(ptr: *anyopaque, cbs: pf.PlatformCallbacks) void {
        const self = cast(ptr);
        self.callbacks = cbs;
        notify.callbacks = &self.callbacks;
    }

    fn vRun(ptr: *anyopaque, on_launch: pf.Callback(void, void)) void {
        const self = cast(ptr);
        self.on_launch = on_launch;
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        const delegate = ensureDelegate(self);
        self.app.msg(void, "setDelegate:", .{delegate});
        if (!self.menus_set) self.app.msg(void, "setMainMenu:", .{buildMainMenu()});

        self.app.msg(void, "run", .{});

        self.app.msg(void, "setDelegate:", .{@as(?id, null)});
        objc.setIvar(delegate, platform_ivar, null);
        delegate.release();
        self.delegate = null;
    }

    fn vQuit(_: *anyopaque) void {
        // Asynchronous (zui): `-terminate:` closes windows, whose callbacks must not
        // run while the caller still holds app state on its stack.
        const Ctx = struct {
            fn run(_: ?*anyopaque) callconv(.c) void {
                ak.sharedApp().msg(void, "terminate:", .{@as(?id, null)});
            }
        };
        dispatcher_mod.onMain(null, &Ctx.run);
    }

    fn vActivate(ptr: *anyopaque, ignoring_other_apps: bool) void {
        cast(ptr).app.msg(void, "activateIgnoringOtherApps:", .{objc.toBOOL(ignoring_other_apps)});
    }

    fn vOpenWindow(ptr: *anyopaque, params: pf.WindowParams) anyerror!pf.Window {
        const w = try MacWindow.open(cast(ptr).gpa, params);
        return w.window();
    }

    fn vDisplays(_: *anyopaque, out: []pf.Display) usize {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const screens = ak.class("NSScreen").msg(id, "screens", .{});
        const count = @min(ak.arrayCount(screens), out.len);
        for (out[0..count], 0..) |*d, i| {
            const screen = ak.arrayAt(screens, i);
            const f = ak.frame(screen);
            const v = ak.msgStruct(ak.NSRect, screen, "visibleFrame", .{});
            // Display-relative, top-left origin (zui `MacDisplay::visible_bounds`).
            const visible_y = f.size.height - v.origin.y - v.size.height + f.origin.y;
            d.* = .{
                .id = ak.displayIdForScreen(screen) orelse 0,
                .bounds = .{ .origin = .zero, .size = .{ .width = @floatCast(f.size.width), .height = @floatCast(f.size.height) } },
                .visible_bounds = .{
                    .origin = .{ .x = @floatCast(v.origin.x - f.origin.x), .y = @floatCast(visible_y) },
                    .size = .{ .width = @floatCast(v.size.width), .height = @floatCast(v.size.height) },
                },
                .scale_factor = @floatCast(screen.msg(ak.CGFloat, "backingScaleFactor", .{})),
                // `screens[0]` holds the menu bar.
                .primary = i == 0,
            };
            d.uuid = ak.displayUuid(d.id);
        }
        return count;
    }

    fn vWindowAppearance(ptr: *anyopaque) pf.WindowAppearance {
        return ak.appearanceFromNative(cast(ptr).app.msg(?id, "effectiveAppearance", .{}));
    }

    fn vSetCursorStyle(_: *anyopaque, style: pf.CursorStyle) void {
        window_mod.setActiveWindowCursorStyle(style);
    }

    fn vWriteClipboard(_: *anyopaque, text: []const u8) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const pb = ak.class("NSPasteboard").msg(id, "generalPasteboard", .{});
        _ = pb.msg(NSInteger, "clearContents", .{});
        _ = pb.msg(BOOL, "setString:forType:", .{ ak.nsString(text), ak.NSPasteboardTypeString });
    }

    fn vReadClipboard(_: *anyopaque, gpa: std.mem.Allocator) ?[]u8 {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const pb = ak.class("NSPasteboard").msg(id, "generalPasteboard", .{});
        const str = pb.msg(?id, "stringForType:", .{ak.NSPasteboardTypeString}) orelse return null;
        return gpa.dupe(u8, ak.stringBytes(str)) catch null;
    }

    fn vOpenUrl(_: *anyopaque, url: []const u8) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const ns_url = ak.class("NSURL").msg(?id, "URLWithString:", .{ak.nsString(url)}) orelse {
            log.err("invalid URL: {s}", .{url});
            return;
        };
        const ws = ak.class("NSWorkspace").msg(id, "sharedWorkspace", .{});
        _ = ws.msg(BOOL, "openURL:", .{ns_url});
    }

    fn vRevealPath(_: *anyopaque, path: []const u8) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        const ws = ak.class("NSWorkspace").msg(id, "sharedWorkspace", .{});
        _ = ws.msg(BOOL, "selectFile:inFileViewerRootedAtPath:", .{ ak.nsString(path), ak.nsString("") });
    }

    fn vPrefersReducedMotion(_: *anyopaque) bool {
        const ws = ak.class("NSWorkspace").msg(id, "sharedWorkspace", .{});
        return ws.msg(BOOL, "accessibilityDisplayShouldReduceMotion", .{}) == YES;
    }

    fn vDeinit(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.text_system.destroy();
        self.gpa.destroy(self);
    }
};

/// The app delegate instance (created on first use; owned by the platform).
fn ensureDelegate(self: *MacPlatform) id {
    if (self.delegate) |d| return d;
    const delegate = delegateClass().msg(id, "new", .{});
    self.delegate = delegate;
    objc.setIvar(delegate, platform_ivar, self);
    return delegate;
}

/// Convenience: `MacPlatform.create(gpa)` as a `pf.Platform`.
pub fn create(gpa: std.mem.Allocator) !pf.Platform {
    return (try MacPlatform.create(gpa)).platform();
}

// ---------------------------------------------------------------------------
// Menu
// ---------------------------------------------------------------------------

fn menuItem(title: id, comptime action: ?[:0]const u8, key: []const u8, mask: NSUInteger) id {
    const item = ak.class("NSMenuItem").msg(id, "alloc", .{}).msg(id, "initWithTitle:action:keyEquivalent:", .{
        title, if (action) |a| @as(?SEL, objc.sel(a)) else @as(?SEL, null), ak.nsString(key),
    });
    if (key.len > 0) item.msg(void, "setKeyEquivalentModifierMask:", .{mask});
    return item.autorelease();
}

fn joined(prefix: []const u8, name: []const u8) id {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, name }) catch prefix;
    return ak.nsString(s);
}

/// Main menu with an application menu; key equivalents reach it only when the
/// focused view doesn't consume them in `performKeyEquivalent:`.
fn buildMainMenu() id {
    const M = ak.NSEventModifierFlags;
    const name = ak.stringBytes(ak.class("NSProcessInfo").msg(id, "processInfo", .{}).msg(id, "processName", .{}));

    const main_menu = ak.class("NSMenu").msg(id, "alloc", .{}).msg(id, "initWithTitle:", .{ak.nsString("")}).autorelease();
    const app_item = menuItem(ak.nsString(""), null, "", 0);
    main_menu.msg(void, "addItem:", .{app_item});

    const app_menu = ak.class("NSMenu").msg(id, "alloc", .{}).msg(id, "initWithTitle:", .{ak.nsString(name)}).autorelease();
    app_menu.msg(void, "addItem:", .{menuItem(joined("Hide ", name), "hide:", "h", M.command)});
    app_menu.msg(void, "addItem:", .{menuItem(ak.nsString("Hide Others"), "hideOtherApplications:", "h", M.command | M.option)});
    app_menu.msg(void, "addItem:", .{menuItem(ak.nsString("Show All"), "unhideAllApplications:", "", 0)});
    app_menu.msg(void, "addItem:", .{ak.class("NSMenuItem").msg(id, "separatorItem", .{})});
    app_menu.msg(void, "addItem:", .{menuItem(joined("Quit ", name), "terminate:", "q", M.command)});
    app_item.msg(void, "setSubmenu:", .{app_menu});
    return main_menu;
}

// ---------------------------------------------------------------------------
// App delegate (zui `GPUIApplicationDelegate`)
// ---------------------------------------------------------------------------

var delegate_class: ?*objc.Class = null;

fn delegateClass() *objc.Class {
    if (delegate_class) |c| return c;
    const B = ak.enc_bool;
    const b = objc.ClassBuilder.init("NSObject", "ZPUIApplicationDelegate") orelse {
        delegate_class = objc.getClass("ZPUIApplicationDelegate").?;
        return delegate_class.?;
    };
    _ = b.addPointerIvar(platform_ivar);
    _ = b.addMethod("applicationWillFinishLaunching:", &willFinishLaunching, "v@:@");
    _ = b.addMethod("applicationDidFinishLaunching:", &didFinishLaunching, "v@:@");
    _ = b.addMethod("applicationShouldHandleReopen:hasVisibleWindows:", &shouldHandleReopen, B ++ "@:@" ++ B);
    _ = b.addMethod("applicationShouldTerminate:", &shouldTerminate, "Q@:@");
    _ = b.addMethod("application:openURLs:", &openUrls, "v@:@@");
    _ = b.addMethod("onKeyboardLayoutChange:", &onKeyboardLayoutChange, "v@:@");
    _ = b.addMethod("onSystemWake:", &onSystemWake, "v@:@");
    // Menu items target the responder chain, which ends at this delegate (menu.zig).
    inline for (.{ menu_mod.handle_selector, "cut:", "copy:", "paste:", "selectAll:", "undo:", "redo:" }) |sel_name| {
        _ = b.addMethod(sel_name, &handleMenuItem, "v@:@");
    }
    _ = b.addMethod("validateMenuItem:", &validateMenuItem, B ++ "@:@");
    _ = b.addMethod("menuWillOpen:", &menuWillOpen, "v@:@");
    delegate_class = b.register();
    return delegate_class.?;
}

fn getPlatform(this: id) ?*MacPlatform {
    return @ptrCast(@alignCast(objc.getIvar(this, platform_ivar)));
}

fn willFinishLaunching(_: id, _: SEL, _: id) callconv(.c) void {
    // The autofill heuristic controller causes slowdowns and high CPU (ghostty#8625, zui).
    const defaults = ak.class("NSUserDefaults").msg(id, "standardUserDefaults", .{});
    const key = objc.nsString("NSAutoFillHeuristicControllerEnabled");
    if (defaults.msg(?id, "objectForKey:", .{key}) == null) {
        const no = ak.class("NSNumber").msg(id, "numberWithBool:", .{NO});
        defaults.msg(void, "setObject:forKey:", .{ no, key });
    }
}

fn didFinishLaunching(this: id, _: SEL, _: id) callconv(.c) void {
    const app = ak.sharedApp();
    _ = app.msg(BOOL, "setActivationPolicy:", .{ak.NSApplicationActivationPolicyRegular});

    const center = ak.class("NSNotificationCenter").msg(id, "defaultCenter", .{});
    center.msg(void, "addObserver:selector:name:object:", .{
        this, objc.sel("onKeyboardLayoutChange:"), objc.nsString("NSTextInputContextKeyboardSelectionDidChangeNotification"), @as(?id, null),
    });
    // Display sleep / session switches can stop CVDisplayLink without a window event.
    const ws_center = ak.class("NSWorkspace").msg(id, "sharedWorkspace", .{}).msg(id, "notificationCenter", .{});
    inline for (.{ "NSWorkspaceDidWakeNotification", "NSWorkspaceScreensDidWakeNotification", "NSWorkspaceSessionDidBecomeActiveNotification" }) |name| {
        ws_center.msg(void, "addObserver:selector:name:object:", .{ this, objc.sel("onSystemWake:"), objc.nsString(name), @as(?id, null) });
    }

    const self = getPlatform(this) orelse return;
    _ = self.on_launch.call({});
}

fn shouldHandleReopen(this: id, _: SEL, _: id, has_visible_windows: BOOL) callconv(.c) BOOL {
    if (has_visible_windows == NO) if (getPlatform(this)) |self| {
        if (self.callbacks.reopen) |f| f(self.callbacks.ctx);
    };
    return YES;
}

fn shouldTerminate(this: id, _: SEL, _: id) callconv(.c) NSUInteger {
    if (getPlatform(this)) |self| if (!self.quit_notified) {
        // Dock "Quit", logout, a stray `terminate:`: the app may veto (unsaved files) and
        // quits later through `Platform.quit` (zeron `native_quit`).
        if (self.callbacks.should_quit) |f| if (!f(self.callbacks.ctx)) return ak.NSTerminateCancel;
        self.quit_notified = true;
        if (self.callbacks.quit) |f| f(self.callbacks.ctx);
    };
    // Leave -[NSApp run] instead of exit(): stop, then post an event so the loop wakes.
    const app = ak.sharedApp();
    app.msg(void, "stop:", .{@as(?id, null)});
    const event = ak.class("NSEvent").msg(?id, "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:", .{
        ak.NSEventType.application_defined, ak.NSPoint{ .x = 0, .y = 0 }, @as(NSUInteger, 0), @as(f64, 0),
        @as(NSInteger, 0),                  @as(?id, null),               @as(i16, 0),        @as(NSInteger, 0),
        @as(NSInteger, 0),
    });
    if (event) |e| app.msg(void, "postEvent:atStart:", .{ e, YES });
    return ak.NSTerminateCancel;
}

fn openUrls(this: id, _: SEL, _: id, urls: id) callconv(.c) void {
    const self = getPlatform(this) orelse return;
    const f = self.callbacks.open_urls orelse return;
    const count = ak.arrayCount(urls);
    const list = self.gpa.alloc([]const u8, count) catch return;
    defer self.gpa.free(list);
    for (list, 0..) |*s, i| s.* = ak.stringBytes(ak.arrayAt(urls, i).msg(id, "absoluteString", .{}));
    f(self.callbacks.ctx, list);
}

fn handleMenuItem(this: id, _: SEL, item: id) callconv(.c) void {
    const self = getPlatform(this) orelse return;
    menu_mod.handle(self.callbacks, item);
}

fn validateMenuItem(this: id, _: SEL, item: id) callconv(.c) BOOL {
    const self = getPlatform(this) orelse return YES;
    return objc.toBOOL(menu_mod.validate(self.callbacks, item));
}

fn menuWillOpen(this: id, _: SEL, _: id) callconv(.c) void {
    const self = getPlatform(this) orelse return;
    if (self.callbacks.will_open_menu) |f| f(self.callbacks.ctx);
}

fn onKeyboardLayoutChange(this: id, _: SEL, _: id) callconv(.c) void {
    const self = getPlatform(this) orelse return;
    if (self.callbacks.keyboard_layout_change) |f| f(self.callbacks.ctx);
}

fn onSystemWake(this: id, _: SEL, _: id) callconv(.c) void {
    display_link.recoverAfterWake();
    const self = getPlatform(this) orelse return;
    if (self.callbacks.system_wake) |f| f(self.callbacks.ctx);
}

test {
    std.testing.refAllDecls(@This());
    _ = menu_mod;
    _ = notify;
    _ = @import("../../text/coretext.zig");
}
