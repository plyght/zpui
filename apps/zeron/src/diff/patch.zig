//! Unified git patch model + parser — port of `zeron_ui::changes`
//! (`parse_patch`, `file_notices`, `truncate_file_lines`, `split_pairs`)
//! and `zeron_ui::transcript::diff_to_file` (tool edit → `FileDiff` through
//! `similar`'s line diff with 3 lines of context).

const std = @import("std");
const Allocator = std.mem.Allocator;
const similar = @import("similar.zig");

pub const LineKind = enum {
    context,
    add,
    del,
    /// `\ No newline at end of file` and friends.
    meta,
};

pub const DiffLine = struct {
    kind: LineKind,
    old_no: ?u32,
    new_no: ?u32,
    text: []const u8,
};

pub const Hunk = struct {
    header: []const u8,
    lines: []DiffLine,
};

pub const FileStatus = enum { added, deleted, modified, renamed };

pub const FileDiff = struct {
    /// Display path (the post-change side).
    path: []const u8,
    /// Pre-rename path, when different.
    old_path: ?[]const u8 = null,
    status: FileStatus = .modified,
    binary: bool = false,
    /// Parser-collected notices (mode changes etc.).
    notices: [][]const u8 = &.{},
    hunks: []Hunk = &.{},
    additions: u32 = 0,
    deletions: u32 = 0,
    /// Largest line number on either side (sizes the gutters).
    max_line: u32 = 0,
};

/// Parsed files plus the arena owning every string and slice in them.
pub const PatchSet = struct {
    arena: std.heap.ArenaAllocator,
    files: []FileDiff,

    pub fn deinit(self: *PatchSet) void {
        self.arena.deinit();
    }
};

fn isWs(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn decode(s: []const u8, i: usize) struct { u21, usize } {
    const n = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ 0xFFFD, 1 };
    if (i + n > s.len) return .{ 0xFFFD, 1 };
    const cp = std.unicode.utf8Decode(s[i .. i + n]) catch return .{ 0xFFFD, 1 };
    return .{ cp, n };
}

fn decodeBack(s: []const u8, end: usize) struct { u21, usize } {
    var i = end - 1;
    var k: usize = 0;
    while (i > 0 and k < 3 and (s[i] & 0xC0) == 0x80) : (k += 1) i -= 1;
    const d = decode(s, i);
    if (i + d[1] != end) return .{ 0xFFFD, 1 };
    return d;
}

/// `str::trim` (Unicode White_Space).
pub fn trim(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const d = decode(s, i);
        if (!isWs(d[0])) break;
        i += d[1];
    }
    var e = s.len;
    while (e > i) {
        const d = decodeBack(s, e);
        if (!isWs(d[0])) break;
        e -= d[1];
    }
    return s[i..e];
}

fn stripGitPrefix(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "a/") or std.mem.startsWith(u8, path, "b/")) return path[2..];
    return path;
}

fn unquote(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const t = trim(s);
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') {
        const inner = t[1 .. t.len - 1];
        const r1 = try std.mem.replaceOwned(u8, a, inner, "\\\"", "\"");
        return std.mem.replaceOwned(u8, a, r1, "\\\\", "\\");
    }
    return t;
}

/// Split the tail of a `diff --git a/… b/…` line into (old, new) paths.
fn parseGitPaths(a: Allocator, rest: []const u8) Allocator.Error!struct { []const u8, []const u8 } {
    const pos = std.mem.lastIndexOf(u8, rest, " b/") orelse std.mem.lastIndexOf(u8, rest, " \"b/");
    if (pos) |p| {
        const old = try unquote(a, rest[0..p]);
        const new = try unquote(a, rest[p + 1 ..]);
        return .{ stripGitPrefix(old), stripGitPrefix(new) };
    }
    const path = stripGitPrefix(try unquote(a, rest));
    return .{ path, path };
}

