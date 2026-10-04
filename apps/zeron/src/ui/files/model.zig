//! `TreeModel`: the explorer's lazily loaded directory tree — zeron
//! `files/model.rs` (`FileTreeModel`): nodes keyed by workspace-relative
//! path, per-directory load state with pagination, expansion, selection,
//! and the flattened `visible` rows (entries plus synthetic Loading / Empty /
//! Error / Load more rows) the virtualized list renders.
//!
//! Directory pages refresh in place: children that survive keep their own
//! expansion and loaded subtrees; vanished ones drop their subtree. Pure,
//! allocation-owning, unit-tested.

const std = @import("std");
const Allocator = std.mem.Allocator;
const proto = @import("protocol.zig");

pub const LoadState = union(enum) {
    unloaded,
    loading: struct { paging: bool },
    loaded: struct { next_cursor: ?[]u8 = null },
    failed: struct { message: []u8, paging: bool },
};

pub const Node = struct {
    path: []u8,
    name: []u8,
    kind: proto.EntryKind,
    revision: ?[]u8 = null,
    ignored: bool = false,
    read_only: bool = false,
    size: ?u64 = null,
    children: std.ArrayList([]const u8) = .empty,
    load: LoadState = .unloaded,
    stale: bool = false,
    has_loaded: bool = false,

    fn deinit(n: *Node, gpa: Allocator) void {
        gpa.free(n.path);
        gpa.free(n.name);
        if (n.revision) |r| gpa.free(r);
        n.children.deinit(gpa);
        freeLoad(gpa, &n.load);
    }

    pub fn isDirectory(n: *const Node) bool {
        return n.kind == .directory;
    }
};

fn freeLoad(gpa: Allocator, l: *LoadState) void {
    switch (l.*) {
        .loaded => |x| if (x.next_cursor) |c| gpa.free(c),
        .failed => |x| gpa.free(x.message),
        else => {},
    }
    l.* = .unloaded;
}

pub const RowKind = enum { entry, loading, empty, failed, load_more };

pub const Row = struct {
    /// Entry path (or the directory of a synthetic row).
    path: []const u8,
    depth: usize,
    kind: RowKind,

    pub fn selectable(r: Row) bool {
        return r.kind == .entry or r.kind == .load_more;
    }

    pub fn eql(a: Row, b: Row) bool {
        return a.kind == b.kind and a.depth == b.depth and std.mem.eql(u8, a.path, b.path);
    }
};

