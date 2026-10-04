//! Text system tests: wrapping/truncation/layout/caching against the deterministic
//! fake backend, and shaping/rasterization against the real FreeType backend on Linux.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const types = @import("types.zig");
const color = @import("../color.zig");
const geometry = @import("../geometry.zig");
const atlas_mod = @import("../atlas.zig");
const FakePlatform = @import("test_platform.zig");
const text_system = @import("text_system.zig");
const line_wrapper = @import("line_wrapper.zig");
const line_layout = @import("line_layout.zig");
const line_mod = @import("line.zig");

const TextSystem = text_system.TextSystem;
const WindowTextSystem = text_system.WindowTextSystem;
const LineFragment = line_wrapper.LineFragment;
const Boundary = line_wrapper.Boundary;
const TextRun = types.TextRun;

const Fixture = struct {
    fake: FakePlatform,
    ts: TextSystem,

    fn init(self: *Fixture) void {
        self.fake = .init(testing.allocator);
        self.ts = .init(testing.allocator, self.fake.textSystem());
    }
    fn deinit(self: *Fixture) void {
        self.ts.deinit();
        self.fake.deinit();
    }
};

fn run(len: usize) TextRun {
    return .{ .len = len, .font = .{ .family = "Mono" }, .color = color.black };
}

fn expectWrap(w: *line_wrapper.LineWrapper, fragments: []const LineFragment, width: f32, expected: []const Boundary) !void {
    const got = try w.wrapLine(testing.allocator, fragments, width);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(Boundary, expected, got);
}

fn b(ix: usize, indent: u32) Boundary {
    return .{ .ix = ix, .next_indent = indent };
}

test "wrap_line (gpui test_wrap_line)" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const w = try f.ts.lineWrapper(.{ .family = "Lilex" }, 16);
    defer f.ts.releaseLineWrapper(w);
    const t = LineFragment.txt;
    const e = LineFragment.elem;

    try expectWrap(w, &.{t("aa bbb cccc ddddd eeee")}, 72, &.{ b(7, 0), b(12, 0), b(18, 0) });
    try expectWrap(w, &.{t("aaa aaaaaaaaaaaaaaaaaa")}, 72, &.{ b(4, 0), b(11, 0), b(18, 0) });
    try expectWrap(w, &.{t("     aaaaaaa")}, 72, &.{ b(7, 5), b(9, 5), b(11, 5) });
    try expectWrap(w, &.{t("                            ")}, 72, &.{ b(7, 0), b(14, 0), b(21, 0) });
    try expectWrap(w, &.{t("          aaaaaaaaaaaaaa")}, 72, &.{ b(7, 0), b(14, 3), b(18, 3), b(22, 3) });
    try expectWrap(w, &.{ t("aa bbb "), t("cccc ddddd eeee") }, 72, &.{ b(7, 0), b(12, 0), b(18, 0) });
    try expectWrap(w, &.{ t("aa "), e(20, 1), t(" bbb "), e(30, 1), t(" cccc") }, 72, &.{ b(5, 0), b(9, 0), b(11, 0) });
    try expectWrap(w, &.{ e(50, 1), t(" aaaa bbbb cccc dddd") }, 72, &.{ b(2, 0), b(7, 0), b(12, 0), b(17, 0) });
    try expectWrap(w, &.{ t("short text "), e(100, 1), t(" more text") }, 72, &.{ b(6, 0), b(11, 0), b(12, 0), b(18, 0) });
    try expectWrap(w, &.{t("a\u{202F}b\u{00A0}c\u{2011}d e")}, 72, &.{b(12, 0)});
}

test "wrap_line keeps closing punctuation attached (zui fork rule)" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const w = try f.ts.lineWrapper(.{ .family = "Lilex" }, 16);
    defer f.ts.releaseLineWrapper(w);
    const t = LineFragment.txt;
    try expectWrap(w, &.{t("aaa aaaa.\"")}, 72, &.{b(4, 0)});
    try expectWrap(w, &.{t("aaa aaaaa!")}, 72, &.{b(4, 0)});
    try expectWrap(w, &.{t("aaa (aaaa)")}, 72, &.{b(4, 0)});
    try expectWrap(w, &.{t("aaaa bbb \"cc\"")}, 72, &.{ b(5, 0), b(9, 0) });
}

