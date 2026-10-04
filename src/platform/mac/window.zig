//! macOS `platform.Window`: an NSWindow subclass (its own delegate) hosting a
//! layer-backed NSView subclass whose backing layer is the Metal renderer's
//! `CAMetalLayer` (port of zui `gpui_macos/src/window.rs`).
//!
//! Classes are registered at runtime (`registerClasses`):
//!   * `ZPUIWindow : NSWindow` / `ZPUIPanel : NSPanel` — delegate callbacks,
//!     close, file drag & drop.
//!   * `ZPUIView : NSView <NSTextInputClient, CALayerDelegate>` — mouse/key
//!     events, IME, cursor rects, backing layer, resize/scale changes.
//!   * `ZPUIBlurredView : NSVisualEffectView` — `.UnderWindowBackground`
//!     behind-window blur for `blurred` windows, with the backdrop layer's
//!     tint/saturation stripped so zpui draws its own tint (zui `BlurredView`).
//!
//! Every Objective-C object carries a raw `*MacWindow` in the `zpuiWindow`
//! ivar. All methods run on the main thread. A window is torn down in two
//! steps: `-close` fires the `close` callback, then the Zig state is freed
//! from a later main-queue turn (after ivars are cleared), so no AppKit frame
//! on the stack can observe freed memory.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const ak = @import("appkit.zig");
const cf = @import("cf.zig");
const events = @import("events.zig");
const display_link = @import("display_link.zig");
const dispatcher = @import("dispatcher.zig");
const platform = @import("../platform.zig");
const input = @import("../../input.zig");
const geometry = @import("../../geometry.zig");
const scene_mod = @import("../../scene.zig");
const atlas_mod = @import("../../atlas.zig");
const Renderer = @import("../../renderer/renderer.zig").Renderer;
const native_views = @import("native_views.zig");
const mac_a11y = @import("a11y.zig");

const log = std.log.scoped(.mac_window);

const id = objc.id;
const SEL = objc.SEL;
const BOOL = objc.BOOL;
const YES = objc.YES;
const NO = objc.NO;
const NSUInteger = ak.NSUInteger;
const NSInteger = ak.NSInteger;
const NSRect = ak.NSRect;
const NSPoint = ak.NSPoint;
const NSSize = ak.NSSize;
const NSRange = ak.NSRange;
const Point = platform.Point;
const Size = platform.Size;
const Bounds = platform.Bounds;

const state_ivar = "zpuiWindow";
/// Vsync ticks without a frame request before the display link is parked (fork: pause when idle).
const idle_ticks_before_park = 30;
/// Interval of the synthetic mouse-move events sent while dragging (autoscroll), as in zui.
const synthetic_drag_interval_ns = 16 * std.time.ns_per_ms;

// ---------------------------------------------------------------------------
// Class registration
// ---------------------------------------------------------------------------

var window_class: ?*objc.Class = null;
var panel_class: ?*objc.Class = null;
var view_class: ?*objc.Class = null;
var blurred_view_class: ?*objc.Class = null;

const B = ak.enc_bool;
const R = ak.enc_range;

/// Register the runtime classes once (main thread).
pub fn registerClasses() void {
    if (view_class != null) return;
    window_class = buildWindowClass("NSWindow", "ZPUIWindow");
    panel_class = buildWindowClass("NSPanel", "ZPUIPanel");
    view_class = buildViewClass();
    blurred_view_class = buildBlurredViewClass();
    mac_a11y.registerClasses();
}

fn buildWindowClass(comptime super: [:0]const u8, comptime name: [:0]const u8) *objc.Class {
    const b = objc.ClassBuilder.init(super, name) orelse return objc.getClass(name).?;
    _ = b.addPointerIvar(state_ivar);
    _ = b.addMethod("canBecomeMainWindow", &yes, B ++ "@:");
    _ = b.addMethod("canBecomeKeyWindow", &yes, B ++ "@:");
    _ = b.addMethod("windowDidResize:", &windowDidResize, "v@:@");
    _ = b.addMethod("windowDidChangeOcclusionState:", &windowDidChangeOcclusionState, "v@:@");
    _ = b.addMethod("windowWillEnterFullScreen:", &windowWillEnterFullScreen, "v@:@");
    _ = b.addMethod("windowWillExitFullScreen:", &windowWillExitFullScreen, "v@:@");
    _ = b.addMethod("windowDidExitFullScreen:", &windowDidExitFullScreen, "v@:@");
    _ = b.addMethod("windowDidMove:", &windowDidMove, "v@:@");
    _ = b.addMethod("windowDidChangeScreen:", &windowDidChangeScreen, "v@:@");
    _ = b.addMethod("windowDidBecomeKey:", &windowDidBecomeKey, "v@:@");
    _ = b.addMethod("windowDidResignKey:", &windowDidResignKey, "v@:@");
    _ = b.addMethod("windowShouldClose:", &windowShouldClose, B ++ "@:@");
    _ = b.addMethod("close", &closeWindow, "v@:");
    _ = b.addMethod("draggingEntered:", &draggingEntered, "Q@:@");
    _ = b.addMethod("draggingUpdated:", &draggingUpdated, "Q@:@");
    _ = b.addMethod("draggingExited:", &draggingExited, "v@:@");
    _ = b.addMethod("performDragOperation:", &performDragOperation, B ++ "@:@");
    _ = b.addMethod("concludeDragOperation:", &concludeDragOperation, "v@:@");
    return b.register();
}

fn buildViewClass() *objc.Class {
    const b = objc.ClassBuilder.init("NSView", "ZPUIView") orelse return objc.getClass("ZPUIView").?;
    _ = b.addPointerIvar(state_ivar);
    _ = b.addMethod("acceptsFirstResponder", &yes, B ++ "@:");
    _ = b.addMethod("performKeyEquivalent:", &performKeyEquivalent, B ++ "@:@");
    _ = b.addMethod("keyDown:", &keyDown, "v@:@");
    _ = b.addMethod("keyUp:", &keyUp, "v@:@");
    inline for (.{
        "mouseDown:",         "mouseUp:",           "rightMouseDown:", "rightMouseUp:",
        "otherMouseDown:",    "otherMouseUp:",      "mouseMoved:",     "mouseDragged:",
        "rightMouseDragged:", "otherMouseDragged:", "scrollWheel:",    "swipeWithEvent:",
        "flagsChanged:",
    }) |s| _ = b.addMethod(s, &handleViewEvent, "v@:@");
    _ = b.addMethod("mouseExited:", &mouseExited, "v@:@");
    _ = b.addMethod("mouseEntered:", &mouseEntered, "v@:@");
    _ = b.addMethod("resetCursorRects", &resetCursorRects, "v@:");
    _ = b.addMethod("makeBackingLayer", &makeBackingLayer, "@@:");
    _ = b.addMethod("viewDidChangeBackingProperties", &viewDidChangeBackingProperties, "v@:");
    _ = b.addMethod("setFrameSize:", &setFrameSize, "v@:" ++ ak.enc_size);
    _ = b.addMethod("displayLayer:", &displayLayer, "v@:@");
    _ = b.addMethod("viewDidChangeEffectiveAppearance", &viewDidChangeEffectiveAppearance, "v@:");
    _ = b.addMethod("acceptsFirstMouse:", &acceptsFirstMouse, B ++ "@:@");
    _ = b.addMethod("_opaqueRectForWindowMoveWhenInTitlebar", &opaqueRectForWindowMove, ak.enc_rect ++ "@:");
    // NSTextInputClient
    _ = b.addMethod("validAttributesForMarkedText", &validAttributesForMarkedText, "@@:");
    _ = b.addMethod("hasMarkedText", &hasMarkedText, B ++ "@:");
    _ = b.addMethod("markedRange", &markedRange, R ++ "@:");
    _ = b.addMethod("selectedRange", &selectedRange, R ++ "@:");
    _ = b.addMethod("firstRectForCharacterRange:actualRange:", &firstRectForCharacterRange, ak.enc_rect ++ "@:" ++ R ++ "^" ++ R);
    _ = b.addMethod("insertText:replacementRange:", &insertText, "v@:@" ++ R);
    _ = b.addMethod("setMarkedText:selectedRange:replacementRange:", &setMarkedText, "v@:@" ++ R ++ R);
    _ = b.addMethod("unmarkText", &unmarkText, "v@:");
    _ = b.addMethod("attributedSubstringForProposedRange:actualRange:", &attributedSubstring, "@@:" ++ R ++ "^" ++ R);
    _ = b.addMethod("characterIndexForPoint:", &characterIndexForPoint, "Q@:" ++ ak.enc_point);
    _ = b.addMethod("doCommandBySelector:", &doCommandBySelector, "v@::");
    if (!objc.addProtocol(b, "NSTextInputClient")) log.warn("NSTextInputClient protocol not found; IME will not work", .{});
    _ = objc.addProtocol(b, "CALayerDelegate");
    mac_a11y.addViewMethods(b);
    return b.register();
}

