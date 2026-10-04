//! A pure-Zig flexbox/block layout engine replacing taffy for zpui.
//!
//! Nodes live in an index-based arena owned by `LayoutEngine` and are built bottom-up each frame
//! (`requestLayout` / `requestMeasuredLayout`), laid out with `computeLayout`, queried with
//! `layoutBounds`, and discarded with `clear` (which keeps capacity for the next frame).
//!
//! The algorithms follow taffy's structure: every node is sized through `computeNode`, which runs
//! in either "compute size" mode (measure only, results cached) or "perform layout" mode (also
//! positions the node's children).

const std = @import("std");
const geometry = @import("../geometry.zig");
const style_mod = @import("style.zig");
const flex = @import("flex.zig");
const block = @import("block.zig");

pub const Style = style_mod.Style;
pub const Dims = style_mod.Dims;
pub const Sides = style_mod.Sides;
pub const AvailableSpace = style_mod.AvailableSpace;
pub const Length = style_mod.Length;
pub const Dimension = style_mod.Dimension;
pub const LengthPercentage = style_mod.LengthPercentage;
pub const Display = style_mod.Display;
pub const Position = style_mod.Position;
pub const Overflow = style_mod.Overflow;
pub const OverflowXY = style_mod.OverflowXY;
pub const FlexDirection = style_mod.FlexDirection;
pub const FlexWrap = style_mod.FlexWrap;
pub const AlignItems = style_mod.AlignItems;
pub const AlignSelf = style_mod.AlignSelf;
pub const AlignContent = style_mod.AlignContent;
pub const JustifyContent = style_mod.JustifyContent;

const Point = geometry.Point(f32);
const Size = geometry.Size(f32);
const Bounds = geometry.Bounds(f32);

/// Handle to a node in a `LayoutEngine`. Valid until the next `clear`.
pub const NodeId = enum(u32) {
    _,

    pub fn index(self: NodeId) usize {
        return @backingInt(self);
    }
};

/// A node's computed border box, relative to its parent's border box.
pub const Layout = struct {
    location: Point = .zero,
    size: Size = .zero,
};

/// Measures a leaf with intrinsic size (text, images). `known` holds content-box dimensions the
/// layout already fixed; `available` is the space to fit into. Returns the content-box size.
pub const MeasureFn = *const fn (ctx: ?*anyopaque, known: Dims(?f32), available: Dims(AvailableSpace)) Size;

/// A measure callback plus its opaque context.
pub const Measure = struct {
    ctx: ?*anyopaque,
    func: MeasureFn,

    /// Wraps a typed callback `f(ctx, known, available)` into a type-erased `Measure`.
    pub fn init(
        comptime T: type,
        ctx: *T,
        comptime f: fn (*T, Dims(?f32), Dims(AvailableSpace)) Size,
    ) Measure {
        const Wrapper = struct {
            fn call(p: ?*anyopaque, known: Dims(?f32), available: Dims(AvailableSpace)) Size {
                return f(@ptrCast(@alignCast(p.?)), known, available);
            }
        };
        return .{ .ctx = ctx, .func = Wrapper.call };
    }
};

/// Whether a node computation must position children or only report a size.
pub const RunMode = enum { perform_layout, compute_size };

/// `inherent_size` applies the node's own size styles; `content_size` ignores them (the caller
/// has already accounted for them).
pub const SizingMode = enum { inherent_size, content_size };

/// Inputs to a single node computation.
pub const Input = struct {
    run_mode: RunMode,
    sizing_mode: SizingMode,
    /// Border-box dimensions fixed by the parent.
    known: Dims(?f32),
    /// The parent's content box, for resolving percentages.
    parent_size: Dims(?f32),
    available: Dims(AvailableSpace),

    fn eqlKey(a: Input, b: Input) bool {
        return a.sizing_mode == b.sizing_mode and
            a.known.width == b.known.width and a.known.height == b.known.height and
            a.parent_size.width == b.parent_size.width and a.parent_size.height == b.parent_size.height and
            a.available.width.eql(b.available.width) and a.available.height.eql(b.available.height);
    }
};

const cache_slots = 8;

const CacheEntry = struct { input: Input, size: Size };

