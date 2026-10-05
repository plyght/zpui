//! Platform abstraction: the contract between zpui's core (App/Window) and each OS backend.
//!
//! Mirrors gpui's `Platform`, `PlatformWindow` and `PlatformDispatcher` traits (zui
//! `crates/gpui/src/platform.rs`), trimmed to the subset zeron needs. Backends live in
//! `src/platform/{linux,mac}/` and expose `pub fn create(gpa, options) !*Platform`-style
//! constructors; the core only ever talks to the vtable types below.
//!
//! Threading: every method is main-thread only unless documented otherwise. Callbacks are
//! invoked on the main thread from inside `Platform.run`.

const std = @import("std");
const geometry = @import("../geometry.zig");
const input = @import("../input.zig");
const scene_mod = @import("../scene.zig");
const atlas_mod = @import("../atlas.zig");
/// The accessibility tree handed to window backends (`Window.VTable.a11yUpdate`).
pub const a11y = @import("../a11y.zig");

pub const Pixels = geometry.Pixels;
pub const DevicePixels = geometry.DevicePixels;
pub const Point = geometry.Point(Pixels);
pub const Size = geometry.Size(Pixels);
pub const Bounds = geometry.Bounds(Pixels);

/// Type-erased callback with context. `ctx` is owned by whoever registered the callback.
pub fn Callback(comptime Args: type, comptime Ret: type) type {
    return struct {
        ctx: ?*anyopaque = null,
        func: ?*const fn (ctx: ?*anyopaque, args: Args) Ret = null,

        pub fn call(self: @This(), args: Args) ?Ret {
            const f = self.func orelse return null;
            return f(self.ctx, args);
        }
    };
}

// ---------------------------------------------------------------------------------------
// Dispatcher / executors
// ---------------------------------------------------------------------------------------

/// A unit of work handed to the dispatcher. `run` is called exactly once (or `drop` if the
/// dispatcher shuts down first). Both receive `ctx`.
pub const Runnable = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque) void,
    drop: ?*const fn (ctx: *anyopaque) void = null,
};

pub const Priority = enum { realtime, high, medium, low };

/// gpui `PlatformDispatcher`. Thread-safe: may be called from any thread.
pub const Dispatcher = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        isMainThread: *const fn (ptr: *anyopaque) bool,
        /// Run on a background worker thread.
        dispatch: *const fn (ptr: *anyopaque, r: Runnable, priority: Priority) void,
        /// Run on the main thread from the platform event loop; wakes the loop.
        dispatchOnMainThread: *const fn (ptr: *anyopaque, r: Runnable, priority: Priority) void,
        /// Run on the main thread after `delay_ns`.
        dispatchAfter: *const fn (ptr: *anyopaque, delay_ns: u64, r: Runnable) void,
        /// Monotonic clock in nanoseconds.
        now: *const fn (ptr: *anyopaque) u64,
    };

    pub fn isMainThread(d: Dispatcher) bool {
        return d.vtable.isMainThread(d.ptr);
    }
    pub fn dispatch(d: Dispatcher, r: Runnable, p: Priority) void {
        d.vtable.dispatch(d.ptr, r, p);
    }
    pub fn dispatchOnMainThread(d: Dispatcher, r: Runnable, p: Priority) void {
        d.vtable.dispatchOnMainThread(d.ptr, r, p);
    }
    pub fn dispatchAfter(d: Dispatcher, delay_ns: u64, r: Runnable) void {
        d.vtable.dispatchAfter(d.ptr, delay_ns, r);
    }
    pub fn now(d: Dispatcher) u64 {
        return d.vtable.now(d.ptr);
    }
};

// ---------------------------------------------------------------------------------------
// Windows
// ---------------------------------------------------------------------------------------

pub const WindowAppearance = enum { light, vibrant_light, dark, vibrant_dark };

/// gpui `WindowBackgroundAppearance`. `blurred` = OS blur behind a transparent window
/// (macOS NSVisualEffectView / KDE blur protocol), falls back to `transparent`.
pub const WindowBackgroundAppearance = enum { opaque_, transparent, blurred };

pub const WindowDecorations = enum { server, client };

pub const WindowKind = enum { normal, popup, floating };

pub const TitlebarOptions = struct {
    title: []const u8 = "",
    /// Content extends under a transparent titlebar (macOS fullSizeContentView).
    appears_transparent: bool = false,
    /// macOS traffic light origin, in logical pixels from the window's top-left.
    traffic_light_position: ?Point = null,
};

pub const WindowParams = struct {
    bounds: Bounds,
    titlebar: ?TitlebarOptions = .{},
    kind: WindowKind = .normal,
    focus: bool = true,
    show: bool = true,
    is_movable: bool = true,
    min_size: ?Size = null,
    background: WindowBackgroundAppearance = .opaque_,
    decorations: WindowDecorations = .server,
    app_id: ?[]const u8 = null,
    /// Place the window on this display (`Display.id`); `bounds.origin` is then relative
    /// to that display's top-left. Null = the main display.
    display_id: ?u32 = null,
};

pub const CursorStyle = enum {
    arrow,
    ibeam,
    crosshair,
    closed_hand,
    open_hand,
    pointing_hand,
    resize_left,
    resize_right,
    resize_left_right,
    resize_up,
    resize_down,
    resize_up_down,
    resize_column,
    resize_row,
    operation_not_allowed,
    drag_link,
    drag_copy,
    context_menu,
    none,
};

/// Text input / IME bridge implemented by the core (gpui `PlatformInputHandler`).
/// Ranges are UTF-16 code-unit offsets, as in gpui (macOS semantics).
pub const InputHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Range = struct { start: usize, end: usize };

    pub const VTable = struct {
        selectedTextRange: *const fn (ptr: *anyopaque) ?struct { range: Range, reversed: bool },
        markedTextRange: *const fn (ptr: *anyopaque) ?Range,
        /// Writes UTF-8 for `range` into `out`; returns the actual adjusted range.
        textForRange: *const fn (ptr: *anyopaque, range: Range, out: *std.ArrayList(u8), gpa: std.mem.Allocator) ?Range,
        replaceTextInRange: *const fn (ptr: *anyopaque, range: ?Range, text: []const u8) void,
        replaceAndMarkTextInRange: *const fn (ptr: *anyopaque, range: ?Range, text: []const u8, new_selected: ?Range) void,
        unmarkText: *const fn (ptr: *anyopaque) void,
        /// Window-relative bounds of the text at `range`, for positioning the IME candidate window.
        boundsForRange: *const fn (ptr: *anyopaque, range: Range) ?Bounds,
    };
};

