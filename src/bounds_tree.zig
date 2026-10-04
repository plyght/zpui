//! R-tree variant that assigns draw orders (gpui `bounds_tree.rs`).
//!
//! `insert` returns one more than the maximum order of any previously inserted
//! bounds that intersect the new bounds, so non-overlapping primitives share
//! orders and can batch together while overlapping ones stack correctly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");

/// Maximum children per internal node.
const max_children = 12;

pub fn BoundsTree(comptime T: type) type {
    return struct {
        const Self = @This();
        const B = geometry.Bounds(T);

        /// All nodes, stored contiguously; indices are stable until `clear`.
        nodes: std.ArrayList(Node) = .empty,
        root: ?usize = null,
        /// Leaf with the globally highest order (fast path for queries).
        max_leaf: ?usize = null,
        insert_path: std.ArrayList(usize) = .empty,
        search_stack: std.ArrayList(usize) = .empty,

        const Children = struct {
            /// Invariant: the child with the highest `max_order` is last.
            indices: [max_children]usize = undefined,
            len: u8 = 0,

            fn push(self: *Children, index: usize) void {
                std.debug.assert(self.len < max_children);
                self.indices[self.len] = index;
                self.len += 1;
            }
            fn slice(self: *const Children) []const usize {
                return self.indices[0..self.len];
            }
            fn swap(self: *Children, i: usize, j: usize) void {
                std.mem.swap(usize, &self.indices[i], &self.indices[j]);
            }
        };

        const Node = struct {
            bounds: B,
            max_order: u32,
            kind: union(enum) {
                leaf: u32,
                internal: Children,
            },
        };

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.nodes.deinit(gpa);
            self.insert_path.deinit(gpa);
            self.search_stack.deinit(gpa);
            self.* = undefined;
        }

        pub fn clear(self: *Self) void {
            self.nodes.clearRetainingCapacity();
            self.root = null;
            self.max_leaf = null;
            self.insert_path.clearRetainingCapacity();
            self.search_stack.clearRetainingCapacity();
        }

        /// Insert `bounds` and return its order (1 + max order of intersecting bounds).
        pub fn insert(self: *Self, gpa: Allocator, bounds: B) Allocator.Error!u32 {
            const ordering = (try self.findMaxOrdering(gpa, bounds)) + 1;
            const leaf = try self.insertLeaf(gpa, bounds, ordering);
            if (self.max_leaf) |old| {
                if (self.nodes.items[old].max_order < ordering) self.max_leaf = leaf;
            } else {
                self.max_leaf = leaf;
            }
            return ordering;
        }

        fn findMaxOrdering(self: *Self, gpa: Allocator, query: B) Allocator.Error!u32 {
            const root = self.root orelse return 0;
            const nodes = self.nodes.items;
            if (self.max_leaf) |m| {
                if (query.intersects(nodes[m].bounds)) return nodes[m].max_order;
            }

            self.search_stack.clearRetainingCapacity();
            try self.search_stack.append(gpa, root);
            var max_found: u32 = 0;
            while (self.search_stack.pop()) |idx| {
                const node = &nodes[idx];
                if (node.max_order <= max_found) continue;
                if (!query.intersects(node.bounds)) continue;
                switch (node.kind) {
                    .leaf => |order| max_found = @max(max_found, order),
                    // Highest max_order child is last, so it is popped first.
                    .internal => |*children| for (children.slice()) |child| {
                        if (nodes[child].max_order > max_found) try self.search_stack.append(gpa, child);
                    },
                }
            }
            return max_found;
        }

        fn insertLeaf(self: *Self, gpa: Allocator, bounds: B, order: u32) Allocator.Error!usize {
            // Reserve for the leaf plus a possible new internal node so indices/pointers stay valid.
            try self.nodes.ensureUnusedCapacity(gpa, 2);
            const leaf = self.nodes.items.len;
            self.nodes.appendAssumeCapacity(.{ .bounds = bounds, .max_order = order, .kind = .{ .leaf = order } });

            const root = self.root orelse {
                self.root = leaf;
                return leaf;
            };

            if (self.nodes.items[root].kind == .leaf) {
                const root_node = self.nodes.items[root];
                var children: Children = .{};
                if (order > root_node.max_order) {
                    children.push(root);
                    children.push(leaf);
                } else {
                    children.push(leaf);
                    children.push(root);
                }
                const new_root = self.nodes.items.len;
                self.nodes.appendAssumeCapacity(.{
                    .bounds = root_node.bounds.unionWith(bounds),
                    .max_order = @max(root_node.max_order, order),
                    .kind = .{ .internal = children },
                });
                self.root = new_root;
                return leaf;
            }

            self.insert_path.clearRetainingCapacity();
            var current = root;
            while (true) {
                try self.insert_path.append(gpa, current);
                const nodes = self.nodes.items;
                const children = &nodes[current].kind.internal;

                var best_pos: usize = 0;
                var best = children.indices[0];
                var best_cost = halfPerimeter(bounds.unionWith(nodes[best].bounds));
                for (children.slice()[1..], 1..) |child, pos| {
                    const cost = halfPerimeter(bounds.unionWith(nodes[child].bounds));
                    if (cost < best_cost) {
                        best_cost = cost;
                        best = child;
                        best_pos = pos;
                    }
                }

                if (nodes[best].kind != .leaf) {
                    current = best;
                    continue;
                }

                const node = &nodes[current];
                if (children.len < max_children) {
                    children.push(leaf);
                    if (order <= node.max_order) children.swap(children.len - 2, children.len - 1);
                    node.bounds = node.bounds.unionWith(bounds);
                    node.max_order = @max(node.max_order, order);
                } else {
                    // Full: replace the best leaf with a new internal node [best, leaf].
                    const sibling = nodes[best];
                    var new_children: Children = .{};
                    if (order > sibling.max_order) {
                        new_children.push(best);
                        new_children.push(leaf);
                    } else {
                        new_children.push(leaf);
                        new_children.push(best);
                    }
                    const new_max = @max(sibling.max_order, order);
                    const new_internal = self.nodes.items.len;
                    self.nodes.appendAssumeCapacity(.{
                        .bounds = sibling.bounds.unionWith(bounds),
                        .max_order = new_max,
                        .kind = .{ .internal = new_children },
                    });
                    const parent = &self.nodes.items[current];
                    const pc = &parent.kind.internal;
                    pc.indices[best_pos] = new_internal;
                    if (new_max > parent.max_order) pc.swap(best_pos, pc.len - 1);
                }
                break;
            }

            // Propagate bounds and max_order up the path.
            var updated_child: ?usize = null;
            var i = self.insert_path.items.len;
            while (i > 0) {
                i -= 1;
                const idx = self.insert_path.items[i];
                const node = &self.nodes.items[idx];
                node.bounds = node.bounds.unionWith(bounds);
                if (node.max_order < order) {
                    node.max_order = order;
                    if (updated_child) |child| {
                        const children = &node.kind.internal;
                        if (std.mem.indexOfScalar(usize, children.slice(), child)) |pos| {
                            const last = children.len - 1;
                            if (pos != last) children.swap(pos, last);
                        }
                    }
                }
                updated_child = idx;
            }
            return leaf;
        }

        fn halfPerimeter(b: B) T {
            return b.size.width + b.size.height;
        }
    };
}

