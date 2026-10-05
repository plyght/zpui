//! The Window (gpui `window.rs`): owns a platform window, its layout engine, per-window text
//! system, element arena and two `Frame`s (rendered / next), and runs the frame lifecycle:
//!
//!   draw: invalidate dirty views → render root view → request layout → compute layout
//!         → prepaint (hitboxes, dispatch tree, element offsets) → paint (scene, listeners)
//!         → swap frames → focus events → present → clear element arena
//!
//! Elements talk to the window during their phases: `requestLayout` / `layoutBounds`,
//! `insertHitbox`, `elementState`, the paint API (`paintQuad`, `paintGlyph`, ... in
//! paint.zig), listener registration (`onMouseEvent`, `onKeyEvent`, `onAction`) and the
//! push/pop stacks (element offset, content mask, text style, opacity, edge fade).
//! Input dispatch (mouse capture/bubble, keymap, actions, IME) lives in dispatch.zig.
//!
//! Main-thread only. A Window is heap-allocated and owned by the App (`app.openWindow`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");
const platform = @import("../platform/platform.zig");
const input = @import("../input.zig");
const scene_mod = @import("../scene.zig");
const atlas_mod = @import("../atlas.zig");
const layout = @import("../layout/layout.zig");
const style_mod = @import("../style.zig");
const refine = @import("../style/refine.zig");
const text_mod = @import("../text/text.zig");
const app_mod = @import("../app/app.zig");
const App = app_mod.App;
const entity_mod = @import("../app/entity.zig");
const EntityId = entity_mod.EntityId;
const dispatch_tree = @import("../app/dispatch_tree.zig");
const DispatchTree = dispatch_tree.DispatchTree;
pub const DispatchPhase = dispatch_tree.DispatchPhase;
pub const DispatchNodeId = dispatch_tree.DispatchNodeId;
const KeyContext = @import("../app/key_context.zig").KeyContext;
const AnyAction = @import("../app/action.zig").AnyAction;
const type_id = @import("../app/type_id.zig");
const TypeId = type_id.TypeId;
const subscriber_set = @import("../app/subscriber_set.zig");
const Subscription = subscriber_set.Subscription;

pub const arena_mod = @import("arena.zig");
pub const element = @import("element.zig");
pub const callback = @import("callback.zig");
pub const focus_mod = @import("focus.zig");
pub const paint_mod = @import("paint.zig");
pub const dispatch_mod = @import("dispatch.zig");
pub const view = @import("view.zig");
pub const input_handler = @import("input_handler.zig");
pub const image = @import("image.zig");
pub const liquid_glass_mod = @import("liquid_glass.zig"); // [liquid-glass]
pub const native_controls_mod = @import("native_controls.zig");
/// Accessibility tree (src/a11y.zig).
pub const a11y = @import("../a11y.zig");

const Captures = callback.Captures;
const ElementArena = arena_mod.ElementArena;
const AnyElement = element.AnyElement;
const ElementId = element.ElementId;
const GlobalElementId = element.GlobalElementId;
const LayoutId = element.LayoutId;
pub const FocusHandle = focus_mod.FocusHandle;
pub const FocusId = focus_mod.FocusId;
const TabStopMap = focus_mod.TabStopMap;
const AnyView = view.AnyView;

pub const Pixels = geometry.Pixels;
pub const Point = geometry.Point(Pixels);
pub const Size = geometry.Size(Pixels);
pub const Bounds = geometry.Bounds(Pixels);
pub const Edges = geometry.Edges(Pixels);
pub const Corners = geometry.Corners(Pixels);
pub const Hsla = color.Hsla;
pub const Style = style_mod.Style;
pub const TextStyle = style_mod.TextStyle;
pub const TextStyleRefinement = style_mod.TextStyleRefinement;
pub const CursorStyle = platform.CursorStyle;
pub const AvailableSpace = layout.AvailableSpace;

/// Options for `App.openWindow` (the platform's window parameters).
pub const WindowOptions = platform.WindowParams;

pub const WindowId = enum(u64) {
    _,
    pub fn index(self: WindowId) u32 {
        return @truncate(@intFromEnum(self));
    }
};

// ---------------------------------------------------------------------------------------
// Hitboxes
// ---------------------------------------------------------------------------------------

pub const HitboxId = enum(u64) {
    _,

    /// Topmost-under-the-mouse test (gpui `HitboxId::is_hovered`). False while the user is
    /// navigating with the keyboard so hover styles don't fight focus styles.
    pub fn isHovered(self: HitboxId, window: *const Window) bool {
        if (window.captured_hitbox) |c| return c == self;
        if (window.last_input_was_keyboard) return false;
        const ids = window.mouse_hit_test.ids.items;
        for (ids[0..@min(window.mouse_hit_test.hover_hitbox_count, ids.len)]) |id| if (id == self) return true;
        return false;
    }

    /// Whether scroll events at the mouse should go to this hitbox (ignores keyboard modality
    /// and `block_mouse_except_scroll` occluders).
    pub fn shouldHandleScroll(self: HitboxId, window: *const Window) bool {
        for (window.mouse_hit_test.ids.items) |id| if (id == self) return true;
        return false;
    }
};

pub const HitboxBehavior = enum {
    /// Hitboxes behind still receive hover and mouse events.
    normal,
    /// Occludes all hitboxes behind it (gpui `occlude()`).
    block_mouse,
    /// Occludes hover/click behind it but lets scroll through.
    block_mouse_except_scroll,
};

pub const ContentMask = struct {
    bounds: Bounds,

    pub fn intersect(a: ContentMask, b: ContentMask) ContentMask {
        return .{ .bounds = a.bounds.intersect(b.bounds) };
    }
};

pub const Hitbox = struct {
    id: HitboxId,
    bounds: Bounds,
    content_mask: ContentMask,
    behavior: HitboxBehavior = .normal,

    pub fn isHovered(self: Hitbox, window: *const Window) bool {
        return self.id.isHovered(window);
    }
    pub fn shouldHandleScroll(self: Hitbox, window: *const Window) bool {
        return self.id.shouldHandleScroll(window);
    }
    pub fn contains(self: Hitbox, p: Point) bool {
        return self.bounds.intersect(self.content_mask.bounds).contains(p);
    }
};

/// Result of hit-testing the mouse position: hitbox ids front to back.
pub const HitTest = struct {
    ids: std.ArrayList(HitboxId) = .empty,
    /// Only the first `hover_hitbox_count` ids count as hovered (the rest are behind a
    /// `block_mouse_except_scroll` hitbox).
    hover_hitbox_count: usize = 0,

    pub fn eql(a: *const HitTest, b: *const HitTest) bool {
        return a.hover_hitbox_count == b.hover_hitbox_count and std.mem.eql(HitboxId, a.ids.items, b.ids.items);
    }
};

/// A scoped edge fade (zui fork `EdgeFade`): primitives inside fade to transparent across
/// `band` at each active edge of `bounds`.
pub const EdgeFade = struct {
    bounds: Bounds,
    band: Pixels,
    band_top: ?Pixels = null,
    band_bottom: ?Pixels = null,
    band_left: ?Pixels = null,
    band_right: ?Pixels = null,
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,

    pub fn topBand(self: EdgeFade) f32 {
        return @max(self.band_top orelse self.band, 1);
    }
    pub fn bottomBand(self: EdgeFade) f32 {
        return @max(self.band_bottom orelse self.band, 1);
    }
    pub fn leftBand(self: EdgeFade) f32 {
        return @max(self.band_left orelse self.band, 1);
    }
    pub fn rightBand(self: EdgeFade) f32 {
        return @max(self.band_right orelse self.band, 1);
    }
    fn active(self: EdgeFade) bool {
        return self.top or self.bottom or self.left or self.right;
    }
};

pub const CursorStyleRequest = struct { hitbox_id: ?HitboxId, style: CursorStyle };

// ---------------------------------------------------------------------------------------
// Frame-owned listeners and requests
// ---------------------------------------------------------------------------------------

pub const MouseEventKind = enum { mouse_down, mouse_up, mouse_move, mouse_exited, scroll_wheel };

pub fn mouseEventKind(comptime Ev: type) MouseEventKind {
    return switch (Ev) {
        input.MouseDownEvent => .mouse_down,
        input.MouseUpEvent => .mouse_up,
        input.MouseMoveEvent => .mouse_move,
        input.MouseExitEvent => .mouse_exited,
        input.ScrollWheelEvent => .scroll_wheel,
        else => @compileError(@typeName(Ev) ++ " is not a mouse event"),
    };
}

pub const MouseListener = struct {
    kind: MouseEventKind,
    func: *const fn (cap: *Captures, event: *const anyopaque, phase: DispatchPhase, window: *Window, app: *App) void,
    cap: Captures,
};

/// An element input handler registered during paint (see input_handler.zig).
pub const InputHandlerRequest = input_handler.ElementInputHandler;

pub const TooltipRequest = struct {
    id: u64,
    view: AnyView,
    mouse_position: Point,
    /// Element state of the owner (`*div.InteractiveElementState`) for visibility checks.
    owner: ?*anyopaque = null,
    check_visible: ?*const fn (owner: *anyopaque, tooltip_bounds: Bounds, window: *Window) bool = null,
};

pub const DeferredDraw = struct {
    current_view: EntityId,
    priority: usize,
    parent_node: DispatchNodeId,
    element_id: ?u64,
    text_style_stack: []const TextStyleRefinement,
    rem_size: Pixels,
    content_mask: ?ContentMask,
    element: ?AnyElement,
    absolute_offset: Point,
    prepaint_range: [2]PrepaintIndex = .{ .{}, .{} },
    paint_range: [2]PaintIndex = .{ .{}, .{} },
};

/// Lengths of every per-frame list touched in prepaint (gpui `PrepaintStateIndex`).
pub const PrepaintIndex = struct {
    hitboxes: usize = 0,
    a11y_nodes: usize = 0,
    a11y_pieces: usize = 0,
    a11y_listeners: usize = 0,
    tooltips: usize = 0,
    deferred_draws: usize = 0,
    dispatch_tree: usize = 0,
    accessed_element_states: usize = 0,
    line_layout: text_mod.LineLayoutIndex = .{},
};

/// Lengths of every per-frame list touched in paint (gpui `PaintIndex`).
pub const PaintIndex = struct {
    scene: usize = 0,
    mouse_listeners: usize = 0,
    input_handlers: usize = 0,
    cursor_styles: usize = 0,
    tab_stops: usize = 0,
    accessed_element_states: usize = 0,
    line_layout: text_mod.LineLayoutIndex = .{},
    native_views: usize = 0,
    overlay_ranges: usize = 0,
};

/// An `onA11yAction` registration for one node of the frame's accessibility tree.
pub const A11yListener = struct {
    node: a11y.NodeId,
    action: a11y.Action,
    listener: @import("../app/context.zig").Listener(a11y.ActionRequest),
};

/// One native child view painted this frame (`Window.paintNativeView`).
pub const NativeViewPaint = struct {
    id: platform.NativeViewId,
    placement: platform.NativeViewPlacement,
};

const StateKey = struct { gid: u64, tid: u64 };

const ElementStateBox = struct {
    ptr: *anyopaque,
    destroy: *const fn (ptr: *anyopaque, app: *App) void,
};

fn stateDestroyer(comptime S: type) *const fn (*anyopaque, *App) void {
    return struct {
        fn destroy(ptr: *anyopaque, app: *App) void {
            const s: *S = @ptrCast(@alignCast(ptr));
            entity_mod.callDeinit(S, s, app);
            app.gpa.destroy(s);
        }
    }.destroy;
}

