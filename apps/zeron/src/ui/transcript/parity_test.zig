//! Parity with zeron for the compact-mode row split (`rows_for_entry(..,
//! compact = true, ..)`), the streaming veil (`markdown/veil.rs`) and the
//! message-badge split (`badges::split`), over the corpus dumped by
//! apps/zeron/scripts/transcript_parity.rs (testdata/transcript_parity.json).

const std = @import("std");
const engine = @import("zeron_engine");
const md = @import("zeron_ui_markdown");
const rows = @import("rows.zig");
const badges = @import("badges.zig");

const testing = std.testing;
const veil = md.veil;
const data = @embedFile("testdata/transcript_parity.json");

const RowCase = struct {
    id: []const u8,
    kind: []const u8,
    fold: ?[]const u8 = null,
    turn_start: bool,
    timestamp: bool,
    summary: ?[]const u8 = null,
    auto_open: ?bool = null,
    worked_secs: ?i64 = null,
    shell: ?bool = null,
    tools: ?[]const []const u8 = null,
};

const Step = struct { elem: usize, ms: u64, text: []const u8, spans: []const [3]f64, fading: bool };
const VeilCase = struct { seeded: bool, steps: []const Step };
const Detail = struct { []const u8, ?[]const u8, []const u8 };
const BadgeOut = struct { label: []const u8, details: []const Detail };
const BadgeCase = struct { text: []const u8, rest: []const u8, badges: []const BadgeOut };

const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

fn root(a: std.mem.Allocator) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, data, opts);
}

test "compact row split matches zeron" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try root(a);
    for (r.object.get("rows").?.array.items, 0..) |case, ci| {
        const entry = try std.json.parseFromValueLeaky(engine.protocol.SessionMessageEntry, a, case.object.get("entry").?, opts);
        const want = try std.json.parseFromValueLeaky([]const RowCase, a, case.object.get("rows").?, opts);
        var parsers = rows.Parsers.init(testing.allocator);
        defer parsers.deinit();
        var er = try rows.buildEntryRows(testing.allocator, &parsers, &entry, .{ .compact = true }, 1);
        defer er.deinit(testing.allocator);
        errdefer std.debug.print("case {d} ({s})\n", .{ ci, entry.id });
        try testing.expectEqual(want.len, er.rows.len);
        for (want, er.rows) |w, g| {
            try testing.expectEqualStrings(w.id, g.id);
            try testing.expectEqualStrings(w.kind, @tagName(g.kind));
            if (w.fold) |f| try testing.expectEqualStrings(f, g.compact_fold.?) else try testing.expect(g.compact_fold == null);
            try testing.expectEqual(w.turn_start, g.turn_start);
            try testing.expectEqual(w.timestamp, g.timestamp != null);
            if (g.kind == .tool_group) {
                const tg = g.kind.tool_group;
                try testing.expectEqualStrings(w.summary.?, tg.summary);
                try testing.expectEqual(w.auto_open.?, tg.auto_open);
                try testing.expectEqual(w.worked_secs, tg.worked_secs);
                try testing.expectEqual(w.shell.?, tg.compact_shell);
                try testing.expectEqual(w.tools.?.len, tg.tools.len);
                for (w.tools.?, tg.tools) |wk, t| try testing.expectEqualStrings(wk, @tagName(t.kind));
            }
        }
    }
}

test "streaming veil matches zeron" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try root(a);
    const cases = try std.json.parseFromValueLeaky([]const VeilCase, a, r.object.get("veils").?, opts);
    const t0: u64 = 10 * std.time.ns_per_s;
    for (cases) |c| {
        var row: veil.RowVeil = if (c.seeded) .seeded(testing.allocator) else .init(testing.allocator);
        defer row.deinit();
        for (c.steps, 0..) |s, si| {
            const spans = row.advance(s.elem, s.text, t0 + s.ms * std.time.ns_per_ms);
            if (si == 0 and c.seeded) row.finishSeeding();
            try testing.expectEqual(s.spans.len, spans.len);
            for (s.spans, spans) |w, g| {
                try testing.expectEqual(@as(usize, @intFromFloat(w[0])), g.range.start);
                try testing.expectEqual(@as(usize, @intFromFloat(w[1])), g.range.end);
                try testing.expectApproxEqAbs(@as(f32, @floatCast(w[2])), g.alpha, 1e-4);
            }
            try testing.expectEqual(s.fading, row.isFading());
        }
    }
}

test "badge split matches zeron" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try root(a);
    const cases = try std.json.parseFromValueLeaky([]const BadgeCase, a, r.object.get("badges").?, opts);
    for (cases) |c| {
        const s = try badges.split(a, c.text);
        try testing.expectEqualStrings(c.rest, s.text);
        try testing.expectEqual(c.badges.len, s.badges.len);
        for (c.badges, s.badges) |w, g| {
            try testing.expectEqualStrings(w.label, g.label);
            try testing.expectEqual(w.details.len, g.details.len);
            for (w.details, g.details) |wd, gd| {
                try testing.expectEqualStrings(wd[0], gd.location);
                if (wd[1]) |t| try testing.expectEqualStrings(t, gd.tag.?) else try testing.expect(gd.tag == null);
                try testing.expectEqualStrings(wd[2], gd.body);
            }
        }
    }
}
