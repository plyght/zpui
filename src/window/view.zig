//! Views (gpui `view.rs`): entities that render, as elements.
//!
//! * A **view** is an entity type `V` with
//!   `pub fn render(self: *V, window: *Window, cx: *Context(V)) R` where `R` is anything
//!   `intoAnyElement` accepts (usually `Div`). Use the entity handle directly as a child:
//!   `div().child(self.sidebar)`. The window's root is a view.
//! * A **component** (gpui `RenderOnce`) is a plain struct with
//!   `pub fn render(self: C, window: *Window, cx: *App) R`, rendered once when laid out:
//!   `div().child(Button{ .label = "Save" })`.
//! * **Cached views** (`entity.cached(style)` / `AnyView.cached`) skip render, layout,
//!   prepaint and paint entirely when neither the view nor anything it read was notified
//!   and its bounds are unchanged: the previous frame's output (scene ranges, hitboxes,
//!   listeners, dispatch nodes, element states, line layouts) is reused.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const refine = @import("../style/refine.zig");
const App = @import("../app/app.zig").App;
const entity_mod = @import("../app/entity.zig");
const EntityId = entity_mod.EntityId;
const Entity = entity_mod.Entity;
const AnyEntity = entity_mod.AnyEntity;
const Context = @import("../app/context.zig").Context;
const element = @import("element.zig");
const AnyElement = element.AnyElement;
const GlobalElementId = element.GlobalElementId;
const LayoutId = element.LayoutId;
const arena_mod = @import("arena.zig");
const window_mod = @import("window.zig");
const Window = window_mod.Window;

const Bounds = geometry.Bounds(geometry.Pixels);

/// True if `X` is `Entity(V)` for a view type `V`.
pub fn isEntityView(comptime X: type) bool {
    if (!@hasDecl(X, "Type") or !@hasField(X, "id")) return false;
    if (X != Entity(X.Type)) return false;
    return @typeInfo(X.Type) == .@"struct" and @hasDecl(X.Type, "render");
}

/// True if `X` is a `RenderOnce` component.
pub fn isRenderOnce(comptime X: type) bool {
    if (!@hasDecl(X, "render")) return false;
    const info = @typeInfo(@TypeOf(X.render));
    if (info != .@"fn") return false;
    return info.@"fn".param_types.len == 3 and info.@"fn".param_types[0] == X;
}

/// A type-erased view handle (gpui `AnyView`). Does not own a reference.
pub const AnyView = struct {
    entity: AnyEntity,
    render: *const fn (id: EntityId, window: *Window, app: *App) AnyElement,
    /// Set by `cached`: the outer style the view is laid out with (arena copy).
    cached_style: ?*const style_mod.StyleRefinement = null,

    pub fn fromEntity(e: anytype) AnyView {
        const V = @TypeOf(e).Type;
        comptime checkView(V);
        return .{ .entity = e.toAny(), .render = renderThunk(V) };
    }

    /// Cache this view's output across frames (see file docs). `style` is the outer
    /// layout style (e.g. `StyleBuilder.init.sizeFull().refinement`).
    pub fn cached(self: AnyView, style: style_mod.StyleRefinement) AnyView {
        var v = self;
        v.cached_style = arena_mod.current().create(style_mod.StyleRefinement, style);
        return v;
    }

    pub fn entityId(self: AnyView) EntityId {
        return self.entity.id;
    }

    pub fn intoAnyElement(self: AnyView) AnyElement {
        return AnyElement.new(ViewElement{ .view = self });
    }
};

fn checkView(comptime V: type) void {
    if (!@hasDecl(V, "render")) @compileError(@typeName(V) ++ " is not a view: add `pub fn render(self: *" ++
        @typeName(V) ++ ", window: *Window, cx: *Context(" ++ @typeName(V) ++ ")) <element type>`");
    const params = @typeInfo(@TypeOf(V.render)).@"fn".param_types;
    if (params.len != 3 or params[0] != *V or params[1] != *Window or params[2] != *Context(V))
        @compileError(@typeName(V) ++ ".render must be `fn (self: *V, window: *Window, cx: *Context(V)) R`");
}

fn renderThunk(comptime V: type) *const fn (EntityId, *Window, *App) AnyElement {
    return struct {
        fn call(id: EntityId, w: *Window, a: *App) AnyElement {
            const e: Entity(V) = .{ .id = id };
            return e.update(a, render, .{w});
        }
        fn render(v: *V, w: *Window, cx: *Context(V)) AnyElement {
            return element.intoAnyElement(v.render(w, cx));
        }
    }.call;
}

/// State of a cached view between frames (gpui `ViewElementState`).
const ViewCacheState = struct {
    valid: bool = false,
    prepaint_range: [2]window_mod.PrepaintIndex = .{ .{}, .{} },
    paint_range: [2]window_mod.PaintIndex = .{ .{}, .{} },
    bounds: Bounds = undefined,
    content_mask: Bounds = undefined,
    text_style_hash: u64 = 0,
    accessed: std.ArrayList(EntityId) = .empty,

    pub fn deinit(self: *ViewCacheState, gpa: Allocator) void {
        self.accessed.deinit(gpa);
    }
};