/// Everything one frame produces (gpui `Frame`). The window keeps the rendered frame (used
/// for hit testing and event dispatch) and builds the next one.
pub const Frame = struct {
    gpa: Allocator,
    focus: ?FocusId = null,
    window_active: bool = false,
    element_states: std.AutoHashMapUnmanaged(StateKey, ElementStateBox) = .empty,
    accessed_element_states: std.ArrayList(StateKey) = .empty,
    mouse_listeners: std.ArrayList(?MouseListener) = .empty,
    dispatch_tree: DispatchTree,
    scene: scene_mod.Scene = .{},
    hitboxes: std.ArrayList(Hitbox) = .empty,
    deferred_draws: std.ArrayList(DeferredDraw) = .empty,
    input_handlers: std.ArrayList(?InputHandlerRequest) = .empty,
    tooltip_requests: std.ArrayList(?TooltipRequest) = .empty,
    cursor_styles: std.ArrayList(CursorStyleRequest) = .empty,
    tab_stops: TabStopMap = .{},
    /// Native child views to place when this frame is presented.
    native_views: std.ArrayList(NativeViewPaint) = .empty,
    /// Scene ranges drawn on the overlay plane above native views (may overlap; merged at present).
    overlay_ranges: std.ArrayList(platform.OverlayRange) = .empty,
    /// The overlay holds interactive content (menus, drags): it takes the mouse.
    overlay_capture_input: bool = false,
    /// [liquid-glass] `Window.paintBackdropHole` of this frame (last one wins).
    backdrop_hole: ?platform.BackdropHole = null,
    /// Accessibility tree, built while accessibility is active (`Window.a11yActive`).
    a11y: a11y.Tree,
    a11y_listeners: std.ArrayList(A11yListener) = .empty,

    fn init(gpa: Allocator, keymap: *const @import("../app/keymap.zig").Keymap) Frame {
        return .{ .gpa = gpa, .dispatch_tree = .init(gpa, keymap), .a11y = .init(gpa) };
    }

    fn deinit(self: *Frame, app: *App) void {
        self.clear(app);
        self.element_states.deinit(self.gpa);
        self.accessed_element_states.deinit(self.gpa);
        self.mouse_listeners.deinit(self.gpa);
        self.dispatch_tree.deinit();
        self.scene.deinit(self.gpa);
        self.hitboxes.deinit(self.gpa);
        self.deferred_draws.deinit(self.gpa);
        self.input_handlers.deinit(self.gpa);
        self.tooltip_requests.deinit(self.gpa);
        self.cursor_styles.deinit(self.gpa);
        self.tab_stops.deinit(self.gpa);
        self.native_views.deinit(self.gpa);
        self.overlay_ranges.deinit(self.gpa);
        self.a11y.deinit();
        self.a11y_listeners.deinit(self.gpa);
    }

    /// Reset for reuse. Element states still here were not carried into the newer frame,
    /// so they are destroyed.
    fn clear(self: *Frame, app: *App) void {
        var it = self.element_states.valueIterator();
        while (it.next()) |b| b.destroy(b.ptr, app);
        self.element_states.clearRetainingCapacity();
        self.accessed_element_states.clearRetainingCapacity();
        self.mouse_listeners.clearRetainingCapacity();
        self.dispatch_tree.clear();
        self.scene.clear(self.gpa);
        self.hitboxes.clearRetainingCapacity();
        self.deferred_draws.clearRetainingCapacity();
        self.input_handlers.clearRetainingCapacity();
        self.tooltip_requests.clearRetainingCapacity();
        self.cursor_styles.clearRetainingCapacity();
        self.tab_stops.clear();
        self.native_views.clearRetainingCapacity();
        self.overlay_ranges.clearRetainingCapacity();
        self.overlay_capture_input = false;
        self.a11y.clear();
        self.a11y_listeners.clearRetainingCapacity();
        self.backdrop_hole = null; // [liquid-glass]
        self.focus = null;
        self.window_active = false;
    }

    /// Hitboxes under `position`, front to back (gpui `Frame::hit_test`).
    pub fn hitTest(self: *const Frame, position: Point, out: *HitTest) void {
        out.ids.clearRetainingCapacity();
        out.hover_hitbox_count = 0;
        var set_hover = false;
        var i = self.hitboxes.items.len;
        while (i > 0) {
            i -= 1;
            const h = self.hitboxes.items[i];
            if (!h.contains(position)) continue;
            if (!set_hover and h.behavior == .block_mouse_except_scroll) {
                out.hover_hitbox_count = out.ids.items.len + 1;
                set_hover = true;
            }
            out.ids.append(self.gpa, h.id) catch @panic("OOM");
            if (h.behavior == .block_mouse) break;
        }
        if (!set_hover) out.hover_hitbox_count = out.ids.items.len;
    }

    /// Focus ids from the root to the focused element.
    pub fn focusPath(self: *const Frame, gpa: Allocator) std.ArrayList(FocusId) {
        const f = self.focus orelse return .empty;
        return self.dispatch_tree.focusPath(gpa, f) catch @panic("OOM");
    }

    /// The cursor requested by the topmost hovered hitbox (window-wide requests win).
    fn cursorStyle(self: *const Frame, window: *const Window) ?CursorStyle {
        var i = self.cursor_styles.items.len;
        while (i > 0) {
            i -= 1;
            const r = self.cursor_styles.items[i];
            if (r.hitbox_id) |h| {
                if (h.isHovered(window)) return r.style;
            } else return r.style;
        }
        return null;
    }
};

pub const DrawPhase = enum { none, prepaint, paint, focus };

pub const FocusListenerKind = enum { focus, blur, focus_in, focus_out };

/// Stored in the App (so subscriptions stay valid after the window closes).
pub const FocusListener = struct {
    kind: FocusListenerKind,
    window: WindowId,
    focus_id: FocusId,
    entity: EntityId,
    func: *const fn (entity: EntityId, window: *Window, app: *App) bool,
};

fn WindowListener(comptime Ret: type) type {
    return struct {
        func: *const fn (cap: *const Captures, window: *Window, app: *App) Ret,
        cap: Captures,
    };
}

const FrameCallback = struct {
    func: *const fn (cap: *const Captures, window: *Window, app: *App) void,
    cap: Captures,
};

/// Text style used when no element overrides it (gpui's default `TextStyle`).
pub var default_text_style: TextStyle = .{};

// ---------------------------------------------------------------------------------------
// Window
// ---------------------------------------------------------------------------------------

