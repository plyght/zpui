//! Parity against the Rust originals: fixtures in testdata/ were produced by
//! apps/zeron/scripts/markdown_parity.rs linking zeron's own rlibs
//! (pulldown-cmark 0.12.2 + zeron_markdown). Every document's pulldown
//! offset events, zeron block tree, mend output and streaming steps must
//! match byte-for-byte as canonical JSON.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const md = @import("root.zig");
const cmark = md.cmark;
const json = md.json;

const corpus_txt = @embedFile("testdata/corpus.txt");
const stream_txt = @embedFile("testdata/stream.txt");
const events_jsonl = @embedFile("testdata/events.jsonl");
const trees_jsonl = @embedFile("testdata/trees.jsonl");
const mend_jsonl = @embedFile("testdata/mend.jsonl");
const stream_jsonl = @embedFile("testdata/stream.jsonl");

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

fn tagName(k: cmark.TagKind) []const u8 {
    return @tagName(k);
}

fn linkTypeName(t: cmark.LinkType) []const u8 {
    return switch (t) {
        .inline_ => "inline",
        .reference => "reference",
        .collapsed => "collapsed",
        .shortcut => "shortcut",
        .autolink => "autolink",
        .email => "email",
    };
}

pub fn writeEvents(o: *json.Out, events: []const cmark.OffsetEvent) !void {
    try o.raw("[");
    for (events, 0..) |oe, i| {
        if (i > 0) try o.raw(",");
        switch (oe.event) {
            .start => |tag| {
                try o.raw("[\"S\",\"");
                try o.raw(tagName(std.meta.activeTag(tag)));
                try o.raw("\",");
                try o.int(oe.start);
                try o.raw(",");
                try o.int(oe.end);
                switch (tag) {
                    .heading => |l| {
                        try o.raw(",");
                        try o.int(l);
                    },
                    .code_block => |info| {
                        try o.raw(",");
                        try o.optStr(info);
                    },
                    .list => |s| {
                        try o.raw(",");
                        if (s) |n| try o.int(n) else try o.raw("null");
                    },
                    .table => |al| {
                        try o.raw(",[");
                        for (al, 0..) |x, k| {
                            if (k > 0) try o.raw(",");
                            try o.str(@tagName(x));
                        }
                        try o.raw("]");
                    },
                    .link, .image => |l| {
                        try o.raw(",\"");
                        try o.raw(linkTypeName(l.link_type));
                        try o.raw("\",");
                        try o.str(l.dest_url);
                        try o.raw(",");
                        try o.str(l.title);
                        try o.raw(",");
                        try o.str(l.id);
                    },
                    else => {},
                }
                try o.raw("]");
            },
            .end => |k| {
                try o.raw("[\"E\",\"");
                try o.raw(tagName(k));
                try o.raw("\",");
                try o.int(oe.start);
                try o.raw(",");
                try o.int(oe.end);
                try o.raw("]");
            },
            .text, .code, .html, .inline_html => |t| {
                try o.raw(switch (oe.event) {
                    .text => "[\"T\",",
                    .code => "[\"C\",",
                    .html => "[\"H\",",
                    else => "[\"I\",",
                });
                try o.int(oe.start);
                try o.raw(",");
                try o.int(oe.end);
                try o.raw(",");
                try o.str(t);
                try o.raw("]");
            },
            .soft_break, .hard_break, .rule => {
                try o.raw(switch (oe.event) {
                    .soft_break => "[\"SB\",",
                    .hard_break => "[\"HB\",",
                    else => "[\"R\",",
                });
                try o.int(oe.start);
                try o.raw(",");
                try o.int(oe.end);
                try o.raw("]");
            },
            .task_list_marker => |b| {
                try o.raw("[\"X\",");
                try o.int(oe.start);
                try o.raw(",");
                try o.int(oe.end);
                try o.raw(",");
                try o.boolean(b);
                try o.raw("]");
            },
        }
    }
    try o.raw("]");
}

fn report(kind: []const u8, i: usize, doc: []const u8, want: []const u8, got: []const u8) void {
    var p: usize = 0;
    while (p < want.len and p < got.len and want[p] == got[p]) p += 1;
    const lo = p -| 80;
    std.debug.print("\n[{s}] doc #{d} mismatch: {f}\n  want: …{s}\n  got:  …{s}\n", .{
        kind,                              i,                               std.zig.fmtString(doc),
        want[lo..@min(want.len, p + 120)], got[lo..@min(got.len, p + 120)],
    });
}

