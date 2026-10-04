//! Unit tests ported from `zeron_markdown::parser`'s test module.

const std = @import("std");
const testing = std.testing;
const md = @import("root.zig");
const parser = md.parser;
const Block = md.Block;
const BlockTree = md.BlockTree;
const IncrementalParser = md.IncrementalParser;

const gpa = testing.allocator;

fn parse(src: []const u8) !BlockTree {
    return parser.parseFull(gpa, src);
}

fn streamChunks(chunk: usize, text: []const u8) !IncrementalParser {
    var p = IncrementalParser.init(gpa);
    errdefer p.deinit();
    var start: usize = 0;
    while (start < text.len) {
        var end = @min(start + chunk, text.len);
        while (end < text.len and (text[end] & 0xC0) == 0x80) end += 1;
        try p.append(text[start..end]);
        start = end;
    }
    return p;
}

pub const CORPORA = [_][]const u8{
    "# Title\n\nHello **bold** and *italic* and `code` and ~~gone~~.\n",
    "Paragraph one\nlazy continuation\n\nParagraph two with a [link](https://x.dev).\n",
    "- item one\n- item two\n  - nested a\n  - nested b\n- item three\n\ntail\n",
    "1. first\n2. second\n\n   loose paragraph in item\n\n3. third\n",
    "```rust\nfn main() {\n    println!(\"hi\");\n}\n```\n\nafter code\n",
    "intro\n\n```\nunclosed fence streaming",
    "> quoted line\n> more quote\n>\n> - a list in a quote\n\nplain\n",
    "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\ndone\n",
    "setext candidate\n===\n\nnext para\n---\n",
    "***\n\ntext between rules\n\n---\n",
    "- [x] done task\n- [ ] open task\n",
    "    indented code line one\n    line two\n\npara\n",
    "see [it's here](/tmp/2026/Some Folder/it's here.txt) and `[raw](/tmp/a b.md)`\n",
    "text\n\n```\n[x](/tmp/a b.md)\n```\n\nafter [y](file:///tmp/c d.md)\n",
    "para with <span>inline html</span> inside\n\n<div>\nblock html\n</div>\n",
    "###### deep heading\n\n#### h4\n",
};

test "incremental matches full on streamed corpora" {
    for (CORPORA) |corpus| {
        var full = try parse(corpus);
        defer full.deinit(gpa);
        for ([_]usize{ 1, 2, 3, 7, 16, 64 }) |chunk| {
            var inc = try streamChunks(chunk, corpus);
            defer inc.deinit();
            if (!inc.canonical().eql(full)) {
                std.debug.print("diverged at chunk {d}:\n{s}\n", .{ chunk, corpus });
                return error.TestExpectedEqual;
            }
        }
    }
}

test "appends keep committed blocks identical" {
    for (CORPORA) |corpus| {
        var p = IncrementalParser.init(gpa);
        defer p.deinit();
        var prev = try p.canonical().clone(gpa);
        defer prev.deinit(gpa);
        var start: usize = 0;
        while (start < corpus.len) {
            const end = @min(start + 3, corpus.len);
            try p.append(corpus[start..end]);
            start = end;
            const cur = p.canonical();
            const committed = prev.blocks.len -| 2;
            try testing.expect(cur.blocks.len >= committed);
            for (0..committed) |i| {
                try testing.expect(cur.blocks[i] == prev.blocks[i]);
            }
            prev.deinit(gpa);
            prev = try cur.clone(gpa);
        }
    }
}

test "incremental matches full with link definitions" {
    const corpus = "See [docs] for more.\n\nMore text.\n\n[docs]: https://example.com\n";
    var full = try parse(corpus);
    defer full.deinit(gpa);
    for ([_]usize{ 1, 3, 9 }) |chunk| {
        var inc = try streamChunks(chunk, corpus);
        defer inc.deinit();
        try testing.expect(inc.canonical().eql(full));
    }
    var has_link = false;
    for (full.blocks) |b| switch (b.block) {
        .paragraph => |runs| for (runs) |r| {
            if (r.style.link != null) has_link = true;
        },
        else => {},
    };
    try testing.expect(has_link);
}

test "set_text appends or resets" {
    var p = IncrementalParser.init(gpa);
    defer p.deinit();
    try p.setText("hello");
    try p.setText("hello world");
    var a = try parse("hello world");
    defer a.deinit(gpa);
    try testing.expect(p.canonical().eql(a));
    try p.setText("different");
    var b = try parse("different");
    defer b.deinit(gpa);
    try testing.expect(p.canonical().eql(b));
    try testing.expectEqualStrings("different", p.sourceText());
}

test "block structure basics" {
    var tree = try parse("## Head\n\npara **b _bi_** text\n\n```ts\nlet x = 1;\n```\n");
    defer tree.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), tree.len());
    const h = tree.blocks[0].block.heading;
    try testing.expectEqual(@as(u8, 2), h.level);
    try testing.expectEqualStrings("Head", h.runs[0].text);
    const runs = tree.blocks[1].block.paragraph;
    try testing.expectEqual(@as(usize, 4), runs.len);
    try testing.expect(runs[1].style.bold and !runs[1].style.italic);
    try testing.expect(runs[2].style.bold and runs[2].style.italic);
    const c = tree.blocks[2].block.code_block;
    try testing.expectEqualStrings("ts", c.language.?);
    try testing.expectEqualStrings("let x = 1;", c.code);
}

