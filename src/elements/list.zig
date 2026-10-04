//! `list()` — a virtualized list of variable-height items (gpui `elements/list.rs`, including
//! the zui fork's tail reservation and negative-offset fixes).
//!
//! Only the items in the viewport (plus `overdraw` pixels above and below) are rendered and
//! laid out each frame. Item heights are measured on demand and cached in a balanced
//! prefix-sum tree (`ItemTree`, a treap standing in for gpui's `SumTree<ListItem>`), so
//! offset ↔ index queries, splices and remeasurement are O(log n).
//!
//! The scroll position is logical: `ListOffset{ item_ix, offset_in_item }`. Content inserted
//! or removed above the viewport (via `splice`) therefore does not move what you are looking
//! at (scroll anchoring), and items that change height re-anchor through `remeasureItems`.
//!
//! ```zig
//! // In the view:
//! self.transcript = zpui.ListState.init(cx.gpa(), messages.len, .bottom, px(320));
//! self.transcript.setFollowMode(.tail);           // chat: stick to the newest message
//! // deinit: self.transcript.release();
//!
//! // In render:
//! zpui.list(self.transcript, cx, Self.renderMessage).sizeFull()
//! fn renderMessage(self: *Chat, ix: usize, window: *Window, cx: *Context(Chat)) zpui.Div { ... }
//!
//! // When data changes:
//! self.transcript.splice(.{ .start = n, .end = n }, 1);   // appended one message
//! self.transcript.remeasureItems(.{ .start = n, .end = n + 1 }); // streaming grew it
//! ```
//!
//! The render callback is either entity-bound (`list(state, cx, f)` with
//! `f(*V, usize, *Window, *Context(V)) R`) or a plain function over a context value copied
//! into the frame arena (`list(state, ctx, f)` with `f(@TypeOf(ctx), usize, *Window, *App) R`).
//! `R` is anything `intoAnyElement` accepts. Items outside the viewport must not change
//! height without a `splice`/`remeasureItems`/`reset`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const refine = @import("../style/refine.zig");
const styled = @import("../styled.zig");
const zpui_styled = styled;
const layout = @import("../layout/layout.zig");
const App = @import("../app/app.zig").App;
const context_mod = @import("../app/context.zig");
const Context = context_mod.Context;
const Listener = context_mod.Listener;
const entity_mod = @import("../app/entity.zig");
const EntityId = entity_mod.EntityId;
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const Hitbox = window_mod.Hitbox;
const HitboxId = window_mod.HitboxId;
const DispatchPhase = window_mod.DispatchPhase;
const element = @import("../window/element.zig");
const AnyElement = element.AnyElement;
const ElementId = element.ElementId;
const GlobalElementId = element.GlobalElementId;
const LayoutId = element.LayoutId;
const AvailableSpace = element.AvailableSpace;
const arena_mod = @import("../window/arena.zig");
const input = @import("../input.zig");
const FocusHandle = @import("../window/focus.zig").FocusHandle;

const Pixels = geometry.Pixels;
const Point = geometry.Point(Pixels);
const Size = geometry.Size(Pixels);
const Bounds = geometry.Bounds(Pixels);
const Edges = geometry.Edges(Pixels);
const Style = style_mod.Style;
const StyleRefinement = style_mod.StyleRefinement;

/// A half-open index range.
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(self: Range) usize {
        return self.end -| self.start;
    }
    pub fn contains(self: Range, ix: usize) bool {
        return ix >= self.start and ix < self.end;
    }
};

/// Whether the list scrolls from the top (most lists) or from the bottom (chat logs:
/// initially shows the end, and stays at the end while scrolled to the bottom).
pub const ListAlignment = enum { top, bottom };

/// Whether the list keeps following new content at its end (gpui `FollowMode`).
pub const FollowMode = enum { normal, tail };

const FollowState = union(enum) {
    normal,
    tail: bool, // is_following

    fn isFollowing(self: FollowState) bool {
        return self == .tail and self.tail;
    }
    fn hasStoppedFollowing(self: FollowState) bool {
        return self == .tail and !self.tail;
    }
    fn startFollowing(self: *FollowState) void {
        if (self.* == .tail) self.* = .{ .tail = true };
    }
    fn stopFollowing(self: *FollowState) void {
        if (self.* == .tail) self.* = .{ .tail = false };
    }
};

/// A scroll event converted to the list's items (gpui `ListScrollEvent`).
pub const ListScrollEvent = struct {
    /// Items visible before the scroll was applied.
    visible_range: Range,
    count: usize,
    /// Whether the list has a logical scroll position (false when pinned to the bottom of a
    /// bottom-aligned list).
    is_scrolled: bool,
    is_following_tail: bool,
};

/// How the list element is sized during layout (gpui `ListSizingBehavior`).
pub const ListSizingBehavior = enum {
    /// Size to the items (up to the available height).
    infer,
    /// Sized purely by its style.
    auto,
};

/// How a uniform list's items are sized horizontally (gpui `ListHorizontalSizingBehavior`).
pub const ListHorizontalSizingBehavior = enum {
    /// Items are as wide as the list.
    fit_list,
    /// Items may be wider than the list (horizontal scrolling).
    unconstrained,
};

const MeasuringBehavior = union(enum) {
    /// Measure every item on the first layout (`measure` = already measured).
    measure: bool,
    /// Only measure what is rendered.
    visible,

    fn reset(self: *MeasuringBehavior) void {
        if (self.* == .measure) self.* = .{ .measure = false };
    }
};

/// A logical scroll position: an item and a pixel offset from its top.
pub const ListOffset = struct {
    item_ix: usize = 0,
    offset_in_item: Pixels = 0,
};

const PendingScroll = union(enum) {
    /// Keep the same pixel offset into the item after it is remeasured.
    absolute: struct { item_ix: usize, offset: Pixels },
    /// Keep the same fractional offset into the item after it is remeasured.
    proportional: struct { item_ix: usize, fraction: f32 },
};

const ScrollAnchor = enum { absolute, proportional };

/// See `ListState.setTailReservation`.
pub const TailReservation = struct {
    start: usize,
    inset: Pixels,
};

// ---------------------------------------------------------------------------------------
// Item tree (gpui SumTree<ListItem>)
// ---------------------------------------------------------------------------------------

const ListItem = struct {
    measured: bool = false,
    /// Measured size, or the size hint of an unmeasured item.
    size: ?Size = null,
    focus_handle: ?FocusHandle = null,

    fn unmeasured(hint: ?Size, focus: ?FocusHandle) ListItem {
        return .{ .measured = false, .size = hint, .focus_handle = focus };
    }
    fn measuredItem(size: Size, focus: ?FocusHandle) ListItem {
        return .{ .measured = true, .size = size, .focus_handle = focus };
    }
    /// gpui `ListItem::size`: only for measured items.
    fn measuredSize(self: ListItem) ?Size {
        return if (self.measured) self.size else null;
    }
    fn sizeHint(self: ListItem) ?Size {
        return self.size;
    }
    fn containsFocused(self: ListItem, window: *const Window) bool {
        const h = self.focus_handle orelse return false;
        return h.containsFocused(window);
    }
    fn summary(self: ListItem) Summary {
        return .{
            .count = 1,
            .rendered_count = @intFromBool(self.measured),
            .unrendered_count = @intFromBool(!self.measured),
            .height = if (self.size) |s| s.height else 0,
            .has_focus_handles = self.focus_handle != null,
            .has_unknown_height = !self.measured and self.size == null,
        };
    }
};

const Summary = struct {
    count: usize = 0,
    rendered_count: usize = 0,
    unrendered_count: usize = 0,
    height: Pixels = 0,
    has_focus_handles: bool = false,
    has_unknown_height: bool = false,

    fn add(a: Summary, b: Summary) Summary {
        return .{
            .count = a.count + b.count,
            .rendered_count = a.rendered_count + b.rendered_count,
            .unrendered_count = a.unrendered_count + b.unrendered_count,
            .height = a.height + b.height,
            .has_focus_handles = a.has_focus_handles or b.has_focus_handles,
            .has_unknown_height = a.has_unknown_height or b.has_unknown_height,
        };
    }
};

const Bias = enum { left, right };

/// An implicit-key treap over `ListItem`s with subtree summaries: the operations gpui's
/// list performs on its `SumTree` (seek by count/height, slice + extend = splice, summary of
/// a prefix or range) in O(log n) expected time.
const ItemTree = struct {
    const nil: u32 = std.math.maxInt(u32);

    const Node = struct {
        item: ListItem,
        prio: u32,
        left: u32 = nil,
        right: u32 = nil,
        sum: Summary = .{},
    };

    gpa: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    free_list: u32 = nil,
    root: u32 = nil,
    rng: u32 = 0x9e3779b9,

    fn deinit(self: *ItemTree) void {
        self.nodes.deinit(self.gpa);
    }

    fn summary(self: *const ItemTree) Summary {
        return self.sumOf(self.root);
    }

    fn count(self: *const ItemTree) usize {
        return self.summary().count;
    }

    fn sumOf(self: *const ItemTree, n: u32) Summary {
        return if (n == nil) .{} else self.nodes.items[n].sum;
    }

    fn nextPrio(self: *ItemTree) u32 {
        var x = self.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng = x;
        return x;
    }

    fn alloc(self: *ItemTree, item: ListItem) u32 {
        const prio = self.nextPrio();
        if (self.free_list != nil) {
            const n = self.free_list;
            self.free_list = self.nodes.items[n].left;
            self.nodes.items[n] = .{ .item = item, .prio = prio, .sum = item.summary() };
            return n;
        }
        self.nodes.append(self.gpa, .{ .item = item, .prio = prio, .sum = item.summary() }) catch @panic("OOM");
        return @intCast(self.nodes.items.len - 1);
    }

    fn freeSubtree(self: *ItemTree, n: u32) void {
        if (n == nil) return;
        const node = self.nodes.items[n];
        self.freeSubtree(node.left);
        self.freeSubtree(node.right);
        self.nodes.items[n].left = self.free_list;
        self.free_list = n;
    }

    fn pull(self: *ItemTree, n: u32) void {
        const node = &self.nodes.items[n];
        node.sum = self.sumOf(node.left).add(node.item.summary()).add(self.sumOf(node.right));
    }

    /// Split `n` into (first `k` items, rest).
    fn split(self: *ItemTree, n: u32, k: usize) [2]u32 {
        if (n == nil) return .{ nil, nil };
        const left_count = self.sumOf(self.nodes.items[n].left).count;
        if (k <= left_count) {
            const parts = self.split(self.nodes.items[n].left, k);
            self.nodes.items[n].left = parts[1];
            self.pull(n);
            return .{ parts[0], n };
        } else {
            const parts = self.split(self.nodes.items[n].right, k - left_count - 1);
            self.nodes.items[n].right = parts[0];
            self.pull(n);
            return .{ n, parts[1] };
        }
    }

    fn merge(self: *ItemTree, a: u32, b: u32) u32 {
        if (a == nil) return b;
        if (b == nil) return a;
        if (self.nodes.items[a].prio > self.nodes.items[b].prio) {
            const r = self.merge(self.nodes.items[a].right, b);
            self.nodes.items[a].right = r;
            self.pull(a);
            return a;
        } else {
            const l = self.merge(a, self.nodes.items[b].left);
            self.nodes.items[b].left = l;
            self.pull(b);
            return b;
        }
    }

    /// Build a treap of `items` in O(len) (Cartesian tree over random priorities).
    fn build(self: *ItemTree, items: []const ListItem) u32 {
        if (items.len == 0) return nil;
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(self.gpa);
        for (items) |it| {
            const x = self.alloc(it);
            var last: u32 = nil;
            while (stack.items.len > 0 and self.nodes.items[stack.items[stack.items.len - 1]].prio < self.nodes.items[x].prio) {
                last = stack.pop().?;
            }
            self.nodes.items[x].left = last;
            if (stack.items.len > 0) self.nodes.items[stack.items[stack.items.len - 1]].right = x;
            stack.append(self.gpa, x) catch @panic("OOM");
        }
        const root = stack.items[0];
        self.pullAll(root);
        return root;
    }

    fn pullAll(self: *ItemTree, n: u32) void {
        if (n == nil) return;
        self.pullAll(self.nodes.items[n].left);
        self.pullAll(self.nodes.items[n].right);
        self.pull(n);
    }

    /// Replace items `[start, end)` with `items`.
    fn replaceRange(self: *ItemTree, start: usize, end: usize, items: []const ListItem) void {
        const total = self.count();
        const s = @min(start, total);
        const e = @min(@max(end, s), total);
        const a = self.split(self.root, s);
        const b = self.split(a[1], e - s);
        self.freeSubtree(b[0]);
        const mid = self.build(items);
        self.root = self.merge(self.merge(a[0], mid), b[1]);
    }

    fn replaceAll(self: *ItemTree, items: []const ListItem) void {
        self.nodes.clearRetainingCapacity();
        self.free_list = nil;
        self.root = nil;
        self.root = self.build(items);
    }

    fn get(self: *const ItemTree, ix: usize) ?ListItem {
        var n = self.root;
        var k = ix;
        while (n != nil) {
            const node = self.nodes.items[n];
            const lc = self.sumOf(node.left).count;
            if (k < lc) {
                n = node.left;
            } else if (k == lc) {
                return node.item;
            } else {
                k -= lc + 1;
                n = node.right;
            }
        }
        return null;
    }

    fn set(self: *ItemTree, ix: usize, item: ListItem) void {
        self.setIn(self.root, ix, item);
    }

    fn setIn(self: *ItemTree, n: u32, k: usize, item: ListItem) void {
        if (n == nil) return;
        const node = self.nodes.items[n];
        const lc = self.sumOf(node.left).count;
        if (k < lc) {
            self.setIn(node.left, k, item);
        } else if (k == lc) {
            self.nodes.items[n].item = item;
        } else {
            self.setIn(node.right, k - lc - 1, item);
        }
        self.pull(n);
    }

    /// Summary of the first `k` items (gpui `cursor.summary(&Count(k), Bias::Right)`).
    fn prefix(self: *const ItemTree, k: usize) Summary {
        var acc: Summary = .{};
        var n = self.root;
        var rem = k;
        while (n != nil and rem > 0) {
            const node = self.nodes.items[n];
            const ls = self.sumOf(node.left);
            if (rem <= ls.count) {
                n = node.left;
            } else {
                acc = acc.add(ls).add(node.item.summary());
                rem -= ls.count + 1;
                n = node.right;
            }
        }
        return acc;
    }

    /// Summary of items `[a, b)`.
    fn rangeSummary(self: *const ItemTree, a: usize, b: usize) Summary {
        if (b <= a) return .{};
        return self.query(self.root, 0, a, b);
    }

    fn query(self: *const ItemTree, n: u32, base: usize, a: usize, b: usize) Summary {
        if (n == nil) return .{};
        const s = self.nodes.items[n].sum;
        const lo = base;
        const hi = base + s.count;
        if (b <= lo or a >= hi) return .{};
        if (a <= lo and hi <= b) return s;
        const node = self.nodes.items[n];
        const lc = self.sumOf(node.left).count;
        var acc = self.query(node.left, base, a, b);
        const mid = base + lc;
        if (mid >= a and mid < b) acc = acc.add(node.item.summary());
        return acc.add(self.query(node.right, mid + 1, a, b));
    }

    /// Seek to a pixel offset (gpui `cursor.seek(&Height(h), bias)`): returns the summary
    /// of the items before the item the cursor lands on. Items are skipped while their end
    /// is before `h` (or at `h`, with right bias).
    fn seekHeight(self: *const ItemTree, h: Pixels, bias: Bias) Summary {
        var acc: Summary = .{};
        var n = self.root;
        while (n != nil) {
            const node = self.nodes.items[n];
            const ls = self.sumOf(node.left);
            if (ls.count > 0 and skips(acc.height + ls.height, h, bias)) {
                acc = acc.add(ls);
                const own = node.item.summary();
                if (skips(acc.height + own.height, h, bias)) {
                    acc = acc.add(own);
                    n = node.right;
                } else return acc;
            } else if (ls.count > 0) {
                n = node.left;
            } else {
                const own = node.item.summary();
                if (skips(acc.height + own.height, h, bias)) {
                    acc = acc.add(own);
                    n = node.right;
                } else return acc;
            }
        }
        return acc;
    }

    fn skips(end: Pixels, target: Pixels, bias: Bias) bool {
        return end < target or (end == target and bias == .right);
    }

    /// Apply `f` to every item in place.
    fn mapAll(self: *ItemTree, ctx: anytype, comptime f: fn (@TypeOf(ctx), ListItem) ListItem) void {
        self.mapIn(self.root, ctx, f);
    }

    fn mapIn(self: *ItemTree, n: u32, ctx: anytype, comptime f: fn (@TypeOf(ctx), ListItem) ListItem) void {
        if (n == nil) return;
        self.mapIn(self.nodes.items[n].left, ctx, f);
        self.nodes.items[n].item = f(ctx, self.nodes.items[n].item);
        self.mapIn(self.nodes.items[n].right, ctx, f);
        self.pull(n);
    }

    /// Index of the first item whose focus handle contains the focus (gpui's
    /// `filter(has_focus_handles)` scan).
    fn findFocused(self: *const ItemTree, window: *const Window) ?usize {
        return self.findFocusedIn(self.root, 0, window);
    }

    fn findFocusedIn(self: *const ItemTree, n: u32, base: usize, window: *const Window) ?usize {
        if (n == nil) return null;
        const node = self.nodes.items[n];
        if (!node.sum.has_focus_handles) return null;
        if (self.findFocusedIn(node.left, base, window)) |ix| return ix;
        const lc = self.sumOf(node.left).count;
        if (node.item.containsFocused(window)) return base + lc;
        return self.findFocusedIn(node.right, base + lc + 1, window);
    }
};

// ---------------------------------------------------------------------------------------
// ListState
// ---------------------------------------------------------------------------------------

const StateInner = struct {
    gpa: Allocator,
    refs: u32 = 1,
    last_layout_bounds: ?Bounds = null,
    last_padding: ?Edges = null,
    items: ItemTree,
    logical_scroll_top: ?ListOffset = null,
    alignment: ListAlignment,
    overdraw: Pixels,
    reset: bool = false,
    scroll_handler: ?Listener(ListScrollEvent) = null,
    scrollbar_drag_start_height: ?Pixels = null,
    measuring_behavior: MeasuringBehavior = .visible,
    pending_scroll: ?PendingScroll = null,
    follow_state: FollowState = .normal,
    tail_reservation: ?TailReservation = null,
    tail_extra: Pixels = 0,
    /// Diagnostics: items rendered (render callback invoked) during the last layout pass.
    last_rendered_count: usize = 0,
    /// Diagnostics: items prepainted (laid out in the viewport) in the last frame.
    last_visible_count: usize = 0,
};

/// The list state your view holds on behalf of the `list` element (gpui `ListState`).
/// Reference counted: `init` in your view, `release` in `deinit` (`retain` for a second
/// owner). The list element keeps it alive while its listeners can still fire.
pub const ListState = struct {
    inner: *StateInner,

    /// A list of `item_count` unmeasured items. `overdraw` is how many pixels above and
    /// below the viewport are measured (not painted) to avoid pop-in while scrolling.
    pub fn init(gpa: Allocator, item_count: usize, align_to: ListAlignment, overdraw_px: Pixels) ListState {
        const s = gpa.create(StateInner) catch @panic("OOM");
        s.* = .{ .gpa = gpa, .items = .{ .gpa = gpa }, .alignment = align_to, .overdraw = overdraw_px };
        const self: ListState = .{ .inner = s };
        self.splice(.{ .start = 0, .end = 0 }, item_count);
        return self;
    }

    pub fn retain(self: ListState) ListState {
        self.inner.refs += 1;
        return self;
    }

    pub fn release(self: ListState) void {
        const s = self.inner;
        s.refs -= 1;
        if (s.refs == 0) {
            s.items.deinit();
            s.gpa.destroy(s);
        }
    }

    pub fn eql(a: ListState, b: ListState) bool {
        return a.inner == b.inner;
    }

    /// Reserve one viewport, less `inset`, from item `start` through the final item: the
    /// unused part becomes trailing space in the final item's box (zui fork). Recomputed
    /// from natural row heights during layout before scroll clamping, so it never creates
    /// a transient scrollable gap; appended rows consume it. Pass null to clear.
    pub fn setTailReservation(self: ListState, reservation: ?TailReservation) void {
        const s = self.inner;
        if (std.meta.eql(s.tail_reservation, reservation)) return;
        self.clearTailExtra();
        s.tail_reservation = reservation;
    }

    pub fn tailReservation(self: ListState) ?TailReservation {
        return self.inner.tail_reservation;
    }

    fn clearTailExtra(self: ListState) void {
        const s = self.inner;
        const n = s.items.count();
        if (s.tail_extra == 0 or n == 0) return;
        const last = n - 1;
        if (s.items.get(last)) |item| {
            var hint = item.sizeHint();
            if (hint) |*h| h.height = @max(h.height - s.tail_extra, 0);
            s.items.set(last, .unmeasured(hint, item.focus_handle));
        }
        s.tail_extra = 0;
    }

    /// Pixel offset of item `ix` in the measured height tree (including retained hints).
    pub fn offsetForItem(self: ListState, ix: usize) Pixels {
        return self.inner.items.prefix(ix).height;
    }

    /// Whether measured natural content has consumed the tail reservation.
    pub fn tailReservationFilled(self: ListState) bool {
        const s = self.inner;
        const tr = s.tail_reservation orelse return false;
        const vh = if (s.last_layout_bounds) |b| b.size.height else 0;
        const minimum = @max(vh - tr.inset, 0);
        const prefix_h = s.items.prefix(tr.start).height;
        return s.items.summary().height - s.tail_extra - prefix_h >= minimum;
    }

    /// Measure every item on the first layout (accurate scrollbar from the start).
    pub fn measureAll(self: ListState) ListState {
        self.inner.measuring_behavior = .{ .measure = false };
        return self;
    }

    /// Give every unmeasured item a height hint so the scrollbar is sized from the first
    /// frame; real heights replace the hints as items render.
    pub fn withUniformItemHeight(self: ListState, height: Pixels) ListState {
        self.applyUniformItemHeight(height);
        return self;
    }

    /// Forget all items and the scroll position; `element_count` new unmeasured items.
    /// Scroll events are dropped until the next paint.
    pub fn reset(self: ListState, element_count: usize) void {
        const s = self.inner;
        s.reset = true;
        s.measuring_behavior.reset();
        s.logical_scroll_top = null;
        s.pending_scroll = null;
        s.scrollbar_drag_start_height = null;
        const old = s.items.count();
        self.splice(.{ .start = 0, .end = old }, element_count);
    }

    /// `reset` plus a uniform height hint.
    pub fn resetWithUniformHeight(self: ListState, element_count: usize, height: Pixels) void {
        self.reset(element_count);
        self.applyUniformItemHeight(height);
    }

    fn applyUniformItemHeight(self: ListState, height: Pixels) void {
        self.inner.items.mapAll(height, struct {
            fn f(h: Pixels, item: ListItem) ListItem {
                return .unmeasured(item.sizeHint() orelse Size{ .width = 0, .height = h }, item.focus_handle);
            }
        }.f);
    }

    /// Remeasure all items, keeping the proportional position within the top item (e.g.
    /// after a font size change).
    pub fn remeasure(self: ListState) void {
        self.remeasureWithAnchor(.{ .start = 0, .end = self.itemCount() }, .proportional);
    }

    /// Mark items in `range` for remeasurement, keeping the pixel offset into the top item
    /// (streaming text, results loading). Does not change the item count.
    pub fn remeasureItems(self: ListState, range: Range) void {
        self.remeasureWithAnchor(range, .absolute);
    }

    fn remeasureWithAnchor(self: ListState, range: Range, anchor: ScrollAnchor) void {
        const s = self.inner;
        if (s.logical_scroll_top) |st| if (range.contains(st.item_ix)) {
            s.pending_scroll = switch (anchor) {
                .absolute => .{ .absolute = .{ .item_ix = st.item_ix, .offset = st.offset_in_item } },
                .proportional => blk: {
                    if (s.items.get(st.item_ix)) |item| if (item.measuredSize()) |size| {
                        const fraction: f32 = if (size.height > 0) std.math.clamp(st.offset_in_item / size.height, 0, 1) else 0;
                        break :blk .{ .proportional = .{ .item_ix = st.item_ix, .fraction = fraction } };
                    };
                    break :blk s.pending_scroll;
                },
            };
        };
        const n = s.items.count();
        const end = @min(range.end, n);
        var ix = @min(range.start, end);
        while (ix < end) : (ix += 1) {
            const item = s.items.get(ix).?;
            s.items.set(ix, .unmeasured(item.sizeHint(), item.focus_handle));
        }
        s.measuring_behavior.reset();
    }

    /// The number of items.
    pub fn itemCount(self: ListState) usize {
        return self.inner.items.count();
    }

    /// Whether the list is scrolled to its end; null if it is not scrollable or the total
    /// height is not known yet.
    pub fn isScrolledToEnd(self: ListState) ?bool {
        const s = self.inner;
        const b = s.last_layout_bounds orelse return null;
        const sum = s.items.summary();
        if (sum.has_unknown_height) return null;
        const p = s.last_padding orelse Edges.all(0);
        const content = sum.height + p.top + p.bottom;
        const scroll_max = @max(content - b.size.height, 0);
        if (scroll_max <= 0) return null;
        return scrollTop(s, logicalScrollTopOf(s)) >= scroll_max;
    }

    /// The items in `old_range` were replaced by `count` new items (gpui `splice`).
    pub fn splice(self: ListState, old_range: Range, new_count: usize) void {
        self.spliceImpl(old_range, new_count, null);
    }

    /// `splice` with a (non-owning) focus handle per new item: a focused item that scrolls
    /// out of view keeps rendering so keyboard interaction continues.
    pub fn spliceFocusable(self: ListState, old_range: Range, focus_handles: []const ?FocusHandle) void {
        self.spliceImpl(old_range, focus_handles.len, focus_handles);
    }

    fn spliceImpl(self: ListState, old_range: Range, new_count: usize, focus: ?[]const ?FocusHandle) void {
        self.clearTailExtra();
        const s = self.inner;
        const items = s.gpa.alloc(ListItem, new_count) catch @panic("OOM");
        defer s.gpa.free(items);
        for (items, 0..) |*it, i| it.* = .unmeasured(null, if (focus) |f| f[i] else null);
        s.items.replaceRange(old_range.start, old_range.end, items);
        if (s.logical_scroll_top) |*st| {
            if (old_range.contains(st.item_ix)) {
                st.item_ix = old_range.start;
                st.offset_in_item = 0;
            } else if (old_range.end <= st.item_ix) {
                st.item_ix = st.item_ix - old_range.len() + new_count;
            }
        }
    }

    /// Call `handler` when the user scrolls the list (`cx.listener(Self.onScroll)` with
    /// `fn onScroll(*Self, *const ListScrollEvent, *Window, *Context(Self)) void`).
    pub fn setScrollHandler(self: ListState, handler: anytype) void {
        self.inner.scroll_handler = Listener(ListScrollEvent).init(handler);
    }

    /// The current scroll position in terms of items.
    pub fn logicalScrollTop(self: ListState) ListOffset {
        return logicalScrollTopOf(self.inner);
    }

    /// Scroll by `distance` pixels (positive scrolls toward the end).
    pub fn scrollBy(self: ListState, distance: Pixels) void {
        if (distance == 0) return;
        const s = self.inner;
        const current = logicalScrollTopOf(s);
        if (distance < 0) s.follow_state.stopFollowing();
        var start_px = s.items.prefix(current.item_ix).height + current.offset_in_item;
        // Deviation from gpui: a list pinned past its end (bottom alignment / follow tail
        // report the item count as the scroll top) scrolls from the visible bottom, not from
        // the total height, so scrolling up from the end moves immediately.
        if (s.last_layout_bounds != null and (s.logical_scroll_top == null or current.item_ix >= s.items.count()))
            start_px = @min(start_px, maxScrollOffset(s) + (if (s.last_padding) |p| p.top + p.bottom else 0));
        const new_px = @max(start_px + distance, 0);
        const start = s.items.seekHeight(new_px, .right);
        const st: ListOffset = .{ .item_ix = start.count, .offset_in_item = new_px - start.height };
        rebasePendingScroll(s, st);
        s.logical_scroll_top = st;
    }

    /// Scroll past the last item: layout walks back from the end, so the bottom of the last
    /// item shows even while it grows.
    pub fn scrollToEnd(self: ListState) void {
        const s = self.inner;
        s.pending_scroll = null;
        s.logical_scroll_top = .{ .item_ix = s.items.count(), .offset_in_item = 0 };
    }

    /// `.tail`: snap to the end now, keep following new content, stop when the user
    /// scrolls up and resume when they scroll back to the bottom.
    pub fn setFollowMode(self: ListState, mode: FollowMode) void {
        const s = self.inner;
        switch (mode) {
            .normal => s.follow_state = .normal,
            .tail => {
                s.follow_state = .{ .tail = true };
                s.logical_scroll_top = .{ .item_ix = s.items.count(), .offset_in_item = 0 };
            },
        }
    }

    pub fn isFollowingTail(self: ListState) bool {
        return self.inner.follow_state.isFollowing();
    }

    /// Scroll to a logical position.
    pub fn scrollTo(self: ListState, offset: ListOffset) void {
        const s = self.inner;
        var st = offset;
        const n = s.items.count();
        if (st.item_ix >= n) st = .{ .item_ix = n, .offset_in_item = 0 };
        if (st.item_ix < n) s.follow_state.stopFollowing();
        rebasePendingScroll(s, st);
        s.logical_scroll_top = st;
    }

    /// Scroll minimally so item `ix` is fully visible.
    pub fn scrollToRevealItem(self: ListState, ix: usize) void {
        const s = self.inner;
        var st = logicalScrollTopOf(s);
        const height: Pixels = if (s.last_layout_bounds) |b| b.size.height else 0;
        const p = s.last_padding orelse Edges.all(0);
        if (ix <= st.item_ix) {
            st = .{ .item_ix = ix, .offset_in_item = 0 };
        } else {
            const bottom = s.items.prefix(ix + 1).height + p.top;
            const goal_top = @max(0, bottom - height + p.bottom);
            const start = s.items.seekHeight(goal_top, .left);
            if (start.count >= st.item_ix) {
                st = .{ .item_ix = start.count, .offset_in_item = goal_top - start.height };
            }
        }
        rebasePendingScroll(s, st);
        s.logical_scroll_top = st;
    }

    /// Window bounds of item `ix` if it is measured and at or after the scroll top.
    pub fn boundsForItem(self: ListState, ix: usize) ?Bounds {
        const s = self.inner;
        const b = s.last_layout_bounds orelse Bounds{ .origin = .zero, .size = .zero };
        const st = logicalScrollTopOf(s);
        if (ix < st.item_ix) return null;
        const scroll_px = s.items.prefix(st.item_ix).height + st.offset_in_item;
        const item = s.items.get(ix) orelse return null;
        const size = item.measuredSize() orelse return null;
        const top = b.origin.y + s.items.prefix(ix).height - scroll_px;
        return .{ .origin = .{ .x = b.origin.x, .y = top }, .size = .{ .width = b.size.width, .height = size.height } };
    }

    /// Call when the user starts dragging a scrollbar: freezes the content height reported
    /// to the scrollbar while overdraw items get measured.
    pub fn scrollbarDragStarted(self: ListState) void {
        self.inner.scrollbar_drag_start_height = self.inner.items.summary().height;
    }

    pub fn scrollbarDragEnded(self: ListState) void {
        self.inner.scrollbar_drag_start_height = null;
    }

    pub fn isScrollbarDragging(self: ListState) bool {
        return self.inner.scrollbar_drag_start_height != null;
    }

    /// Set the scroll position from a scrollbar (`point.y` ≤ 0, like `ScrollHandle`).
    pub fn setOffsetFromScrollbar(self: ListState, p: Point) void {
        const s = self.inner;
        const b = s.last_layout_bounds orelse return;
        const height = b.size.height;
        const pad = s.last_padding orelse Edges.all(0);
        const content_height = s.scrollbar_drag_start_height orelse s.items.summary().height;
        const scroll_max = @max(content_height + pad.top + pad.bottom - height, 0);
        const new_top = @min(@max(-p.y, 0), scroll_max);
        const dragged_to_end = scroll_max > 0 and new_top >= @max(scroll_max - 1, 0);
        if (dragged_to_end and s.follow_state == .tail) {
            s.follow_state = .{ .tail = true };
            s.pending_scroll = null;
            s.logical_scroll_top = .{ .item_ix = s.items.count(), .offset_in_item = 0 };
            return;
        }
        s.follow_state.stopFollowing();
        if (s.alignment == .bottom and new_top == scroll_max) {
            s.pending_scroll = null;
            s.logical_scroll_top = null;
        } else {
            const start = s.items.seekHeight(new_top, .right);
            const st: ListOffset = .{ .item_ix = start.count, .offset_in_item = new_top - start.height };
            rebasePendingScroll(s, st);
            s.logical_scroll_top = st;
        }
    }

    /// Maximum scroll offset by measured heights (frozen while a scrollbar drag is active).
    pub fn maxOffsetForScrollbar(self: ListState) Point {
        return .{ .x = 0, .y = maxScrollOffset(self.inner) };
    }

    /// Current scroll offset for a scrollbar (y ≤ 0).
    pub fn scrollPxOffsetForScrollbar(self: ListState) Point {
        const s = self.inner;
        if (s.logical_scroll_top == null and s.alignment == .bottom) return .{ .x = 0, .y = -maxScrollOffset(s) };
        const st = logicalScrollTopOf(s);
        return .{ .x = 0, .y = -(s.items.prefix(st.item_ix).height + st.offset_in_item) };
    }

    /// The viewport bounds from the last layout.
    pub fn viewportBounds(self: ListState) Bounds {
        return self.inner.last_layout_bounds orelse .{ .origin = .zero, .size = .zero };
    }

    /// Whether item `ix` is entirely above the viewport; null before layout.
    pub fn itemIsAboveViewport(self: ListState, ix: usize) ?bool {
        const vb = self.inner.last_layout_bounds orelse return null;
        if (ix < self.logicalScrollTop().item_ix) return true;
        const ib = self.boundsForItem(ix) orelse return null;
        return ib.bottom() <= vb.origin.y;
    }

    /// Whether item `ix` is entirely below the viewport; null before layout.
    pub fn itemIsBelowViewport(self: ListState, ix: usize) ?bool {
        const vb = self.inner.last_layout_bounds orelse return null;
        if (ix < self.logicalScrollTop().item_ix) return false;
        const ib = self.boundsForItem(ix) orelse return null;
        return ib.origin.y >= vb.bottom();
    }

    /// Total height of measured items plus hints (unmeasured items without hints count 0).
    pub fn contentHeight(self: ListState) Pixels {
        return self.inner.items.summary().height;
    }

    /// Number of measured items (diagnostics).
    pub fn measuredCount(self: ListState) usize {
        return self.inner.items.summary().rendered_count;
    }

    /// Items whose render callback ran during the last frame's layout (diagnostics: shows
    /// virtualization at work).
    pub fn lastRenderedCount(self: ListState) usize {
        return self.inner.last_rendered_count;
    }

    /// Items laid out in the viewport in the last frame.
    pub fn lastVisibleCount(self: ListState) usize {
        return self.inner.last_visible_count;
    }

    pub fn alignment(self: ListState) ListAlignment {
        return self.inner.alignment;
    }

    pub fn overdraw(self: ListState) Pixels {
        return self.inner.overdraw;
    }
};