/// Result of dispatching one input event to the core.
pub const DispatchEventResult = struct {
    propagate: bool = true,
    default_prevented: bool = false,
};

/// Callbacks the core registers on each window (gpui's `on_*` setters, collapsed into one struct).
pub const WindowCallbacks = struct {
    ctx: ?*anyopaque = null,
    /// Draw a frame now (display-link / frame callback tick). `force_render` = window was resized/exposed.
    request_frame: ?*const fn (ctx: ?*anyopaque, force_render: bool) void = null,
    input: ?*const fn (ctx: ?*anyopaque, event: input.PlatformInput) DispatchEventResult = null,
    active_status_change: ?*const fn (ctx: ?*anyopaque, active: bool) void = null,
    hover_status_change: ?*const fn (ctx: ?*anyopaque, hovered: bool) void = null,
    resize: ?*const fn (ctx: ?*anyopaque, size: Size, scale_factor: f32) void = null,
    moved: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Return false to veto closing.
    should_close: ?*const fn (ctx: ?*anyopaque) bool = null,
    close: ?*const fn (ctx: ?*anyopaque) void = null,
    appearance_changed: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Assistive technology asks for an action on a node (`a11y.ActionRequest`).
    a11y_action: ?*const fn (ctx: ?*anyopaque, request: a11y.ActionRequest) void = null,
    /// Assistive technology started (true) or stopped (false) using this window: the
    /// core builds the tree only while active and redraws on activation.
    a11y_activation: ?*const fn (ctx: ?*anyopaque, active: bool) void = null,
    /// The user changed a native control (`attachNativeControl`): its new value.
    native_control: ?*const fn (ctx: ?*anyopaque, view: NativeViewId, event: NativeControlEvent) void = null,
};

