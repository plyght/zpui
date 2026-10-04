//! Git status colors for explorer rows — zeron `files/git_status.rs`
//! (`Decoration`, `Decorations::from_snapshot`): a file's index/worktree
//! states fold to one kind; every ancestor directory takes the strongest
//! kind beneath it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zt = @import("zeron_theme");
const proto = @import("protocol.zig");

pub const Kind = enum(u8) {
    untracked,
    added,
    modified,
    renamed,
    deleted,
    conflict,

    pub fn color(k: Kind, theme: *const zt.Theme) @import("zpui").Hsla {
        return switch (k) {
            .untracked, .added => theme.success,
            .modified => theme.warning,
            .renamed => theme.accent,
            .deleted, .conflict => theme.danger,
        };
    }
};

pub fn kindOf(f: proto.GitFileStatus) Kind {
    const s = [2]proto.GitFileState{ f.index, f.worktree };
    const has = struct {
        fn any(states: [2]proto.GitFileState, st: proto.GitFileState) bool {
            return states[0] == st or states[1] == st;
        }
    }.any;
    if (has(s, .unmerged) or (f.index == .added and f.worktree == .added) or (f.index == .deleted and f.worktree == .deleted)) return .conflict;
    if (has(s, .deleted) and has(s, .untracked)) return .modified;
    if (has(s, .deleted)) return .deleted;
    if (has(s, .renamed) or has(s, .copied)) return .renamed;
    if (has(s, .modified) or has(s, .typeChanged)) return .modified;
    if (has(s, .untracked)) return .untracked;
    return .added;
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |p| if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return false;
    return true;
}

pub const Decorations = struct {
    arena: std.heap.ArenaAllocator,
    files: std.StringHashMapUnmanaged(Kind) = .empty,
    dirs: std.StringHashMapUnmanaged(Kind) = .empty,

    pub fn init(gpa: Allocator) Decorations {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Decorations) void {
        self.arena.deinit();
    }

    pub fn clear(self: *Decorations) void {
        _ = self.arena.reset(.retain_capacity);
        self.files = .empty;
        self.dirs = .empty;
    }

    pub fn load(self: *Decorations, snapshot: ?*const proto.CheckoutGitStatus) void {
        self.clear();
        const st = snapshot orelse return;
        if (!st.complete) return;
        const a = self.arena.allocator();
        for (st.files) |f| {
            if (!validPath(f.path)) continue;
            const k = kindOf(f);
            const path = a.dupe(u8, f.path) catch continue;
            self.files.put(a, path, k) catch {};
            const paths = [2]?[]const u8{ f.path, f.oldPath };
            for (paths) |maybe| {
                const p = maybe orelse continue;
                if (!validPath(p)) continue;
                var end = p.len;
                while (std.mem.lastIndexOfScalar(u8, p[0..end], '/')) |slash| {
                    const dir = a.dupe(u8, p[0..slash]) catch break;
                    const gop = self.dirs.getOrPut(a, dir) catch break;
                    if (!gop.found_existing or @intFromEnum(k) > @intFromEnum(gop.value_ptr.*)) gop.value_ptr.* = k;
                    end = slash;
                }
            }
        }
    }

    pub fn get(self: *const Decorations, path: []const u8, is_dir: bool) ?Kind {
        return if (is_dir) self.dirs.get(path) else self.files.get(path);
    }
};

test "directories take the strongest descendant kind" {
    var d = Decorations.init(std.testing.allocator);
    defer d.deinit();
    const st: proto.CheckoutGitStatus = .{ .checkoutId = "c", .deviceId = "d", .revision = "r", .complete = true, .files = &.{
        .{ .path = "src/config.rs", .index = .unchanged, .worktree = .modified },
        .{ .path = "src/retry.rs", .index = .untracked, .worktree = .untracked },
    } };
    d.load(&st);
    try std.testing.expectEqual(Kind.modified, d.get("src/config.rs", false).?);
    try std.testing.expectEqual(Kind.untracked, d.get("src/retry.rs", false).?);
    try std.testing.expectEqual(Kind.modified, d.get("src", true).?);
    try std.testing.expect(d.get("src/lib.rs", false) == null);
}