fn buildBlurredViewClass() *objc.Class {
    const b = objc.ClassBuilder.init("NSVisualEffectView", "ZPUIBlurredView") orelse return objc.getClass("ZPUIBlurredView").?;
    _ = b.addPointerIvar(state_ivar); // [liquid-glass] backdrop hole: no black base
    _ = b.addMethod("initWithFrame:", &blurredViewInitWithFrame, "@@:" ++ ak.enc_rect);
    _ = b.addMethod("updateLayer", &blurredViewUpdateLayer, "v@:");
    return b.register();
}

fn state(obj: id) ?*MacWindow {
    return @ptrCast(@alignCast(objc.getIvar(obj, state_ivar)));
}

fn superOf(obj: id, comptime class_name: [:0]const u8) objc.Super {
    return .{ .receiver = obj, .super_class = ak.class(class_name) };
}

fn yes(_: id, _: SEL) callconv(.c) BOOL {
    return YES;
}

// ---------------------------------------------------------------------------
// MacWindow
// ---------------------------------------------------------------------------

const TrafficLightFrames = struct { titlebar: NSRect, close: NSRect, minimize: NSRect, zoom: NSRect };

pub const MacWindow = struct {
    gpa: std.mem.Allocator,
    native_window: id,
    native_view: id,
    blurred_view: ?id = null,
    renderer: Renderer,
    callbacks: platform.WindowCallbacks = .{},
    input_handler: ?platform.InputHandler = null,
    background: platform.WindowBackgroundAppearance = .opaque_,
    cursor_style: platform.CursorStyle = .arrow,

    frame_source: ?display_link.FrameSource = null,
    frame_requested: bool = true,
    idle_ticks: u32 = 0,
    /// Frames delivered so far (any path); the smoke test checks it.
    frames_requested_count: u64 = 0,

    last_key_equivalent: ?events.KeyEvent = null,
    keystroke_for_do_command: ?events.KeystrokeBuf = null,
    do_command_handled: ?bool = null,
    previous_modifiers: ?input.ModifiersChangedEvent = null,
    synthetic_drag_counter: usize = 0,
    external_files_dragged: bool = false,
    first_mouse: bool = false,
    hovered: bool = false,

    traffic_light_position: ?Point = null,
    traffic_light_frames: ?TrafficLightFrames = null,
    transparent_titlebar: bool = false,
    activated_at_least_once: bool = false,
    closed: bool = false,
    /// Native child views + the overlay plane (native_views.zig).
    natives: native_views.Host = .{},
    /// NSAccessibility bridge (a11y.zig), created on first use.
    a11y: ?*mac_a11y.Bridge = null,

    // -- construction ---------------------------------------------------------

    pub fn open(gpa: std.mem.Allocator, params: platform.WindowParams) !*MacWindow {
        registerClasses();
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();

        ak.class("NSWindow").msg(void, "setAllowsAutomaticWindowTabbing:", .{NO});

        const S = ak.WindowStyleMask;
        var style: NSUInteger = undefined;
        if (params.titlebar) |tb| {
            style = S.closable | S.titled | S.resizable | S.miniaturizable;
            if (tb.appears_transparent) style |= S.full_size_content_view;
        } else {
            style = S.titled | S.full_size_content_view;
        }
        const cls = switch (params.kind) {
            .normal => window_class.?,
            .popup => blk: {
                style |= S.nonactivating_panel;
                break :blk panel_class.?;
            },
            .floating => panel_class.?,
        };

        // Position relative to the main screen, top-left origin (zui `MacWindow::open`).
        const screen = (if (params.display_id) |did| ak.screenForDisplayId(did) else null) orelse
            ak.class("NSScreen").msg(?id, "mainScreen", .{});
        const screen_frame: NSRect = if (screen) |s| ak.frame(s) else .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1440, .height = 900 } };
        const top_left: NSPoint = .{
            .x = screen_frame.origin.x + params.bounds.origin.x,
            .y = screen_frame.origin.y + screen_frame.size.height - params.bounds.origin.y,
        };
        const content_rect: NSRect = .{
            .origin = .{ .x = top_left.x, .y = top_left.y - params.bounds.size.height },
            .size = .{ .width = params.bounds.size.width, .height = params.bounds.size.height },
        };

        const native_window = cls.msg(id, "alloc", .{}).msg(?id, "initWithContentRect:styleMask:backing:defer:screen:", .{
            content_rect, style, ak.NSBackingStoreBuffered, NO, screen,
        }) orelse return error.WindowCreationFailed;
        errdefer native_window.release();
        native_window.msg(void, "setReleasedWhenClosed:", .{NO});
        native_window.msg(void, "registerForDraggedTypes:", .{ak.class("NSArray").msg(id, "arrayWithObject:", .{ak.NSFilenamesPboardType})});

        const content_view = native_window.msg(id, "contentView", .{});
        const content_bounds = ak.bounds(content_view);
        const scale = scaleFactorOf(native_window);

        const self = try gpa.create(MacWindow);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .native_window = native_window,
            .native_view = undefined,
            .renderer = try Renderer.init(gpa, .{
                .size = deviceSize(sizeFromNS(content_bounds.size), scale),
                .surface = .{ .metal_layer = null },
                .transparent = params.background != .opaque_,
            }),
            .traffic_light_position = if (params.titlebar) |tb| tb.traffic_light_position else null,
            .transparent_titlebar = if (params.titlebar) |tb| tb.appears_transparent else true,
        };
        errdefer self.renderer.deinit();
        if (self.renderer.layer()) |layer| @as(id, @ptrCast(layer)).msg(void, "setContentsScale:", .{@as(ak.CGFloat, scale)});

        const native_view = view_class.?.msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{content_bounds});
        self.native_view = native_view;
        objc.setIvar(native_view, state_ivar, self);
        objc.setIvar(native_window, state_ivar, self);
        native_window.msg(void, "setDelegate:", .{native_window});

        if (params.titlebar) |tb| if (tb.title.len > 0) self.setTitle(tb.title);
        native_window.msg(void, "setMovable:", .{objc.toBOOL(params.is_movable)});
        if (params.min_size) |min| native_window.msg(void, "setContentMinSize:", .{NSSize{ .width = min.width, .height = min.height }});
        if (params.titlebar == null or params.titlebar.?.appears_transparent) {
            native_window.msg(void, "setTitlebarAppearsTransparent:", .{YES});
            native_window.msg(void, "setTitleVisibility:", .{ak.NSWindowTitleHidden});
        }

        native_view.msg(void, "setAutoresizingMask:", .{ak.NSViewWidthSizable | ak.NSViewHeightSizable});
        // Make the view layer-backed up front; this calls -makeBackingLayer (the CAMetalLayer).
        native_view.msg(void, "setWantsLayer:", .{YES});
        native_view.msg(void, "setLayerContentsRedrawPolicy:", .{ak.NSViewLayerContentsRedrawDuringViewResize});

        // Entered/exited for hover + mouseExited; popups also need moves while inactive.
        var tracking_options = ak.NSTrackingMouseEnteredAndExited | ak.NSTrackingActiveAlways | ak.NSTrackingInVisibleRect;
        if (params.kind == .popup) tracking_options |= ak.NSTrackingMouseMoved;
        const tracking_area = ak.class("NSTrackingArea").msg(id, "alloc", .{}).msg(id, "initWithRect:options:owner:userInfo:", .{
            NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } }, tracking_options, native_view, @as(?id, null),
        });
        native_view.msg(void, "addTrackingArea:", .{tracking_area});
        tracking_area.release();

        content_view.msg(void, "addSubview:", .{native_view});
        native_view.release(); // retained by the content view
        _ = native_window.msg(BOOL, "makeFirstResponder:", .{native_view});

        switch (params.kind) {
            .normal, .floating => {
                native_window.msg(void, "setLevel:", .{if (params.kind == .floating) ak.NSFloatingWindowLevel else ak.NSNormalWindowLevel});
                native_window.msg(void, "setAcceptsMouseMovedEvents:", .{YES});
                native_window.msg(void, "setTabbingIdentifier:", .{@as(?id, null)});
            },
            .popup => {
                native_window.msg(void, "setLevel:", .{ak.NSPopUpMenuWindowLevel});
                native_window.msg(void, "setAnimationBehavior:", .{ak.NSWindowAnimationBehaviorUtilityWindow});
                native_window.msg(void, "setCollectionBehavior:", .{ak.NSWindowCollectionBehaviorCanJoinAllSpaces | ak.NSWindowCollectionBehaviorFullScreenAuxiliary});
            },
        }

        self.setBackgroundAppearance(params.background);

        if (params.focus and params.show) {
            native_window.msg(void, "makeKeyAndOrderFront:", .{@as(?id, null)});
        } else if (params.show) {
            native_window.msg(void, "orderFront:", .{@as(?id, null)});
        }
        // The init origin can be off when the key screen differs from the main screen.
        native_window.msg(void, "setFrameTopLeftPoint:", .{top_left});
        self.moveTrafficLight();
        self.startDisplayLink();
        return self;
    }

    pub fn window(self: *MacWindow) platform.Window {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The `MacWindow` behind a `platform.Window` created by this backend.
    pub fn fromWindow(w: platform.Window) *MacWindow {
        std.debug.assert(w.vtable == &vtable);
        return @ptrCast(@alignCast(w.ptr));
    }

    /// `-[NSWindow windowNumber]` (the CGWindowID).
    pub fn windowNumber(self: *MacWindow) u32 {
        return @intCast(@max(self.native_window.msg(NSInteger, "windowNumber", .{}), 0));
    }

    // -- geometry -------------------------------------------------------------

    pub fn contentSize(self: *const MacWindow) Size {
        return sizeFromNS(ak.frame(self.native_window.msg(id, "contentView", .{})).size);
    }

    pub fn scaleFactor(self: *const MacWindow) f32 {
        return scaleFactorOf(self.native_window);
    }

    fn drawableSize(self: *const MacWindow) geometry.Size(geometry.DevicePixels) {
        return deviceSize(self.contentSize(), self.scaleFactor());
    }

    pub fn drawableSizePub(self: *const MacWindow) geometry.Size(geometry.DevicePixels) {
        return self.drawableSize();
    }

    fn boundsImpl(self: *const MacWindow) Bounds {
        const f = ak.frame(self.native_window);
        const screen = self.native_window.msg(?id, "screen", .{}) orelse
            return .{ .origin = .zero, .size = sizeFromNS(f.size) };
        const sf = ak.frame(screen);
        // Flip to a top-left origin relative to the window's screen (zui `bounds`).
        const top = sf.size.height - f.origin.y - f.size.height;
        return .{
            .origin = .{ .x = @floatCast(f.origin.x - sf.origin.x), .y = @floatCast(top + sf.origin.y) },
            .size = sizeFromNS(f.size),
        };
    }

    fn isFullscreen(self: *const MacWindow) bool {
        return self.native_window.msg(NSUInteger, "styleMask", .{}) & ak.WindowStyleMask.full_screen != 0;
    }

    // -- frames ---------------------------------------------------------------

    fn startDisplayLink(self: *MacWindow) void {
        self.stopDisplayLink();
        if (self.closed) return;
        if (self.native_window.msg(NSUInteger, "occlusionState", .{}) & ak.NSWindowOcclusionStateVisible == 0) return;
        // AppKit can briefly report no screen during display reconfiguration.
        const display_id = ak.displayIdForScreen(self.native_window.msg(?id, "screen", .{})) orelse return;
        if (self.frame_source == null) {
            self.frame_source = display_link.FrameSource.init(self, &step) catch |err| {
                log.err("frame source: {s}", .{@errorName(err)});
                return;
            };
        }
        self.idle_ticks = 0;
        self.frame_source.?.start(display_id) catch |err| log.err("display link start: {s}", .{@errorName(err)});
    }

    fn stopDisplayLink(self: *MacWindow) void {
        if (self.frame_source) |*fs| fs.stop();
    }

    fn requestFrameCallback(self: *MacWindow, force_render: bool) void {
        if (self.closed) return;
        self.frames_requested_count += 1;
        if (self.callbacks.request_frame) |f| f(self.callbacks.ctx, force_render);
    }

    /// zui `display_layer` / first activation: draw synchronously inside the
    /// current Core Animation transaction (smooth live resize).
    fn synchronousFrame(self: *MacWindow) void {
        self.renderer.setPresentsWithTransaction(true);
        self.stopDisplayLink();
        self.requestFrameCallback(true);
        // With native children both planes always present inside the CA transaction.
        self.renderer.setPresentsWithTransaction(self.natives.enabled());
        self.startDisplayLink();
    }

    // -- state updates --------------------------------------------------------

    fn updateScaleFactorAndSize(self: *MacWindow) void {
        const scale = self.scaleFactor();
        if (self.renderer.layer()) |layer| @as(id, @ptrCast(layer)).msg(void, "setContentsScale:", .{@as(ak.CGFloat, scale)});
        native_views.updateScale(self);
        self.renderer.resize(self.drawableSize()) catch |err| log.err("renderer resize: {s}", .{@errorName(err)});
        if (self.callbacks.resize) |f| f(self.callbacks.ctx, self.contentSize(), scale);
    }

    fn dispatchInput(self: *MacWindow, event: input.PlatformInput) ?platform.DispatchEventResult {
        const f = self.callbacks.input orelse return null;
        return f(self.callbacks.ctx, event);
    }

    /// Runs the input callback; true when a handler consumed the event.
    fn runCallback(self: *MacWindow, event: input.PlatformInput) bool {
        const result = self.dispatchInput(event) orelse return false;
        return !result.propagate;
    }

    pub fn setTitle(self: *MacWindow, title: []const u8) void {
        const pool = objc.AutoreleasePool.push();
        defer pool.pop();
        self.native_window.msg(void, "setTitle:", .{ak.nsString(title)});
        self.moveTrafficLight();
    }

    pub fn setBackgroundAppearance(self: *MacWindow, bg: platform.WindowBackgroundAppearance) void {
        self.background = bg;
        const is_opaque = bg == .opaque_;
        self.renderer.setTransparent(!is_opaque);
        self.native_window.msg(void, "setOpaque:", .{objc.toBOOL(is_opaque)});
        // Not +clearColor: a fully clear background breaks the window shadow.
        const alpha: ak.CGFloat = if (is_opaque) 1 else 0.0001;
        const color = ak.class("NSColor").msg(id, "colorWithSRGBRed:green:blue:alpha:", .{ @as(ak.CGFloat, 0), @as(ak.CGFloat, 0), @as(ak.CGFloat, 0), alpha });
        self.native_window.msg(void, "setBackgroundColor:", .{color});

        if (bg != .blurred) {
            if (self.blurred_view) |v| {
                objc.setIvar(v, state_ivar, null); // [liquid-glass]
                v.msg(void, "removeFromSuperview", .{});
                v.release();
                self.blurred_view = null;
            }
        } else if (self.blurred_view == null) {
            const content_view = self.native_window.msg(id, "contentView", .{});
            const blur = blurred_view_class.?.msg(id, "alloc", .{}).msg(id, "initWithFrame:", .{ak.bounds(content_view)});
            blur.msg(void, "setAutoresizingMask:", .{ak.NSViewWidthSizable | ak.NSViewHeightSizable});
            content_view.msg(void, "addSubview:positioned:relativeTo:", .{ blur, ak.NSWindowBelow, @as(?id, null) });
            self.blurred_view = blur; // keep our +1
            objc.setIvar(blur, state_ivar, self); // [liquid-glass]
            native_views.refreshBackdropMask(self); // [liquid-glass] a hole set earlier
        }
    }

    // -- traffic lights (zui `move_traffic_light`) ------------------------------

    const Buttons = struct { close: id, minimize: id, zoom: id };

    fn trafficLightButtons(self: *const MacWindow) ?Buttons {
        return .{
            .close = self.native_window.msg(?id, "standardWindowButton:", .{ak.NSWindowCloseButton}) orelse return null,
            .minimize = self.native_window.msg(?id, "standardWindowButton:", .{ak.NSWindowMiniaturizeButton}) orelse return null,
            .zoom = self.native_window.msg(?id, "standardWindowButton:", .{ak.NSWindowZoomButton}) orelse return null,
        };
    }

    fn titlebarContainer(close_button: id) ?id {
        const container = close_button.msg(?id, "superview", .{}) orelse return null;
        return container.msg(?id, "superview", .{});
    }

    fn updateTracking(container: id, buttons: Buttons) void {
        container.msg(void, "updateTrackingAreas", .{});
        buttons.close.msg(void, "updateTrackingAreas", .{});
        buttons.minimize.msg(void, "updateTrackingAreas", .{});
        buttons.zoom.msg(void, "updateTrackingAreas", .{});
    }

    fn moveTrafficLight(self: *MacWindow) void {
        const pos = self.traffic_light_position orelse return;
        if (self.isFullscreen()) {
            self.restoreTrafficLight();
            return;
        }
        // AppKit can recreate the standard buttons, so fetch them on every pass.
        const buttons = self.trafficLightButtons() orelse return;
        const container = titlebarContainer(buttons.close) orelse return;
        if (self.traffic_light_frames == null) self.traffic_light_frames = .{
            .titlebar = ak.frame(container),
            .close = ak.frame(buttons.close),
            .minimize = ak.frame(buttons.minimize),
            .zoom = ak.frame(buttons.zoom),
        };

        const window_height = ak.frame(self.native_window).size.height;
        const close_frame = ak.frame(buttons.close);
        const minimize_frame = ak.frame(buttons.minimize);
        const button_width = close_frame.size.width;
        const button_padding = minimize_frame.origin.x - close_frame.origin.x - close_frame.size.width;
        const x: ak.CGFloat = pos.x;
        const y: ak.CGFloat = pos.y;
        const container_height = close_frame.size.height + y + y;

        var titlebar_frame = ak.frame(container);
        titlebar_frame.size.height = container_height;
        titlebar_frame.origin.y = window_height - container_height;
        const minimize_x = x + button_width + button_padding;
        const zoom_x = minimize_x + button_width + button_padding;

        container.msg(void, "setFrame:", .{titlebar_frame});
        buttons.close.msg(void, "setFrameOrigin:", .{NSPoint{ .x = x, .y = y }});
        buttons.minimize.msg(void, "setFrameOrigin:", .{NSPoint{ .x = minimize_x, .y = y }});
        buttons.zoom.msg(void, "setFrameOrigin:", .{NSPoint{ .x = zoom_x, .y = y }});
        updateTracking(container, buttons);
    }

    fn restoreTrafficLight(self: *MacWindow) void {
        const frames = self.traffic_light_frames orelse return;
        self.traffic_light_frames = null;
        const buttons = self.trafficLightButtons() orelse return;
        const container = titlebarContainer(buttons.close) orelse return;
        buttons.close.msg(void, "setFrame:", .{frames.close});
        buttons.minimize.msg(void, "setFrame:", .{frames.minimize});
        buttons.zoom.msg(void, "setFrame:", .{frames.zoom});
        container.msg(void, "setFrame:", .{frames.titlebar});
        updateTracking(container, buttons);
    }

    // -- IME helpers ------------------------------------------------------------

    fn markedTextRange(self: *MacWindow) ?platform.InputHandler.Range {
        const h = self.input_handler orelse return null;
        return h.vtable.markedTextRange(h.ptr);
    }

    // -- teardown ---------------------------------------------------------------

    /// Second half of closing, on a fresh main-queue turn.
    fn destroy(self: *MacWindow) void {
        if (self.frame_source) |*fs| fs.deinit();
        self.frame_source = null;
        objc.setIvar(self.native_view, state_ivar, null);
        objc.setIvar(self.native_window, state_ivar, null);
        self.native_window.msg(void, "setDelegate:", .{@as(?id, null)});
        if (self.blurred_view) |v| {
            objc.setIvar(v, state_ivar, null); // [liquid-glass]
            v.release();
        }
        self.natives.deinit(self);
        mac_a11y.deinit(self);
        self.renderer.deinit();
        self.native_window.release();
        self.gpa.destroy(self);
    }

    // -- vtable -----------------------------------------------------------------

    const vtable: platform.Window.VTable = .{
        .setCallbacks = vSetCallbacks,
        .bounds = vBounds,
        .contentSize = vContentSize,
        .resize = vResize,
        .scaleFactor = vScaleFactor,
        .appearance = vAppearance,
        .mousePosition = vMousePosition,
        .modifiers = vModifiers,
        .isActive = vIsActive,
        .isHovered = vIsHovered,
        .isFullscreen = vIsFullscreen,
        .isMaximized = vIsMaximized,
        .setInputHandler = vSetInputHandler,
        .setTitle = vSetTitle,
        .setBackgroundAppearance = vSetBackgroundAppearance,
        .activate = vActivate,
        .minimize = vMinimize,
        .zoom = vZoom,
        .toggleFullscreen = vToggleFullscreen,
        .startWindowMove = vStartWindowMove,
        .startWindowResize = vStartWindowResize,
        .setClientInset = vSetClientInset,
        .requestFrame = vRequestFrame,
        .draw = vDraw,
        .spriteAtlas = vSpriteAtlas,
        .updateImePosition = vUpdateImePosition,
        .close = vClose,
        .displayId = vDisplayId,
        .attachNativeView = vAttachNativeView,
        .placeNativeView = vPlaceNativeView,
        .detachNativeView = vDetachNativeView,
        .focusNativeView = vFocusNativeView,
        .drawLayered = vDrawLayered,
        .attachLiquidGlass = vAttachLiquidGlass, // [liquid-glass]
        .configureLiquidGlass = vConfigureLiquidGlass,
        .setBackdropHole = vSetBackdropHole,
        .a11yUpdate = vA11yUpdate,
    };

    fn vA11yUpdate(ptr: *anyopaque, update: platform.a11y.Update) void {
        mac_a11y.update(cast(ptr), update);
    }

    // [liquid-glass] A hole in the behind-window material (native_views.zig).
    fn vSetBackdropHole(ptr: *anyopaque, hole: ?platform.BackdropHole) void {
        const self = cast(ptr);
        if (self.closed) return;
        native_views.setBackdropHole(self, hole);
    }

    // [liquid-glass] NSGlassEffectView children (native_views.zig).
    fn vAttachLiquidGlass(ptr: *anyopaque, options: platform.LiquidGlassAttach) anyerror!platform.NativeViewId {
        return native_views.attachGlass(cast(ptr), options);
    }
    fn vConfigureLiquidGlass(ptr: *anyopaque, view: platform.NativeViewId, config: platform.LiquidGlassConfig) void {
        const self = cast(ptr);
        if (self.closed) return;
        native_views.configureGlass(self, view, config);
    }

    fn vAttachNativeView(ptr: *anyopaque, native: *anyopaque, options: platform.NativeViewOptions) anyerror!platform.NativeViewId {
        return native_views.attach(cast(ptr), native, options);
    }
    fn vPlaceNativeView(ptr: *anyopaque, view: platform.NativeViewId, placement: ?platform.NativeViewPlacement) void {
        const self = cast(ptr);
        if (self.closed) return;
        native_views.place(self, view, placement);
    }
    fn vDetachNativeView(ptr: *anyopaque, view: platform.NativeViewId) void {
        native_views.detach(cast(ptr), view);
    }
    fn vFocusNativeView(ptr: *anyopaque, view: ?platform.NativeViewId) void {
        native_views.focus(cast(ptr), view);
    }
    fn vDrawLayered(ptr: *anyopaque, scene: *const scene_mod.Scene, overlay: []const platform.OverlayRange, capture_input: bool) anyerror!void {
        const self = cast(ptr);
        if (self.closed) return;
        try native_views.drawLayered(self, scene, overlay, capture_input);
    }

    fn cast(ptr: *anyopaque) *MacWindow {
        return @ptrCast(@alignCast(ptr));
    }
    fn vSetCallbacks(ptr: *anyopaque, cbs: platform.WindowCallbacks) void {
        cast(ptr).callbacks = cbs;
    }
    fn vDisplayId(ptr: *anyopaque) ?u32 {
        return ak.displayIdForScreen(cast(ptr).native_window.msg(?id, "screen", .{}));
    }
    fn vBounds(ptr: *anyopaque) Bounds {
        return cast(ptr).boundsImpl();
    }
    fn vContentSize(ptr: *anyopaque) Size {
        return cast(ptr).contentSize();
    }
    fn vResize(ptr: *anyopaque, size: Size) void {
        // Deferred (zui): resizing synchronously re-enters setFrameSize: → resize callback.
        const Ctx = struct {
            fn run(ctx: ?*anyopaque) callconv(.c) void {
                const req: *ResizeRequest = @ptrCast(@alignCast(ctx.?));
                defer std.heap.c_allocator.destroy(req);
                defer req.view.release();
                const w = state(req.view) orelse return;
                w.native_window.msg(void, "setContentSize:", .{NSSize{ .width = req.size.width, .height = req.size.height }});
            }
        };
        const self = cast(ptr);
        const req = std.heap.c_allocator.create(ResizeRequest) catch return;
        req.* = .{ .view = self.native_view.retain(), .size = size };
        dispatcher.onMain(req, &Ctx.run);
    }
    fn vScaleFactor(ptr: *anyopaque) f32 {
        return cast(ptr).scaleFactor();
    }
    fn vAppearance(ptr: *anyopaque) platform.WindowAppearance {
        return ak.appearanceFromNative(cast(ptr).native_window.msg(?id, "effectiveAppearance", .{}));
    }
    fn vMousePosition(ptr: *anyopaque) Point {
        const self = cast(ptr);
        const p = self.native_window.msg(NSPoint, "mouseLocationOutsideOfEventStream", .{});
        return .{ .x = @floatCast(p.x), .y = self.contentSize().height - @as(f32, @floatCast(p.y)) };
    }
    fn vModifiers(_: *anyopaque) input.Modifiers {
        return events.modifiersFromFlags(ak.class("NSEvent").msg(NSUInteger, "modifierFlags", .{}));
    }
    fn vIsActive(ptr: *anyopaque) bool {
        return cast(ptr).native_window.msg(BOOL, "isKeyWindow", .{}) == YES;
    }
    fn vIsHovered(ptr: *anyopaque) bool {
        return cast(ptr).hovered;
    }
    fn vIsFullscreen(ptr: *anyopaque) bool {
        return cast(ptr).isFullscreen();
    }
    fn vIsMaximized(ptr: *anyopaque) bool {
        const self = cast(ptr);
        const screen = self.native_window.msg(?id, "screen", .{}) orelse return false;
        const visible = ak.msgStruct(NSRect, screen, "visibleFrame", .{});
        const size = self.boundsImpl().size;
        return size.width == @as(f32, @floatCast(visible.size.width)) and size.height == @as(f32, @floatCast(visible.size.height));
    }
    fn vSetInputHandler(ptr: *anyopaque, handler: ?platform.InputHandler) void {
        cast(ptr).input_handler = handler;
    }
    fn vSetTitle(ptr: *anyopaque, title: []const u8) void {
        cast(ptr).setTitle(title);
    }
    fn vSetBackgroundAppearance(ptr: *anyopaque, bg: platform.WindowBackgroundAppearance) void {
        cast(ptr).setBackgroundAppearance(bg);
    }
    fn vActivate(ptr: *anyopaque) void {
        sendDeferred(cast(ptr), "makeKeyAndOrderFront:");
    }
    fn vMinimize(ptr: *anyopaque) void {
        cast(ptr).native_window.msg(void, "miniaturize:", .{@as(?id, null)});
    }
    fn vZoom(ptr: *anyopaque) void {
        sendDeferred(cast(ptr), "zoom:");
    }
    fn vToggleFullscreen(ptr: *anyopaque) void {
        sendDeferred(cast(ptr), "toggleFullScreen:");
    }
    fn vStartWindowMove(ptr: *anyopaque) void {
        const event = ak.sharedApp().msg(?id, "currentEvent", .{}) orelse return;
        cast(ptr).native_window.msg(void, "performWindowDragWithEvent:", .{event});
    }
    fn vStartWindowResize(_: *anyopaque, _: platform.ResizeEdge) void {
        // AppKit resizes titled windows itself; client-side resize is Linux-only.
    }
    fn vSetClientInset(_: *anyopaque, _: geometry.Pixels) void {}
    fn vRequestFrame(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.frame_requested = true;
        if (self.frame_source == null or !self.frame_source.?.isRunning()) self.startDisplayLink();
    }
    fn vDraw(ptr: *anyopaque, scene: *const scene_mod.Scene) anyerror!void {
        const self = cast(ptr);
        if (self.closed) return;
        try self.renderer.drawScene(scene, self.drawableSize(), self.scaleFactor(), .{});
    }
    fn vSpriteAtlas(ptr: *anyopaque) *atlas_mod.Atlas {
        return cast(ptr).renderer.atlas();
    }
    fn vUpdateImePosition(_: *anyopaque, _: Bounds) void {
        const Ctx = struct {
            fn run(_: ?*anyopaque) callconv(.c) void {
                const ctx = ak.class("NSTextInputContext").msg(?id, "currentInputContext", .{}) orelse return;
                ctx.msg(void, "invalidateCharacterCoordinates", .{});
            }
        };
        dispatcher.onMain(null, &Ctx.run);
    }
    fn vClose(ptr: *anyopaque) void {
        sendDeferred(cast(ptr), "close");
    }
};