fn logicalScrollTopOf(s: *const StateInner) ListOffset {
    return s.logical_scroll_top orelse switch (s.alignment) {
        .top => .{},
        .bottom => .{ .item_ix = s.items.count(), .offset_in_item = 0 },
    };
}

fn scrollTop(s: *const StateInner, lst: ListOffset) Pixels {
    return s.items.prefix(lst.item_ix).height + lst.offset_in_item;
}

fn maxScrollOffset(s: *const StateInner) Pixels {
    const vh: Pixels = if (s.last_layout_bounds) |b| b.size.height else 0;
    const height = s.scrollbar_drag_start_height orelse s.items.summary().height;
    return @max(height - vh, 0);
}

/// Re-anchor a pending remeasure adjustment onto a newly set scroll position so it clamps
/// to the remeasured item instead of reverting the scroll.
fn rebasePendingScroll(s: *StateInner, st: ListOffset) void {
    const pending = s.pending_scroll orelse return;
    s.pending_scroll = null;
    if (st.item_ix >= s.items.count()) return;
    s.pending_scroll = switch (pending) {
        .absolute => .{ .absolute = .{ .item_ix = st.item_ix, .offset = st.offset_in_item } },
        .proportional => blk: {
            const item = s.items.get(st.item_ix) orelse break :blk null;
            const size = item.sizeHint() orelse break :blk null;
            if (size.height <= 0) break :blk null;
            break :blk .{ .proportional = .{ .item_ix = st.item_ix, .fraction = std.math.clamp(st.offset_in_item / size.height, 0, 1) } };
        },
    };
}

fn visibleRange(s: *const StateInner, height: Pixels, st: ListOffset) Range {
    const start_y = s.items.prefix(st.item_ix).height + st.offset_in_item;
    const end = s.items.seekHeight(start_y + height, .left);
    return .{ .start = st.item_ix, .end = @min(end.count + 1, s.items.count()) };
}

fn scrollState(s: *StateInner, st: ListOffset, height: Pixels, delta: Point, view: EntityId, window: *Window, cx: *App) void {
    // Drop scroll events after a reset: no item heights to compute the new position.
    if (s.reset) return;
    const p = s.last_padding orelse Edges.all(0);
    const scroll_max = @max(s.items.summary().height + p.top + p.bottom - height, 0);
    const new_top = @min(@max(scrollTop(s, st) - delta.y, 0), scroll_max);
    if (s.alignment == .bottom and new_top == scroll_max) {
        s.pending_scroll = null;
        s.logical_scroll_top = null;
    } else {
        const start = s.items.seekHeight(new_top, .right);
        const nst: ListOffset = .{ .item_ix = start.count, .offset_in_item = new_top - start.height };
        rebasePendingScroll(s, nst);
        s.logical_scroll_top = nst;
    }
    if (delta.y > 0) s.follow_state.stopFollowing();
    if (s.scroll_handler) |h| {
        const ev: ListScrollEvent = .{
            .visible_range = visibleRange(s, height, st),
            .count = s.items.count(),
            .is_scrolled = s.logical_scroll_top != null,
            .is_following_tail = s.follow_state.isFollowing(),
        };
        h.callIn(&ev, window, cx);
    }
    cx.notify(view);
}

// ---------------------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------------------

/// The item render callback: built by `list()` from an entity context or a plain context.
pub const RenderItem = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, ix: usize, window: *Window, cx: *App) AnyElement,

    pub fn call(self: RenderItem, ix: usize, window: *Window, cx: *App) AnyElement {
        return self.func(self.ctx, ix, window, cx);
    }

    /// `ctx` is `*Context(V)` (then `f(*V, usize, *Window, *Context(V)) R`, entity held
    /// weakly) or any value copied into the frame arena (then `f(@TypeOf(ctx), usize,
    /// *Window, *App) R`).
    pub fn init(ctx: anytype, comptime f: anytype) RenderItem {
        return .{ .ctx = boxCtx(ctx), .func = Thunk(@TypeOf(ctx), usize, f).call };
    }
};

/// True if `C` is `*Context(V)` / `*const Context(V)`.
pub fn isContextPtr(comptime C: type) bool {
    const info = @typeInfo(C);
    if (info != .pointer or info.pointer.size != .one) return false;
    const Child = info.pointer.child;
    if (@typeInfo(Child) != .@"struct" or !@hasDecl(Child, "Type")) return false;
    return Child == Context(Child.Type);
}

/// Box a callback context in the frame arena (entity contexts become their entity id).
pub fn boxCtx(ctx: anytype) *anyopaque {
    const C = @TypeOf(ctx);
    const a = arena_mod.current();
    if (comptime isContextPtr(C)) return @ptrCast(a.create(EntityId, ctx.entity_id));
    if (@sizeOf(C) == 0) return @ptrCast(a.create(u8, 0));
    return @ptrCast(a.create(C, ctx));
}

/// Calls `f` with a boxed context and an argument `Arg`, converting the result to
/// `AnyElement` (shared by `list` and `uniformList`).
pub fn Thunk(comptime C: type, comptime Arg: type, comptime f: anytype) type {
    return struct {
        pub fn call(p: *anyopaque, arg: Arg, w: *Window, a: *App) AnyElement {
            if (comptime isContextPtr(C)) {
                const V = @typeInfo(C).pointer.child.Type;
                const id: *const EntityId = @ptrCast(@alignCast(p));
                const weak: entity_mod.WeakEntity(V) = .{ .id = id.* };
                return weak.update(a, entityCall, .{ arg, w }) orelse element.empty();
            } else {
                const c: *C = @ptrCast(@alignCast(p));
                return element.intoAnyElement(f(c.*, arg, w, a));
            }
        }
        fn entityCall(v: anytype, arg: Arg, w: *Window, cx: anytype) AnyElement {
            return element.intoAnyElement(f(v, arg, w, cx));
        }
    };
}

const ItemLayout = struct {
    index: usize,
    element: AnyElement,
    size: Size,
};

const LayoutResponse = struct {
    max_item_width: Pixels,
    scroll_top: ListOffset,
    item_layouts: []ItemLayout,
};

/// A double-ended sequence in the frame arena (gpui's `VecDeque` in layout).
fn Deque(comptime T: type) type {
    return struct {
        const Self = @This();
        front: std.ArrayList(T) = .empty, // reversed
        back: std.ArrayList(T) = .empty,

        fn pushFront(self: *Self, v: T) void {
            self.front.append(arena_mod.frameAllocator(), v) catch @panic("OOM");
        }
        fn pushBack(self: *Self, v: T) void {
            self.back.append(arena_mod.frameAllocator(), v) catch @panic("OOM");
        }
        fn len(self: *const Self) usize {
            return self.front.items.len + self.back.items.len;
        }
        fn at(self: *Self, i: usize) *T {
            const nf = self.front.items.len;
            return if (i < nf) &self.front.items[nf - 1 - i] else &self.back.items[i - nf];
        }
        fn last(self: *Self) ?*T {
            const n = self.len();
            return if (n == 0) null else self.at(n - 1);
        }
        fn toSlice(self: *Self) []T {
            const out = arena_mod.frameAllocator().alloc(T, self.len()) catch @panic("OOM");
            for (out, 0..) |*o, i| o.* = self.at(i).*;
            return out;
        }
    };
}

fn itemSpace(width: ?Pixels) layout.Dims(AvailableSpace) {
    return .{
        .width = if (width) |w| .{ .definite = w } else .max_content,
        .height = .min_content,
    };
}

fn measureItem(s: *StateInner, render: RenderItem, ix: usize, space: layout.Dims(AvailableSpace), window: *Window, cx: *App) struct { AnyElement, Size } {
    s.last_rendered_count += 1;
    const el = render.call(ix, window, cx);
    const size = el.layoutAsRoot(space, window, cx);
    return .{ el, size };
}

fn layoutAllItems(s: *StateInner, width: Pixels, render: RenderItem, window: *Window, cx: *App) void {
    switch (s.measuring_behavior) {
        .visible => return,
        .measure => |done| if (done) return,
    }
    s.measuring_behavior = .{ .measure = true };
    const n = s.items.count();
    const space = itemSpace(width);
    var ix: usize = 0;
    while (ix < n) : (ix += 1) {
        const item = s.items.get(ix).?;
        const size = item.measuredSize() orelse measureItem(s, render, ix, space, window, cx)[1];
        s.items.set(ix, .measuredItem(size, item.focus_handle));
    }
}

fn reserveTail(
    s: *StateInner,
    measured_start: usize,
    measured: *Deque(ListItem),
    layouts: *Deque(ItemLayout),
    applied: *Pixels,
    viewport_height: Pixels,
) Pixels {
    const tr = s.tail_reservation orelse return 0;
    const minimum = @max(viewport_height - tr.inset, 0);
    const n = s.items.count();
    if (measured.len() == 0 or measured_start + measured.len() != n or tr.start >= n) return 0;
    const earlier = s.items.rangeSummary(tr.start, @max(measured_start, tr.start));
    // If a direct jump skipped unknown rows, let layout walk backward naturally first:
    // guessing zero for them would manufacture a gap.
    if (earlier.has_unknown_height) {
        s.tail_extra = 0;
        return 0;
    }
    var natural = earlier.height;
    for (0..measured.len()) |i| {
        if (measured_start + i >= tr.start) natural += measured.at(i).size.?.height;
    }
    natural -= applied.*;
    const extra = @max(minimum - natural, 0);
    const delta = extra - applied.*;
    if (measured.last()) |m| if (m.measured) {
        m.size.?.height += delta;
    };
    if (layouts.last()) |l| if (l.index + 1 == n) {
        l.size.height += delta;
    };
    applied.* = extra;
    s.tail_extra = extra;
    return delta;
}

fn layoutItems(
    s: *StateInner,
    available_width: ?Pixels,
    available_height: Pixels,
    padding: Edges,
    render: RenderItem,
    window: *Window,
    cx: *App,
) LayoutResponse {
    var measured: Deque(ListItem) = .{};
    var layouts: Deque(ItemLayout) = .{};
    var rendered_height: Pixels = padding.top;
    var max_item_width: Pixels = 0;
    var scroll_top = logicalScrollTopOf(s);
    const item_count = s.items.count();

    if (s.follow_state.isFollowing()) {
        scroll_top = .{ .item_ix = item_count, .offset_in_item = 0 };
        s.logical_scroll_top = scroll_top;
    }

    var rendered_focused_item = false;
    const space = itemSpace(available_width);

    // Render items after the scroll top, including the trailing overdraw.
    var ix: usize = scroll_top.item_ix;
    while (ix < item_count) : (ix += 1) {
        const item = s.items.get(ix).?;
        const visible_height = rendered_height - scroll_top.offset_in_item;
        if (visible_height >= available_height + s.overdraw) break;

        var size = item.measuredSize();
        // Render inside the visible area, when the height is unknown, and for the last row
        // while a tail reservation is active.
        if (visible_height < available_height or size == null or
            (s.tail_reservation != null and ix + 1 == item_count))
        {
            const el, const el_size = measureItem(s, render, ix, space, window, cx);
            size = el_size;
            // Apply a pending scroll adjustment for the (remeasured) scroll-top item.
            if (ix == scroll_top.item_ix) if (s.pending_scroll) |pending| {
                s.pending_scroll = null;
                switch (pending) {
                    .absolute => |a| if (a.item_ix == scroll_top.item_ix) {
                        scroll_top.offset_in_item = @min(a.offset, el_size.height);
                        s.logical_scroll_top = scroll_top;
                    },
                    .proportional => |p| if (p.item_ix == scroll_top.item_ix) {
                        scroll_top.offset_in_item = p.fraction * el_size.height;
                        s.logical_scroll_top = scroll_top;
                    },
                }
            };
            if (visible_height < available_height) {
                layouts.pushBack(.{ .index = ix, .element = el, .size = el_size });
                if (item.containsFocused(window)) rendered_focused_item = true;
            }
        }
        const sz = size.?;
        rendered_height += sz.height;
        max_item_width = @max(max_item_width, sz.width);
        measured.pushBack(.measuredItem(sz, item.focus_handle));
    }
    var applied_tail_extra: Pixels = 0;
    rendered_height += reserveTail(s, scroll_top.item_ix, &measured, &layouts, &applied_tail_extra, available_height);
    rendered_height += padding.bottom;

    // The cursor: walking upward from the scroll top.
    var cursor: usize = scroll_top.item_ix;

    // If the rendered items do not fill the viewport, move the scroll top up.
    if (rendered_height - scroll_top.offset_in_item < available_height) {
        while (rendered_height < available_height) {
            if (cursor == 0) break;
            cursor -= 1;
            const item = s.items.get(cursor).?;
            const el, const el_size = measureItem(s, render, cursor, space, window, cx);
            rendered_height += el_size.height;
            measured.pushFront(.measuredItem(el_size, item.focus_handle));
            layouts.pushFront(.{ .index = cursor, .element = el, .size = el_size });
            if (item.containsFocused(window)) rendered_focused_item = true;
        }
        rendered_height += reserveTail(s, cursor, &measured, &layouts, &applied_tail_extra, available_height);
        scroll_top = .{ .item_ix = cursor, .offset_in_item = rendered_height - available_height };
        switch (s.alignment) {
            .top => {
                scroll_top.offset_in_item = @max(scroll_top.offset_in_item, 0);
                s.logical_scroll_top = scroll_top;
            },
            .bottom => s.logical_scroll_top = null,
        }
    }

    // Measure items in the leading overdraw.
    var leading = scroll_top.offset_in_item;
    while (leading < s.overdraw) {
        if (cursor == 0) break;
        cursor -= 1;
        const item = s.items.get(cursor).?;
        const size = item.measuredSize() orelse measureItem(s, render, cursor, space, window, cx)[1];
        leading += size.height;
        measured.pushFront(.measuredItem(size, item.focus_handle));
    }

    // Write the measurements back.
    {
        const fa = arena_mod.frameAllocator();
        const tmp = fa.alloc(ListItem, measured.len()) catch @panic("OOM");
        for (tmp, 0..) |*t, i| t.* = measured.at(i).*;
        if (tmp.len > 0) s.items.replaceRange(cursor, cursor + tmp.len, tmp);
    }

    // Following was stopped by the user: resume once scrolled back to the bottom.
    if (s.follow_state.hasStoppedFollowing()) {
        const p = s.last_padding orelse Edges.all(0);
        const total = s.items.summary().height + p.top + p.bottom;
        if (scrollTop(s, scroll_top) + available_height >= total - 1) s.follow_state.startFollowing();
    }

    // Keep rendering an off-screen focused item so keyboard interaction continues.
    if (!rendered_focused_item) if (s.items.findFocused(window)) |fix| {
        const el, const size = measureItem(s, render, fix, space, window, cx);
        layouts.pushBack(.{ .index = fix, .element = el, .size = size });
    };

    return .{ .max_item_width = max_item_width, .scroll_top = scroll_top, .item_layouts = layouts.toSlice() };
}

const PrepaintResult = union(enum) { ok: LayoutResponse, retry: ListOffset };

fn prepaintItems(
    s: *StateInner,
    bounds: Bounds,
    padding: Edges,
    autoscroll: bool,
    render: RenderItem,
    window: *Window,
    cx: *App,
) PrepaintResult {
    // gpui `window.transact`: roll prepaint output back when an autoscroll asks to retry.
    const start_index = window.prepaintIndex();
    if (s.measuring_behavior == .measure and !s.measuring_behavior.measure) layoutAllItems(s, bounds.size.width, render, window, cx);
    var resp = layoutItems(s, bounds.size.width, bounds.size.height, padding, render, window, cx);
    // Ignore autoscroll requests from elements other than our children.
    _ = window.takeAutoscroll();
    if (bounds.size.height > padding.top + padding.bottom) {
        var origin: Point = .{ .x = bounds.origin.x, .y = bounds.origin.y + padding.top - resp.scroll_top.offset_in_item };
        const space = itemSpace(bounds.size.width);
        for (resp.item_layouts) |*item| {
            window.pushContentMask(.{ .bounds = bounds });
            item.element.prepaintAt(origin, window, cx);
            window.popContentMask(.{ .bounds = bounds });
            if (window.takeAutoscroll()) |ab| if (autoscroll) {
                if (ab.origin.y < bounds.origin.y) {
                    var item_ix = item.index;
                    var offset = ab.origin.y - origin.y;
                    // The requested top can sit above this item's own top: walk into
                    // earlier items so the offset stays non-negative.
                    while (offset < 0) {
                        if (item_ix == 0) {
                            offset = 0;
                            break;
                        }
                        item_ix -= 1;
                        const prev = s.items.get(item_ix).?;
                        const size = prev.measuredSize() orelse measureItem(s, render, item_ix, space, window, cx)[1];
                        offset += size.height;
                    }
                    window.truncatePrepaint(start_index);
                    return .{ .retry = .{ .item_ix = item_ix, .offset_in_item = offset } };
                } else if (ab.bottom() > bounds.bottom()) {
                    var c = item.index;
                    var height = bounds.size.height - padding.top - padding.bottom;
                    height -= ab.bottom() - origin.y;
                    while (height > 0) {
                        if (c == 0) break;
                        c -= 1;
                        const prev = s.items.get(c).?;
                        const size = prev.measuredSize() orelse measureItem(s, render, c, space, window, cx)[1];
                        height -= size.height;
                    }
                    window.truncatePrepaint(start_index);
                    return .{ .retry = .{ .item_ix = c, .offset_in_item = if (height < 0) -height else 0 } };
                }
            };
            origin.y += item.size.height;
        }
    } else {
        resp.item_layouts = &.{};
    }
    return .{ .ok = resp };
}

// ---------------------------------------------------------------------------------------
// The element
// ---------------------------------------------------------------------------------------

pub const ListData = struct {
    state: ListState,
    render_item: RenderItem,
    style: StyleRefinement = .{},
    sizing_behavior: ListSizingBehavior = .auto,
};

/// Construct a list element over `state` (see the file docs for the callback forms).
pub fn list(state: ListState, ctx: anytype, comptime render_item: anytype) List {
    const a = arena_mod.current();
    return .{ .d = a.create(ListData, .{ .state = state, .render_item = .init(ctx, render_item) }) };
}

