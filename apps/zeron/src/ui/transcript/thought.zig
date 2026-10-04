//! Reasoning ("Thought process") flattening — port of zeron transcript.rs
//! `thought_lines` / `wrap_styled_runs` / `thought_block_lines`: a thought's
//! parsed markdown becomes word-wrapped STYLED lines (96 cols), one fixed
//! 18px row each, so the chip detail height stays analytic.

const std = @import("std");
const Allocator = std.mem.Allocator;
const mdm = @import("zeron_markdown");

const Block = mdm.Block;
const InlineRun = mdm.InlineRun;
const InlineStyle = mdm.InlineStyle;

pub const wrap_cols: usize = 96;

pub const Line = []InlineRun;

const LineBuf = std.ArrayList(InlineRun);

const Ctx = struct {
    a: Allocator,
    out: *std.ArrayList(Line),
};

/// All lines of a tree (blank separator rows between top-level blocks,
/// trailing blank rows trimmed). Everything is allocated in `a`.
pub fn thoughtLines(a: Allocator, tree: mdm.BlockTree) Allocator.Error![]Line {
    var out: std.ArrayList(Line) = .empty;
    const c: Ctx = .{ .a = a, .out = &out };
    for (tree.blocks) |top| {
        if (out.items.len > 0) try out.append(a, &.{});
        try blockLines(c, top.block, 0);
    }
    while (out.items.len > 0 and isBlank(out.items[out.items.len - 1])) _ = out.pop();
    return out.items;
}

pub fn isBlank(line: []const InlineRun) bool {
    for (line) |r| if (std.mem.trim(u8, r.text, " \t\r\n").len > 0) return false;
    return true;
}

fn indentRun(a: Allocator, indent: usize) Allocator.Error!InlineRun {
    const t = try a.alloc(u8, indent);
    @memset(t, ' ');
    return .{ .text = t };
}

fn pushStyled(a: Allocator, line: *LineBuf, text: []const u8, style: InlineStyle) Allocator.Error!void {
    if (text.len == 0) return;
    if (line.items.len > 0 and line.items[line.items.len - 1].style.eql(style)) {
        const last = &line.items[line.items.len - 1];
        last.text = try std.mem.concat(a, u8, &.{ last.text, text });
    } else try line.append(a, .{ .text = try a.dupe(u8, text), .style = style });
}

fn finishLine(c: Ctx, indent: usize, line: *LineBuf) Allocator.Error!void {
    var full: LineBuf = .empty;
    try full.append(c.a, try indentRun(c.a, indent));
    try full.appendSlice(c.a, line.items);
    line.* = .empty;
    try c.out.append(c.a, full.items);
}

