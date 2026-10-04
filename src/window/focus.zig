//! Focus handles and tab order (gpui `FocusHandle`, `FocusMap`, `tab_stop.rs`).
//!
//! `FocusHandle` is a small value (`id` + tab settings). Handles created with
//! `cx.focusHandle()` are reference counted by the App's `FocusMap`: keep the handle in your
//! view and `release(cx)` it in `deinit` (like an `Entity`). Focus itself is per window
//! (`window.focus(handle)`); whether a handle "contains" focus is answered from the rendered
//! frame's dispatch tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dispatch_tree = @import("../app/dispatch_tree.zig");
const entity_mod = @import("../app/entity.zig");
pub const FocusId = dispatch_tree.FocusId;
const Window = @import("window.zig").Window;
const App = @import("../app/app.zig").App;

pub const FocusHandle = struct {
    id: FocusId,
    /// Position in the tab order relative to siblings (gpui `tab_index`).
    tab_index: isize = 0,
    /// Whether tab navigation stops here (gpui `tab_stop`).
    tab_stop: bool = false,

    pub fn tabIndex(self: FocusHandle, index: isize) FocusHandle {
        var h = self;
        h.tab_index = index;
        return h;
    }

    pub fn tabStop(self: FocusHandle, stop: bool) FocusHandle {
        var h = self;
        h.tab_stop = stop;
        return h;
    }

    pub fn eql(a: FocusHandle, b: FocusHandle) bool {
        return a.id == b.id;
    }

    /// Take another reference (keep it in a second owner).
    pub fn retain(self: FocusHandle, cx: anytype) FocusHandle {
        entity_mod.appOf(cx).focus_map.retain(self.id);
        return self;
    }

    /// Drop a reference; the id is forgotten when the last one goes.
    pub fn release(self: FocusHandle, cx: anytype) void {
        entity_mod.appOf(cx).focus_map.release(self.id);
    }

    /// Move focus in `window` to this handle (gpui `focus_handle.focus(window, cx)`).
    pub fn focus(self: FocusHandle, window: *Window) void {
        window.focus(self);
    }

    pub fn isFocused(self: FocusHandle, window: *const Window) bool {
        return window.focused_id == self.id;
    }

    /// This handle or one of its descendants is focused (gpui `contains_focused`).
    pub fn containsFocused(self: FocusHandle, window: *const Window) bool {
        const f = window.focused_id orelse return false;
        return window.rendered_frame.dispatch_tree.focusContains(self.id, f);
    }

    /// This handle is focused or is a descendant of the focused element (gpui `within_focused`).
    pub fn withinFocused(self: FocusHandle, window: *const Window) bool {
        const f = window.focused_id orelse return false;
        return window.rendered_frame.dispatch_tree.focusContains(f, self.id);
    }
};

/// App-wide focus id allocator with reference counts (gpui `FocusMap`).
pub const FocusMap = struct {
    gpa: Allocator,
    refs: std.AutoHashMapUnmanaged(FocusId, u32) = .empty,
    next_id: u64 = 1,

    pub fn init(gpa: Allocator) FocusMap {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FocusMap) void {
        self.refs.deinit(self.gpa);
    }

    pub fn create(self: *FocusMap) FocusHandle {
        const id: FocusId = @enumFromInt(self.next_id);
        self.next_id += 1;
        self.refs.put(self.gpa, id, 1) catch @panic("OOM");
        return .{ .id = id };
    }

    pub fn retain(self: *FocusMap, id: FocusId) void {
        const r = self.refs.getPtr(id) orelse return;
        r.* += 1;
    }

    pub fn release(self: *FocusMap, id: FocusId) void {
        const r = self.refs.getPtr(id) orelse return;
        r.* -= 1;
        if (r.* == 0) _ = self.refs.remove(id);
    }

    pub fn isAlive(self: *const FocusMap, id: FocusId) bool {
        return self.refs.contains(id);
    }
};