test "wrap_line breaks CJK anywhere and long words mid-word" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const w = try f.ts.lineWrapper(.{ .family = "Lilex" }, 16);
    defer f.ts.releaseLineWrapper(w);
    // CJK chars are double width: 3 fit in 72px; every CJK char is a break opportunity.
    try expectWrap(w, &.{LineFragment.txt("你好世界你好世界")}, 72, &.{ b(9, 0), b(18, 0) });
    // A CJK char directly after a Latin word is not a candidate (fork rule); the next one is.
    try expectWrap(w, &.{LineFragment.txt("Hello你好世界")}, 72, &.{b(8, 0)});
    try expectWrap(w, &.{LineFragment.txt("abcdefghijklmnop")}, 72, &.{ b(7, 0), b(14, 0) });
}

fn expectTruncate(w: *line_wrapper.LineWrapper, text: []const u8, width: f32, affix: []const u8, from: line_wrapper.TruncateFrom, expected: []const u8) !void {
    const runs = [_]TextRun{run(text.len)};
    const r = try w.truncateLine(testing.allocator, text, width, affix, &runs, from);
    if (r) |tr| {
        defer tr.deinit(testing.allocator);
        try testing.expectEqualStrings(expected, tr.text);
        var total: usize = 0;
        for (tr.runs) |rr| total += rr.len;
        try testing.expectEqual(tr.text.len, total);
    } else try testing.expectEqualStrings(expected, text);
}

test "truncate_line end/start/middle" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const w = try f.ts.lineWrapper(.{ .family = "Lilex" }, 16);
    defer f.ts.releaseLineWrapper(w);
    const s = "aa bbb cccc ddddd eeee ffff gggg";
    try expectTruncate(w, s, 220, "", .end, "aa bbb cccc ddddd eeee");
    try expectTruncate(w, s, 220, "…", .end, "aa bbb cccc ddddd eee…");
    try expectTruncate(w, s, 220, "......", .end, "aa bbb cccc dddd......");
    try expectTruncate(w, "aa bbb cccc 🦀🦀🦀🦀🦀 eeee ffff gggg", 220, "…", .end, "aa bbb cccc 🦀🦀🦀🦀…");
    const s2 = "aaaa bbbb cccc ddddd eeee fff gg";
    try expectTruncate(w, s2, 220, "", .start, "cccc ddddd eeee fff gg");
    try expectTruncate(w, s2, 220, "…", .start, "…ccc ddddd eeee fff gg");
    try expectTruncate(w, s2, 220, "......", .start, "......dddd eeee fff gg");
    try expectTruncate(w, "aaaa bbbb cccc 🦀🦀🦀🦀🦀 eeee fff gg", 220, "…", .start, "…🦀🦀🦀🦀 eeee fff gg");
    try expectTruncate(w, "abcdefghijklmnopqrstuvwxyz", 100, "…", .middle, "abcdef…xyz");
    try expectTruncate(w, "short", 100, "…", .end, "short");
}

test "truncate multiple runs" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const w = try f.ts.lineWrapper(.{ .family = "Lilex" }, 16);
    defer f.ts.releaseLineWrapper(w);
    const runs = [_]TextRun{ run(4), run(4), run(4) };
    const r = (try w.truncateLine(testing.allocator, "abcdefghijkl", 70, "…", &runs, .end)).?;
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("abcdef…", r.text);
    try testing.expectEqual(@as(usize, 2), r.runs.len);
    try testing.expectEqual(@as(usize, 5), r.runs[1].len);
    const r2 = (try w.truncateLine(testing.allocator, "abcdefghijkl", 90, "…", &runs, .end)).?;
    defer r2.deinit(testing.allocator);
    try testing.expectEqualStrings("abcdefgh…", r2.text);
    try testing.expectEqual(@as(usize, 3), r2.runs[2].len);
}