/// Split at the first char matching `,` or whitespace (`split(..).next()`).
fn firstField(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const d = decode(s, i);
        if (d[0] == ',' or isWs(d[0])) break;
        i += d[1];
    }
    return s[0..i];
}

/// Rust `u32::from_str`: optional leading `+`, ASCII digits, no overflow.
fn parseU32(s: []const u8) ?u32 {
    var t = s;
    if (t.len > 0 and t[0] == '+') t = t[1..];
    if (t.len == 0) return null;
    for (t) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u32, t, 10) catch null;
}

/// Parse one `@@ -a[,b] +c[,d] @@ …` header into starting line numbers.
fn parseHunkHeader(line: []const u8) ?struct { u32, u32 } {
    if (!std.mem.startsWith(u8, line, "@@")) return null;
    const rest = line[2..];
    const minus = std.mem.indexOfScalar(u8, rest, '-') orelse return null;
    const old = parseU32(firstField(rest[minus + 1 ..])) orelse return null;
    const plus = std.mem.indexOfScalar(u8, rest, '+') orelse return null;
    const new = parseU32(firstField(rest[plus + 1 ..])) orelse return null;
    return .{ old, new };
}

/// Rust `str::lines`.
const LineIter = struct {
    s: []const u8,
    pos: usize = 0,
    fn next(self: *LineIter) ?[]const u8 {
        if (self.pos >= self.s.len) return null;
        const rest = self.s[self.pos..];
        var line: []const u8 = undefined;
        if (std.mem.indexOfScalar(u8, rest, '\n')) |i| {
            line = rest[0..i];
            self.pos += i + 1;
        } else {
            line = rest;
            self.pos = self.s.len;
        }
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return line;
    }
};

const FileBuilder = struct {
    file: FileDiff,
    notices: std.ArrayList([]const u8) = .empty,
    hunks: std.ArrayList(struct { header: []const u8, lines: std.ArrayList(DiffLine) }) = .empty,
};

