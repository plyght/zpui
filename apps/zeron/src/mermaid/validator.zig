//! Preflight validation (mermaid-rs-renderer `validator.rs`). On failure the
//! returned message is the crate's `ParseError` display string.

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util.zig");
const json5 = @import("json5.zig");

pub fn validate(a: Allocator, input: []const u8) Allocator.Error!?[]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = util.lines(input);
    while (it.next()) |l| try list.append(a, l);
    const lines = list.items;
    if (try checkInitDirective(a, lines)) |e| return e;
    if (try checkSubgraphBalance(a, lines)) |e| return e;
    if (try checkLeadingArrow(a, lines)) |e| return e;
    if (try checkClickQuotes(a, lines)) |e| return e;
    if (try checkSequenceParticipants(a, lines)) |e| return e;
    return null;
}

fn colOfFirstNonWs(raw: []const u8) usize {
    var i: usize = 0;
    var col: usize = 0;
    while (i < raw.len) {
        const d = util.decodeAt(raw, i);
        if (!util.isWhitespace(d.cp)) return col + 1;
        col += 1;
        i += d.len;
    }
    return 1;
}

fn invalidDirective(a: Allocator, line: usize, col: usize, directive: []const u8, reason: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "invalid directive '{s}' at {d}:{d}: {s}", .{ directive, line, col, reason });
}

fn unexpected(a: Allocator, line: usize, col: usize, found: []const u8, expected: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(a, "unexpected token '{s}' at {d}:{d}; expected {s}", .{ found, line, col, expected });
}

fn checkInitDirective(a: Allocator, lines: []const []const u8) Allocator.Error!?[]const u8 {
    for (lines, 1..) |raw, line_no| {
        const t = util.trimStart(raw);
        const col = colOfFirstNonWs(raw);
        if (!util.startsWith(t, "%%{")) continue;
        const rest = util.trimEnd(t[3..]);
        if (!util.endsWith(rest, "}%%")) return try invalidDirective(a, line_no, col, "unknown", "missing closing '}%%' fence");
        const inside = rest[0 .. rest.len - 3];
        const colon = std.mem.indexOfScalar(u8, inside, ':') orelse
            return try invalidDirective(a, line_no, col, "unknown", "missing ':' between directive name and body");
        const name = util.trim(inside[0..colon]);
        const body = util.trim(inside[colon + 1 ..]);
        if (!util.eql(name, "init")) continue;
        if (body.len == 0) return try invalidDirective(a, line_no, col, name, "empty body");
        if (!json5.isValid(a, body)) return try invalidDirective(a, line_no, col, name, "JSON parse error");
    }
    return null;
}

const BalanceKind = enum { flowchart, sequence, block, other };

fn detectBalanceKind(a: Allocator, lines: []const []const u8) Allocator.Error!BalanceKind {
    var in_fm = false;
    var seen_any = false;
    for (lines) |raw| {
        const t = util.trim(raw);
        if (t.len == 0 or util.startsWith(t, "%%")) continue;
        if (util.eql(t, "---")) {
            if (!seen_any) {
                in_fm = true;
                seen_any = true;
                continue;
            }
            if (in_fm) {
                in_fm = false;
                continue;
            }
        }
        seen_any = true;
        if (in_fm) continue;
        const lower = try util.lowerAscii(a, t);
        if (util.startsWith(lower, "flowchart") or util.startsWith(lower, "graph")) return .flowchart;
        if (util.startsWith(lower, "sequencediagram")) return .sequence;
        if (util.startsWith(lower, "block-beta") or util.eql(lower, "block") or util.startsWith(lower, "block ")) return .block;
        return .other;
    }
    return .other;
}

fn kwOpen(lower: []const u8, kw: []const u8) bool {
    if (util.eql(lower, kw)) return true;
    return util.startsWith(lower, kw) and lower.len > kw.len and (lower[kw.len] == ' ' or lower[kw.len] == '\t');
}

fn checkSubgraphBalance(a: Allocator, lines: []const []const u8) Allocator.Error!?[]const u8 {
    const kind = try detectBalanceKind(a, lines);
    const expected = switch (kind) {
        .flowchart => "matching subgraph",
        .sequence => "matching alt/opt/loop/par/rect/critical/break/box",
        .block => "matching block group",
        .other => return null,
    };
    var stack: std.ArrayList(usize) = .empty;
    for (lines, 1..) |raw, line_no| {
        const t = util.trim(raw);
        if (t.len == 0 or util.startsWith(t, "%%")) continue;
        const lower = try util.lowerAscii(a, t);
        const opens = switch (kind) {
            .flowchart => kwOpen(lower, "subgraph"),
            .sequence => blk: {
                for ([_][]const u8{ "alt", "opt", "loop", "par", "rect", "critical", "break", "box" }) |kw| {
                    if (kwOpen(lower, kw)) break :blk true;
                }
                break :blk false;
            },
            .block => util.startsWith(lower, "block:"),
            .other => false,
        };
        const closes = util.eql(lower, "end") or util.startsWith(lower, "end ") or util.startsWith(lower, "end\t") or util.startsWith(lower, "end%%");
        if (opens) {
            try stack.append(a, line_no);
        } else if (closes and stack.pop() == null) {
            return try unexpected(a, line_no, colOfFirstNonWs(raw), "end", expected);
        }
    }
    if (stack.items.len > 0) return try std.fmt.allocPrint(a, "unclosed subgraph opened at line {d}", .{stack.items[0]});
    return null;
}

