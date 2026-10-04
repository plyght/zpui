//! Compact transcript mode — port of zeron transcript.rs's `compact_mode_*`
//! row tests (`rows_for_entry(.., compact = true, ..)`) plus the fold
//! geometry helpers.

const std = @import("std");
const engine = @import("zeron_engine");
const rows = @import("rows.zig");
const view = @import("view.zig");

const protocol = engine.protocol;
const MessagePart = protocol.MessagePart;
const SessionMessageEntry = protocol.SessionMessageEntry;
const Row = rows.Row;
const testing = std.testing;

fn textPart(id: []const u8, text: []const u8) MessagePart {
    return .{ .text = .{ .id = id, .text = text } };
}
fn toolPart(id: []const u8, cmd: []const u8) MessagePart {
    return .{ .tool = .{ .id = id, .call = .{ .exec = .{ .command = cmd } }, .resolved = true, .output = "ok\n" } };
}
fn reasoningPart(id: []const u8, text: []const u8) MessagePart {
    return .{ .reasoning = .{ .id = id, .text = text } };
}

const Built = struct {
    parsers: rows.Parsers,
    er: rows.EntryRows,

    fn deinit(self: *Built) void {
        self.er.deinit(testing.allocator);
        self.parsers.deinit();
    }

    fn visible(self: *const Built, buf: []*const Row) []*const Row {
        var n: usize = 0;
        for (self.er.rows) |*r| if (r.compact_fold == null) {
            buf[n] = r;
            n += 1;
        };
        return buf[0..n];
    }

    fn anyFolded(self: *const Built, comptime tag: std.meta.Tag(rows.RowKind), shell: ?bool) bool {
        for (self.er.rows) |r| if (r.compact_fold != null and r.kind == tag) {
            if (shell) |s| if (r.kind == .tool_group and r.kind.tool_group.compact_shell != s) continue;
            return true;
        };
        return false;
    }
};

fn build(parts: []MessagePart, status: protocol.MessageStatus, duration_ms: ?i64) !Built {
    var b: Built = .{ .parsers = .init(testing.allocator), .er = undefined };
    errdefer b.parsers.deinit();
    const entry: SessionMessageEntry = .{ .id = "a1", .role = .assistant, .parts = parts, .createdAt = 0, .deviceId = "d", .status = status, .durationMs = duration_ms };
    b.er = try rows.buildEntryRows(testing.allocator, &b.parsers, &entry, .{ .compact = true }, 1);
    return b;
}

test "compact mode folds the whole turn into one collapsed group" {
    var parts = [_]MessagePart{
        reasoningPart("r0", "thinking about it"),
        toolPart("t1", "ls"),
        textPart("n1", "checking the layout now"),
        toolPart("t2", "pwd"),
        textPart("r1", "All done \u{2014} here is the answer."),
    };
    var b = try build(&parts, .complete, null);
    defer b.deinit();
    var buf: [16]*const Row = undefined;
    const vis = b.visible(&buf);
    try testing.expectEqual(@as(usize, 2), vis.len);
    const g = vis[0].kind.tool_group;
    try testing.expect(g.compact_shell);
    try testing.expect(!g.auto_open);
    try testing.expectEqualStrings("a1#work", vis[0].id);
    try testing.expectEqual(@as(usize, 4), g.tools.len);
    try testing.expectEqual(rows.ToolItemKind.thought, g.tools[0].kind);
    try testing.expectEqual(rows.ToolItemKind.call, g.tools[1].kind);
    try testing.expectEqual(rows.ToolItemKind.note, g.tools[2].kind);
    try testing.expectEqual(rows.ToolItemKind.call, g.tools[3].kind);
    try testing.expect(vis[1].kind == .markdown);
    try testing.expect(std.mem.indexOf(u8, g.summary, "wrote a note") != null);
    try testing.expect(std.mem.indexOf(u8, g.summary, "Ran 2 commands") != null);
    try testing.expect(std.mem.indexOf(u8, g.summary, "Thought process") != null);
    try testing.expect(b.anyFolded(.markdown, null));
    try testing.expect(b.anyFolded(.tool_group, false));
    try testing.expectEqual(@as(?i64, null), g.worked_secs);
    // The body rows sit right after the header and name its fold.
    try testing.expectEqualStrings("a1#work", b.er.rows[1].compact_fold.?);
    try testing.expect(b.er.rows[0].turn_start);
    try testing.expect(b.er.rows[b.er.rows.len - 1].timestamp != null);
}