test "shapeLine hit testing: xForIndex / indexForX / closestIndexForX" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var wts: WindowTextSystem = .init(&f.ts);
    defer wts.deinit();
    const line = try wts.shapeLine("abc你", 16, &.{run(6)}, null);
    defer line.deinit(testing.allocator);
    try testing.expectEqual(@as(f32, 50), line.width());
    try testing.expectEqual(@as(f32, 0), line.xForIndex(0));
    try testing.expectEqual(@as(f32, 20), line.xForIndex(2));
    try testing.expectEqual(@as(f32, 30), line.xForIndex(3));
    try testing.expectEqual(@as(f32, 50), line.xForIndex(6));
    try testing.expectEqual(@as(?usize, 1), line.indexForX(14));
    try testing.expectEqual(@as(?usize, 3), line.indexForX(45));
    try testing.expectEqual(@as(?usize, null), line.indexForX(50));
    try testing.expectEqual(@as(usize, 1), line.closestIndexForX(14));
    try testing.expectEqual(@as(usize, 2), line.closestIndexForX(16));
    try testing.expectEqual(@as(usize, 6), line.closestIndexForX(99));
}

test "shapeText splits lines, wraps, clamps and truncates" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var wts: WindowTextSystem = .init(&f.ts);
    defer wts.deinit();
    const text = "aa bbb cccc\nddddd eeee";
    const lines = try wts.shapeText(text, 16, &.{run(text.len)}, .{ .wrap_width = 72 });
    defer text_system.freeLines(testing.allocator, lines);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("aa bbb cccc", lines[0].text);
    try testing.expectEqual(@as(usize, 1), lines[0].wrapBoundaries().len);
    try testing.expectEqual(@as(f32, 40), lines[0].size(20).height);
    try testing.expectEqual(@as(usize, 1), lines[1].wrapBoundaries().len);
    // Caret positions on the wrapped second visual row.
    const p = lines[0].positionForIndex(9, 20).?;
    try testing.expectEqual(@as(f32, 20), p.y);
    try testing.expectEqual(@as(f32, 20), p.x);
    try testing.expectEqual(line_layout.SharedWrappedLayout.PositionIndex{ .inside = 9 }, lines[0].indexForPosition(.{ .x = 25, .y = 25 }, 20));

    // Clamp to 2 visual lines total.
    const long = "aa bbb cccc ddddd eeee";
    const clamped = try wts.shapeText(long, 16, &.{run(long.len)}, .{ .wrap_width = 72, .line_clamp = 2 });
    defer text_system.freeLines(testing.allocator, clamped);
    try testing.expectEqual(@as(usize, 1), clamped[0].wrapBoundaries().len);

    // Truncation with ellipsis.
    const tr = try wts.shapeText(long, 16, &.{run(long.len)}, .{ .truncate = .{ .width = 100, .line_height = 20 } });
    defer text_system.freeLines(testing.allocator, tr);
    try testing.expectEqualStrings("aa bbb c…", tr[0].text);
    try testing.expect(tr[0].width() <= 100);
}