/// The `list()` builder (a handle to arena data, like `Div`).
pub const List = struct {
    const Self = @This();
    d: *ListData,

    pub fn style(self: *Self) *StyleRefinement {
        return &self.d.style;
    }

    pub fn withSizingBehavior(self: Self, behavior: ListSizingBehavior) Self {
        self.d.sizing_behavior = behavior;
        return self;
    }

    pub fn intoAnyElement(self: Self) AnyElement {
        return AnyElement.new(ListElement{ .d = self.d });
    }

    // zpui:styled-forwarders begin(Self)
    const StyledMethods = zpui_styled.Styled(Self);
    const GeneratedStyledMethods = zpui_styled.Generated(Self);
    pub const textStyle = StyledMethods.textStyle;
    pub const block = StyledMethods.block;
    pub const flex = StyledMethods.flex;
    pub const hidden = StyledMethods.hidden;
    pub const scrollbarWidth = StyledMethods.scrollbarWidth;
    pub const overflowScroll = StyledMethods.overflowScroll;
    pub const overflowXScroll = StyledMethods.overflowXScroll;
    pub const overflowYScroll = StyledMethods.overflowYScroll;
    pub const whitespaceNormal = StyledMethods.whitespaceNormal;
    pub const whitespaceNowrap = StyledMethods.whitespaceNowrap;
    pub const textEllipsis = StyledMethods.textEllipsis;
    pub const textEllipsisStart = StyledMethods.textEllipsisStart;
    pub const textEllipsisMiddle = StyledMethods.textEllipsisMiddle;
    pub const textOverflow = StyledMethods.textOverflow;
    pub const textAlign = StyledMethods.textAlign;
    pub const textLeft = StyledMethods.textLeft;
    pub const textCenter = StyledMethods.textCenter;
    pub const textRight = StyledMethods.textRight;
    pub const truncate = StyledMethods.truncate;
    pub const lineClamp = StyledMethods.lineClamp;
    pub const flexCol = StyledMethods.flexCol;
    pub const flexColReverse = StyledMethods.flexColReverse;
    pub const flexRow = StyledMethods.flexRow;
    pub const flexRowReverse = StyledMethods.flexRowReverse;
    pub const flex1 = StyledMethods.flex1;
    pub const flexAuto = StyledMethods.flexAuto;
    pub const flexInitial = StyledMethods.flexInitial;
    pub const flexNone = StyledMethods.flexNone;
    pub const flexBasis = StyledMethods.flexBasis;
    pub const flexGrow = StyledMethods.flexGrow;
    pub const flexGrow0 = StyledMethods.flexGrow0;
    pub const flexGrow1 = StyledMethods.flexGrow1;
    pub const flexShrink = StyledMethods.flexShrink;
    pub const flexShrink0 = StyledMethods.flexShrink0;
    pub const flexShrink1 = StyledMethods.flexShrink1;
    pub const flexWrap = StyledMethods.flexWrap;
    pub const flexWrapReverse = StyledMethods.flexWrapReverse;
    pub const flexNowrap = StyledMethods.flexNowrap;
    pub const itemsStart = StyledMethods.itemsStart;
    pub const itemsEnd = StyledMethods.itemsEnd;
    pub const itemsCenter = StyledMethods.itemsCenter;
    pub const itemsBaseline = StyledMethods.itemsBaseline;
    pub const itemsStretch = StyledMethods.itemsStretch;
    pub const selfStart = StyledMethods.selfStart;
    pub const selfEnd = StyledMethods.selfEnd;
    pub const selfFlexStart = StyledMethods.selfFlexStart;
    pub const selfFlexEnd = StyledMethods.selfFlexEnd;
    pub const selfCenter = StyledMethods.selfCenter;
    pub const selfBaseline = StyledMethods.selfBaseline;
    pub const selfStretch = StyledMethods.selfStretch;
    pub const justifyStart = StyledMethods.justifyStart;
    pub const justifyEnd = StyledMethods.justifyEnd;
    pub const justifyCenter = StyledMethods.justifyCenter;
    pub const justifyBetween = StyledMethods.justifyBetween;
    pub const justifyAround = StyledMethods.justifyAround;
    pub const justifyEvenly = StyledMethods.justifyEvenly;
    pub const contentNormal = StyledMethods.contentNormal;
    pub const contentCenter = StyledMethods.contentCenter;
    pub const contentStart = StyledMethods.contentStart;
    pub const contentEnd = StyledMethods.contentEnd;
    pub const contentBetween = StyledMethods.contentBetween;
    pub const contentAround = StyledMethods.contentAround;
    pub const contentEvenly = StyledMethods.contentEvenly;
    pub const contentStretch = StyledMethods.contentStretch;
    pub const aspectRatio = StyledMethods.aspectRatio;
    pub const aspectSquare = StyledMethods.aspectSquare;
    pub const bg = StyledMethods.bg;
    pub const borderColor = StyledMethods.borderColor;
    pub const borderDashed = StyledMethods.borderDashed;
    pub const shadow = StyledMethods.shadow;
    pub const shadowNone = StyledMethods.shadowNone;
    pub const opacity = StyledMethods.opacity;
    pub const cursor = StyledMethods.cursor;
    pub const debug = StyledMethods.debug;
    pub const debugBelow = StyledMethods.debugBelow;
    pub const textColor = StyledMethods.textColor;
    pub const textBg = StyledMethods.textBg;
    pub const fontWeight = StyledMethods.fontWeight;
    pub const textSize = StyledMethods.textSize;
    pub const textXs = StyledMethods.textXs;
    pub const textSm = StyledMethods.textSm;
    pub const textBase = StyledMethods.textBase;
    pub const textLg = StyledMethods.textLg;
    pub const textXl = StyledMethods.textXl;
    pub const text2xl = StyledMethods.text2xl;
    pub const text3xl = StyledMethods.text3xl;
    pub const italic = StyledMethods.italic;
    pub const notItalic = StyledMethods.notItalic;
    pub const underline = StyledMethods.underline;
    pub const lineThrough = StyledMethods.lineThrough;
    pub const textDecorationNone = StyledMethods.textDecorationNone;
    pub const textDecorationColor = StyledMethods.textDecorationColor;
    pub const textDecorationSolid = StyledMethods.textDecorationSolid;
    pub const textDecorationWavy = StyledMethods.textDecorationWavy;
    pub const textDecoration0 = StyledMethods.textDecoration0;
    pub const textDecoration1 = StyledMethods.textDecoration1;
    pub const textDecoration2 = StyledMethods.textDecoration2;
    pub const textDecoration4 = StyledMethods.textDecoration4;
    pub const textDecoration8 = StyledMethods.textDecoration8;
    pub const fontFamily = StyledMethods.fontFamily;
    pub const fontFeatures = StyledMethods.fontFeatures;
    pub const font = StyledMethods.font;
    pub const lineHeight = StyledMethods.lineHeight;
    pub const w = GeneratedStyledMethods.w;
    pub const w0 = GeneratedStyledMethods.w0;
    pub const w0p5 = GeneratedStyledMethods.w0p5;
    pub const w1 = GeneratedStyledMethods.w1;
    pub const w1p5 = GeneratedStyledMethods.w1p5;
    pub const w2 = GeneratedStyledMethods.w2;
    pub const w2p5 = GeneratedStyledMethods.w2p5;
    pub const w3 = GeneratedStyledMethods.w3;
    pub const w3p5 = GeneratedStyledMethods.w3p5;
    pub const w4 = GeneratedStyledMethods.w4;
    pub const w5 = GeneratedStyledMethods.w5;
    pub const w6 = GeneratedStyledMethods.w6;
    pub const w7 = GeneratedStyledMethods.w7;
    pub const w8 = GeneratedStyledMethods.w8;
    pub const w9 = GeneratedStyledMethods.w9;
    pub const w10 = GeneratedStyledMethods.w10;
    pub const w11 = GeneratedStyledMethods.w11;
    pub const w12 = GeneratedStyledMethods.w12;
    pub const w16 = GeneratedStyledMethods.w16;
    pub const w20 = GeneratedStyledMethods.w20;
    pub const w24 = GeneratedStyledMethods.w24;
    pub const w32 = GeneratedStyledMethods.w32;
    pub const w40 = GeneratedStyledMethods.w40;
    pub const w48 = GeneratedStyledMethods.w48;
    pub const w56 = GeneratedStyledMethods.w56;
    pub const w64 = GeneratedStyledMethods.w64;
    pub const w72 = GeneratedStyledMethods.w72;
    pub const w80 = GeneratedStyledMethods.w80;
    pub const w96 = GeneratedStyledMethods.w96;
    pub const w112 = GeneratedStyledMethods.w112;
    pub const w128 = GeneratedStyledMethods.w128;
    pub const wAuto = GeneratedStyledMethods.wAuto;
    pub const wPx = GeneratedStyledMethods.wPx;
    pub const wFull = GeneratedStyledMethods.wFull;
    pub const w1_2 = GeneratedStyledMethods.w1_2;
    pub const w1_3 = GeneratedStyledMethods.w1_3;
    pub const w2_3 = GeneratedStyledMethods.w2_3;
    pub const w1_4 = GeneratedStyledMethods.w1_4;
    pub const w2_4 = GeneratedStyledMethods.w2_4;
    pub const w3_4 = GeneratedStyledMethods.w3_4;
    pub const w1_5 = GeneratedStyledMethods.w1_5;
    pub const w2_5 = GeneratedStyledMethods.w2_5;
    pub const w3_5 = GeneratedStyledMethods.w3_5;
    pub const w4_5 = GeneratedStyledMethods.w4_5;
    pub const w1_6 = GeneratedStyledMethods.w1_6;
    pub const w5_6 = GeneratedStyledMethods.w5_6;
    pub const w1_12 = GeneratedStyledMethods.w1_12;
    pub const h = GeneratedStyledMethods.h;
    pub const h0 = GeneratedStyledMethods.h0;
    pub const h0p5 = GeneratedStyledMethods.h0p5;
    pub const h1 = GeneratedStyledMethods.h1;
    pub const h1p5 = GeneratedStyledMethods.h1p5;
    pub const h2 = GeneratedStyledMethods.h2;
    pub const h2p5 = GeneratedStyledMethods.h2p5;
    pub const h3 = GeneratedStyledMethods.h3;
    pub const h3p5 = GeneratedStyledMethods.h3p5;
    pub const h4 = GeneratedStyledMethods.h4;
    pub const h5 = GeneratedStyledMethods.h5;
    pub const h6 = GeneratedStyledMethods.h6;
    pub const h7 = GeneratedStyledMethods.h7;
    pub const h8 = GeneratedStyledMethods.h8;
    pub const h9 = GeneratedStyledMethods.h9;
    pub const h10 = GeneratedStyledMethods.h10;
    pub const h11 = GeneratedStyledMethods.h11;
    pub const h12 = GeneratedStyledMethods.h12;
    pub const h16 = GeneratedStyledMethods.h16;
    pub const h20 = GeneratedStyledMethods.h20;
    pub const h24 = GeneratedStyledMethods.h24;
    pub const h32 = GeneratedStyledMethods.h32;
    pub const h40 = GeneratedStyledMethods.h40;
    pub const h48 = GeneratedStyledMethods.h48;
    pub const h56 = GeneratedStyledMethods.h56;
    pub const h64 = GeneratedStyledMethods.h64;
    pub const h72 = GeneratedStyledMethods.h72;
    pub const h80 = GeneratedStyledMethods.h80;
    pub const h96 = GeneratedStyledMethods.h96;
    pub const h112 = GeneratedStyledMethods.h112;
    pub const h128 = GeneratedStyledMethods.h128;
    pub const hAuto = GeneratedStyledMethods.hAuto;
    pub const hPx = GeneratedStyledMethods.hPx;
    pub const hFull = GeneratedStyledMethods.hFull;
    pub const h1_2 = GeneratedStyledMethods.h1_2;
    pub const h1_3 = GeneratedStyledMethods.h1_3;
    pub const h2_3 = GeneratedStyledMethods.h2_3;
    pub const h1_4 = GeneratedStyledMethods.h1_4;
    pub const h2_4 = GeneratedStyledMethods.h2_4;
    pub const h3_4 = GeneratedStyledMethods.h3_4;
    pub const h1_5 = GeneratedStyledMethods.h1_5;
    pub const h2_5 = GeneratedStyledMethods.h2_5;
    pub const h3_5 = GeneratedStyledMethods.h3_5;
    pub const h4_5 = GeneratedStyledMethods.h4_5;
    pub const h1_6 = GeneratedStyledMethods.h1_6;
    pub const h5_6 = GeneratedStyledMethods.h5_6;
    pub const h1_12 = GeneratedStyledMethods.h1_12;
    pub const size = GeneratedStyledMethods.size;
    pub const size0 = GeneratedStyledMethods.size0;
    pub const size0p5 = GeneratedStyledMethods.size0p5;
    pub const size1 = GeneratedStyledMethods.size1;
    pub const size1p5 = GeneratedStyledMethods.size1p5;
    pub const size2 = GeneratedStyledMethods.size2;
    pub const size2p5 = GeneratedStyledMethods.size2p5;
    pub const size3 = GeneratedStyledMethods.size3;
    pub const size3p5 = GeneratedStyledMethods.size3p5;
    pub const size4 = GeneratedStyledMethods.size4;
    pub const size5 = GeneratedStyledMethods.size5;
    pub const size6 = GeneratedStyledMethods.size6;
    pub const size7 = GeneratedStyledMethods.size7;
    pub const size8 = GeneratedStyledMethods.size8;
    pub const size9 = GeneratedStyledMethods.size9;
    pub const size10 = GeneratedStyledMethods.size10;
    pub const size11 = GeneratedStyledMethods.size11;
    pub const size12 = GeneratedStyledMethods.size12;
    pub const size16 = GeneratedStyledMethods.size16;
    pub const size20 = GeneratedStyledMethods.size20;
    pub const size24 = GeneratedStyledMethods.size24;
    pub const size32 = GeneratedStyledMethods.size32;
    pub const size40 = GeneratedStyledMethods.size40;
    pub const size48 = GeneratedStyledMethods.size48;
    pub const size56 = GeneratedStyledMethods.size56;
    pub const size64 = GeneratedStyledMethods.size64;
    pub const size72 = GeneratedStyledMethods.size72;
    pub const size80 = GeneratedStyledMethods.size80;
    pub const size96 = GeneratedStyledMethods.size96;
    pub const size112 = GeneratedStyledMethods.size112;
    pub const size128 = GeneratedStyledMethods.size128;
    pub const sizeAuto = GeneratedStyledMethods.sizeAuto;
    pub const sizePx = GeneratedStyledMethods.sizePx;
    pub const sizeFull = GeneratedStyledMethods.sizeFull;
    pub const size1_2 = GeneratedStyledMethods.size1_2;
    pub const size1_3 = GeneratedStyledMethods.size1_3;
    pub const size2_3 = GeneratedStyledMethods.size2_3;
    pub const size1_4 = GeneratedStyledMethods.size1_4;
    pub const size2_4 = GeneratedStyledMethods.size2_4;
    pub const size3_4 = GeneratedStyledMethods.size3_4;
    pub const size1_5 = GeneratedStyledMethods.size1_5;
    pub const size2_5 = GeneratedStyledMethods.size2_5;
    pub const size3_5 = GeneratedStyledMethods.size3_5;
    pub const size4_5 = GeneratedStyledMethods.size4_5;
    pub const size1_6 = GeneratedStyledMethods.size1_6;
    pub const size5_6 = GeneratedStyledMethods.size5_6;
    pub const size1_12 = GeneratedStyledMethods.size1_12;
    pub const minSize = GeneratedStyledMethods.minSize;
    pub const minSize0 = GeneratedStyledMethods.minSize0;
    pub const minSize0p5 = GeneratedStyledMethods.minSize0p5;
    pub const minSize1 = GeneratedStyledMethods.minSize1;
    pub const minSize1p5 = GeneratedStyledMethods.minSize1p5;
    pub const minSize2 = GeneratedStyledMethods.minSize2;
    pub const minSize2p5 = GeneratedStyledMethods.minSize2p5;
    pub const minSize3 = GeneratedStyledMethods.minSize3;
    pub const minSize3p5 = GeneratedStyledMethods.minSize3p5;
    pub const minSize4 = GeneratedStyledMethods.minSize4;
    pub const minSize5 = GeneratedStyledMethods.minSize5;
    pub const minSize6 = GeneratedStyledMethods.minSize6;
    pub const minSize7 = GeneratedStyledMethods.minSize7;
    pub const minSize8 = GeneratedStyledMethods.minSize8;
    pub const minSize9 = GeneratedStyledMethods.minSize9;
    pub const minSize10 = GeneratedStyledMethods.minSize10;
    pub const minSize11 = GeneratedStyledMethods.minSize11;
    pub const minSize12 = GeneratedStyledMethods.minSize12;
    pub const minSize16 = GeneratedStyledMethods.minSize16;
    pub const minSize20 = GeneratedStyledMethods.minSize20;
    pub const minSize24 = GeneratedStyledMethods.minSize24;
    pub const minSize32 = GeneratedStyledMethods.minSize32;
    pub const minSize40 = GeneratedStyledMethods.minSize40;
    pub const minSize48 = GeneratedStyledMethods.minSize48;
    pub const minSize56 = GeneratedStyledMethods.minSize56;
    pub const minSize64 = GeneratedStyledMethods.minSize64;
    pub const minSize72 = GeneratedStyledMethods.minSize72;
    pub const minSize80 = GeneratedStyledMethods.minSize80;
    pub const minSize96 = GeneratedStyledMethods.minSize96;
    pub const minSize112 = GeneratedStyledMethods.minSize112;
    pub const minSize128 = GeneratedStyledMethods.minSize128;
    pub const minSizeAuto = GeneratedStyledMethods.minSizeAuto;
    pub const minSizePx = GeneratedStyledMethods.minSizePx;
    pub const minSizeFull = GeneratedStyledMethods.minSizeFull;
    pub const minSize1_2 = GeneratedStyledMethods.minSize1_2;
    pub const minSize1_3 = GeneratedStyledMethods.minSize1_3;
    pub const minSize2_3 = GeneratedStyledMethods.minSize2_3;
    pub const minSize1_4 = GeneratedStyledMethods.minSize1_4;
    pub const minSize2_4 = GeneratedStyledMethods.minSize2_4;
    pub const minSize3_4 = GeneratedStyledMethods.minSize3_4;
    pub const minSize1_5 = GeneratedStyledMethods.minSize1_5;
    pub const minSize2_5 = GeneratedStyledMethods.minSize2_5;
    pub const minSize3_5 = GeneratedStyledMethods.minSize3_5;
    pub const minSize4_5 = GeneratedStyledMethods.minSize4_5;
    pub const minSize1_6 = GeneratedStyledMethods.minSize1_6;
    pub const minSize5_6 = GeneratedStyledMethods.minSize5_6;
    pub const minSize1_12 = GeneratedStyledMethods.minSize1_12;
    pub const minW = GeneratedStyledMethods.minW;
    pub const minW0 = GeneratedStyledMethods.minW0;
    pub const minW0p5 = GeneratedStyledMethods.minW0p5;
    pub const minW1 = GeneratedStyledMethods.minW1;
    pub const minW1p5 = GeneratedStyledMethods.minW1p5;
    pub const minW2 = GeneratedStyledMethods.minW2;
    pub const minW2p5 = GeneratedStyledMethods.minW2p5;
    pub const minW3 = GeneratedStyledMethods.minW3;
    pub const minW3p5 = GeneratedStyledMethods.minW3p5;
    pub const minW4 = GeneratedStyledMethods.minW4;
    pub const minW5 = GeneratedStyledMethods.minW5;
    pub const minW6 = GeneratedStyledMethods.minW6;
    pub const minW7 = GeneratedStyledMethods.minW7;
    pub const minW8 = GeneratedStyledMethods.minW8;
    pub const minW9 = GeneratedStyledMethods.minW9;
    pub const minW10 = GeneratedStyledMethods.minW10;
    pub const minW11 = GeneratedStyledMethods.minW11;
    pub const minW12 = GeneratedStyledMethods.minW12;
    pub const minW16 = GeneratedStyledMethods.minW16;
    pub const minW20 = GeneratedStyledMethods.minW20;
    pub const minW24 = GeneratedStyledMethods.minW24;
    pub const minW32 = GeneratedStyledMethods.minW32;
    pub const minW40 = GeneratedStyledMethods.minW40;
    pub const minW48 = GeneratedStyledMethods.minW48;
    pub const minW56 = GeneratedStyledMethods.minW56;
    pub const minW64 = GeneratedStyledMethods.minW64;
    pub const minW72 = GeneratedStyledMethods.minW72;
    pub const minW80 = GeneratedStyledMethods.minW80;
    pub const minW96 = GeneratedStyledMethods.minW96;
    pub const minW112 = GeneratedStyledMethods.minW112;
    pub const minW128 = GeneratedStyledMethods.minW128;
    pub const minWAuto = GeneratedStyledMethods.minWAuto;
    pub const minWPx = GeneratedStyledMethods.minWPx;
    pub const minWFull = GeneratedStyledMethods.minWFull;
    pub const minW1_2 = GeneratedStyledMethods.minW1_2;
    pub const minW1_3 = GeneratedStyledMethods.minW1_3;
    pub const minW2_3 = GeneratedStyledMethods.minW2_3;
    pub const minW1_4 = GeneratedStyledMethods.minW1_4;
    pub const minW2_4 = GeneratedStyledMethods.minW2_4;
    pub const minW3_4 = GeneratedStyledMethods.minW3_4;
    pub const minW1_5 = GeneratedStyledMethods.minW1_5;
    pub const minW2_5 = GeneratedStyledMethods.minW2_5;
    pub const minW3_5 = GeneratedStyledMethods.minW3_5;
    pub const minW4_5 = GeneratedStyledMethods.minW4_5;
    pub const minW1_6 = GeneratedStyledMethods.minW1_6;
    pub const minW5_6 = GeneratedStyledMethods.minW5_6;
    pub const minW1_12 = GeneratedStyledMethods.minW1_12;
    pub const minH = GeneratedStyledMethods.minH;
    pub const minH0 = GeneratedStyledMethods.minH0;
    pub const minH0p5 = GeneratedStyledMethods.minH0p5;
    pub const minH1 = GeneratedStyledMethods.minH1;
    pub const minH1p5 = GeneratedStyledMethods.minH1p5;
    pub const minH2 = GeneratedStyledMethods.minH2;
    pub const minH2p5 = GeneratedStyledMethods.minH2p5;
    pub const minH3 = GeneratedStyledMethods.minH3;
    pub const minH3p5 = GeneratedStyledMethods.minH3p5;
    pub const minH4 = GeneratedStyledMethods.minH4;
    pub const minH5 = GeneratedStyledMethods.minH5;
    pub const minH6 = GeneratedStyledMethods.minH6;
    pub const minH7 = GeneratedStyledMethods.minH7;
    pub const minH8 = GeneratedStyledMethods.minH8;
    pub const minH9 = GeneratedStyledMethods.minH9;
    pub const minH10 = GeneratedStyledMethods.minH10;
    pub const minH11 = GeneratedStyledMethods.minH11;
    pub const minH12 = GeneratedStyledMethods.minH12;
    pub const minH16 = GeneratedStyledMethods.minH16;
    pub const minH20 = GeneratedStyledMethods.minH20;
    pub const minH24 = GeneratedStyledMethods.minH24;
    pub const minH32 = GeneratedStyledMethods.minH32;
    pub const minH40 = GeneratedStyledMethods.minH40;
    pub const minH48 = GeneratedStyledMethods.minH48;
    pub const minH56 = GeneratedStyledMethods.minH56;
    pub const minH64 = GeneratedStyledMethods.minH64;
    pub const minH72 = GeneratedStyledMethods.minH72;
    pub const minH80 = GeneratedStyledMethods.minH80;
    pub const minH96 = GeneratedStyledMethods.minH96;
    pub const minH112 = GeneratedStyledMethods.minH112;
    pub const minH128 = GeneratedStyledMethods.minH128;
    pub const minHAuto = GeneratedStyledMethods.minHAuto;
    pub const minHPx = GeneratedStyledMethods.minHPx;
    pub const minHFull = GeneratedStyledMethods.minHFull;
    pub const minH1_2 = GeneratedStyledMethods.minH1_2;
    pub const minH1_3 = GeneratedStyledMethods.minH1_3;
    pub const minH2_3 = GeneratedStyledMethods.minH2_3;
    pub const minH1_4 = GeneratedStyledMethods.minH1_4;
    pub const minH2_4 = GeneratedStyledMethods.minH2_4;
    pub const minH3_4 = GeneratedStyledMethods.minH3_4;
    pub const minH1_5 = GeneratedStyledMethods.minH1_5;
    pub const minH2_5 = GeneratedStyledMethods.minH2_5;
    pub const minH3_5 = GeneratedStyledMethods.minH3_5;
    pub const minH4_5 = GeneratedStyledMethods.minH4_5;
    pub const minH1_6 = GeneratedStyledMethods.minH1_6;
    pub const minH5_6 = GeneratedStyledMethods.minH5_6;
    pub const minH1_12 = GeneratedStyledMethods.minH1_12;
    pub const maxSize = GeneratedStyledMethods.maxSize;
    pub const maxSize0 = GeneratedStyledMethods.maxSize0;
    pub const maxSize0p5 = GeneratedStyledMethods.maxSize0p5;
    pub const maxSize1 = GeneratedStyledMethods.maxSize1;
    pub const maxSize1p5 = GeneratedStyledMethods.maxSize1p5;
    pub const maxSize2 = GeneratedStyledMethods.maxSize2;
    pub const maxSize2p5 = GeneratedStyledMethods.maxSize2p5;
    pub const maxSize3 = GeneratedStyledMethods.maxSize3;
    pub const maxSize3p5 = GeneratedStyledMethods.maxSize3p5;
    pub const maxSize4 = GeneratedStyledMethods.maxSize4;
    pub const maxSize5 = GeneratedStyledMethods.maxSize5;
    pub const maxSize6 = GeneratedStyledMethods.maxSize6;
    pub const maxSize7 = GeneratedStyledMethods.maxSize7;
    pub const maxSize8 = GeneratedStyledMethods.maxSize8;
    pub const maxSize9 = GeneratedStyledMethods.maxSize9;
    pub const maxSize10 = GeneratedStyledMethods.maxSize10;
    pub const maxSize11 = GeneratedStyledMethods.maxSize11;
    pub const maxSize12 = GeneratedStyledMethods.maxSize12;
    pub const maxSize16 = GeneratedStyledMethods.maxSize16;
    pub const maxSize20 = GeneratedStyledMethods.maxSize20;
    pub const maxSize24 = GeneratedStyledMethods.maxSize24;
    pub const maxSize32 = GeneratedStyledMethods.maxSize32;
    pub const maxSize40 = GeneratedStyledMethods.maxSize40;
    pub const maxSize48 = GeneratedStyledMethods.maxSize48;
    pub const maxSize56 = GeneratedStyledMethods.maxSize56;
    pub const maxSize64 = GeneratedStyledMethods.maxSize64;
    pub const maxSize72 = GeneratedStyledMethods.maxSize72;
    pub const maxSize80 = GeneratedStyledMethods.maxSize80;
    pub const maxSize96 = GeneratedStyledMethods.maxSize96;
    pub const maxSize112 = GeneratedStyledMethods.maxSize112;
    pub const maxSize128 = GeneratedStyledMethods.maxSize128;
    pub const maxSizeAuto = GeneratedStyledMethods.maxSizeAuto;
    pub const maxSizePx = GeneratedStyledMethods.maxSizePx;
    pub const maxSizeFull = GeneratedStyledMethods.maxSizeFull;
    pub const maxSize1_2 = GeneratedStyledMethods.maxSize1_2;
    pub const maxSize1_3 = GeneratedStyledMethods.maxSize1_3;
    pub const maxSize2_3 = GeneratedStyledMethods.maxSize2_3;
    pub const maxSize1_4 = GeneratedStyledMethods.maxSize1_4;
    pub const maxSize2_4 = GeneratedStyledMethods.maxSize2_4;
    pub const maxSize3_4 = GeneratedStyledMethods.maxSize3_4;
    pub const maxSize1_5 = GeneratedStyledMethods.maxSize1_5;
    pub const maxSize2_5 = GeneratedStyledMethods.maxSize2_5;
    pub const maxSize3_5 = GeneratedStyledMethods.maxSize3_5;
    pub const maxSize4_5 = GeneratedStyledMethods.maxSize4_5;
    pub const maxSize1_6 = GeneratedStyledMethods.maxSize1_6;
    pub const maxSize5_6 = GeneratedStyledMethods.maxSize5_6;
    pub const maxSize1_12 = GeneratedStyledMethods.maxSize1_12;
    pub const maxW = GeneratedStyledMethods.maxW;
    pub const maxW0 = GeneratedStyledMethods.maxW0;
    pub const maxW0p5 = GeneratedStyledMethods.maxW0p5;
    pub const maxW1 = GeneratedStyledMethods.maxW1;
    pub const maxW1p5 = GeneratedStyledMethods.maxW1p5;
    pub const maxW2 = GeneratedStyledMethods.maxW2;
    pub const maxW2p5 = GeneratedStyledMethods.maxW2p5;
    pub const maxW3 = GeneratedStyledMethods.maxW3;
    pub const maxW3p5 = GeneratedStyledMethods.maxW3p5;
    pub const maxW4 = GeneratedStyledMethods.maxW4;
    pub const maxW5 = GeneratedStyledMethods.maxW5;
    pub const maxW6 = GeneratedStyledMethods.maxW6;
    pub const maxW7 = GeneratedStyledMethods.maxW7;
    pub const maxW8 = GeneratedStyledMethods.maxW8;
    pub const maxW9 = GeneratedStyledMethods.maxW9;
    pub const maxW10 = GeneratedStyledMethods.maxW10;
    pub const maxW11 = GeneratedStyledMethods.maxW11;
    pub const maxW12 = GeneratedStyledMethods.maxW12;
    pub const maxW16 = GeneratedStyledMethods.maxW16;
    pub const maxW20 = GeneratedStyledMethods.maxW20;
    pub const maxW24 = GeneratedStyledMethods.maxW24;
    pub const maxW32 = GeneratedStyledMethods.maxW32;
    pub const maxW40 = GeneratedStyledMethods.maxW40;
    pub const maxW48 = GeneratedStyledMethods.maxW48;
    pub const maxW56 = GeneratedStyledMethods.maxW56;
    pub const maxW64 = GeneratedStyledMethods.maxW64;
    pub const maxW72 = GeneratedStyledMethods.maxW72;
    pub const maxW80 = GeneratedStyledMethods.maxW80;
    pub const maxW96 = GeneratedStyledMethods.maxW96;
    pub const maxW112 = GeneratedStyledMethods.maxW112;
    pub const maxW128 = GeneratedStyledMethods.maxW128;
    pub const maxWAuto = GeneratedStyledMethods.maxWAuto;
    pub const maxWPx = GeneratedStyledMethods.maxWPx;
    pub const maxWFull = GeneratedStyledMethods.maxWFull;
    pub const maxW1_2 = GeneratedStyledMethods.maxW1_2;
    pub const maxW1_3 = GeneratedStyledMethods.maxW1_3;
    pub const maxW2_3 = GeneratedStyledMethods.maxW2_3;
    pub const maxW1_4 = GeneratedStyledMethods.maxW1_4;
    pub const maxW2_4 = GeneratedStyledMethods.maxW2_4;
    pub const maxW3_4 = GeneratedStyledMethods.maxW3_4;
    pub const maxW1_5 = GeneratedStyledMethods.maxW1_5;
    pub const maxW2_5 = GeneratedStyledMethods.maxW2_5;
    pub const maxW3_5 = GeneratedStyledMethods.maxW3_5;
    pub const maxW4_5 = GeneratedStyledMethods.maxW4_5;
    pub const maxW1_6 = GeneratedStyledMethods.maxW1_6;
    pub const maxW5_6 = GeneratedStyledMethods.maxW5_6;
    pub const maxW1_12 = GeneratedStyledMethods.maxW1_12;
    pub const maxH = GeneratedStyledMethods.maxH;
    pub const maxH0 = GeneratedStyledMethods.maxH0;
    pub const maxH0p5 = GeneratedStyledMethods.maxH0p5;
    pub const maxH1 = GeneratedStyledMethods.maxH1;
    pub const maxH1p5 = GeneratedStyledMethods.maxH1p5;
    pub const maxH2 = GeneratedStyledMethods.maxH2;
    pub const maxH2p5 = GeneratedStyledMethods.maxH2p5;
    pub const maxH3 = GeneratedStyledMethods.maxH3;
    pub const maxH3p5 = GeneratedStyledMethods.maxH3p5;
    pub const maxH4 = GeneratedStyledMethods.maxH4;
    pub const maxH5 = GeneratedStyledMethods.maxH5;
    pub const maxH6 = GeneratedStyledMethods.maxH6;
    pub const maxH7 = GeneratedStyledMethods.maxH7;
    pub const maxH8 = GeneratedStyledMethods.maxH8;
    pub const maxH9 = GeneratedStyledMethods.maxH9;
    pub const maxH10 = GeneratedStyledMethods.maxH10;
    pub const maxH11 = GeneratedStyledMethods.maxH11;
    pub const maxH12 = GeneratedStyledMethods.maxH12;
    pub const maxH16 = GeneratedStyledMethods.maxH16;
    pub const maxH20 = GeneratedStyledMethods.maxH20;
    pub const maxH24 = GeneratedStyledMethods.maxH24;
    pub const maxH32 = GeneratedStyledMethods.maxH32;
    pub const maxH40 = GeneratedStyledMethods.maxH40;
    pub const maxH48 = GeneratedStyledMethods.maxH48;
    pub const maxH56 = GeneratedStyledMethods.maxH56;
    pub const maxH64 = GeneratedStyledMethods.maxH64;
    pub const maxH72 = GeneratedStyledMethods.maxH72;
    pub const maxH80 = GeneratedStyledMethods.maxH80;
    pub const maxH96 = GeneratedStyledMethods.maxH96;
    pub const maxH112 = GeneratedStyledMethods.maxH112;
    pub const maxH128 = GeneratedStyledMethods.maxH128;
    pub const maxHAuto = GeneratedStyledMethods.maxHAuto;
    pub const maxHPx = GeneratedStyledMethods.maxHPx;
    pub const maxHFull = GeneratedStyledMethods.maxHFull;
    pub const maxH1_2 = GeneratedStyledMethods.maxH1_2;
    pub const maxH1_3 = GeneratedStyledMethods.maxH1_3;
    pub const maxH2_3 = GeneratedStyledMethods.maxH2_3;
    pub const maxH1_4 = GeneratedStyledMethods.maxH1_4;
    pub const maxH2_4 = GeneratedStyledMethods.maxH2_4;
    pub const maxH3_4 = GeneratedStyledMethods.maxH3_4;
    pub const maxH1_5 = GeneratedStyledMethods.maxH1_5;
    pub const maxH2_5 = GeneratedStyledMethods.maxH2_5;
    pub const maxH3_5 = GeneratedStyledMethods.maxH3_5;
    pub const maxH4_5 = GeneratedStyledMethods.maxH4_5;
    pub const maxH1_6 = GeneratedStyledMethods.maxH1_6;
    pub const maxH5_6 = GeneratedStyledMethods.maxH5_6;
    pub const maxH1_12 = GeneratedStyledMethods.maxH1_12;
    pub const gap = GeneratedStyledMethods.gap;
    pub const gap0 = GeneratedStyledMethods.gap0;
    pub const gap0p5 = GeneratedStyledMethods.gap0p5;
    pub const gap1 = GeneratedStyledMethods.gap1;
    pub const gap1p5 = GeneratedStyledMethods.gap1p5;
    pub const gap2 = GeneratedStyledMethods.gap2;
    pub const gap2p5 = GeneratedStyledMethods.gap2p5;
    pub const gap3 = GeneratedStyledMethods.gap3;
    pub const gap3p5 = GeneratedStyledMethods.gap3p5;
    pub const gap4 = GeneratedStyledMethods.gap4;
    pub const gap5 = GeneratedStyledMethods.gap5;
    pub const gap6 = GeneratedStyledMethods.gap6;
    pub const gap7 = GeneratedStyledMethods.gap7;
    pub const gap8 = GeneratedStyledMethods.gap8;
    pub const gap9 = GeneratedStyledMethods.gap9;
    pub const gap10 = GeneratedStyledMethods.gap10;
    pub const gap11 = GeneratedStyledMethods.gap11;
    pub const gap12 = GeneratedStyledMethods.gap12;
    pub const gap16 = GeneratedStyledMethods.gap16;
    pub const gap20 = GeneratedStyledMethods.gap20;
    pub const gap24 = GeneratedStyledMethods.gap24;
    pub const gap32 = GeneratedStyledMethods.gap32;
    pub const gap40 = GeneratedStyledMethods.gap40;
    pub const gap48 = GeneratedStyledMethods.gap48;
    pub const gap56 = GeneratedStyledMethods.gap56;
    pub const gap64 = GeneratedStyledMethods.gap64;
    pub const gap72 = GeneratedStyledMethods.gap72;
    pub const gap80 = GeneratedStyledMethods.gap80;
    pub const gap96 = GeneratedStyledMethods.gap96;
    pub const gap112 = GeneratedStyledMethods.gap112;
    pub const gap128 = GeneratedStyledMethods.gap128;
    pub const gapPx = GeneratedStyledMethods.gapPx;
    pub const gapFull = GeneratedStyledMethods.gapFull;
    pub const gap1_2 = GeneratedStyledMethods.gap1_2;
    pub const gap1_3 = GeneratedStyledMethods.gap1_3;
    pub const gap2_3 = GeneratedStyledMethods.gap2_3;
    pub const gap1_4 = GeneratedStyledMethods.gap1_4;
    pub const gap2_4 = GeneratedStyledMethods.gap2_4;
    pub const gap3_4 = GeneratedStyledMethods.gap3_4;
    pub const gap1_5 = GeneratedStyledMethods.gap1_5;
    pub const gap2_5 = GeneratedStyledMethods.gap2_5;
    pub const gap3_5 = GeneratedStyledMethods.gap3_5;
    pub const gap4_5 = GeneratedStyledMethods.gap4_5;
    pub const gap1_6 = GeneratedStyledMethods.gap1_6;
    pub const gap5_6 = GeneratedStyledMethods.gap5_6;
    pub const gap1_12 = GeneratedStyledMethods.gap1_12;
    pub const gapX = GeneratedStyledMethods.gapX;
    pub const gapX0 = GeneratedStyledMethods.gapX0;
    pub const gapX0p5 = GeneratedStyledMethods.gapX0p5;
    pub const gapX1 = GeneratedStyledMethods.gapX1;
    pub const gapX1p5 = GeneratedStyledMethods.gapX1p5;
    pub const gapX2 = GeneratedStyledMethods.gapX2;
    pub const gapX2p5 = GeneratedStyledMethods.gapX2p5;
    pub const gapX3 = GeneratedStyledMethods.gapX3;
    pub const gapX3p5 = GeneratedStyledMethods.gapX3p5;
    pub const gapX4 = GeneratedStyledMethods.gapX4;
    pub const gapX5 = GeneratedStyledMethods.gapX5;
    pub const gapX6 = GeneratedStyledMethods.gapX6;
    pub const gapX7 = GeneratedStyledMethods.gapX7;
    pub const gapX8 = GeneratedStyledMethods.gapX8;
    pub const gapX9 = GeneratedStyledMethods.gapX9;
    pub const gapX10 = GeneratedStyledMethods.gapX10;
    pub const gapX11 = GeneratedStyledMethods.gapX11;
    pub const gapX12 = GeneratedStyledMethods.gapX12;
    pub const gapX16 = GeneratedStyledMethods.gapX16;
    pub const gapX20 = GeneratedStyledMethods.gapX20;
    pub const gapX24 = GeneratedStyledMethods.gapX24;
    pub const gapX32 = GeneratedStyledMethods.gapX32;
    pub const gapX40 = GeneratedStyledMethods.gapX40;
    pub const gapX48 = GeneratedStyledMethods.gapX48;
    pub const gapX56 = GeneratedStyledMethods.gapX56;
    pub const gapX64 = GeneratedStyledMethods.gapX64;
    pub const gapX72 = GeneratedStyledMethods.gapX72;
    pub const gapX80 = GeneratedStyledMethods.gapX80;
    pub const gapX96 = GeneratedStyledMethods.gapX96;
    pub const gapX112 = GeneratedStyledMethods.gapX112;
    pub const gapX128 = GeneratedStyledMethods.gapX128;
    pub const gapXPx = GeneratedStyledMethods.gapXPx;
    pub const gapXFull = GeneratedStyledMethods.gapXFull;
    pub const gapX1_2 = GeneratedStyledMethods.gapX1_2;
    pub const gapX1_3 = GeneratedStyledMethods.gapX1_3;
    pub const gapX2_3 = GeneratedStyledMethods.gapX2_3;
    pub const gapX1_4 = GeneratedStyledMethods.gapX1_4;
    pub const gapX2_4 = GeneratedStyledMethods.gapX2_4;
    pub const gapX3_4 = GeneratedStyledMethods.gapX3_4;
    pub const gapX1_5 = GeneratedStyledMethods.gapX1_5;
    pub const gapX2_5 = GeneratedStyledMethods.gapX2_5;
    pub const gapX3_5 = GeneratedStyledMethods.gapX3_5;
    pub const gapX4_5 = GeneratedStyledMethods.gapX4_5;
    pub const gapX1_6 = GeneratedStyledMethods.gapX1_6;
    pub const gapX5_6 = GeneratedStyledMethods.gapX5_6;
    pub const gapX1_12 = GeneratedStyledMethods.gapX1_12;
    pub const gapY = GeneratedStyledMethods.gapY;
    pub const gapY0 = GeneratedStyledMethods.gapY0;
    pub const gapY0p5 = GeneratedStyledMethods.gapY0p5;
    pub const gapY1 = GeneratedStyledMethods.gapY1;
    pub const gapY1p5 = GeneratedStyledMethods.gapY1p5;
    pub const gapY2 = GeneratedStyledMethods.gapY2;
    pub const gapY2p5 = GeneratedStyledMethods.gapY2p5;
    pub const gapY3 = GeneratedStyledMethods.gapY3;
    pub const gapY3p5 = GeneratedStyledMethods.gapY3p5;
    pub const gapY4 = GeneratedStyledMethods.gapY4;
    pub const gapY5 = GeneratedStyledMethods.gapY5;
    pub const gapY6 = GeneratedStyledMethods.gapY6;
    pub const gapY7 = GeneratedStyledMethods.gapY7;
    pub const gapY8 = GeneratedStyledMethods.gapY8;
    pub const gapY9 = GeneratedStyledMethods.gapY9;
    pub const gapY10 = GeneratedStyledMethods.gapY10;
    pub const gapY11 = GeneratedStyledMethods.gapY11;
    pub const gapY12 = GeneratedStyledMethods.gapY12;
    pub const gapY16 = GeneratedStyledMethods.gapY16;
    pub const gapY20 = GeneratedStyledMethods.gapY20;
    pub const gapY24 = GeneratedStyledMethods.gapY24;
    pub const gapY32 = GeneratedStyledMethods.gapY32;
    pub const gapY40 = GeneratedStyledMethods.gapY40;
    pub const gapY48 = GeneratedStyledMethods.gapY48;
    pub const gapY56 = GeneratedStyledMethods.gapY56;
    pub const gapY64 = GeneratedStyledMethods.gapY64;
    pub const gapY72 = GeneratedStyledMethods.gapY72;
    pub const gapY80 = GeneratedStyledMethods.gapY80;
    pub const gapY96 = GeneratedStyledMethods.gapY96;
    pub const gapY112 = GeneratedStyledMethods.gapY112;
    pub const gapY128 = GeneratedStyledMethods.gapY128;
    pub const gapYPx = GeneratedStyledMethods.gapYPx;
    pub const gapYFull = GeneratedStyledMethods.gapYFull;
    pub const gapY1_2 = GeneratedStyledMethods.gapY1_2;
    pub const gapY1_3 = GeneratedStyledMethods.gapY1_3;
    pub const gapY2_3 = GeneratedStyledMethods.gapY2_3;
    pub const gapY1_4 = GeneratedStyledMethods.gapY1_4;
    pub const gapY2_4 = GeneratedStyledMethods.gapY2_4;
    pub const gapY3_4 = GeneratedStyledMethods.gapY3_4;
    pub const gapY1_5 = GeneratedStyledMethods.gapY1_5;
    pub const gapY2_5 = GeneratedStyledMethods.gapY2_5;
    pub const gapY3_5 = GeneratedStyledMethods.gapY3_5;
    pub const gapY4_5 = GeneratedStyledMethods.gapY4_5;
    pub const gapY1_6 = GeneratedStyledMethods.gapY1_6;
    pub const gapY5_6 = GeneratedStyledMethods.gapY5_6;
    pub const gapY1_12 = GeneratedStyledMethods.gapY1_12;
    pub const m = GeneratedStyledMethods.m;
    pub const m0 = GeneratedStyledMethods.m0;
    pub const mNeg0 = GeneratedStyledMethods.mNeg0;
    pub const m0p5 = GeneratedStyledMethods.m0p5;
    pub const mNeg0p5 = GeneratedStyledMethods.mNeg0p5;
    pub const m1 = GeneratedStyledMethods.m1;
    pub const mNeg1 = GeneratedStyledMethods.mNeg1;
    pub const m1p5 = GeneratedStyledMethods.m1p5;
    pub const mNeg1p5 = GeneratedStyledMethods.mNeg1p5;
    pub const m2 = GeneratedStyledMethods.m2;
    pub const mNeg2 = GeneratedStyledMethods.mNeg2;
    pub const m2p5 = GeneratedStyledMethods.m2p5;
    pub const mNeg2p5 = GeneratedStyledMethods.mNeg2p5;
    pub const m3 = GeneratedStyledMethods.m3;
    pub const mNeg3 = GeneratedStyledMethods.mNeg3;
    pub const m3p5 = GeneratedStyledMethods.m3p5;
    pub const mNeg3p5 = GeneratedStyledMethods.mNeg3p5;
    pub const m4 = GeneratedStyledMethods.m4;
    pub const mNeg4 = GeneratedStyledMethods.mNeg4;
    pub const m5 = GeneratedStyledMethods.m5;
    pub const mNeg5 = GeneratedStyledMethods.mNeg5;
    pub const m6 = GeneratedStyledMethods.m6;
    pub const mNeg6 = GeneratedStyledMethods.mNeg6;
    pub const m7 = GeneratedStyledMethods.m7;
    pub const mNeg7 = GeneratedStyledMethods.mNeg7;
    pub const m8 = GeneratedStyledMethods.m8;
    pub const mNeg8 = GeneratedStyledMethods.mNeg8;
    pub const m9 = GeneratedStyledMethods.m9;
    pub const mNeg9 = GeneratedStyledMethods.mNeg9;
    pub const m10 = GeneratedStyledMethods.m10;
    pub const mNeg10 = GeneratedStyledMethods.mNeg10;
    pub const m11 = GeneratedStyledMethods.m11;
    pub const mNeg11 = GeneratedStyledMethods.mNeg11;
    pub const m12 = GeneratedStyledMethods.m12;
    pub const mNeg12 = GeneratedStyledMethods.mNeg12;
    pub const m16 = GeneratedStyledMethods.m16;
    pub const mNeg16 = GeneratedStyledMethods.mNeg16;
    pub const m20 = GeneratedStyledMethods.m20;
    pub const mNeg20 = GeneratedStyledMethods.mNeg20;
    pub const m24 = GeneratedStyledMethods.m24;
    pub const mNeg24 = GeneratedStyledMethods.mNeg24;
    pub const m32 = GeneratedStyledMethods.m32;
    pub const mNeg32 = GeneratedStyledMethods.mNeg32;
    pub const m40 = GeneratedStyledMethods.m40;
    pub const mNeg40 = GeneratedStyledMethods.mNeg40;
    pub const m48 = GeneratedStyledMethods.m48;
    pub const mNeg48 = GeneratedStyledMethods.mNeg48;
    pub const m56 = GeneratedStyledMethods.m56;
    pub const mNeg56 = GeneratedStyledMethods.mNeg56;
    pub const m64 = GeneratedStyledMethods.m64;
    pub const mNeg64 = GeneratedStyledMethods.mNeg64;
    pub const m72 = GeneratedStyledMethods.m72;
    pub const mNeg72 = GeneratedStyledMethods.mNeg72;
    pub const m80 = GeneratedStyledMethods.m80;
    pub const mNeg80 = GeneratedStyledMethods.mNeg80;
    pub const m96 = GeneratedStyledMethods.m96;
    pub const mNeg96 = GeneratedStyledMethods.mNeg96;
    pub const m112 = GeneratedStyledMethods.m112;
    pub const mNeg112 = GeneratedStyledMethods.mNeg112;
    pub const m128 = GeneratedStyledMethods.m128;
    pub const mNeg128 = GeneratedStyledMethods.mNeg128;
    pub const mAuto = GeneratedStyledMethods.mAuto;
    pub const mPx = GeneratedStyledMethods.mPx;
    pub const mNegPx = GeneratedStyledMethods.mNegPx;
    pub const mFull = GeneratedStyledMethods.mFull;
    pub const mNegFull = GeneratedStyledMethods.mNegFull;
    pub const m1_2 = GeneratedStyledMethods.m1_2;
    pub const mNeg1_2 = GeneratedStyledMethods.mNeg1_2;
    pub const m1_3 = GeneratedStyledMethods.m1_3;
    pub const mNeg1_3 = GeneratedStyledMethods.mNeg1_3;
    pub const m2_3 = GeneratedStyledMethods.m2_3;
    pub const mNeg2_3 = GeneratedStyledMethods.mNeg2_3;
    pub const m1_4 = GeneratedStyledMethods.m1_4;
    pub const mNeg1_4 = GeneratedStyledMethods.mNeg1_4;
    pub const m2_4 = GeneratedStyledMethods.m2_4;
    pub const mNeg2_4 = GeneratedStyledMethods.mNeg2_4;
    pub const m3_4 = GeneratedStyledMethods.m3_4;
    pub const mNeg3_4 = GeneratedStyledMethods.mNeg3_4;
    pub const m1_5 = GeneratedStyledMethods.m1_5;
    pub const mNeg1_5 = GeneratedStyledMethods.mNeg1_5;
    pub const m2_5 = GeneratedStyledMethods.m2_5;
    pub const mNeg2_5 = GeneratedStyledMethods.mNeg2_5;
    pub const m3_5 = GeneratedStyledMethods.m3_5;
    pub const mNeg3_5 = GeneratedStyledMethods.mNeg3_5;
    pub const m4_5 = GeneratedStyledMethods.m4_5;
    pub const mNeg4_5 = GeneratedStyledMethods.mNeg4_5;
    pub const m1_6 = GeneratedStyledMethods.m1_6;
    pub const mNeg1_6 = GeneratedStyledMethods.mNeg1_6;
    pub const m5_6 = GeneratedStyledMethods.m5_6;
    pub const mNeg5_6 = GeneratedStyledMethods.mNeg5_6;
    pub const m1_12 = GeneratedStyledMethods.m1_12;
    pub const mNeg1_12 = GeneratedStyledMethods.mNeg1_12;
    pub const mt = GeneratedStyledMethods.mt;
    pub const mt0 = GeneratedStyledMethods.mt0;
    pub const mtNeg0 = GeneratedStyledMethods.mtNeg0;
    pub const mt0p5 = GeneratedStyledMethods.mt0p5;
    pub const mtNeg0p5 = GeneratedStyledMethods.mtNeg0p5;
    pub const mt1 = GeneratedStyledMethods.mt1;
    pub const mtNeg1 = GeneratedStyledMethods.mtNeg1;
    pub const mt1p5 = GeneratedStyledMethods.mt1p5;
    pub const mtNeg1p5 = GeneratedStyledMethods.mtNeg1p5;
    pub const mt2 = GeneratedStyledMethods.mt2;
    pub const mtNeg2 = GeneratedStyledMethods.mtNeg2;
    pub const mt2p5 = GeneratedStyledMethods.mt2p5;
    pub const mtNeg2p5 = GeneratedStyledMethods.mtNeg2p5;
    pub const mt3 = GeneratedStyledMethods.mt3;
    pub const mtNeg3 = GeneratedStyledMethods.mtNeg3;
    pub const mt3p5 = GeneratedStyledMethods.mt3p5;
    pub const mtNeg3p5 = GeneratedStyledMethods.mtNeg3p5;
    pub const mt4 = GeneratedStyledMethods.mt4;
    pub const mtNeg4 = GeneratedStyledMethods.mtNeg4;
    pub const mt5 = GeneratedStyledMethods.mt5;
    pub const mtNeg5 = GeneratedStyledMethods.mtNeg5;
    pub const mt6 = GeneratedStyledMethods.mt6;
    pub const mtNeg6 = GeneratedStyledMethods.mtNeg6;
    pub const mt7 = GeneratedStyledMethods.mt7;
    pub const mtNeg7 = GeneratedStyledMethods.mtNeg7;
    pub const mt8 = GeneratedStyledMethods.mt8;
    pub const mtNeg8 = GeneratedStyledMethods.mtNeg8;
    pub const mt9 = GeneratedStyledMethods.mt9;
    pub const mtNeg9 = GeneratedStyledMethods.mtNeg9;
    pub const mt10 = GeneratedStyledMethods.mt10;
    pub const mtNeg10 = GeneratedStyledMethods.mtNeg10;
    pub const mt11 = GeneratedStyledMethods.mt11;
    pub const mtNeg11 = GeneratedStyledMethods.mtNeg11;
    pub const mt12 = GeneratedStyledMethods.mt12;
    pub const mtNeg12 = GeneratedStyledMethods.mtNeg12;
    pub const mt16 = GeneratedStyledMethods.mt16;
    pub const mtNeg16 = GeneratedStyledMethods.mtNeg16;
    pub const mt20 = GeneratedStyledMethods.mt20;
    pub const mtNeg20 = GeneratedStyledMethods.mtNeg20;
    pub const mt24 = GeneratedStyledMethods.mt24;
    pub const mtNeg24 = GeneratedStyledMethods.mtNeg24;
    pub const mt32 = GeneratedStyledMethods.mt32;
    pub const mtNeg32 = GeneratedStyledMethods.mtNeg32;
    pub const mt40 = GeneratedStyledMethods.mt40;
    pub const mtNeg40 = GeneratedStyledMethods.mtNeg40;
    pub const mt48 = GeneratedStyledMethods.mt48;
    pub const mtNeg48 = GeneratedStyledMethods.mtNeg48;
    pub const mt56 = GeneratedStyledMethods.mt56;
    pub const mtNeg56 = GeneratedStyledMethods.mtNeg56;
    pub const mt64 = GeneratedStyledMethods.mt64;
    pub const mtNeg64 = GeneratedStyledMethods.mtNeg64;
    pub const mt72 = GeneratedStyledMethods.mt72;
    pub const mtNeg72 = GeneratedStyledMethods.mtNeg72;
    pub const mt80 = GeneratedStyledMethods.mt80;
    pub const mtNeg80 = GeneratedStyledMethods.mtNeg80;
    pub const mt96 = GeneratedStyledMethods.mt96;
    pub const mtNeg96 = GeneratedStyledMethods.mtNeg96;
    pub const mt112 = GeneratedStyledMethods.mt112;
    pub const mtNeg112 = GeneratedStyledMethods.mtNeg112;
    pub const mt128 = GeneratedStyledMethods.mt128;
    pub const mtNeg128 = GeneratedStyledMethods.mtNeg128;
    pub const mtAuto = GeneratedStyledMethods.mtAuto;
    pub const mtPx = GeneratedStyledMethods.mtPx;
    pub const mtNegPx = GeneratedStyledMethods.mtNegPx;
    pub const mtFull = GeneratedStyledMethods.mtFull;
    pub const mtNegFull = GeneratedStyledMethods.mtNegFull;
    pub const mt1_2 = GeneratedStyledMethods.mt1_2;
    pub const mtNeg1_2 = GeneratedStyledMethods.mtNeg1_2;
    pub const mt1_3 = GeneratedStyledMethods.mt1_3;
    pub const mtNeg1_3 = GeneratedStyledMethods.mtNeg1_3;
    pub const mt2_3 = GeneratedStyledMethods.mt2_3;
    pub const mtNeg2_3 = GeneratedStyledMethods.mtNeg2_3;
    pub const mt1_4 = GeneratedStyledMethods.mt1_4;
    pub const mtNeg1_4 = GeneratedStyledMethods.mtNeg1_4;
    pub const mt2_4 = GeneratedStyledMethods.mt2_4;
    pub const mtNeg2_4 = GeneratedStyledMethods.mtNeg2_4;
    pub const mt3_4 = GeneratedStyledMethods.mt3_4;
    pub const mtNeg3_4 = GeneratedStyledMethods.mtNeg3_4;
    pub const mt1_5 = GeneratedStyledMethods.mt1_5;
    pub const mtNeg1_5 = GeneratedStyledMethods.mtNeg1_5;
    pub const mt2_5 = GeneratedStyledMethods.mt2_5;
    pub const mtNeg2_5 = GeneratedStyledMethods.mtNeg2_5;
    pub const mt3_5 = GeneratedStyledMethods.mt3_5;
    pub const mtNeg3_5 = GeneratedStyledMethods.mtNeg3_5;
    pub const mt4_5 = GeneratedStyledMethods.mt4_5;
    pub const mtNeg4_5 = GeneratedStyledMethods.mtNeg4_5;
    pub const mt1_6 = GeneratedStyledMethods.mt1_6;
    pub const mtNeg1_6 = GeneratedStyledMethods.mtNeg1_6;
    pub const mt5_6 = GeneratedStyledMethods.mt5_6;
    pub const mtNeg5_6 = GeneratedStyledMethods.mtNeg5_6;
    pub const mt1_12 = GeneratedStyledMethods.mt1_12;
    pub const mtNeg1_12 = GeneratedStyledMethods.mtNeg1_12;
    pub const mb = GeneratedStyledMethods.mb;
    pub const mb0 = GeneratedStyledMethods.mb0;
    pub const mbNeg0 = GeneratedStyledMethods.mbNeg0;
    pub const mb0p5 = GeneratedStyledMethods.mb0p5;
    pub const mbNeg0p5 = GeneratedStyledMethods.mbNeg0p5;
    pub const mb1 = GeneratedStyledMethods.mb1;
    pub const mbNeg1 = GeneratedStyledMethods.mbNeg1;
    pub const mb1p5 = GeneratedStyledMethods.mb1p5;
    pub const mbNeg1p5 = GeneratedStyledMethods.mbNeg1p5;
    pub const mb2 = GeneratedStyledMethods.mb2;
    pub const mbNeg2 = GeneratedStyledMethods.mbNeg2;
    pub const mb2p5 = GeneratedStyledMethods.mb2p5;
    pub const mbNeg2p5 = GeneratedStyledMethods.mbNeg2p5;
    pub const mb3 = GeneratedStyledMethods.mb3;
    pub const mbNeg3 = GeneratedStyledMethods.mbNeg3;
    pub const mb3p5 = GeneratedStyledMethods.mb3p5;
    pub const mbNeg3p5 = GeneratedStyledMethods.mbNeg3p5;
    pub const mb4 = GeneratedStyledMethods.mb4;
    pub const mbNeg4 = GeneratedStyledMethods.mbNeg4;
    pub const mb5 = GeneratedStyledMethods.mb5;
    pub const mbNeg5 = GeneratedStyledMethods.mbNeg5;
    pub const mb6 = GeneratedStyledMethods.mb6;
    pub const mbNeg6 = GeneratedStyledMethods.mbNeg6;
    pub const mb7 = GeneratedStyledMethods.mb7;
    pub const mbNeg7 = GeneratedStyledMethods.mbNeg7;
    pub const mb8 = GeneratedStyledMethods.mb8;
    pub const mbNeg8 = GeneratedStyledMethods.mbNeg8;
    pub const mb9 = GeneratedStyledMethods.mb9;
    pub const mbNeg9 = GeneratedStyledMethods.mbNeg9;
    pub const mb10 = GeneratedStyledMethods.mb10;
    pub const mbNeg10 = GeneratedStyledMethods.mbNeg10;
    pub const mb11 = GeneratedStyledMethods.mb11;
    pub const mbNeg11 = GeneratedStyledMethods.mbNeg11;
    pub const mb12 = GeneratedStyledMethods.mb12;
    pub const mbNeg12 = GeneratedStyledMethods.mbNeg12;
    pub const mb16 = GeneratedStyledMethods.mb16;
    pub const mbNeg16 = GeneratedStyledMethods.mbNeg16;
    pub const mb20 = GeneratedStyledMethods.mb20;
    pub const mbNeg20 = GeneratedStyledMethods.mbNeg20;
    pub const mb24 = GeneratedStyledMethods.mb24;
    pub const mbNeg24 = GeneratedStyledMethods.mbNeg24;
    pub const mb32 = GeneratedStyledMethods.mb32;
    pub const mbNeg32 = GeneratedStyledMethods.mbNeg32;
    pub const mb40 = GeneratedStyledMethods.mb40;
    pub const mbNeg40 = GeneratedStyledMethods.mbNeg40;
    pub const mb48 = GeneratedStyledMethods.mb48;
    pub const mbNeg48 = GeneratedStyledMethods.mbNeg48;
    pub const mb56 = GeneratedStyledMethods.mb56;
    pub const mbNeg56 = GeneratedStyledMethods.mbNeg56;
    pub const mb64 = GeneratedStyledMethods.mb64;
    pub const mbNeg64 = GeneratedStyledMethods.mbNeg64;
    pub const mb72 = GeneratedStyledMethods.mb72;
    pub const mbNeg72 = GeneratedStyledMethods.mbNeg72;
    pub const mb80 = GeneratedStyledMethods.mb80;
    pub const mbNeg80 = GeneratedStyledMethods.mbNeg80;
    pub const mb96 = GeneratedStyledMethods.mb96;
    pub const mbNeg96 = GeneratedStyledMethods.mbNeg96;
    pub const mb112 = GeneratedStyledMethods.mb112;
    pub const mbNeg112 = GeneratedStyledMethods.mbNeg112;
    pub const mb128 = GeneratedStyledMethods.mb128;
    pub const mbNeg128 = GeneratedStyledMethods.mbNeg128;
    pub const mbAuto = GeneratedStyledMethods.mbAuto;
    pub const mbPx = GeneratedStyledMethods.mbPx;
    pub const mbNegPx = GeneratedStyledMethods.mbNegPx;
    pub const mbFull = GeneratedStyledMethods.mbFull;
    pub const mbNegFull = GeneratedStyledMethods.mbNegFull;
    pub const mb1_2 = GeneratedStyledMethods.mb1_2;
    pub const mbNeg1_2 = GeneratedStyledMethods.mbNeg1_2;
    pub const mb1_3 = GeneratedStyledMethods.mb1_3;
    pub const mbNeg1_3 = GeneratedStyledMethods.mbNeg1_3;
    pub const mb2_3 = GeneratedStyledMethods.mb2_3;
    pub const mbNeg2_3 = GeneratedStyledMethods.mbNeg2_3;
    pub const mb1_4 = GeneratedStyledMethods.mb1_4;
    pub const mbNeg1_4 = GeneratedStyledMethods.mbNeg1_4;
    pub const mb2_4 = GeneratedStyledMethods.mb2_4;
    pub const mbNeg2_4 = GeneratedStyledMethods.mbNeg2_4;
    pub const mb3_4 = GeneratedStyledMethods.mb3_4;
    pub const mbNeg3_4 = GeneratedStyledMethods.mbNeg3_4;
    pub const mb1_5 = GeneratedStyledMethods.mb1_5;
    pub const mbNeg1_5 = GeneratedStyledMethods.mbNeg1_5;
    pub const mb2_5 = GeneratedStyledMethods.mb2_5;
    pub const mbNeg2_5 = GeneratedStyledMethods.mbNeg2_5;
    pub const mb3_5 = GeneratedStyledMethods.mb3_5;
    pub const mbNeg3_5 = GeneratedStyledMethods.mbNeg3_5;
    pub const mb4_5 = GeneratedStyledMethods.mb4_5;
    pub const mbNeg4_5 = GeneratedStyledMethods.mbNeg4_5;
    pub const mb1_6 = GeneratedStyledMethods.mb1_6;
    pub const mbNeg1_6 = GeneratedStyledMethods.mbNeg1_6;
    pub const mb5_6 = GeneratedStyledMethods.mb5_6;
    pub const mbNeg5_6 = GeneratedStyledMethods.mbNeg5_6;
    pub const mb1_12 = GeneratedStyledMethods.mb1_12;
    pub const mbNeg1_12 = GeneratedStyledMethods.mbNeg1_12;
    pub const my = GeneratedStyledMethods.my;
    pub const my0 = GeneratedStyledMethods.my0;
    pub const myNeg0 = GeneratedStyledMethods.myNeg0;
    pub const my0p5 = GeneratedStyledMethods.my0p5;
    pub const myNeg0p5 = GeneratedStyledMethods.myNeg0p5;
    pub const my1 = GeneratedStyledMethods.my1;
    pub const myNeg1 = GeneratedStyledMethods.myNeg1;
    pub const my1p5 = GeneratedStyledMethods.my1p5;
    pub const myNeg1p5 = GeneratedStyledMethods.myNeg1p5;
    pub const my2 = GeneratedStyledMethods.my2;
    pub const myNeg2 = GeneratedStyledMethods.myNeg2;
    pub const my2p5 = GeneratedStyledMethods.my2p5;
    pub const myNeg2p5 = GeneratedStyledMethods.myNeg2p5;
    pub const my3 = GeneratedStyledMethods.my3;
    pub const myNeg3 = GeneratedStyledMethods.myNeg3;
    pub const my3p5 = GeneratedStyledMethods.my3p5;
    pub const myNeg3p5 = GeneratedStyledMethods.myNeg3p5;
    pub const my4 = GeneratedStyledMethods.my4;
    pub const myNeg4 = GeneratedStyledMethods.myNeg4;
    pub const my5 = GeneratedStyledMethods.my5;
    pub const myNeg5 = GeneratedStyledMethods.myNeg5;
    pub const my6 = GeneratedStyledMethods.my6;
    pub const myNeg6 = GeneratedStyledMethods.myNeg6;
    pub const my7 = GeneratedStyledMethods.my7;
    pub const myNeg7 = GeneratedStyledMethods.myNeg7;
    pub const my8 = GeneratedStyledMethods.my8;
    pub const myNeg8 = GeneratedStyledMethods.myNeg8;
    pub const my9 = GeneratedStyledMethods.my9;
    pub const myNeg9 = GeneratedStyledMethods.myNeg9;
    pub const my10 = GeneratedStyledMethods.my10;
    pub const myNeg10 = GeneratedStyledMethods.myNeg10;
    pub const my11 = GeneratedStyledMethods.my11;
    pub const myNeg11 = GeneratedStyledMethods.myNeg11;
    pub const my12 = GeneratedStyledMethods.my12;
    pub const myNeg12 = GeneratedStyledMethods.myNeg12;
    pub const my16 = GeneratedStyledMethods.my16;
    pub const myNeg16 = GeneratedStyledMethods.myNeg16;
    pub const my20 = GeneratedStyledMethods.my20;
    pub const myNeg20 = GeneratedStyledMethods.myNeg20;
    pub const my24 = GeneratedStyledMethods.my24;
    pub const myNeg24 = GeneratedStyledMethods.myNeg24;
    pub const my32 = GeneratedStyledMethods.my32;
    pub const myNeg32 = GeneratedStyledMethods.myNeg32;
    pub const my40 = GeneratedStyledMethods.my40;
    pub const myNeg40 = GeneratedStyledMethods.myNeg40;
    pub const my48 = GeneratedStyledMethods.my48;
    pub const myNeg48 = GeneratedStyledMethods.myNeg48;
    pub const my56 = GeneratedStyledMethods.my56;
    pub const myNeg56 = GeneratedStyledMethods.myNeg56;
    pub const my64 = GeneratedStyledMethods.my64;
    pub const myNeg64 = GeneratedStyledMethods.myNeg64;
    pub const my72 = GeneratedStyledMethods.my72;
    pub const myNeg72 = GeneratedStyledMethods.myNeg72;
    pub const my80 = GeneratedStyledMethods.my80;
    pub const myNeg80 = GeneratedStyledMethods.myNeg80;
    pub const my96 = GeneratedStyledMethods.my96;
    pub const myNeg96 = GeneratedStyledMethods.myNeg96;
    pub const my112 = GeneratedStyledMethods.my112;
    pub const myNeg112 = GeneratedStyledMethods.myNeg112;
    pub const my128 = GeneratedStyledMethods.my128;
    pub const myNeg128 = GeneratedStyledMethods.myNeg128;
    pub const myAuto = GeneratedStyledMethods.myAuto;
    pub const myPx = GeneratedStyledMethods.myPx;
    pub const myNegPx = GeneratedStyledMethods.myNegPx;
    pub const myFull = GeneratedStyledMethods.myFull;
    pub const myNegFull = GeneratedStyledMethods.myNegFull;
    pub const my1_2 = GeneratedStyledMethods.my1_2;
    pub const myNeg1_2 = GeneratedStyledMethods.myNeg1_2;
    pub const my1_3 = GeneratedStyledMethods.my1_3;
    pub const myNeg1_3 = GeneratedStyledMethods.myNeg1_3;
    pub const my2_3 = GeneratedStyledMethods.my2_3;
    pub const myNeg2_3 = GeneratedStyledMethods.myNeg2_3;
    pub const my1_4 = GeneratedStyledMethods.my1_4;
    pub const myNeg1_4 = GeneratedStyledMethods.myNeg1_4;
    pub const my2_4 = GeneratedStyledMethods.my2_4;
    pub const myNeg2_4 = GeneratedStyledMethods.myNeg2_4;
    pub const my3_4 = GeneratedStyledMethods.my3_4;
    pub const myNeg3_4 = GeneratedStyledMethods.myNeg3_4;
    pub const my1_5 = GeneratedStyledMethods.my1_5;
    pub const myNeg1_5 = GeneratedStyledMethods.myNeg1_5;
    pub const my2_5 = GeneratedStyledMethods.my2_5;
    pub const myNeg2_5 = GeneratedStyledMethods.myNeg2_5;
    pub const my3_5 = GeneratedStyledMethods.my3_5;
    pub const myNeg3_5 = GeneratedStyledMethods.myNeg3_5;
    pub const my4_5 = GeneratedStyledMethods.my4_5;
    pub const myNeg4_5 = GeneratedStyledMethods.myNeg4_5;
    pub const my1_6 = GeneratedStyledMethods.my1_6;
    pub const myNeg1_6 = GeneratedStyledMethods.myNeg1_6;
    pub const my5_6 = GeneratedStyledMethods.my5_6;
    pub const myNeg5_6 = GeneratedStyledMethods.myNeg5_6;
    pub const my1_12 = GeneratedStyledMethods.my1_12;
    pub const myNeg1_12 = GeneratedStyledMethods.myNeg1_12;
    pub const mx = GeneratedStyledMethods.mx;
    pub const mx0 = GeneratedStyledMethods.mx0;
    pub const mxNeg0 = GeneratedStyledMethods.mxNeg0;
    pub const mx0p5 = GeneratedStyledMethods.mx0p5;
    pub const mxNeg0p5 = GeneratedStyledMethods.mxNeg0p5;
    pub const mx1 = GeneratedStyledMethods.mx1;
    pub const mxNeg1 = GeneratedStyledMethods.mxNeg1;
    pub const mx1p5 = GeneratedStyledMethods.mx1p5;
    pub const mxNeg1p5 = GeneratedStyledMethods.mxNeg1p5;
    pub const mx2 = GeneratedStyledMethods.mx2;
    pub const mxNeg2 = GeneratedStyledMethods.mxNeg2;
    pub const mx2p5 = GeneratedStyledMethods.mx2p5;
    pub const mxNeg2p5 = GeneratedStyledMethods.mxNeg2p5;
    pub const mx3 = GeneratedStyledMethods.mx3;
    pub const mxNeg3 = GeneratedStyledMethods.mxNeg3;
    pub const mx3p5 = GeneratedStyledMethods.mx3p5;
    pub const mxNeg3p5 = GeneratedStyledMethods.mxNeg3p5;
    pub const mx4 = GeneratedStyledMethods.mx4;
    pub const mxNeg4 = GeneratedStyledMethods.mxNeg4;
    pub const mx5 = GeneratedStyledMethods.mx5;
    pub const mxNeg5 = GeneratedStyledMethods.mxNeg5;
    pub const mx6 = GeneratedStyledMethods.mx6;
    pub const mxNeg6 = GeneratedStyledMethods.mxNeg6;
    pub const mx7 = GeneratedStyledMethods.mx7;
    pub const mxNeg7 = GeneratedStyledMethods.mxNeg7;
    pub const mx8 = GeneratedStyledMethods.mx8;
    pub const mxNeg8 = GeneratedStyledMethods.mxNeg8;
    pub const mx9 = GeneratedStyledMethods.mx9;
    pub const mxNeg9 = GeneratedStyledMethods.mxNeg9;
    pub const mx10 = GeneratedStyledMethods.mx10;
    pub const mxNeg10 = GeneratedStyledMethods.mxNeg10;
    pub const mx11 = GeneratedStyledMethods.mx11;
    pub const mxNeg11 = GeneratedStyledMethods.mxNeg11;
    pub const mx12 = GeneratedStyledMethods.mx12;
    pub const mxNeg12 = GeneratedStyledMethods.mxNeg12;
    pub const mx16 = GeneratedStyledMethods.mx16;
    pub const mxNeg16 = GeneratedStyledMethods.mxNeg16;
    pub const mx20 = GeneratedStyledMethods.mx20;
    pub const mxNeg20 = GeneratedStyledMethods.mxNeg20;
    pub const mx24 = GeneratedStyledMethods.mx24;
    pub const mxNeg24 = GeneratedStyledMethods.mxNeg24;
    pub const mx32 = GeneratedStyledMethods.mx32;
    pub const mxNeg32 = GeneratedStyledMethods.mxNeg32;
    pub const mx40 = GeneratedStyledMethods.mx40;
    pub const mxNeg40 = GeneratedStyledMethods.mxNeg40;
    pub const mx48 = GeneratedStyledMethods.mx48;
    pub const mxNeg48 = GeneratedStyledMethods.mxNeg48;
    pub const mx56 = GeneratedStyledMethods.mx56;
    pub const mxNeg56 = GeneratedStyledMethods.mxNeg56;
    pub const mx64 = GeneratedStyledMethods.mx64;
    pub const mxNeg64 = GeneratedStyledMethods.mxNeg64;
    pub const mx72 = GeneratedStyledMethods.mx72;
    pub const mxNeg72 = GeneratedStyledMethods.mxNeg72;
    pub const mx80 = GeneratedStyledMethods.mx80;
    pub const mxNeg80 = GeneratedStyledMethods.mxNeg80;
    pub const mx96 = GeneratedStyledMethods.mx96;
    pub const mxNeg96 = GeneratedStyledMethods.mxNeg96;
    pub const mx112 = GeneratedStyledMethods.mx112;
    pub const mxNeg112 = GeneratedStyledMethods.mxNeg112;
    pub const mx128 = GeneratedStyledMethods.mx128;
    pub const mxNeg128 = GeneratedStyledMethods.mxNeg128;
    pub const mxAuto = GeneratedStyledMethods.mxAuto;
    pub const mxPx = GeneratedStyledMethods.mxPx;
    pub const mxNegPx = GeneratedStyledMethods.mxNegPx;
    pub const mxFull = GeneratedStyledMethods.mxFull;
    pub const mxNegFull = GeneratedStyledMethods.mxNegFull;
    pub const mx1_2 = GeneratedStyledMethods.mx1_2;
    pub const mxNeg1_2 = GeneratedStyledMethods.mxNeg1_2;
    pub const mx1_3 = GeneratedStyledMethods.mx1_3;
    pub const mxNeg1_3 = GeneratedStyledMethods.mxNeg1_3;
    pub const mx2_3 = GeneratedStyledMethods.mx2_3;
    pub const mxNeg2_3 = GeneratedStyledMethods.mxNeg2_3;
    pub const mx1_4 = GeneratedStyledMethods.mx1_4;
    pub const mxNeg1_4 = GeneratedStyledMethods.mxNeg1_4;
    pub const mx2_4 = GeneratedStyledMethods.mx2_4;
    pub const mxNeg2_4 = GeneratedStyledMethods.mxNeg2_4;
    pub const mx3_4 = GeneratedStyledMethods.mx3_4;
    pub const mxNeg3_4 = GeneratedStyledMethods.mxNeg3_4;
    pub const mx1_5 = GeneratedStyledMethods.mx1_5;
    pub const mxNeg1_5 = GeneratedStyledMethods.mxNeg1_5;
    pub const mx2_5 = GeneratedStyledMethods.mx2_5;
    pub const mxNeg2_5 = GeneratedStyledMethods.mxNeg2_5;
    pub const mx3_5 = GeneratedStyledMethods.mx3_5;
    pub const mxNeg3_5 = GeneratedStyledMethods.mxNeg3_5;
    pub const mx4_5 = GeneratedStyledMethods.mx4_5;
    pub const mxNeg4_5 = GeneratedStyledMethods.mxNeg4_5;
    pub const mx1_6 = GeneratedStyledMethods.mx1_6;
    pub const mxNeg1_6 = GeneratedStyledMethods.mxNeg1_6;
    pub const mx5_6 = GeneratedStyledMethods.mx5_6;
    pub const mxNeg5_6 = GeneratedStyledMethods.mxNeg5_6;
    pub const mx1_12 = GeneratedStyledMethods.mx1_12;
    pub const mxNeg1_12 = GeneratedStyledMethods.mxNeg1_12;
    pub const ml = GeneratedStyledMethods.ml;
    pub const ml0 = GeneratedStyledMethods.ml0;
    pub const mlNeg0 = GeneratedStyledMethods.mlNeg0;
    pub const ml0p5 = GeneratedStyledMethods.ml0p5;
    pub const mlNeg0p5 = GeneratedStyledMethods.mlNeg0p5;
    pub const ml1 = GeneratedStyledMethods.ml1;
    pub const mlNeg1 = GeneratedStyledMethods.mlNeg1;
    pub const ml1p5 = GeneratedStyledMethods.ml1p5;
    pub const mlNeg1p5 = GeneratedStyledMethods.mlNeg1p5;
    pub const ml2 = GeneratedStyledMethods.ml2;
    pub const mlNeg2 = GeneratedStyledMethods.mlNeg2;
    pub const ml2p5 = GeneratedStyledMethods.ml2p5;
    pub const mlNeg2p5 = GeneratedStyledMethods.mlNeg2p5;
    pub const ml3 = GeneratedStyledMethods.ml3;
    pub const mlNeg3 = GeneratedStyledMethods.mlNeg3;
    pub const ml3p5 = GeneratedStyledMethods.ml3p5;
    pub const mlNeg3p5 = GeneratedStyledMethods.mlNeg3p5;
    pub const ml4 = GeneratedStyledMethods.ml4;
    pub const mlNeg4 = GeneratedStyledMethods.mlNeg4;
    pub const ml5 = GeneratedStyledMethods.ml5;
    pub const mlNeg5 = GeneratedStyledMethods.mlNeg5;
    pub const ml6 = GeneratedStyledMethods.ml6;
    pub const mlNeg6 = GeneratedStyledMethods.mlNeg6;
    pub const ml7 = GeneratedStyledMethods.ml7;
    pub const mlNeg7 = GeneratedStyledMethods.mlNeg7;
    pub const ml8 = GeneratedStyledMethods.ml8;
    pub const mlNeg8 = GeneratedStyledMethods.mlNeg8;
    pub const ml9 = GeneratedStyledMethods.ml9;
    pub const mlNeg9 = GeneratedStyledMethods.mlNeg9;
    pub const ml10 = GeneratedStyledMethods.ml10;
    pub const mlNeg10 = GeneratedStyledMethods.mlNeg10;
    pub const ml11 = GeneratedStyledMethods.ml11;
    pub const mlNeg11 = GeneratedStyledMethods.mlNeg11;
    pub const ml12 = GeneratedStyledMethods.ml12;
    pub const mlNeg12 = GeneratedStyledMethods.mlNeg12;
    pub const ml16 = GeneratedStyledMethods.ml16;
    pub const mlNeg16 = GeneratedStyledMethods.mlNeg16;
    pub const ml20 = GeneratedStyledMethods.ml20;
    pub const mlNeg20 = GeneratedStyledMethods.mlNeg20;
    pub const ml24 = GeneratedStyledMethods.ml24;
    pub const mlNeg24 = GeneratedStyledMethods.mlNeg24;
    pub const ml32 = GeneratedStyledMethods.ml32;
    pub const mlNeg32 = GeneratedStyledMethods.mlNeg32;
    pub const ml40 = GeneratedStyledMethods.ml40;
    pub const mlNeg40 = GeneratedStyledMethods.mlNeg40;
    pub const ml48 = GeneratedStyledMethods.ml48;
    pub const mlNeg48 = GeneratedStyledMethods.mlNeg48;
    pub const ml56 = GeneratedStyledMethods.ml56;
    pub const mlNeg56 = GeneratedStyledMethods.mlNeg56;
    pub const ml64 = GeneratedStyledMethods.ml64;
    pub const mlNeg64 = GeneratedStyledMethods.mlNeg64;
    pub const ml72 = GeneratedStyledMethods.ml72;
    pub const mlNeg72 = GeneratedStyledMethods.mlNeg72;
    pub const ml80 = GeneratedStyledMethods.ml80;
    pub const mlNeg80 = GeneratedStyledMethods.mlNeg80;
    pub const ml96 = GeneratedStyledMethods.ml96;
    pub const mlNeg96 = GeneratedStyledMethods.mlNeg96;
    pub const ml112 = GeneratedStyledMethods.ml112;
    pub const mlNeg112 = GeneratedStyledMethods.mlNeg112;
    pub const ml128 = GeneratedStyledMethods.ml128;
    pub const mlNeg128 = GeneratedStyledMethods.mlNeg128;
    pub const mlAuto = GeneratedStyledMethods.mlAuto;
    pub const mlPx = GeneratedStyledMethods.mlPx;
    pub const mlNegPx = GeneratedStyledMethods.mlNegPx;
    pub const mlFull = GeneratedStyledMethods.mlFull;
    pub const mlNegFull = GeneratedStyledMethods.mlNegFull;
    pub const ml1_2 = GeneratedStyledMethods.ml1_2;
    pub const mlNeg1_2 = GeneratedStyledMethods.mlNeg1_2;
    pub const ml1_3 = GeneratedStyledMethods.ml1_3;
    pub const mlNeg1_3 = GeneratedStyledMethods.mlNeg1_3;
    pub const ml2_3 = GeneratedStyledMethods.ml2_3;
    pub const mlNeg2_3 = GeneratedStyledMethods.mlNeg2_3;
    pub const ml1_4 = GeneratedStyledMethods.ml1_4;
    pub const mlNeg1_4 = GeneratedStyledMethods.mlNeg1_4;
    pub const ml2_4 = GeneratedStyledMethods.ml2_4;
    pub const mlNeg2_4 = GeneratedStyledMethods.mlNeg2_4;
    pub const ml3_4 = GeneratedStyledMethods.ml3_4;
    pub const mlNeg3_4 = GeneratedStyledMethods.mlNeg3_4;
    pub const ml1_5 = GeneratedStyledMethods.ml1_5;
    pub const mlNeg1_5 = GeneratedStyledMethods.mlNeg1_5;
    pub const ml2_5 = GeneratedStyledMethods.ml2_5;
    pub const mlNeg2_5 = GeneratedStyledMethods.mlNeg2_5;
    pub const ml3_5 = GeneratedStyledMethods.ml3_5;
    pub const mlNeg3_5 = GeneratedStyledMethods.mlNeg3_5;
    pub const ml4_5 = GeneratedStyledMethods.ml4_5;
    pub const mlNeg4_5 = GeneratedStyledMethods.mlNeg4_5;
    pub const ml1_6 = GeneratedStyledMethods.ml1_6;
    pub const mlNeg1_6 = GeneratedStyledMethods.mlNeg1_6;
    pub const ml5_6 = GeneratedStyledMethods.ml5_6;
    pub const mlNeg5_6 = GeneratedStyledMethods.mlNeg5_6;
    pub const ml1_12 = GeneratedStyledMethods.ml1_12;
    pub const mlNeg1_12 = GeneratedStyledMethods.mlNeg1_12;
    pub const mr = GeneratedStyledMethods.mr;
    pub const mr0 = GeneratedStyledMethods.mr0;
    pub const mrNeg0 = GeneratedStyledMethods.mrNeg0;
    pub const mr0p5 = GeneratedStyledMethods.mr0p5;
    pub const mrNeg0p5 = GeneratedStyledMethods.mrNeg0p5;
    pub const mr1 = GeneratedStyledMethods.mr1;
    pub const mrNeg1 = GeneratedStyledMethods.mrNeg1;
    pub const mr1p5 = GeneratedStyledMethods.mr1p5;
    pub const mrNeg1p5 = GeneratedStyledMethods.mrNeg1p5;
    pub const mr2 = GeneratedStyledMethods.mr2;
    pub const mrNeg2 = GeneratedStyledMethods.mrNeg2;
    pub const mr2p5 = GeneratedStyledMethods.mr2p5;
    pub const mrNeg2p5 = GeneratedStyledMethods.mrNeg2p5;
    pub const mr3 = GeneratedStyledMethods.mr3;
    pub const mrNeg3 = GeneratedStyledMethods.mrNeg3;
    pub const mr3p5 = GeneratedStyledMethods.mr3p5;
    pub const mrNeg3p5 = GeneratedStyledMethods.mrNeg3p5;
    pub const mr4 = GeneratedStyledMethods.mr4;
    pub const mrNeg4 = GeneratedStyledMethods.mrNeg4;
    pub const mr5 = GeneratedStyledMethods.mr5;
    pub const mrNeg5 = GeneratedStyledMethods.mrNeg5;
    pub const mr6 = GeneratedStyledMethods.mr6;
    pub const mrNeg6 = GeneratedStyledMethods.mrNeg6;
    pub const mr7 = GeneratedStyledMethods.mr7;
    pub const mrNeg7 = GeneratedStyledMethods.mrNeg7;
    pub const mr8 = GeneratedStyledMethods.mr8;
    pub const mrNeg8 = GeneratedStyledMethods.mrNeg8;
    pub const mr9 = GeneratedStyledMethods.mr9;
    pub const mrNeg9 = GeneratedStyledMethods.mrNeg9;
    pub const mr10 = GeneratedStyledMethods.mr10;
    pub const mrNeg10 = GeneratedStyledMethods.mrNeg10;
    pub const mr11 = GeneratedStyledMethods.mr11;
    pub const mrNeg11 = GeneratedStyledMethods.mrNeg11;
    pub const mr12 = GeneratedStyledMethods.mr12;
    pub const mrNeg12 = GeneratedStyledMethods.mrNeg12;
    pub const mr16 = GeneratedStyledMethods.mr16;
    pub const mrNeg16 = GeneratedStyledMethods.mrNeg16;
    pub const mr20 = GeneratedStyledMethods.mr20;
    pub const mrNeg20 = GeneratedStyledMethods.mrNeg20;
    pub const mr24 = GeneratedStyledMethods.mr24;
    pub const mrNeg24 = GeneratedStyledMethods.mrNeg24;
    pub const mr32 = GeneratedStyledMethods.mr32;
    pub const mrNeg32 = GeneratedStyledMethods.mrNeg32;
    pub const mr40 = GeneratedStyledMethods.mr40;
    pub const mrNeg40 = GeneratedStyledMethods.mrNeg40;
    pub const mr48 = GeneratedStyledMethods.mr48;
    pub const mrNeg48 = GeneratedStyledMethods.mrNeg48;
    pub const mr56 = GeneratedStyledMethods.mr56;
    pub const mrNeg56 = GeneratedStyledMethods.mrNeg56;
    pub const mr64 = GeneratedStyledMethods.mr64;
    pub const mrNeg64 = GeneratedStyledMethods.mrNeg64;
    pub const mr72 = GeneratedStyledMethods.mr72;
    pub const mrNeg72 = GeneratedStyledMethods.mrNeg72;
    pub const mr80 = GeneratedStyledMethods.mr80;
    pub const mrNeg80 = GeneratedStyledMethods.mrNeg80;
    pub const mr96 = GeneratedStyledMethods.mr96;
    pub const mrNeg96 = GeneratedStyledMethods.mrNeg96;
    pub const mr112 = GeneratedStyledMethods.mr112;
    pub const mrNeg112 = GeneratedStyledMethods.mrNeg112;
    pub const mr128 = GeneratedStyledMethods.mr128;
    pub const mrNeg128 = GeneratedStyledMethods.mrNeg128;
    pub const mrAuto = GeneratedStyledMethods.mrAuto;
    pub const mrPx = GeneratedStyledMethods.mrPx;
    pub const mrNegPx = GeneratedStyledMethods.mrNegPx;
    pub const mrFull = GeneratedStyledMethods.mrFull;
    pub const mrNegFull = GeneratedStyledMethods.mrNegFull;
    pub const mr1_2 = GeneratedStyledMethods.mr1_2;
    pub const mrNeg1_2 = GeneratedStyledMethods.mrNeg1_2;
    pub const mr1_3 = GeneratedStyledMethods.mr1_3;
    pub const mrNeg1_3 = GeneratedStyledMethods.mrNeg1_3;
    pub const mr2_3 = GeneratedStyledMethods.mr2_3;
    pub const mrNeg2_3 = GeneratedStyledMethods.mrNeg2_3;
    pub const mr1_4 = GeneratedStyledMethods.mr1_4;
    pub const mrNeg1_4 = GeneratedStyledMethods.mrNeg1_4;
    pub const mr2_4 = GeneratedStyledMethods.mr2_4;
    pub const mrNeg2_4 = GeneratedStyledMethods.mrNeg2_4;
    pub const mr3_4 = GeneratedStyledMethods.mr3_4;
    pub const mrNeg3_4 = GeneratedStyledMethods.mrNeg3_4;
    pub const mr1_5 = GeneratedStyledMethods.mr1_5;
    pub const mrNeg1_5 = GeneratedStyledMethods.mrNeg1_5;
    pub const mr2_5 = GeneratedStyledMethods.mr2_5;
    pub const mrNeg2_5 = GeneratedStyledMethods.mrNeg2_5;
    pub const mr3_5 = GeneratedStyledMethods.mr3_5;
    pub const mrNeg3_5 = GeneratedStyledMethods.mrNeg3_5;
    pub const mr4_5 = GeneratedStyledMethods.mr4_5;
    pub const mrNeg4_5 = GeneratedStyledMethods.mrNeg4_5;
    pub const mr1_6 = GeneratedStyledMethods.mr1_6;
    pub const mrNeg1_6 = GeneratedStyledMethods.mrNeg1_6;
    pub const mr5_6 = GeneratedStyledMethods.mr5_6;
    pub const mrNeg5_6 = GeneratedStyledMethods.mrNeg5_6;
    pub const mr1_12 = GeneratedStyledMethods.mr1_12;
    pub const mrNeg1_12 = GeneratedStyledMethods.mrNeg1_12;
    pub const p = GeneratedStyledMethods.p;
    pub const p0 = GeneratedStyledMethods.p0;
    pub const p0p5 = GeneratedStyledMethods.p0p5;
    pub const p1 = GeneratedStyledMethods.p1;
    pub const p1p5 = GeneratedStyledMethods.p1p5;
    pub const p2 = GeneratedStyledMethods.p2;
    pub const p2p5 = GeneratedStyledMethods.p2p5;
    pub const p3 = GeneratedStyledMethods.p3;
    pub const p3p5 = GeneratedStyledMethods.p3p5;
    pub const p4 = GeneratedStyledMethods.p4;
    pub const p5 = GeneratedStyledMethods.p5;
    pub const p6 = GeneratedStyledMethods.p6;
    pub const p7 = GeneratedStyledMethods.p7;
    pub const p8 = GeneratedStyledMethods.p8;
    pub const p9 = GeneratedStyledMethods.p9;
    pub const p10 = GeneratedStyledMethods.p10;
    pub const p11 = GeneratedStyledMethods.p11;
    pub const p12 = GeneratedStyledMethods.p12;
    pub const p16 = GeneratedStyledMethods.p16;
    pub const p20 = GeneratedStyledMethods.p20;
    pub const p24 = GeneratedStyledMethods.p24;
    pub const p32 = GeneratedStyledMethods.p32;
    pub const p40 = GeneratedStyledMethods.p40;
    pub const p48 = GeneratedStyledMethods.p48;
    pub const p56 = GeneratedStyledMethods.p56;
    pub const p64 = GeneratedStyledMethods.p64;
    pub const p72 = GeneratedStyledMethods.p72;
    pub const p80 = GeneratedStyledMethods.p80;
    pub const p96 = GeneratedStyledMethods.p96;
    pub const p112 = GeneratedStyledMethods.p112;
    pub const p128 = GeneratedStyledMethods.p128;
    pub const pPx = GeneratedStyledMethods.pPx;
    pub const pFull = GeneratedStyledMethods.pFull;
    pub const p1_2 = GeneratedStyledMethods.p1_2;
    pub const p1_3 = GeneratedStyledMethods.p1_3;
    pub const p2_3 = GeneratedStyledMethods.p2_3;
    pub const p1_4 = GeneratedStyledMethods.p1_4;
    pub const p2_4 = GeneratedStyledMethods.p2_4;
    pub const p3_4 = GeneratedStyledMethods.p3_4;
    pub const p1_5 = GeneratedStyledMethods.p1_5;
    pub const p2_5 = GeneratedStyledMethods.p2_5;
    pub const p3_5 = GeneratedStyledMethods.p3_5;
    pub const p4_5 = GeneratedStyledMethods.p4_5;
    pub const p1_6 = GeneratedStyledMethods.p1_6;
    pub const p5_6 = GeneratedStyledMethods.p5_6;
    pub const p1_12 = GeneratedStyledMethods.p1_12;
    pub const pt = GeneratedStyledMethods.pt;
    pub const pt0 = GeneratedStyledMethods.pt0;
    pub const pt0p5 = GeneratedStyledMethods.pt0p5;
    pub const pt1 = GeneratedStyledMethods.pt1;
    pub const pt1p5 = GeneratedStyledMethods.pt1p5;
    pub const pt2 = GeneratedStyledMethods.pt2;
    pub const pt2p5 = GeneratedStyledMethods.pt2p5;
    pub const pt3 = GeneratedStyledMethods.pt3;
    pub const pt3p5 = GeneratedStyledMethods.pt3p5;
    pub const pt4 = GeneratedStyledMethods.pt4;
    pub const pt5 = GeneratedStyledMethods.pt5;
    pub const pt6 = GeneratedStyledMethods.pt6;
    pub const pt7 = GeneratedStyledMethods.pt7;
    pub const pt8 = GeneratedStyledMethods.pt8;
    pub const pt9 = GeneratedStyledMethods.pt9;
    pub const pt10 = GeneratedStyledMethods.pt10;
    pub const pt11 = GeneratedStyledMethods.pt11;
    pub const pt12 = GeneratedStyledMethods.pt12;
    pub const pt16 = GeneratedStyledMethods.pt16;
    pub const pt20 = GeneratedStyledMethods.pt20;
    pub const pt24 = GeneratedStyledMethods.pt24;
    pub const pt32 = GeneratedStyledMethods.pt32;
    pub const pt40 = GeneratedStyledMethods.pt40;
    pub const pt48 = GeneratedStyledMethods.pt48;
    pub const pt56 = GeneratedStyledMethods.pt56;
    pub const pt64 = GeneratedStyledMethods.pt64;
    pub const pt72 = GeneratedStyledMethods.pt72;
    pub const pt80 = GeneratedStyledMethods.pt80;
    pub const pt96 = GeneratedStyledMethods.pt96;
    pub const pt112 = GeneratedStyledMethods.pt112;
    pub const pt128 = GeneratedStyledMethods.pt128;
    pub const ptPx = GeneratedStyledMethods.ptPx;
    pub const ptFull = GeneratedStyledMethods.ptFull;
    pub const pt1_2 = GeneratedStyledMethods.pt1_2;
    pub const pt1_3 = GeneratedStyledMethods.pt1_3;
    pub const pt2_3 = GeneratedStyledMethods.pt2_3;
    pub const pt1_4 = GeneratedStyledMethods.pt1_4;
    pub const pt2_4 = GeneratedStyledMethods.pt2_4;
    pub const pt3_4 = GeneratedStyledMethods.pt3_4;
    pub const pt1_5 = GeneratedStyledMethods.pt1_5;
    pub const pt2_5 = GeneratedStyledMethods.pt2_5;
    pub const pt3_5 = GeneratedStyledMethods.pt3_5;
    pub const pt4_5 = GeneratedStyledMethods.pt4_5;
    pub const pt1_6 = GeneratedStyledMethods.pt1_6;
    pub const pt5_6 = GeneratedStyledMethods.pt5_6;
    pub const pt1_12 = GeneratedStyledMethods.pt1_12;
    pub const pb = GeneratedStyledMethods.pb;
    pub const pb0 = GeneratedStyledMethods.pb0;
    pub const pb0p5 = GeneratedStyledMethods.pb0p5;
    pub const pb1 = GeneratedStyledMethods.pb1;
    pub const pb1p5 = GeneratedStyledMethods.pb1p5;
    pub const pb2 = GeneratedStyledMethods.pb2;
    pub const pb2p5 = GeneratedStyledMethods.pb2p5;
    pub const pb3 = GeneratedStyledMethods.pb3;
    pub const pb3p5 = GeneratedStyledMethods.pb3p5;
    pub const pb4 = GeneratedStyledMethods.pb4;
    pub const pb5 = GeneratedStyledMethods.pb5;
    pub const pb6 = GeneratedStyledMethods.pb6;
    pub const pb7 = GeneratedStyledMethods.pb7;
    pub const pb8 = GeneratedStyledMethods.pb8;
    pub const pb9 = GeneratedStyledMethods.pb9;
    pub const pb10 = GeneratedStyledMethods.pb10;
    pub const pb11 = GeneratedStyledMethods.pb11;
    pub const pb12 = GeneratedStyledMethods.pb12;
    pub const pb16 = GeneratedStyledMethods.pb16;
    pub const pb20 = GeneratedStyledMethods.pb20;
    pub const pb24 = GeneratedStyledMethods.pb24;
    pub const pb32 = GeneratedStyledMethods.pb32;
    pub const pb40 = GeneratedStyledMethods.pb40;
    pub const pb48 = GeneratedStyledMethods.pb48;
    pub const pb56 = GeneratedStyledMethods.pb56;
    pub const pb64 = GeneratedStyledMethods.pb64;
    pub const pb72 = GeneratedStyledMethods.pb72;
    pub const pb80 = GeneratedStyledMethods.pb80;
    pub const pb96 = GeneratedStyledMethods.pb96;
    pub const pb112 = GeneratedStyledMethods.pb112;
    pub const pb128 = GeneratedStyledMethods.pb128;
    pub const pbPx = GeneratedStyledMethods.pbPx;
    pub const pbFull = GeneratedStyledMethods.pbFull;
    pub const pb1_2 = GeneratedStyledMethods.pb1_2;
    pub const pb1_3 = GeneratedStyledMethods.pb1_3;
    pub const pb2_3 = GeneratedStyledMethods.pb2_3;
    pub const pb1_4 = GeneratedStyledMethods.pb1_4;
    pub const pb2_4 = GeneratedStyledMethods.pb2_4;
    pub const pb3_4 = GeneratedStyledMethods.pb3_4;
    pub const pb1_5 = GeneratedStyledMethods.pb1_5;
    pub const pb2_5 = GeneratedStyledMethods.pb2_5;
    pub const pb3_5 = GeneratedStyledMethods.pb3_5;
    pub const pb4_5 = GeneratedStyledMethods.pb4_5;
    pub const pb1_6 = GeneratedStyledMethods.pb1_6;
    pub const pb5_6 = GeneratedStyledMethods.pb5_6;
    pub const pb1_12 = GeneratedStyledMethods.pb1_12;
    pub const px = GeneratedStyledMethods.px;
    pub const px0 = GeneratedStyledMethods.px0;
    pub const px0p5 = GeneratedStyledMethods.px0p5;
    pub const px1 = GeneratedStyledMethods.px1;
    pub const px1p5 = GeneratedStyledMethods.px1p5;
    pub const px2 = GeneratedStyledMethods.px2;
    pub const px2p5 = GeneratedStyledMethods.px2p5;
    pub const px3 = GeneratedStyledMethods.px3;
    pub const px3p5 = GeneratedStyledMethods.px3p5;
    pub const px4 = GeneratedStyledMethods.px4;
    pub const px5 = GeneratedStyledMethods.px5;
    pub const px6 = GeneratedStyledMethods.px6;
    pub const px7 = GeneratedStyledMethods.px7;
    pub const px8 = GeneratedStyledMethods.px8;
    pub const px9 = GeneratedStyledMethods.px9;
    pub const px10 = GeneratedStyledMethods.px10;
    pub const px11 = GeneratedStyledMethods.px11;
    pub const px12 = GeneratedStyledMethods.px12;
    pub const px16 = GeneratedStyledMethods.px16;
    pub const px20 = GeneratedStyledMethods.px20;
    pub const px24 = GeneratedStyledMethods.px24;
    pub const px32 = GeneratedStyledMethods.px32;
    pub const px40 = GeneratedStyledMethods.px40;
    pub const px48 = GeneratedStyledMethods.px48;
    pub const px56 = GeneratedStyledMethods.px56;
    pub const px64 = GeneratedStyledMethods.px64;
    pub const px72 = GeneratedStyledMethods.px72;
    pub const px80 = GeneratedStyledMethods.px80;
    pub const px96 = GeneratedStyledMethods.px96;
    pub const px112 = GeneratedStyledMethods.px112;
    pub const px128 = GeneratedStyledMethods.px128;
    pub const pxPx = GeneratedStyledMethods.pxPx;
    pub const pxFull = GeneratedStyledMethods.pxFull;
    pub const px1_2 = GeneratedStyledMethods.px1_2;
    pub const px1_3 = GeneratedStyledMethods.px1_3;
    pub const px2_3 = GeneratedStyledMethods.px2_3;
    pub const px1_4 = GeneratedStyledMethods.px1_4;
    pub const px2_4 = GeneratedStyledMethods.px2_4;
    pub const px3_4 = GeneratedStyledMethods.px3_4;
    pub const px1_5 = GeneratedStyledMethods.px1_5;
    pub const px2_5 = GeneratedStyledMethods.px2_5;
    pub const px3_5 = GeneratedStyledMethods.px3_5;
    pub const px4_5 = GeneratedStyledMethods.px4_5;
    pub const px1_6 = GeneratedStyledMethods.px1_6;
    pub const px5_6 = GeneratedStyledMethods.px5_6;
    pub const px1_12 = GeneratedStyledMethods.px1_12;
    pub const py = GeneratedStyledMethods.py;
    pub const py0 = GeneratedStyledMethods.py0;
    pub const py0p5 = GeneratedStyledMethods.py0p5;
    pub const py1 = GeneratedStyledMethods.py1;
    pub const py1p5 = GeneratedStyledMethods.py1p5;
    pub const py2 = GeneratedStyledMethods.py2;
    pub const py2p5 = GeneratedStyledMethods.py2p5;
    pub const py3 = GeneratedStyledMethods.py3;
    pub const py3p5 = GeneratedStyledMethods.py3p5;
    pub const py4 = GeneratedStyledMethods.py4;
    pub const py5 = GeneratedStyledMethods.py5;
    pub const py6 = GeneratedStyledMethods.py6;
    pub const py7 = GeneratedStyledMethods.py7;
    pub const py8 = GeneratedStyledMethods.py8;
    pub const py9 = GeneratedStyledMethods.py9;
    pub const py10 = GeneratedStyledMethods.py10;
    pub const py11 = GeneratedStyledMethods.py11;
    pub const py12 = GeneratedStyledMethods.py12;
    pub const py16 = GeneratedStyledMethods.py16;
    pub const py20 = GeneratedStyledMethods.py20;
    pub const py24 = GeneratedStyledMethods.py24;
    pub const py32 = GeneratedStyledMethods.py32;
    pub const py40 = GeneratedStyledMethods.py40;
    pub const py48 = GeneratedStyledMethods.py48;
    pub const py56 = GeneratedStyledMethods.py56;
    pub const py64 = GeneratedStyledMethods.py64;
    pub const py72 = GeneratedStyledMethods.py72;
    pub const py80 = GeneratedStyledMethods.py80;
    pub const py96 = GeneratedStyledMethods.py96;
    pub const py112 = GeneratedStyledMethods.py112;
    pub const py128 = GeneratedStyledMethods.py128;
    pub const pyPx = GeneratedStyledMethods.pyPx;
    pub const pyFull = GeneratedStyledMethods.pyFull;
    pub const py1_2 = GeneratedStyledMethods.py1_2;
    pub const py1_3 = GeneratedStyledMethods.py1_3;
    pub const py2_3 = GeneratedStyledMethods.py2_3;
    pub const py1_4 = GeneratedStyledMethods.py1_4;
    pub const py2_4 = GeneratedStyledMethods.py2_4;
    pub const py3_4 = GeneratedStyledMethods.py3_4;
    pub const py1_5 = GeneratedStyledMethods.py1_5;
    pub const py2_5 = GeneratedStyledMethods.py2_5;
    pub const py3_5 = GeneratedStyledMethods.py3_5;
    pub const py4_5 = GeneratedStyledMethods.py4_5;
    pub const py1_6 = GeneratedStyledMethods.py1_6;
    pub const py5_6 = GeneratedStyledMethods.py5_6;
    pub const py1_12 = GeneratedStyledMethods.py1_12;
    pub const pl = GeneratedStyledMethods.pl;
    pub const pl0 = GeneratedStyledMethods.pl0;
    pub const pl0p5 = GeneratedStyledMethods.pl0p5;
    pub const pl1 = GeneratedStyledMethods.pl1;
    pub const pl1p5 = GeneratedStyledMethods.pl1p5;
    pub const pl2 = GeneratedStyledMethods.pl2;
    pub const pl2p5 = GeneratedStyledMethods.pl2p5;
    pub const pl3 = GeneratedStyledMethods.pl3;
    pub const pl3p5 = GeneratedStyledMethods.pl3p5;
    pub const pl4 = GeneratedStyledMethods.pl4;
    pub const pl5 = GeneratedStyledMethods.pl5;
    pub const pl6 = GeneratedStyledMethods.pl6;
    pub const pl7 = GeneratedStyledMethods.pl7;
    pub const pl8 = GeneratedStyledMethods.pl8;
    pub const pl9 = GeneratedStyledMethods.pl9;
    pub const pl10 = GeneratedStyledMethods.pl10;
    pub const pl11 = GeneratedStyledMethods.pl11;
    pub const pl12 = GeneratedStyledMethods.pl12;
    pub const pl16 = GeneratedStyledMethods.pl16;
    pub const pl20 = GeneratedStyledMethods.pl20;
    pub const pl24 = GeneratedStyledMethods.pl24;
    pub const pl32 = GeneratedStyledMethods.pl32;
    pub const pl40 = GeneratedStyledMethods.pl40;
    pub const pl48 = GeneratedStyledMethods.pl48;
    pub const pl56 = GeneratedStyledMethods.pl56;
    pub const pl64 = GeneratedStyledMethods.pl64;
    pub const pl72 = GeneratedStyledMethods.pl72;
    pub const pl80 = GeneratedStyledMethods.pl80;
    pub const pl96 = GeneratedStyledMethods.pl96;
    pub const pl112 = GeneratedStyledMethods.pl112;
    pub const pl128 = GeneratedStyledMethods.pl128;
    pub const plPx = GeneratedStyledMethods.plPx;
    pub const plFull = GeneratedStyledMethods.plFull;
    pub const pl1_2 = GeneratedStyledMethods.pl1_2;
    pub const pl1_3 = GeneratedStyledMethods.pl1_3;
    pub const pl2_3 = GeneratedStyledMethods.pl2_3;
    pub const pl1_4 = GeneratedStyledMethods.pl1_4;
    pub const pl2_4 = GeneratedStyledMethods.pl2_4;
    pub const pl3_4 = GeneratedStyledMethods.pl3_4;
    pub const pl1_5 = GeneratedStyledMethods.pl1_5;
    pub const pl2_5 = GeneratedStyledMethods.pl2_5;
    pub const pl3_5 = GeneratedStyledMethods.pl3_5;
    pub const pl4_5 = GeneratedStyledMethods.pl4_5;
    pub const pl1_6 = GeneratedStyledMethods.pl1_6;
    pub const pl5_6 = GeneratedStyledMethods.pl5_6;
    pub const pl1_12 = GeneratedStyledMethods.pl1_12;
    pub const pr = GeneratedStyledMethods.pr;
    pub const pr0 = GeneratedStyledMethods.pr0;
    pub const pr0p5 = GeneratedStyledMethods.pr0p5;
    pub const pr1 = GeneratedStyledMethods.pr1;
    pub const pr1p5 = GeneratedStyledMethods.pr1p5;
    pub const pr2 = GeneratedStyledMethods.pr2;
    pub const pr2p5 = GeneratedStyledMethods.pr2p5;
    pub const pr3 = GeneratedStyledMethods.pr3;
    pub const pr3p5 = GeneratedStyledMethods.pr3p5;
    pub const pr4 = GeneratedStyledMethods.pr4;
    pub const pr5 = GeneratedStyledMethods.pr5;
    pub const pr6 = GeneratedStyledMethods.pr6;
    pub const pr7 = GeneratedStyledMethods.pr7;
    pub const pr8 = GeneratedStyledMethods.pr8;
    pub const pr9 = GeneratedStyledMethods.pr9;
    pub const pr10 = GeneratedStyledMethods.pr10;
    pub const pr11 = GeneratedStyledMethods.pr11;
    pub const pr12 = GeneratedStyledMethods.pr12;
    pub const pr16 = GeneratedStyledMethods.pr16;
    pub const pr20 = GeneratedStyledMethods.pr20;
    pub const pr24 = GeneratedStyledMethods.pr24;
    pub const pr32 = GeneratedStyledMethods.pr32;
    pub const pr40 = GeneratedStyledMethods.pr40;
    pub const pr48 = GeneratedStyledMethods.pr48;
    pub const pr56 = GeneratedStyledMethods.pr56;
    pub const pr64 = GeneratedStyledMethods.pr64;
    pub const pr72 = GeneratedStyledMethods.pr72;
    pub const pr80 = GeneratedStyledMethods.pr80;
    pub const pr96 = GeneratedStyledMethods.pr96;
    pub const pr112 = GeneratedStyledMethods.pr112;
    pub const pr128 = GeneratedStyledMethods.pr128;
    pub const prPx = GeneratedStyledMethods.prPx;
    pub const prFull = GeneratedStyledMethods.prFull;
    pub const pr1_2 = GeneratedStyledMethods.pr1_2;
    pub const pr1_3 = GeneratedStyledMethods.pr1_3;
    pub const pr2_3 = GeneratedStyledMethods.pr2_3;
    pub const pr1_4 = GeneratedStyledMethods.pr1_4;
    pub const pr2_4 = GeneratedStyledMethods.pr2_4;
    pub const pr3_4 = GeneratedStyledMethods.pr3_4;
    pub const pr1_5 = GeneratedStyledMethods.pr1_5;
    pub const pr2_5 = GeneratedStyledMethods.pr2_5;
    pub const pr3_5 = GeneratedStyledMethods.pr3_5;
    pub const pr4_5 = GeneratedStyledMethods.pr4_5;
    pub const pr1_6 = GeneratedStyledMethods.pr1_6;
    pub const pr5_6 = GeneratedStyledMethods.pr5_6;
    pub const pr1_12 = GeneratedStyledMethods.pr1_12;
    pub const inset = GeneratedStyledMethods.inset;
    pub const inset0 = GeneratedStyledMethods.inset0;
    pub const insetNeg0 = GeneratedStyledMethods.insetNeg0;
    pub const inset0p5 = GeneratedStyledMethods.inset0p5;
    pub const insetNeg0p5 = GeneratedStyledMethods.insetNeg0p5;
    pub const inset1 = GeneratedStyledMethods.inset1;
    pub const insetNeg1 = GeneratedStyledMethods.insetNeg1;
    pub const inset1p5 = GeneratedStyledMethods.inset1p5;
    pub const insetNeg1p5 = GeneratedStyledMethods.insetNeg1p5;
    pub const inset2 = GeneratedStyledMethods.inset2;
    pub const insetNeg2 = GeneratedStyledMethods.insetNeg2;
    pub const inset2p5 = GeneratedStyledMethods.inset2p5;
    pub const insetNeg2p5 = GeneratedStyledMethods.insetNeg2p5;
    pub const inset3 = GeneratedStyledMethods.inset3;
    pub const insetNeg3 = GeneratedStyledMethods.insetNeg3;
    pub const inset3p5 = GeneratedStyledMethods.inset3p5;
    pub const insetNeg3p5 = GeneratedStyledMethods.insetNeg3p5;
    pub const inset4 = GeneratedStyledMethods.inset4;
    pub const insetNeg4 = GeneratedStyledMethods.insetNeg4;
    pub const inset5 = GeneratedStyledMethods.inset5;
    pub const insetNeg5 = GeneratedStyledMethods.insetNeg5;
    pub const inset6 = GeneratedStyledMethods.inset6;
    pub const insetNeg6 = GeneratedStyledMethods.insetNeg6;
    pub const inset7 = GeneratedStyledMethods.inset7;
    pub const insetNeg7 = GeneratedStyledMethods.insetNeg7;
    pub const inset8 = GeneratedStyledMethods.inset8;
    pub const insetNeg8 = GeneratedStyledMethods.insetNeg8;
    pub const inset9 = GeneratedStyledMethods.inset9;
    pub const insetNeg9 = GeneratedStyledMethods.insetNeg9;
    pub const inset10 = GeneratedStyledMethods.inset10;
    pub const insetNeg10 = GeneratedStyledMethods.insetNeg10;
    pub const inset11 = GeneratedStyledMethods.inset11;
    pub const insetNeg11 = GeneratedStyledMethods.insetNeg11;
    pub const inset12 = GeneratedStyledMethods.inset12;
    pub const insetNeg12 = GeneratedStyledMethods.insetNeg12;
    pub const inset16 = GeneratedStyledMethods.inset16;
    pub const insetNeg16 = GeneratedStyledMethods.insetNeg16;
    pub const inset20 = GeneratedStyledMethods.inset20;
    pub const insetNeg20 = GeneratedStyledMethods.insetNeg20;
    pub const inset24 = GeneratedStyledMethods.inset24;
    pub const insetNeg24 = GeneratedStyledMethods.insetNeg24;
    pub const inset32 = GeneratedStyledMethods.inset32;
    pub const insetNeg32 = GeneratedStyledMethods.insetNeg32;
    pub const inset40 = GeneratedStyledMethods.inset40;
    pub const insetNeg40 = GeneratedStyledMethods.insetNeg40;
    pub const inset48 = GeneratedStyledMethods.inset48;
    pub const insetNeg48 = GeneratedStyledMethods.insetNeg48;
    pub const inset56 = GeneratedStyledMethods.inset56;
    pub const insetNeg56 = GeneratedStyledMethods.insetNeg56;
    pub const inset64 = GeneratedStyledMethods.inset64;
    pub const insetNeg64 = GeneratedStyledMethods.insetNeg64;
    pub const inset72 = GeneratedStyledMethods.inset72;
    pub const insetNeg72 = GeneratedStyledMethods.insetNeg72;
    pub const inset80 = GeneratedStyledMethods.inset80;
    pub const insetNeg80 = GeneratedStyledMethods.insetNeg80;
    pub const inset96 = GeneratedStyledMethods.inset96;
    pub const insetNeg96 = GeneratedStyledMethods.insetNeg96;
    pub const inset112 = GeneratedStyledMethods.inset112;
    pub const insetNeg112 = GeneratedStyledMethods.insetNeg112;
    pub const inset128 = GeneratedStyledMethods.inset128;
    pub const insetNeg128 = GeneratedStyledMethods.insetNeg128;
    pub const insetAuto = GeneratedStyledMethods.insetAuto;
    pub const insetPx = GeneratedStyledMethods.insetPx;
    pub const insetNegPx = GeneratedStyledMethods.insetNegPx;
    pub const insetFull = GeneratedStyledMethods.insetFull;
    pub const insetNegFull = GeneratedStyledMethods.insetNegFull;
    pub const inset1_2 = GeneratedStyledMethods.inset1_2;
    pub const insetNeg1_2 = GeneratedStyledMethods.insetNeg1_2;
    pub const inset1_3 = GeneratedStyledMethods.inset1_3;
    pub const insetNeg1_3 = GeneratedStyledMethods.insetNeg1_3;
    pub const inset2_3 = GeneratedStyledMethods.inset2_3;
    pub const insetNeg2_3 = GeneratedStyledMethods.insetNeg2_3;
    pub const inset1_4 = GeneratedStyledMethods.inset1_4;
    pub const insetNeg1_4 = GeneratedStyledMethods.insetNeg1_4;
    pub const inset2_4 = GeneratedStyledMethods.inset2_4;
    pub const insetNeg2_4 = GeneratedStyledMethods.insetNeg2_4;
    pub const inset3_4 = GeneratedStyledMethods.inset3_4;
    pub const insetNeg3_4 = GeneratedStyledMethods.insetNeg3_4;
    pub const inset1_5 = GeneratedStyledMethods.inset1_5;
    pub const insetNeg1_5 = GeneratedStyledMethods.insetNeg1_5;
    pub const inset2_5 = GeneratedStyledMethods.inset2_5;
    pub const insetNeg2_5 = GeneratedStyledMethods.insetNeg2_5;
    pub const inset3_5 = GeneratedStyledMethods.inset3_5;
    pub const insetNeg3_5 = GeneratedStyledMethods.insetNeg3_5;
    pub const inset4_5 = GeneratedStyledMethods.inset4_5;
    pub const insetNeg4_5 = GeneratedStyledMethods.insetNeg4_5;
    pub const inset1_6 = GeneratedStyledMethods.inset1_6;
    pub const insetNeg1_6 = GeneratedStyledMethods.insetNeg1_6;
    pub const inset5_6 = GeneratedStyledMethods.inset5_6;
    pub const insetNeg5_6 = GeneratedStyledMethods.insetNeg5_6;
    pub const inset1_12 = GeneratedStyledMethods.inset1_12;
    pub const insetNeg1_12 = GeneratedStyledMethods.insetNeg1_12;
    pub const top = GeneratedStyledMethods.top;
    pub const top0 = GeneratedStyledMethods.top0;
    pub const topNeg0 = GeneratedStyledMethods.topNeg0;
    pub const top0p5 = GeneratedStyledMethods.top0p5;
    pub const topNeg0p5 = GeneratedStyledMethods.topNeg0p5;
    pub const top1 = GeneratedStyledMethods.top1;
    pub const topNeg1 = GeneratedStyledMethods.topNeg1;
    pub const top1p5 = GeneratedStyledMethods.top1p5;
    pub const topNeg1p5 = GeneratedStyledMethods.topNeg1p5;
    pub const top2 = GeneratedStyledMethods.top2;
    pub const topNeg2 = GeneratedStyledMethods.topNeg2;
    pub const top2p5 = GeneratedStyledMethods.top2p5;
    pub const topNeg2p5 = GeneratedStyledMethods.topNeg2p5;
    pub const top3 = GeneratedStyledMethods.top3;
    pub const topNeg3 = GeneratedStyledMethods.topNeg3;
    pub const top3p5 = GeneratedStyledMethods.top3p5;
    pub const topNeg3p5 = GeneratedStyledMethods.topNeg3p5;
    pub const top4 = GeneratedStyledMethods.top4;
    pub const topNeg4 = GeneratedStyledMethods.topNeg4;
    pub const top5 = GeneratedStyledMethods.top5;
    pub const topNeg5 = GeneratedStyledMethods.topNeg5;
    pub const top6 = GeneratedStyledMethods.top6;
    pub const topNeg6 = GeneratedStyledMethods.topNeg6;
    pub const top7 = GeneratedStyledMethods.top7;
    pub const topNeg7 = GeneratedStyledMethods.topNeg7;
    pub const top8 = GeneratedStyledMethods.top8;
    pub const topNeg8 = GeneratedStyledMethods.topNeg8;
    pub const top9 = GeneratedStyledMethods.top9;
    pub const topNeg9 = GeneratedStyledMethods.topNeg9;
    pub const top10 = GeneratedStyledMethods.top10;
    pub const topNeg10 = GeneratedStyledMethods.topNeg10;
    pub const top11 = GeneratedStyledMethods.top11;
    pub const topNeg11 = GeneratedStyledMethods.topNeg11;
    pub const top12 = GeneratedStyledMethods.top12;
    pub const topNeg12 = GeneratedStyledMethods.topNeg12;
    pub const top16 = GeneratedStyledMethods.top16;
    pub const topNeg16 = GeneratedStyledMethods.topNeg16;
    pub const top20 = GeneratedStyledMethods.top20;
    pub const topNeg20 = GeneratedStyledMethods.topNeg20;
    pub const top24 = GeneratedStyledMethods.top24;
    pub const topNeg24 = GeneratedStyledMethods.topNeg24;
    pub const top32 = GeneratedStyledMethods.top32;
    pub const topNeg32 = GeneratedStyledMethods.topNeg32;
    pub const top40 = GeneratedStyledMethods.top40;
    pub const topNeg40 = GeneratedStyledMethods.topNeg40;
    pub const top48 = GeneratedStyledMethods.top48;
    pub const topNeg48 = GeneratedStyledMethods.topNeg48;
    pub const top56 = GeneratedStyledMethods.top56;
    pub const topNeg56 = GeneratedStyledMethods.topNeg56;
    pub const top64 = GeneratedStyledMethods.top64;
    pub const topNeg64 = GeneratedStyledMethods.topNeg64;
    pub const top72 = GeneratedStyledMethods.top72;
    pub const topNeg72 = GeneratedStyledMethods.topNeg72;
    pub const top80 = GeneratedStyledMethods.top80;
    pub const topNeg80 = GeneratedStyledMethods.topNeg80;
    pub const top96 = GeneratedStyledMethods.top96;
    pub const topNeg96 = GeneratedStyledMethods.topNeg96;
    pub const top112 = GeneratedStyledMethods.top112;
    pub const topNeg112 = GeneratedStyledMethods.topNeg112;
    pub const top128 = GeneratedStyledMethods.top128;
    pub const topNeg128 = GeneratedStyledMethods.topNeg128;
    pub const topAuto = GeneratedStyledMethods.topAuto;
    pub const topPx = GeneratedStyledMethods.topPx;
    pub const topNegPx = GeneratedStyledMethods.topNegPx;
    pub const topFull = GeneratedStyledMethods.topFull;
    pub const topNegFull = GeneratedStyledMethods.topNegFull;
    pub const top1_2 = GeneratedStyledMethods.top1_2;
    pub const topNeg1_2 = GeneratedStyledMethods.topNeg1_2;
    pub const top1_3 = GeneratedStyledMethods.top1_3;
    pub const topNeg1_3 = GeneratedStyledMethods.topNeg1_3;
    pub const top2_3 = GeneratedStyledMethods.top2_3;
    pub const topNeg2_3 = GeneratedStyledMethods.topNeg2_3;
    pub const top1_4 = GeneratedStyledMethods.top1_4;
    pub const topNeg1_4 = GeneratedStyledMethods.topNeg1_4;
    pub const top2_4 = GeneratedStyledMethods.top2_4;
    pub const topNeg2_4 = GeneratedStyledMethods.topNeg2_4;
    pub const top3_4 = GeneratedStyledMethods.top3_4;
    pub const topNeg3_4 = GeneratedStyledMethods.topNeg3_4;
    pub const top1_5 = GeneratedStyledMethods.top1_5;
    pub const topNeg1_5 = GeneratedStyledMethods.topNeg1_5;
    pub const top2_5 = GeneratedStyledMethods.top2_5;
    pub const topNeg2_5 = GeneratedStyledMethods.topNeg2_5;
    pub const top3_5 = GeneratedStyledMethods.top3_5;
    pub const topNeg3_5 = GeneratedStyledMethods.topNeg3_5;
    pub const top4_5 = GeneratedStyledMethods.top4_5;
    pub const topNeg4_5 = GeneratedStyledMethods.topNeg4_5;
    pub const top1_6 = GeneratedStyledMethods.top1_6;
    pub const topNeg1_6 = GeneratedStyledMethods.topNeg1_6;
    pub const top5_6 = GeneratedStyledMethods.top5_6;
    pub const topNeg5_6 = GeneratedStyledMethods.topNeg5_6;
    pub const top1_12 = GeneratedStyledMethods.top1_12;
    pub const topNeg1_12 = GeneratedStyledMethods.topNeg1_12;
    pub const bottom = GeneratedStyledMethods.bottom;
    pub const bottom0 = GeneratedStyledMethods.bottom0;
    pub const bottomNeg0 = GeneratedStyledMethods.bottomNeg0;
    pub const bottom0p5 = GeneratedStyledMethods.bottom0p5;
    pub const bottomNeg0p5 = GeneratedStyledMethods.bottomNeg0p5;
    pub const bottom1 = GeneratedStyledMethods.bottom1;
    pub const bottomNeg1 = GeneratedStyledMethods.bottomNeg1;
    pub const bottom1p5 = GeneratedStyledMethods.bottom1p5;
    pub const bottomNeg1p5 = GeneratedStyledMethods.bottomNeg1p5;
    pub const bottom2 = GeneratedStyledMethods.bottom2;
    pub const bottomNeg2 = GeneratedStyledMethods.bottomNeg2;
    pub const bottom2p5 = GeneratedStyledMethods.bottom2p5;
    pub const bottomNeg2p5 = GeneratedStyledMethods.bottomNeg2p5;
    pub const bottom3 = GeneratedStyledMethods.bottom3;
    pub const bottomNeg3 = GeneratedStyledMethods.bottomNeg3;
    pub const bottom3p5 = GeneratedStyledMethods.bottom3p5;
    pub const bottomNeg3p5 = GeneratedStyledMethods.bottomNeg3p5;
    pub const bottom4 = GeneratedStyledMethods.bottom4;
    pub const bottomNeg4 = GeneratedStyledMethods.bottomNeg4;
    pub const bottom5 = GeneratedStyledMethods.bottom5;
    pub const bottomNeg5 = GeneratedStyledMethods.bottomNeg5;
    pub const bottom6 = GeneratedStyledMethods.bottom6;
    pub const bottomNeg6 = GeneratedStyledMethods.bottomNeg6;
    pub const bottom7 = GeneratedStyledMethods.bottom7;
    pub const bottomNeg7 = GeneratedStyledMethods.bottomNeg7;
    pub const bottom8 = GeneratedStyledMethods.bottom8;
    pub const bottomNeg8 = GeneratedStyledMethods.bottomNeg8;
    pub const bottom9 = GeneratedStyledMethods.bottom9;
    pub const bottomNeg9 = GeneratedStyledMethods.bottomNeg9;
    pub const bottom10 = GeneratedStyledMethods.bottom10;
    pub const bottomNeg10 = GeneratedStyledMethods.bottomNeg10;
    pub const bottom11 = GeneratedStyledMethods.bottom11;
    pub const bottomNeg11 = GeneratedStyledMethods.bottomNeg11;
    pub const bottom12 = GeneratedStyledMethods.bottom12;
    pub const bottomNeg12 = GeneratedStyledMethods.bottomNeg12;
    pub const bottom16 = GeneratedStyledMethods.bottom16;
    pub const bottomNeg16 = GeneratedStyledMethods.bottomNeg16;
    pub const bottom20 = GeneratedStyledMethods.bottom20;
    pub const bottomNeg20 = GeneratedStyledMethods.bottomNeg20;
    pub const bottom24 = GeneratedStyledMethods.bottom24;
    pub const bottomNeg24 = GeneratedStyledMethods.bottomNeg24;
    pub const bottom32 = GeneratedStyledMethods.bottom32;
    pub const bottomNeg32 = GeneratedStyledMethods.bottomNeg32;
    pub const bottom40 = GeneratedStyledMethods.bottom40;
    pub const bottomNeg40 = GeneratedStyledMethods.bottomNeg40;
    pub const bottom48 = GeneratedStyledMethods.bottom48;
    pub const bottomNeg48 = GeneratedStyledMethods.bottomNeg48;
    pub const bottom56 = GeneratedStyledMethods.bottom56;
    pub const bottomNeg56 = GeneratedStyledMethods.bottomNeg56;
    pub const bottom64 = GeneratedStyledMethods.bottom64;
    pub const bottomNeg64 = GeneratedStyledMethods.bottomNeg64;
    pub const bottom72 = GeneratedStyledMethods.bottom72;
    pub const bottomNeg72 = GeneratedStyledMethods.bottomNeg72;
    pub const bottom80 = GeneratedStyledMethods.bottom80;
    pub const bottomNeg80 = GeneratedStyledMethods.bottomNeg80;
    pub const bottom96 = GeneratedStyledMethods.bottom96;
    pub const bottomNeg96 = GeneratedStyledMethods.bottomNeg96;
    pub const bottom112 = GeneratedStyledMethods.bottom112;
    pub const bottomNeg112 = GeneratedStyledMethods.bottomNeg112;
    pub const bottom128 = GeneratedStyledMethods.bottom128;
    pub const bottomNeg128 = GeneratedStyledMethods.bottomNeg128;
    pub const bottomAuto = GeneratedStyledMethods.bottomAuto;
    pub const bottomPx = GeneratedStyledMethods.bottomPx;
    pub const bottomNegPx = GeneratedStyledMethods.bottomNegPx;
    pub const bottomFull = GeneratedStyledMethods.bottomFull;
    pub const bottomNegFull = GeneratedStyledMethods.bottomNegFull;
    pub const bottom1_2 = GeneratedStyledMethods.bottom1_2;
    pub const bottomNeg1_2 = GeneratedStyledMethods.bottomNeg1_2;
    pub const bottom1_3 = GeneratedStyledMethods.bottom1_3;
    pub const bottomNeg1_3 = GeneratedStyledMethods.bottomNeg1_3;
    pub const bottom2_3 = GeneratedStyledMethods.bottom2_3;
    pub const bottomNeg2_3 = GeneratedStyledMethods.bottomNeg2_3;
    pub const bottom1_4 = GeneratedStyledMethods.bottom1_4;
    pub const bottomNeg1_4 = GeneratedStyledMethods.bottomNeg1_4;
    pub const bottom2_4 = GeneratedStyledMethods.bottom2_4;
    pub const bottomNeg2_4 = GeneratedStyledMethods.bottomNeg2_4;
    pub const bottom3_4 = GeneratedStyledMethods.bottom3_4;
    pub const bottomNeg3_4 = GeneratedStyledMethods.bottomNeg3_4;
    pub const bottom1_5 = GeneratedStyledMethods.bottom1_5;
    pub const bottomNeg1_5 = GeneratedStyledMethods.bottomNeg1_5;
    pub const bottom2_5 = GeneratedStyledMethods.bottom2_5;
    pub const bottomNeg2_5 = GeneratedStyledMethods.bottomNeg2_5;
    pub const bottom3_5 = GeneratedStyledMethods.bottom3_5;
    pub const bottomNeg3_5 = GeneratedStyledMethods.bottomNeg3_5;
    pub const bottom4_5 = GeneratedStyledMethods.bottom4_5;
    pub const bottomNeg4_5 = GeneratedStyledMethods.bottomNeg4_5;
    pub const bottom1_6 = GeneratedStyledMethods.bottom1_6;
    pub const bottomNeg1_6 = GeneratedStyledMethods.bottomNeg1_6;
    pub const bottom5_6 = GeneratedStyledMethods.bottom5_6;
    pub const bottomNeg5_6 = GeneratedStyledMethods.bottomNeg5_6;
    pub const bottom1_12 = GeneratedStyledMethods.bottom1_12;
    pub const bottomNeg1_12 = GeneratedStyledMethods.bottomNeg1_12;
    pub const left = GeneratedStyledMethods.left;
    pub const left0 = GeneratedStyledMethods.left0;
    pub const leftNeg0 = GeneratedStyledMethods.leftNeg0;
    pub const left0p5 = GeneratedStyledMethods.left0p5;
    pub const leftNeg0p5 = GeneratedStyledMethods.leftNeg0p5;
    pub const left1 = GeneratedStyledMethods.left1;
    pub const leftNeg1 = GeneratedStyledMethods.leftNeg1;
    pub const left1p5 = GeneratedStyledMethods.left1p5;
    pub const leftNeg1p5 = GeneratedStyledMethods.leftNeg1p5;
    pub const left2 = GeneratedStyledMethods.left2;
    pub const leftNeg2 = GeneratedStyledMethods.leftNeg2;
    pub const left2p5 = GeneratedStyledMethods.left2p5;
    pub const leftNeg2p5 = GeneratedStyledMethods.leftNeg2p5;
    pub const left3 = GeneratedStyledMethods.left3;
    pub const leftNeg3 = GeneratedStyledMethods.leftNeg3;
    pub const left3p5 = GeneratedStyledMethods.left3p5;
    pub const leftNeg3p5 = GeneratedStyledMethods.leftNeg3p5;
    pub const left4 = GeneratedStyledMethods.left4;
    pub const leftNeg4 = GeneratedStyledMethods.leftNeg4;
    pub const left5 = GeneratedStyledMethods.left5;
    pub const leftNeg5 = GeneratedStyledMethods.leftNeg5;
    pub const left6 = GeneratedStyledMethods.left6;
    pub const leftNeg6 = GeneratedStyledMethods.leftNeg6;
    pub const left7 = GeneratedStyledMethods.left7;
    pub const leftNeg7 = GeneratedStyledMethods.leftNeg7;
    pub const left8 = GeneratedStyledMethods.left8;
    pub const leftNeg8 = GeneratedStyledMethods.leftNeg8;
    pub const left9 = GeneratedStyledMethods.left9;
    pub const leftNeg9 = GeneratedStyledMethods.leftNeg9;
    pub const left10 = GeneratedStyledMethods.left10;
    pub const leftNeg10 = GeneratedStyledMethods.leftNeg10;
    pub const left11 = GeneratedStyledMethods.left11;
    pub const leftNeg11 = GeneratedStyledMethods.leftNeg11;
    pub const left12 = GeneratedStyledMethods.left12;
    pub const leftNeg12 = GeneratedStyledMethods.leftNeg12;
    pub const left16 = GeneratedStyledMethods.left16;
    pub const leftNeg16 = GeneratedStyledMethods.leftNeg16;
    pub const left20 = GeneratedStyledMethods.left20;
    pub const leftNeg20 = GeneratedStyledMethods.leftNeg20;
    pub const left24 = GeneratedStyledMethods.left24;
    pub const leftNeg24 = GeneratedStyledMethods.leftNeg24;
    pub const left32 = GeneratedStyledMethods.left32;
    pub const leftNeg32 = GeneratedStyledMethods.leftNeg32;
    pub const left40 = GeneratedStyledMethods.left40;
    pub const leftNeg40 = GeneratedStyledMethods.leftNeg40;
    pub const left48 = GeneratedStyledMethods.left48;
    pub const leftNeg48 = GeneratedStyledMethods.leftNeg48;
    pub const left56 = GeneratedStyledMethods.left56;
    pub const leftNeg56 = GeneratedStyledMethods.leftNeg56;
    pub const left64 = GeneratedStyledMethods.left64;
    pub const leftNeg64 = GeneratedStyledMethods.leftNeg64;
    pub const left72 = GeneratedStyledMethods.left72;
    pub const leftNeg72 = GeneratedStyledMethods.leftNeg72;
    pub const left80 = GeneratedStyledMethods.left80;
    pub const leftNeg80 = GeneratedStyledMethods.leftNeg80;
    pub const left96 = GeneratedStyledMethods.left96;
    pub const leftNeg96 = GeneratedStyledMethods.leftNeg96;
    pub const left112 = GeneratedStyledMethods.left112;
    pub const leftNeg112 = GeneratedStyledMethods.leftNeg112;
    pub const left128 = GeneratedStyledMethods.left128;
    pub const leftNeg128 = GeneratedStyledMethods.leftNeg128;
    pub const leftAuto = GeneratedStyledMethods.leftAuto;
    pub const leftPx = GeneratedStyledMethods.leftPx;
    pub const leftNegPx = GeneratedStyledMethods.leftNegPx;
    pub const leftFull = GeneratedStyledMethods.leftFull;
    pub const leftNegFull = GeneratedStyledMethods.leftNegFull;
    pub const left1_2 = GeneratedStyledMethods.left1_2;
    pub const leftNeg1_2 = GeneratedStyledMethods.leftNeg1_2;
    pub const left1_3 = GeneratedStyledMethods.left1_3;
    pub const leftNeg1_3 = GeneratedStyledMethods.leftNeg1_3;
    pub const left2_3 = GeneratedStyledMethods.left2_3;
    pub const leftNeg2_3 = GeneratedStyledMethods.leftNeg2_3;
    pub const left1_4 = GeneratedStyledMethods.left1_4;
    pub const leftNeg1_4 = GeneratedStyledMethods.leftNeg1_4;
    pub const left2_4 = GeneratedStyledMethods.left2_4;
    pub const leftNeg2_4 = GeneratedStyledMethods.leftNeg2_4;
    pub const left3_4 = GeneratedStyledMethods.left3_4;
    pub const leftNeg3_4 = GeneratedStyledMethods.leftNeg3_4;
    pub const left1_5 = GeneratedStyledMethods.left1_5;
    pub const leftNeg1_5 = GeneratedStyledMethods.leftNeg1_5;
    pub const left2_5 = GeneratedStyledMethods.left2_5;
    pub const leftNeg2_5 = GeneratedStyledMethods.leftNeg2_5;
    pub const left3_5 = GeneratedStyledMethods.left3_5;
    pub const leftNeg3_5 = GeneratedStyledMethods.leftNeg3_5;
    pub const left4_5 = GeneratedStyledMethods.left4_5;
    pub const leftNeg4_5 = GeneratedStyledMethods.leftNeg4_5;
    pub const left1_6 = GeneratedStyledMethods.left1_6;
    pub const leftNeg1_6 = GeneratedStyledMethods.leftNeg1_6;
    pub const left5_6 = GeneratedStyledMethods.left5_6;
    pub const leftNeg5_6 = GeneratedStyledMethods.leftNeg5_6;
    pub const left1_12 = GeneratedStyledMethods.left1_12;
    pub const leftNeg1_12 = GeneratedStyledMethods.leftNeg1_12;
    pub const right = GeneratedStyledMethods.right;
    pub const right0 = GeneratedStyledMethods.right0;
    pub const rightNeg0 = GeneratedStyledMethods.rightNeg0;
    pub const right0p5 = GeneratedStyledMethods.right0p5;
    pub const rightNeg0p5 = GeneratedStyledMethods.rightNeg0p5;
    pub const right1 = GeneratedStyledMethods.right1;
    pub const rightNeg1 = GeneratedStyledMethods.rightNeg1;
    pub const right1p5 = GeneratedStyledMethods.right1p5;
    pub const rightNeg1p5 = GeneratedStyledMethods.rightNeg1p5;
    pub const right2 = GeneratedStyledMethods.right2;
    pub const rightNeg2 = GeneratedStyledMethods.rightNeg2;
    pub const right2p5 = GeneratedStyledMethods.right2p5;
    pub const rightNeg2p5 = GeneratedStyledMethods.rightNeg2p5;
    pub const right3 = GeneratedStyledMethods.right3;
    pub const rightNeg3 = GeneratedStyledMethods.rightNeg3;
    pub const right3p5 = GeneratedStyledMethods.right3p5;
    pub const rightNeg3p5 = GeneratedStyledMethods.rightNeg3p5;
    pub const right4 = GeneratedStyledMethods.right4;
    pub const rightNeg4 = GeneratedStyledMethods.rightNeg4;
    pub const right5 = GeneratedStyledMethods.right5;
    pub const rightNeg5 = GeneratedStyledMethods.rightNeg5;
    pub const right6 = GeneratedStyledMethods.right6;
    pub const rightNeg6 = GeneratedStyledMethods.rightNeg6;
    pub const right7 = GeneratedStyledMethods.right7;
    pub const rightNeg7 = GeneratedStyledMethods.rightNeg7;
    pub const right8 = GeneratedStyledMethods.right8;
    pub const rightNeg8 = GeneratedStyledMethods.rightNeg8;
    pub const right9 = GeneratedStyledMethods.right9;
    pub const rightNeg9 = GeneratedStyledMethods.rightNeg9;
    pub const right10 = GeneratedStyledMethods.right10;
    pub const rightNeg10 = GeneratedStyledMethods.rightNeg10;
    pub const right11 = GeneratedStyledMethods.right11;
    pub const rightNeg11 = GeneratedStyledMethods.rightNeg11;
    pub const right12 = GeneratedStyledMethods.right12;
    pub const rightNeg12 = GeneratedStyledMethods.rightNeg12;
    pub const right16 = GeneratedStyledMethods.right16;
    pub const rightNeg16 = GeneratedStyledMethods.rightNeg16;
    pub const right20 = GeneratedStyledMethods.right20;
    pub const rightNeg20 = GeneratedStyledMethods.rightNeg20;
    pub const right24 = GeneratedStyledMethods.right24;
    pub const rightNeg24 = GeneratedStyledMethods.rightNeg24;
    pub const right32 = GeneratedStyledMethods.right32;
    pub const rightNeg32 = GeneratedStyledMethods.rightNeg32;
    pub const right40 = GeneratedStyledMethods.right40;
    pub const rightNeg40 = GeneratedStyledMethods.rightNeg40;
    pub const right48 = GeneratedStyledMethods.right48;
    pub const rightNeg48 = GeneratedStyledMethods.rightNeg48;
    pub const right56 = GeneratedStyledMethods.right56;
    pub const rightNeg56 = GeneratedStyledMethods.rightNeg56;
    pub const right64 = GeneratedStyledMethods.right64;
    pub const rightNeg64 = GeneratedStyledMethods.rightNeg64;
    pub const right72 = GeneratedStyledMethods.right72;
    pub const rightNeg72 = GeneratedStyledMethods.rightNeg72;
    pub const right80 = GeneratedStyledMethods.right80;
    pub const rightNeg80 = GeneratedStyledMethods.rightNeg80;
    pub const right96 = GeneratedStyledMethods.right96;
    pub const rightNeg96 = GeneratedStyledMethods.rightNeg96;
    pub const right112 = GeneratedStyledMethods.right112;
    pub const rightNeg112 = GeneratedStyledMethods.rightNeg112;
    pub const right128 = GeneratedStyledMethods.right128;
    pub const rightNeg128 = GeneratedStyledMethods.rightNeg128;
    pub const rightAuto = GeneratedStyledMethods.rightAuto;
    pub const rightPx = GeneratedStyledMethods.rightPx;
    pub const rightNegPx = GeneratedStyledMethods.rightNegPx;
    pub const rightFull = GeneratedStyledMethods.rightFull;
    pub const rightNegFull = GeneratedStyledMethods.rightNegFull;
    pub const right1_2 = GeneratedStyledMethods.right1_2;
    pub const rightNeg1_2 = GeneratedStyledMethods.rightNeg1_2;
    pub const right1_3 = GeneratedStyledMethods.right1_3;
    pub const rightNeg1_3 = GeneratedStyledMethods.rightNeg1_3;
    pub const right2_3 = GeneratedStyledMethods.right2_3;
    pub const rightNeg2_3 = GeneratedStyledMethods.rightNeg2_3;
    pub const right1_4 = GeneratedStyledMethods.right1_4;
    pub const rightNeg1_4 = GeneratedStyledMethods.rightNeg1_4;
    pub const right2_4 = GeneratedStyledMethods.right2_4;
    pub const rightNeg2_4 = GeneratedStyledMethods.rightNeg2_4;
    pub const right3_4 = GeneratedStyledMethods.right3_4;
    pub const rightNeg3_4 = GeneratedStyledMethods.rightNeg3_4;
    pub const right1_5 = GeneratedStyledMethods.right1_5;
    pub const rightNeg1_5 = GeneratedStyledMethods.rightNeg1_5;
    pub const right2_5 = GeneratedStyledMethods.right2_5;
    pub const rightNeg2_5 = GeneratedStyledMethods.rightNeg2_5;
    pub const right3_5 = GeneratedStyledMethods.right3_5;
    pub const rightNeg3_5 = GeneratedStyledMethods.rightNeg3_5;
    pub const right4_5 = GeneratedStyledMethods.right4_5;
    pub const rightNeg4_5 = GeneratedStyledMethods.rightNeg4_5;
    pub const right1_6 = GeneratedStyledMethods.right1_6;
    pub const rightNeg1_6 = GeneratedStyledMethods.rightNeg1_6;
    pub const right5_6 = GeneratedStyledMethods.right5_6;
    pub const rightNeg5_6 = GeneratedStyledMethods.rightNeg5_6;
    pub const right1_12 = GeneratedStyledMethods.right1_12;
    pub const rightNeg1_12 = GeneratedStyledMethods.rightNeg1_12;
    pub const rounded = GeneratedStyledMethods.rounded;
    pub const roundedNone = GeneratedStyledMethods.roundedNone;
    pub const roundedXs = GeneratedStyledMethods.roundedXs;
    pub const roundedSm = GeneratedStyledMethods.roundedSm;
    pub const roundedMd = GeneratedStyledMethods.roundedMd;
    pub const roundedLg = GeneratedStyledMethods.roundedLg;
    pub const roundedXl = GeneratedStyledMethods.roundedXl;
    pub const rounded2xl = GeneratedStyledMethods.rounded2xl;
    pub const rounded3xl = GeneratedStyledMethods.rounded3xl;
    pub const roundedFull = GeneratedStyledMethods.roundedFull;
    pub const roundedT = GeneratedStyledMethods.roundedT;
    pub const roundedTNone = GeneratedStyledMethods.roundedTNone;
    pub const roundedTXs = GeneratedStyledMethods.roundedTXs;
    pub const roundedTSm = GeneratedStyledMethods.roundedTSm;
    pub const roundedTMd = GeneratedStyledMethods.roundedTMd;
    pub const roundedTLg = GeneratedStyledMethods.roundedTLg;
    pub const roundedTXl = GeneratedStyledMethods.roundedTXl;
    pub const roundedT2xl = GeneratedStyledMethods.roundedT2xl;
    pub const roundedT3xl = GeneratedStyledMethods.roundedT3xl;
    pub const roundedTFull = GeneratedStyledMethods.roundedTFull;
    pub const roundedB = GeneratedStyledMethods.roundedB;
    pub const roundedBNone = GeneratedStyledMethods.roundedBNone;
    pub const roundedBXs = GeneratedStyledMethods.roundedBXs;
    pub const roundedBSm = GeneratedStyledMethods.roundedBSm;
    pub const roundedBMd = GeneratedStyledMethods.roundedBMd;
    pub const roundedBLg = GeneratedStyledMethods.roundedBLg;
    pub const roundedBXl = GeneratedStyledMethods.roundedBXl;
    pub const roundedB2xl = GeneratedStyledMethods.roundedB2xl;
    pub const roundedB3xl = GeneratedStyledMethods.roundedB3xl;
    pub const roundedBFull = GeneratedStyledMethods.roundedBFull;
    pub const roundedR = GeneratedStyledMethods.roundedR;
    pub const roundedRNone = GeneratedStyledMethods.roundedRNone;
    pub const roundedRXs = GeneratedStyledMethods.roundedRXs;
    pub const roundedRSm = GeneratedStyledMethods.roundedRSm;
    pub const roundedRMd = GeneratedStyledMethods.roundedRMd;
    pub const roundedRLg = GeneratedStyledMethods.roundedRLg;
    pub const roundedRXl = GeneratedStyledMethods.roundedRXl;
    pub const roundedR2xl = GeneratedStyledMethods.roundedR2xl;
    pub const roundedR3xl = GeneratedStyledMethods.roundedR3xl;
    pub const roundedRFull = GeneratedStyledMethods.roundedRFull;
    pub const roundedL = GeneratedStyledMethods.roundedL;
    pub const roundedLNone = GeneratedStyledMethods.roundedLNone;
    pub const roundedLXs = GeneratedStyledMethods.roundedLXs;
    pub const roundedLSm = GeneratedStyledMethods.roundedLSm;
    pub const roundedLMd = GeneratedStyledMethods.roundedLMd;
    pub const roundedLLg = GeneratedStyledMethods.roundedLLg;
    pub const roundedLXl = GeneratedStyledMethods.roundedLXl;
    pub const roundedL2xl = GeneratedStyledMethods.roundedL2xl;
    pub const roundedL3xl = GeneratedStyledMethods.roundedL3xl;
    pub const roundedLFull = GeneratedStyledMethods.roundedLFull;
    pub const roundedTl = GeneratedStyledMethods.roundedTl;
    pub const roundedTlNone = GeneratedStyledMethods.roundedTlNone;
    pub const roundedTlXs = GeneratedStyledMethods.roundedTlXs;
    pub const roundedTlSm = GeneratedStyledMethods.roundedTlSm;
    pub const roundedTlMd = GeneratedStyledMethods.roundedTlMd;
    pub const roundedTlLg = GeneratedStyledMethods.roundedTlLg;
    pub const roundedTlXl = GeneratedStyledMethods.roundedTlXl;
    pub const roundedTl2xl = GeneratedStyledMethods.roundedTl2xl;
    pub const roundedTl3xl = GeneratedStyledMethods.roundedTl3xl;
    pub const roundedTlFull = GeneratedStyledMethods.roundedTlFull;
    pub const roundedTr = GeneratedStyledMethods.roundedTr;
    pub const roundedTrNone = GeneratedStyledMethods.roundedTrNone;
    pub const roundedTrXs = GeneratedStyledMethods.roundedTrXs;
    pub const roundedTrSm = GeneratedStyledMethods.roundedTrSm;
    pub const roundedTrMd = GeneratedStyledMethods.roundedTrMd;
    pub const roundedTrLg = GeneratedStyledMethods.roundedTrLg;
    pub const roundedTrXl = GeneratedStyledMethods.roundedTrXl;
    pub const roundedTr2xl = GeneratedStyledMethods.roundedTr2xl;
    pub const roundedTr3xl = GeneratedStyledMethods.roundedTr3xl;
    pub const roundedTrFull = GeneratedStyledMethods.roundedTrFull;
    pub const roundedBl = GeneratedStyledMethods.roundedBl;
    pub const roundedBlNone = GeneratedStyledMethods.roundedBlNone;
    pub const roundedBlXs = GeneratedStyledMethods.roundedBlXs;
    pub const roundedBlSm = GeneratedStyledMethods.roundedBlSm;
    pub const roundedBlMd = GeneratedStyledMethods.roundedBlMd;
    pub const roundedBlLg = GeneratedStyledMethods.roundedBlLg;
    pub const roundedBlXl = GeneratedStyledMethods.roundedBlXl;
    pub const roundedBl2xl = GeneratedStyledMethods.roundedBl2xl;
    pub const roundedBl3xl = GeneratedStyledMethods.roundedBl3xl;
    pub const roundedBlFull = GeneratedStyledMethods.roundedBlFull;
    pub const roundedBr = GeneratedStyledMethods.roundedBr;
    pub const roundedBrNone = GeneratedStyledMethods.roundedBrNone;
    pub const roundedBrXs = GeneratedStyledMethods.roundedBrXs;
    pub const roundedBrSm = GeneratedStyledMethods.roundedBrSm;
    pub const roundedBrMd = GeneratedStyledMethods.roundedBrMd;
    pub const roundedBrLg = GeneratedStyledMethods.roundedBrLg;
    pub const roundedBrXl = GeneratedStyledMethods.roundedBrXl;
    pub const roundedBr2xl = GeneratedStyledMethods.roundedBr2xl;
    pub const roundedBr3xl = GeneratedStyledMethods.roundedBr3xl;
    pub const roundedBrFull = GeneratedStyledMethods.roundedBrFull;
    pub const border = GeneratedStyledMethods.border;
    pub const border0 = GeneratedStyledMethods.border0;
    pub const border1 = GeneratedStyledMethods.border1;
    pub const border2 = GeneratedStyledMethods.border2;
    pub const border3 = GeneratedStyledMethods.border3;
    pub const border4 = GeneratedStyledMethods.border4;
    pub const border5 = GeneratedStyledMethods.border5;
    pub const border6 = GeneratedStyledMethods.border6;
    pub const border7 = GeneratedStyledMethods.border7;
    pub const border8 = GeneratedStyledMethods.border8;
    pub const border9 = GeneratedStyledMethods.border9;
    pub const border10 = GeneratedStyledMethods.border10;
    pub const border11 = GeneratedStyledMethods.border11;
    pub const border12 = GeneratedStyledMethods.border12;
    pub const border16 = GeneratedStyledMethods.border16;
    pub const border20 = GeneratedStyledMethods.border20;
    pub const border24 = GeneratedStyledMethods.border24;
    pub const border32 = GeneratedStyledMethods.border32;
    pub const borderT = GeneratedStyledMethods.borderT;
    pub const borderT0 = GeneratedStyledMethods.borderT0;
    pub const borderT1 = GeneratedStyledMethods.borderT1;
    pub const borderT2 = GeneratedStyledMethods.borderT2;
    pub const borderT3 = GeneratedStyledMethods.borderT3;
    pub const borderT4 = GeneratedStyledMethods.borderT4;
    pub const borderT5 = GeneratedStyledMethods.borderT5;
    pub const borderT6 = GeneratedStyledMethods.borderT6;
    pub const borderT7 = GeneratedStyledMethods.borderT7;
    pub const borderT8 = GeneratedStyledMethods.borderT8;
    pub const borderT9 = GeneratedStyledMethods.borderT9;
    pub const borderT10 = GeneratedStyledMethods.borderT10;
    pub const borderT11 = GeneratedStyledMethods.borderT11;
    pub const borderT12 = GeneratedStyledMethods.borderT12;
    pub const borderT16 = GeneratedStyledMethods.borderT16;
    pub const borderT20 = GeneratedStyledMethods.borderT20;
    pub const borderT24 = GeneratedStyledMethods.borderT24;
    pub const borderT32 = GeneratedStyledMethods.borderT32;
    pub const borderB = GeneratedStyledMethods.borderB;
    pub const borderB0 = GeneratedStyledMethods.borderB0;
    pub const borderB1 = GeneratedStyledMethods.borderB1;
    pub const borderB2 = GeneratedStyledMethods.borderB2;
    pub const borderB3 = GeneratedStyledMethods.borderB3;
    pub const borderB4 = GeneratedStyledMethods.borderB4;
    pub const borderB5 = GeneratedStyledMethods.borderB5;
    pub const borderB6 = GeneratedStyledMethods.borderB6;
    pub const borderB7 = GeneratedStyledMethods.borderB7;
    pub const borderB8 = GeneratedStyledMethods.borderB8;
    pub const borderB9 = GeneratedStyledMethods.borderB9;
    pub const borderB10 = GeneratedStyledMethods.borderB10;
    pub const borderB11 = GeneratedStyledMethods.borderB11;
    pub const borderB12 = GeneratedStyledMethods.borderB12;
    pub const borderB16 = GeneratedStyledMethods.borderB16;
    pub const borderB20 = GeneratedStyledMethods.borderB20;
    pub const borderB24 = GeneratedStyledMethods.borderB24;
    pub const borderB32 = GeneratedStyledMethods.borderB32;
    pub const borderR = GeneratedStyledMethods.borderR;
    pub const borderR0 = GeneratedStyledMethods.borderR0;
    pub const borderR1 = GeneratedStyledMethods.borderR1;
    pub const borderR2 = GeneratedStyledMethods.borderR2;
    pub const borderR3 = GeneratedStyledMethods.borderR3;
    pub const borderR4 = GeneratedStyledMethods.borderR4;
    pub const borderR5 = GeneratedStyledMethods.borderR5;
    pub const borderR6 = GeneratedStyledMethods.borderR6;
    pub const borderR7 = GeneratedStyledMethods.borderR7;
    pub const borderR8 = GeneratedStyledMethods.borderR8;
    pub const borderR9 = GeneratedStyledMethods.borderR9;
    pub const borderR10 = GeneratedStyledMethods.borderR10;
    pub const borderR11 = GeneratedStyledMethods.borderR11;
    pub const borderR12 = GeneratedStyledMethods.borderR12;
    pub const borderR16 = GeneratedStyledMethods.borderR16;
    pub const borderR20 = GeneratedStyledMethods.borderR20;
    pub const borderR24 = GeneratedStyledMethods.borderR24;
    pub const borderR32 = GeneratedStyledMethods.borderR32;
    pub const borderL = GeneratedStyledMethods.borderL;
    pub const borderL0 = GeneratedStyledMethods.borderL0;
    pub const borderL1 = GeneratedStyledMethods.borderL1;
    pub const borderL2 = GeneratedStyledMethods.borderL2;
    pub const borderL3 = GeneratedStyledMethods.borderL3;
    pub const borderL4 = GeneratedStyledMethods.borderL4;
    pub const borderL5 = GeneratedStyledMethods.borderL5;
    pub const borderL6 = GeneratedStyledMethods.borderL6;
    pub const borderL7 = GeneratedStyledMethods.borderL7;
    pub const borderL8 = GeneratedStyledMethods.borderL8;
    pub const borderL9 = GeneratedStyledMethods.borderL9;
    pub const borderL10 = GeneratedStyledMethods.borderL10;
    pub const borderL11 = GeneratedStyledMethods.borderL11;
    pub const borderL12 = GeneratedStyledMethods.borderL12;
    pub const borderL16 = GeneratedStyledMethods.borderL16;
    pub const borderL20 = GeneratedStyledMethods.borderL20;
    pub const borderL24 = GeneratedStyledMethods.borderL24;
    pub const borderL32 = GeneratedStyledMethods.borderL32;
    pub const borderX = GeneratedStyledMethods.borderX;
    pub const borderX0 = GeneratedStyledMethods.borderX0;
    pub const borderX1 = GeneratedStyledMethods.borderX1;
    pub const borderX2 = GeneratedStyledMethods.borderX2;
    pub const borderX3 = GeneratedStyledMethods.borderX3;
    pub const borderX4 = GeneratedStyledMethods.borderX4;
    pub const borderX5 = GeneratedStyledMethods.borderX5;
    pub const borderX6 = GeneratedStyledMethods.borderX6;
    pub const borderX7 = GeneratedStyledMethods.borderX7;
    pub const borderX8 = GeneratedStyledMethods.borderX8;
    pub const borderX9 = GeneratedStyledMethods.borderX9;
    pub const borderX10 = GeneratedStyledMethods.borderX10;
    pub const borderX11 = GeneratedStyledMethods.borderX11;
    pub const borderX12 = GeneratedStyledMethods.borderX12;
    pub const borderX16 = GeneratedStyledMethods.borderX16;
    pub const borderX20 = GeneratedStyledMethods.borderX20;
    pub const borderX24 = GeneratedStyledMethods.borderX24;
    pub const borderX32 = GeneratedStyledMethods.borderX32;
    pub const borderY = GeneratedStyledMethods.borderY;
    pub const borderY0 = GeneratedStyledMethods.borderY0;
    pub const borderY1 = GeneratedStyledMethods.borderY1;
    pub const borderY2 = GeneratedStyledMethods.borderY2;
    pub const borderY3 = GeneratedStyledMethods.borderY3;
    pub const borderY4 = GeneratedStyledMethods.borderY4;
    pub const borderY5 = GeneratedStyledMethods.borderY5;
    pub const borderY6 = GeneratedStyledMethods.borderY6;
    pub const borderY7 = GeneratedStyledMethods.borderY7;
    pub const borderY8 = GeneratedStyledMethods.borderY8;
    pub const borderY9 = GeneratedStyledMethods.borderY9;
    pub const borderY10 = GeneratedStyledMethods.borderY10;
    pub const borderY11 = GeneratedStyledMethods.borderY11;
    pub const borderY12 = GeneratedStyledMethods.borderY12;
    pub const borderY16 = GeneratedStyledMethods.borderY16;
    pub const borderY20 = GeneratedStyledMethods.borderY20;
    pub const borderY24 = GeneratedStyledMethods.borderY24;
    pub const borderY32 = GeneratedStyledMethods.borderY32;
    pub const visible = GeneratedStyledMethods.visible;
    pub const invisible = GeneratedStyledMethods.invisible;
    pub const relative = GeneratedStyledMethods.relative;
    pub const absolute = GeneratedStyledMethods.absolute;
    pub const overflowHidden = GeneratedStyledMethods.overflowHidden;
    pub const overflowXHidden = GeneratedStyledMethods.overflowXHidden;
    pub const overflowYHidden = GeneratedStyledMethods.overflowYHidden;
    pub const cursorDefault = GeneratedStyledMethods.cursorDefault;
    pub const cursorPointer = GeneratedStyledMethods.cursorPointer;
    pub const cursorText = GeneratedStyledMethods.cursorText;
    pub const cursorMove = GeneratedStyledMethods.cursorMove;
    pub const cursorNotAllowed = GeneratedStyledMethods.cursorNotAllowed;
    pub const cursorContextMenu = GeneratedStyledMethods.cursorContextMenu;
    pub const cursorCrosshair = GeneratedStyledMethods.cursorCrosshair;
    pub const cursorAlias = GeneratedStyledMethods.cursorAlias;
    pub const cursorCopy = GeneratedStyledMethods.cursorCopy;
    pub const cursorNoDrop = GeneratedStyledMethods.cursorNoDrop;
    pub const cursorGrab = GeneratedStyledMethods.cursorGrab;
    pub const cursorGrabbing = GeneratedStyledMethods.cursorGrabbing;
    pub const cursorEwResize = GeneratedStyledMethods.cursorEwResize;
    pub const cursorNsResize = GeneratedStyledMethods.cursorNsResize;
    pub const cursorColResize = GeneratedStyledMethods.cursorColResize;
    pub const cursorRowResize = GeneratedStyledMethods.cursorRowResize;
    pub const cursorNResize = GeneratedStyledMethods.cursorNResize;
    pub const cursorEResize = GeneratedStyledMethods.cursorEResize;
    pub const cursorSResize = GeneratedStyledMethods.cursorSResize;
    pub const cursorWResize = GeneratedStyledMethods.cursorWResize;
    pub const shadow2xs = GeneratedStyledMethods.shadow2xs;
    pub const shadowXs = GeneratedStyledMethods.shadowXs;
    pub const shadowSm = GeneratedStyledMethods.shadowSm;
    pub const shadowMd = GeneratedStyledMethods.shadowMd;
    pub const shadowLg = GeneratedStyledMethods.shadowLg;
    pub const shadowXl = GeneratedStyledMethods.shadowXl;
    pub const shadow2xl = GeneratedStyledMethods.shadow2xl;
    // zpui:styled-forwarders end
};

