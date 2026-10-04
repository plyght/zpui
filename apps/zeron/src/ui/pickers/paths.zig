//! Folder-browser path helpers (zeron `pickers.rs`: `parent_path`,
//! `child_path`, `completion_prefix_len`, `segment_target`, `is_typed_path`,
//! `typed_path_target`, `breadcrumbs`) — POSIX and Windows drive paths.
//! Results are allocated with the caller's allocator.

const std = @import("std");
const Allocator = std.mem.Allocator;

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

pub fn isWindowsPath(path: []const u8) bool {
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path.len == 2 or isSep(path[2]));
}

/// Parent of an absolute path; null at the filesystem root.
pub fn parentPath(a: Allocator, path: []const u8) ?[]const u8 {
    if (isWindowsPath(path)) {
        const drive = path[0..2];
        const rest = std.mem.trim(u8, path[2..], "/\\");
        if (rest.len == 0) return null;
        const parent = if (std.mem.findLastAny(u8, rest, "/\\")) |at| rest[0..at] else "";
        return std.fmt.allocPrint(a, "{s}\\{s}", .{ drive, parent }) catch null;
    }
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return null;
    const at = std.mem.findLast(u8, trimmed, "/") orelse return null;
    if (at == 0) return "/";
    return trimmed[0..at];
}

/// Join a listing path and an entry name.
pub fn childPath(a: Allocator, base: []const u8, name: []const u8) []const u8 {
    if (base.len > 0 and isSep(base[base.len - 1])) return std.fmt.allocPrint(a, "{s}{s}", .{ base, name }) catch base;
    if (isWindowsPath(base)) return std.fmt.allocPrint(a, "{s}\\{s}", .{ base, name }) catch base;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ base, name }) catch base;
}

/// Byte length of `name`'s prefix matching `query` (ASCII case-insensitive,
/// byte-exact otherwise); null when `query` isn't a prefix.
pub fn completionPrefixLen(name: []const u8, query: []const u8) ?usize {
    if (query.len > name.len) return null;
    for (query, 0..) |q, i| {
        if (std.ascii.toLower(q) != std.ascii.toLower(name[i])) return null;
    }
    return query.len;
}

/// Resolve a typed segment against folder `names`: exact (case-sensitive),
/// then exact case-insensitive, then a unique prefix; ambiguity → null.
pub fn segmentTarget(names: []const []const u8, query: []const u8) ?usize {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, query)) return i;
    for (names, 0..) |n, i| if (completionPrefixLen(n, query) == n.len) return i;
    var hit: ?usize = null;
    for (names, 0..) |n, i| if (completionPrefixLen(n, query) != null) {
        if (hit != null) return null;
        hit = i;
    };
    return hit;
}

pub fn isTypedPath(query: []const u8) bool {
    return (query.len > 0 and (query[0] == '/' or query[0] == '~')) or isWindowsPath(query);
}

/// A typed path jump (absolute, drive-rooted, `~`/`~/x`); null otherwise or
/// when `~` can't expand yet.
pub fn typedPathTarget(a: Allocator, query_in: []const u8, home: ?[]const u8) ?[]const u8 {
    const query = std.mem.trim(u8, query_in, " \t");
    if (isWindowsPath(query)) {
        const path = a.dupe(u8, query) catch return null;
        std.mem.replaceScalar(u8, path, '/', '\\');
        const trimmed = std.mem.trimEnd(u8, path, "\\");
        if (trimmed.len == 2) return std.fmt.allocPrint(a, "{s}\\", .{trimmed}) catch null;
        return trimmed;
    }
    if (query.len > 0 and query[0] == '~') {
        const h = std.mem.trimEnd(u8, home orelse return null, "/");
        const rest = query[1..];
        if (rest.len == 0) return h;
        if (rest[0] != '/') return null;
        const tail = std.mem.trimEnd(u8, rest[1..], "/");
        if (tail.len == 0) return h;
        return std.fmt.allocPrint(a, "{s}/{s}", .{ h, tail }) catch null;
    }
    if (query.len > 0 and query[0] == '/') {
        const trimmed = std.mem.trimEnd(u8, query, "/");
        return if (trimmed.len == 0) "/" else trimmed;
    }
    return null;
}

pub const Crumb = struct { label: []const u8, full: []const u8 };

/// Breadcrumb segments, root first.
pub fn breadcrumbs(a: Allocator, path: []const u8) []Crumb {
    var out: std.ArrayList(Crumb) = .empty;
    const win = isWindowsPath(path);
    const drive = if (win) path[0..2] else "";
    const sep: u8 = if (win) '\\' else '/';
    const rest = if (win) path[2..] else path;
    const root = std.fmt.allocPrint(a, "{s}{c}", .{ drive, sep }) catch return &.{};
    out.append(a, .{ .label = root, .full = root }) catch return &.{};
    var acc: std.ArrayList(u8) = .empty;
    acc.appendSlice(a, drive) catch return out.items;
    var it = std.mem.tokenizeAny(u8, rest, if (win) "/\\" else "/");
    while (it.next()) |seg| {
        acc.append(a, sep) catch break;
        acc.appendSlice(a, seg) catch break;
        out.append(a, .{ .label = seg, .full = a.dupe(u8, acc.items) catch break }) catch break;
    }
    return out.items;
}

