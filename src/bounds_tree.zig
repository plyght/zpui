//! R-tree variant that assigns draw orders (gpui `bounds_tree.rs`).
//!
//! `insert` returns one more than the maximum order of any previously inserted
//! bounds that intersect the new bounds, so non-overlapping primitives share
//! orders and can batch together while overlapping ones stack correctly.
//!
//! Same orders as gpui's per-primitive R-tree, computed more cheaply for the
//! common case of many small neighbouring inserts (the glyphs of a line):
//!
//! * New bounds first collect in a short **run** (the tail of `items`) that is
//!   scanned linearly; a full or far-away run enters the tree as ONE leaf
//!   holding its items, so the tree grows per run, not per glyph.
//! * Between flushes the tree does not change, so the tree items around the
//!   current insert are gathered once into a small **neighbourhood cache**;
//!   inserts inside that region scan it instead of searching the tree.
//!
//! Both are exact: every order equals a brute-force scan of all earlier bounds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const geometry = @import("geometry.zig");

/// Maximum children per internal node.
const max_children = 12;

pub fn BoundsTree(comptime T: type) type {
    return struct {
        const Self = @This();
        const B = geometry.Bounds(T);

        /// Every inserted bounds with its order, in insertion order. Leaves own
        /// contiguous ranges; `items[run_start..]` is the run not yet in the tree.
        items: std.ArrayList(Item) = .empty,
        run_start: u32 = 0,
        run_bounds: B = undefined,
        /// Tree nodes; indices are stable until `clear`.
        nodes: std.ArrayList(Node) = .empty,
        root: ?usize = null,
        /// The tree item with the highest order (fast path for queries).
        max_item: ?u32 = null,
        insert_path: std.ArrayList(usize) = .empty,
        search_stack: std.ArrayList(usize) = .empty,
        /// Tree items intersecting `cache_region` (valid until the next flush).
        cache: std.ArrayList(Item) = .empty,
        cache_region: ?B = null,
        /// Inserts left before another neighbourhood is tried (after one overflowed).
        cache_backoff: u8 = 0,

        const Item = struct { bounds: B, order: u32 };

        /// Most bounds a run holds before it becomes a leaf (each later insert scans it).
        const max_run = 24;
        /// Most items a neighbourhood cache holds; a denser region searches the tree.
        const max_cache = 48;

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
                /// `items[start..end]`.
                leaf: struct { start: u32, end: u32 },
                internal: Children,
            },
        };

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.items.deinit(gpa);
            self.nodes.deinit(gpa);
            self.insert_path.deinit(gpa);
            self.search_stack.deinit(gpa);
            self.cache.deinit(gpa);
            self.* = undefined;
        }

        pub fn clear(self: *Self) void {
            self.items.clearRetainingCapacity();
            self.run_start = 0;
            self.nodes.clearRetainingCapacity();
            self.root = null;
            self.max_item = null;
            self.insert_path.clearRetainingCapacity();
            self.search_stack.clearRetainingCapacity();
            self.cache.clearRetainingCapacity();
            self.cache_region = null;
            self.cache_backoff = 0;
        }

        /// Insert `bounds` and return its order (1 + max order of intersecting bounds).
        pub fn insert(self: *Self, gpa: Allocator, bounds: B) Allocator.Error!u32 {
            try self.items.ensureUnusedCapacity(gpa, 1);
            var max_found = try self.treeMax(gpa, bounds);
            const run = self.items.items[self.run_start..];
            for (run) |it| {
                if (it.order > max_found and it.bounds.intersects(bounds)) max_found = it.order;
            }
            const ordering = max_found + 1;
            if (run.len > 0 and (run.len >= max_run or !near(self.run_bounds, bounds))) try self.flushRun(gpa);
            self.items.appendAssumeCapacity(.{ .bounds = bounds, .order = ordering });
            self.run_bounds = if (self.items.items.len - self.run_start == 1) bounds else self.run_bounds.unionWith(bounds);
            return ordering;
        }

        /// Whether `b` continues the run (a neighbour of what it covers).
        fn near(run: B, b: B) bool {
            const pad = @max(b.size.height, 1);
            return b.origin.x < run.right() + pad and b.right() > run.origin.x - pad and
                b.origin.y < run.bottom() + pad and b.bottom() > run.origin.y - pad;
        }

        /// Max order of tree items (excluding the run) intersecting `query`.
        fn treeMax(self: *Self, gpa: Allocator, query: B) Allocator.Error!u32 {
            if (self.root == null) return 0;
            if (self.max_item) |m| {
                const it = self.items.items[m];
                if (query.intersects(it.bounds)) return it.order;
            }
            if (self.cache_region) |r| if (contains(r, query)) return scanMax(self.cache.items, query);
            if (self.cache_backoff > 0) {
                self.cache_backoff -= 1;
                return self.search(gpa, query);
            }
            // A neighbourhood around `query`, reaching ahead along the line.
            const h = @max(query.size.height, 1);
            const region: B = .{
                .origin = .{ .x = query.origin.x - h, .y = query.origin.y - h / 2 },
                .size = .{ .width = query.size.width + 18 * h, .height = query.size.height + h },
            };
            if (try self.collect(gpa, region)) {
                self.cache_region = region;
                return scanMax(self.cache.items, query);
            }
            self.cache_backoff = 16;
            return self.search(gpa, query);
        }

        /// `outer` covers `b`: anything intersecting `b` intersects `outer`.
        fn contains(outer: B, b: B) bool {
            return b.origin.x >= outer.origin.x and b.origin.y >= outer.origin.y and
                b.right() <= outer.right() and b.bottom() <= outer.bottom();
        }

        fn scanMax(items: []const Item, query: B) u32 {
            var max_found: u32 = 0;
            for (items) |it| {
                if (it.order > max_found and it.bounds.intersects(query)) max_found = it.order;
            }
            return max_found;
        }

        /// Gather the tree items intersecting `region` into `cache`; false (cache
        /// invalid) when there are more than `max_cache`.
        fn collect(self: *Self, gpa: Allocator, region: B) Allocator.Error!bool {
            self.cache_region = null;
            self.cache.clearRetainingCapacity();
            try self.cache.ensureTotalCapacity(gpa, max_cache);
            const nodes = self.nodes.items;
            self.search_stack.clearRetainingCapacity();
            try self.search_stack.ensureTotalCapacity(gpa, nodes.len);
            const stack = self.search_stack.allocatedSlice();
            stack[0] = self.root.?;
            var len: usize = 1;
            while (len > 0) {
                len -= 1;
                const node = &nodes[stack[len]];
                if (!region.intersects(node.bounds)) continue;
                switch (node.kind) {
                    .leaf => |l| for (self.items.items[l.start..l.end]) |it| {
                        if (!it.bounds.intersects(region)) continue;
                        if (self.cache.items.len == max_cache) return false;
                        self.cache.appendAssumeCapacity(it);
                    },
                    .internal => |*children| for (children.slice()) |child| {
                        stack[len] = child;
                        len += 1;
                    },
                }
            }
            return true;
        }

        /// Full tree search for the max order intersecting `query`.
        fn search(self: *Self, gpa: Allocator, query: B) Allocator.Error!u32 {
            const nodes = self.nodes.items;
            // The stack never holds more than every node once: reserve up front so the
            // pushes below are plain stores (this loop runs for many primitives).
            self.search_stack.clearRetainingCapacity();
            try self.search_stack.ensureTotalCapacity(gpa, nodes.len);
            const stack = self.search_stack.allocatedSlice();
            stack[0] = self.root.?;
            var len: usize = 1;
            var max_found: u32 = 0;
            while (len > 0) {
                len -= 1;
                const node = &nodes[stack[len]];
                if (node.max_order <= max_found) continue;
                if (!query.intersects(node.bounds)) continue;
                switch (node.kind) {
                    .leaf => |l| for (self.items.items[l.start..l.end]) |it| {
                        if (it.order > max_found and it.bounds.intersects(query)) max_found = it.order;
                    },
                    // Highest max_order child is last, so it is popped first.
                    .internal => |*children| for (children.slice()) |child| {
                        if (nodes[child].max_order > max_found) {
                            stack[len] = child;
                            len += 1;
                        }
                    },
                }
            }
            return max_found;
        }

        /// Move the run into the tree as one leaf.
        fn flushRun(self: *Self, gpa: Allocator) Allocator.Error!void {
            const start = self.run_start;
            const end: u32 = @intCast(self.items.items.len);
            if (start == end) return;
            var max_order: u32 = 0;
            var max_ix: u32 = start;
            for (self.items.items[start..end], start..) |it, i| {
                if (it.order > max_order) {
                    max_order = it.order;
                    max_ix = @intCast(i);
                }
            }
            try self.insertLeaf(gpa, .{ .bounds = self.run_bounds, .max_order = max_order, .kind = .{ .leaf = .{ .start = start, .end = end } } });
            self.run_start = end;
            if (self.max_item) |m| {
                if (self.items.items[m].order < max_order) self.max_item = max_ix;
            } else self.max_item = max_ix;
            // The tree changed under the neighbourhood.
            self.cache_region = null;
        }

        fn insertLeaf(self: *Self, gpa: Allocator, leaf_node: Node) Allocator.Error!void {
            const bounds = leaf_node.bounds;
            const order = leaf_node.max_order;
            // Reserve for the leaf plus a possible new internal node so indices/pointers stay valid.
            try self.nodes.ensureUnusedCapacity(gpa, 2);
            const leaf = self.nodes.items.len;
            self.nodes.appendAssumeCapacity(leaf_node);

            const root = self.root orelse {
                self.root = leaf;
                return;
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
                return;
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

test "runs of neighbouring inserts match brute force" {
    // Lines of glyph-sized bounds over backgrounds, with overlapping
    // decorations and occasional far-away inserts: exercises the run, its
    // flushes and the neighbourhood cache (including overflow and reuse after
    // `clear`), against a scan of every earlier bounds.
    const gpa = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x91f3);
    const rand = prng.random();
    const Entry = struct { b: geometry.Bounds(f32), order: u32 };
    var tree: BoundsTree(f32) = .{};
    defer tree.deinit(gpa);
    var expected: std.ArrayList(Entry) = .empty;
    defer expected.deinit(gpa);
    for (0..40) |_| {
        tree.clear();
        expected.clearRetainingCapacity();
        const lines = rand.intRangeAtMost(usize, 1, 30);
        for (0..lines) |line| {
            const y: f32 = @as(f32, @floatFromInt(line)) * (14 + rand.float(f32) * 10);
            var x: f32 = rand.float(f32) * 40;
            const glyphs = rand.intRangeAtMost(usize, 0, 90);
            for (0..glyphs) |_| {
                var b: geometry.Bounds(f32) = undefined;
                switch (rand.intRangeLessThan(u8, 0, 40)) {
                    // A background or highlight behind part of the line.
                    0 => b = rect(x - 5, y - 2, rand.float(f32) * 300, 22),
                    // Something elsewhere entirely.
                    1 => b = rect(rand.float(f32) * 2000 - 500, rand.float(f32) * 800 - 100, rand.float(f32) * 400, rand.float(f32) * 300),
                    // An empty bounds (never intersects).
                    2 => b = rect(x, y, 0, 10),
                    else => {
                        const w = 2 + rand.float(f32) * 9;
                        b = rect(x - rand.float(f32) * 2, y + rand.float(f32) * 6, w, 6 + rand.float(f32) * 12);
                        x += w * (0.6 + rand.float(f32) * 0.6);
                    },
                }
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
}