/// Keeps a `ListState` alive while the rendered frame's listeners reference it.
const KeepAlive = struct {
    state: ?ListState = null,
    pub fn deinit(self: *KeepAlive) void {
        if (self.state) |s| s.release();
    }
};

pub const ListPrepaintState = struct {
    hitbox: Hitbox,
    layout: LayoutResponse,
};

const ListElement = struct {
    d: *ListData,

    pub const PrepaintState = ListPrepaintState;

    pub fn elementId(self: *ListElement) ?ElementId {
        return .{ .hash = @intFromPtr(self.d.state.inner) };
    }

    fn baseStyle(self: *ListElement) Style {
        var s: Style = .{};
        refine.refine(&s, self.d.style);
        return s;
    }

    pub fn requestLayout(self: *ListElement, _: ?GlobalElementId, _: *void, window: *Window, cx: *App) LayoutId {
        switch (self.d.sizing_behavior) {
            .infer => {
                var s: Style = .{};
                s.overflow.y = .scroll;
                refine.refine(&s, self.d.style);
                const text: ?style_mod.TextStyleRefinement = if (s.textStyle()) |t| t.* else null;
                window.pushTextStyle(text);
                defer window.popTextStyle(text);
                const st = self.d.state.inner;
                st.last_rendered_count = 0;
                const last = st.last_layout_bounds;
                const available_height = if (last) |b| b.size.height else st.overdraw;
                const padding = paddingPixels(&s, if (last) |b| b.size else .zero, window.remSize());
                const resp = layoutItems(st, null, available_height, padding, self.d.render_item, window, cx);
                const Measure = struct {
                    max_w: Pixels,
                    total_h: Pixels,
                    fn f(m: @This(), known: layout.Dims(?Pixels), avail: layout.Dims(AvailableSpace), _: *Window, _: *App) Size {
                        const w = known.width orelse switch (avail.width) {
                            .definite => |x| x,
                            else => m.max_w,
                        };
                        const h = switch (avail.height) {
                            .definite => |x| @min(m.total_h, x),
                            else => m.total_h,
                        };
                        return .{ .width = w, .height = h };
                    }
                };
                return window.requestMeasuredLayout(s, Measure{ .max_w = resp.max_item_width, .total_h = st.items.summary().height }, Measure.f);
            },
            .auto => {
                const s = self.baseStyle();
                const text: ?style_mod.TextStyleRefinement = if (s.textStyle()) |t| t.* else null;
                window.pushTextStyle(text);
                defer window.popTextStyle(text);
                return window.requestLayout(s, &.{});
            },
        }
    }

    pub fn prepaint(self: *ListElement, gid: ?GlobalElementId, bounds: Bounds, _: *void, pp: *ListPrepaintState, window: *Window, cx: *App) void {
        const state = self.d.state;
        const st = state.inner;
        if (gid) |g| {
            const ka = window.elementState(KeepAlive, g);
            if (ka.state == null) ka.state = state.retain();
        }
        st.reset = false;
        if (self.d.sizing_behavior != .infer) st.last_rendered_count = 0;
        const s = self.baseStyle();
        const hitbox = window.insertHitbox(bounds, .normal);

        // A width change invalidates every measured height. (Deviation from gpui: hints of
        // still-unmeasured items survive, so `withUniformItemHeight` also covers the first
        // layout instead of being wiped by it.)
        if (st.last_layout_bounds == null or st.last_layout_bounds.?.size.width != bounds.size.width) {
            st.items.mapAll({}, struct {
                fn f(_: void, item: ListItem) ListItem {
                    return .unmeasured(if (item.measured) null else item.size, item.focus_handle);
                }
            }.f);
            st.measuring_behavior.reset();
        }

        const padding = paddingPixels(&s, bounds.size, window.remSize());
        const text: ?style_mod.TextStyleRefinement = if (s.textStyle()) |t| t.* else null;
        window.pushTextStyle(text);
        defer window.popTextStyle(text);
        const resp = switch (prepaintItems(st, bounds, padding, true, self.d.render_item, window, cx)) {
            .ok => |r| r,
            .retry => |offset| blk: {
                st.logical_scroll_top = offset;
                break :blk prepaintItems(st, bounds, padding, false, self.d.render_item, window, cx).ok;
            },
        };
        st.last_layout_bounds = bounds;
        st.last_padding = padding;
        st.last_visible_count = resp.item_layouts.len;
        pp.* = .{ .hitbox = hitbox, .layout = resp };
    }

    pub fn paint(self: *ListElement, _: ?GlobalElementId, bounds: Bounds, _: *void, pp: *ListPrepaintState, window: *Window, cx: *App) void {
        const s = self.baseStyle();
        const text: ?style_mod.TextStyleRefinement = if (s.textStyle()) |t| t.* else null;
        window.pushTextStyle(text);
        window.pushContentMask(.{ .bounds = bounds });
        for (pp.layout.item_layouts) |item| item.element.paint(window, cx);
        window.popContentMask(.{ .bounds = bounds });
        window.popTextStyle(text);

        const Ctx = struct {
            state: *StateInner,
            height: Pixels,
            scroll_top: ListOffset,
            hitbox: HitboxId,
            view: EntityId,
            accumulated: ?input.ScrollDelta = null,
        };
        window.onMouseEvent(input.ScrollWheelEvent, Ctx{
            .state = self.d.state.inner,
            .height = bounds.size.height,
            .scroll_top = pp.layout.scroll_top,
            .hitbox = pp.hitbox.id,
            .view = window.currentView(),
        }, struct {
            fn f(c: *Ctx, ev: *const input.ScrollWheelEvent, phase: DispatchPhase, w: *Window, a: *App) void {
                if (phase != .bubble or !c.hitbox.shouldHandleScroll(w)) return;
                c.accumulated = if (c.accumulated) |acc| coalesce(acc, ev.delta) else ev.delta;
                const delta = pixelDelta(c.accumulated.?, 20);
                scrollState(c.state, c.scroll_top, c.height, delta, c.view, w, a);
            }
        }.f);
    }
};