/// Per-node memo of computed sizes, valid for the lifetime of the node (styles are immutable).
const Cache = struct {
    sizes: [cache_slots]CacheEntry = undefined,
    len: u8 = 0,
    next: u8 = 0,
    final: ?CacheEntry = null,

    fn get(self: *const Cache, input: Input) ?Size {
        if (self.final) |f| if (f.input.eqlKey(input)) return f.size;
        if (input.run_mode == .perform_layout) return null;
        for (self.sizes[0..self.len]) |e| if (e.input.eqlKey(input)) return e.size;
        return null;
    }

    fn put(self: *Cache, input: Input, size: Size) void {
        const entry: CacheEntry = .{ .input = input, .size = size };
        if (input.run_mode == .perform_layout) {
            self.final = entry;
            return;
        }
        self.sizes[self.next] = entry;
        self.next = (self.next + 1) % cache_slots;
        if (self.len < cache_slots) self.len += 1;
    }
};

const no_parent = std.math.maxInt(u32);

const Node = struct {
    style: Style,
    first_child: u32,
    child_count: u32,
    parent: u32 = no_parent,
    measure: ?Measure,
    layout: Layout = .{},
    abs_origin: Point = .zero,
    abs_generation: u32 = 0,
    cache: Cache = .{},
};

/// Owns all layout nodes for a frame. See the file doc comment for the lifecycle.
pub const LayoutEngine = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Node) = .empty,
    child_ids: std.ArrayList(NodeId) = .empty,
    /// Scratch stacks for the flex algorithm; capacity is reserved up front so slices stay valid
    /// across recursion.
    flex_items: std.ArrayList(flex.Item) = .empty,
    flex_lines: std.ArrayList(flex.Line) = .empty,
    generation: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) LayoutEngine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LayoutEngine) void {
        self.nodes.deinit(self.allocator);
        self.child_ids.deinit(self.allocator);
        self.flex_items.deinit(self.allocator);
        self.flex_lines.deinit(self.allocator);
        self.* = undefined;
    }

    /// Drops every node, keeping allocated capacity for reuse next frame.
    pub fn clear(self: *LayoutEngine) void {
        self.nodes.clearRetainingCapacity();
        self.child_ids.clearRetainingCapacity();
        self.generation +%= 1;
    }

    /// Adds a node with the given children. Each child must not already have a parent.
    pub fn requestLayout(self: *LayoutEngine, style: Style, child_nodes: []const NodeId) !NodeId {
        return self.addNode(style, null, child_nodes);
    }

    /// Adds a leaf whose content size comes from `measure`.
    pub fn requestMeasuredLayout(self: *LayoutEngine, style: Style, measure: Measure) !NodeId {
        return self.addNode(style, measure, &.{});
    }

    fn addNode(self: *LayoutEngine, style: Style, measure: ?Measure, child_nodes: []const NodeId) !NodeId {
        try self.nodes.ensureUnusedCapacity(self.allocator, 1);
        const first: u32 = @intCast(self.child_ids.items.len);
        try self.child_ids.appendSlice(self.allocator, child_nodes);
        const id: NodeId = @fromBackingInt(@intCast(self.nodes.items.len));
        for (child_nodes) |c| {
            std.debug.assert(self.nodes.items[c.index()].parent == no_parent);
            self.nodes.items[c.index()].parent = @backingInt(id);
        }
        self.nodes.appendAssumeCapacity(.{
            .style = style,
            .first_child = first,
            .child_count = @intCast(child_nodes.len),
            .measure = measure,
        });
        return id;
    }

    /// Returns the style a node was created with.
    pub fn getStyle(self: *const LayoutEngine, id: NodeId) *const Style {
        return &self.nodes.items[id.index()].style;
    }

    /// Returns a node's children in order.
    pub fn children(self: *const LayoutEngine, id: NodeId) []const NodeId {
        const n = &self.nodes.items[id.index()];
        return self.child_ids.items[n.first_child..][0..n.child_count];
    }

    /// Returns a node's parent, if any.
    pub fn parent(self: *const LayoutEngine, id: NodeId) ?NodeId {
        const p = self.nodes.items[id.index()].parent;
        return if (p == no_parent) null else @fromBackingInt(@intCast(p));
    }

    /// Treats `auto` width/height of `id` as `size`, like gpui does for window roots.
    pub fn stretchAutoSizeToFill(self: *LayoutEngine, id: NodeId, size: Size) void {
        const n = &self.nodes.items[id.index()];
        if (n.style.size.width == .auto) n.style.size.width = .{ .px = size.width };
        if (n.style.size.height == .auto) n.style.size.height = .{ .px = size.height };
        n.cache = .{};
    }

    /// Lays out the tree rooted at `root` within `available` space.
    pub fn computeLayout(self: *LayoutEngine, root: NodeId, available: Dims(AvailableSpace)) !void {
        const count = self.nodes.items.len;
        try self.flex_items.ensureTotalCapacity(self.allocator, count);
        try self.flex_lines.ensureTotalCapacity(self.allocator, count);
        self.generation +%= 1;

        const n = self.node(root);
        const style = &n.style;
        const parent_size: Dims(?f32) = .{ .width = available.width.toOption(), .height = available.height.toOption() };
        var known: Dims(?f32) = .all(null);
        if (style.display == .block) {
            // Block roots stretch to fill definite available width, like taffy's root handling.
            const pb = style_mod.paddingBorder(style, parent_size.width).sum();
            const margin = style_mod.orZero(style_mod.resolveSidesOpt(style.margin, parent_size.width));
            const min = style_mod.applyAspectRatio(style_mod.resolveDims(style.min_size, parent_size), style.aspect_ratio);
            const max = style_mod.applyAspectRatio(style_mod.resolveDims(style.max_size, parent_size), style.aspect_ratio);
            const styled = style_mod.clampDims(style_mod.applyAspectRatio(style_mod.resolveDims(style.size, parent_size), style.aspect_ratio), min, max);
            known = .{
                .width = style_mod.maxOpt(styled.width orelse style_mod.subOpt(parent_size.width, margin.horizontal()), pb.width),
                .height = style_mod.maxOpt(styled.height, pb.height),
            };
        }
        const size = self.computeNode(root, .{
            .run_mode = .perform_layout,
            .sizing_mode = .inherent_size,
            .known = known,
            .parent_size = parent_size,
            .available = available,
        });
        self.setLayout(root, .zero, size);
    }

    /// Returns a node's border box relative to its parent (unrounded).
    pub fn layout(self: *const LayoutEngine, id: NodeId) Layout {
        return self.nodes.items[id.index()].layout;
    }

    /// Returns a node's border box in absolute coordinates (relative to its root's origin), the
    /// same semantics as gpui's `TaffyLayoutEngine::layout_bounds` (without device-pixel snapping).
    pub fn layoutBounds(self: *LayoutEngine, id: NodeId) Bounds {
        return .{ .origin = self.absoluteOrigin(id), .size = self.node(id).layout.size };
    }

    fn absoluteOrigin(self: *LayoutEngine, id: NodeId) Point {
        const n = self.node(id);
        if (n.abs_generation == self.generation) return n.abs_origin;
        const base: Point = if (n.parent == no_parent) .zero else self.absoluteOrigin(@fromBackingInt(@intCast(n.parent)));
        n.abs_origin = base.add(n.layout.location);
        n.abs_generation = self.generation;
        return n.abs_origin;
    }

    // ---- Internal interface used by the layout algorithms ----

    /// Returns a pointer to a node. Stable during `computeLayout` (the arena does not grow).
    pub fn node(self: *LayoutEngine, id: NodeId) *Node {
        return &self.nodes.items[id.index()];
    }

    pub fn setLayout(self: *LayoutEngine, id: NodeId, location: Point, size: Size) void {
        self.node(id).layout = .{ .location = location, .size = size };
    }

    /// Sizes (and in perform mode, lays out) a node, consulting its cache.
    pub fn computeNode(self: *LayoutEngine, id: NodeId, input: Input) Size {
        const n = self.node(id);
        if (n.cache.get(input)) |s| return s;
        const size = self.computeUncached(id, input);
        self.node(id).cache.put(input, size);
        return size;
    }

    /// Measures a node without positioning its descendants.
    pub fn computeSize(self: *LayoutEngine, id: NodeId, known: Dims(?f32), parent_size: Dims(?f32), available: Dims(AvailableSpace), sizing_mode: SizingMode) Size {
        return self.computeNode(id, .{ .run_mode = .compute_size, .sizing_mode = sizing_mode, .known = known, .parent_size = parent_size, .available = available });
    }

    /// Fully lays out a child; the caller is responsible for `setLayout` on it.
    pub fn performLayout(self: *LayoutEngine, id: NodeId, known: Dims(?f32), parent_size: Dims(?f32), available: Dims(AvailableSpace), sizing_mode: SizingMode) Size {
        return self.computeNode(id, .{ .run_mode = .perform_layout, .sizing_mode = sizing_mode, .known = known, .parent_size = parent_size, .available = available });
    }

    /// Zeroes the layout of a `display: none` node and all of its descendants.
    pub fn hideSubtree(self: *LayoutEngine, id: NodeId) void {
        self.setLayout(id, .zero, .zero);
        for (self.children(id)) |c| self.hideSubtree(c);
    }

    fn computeUncached(self: *LayoutEngine, id: NodeId, input: Input) Size {
        const n = self.node(id);
        if (n.style.display == .none) {
            if (input.run_mode == .perform_layout) for (self.children(id)) |c| self.hideSubtree(c);
            return .zero;
        }
        if (n.child_count == 0) return computeLeaf(&n.style, n.measure, input);
        return switch (n.style.display) {
            .flex => flex.compute(self, id, input),
            .block => block.compute(self, id, input),
            .none => unreachable,
        };
    }
};