test "line layout cache: hits, two-frame retention, reuse" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var wts: WindowTextSystem = .init(&f.ts);
    defer wts.deinit();
    const runs = [_]TextRun{run(5)};

    const a = try wts.layoutLine("hello", 16, &runs, null);
    a.release();
    const calls = f.fake.layout_calls;
    const a2 = try wts.layoutLine("hello", 16, &runs, null);
    try testing.expectEqual(a, a2);
    a2.release();
    try testing.expectEqual(calls, f.fake.layout_calls);

    // Survives one frame boundary when used again in the next frame.
    wts.finishFrame();
    const a3 = try wts.layoutLine("hello", 16, &runs, null);
    try testing.expectEqual(calls, f.fake.layout_calls);
    a3.release();
    // Not used in a frame -> dropped after it.
    wts.finishFrame();
    wts.finishFrame();
    const a4 = try wts.layoutLine("hello", 16, &runs, null);
    try testing.expectEqual(calls + 1, f.fake.layout_calls);
    a4.release();

    // reuseLayouts carries a range of last frame's layouts into this frame.
    wts.finishFrame();
    const start = wts.layoutIndex();
    (try wts.layoutLine("world", 16, &runs, null)).release();
    const end = wts.layoutIndex();
    wts.finishFrame();
    try wts.reuseLayouts(start, end);
    wts.finishFrame();
    const calls2 = f.fake.layout_calls;
    // "world" was carried into the previous frame by reuse, so it is still cached.
    (try wts.layoutLine("world", 16, &runs, null)).release();
    try testing.expectEqual(calls2, f.fake.layout_calls);

    // Held references outlive the cache.
    const held = try wts.layoutLine("keep", 16, &.{run(4)}, null);
    wts.finishFrame();
    wts.finishFrame();
    try testing.expectEqual(@as(usize, 4), held.layout.len);
    held.release();

    // Content-hash keyed lookups.
    const Mat = struct {
        pub fn text(_: @This()) []const u8 {
            return "hashed";
        }
    };
    const h1 = try wts.cache.layoutLineByHash(42, 6, 16, &.{.{ .len = 6, .font_id = @enumFromInt(0) }}, null, Mat{});
    defer h1.release();
    const h2 = (try wts.cache.tryLayoutLineByHash(42, 6, 16, &.{.{ .len = 6, .font_id = @enumFromInt(0) }}, null)).?;
    defer h2.release();
    try testing.expectEqual(h1, h2);
}

test "font resolution caches results and falls back" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const id = try f.ts.resolveFont(.{ .family = "Missing" });
    // First fallback in the stack.
    try testing.expectEqual(try f.ts.fontId(.{ .family = ".ZedMono" }), id);
    try testing.expectError(error.FontNotFound, f.ts.fontId(.{ .family = "Missing" }));
    try testing.expectEqual(@as(f32, 12), f.ts.ascent(id, 16));
    try testing.expectEqual(@as(f32, 16 * 0.75 + 2), f.ts.baselineOffset(id, 16, 20));
}

const RecordingPainter = struct {
    glyphs: std.ArrayList(geometry.Point(f32)) = .empty,
    quads: usize = 0,
    underlines: std.ArrayList(f32) = .empty,

    fn painter(self: *RecordingPainter, ts: *TextSystem) line_mod.GlyphPainter {
        return .{ .ptr = self, .vtable = &.{
            .paintGlyph = paintGlyph,
            .paintEmoji = paintEmoji,
            .paintQuad = paintQuad,
            .paintUnderline = paintUnderline,
            .paintStrikethrough = paintStrike,
        }, .text_system = ts, .scale_factor = 2 };
    }
    fn paintGlyph(ptr: *anyopaque, _: types.RenderGlyphParams, origin: geometry.Point(f32), _: color.Hsla) anyerror!void {
        const self: *RecordingPainter = @ptrCast(@alignCast(ptr));
        try self.glyphs.append(testing.allocator, origin);
    }
    fn paintEmoji(ptr: *anyopaque, p: types.RenderGlyphParams, origin: geometry.Point(f32)) anyerror!void {
        try paintGlyph(ptr, p, origin, color.black);
    }
    fn paintQuad(ptr: *anyopaque, _: geometry.Bounds(f32), _: color.Hsla) anyerror!void {
        const self: *RecordingPainter = @ptrCast(@alignCast(ptr));
        self.quads += 1;
    }
    fn paintUnderline(ptr: *anyopaque, _: geometry.Point(f32), width: f32, _: types.UnderlineStyle) anyerror!void {
        const self: *RecordingPainter = @ptrCast(@alignCast(ptr));
        try self.underlines.append(testing.allocator, width);
    }
    fn paintStrike(_: *anyopaque, _: geometry.Point(f32), _: f32, _: types.StrikethroughStyle) anyerror!void {}
};