fn paddingPixels(s: *const Style, size: Size, rem: Pixels) Edges {
    const w: style_mod.AbsoluteLength = .{ .pixels = size.width };
    const h: style_mod.AbsoluteLength = .{ .pixels = size.height };
    return .{
        .top = s.padding.top.toPixels(h, rem),
        .right = s.padding.right.toPixels(w, rem),
        .bottom = s.padding.bottom.toPixels(h, rem),
        .left = s.padding.left.toPixels(w, rem),
    };
}

/// gpui `ScrollDelta::pixel_delta`.
pub fn pixelDelta(d: input.ScrollDelta, line_height: Pixels) Point {
    return switch (d) {
        .pixels => |p| p,
        .lines => |l| l.scale(line_height),
    };
}

/// gpui `ScrollDelta::coalesce`: same-signed deltas add, an opposite sign replaces.
pub fn coalesce(a: input.ScrollDelta, b: input.ScrollDelta) input.ScrollDelta {
    const C = struct {
        fn axis(x: f32, y: f32) f32 {
            return if (std.math.sign(x) == std.math.sign(y)) x + y else y;
        }
        fn pt(p: Point, q: Point) Point {
            return .{ .x = axis(p.x, q.x), .y = axis(p.y, q.y) };
        }
    };
    return switch (a) {
        .pixels => |p| switch (b) {
            .pixels => |q| .{ .pixels = C.pt(p, q) },
            .lines => b,
        },
        .lines => |p| switch (b) {
            .lines => |q| .{ .lines = C.pt(p, q) },
            .pixels => b,
        },
    };
}

