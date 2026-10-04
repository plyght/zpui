//! Overlay scrollbars (port of gpui-component's `base/src/scrollbar.rs`, the scrollbar zeron
//! draws over its lists): a thin thumb painted above the content that appears while
//! scrolling and fades out when idle, widens on hover, and can be dragged or clicked.
//!
//! ```zig
//! div().relative().sizeFull()
//!     .child(zpui.list(self.state, cx, Self.row).sizeFull())
//!     .child(zpui.scrollbar(self.state))                 // ListState, ScrollHandle or
//!                                                        // UniformListScrollHandle
//! zpui.scrollbar(self.scroll).id("files-sb").axis(.both).mode(.hover)
//!     .withStyle(.{ .thumb = theme.text.opacity(0.30), .thumb_hover = theme.text.opacity(0.42) })
//! zpui.scrollbar(self.scroll).withStyle(zpui.ScrollbarStyle.compact)   // zeron menus
//! ```
//!
//! The scrollbar is an absolutely positioned overlay filling its parent (put it after the
//! scrolled content in a `relative()` parent). Its interaction state lives in element state
//! keyed by its id (default "scrollbar"; give siblings distinct ids).

const std = @import("std");
const geometry = @import("../geometry.zig");
const color = @import("../color.zig");
const Hsla = color.Hsla;
const style_mod = @import("../style.zig");
const refine = @import("../style/refine.zig");
const StyleBuilder = @import("../styled.zig").StyleBuilder;
const App = @import("../app/app.zig").App;
const entity_mod = @import("../app/entity.zig");
const EntityId = entity_mod.EntityId;
const executor = @import("../app/executor.zig");
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const Hitbox = window_mod.Hitbox;
const DispatchPhase = window_mod.DispatchPhase;
const element = @import("../window/element.zig");
const AnyElement = element.AnyElement;
const ElementId = element.ElementId;
const GlobalElementId = element.GlobalElementId;
const LayoutId = element.LayoutId;
const paint_mod = @import("../window/paint.zig");
const input = @import("../input.zig");
const arena_mod = @import("../window/arena.zig");
const div_mod = @import("div.zig");
const ScrollHandle = div_mod.ScrollHandle;
const list_mod = @import("list.zig");
const ListState = list_mod.ListState;
const uniform_mod = @import("uniform_list.zig");
const UniformListScrollHandle = uniform_mod.UniformListScrollHandle;

const Pixels = geometry.Pixels;
const Point = geometry.Point(Pixels);
const Size = geometry.Size(Pixels);
const Bounds = geometry.Bounds(Pixels);

/// When the scrollbar shows (gpui-component `ScrollbarMode`).
pub const ScrollbarMode = enum {
    /// While scrolling; fades out after `fade_delay_ms` idle.
    scrolling,
    /// While hovering the bar (and while scrolling).
    hover,
    /// Always.
    always,
};

pub const Axis = enum { vertical, horizontal };

pub const ScrollbarAxis = enum {
    vertical,
    horizontal,
    both,

    fn has(self: ScrollbarAxis, a: Axis) bool {
        return switch (self) {
            .both => true,
            .vertical => a == .vertical,
            .horizontal => a == .horizontal,
        };
    }
};

/// Geometry, colors and timing. The defaults are gpui-component's.
pub const ScrollbarStyle = struct {
    /// Width of the interactive bar (track).
    track_width: Pixels = 16,
    /// Thumb thickness while scrolling (`.scrolling` mode, idle bar).
    thumb_width: Pixels = 6,
    /// Thumb thickness when hovered/dragged (and in `.hover`/`.always` modes).
    thumb_active_width: Pixels = 8,
    /// Distance between the thumb and the bar edges.
    inset: Pixels = 4,
    /// Thumb corner radius (clamped to half the thumb thickness).
    radius: Pixels = 0,
    min_thumb_length: Pixels = 48,
    thumb: Hsla = color.black.opacity(0.35),
    thumb_hover: Hsla = color.black.opacity(0.55),
    thumb_active: Hsla = color.black.opacity(0.55),
    track: Hsla = color.transparent_black,
    track_hover: Hsla = color.transparent_black,
    /// Visible time after the last scroll before fading.
    fade_delay_ms: u64 = 2000,
    /// Fade-out time.
    fade_ms: u64 = 1000,
    /// gpui-component fades with `1 - t^10` (holds, then drops); false fades linearly.
    sharp_fade: bool = true,
    /// Limit for drag-driven offset updates.
    max_fps: u32 = 120,

    /// zeron's menu scrollbar: 3px thumb, 5px on hover, 24px minimum, lingers 1.4s and
    /// fades over 260ms, fully rounded.
    pub const compact: ScrollbarStyle = .{
        .track_width = 9,
        .thumb_width = 3,
        .thumb_active_width = 5,
        .inset = 2,
        .radius = 999,
        .min_thumb_length = 24,
        .fade_delay_ms = 1400,
        .fade_ms = 260,
        .sharp_fade = false,
    };
};

