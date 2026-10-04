//! Parity against the Rust originals: testdata/*.jsonl were produced by
//! apps/zeron/scripts/diff_parity.rs linking zeron_ui (parse_patch & co.,
//! transcript::diff_to_file) and similar 2.7.0. Each record must match
//! byte-for-byte as canonical JSON.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const diff = @import("root.zig");
const similar = diff.similar;

const patches_txt = @embedFile("testdata/patches.txt");
const patches_jsonl = @embedFile("testdata/patches.jsonl");
const pairs_txt = @embedFile("testdata/pairs.txt");
const pairs_jsonl = @embedFile("testdata/pairs.jsonl");

const Out = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,

    fn raw(self: *Out, s: []const u8) !void {
        try self.buf.appendSlice(self.a, s);
    }
    fn print(self: *Out, comptime f: []const u8, args: anytype) !void {
        try self.buf.print(self.a, f, args);
    }
    fn str(self: *Out, s: []const u8) !void {
        try self.buf.append(self.a, '"');
        for (s) |c| switch (c) {
            '"' => try self.raw("\\\""),
            '\\' => try self.raw("\\\\"),
            '\n' => try self.raw("\\n"),
            '\r' => try self.raw("\\r"),
            '\t' => try self.raw("\\t"),
            0...8, 11, 12, 14...0x1f => try self.print("\\u{x:0>4}", .{c}),
            else => try self.buf.append(self.a, c),
        };
        try self.buf.append(self.a, '"');
    }
    fn optNum(self: *Out, v: anytype) !void {
        if (v) |x| try self.print("{d}", .{x}) else try self.raw("null");
    }
    fn strs(self: *Out, v: []const []const u8) !void {
        try self.raw("[");
        for (v, 0..) |s, i| {
            if (i > 0) try self.raw(",");
            try self.str(s);
        }
        try self.raw("]");
    }
};

fn writeFile(o: *Out, f: diff.FileDiff) !void {
    try o.raw("{\"path\":");
    try o.str(f.path);
    try o.raw(",\"old_path\":");
    if (f.old_path) |p| try o.str(p) else try o.raw("null");
    try o.print(",\"status\":\"{s}\",\"binary\":{},\"notices\":", .{ @tagName(f.status), f.binary });
    try o.strs(f.notices);
    try o.raw(",\"hunks\":[");
    for (f.hunks, 0..) |h, i| {
        if (i > 0) try o.raw(",");
        try o.raw("{\"header\":");
        try o.str(h.header);
        try o.raw(",\"lines\":[");
        for (h.lines, 0..) |l, j| {
            if (j > 0) try o.raw(",");
            try o.print("[\"{s}\",", .{@tagName(l.kind)});
            try o.optNum(l.old_no);
            try o.raw(",");
            try o.optNum(l.new_no);
            try o.raw(",");
            try o.str(l.text);
            try o.raw("]");
        }
        try o.raw("]}");
    }
    try o.print("],\"additions\":{d},\"deletions\":{d},\"max_line\":{d}}}", .{ f.additions, f.deletions, f.max_line });
}

fn writePairs(o: *Out, ps: []const diff.LinePair) !void {
    try o.raw("[");
    for (ps, 0..) |p, i| {
        if (i > 0) try o.raw(",");
        try o.raw("[");
        try o.optNum(p.left);
        try o.raw(",");
        try o.optNum(p.right);
        try o.raw("]");
    }
    try o.raw("]");
}

fn writeOps(o: *Out, ops: []const similar.DiffOp) !void {
    try o.raw("[");
    for (ops, 0..) |op, i| {
        if (i > 0) try o.raw(",");
        switch (op) {
            .equal => |e| try o.print("[\"E\",{d},{d},{d}]", .{ e.old_index, e.new_index, e.len }),
            .delete => |d| try o.print("[\"D\",{d},{d},{d}]", .{ d.old_index, d.old_len, d.new_index }),
            .insert => |n| try o.print("[\"I\",{d},{d},{d}]", .{ n.old_index, n.new_index, n.new_len }),
            .replace => |r| try o.print("[\"R\",{d},{d},{d},{d}]", .{ r.old_index, r.old_len, r.new_index, r.new_len }),
        }
    }
    try o.raw("]");
}

fn readDocs(a: Allocator, bytes: []const u8) ![]const []const u8 {
    var docs: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (at < bytes.len) {
        const nl = at + std.mem.indexOfScalar(u8, bytes[at..], '\n').?;
        const len = try std.fmt.parseInt(usize, bytes[at..nl], 10);
        const start = nl + 1;
        try docs.append(a, bytes[start .. start + len]);
        at = start + len + 1;
    }
    return docs.items;
}

fn lines(a: Allocator, bytes: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |l| try out.append(a, l);
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
    return out.items;
}

fn report(kind: []const u8, i: usize, want: []const u8, got: []const u8) void {
    var p: usize = 0;
    while (p < want.len and p < got.len and want[p] == got[p]) p += 1;
    const lo = p -| 100;
    std.debug.print("\n[{s}] #{d} mismatch at byte {d}\n  want: …{s}\n  got:  …{s}\n", .{
        kind, i, p, want[lo..@min(want.len, p + 140)], got[lo..@min(got.len, p + 140)],
    });
}

