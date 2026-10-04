//! `comments.zig` against `testdata/comments_parity.json`, dumped from zeron's
//! own `comments.rs` (compiled verbatim by `apps/zeron/scripts/comments_parity.rs`):
//! the folded prompt, the badge read back out of it, malformed / quoted
//! trailing blocks, card metrics and chip labels.

const std = @import("std");
const testing = std.testing;
const c = @import("comments.zig");

const Comment = struct {
    path: []const u8,
    line: u32,
    body: []const u8,
    kind: []const u8,
    side: ?[]const u8 = null,
    oldPath: ?[]const u8 = null,
};
const Detail = struct { location: []const u8, tag: ?[]const u8 = null, body: []const u8 };
const Extracted = struct { text: []const u8, label: []const u8, details: []const Detail };
const Case = struct { text: []const u8, comments: []const Comment, prompt: []const u8, extracted: ?Extracted = null };
const Raw = struct { text: []const u8, extracted: ?Extracted = null };
const Metric = struct { body: []const u8, lines: usize, height: f32 };
const Fixture = struct { cases: []const Case, raw: []const Raw, metrics: []const Metric, chips: []const []const u8 };

fn expectExtracted(a: std.mem.Allocator, want: ?Extracted, text: []const u8) !void {
    const got = try c.extractBadge(a, text);
    if (want == null) {
        if (got != null) std.debug.print("unexpected badge for {s}\n", .{text});
        return testing.expect(got == null);
    }
    const w = want.?;
    const g = got orelse {
        std.debug.print("missing badge for {s}\n", .{text});
        return error.TestExpectedEqual;
    };
    try testing.expectEqualStrings(w.text, g.text);
    try testing.expectEqualStrings(w.label, g.badge.label);
    try testing.expectEqual(w.details.len, g.badge.details.len);
    for (w.details, g.badge.details) |wd, gd| {
        try testing.expectEqualStrings(wd.location, gd.location);
        try testing.expectEqualStrings(wd.body, gd.body);
        try testing.expectEqual(wd.tag == null, gd.tag == null);
        if (wd.tag) |t| try testing.expectEqualStrings(t, gd.tag.?);
    }
}

test "comments parity: fold, extract, metrics" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fx = try std.json.parseFromSliceLeaky(Fixture, a, @embedFile("testdata/comments_parity.json"), .{});
    try testing.expect(fx.cases.len >= 200);
    for (fx.cases) |case| {
        const staged = try a.alloc(c.ReviewComment, case.comments.len);
        for (case.comments, staged) |in, *out| {
            out.* = .{
                .id = "id",
                .path = in.path,
                .line = in.line,
                .body = in.body,
                .source = if (std.mem.eql(u8, in.kind, "file")) .file else .{ .diff = .{
                    .side = if (std.mem.eql(u8, in.side.?, "L")) .old else .new,
                    .old_path = in.oldPath,
                } },
            };
        }
        const prompt = try c.withComments(a, case.text, staged);
        try testing.expectEqualStrings(case.prompt, prompt);
        try expectExtracted(a, case.extracted, prompt);
    }
    for (fx.raw) |r| try expectExtracted(a, r.extracted, r.text);
    for (fx.metrics) |m| {
        try testing.expectEqual(m.lines, c.cardBodyLines(m.body));
        try testing.expectEqual(m.height, c.cardHeight(m.body));
    }
    for (fx.chips, [_]usize{ 0, 1, 2, 11 }) |want, n| try testing.expectEqualStrings(want, try c.chipLabel(a, n));
}