/// What the scrollbar scrolls.
pub const Source = union(enum) {
    scroll: ScrollHandle,
    list: ListState,
    uniform: UniformListScrollHandle,

    pub fn from(h: anytype) Source {
        const H = @TypeOf(h);
        if (H == Source) return h;
        if (H == ScrollHandle) return .{ .scroll = h };
        if (H == ListState) return .{ .list = h };
        if (H == UniformListScrollHandle) return .{ .uniform = h };
        @compileError("scrollbar() takes a ScrollHandle, ListState or UniformListScrollHandle, got " ++ @typeName(H));
    }

    fn retain(self: Source) Source {
        return switch (self) {
            .scroll => |h| .{ .scroll = h.retain() },
            .list => |h| .{ .list = h.retain() },
            .uniform => |h| .{ .uniform = h.retain() },
        };
    }

    fn release(self: Source) void {
        switch (self) {
            .scroll => |h| h.release(),
            .list => |h| h.release(),
            .uniform => |h| h.release(),
        }
    }

    fn ptr(self: Source) *anyopaque {
        return switch (self) {
            .scroll => |h| @ptrCast(h.state),
            .list => |h| @ptrCast(h.inner),
            .uniform => |h| @ptrCast(h.state),
        };
    }

    pub fn offset(self: Source) Point {
        return switch (self) {
            .scroll => |h| h.offset(),
            .list => |h| h.scrollPxOffsetForScrollbar(),
            .uniform => |h| h.offset(),
        };
    }

    pub fn setOffset(self: Source, p: Point) void {
        switch (self) {
            .scroll => |h| h.setOffset(p),
            .list => |h| h.setOffsetFromScrollbar(p),
            .uniform => |h| h.setOffset(p),
        }
    }

    /// Maximum scroll distance (≥ 0) per axis.
    pub fn maxOffset(self: Source) Point {
        return switch (self) {
            .scroll => |h| h.maxOffset(),
            .list => |h| h.maxOffsetForScrollbar(),
            .uniform => |h| h.baseHandle().maxOffset(),
        };
    }

    /// Full content size including padding.
    pub fn contentSize(self: Source) Size {
        return switch (self) {
            .scroll => |h| .{ .width = h.maxOffset().x + h.bounds().size.width, .height = h.maxOffset().y + h.bounds().size.height },
            .list => |h| .{ .width = h.viewportBounds().size.width, .height = h.viewportBounds().size.height + h.maxOffsetForScrollbar().y },
            .uniform => |h| blk: {
                const b = h.baseHandle();
                break :blk .{ .width = b.maxOffset().x + b.bounds().size.width, .height = b.maxOffset().y + b.bounds().size.height };
            },
        };
    }

    fn startDrag(self: Source) void {
        if (self == .list) self.list.scrollbarDragStarted();
    }

    fn endDrag(self: Source) void {
        if (self == .list) self.list.scrollbarDragEnded();
    }
};

const State = struct {
    hovered_axis: ?Axis = null,
    hovered_on_thumb: ?Axis = null,
    dragged_axis: ?Axis = null,
    drag_pos: Point = .zero,
    last_scroll_offset: Point = .zero,
    last_scroll_time: ?u64 = null,
    last_update: u64 = 0,
    idle_task: ?executor.Task(void) = null,
    /// Keeps the scrolled state alive while listeners reference it.
    source: ?Source = null,

    pub fn deinit(self: *State) void {
        if (self.idle_task) |*t| t.cancel();
        if (self.source) |s| s.release();
    }

    fn isVisible(self: *const State, now: u64, st: *const ScrollbarStyle) bool {
        const t = self.last_scroll_time orelse return false;
        return now -| t < (st.fade_delay_ms + st.fade_ms) * std.time.ns_per_ms;
    }
};