/// Tab order for one frame (gpui `TabStopMap`). Nodes sort by their path of tab indices
/// (enclosing tab groups, then the handle's own index), ties broken by paint order.
pub const TabStopMap = struct {
    pub const max_depth = 8;

    pub const Operation = union(enum) {
        insert: FocusHandle,
        group: isize,
        group_end,
    };

    const Node = struct {
        id: FocusId,
        path: [max_depth]isize,
        path_len: u8,
        insertion_index: usize,
        tab_stop: bool,

        fn lessThan(_: void, a: Node, b: Node) bool {
            const n = @min(a.path_len, b.path_len);
            for (a.path[0..n], b.path[0..n]) |x, y| if (x != y) return x < y;
            if (a.path_len != b.path_len) return a.path_len < b.path_len;
            return a.insertion_index < b.insertion_index;
        }
    };

    insertion_history: std.ArrayList(Operation) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    current_path: [max_depth]isize = undefined,
    current_len: u8 = 0,

    pub fn deinit(self: *TabStopMap, gpa: Allocator) void {
        self.insertion_history.deinit(gpa);
        self.nodes.deinit(gpa);
    }

    pub fn clear(self: *TabStopMap) void {
        self.insertion_history.clearRetainingCapacity();
        self.nodes.clearRetainingCapacity();
        self.current_len = 0;
    }

    pub fn insert(self: *TabStopMap, gpa: Allocator, handle: FocusHandle) void {
        self.insertion_history.append(gpa, .{ .insert = handle }) catch @panic("OOM");
        var node: Node = .{
            .id = handle.id,
            .path = undefined,
            .path_len = self.current_len,
            .insertion_index = self.insertion_history.items.len - 1,
            .tab_stop = handle.tab_stop,
        };
        @memcpy(node.path[0..self.current_len], self.current_path[0..self.current_len]);
        if (node.path_len < max_depth) {
            node.path[node.path_len] = handle.tab_index;
            node.path_len += 1;
        }
        // insert_or_replace: a handle painted twice keeps its last position.
        for (self.nodes.items) |*n| if (n.id == handle.id) {
            n.* = node;
            return;
        };
        self.nodes.append(gpa, node) catch @panic("OOM");
    }

    pub fn beginGroup(self: *TabStopMap, gpa: Allocator, index: isize) void {
        self.insertion_history.append(gpa, .{ .group = index }) catch @panic("OOM");
        if (self.current_len < max_depth) self.current_path[self.current_len] = index;
        self.current_len +|= 1;
    }

    pub fn endGroup(self: *TabStopMap, gpa: Allocator) void {
        self.insertion_history.append(gpa, .group_end) catch @panic("OOM");
        self.current_len -|= 1;
    }

    pub fn paintIndex(self: *const TabStopMap) usize {
        return self.insertion_history.items.len;
    }

    /// Re-apply operations recorded in a previous frame (cached view reuse).
    pub fn replay(self: *TabStopMap, gpa: Allocator, ops: []const Operation) void {
        for (ops) |op| switch (op) {
            .insert => |h| self.insert(gpa, h),
            .group => |i| self.beginGroup(gpa, i),
            .group_end => self.endGroup(gpa),
        };
    }

    fn sorted(self: *TabStopMap) []Node {
        std.mem.sort(Node, self.nodes.items, {}, Node.lessThan);
        return self.nodes.items;
    }

    /// The next tab stop after `focused` (wrapping), or the first one.
    pub fn next(self: *TabStopMap, focused: ?FocusId) ?FocusId {
        return self.step(focused, true);
    }

    pub fn prev(self: *TabStopMap, focused: ?FocusId) ?FocusId {
        return self.step(focused, false);
    }

    fn step(self: *TabStopMap, focused: ?FocusId, forward: bool) ?FocusId {
        const nodes = self.sorted();
        if (nodes.len == 0) return null;
        var start: ?usize = null;
        if (focused) |f| for (nodes, 0..) |n, i| if (n.id == f) {
            start = i;
            break;
        };
        const len = nodes.len;
        var k: usize = 0;
        while (k < len) : (k += 1) {
            const i = if (start) |s|
                (if (forward) (s + 1 + k) % len else (s + len - 1 - (k % len)) % len)
            else
                (if (forward) k else len - 1 - k);
            if (nodes[i].tab_stop) return nodes[i].id;
        }
        return null;
    }

    pub fn tabStopCount(self: *const TabStopMap) usize {
        var c: usize = 0;
        for (self.nodes.items) |n| c += @intFromBool(n.tab_stop);
        return c;
    }
};

test "tab order by index, groups and insertion" {
    const gpa = std.testing.allocator;
    var m: TabStopMap = .{};
    defer m.deinit(gpa);
    const h = struct {
        fn mk(id: u64, ix: isize) FocusHandle {
            return .{ .id = @enumFromInt(id), .tab_index = ix, .tab_stop = true };
        }
    }.mk;
    m.insert(gpa, h(1, 0));
    m.insert(gpa, h(2, -1));
    m.beginGroup(gpa, 1);
    m.insert(gpa, h(3, 0));
    m.insert(gpa, h(4, 0));
    m.endGroup(gpa);
    m.insert(gpa, .{ .id = @enumFromInt(5), .tab_index = 0 }); // not a tab stop
    // Order: 2 (-1), 1 (0), 5 (0, skipped), 3, 4 (group 1).
    try std.testing.expectEqual(@as(?FocusId, @enumFromInt(2)), m.next(null));
    try std.testing.expectEqual(@as(?FocusId, @enumFromInt(1)), m.next(@enumFromInt(2)));
    try std.testing.expectEqual(@as(?FocusId, @enumFromInt(3)), m.next(@enumFromInt(1)));
    try std.testing.expectEqual(@as(?FocusId, @enumFromInt(4)), m.next(@enumFromInt(3)));
    try std.testing.expectEqual(@as(?FocusId, @enumFromInt(2)), m.next(@enumFromInt(4)));
    try std.testing.expectEqual(@as(?FocusId, @enumFromInt(4)), m.prev(@enumFromInt(2)));
    try std.testing.expectEqual(@as(?FocusId, @enumFromInt(4)), m.prev(null));
}