const ResizeRequest = struct { view: id, size: Size };

/// Send a no-argument-or-nil-argument action to the window on the next main-queue
/// turn, if the window still exists (zui `if_window_not_closed`).
fn sendDeferred(self: *MacWindow, comptime selector: [:0]const u8) void {
    const Ctx = struct {
        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const view: id = @ptrCast(ctx.?);
            defer view.release();
            const w = state(view) orelse return;
            if (w.closed) return;
            if (comptime std.mem.endsWith(u8, selector, ":")) {
                w.native_window.msg(void, selector, .{@as(?id, null)});
            } else {
                w.native_window.msg(void, selector, .{});
            }
        }
    };
    dispatcher.onMain(self.native_view.retain(), &Ctx.run);
}

fn scaleFactorOf(native_window: id) f32 {
    const screen = native_window.msg(?id, "screen", .{}) orelse return 2;
    const f: f32 = @floatCast(screen.msg(ak.CGFloat, "backingScaleFactor", .{}));
    // Sometimes 0 for off-screen windows (zed#6412).
    return if (f == 0) 2 else f;
}

fn sizeFromNS(s: NSSize) Size {
    return .{ .width = @floatCast(s.width), .height = @floatCast(s.height) };
}

fn deviceSize(size: Size, scale: f32) geometry.Size(geometry.DevicePixels) {
    return .{
        .width = @intFromFloat(@max(@round(size.width * scale), 0)),
        .height = @intFromFloat(@max(@round(size.height * scale), 0)),
    };
}