/// gpui `PlatformWindow`. Owned by the platform; destroyed via `close` + the `close` callback.
pub const Window = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setCallbacks: *const fn (ptr: *anyopaque, cbs: WindowCallbacks) void,
        /// Outer window bounds in screen coordinates (logical pixels).
        bounds: *const fn (ptr: *anyopaque) Bounds,
        contentSize: *const fn (ptr: *anyopaque) Size,
        resize: *const fn (ptr: *anyopaque, size: Size) void,
        scaleFactor: *const fn (ptr: *anyopaque) f32,
        appearance: *const fn (ptr: *anyopaque) WindowAppearance,
        mousePosition: *const fn (ptr: *anyopaque) Point,
        modifiers: *const fn (ptr: *anyopaque) input.Modifiers,
        isActive: *const fn (ptr: *anyopaque) bool,
        isHovered: *const fn (ptr: *anyopaque) bool,
        isFullscreen: *const fn (ptr: *anyopaque) bool,
        isMaximized: *const fn (ptr: *anyopaque) bool,
        setInputHandler: *const fn (ptr: *anyopaque, handler: ?InputHandler) void,
        setTitle: *const fn (ptr: *anyopaque, title: []const u8) void,
        setBackgroundAppearance: *const fn (ptr: *anyopaque, bg: WindowBackgroundAppearance) void,
        activate: *const fn (ptr: *anyopaque) void,
        minimize: *const fn (ptr: *anyopaque) void,
        zoom: *const fn (ptr: *anyopaque) void,
        toggleFullscreen: *const fn (ptr: *anyopaque) void,
        /// Client-side decorations: begin an interactive move / resize from the current pointer event.
        startWindowMove: *const fn (ptr: *anyopaque) void,
        startWindowResize: *const fn (ptr: *anyopaque, edge: ResizeEdge) void,
        /// Area (window coords) that must stay hit-testable as titlebar for CSD / window dragging.
        setClientInset: *const fn (ptr: *anyopaque, inset: Pixels) void,
        /// Request one `request_frame` callback at the next vsync (no-op if already pending).
        requestFrame: *const fn (ptr: *anyopaque) void,
        /// Submit a finished frame to the GPU and present it.
        draw: *const fn (ptr: *anyopaque, scene: *const scene_mod.Scene) anyerror!void,
        /// The window renderer's sprite atlas (shared across windows on some backends).
        spriteAtlas: *const fn (ptr: *anyopaque) *atlas_mod.Atlas,
        updateImePosition: *const fn (ptr: *anyopaque, bounds: Bounds) void,
        close: *const fn (ptr: *anyopaque) void,
        /// The display (`Display.id`) the window is mostly on; null when unknown. Optional.
        displayId: ?*const fn (ptr: *anyopaque) ?u32 = null,

        // -- native child views (optional; see `NativeViewId`) ------------------------------
        /// Host a platform view created by the caller (macOS: any `NSView*`; retained)
        /// inside the window's content view, ordered by `options.z`. Starts hidden.
        attachNativeView: ?*const fn (ptr: *anyopaque, native: *anyopaque, options: NativeViewOptions) anyerror!NativeViewId = null,
        /// Place (or with `null`, hide) an attached view. Applied right before the
        /// matching frame is presented, so native geometry and pixels land together.
        placeNativeView: ?*const fn (ptr: *anyopaque, view: NativeViewId, placement: ?NativeViewPlacement) void = null,
        /// Remove an attached view from the window and release it.
        detachNativeView: ?*const fn (ptr: *anyopaque, view: NativeViewId) void = null,
        /// Give keyboard focus to an attached view, or back to zpui content (`null`).
        focusNativeView: ?*const fn (ptr: *anyopaque, view: ?NativeViewId) void = null,
        /// zui `draw_layered`, generalized: paint operations inside `overlay` ranges
        /// (`scene.paint_operations` indices, sorted, disjoint) go to a transparent plane
        /// above every native view, everything else to the main surface. The window puts
        /// deferred draws, drag previews and tooltips there, plus any element painted
        /// between `Window.pushOverlayPlane`/`popOverlayPlane`.
        /// The window only routes content to the planes while a native view is placed
        /// in the frame (otherwise `overlay` is empty and everything is on the main
        /// surface, exactly like `draw`). Ranges holding backdrop blurs carry
        /// `samples_lower_planes`.
        /// `capture_input`: the overlay holds interactive content and takes the mouse.
        /// Backends without native views leave it null; the window then calls `draw`.
        drawLayered: ?*const fn (ptr: *anyopaque, scene: *const scene_mod.Scene, overlay: []const OverlayRange, capture_input: bool) anyerror!void = null,

        // -- [liquid-glass] native glass children (optional; see `LiquidGlassAttach`) -------
        /// Create a backend glass view (macOS 26: `NSGlassEffectView`, or for `.container`
        /// an `NSGlassEffectContainerView`) and attach it like `attachNativeView`
        /// (pass-through mouse, hidden until placed). Errors when the OS lacks it.
        attachLiquidGlass: ?*const fn (ptr: *anyopaque, options: LiquidGlassAttach) anyerror!NativeViewId = null,
        /// The window's own corner radius in logical pixels (macOS `_cornerRadius`), if known.
        windowCornerRadius: ?*const fn (ptr: *anyopaque) ?f32 = null,
        /// Apply style / tint / corner radius / interactivity / container spacing.
        configureLiquidGlass: ?*const fn (ptr: *anyopaque, view: NativeViewId, config: LiquidGlassConfig) void = null,
        /// [liquid-glass] Cut `hole` out of the window's behind-window material (macOS
        /// `blurred` background: the `NSVisualEffectView` under the main surface), so
        /// native glass above a transparent (alpha 0) region samples the desktop itself
        /// rather than the app's blurred backdrop. null = no hole.
        setBackdropHole: ?*const fn (ptr: *anyopaque, hole: ?BackdropHole) void = null,

        // -- native form controls (optional; see `NativeControlState`) ---------------------
        /// The frame size (logical px) the platform control for `state` wants; a 0 width
        /// or height means "no preference" (the layout decides). null: this window shows
        /// no native control for `state` (the caller renders its own fallback).
        measureNativeControl: ?*const fn (ptr: *anyopaque, state: NativeControlState) ?Size = null,
        /// Create the platform control for `state` (macOS: NSSwitch, NSSlider, ...) and
        /// attach it like `attachNativeView` (hidden until placed). User changes come
        /// back through `WindowCallbacks.native_control`.
        attachNativeControl: ?*const fn (ptr: *anyopaque, state: NativeControlState, z: NativeViewZ) anyerror!NativeViewId = null,
        /// Apply a new state (value, items, enabled, appearance, ...). Never reports
        /// back through `native_control` (programmatic changes are not user changes).
        updateNativeControl: ?*const fn (ptr: *anyopaque, view: NativeViewId, state: NativeControlState) void = null,

        // -- accessibility (optional; see `a11y.zig`) ----------------------------------------
        /// A frame's finalized accessibility tree and what changed since the last one. The
        /// tree stays valid (the backend may keep the pointer and answer queries from it)
        /// until the next call or until the window closes.
        a11yUpdate: ?*const fn (ptr: *anyopaque, update: a11y.Update) void = null,
    };

    /// Whether this backend can host native child views (`attachNativeView`).
    pub fn supportsNativeViews(w: Window) bool {
        return w.vtable.attachNativeView != null and w.vtable.placeNativeView != null and w.vtable.detachNativeView != null;
    }
    pub fn attachNativeView(w: Window, native: *anyopaque, options: NativeViewOptions) !NativeViewId {
        const f = w.vtable.attachNativeView orelse return error.NativeViewsUnsupported;
        return f(w.ptr, native, options);
    }
    pub fn placeNativeView(w: Window, view: NativeViewId, placement: ?NativeViewPlacement) void {
        if (w.vtable.placeNativeView) |f| f(w.ptr, view, placement);
    }
    pub fn detachNativeView(w: Window, view: NativeViewId) void {
        if (w.vtable.detachNativeView) |f| f(w.ptr, view);
    }
    pub fn focusNativeView(w: Window, view: ?NativeViewId) void {
        if (w.vtable.focusNativeView) |f| f(w.ptr, view);
    }
    /// [liquid-glass] Whether this window can host native glass (`attachLiquidGlass`).
    pub fn hasLiquidGlass(w: Window) bool {
        return w.vtable.attachLiquidGlass != null and w.vtable.configureLiquidGlass != null and w.supportsNativeViews();
    }
    pub fn windowCornerRadius(w: Window) ?f32 {
        const f = w.vtable.windowCornerRadius orelse return null;
        return f(w.ptr);
    }
    pub fn attachLiquidGlass(w: Window, options: LiquidGlassAttach) !NativeViewId {
        const f = w.vtable.attachLiquidGlass orelse return error.LiquidGlassUnsupported;
        return f(w.ptr, options);
    }
    pub fn configureLiquidGlass(w: Window, view: NativeViewId, config: LiquidGlassConfig) void {
        if (w.vtable.configureLiquidGlass) |f| f(w.ptr, view, config);
    }
    pub fn setBackdropHole(w: Window, hole: ?BackdropHole) void {
        if (w.vtable.setBackdropHole) |f| f(w.ptr, hole);
    }
    /// Whether this backend can host native form controls at all.
    pub fn hasNativeControls(w: Window) bool {
        return w.vtable.measureNativeControl != null and w.vtable.attachNativeControl != null and
            w.vtable.updateNativeControl != null and w.supportsNativeViews();
    }
    pub fn measureNativeControl(w: Window, state: NativeControlState) ?Size {
        const f = w.vtable.measureNativeControl orelse return null;
        return f(w.ptr, state);
    }
    pub fn attachNativeControl(w: Window, state: NativeControlState, z: NativeViewZ) !NativeViewId {
        const f = w.vtable.attachNativeControl orelse return error.NativeControlsUnsupported;
        return f(w.ptr, state, z);
    }
    pub fn updateNativeControl(w: Window, view: NativeViewId, state: NativeControlState) void {
        if (w.vtable.updateNativeControl) |f| f(w.ptr, view, state);
    }
    pub fn supportsA11y(w: Window) bool {
        return w.vtable.a11yUpdate != null;
    }
    pub fn a11yUpdate(w: Window, update: a11y.Update) void {
        if (w.vtable.a11yUpdate) |f| f(w.ptr, update);
    }

    pub fn setCallbacks(w: Window, cbs: WindowCallbacks) void {
        w.vtable.setCallbacks(w.ptr, cbs);
    }
    pub fn bounds(w: Window) Bounds {
        return w.vtable.bounds(w.ptr);
    }
    pub fn contentSize(w: Window) Size {
        return w.vtable.contentSize(w.ptr);
    }
    pub fn scaleFactor(w: Window) f32 {
        return w.vtable.scaleFactor(w.ptr);
    }
    pub fn appearance(w: Window) WindowAppearance {
        return w.vtable.appearance(w.ptr);
    }
    pub fn mousePosition(w: Window) Point {
        return w.vtable.mousePosition(w.ptr);
    }
    pub fn modifiers(w: Window) input.Modifiers {
        return w.vtable.modifiers(w.ptr);
    }
    pub fn requestFrame(w: Window) void {
        w.vtable.requestFrame(w.ptr);
    }
    pub fn draw(w: Window, scene: *const scene_mod.Scene) !void {
        return w.vtable.draw(w.ptr, scene);
    }
    pub fn spriteAtlas(w: Window) *atlas_mod.Atlas {
        return w.vtable.spriteAtlas(w.ptr);
    }
    pub fn setTitle(w: Window, title: []const u8) void {
        w.vtable.setTitle(w.ptr, title);
    }
    pub fn setInputHandler(w: Window, h: ?InputHandler) void {
        w.vtable.setInputHandler(w.ptr, h);
    }
    pub fn close(w: Window) void {
        w.vtable.close(w.ptr);
    }
};

