//! The element protocol (gpui `element.rs`): ids, the `Drawable` phase machine, `AnyElement`
//! type erasure and `IntoElement` conversion.
//!
//! An element type `E` is a struct with:
//!
//! ```zig
//! pub const RequestLayoutState = S1;   // optional, default void
//! pub const PrepaintState = S2;        // optional, default void
//! pub fn elementId(self: *E) ?ElementId                       // optional
//! pub fn requestLayout(self: *E, id: ?GlobalElementId, state: *S1, window: *Window, cx: *App) LayoutId
//! pub fn prepaint(self: *E, id: ?GlobalElementId, bounds: Bounds, rl: *S1, state: *S2, window: *Window, cx: *App) void
//! pub fn paint(self: *E, id: ?GlobalElementId, bounds: Bounds, rl: *S1, pp: *S2, window: *Window, cx: *App) void
//! pub fn deinit(self: *E) void                               // optional, at arena clear
//! ```
//!
//! The window drives every element through request layout → prepaint → paint exactly once
//! per frame (calling out of order panics, like gpui). Elements, their states and the
//! `Drawable` wrapper live in the window's per-frame element arena.

const std = @import("std");
const geometry = @import("../geometry.zig");
const layout = @import("../layout/layout.zig");
const App = @import("../app/app.zig").App;
const EntityId = @import("../app/entity.zig").EntityId;
const dispatch_tree = @import("../app/dispatch_tree.zig");
const type_id = @import("../app/type_id.zig");
const arena_mod = @import("arena.zig");
const window_mod = @import("window.zig");
const Window = window_mod.Window;

pub const Pixels = geometry.Pixels;
pub const Point = geometry.Point(Pixels);
pub const Size = geometry.Size(Pixels);
pub const Bounds = geometry.Bounds(Pixels);
pub const LayoutId = layout.NodeId;
pub const AvailableSpace = layout.AvailableSpace;
pub const DispatchNodeId = dispatch_tree.DispatchNodeId;

/// Identifies an element among its siblings so its state persists across frames
/// (gpui `ElementId`). Build with `ElementId.from("name")`, `.from(42)`, `.from(.{ "row", ix })`.
pub const ElementId = union(enum) {
    name: []const u8,
    integer: u64,
    named_integer: struct { name: []const u8, index: u64 },
    view: EntityId,
    focus: u64,
    /// A precomputed hash (e.g. of a path or uuid).
    hash: u64,

    /// Converts strings, integers, `.{ name, index }` tuples, `EntityId`s and `ElementId`s.
    pub fn from(x: anytype) ElementId {
        const X = @TypeOf(x);
        if (X == ElementId) return x;
        if (X == EntityId) return .{ .view = x };
        if (X == @import("focus.zig").FocusId) return .{ .focus = @intFromEnum(x) };
        switch (@typeInfo(X)) {
            .int, .comptime_int => return .{ .integer = @intCast(x) },
            .pointer => |p| {
                if (p.size == .slice and p.child == u8) return .{ .name = x };
                if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) return .{ .name = x };
            },
            .@"struct" => |s| if (s.is_tuple and s.field_names.len == 2) {
                return .{ .named_integer = .{ .name = x[0], .index = @intCast(x[1]) } };
            },
            else => {},
        }
        @compileError("cannot convert " ++ @typeName(X) ++ " to ElementId");
    }

    /// Hash combined with the parent's global id.
    pub fn hashWith(self: ElementId, seed: u64) u64 {
        var h = std.hash.Wyhash.init(seed);
        const tag: u8 = @intFromEnum(std.meta.activeTag(self));
        h.update(&.{tag});
        switch (self) {
            .name => |n| h.update(n),
            .integer => |i| h.update(std.mem.asBytes(&i)),
            .named_integer => |ni| {
                h.update(ni.name);
                h.update(std.mem.asBytes(&ni.index));
            },
            .view => |v| h.update(std.mem.asBytes(&v)),
            .focus => |f| h.update(std.mem.asBytes(&f)),
            .hash => |v| h.update(std.mem.asBytes(&v)),
        }
        return h.final();
    }
};