pub const TreeModel = struct {
    gpa: Allocator,
    nodes: std.StringHashMapUnmanaged(*Node) = .empty,
    expanded: std.StringHashMapUnmanaged(void) = .empty,
    visible: std.ArrayList(Row) = .empty,
    selected: ?[]u8 = null,
    include_ignored: bool = false,
    generation: u64 = 0,

    pub fn init(gpa: Allocator, include_ignored: bool) TreeModel {
        var self: TreeModel = .{ .gpa = gpa, .include_ignored = include_ignored };
        self.addRoot();
        return self;
    }

    fn addRoot(self: *TreeModel) void {
        const root = self.gpa.create(Node) catch @panic("OOM");
        root.* = .{ .path = self.gpa.dupe(u8, "") catch @panic("OOM"), .name = self.gpa.dupe(u8, "") catch @panic("OOM"), .kind = .directory };
        self.nodes.put(self.gpa, root.path, root) catch @panic("OOM");
        self.expanded.put(self.gpa, root.path, {}) catch @panic("OOM");
    }

    pub fn deinit(self: *TreeModel) void {
        self.clearNodes();
        self.nodes.deinit(self.gpa);
        self.expanded.deinit(self.gpa);
        self.visible.deinit(self.gpa);
        if (self.selected) |s| self.gpa.free(s);
    }

    fn clearNodes(self: *TreeModel) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |n| {
            n.*.deinit(self.gpa);
            self.gpa.destroy(n.*);
        }
        self.nodes.clearRetainingCapacity();
        // Expanded keys are borrowed from node paths; keep the set of path
        // strings alive by re-owning them.
        self.expanded.clearRetainingCapacity();
    }

    /// Drop everything (target change); bumps the generation.
    pub fn reset(self: *TreeModel) void {
        self.clearNodes();
        self.visible.clearRetainingCapacity();
        if (self.selected) |s| self.gpa.free(s);
        self.selected = null;
        self.addRoot();
        self.generation += 1;
    }

    pub fn setIncludeIgnored(self: *TreeModel, include: bool) bool {
        if (self.include_ignored == include) return false;
        self.include_ignored = include;
        self.reset();
        return true;
    }

    pub fn node(self: *const TreeModel, path: []const u8) ?*Node {
        return self.nodes.get(path);
    }

    pub fn isExpanded(self: *const TreeModel, path: []const u8) bool {
        return self.expanded.contains(path);
    }

    pub fn rows(self: *const TreeModel) []const Row {
        return self.visible.items;
    }

    pub fn rootLoaded(self: *const TreeModel) bool {
        const r = self.node("") orelse return false;
        return r.has_loaded;
    }

    /// Expanded directories, parents first.
    pub fn expandedDirectories(self: *const TreeModel, a: Allocator) []const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = self.expanded.keyIterator();
        while (it.next()) |k| {
            if (k.*.len == 0) continue;
            if (self.nodes.contains(k.*)) out.append(a, k.*) catch {};
        }
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                const dx = std.mem.count(u8, x, "/");
                const dy = std.mem.count(u8, y, "/");
                if (dx != dy) return dx < dy;
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        return out.items;
    }

    /// Mark `directory` loading; false when a first-page load is already in flight.
    pub fn beginLoad(self: *TreeModel, directory: []const u8, paging: bool) bool {
        const n = self.node(directory) orelse return false;
        if (n.load == .loading and !paging and !n.load.loading.paging) return false;
        freeLoad(self.gpa, &n.load);
        n.load = .{ .loading = .{ .paging = paging } };
        self.rebuild();
        return true;
    }

    pub fn failLoad(self: *TreeModel, directory: []const u8, message: []const u8, paging: bool) void {
        const n = self.node(directory) orelse return;
        freeLoad(self.gpa, &n.load);
        n.load = .{ .failed = .{ .message = self.gpa.dupe(u8, message) catch @panic("OOM"), .paging = paging } };
        self.rebuild();
    }

    /// Fold a directory page in (first page replaces, later pages append).
    pub fn applyPage(self: *TreeModel, page: proto.DirectoryPage, paging: bool) void {
        const dir = self.node(page.directory) orelse return;
        if (dir.kind != .directory) return;
        var keep: std.StringHashMapUnmanaged(void) = .empty;
        defer keep.deinit(self.gpa);
        if (paging) for (dir.children.items) |c| keep.put(self.gpa, c, {}) catch {};
        var next_children: std.ArrayList([]const u8) = .empty;
        if (paging) next_children.appendSlice(self.gpa, dir.children.items) catch {};
        for (page.entries) |e| {
            // Only direct children of this directory.
            if (!isDirectChild(e.path, page.directory)) continue;
            if (keep.contains(e.path)) continue;
            const existing = self.nodes.get(e.path);
            const n: *Node = if (existing) |x| x else blk: {
                const nn = self.gpa.create(Node) catch @panic("OOM");
                nn.* = .{ .path = self.gpa.dupe(u8, e.path) catch @panic("OOM"), .name = self.gpa.dupe(u8, e.name) catch @panic("OOM"), .kind = e.kind };
                self.nodes.put(self.gpa, nn.path, nn) catch @panic("OOM");
                break :blk nn;
            };
            if (existing != null and n.kind != e.kind) {
                // A directory became a file (or vice versa): drop its subtree.
                self.removeDescendants(n.path);
                freeLoad(self.gpa, &n.load);
                n.children.clearRetainingCapacity();
                n.has_loaded = false;
                n.kind = e.kind;
            }
            if (!std.mem.eql(u8, n.name, e.name)) {
                self.gpa.free(n.name);
                n.name = self.gpa.dupe(u8, e.name) catch @panic("OOM");
            }
            if (n.revision) |r| self.gpa.free(r);
            n.revision = if (e.mutationRevision) |r| self.gpa.dupe(u8, r) catch null else null;
            n.ignored = e.ignored;
            n.read_only = e.readOnly;
            n.size = e.size;
            if (n.kind != .directory and n.load == .unloaded) n.load = .{ .loaded = .{} };
            keep.put(self.gpa, n.path, {}) catch {};
            next_children.append(self.gpa, n.path) catch {};
        }
        if (!paging) {
            // Children that vanished lose their subtrees.
            for (dir.children.items) |old| {
                if (keep.contains(old)) continue;
                self.removeSubtree(old);
            }
        }
        dir.children.deinit(self.gpa);
        dir.children = next_children;
        self.sortChildren(dir);
        freeLoad(self.gpa, &dir.load);
        dir.load = .{ .loaded = .{ .next_cursor = if (page.nextCursor) |c| self.gpa.dupe(u8, c) catch null else null } };
        dir.has_loaded = true;
        dir.stale = false;
        self.rebuild();
    }

    fn sortChildren(self: *TreeModel, dir: *Node) void {
        const Ctx = struct {
            m: *TreeModel,
            fn lt(c: @This(), a: []const u8, b: []const u8) bool {
                const na = c.m.nodes.get(a).?;
                const nb = c.m.nodes.get(b).?;
                const ra = rank(na.kind);
                const rb = rank(nb.kind);
                if (ra != rb) return ra < rb;
                const o = std.ascii.orderIgnoreCase(na.name, nb.name);
                if (o != .eq) return o == .lt;
                return std.mem.lessThan(u8, a, b);
            }
        };
        std.mem.sort([]const u8, dir.children.items, Ctx{ .m = self }, Ctx.lt);
    }

    fn rank(k: proto.EntryKind) u8 {
        return switch (k) {
            .directory => 0,
            .file => 1,
            .symlink => 2,
        };
    }

    fn removeDescendants(self: *TreeModel, path: []const u8) void {
        const n = self.nodes.get(path) orelse return;
        const kids = self.gpa.dupe([]const u8, n.children.items) catch return;
        defer self.gpa.free(kids);
        for (kids) |c| self.removeSubtree(c);
        n.children.clearRetainingCapacity();
    }

    fn removeSubtree(self: *TreeModel, path: []const u8) void {
        const n = self.nodes.get(path) orelse return;
        self.removeDescendants(path);
        _ = self.expanded.remove(path);
        if (self.selected) |s| if (std.mem.eql(u8, s, path)) {
            self.gpa.free(s);
            self.selected = null;
        };
        _ = self.nodes.remove(path);
        n.deinit(self.gpa);
        self.gpa.destroy(n);
    }

    /// Remove an entry (delete, or a watcher's removal) and its subtree.
    pub fn remove(self: *TreeModel, path: []const u8) bool {
        if (path.len == 0 or !self.nodes.contains(path)) return false;
        const parent_path = parentPath(path);
        if (self.nodes.get(parent_path)) |p| {
            for (p.children.items, 0..) |c, i| if (std.mem.eql(u8, c, path)) {
                _ = p.children.orderedRemove(i);
                break;
            };
        }
        self.removeSubtree(path);
        self.rebuild();
        return true;
    }

    /// Toggle a directory; returns false for non-directories.
    pub fn toggleExpanded(self: *TreeModel, path: []const u8) bool {
        const n = self.node(path) orelse return false;
        if (n.kind != .directory) return false;
        if (self.expanded.contains(path)) {
            _ = self.expanded.remove(path);
            // Hidden selection moves to the collapsed ancestor.
            if (self.selected) |s| if (isDescendant(s, path)) {
                self.select(path);
            };
        } else self.expanded.put(self.gpa, n.path, {}) catch @panic("OOM");
        self.rebuild();
        return true;
    }

    pub fn expand(self: *TreeModel, path: []const u8) bool {
        const n = self.node(path) orelse return false;
        if (n.kind != .directory or self.expanded.contains(path)) return false;
        self.expanded.put(self.gpa, n.path, {}) catch @panic("OOM");
        self.rebuild();
        return true;
    }

    pub fn select(self: *TreeModel, path: []const u8) void {
        if (self.selected) |s| {
            if (std.mem.eql(u8, s, path)) return;
            self.gpa.free(s);
        }
        self.selected = self.gpa.dupe(u8, path) catch null;
    }

    pub fn clearSelection(self: *TreeModel) void {
        if (self.selected) |s| self.gpa.free(s);
        self.selected = null;
    }

    pub fn selectedIndex(self: *const TreeModel) ?usize {
        const s = self.selected orelse return null;
        for (self.visible.items, 0..) |r, i| if (r.kind == .entry and std.mem.eql(u8, r.path, s)) return i;
        return null;
    }

    fn moveSelection(self: *TreeModel, delta: isize) void {
        const rows_ = self.visible.items;
        if (rows_.len == 0) return;
        var i: isize = if (self.selectedIndex()) |ix| @as(isize, @intCast(ix)) + delta else if (delta > 0) 0 else @as(isize, @intCast(rows_.len)) - 1;
        while (i >= 0 and i < rows_.len) : (i += delta) {
            const r = rows_[@intCast(i)];
            if (r.kind == .entry) {
                self.select(r.path);
                return;
            }
        }
    }

    pub fn selectNext(self: *TreeModel) void {
        self.moveSelection(1);
    }

    pub fn selectPrevious(self: *TreeModel) void {
        self.moveSelection(-1);
    }

    pub fn selectParent(self: *TreeModel) void {
        const s = self.selected orelse return;
        const p = parentPath(s);
        if (p.len > 0) self.select(p);
    }

    pub fn selectFirstChild(self: *TreeModel) void {
        const s = self.selected orelse return;
        const n = self.node(s) orelse return;
        if (n.children.items.len > 0) self.select(n.children.items[0]);
    }

    pub fn invalidateDirectory(self: *TreeModel, directory: []const u8) bool {
        const n = self.node(directory) orelse return false;
        if (n.kind != .directory) return false;
        n.stale = true;
        return true;
    }

    /// Expand every ancestor of `path` (search reveal); returns the
    /// directories that still need loading, parents first.
    pub fn revealAncestors(self: *TreeModel, path: []const u8, a: Allocator) []const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, i, '/')) |slash| : (i = slash + 1) {
            const dir = path[0..slash];
            if (self.node(dir)) |n| {
                if (!self.expanded.contains(dir)) self.expanded.put(self.gpa, n.path, {}) catch {};
                if (!n.has_loaded) out.append(a, n.path) catch {};
            } else out.append(a, a.dupe(u8, dir) catch dir) catch {};
        }
        self.rebuild();
        return out.items;
    }

    /// Rebuild the flattened rows.
    pub fn rebuild(self: *TreeModel) void {
        self.visible.clearRetainingCapacity();
        self.appendRows("", 0, 0);
    }

    fn appendRows(self: *TreeModel, directory: []const u8, depth: usize, guard: usize) void {
        if (guard > 256) return;
        const n = self.node(directory) orelse return;
        for (n.children.items) |c| {
            const child = self.node(c) orelse continue;
            self.visible.append(self.gpa, .{ .path = child.path, .depth = depth, .kind = .entry }) catch return;
            if (child.kind == .directory and self.expanded.contains(c)) self.appendRows(c, depth + 1, guard + 1);
        }
        if (!self.expanded.contains(directory)) return;
        switch (n.load) {
            .unloaded => {},
            .loading => |l| {
                if (!n.has_loaded or l.paging) {
                    self.visible.append(self.gpa, .{ .path = n.path, .depth = depth, .kind = .loading }) catch {};
                } else if (n.children.items.len == 0) {
                    self.visible.append(self.gpa, .{ .path = n.path, .depth = depth, .kind = .empty }) catch {};
                }
            },
            .loaded => |l| {
                if (n.children.items.len == 0) self.visible.append(self.gpa, .{ .path = n.path, .depth = depth, .kind = .empty }) catch {};
                if (l.next_cursor != null) self.visible.append(self.gpa, .{ .path = n.path, .depth = depth, .kind = .load_more }) catch {};
            },
            .failed => self.visible.append(self.gpa, .{ .path = n.path, .depth = depth, .kind = .failed }) catch {},
        }
    }
};