pub const ResizeEdge = enum { top, top_right, right, bottom_right, bottom, bottom_left, left, top_left };

/// Native child views (zui fork's native-child compositing, generalized).
///
/// Any platform view the caller creates (macOS: an `NSView*` — a WKWebView for zeron's
/// browser, an NSGlassEffectView for Liquid Glass, ...) can be attached to a window and
/// becomes one of its subviews. Several children per window; each picks its z-order:
///
///     .below_content:  [ child ] < [ zpui surface ] < [ overlay plane ]   (needs a transparent window/scene)
///     .above_content:  [ zpui surface ] < [ child ] < [ overlay plane ]   (default)
///
/// Per frame, the element `zpui.nativeView(id)` (or `Window.paintNativeView`) records the
/// child's bounds, corner radius and the current content mask during paint; the window
/// applies the placements right before presenting (children not painted this frame are
/// hidden) and draws with `drawLayered`: paint operations in overlay ranges land on a
/// transparent Metal layer above every child. Deferred draws (menus, popovers), drag
/// previews and tooltips are overlay content automatically; any other element can paint
/// there with `Window.pushOverlayPlane()` / `popOverlayPlane()` (e.g. text above glass).
/// `pass_through_mouse` children never take hit tests, so zpui keeps input over them.
/// Coordinates are window-relative logical pixels, top-left origin. Only macOS implements
/// this; elsewhere `supportsNativeViews()` is false and nothing is attached.
pub const NativeViewId = enum(u32) { _ };

pub const NativeViewZ = enum {
    above_content,
    below_content,
    /// [liquid-glass] Above the overlay plane, below the top plane: floating glass
    /// (menus, popovers, tooltips) whose own foreground paints on the top plane.
    above_overlay,
};

pub const NativeViewOptions = struct {
    z: NativeViewZ = .above_content,
    /// Never hit-test (mouse events fall through to zpui content).
    pass_through_mouse: bool = false,
};

/// Half-open range of `Scene.paint_operations` indices drawn on the overlay plane
/// (or, with `plane = .top`, on the top plane above `.above_overlay` children).
pub const OverlayRange = struct {
    start: usize,
    end: usize,
    plane: OverlayPlane = .overlay,
    /// The range holds a backdrop blur. Its plane is transparent where the planes
    /// beneath show through, so the backend must blur the COMPOSITED planes beneath
    /// (main surface, plus the overlay plane for `.top`) rather than the plane's own
    /// drawable, or the blur blurs nothing (frosted menus over crisp content).
    /// Native children between planes are invisible to the renderer and stay unblurred.
    samples_lower_planes: bool = false,
};

/// [liquid-glass] The two transparent planes above native children, back to front:
///
///     [main surface] < [.above_content children] < [overlay plane]
///                    < [.above_overlay children] < [top plane]
pub const OverlayPlane = enum(u8) { overlay, top };

// ---- [liquid-glass] native Liquid Glass (macOS 26 NSGlassEffectView) --------------------

/// `NSGlassEffectView.Style` (raw values match AppKit: regular = 0, clear = 1).
pub const LiquidGlassStyle = enum(u8) { regular = 0, clear = 1 };

pub const LiquidGlassKind = enum {
    /// `NSGlassEffectView` (no content view: zpui paints the foreground on a plane above).
    glass,
    /// `NSGlassEffectContainerView`: glass views attached with `parent` = this view
    /// become descendants of its content view and merge/morph within `spacing`.
    container,
    /// A behind-window sidebar material (`NSVisualEffectView`, `.sidebar`,
    /// `.behindWindow`, follows the window's active state), always attached
    /// `.below_content` (under the main surface: zpui must leave alpha 0 above it).
    /// The fallback when glass alone cannot show the desktop (docs/LIQUID_GLASS.md).
    sidebar_material,
};

/// [liquid-glass] A rounded rectangle (logical px, window coordinates) cut out of the
/// window's behind-window material (`Window.setBackdropHole`).
pub const BackdropHole = struct {
    bounds: Bounds,
    /// Corner radii: top-left, top-right, bottom-right, bottom-left.
    corner_radii: [4]Pixels = .{ 0, 0, 0, 0 },
};