/// The path of element ids from the root, hashed (gpui `GlobalElementId`). Keys element
/// state, scroll offsets, focus handles of focusable divs, etc.
pub const GlobalElementId = enum(u64) {
    _,
    pub fn toKey(self: GlobalElementId) u64 {
        return @intFromEnum(self);
    }
};

/// True if `T` implements the element protocol.
pub fn isElement(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "requestLayout") and @hasDecl(T, "prepaint") and @hasDecl(T, "paint");
}

fn StateOf(comptime E: type, comptime name: []const u8) type {
    return if (@hasDecl(E, name)) @field(E, name) else void;
}

fn hasDeinit(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasDecl(T, "deinit") and @TypeOf(T.deinit) != void,
        else => false,
    };
}

const Phase = enum { start, request_layout, layout_computed, prepaint, painted };

/// gpui `Drawable<E>`: an element plus its draw-phase state.
pub fn Drawable(comptime E: type) type {
    comptime {
        if (!isElement(E)) @compileError(@typeName(E) ++ " is not an element: needs requestLayout/prepaint/paint");
    }
    const RL = StateOf(E, "RequestLayoutState");
    const PP = StateOf(E, "PrepaintState");
    return struct {
        const Self = @This();

        element: E,
        phase: Phase = .start,
        layout_id: LayoutId = undefined,
        global_id: ?GlobalElementId = null,
        available: layout.Dims(AvailableSpace) = undefined,
        node_id: DispatchNodeId = undefined,
        bounds: Bounds = undefined,
        rl: RL = undefined,
        pp: PP = undefined,

        pub const needs_deinit = hasDeinit(E) or hasDeinit(RL) or hasDeinit(PP);

        pub const vtable: AnyElement.VTable = .{
            .request_layout = vRequestLayout,
            .prepaint = vPrepaint,
            .paint = vPaint,
            .layout_as_root = vLayoutAsRoot,
            .type_id = type_id.typeId(E),
            .type_name = @typeName(E),
        };

        fn cast(p: *anyopaque) *Self {
            return @ptrCast(@alignCast(p));
        }

        fn elementId(self: *Self) ?ElementId {
            if (comptime @hasDecl(E, "elementId")) return self.element.elementId();
            return null;
        }

        pub fn deinitErased(p: *anyopaque) void {
            const self = cast(p);
            if (comptime hasDeinit(PP)) if (@intFromEnum(self.phase) >= @intFromEnum(Phase.prepaint)) self.pp.deinit();
            if (comptime hasDeinit(RL)) if (self.phase != .start) self.rl.deinit();
            if (comptime hasDeinit(E)) self.element.deinit();
        }

        fn vRequestLayout(p: *anyopaque, window: *Window, cx: *App) LayoutId {
            const self = cast(p);
            if (self.phase != .start) std.debug.panic("{s}: request_layout called twice", .{@typeName(E)});
            const eid = self.elementId();
            if (eid) |id| self.global_id = window.pushElementId(id);
            defer if (eid != null) window.popElementId();
            if (RL != void) self.rl = undefined;
            self.layout_id = self.element.requestLayout(self.global_id, &self.rl, window, cx);
            self.phase = .request_layout;
            return self.layout_id;
        }

        fn vPrepaint(p: *anyopaque, window: *Window, cx: *App) void {
            const self = cast(p);
            switch (self.phase) {
                .request_layout, .layout_computed => {},
                else => std.debug.panic("{s}: prepaint called before request_layout or twice", .{@typeName(E)}),
            }
            const eid = self.elementId();
            if (eid) |id| _ = window.pushElementId(id);
            defer if (eid != null) window.popElementId();
            self.bounds = window.layoutBounds(self.layout_id);
            self.node_id = window.next_frame.dispatch_tree.pushNode() catch @panic("OOM");
            self.element.prepaint(self.global_id, self.bounds, &self.rl, &self.pp, window, cx);
            window.next_frame.dispatch_tree.popNode();
            self.phase = .prepaint;
        }

        fn vPaint(p: *anyopaque, window: *Window, cx: *App) void {
            const self = cast(p);
            if (self.phase != .prepaint) std.debug.panic("{s}: paint called before prepaint or twice", .{@typeName(E)});
            const eid = self.elementId();
            if (eid) |id| _ = window.pushElementId(id);
            defer if (eid != null) window.popElementId();
            window.next_frame.dispatch_tree.setActiveNode(self.node_id) catch @panic("OOM");
            self.element.paint(self.global_id, self.bounds, &self.rl, &self.pp, window, cx);
            self.phase = .painted;
        }

        fn vLayoutAsRoot(p: *anyopaque, available: layout.Dims(AvailableSpace), window: *Window, cx: *App) Size {
            const self = cast(p);
            if (self.phase == .start) _ = vRequestLayout(p, window, cx);
            switch (self.phase) {
                .request_layout => {
                    window.computeLayout(self.layout_id, available);
                    self.available = available;
                    self.phase = .layout_computed;
                },
                .layout_computed => if (!availEql(self.available, available)) {
                    window.computeLayout(self.layout_id, available);
                    self.available = available;
                },
                else => std.debug.panic("{s}: cannot layout after prepaint", .{@typeName(E)}),
            }
            return window.layoutBounds(self.layout_id).size;
        }
    };
}