test "paint emits glyphs per wrapped row with decorations" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var wts: WindowTextSystem = .init(&f.ts);
    defer wts.deinit();
    var runs = [_]TextRun{ run(3), run(8) };
    runs[1].underline = .{};
    runs[1].background_color = color.red;
    const lines = try wts.shapeText("aa bbb cccc", 16, &runs, .{ .wrap_width = 72 });
    defer text_system.freeLines(testing.allocator, lines);
    var rec: RecordingPainter = .{};
    defer rec.glyphs.deinit(testing.allocator);
    defer rec.underlines.deinit(testing.allocator);
    const p = rec.painter(&f.ts);
    try lines[0].paintBackground(p, .{ .x = 10, .y = 0 }, 20, .left, null);
    try lines[0].paint(p, .{ .x = 10, .y = 0 }, 20, .left, null);
    try testing.expectEqual(@as(usize, 11), rec.glyphs.items.len);
    // Device px (scale 2): first glyph at x=20, baseline (20-12-4)/2+12 = 14 -> 28.
    try testing.expectEqual(@as(f32, 20), rec.glyphs.items[0].x);
    try testing.expectEqual(@as(f32, 28), rec.glyphs.items[0].y);
    // "cccc" wraps to the second row at the origin x.
    try testing.expectEqual(@as(f32, 20), rec.glyphs.items[7].x);
    try testing.expectEqual(@as(f32, 68), rec.glyphs.items[7].y);
    try testing.expectEqual(@as(usize, 2), rec.underlines.items.len);
    try testing.expectEqual(@as(usize, 2), rec.quads);
}

test "subpixel glyph quantization matches gpui" {
    const g = line_mod.glyphRenderParams(@enumFromInt(0), 1, 14, .{ .x = 10.3, .y = 5.5 }, 1, false);
    try testing.expectEqual(@as(u8, 1), g.params.subpixel_variant_x);
    try testing.expectEqual(@as(f32, 10), g.origin.x);
    try testing.expectEqual(@as(f32, 5), g.origin.y);
    const g2 = line_mod.glyphRenderParams(@enumFromInt(0), 1, 14, .{ .x = 10.9, .y = 0 }, 1, false);
    try testing.expectEqual(@as(u8, 0), g2.params.subpixel_variant_x);
    try testing.expectEqual(@as(f32, 11), g2.origin.x);
}

test "rasterizeToAtlas inserts glyph tiles once" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    var atlas: atlas_mod.Atlas = .init(testing.allocator, .{});
    defer atlas.deinit();
    const g = line_mod.glyphRenderParams(@enumFromInt(0), 'a', 16, .{ .x = 0, .y = 10 }, 1, false);
    const s1 = (try f.ts.rasterizeToAtlas(&atlas, g.params, g.origin)).?;
    const s2 = (try f.ts.rasterizeToAtlas(&atlas, g.params, g.origin)).?;
    try testing.expectEqual(s1.tile.tile_id, s2.tile.tile_id);
    try testing.expectEqual(@as(f32, 0), s1.bounds.origin.y);
    const space = line_mod.glyphRenderParams(@enumFromInt(0), ' ', 16, .{ .x = 0, .y = 10 }, 1, false);
    try testing.expectEqual(@as(?TextSystem.GlyphSprite, null), try f.ts.rasterizeToAtlas(&atlas, space.params, space.origin));
}

// ---------------------------------------------------------------------------
// FreeType backend (Linux)
// ---------------------------------------------------------------------------

const freetype = if (builtin.os.tag == .linux) @import("freetype.zig") else struct {};

const Real = struct {
    platform: @import("../platform/platform.zig").TextSystem,
    ts: TextSystem,

    fn init(self: *Real) !void {
        self.platform = try freetype.create(testing.allocator);
        self.ts = .init(testing.allocator, self.platform);
    }
    fn deinit(self: *Real) void {
        self.ts.deinit();
        freetype.destroy(self.platform);
    }
    fn shape(self: *Real, arena: std.mem.Allocator, f: types.Font, text: []const u8) !types.LineLayout {
        const id = try self.ts.fontId(f);
        return self.platform.vtable.layoutLine(self.platform.ptr, arena, text, 16, &.{.{ .len = text.len, .font_id = id }});
    }
};