pub const LiquidGlassAttach = struct {
    kind: LiquidGlassKind = .glass,
    z: NativeViewZ = .above_content,
    /// A `.container` view: the new glass is added inside it (frames relative to it)
    /// instead of directly in the window's content view.
    parent: ?NativeViewId = null,
};

pub const LiquidGlassConfig = struct {
    style: LiquidGlassStyle = .regular,
    /// Straight-alpha sRGB tint (`NSGlassEffectView.tintColor`), null = none.
    tint: ?[4]f32 = null,
    /// `effectIsInteractive` (AppKit, macOS 27+; ignored where unavailable).
    interactive: bool = false,
    /// Glass `cornerRadius` in logical pixels.
    corner_radius: Pixels = 0,
    /// Container merge distance (`NSGlassEffectContainerView.spacing`).
    spacing: Pixels = 0,
    /// Force a light/dark glass material (the app's theme), null = follow the system.
    dark: ?bool = null,
    /// Place the glass under the main surface (Ghostty's window glass): zpui paints its
    /// translucent content on top of it instead of on the overlay plane.
    behind_content: bool = false,
};

// ---- native form controls (macOS: AppKit controls as native child views) ----------------

/// The platform control behind `zpui.nativeSwitch` & co. (macOS: NSSwitch, NSButton
/// checkbox, NSSlider, NSSegmentedControl, NSPopUpButton, NSStepper).
pub const NativeControlKind = enum(u8) { switch_, checkbox, slider, segmented, popup, stepper };

/// AppKit `NSControlSize` (raw values match: regular 0, small 1, mini 2, large 3).
pub const NativeControlSize = enum(u8) { regular = 0, small = 1, mini = 2, large = 3 };

/// Everything a native control shows. Slices are borrowed for the duration of the call
/// (backends copy what they keep).
pub const NativeControlState = struct {
    kind: NativeControlKind,
    enabled: bool = true,
    size: NativeControlSize = .regular,
    /// Pin the control's appearance to dark / light (the app theme); null = system.
    dark: ?bool = null,
    /// Accessible name (and a checkbox's title when `title` is null).
    label: []const u8 = "",
    /// A checkbox's visible title ("" = a bare box).
    title: []const u8 = "",
    /// Accessibility help / tooltip (e.g. why the control is unavailable).
    help: []const u8 = "",
    /// switch / checkbox.
    on: bool = false,
    /// slider / stepper.
    value: f64 = 0,
    min: f64 = 0,
    max: f64 = 1,
    /// stepper: increment; slider: > 0 snaps to tick marks every `step`.
    step: f64 = 0,
    /// segmented / popup: the option labels and the selected index.
    items: []const []const u8 = &.{},
    selected: ?u32 = null,
};

/// A user change reported by a native control (`WindowCallbacks.native_control`).
pub const NativeControlEvent = struct {
    kind: NativeControlKind,
    /// switch / checkbox: the new state.
    on: bool = false,
    /// slider / stepper: the new value.
    value: f64 = 0,
    /// segmented / popup: the newly selected index.
    index: u32 = 0,
};

pub const NativeViewPlacement = struct {
    /// Where the native view's frame goes (its full layout bounds).
    bounds: Bounds,
    /// The visible region (bounds ∩ content mask); native pixels and hit testing are
    /// clipped to it.
    clip: Bounds,
    /// Uniform corner radius applied to the child's layer (glass shapes).
    corner_radius: Pixels = 0,
};

pub const Display = struct {
    id: u32,
    bounds: Bounds,
    visible_bounds: Bounds,
    scale_factor: f32,
    /// Stable identity across launches (macOS `CGDisplayCreateUUIDFromDisplayID`), raw
    /// RFC 4122 bytes; null when the backend has none.
    uuid: ?[16]u8 = null,
    /// The main display (menu bar / primary output).
    primary: bool = false,
};

// ---------------------------------------------------------------------------------------
// Platform
// ---------------------------------------------------------------------------------------

pub const PlatformCallbacks = struct {
    ctx: ?*anyopaque = null,
    quit: ?*const fn (ctx: ?*anyopaque) void = null,
    reopen: ?*const fn (ctx: ?*anyopaque) void = null,
    open_urls: ?*const fn (ctx: ?*anyopaque, urls: []const []const u8) void = null,
    keyboard_layout_change: ?*const fn (ctx: ?*anyopaque) void = null,
    system_wake: ?*const fn (ctx: ?*anyopaque) void = null,
    // -- app lifecycle (see `App.onShouldQuit`, `App.setMenus`) ---------------------------
    /// The OS asks to terminate (Dock "Quit", logout, the native app menu's Quit). Return
    /// false to cancel; the app then quits later through `Platform.quit`, which is never
    /// vetoed. Null = always allow.
    should_quit: ?*const fn (ctx: ?*anyopaque) bool = null,
    /// A menu item from `setMenus` was chosen (its `MenuItem.action.tag`).
    menu_action: ?*const fn (ctx: ?*anyopaque, tag: usize) void = null,
    /// Whether menu item `tag` is enabled right now (AppKit `validateMenuItem:`).
    validate_menu: ?*const fn (ctx: ?*anyopaque, tag: usize) bool = null,
    /// A menu is about to open (refresh state the validation reads).
    will_open_menu: ?*const fn (ctx: ?*anyopaque) void = null,
    /// A notification posted with `postNotification` was clicked; `tag` as posted
    /// (borrowed for the call).
    notification_activated: ?*const fn (ctx: ?*anyopaque, tag: []const u8) void = null,
};

