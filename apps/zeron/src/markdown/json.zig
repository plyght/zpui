//! Canonical compact JSON for the markdown model — the format the Rust
//! parity dumper (apps/zeron/scripts/markdown_parity.rs) writes, so fixtures
//! compare as plain strings. Escaping: `"` `\\` `\n` `\r` `\t`, other bytes
//! below 0x20 as `\u00XX`, everything else verbatim.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("model.zig");

pub const Out = struct {
    a: Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn raw(self: *Out, s: []const u8) Allocator.Error!void {
        try self.buf.appendSlice(self.a, s);
    }

    pub fn str(self: *Out, s: []const u8) Allocator.Error!void {
        try self.buf.append(self.a, '"');
        for (s) |c| {
            switch (c) {
                '"' => try self.raw("\\\""),
                '\\' => try self.raw("\\\\"),
                '\n' => try self.raw("\\n"),
                '\r' => try self.raw("\\r"),
                '\t' => try self.raw("\\t"),
                0...8, 11, 12, 14...0x1f => {
                    var b: [6]u8 = undefined;
                    _ = std.fmt.bufPrint(&b, "\\u{x:0>4}", .{c}) catch unreachable;
                    try self.raw(&b);
                },
                else => try self.buf.append(self.a, c),
            }
        }
        try self.buf.append(self.a, '"');
    }

    pub fn optStr(self: *Out, s: ?[]const u8) Allocator.Error!void {
        if (s) |v| try self.str(v) else try self.raw("null");
    }

    pub fn int(self: *Out, v: anytype) Allocator.Error!void {
        var b: [32]u8 = undefined;
        try self.raw(std.fmt.bufPrint(&b, "{d}", .{v}) catch unreachable);
    }

    pub fn boolean(self: *Out, v: bool) Allocator.Error!void {
        try self.raw(if (v) "true" else "false");
    }

    pub fn range(self: *Out, r: model.Range) Allocator.Error!void {
        try self.raw("[");
        try self.int(r.start);
        try self.raw(",");
        try self.int(r.end);
        try self.raw("]");
    }
};

pub fn writeRun(o: *Out, r: model.InlineRun) Allocator.Error!void {
    try o.raw("{\"text\":");
    try o.str(r.text);
    try o.raw(",\"b\":");
    try o.boolean(r.style.bold);
    try o.raw(",\"i\":");
    try o.boolean(r.style.italic);
    try o.raw(",\"c\":");
    try o.boolean(r.style.code);
    try o.raw(",\"s\":");
    try o.boolean(r.style.strikethrough);
    try o.raw(",\"link\":");
    try o.optStr(r.style.link);
    try o.raw(",\"image\":");
    if (r.style.image) |img| {
        try o.raw("{\"source\":");
        try o.str(img.source);
        try o.raw(",\"alt\":");
        try o.str(img.alt);
        try o.raw(",\"title\":");
        try o.str(img.title);
        try o.raw(",\"link\":");
        try o.optStr(img.link);
        try o.raw("}");
    } else try o.raw("null");
    try o.raw(",\"task\":");
    if (r.style.task) |t| {
        try o.raw("{\"checked\":");
        try o.boolean(t.checked);
        try o.raw(",\"range\":");
        try o.range(t.range);
        try o.raw("}");
    } else try o.raw("null");
    try o.raw("}");
}

pub fn writeRuns(o: *Out, runs: []const model.InlineRun) Allocator.Error!void {
    try o.raw("[");
    for (runs, 0..) |r, i| {
        if (i > 0) try o.raw(",");
        try writeRun(o, r);
    }
    try o.raw("]");
}

fn writeCells(o: *Out, cells: []const []const model.InlineRun) Allocator.Error!void {
    try o.raw("[");
    for (cells, 0..) |c, i| {
        if (i > 0) try o.raw(",");
        try writeRuns(o, c);
    }
    try o.raw("]");
}

pub fn writeBlocks(o: *Out, blocks: []const model.Block) Allocator.Error!void {
    try o.raw("[");
    for (blocks, 0..) |b, i| {
        if (i > 0) try o.raw(",");
        try writeBlock(o, b);
    }
    try o.raw("]");
}

pub fn writeBlock(o: *Out, b: model.Block) Allocator.Error!void {
    switch (b) {
        .paragraph => |runs| {
            try o.raw("{\"t\":\"p\",\"runs\":");
            try writeRuns(o, runs);
            try o.raw("}");
        },
        .heading => |h| {
            try o.raw("{\"t\":\"h\",\"level\":");
            try o.int(h.level);
            try o.raw(",\"runs\":");
            try writeRuns(o, h.runs);
            try o.raw("}");
        },
        .code_block => |c| {
            try o.raw("{\"t\":\"code\",\"lang\":");
            try o.optStr(c.language);
            try o.raw(",\"code\":");
            try o.str(c.code);
            try o.raw("}");
        },
        .block_quote => |ch| {
            try o.raw("{\"t\":\"quote\",\"children\":");
            try writeBlocks(o, ch);
            try o.raw("}");
        },
        .list => |l| {
            try o.raw("{\"t\":\"list\",\"start\":");
            if (l.ordered_start) |s| try o.int(s) else try o.raw("null");
            try o.raw(",\"items\":[");
            for (l.items, 0..) |it, i| {
                if (i > 0) try o.raw(",");
                try writeBlocks(o, it);
            }
            try o.raw("]}");
        },
        .table => |t| {
            try o.raw("{\"t\":\"table\",\"header\":");
            try writeCells(o, t.header);
            try o.raw(",\"rows\":[");
            for (t.rows, 0..) |r, i| {
                if (i > 0) try o.raw(",");
                try writeCells(o, r);
            }
            try o.raw("],\"align\":[");
            for (t.alignment, 0..) |al, i| {
                if (i > 0) try o.raw(",");
                try o.str(@tagName(al));
            }
            try o.raw("]}");
        },
        .rule => try o.raw("{\"t\":\"rule\"}"),
    }
}

pub fn writeTree(o: *Out, tree: model.BlockTree) Allocator.Error!void {
    try o.raw("[");
    for (tree.blocks, 0..) |tb, i| {
        if (i > 0) try o.raw(",");
        try o.raw("{\"range\":");
        try o.range(tb.range);
        try o.raw(",\"block\":");
        try writeBlock(o, tb.block);
        try o.raw("}");
    }
    try o.raw("]");
}