// ---------------------------------------------------------------------------
// Display-link tick (main queue)
// ---------------------------------------------------------------------------

fn step(ctx: ?*anyopaque) callconv(.c) void {
    const self: *MacWindow = @ptrCast(@alignCast(ctx.?));
    if (self.closed) return;
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    if (self.frame_requested) {
        self.frame_requested = false;
        self.idle_ticks = 0;
        self.requestFrameCallback(false);
    } else {
        self.idle_ticks += 1;
        if (self.idle_ticks >= idle_ticks_before_park) {
            self.stopDisplayLink();
            self.renderer.trimIdleResources();
        }
    }
}

// ---------------------------------------------------------------------------
// NSWindow delegate / overrides
// ---------------------------------------------------------------------------

fn windowDidResize(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    w.moveTrafficLight();
}

fn windowDidChangeOcclusionState(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    if (w.native_window.msg(NSUInteger, "occlusionState", .{}) & ak.NSWindowOcclusionStateVisible != 0) {
        w.moveTrafficLight();
        w.frame_requested = true;
        w.startDisplayLink();
    } else {
        w.stopDisplayLink();
    }
}

fn windowWillEnterFullScreen(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    w.restoreTrafficLight();
    if (ak.osAtLeast(15, 3, 0)) w.native_window.msg(void, "setTitlebarAppearsTransparent:", .{NO});
}

