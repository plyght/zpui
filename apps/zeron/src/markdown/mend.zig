//! Mends half-streamed inline markdown for display — port of
//! `zeron_markdown::mend` (after streamdown's `remend`).
//!
//! While a block streams, an unclosed `**bold`, `*em`, `` `code ``,
//! `~~strike` or `[link](partial-url` parses as literal text; appending
//! synthetic closers to the *display* parse keeps styling stable from the
//! moment content follows an opener. Only the display tree sees mended text;
//! the canonical tree settles honestly on completion.
//!
//! Repairs: emphasis parity (innermost-first nested closers, half-streamed
//! closers completed), inline-code backtick parity, links/images mended to
//! `[text](zeron:pending-link)` so the URL never renders, and a zero-width
//! space after a trailing `-`/`--`/`=`/`==` line so a streaming list item is
//! never misread as a setext underline.

const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("cmark/unicode.zig");

/// Sentinel destination for a link whose URL is still streaming. The
/// renderer styles it like any link but must not register it as clickable.
pub const PENDING_LINK_URL = "zeron:pending-link";

const OpenDelim = struct {
    ch: u21,
    len: usize,
    /// Char index just past the run.
    pos: usize,
};

const Ch = struct { byte: usize, c: u21 };

/// Repair hanging inline markers in a streaming block's source. Returns
/// null when the text needs no repair; otherwise an owned string.
pub fn closeHanging(gpa: Allocator, text: []const u8) Allocator.Error!?[]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var cs_list: std.ArrayList(Ch) = .empty;
    {
        var i: usize = 0;
        while (i < text.len) {
            const d = unicode.decodeFirst(text[i..]).?;
            try cs_list.append(a, .{ .byte = i, .c = d.cp });
            i += d.len;
        }
    }
    const cs = cs_list.items;
    const n = cs.len;

    var delims: std.ArrayList(OpenDelim) = .empty;
    var brackets: std.ArrayList(usize) = .empty;
    var code: ?struct { usize, usize } = null;
    var last_content: ?usize = null;
    var pending_url: ?usize = null;

    var i: usize = 0;
    while (i < n) {
        const c = cs[i].c;
        if (code == null and c == '\\') {
            if (i + 1 < n) last_content = i + 1;
            i += 2;
            continue;
        }
        if (c == '`') {
            const run = runLen(cs, i);
            if (code) |cd| {
                if (run == cd[0]) code = null else last_content = i + run - 1;
            } else {
                code = .{ run, i + run };
            }
            i += run;
            continue;
        }
        if (code != null) {
            last_content = i;
            i += 1;
            continue;
        }
        switch (c) {
            '*', '_', '~' => {
                const run = runLen(cs, i);
                try delim(a, &delims, cs, c, run, i, &last_content);
                i += run;
            },
            '[' => {
                try brackets.append(a, i);
                i += 1;
            },
            ']' => {
                if (brackets.pop()) |open| {
                    // Emphasis opened inside a completed `[…]` stays literal.
                    var k: usize = 0;
                    for (delims.items) |d| {
                        if (d.pos < open) {
                            delims.items[k] = d;
                            k += 1;
                        }
                    }
                    delims.shrinkRetainingCapacity(k);
                    if (i + 1 < n and cs[i + 1].c == '(') {
                        var j = i + 2;
                        var depth: usize = 0;
                        while (true) {
                            if (j >= n) {
                                pending_url = i;
                                break;
                            }
                            const cj = cs[j].c;
                            if (cj == '(') {
                                depth += 1;
                            } else if (cj == ')') {
                                if (depth == 0) break;
                                depth -= 1;
                            }
                            j += 1;
                        }
                        if (pending_url != null) break;
                        last_content = j;
                        i = j + 1;
                        continue;
                    }
                }
                last_content = i;
                i += 1;
            },
            else => {
                if (!unicode.isWhitespace(c)) last_content = i;
                i += 1;
            },
        }
    }

    // Text ends inside a link/image URL: drop the partial URL, keep the text.
    if (pending_url) |close| {
        const byte = cs[close].byte;
        return try std.mem.concat(gpa, u8, &.{ text[0..byte], "](" ++ PENDING_LINK_URL ++ ")" });
    }

    const Pending = struct { pos: usize, s: []const u8 };
    var pending: std.ArrayList(Pending) = .empty;
    if (code) |cd| {
        if (last_content) |lc| if (lc >= cd[1]) {
            try pending.append(a, .{ .pos = cd[1], .s = try repeatChar(a, '`', cd[0]) });
        };
    }
    for (delims.items) |d| {
        if (last_content) |lc| if (lc >= d.pos) {
            try pending.append(a, .{ .pos = d.pos, .s = try repeatChar(a, d.ch, d.len) });
        };
    }
    if (brackets.items.len > 0) {
        const open = brackets.items[brackets.items.len - 1];
        if (last_content) |lc| if (lc > open) {
            try pending.append(a, .{ .pos = open, .s = "](" ++ PENDING_LINK_URL ++ ")" });
        };
    }
    // Stable sort by descending position (sort_by_key(Reverse) is stable).
    std.sort.insertion(Pending, pending.items, {}, struct {
        fn lt(_: void, x: Pending, y: Pending) bool {
            return x.pos > y.pos;
        }
    }.lt);
    var closers: std.ArrayList(u8) = .empty;
    for (pending.items) |p| try closers.appendSlice(a, p.s);

    const setext = setextPartial(text);

    if (closers.items.len == 0 and !setext) return null;
    const zwsp = "\u{200B}";
    if (setext) {
        const nl = std.mem.lastIndexOfScalar(u8, text, '\n');
        if (nl != null and closers.items.len != 0) {
            return try std.mem.concat(gpa, u8, &.{ text[0..nl.?], closers.items, text[nl.?..], zwsp });
        }
        return try std.mem.concat(gpa, u8, &.{ text, zwsp });
    }
    // Insert before trailing whitespace: a closer after a trailing space is
    // not right-flanking and would not close.
    const end = unicode.trimEnd(text).len;
    return try std.mem.concat(gpa, u8, &.{ text[0..end], closers.items, text[end..] });
}