const testing = std.testing;

fn rect(x: f32, y: f32, w: f32, h: f32) geometry.Bounds(f32) {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

test "insert assigns stacking orders" {
    const gpa = testing.allocator;
    var tree: BoundsTree(f32) = .{};
    defer tree.deinit(gpa);
    try testing.expectEqual(@as(u32, 1), try tree.insert(gpa, rect(0, 0, 10, 10)));
    try testing.expectEqual(@as(u32, 2), try tree.insert(gpa, rect(5, 5, 10, 10)));
    try testing.expectEqual(@as(u32, 3), try tree.insert(gpa, rect(10, 10, 10, 10)));
    try testing.expectEqual(@as(u32, 1), try tree.insert(gpa, rect(20, 20, 10, 10)));
    try testing.expectEqual(@as(u32, 1), try tree.insert(gpa, rect(40, 40, 10, 10)));
    try testing.expectEqual(@as(u32, 2), try tree.insert(gpa, rect(25, 25, 10, 10)));
}

test "random inserts match brute force" {
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();
    const Entry = struct { b: geometry.Bounds(f32), order: u32 };
    var seed: usize = 0;
    while (seed < 200) : (seed += 1) {
        var tree: BoundsTree(f32) = .{};
        defer tree.deinit(gpa);
        var expected: std.ArrayList(Entry) = .empty;
        defer expected.deinit(gpa);
        const n = rand.intRangeAtMost(usize, 1, 100);
        for (0..n) |_| {
            const b = rect(
                rand.float(f32) * 200 - 100,
                rand.float(f32) * 200 - 100,
                rand.float(f32) * 50,
                rand.float(f32) * 50,
            );
            var want: u32 = 0;
            for (expected.items) |e| {
                if (e.b.intersects(b)) want = @max(want, e.order);
            }
            want += 1;
            try expected.append(gpa, .{ .b = b, .order = want });
            try testing.expectEqual(want, try tree.insert(gpa, b));
        }
    }
}