fn windowWillExitFullScreen(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    if (ak.osAtLeast(15, 3, 0) and w.transparent_titlebar) w.native_window.msg(void, "setTitlebarAppearsTransparent:", .{YES});
}

fn windowDidExitFullScreen(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    w.moveTrafficLight();
}

fn windowDidMove(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    if (w.callbacks.moved) |f| f(w.callbacks.ctx);
}

fn windowDidChangeScreen(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    w.startDisplayLink();
    w.updateScaleFactorAndSize();
}

fn windowDidBecomeKey(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    const is_active = w.native_window.msg(BOOL, "isKeyWindow", .{}) == YES;
    // A pop-up opened while the app is inactive can trigger a spurious
    // becomeKey on the previous key window; balance it (zui).
    if (!is_active) {
        w.native_window.msg(void, "resignKeyWindow", .{});
        return;
    }
    // Draw synchronously on re-activation to avoid flicker (not on the first activation,
    // so the initial focus path is established first).
    if (w.activated_at_least_once) {
        w.synchronousFrame();
    } else {
        w.activated_at_least_once = true;
    }
    notifyActiveDeferred(w, true);
}

fn windowDidResignKey(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    notifyActiveDeferred(w, w.native_window.msg(BOOL, "isKeyWindow", .{}) == YES);
}