pub const Window = struct {
    app: *App,
    gpa: Allocator,
    id: WindowId,
    platform_window: platform.Window,
    sprite_atlas: *atlas_mod.Atlas,
    text_system: text_mod.WindowTextSystem,
    layout_engine: layout.LayoutEngine,
    element_arena: ElementArena,
    root: ?AnyView = null,

    rem_size: Pixels = 16,
    rem_size_stack: std.ArrayList(Pixels) = .empty,
    viewport_size: Size,
    scale_factor: f32,
    appearance: platform.WindowAppearance,
    background_appearance: platform.WindowBackgroundAppearance = .opaque_,
    prefers_reduced_motion: bool = false,

    element_id_stack: std.ArrayList(u64) = .empty,
    text_style_stack: std.ArrayList(TextStyleRefinement) = .empty,
    rendered_entity_stack: std.ArrayList(EntityId) = .empty,
    element_offset_stack: std.ArrayList(Point) = .empty,
    content_mask_stack: std.ArrayList(ContentMask) = .empty,
    element_opacity: f32 = 1,
    edge_fade: ?EdgeFade = null,

    rendered_frame: Frame,
    next_frame: Frame,
    next_hitbox_id: u64 = 1,
    next_tooltip_id: u64 = 1,
    tooltip_bounds: ?struct { id: u64, bounds: Bounds } = null,

    dirty: bool = true,
    dirty_views: std.AutoHashMapUnmanaged(EntityId, void) = .empty,
    /// Views notified while drawing; they count as dirty in the next frame.
    pending_dirty_views: std.AutoHashMapUnmanaged(EntityId, void) = .empty,
    refreshing: bool = false,
    /// Inside `onRequestFrame` (draw + present). The platform can ask for a frame from
    /// inside one (macOS `displayLayer:` during the Core Animation flush in present, or
    /// AppKit redisplaying while a view's render changes the window background): that
    /// nested request is dropped and a redraw is scheduled instead.
    in_frame: bool = false,
    phase: DrawPhase = .none,
    needs_present: bool = false,
    /// `pushOverlayPlane` nesting and where the open overlay range starts.
    overlay_depth: u32 = 0,
    overlay_open_start: usize = 0,
    /// [liquid-glass] `pushTopPlane` nesting / open top range start.
    top_depth: u32 = 0,
    /// Light/dark material for Liquid Glass views (the app theme); null = system.
    glass_dark: ?bool = null,
    top_open_start: usize = 0,
    /// [liquid-glass] Native glass views of this window (liquid_glass.zig).
    liquid_glass: liquid_glass_mod.Pool = .{},
    /// Native form controls of this window (native_controls.zig).
    native_controls: native_controls_mod.Pool = .{},
    /// [liquid-glass] The backdrop hole last handed to the platform window.
    applied_backdrop_hole: ?platform.BackdropHole = null,
    /// Native views placed by the last present (hidden when a frame omits them).
    presented_native_views: std.ArrayList(platform.NativeViewId) = .empty,
    /// Merged overlay ranges handed to `drawLayered` (reused buffer).
    present_overlay: std.ArrayList(platform.OverlayRange) = .empty,
    removed: bool = false,
    /// The platform window is gone (closed by the OS); never touch it again.
    platform_closed: bool = false,
    destroy_scheduled: bool = false,
    /// Bumped by every invalidation (gpui `update_count`).
    update_count: u64 = 0,
    frame_count: u64 = 0,

    focused_id: ?FocusId = null,
    focus_generation: u64 = 0,
    pending_input: dispatch_tree.PendingInput = .{},
    pending_modifier: struct { modifiers: input.Modifiers = .{}, saw_keystroke: bool = false } = .{},

    mouse_position: Point = .zero,
    modifiers: input.Modifiers = .{},
    capslock: bool = false,
    mouse_hit_test: HitTest = .{},
    captured_hitbox: ?HitboxId = null,
    last_input_was_keyboard: bool = false,
    default_prevented: bool = false,

    active: bool = true,
    hovered: bool = false,

    /// Entities read or updated during the last draw; notifying one invalidates the window.
    accessed_entities: std.AutoHashMapUnmanaged(EntityId, void) = .empty,
    next_frame_callbacks: std.ArrayList(FrameCallback) = .empty,
    /// Group name (owned copy) → stack of hitboxes, valid during paint (gpui `GroupHitboxes`).
    group_hitboxes: std.StringHashMapUnmanaged(std.ArrayList(HitboxId)) = .empty,
    /// Parsed key contexts by source string. Dispatch trees outlive the frame arena (key
    /// dispatch runs between frames, cached views move nodes forward), so contexts are
    /// interned for the window's lifetime.
    key_contexts: std.StringHashMapUnmanaged(KeyContext) = .empty,
    intern_arena: std.heap.ArenaAllocator,
    /// The element input handler currently given to the platform (IME bridge).
    input_handler: ?InputHandlerRequest = null,
    /// Pending autoscroll request from an element (gpui `requested_autoscroll`), consumed by
    /// scroll containers such as `list` during prepaint.
    requested_autoscroll: ?Bounds = null,
    /// `onShouldClose` vetoes and `observeBounds` observers (window lifecycle).
    should_close_listeners: std.ArrayList(WindowListener(bool)) = .empty,
    bounds_observers: std.ArrayList(WindowListener(void)) = .empty,
    /// Accessibility: build the tree each frame (assistive technology is listening, or a
    /// test turned it on). Changes from the previous tree, and the window title (owned).
    a11y_active: bool = false,
    a11y_changes: a11y.Changes = .{},
    a11y_title: ?[]u8 = null,

    // ---- lifecycle ------------------------------------------------------------------

    /// Create a window around an already opened platform window. Use `App.openWindow`.
    pub fn create(app: *App, id: WindowId, pw: platform.Window) Allocator.Error!*Window {
        const gpa = app.gpa;
        const self = try gpa.create(Window);
        self.* = .{
            .app = app,
            .gpa = gpa,
            .id = id,
            .platform_window = pw,
            .sprite_atlas = pw.spriteAtlas(),
            .text_system = .init(app.textSystem()),
            .layout_engine = .init(gpa),
            .element_arena = .init(gpa),
            .viewport_size = pw.contentSize(),
            .scale_factor = pw.scaleFactor(),
            .appearance = pw.appearance(),
            .rendered_frame = .init(gpa, &app.keymap),
            .next_frame = .init(gpa, &app.keymap),
            .intern_arena = .init(gpa),
            .prefers_reduced_motion = app.platform.vtable.prefersReducedMotion(app.platform.ptr),
        };
        self.mouse_position = pw.mousePosition();
        self.active = pw.vtable.isActive(pw.ptr);
        pw.setCallbacks(.{
            .ctx = self,
            .request_frame = cbRequestFrame,
            .input = cbInput,
            .active_status_change = cbActive,
            .hover_status_change = cbHover,
            .resize = cbResize,
            .moved = cbMoved,
            .should_close = cbShouldClose,
            .close = cbClose,
            .appearance_changed = cbAppearance,
            .a11y_action = cbA11yAction,
            .a11y_activation = cbA11yActivation,
            .native_control = cbNativeControl,
        });
        return self;
    }

    /// Free everything. Called by the App after the window was removed.
    pub fn destroy(self: *Window) void {
        const app = self.app;
        const gpa = self.gpa;
        if (!self.platform_closed) {
            self.platform_window.setCallbacks(.{});
            self.platform_window.setInputHandler(null);
            self.platform_window.close();
            self.platform_closed = true;
        }
        self.pending_input.deinit(gpa);
        self.should_close_listeners.deinit(gpa);
        self.bounds_observers.deinit(gpa);
        self.a11y_changes.deinit(gpa);
        if (self.a11y_title) |t| gpa.free(t);
        if (self.root) |r| r.entity.release(app);
        self.root = null;
        self.rendered_frame.deinit(app);
        self.next_frame.deinit(app);
        self.element_arena.deinit();
        self.layout_engine.deinit();
        self.text_system.deinit();
        self.rem_size_stack.deinit(gpa);
        self.element_id_stack.deinit(gpa);
        self.text_style_stack.deinit(gpa);
        self.rendered_entity_stack.deinit(gpa);
        self.element_offset_stack.deinit(gpa);
        self.content_mask_stack.deinit(gpa);
        self.presented_native_views.deinit(gpa);
        self.present_overlay.deinit(gpa);
        self.liquid_glass.deinit(gpa); // [liquid-glass] (views went with the platform window)
        self.native_controls.deinit(gpa);
        self.dirty_views.deinit(gpa);
        self.pending_dirty_views.deinit(gpa);
        self.mouse_hit_test.ids.deinit(gpa);
        self.accessed_entities.deinit(gpa);
        self.next_frame_callbacks.deinit(gpa);
        var git = self.group_hitboxes.iterator();
        while (git.next()) |kv| {
            kv.value_ptr.deinit(gpa);
            gpa.free(kv.key_ptr.*);
        }
        self.group_hitboxes.deinit(gpa);
        self.key_contexts.deinit(gpa);
        self.intern_arena.deinit();
        gpa.destroy(self);
    }

    // ---- platform callbacks -----------------------------------------------------------

    fn fromCtx(ctx: ?*anyopaque) *Window {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn cbRequestFrame(ctx: ?*anyopaque, force_render: bool) void {
        const self = fromCtx(ctx);
        if (self.removed) return;
        const app = self.app;
        app.startUpdate();
        defer app.finishUpdate();
        self.onRequestFrame(force_render);
    }

    /// gpui's `on_request_frame` body: run animation-frame callbacks, then draw if dirty
    /// (or forced) and present.
    pub fn onRequestFrame(self: *Window, force_render: bool) void {
        if (self.in_frame) {
            self.dirty = true;
            self.platform_window.requestFrame();
            return;
        }
        self.in_frame = true;
        defer self.in_frame = false;
        self.runFrameCallbacks();
        if (self.dirty or force_render) {
            self.draw();
            self.present();
        } else if (self.needs_present) {
            self.present();
        }
        if (self.next_frame_callbacks.items.len > 0) self.platform_window.requestFrame();
    }

    fn cbInput(ctx: ?*anyopaque, event: input.PlatformInput) platform.DispatchEventResult {
        const self = fromCtx(ctx);
        if (self.removed) return .{};
        return self.dispatchEvent(event);
    }

    fn cbActive(ctx: ?*anyopaque, active: bool) void {
        const self = fromCtx(ctx);
        const app = self.app;
        app.startUpdate();
        defer app.finishUpdate();
        self.active = active;
        self.refresh();
    }

    fn cbHover(ctx: ?*anyopaque, hovered: bool) void {
        const self = fromCtx(ctx);
        self.hovered = hovered;
        if (!hovered) {
            self.app.startUpdate();
            defer self.app.finishUpdate();
            self.refresh();
        }
    }

    fn cbResize(ctx: ?*anyopaque, size: Size, scale: f32) void {
        const self = fromCtx(ctx);
        const app = self.app;
        app.startUpdate();
        defer app.finishUpdate();
        self.viewport_size = size;
        self.scale_factor = scale;
        self.refresh();
        self.notifyBoundsObservers();
    }

    fn cbMoved(ctx: ?*anyopaque) void {
        const self = fromCtx(ctx);
        if (self.removed) return;
        const app = self.app;
        app.startUpdate();
        defer app.finishUpdate();
        self.notifyBoundsObservers();
    }

    fn notifyBoundsObservers(self: *Window) void {
        if (self.bounds_observers.items.len == 0) return;
        const items = self.gpa.dupe(WindowListener(void), self.bounds_observers.items) catch return;
        defer self.gpa.free(items);
        for (items) |*l| l.func(&l.cap, self, self.app);
    }

    /// The OS close button / `performClose:`: every `onShouldClose` listener must agree.
    fn cbShouldClose(ctx: ?*anyopaque) bool {
        const self = fromCtx(ctx);
        if (self.removed or self.should_close_listeners.items.len == 0) return true;
        const app = self.app;
        app.startUpdate();
        defer app.finishUpdate();
        const items = self.gpa.dupe(WindowListener(bool), self.should_close_listeners.items) catch return true;
        defer self.gpa.free(items);
        var ok = true;
        for (items) |*l| ok = l.func(&l.cap, self, app) and ok;
        return ok;
    }

    /// `f(ctx, window, app) bool` when the user asks to close the window from its frame
    /// (close button, Alt+F4, the compositor); return false to keep it open (gpui
    /// `on_window_should_close`). `removeWindow` is never vetoed.
    pub fn onShouldClose(self: *Window, ctx: anytype, comptime f: anytype) Allocator.Error!void {
        const C = @TypeOf(ctx);
        const Gen = struct {
            fn call(cap: *const Captures, w: *Window, a: *App) bool {
                return f(cap.get(C).*, w, a);
            }
        };
        try self.should_close_listeners.append(self.gpa, .{ .func = Gen.call, .cap = .init(ctx) });
    }

    /// `f(ctx, window, app)` after the window moved or resized (gpui `observe_window_bounds`).
    pub fn observeBounds(self: *Window, ctx: anytype, comptime f: anytype) Allocator.Error!void {
        const C = @TypeOf(ctx);
        const Gen = struct {
            fn call(cap: *const Captures, w: *Window, a: *App) void {
                f(cap.get(C).*, w, a);
            }
        };
        try self.bounds_observers.append(self.gpa, .{ .func = Gen.call, .cap = .init(ctx) });
    }

    /// The display the window is on (`platform.Display.id`), when the backend knows.
    pub fn displayId(self: *const Window) ?u32 {
        if (self.platform_closed) return null;
        const f = self.platform_window.vtable.displayId orelse return null;
        return f(self.platform_window.ptr);
    }

    fn cbClose(ctx: ?*anyopaque) void {
        const self = fromCtx(ctx);
        self.removed = true;
        self.platform_closed = true;
        self.app.startUpdate();
        self.app.finishUpdate();
    }

    fn cbAppearance(ctx: ?*anyopaque) void {
        const self = fromCtx(ctx);
        const app = self.app;
        app.startUpdate();
        defer app.finishUpdate();
        self.appearance = self.platform_window.appearance();
        self.refresh();
    }

    fn cbA11yAction(ctx: ?*anyopaque, request: a11y.ActionRequest) void {
        const self = fromCtx(ctx);
        if (self.removed) return;
        self.handleA11yAction(request);
    }

    fn cbNativeControl(ctx: ?*anyopaque, control: platform.NativeViewId, event: platform.NativeControlEvent) void {
        const self = fromCtx(ctx);
        if (self.removed) return;
        native_controls_mod.handleEvent(self, control, event);
    }

    fn cbA11yActivation(ctx: ?*anyopaque, active: bool) void {
        const self = fromCtx(ctx);
        if (self.removed) return;
        const app = self.app;
        app.startUpdate();
        defer app.finishUpdate();
        self.setA11yActive(active);
    }

    // ---- accessibility (src/a11y.zig) -------------------------------------------------

    /// Whether frames build the accessibility tree (zui `is_a11y_active`). Gate work that
    /// only matters to assistive technology on it.
    pub fn a11yActive(self: *const Window) bool {
        return self.a11y_active;
    }

    /// Turn tree building on or off (the platform does this when assistive technology
    /// connects; tests call it directly). Activation redraws without view caching so the
    /// first tree is complete.
    pub fn setA11yActive(self: *Window, active: bool) void {
        if (self.a11y_active == active) return;
        self.a11y_active = active;
        self.refresh();
    }

    /// The last drawn frame's accessibility tree (empty while inactive).
    pub fn a11yTree(self: *const Window) *const a11y.Tree {
        return &self.rendered_frame.a11y;
    }

    /// What changed between the last two trees.
    pub fn a11yChanges(self: *const Window) *const a11y.Changes {
        return &self.a11y_changes;
    }

    /// The tree is being built this frame (prepaint with accessibility active).
    pub fn a11yBuilding(self: *const Window) bool {
        return self.next_frame.a11y.isBuilding();
    }

    /// Push a node (from an element's prepaint); pair a `true` result with `a11yPopNode`.
    pub fn a11yPushNode(self: *Window, spec: a11y.NodeSpec) bool {
        if (!self.next_frame.a11y.isBuilding()) return false;
        return self.next_frame.a11y.push(spec);
    }

    /// Audit hook: an interactive element without a role (see `a11y.Tree.unroled`).
    pub fn a11yNoteUnroled(self: *Window, gid: u64, b: Bounds, el: []const u8, clickable: bool, focusable: bool) void {
        if (!self.next_frame.a11y.isBuilding()) return;
        self.next_frame.a11y.noteUnroled(gid, b, el, clickable, focusable);
    }

    pub fn a11yPopNode(self: *Window) void {
        self.next_frame.a11y.pop();
    }

    /// Text drawn by a text element at `b` (names the enclosing button, fills the
    /// enclosing text field's value, or becomes static text).
    pub fn a11yAppendText(self: *Window, text: []const u8, b: Bounds) void {
        if (!self.next_frame.a11y.isBuilding()) return;
        self.next_frame.a11y.appendText(text, b);
    }

    /// Register `listener` for `action` on `node` this frame (zui `on_a11y_action`).
    pub fn onA11yAction(self: *Window, node: a11y.NodeId, action: a11y.Action, listener: anytype) void {
        if (!self.next_frame.a11y.isBuilding()) return;
        const L = @import("../app/context.zig").Listener(a11y.ActionRequest);
        self.next_frame.a11y_listeners.append(self.gpa, .{ .node = node, .action = action, .listener = L.init(listener) }) catch @panic("OOM");
    }

    /// Run an assistive-technology request against the rendered frame (zui
    /// `handle_a11y_action`): matching `onA11yAction` listeners first, else the built-in
    /// behaviour — `click` is a synthesized left click at the node's center, `focus`
    /// focuses the node's focus handle, `blur` clears focus.
    pub fn handleA11yAction(self: *Window, request: a11y.ActionRequest) void {
        const app = self.app;
        app.startUpdate();
        defer app.finishUpdate();
        const tree = &self.rendered_frame.a11y;
        const node = tree.get(request.target);
        var matched = false;
        {
            const n = self.rendered_frame.a11y_listeners.items.len;
            const ls = self.gpa.dupe(A11yListener, self.rendered_frame.a11y_listeners.items[0..n]) catch return;
            defer self.gpa.free(ls);
            for (ls) |*l| {
                if (l.node != request.target or l.action != request.action) continue;
                l.listener.callIn(&request, self, app);
                matched = true;
            }
        }
        if (matched) return;
        const nd = node orelse return;
        switch (request.action) {
            .click => {
                const center: Point = .{ .x = nd.bounds.origin.x + nd.bounds.size.width / 2, .y = nd.bounds.origin.y + nd.bounds.size.height / 2 };
                _ = self.dispatchEvent(.{ .mouse_down = .{ .button = .left, .position = center, .click_count = 1 } });
                _ = self.dispatchEvent(.{ .mouse_up = .{ .button = .left, .position = center, .click_count = 1 } });
            },
            .focus => if (nd.focus_id) |f| self.focus(.{ .id = @enumFromInt(f) }),
            .blur => self.blur(),
            else => {},
        }
    }

    // ---- window-level API -------------------------------------------------------------

    /// Logical content size.
    pub fn viewportSize(self: *const Window) Size {
        return self.viewport_size;
    }

    pub fn bounds(self: *const Window) Bounds {
        return self.platform_window.bounds();
    }

    pub fn scaleFactor(self: *const Window) f32 {
        return self.scale_factor;
    }

    pub fn windowAppearance(self: *const Window) platform.WindowAppearance {
        return self.appearance;
    }

    pub fn isWindowActive(self: *const Window) bool {
        return self.active;
    }

    pub fn isWindowHovered(self: *const Window) bool {
        return self.hovered;
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        if (self.a11y_title) |t| self.gpa.free(t);
        self.a11y_title = self.gpa.dupe(u8, title) catch null;
        self.platform_window.setTitle(title);
    }

    pub fn setBackgroundAppearance(self: *Window, bg: platform.WindowBackgroundAppearance) void {
        self.background_appearance = bg;
        self.platform_window.vtable.setBackgroundAppearance(self.platform_window.ptr, bg);
        self.refresh();
    }

    pub fn activateWindow(self: *Window) void {
        self.platform_window.vtable.activate(self.platform_window.ptr);
    }

    pub fn minimizeWindow(self: *Window) void {
        self.platform_window.vtable.minimize(self.platform_window.ptr);
    }

    pub fn zoomWindow(self: *Window) void {
        self.platform_window.vtable.zoom(self.platform_window.ptr);
    }

    pub fn toggleFullscreen(self: *Window) void {
        self.platform_window.vtable.toggleFullscreen(self.platform_window.ptr);
    }

    pub fn startWindowMove(self: *Window) void {
        self.platform_window.vtable.startWindowMove(self.platform_window.ptr);
    }

    /// Client-side decorations: begin an interactive resize from `edge`.
    pub fn startWindowResize(self: *Window, edge: platform.ResizeEdge) void {
        self.platform_window.vtable.startWindowResize(self.platform_window.ptr, edge);
    }

    /// Client-side decorations: the inset kept hit-testable as window frame.
    pub fn setClientInset(self: *Window, inset: Pixels) void {
        self.platform_window.vtable.setClientInset(self.platform_window.ptr, inset);
    }

    pub fn isFullscreen(self: *const Window) bool {
        return self.platform_window.vtable.isFullscreen(self.platform_window.ptr);
    }

    pub fn isMaximized(self: *const Window) bool {
        return self.platform_window.vtable.isMaximized(self.platform_window.ptr);
    }

    /// Resize the window's content area.
    pub fn resize(self: *Window, size: Size) void {
        self.platform_window.vtable.resize(self.platform_window.ptr, size);
    }

    /// Position the IME candidate window near `bounds` (window coordinates).
    pub fn updateImePosition(self: *Window, b: Bounds) void {
        self.platform_window.vtable.updateImePosition(self.platform_window.ptr, b);
    }

    /// Close the window (gpui `remove_window`). It stops receiving events now and is
    /// destroyed (closing the platform window) from a main-thread task after this update.
    pub fn removeWindow(self: *Window) void {
        if (self.removed) return;
        self.removed = true;
        if (!self.platform_closed) self.platform_window.setCallbacks(.{});
    }

    /// Whether the OS asked for reduced motion; animations should jump to their end.
    pub fn prefersReducedMotion(self: *const Window) bool {
        return self.prefers_reduced_motion;
    }

    pub fn mousePosition(self: *const Window) Point {
        return self.mouse_position;
    }

    pub fn currentModifiers(self: *const Window) input.Modifiers {
        return self.modifiers;
    }

    pub fn lastInputWasKeyboard(self: *const Window) bool {
        return self.last_input_was_keyboard;
    }

    /// Schedule a full redraw (gpui `refresh`): no view caches are reused.
    pub fn refresh(self: *Window) void {
        if (self.phase != .none) return;
        self.refreshing = true;
        self.markDirty();
    }

    fn markDirty(self: *Window) void {
        self.update_count += 1;
        if (!self.dirty) {
            self.dirty = true;
            self.platform_window.requestFrame();
        }
    }

    /// Mark `entity` (usually a view) dirty; called by `App.notify` for entities this
    /// window rendered (gpui `WindowInvalidator::invalidate_view`). Returns false mid-draw.
    pub fn invalidateView(self: *Window, entity: EntityId) bool {
        self.update_count += 1;
        if (self.phase != .none) {
            self.pending_dirty_views.put(self.gpa, entity, {}) catch @panic("OOM");
            return false;
        }
        self.dirty_views.put(self.gpa, entity, {}) catch @panic("OOM");
        self.markDirty();
        return true;
    }

    pub fn isDirty(self: *const Window) bool {
        return self.dirty;
    }

    /// The entity whose render is executing, else the root view (gpui `current_view`).
    pub fn currentView(self: *const Window) EntityId {
        if (self.rendered_entity_stack.items.len > 0) return self.rendered_entity_stack.items[self.rendered_entity_stack.items.len - 1];
        return self.root.?.entity.id;
    }

    pub fn pushRenderedView(self: *Window, id: EntityId) void {
        self.rendered_entity_stack.append(self.gpa, id) catch @panic("OOM");
    }

    pub fn popRenderedView(self: *Window) void {
        _ = self.rendered_entity_stack.pop();
    }

    /// Run `f(ctx, window, app)` before the next frame is drawn (gpui `on_next_frame`).
    /// `ctx` is copied inline (<= 160 bytes).
    pub fn onNextFrame(self: *Window, ctx: anytype, comptime f: fn (*const @TypeOf(ctx), *Window, *App) void) void {
        const C = @TypeOf(ctx);
        const Gen = struct {
            fn call(cap: *const Captures, w: *Window, a: *App) void {
                f(cap.get(C), w, a);
            }
        };
        self.next_frame_callbacks.append(self.gpa, .{ .func = Gen.call, .cap = .init(ctx) }) catch @panic("OOM");
        self.platform_window.requestFrame();
    }

    /// Redraw the current view on the next frame (gpui `request_animation_frame`).
    pub fn requestAnimationFrame(self: *Window) void {
        const view_id = self.currentView();
        self.onNextFrame(view_id, struct {
            fn f(id: *const EntityId, _: *Window, a: *App) void {
                a.notify(id.*);
            }
        }.f);
    }

    fn runFrameCallbacks(self: *Window) void {
        if (self.next_frame_callbacks.items.len == 0) return;
        var cbs = self.next_frame_callbacks;
        self.next_frame_callbacks = .empty;
        defer cbs.deinit(self.gpa);
        for (cbs.items) |*c| c.func(&c.cap, self, self.app);
    }

    // ---- focus --------------------------------------------------------------------------

    /// Move keyboard focus to `handle` (gpui `window.focus`).
    pub fn focus(self: *Window, handle: FocusHandle) void {
        if (self.focused_id == handle.id) return;
        self.focused_id = handle.id;
        self.focus_generation += 1;
        self.pending_input.clear(self.gpa);
        self.refresh();
    }

    pub fn blur(self: *Window) void {
        if (self.focused_id == null) return;
        self.focused_id = null;
        self.focus_generation += 1;
        self.refresh();
    }

    pub fn focusedId(self: *const Window) ?FocusId {
        return self.focused_id;
    }

    /// Focus the next tab stop of the rendered frame (gpui `focus_next`).
    pub fn focusNext(self: *Window) void {
        if (self.rendered_frame.tab_stops.next(self.focused_id)) |id| self.focus(.{ .id = id });
    }

    pub fn focusPrev(self: *Window) void {
        if (self.rendered_frame.tab_stops.prev(self.focused_id)) |id| self.focus(.{ .id = id });
    }

    pub fn addFocusListener(self: *Window, kind: FocusListenerKind, focus_id: FocusId, entity: EntityId, func: *const fn (EntityId, *Window, *App) bool) Allocator.Error!Subscription {
        const key = @intFromEnum(focus_id);
        const set = &self.app.focus_listeners;
        const ins = try set.insert(key, .{ .kind = kind, .window = self.id, .focus_id = focus_id, .entity = entity, .func = func });
        set.activate(key, ins.id);
        return ins.subscription;
    }

    fn fireFocusEvents(self: *Window, prev: []const FocusId, cur: []const FocusId) void {
        const Ctx = struct { w: *Window, prev: []const FocusId, cur: []const FocusId };
        var ctx: Ctx = .{ .w = self, .prev = prev, .cur = cur };
        const visit = struct {
            fn contains(list: []const FocusId, id: FocusId) bool {
                return std.mem.indexOfScalar(FocusId, list, id) != null;
            }
            fn last(list: []const FocusId) ?FocusId {
                return if (list.len == 0) null else list[list.len - 1];
            }
            fn call(c: *Ctx, l: *FocusListener) bool {
                if (l.window != c.w.id) return true;
                const id = l.focus_id;
                const fire = switch (l.kind) {
                    .focus => last(c.cur) == id and last(c.prev) != id,
                    .blur => last(c.prev) == id and last(c.cur) != id,
                    .focus_in => contains(c.cur, id) and !contains(c.prev, id),
                    .focus_out => contains(c.prev, id) and !contains(c.cur, id),
                };
                if (!fire) return true;
                return l.func(l.entity, c.w, c.w.app);
            }
        };
        var seen: std.ArrayList(FocusId) = .empty;
        defer seen.deinit(self.gpa);
        for ([_][]const FocusId{ prev, cur }) |list| for (list) |id| {
            if (std.mem.indexOfScalar(FocusId, seen.items, id) != null) continue;
            seen.append(self.gpa, id) catch @panic("OOM");
            self.app.focus_listeners.retain(@intFromEnum(id), &ctx, visit.call);
        };
    }

    // ---- frame lifecycle ----------------------------------------------------------------

    /// Render and lay out the root view and build the next frame (gpui `Window::draw`).
    /// Call `present` afterwards (or `drawAndPresent`).
    pub fn draw(self: *Window) void {
        const app = self.app;
        const gpa = self.gpa;
        const prev_arena = arena_mod.enter(&self.element_arena);
        defer arena_mod.exit(prev_arena);
        self.liquid_glass.frame_keys.clearRetainingCapacity(); // [liquid-glass]
        self.native_controls.frame_keys.clearRetainingCapacity();

        // Dirty views → mark their ancestor views dirty too.
        {
            var pit = self.pending_dirty_views.keyIterator();
            while (pit.next()) |k| self.dirty_views.put(gpa, k.*, {}) catch @panic("OOM");
            self.pending_dirty_views.clearRetainingCapacity();
            var views: std.ArrayList(EntityId) = .empty;
            defer views.deinit(gpa);
            var it = self.dirty_views.keyIterator();
            while (it.next()) |k| views.append(gpa, k.*) catch @panic("OOM");
            for (views.items) |v| self.markViewDirty(v);
        }
        app.entities.accessed.clearRetainingCapacity();
        const prev_tracking = app.entities.track_accessed;
        app.entities.track_accessed = true;
        self.dirty = false;

        if (self.root != null) self.drawRoots();
        const a11y_built = self.next_frame.a11y.built;
        if (a11y_built) {
            self.next_frame.a11y.finalize(if (self.focused_id) |f| @intFromEnum(f) else null);
            a11y.diff(gpa, &self.rendered_frame.a11y, &self.next_frame.a11y, &self.a11y_changes);
        }

        self.dirty_views.clearRetainingCapacity();
        self.next_frame.window_active = self.active;
        self.next_frame.focus = self.focused_id;

        // Hand the last requested input handler to the platform.
        self.input_handler = null;
        {
            var i = self.next_frame.input_handlers.items.len;
            while (i > 0) {
                i -= 1;
                if (self.next_frame.input_handlers.items[i]) |h| {
                    self.input_handler = h;
                    break;
                }
            }
        }
        self.platform_window.setInputHandler(if (self.input_handler != null) input_handler.platformHandler(self) else null);

        self.layout_engine.clear();
        self.text_system.finishFrame();
        self.next_frame.scene.finish();

        self.phase = .focus;
        var prev_path = self.rendered_frame.focusPath(gpa);
        defer prev_path.deinit(gpa);
        const prev_active = self.rendered_frame.window_active;
        std.mem.swap(Frame, &self.rendered_frame, &self.next_frame);
        self.next_frame.clear(app);
        if (a11y_built and !self.platform_closed) self.platform_window.a11yUpdate(.{ .tree = &self.rendered_frame.a11y, .changes = &self.a11y_changes });
        var cur_path = self.rendered_frame.focusPath(gpa);
        defer cur_path.deinit(gpa);
        const cur_active = self.rendered_frame.window_active;
        const focus_before = self.focused_id;
        self.phase = .none;
        if (!std.mem.eql(FocusId, prev_path.items, cur_path.items) or prev_active != cur_active) {
            self.fireFocusEvents(if (prev_active) prev_path.items else &.{}, if (cur_active) cur_path.items else &.{});
        }

        // Record entities read during this draw (gpui `record_entities_accessed`).
        std.mem.swap(std.AutoHashMapUnmanaged(EntityId, void), &self.accessed_entities, &app.entities.accessed);
        app.entities.accessed.clearRetainingCapacity();
        app.entities.track_accessed = prev_tracking;

        self.resetCursorStyle();
        self.refreshing = false;
        self.frame_count += 1;
        if (self.focused_id != focus_before) self.refresh();
        self.needs_present = true;
    }

    fn markViewDirty(self: *Window, view_id: EntityId) void {
        var path = self.rendered_frame.dispatch_tree.viewPathReversed(self.gpa, view_id) catch @panic("OOM");
        defer path.deinit(self.gpa);
        for (path.items) |v| {
            const gop = self.dirty_views.getOrPut(self.gpa, v) catch @panic("OOM");
            if (gop.found_existing and v != view_id) break;
        }
    }

    fn drawRoots(self: *Window) void {
        const app = self.app;
        self.phase = .prepaint;
        if (self.a11y_active) self.next_frame.a11y.begin(self.a11y_title, .{ .origin = .zero, .size = self.viewport_size });
        self.tooltip_bounds = null;
        const root_size = self.viewport_size;

        var root = self.root.?.intoAnyElement();
        const root_layout = root.requestLayout(self, app);
        const s = self.scale_factor;
        self.layout_engine.stretchAutoSizeToFill(root_layout, .{
            .width = style_mod.roundHalfTowardZero(root_size.width * s),
            .height = style_mod.roundHalfTowardZero(root_size.height * s),
        });
        root.prepaintAsRoot(.zero, element.avail.definite(root_size), self, app);

        self.prepaintDeferredDraws();

        var drag_element: ?AnyElement = null;
        var tooltip_element: ?AnyElement = null;
        if (app.active_drag) |drag| {
            const el = drag.view.intoAnyElement();
            const offset = self.mouse_position.sub(drag.cursor_offset);
            el.prepaintAsRoot(offset, element.avail.min_content, self, app);
            drag_element = el;
        } else {
            tooltip_element = self.prepaintTooltip();
        }

        self.next_frame.hitTest(self.mouse_position, &self.mouse_hit_test);

        self.phase = .paint;
        root.paint(self, app);
        // Root paint is beneath native views; deferred menus, drags and tooltips use the
        // overlay plane (zui `overlay_scene_start`). Passive tooltips do not take input.
        self.next_frame.overlay_capture_input = self.next_frame.deferred_draws.items.len > 0 or drag_element != null;
        self.pushOverlayPlane();
        self.liquid_glass.floating_depth += 1; // [liquid-glass] glass here floats
        self.paintDeferredDraws();
        if (drag_element) |el| el.paint(self, app) else if (tooltip_element) |el| el.paint(self, app);
        self.liquid_glass.floating_depth -= 1;
        self.popOverlayPlane();
        self.phase = .none;
    }

    fn prepaintTooltip(self: *Window) ?AnyElement {
        const app = self.app;
        var i = self.next_frame.tooltip_requests.items.len;
        while (i > 0) {
            i -= 1;
            const req = self.next_frame.tooltip_requests.items[i] orelse continue;
            const el = req.view.intoAnyElement();
            const size = el.layoutAsRoot(element.avail.min_content, self, app);
            var b: Bounds = .{ .origin = req.mouse_position.add(.{ .x = 1, .y = 1 }), .size = size };
            const wb: Bounds = .{ .origin = .zero, .size = self.viewport_size };
            if (b.right() > wb.right()) {
                const nx = req.mouse_position.x - b.size.width - 1;
                b.origin.x = if (nx >= 0) nx else @max(0, b.origin.x - b.right() - wb.right());
            }
            if (b.bottom() > wb.bottom()) {
                const ny = req.mouse_position.y - b.size.height - 1;
                b.origin.y = if (ny >= 0) ny else @max(0, b.origin.y - b.bottom() - wb.bottom());
            }
            if (req.check_visible) |check| if (!check(req.owner.?, b, self)) continue;
            el.prepaintAt(b.origin, self, app);
            self.tooltip_bounds = .{ .id = req.id, .bounds = b };
            return el;
        }
        return null;
    }

    fn prepaintDeferredDraws(self: *Window) void {
        const app = self.app;
        std.debug.assert(self.element_id_stack.items.len == 0);
        var round_start: usize = 0;
        var depth: usize = 0;
        while (true) {
            const round_end = self.next_frame.deferred_draws.items.len;
            if (round_start == round_end) break;
            depth += 1;
            if (depth > 10) @panic("exceeded maximum (10) deferred draw depth");
            const order = self.deferredOrder(round_start, round_end);
            for (order) |ix| {
                const d = self.next_frame.deferred_draws.items[ix];
                self.restoreDeferredStacks(d);
                self.next_frame.dispatch_tree.setActiveNode(d.parent_node) catch @panic("OOM");
                const start = self.prepaintIndex();
                if (d.element) |el| {
                    self.pushRenderedView(d.current_view);
                    self.pushRemSize(d.rem_size);
                    self.pushAbsoluteElementOffset(d.absolute_offset);
                    el.prepaint(self, app);
                    self.popElementOffset();
                    self.popRemSize();
                    self.popRenderedView();
                } else {
                    self.reusePrepaint(d.prepaint_range);
                }
                self.next_frame.deferred_draws.items[ix].prepaint_range = .{ start, self.prepaintIndex() };
            }
            self.element_id_stack.clearRetainingCapacity();
            self.text_style_stack.clearRetainingCapacity();
            round_start = round_end;
        }
    }

    fn restoreDeferredStacks(self: *Window, d: DeferredDraw) void {
        self.element_id_stack.clearRetainingCapacity();
        if (d.element_id) |e| self.element_id_stack.append(self.gpa, e) catch @panic("OOM");
        self.text_style_stack.clearRetainingCapacity();
        self.text_style_stack.appendSlice(self.gpa, d.text_style_stack) catch @panic("OOM");
    }

    fn deferredOrder(self: *Window, start: usize, end: usize) []usize {
        const order = arena_mod.frameAllocator().alloc(usize, end - start) catch @panic("OOM");
        for (order, start..) |*o, i| o.* = i;
        const draws = self.next_frame.deferred_draws.items;
        std.mem.sort(usize, order, draws, struct {
            fn lt(d: []const DeferredDraw, a: usize, b: usize) bool {
                return d[a].priority < d[b].priority;
            }
        }.lt);
        return order;
    }

    fn paintDeferredDraws(self: *Window) void {
        const app = self.app;
        const n = self.next_frame.deferred_draws.items.len;
        if (n == 0) return;
        const order = self.deferredOrder(0, n);
        for (order) |ix| {
            const d = self.next_frame.deferred_draws.items[ix];
            self.restoreDeferredStacks(d);
            self.next_frame.dispatch_tree.setActiveNode(d.parent_node) catch @panic("OOM");
            const start = self.paintIndex();
            if (d.element) |el| {
                self.pushRenderedView(d.current_view);
                self.pushContentMask(d.content_mask);
                self.pushRemSize(d.rem_size);
                el.paint(self, app);
                self.popRemSize();
                self.popContentMask(d.content_mask);
                self.popRenderedView();
            } else {
                self.reusePaint(d.paint_range);
            }
            self.next_frame.deferred_draws.items[ix].paint_range = .{ start, self.paintIndex() };
        }
        self.element_id_stack.clearRetainingCapacity();
        self.text_style_stack.clearRetainingCapacity();
    }

    /// Submit the rendered frame's scene to the platform window, then release this frame's
    /// elements (gpui `present` + `ArenaClearNeeded::clear`).
    pub fn present(self: *Window) void {
        self.applyNativeViews();
        liquid_glass_mod.sweep(self); // [liquid-glass]
        native_controls_mod.sweep(self);
        self.applyBackdropHole(); // [liquid-glass]
        const drawn = if (self.platform_window.vtable.drawLayered) |draw_layered| blk: {
            // Planes only matter above native views: without one placed this frame,
            // everything (menus, popovers, tooltips, drags) stays on the main surface,
            // where backdrop blurs see the content beneath them.
            const layered = self.hasPlacedNativeViews();
            if (layered) self.mergeOverlayRanges() else self.present_overlay.clearRetainingCapacity();
            const capture = layered and self.rendered_frame.overlay_capture_input;
            break :blk draw_layered(self.platform_window.ptr, &self.rendered_frame.scene, self.present_overlay.items, capture);
        } else self.platform_window.draw(&self.rendered_frame.scene);
        drawn catch |err| {
            std.log.err("window present failed: {t}", .{err});
        };
        self.needs_present = false;
        self.element_arena.clear();
    }

    /// `draw` + `present` (used by tests and on demand).
    pub fn drawAndPresent(self: *Window) void {
        if (self.in_frame) {
            self.dirty = true;
            self.platform_window.requestFrame();
            return;
        }
        self.in_frame = true;
        defer self.in_frame = false;
        self.draw();
        self.present();
    }

    fn resetCursorStyle(self: *Window) void {
        if (!self.hovered and !self.active) return;
        const style = self.rendered_frame.cursorStyle(self) orelse .arrow;
        self.app.platform.setCursorStyle(style);
    }

    // ---- element ids and state ----------------------------------------------------------

    /// Push `id` onto the element id stack; returns the new global id.
    pub fn pushElementId(self: *Window, id: ElementId) GlobalElementId {
        const parent: u64 = if (self.element_id_stack.items.len > 0) self.element_id_stack.items[self.element_id_stack.items.len - 1] else 0x9e3779b97f4a7c15;
        const h = id.hashWith(parent);
        self.element_id_stack.append(self.gpa, h) catch @panic("OOM");
        return @enumFromInt(h);
    }

    pub fn popElementId(self: *Window) void {
        _ = self.element_id_stack.pop();
    }

    /// The global id of the innermost element with an id, if any.
    pub fn currentGlobalId(self: *const Window) ?GlobalElementId {
        if (self.element_id_stack.items.len == 0) return null;
        return @enumFromInt(self.element_id_stack.items[self.element_id_stack.items.len - 1]);
    }

    /// The state `S` stored for element `gid`, created as `S{}` on first use. It persists
    /// across frames for as long as an element with this id is drawn every frame (gpui
    /// `with_element_state`). The pointer is stable until the element disappears.
    /// `S` may declare `deinit(self)`, `deinit(self, *App)` or `deinit(self, Allocator)`.
    pub fn elementState(self: *Window, comptime S: type, gid: GlobalElementId) *S {
        return self.elementStateInit(S, gid, .{});
    }

    /// Like `elementState` with an explicit initial value.
    pub fn elementStateInit(self: *Window, comptime S: type, gid: GlobalElementId, initial: S) *S {
        std.debug.assert(self.phase == .prepaint or self.phase == .paint);
        const key: StateKey = .{ .gid = gid.toKey(), .tid = type_id.key(type_id.typeId(S)) };
        if (self.next_frame.element_states.get(key)) |b| return @ptrCast(@alignCast(b.ptr));
        self.next_frame.accessed_element_states.append(self.gpa, key) catch @panic("OOM");
        if (self.rendered_frame.element_states.fetchRemove(key)) |kv| {
            self.next_frame.element_states.put(self.gpa, key, kv.value) catch @panic("OOM");
            return @ptrCast(@alignCast(kv.value.ptr));
        }
        const p = self.gpa.create(S) catch @panic("OOM");
        p.* = initial;
        self.next_frame.element_states.put(self.gpa, key, .{ .ptr = p, .destroy = stateDestroyer(S) }) catch @panic("OOM");
        return p;
    }

    /// `elementState` when the element has an id, else null.
    pub fn optionalElementState(self: *Window, comptime S: type, gid: ?GlobalElementId) ?*S {
        return if (gid) |g| self.elementState(S, g) else null;
    }

    // ---- stacks ---------------------------------------------------------------------------

    pub fn pushTextStyle(self: *Window, refinement: ?TextStyleRefinement) void {
        if (refinement) |r| self.text_style_stack.append(self.gpa, r) catch @panic("OOM");
    }

    /// Pass the same optional value given to `pushTextStyle`.
    pub fn popTextStyle(self: *Window, refinement: ?TextStyleRefinement) void {
        if (refinement != null) _ = self.text_style_stack.pop();
    }

    /// The text style in effect (gpui `text_style`): defaults refined by the stack.
    pub fn textStyle(self: *const Window) TextStyle {
        var s = default_text_style;
        for (self.text_style_stack.items) |r| refine.refine(&s, r);
        return s;
    }

    /// Line height of the current text style in pixels.
    pub fn lineHeight(self: *const Window) Pixels {
        return self.textStyle().lineHeightInPixels(self.remSize());
    }

    pub fn remSize(self: *const Window) Pixels {
        if (self.rem_size_stack.items.len > 0) return self.rem_size_stack.items[self.rem_size_stack.items.len - 1];
        return self.rem_size;
    }

    pub fn setRemSize(self: *Window, size: Pixels) void {
        self.rem_size = size;
    }

    pub fn pushRemSize(self: *Window, size: Pixels) void {
        self.rem_size_stack.append(self.gpa, size) catch @panic("OOM");
    }

    pub fn popRemSize(self: *Window) void {
        _ = self.rem_size_stack.pop();
    }

    /// Current content mask (logical px); the viewport when nothing clips.
    pub fn contentMask(self: *const Window) ContentMask {
        if (self.content_mask_stack.items.len > 0) return self.content_mask_stack.items[self.content_mask_stack.items.len - 1];
        return .{ .bounds = .{ .origin = .zero, .size = self.viewport_size } };
    }

    /// Clip to `mask` ∩ current mask (no-op for null). Pop with the same argument.
    pub fn pushContentMask(self: *Window, mask: ?ContentMask) void {
        const m = mask orelse return;
        self.content_mask_stack.append(self.gpa, m.intersect(self.contentMask())) catch @panic("OOM");
    }

    pub fn popContentMask(self: *Window, mask: ?ContentMask) void {
        if (mask != null) _ = self.content_mask_stack.pop();
    }

    /// The current element offset (scroll translation applied to layout bounds).
    pub fn elementOffset(self: *const Window) Point {
        if (self.element_offset_stack.items.len > 0) return self.element_offset_stack.items[self.element_offset_stack.items.len - 1];
        return .zero;
    }

    /// Offset descendants by `offset` relative to the current offset (scrolling).
    pub fn pushElementOffset(self: *Window, offset: Point) void {
        self.pushAbsoluteElementOffset(self.elementOffset().add(offset));
    }

    pub fn pushAbsoluteElementOffset(self: *Window, offset: Point) void {
        self.element_offset_stack.append(self.gpa, offset) catch @panic("OOM");
    }

    pub fn popElementOffset(self: *Window) void {
        _ = self.element_offset_stack.pop();
    }

    /// Multiply descendants' opacity by `opacity`; returns the previous value for `popOpacity`.
    pub fn pushOpacity(self: *Window, opacity: ?f32) f32 {
        const prev = self.element_opacity;
        if (opacity) |o| self.element_opacity = prev * o;
        return prev;
    }

    pub fn popOpacity(self: *Window, prev: f32) void {
        self.element_opacity = prev;
    }

    /// Apply an edge fade to descendants; returns the previous fade for `popEdgeFade`.
    pub fn pushEdgeFade(self: *Window, fade: ?EdgeFade) ?EdgeFade {
        const prev = self.edge_fade;
        if (fade) |f| if (f.active()) {
            self.edge_fade = f;
        };
        return prev;
    }

    pub fn popEdgeFade(self: *Window, prev: ?EdgeFade) void {
        self.edge_fade = prev;
    }

    /// Paint-time opacity for a primitive covering `b` (uniform opacity × edge-fade ramp).
    pub fn elementOpacityForBounds(self: *const Window, b: Bounds) f32 {
        const o = self.element_opacity;
        const f = self.edge_fade orelse return o;
        var ramp: f32 = 1;
        if (f.top) ramp = @min(ramp, std.math.clamp((b.origin.y - f.bounds.origin.y) / f.topBand(), 0, 1));
        if (f.bottom) ramp = @min(ramp, std.math.clamp((f.bounds.bottom() - b.bottom()) / f.bottomBand(), 0, 1));
        if (f.left) ramp = @min(ramp, std.math.clamp((b.origin.x - f.bounds.origin.x) / f.leftBand(), 0, 1));
        if (f.right) ramp = @min(ramp, std.math.clamp((f.bounds.right() - b.right()) / f.rightBand(), 0, 1));
        return o * ramp * ramp;
    }

    pub fn elementOpacityAt(self: *const Window, p: Point) f32 {
        return self.elementOpacityForBounds(.{ .origin = p, .size = .zero });
    }

    // ---- layout --------------------------------------------------------------------------

    /// Add a layout node for `style` with `children` (gpui `request_layout`).
    pub fn requestLayout(self: *Window, style: Style, children: []const LayoutId) LayoutId {
        return self.layout_engine.requestLayout(style.toLayoutStyle(self.remSize(), self.scale_factor), children) catch @panic("OOM");
    }

    /// Add a leaf whose size comes from `f(ctx, known, available, window, app)` in logical
    /// pixels (gpui `request_measured_layout`). `ctx` must outlive the frame (arena).
    pub fn requestMeasuredLayout(
        self: *Window,
        style: Style,
        ctx: anytype,
        comptime f: fn (@TypeOf(ctx), layout.Dims(?Pixels), layout.Dims(AvailableSpace), *Window, *App) Size,
    ) LayoutId {
        const C = @TypeOf(ctx);
        const Thunk = struct {
            ctx: C,
            window: *Window,
            fn measure(p: ?*anyopaque, known: layout.Dims(?f32), avail: layout.Dims(AvailableSpace)) geometry.Size(f32) {
                const t: *@This() = @ptrCast(@alignCast(p.?));
                const s = t.window.scale_factor;
                const k: layout.Dims(?Pixels) = .{
                    .width = if (known.width) |w| w / s else null,
                    .height = if (known.height) |h| h / s else null,
                };
                const a: layout.Dims(AvailableSpace) = .{ .width = unscale(avail.width, s), .height = unscale(avail.height, s) };
                const size = f(t.ctx, k, a, t.window, t.window.app);
                return .{ .width = @ceil(@max(size.width, 0) * s), .height = @ceil(@max(size.height, 0) * s) };
            }
            fn unscale(v: AvailableSpace, s: f32) AvailableSpace {
                return switch (v) {
                    .definite => |d| .{ .definite = d / s },
                    else => v,
                };
            }
        };
        const t = self.element_arena.create(Thunk, .{ .ctx = ctx, .window = self });
        return self.layout_engine.requestMeasuredLayout(style.toLayoutStyle(self.remSize(), self.scale_factor), .{ .ctx = t, .func = Thunk.measure }) catch @panic("OOM");
    }

    /// Lay out the tree rooted at `id` in `available` logical space.
    pub fn computeLayout(self: *Window, id: LayoutId, avail: layout.Dims(AvailableSpace)) void {
        const s = self.scale_factor;
        const scale = struct {
            fn f(v: AvailableSpace, k: f32) AvailableSpace {
                return switch (v) {
                    .definite => |d| .{ .definite = d * k },
                    else => v,
                };
            }
        }.f;
        self.layout_engine.computeLayout(id, .{ .width = scale(avail.width, s), .height = scale(avail.height, s) }) catch @panic("OOM");
    }

    /// Absolute, device-pixel-snapped bounds of a laid out node plus the element offset
    /// (gpui `layout_bounds`).
    pub fn layoutBounds(self: *Window, id: LayoutId) Bounds {
        const s = self.scale_factor;
        const b = self.layout_engine.layoutBounds(id);
        const r = style_mod.roundHalfTowardZero;
        const x0 = r(b.origin.x);
        const y0 = r(b.origin.y);
        const x1 = r(b.origin.x + b.size.width);
        const y1 = r(b.origin.y + b.size.height);
        const off = self.elementOffset();
        return .{
            .origin = .{ .x = x0 / s + self.pixelSnap(off.x), .y = y0 / s + self.pixelSnap(off.y) },
            .size = .{ .width = (x1 - x0) / s, .height = (y1 - y0) / s },
        };
    }

    /// Round a logical coordinate to the nearest device pixel.
    pub fn pixelSnap(self: *const Window, v: Pixels) Pixels {
        return style_mod.roundHalfTowardZero(v * self.scale_factor) / self.scale_factor;
    }

    // ---- hitboxes, cursors, tooltips ------------------------------------------------------

    /// Register a hitbox for this frame (prepaint only; gpui `insert_hitbox`).
    pub fn insertHitbox(self: *Window, b: Bounds, behavior: HitboxBehavior) Hitbox {
        std.debug.assert(self.phase == .prepaint);
        const h: Hitbox = .{ .id = @enumFromInt(self.next_hitbox_id), .bounds = b, .content_mask = self.contentMask(), .behavior = behavior };
        self.next_hitbox_id += 1;
        self.next_frame.hitboxes.append(self.gpa, h) catch @panic("OOM");
        return h;
    }

    /// Route all mouse events to `hitbox` until the next mouse up (gpui `capture_pointer`).
    pub fn capturePointer(self: *Window, hitbox: HitboxId) void {
        self.captured_hitbox = hitbox;
    }

    pub fn releasePointer(self: *Window) void {
        self.captured_hitbox = null;
    }

    /// Cursor while `hitbox` is hovered (paint only).
    pub fn setCursorStyle(self: *Window, style: CursorStyle, hitbox: Hitbox) void {
        self.next_frame.cursor_styles.append(self.gpa, .{ .hitbox_id = hitbox.id, .style = style }) catch @panic("OOM");
    }

    /// Cursor for the whole window, overriding hitbox requests (paint only).
    pub fn setWindowCursorStyle(self: *Window, style: CursorStyle) void {
        self.next_frame.cursor_styles.append(self.gpa, .{ .hitbox_id = null, .style = style }) catch @panic("OOM");
    }

    /// Request a tooltip for this frame (prepaint). Returns its id.
    pub fn setTooltip(self: *Window, req: TooltipRequest) u64 {
        var r = req;
        r.id = self.next_tooltip_id;
        self.next_tooltip_id += 1;
        self.next_frame.tooltip_requests.append(self.gpa, r) catch @panic("OOM");
        return r.id;
    }

    pub fn pushGroupHitbox(self: *Window, name: []const u8, id: HitboxId) void {
        const gop = self.group_hitboxes.getOrPut(self.gpa, name) catch @panic("OOM");
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, name) catch @panic("OOM");
            gop.value_ptr.* = .empty;
        }
        gop.value_ptr.append(self.gpa, id) catch @panic("OOM");
    }

    pub fn popGroupHitbox(self: *Window, name: []const u8) void {
        if (self.group_hitboxes.getPtr(name)) |l| _ = l.pop();
    }

    pub fn groupHitbox(self: *const Window, name: []const u8) ?HitboxId {
        const l = self.group_hitboxes.get(name) orelse return null;
        return if (l.items.len == 0) null else l.items[l.items.len - 1];
    }

    // ---- listener registration (paint) ----------------------------------------------------

    /// Register a mouse listener for this frame (gpui `on_mouse_event`). `ctx` is copied
    /// inline into the listener (<= 160 bytes) and passed mutably to `f`.
    pub fn onMouseEvent(
        self: *Window,
        comptime Ev: type,
        ctx: anytype,
        comptime f: fn (*@TypeOf(ctx), *const Ev, DispatchPhase, *Window, *App) void,
    ) void {
        const C = @TypeOf(ctx);
        const Gen = struct {
            fn call(cap: *Captures, ev: *const anyopaque, phase: DispatchPhase, w: *Window, a: *App) void {
                f(cap.getMut(C), @ptrCast(@alignCast(ev)), phase, w, a);
            }
        };
        self.next_frame.mouse_listeners.append(self.gpa, .{ .kind = mouseEventKind(Ev), .func = Gen.call, .cap = .init(ctx) }) catch @panic("OOM");
    }

    /// Register a key down/up listener on the current dispatch node (gpui `on_key_event`).
    /// `Ev` is `input.KeyDownEvent` or `input.KeyUpEvent`.
    pub fn onKeyEvent(
        self: *Window,
        comptime Ev: type,
        ctx: anytype,
        comptime f: fn (*const @TypeOf(ctx), *const Ev, DispatchPhase, *Window, *App) void,
    ) void {
        const C = @TypeOf(ctx);
        const want: dispatch_mod.KeyEventKind = comptime dispatch_mod.keyEventKind(Ev);
        const Gen = struct {
            fn call(l: *const dispatch_tree.KeyListener, ev: *const anyopaque, phase: DispatchPhase, w: ?*anyopaque, a: *App) void {
                const ke: *const dispatch_mod.KeyEvent = @ptrCast(@alignCast(ev));
                if (ke.kind != want) return;
                f(l.cap.get(C), @ptrCast(@alignCast(ke.event)), phase, @ptrCast(@alignCast(w.?)), a);
            }
        };
        self.next_frame.dispatch_tree.onKeyEvent(.{ .func = Gen.call, .cap = .init(ctx) }) catch @panic("OOM");
    }

    pub fn onModifiersChanged(
        self: *Window,
        ctx: anytype,
        comptime f: fn (*const @TypeOf(ctx), *const input.ModifiersChangedEvent, *Window, *App) void,
    ) void {
        const C = @TypeOf(ctx);
        const Gen = struct {
            fn call(l: *const dispatch_tree.ModifiersChangedListener, ev: *const anyopaque, w: ?*anyopaque, a: *App) void {
                f(l.cap.get(C), @ptrCast(@alignCast(ev)), @ptrCast(@alignCast(w.?)), a);
            }
        };
        self.next_frame.dispatch_tree.onModifiersChanged(.{ .func = Gen.call, .cap = .init(ctx) }) catch @panic("OOM");
    }

    /// Register an action listener on the current dispatch node (gpui `on_action`).
    pub fn onAction(
        self: *Window,
        comptime A: type,
        ctx: anytype,
        comptime f: fn (*const @TypeOf(ctx), *const A, DispatchPhase, *Window, *App) void,
    ) void {
        const C = @TypeOf(ctx);
        const Gen = struct {
            fn call(l: *const dispatch_tree.ActionListener, action: *const AnyAction, phase: DispatchPhase, w: ?*anyopaque, a: *App) void {
                f(l.cap.get(C), action.downcast(A).?, phase, @ptrCast(@alignCast(w.?)), a);
            }
        };
        self.next_frame.dispatch_tree.onAction(.{ .action_type = type_id.typeId(A), .func = Gen.call, .cap = .init(ctx) }) catch @panic("OOM");
    }

    /// Set the key context of the current dispatch node. The context's memory must outlive
    /// every frame that uses it (static or interned: see `internKeyContext`).
    pub fn setKeyContext(self: *Window, ctx: KeyContext) void {
        self.next_frame.dispatch_tree.setKeyContext(ctx) catch @panic("OOM");
    }

    /// The parsed context for `source` ("Editor mode=full"), cached for the window's life.
    pub fn internKeyContext(self: *Window, source: []const u8) !KeyContext {
        if (self.key_contexts.get(source)) |c| return c;
        const a = self.intern_arena.allocator();
        const owned = try a.dupe(u8, source);
        const ctx = try KeyContext.parse(a, owned);
        try self.key_contexts.put(self.gpa, owned, ctx);
        return ctx;
    }

    /// Mark the current dispatch node as `handle`'s element (prepaint).
    pub fn setFocusHandle(self: *Window, handle: FocusHandle) void {
        self.next_frame.dispatch_tree.setFocusId(handle.id) catch @panic("OOM");
    }

    pub fn setViewId(self: *Window, id: EntityId) void {
        self.next_frame.dispatch_tree.setViewId(id) catch @panic("OOM");
    }

    /// Add a focusable element to this frame's tab order (paint).
    pub fn insertTabStop(self: *Window, handle: FocusHandle) void {
        self.next_frame.tab_stops.insert(self.gpa, handle);
    }

    pub fn beginTabGroup(self: *Window, index: ?isize) void {
        if (index) |i| self.next_frame.tab_stops.beginGroup(self.gpa, i);
    }

    pub fn endTabGroup(self: *Window, index: ?isize) void {
        if (index != null) self.next_frame.tab_stops.endGroup(self.gpa);
    }

    /// Register `handler` as the text input target while `handle` is focused (paint; gpui
    /// `handle_input`).
    pub fn handleInput(self: *Window, handle: FocusHandle, handler: InputHandlerRequest) void {
        if (!handle.isFocused(self)) return;
        self.next_frame.input_handlers.append(self.gpa, handler) catch @panic("OOM");
    }

    /// Draw `el` after everything else at `offset` (gpui `defer_draw`; prepaint).
    /// Ask the enclosing scroll container (e.g. `list`) to scroll `b` into view; call during
    /// prepaint (gpui `request_autoscroll`).
    pub fn requestAutoscroll(self: *Window, b: Bounds) void {
        self.requested_autoscroll = b;
    }

    /// Take the pending autoscroll request (gpui `take_autoscroll`).
    pub fn takeAutoscroll(self: *Window) ?Bounds {
        const b = self.requested_autoscroll;
        self.requested_autoscroll = null;
        return b;
    }

    pub fn deferDraw(self: *Window, el: AnyElement, offset: Point, priority: usize, content_mask: ?ContentMask) void {
        const parent = self.next_frame.dispatch_tree.activeNodeId().?;
        const styles = arena_mod.frameAllocator().dupe(TextStyleRefinement, self.text_style_stack.items) catch @panic("OOM");
        self.next_frame.deferred_draws.append(self.gpa, .{
            .current_view = self.currentView(),
            .priority = priority,
            .parent_node = parent,
            .element_id = if (self.currentGlobalId()) |g| g.toKey() else null,
            .text_style_stack = styles,
            .rem_size = self.remSize(),
            .content_mask = content_mask,
            .element = el,
            .absolute_offset = offset,
        }) catch @panic("OOM");
    }

    pub fn preventDefault(self: *Window) void {
        self.default_prevented = true;
    }

    pub fn defaultPrevented(self: *const Window) bool {
        return self.default_prevented;
    }

    // ---- view caching: index snapshots and reuse ------------------------------------------

    pub fn prepaintIndex(self: *Window) PrepaintIndex {
        return .{
            .hitboxes = self.next_frame.hitboxes.items.len,
            .a11y_nodes = self.next_frame.a11y.len(),
            .a11y_pieces = self.next_frame.a11y.piecesLen(),
            .a11y_listeners = self.next_frame.a11y_listeners.items.len,
            .tooltips = self.next_frame.tooltip_requests.items.len,
            .deferred_draws = self.next_frame.deferred_draws.items.len,
            .dispatch_tree = self.next_frame.dispatch_tree.len(),
            .accessed_element_states = self.next_frame.accessed_element_states.items.len,
            .line_layout = self.text_system.layoutIndex(),
        };
    }

    pub fn paintIndex(self: *Window) PaintIndex {
        return .{
            .scene = self.next_frame.scene.len(),
            .mouse_listeners = self.next_frame.mouse_listeners.items.len,
            .input_handlers = self.next_frame.input_handlers.items.len,
            .cursor_styles = self.next_frame.cursor_styles.items.len,
            .tab_stops = self.next_frame.tab_stops.paintIndex(),
            .accessed_element_states = self.next_frame.accessed_element_states.items.len,
            .line_layout = self.text_system.layoutIndex(),
            .native_views = self.next_frame.native_views.items.len,
            .overlay_ranges = self.next_frame.overlay_ranges.items.len,
        };
    }

    fn reuseElementStates(self: *Window, start: usize, end: usize) void {
        for (self.rendered_frame.accessed_element_states.items[start..end]) |key| {
            if (self.next_frame.element_states.contains(key)) continue;
            if (self.rendered_frame.element_states.fetchRemove(key)) |kv| {
                self.next_frame.element_states.put(self.gpa, key, kv.value) catch @panic("OOM");
                self.next_frame.accessed_element_states.append(self.gpa, key) catch @panic("OOM");
            }
        }
    }

    /// Roll prepaint output back to `index` (gpui `transact` on error): used by elements
    /// that prepaint children speculatively, e.g. lists adjusting their scroll position.
    pub fn truncatePrepaint(self: *Window, index: PrepaintIndex) void {
        const n = &self.next_frame;
        n.hitboxes.shrinkRetainingCapacity(index.hitboxes);
        n.a11y.truncate(index.a11y_nodes, index.a11y_pieces);
        if (index.a11y_listeners < n.a11y_listeners.items.len) n.a11y_listeners.shrinkRetainingCapacity(index.a11y_listeners);
        n.tooltip_requests.shrinkRetainingCapacity(index.tooltips);
        n.deferred_draws.shrinkRetainingCapacity(index.deferred_draws);
        n.dispatch_tree.truncate(index.dispatch_tree);
        n.accessed_element_states.shrinkRetainingCapacity(index.accessed_element_states);
        self.text_system.truncateLayouts(index.line_layout);
    }

    /// An entity of type `S` kept in element state under `gid` (gpui `use_keyed_state`):
    /// created with `init(cx)` the first frame, then reused while the element is drawn.
    /// Returns a borrowed handle. Lets `RenderOnce` components own reactive state.
    pub fn useKeyedState(self: *Window, comptime S: type, gid: GlobalElementId, comptime init: fn (*App) S) entity_mod.Entity(S) {
        const Holder = struct {
            entity: ?entity_mod.Entity(S) = null,
            pub fn deinit(h: *@This(), app: *App) void {
                if (h.entity) |e| e.release(app);
            }
        };
        const h = self.elementState(Holder, gid);
        if (h.entity == null) h.entity = self.app.new(S, init(self.app)) catch @panic("OOM");
        return h.entity.?;
    }

    /// Copy a cached view's prepaint output from the rendered frame (gpui `reuse_prepaint`).
    pub fn reusePrepaint(self: *Window, range: [2]PrepaintIndex) void {
        const gpa = self.gpa;
        const r = &self.rendered_frame;
        const n = &self.next_frame;
        n.hitboxes.appendSlice(gpa, r.hitboxes.items[range[0].hitboxes..range[1].hitboxes]) catch @panic("OOM");
        if (n.a11y.isBuilding()) {
            n.a11y.reuseRange(&r.a11y, range[0].a11y_nodes, range[1].a11y_nodes, range[0].a11y_pieces, range[1].a11y_pieces);
            if (range[1].a11y_listeners <= r.a11y_listeners.items.len)
                n.a11y_listeners.appendSlice(gpa, r.a11y_listeners.items[range[0].a11y_listeners..range[1].a11y_listeners]) catch @panic("OOM");
        }
        n.tooltip_requests.appendSlice(gpa, r.tooltip_requests.items[range[0].tooltips..range[1].tooltips]) catch @panic("OOM");
        const reused = n.dispatch_tree.reuseSubtree(
            range[0].dispatch_tree,
            range[1].dispatch_tree - range[0].dispatch_tree,
            &r.dispatch_tree,
            self.focused_id,
        ) catch @panic("OOM");
        if (reused.contains_focus) n.focus = self.focused_id;
        for (r.deferred_draws.items[range[0].deferred_draws..range[1].deferred_draws]) |d| {
            var copy = d;
            copy.parent_node = reused.refreshNodeId(d.parent_node);
            copy.element = null;
            copy.text_style_stack = &.{};
            n.deferred_draws.append(gpa, copy) catch @panic("OOM");
        }
        self.reuseElementStates(range[0].accessed_element_states, range[1].accessed_element_states);
        self.text_system.reuseLayouts(range[0].line_layout, range[1].line_layout) catch @panic("OOM");
    }

    /// Copy a cached view's paint output from the rendered frame (gpui `reuse_paint`).
    pub fn reusePaint(self: *Window, range: [2]PaintIndex) void {
        const gpa = self.gpa;
        const r = &self.rendered_frame;
        const n = &self.next_frame;
        const scene_base = n.scene.len();
        n.scene.replay(gpa, range[0].scene, range[1].scene, &r.scene) catch @panic("OOM");
        n.native_views.appendSlice(gpa, r.native_views.items[range[0].native_views..range[1].native_views]) catch @panic("OOM");
        for (r.overlay_ranges.items[range[0].overlay_ranges..range[1].overlay_ranges]) |o| {
            const start = @max(o.start, range[0].scene) - range[0].scene + scene_base;
            const end = @min(o.end, range[1].scene) - range[0].scene + scene_base;
            if (end > start) n.overlay_ranges.append(gpa, .{ .start = start, .end = end, .plane = o.plane }) catch @panic("OOM");
        }
        for (r.mouse_listeners.items[range[0].mouse_listeners..range[1].mouse_listeners]) |*l| {
            n.mouse_listeners.append(gpa, l.*) catch @panic("OOM");
            l.* = null;
        }
        for (r.input_handlers.items[range[0].input_handlers..range[1].input_handlers]) |*h| {
            n.input_handlers.append(gpa, h.*) catch @panic("OOM");
            h.* = null;
        }
        n.cursor_styles.appendSlice(gpa, r.cursor_styles.items[range[0].cursor_styles..range[1].cursor_styles]) catch @panic("OOM");
        n.tab_stops.replay(gpa, r.tab_stops.insertion_history.items[range[0].tab_stops..range[1].tab_stops]);
        self.reuseElementStates(range[0].accessed_element_states, range[1].accessed_element_states);
        self.text_system.reuseLayouts(range[0].line_layout, range[1].line_layout) catch @panic("OOM");
    }

    // ---- native child views + overlay plane (platform.NativeViewId) ----------------------

    /// Place native view `id` at `bounds` for this frame (paint phase), clipped to the
    /// current content mask. Views not painted in a presented frame are hidden.
    pub fn paintNativeView(self: *Window, id: platform.NativeViewId, view_bounds: Bounds, corner_radius: Pixels) void {
        std.debug.assert(self.phase == .paint);
        const clip = view_bounds.intersect(self.contentMask().bounds);
        self.next_frame.native_views.append(self.gpa, .{ .id = id, .placement = .{
            .bounds = view_bounds,
            .clip = clip,
            .corner_radius = corner_radius,
        } }) catch @panic("OOM");
    }

    /// Paint everything until the matching `popOverlayPlane` on the overlay plane above
    /// native child views (no-op on backends without native views). Nests.
    pub fn pushOverlayPlane(self: *Window) void {
        if (self.overlay_depth == 0) self.overlay_open_start = self.next_frame.scene.len();
        self.overlay_depth += 1;
    }

    pub fn popOverlayPlane(self: *Window) void {
        std.debug.assert(self.overlay_depth > 0);
        self.overlay_depth -= 1;
        if (self.overlay_depth != 0) return;
        const end = self.next_frame.scene.len();
        if (end > self.overlay_open_start)
            self.next_frame.overlay_ranges.append(self.gpa, .{ .start = self.overlay_open_start, .end = end }) catch @panic("OOM");
    }

    /// [liquid-glass] Paint until `popTopPlane` on the top plane: above `.above_overlay`
    /// native children (floating glass) and the overlay plane. Nests; it also counts as
    /// overlay content (`overlay_depth`), so glass painted inside stays floating.
    pub fn pushTopPlane(self: *Window) void {
        if (self.top_depth == 0) self.top_open_start = self.next_frame.scene.len();
        self.top_depth += 1;
        self.pushOverlayPlane();
    }

    pub fn popTopPlane(self: *Window) void {
        std.debug.assert(self.top_depth > 0);
        self.popOverlayPlane();
        self.top_depth -= 1;
        if (self.top_depth != 0) return;
        const end = self.next_frame.scene.len();
        if (end > self.top_open_start)
            self.next_frame.overlay_ranges.append(self.gpa, .{ .start = self.top_open_start, .end = end, .plane = .top }) catch @panic("OOM");
    }

    /// [liquid-glass] Place native glass for element `gid` this frame (paint phase);
    /// null when the platform has no native Liquid Glass (paint a fallback instead).
    /// The caller paints the glass's foreground between `pushOverlayPlane` (tier
    /// `.base`) or `pushTopPlane` (tier `.floating`) and the matching pop.
    pub fn paintLiquidGlass(self: *Window, gid: GlobalElementId, kind: platform.LiquidGlassKind, view_bounds: Bounds, config: platform.LiquidGlassConfig) ?liquid_glass_mod.Tier {
        return liquid_glass_mod.paint(self, gid.toKey(), kind, view_bounds, config);
    }

    /// [liquid-glass] Cut `bounds` (logical px, rounded by `corner_radii`: tl, tr, br, bl)
    /// out of the window's behind-window material for this frame, so native glass over a
    /// region zpui leaves at alpha 0 samples the desktop (macOS `blurred` windows; a no-op
    /// elsewhere). Paint it from a view that is redrawn every frame (the root view): a
    /// frame that paints none removes the hole.
    pub fn paintBackdropHole(self: *Window, hole_bounds: Bounds, corner_radii: [4]Pixels) void {
        std.debug.assert(self.phase == .paint);
        self.next_frame.backdrop_hole = .{ .bounds = hole_bounds, .corner_radii = corner_radii };
    }

    fn applyBackdropHole(self: *Window) void {
        const hole = self.rendered_frame.backdrop_hole;
        if (std.meta.eql(hole, self.applied_backdrop_hole)) return;
        self.applied_backdrop_hole = hole;
        self.platform_window.setBackdropHole(hole);
    }

    /// The frame size of the native control for `state`, or null when this window
    /// shows no native controls (Linux, tests by default, `setNativeControlsEnabled(false)`).
    pub fn measureNativeControl(self: *Window, state: platform.NativeControlState) ?Size {
        return native_controls_mod.measure(self, state);
    }

    /// Place native control `gid` this frame (paint phase); see native_controls.zig.
    pub fn paintNativeControl(self: *Window, gid: GlobalElementId, state: platform.NativeControlState, view_bounds: Bounds, listener: ?native_controls_mod.Listener) bool {
        return native_controls_mod.paint(self, gid.toKey(), state, view_bounds, listener);
    }

    /// Show the zpui-drawn fallbacks instead of native controls in this window.
    pub fn setNativeControlsEnabled(self: *Window, enabled: bool) void {
        if (self.native_controls.disabled == !enabled) return;
        self.native_controls.disabled = !enabled;
        self.refresh();
    }

    /// [liquid-glass] Whether `paintLiquidGlass` can place native glass in this window.
    pub fn supportsLiquidGlass(self: *Window) bool {
        return liquid_glass_mod.supported(self);
    }

    /// Hide native views the rendered frame omits, then place the painted ones.
    fn applyNativeViews(self: *Window) void {
        const pw = self.platform_window;
        if (pw.vtable.placeNativeView == null) return;
        const views = self.rendered_frame.native_views.items;
        for (self.presented_native_views.items) |old| {
            const still = for (views) |v| {
                if (v.id == old) break true;
            } else false;
            if (!still) pw.placeNativeView(old, null);
        }
        self.presented_native_views.clearRetainingCapacity();
        for (views) |v| {
            if (v.id == forgotten_native_view) continue;
            pw.placeNativeView(v.id, v.placement);
            self.presented_native_views.append(self.gpa, v.id) catch {};
        }
    }

    /// Attach a caller-created platform view (macOS `NSView*`) to this window.
    pub fn attachNativeView(self: *Window, native: *anyopaque, options: platform.NativeViewOptions) !platform.NativeViewId {
        return self.platform_window.attachNativeView(native, options);
    }

    /// Detach (and release) a native view attached with `attachNativeView`.
    pub fn detachNativeView(self: *Window, id: platform.NativeViewId) void {
        self.forgetNativeView(id);
        self.platform_window.detachNativeView(id);
    }

    /// Give keyboard focus to a native view, or back to zpui content with `null`.
    pub fn focusNativeView(self: *Window, id: ?platform.NativeViewId) void {
        self.platform_window.focusNativeView(id);
    }

    /// Forget a detached native view (it must not be placed again).
    fn forgetNativeView(self: *Window, id: platform.NativeViewId) void {
        for (self.presented_native_views.items, 0..) |v, i| if (v == id) {
            _ = self.presented_native_views.swapRemove(i);
            break;
        };
        // Tombstone, don't remove: cached views' paint ranges index this list
        // (`reusePaint`), and removing would shift them.
        for (self.rendered_frame.native_views.items) |*v| if (v.id == id) {
            v.id = forgotten_native_view;
            v.placement.clip.size = .{ .width = 0, .height = 0 };
        };
    }

    /// The id a forgotten (detached) native view's paint record takes.
    pub const forgotten_native_view: platform.NativeViewId = @enumFromInt(std.math.maxInt(u32));

    /// The rendered frame places at least one visible native view (web view, native
    /// glass): only then can plane content end up beneath or above something native.
    fn hasPlacedNativeViews(self: *const Window) bool {
        for (self.rendered_frame.native_views.items) |v| {
            if (v.placement.clip.size.width > 0 and v.placement.clip.size.height > 0) return true;
        }
        return false;
    }

    /// Sorted, disjoint ranges for `drawLayered`; [liquid-glass] top-plane ranges win
    /// over the overlay ranges they nest in. Ranges holding a backdrop blur are flagged
    /// `samples_lower_planes`.
    fn mergeOverlayRanges(self: *Window) void {
        self.mergeOverlayRangesInner();
        const ops = self.rendered_frame.scene.paint_operations.items;
        for (self.present_overlay.items) |*r| {
            r.samples_lower_planes = false;
            const end = @min(r.end, ops.len);
            if (r.start >= end) continue;
            for (ops[r.start..end]) |op| if (op == .backdrop_blur) {
                r.samples_lower_planes = true;
                break;
            };
        }
    }

    fn mergeOverlayRangesInner(self: *Window) void {
        const out = &self.present_overlay;
        out.clearRetainingCapacity();
        const all = self.rendered_frame.overlay_ranges.items;
        var has_top = false;
        for (all) |r| if (r.plane == .top) {
            has_top = true;
            break;
        };
        if (!has_top) {
            out.appendSlice(self.gpa, all) catch return;
            sortRanges(out.items);
            var w: usize = 0;
            for (out.items) |r| {
                if (w > 0 and r.start <= out.items[w - 1].end) {
                    out.items[w - 1].end = @max(out.items[w - 1].end, r.end);
                } else {
                    out.items[w] = r;
                    w += 1;
                }
            }
            out.shrinkRetainingCapacity(w);
            return;
        }
        // Sweep the boundaries: each elementary segment takes the strongest plane
        // covering it (top > overlay); equal neighbours merge.
        var cuts: std.ArrayList(usize) = .empty;
        defer cuts.deinit(self.gpa);
        for (all) |r| {
            cuts.append(self.gpa, r.start) catch return;
            cuts.append(self.gpa, r.end) catch return;
        }
        std.mem.sort(usize, cuts.items, {}, std.sort.asc(usize));
        var k: usize = 0;
        while (k + 1 < cuts.items.len) : (k += 1) {
            const a = cuts.items[k];
            const b = cuts.items[k + 1];
            if (b <= a) continue;
            var plane: ?platform.OverlayPlane = null;
            for (all) |r| if (r.start <= a and r.end >= b) {
                if (r.plane == .top) {
                    plane = .top;
                    break;
                }
                plane = .overlay;
            };
            const p = plane orelse continue;
            if (out.items.len > 0) {
                const last = &out.items[out.items.len - 1];
                if (last.end == a and last.plane == p) {
                    last.end = b;
                    continue;
                }
            }
            out.append(self.gpa, .{ .start = a, .end = b, .plane = p }) catch return;
        }
    }

    fn sortRanges(items: []platform.OverlayRange) void {
        std.mem.sort(platform.OverlayRange, items, {}, struct {
            fn lt(_: void, a: platform.OverlayRange, b: platform.OverlayRange) bool {
                return a.start < b.start;
            }
        }.lt);
    }

    // ---- paint API (paint.zig) ------------------------------------------------------------

    pub const paintQuad = paint_mod.paintQuad;
    pub const paintDropShadows = paint_mod.paintDropShadows;
    pub const paintInsetShadows = paint_mod.paintInsetShadows;
    pub const paintShadows = paint_mod.paintShadows;
    pub const paintBackdropBlur = paint_mod.paintBackdropBlur;
    pub const paintPath = paint_mod.paintPath;
    pub const paintUnderline = paint_mod.paintUnderline;
    pub const paintStrikethrough = paint_mod.paintStrikethrough;
    pub const paintGlyph = paint_mod.paintGlyph;
    pub const paintEmoji = paint_mod.paintEmoji;
    pub const paintSvg = paint_mod.paintSvg;
    pub const paintImage = paint_mod.paintImage;
    pub const paintImageFitted = paint_mod.paintImageFitted;
    pub const pushLayer = paint_mod.pushLayer;
    pub const popLayer = paint_mod.popLayer;
    pub const glyphPainter = paint_mod.glyphPainter;
    pub const paintStyle = paint_mod.paintStyle;
    pub const paintStyleBorder = paint_mod.paintStyleBorder;

    // ---- input dispatch (dispatch.zig) ----------------------------------------------------

    pub const dispatchEvent = dispatch_mod.dispatchEvent;
    pub const dispatchAction = dispatch_mod.dispatchAction;
    pub const dispatchAnyAction = dispatch_mod.dispatchAnyAction;
    pub const isActionAvailable = dispatch_mod.isActionAvailable;
    pub const hasPendingKeystrokes = dispatch_mod.hasPendingKeystrokes;
    pub const pendingKeystrokes = dispatch_mod.pendingKeystrokes;
};

test {
    _ = arena_mod;
    _ = element;
    _ = callback;
    _ = focus_mod;
}