test "nested lists and tight items" {
    var tree = try parse("- a\n  - a1\n  - a2\n- b\n");
    defer tree.deinit(gpa);
    const l = tree.blocks[0].block.list;
    try testing.expect(l.ordered_start == null);
    try testing.expectEqual(@as(usize, 2), l.items.len);
    try testing.expect(l.items[0][0] == .paragraph);
    try testing.expect(l.items[0][1] == .list);
}

test "tables parse header rows and alignment" {
    var tree = try parse("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n");
    defer tree.deinit(gpa);
    const t = tree.blocks[0].block.table;
    try testing.expectEqual(@as(usize, 3), t.header.len);
    try testing.expectEqual(@as(usize, 1), t.rows.len);
    try testing.expectEqualStrings("2", t.rows[0][1][0].text);
    try testing.expectEqualSlices(md.TableAlign, &.{ .left, .center, .right }, t.alignment);
}

test "links carry urls and bare urls autolink" {
    var tree = try parse("go to [zed](https://zed.dev) now\n");
    defer tree.deinit(gpa);
    var found = false;
    for (tree.blocks[0].block.paragraph) |r| if (r.style.link) |l| {
        try testing.expectEqualStrings("zed", r.text);
        try testing.expectEqualStrings("https://zed.dev", l);
        found = true;
    };
    try testing.expect(found);

    var t2 = try parse("(docs: https://x.dev/Foo_(bar))\n");
    defer t2.deinit(gpa);
    found = false;
    for (t2.blocks[0].block.paragraph) |r| if (r.style.link) |l| {
        try testing.expectEqualStrings("https://x.dev/Foo_(bar)", l);
        found = true;
    };
    try testing.expect(found);
}

test "top level ranges are stable anchors" {
    const src = "first\n\nsecond\n\nthird";
    var tree = try parse(src);
    defer tree.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), tree.len());
    const r = tree.blocks[1].range;
    try testing.expectEqualStrings("second\n", src[r.start..r.end]);
}

test "display tree styles hanging bold immediately" {
    var p = IncrementalParser.init(gpa);
    defer p.deinit();
    try p.setText("intro **bo");
    var d = try p.displayTree();
    defer d.deinit(gpa);
    var bold: usize = 0;
    for (d.blocks[0].block.paragraph) |r| if (r.style.bold) {
        bold += 1;
        try testing.expectEqualStrings("bo", r.text);
    };
    try testing.expectEqual(@as(usize, 1), bold);
}

test "display tree never leaks streaming urls" {
    const full = "read [docs](https://example.com/long/path) now";
    var p = IncrementalParser.init(gpa);
    defer p.deinit();
    for (1..full.len + 1) |i| {
        try p.setText(full[0..i]);
        var d = try p.displayTree();
        defer d.deinit(gpa);
        for (d.blocks[0].block.paragraph) |r| {
            try testing.expect(std.mem.indexOf(u8, r.text, "http") == null);
        }
    }
}

test "display tree leaves code blocks alone and suppresses setext flicker" {
    var p = IncrementalParser.init(gpa);
    defer p.deinit();
    try p.setText("intro\n\n```\nunclosed **fence");
    var d = try p.displayTree();
    defer d.deinit(gpa);
    try testing.expect(d.eql(p.canonical()));

    try p.setText("para\n-");
    var d2 = try p.displayTree();
    defer d2.deinit(gpa);
    try testing.expect(d2.blocks[d2.blocks.len - 1].block == .paragraph);
}

test "rewritten destinations become links and ranges map back" {
    const source = "intro [x](/tmp/a b.md) tail\n\nsecond paragraph\n";
    var tree = try parse(source);
    defer tree.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), tree.len());
    const r0 = tree.blocks[0].range;
    try testing.expectEqualStrings("intro [x](/tmp/a b.md) tail\n", source[r0.start..r0.end]);
    var link: ?[]const u8 = null;
    for (tree.blocks[0].block.paragraph) |r| if (r.style.link) |l| {
        link = l;
    };
    try testing.expectEqualStrings("/tmp/a b.md", link.?);
}

test "images preserve alt title links" {
    var tree = try parse("Before [![**alt**](a.png \"Title\")](next.md) after ![](b.png) ![](b.png)");
    defer tree.deinit(gpa);
    var imgs: std.ArrayList(md.InlineImage) = .empty;
    defer imgs.deinit(gpa);
    for (tree.blocks[0].block.paragraph) |r| if (r.style.image) |img| try imgs.append(gpa, img);
    try testing.expectEqual(@as(usize, 3), imgs.items.len);
    try testing.expectEqualStrings("alt", imgs.items[0].alt);
    try testing.expectEqualStrings("Title", imgs.items[0].title);
    try testing.expectEqualStrings("next.md", imgs.items[0].link.?);
    try testing.expectEqualStrings("b.png", imgs.items[1].source);
}

test "empty and whitespace sources" {
    var a = try parse("");
    defer a.deinit(gpa);
    try testing.expect(a.isEmpty());
    var b = try parse("\n\n  \n");
    defer b.deinit(gpa);
    try testing.expect(b.isEmpty());
}