fn charCount(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn isWs(b: u8) bool {
    return b == ' ' or b == '\t' or b == '\r';
}

fn wrapStyledRuns(c: Ctx, runs: []const InlineRun, indent: usize) Allocator.Error!void {
    const a = c.a;
    const budget = @max(wrap_cols -| indent, 16);
    // Split into hard-break segments.
    var segments: std.ArrayList(LineBuf) = .empty;
    try segments.append(a, .empty);
    for (runs) |run| {
        var it = std.mem.splitScalar(u8, run.text, '\n');
        var ix: usize = 0;
        while (it.next()) |piece| : (ix += 1) {
            if (ix > 0) try segments.append(a, .empty);
            if (piece.len > 0) try segments.items[segments.items.len - 1].append(a, .{ .text = piece, .style = run.style });
        }
    }
    for (segments.items) |segment| {
        // Tokens: maximal non-whitespace piece lists, glued across runs.
        var tokens: std.ArrayList(LineBuf) = .empty;
        var in_token = false;
        for (segment.items) |run| {
            const text = run.text;
            var pos: usize = 0;
            while (pos < text.len) {
                const ws = isWs(text[pos]);
                var end = pos;
                while (end < text.len and isWs(text[end]) == ws) end += 1;
                if (ws) in_token = false else {
                    if (!in_token) {
                        try tokens.append(a, .empty);
                        in_token = true;
                    }
                    try pushStyled(a, &tokens.items[tokens.items.len - 1], text[pos..end], run.style);
                }
                pos = end;
            }
        }
        var line: LineBuf = .empty;
        var len: usize = 0;
        for (tokens.items) |token| {
            var tok_len: usize = 0;
            for (token.items) |r| tok_len += charCount(r.text);
            if (tok_len > budget) {
                if (len > 0) {
                    try finishLine(c, indent, &line);
                    len = 0;
                }
                for (token.items) |piece| {
                    var view = std.unicode.Utf8View.initUnchecked(piece.text).iterator();
                    while (true) {
                        const start = view.i;
                        var n: usize = 0;
                        while (n < budget - len) : (n += 1) if (view.nextCodepointSlice() == null) break;
                        const chunk = piece.text[start..view.i];
                        if (chunk.len == 0) break;
                        len += n;
                        try pushStyled(a, &line, chunk, piece.style);
                        if (len == budget) {
                            try finishLine(c, indent, &line);
                            len = 0;
                        }
                    }
                }
                continue;
            }
            if (len > 0 and len + 1 + tok_len > budget) {
                try finishLine(c, indent, &line);
                len = 0;
            }
            if (len > 0) {
                const last = &line.items[line.items.len - 1];
                last.text = try std.mem.concat(a, u8, &.{ last.text, " " });
                len += 1;
            }
            for (token.items) |piece| try pushStyled(a, &line, piece.text, piece.style);
            len += tok_len;
        }
        if (len > 0) try finishLine(c, indent, &line);
    }
}

fn blockLines(c: Ctx, block: Block, indent: usize) Allocator.Error!void {
    const a = c.a;
    switch (block) {
        .paragraph => |runs| try wrapStyledRuns(c, runs, indent),
        .heading => |h| {
            const bold = try a.alloc(InlineRun, h.runs.len);
            for (h.runs, bold) |r, *o| {
                o.* = r;
                o.style.bold = true;
            }
            try wrapStyledRuns(c, bold, indent);
        },
        .code_block => |cb| {
            const style: InlineStyle = .{ .code = true };
            const budget = @max(wrap_cols -| indent, 16);
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, cb.code, "\n"), '\n');
            while (it.next()) |line| {
                var rest = line;
                while (true) {
                    var view = std.unicode.Utf8View.initUnchecked(rest).iterator();
                    var n: usize = 0;
                    while (n < budget) : (n += 1) if (view.nextCodepointSlice() == null) break;
                    const chunk = rest[0..view.i];
                    var row: LineBuf = .empty;
                    try row.append(a, try indentRun(a, indent));
                    if (chunk.len > 0) try row.append(a, .{ .text = try a.dupe(u8, chunk), .style = style });
                    try c.out.append(a, row.items);
                    rest = rest[view.i..];
                    if (rest.len == 0) break;
                }
            }
        },
        .list => |l| {
            for (l.items, 0..) |item, ix| {
                const marker = if (l.ordered_start) |s| try std.fmt.allocPrint(a, "{d}. ", .{s + ix}) else "• ";
                const inner = indent + charCount(marker);
                const mark = c.out.items.len;
                for (item) |child| try blockLines(c, child, inner);
                if (c.out.items.len == mark) {
                    const row = try a.alloc(InlineRun, 1);
                    row[0] = try indentRun(a, inner);
                    try c.out.append(a, row);
                }
                const first = c.out.items[mark];
                if (first.len > 0) {
                    const sp = try a.alloc(u8, indent);
                    @memset(sp, ' ');
                    first[0].text = try std.mem.concat(a, u8, &.{ sp, marker });
                }
            }
        },
        .block_quote => |children| {
            const mark = c.out.items.len;
            for (children, 0..) |child, ix| {
                if (ix > 0) try c.out.append(a, &.{});
                try blockLines(c, child, indent + 2);
            }
            for (c.out.items[mark..]) |line| {
                if (line.len > 0 and line[0].text.len >= indent + 2) {
                    const t = line[0].text;
                    line[0].text = try std.mem.concat(a, u8, &.{ t[0..indent], "│ ", t[indent + 2 ..] });
                }
            }
        },
        .table => |t| {
            try wrapStyledRuns(c, try joinCells(a, t.header, true), indent);
            for (t.rows) |row| try wrapStyledRuns(c, try joinCells(a, row, false), indent);
        },
        .rule => {
            const row = try a.alloc(InlineRun, 2);
            row[0] = try indentRun(a, indent);
            row[1] = .{ .text = "———" };
            try c.out.append(a, row);
        },
    }
}

fn joinCells(a: Allocator, cells: []const []const InlineRun, bold: bool) Allocator.Error![]InlineRun {
    var line: LineBuf = .empty;
    for (cells, 0..) |cell, ix| {
        if (ix > 0) try pushStyled(a, &line, " · ", .{});
        for (cell) |r| {
            var rr = r;
            rr.style.bold = rr.style.bold or bold;
            try line.append(a, rr);
        }
    }
    return line.items;
}

test "thought lines wrap and style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tree = try mdm.parseFull(std.testing.allocator, "**Planning** the change.\n\n- one\n- two");
    defer tree.deinit(std.testing.allocator);
    const lines = try thoughtLines(arena.allocator(), tree);
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expect(lines[0][1].style.bold);
    try std.testing.expectEqualStrings("• ", lines[2][0].text);
}
