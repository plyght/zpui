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
    };

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

pub const Display = struct {
    id: u32,
    bounds: Bounds,
    visible_bounds: Bounds,
    scale_factor: f32,
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
        /// Rasterize into `out` (allocated with gpa, caller frees). Mono = 1 byte/px, emoji = 4 (BGRA premultiplied).
        rasterizeGlyph: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, params: text.RenderGlyphParams, bounds: geometry.Bounds(DevicePixels)) anyerror![]u8,
        /// Shape one line of text with per-run fonts; result allocated in `arena`.
        layoutLine: *const fn (ptr: *anyopaque, arena: std.mem.Allocator, str: []const u8, font_size: Pixels, runs: []const text.FontRun) anyerror!text.LineLayout,
    };
};