comptime {
    styled.assertStyled(List);
}

// ---------------------------------------------------------------------------------------
// Tests (tree only; element tests live in list_tests.zig)
// ---------------------------------------------------------------------------------------

test "item tree splice, prefix and seek" {
    var t: ItemTree = .{ .gpa = std.testing.allocator };
    defer t.deinit();
    var items: [100]ListItem = undefined;
    for (&items, 0..) |*it, i| it.* = .measuredItem(.{ .width = 1, .height = @floatFromInt(i % 7 + 1) }, null);
    t.replaceRange(0, 0, &items);
    try std.testing.expectEqual(@as(usize, 100), t.count());
    var expect_h: f32 = 0;
    for (0..101) |k| {
        try std.testing.expectEqual(expect_h, t.prefix(k).height);
        if (k < 100) expect_h += @floatFromInt(k % 7 + 1);
    }
    // seek right: item containing h (exclusive end)
    const s1 = t.seekHeight(1, .right); // item0 [0,1): end == 1 skipped with right bias
    try std.testing.expectEqual(@as(usize, 1), s1.count);
    const s2 = t.seekHeight(1, .left);
    try std.testing.expectEqual(@as(usize, 0), s2.count);
    const s3 = t.seekHeight(1e9, .right);
    try std.testing.expectEqual(@as(usize, 100), s3.count);
    // splice out 10..20, insert 3 unknown
    const new = [_]ListItem{ .unmeasured(null, null), .unmeasured(null, null), .unmeasured(null, null) };
    t.replaceRange(10, 20, &new);
    try std.testing.expectEqual(@as(usize, 93), t.count());
    try std.testing.expect(t.summary().has_unknown_height);
    try std.testing.expect(t.rangeSummary(10, 13).has_unknown_height);
    try std.testing.expect(!t.rangeSummary(13, 93).has_unknown_height);
    try std.testing.expectEqual(@as(f32, 3), t.get(9).?.size.?.height);
}