fn repeatChar(a: Allocator, c: u21, count: usize) Allocator.Error![]const u8 {
    var buf: [4]u8 = undefined;
    const l = std.unicode.utf8Encode(c, &buf) catch unreachable;
    const out = try a.alloc(u8, l * count);
    for (0..count) |k| @memcpy(out[k * l .. (k + 1) * l], buf[0..l]);
    return out;
}

fn runLen(cs: []const Ch, i: usize) usize {
    const c = cs[i].c;
    var k = i;
    while (k < cs.len and cs[k].c == c) k += 1;
    return k - i;
}

/// Match or open one delimiter run.
fn delim(a: Allocator, delims: *std.ArrayList(OpenDelim), cs: []const Ch, c: u21, run: usize, i: usize, last_content: *?usize) Allocator.Error!void {
    const end = i + run;
    // GFM strikethrough is `~~` only; longer tilde runs are literal.
    if (c == '~' and run > 2) {
        last_content.* = end - 1;
        return;
    }
    const prev: ?u21 = if (i > 0) cs[i - 1].c else null;
    const next: ?u21 = if (end < cs.len) cs[end].c else null;
    const prev_word = if (prev) |p| unicode.isAlphanumeric(p) else false;
    const next_word = if (next) |x| unicode.isAlphanumeric(x) else false;
    if (prev_word and next_word and (c == '_' or (c == '*' and run == 1))) {
        last_content.* = end - 1;
        return;
    }
    const can_close = if (prev) |p| !unicode.isWhitespace(p) else false;
    const can_open = if (next) |x| !unicode.isWhitespace(x) else false;
    var rest = run;
    if (can_close) {
        var k_opt: ?usize = null;
        var k = delims.items.len;
        while (k > 0) {
            k -= 1;
            if (delims.items[k].ch == c) {
                k_opt = k;
                break;
            }
        }
        if (k_opt) |kk| {
            const take = @min(rest, delims.items[kk].len);
            delims.items[kk].len -= take;
            rest -= take;
            const keep = if (delims.items[kk].len == 0) kk else kk + 1;
            delims.shrinkRetainingCapacity(keep);
        }
    }
    if (rest > 0) {
        if (can_open and (c != '~' or rest == 2)) {
            try delims.append(a, .{ .ch = c, .len = rest, .pos = end });
        } else {
            last_content.* = end - 1;
        }
    }
}