fn availEql(a: layout.Dims(AvailableSpace), b: layout.Dims(AvailableSpace)) bool {
    return a.width.eql(b.width) and a.height.eql(b.height);
}

/// A type-erased element allocated in the frame arena (gpui `AnyElement`).
pub const AnyElement = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request_layout: *const fn (*anyopaque, *Window, *App) LayoutId,
        prepaint: *const fn (*anyopaque, *Window, *App) void,
        paint: *const fn (*anyopaque, *Window, *App) void,
        layout_as_root: *const fn (*anyopaque, layout.Dims(AvailableSpace), *Window, *App) Size,
        type_id: type_id.TypeId,
        type_name: []const u8,
    };

    /// Box `element` (any element type) in the current element arena.
    pub fn new(element: anytype) AnyElement {
        const E = @TypeOf(element);
        const D = Drawable(E);
        const a = arena_mod.current();
        const d = a.allocator().create(D) catch @panic("OOM");
        d.* = .{ .element = element };
        if (D.needs_deinit) a.onClear(d, D.deinitErased);
        return .{ .ptr = d, .vtable = &D.vtable };
    }

    pub fn requestLayout(self: AnyElement, window: *Window, cx: *App) LayoutId {
        return self.vtable.request_layout(self.ptr, window, cx);
    }

    pub fn prepaint(self: AnyElement, window: *Window, cx: *App) void {
        self.vtable.prepaint(self.ptr, window, cx);
    }

    pub fn paint(self: AnyElement, window: *Window, cx: *App) void {
        self.vtable.paint(self.ptr, window, cx);
    }

    /// Lay this element out as the root of its own layout tree; returns its size.
    pub fn layoutAsRoot(self: AnyElement, available: layout.Dims(AvailableSpace), window: *Window, cx: *App) Size {
        return self.vtable.layout_as_root(self.ptr, available, window, cx);
    }

    /// Prepaint at an absolute window position (after layout).
    pub fn prepaintAt(self: AnyElement, origin: Point, window: *Window, cx: *App) void {
        window.pushAbsoluteElementOffset(origin);
        defer window.popElementOffset();
        self.prepaint(window, cx);
    }

    /// `layoutAsRoot` then `prepaintAt`.
    pub fn prepaintAsRoot(self: AnyElement, origin: Point, available: layout.Dims(AvailableSpace), window: *Window, cx: *App) void {
        _ = self.layoutAsRoot(available, window, cx);
        self.prepaintAt(origin, window, cx);
    }

    /// The wrapped element if it is an `E`.
    pub fn downcast(self: AnyElement, comptime E: type) ?*E {
        if (self.vtable.type_id != type_id.typeId(E)) return null;
        return &@as(*Drawable(E), @ptrCast(@alignCast(self.ptr))).element;
    }

    pub fn intoAnyElement(self: AnyElement) AnyElement {
        return self;
    }
};