/// gpui `Platform`.
pub const Platform = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        dispatcher: *const fn (ptr: *anyopaque) Dispatcher,
        textSystem: *const fn (ptr: *anyopaque) TextSystem,
        setCallbacks: *const fn (ptr: *anyopaque, cbs: PlatformCallbacks) void,
        /// Enter the OS event loop. `on_launch` runs once the app has finished launching.
        /// Returns after `quit`.
        run: *const fn (ptr: *anyopaque, on_launch: Callback(void, void)) void,
        quit: *const fn (ptr: *anyopaque) void,
        activate: *const fn (ptr: *anyopaque, ignoring_other_apps: bool) void,
        openWindow: *const fn (ptr: *anyopaque, params: WindowParams) anyerror!Window,
        displays: *const fn (ptr: *anyopaque, out: []Display) usize,
        windowAppearance: *const fn (ptr: *anyopaque) WindowAppearance,
        setCursorStyle: *const fn (ptr: *anyopaque, style: CursorStyle) void,
        /// Clipboard: write UTF-8 text; read returns bytes allocated with `gpa` (caller frees).
        writeClipboard: *const fn (ptr: *anyopaque, text: []const u8) void,
        readClipboard: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator) ?[]u8,
        openUrl: *const fn (ptr: *anyopaque, url: []const u8) void,
        revealPath: *const fn (ptr: *anyopaque, path: []const u8) void,
        /// Whether the OS asked for reduced motion.
        prefersReducedMotion: *const fn (ptr: *anyopaque) bool,
        deinit: *const fn (ptr: *anyopaque) void,
        /// Image data on the clipboard (gpui `ClipboardEntry::Image`), bytes allocated
        /// with `gpa` (caller frees). Null when the clipboard holds no image. Optional.
        readClipboardImage: ?*const fn (ptr: *anyopaque, gpa: std.mem.Allocator) ?ClipboardImage = null,
        /// Native "open file" dialog (gpui `prompt_for_paths`). Never blocks: `done`
        /// runs later on the main thread exactly once (null paths = canceled or no
        /// dialog available). Optional.
        promptForPaths: ?*const fn (ptr: *anyopaque, options: PathPromptOptions, done: PathsCallback) void = null,
        // -- app lifecycle (optional) ----------------------------------------------------
        /// Install the application menu bar (macOS); strings are copied. Items report
        /// back through `PlatformCallbacks.menu_action` / `validate_menu`.
        setMenus: ?*const fn (ptr: *anyopaque, menus: []const Menu) void = null,
        /// Hide this app / the other apps / show all (macOS NSApp verbs).
        appCommand: ?*const fn (ptr: *anyopaque, command: AppCommand) void = null,
        /// The standard About panel (macOS `orderFrontStandardAboutPanelWithOptions:`).
        showAboutPanel: ?*const fn (ptr: *anyopaque, options: AboutPanelOptions) void = null,
        /// Post a desktop banner (macOS NSUserNotification, Linux
        /// org.freedesktop.Notifications). Never blocks; failures are swallowed.
        postNotification: ?*const fn (ptr: *anyopaque, notification: Notification) void = null,
        /// Play an in-memory sound (WAV) without blocking (macOS NSSound, Linux
        /// paplay / pw-play / aplay / ffplay / mpv). Failures are swallowed.
        playSound: ?*const fn (ptr: *anyopaque, bytes: []const u8) void = null,
        // -- global hotkey + window capture (optional; see `GlobalHotkey`) -----------------
        /// Register (or with null, unregister) the app's one system-wide hotkey. Replaces
        /// the previous registration. `handler` runs on the main thread per press.
        setGlobalHotkey: ?*const fn (ptr: *anyopaque, hotkey: ?GlobalHotkey, handler: GlobalHotkeyHandler) void = null,
        /// Current hotkey / capture / accessibility-text readiness (cheap; main thread).
        windowCaptureCapabilities: ?*const fn (ptr: *anyopaque) WindowCaptureCapabilities = null,
        /// Capture the frontmost window of another application. Never blocks: `done` runs
        /// later on the main thread exactly once.
        captureActiveWindow: ?*const fn (ptr: *anyopaque, gpa: std.mem.Allocator, done: WindowCaptureCallback) void = null,
        /// Ask the OS for a capture permission (macOS prompts; elsewhere a no-op).
        requestCaptureAccess: ?*const fn (ptr: *anyopaque, kind: CaptureAccess) void = null,
        /// Bring this app back to the front after a user-requested capture (macOS).
        foregroundAfterCapture: ?*const fn (ptr: *anyopaque) void = null,
        // [liquid-glass] Native Liquid Glass (macOS 26+ NSGlassEffectView) is available
        // on this machine. Null = never (every non-macOS backend, older macOS).
        supportsLiquidGlass: ?*const fn (ptr: *anyopaque) bool = null,
        // [liquid-glass] The macOS major version whose Liquid Glass design is shown
        // (26 Tahoe, 27 Golden Gate, ...); 0 where `supportsLiquidGlass` is false.
        liquidGlassRevision: ?*const fn (ptr: *anyopaque) u32 = null,
    };

    pub fn dispatcher(p: Platform) Dispatcher {
        return p.vtable.dispatcher(p.ptr);
    }
    pub fn textSystem(p: Platform) TextSystem {
        return p.vtable.textSystem(p.ptr);
    }
    pub fn run(p: Platform, on_launch: Callback(void, void)) void {
        p.vtable.run(p.ptr, on_launch);
    }
    pub fn quit(p: Platform) void {
        p.vtable.quit(p.ptr);
    }
    pub fn openWindow(p: Platform, params: WindowParams) !Window {
        return p.vtable.openWindow(p.ptr, params);
    }
    pub fn setCursorStyle(p: Platform, s: CursorStyle) void {
        p.vtable.setCursorStyle(p.ptr, s);
    }
    pub fn deinit(p: Platform) void {
        p.vtable.deinit(p.ptr);
    }
    /// The clipboard's image, if any (caller frees `bytes` with `gpa`).
    pub fn readClipboardImage(p: Platform, gpa: std.mem.Allocator) ?ClipboardImage {
        const f = p.vtable.readClipboardImage orelse return null;
        return f(p.ptr, gpa);
    }
    pub fn setMenus(p: Platform, menus: []const Menu) void {
        if (p.vtable.setMenus) |f| f(p.ptr, menus);
    }
    pub fn appCommand(p: Platform, command: AppCommand) void {
        if (p.vtable.appCommand) |f| f(p.ptr, command);
    }
    pub fn showAboutPanel(p: Platform, options: AboutPanelOptions) void {
        if (p.vtable.showAboutPanel) |f| f(p.ptr, options);
    }
    pub fn postNotification(p: Platform, n: Notification) void {
        if (p.vtable.postNotification) |f| f(p.ptr, n);
    }
    pub fn playSound(p: Platform, bytes: []const u8) void {
        if (p.vtable.playSound) |f| f(p.ptr, bytes);
    }
    /// [liquid-glass] Whether native Liquid Glass (`zpui.liquidGlass`) can be shown.
    pub fn supportsLiquidGlass(p: Platform) bool {
        const f = p.vtable.supportsLiquidGlass orelse return false;
        return f(p.ptr);
    }
    /// [liquid-glass] macOS major version of the native glass design (26, 27, ...), 0 = none.
    pub fn liquidGlassRevision(p: Platform) u32 {
        if (!p.supportsLiquidGlass()) return 0;
        const f = p.vtable.liquidGlassRevision orelse return 26;
        return f(p.ptr);
    }
    /// Open the native file picker; `done` runs on the main thread (null = canceled).
    pub fn promptForPaths(p: Platform, options: PathPromptOptions, done: PathsCallback) void {
        const f = p.vtable.promptForPaths orelse return done.func(done.ctx, null);
        f(p.ptr, options, done);
    }
    /// Register / replace / (null) remove the system-wide hotkey. No-op without support.
    pub fn setGlobalHotkey(p: Platform, hotkey: ?GlobalHotkey, handler: GlobalHotkeyHandler) void {
        if (p.vtable.setGlobalHotkey) |f| f(p.ptr, hotkey, handler);
    }
    pub fn windowCaptureCapabilities(p: Platform) WindowCaptureCapabilities {
        const f = p.vtable.windowCaptureCapabilities orelse return .{};
        return f(p.ptr);
    }
    /// Capture the frontmost window; `done` runs on the main thread (owns the result).
    pub fn captureActiveWindow(p: Platform, gpa: std.mem.Allocator, done: WindowCaptureCallback) void {
        const f = p.vtable.captureActiveWindow orelse {
            var r: WindowCaptureResult = .{ .err = .{ .failed = gpa.dupe(u8, "Appshots are not available on this platform.") catch &.{} } };
            return done.done(done.ctx, gpa, &r);
        };
        f(p.ptr, gpa, done);
    }
    pub fn requestCaptureAccess(p: Platform, kind: CaptureAccess) void {
        if (p.vtable.requestCaptureAccess) |f| f(p.ptr, kind);
    }
    pub fn foregroundAfterCapture(p: Platform) void {
        if (p.vtable.foregroundAfterCapture) |f| f(p.ptr);
    }
};