fn fnv(s: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (s) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

test "parity: pulldown-cmark offset events" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = try readDocs(a, corpus_txt);
    const want = try lines(a, events_jsonl);
    try testing.expectEqual(docs.len, want.len);
    var failures: usize = 0;
    for (docs, want, 0..) |doc, w, i| {
        var tmp = std.heap.ArenaAllocator.init(testing.allocator);
        defer tmp.deinit();
        const evs = try cmark.collectEvents(tmp.allocator(), doc);
        var o: json.Out = .{ .a = tmp.allocator() };
        try writeEvents(&o, evs);
        if (!std.mem.eql(u8, o.buf.items, w)) {
            failures += 1;
            if (failures <= 5) report("events", i, doc, w, o.buf.items);
        }
    }
    if (failures > 0) {
        std.debug.print("events: {d}/{d} documents differ\n", .{ failures, docs.len });
        return error.TestExpectedEqual;
    }
}

test "parity: zeron block trees" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = try readDocs(a, corpus_txt);
    const want = try lines(a, trees_jsonl);
    try testing.expectEqual(docs.len, want.len);
    var failures: usize = 0;
    for (docs, want, 0..) |doc, w, i| {
        var tree = try md.parseFull(testing.allocator, doc);
        defer tree.deinit(testing.allocator);
        var o: json.Out = .{ .a = testing.allocator };
        defer o.buf.deinit(testing.allocator);
        try json.writeTree(&o, tree);
        if (!std.mem.eql(u8, o.buf.items, w)) {
            failures += 1;
            if (failures <= 5) report("trees", i, doc, w, o.buf.items);
        }
    }
    if (failures > 0) {
        std.debug.print("trees: {d}/{d} documents differ\n", .{ failures, docs.len });
        return error.TestExpectedEqual;
    }
}

test "parity: streaming mend (close_hanging)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = try readDocs(a, corpus_txt);
    const want = try lines(a, mend_jsonl);
    try testing.expectEqual(docs.len, want.len);
    var failures: usize = 0;
    for (docs, want, 0..) |doc, w, i| {
        const got = try md.closeHanging(testing.allocator, doc);
        defer if (got) |g| testing.allocator.free(g);
        var o: json.Out = .{ .a = testing.allocator };
        defer o.buf.deinit(testing.allocator);
        try o.optStr(got);
        if (!std.mem.eql(u8, o.buf.items, w)) {
            failures += 1;
            if (failures <= 5) report("mend", i, doc, w, o.buf.items);
        }
    }
    if (failures > 0) {
        std.debug.print("mend: {d}/{d} documents differ\n", .{ failures, docs.len });
        return error.TestExpectedEqual;
    }
}

test "parity: incremental streaming (canonical + display trees)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = try readDocs(a, stream_txt);
    const want = try lines(a, stream_jsonl);
    try testing.expectEqual(docs.len, want.len);
    var failures: usize = 0;
    var steps_total: usize = 0;
    for (docs, want, 0..) |doc, w, i| {
        const chunk: usize = if (doc.len <= 160) 1 else 5;
        var p = md.IncrementalParser.init(testing.allocator);
        defer p.deinit();
        var o: json.Out = .{ .a = testing.allocator };
        defer o.buf.deinit(testing.allocator);
        try o.raw("[");
        var start: usize = 0;
        var first = true;
        while (start < doc.len) {
            var end = @min(start + chunk, doc.len);
            while (end < doc.len and (doc[end] & 0xC0) == 0x80) end += 1;
            try p.append(doc[start..end]);
            start = end;
            steps_total += 1;
            if (!first) try o.raw(",");
            first = false;
            try o.raw("{\"n\":");
            try o.int(end);
            try o.raw(",\"stable\":");
            try o.int(p.stablePrefixBlocks());
            try o.raw(",\"bytes\":");
            try o.int(p.lastParseBytes());
            try o.raw(",\"canon\":");
            var c: json.Out = .{ .a = testing.allocator };
            defer c.buf.deinit(testing.allocator);
            try json.writeTree(&c, p.canonical());
            var hb: [18]u8 = undefined;
            try o.raw(try std.fmt.bufPrint(&hb, "\"{x:0>16}\"", .{fnv(c.buf.items)}));
            try o.raw(",\"display\":");
            var d = try p.displayTree();
            defer d.deinit(testing.allocator);
            if (d.eql(p.canonical())) {
                try o.raw("null");
            } else {
                var dj: json.Out = .{ .a = testing.allocator };
                defer dj.buf.deinit(testing.allocator);
                try json.writeTree(&dj, d);
                try o.raw(try std.fmt.bufPrint(&hb, "\"{x:0>16}\"", .{fnv(dj.buf.items)}));
            }
            try o.raw("}");
        }
        try o.raw("]");
        if (!std.mem.eql(u8, o.buf.items, w)) {
            failures += 1;
            if (failures <= 5) report("stream", i, doc, w, o.buf.items);
        }
    }
    if (failures > 0) {
        std.debug.print("stream: {d}/{d} documents differ ({d} steps)\n", .{ failures, docs.len, steps_total });
        return error.TestExpectedEqual;
    }
}