fn glyphCount(l: types.LineLayout) usize {
    var n: usize = 0;
    for (l.runs) |r| n += r.glyphs.len;
    return n;
}

test "freetype: font matching by weight and style" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Real = undefined;
    try r.init();
    defer r.deinit();
    const regular = try r.ts.fontId(.{ .family = "Inter" });
    const bold = try r.ts.fontId(.{ .family = "Inter", .weight = types.weight.bold });
    const italic = try r.ts.fontId(.{ .family = "Inter", .style = .italic });
    try testing.expect(regular != bold and regular != italic and bold != italic);
    try testing.expectError(error.FontNotFound, r.ts.fontId(.{ .family = "No Such Font Family" }));
    const m = r.ts.fontMetrics(regular);
    try testing.expect(m.units_per_em > 0 and m.ascent > 0 and m.descent < 0);
    try testing.expect(r.ts.capHeight(regular, 16) > 10 and r.ts.capHeight(regular, 16) < 13);
    // Generic families resolve through fontconfig.
    _ = try r.ts.fontId(.{ .family = "sans-serif" });
}

test "freetype: ligatures toggle with OpenType features; clusters map to UTF-8" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Real = undefined;
    try r.init();
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // JetBrains Mono programming ligatures live in `calt`.
    const on = try r.shape(a, .{ .family = "JetBrains Mono" }, "a->b != c");
    const off = try r.shape(a, .{ .family = "JetBrains Mono", .features = &.{.{ .tag = "calt".*, .value = 0 }} }, "a->b != c");
    var differs = false;
    for (on.runs[0].glyphs, off.runs[0].glyphs) |x, y| differs = differs or x.id != y.id;
    try testing.expect(differs);

    // Standard `liga`: "fi" in "office" becomes fewer glyphs when enabled.
    const lig = try r.shape(a, .{ .family = "Noto Sans" }, "office");
    const nolig = try r.shape(a, .{ .family = "Noto Sans", .features = &.{.{ .tag = "liga".*, .value = 0 }} }, "office");
    try testing.expectEqual(@as(usize, 6), glyphCount(nolig));
    try testing.expect(glyphCount(lig) < 6);

    // Cluster indices are UTF-8 byte offsets.
    const multi = try r.shape(a, .{ .family = "Inter" }, "aé€b");
    const g = multi.runs[0].glyphs;
    try testing.expectEqual(@as(usize, 4), g.len);
    try testing.expectEqual(@as(usize, 0), g[0].index);
    try testing.expectEqual(@as(usize, 1), g[1].index);
    try testing.expectEqual(@as(usize, 3), g[2].index);
    try testing.expectEqual(@as(usize, 6), g[3].index);
    try testing.expect(g[1].position.x > g[0].position.x and multi.width > g[3].position.x);
}

test "freetype: emoji and CJK fall back to covering fonts" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Real = undefined;
    try r.init();
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = "hi 😀 字 ok";
    const l = try r.shape(arena.allocator(), .{ .family = "Inter" }, text);
    try testing.expect(l.runs.len >= 4);
    var saw_emoji = false;
    var saw_cjk = false;
    for (l.runs) |run_| for (run_.glyphs) |gl| {
        try testing.expect(gl.id != 0); // no .notdef
        if (gl.index == 3) {
            try testing.expect(gl.is_emoji);
            saw_emoji = true;
        }
        if (gl.index == 8) {
            try testing.expect(!gl.is_emoji);
            saw_cjk = true;
        }
    };
    try testing.expect(saw_emoji and saw_cjk);
    // ZWJ family is one emoji glyph from one cluster.
    const fam = try r.shape(arena.allocator(), .{ .family = "Inter" }, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}");
    try testing.expectEqual(@as(usize, 1), glyphCount(fam));
}