/// zui dispatches active-status changes through the foreground executor.
fn notifyActiveDeferred(w: *MacWindow, active: bool) void {
    const Ctx = struct {
        fn run(ctx: ?*anyopaque) callconv(.c) void {
            const req: *ActiveRequest = @ptrCast(@alignCast(ctx.?));
            defer std.heap.c_allocator.destroy(req);
            defer req.view.release();
            const win = state(req.view) orelse return;
            if (win.closed) return;
            if (req.active) win.moveTrafficLight();
            if (win.callbacks.active_status_change) |f| f(win.callbacks.ctx, req.active);
        }
    };
    const req = std.heap.c_allocator.create(ActiveRequest) catch return;
    req.* = .{ .view = w.native_view.retain(), .active = active };
    dispatcher.onMain(req, &Ctx.run);
}

const ActiveRequest = struct { view: id, active: bool };

fn windowShouldClose(this: id, _: SEL, _: id) callconv(.c) BOOL {
    const w = state(this) orelse return YES;
    const f = w.callbacks.should_close orelse return YES;
    return objc.toBOOL(f(w.callbacks.ctx));
}

fn closeWindow(this: id, _: SEL) callconv(.c) void {
    if (state(this)) |w| if (!w.closed) {
        w.closed = true;
        w.stopDisplayLink();
        w.input_handler = null;
        if (w.callbacks.close) |f| f(w.callbacks.ctx);
        const Ctx = struct {
            fn run(ctx: ?*anyopaque) callconv(.c) void {
                const win: *MacWindow = @ptrCast(@alignCast(ctx.?));
                win.destroy();
            }
        };
        dispatcher.onMain(w, &Ctx.run);
    };
    var sup = superOf(this, "NSWindow");
    objc.msgSendSuper(void, &sup, objc.sel("close"), .{});
}

// -- file drag & drop ------------------------------------------------------------

fn dragPosition(w: *MacWindow, info: id) Point {
    const p = info.msg(NSPoint, "draggingLocation", .{});
    return .{ .x = @floatCast(p.x), .y = w.contentSize().height - @as(f32, @floatCast(p.y)) };
}

fn sendFileDrop(w: *MacWindow, event: input.FileDropEvent) bool {
    const f = w.callbacks.input orelse return false;
    _ = f(w.callbacks.ctx, .{ .file_drop = event });
    switch (event) {
        .entered => w.external_files_dragged = true,
        .exited => w.external_files_dragged = false,
        else => {},
    }
    return true;
}

fn draggingEntered(this: id, _: SEL, info: id) callconv(.c) NSUInteger {
    const w = state(this) orelse return ak.NSDragOperationNone;
    const pb = info.msg(id, "draggingPasteboard", .{});
    const files = pb.msg(?id, "propertyListForType:", .{ak.NSFilenamesPboardType}) orelse return ak.NSDragOperationNone;
    const count = ak.arrayCount(files);
    const paths = w.gpa.alloc([]const u8, count) catch return ak.NSDragOperationNone;
    defer w.gpa.free(paths);
    for (paths, 0..) |*p, i| p.* = ak.stringBytes(ak.arrayAt(files, i));
    const ok = sendFileDrop(w, .{ .entered = .{ .position = dragPosition(w, info), .paths = paths } });
    return if (ok) ak.NSDragOperationCopy else ak.NSDragOperationNone;
}

fn draggingUpdated(this: id, _: SEL, info: id) callconv(.c) NSUInteger {
    const w = state(this) orelse return ak.NSDragOperationNone;
    return if (sendFileDrop(w, .{ .pending = .{ .position = dragPosition(w, info) } })) ak.NSDragOperationCopy else ak.NSDragOperationNone;
}

fn draggingExited(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    _ = sendFileDrop(w, .exited);
}

fn performDragOperation(this: id, _: SEL, info: id) callconv(.c) BOOL {
    const w = state(this) orelse return NO;
    return objc.toBOOL(sendFileDrop(w, .{ .submit = .{ .position = dragPosition(w, info) } }));
}

fn concludeDragOperation(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    _ = sendFileDrop(w, .exited);
}

// ---------------------------------------------------------------------------
// NSView overrides: layer, size, appearance, cursor
// ---------------------------------------------------------------------------

fn makeBackingLayer(this: id, _: SEL) callconv(.c) ?id {
    const w = state(this) orelse return null;
    return @ptrCast(w.renderer.layer());
}

fn viewDidChangeBackingProperties(this: id, _: SEL) callconv(.c) void {
    const w = state(this) orelse return;
    w.updateScaleFactorAndSize();
}

fn setFrameSize(this: id, _: SEL, size: NSSize) callconv(.c) void {
    const old = ak.frame(this).size;
    var sup = superOf(this, "NSView");
    if (old.width == size.width and old.height == size.height) return;
    objc.msgSendSuper(void, &sup, objc.sel("setFrameSize:"), .{size});
    const w = state(this) orelse return;
    w.renderer.resize(w.drawableSize()) catch |err| log.err("renderer resize: {s}", .{@errorName(err)});
    native_views.refreshBackdropMask(w); // [liquid-glass] the mask image tracks the width
    if (w.callbacks.resize) |f| f(w.callbacks.ctx, w.contentSize(), w.scaleFactor());
}

fn displayLayer(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    w.synchronousFrame();
}

fn viewDidChangeEffectiveAppearance(this: id, _: SEL) callconv(.c) void {
    const w = state(this) orelse return;
    if (w.callbacks.appearance_changed) |f| f(w.callbacks.ctx);
    // AppKit may relayout the standard buttons when applying an appearance.
    w.moveTrafficLight();
}

fn acceptsFirstMouse(this: id, _: SEL, _: id) callconv(.c) BOOL {
    if (state(this)) |w| w.first_mouse = true;
    return YES;
}

/// Empty: AppKit keeps native titlebar dragging (zui without `app_owns_titlebar_drag`).
fn opaqueRectForWindowMove(_: id, _: SEL) callconv(.c) NSRect {
    return .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
}

fn resetCursorRects(this: id, _: SEL) callconv(.c) void {
    var sup = superOf(this, "NSView");
    objc.msgSendSuper(void, &sup, objc.sel("resetCursorRects"), .{});
    const w = state(this) orelse return;
    const cursor = cursorFor(w.cursor_style);
    this.msg(void, "addCursorRect:cursor:", .{ ak.bounds(this), cursor });
}

pub fn cursorFor(style: platform.CursorStyle) id {
    const C = ak.class("NSCursor");
    return switch (style) {
        .arrow, .none => C.msg(id, "arrowCursor", .{}),
        .ibeam => C.msg(id, "IBeamCursor", .{}),
        .crosshair => C.msg(id, "crosshairCursor", .{}),
        .closed_hand => C.msg(id, "closedHandCursor", .{}),
        .open_hand => C.msg(id, "openHandCursor", .{}),
        .pointing_hand => C.msg(id, "pointingHandCursor", .{}),
        .resize_left => C.msg(id, "resizeLeftCursor", .{}),
        .resize_right => C.msg(id, "resizeRightCursor", .{}),
        .resize_left_right, .resize_column => C.msg(id, "resizeLeftRightCursor", .{}),
        .resize_up => C.msg(id, "resizeUpCursor", .{}),
        .resize_down => C.msg(id, "resizeDownCursor", .{}),
        .resize_up_down, .resize_row => C.msg(id, "resizeUpDownCursor", .{}),
        .operation_not_allowed => C.msg(id, "operationNotAllowedCursor", .{}),
        .drag_link => C.msg(id, "dragLinkCursor", .{}),
        .drag_copy => C.msg(id, "dragCopyCursor", .{}),
        .context_menu => C.msg(id, "contextualMenuCursor", .{}),
    };
}

/// Store the cursor on the active zpui window and invalidate its cursor rects
/// (zui `set_active_window_cursor_style`).
pub fn setActiveWindowCursorStyle(style: platform.CursorStyle) void {
    const app = ak.sharedApp();
    const candidates = [_]?id{ app.msg(?id, "keyWindow", .{}), app.msg(?id, "mainWindow", .{}) };
    for (candidates) |maybe| {
        const win = maybe orelse continue;
        if (!(objc.isKindOf(win, window_class orelse return) or objc.isKindOf(win, panel_class.?))) continue;
        const w = state(win) orelse continue;
        if (w.cursor_style != style) {
            w.cursor_style = style;
            w.native_window.msg(void, "invalidateCursorRectsForView:", .{w.native_view});
        }
        if (style == .none) ak.class("NSCursor").msg(void, "setHiddenUntilMouseMoves:", .{YES});
        return;
    }
}