/// Sizes a childless node, calling its measure function if it has one.
fn computeLeaf(style: *const Style, measure: ?Measure, input: Input) Size {
    const s = style_mod;
    const parent = input.parent_size;
    const margin = s.orZero(s.resolveSidesOpt(style.margin, parent.width));
    const pb = s.paddingBorder(style, parent.width);
    const gutter = s.scrollbarGutter(style);
    var inset = pb;
    inset.right += gutter.width;
    inset.bottom += gutter.height;
    const inset_sum = inset.sum();

    var node_size = input.known;
    var min: Dims(?f32) = .all(null);
    var max: Dims(?f32) = .all(null);
    var ratio: ?f32 = null;
    if (input.sizing_mode == .inherent_size) {
        ratio = style.aspect_ratio;
        const styled = s.applyAspectRatio(s.resolveDims(style.size, parent), ratio);
        min = s.applyAspectRatio(s.resolveDims(style.min_size, parent), ratio);
        max = s.resolveDims(style.max_size, parent);
        node_size = .{ .width = input.known.width orelse styled.width, .height = input.known.height orelse styled.height };
    }

    if (input.run_mode == .compute_size) {
        if (node_size.width != null and node_size.height != null) {
            return .{
                .width = @max(s.clamp(node_size.width.?, min.width, max.width), pb.horizontal()),
                .height = @max(s.clamp(node_size.height.?, min.height, max.height), pb.vertical()),
            };
        }
    }

    const avail: Dims(AvailableSpace) = .{
        .width = leafAvailable(input.available.width, margin.horizontal(), input.known.width, node_size.width, min.width, max.width, inset_sum.width),
        .height = leafAvailable(input.available.height, margin.vertical(), input.known.height, node_size.height, min.height, max.height, inset_sum.height),
    };

    const measured: Size = if (measure) |m| m.func(m.ctx, .{
        .width = if (node_size.width) |w| @max(w - inset_sum.width, 0) else null,
        .height = if (node_size.height) |h| @max(h - inset_sum.height, 0) else null,
    }, avail) else .zero;

    const w = s.clamp(node_size.width orelse measured.width + inset_sum.width, min.width, max.width);
    var h = s.clamp(node_size.height orelse measured.height + inset_sum.height, min.height, max.height);
    if (ratio) |r| h = @max(h, w / r);
    return .{ .width = @max(w, pb.horizontal()), .height = @max(h, pb.vertical()) };
}

fn leafAvailable(avail: AvailableSpace, margin: f32, known: ?f32, node_size: ?f32, min: ?f32, max: ?f32, inset: f32) AvailableSpace {
    var a = avail.sub(margin);
    if (known) |k| a = .{ .definite = k };
    if (node_size) |k| a = .{ .definite = k };
    if (max) |k| a = .{ .definite = k };
    return switch (a) {
        .definite => |v| .{ .definite = style_mod.clamp(v, min, max) - inset },
        else => a,
    };
}

test {
    _ = style_mod;
    _ = @import("tests.zig");
}