test "parity: parse_patch, file_notices, split_pairs, truncate_file_lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = try readDocs(a, patches_txt);
    const want = try lines(a, patches_jsonl);
    try testing.expectEqual(docs.len, want.len);
    var failures: usize = 0;
    for (docs, want, 0..) |doc, w, i| {
        var set = try diff.parsePatch(testing.allocator, doc);
        defer set.deinit();
        const sa = set.arena.allocator();
        var o: Out = .{ .a = testing.allocator };
        defer o.buf.deinit(testing.allocator);
        try o.raw("[");
        for (set.files, 0..) |f, fi| {
            if (fi > 0) try o.raw(",");
            try o.raw("{\"file\":");
            try writeFile(&o, f);
            try o.raw(",\"notices\":");
            try o.strs(try diff.fileNotices(sa, f));
            try o.raw(",\"pairs\":[");
            for (f.hunks, 0..) |h, j| {
                if (j > 0) try o.raw(",");
                try writePairs(&o, try diff.splitPairs(sa, h.lines));
            }
            try o.raw("],\"pairs3\":[");
            for (f.hunks, 0..) |h, j| {
                if (j > 0) try o.raw(",");
                try writePairs(&o, try diff.splitPairsUpto(sa, h.lines, 3));
            }
            try o.raw("],\"truncated\":");
            var t = f;
            try diff.truncateFileLines(sa, &t, 5);
            try writeFile(&o, t);
            try o.raw("}");
        }
        try o.raw("]");
        if (!std.mem.eql(u8, o.buf.items, w)) {
            failures += 1;
            if (failures <= 5) report("patch", i, w, o.buf.items);
        }
    }
    if (failures > 0) {
        std.debug.print("patches: {d}/{d} differ\n", .{ failures, docs.len });
        return error.TestExpectedEqual;
    }
}

test "parity: similar line/word/char diffs, grouping, inline changes, diff_to_file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = try readDocs(a, pairs_txt);
    const want = try lines(a, pairs_jsonl);
    try testing.expectEqual(docs.len / 2, want.len);
    var failures: usize = 0;
    for (want, 0..) |w, i| {
        const old_raw = docs[2 * i];
        const new = docs[2 * i + 1];
        const old_opt: ?[]const u8 = if (std.mem.eql(u8, old_raw, "\x00")) null else old_raw;
        const old = old_opt orelse "";

        var tmp = std.heap.ArenaAllocator.init(testing.allocator);
        defer tmp.deinit();
        const ta = tmp.allocator();
        var o: Out = .{ .a = ta };

        var ld = try similar.TextDiff.fromLines(testing.allocator, old, new);
        defer ld.deinit();
        try o.raw("{\"lines\":");
        try writeOps(&o, ld.ops);
        try o.raw(",\"grouped\":[");
        for (try similar.groupDiffOps(ta, ld.ops, 3), 0..) |g, gi| {
            if (gi > 0) try o.raw(",");
            try writeOps(&o, g);
        }
        try o.raw("],\"changes\":[");
        var changes: std.ArrayList(similar.Change) = .empty;
        for (ld.ops) |op| try ld.iterChanges(ta, op, &changes);
        for (changes.items, 0..) |c, ci| {
            if (ci > 0) try o.raw(",");
            try o.print("[\"{s}\",", .{@tagName(c.tag)});
            try o.optNum(c.old_index);
            try o.raw(",");
            try o.optNum(c.new_index);
            try o.raw(",");
            try o.str(c.value);
            try o.raw("]");
        }
        try o.raw("],\"inline\":[");
        var inl: std.ArrayList(similar.InlineChange) = .empty;
        for (ld.ops) |op| try ld.iterInlineChanges(ta, op, &inl);
        for (inl.items, 0..) |c, ci| {
            if (ci > 0) try o.raw(",");
            try o.print("[\"{s}\",", .{@tagName(c.tag)});
            try o.optNum(c.old_index);
            try o.raw(",");
            try o.optNum(c.new_index);
            try o.raw(",[");
            for (c.values, 0..) |v, vi| {
                if (vi > 0) try o.raw(",");
                try o.print("[{},", .{v.emphasized});
                try o.str(v.value);
                try o.raw("]");
            }
            try o.raw("]]");
        }
        try o.raw("],\"words\":");
        var wd = try similar.TextDiff.fromWords(testing.allocator, old, new);
        defer wd.deinit();
        try writeOps(&o, wd.ops);
        try o.raw(",\"chars\":");
        if (old.len + new.len <= 6000) {
            var cd = try similar.TextDiff.fromChars(testing.allocator, old, new);
            defer cd.deinit();
            try writeOps(&o, cd.ops);
        } else try o.raw("null");
        try o.raw(",\"file\":");
        var fs = try diff.diffToFile(testing.allocator, "dir/file.rs", old_opt, new);
        defer fs.deinit();
        try writeFile(&o, fs.files[0]);
        try o.raw("}");

        if (!std.mem.eql(u8, o.buf.items, w)) {
            failures += 1;
            if (failures <= 5) report("pairs", i, w, o.buf.items);
        }
    }
    if (failures > 0) {
        std.debug.print("pairs: {d}/{d} differ\n", .{ failures, want.len });
        return error.TestExpectedEqual;
    }
}