fn startsWithArrow(t: []const u8) bool {
    if (t.len == 0) return false;
    switch (t[0]) {
        '-', '=', '~', '.', '<' => {
            var any = false;
            for (t) |b| {
                switch (b) {
                    '-', '=', '~', '.', '<', '>', 'o', 'x' => {},
                    else => break,
                }
                if (b == '>' or b == '<' or b == '-' or b == '=') any = true;
            }
            if (!any) return false;
            for (t[0..@min(16, t.len)]) |b| if (b == '>' or b == '<') return true;
            return false;
        },
        else => return false,
    }
}

fn checkLeadingArrow(a: Allocator, lines: []const []const u8) Allocator.Error!?[]const u8 {
    for (lines, 1..) |raw, line_no| {
        const t = util.trimStart(raw);
        if (t.len == 0 or util.startsWith(t, "%%")) continue;
        if (startsWithArrow(t)) {
            var it = util.splitWhitespace(t);
            return try unexpected(a, line_no, colOfFirstNonWs(raw), it.next() orelse "", "node identifier");
        }
    }
    return null;
}

fn checkClickQuotes(a: Allocator, lines: []const []const u8) Allocator.Error!?[]const u8 {
    for (lines, 1..) |raw, line_no| {
        const t = util.trimStart(raw);
        if (!util.startsWith(t, "click ") and !util.startsWith(t, "click\t")) continue;
        if (std.mem.count(u8, t, "\"") % 2 == 1) {
            const lead = raw.len - t.len;
            const q = std.mem.indexOfScalar(u8, t, '"') orelse 0;
            const col = util.charCount(raw[0 .. lead + q]) + 1;
            return try unexpected(a, line_no, col, "\"", "matching double quote");
        }
    }
    return null;
}

fn checkSequenceParticipants(a: Allocator, lines: []const []const u8) Allocator.Error!?[]const u8 {
    var is_seq = false;
    for (lines) |raw| {
        const t = util.trim(raw);
        if (t.len == 0 or util.startsWith(t, "%%")) continue;
        is_seq = util.startsWith(try util.lowerAscii(a, t), "sequencediagram");
        break;
    }
    if (!is_seq) return null;
    var declared: std.ArrayList([]const u8) = .empty;
    for (lines) |raw| {
        const t = util.trim(raw);
        const rest_raw = if (util.startsWith(t, "participant ")) t["participant ".len..] else if (util.startsWith(t, "actor ")) t["actor ".len..] else continue;
        const rest = util.trim(rest_raw);
        if (util.find(rest, " as ")) |i| {
            const name = util.trim(rest[0..i]);
            const alias = util.trim(rest[i + 4 ..]);
            if (name.len > 0) try declared.append(a, name);
            if (alias.len > 0) try declared.append(a, alias);
        } else if (rest.len > 0) try declared.append(a, rest);
    }
    if (declared.items.len == 0) return null;
    for (lines, 1..) |raw, line_no| {
        const t = util.trim(raw);
        if (t.len == 0 or util.startsWith(t, "%%")) continue;
        const before = if (std.mem.indexOfScalar(u8, t, ':')) |i| t[0..i] else t;
        for ([_][]const u8{ "-->>", "--x", "--)", "-->", "->>", "->", "-x", "-)" }) |pat| {
            const i = util.find(before, pat) orelse continue;
            for ([_][]const u8{ util.trim(before[0..i]), util.trim(before[i + pat.len ..]) }) |name| {
                if (name.len == 0) continue;
                var found = false;
                for (declared.items) |d| found = found or util.eql(d, name);
                if (!found) return try std.fmt.allocPrint(a, "unknown participant '{s}' at line {d}", .{ name, line_no });
            }
            break;
        }
    }
    return null;
}

test "validator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try validate(a, "flowchart TD\nA-->B")) == null);
    try std.testing.expectEqualStrings("unclosed subgraph opened at line 2", (try validate(a, "flowchart TD\nsubgraph X\nA-->B")).?);
    try std.testing.expectEqualStrings("unexpected token '-->' at 2:1; expected node identifier", (try validate(a, "flowchart TD\n--> B")).?);
}