/// Segment-aware "is `path` at or under `base`".
pub fn pathUnder(path: []const u8, base_in: []const u8) bool {
    const base = std.mem.trimEnd(u8, base_in, "/\\");
    if (base.len == 0) return true;
    if (!std.mem.startsWith(u8, path, base)) return false;
    const rest = path[base.len..];
    return rest.len == 0 or isSep(rest[0]);
}

const testing = std.testing;

test "folder paths and breadcrumbs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("/home/w", parentPath(a, "/home/w/dev").?);
    try testing.expectEqualStrings("/", parentPath(a, "/home").?);
    try testing.expectEqualStrings("/", parentPath(a, "/home/").?);
    try testing.expect(parentPath(a, "/") == null);
    try testing.expect(parentPath(a, "") == null);
    try testing.expectEqualStrings("/home/w", childPath(a, "/home", "w"));
    try testing.expectEqualStrings("/home", childPath(a, "/", "home"));
    const crumbs = breadcrumbs(a, "/home/w/dev");
    try testing.expectEqual(@as(usize, 4), crumbs.len);
    try testing.expectEqualStrings("/", crumbs[0].label);
    try testing.expectEqualStrings("w", crumbs[2].label);
    try testing.expectEqualStrings("/home/w", crumbs[2].full);
    try testing.expectEqual(@as(usize, 1), breadcrumbs(a, "/").len);
}

test "windows folder paths and breadcrumbs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("D:\\Random", parentPath(a, "D:\\Random\\zeron").?);
    try testing.expectEqualStrings("D:\\", parentPath(a, "D:\\Random").?);
    try testing.expectEqualStrings("D:\\", parentPath(a, "D:\\Random\\").?);
    try testing.expect(parentPath(a, "D:\\") == null);
    try testing.expect(parentPath(a, "D:") == null);
    try testing.expectEqualStrings("D:\\Random", childPath(a, "D:\\", "Random"));
    try testing.expectEqualStrings("D:\\Random\\zeron", childPath(a, "D:\\Random", "zeron"));
    const crumbs = breadcrumbs(a, "D:\\Random\\zeron");
    try testing.expectEqual(@as(usize, 3), crumbs.len);
    try testing.expectEqualStrings("D:\\", crumbs[0].label);
    try testing.expectEqualStrings("D:\\Random", crumbs[1].full);
    try testing.expect(!isWindowsPath("/D:/x"));
    try testing.expect(!isWindowsPath("ab:/x"));
}

test "completion prefixes and segment targets" {
    try testing.expectEqual(@as(?usize, 3), completionPrefixLen("Documents", "doc"));
    try testing.expectEqual(@as(?usize, 5), completionPrefixLen("zeron", "zeron"));
    try testing.expectEqual(@as(?usize, 0), completionPrefixLen("zeron", ""));
    try testing.expectEqual(@as(?usize, null), completionPrefixLen("zeron", "dev"));
    try testing.expectEqual(@as(?usize, null), completionPrefixLen("dev", "devel"));
    const names = [_][]const u8{ "github", "GitHub", "worktree" };
    try testing.expectEqual(@as(?usize, 1), segmentTarget(&names, "GitHub"));
    try testing.expectEqual(@as(?usize, 0), segmentTarget(&names, "github"));
    try testing.expectEqual(@as(?usize, 2), segmentTarget(&names, "WORKTREE"));
    try testing.expectEqual(@as(?usize, 2), segmentTarget(&names, "work"));
    try testing.expectEqual(@as(?usize, null), segmentTarget(&names, "g"));
    try testing.expectEqual(@as(?usize, null), segmentTarget(&names, "x"));
}

test "typed path targets" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const home: ?[]const u8 = "/home/wing";
    try testing.expectEqualStrings("/disk2", typedPathTarget(a, "/disk2/", home).?);
    try testing.expectEqualStrings("/disk2/projects", typedPathTarget(a, "/disk2/projects", home).?);
    try testing.expectEqualStrings("/", typedPathTarget(a, "/", home).?);
    try testing.expectEqualStrings("/home/wing", typedPathTarget(a, "~", home).?);
    try testing.expectEqualStrings("/home/wing", typedPathTarget(a, "~/", home).?);
    try testing.expectEqualStrings("/home/wing/github", typedPathTarget(a, "~/github/", home).?);
    try testing.expect(typedPathTarget(a, "~x", home) == null);
    try testing.expect(typedPathTarget(a, "src", home) == null);
    try testing.expect(typedPathTarget(a, "~/github", null) == null);
    try testing.expectEqualStrings("D:\\", typedPathTarget(a, "D:", null).?);
    try testing.expectEqualStrings("D:\\", typedPathTarget(a, "D:/", null).?);
    try testing.expectEqualStrings("D:\\Random\\zeron", typedPathTarget(a, "D:/Random/zeron", null).?);
    try testing.expect(isTypedPath("D:\\x") and isTypedPath("/x") and isTypedPath("~"));
    try testing.expect(!isTypedPath("src") and !isTypedPath("ab:/x"));
    try testing.expect(pathUnder("/media/a/x", "/media/a"));
    try testing.expect(!pathUnder("/media/ab", "/media/a"));
    try testing.expect(pathUnder("/anything", "/"));
}