/// Parse a unified git patch into file sections. Tolerant: unknown header
/// lines are skipped, truncated hunks keep what parsed so far.
pub fn parsePatch(gpa: Allocator, patch: []const u8) Allocator.Error!PatchSet {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var files: std.ArrayList(FileBuilder) = .empty;
    var in_hunk = false;
    var old_no: u32 = 0;
    var new_no: u32 = 0;

    var it = LineIter{ .s = try a.dupe(u8, patch) };
    while (it.next()) |raw| {
        if (std.mem.startsWith(u8, raw, "diff --git ")) {
            const paths = try parseGitPaths(a, raw["diff --git ".len..]);
            const old_path: ?[]const u8 = if (!std.mem.eql(u8, paths[0], paths[1])) paths[0] else null;
            try files.append(a, .{ .file = .{ .path = paths[1], .old_path = old_path } });
            in_hunk = false;
            continue;
        }
        if (files.items.len == 0) continue;
        const fb = &files.items[files.items.len - 1];
        const file = &fb.file;

        if (std.mem.startsWith(u8, raw, "@@")) {
            if (parseHunkHeader(raw)) |h| {
                old_no = h[0];
                new_no = h[1];
                try fb.hunks.append(a, .{ .header = raw, .lines = .empty });
                in_hunk = true;
            }
            continue;
        }

        if (in_hunk) {
            var line: ?DiffLine = null;
            if (raw.len == 0) {
                line = .{ .kind = .context, .old_no = old_no, .new_no = new_no, .text = "" };
                old_no +%= 1;
                new_no +%= 1;
            } else {
                const d = decode(raw, 0);
                const body = raw[d[1]..];
                switch (d[0]) {
                    '+' => {
                        file.additions +%= 1;
                        line = .{ .kind = .add, .old_no = null, .new_no = new_no, .text = body };
                        new_no +%= 1;
                    },
                    '-' => {
                        file.deletions +%= 1;
                        line = .{ .kind = .del, .old_no = old_no, .new_no = null, .text = body };
                        old_no +%= 1;
                    },
                    ' ' => {
                        line = .{ .kind = .context, .old_no = old_no, .new_no = new_no, .text = body };
                        old_no +%= 1;
                        new_no +%= 1;
                    },
                    '\\' => line = .{
                        .kind = .meta,
                        .old_no = null,
                        .new_no = null,
                        .text = trim(std.mem.trimStart(u8, raw, "\\")),
                    },
                    else => in_hunk = false, // A non-hunk line ends the hunk; reprocess as a header.
                }
            }
            if (line) |l| {
                if (fb.hunks.items.len > 0) {
                    file.max_line = @max(file.max_line, @max(l.old_no orelse 0, l.new_no orelse 0));
                    try fb.hunks.items[fb.hunks.items.len - 1].lines.append(a, l);
                    continue;
                }
            }
            if (in_hunk) continue;
        }

        // File header territory.
        if (std.mem.startsWith(u8, raw, "new file mode")) {
            file.status = .added;
        } else if (std.mem.startsWith(u8, raw, "deleted file mode")) {
            file.status = .deleted;
        } else if (std.mem.startsWith(u8, raw, "rename from ")) {
            file.status = .renamed;
            file.old_path = trim(raw["rename from ".len..]);
        } else if (std.mem.startsWith(u8, raw, "rename to ")) {
            file.status = .renamed;
            file.path = trim(raw["rename to ".len..]);
        } else if (std.mem.startsWith(u8, raw, "Binary files") or std.mem.startsWith(u8, raw, "GIT binary patch")) {
            file.binary = true;
        } else if (std.mem.startsWith(u8, raw, "new mode ")) {
            try fb.notices.append(a, try std.fmt.allocPrint(a, "Mode changed to {s}", .{trim(raw["new mode ".len..])}));
        } else if (std.mem.startsWith(u8, raw, "+++ ")) {
            const new = trim(raw["+++ ".len..]);
            if (std.mem.eql(u8, new, "/dev/null")) {
                file.status = .deleted;
            } else if (file.old_path == null) {
                file.path = stripGitPrefix(new);
            }
        } else if (std.mem.startsWith(u8, raw, "--- ") and std.mem.eql(u8, trim(raw["--- ".len..]), "/dev/null")) {
            file.status = .added;
        }
        // "index …", "similarity index …", "old mode …" etc.: skipped.
    }

    const out = try a.alloc(FileDiff, files.items.len);
    for (files.items, out) |*fb, *o| {
        o.* = fb.file;
        o.notices = fb.notices.items;
        const hunks = try a.alloc(Hunk, fb.hunks.items.len);
        for (fb.hunks.items, hunks) |h, *hh| hh.* = .{ .header = h.header, .lines = h.lines.items };
        o.hunks = hunks;
    }
    return .{ .arena = arena, .files = out };
}

/// Derived per-file notice rows (new/deleted/renamed/binary + parser
/// notices), allocated in `a`.
pub fn fileNotices(a: Allocator, file: FileDiff) Allocator.Error![][]const u8 {
    var notices: std.ArrayList([]const u8) = .empty;
    switch (file.status) {
        .added => try notices.append(a, "New file"),
        .deleted => try notices.append(a, "Deleted file"),
        .renamed => try notices.append(a, try std.fmt.allocPrint(a, "Renamed from {s}", .{file.old_path orelse "?"})),
        .modified => {},
    }
    if (file.binary) try notices.append(a, "Binary file \u{2014} contents not shown");
    try notices.appendSlice(a, file.notices);
    return notices.toOwnedSlice(a);
}