/// Last line is only 1–2 `-` or `=` under a non-empty line.
fn setextPartial(text: []const u8) bool {
    const nl = std.mem.lastIndexOfScalar(u8, text, '\n') orelse return false;
    const trimmed = unicode.trimStart(text[nl + 1 ..]);
    const underline = struct {
        fn f(t: []const u8, c: u8) bool {
            if (t.len == 0 or t.len > 2) return false;
            for (t) |x| if (x != c) return false;
            return true;
        }
    }.f;
    if (!(underline(trimmed, '-') or underline(trimmed, '='))) return false;
    var last_line: ?[]const u8 = null;
    var it = unicode.LineIter{ .s = text[0..nl] };
    while (it.next()) |l| last_line = l;
    const l = last_line orelse return false;
    return unicode.trim(l).len != 0;
}

// ---------------------------------------------------------------------------
// Tests (ported from mend.rs)
// ---------------------------------------------------------------------------

fn expectMends(input: []const u8, expected: []const u8) !void {
    const got = (try closeHanging(std.testing.allocator, input)) orelse {
        std.debug.print("expected mend for {s}\n", .{input});
        return error.TestExpectedEqual;
    };
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

fn expectStays(input: []const u8) !void {
    const got = try closeHanging(std.testing.allocator, input);
    if (got) |g| {
        defer std.testing.allocator.free(g);
        std.debug.print("unexpected mend for {s}: {s}\n", .{ input, g });
        return error.TestExpectedEqual;
    }
}

test "mend: balanced text needs nothing" {
    try expectStays("plain words, no markers");
    try expectStays("a **b** and *c* and `d` and ~~e~~");
    try expectStays("[docs](https://x.dev) done");
    try expectStays("");
}

test "mend: bold and italic close" {
    try expectMends("**bold", "**bold**");
    try expectMends("some *em", "some *em*");
    try expectMends("a __b", "a __b__");
    try expectMends("a _b", "a _b_");
    try expectMends("***both", "***both***");
}

test "mend: half streamed closers complete" {
    try expectMends("**bold*", "**bold**");
    try expectMends("__b_", "__b__");
    try expectMends("~~gone~", "~~gone~~");
}

test "mend: nested closers innermost first" {
    try expectMends("**a *b", "**a *b***");
    try expectMends("*a **b", "*a **b***");
    try expectMends("_a **b", "_a **b**_");
}

test "mend: bare openers stay literal" {
    try expectStays("**");
    try expectStays("text **");
    try expectStays("text ** ");
    try expectStays("*");
    try expectStays("~~");
    try expectStays("`");
}

test "mend: closers before trailing whitespace" {
    try expectMends("**bold ", "**bold** ");
    try expectMends("*em\n", "*em*\n");
}

test "mend: intraword and escapes literal" {
    try expectStays("2*3 equals 6");
    try expectStays("snake_case_name");
    try expectStays("20~25 degrees");
    try expectStays("\\*not emphasis");
    try expectStays("a \\** b");
}

test "mend: list markers are not openers" {
    try expectStays("* item one");
    try expectStays("- a\n* b");
}

test "mend: strikethrough" {
    try expectMends("~~gone", "~~gone~~");
    try expectStays("~single~x");
}

test "mend: inline code" {
    try expectMends("`code", "`code`");
    try expectMends("call `a ** b", "call `a ** b`");
    try expectMends("``a`", "``a```");
    try expectStays("`done` after");
}

test "mend: links" {
    try expectMends("[docs](https://x.dev/lo", "[docs](zeron:pending-link)");
    try expectMends("[docs](", "[docs](zeron:pending-link)");
    try expectMends("see [do", "see [do](zeron:pending-link)");
    try expectMends("![alt](https://x/i.p", "![alt](zeron:pending-link)");
    try expectStays("see [");
    try expectStays("[x] task-like");
    try expectStays("[a](https://x.dev/(y)) done");
    try expectMends("[a](https://x.dev/(y", "[a](zeron:pending-link)");
    try expectMends("[**a", "[**a**](zeron:pending-link)");
    try expectMends("**a [b", "**a [b](zeron:pending-link)**");
    try expectStays("[**a] done");
}

test "mend: setext partials" {
    try expectMends("para\n-", "para\n-\u{200B}");
    try expectMends("para\n--", "para\n--\u{200B}");
    try expectMends("para\n=", "para\n=\u{200B}");
    try expectStays("para\n---");
    try expectStays("-");
    try expectStays("\n-");
    try expectMends("**b\n-", "**b**\n-\u{200B}");
}