// ---------------------------------------------------------------------------
// Keyboard (zui `handle_key_event`)
// ---------------------------------------------------------------------------

fn performKeyEquivalent(this: id, _: SEL, event: id) callconv(.c) BOOL {
    return handleKeyEvent(this, event, true);
}

fn keyDown(this: id, _: SEL, event: id) callconv(.c) void {
    _ = handleKeyEvent(this, event, false);
}

fn keyUp(this: id, _: SEL, event: id) callconv(.c) void {
    _ = handleKeyEvent(this, event, false);
}

fn inputContextHandle(view: id, event: id) bool {
    const ctx = view.msg(?id, "inputContext", .{}) orelse return false;
    return ctx.msg(BOOL, "handleEvent:", .{event}) == YES;
}

fn isPrintable(s: []const u8) bool {
    var it = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (it.nextCodepoint()) |c| if (c < 0x20 or (c >= 0x7f and c <= 0x9f)) return false;
    return true;
}

// Things to test when modifying this (from zui):
//  U.S.: IME must not eat `j`/`k` in vim-like bindings; `alt-t` reaches bindings; "j j" multi-stroke works.
//  Brazilian: `" space` → unmarked quote; `" backspace` deletes the marked quote; `" cmd-down` inserts and moves.
//  Japanese (Romaji): `a i left down up enter enter` → 愛; with a "j j" binding, `j i` → じ.
fn handleKeyEvent(this: id, native_event: id, key_equivalent: bool) BOOL {
    const w = state(this) orelse return NO;
    const translated = events.translate(native_event, w.contentSize().height) orelse return NO;
    switch (translated) {
        .key_down => |kd_value| {
            var kd = kd_value;
            // macOS may deliver a key equivalent and then the same key as keyDown:;
            // gpui treats them as one event.
            if (key_equivalent) {
                w.last_key_equivalent = kd;
            } else if (w.last_key_equivalent) |last| {
                w.last_key_equivalent = null;
                if (last.eql(&kd)) return NO;
            }
            const ks = kd.buf.keystroke();
            const event: input.PlatformInput = .{ .key_down = .{ .keystroke = ks, .is_held = kd.is_held } };
            const m = ks.modifiers;
            const is_composing = w.markedTextRange() != null;

            // Send to the IME first when composing, for printable keys under a
            // composition input source, and for non-printing keys (the IME menu may
            // need arrows/escape) — except with ctrl/fn/cmd, which it would swallow.
            const is_ime_printable_key = !is_composing and
                ks.key_char != null and isPrintable(ks.key_char.?) and
                !m.control and !m.function and !m.platform and
                w.input_handler != null and events.isImeInputSourceActive();
            if (is_composing or is_ime_printable_key or
                (ks.key_char == null and !m.control and !m.function and !m.platform))
            {
                w.keystroke_for_do_command = kd.buf;
                w.do_command_handled = null;
                const handled = inputContextHandle(this, native_event);
                const ww = state(this) orelse return objc.toBOOL(handled);
                ww.keystroke_for_do_command = null;
                if (ww.do_command_handled) |h| {
                    ww.do_command_handled = null;
                    return objc.toBOOL(h);
                } else if (handled) return YES;
                return objc.toBOOL(ww.runCallback(event));
            }

            if (w.runCallback(event)) return YES;
            // ApplePressAndHold is assumed enabled (gpui's default), so held keys are not re-inserted here.

            // Key equivalents with modifiers other than fn go back to AppKit, or
            // shortcuts like cmd-` stop working.
            const only_function = input.Modifiers{ .function = true };
            if (key_equivalent and !m.eql(only_function)) return NO;
            if (state(this) == null) return NO;
            return objc.toBOOL(inputContextHandle(this, native_event));
        },
        .key_up => |ku| {
            return objc.toBOOL(w.runCallback(.{ .key_up = .{ .keystroke = ku.buf.keystroke() } }));
        },
        .input => return NO,
    }
}

// ---------------------------------------------------------------------------
// Mouse / scroll / modifiers (zui `handle_view_event`)
// ---------------------------------------------------------------------------

fn mouseEntered(this: id, _: SEL, _: id) callconv(.c) void {
    const w = state(this) orelse return;
    w.hovered = true;
    if (w.callbacks.hover_status_change) |f| f(w.callbacks.ctx, true);
}

fn mouseExited(this: id, s: SEL, event: id) callconv(.c) void {
    handleViewEvent(this, s, event);
    const w = state(this) orelse return;
    w.hovered = false;
    if (w.callbacks.hover_status_change) |f| f(w.callbacks.ctx, false);
}

pub fn handleViewEvent(this: id, _: SEL, native_event: id) callconv(.c) void {
    const w = state(this) orelse return;
    const translated = events.translate(native_event, w.contentSize().height) orelse return;
    var event = switch (translated) {
        .input => |e| e,
        else => return,
    };

    switch (event) {
        .mouse_down => |*e| if (e.button == .left and e.modifiers.control) {
            // ctrl-left click is a right click on macOS.
            e.button = .right;
            e.modifiers.control = false;
            e.click_count = 1;
        } else if (e.button == .left and w.first_mouse) {
            // The click that focused the window.
            e.first_mouse = true;
            w.first_mouse = false;
        },
        // Matches the ctrl-left → right mapping above so downs/ups stay paired.
        .mouse_up => |*e| if (e.button == .left and e.modifiers.control) {
            e.button = .right;
            e.modifiers.control = false;
            e.click_count = 1;
        },
        else => {},
    }

    switch (event) {
        .mouse_down => {
            // Let the IME commit/cancel composition on click.
            _ = inputContextHandle(this, native_event);
        },
        .mouse_move => |e| if (e.pressed_button != null and !w.external_files_dragged) {
            // Synthetic drags keep selections extending while content autoscrolls.
            w.synthetic_drag_counter += 1;
            scheduleSyntheticDrag(w, w.synthetic_drag_counter, e);
        },
        .mouse_up => w.synthetic_drag_counter += 1,
        .modifiers_changed => |e| {
            // Only report actual changes.
            if (w.previous_modifiers) |prev| if (prev.modifiers.eql(e.modifiers) and prev.capslock == e.capslock) return;
            w.previous_modifiers = e;
        },
        else => {},
    }

    const ww = state(this) orelse return;
    _ = ww.dispatchInput(event);
}

const SyntheticDrag = struct { view: id, drag_id: usize, event: input.MouseMoveEvent };

fn scheduleSyntheticDrag(w: *MacWindow, drag_id: usize, event: input.MouseMoveEvent) void {
    const ctx = std.heap.c_allocator.create(SyntheticDrag) catch return;
    ctx.* = .{ .view = w.native_view.retain(), .drag_id = drag_id, .event = event };
    dispatcher.onMainAfter(synthetic_drag_interval_ns, ctx, &syntheticDragTick);
}

fn syntheticDragTick(raw: ?*anyopaque) callconv(.c) void {
    const ctx: *SyntheticDrag = @ptrCast(@alignCast(raw.?));
    const w = state(ctx.view);
    if (w != null and !w.?.closed and w.?.synthetic_drag_counter == ctx.drag_id) {
        _ = w.?.dispatchInput(.{ .mouse_move = ctx.event });
        dispatcher.onMainAfter(synthetic_drag_interval_ns, ctx, &syntheticDragTick);
        return;
    }
    ctx.view.release();
    std.heap.c_allocator.destroy(ctx);
}

// ---------------------------------------------------------------------------
// NSTextInputClient
// ---------------------------------------------------------------------------

const invalid_range: NSRange = .{ .location = ak.NSNotFound, .length = 0 };

fn toRange(r: NSRange) ?platform.InputHandler.Range {
    if (r.location == ak.NSNotFound) return null;
    return .{ .start = r.location, .end = r.location + r.length };
}

fn fromRange(r: platform.InputHandler.Range) NSRange {
    return .{ .location = r.start, .length = r.end - r.start };
}

/// UTF-8 of an `NSString` or `NSAttributedString` argument.
fn textArg(text: id) []const u8 {
    const s = if (objc.isKindOf(text, ak.class("NSAttributedString"))) text.msg(id, "string", .{}) else text;
    return ak.stringBytes(s);
}

fn validAttributesForMarkedText(_: id, _: SEL) callconv(.c) id {
    return ak.class("NSArray").msg(id, "array", .{});
}

fn hasMarkedText(this: id, _: SEL) callconv(.c) BOOL {
    const w = state(this) orelse return NO;
    return objc.toBOOL(w.markedTextRange() != null);
}