const IdleTimer = struct {
    state: *State,
    app: *App,
    view: EntityId,

    pub fn finish(self: *IdleTimer) void {
        if (self.state.idle_task) |*t| t.detach();
        self.state.idle_task = null;
        self.app.notify(self.view);
    }
};

pub const ScrollbarData = struct {
    source: Source,
    id: ElementId = .{ .name = "scrollbar" },
    axis: ScrollbarAxis = .vertical,
    mode: ScrollbarMode = .scrolling,
    style: ScrollbarStyle = .{},
    /// Explicit content size (else from the source).
    scroll_size: ?Size = null,
};

/// An overlay scrollbar for `handle` (`ScrollHandle`, `ListState` or
/// `UniformListScrollHandle`).
pub fn scrollbar(handle: anytype) Scrollbar {
    return .{ .d = arena_mod.current().create(ScrollbarData, .{ .source = Source.from(handle) }) };
}

pub const Scrollbar = struct {
    const Self = @This();
    d: *ScrollbarData,

    pub fn id(self: Self, x: anytype) Self {
        self.d.id = ElementId.from(x);
        return self;
    }
    pub fn axis(self: Self, a: ScrollbarAxis) Self {
        self.d.axis = a;
        return self;
    }
    pub fn vertical(self: Self) Self {
        return self.axis(.vertical);
    }
    pub fn horizontal(self: Self) Self {
        return self.axis(.horizontal);
    }
    pub fn mode(self: Self, m: ScrollbarMode) Self {
        self.d.mode = m;
        return self;
    }
    pub fn withStyle(self: Self, s: ScrollbarStyle) Self {
        self.d.style = s;
        return self;
    }
    /// Override the content size reported by the source.
    pub fn scrollSize(self: Self, s: Size) Self {
        self.d.scroll_size = s;
        return self;
    }
    pub fn intoAnyElement(self: Self) AnyElement {
        return AnyElement.new(ScrollbarElement{ .d = self.d });
    }
};

const AxisState = struct {
    axis: Axis,
    bar_hitbox: Hitbox,
    bounds: Bounds,
    radius: Pixels,
    bg: Hsla,
    thumb_bounds: Bounds,
    thumb_fill_bounds: Bounds,
    thumb_bg: Hsla,
    scroll_size: Pixels,
    container_size: Pixels,
    thumb_size: Pixels,
    margin_end: Pixels,
};

pub const PrepaintState = struct {
    hitbox: Hitbox,
    axes: [2]?AxisState = .{ null, null },
    state: *State,
};

const Look = struct { thumb: Hsla, track: Hsla, width: Pixels };