/// Available space presets.
pub const avail = struct {
    pub const min_content: layout.Dims(AvailableSpace) = .{ .width = .min_content, .height = .min_content };
    pub const max_content: layout.Dims(AvailableSpace) = .{ .width = .max_content, .height = .max_content };
    pub fn definite(size: Size) layout.Dims(AvailableSpace) {
        return .{ .width = .{ .definite = size.width }, .height = .{ .definite = size.height } };
    }
};

/// An element that takes no space and paints nothing (gpui `Empty`).
pub const Empty = struct {
    pub fn requestLayout(_: *Empty, _: ?GlobalElementId, _: *void, window: *Window, _: *App) LayoutId {
        return window.requestLayout(.{}, &.{});
    }
    pub fn prepaint(_: *Empty, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, _: *Window, _: *App) void {}
    pub fn paint(_: *Empty, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, _: *Window, _: *App) void {}
};

pub fn empty() AnyElement {
    return AnyElement.new(Empty{});
}

/// Convert anything element-like to an `AnyElement` (gpui `IntoElement::into_any_element`):
/// `AnyElement`, element types, values with `intoAnyElement()`, strings (text), views
/// (`Entity(T)` with a `render` method, `AnyView`), `RenderOnce` components (structs with
/// `render(self, *Window, *App)`), and optionals (null → empty).
pub fn intoAnyElement(x: anytype) AnyElement {
    const X = @TypeOf(x);
    if (X == AnyElement) return x;
    const view = @import("view.zig");
    const text = @import("../elements/text.zig");
    switch (@typeInfo(X)) {
        .optional => return if (x) |v| intoAnyElement(v) else empty(),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return text.Text.element(x);
            if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8) return text.Text.element(x);
        },
        .@"struct" => {
            if (@hasDecl(X, "intoAnyElement")) return x.intoAnyElement();
            if (comptime isElement(X)) return AnyElement.new(x);
            if (comptime view.isEntityView(X)) return view.AnyView.fromEntity(x).intoAnyElement();
            if (comptime view.isRenderOnce(X)) return view.component(x);
        },
        else => {},
    }
    @compileError("cannot convert " ++ @typeName(X) ++ " into an element");
}

/// A child list for container elements (gpui `ParentElement`). Allocated in the frame arena.
pub const Children = struct {
    items: std.ArrayList(AnyElement) = .empty,

    pub fn add(self: *Children, child: anytype) void {
        self.items.append(arena_mod.frameAllocator(), intoAnyElement(child)) catch @panic("OOM");
    }

    /// Add a tuple of element-likes or a slice of them.
    pub fn addMany(self: *Children, list: anytype) void {
        const L = @TypeOf(list);
        switch (@typeInfo(L)) {
            .@"struct" => |s| if (s.is_tuple) {
                inline for (0..s.field_names.len) |i| self.add(list[i]);
                return;
            },
            .pointer => |p| if (p.size == .slice or (p.size == .one and @typeInfo(p.child) == .array)) {
                for (list) |c| self.add(c);
                return;
            },
            else => {},
        }
        @compileError("children() takes a tuple or slice, got " ++ @typeName(L));
    }

    pub fn slice(self: *const Children) []AnyElement {
        return self.items.items;
    }
};

test "element ids hash by value" {
    const a = ElementId.from("save").hashWith(0);
    try std.testing.expectEqual(a, ElementId.from(@as([]const u8, "save")).hashWith(0));
    try std.testing.expect(a != ElementId.from("save").hashWith(1));
    try std.testing.expect(ElementId.from(3).hashWith(0) != ElementId.from(.{ "row", 3 }).hashWith(0));
}