// ---------------------------------------------------------------------------------------
// Global hotkey + frontmost-window capture (zeron Appshots: `appshots/{macos,linux}`)
// ---------------------------------------------------------------------------------------

/// A system-wide hotkey: one key (gpui key name: "space", "a", "f5", "pageup", ...) plus
/// modifiers. `platform` is Command on macOS and Super/Logo elsewhere.
pub const GlobalHotkey = struct {
    key: []const u8,
    control: bool = false,
    alt: bool = false,
    shift: bool = false,
    platform: bool = false,
    /// Linux GlobalShortcuts portal: the shortcut's description shown by the desktop.
    description: []const u8 = "Capture an Appshot",
    /// Linux GlobalShortcuts portal: the shortcut id (stable per app).
    id: []const u8 = "capture-appshot",

    pub fn eql(a: GlobalHotkey, b: GlobalHotkey) bool {
        return std.mem.eql(u8, a.key, b.key) and a.control == b.control and a.alt == b.alt and
            a.shift == b.shift and a.platform == b.platform;
    }
};

/// Main-thread hotkey press handler.
pub const GlobalHotkeyHandler = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque) void,
};

/// Readiness of one capture capability (zeron `CapabilityState`).
pub const CapabilityState = enum { checking, ready, permission_required, setup_required, user_selection, unavailable };

/// Which backend captures (zeron `AppshotPlatform`).
pub const CaptureSystem = enum { macos, linux_wayland, linux_x11, unsupported };

/// What a capture targets (zeron `CaptureTarget`).
pub const CaptureTarget = enum { active_window, portal_window_picker };

pub const WindowCaptureCapabilities = struct {
    system: CaptureSystem = .unsupported,
    global_hotkey: CapabilityState = .unavailable,
    window_capture: CapabilityState = .unavailable,
    application_text: CapabilityState = .unavailable,
    target: CaptureTarget = .active_window,
};

pub const CaptureAccess = enum { capture, semantic };

/// A captured window. All slices are owned (allocated with the `gpa` passed to
/// `captureActiveWindow`); free with `deinit`.
pub const WindowCapture = struct {
    /// The window's pixels, PNG-encoded.
    png: []u8,
    app_name: []u8,
    bundle_identifier: ?[]u8 = null,
    window_title: ?[]u8 = null,
    /// Accessibility-tree text (AXUIElement / AT-SPI), one node per line; "" when none.
    accessibility: []u8 = &.{},
    accessibility_truncated: bool = false,
    /// The application's icon, PNG-encoded (presentation only).
    icon_png: ?[]u8 = null,

    pub fn deinit(self: *WindowCapture, gpa: std.mem.Allocator) void {
        gpa.free(self.png);
        gpa.free(self.app_name);
        if (self.bundle_identifier) |s| gpa.free(s);
        if (self.window_title) |s| gpa.free(s);
        gpa.free(self.accessibility);
        if (self.icon_png) |s| gpa.free(s);
        self.* = undefined;
    }
};

/// zeron `CaptureError` (the message of `.failed` is owned).
pub const WindowCaptureError = union(enum) {
    permission_required,
    cancelled,
    self_capture,
    no_eligible_window,
    shortcut_unavailable,
    failed: []u8,
};

pub const WindowCaptureResult = union(enum) {
    ok: WindowCapture,
    err: WindowCaptureError,

    pub fn deinit(self: *WindowCaptureResult, gpa: std.mem.Allocator) void {
        switch (self.*) {
            .ok => |*c| c.deinit(gpa),
            .err => |e| if (e == .failed) gpa.free(e.failed),
        }
    }
};