fn hashTextStyle(t: style_mod.TextStyle) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&t.color));
    h.update(t.font_family);
    h.update(std.mem.asBytes(&t.font_size));
    h.update(std.mem.asBytes(&t.line_height));
    h.update(std.mem.asBytes(&t.font_weight));
    h.update(std.mem.asBytes(&t.font_style));
    h.update(std.mem.asBytes(&t.white_space));
    h.update(std.mem.asBytes(&t.text_align));
    h.update(std.mem.asBytes(&t.line_clamp));
    if (t.background_color) |c| h.update(std.mem.asBytes(&c));
    if (t.text_overflow) |o| h.update(std.mem.asBytes(&std.meta.activeTag(o)));
    return h.final();
}

/// The element for a view (gpui `ViewElement` / `AnyView` element impl).
pub const ViewElement = struct {
    view: AnyView,

    pub const RequestLayoutState = ?AnyElement;
    pub const PrepaintState = ?AnyElement;

    pub fn elementId(self: *ViewElement) ?element.ElementId {
        return .{ .view = self.view.entity.id };
    }

    pub fn requestLayout(self: *ViewElement, _: ?GlobalElementId, state: *?AnyElement, window: *Window, cx: *App) LayoutId {
        const id = self.view.entity.id;
        window.pushRenderedView(id);
        defer window.popRenderedView();
        if (self.view.cached_style) |cs| {
            var s: style_mod.Style = .{};
            refine.refine(&s, cs.*);
            state.* = null;
            return window.requestLayout(s, &.{});
        }
        const el = self.view.render(id, window, cx);
        state.* = el;
        return el.requestLayout(window, cx);
    }

    pub fn prepaint(self: *ViewElement, gid: ?GlobalElementId, bounds: Bounds, rl: *?AnyElement, pp: *?AnyElement, window: *Window, cx: *App) void {
        const id = self.view.entity.id;
        window.setViewId(id);
        window.pushRenderedView(id);
        defer window.popRenderedView();
        pp.* = null;
        if (self.view.cached_style == null) {
            rl.*.?.prepaint(window, cx);
            return;
        }
        const st = window.elementState(ViewCacheState, gid.?);
        const mask = window.contentMask().bounds;
        const th = hashTextStyle(window.textStyle());
        if (st.valid and std.meta.eql(st.bounds, bounds) and std.meta.eql(st.content_mask, mask) and st.text_style_hash == th and
            !window.dirty_views.contains(id) and !window.refreshing)
        {
            const reuse_start = window.prepaintIndex();
            window.reusePrepaint(st.prepaint_range);
            st.prepaint_range = .{ reuse_start, window.prepaintIndex() };
            for (st.accessed.items) |e| cx.entities.accessed.put(cx.gpa, e, {}) catch @panic("OOM");
            return;
        }
        // Render fresh, recording which entities this view reads.
        var outer = cx.entities.accessed;
        cx.entities.accessed = .empty;
        const start = window.prepaintIndex();
        const el = self.view.render(id, window, cx);
        _ = el.layoutAsRoot(element.avail.definite(bounds.size), window, cx);
        el.prepaintAt(bounds.origin, window, cx);
        const end = window.prepaintIndex();
        st.accessed.clearRetainingCapacity();
        var it = cx.entities.accessed.keyIterator();
        while (it.next()) |k| {
            st.accessed.append(cx.gpa, k.*) catch @panic("OOM");
            outer.put(cx.gpa, k.*, {}) catch @panic("OOM");
        }
        cx.entities.accessed.deinit(cx.gpa);
        cx.entities.accessed = outer;
        st.prepaint_range = .{ start, end };
        st.bounds = bounds;
        st.content_mask = mask;
        st.text_style_hash = th;
        st.valid = false; // becomes valid once painted
        pp.* = el;
    }

    pub fn paint(self: *ViewElement, gid: ?GlobalElementId, _: Bounds, rl: *?AnyElement, pp: *?AnyElement, window: *Window, cx: *App) void {
        const id = self.view.entity.id;
        window.pushRenderedView(id);
        defer window.popRenderedView();
        if (self.view.cached_style == null) {
            rl.*.?.paint(window, cx);
            return;
        }
        const st = window.elementState(ViewCacheState, gid.?);
        if (pp.*) |el| {
            const start = window.paintIndex();
            el.paint(window, cx);
            st.paint_range = .{ start, window.paintIndex() };
            st.valid = true;
        } else {
            const start = window.paintIndex();
            window.reusePaint(st.paint_range);
            st.paint_range = .{ start, window.paintIndex() };
        }
    }
};

/// Wrap a `RenderOnce` component value as an element.
pub fn component(value: anytype) AnyElement {
    return AnyElement.new(Component(@TypeOf(value)){ .value = value });
}

pub fn Component(comptime C: type) type {
    return struct {
        value: C,

        pub const RequestLayoutState = AnyElement;

        pub fn requestLayout(self: *@This(), _: ?GlobalElementId, state: *AnyElement, window: *Window, cx: *App) LayoutId {
            state.* = element.intoAnyElement(self.value.render(window, cx));
            return state.requestLayout(window, cx);
        }
        pub fn prepaint(_: *@This(), _: ?GlobalElementId, _: Bounds, rl: *AnyElement, _: *void, window: *Window, cx: *App) void {
            rl.prepaint(window, cx);
        }
        pub fn paint(_: *@This(), _: ?GlobalElementId, _: Bounds, rl: *AnyElement, _: *void, window: *Window, cx: *App) void {
            rl.paint(window, cx);
        }
    };
}