/// Cap a file's hunks at `max_lines` total diff lines, appending a notice
/// when lines were dropped. New slices come from `a` (use the set's arena).
pub fn truncateFileLines(a: Allocator, file: *FileDiff, max_lines: usize) Allocator.Error!void {
    var total: usize = 0;
    for (file.hunks) |h| total += h.lines.len;
    if (total <= max_lines) return;
    var budget = max_lines;
    var kept: std.ArrayList(Hunk) = .empty;
    for (file.hunks) |h| {
        if (budget == 0) break;
        var hh = h;
        if (hh.lines.len > budget) hh.lines = hh.lines[0..budget];
        budget -= hh.lines.len;
        try kept.append(a, hh);
    }
    file.hunks = kept.items;
    var notices: std.ArrayList([]const u8) = .empty;
    try notices.appendSlice(a, file.notices);
    try notices.append(a, try std.fmt.allocPrint(a, "Diff truncated \u{2014} showing first {d} of {d} lines", .{ max_lines, total }));
    file.notices = notices.items;
    var max: u32 = 0;
    for (file.hunks) |h| for (h.lines) |l| {
        max = @max(max, @max(l.old_no orelse 0, l.new_no orelse 0));
    };
    file.max_line = max;
}

/// One split row: indices into the hunk's lines for the left (old) and right
/// (new) column; null = that column is empty for this row.
pub const LinePair = struct { left: ?u32, right: ?u32 };

pub fn splitPairs(a: Allocator, lines: []const DiffLine) Allocator.Error![]LinePair {
    return splitPairsUpto(a, lines, std.math.maxInt(usize));
}

/// Pair a hunk's lines into split rows, stopping at `max_rows`
/// (`split_pairs_upto`).
pub fn splitPairsUpto(a: Allocator, lines: []const DiffLine, max_rows: usize) Allocator.Error![]LinePair {
    const Block = struct {
        dels: std.ArrayList(u32) = .empty,
        adds: std.ArrayList(u32) = .empty,
        del_meta: std.ArrayList(u32) = .empty,
        add_meta: std.ArrayList(u32) = .empty,
    };
    const S = struct {
        fn drain(al: Allocator, pairs: *std.ArrayList(LinePair), left: *std.ArrayList(u32), right: *std.ArrayList(u32), max: usize) Allocator.Error!void {
            const n = @max(left.items.len, right.items.len);
            for (0..n) |ix| {
                if (pairs.items.len >= max) break;
                try pairs.append(al, .{
                    .left = if (ix < left.items.len) left.items[ix] else null,
                    .right = if (ix < right.items.len) right.items[ix] else null,
                });
            }
            left.clearRetainingCapacity();
            right.clearRetainingCapacity();
        }
        fn flush(al: Allocator, pairs: *std.ArrayList(LinePair), b: *Block, max: usize) Allocator.Error!void {
            try drain(al, pairs, &b.dels, &b.adds, max);
            try drain(al, pairs, &b.del_meta, &b.add_meta, max);
        }
    };

    var pairs: std.ArrayList(LinePair) = .empty;
    var block: Block = .{};
    var pending_side: ?LineKind = null;
    for (lines, 0..) |line, ix_usize| {
        const ix: u32 = @intCast(ix_usize);
        switch (line.kind) {
            .del => {
                if (block.adds.items.len != 0 or block.del_meta.items.len != 0 or block.add_meta.items.len != 0) {
                    try S.flush(a, &pairs, &block, max_rows);
                }
                const remaining = max_rows - @min(pairs.items.len, max_rows);
                if (remaining == 0) break;
                if (block.dels.items.len < remaining) try block.dels.append(a, ix);
                pending_side = .del;
            },
            .add => {
                if (block.add_meta.items.len != 0) try S.flush(a, &pairs, &block, max_rows);
                const remaining = max_rows - @min(pairs.items.len, max_rows);
                if (remaining == 0) break;
                if (block.adds.items.len < remaining) try block.adds.append(a, ix);
                pending_side = .add;
            },
            .meta => {
                if (pending_side == .del) {
                    try block.del_meta.append(a, ix);
                } else if (pending_side == .add) {
                    try block.add_meta.append(a, ix);
                } else {
                    try block.del_meta.append(a, ix);
                    try block.add_meta.append(a, ix);
                }
            },
            .context => {
                try S.flush(a, &pairs, &block, max_rows);
                if (pairs.items.len >= max_rows) break;
                try pairs.append(a, .{ .left = ix, .right = ix });
                pending_side = .context;
            },
        }
    }
    try S.flush(a, &pairs, &block, max_rows);
    if (pairs.items.len > max_rows) pairs.shrinkRetainingCapacity(max_rows);
    return pairs.toOwnedSlice(a);
}