/// Completion of `captureActiveWindow` (main thread). The callee takes ownership of
/// `result` (move it out or `deinit` it with `gpa`). `pixels_ready`, when set, fires on
/// the main thread as soon as the pixels are saved, before slower accessibility
/// enrichment finishes (zeron's capture sound cue).
pub const WindowCaptureCallback = struct {
    ctx: ?*anyopaque = null,
    done: *const fn (ctx: ?*anyopaque, gpa: std.mem.Allocator, result: *WindowCaptureResult) void,
    pixels_ready: ?*const fn (ctx: ?*anyopaque) void = null,
};

// ---------------------------------------------------------------------------------------
// Menus, app commands, notifications (gpui `Menu` / `MenuItem` / `OsAction`)
// ---------------------------------------------------------------------------------------

/// Native editing verbs a menu item maps to (macOS selectors `cut:`, `copy:`, ...), so
/// the OS routes them to native text fields (save panels) as well.
pub const OsAction = enum { cut, copy, paste, select_all, undo, redo };

pub const SystemMenuType = enum { services };

/// A menu item's displayed shortcut (single keystroke; gpui spelling of `key`).
pub const KeyEquivalent = struct {
    key: []const u8,
    modifiers: input.Modifiers = .{},
};

pub const MenuItem = union(enum) {
    separator,
    action: struct {
        name: []const u8,
        /// Reported back through `PlatformCallbacks.menu_action` / `validate_menu`.
        tag: usize,
        key_equivalent: ?KeyEquivalent = null,
        os_action: ?OsAction = null,
        checked: bool = false,
        disabled: bool = false,
    },
    submenu: Menu,
    system_menu: struct { name: []const u8, kind: SystemMenuType },
};

/// A top-level menu (or a submenu). A menu named "Window" becomes the OS window menu.
pub const Menu = struct {
    name: []const u8,
    items: []const MenuItem,
    disabled: bool = false,
};

pub const AppCommand = enum { hide, hide_other_apps, unhide_other_apps };

pub const AboutPanelOptions = struct {
    application_name: []const u8,
    version: []const u8,
};

/// A desktop banner. `tag` (e.g. a chat id) comes back in
/// `PlatformCallbacks.notification_activated` when the user clicks it.
pub const Notification = struct {
    title: []const u8,
    body: []const u8 = "",
    tag: ?[]const u8 = null,
    /// Linux `app_name` (macOS attributes banners to the bundle).
    app_name: []const u8 = "",
    /// macOS: an unbundled process (dev run) borrows this installed app's identity so
    /// the banner shows its name and icon (zeron `notify.rs`); else `osascript`.
    bundle_id: ?[]const u8 = null,
};

/// gpui `ImageFormat` subset carried by clipboard images.
pub const ClipboardImageFormat = enum {
    png,
    jpeg,
    gif,
    webp,
    bmp,
    tiff,
    svg,

    pub fn mimeType(f: ClipboardImageFormat) []const u8 {
        return switch (f) {
            .png => "image/png",
            .jpeg => "image/jpeg",
            .gif => "image/gif",
            .webp => "image/webp",
            .bmp => "image/bmp",
            .tiff => "image/tiff",
            .svg => "image/svg+xml",
        };
    }

    pub fn fromMime(mime: []const u8) ?ClipboardImageFormat {
        inline for (std.meta.fields(ClipboardImageFormat)) |f| {
            const v: ClipboardImageFormat = @enumFromInt(f.value);
            if (std.ascii.eqlIgnoreCase(mime, v.mimeType())) return v;
        }
        if (std.ascii.eqlIgnoreCase(mime, "image/jpg")) return .jpeg;
        return null;
    }

    /// Preference order when a clipboard offers several image types (lossless first).
    pub const preference = [_]ClipboardImageFormat{ .png, .tiff, .bmp, .webp, .jpeg, .gif, .svg };
};

/// Encoded image bytes read from the clipboard.
pub const ClipboardImage = struct {
    format: ClipboardImageFormat,
    bytes: []u8,
};

/// gpui `PathPromptOptions`.
pub const PathPromptOptions = struct {
    files: bool = true,
    directories: bool = false,
    multiple: bool = false,
    /// The accept button's label ("Attach"); null = the platform default.
    prompt: ?[]const u8 = null,
    /// Dialog title; null = the platform default.
    title: ?[]const u8 = null,
};

/// Completion of `promptForPaths`. `paths` (and its strings) are borrowed for the
/// duration of the call; copy what you keep.
pub const PathsCallback = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, paths: ?[]const []const u8) void,
};

// ---------------------------------------------------------------------------------------
// Platform text system (implemented by text/coretext.zig and text/freetype.zig)
// ---------------------------------------------------------------------------------------

pub const text = @import("../text/types.zig");

/// gpui `PlatformTextSystem`. Shaping + rasterization backend; caching lives in the core.
pub const TextSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Register font data (TTF/OTF bytes, must outlive the text system).
        addFont: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!void,
        fontId: *const fn (ptr: *anyopaque, font: text.Font) anyerror!text.FontId,
        fontMetrics: *const fn (ptr: *anyopaque, id: text.FontId) text.FontMetrics,
        glyphForChar: *const fn (ptr: *anyopaque, id: text.FontId, ch: u21) ?text.GlyphId,
        advance: *const fn (ptr: *anyopaque, id: text.FontId, glyph: text.GlyphId) geometry.Size(f32),
        glyphRasterBounds: *const fn (ptr: *anyopaque, params: text.RenderGlyphParams) anyerror!geometry.Bounds(DevicePixels),
        /// Rasterize into `out` (allocated with gpa, caller frees). Mono = 1 byte/px; emoji = 4 (BGRA, straight
        /// alpha, as the polychrome atlas expects); subpixel = 4 (BGRA per-channel LCD coverage, A = max).
        rasterizeGlyph: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, params: text.RenderGlyphParams, bounds: geometry.Bounds(DevicePixels)) anyerror![]u8,
        /// Shape one line of text with per-run fonts; result allocated in `arena`.
        layoutLine: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, str: []const u8, font_size: Pixels, runs: []const text.FontRun) anyerror!text.LineLayout,
    };
};
