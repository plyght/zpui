//! Fuzzy file-search results as a tree — zeron `files/search.rs`
//! (`SearchTreeModel`): every match brings its ancestor directories; a
//! branch sorts by its best descendant score, then directories first, then
//! name. Directories with children start expanded and can be collapsed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("protocol.zig");

pub const Row = struct {
    path: []const u8,
    name: []const u8,
    kind: proto.EntryKind,
    depth: usize,
    has_children: bool,
    score: i64,
    /// A real match (vs. an ancestor shown for context).
    is_match: bool,
};

const Node = struct {
    path: []const u8,
    name: []const u8,
    kind: proto.EntryKind,
    score: ?i64,
    best: i64,
    children: std.ArrayList([]const u8) = .empty,
};

pub const SearchTree = struct {
    arena: std.heap.ArenaAllocator,
    nodes: std.StringHashMapUnmanaged(Node) = .empty,
    roots: std.ArrayList([]const u8) = .empty,
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    rows: std.ArrayList(Row) = .empty,

    pub fn init(gpa: Allocator) SearchTree {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *SearchTree) void {
        self.arena.deinit();
    }

    pub fn clear(self: *SearchTree) void {
        _ = self.arena.reset(.retain_capacity);
        self.nodes = .empty;
        self.roots = .empty;
        self.collapsed = .empty;
        self.rows = .empty;
    }

    pub fn rebuild(self: *SearchTree, results: []const proto.SearchMatch) void {
        self.clear();
        const a = self.arena.allocator();
        for (results) |r| {
            var parent: ?[]const u8 = null;
            var it = std.mem.tokenizeScalar(u8, r.path, '/');
            var end: usize = 0;
            while (it.next()) |comp| {
                end = @intFromPtr(comp.ptr) - @intFromPtr(r.path.ptr) + comp.len;
                const path = a.dupe(u8, r.path[0..end]) catch return;
                const is_match = end == r.path.len;
                const gop = self.nodes.getOrPut(a, path) catch return;
                if (gop.found_existing) {
                    if (is_match) {
                        gop.value_ptr.name = a.dupe(u8, r.name) catch r.name;
                        gop.value_ptr.kind = r.kind;
                        gop.value_ptr.score = @max(gop.value_ptr.score orelse std.math.minInt(i64), r.score);
                    }
                } else {
                    gop.value_ptr.* = .{
                        .path = path,
                        .name = a.dupe(u8, if (is_match) r.name else comp) catch comp,
                        .kind = if (is_match) r.kind else .directory,
                        .score = if (is_match) r.score else null,
                        .best = r.score,
                    };
                }
                const key = gop.key_ptr.*;
                if (parent) |p| {
                    const pn = self.nodes.getPtr(p).?;
                    var present = false;
                    for (pn.children.items) |c| if (std.mem.eql(u8, c, key)) {
                        present = true;
                        break;
                    };
                    if (!present) pn.children.append(a, key) catch {};
                } else {
                    var present = false;
                    for (self.roots.items) |c| if (std.mem.eql(u8, c, key)) {
                        present = true;
                        break;
                    };
                    if (!present) self.roots.append(a, key) catch {};
                }
                parent = key;
            }
        }
        for (self.roots.items) |root| _ = self.updateBest(root);
        self.sortPaths(self.roots.items);
        for (self.roots.items) |root| self.sortBranch(root);
        self.rebuildRows();
    }

    fn updateBest(self: *SearchTree, path: []const u8) i64 {
        const n = self.nodes.getPtr(path) orelse return std.math.minInt(i64);
        var best = n.score orelse std.math.minInt(i64);
        for (n.children.items) |c| best = @max(best, self.updateBest(c));
        self.nodes.getPtr(path).?.best = best;
        return best;
    }

    fn sortBranch(self: *SearchTree, path: []const u8) void {
        const n = self.nodes.getPtr(path) orelse return;
        for (n.children.items) |c| self.sortBranch(c);
        self.sortPaths(self.nodes.getPtr(path).?.children.items);
    }

    fn sortPaths(self: *SearchTree, paths: [][]const u8) void {
        const Ctx = struct {
            t: *SearchTree,
            fn lt(c: @This(), l: []const u8, r: []const u8) bool {
                const a = c.t.nodes.get(l).?;
                const b = c.t.nodes.get(r).?;
                if (a.best != b.best) return a.best > b.best;
                const ad = a.kind == .directory;
                const bd = b.kind == .directory;
                if (ad != bd) return ad;
                const o = std.ascii.orderIgnoreCase(a.name, b.name);
                if (o != .eq) return o == .lt;
                return std.mem.lessThan(u8, a.path, b.path);
            }
        };
        std.mem.sort([]const u8, paths, Ctx{ .t = self }, Ctx.lt);
    }

    fn rebuildRows(self: *SearchTree) void {
        self.rows = .empty;
        for (self.roots.items) |root| self.appendRows(root, 0);
    }

    fn appendRows(self: *SearchTree, path: []const u8, depth: usize) void {
        const n = self.nodes.get(path) orelse return;
        const has_children = n.children.items.len > 0;
        self.rows.append(self.arena.allocator(), .{
            .path = n.path,
            .name = n.name,
            .kind = n.kind,
            .depth = depth,
            .has_children = has_children,
            .score = n.score orelse n.best,
            .is_match = n.score != null,
        }) catch return;
        if (has_children and !self.collapsed.contains(path)) for (n.children.items) |c| self.appendRows(c, depth + 1);
    }

    pub fn toggle(self: *SearchTree, path: []const u8) bool {
        const n = self.nodes.get(path) orelse return false;
        if (n.children.items.len == 0) return false;
        if (self.collapsed.contains(path)) {
            _ = self.collapsed.remove(path);
        } else self.collapsed.put(self.arena.allocator(), n.path, {}) catch return false;
        self.rebuildRows();
        return true;
    }

    pub fn isExpanded(self: *const SearchTree, path: []const u8) bool {
        return !self.collapsed.contains(path);
    }
};

test "matches bring their ancestors, best score first" {
    var t = SearchTree.init(std.testing.allocator);
    defer t.deinit();
    t.rebuild(&.{
        .{ .path = "src/stream.rs", .name = "stream.rs", .kind = .file, .score = 8000 },
        .{ .path = "docs/stream.md", .name = "stream.md", .kind = .file, .score = 7000 },
        .{ .path = "src/a/stream_util.rs", .name = "stream_util.rs", .kind = .file, .score = 6000 },
    });
    try std.testing.expectEqualStrings("src", t.rows.items[0].path);
    try std.testing.expect(t.rows.items[0].has_children);
    try std.testing.expectEqualStrings("src/stream.rs", t.rows.items[1].path);
    try std.testing.expectEqual(@as(usize, 6), t.rows.items.len);
    try std.testing.expect(t.toggle("src"));
    try std.testing.expectEqual(@as(usize, 3), t.rows.items.len);
}