test "compact mode carries the worked-for duration on the work group" {
    {
        var parts = [_]MessagePart{ toolPart("t0", "ls"), textPart("r0", "done") };
        var b = try build(&parts, .complete, 310_000);
        defer b.deinit();
        try testing.expectEqual(@as(?i64, 310), b.er.rows[0].kind.tool_group.worked_secs);
    }
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("5m 10s", rows.formatElapsed(&buf, 310));
    try testing.expectEqualStrings("1m 35s", rows.formatElapsed(&buf, 95));
    {
        var parts = [_]MessagePart{toolPart("t0", "ls")};
        var b = try build(&parts, .streaming, 310_000);
        defer b.deinit();
        try testing.expectEqual(@as(?i64, null), b.er.rows[0].kind.tool_group.worked_secs);
    }
    {
        var parts = [_]MessagePart{ toolPart("t0", "ls"), textPart("r0", "done") };
        var b = try build(&parts, .complete, 0);
        defer b.deinit();
        try testing.expectEqual(@as(?i64, null), b.er.rows[0].kind.tool_group.worked_secs);
    }
    {
        var parts = [_]MessagePart{ toolPart("t0", "ls"), textPart("r0", "done") };
        var b = try build(&parts, .complete, 400);
        defer b.deinit();
        try testing.expectEqual(@as(?i64, 1), b.er.rows[0].kind.tool_group.worked_secs);
    }
}

test "compact mode keeps reply rows and skips empty groups" {
    {
        var parts = [_]MessagePart{textPart("t0", "just an answer")};
        var b = try build(&parts, .complete, null);
        defer b.deinit();
        try testing.expectEqual(@as(usize, 1), b.er.rows.len);
        try testing.expect(b.er.rows[0].kind == .markdown);
    }
    var parts = [_]MessagePart{ toolPart("t0", "ls"), textPart("r0", "first half"), textPart("r1", "second half") };
    var b = try build(&parts, .complete, null);
    defer b.deinit();
    var buf: [16]*const Row = undefined;
    const vis = b.visible(&buf);
    try testing.expectEqual(@as(usize, 3), vis.len);
    try testing.expect(vis[0].kind == .tool_group);
    try testing.expect(vis[1].kind == .markdown);
    try testing.expect(vis[2].kind == .markdown);
    try testing.expect(b.anyFolded(.tool_group, false));
}

test "compact mode stays collapsed while streaming" {
    var parts = [_]MessagePart{ reasoningPart("r0", "thinking"), toolPart("t1", "ls"), textPart("r1", "streaming the answer") };
    {
        var b = try build(&parts, .streaming, null);
        defer b.deinit();
        var buf: [16]*const Row = undefined;
        const vis = b.visible(&buf);
        try testing.expectEqual(@as(usize, 1), vis.len);
        const g = vis[0].kind.tool_group;
        try testing.expect(!g.auto_open);
        try testing.expectEqual(@as(usize, 3), g.tools.len);
        try testing.expectEqual(rows.ToolItemKind.note, g.tools[2].kind);
        try testing.expect(b.anyFolded(.markdown, null));
    }
    var b = try build(&parts, .complete, null);
    defer b.deinit();
    var buf: [16]*const Row = undefined;
    const vis = b.visible(&buf);
    try testing.expectEqual(@as(usize, 2), vis.len);
    try testing.expect(vis[0].kind == .tool_group);
    try testing.expect(vis[1].kind == .markdown);
}

test "compact mode keeps input and error chips visible" {
    var parts = [_]MessagePart{
        toolPart("t0", "ls"),
        .{ .@"error" = .{ .id = "e1", .message = "boom" } },
        toolPart("t1", "pwd"),
        textPart("r0", "the answer"),
    };
    var b = try build(&parts, .complete, null);
    defer b.deinit();
    var buf: [16]*const Row = undefined;
    const vis = b.visible(&buf);
    try testing.expectEqual(@as(usize, 3), vis.len);
    try testing.expect(vis[0].kind == .tool_group);
    try testing.expect(vis[1].kind == .error_chip);
    try testing.expect(vis[2].kind == .markdown);
    try testing.expectEqual(@as(usize, 2), vis[0].kind.tool_group.tools.len);
}

test "compact fold geometry reports prefix, own and total" {
    var a: Row = .{ .id = "x", .version = 0, .kind = .{ .error_chip = .{ .message = "" } }, .entry_id = "e", .key = 1 };
    var f1 = a;
    f1.key = 2;
    f1.compact_fold = "e#work";
    var f2 = f1;
    f2.key = 3;
    var f3 = f1;
    f3.key = 4;
    var other = f1;
    other.key = 5;
    other.compact_fold = "other#work";
    const order = [_]*const Row{ &a, &f1, &f2, &f3, &other };
    var heights: std.AutoHashMapUnmanaged(u64, f32) = .empty;
    defer heights.deinit(testing.allocator);
    try heights.put(testing.allocator, 2, 10);
    try heights.put(testing.allocator, 3, 20);
    try heights.put(testing.allocator, 4, 30);
    try heights.put(testing.allocator, 5, 99);
    const g = view.TranscriptView.compactFoldGeometry(&order, &heights, "e#work", 2);
    try testing.expectEqual([3]f32{ 10, 20, 60 }, g);
    // Closed and settled: no budget; mid-tween it lerps from `from`.
    const closed = view.TranscriptView.compactBodyHeight(.{ .open = false }, 60, false, 0);
    try testing.expectEqual(@as(f32, 0), closed);
    const open = view.TranscriptView.compactBodyHeight(.{ .open = true, .toggled_at = 0, .from = 0 }, 60, true, 5);
    try testing.expectEqual(@as(f32, 60), open);
}