test "freetype: user fallback chain is preferred for uncovered chars" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Real = undefined;
    try r.init();
    defer r.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const jb = try r.ts.fontId(.{ .family = "JetBrains Mono" });
    const l = try r.shape(arena.allocator(), .{ .family = "Inter", .fallbacks = &.{"JetBrains Mono"} }, "a\u{2591}b");
    // U+2591 (light shade) is in JetBrains Mono but not Inter.
    try testing.expectEqual(@as(usize, 3), l.runs.len);
    try testing.expectEqual(jb, l.runs[1].font_id);
}

test "freetype: rasterization (gray, subpixel variants, LCD, color emoji)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var r: Real = undefined;
    try r.init();
    defer r.deinit();
    const id = try r.ts.fontId(.{ .family = "Inter" });
    const glyph = r.platform.vtable.glyphForChar(r.platform.ptr, id, 'H').?;
    var p: types.RenderGlyphParams = .{ .font_id = id, .glyph_id = glyph, .font_size = 16, .subpixel_variant_x = 0, .subpixel_variant_y = 0, .is_emoji = false, .subpixel_rendering = false, .scale_factor = 2 };
    const gray = try r.ts.rasterizeGlyph(testing.allocator, p);
    defer testing.allocator.free(gray.bytes);
    try testing.expect(gray.bounds.size.height >= 22 and gray.bounds.size.height <= 25);
    try testing.expect(gray.bounds.origin.y < -20);
    try testing.expectEqual(@as(usize, @intCast(gray.bounds.size.width * gray.bounds.size.height)), gray.bytes.len);
    try testing.expect(std.mem.max(u8, gray.bytes) == 255);

    p.subpixel_variant_x = 2;
    const shifted = try r.ts.rasterizeGlyph(testing.allocator, p);
    defer testing.allocator.free(shifted.bytes);
    try testing.expect(!std.mem.eql(u8, gray.bytes, shifted.bytes) or gray.bounds.size.width != shifted.bounds.size.width);

    p.subpixel_variant_x = 0;
    p.subpixel_rendering = true;
    const lcd = try r.ts.rasterizeGlyph(testing.allocator, p);
    defer testing.allocator.free(lcd.bytes);
    try testing.expectEqual(@as(usize, @intCast(lcd.bounds.size.width * lcd.bounds.size.height * 4)), lcd.bytes.len);

    // Color emoji: BGRA with non-gray pixels, scaled to the requested size.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const l = try r.shape(arena.allocator(), .{ .family = "Inter" }, "😀");
    const eg = l.runs[0].glyphs[0];
    try testing.expect(eg.is_emoji);
    const ep: types.RenderGlyphParams = .{ .font_id = l.runs[0].font_id, .glyph_id = eg.id, .font_size = 16, .subpixel_variant_x = 0, .subpixel_variant_y = 0, .is_emoji = true, .subpixel_rendering = false, .scale_factor = 1 };
    const emoji = try r.ts.rasterizeGlyph(testing.allocator, ep);
    defer testing.allocator.free(emoji.bytes);
    try testing.expect(emoji.bounds.size.width >= 14 and emoji.bounds.size.width <= 22);
    var colorful = false;
    var i: usize = 0;
    while (i < emoji.bytes.len) : (i += 4) {
        const px = emoji.bytes[i..][0..4];
        if (px[3] > 200 and (@as(i16, px[2]) - px[0] > 60)) colorful = true;
    }
    try testing.expect(colorful);
}

test "freetype: addFont registers memory fonts" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const bytes = std.Io.Dir.cwd().readFileAlloc(testing.io, "/home/user/zeron/crates/ui/assets/fonts/Geist.ttf", testing.allocator, .limited(4 << 20)) catch return error.SkipZigTest;
    defer testing.allocator.free(bytes);
    var r: Real = undefined;
    try r.init();
    defer r.deinit();
    try testing.expectError(error.FontNotFound, r.ts.platform.vtable.fontId(r.platform.ptr, .{ .family = "Geist" }));
    try r.ts.addFont(bytes);
    const id = try r.platform.vtable.fontId(r.platform.ptr, .{ .family = "Geist" });
    try testing.expect(r.platform.vtable.glyphForChar(r.platform.ptr, id, 'g') != null);
}