/// `transcript::diff_to_file`: reduce a tool edit (`old_text` null = new
/// file) to a `FileDiff` — hunks grouped with 3 context lines, dual 1-based
/// line numbers, unified hunk headers, add/del counts. The set owns copies
/// of every string.
pub fn diffToFile(gpa: Allocator, path: []const u8, old_text: ?[]const u8, new_text: []const u8) Allocator.Error!PatchSet {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const old = old_text orelse "";
    var td = try similar.TextDiff.fromLines(gpa, old, new_text);
    defer td.deinit();

    var hunks: std.ArrayList(Hunk) = .empty;
    var additions: u32 = 0;
    var deletions: u32 = 0;
    var max_line: u32 = 0;
    const groups = try similar.groupDiffOps(a, td.ops, 3);
    for (groups) |group| {
        if (group.len == 0) continue;
        const first = group[0];
        const last = group[group.len - 1];
        const os = first.oldRange().start;
        const oe = last.oldRange().end;
        const ns = first.newRange().start;
        const ne = last.newRange().end;
        const header = try std.fmt.allocPrint(a, "@@ -{d},{d} +{d},{d} @@", .{ os + 1, oe - os, ns + 1, ne - ns });
        var lines: std.ArrayList(DiffLine) = .empty;
        var changes: std.ArrayList(similar.Change) = .empty;
        for (group) |op| {
            changes.clearRetainingCapacity();
            try td.iterChanges(a, op, &changes);
            for (changes.items) |c| {
                const kind: LineKind = switch (c.tag) {
                    .delete => blk: {
                        deletions += 1;
                        break :blk .del;
                    },
                    .insert => blk: {
                        additions += 1;
                        break :blk .add;
                    },
                    .equal => .context,
                };
                const o: ?u32 = if (c.old_index) |i| @intCast(i + 1) else null;
                const n: ?u32 = if (c.new_index) |i| @intCast(i + 1) else null;
                max_line = @max(max_line, @max(o orelse 0, n orelse 0));
                const text = try a.dupe(u8, std.mem.trimEnd(u8, c.value, "\n"));
                try lines.append(a, .{ .kind = kind, .old_no = o, .new_no = n, .text = text });
            }
        }
        try hunks.append(a, .{ .header = header, .lines = lines.items });
    }
    const files = try a.alloc(FileDiff, 1);
    files[0] = .{
        .path = try a.dupe(u8, path),
        .old_path = null,
        .status = if (old_text == null) .added else .modified,
        .binary = false,
        .notices = &.{},
        .hunks = hunks.items,
        .additions = additions,
        .deletions = deletions,
        .max_line = max_line,
    };
    return .{ .arena = arena, .files = files };
}

test "parse_patch basics" {
    var set = try parsePatch(std.testing.allocator, "diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n");
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 1), set.files.len);
    const f = set.files[0];
    try std.testing.expectEqualStrings("x", f.path);
    try std.testing.expectEqual(@as(u32, 1), f.additions);
    try std.testing.expectEqual(@as(u32, 1), f.deletions);
    try std.testing.expectEqual(LineKind.del, f.hunks[0].lines[0].kind);
    try std.testing.expectEqual(@as(?u32, 1), f.hunks[0].lines[1].new_no);
}