fn markedRange(this: id, _: SEL) callconv(.c) NSRange {
    const w = state(this) orelse return invalid_range;
    return if (w.markedTextRange()) |r| fromRange(r) else invalid_range;
}

fn selectedRange(this: id, _: SEL) callconv(.c) NSRange {
    const w = state(this) orelse return invalid_range;
    const h = w.input_handler orelse return invalid_range;
    const sel = h.vtable.selectedTextRange(h.ptr) orelse return invalid_range;
    return fromRange(sel.range);
}

/// The window frame used to map IME rects (zui `get_frame`).
fn imeFrame(w: *MacWindow) NSRect {
    var f = ak.frame(w.native_window);
    const layout = ak.msgStruct(NSRect, w.native_window, "contentLayoutRect", .{});
    if (w.native_window.msg(NSUInteger, "styleMask", .{}) & ak.WindowStyleMask.full_size_content_view == 0) {
        f.origin.y -= f.size.height - layout.size.height;
    }
    return f;
}

fn firstRectForCharacterRange(this: id, _: SEL, range: NSRange, _: ?*NSRange) callconv(.c) NSRect {
    const zero: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
    const w = state(this) orelse return zero;
    const h = w.input_handler orelse return zero;
    const r = toRange(range) orelse return zero;
    const b = h.vtable.boundsForRange(h.ptr, r) orelse return zero;
    const f = imeFrame(w);
    return .{
        .origin = .{
            .x = f.origin.x + b.origin.x,
            .y = f.origin.y + f.size.height - b.origin.y - b.size.height,
        },
        .size = .{ .width = b.size.width, .height = b.size.height },
    };
}

fn insertText(this: id, _: SEL, text: id, replacement: NSRange) callconv(.c) void {
    const w = state(this) orelse return;
    const h = w.input_handler orelse return;
    h.vtable.replaceTextInRange(h.ptr, toRange(replacement), textArg(text));
}

fn setMarkedText(this: id, _: SEL, text: id, selected: NSRange, replacement: NSRange) callconv(.c) void {
    const w = state(this) orelse return;
    const h = w.input_handler orelse return;
    h.vtable.replaceAndMarkTextInRange(h.ptr, toRange(replacement), textArg(text), toRange(selected));
}

fn unmarkText(this: id, _: SEL) callconv(.c) void {
    const w = state(this) orelse return;
    const h = w.input_handler orelse return;
    h.vtable.unmarkText(h.ptr);
}

fn attributedSubstring(this: id, _: SEL, range: NSRange, actual: ?*NSRange) callconv(.c) ?id {
    const w = state(this) orelse return null;
    const h = w.input_handler orelse return null;
    const r = toRange(range) orelse return null;
    if (r.start == r.end) return null;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(w.gpa);
    const adjusted = h.vtable.textForRange(h.ptr, r, &out, w.gpa) orelse return null;
    if (actual) |a| if (adjusted.start != r.start or adjusted.end != r.end) {
        a.* = fromRange(adjusted);
    };
    const str = ak.nsString(out.items);
    return ak.class("NSAttributedString").msg(id, "alloc", .{}).msg(id, "initWithString:", .{str}).autorelease();
}

/// gpui has no hit-testing hook in `InputHandler` yet.
fn characterIndexForPoint(_: id, _: SEL, _: NSPoint) callconv(.c) NSUInteger {
    return ak.NSNotFound;
}

/// The IME could not use the key: route it to keybindings. The selector is
/// ignored because users may have rebound the shortcut.
fn doCommandBySelector(this: id, _: SEL, _: SEL) callconv(.c) void {
    const w = state(this) orelse return;
    const buf = w.keystroke_for_do_command orelse return;
    w.keystroke_for_do_command = null;
    // `buf` is a copy on this stack frame, so the keystroke slices outlive the callback.
    const result = w.dispatchInput(.{ .key_down = .{ .keystroke = buf.keystroke() } }) orelse return;
    if (state(this)) |ww| ww.do_command_handled = !result.propagate;
}

// ---------------------------------------------------------------------------
// ZPUIBlurredView (zui `BlurredView`)
// ---------------------------------------------------------------------------

fn blurredViewInitWithFrame(this: id, _: SEL, frame_rect: NSRect) callconv(.c) ?id {
    var sup = superOf(this, "NSVisualEffectView");
    const view = objc.msgSendSuper(?id, &sup, objc.sel("initWithFrame:"), .{frame_rect}) orelse return null;
    // `UnderWindowBackground`, not `Selection`: on macOS 26 `Selection` no longer vends
    // the CABackdropLayer `removeLayerBackground` walks, so nothing would blur.
    view.msg(void, "setMaterial:", .{ak.NSVisualEffectMaterialUnderWindowBackground});
    // Behind-window blending samples the desktop (already the default).
    view.msg(void, "setBlendingMode:", .{ak.NSVisualEffectBlendingModeBehindWindow});
    view.msg(void, "setState:", .{ak.NSVisualEffectStateActive});
    return view;
}

fn blurredViewUpdateLayer(this: id, _: SEL) callconv(.c) void {
    var sup = superOf(this, "NSVisualEffectView");
    objc.msgSendSuper(void, &sup, objc.sel("updateLayer"), .{});
    const layer = this.msg(?id, "layer", .{}) orelse return;
    // Reduce Transparency: AppKit swaps the backdrop for a solid material fill. Keep it,
    // as AppKit's own materials (and native Liquid Glass) do; stripping its backgrounds
    // here would leave the window black instead of the accessible solid surface.
    if (reduceTransparency()) return;
    removeLayerBackground(layer);
    // [liquid-glass] With a backdrop hole cut out (native glass sampling the desktop),
    // no base: it would fill the hole black.
    if (state(this)) |w| if (w.natives.backdrop_hole != null) return;
    // An opaque dark base behind the backdrop keeps Mission Control snapshots
    // (which omit backdrop layers) reading as a solid surface.
    const black = ak.class("NSColor").msg(id, "blackColor", .{});
    layer.msg(void, "setBackgroundColor:", .{black.msg(?*anyopaque, "CGColor", .{})});
}

/// `-[NSWorkspace accessibilityDisplayShouldReduceTransparency]`.
pub fn reduceTransparency() bool {
    const ws = ak.class("NSWorkspace").msg(id, "sharedWorkspace", .{});
    return ws.msg(BOOL, "accessibilityDisplayShouldReduceTransparency", .{}) == YES;
}

fn removeLayerBackground(layer: id) void {
    layer.msg(void, "setBackgroundColor:", .{@as(?*anyopaque, null)});
    const class_name = layer.msg(id, "className", .{});
    if (ak.isEqualToString(class_name, objc.nsString("CAChameleonLayer"))) {
        // Remove the desktop tinting effect.
        layer.msg(void, "setHidden:", .{YES});
        return;
    }
    if (layer.msg(?id, "filters", .{})) |filters| {
        // Widen the backdrop blur (fork: heavier blur under the app's own scrim).
        const count = ak.arrayCount(filters);
        var i: NSUInteger = 0;
        while (i < count) : (i += 1) {
            const filter = ak.arrayAt(filters, i);
            const desc = filter.msg(id, "description", .{});
            if (desc.msg(BOOL, "containsString:", .{objc.nsString("Blur")}) == YES) {
                const radius = ak.class("NSNumber").msg(id, "numberWithDouble:", .{@as(f64, 60)});
                filter.msg(void, "setValue:forKey:", .{ radius, objc.nsString("inputRadius") });
                layer.msg(void, "setFilters:", .{filters});
                break;
            }
        }
        // Drop the saturation boost ("colorSaturate" CAFilter; a CIFilter would say "inputSaturation").
        i = 0;
        while (i < count) : (i += 1) {
            const desc = ak.arrayAt(filters, i).msg(id, "description", .{});
            if (desc.msg(BOOL, "containsString:", .{objc.nsString("Saturat")}) != YES) continue;
            const indices = ak.class("NSMutableIndexSet").msg(id, "indexSet", .{});
            indices.msg(void, "addIndexesInRange:", .{NSRange{ .location = 0, .length = count }});
            indices.msg(void, "removeIndex:", .{i});
            layer.msg(void, "setFilters:", .{filters.msg(id, "objectsAtIndexes:", .{indices})});
            break;
        }
    }
    if (layer.msg(?id, "sublayers", .{})) |sublayers| {
        const count = ak.arrayCount(sublayers);
        var i: NSUInteger = 0;
        while (i < count) : (i += 1) removeLayerBackground(ak.arrayAt(sublayers, i));
    }
}