const ScrollbarElement = struct {
    d: *ScrollbarData,

    pub const PrepaintState = @import("scrollbar.zig").PrepaintState;

    pub fn elementId(self: *ScrollbarElement) ?ElementId {
        return self.d.id;
    }

    pub fn requestLayout(_: *ScrollbarElement, _: ?GlobalElementId, _: *void, window: *Window, _: *App) LayoutId {
        var s: style_mod.Style = .{};
        refine.refine(&s, StyleBuilder.init.absolute().top0().left0().sizeFull().refinement);
        return window.requestLayout(s, &.{});
    }

    pub fn prepaint(self: *ScrollbarElement, gid: ?GlobalElementId, bounds: Bounds, _: *void, pp: *ScrollbarElement.PrepaintState, window: *Window, cx: *App) void {
        const d = self.d;
        const st = &d.style;
        window.pushContentMask(.{ .bounds = bounds });
        const hitbox = window.insertHitbox(bounds, .normal);
        window.popContentMask(.{ .bounds = bounds });
        const state = window.elementState(State, gid.?);
        if (state.source == null or state.source.?.ptr() != d.source.ptr()) {
            if (state.source) |old| old.release();
            state.source = d.source.retain();
        }
        pp.* = .{ .hitbox = hitbox, .state = state };

        const now = cx.executor.now();
        const scroll_size = d.scroll_size orelse d.source.contentSize();
        const offset = d.source.offset();
        var has_both = d.axis == .both;
        const offset_changed = state.last_scroll_offset.x != offset.x or state.last_scroll_offset.y != offset.y;

        for ([_]Axis{ .vertical, .horizontal }, 0..) |ax, i| {
            if (!d.axis.has(ax)) continue;
            const vertical = ax == .vertical;
            const area = if (vertical) scroll_size.height else scroll_size.width;
            const container = if (vertical) bounds.size.height else bounds.size.width;
            const position = if (vertical) offset.y else offset.x;
            const margin_end: Pixels = if (has_both and !vertical) st.track_width else 0;
            if (area <= container) {
                has_both = false;
                continue;
            }
            const bar: Bounds = if (vertical)
                .{ .origin = .{ .x = bounds.right() - st.track_width, .y = bounds.origin.y }, .size = .{ .width = st.track_width, .height = bounds.size.height } }
            else
                .{ .origin = .{ .x = bounds.origin.x, .y = bounds.bottom() - st.track_width }, .size = .{ .width = bounds.size.width, .height = st.track_width } };

            const hovered_bar = state.hovered_axis == ax;
            const hovered_thumb = state.hovered_on_thumb == ax;
            var look: Look = undefined;
            const idle_width = if (d.mode == .scrolling) st.thumb_width else st.thumb_active_width;
            if (state.dragged_axis == ax) {
                look = .{ .thumb = st.thumb_active, .track = st.track_hover, .width = st.thumb_active_width };
            } else if (d.mode == .hover and (hovered_bar or hovered_thumb)) {
                look = if (hovered_thumb)
                    .{ .thumb = st.thumb_hover, .track = st.track_hover, .width = st.thumb_active_width }
                else
                    .{ .thumb = st.thumb, .track = st.track_hover, .width = st.thumb_active_width };
            } else if (offset_changed) {
                look = .{ .thumb = st.thumb, .track = st.track, .width = idle_width };
            } else if (d.mode == .always) {
                look = if (hovered_thumb)
                    .{ .thumb = st.thumb_hover, .track = st.track_hover, .width = st.thumb_active_width }
                else
                    .{ .thumb = st.thumb, .track = st.track_hover, .width = st.thumb_active_width };
            } else {
                look = .{ .thumb = color.transparent_black, .track = color.transparent_black, .width = idle_width };
                if (state.last_scroll_time) |t| {
                    const elapsed = now -| t;
                    const delay = st.fade_delay_ms * std.time.ns_per_ms;
                    const fade = st.fade_ms * std.time.ns_per_ms;
                    if (hovered_bar) {
                        state.last_scroll_time = now;
                        look = if (hovered_thumb)
                            .{ .thumb = st.thumb_hover, .track = st.track_hover, .width = st.thumb_active_width }
                        else
                            .{ .thumb = st.thumb, .track = st.track_hover, .width = st.thumb_active_width };
                    } else if (elapsed < delay) {
                        look.thumb = st.thumb;
                        if (state.idle_task == null) {
                            state.idle_task = cx.foregroundExecutor().timer(delay - elapsed, IdleTimer{ .state = state, .app = cx, .view = window.currentView() }) catch @panic("OOM");
                        }
                    } else if (elapsed < delay + fade) {
                        const t01: f32 = @floatCast(@as(f64, @floatFromInt(elapsed - delay)) / @as(f64, @floatFromInt(@max(fade, 1))));
                        const opacity = if (st.sharp_fade) 1 - std.math.pow(f32, t01, 10) else 1 - t01;
                        look.thumb = st.thumb.opacity(opacity);
                        window.requestAnimationFrame();
                    }
                }
            }

            const thumb_size = @max(container / area * container, st.min_thumb_length);
            const thumb_start = -(position / (area - container) * (container - margin_end - thumb_size));
            const thumb_end = @min(thumb_start + thumb_size, container - margin_end);
            const thumb_length = thumb_end - thumb_start - st.inset * 2;
            const thumb_bounds: Bounds = if (vertical)
                .{ .origin = .{ .x = bar.right() - st.inset - st.track_width, .y = bar.origin.y + st.inset + thumb_start }, .size = .{ .width = st.track_width, .height = thumb_length } }
            else
                .{ .origin = .{ .x = bar.origin.x + st.inset + thumb_start, .y = bar.bottom() - st.inset - st.track_width }, .size = .{ .width = thumb_length, .height = st.track_width } };
            const fill_bounds: Bounds = if (vertical)
                .{ .origin = .{ .x = bar.right() - st.inset - look.width, .y = bar.origin.y + st.inset + thumb_start }, .size = .{ .width = look.width, .height = thumb_length } }
            else
                .{ .origin = .{ .x = bar.origin.x + st.inset + thumb_start, .y = bar.bottom() - st.inset - look.width }, .size = .{ .width = thumb_length, .height = look.width } };

            window.pushContentMask(.{ .bounds = bar });
            const bar_hitbox = window.insertHitbox(bar, .normal);
            window.popContentMask(.{ .bounds = bar });
            pp.axes[i] = .{
                .axis = ax,
                .bar_hitbox = bar_hitbox,
                .bounds = bar,
                .radius = @min(st.radius, @min(fill_bounds.size.width, fill_bounds.size.height) / 2),
                .bg = look.track,
                .thumb_bounds = thumb_bounds,
                .thumb_fill_bounds = fill_bounds,
                .thumb_bg = look.thumb,
                .scroll_size = area,
                .container_size = container,
                .thumb_size = thumb_length,
                .margin_end = margin_end,
            };
        }
    }

    pub fn paint(self: *ScrollbarElement, _: ?GlobalElementId, _: Bounds, _: *void, pp: *ScrollbarElement.PrepaintState, window: *Window, cx: *App) void {
        const d = self.d;
        const state = pp.state;
        const now = cx.executor.now();
        const view = window.currentView();
        const hb = pp.hitbox.bounds;
        const visible = state.isVisible(now, &d.style) or d.mode == .always;
        const hover_mode = d.mode == .hover;

        // Remember when the offset last changed (drives show/fade).
        const offset = d.source.offset();
        if (offset.x != state.last_scroll_offset.x or offset.y != state.last_scroll_offset.y) {
            state.last_scroll_offset = offset;
            state.last_scroll_time = now;
            cx.notify(view);
        }

        window.pushContentMask(.{ .bounds = hb });
        defer window.popContentMask(.{ .bounds = hb });
        for (pp.axes) |maybe| {
            const ax = maybe orelse continue;
            window.setCursorStyle(.arrow, ax.bar_hitbox);
            const layer = window.pushLayer(hb);
            if (ax.bg.a > 0) window.paintQuad(paint_mod.fill(ax.bounds, ax.bg));
            if (ax.thumb_bg.a > 0) window.paintQuad(paint_mod.fill(ax.thumb_fill_bounds, ax.thumb_bg).cornerRadii(ax.radius));
            window.popLayer(layer);

            const Ctx = struct {
                state: *State,
                source: Source,
                hitbox_bounds: Bounds,
                bounds: Bounds,
                thumb_bounds: Bounds,
                axis: Axis,
                scroll_size: Pixels,
                container_size: Pixels,
                thumb_size: Pixels,
                margin_end: Pixels,
                view: EntityId,
                hover_or_visible: bool,
                min_update_ns: u64,
            };
            const ctx: Ctx = .{
                .state = state,
                .source = d.source,
                .hitbox_bounds = hb,
                .bounds = ax.bounds,
                .thumb_bounds = ax.thumb_bounds,
                .axis = ax.axis,
                .scroll_size = ax.scroll_size,
                .container_size = ax.container_size,
                .thumb_size = ax.thumb_size,
                .margin_end = ax.margin_end,
                .view = view,
                .hover_or_visible = hover_mode or visible,
                .min_update_ns = std.time.ns_per_s / @max(d.style.max_fps, 1),
            };
            window.onMouseEvent(input.ScrollWheelEvent, ctx, struct {
                fn f(c: *Ctx, ev: *const input.ScrollWheelEvent, phase: DispatchPhase, _: *Window, a: *App) void {
                    if (phase != .bubble or !c.hitbox_bounds.contains(ev.position)) return;
                    const o = c.source.offset();
                    if (o.x != c.state.last_scroll_offset.x or o.y != c.state.last_scroll_offset.y) {
                        c.state.last_scroll_offset = o;
                        c.state.last_scroll_time = a.executor.now();
                        a.notify(c.view);
                    }
                }
            }.f);
            if (ctx.hover_or_visible) window.onMouseEvent(input.MouseDownEvent, ctx, struct {
                fn f(c: *Ctx, ev: *const input.MouseDownEvent, phase: DispatchPhase, _: *Window, a: *App) void {
                    if (phase != .bubble or !c.bounds.contains(ev.position)) return;
                    a.propagate_event = false;
                    const vertical = c.axis == .vertical;
                    if (c.thumb_bounds.contains(ev.position)) {
                        c.source.startDrag();
                        c.state.dragged_axis = c.axis;
                        c.state.drag_pos = .{ .x = ev.position.x - c.thumb_bounds.origin.x, .y = ev.position.y - c.thumb_bounds.origin.y };
                    } else {
                        // Jump: center the thumb on the click.
                        const o = c.source.offset();
                        const pct = @min(if (vertical)
                            (ev.position.y - c.thumb_size / 2 - c.bounds.origin.y) / (c.bounds.size.height - c.thumb_size)
                        else
                            (ev.position.x - c.thumb_size / 2 - c.bounds.origin.x) / (c.bounds.size.width - c.thumb_size), 1);
                        const v = std.math.clamp(-c.scroll_size * pct, -c.scroll_size + c.container_size, 0);
                        c.source.setOffset(if (vertical) .{ .x = o.x, .y = v } else .{ .x = v, .y = o.y });
                    }
                    a.notify(c.view);
                }
            }.f);
            window.onMouseEvent(input.MouseMoveEvent, ctx, struct {
                fn f(c: *Ctx, ev: *const input.MouseMoveEvent, _: DispatchPhase, _: *Window, a: *App) void {
                    const s = c.state;
                    var notify = false;
                    if (c.bounds.contains(ev.position) and c.hover_or_visible) {
                        if (s.hovered_axis != c.axis) notify = true;
                        s.hovered_axis = c.axis;
                    } else if (s.hovered_axis == c.axis) {
                        s.hovered_axis = null;
                        notify = true;
                    }
                    if (c.thumb_bounds.contains(ev.position)) {
                        if (s.hovered_on_thumb != c.axis) {
                            s.hovered_on_thumb = c.axis;
                            notify = true;
                        }
                    } else if (s.hovered_on_thumb == c.axis) {
                        s.hovered_on_thumb = null;
                        notify = true;
                    }
                    if (s.dragged_axis == c.axis and ev.pressed_button == .left) {
                        a.propagate_event = false;
                        const vertical = c.axis == .vertical;
                        const pct = std.math.clamp(if (vertical)
                            (ev.position.y - s.drag_pos.y - c.bounds.origin.y) / (c.bounds.size.height - c.thumb_size)
                        else
                            (ev.position.x - s.drag_pos.x - c.bounds.origin.x) / (c.bounds.size.width - c.thumb_size - c.margin_end), 0, 1);
                        const v = std.math.clamp(-(c.scroll_size - c.container_size) * pct, -c.scroll_size + c.container_size, 0);
                        const o = c.source.offset();
                        const target: Point = if (vertical) .{ .x = o.x, .y = v } else .{ .x = v, .y = o.y };
                        if (@abs(o.y - target.y) > 1 or @abs(o.x - target.x) > 1) {
                            const t_now = a.executor.now();
                            if (t_now -| s.last_update >= c.min_update_ns) {
                                c.source.setOffset(target);
                                s.last_update = t_now;
                                notify = true;
                            }
                        }
                    }
                    if (notify) a.notify(c.view);
                }
            }.f);
            window.onMouseEvent(input.MouseUpEvent, ctx, struct {
                fn f(c: *Ctx, _: *const input.MouseUpEvent, phase: DispatchPhase, _: *Window, a: *App) void {
                    if (phase != .bubble) return;
                    if (c.state.dragged_axis == null) return;
                    c.source.endDrag();
                    c.state.dragged_axis = null;
                    a.notify(c.view);
                }
            }.f);
        }
    }
};