pub fn parentPath(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[0..i];
    return "";
}

pub fn baseName(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

pub fn isDescendant(candidate: []const u8, ancestor: []const u8) bool {
    if (ancestor.len == 0) return candidate.len > 0;
    return candidate.len > ancestor.len and std.mem.startsWith(u8, candidate, ancestor) and candidate[ancestor.len] == '/';
}

fn isDirectChild(candidate: []const u8, directory: []const u8) bool {
    if (candidate.len == 0) return false;
    return std.mem.eql(u8, parentPath(candidate), directory) and !std.mem.eql(u8, candidate, directory);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn pageOf(dir: []const u8, entries: []const proto.Entry) proto.DirectoryPage {
    return .{ .directory = dir, .entries = entries };
}

fn ent(path: []const u8, kind: proto.EntryKind) proto.Entry {
    return .{ .path = path, .name = baseName(path), .kind = kind };
}

fn rowPaths(m: *const TreeModel, a: Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (m.rows()) |r| {
        try out.appendSlice(a, switch (r.kind) {
            .entry => r.path,
            .loading => "<loading>",
            .empty => "<empty>",
            .failed => "<error>",
            .load_more => "<more>",
        });
        try out.append(a, ' ');
    }
    return out.items;
}

test "root page sorts dirs first and expansion inserts children with a loading row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var m = TreeModel.init(testing.allocator, false);
    defer m.deinit();
    try testing.expect(m.beginLoad("", false));
    m.applyPage(pageOf("", &.{ ent("README.md", .file), ent("src", .directory), ent(".gitignore", .file), ent("docs", .directory) }), false);
    try testing.expectEqualStrings("docs src .gitignore README.md ", try rowPaths(&m, a));
    try testing.expect(m.toggleExpanded("src"));
    try testing.expect(m.beginLoad("src", false));
    try testing.expectEqualStrings("docs src <loading> .gitignore README.md ", try rowPaths(&m, a));
    m.applyPage(pageOf("src", &.{ ent("src/main.rs", .file), ent("src/lib.rs", .file) }), false);
    try testing.expectEqualStrings("docs src src/lib.rs src/main.rs .gitignore README.md ", try rowPaths(&m, a));
    try testing.expectEqual(@as(usize, 1), m.rows()[2].depth);
    // Refresh drops vanished children, keeps expansion.
    m.applyPage(pageOf("", &.{ ent("src", .directory), ent("README.md", .file) }), false);
    try testing.expectEqualStrings("src src/lib.rs src/main.rs README.md ", try rowPaths(&m, a));
    // Empty dirs show an Empty row.
    m.applyPage(pageOf("src", &.{}), false);
    try testing.expectEqualStrings("src <empty> README.md ", try rowPaths(&m, a));
}

test "keyboard selection, collapse moves selection to the ancestor, remove" {
    var m = TreeModel.init(testing.allocator, false);
    defer m.deinit();
    m.applyPage(pageOf("", &.{ ent("a", .directory), ent("z.txt", .file) }), false);
    _ = m.toggleExpanded("a");
    m.applyPage(pageOf("a", &.{ent("a/b.txt", .file)}), false);
    m.selectNext();
    try testing.expectEqualStrings("a", m.selected.?);
    m.selectNext();
    try testing.expectEqualStrings("a/b.txt", m.selected.?);
    _ = m.toggleExpanded("a");
    try testing.expectEqualStrings("a", m.selected.?);
    try testing.expect(m.remove("a"));
    try testing.expect(m.selected == null);
    try testing.expectEqual(@as(usize, 1), m.rows().len);
}

test "errors and pagination rows" {
    var m = TreeModel.init(testing.allocator, false);
    defer m.deinit();
    m.failLoad("", "boom", false);
    try testing.expectEqual(RowKind.failed, m.rows()[0].kind);
    m.applyPage(.{ .directory = "", .entries = &.{ent("x", .file)}, .nextCursor = "c1" }, false);
    try testing.expectEqual(RowKind.load_more, m.rows()[1].kind);
    _ = m.beginLoad("", true);
    m.applyPage(.{ .directory = "", .entries = &.{ent("y", .file)} }, true);
    try testing.expectEqual(@as(usize, 2), m.rows().len);
}
