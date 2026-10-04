//! Width-dependent link presentation — port of zeron
//! `markdown/link_presentation.rs` (`truncate`, `OffsetMap`, `slice_runs`).
//!
//! A web link whose label is wider than the line is cut at the longest
//! grapheme prefix that still fits with a trailing `…`. Only the PRESENTED
//! text changes: every omission is recorded as `(source range, shown range)`
//! so selection and copy map back to the source text, and link / code /
//! glyph ranges move to displayed coordinates. Pure (frame memory).

const std = @import("std");
const Allocator = std.mem.Allocator;
const TextRun = @import("zpui").text.TextRun;

pub const Range = struct { start: usize, end: usize };

/// `(source range, shown range)`; the shown span is the `…`.
pub const Omission = struct { original: Range, shown: Range };

pub const ellipsis = "\u{2026}";

/// The flattened text a presentation starts from.
pub const Flat = struct {
    text: []const u8,
    runs: []const TextRun,
    links: []const Range,
    /// One destination per link.
    urls: []const []const u8,
    code_ranges: []const Range = &.{},
    glyphs: []const Range = &.{},
};

pub const Presented = struct {
    text: []const u8,
    runs: []const TextRun,
    links: []const Range,
    code_ranges: []const Range,
    glyphs: []const Range,
    omissions: []const Omission,
};

/// `transcript_address(..).is_ok()` for presentation purposes: an explicit
/// http(s) URL with an authority, no controls / whitespace / backslashes,
/// well-formed escapes and no credentials.
pub fn isWebTarget(url: []const u8) bool {
    const rest = if (std.ascii.startsWithIgnoreCase(url, "https://"))
        url["https://".len..]
    else if (std.ascii.startsWithIgnoreCase(url, "http://"))
        url["http://".len..]
    else
        return false;
    if (rest.len == 0 or rest[0] == '/' or rest[0] == '?' or rest[0] == '#') return false;
    for (url, 0..) |c, i| {
        if (c < 0x20 or c == 0x7f or c == ' ' or c == '\\') return false;
        if (c == '%') {
            if (i + 2 >= url.len or !std.ascii.isHex(url[i + 1]) or !std.ascii.isHex(url[i + 2])) return false;
        }
    }
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    if (std.mem.indexOfScalar(u8, rest[0..authority_end], '@') != null) return false;
    return true;
}

/// `slice_runs`: the runs covering `[start, end)`, trimmed to it.
pub fn sliceRuns(a: Allocator, runs: []const TextRun, start: usize, end: usize) Allocator.Error![]TextRun {
    var out: std.ArrayList(TextRun) = .empty;
    var at: usize = 0;
    for (runs) |run| {
        const s = at;
        at += run.len;
        const lo = @max(s, start);
        const hi = @min(at, end);
        if (hi > lo) {
            var r = run;
            r.len = hi - lo;
            try out.append(a, r);
        }
    }
    return out.items;
}

fn runAt(runs: []const TextRun, offset: usize) ?TextRun {
    var at: usize = 0;
    for (runs) |run| {
        if (offset < at + run.len) return run;
        at += run.len;
    }
    return null;
}

/// Start offsets of the label's extended grapheme clusters (approximated:
/// combining marks, joiners, variation selectors and the joined code point
/// stay with their base).
fn graphemeStarts(a: Allocator, label: []const u8) Allocator.Error![]usize {
    var out: std.ArrayList(usize) = .empty;
    var it = std.unicode.Utf8View.initUnchecked(label).iterator();
    var prev_zwj = false;
    while (true) {
        const at = it.i;
        const cp = it.nextCodepoint() orelse break;
        const extend = cp == 0x200D or (cp >= 0x300 and cp <= 0x36F) or (cp >= 0xFE00 and cp <= 0xFE0F) or
            (cp >= 0x1F3FB and cp <= 0x1F3FF) or (cp >= 0xE0020 and cp <= 0xE007F);
        if (!(extend or prev_zwj) or out.items.len == 0) try out.append(a, at);
        prev_zwj = cp == 0x200D;
    }
    return out.items;
}

/// Source offset for a shown offset (`OffsetMap::local_original`).
pub fn originalOffset(omissions: []const Omission, displayed: usize) usize {
    var shift: isize = 0;
    for (omissions) |o| {
        if (displayed < o.shown.start) break;
        if (displayed < o.shown.end) return o.original.start;
        shift = @as(isize, @intCast(o.original.end)) - @as(isize, @intCast(o.shown.end));
    }
    return @intCast(@as(isize, @intCast(displayed)) + shift);
}

/// Shown offset for a source offset (`OffsetMap::local_displayed`).
pub fn displayedOffset(omissions: []const Omission, original: usize) usize {
    var shift: isize = 0;
    for (omissions) |o| {
        if (original < o.original.start) break;
        if (original < o.original.end) return o.shown.start;
        shift = @as(isize, @intCast(o.original.end)) - @as(isize, @intCast(o.shown.end));
    }
    return @intCast(@max(@as(isize, @intCast(original)) - shift, 0));
}

/// Shown range for a source range: one overlapping a replaced span expands
/// to cover the replacement (`local_displayed_range`).
pub fn displayedRange(omissions: []const Omission, r: Range) Range {
    var out: Range = .{ .start = displayedOffset(omissions, r.start), .end = displayedOffset(omissions, r.end) };
    for (omissions) |o| if (r.start < o.original.end and r.end > o.original.start) {
        out.start = @min(out.start, o.shown.start);
        out.end = @max(out.end, o.shown.end);
    };
    return out;
}

/// `truncate`: present `flat` for `width`. `measurer.width(text, runs)` is
/// the shaped single-line width.
pub fn truncate(a: Allocator, flat: Flat, width: f32, measurer: anytype) Presented {
    return truncateImpl(a, flat, width, measurer) catch .{
        .text = flat.text,
        .runs = flat.runs,
        .links = flat.links,
        .code_ranges = flat.code_ranges,
        .glyphs = flat.glyphs,
        .omissions = &.{},
    };
}

fn truncateImpl(a: Allocator, flat: Flat, width: f32, measurer: anytype) Allocator.Error!Presented {
    var cuts: std.ArrayList(Range) = .empty;
    for (flat.links, 0..) |range, li| {
        if (li >= flat.urls.len or !isWebTarget(flat.urls[li])) continue;
        const label = flat.text[range.start..range.end];
        const runs = try sliceRuns(a, flat.runs, range.start, range.end);
        if (measurer.width(label, runs) <= width) continue;
        const boundaries = try graphemeStarts(a, label);
        var low: usize = 0;
        var high: usize = boundaries.len;
        while (low < high) {
            const middle = (low + high) / 2;
            const end = boundaries[middle];
            const text = try std.mem.concat(a, u8, &.{ label[0..end], ellipsis });
            var crun: std.ArrayList(TextRun) = .fromOwnedSlice(try sliceRuns(a, runs, 0, end));
            var e = runAt(flat.runs, range.start + end) orelse runs[runs.len - 1];
            e.len = ellipsis.len;
            try crun.append(a, e);
            if (measurer.width(text, crun.items) <= width) low = middle + 1 else high = middle;
        }
        const prefix = boundaries[low -| 1];
        // Never make a short label longer just to show an ellipsis.
        if (range.end - (range.start + prefix) > ellipsis.len) try cuts.append(a, .{ .start = range.start + prefix, .end = range.end });
    }
    if (cuts.items.len == 0) return .{
        .text = flat.text,
        .runs = flat.runs,
        .links = flat.links,
        .code_ranges = flat.code_ranges,
        .glyphs = flat.glyphs,
        .omissions = &.{},
    };
    var text: std.ArrayList(u8) = .empty;
    var runs: std.ArrayList(TextRun) = .empty;
    var omissions: std.ArrayList(Omission) = .empty;
    var at: usize = 0;
    for (cuts.items) |cut| {
        try text.appendSlice(a, flat.text[at..cut.start]);
        try runs.appendSlice(a, try sliceRuns(a, flat.runs, at, cut.start));
        const start = text.items.len;
        try text.appendSlice(a, ellipsis);
        var style = runAt(flat.runs, cut.start) orelse flat.runs[flat.runs.len - 1];
        style.len = ellipsis.len;
        try runs.append(a, style);
        at = cut.end;
        try omissions.append(a, .{ .original = cut, .shown = .{ .start = start, .end = text.items.len } });
    }
    try text.appendSlice(a, flat.text[at..]);
    try runs.appendSlice(a, try sliceRuns(a, flat.runs, at, flat.text.len));
    const om = omissions.items;
    const mapAll = struct {
        fn f(alloc: Allocator, o: []const Omission, rs: []const Range) Allocator.Error![]const Range {
            const out = try alloc.alloc(Range, rs.len);
            for (rs, out) |r, *d| d.* = displayedRange(o, r);
            return out;
        }
    }.f;
    return .{
        .text = text.items,
        .runs = runs.items,
        .links = try mapAll(a, om, flat.links),
        .code_ranges = try mapAll(a, om, flat.code_ranges),
        .glyphs = try mapAll(a, om, flat.glyphs),
        .omissions = om,
    };
}

/// A presentation copied into element state (survives into prepaint/paint).
pub const Owned = struct {
    text: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(TextRun) = .empty,
    code_ranges: std.ArrayList(Range) = .empty,
    glyphs: std.ArrayList(Range) = .empty,
    omissions: std.ArrayList(Omission) = .empty,

    pub fn clear(self: *Owned) void {
        self.text.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        self.code_ranges.clearRetainingCapacity();
        self.glyphs.clearRetainingCapacity();
        self.omissions.clearRetainingCapacity();
    }

    pub fn set(self: *Owned, gpa: Allocator, p: Presented) Allocator.Error!void {
        self.clear();
        try self.text.appendSlice(gpa, p.text);
        try self.runs.appendSlice(gpa, p.runs);
        try self.code_ranges.appendSlice(gpa, p.code_ranges);
        try self.glyphs.appendSlice(gpa, p.glyphs);
        try self.omissions.appendSlice(gpa, p.omissions);
    }

    pub fn deinit(self: *Owned, gpa: Allocator) void {
        self.text.deinit(gpa);
        self.runs.deinit(gpa);
        self.code_ranges.deinit(gpa);
        self.glyphs.deinit(gpa);
        self.omissions.deinit(gpa);
    }
};

// ---------------------------------------------------------------------------
// Tests (link_presentation.rs, with the grapheme-count measure)
// ---------------------------------------------------------------------------

const testing = std.testing;

const Graphemes = struct {
    pub fn width(_: Graphemes, text: []const u8, _: []const TextRun) f32 {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        return @floatFromInt((graphemeStarts(arena.allocator(), text) catch unreachable).len);
    }
};

fn linkFlat(a: Allocator, parts: []const struct { []const u8, ?[]const u8 }) !Flat {
    var text: std.ArrayList(u8) = .empty;
    var runs: std.ArrayList(TextRun) = .empty;
    var links: std.ArrayList(Range) = .empty;
    var urls: std.ArrayList([]const u8) = .empty;
    for (parts) |p| {
        const s = text.items.len;
        try text.appendSlice(a, p[0]);
        try runs.append(a, .{ .len = p[0].len, .font = .{ .family = "Test" }, .color = .{ .h = 0, .s = 0, .l = 1, .a = 1 } });
        if (p[1]) |u| {
            try links.append(a, .{ .start = s, .end = text.items.len });
            try urls.append(a, u);
        }
    }
    return .{ .text = text.items, .runs = runs.items, .links = links.items, .urls = urls.items };
}

fn totalLen(runs: []const TextRun) usize {
    var n: usize = 0;
    for (runs) |r| n += r.len;
    return n;
}

test "truncation preserves graphemes, destinations and source selection" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const label = "https://example.com/á🙂👨‍👩‍👧‍👦界/very/long/path";
    const flat = try linkFlat(a, &.{.{ label, "https://example.com/destination" }});
    for ([_]f32{ 1, 12, 25, 32 }) |w| {
        const shown = truncate(a, flat, w, Graphemes{});
        try testing.expect(Graphemes.width(.{}, shown.text, &.{}) <= w);
        try testing.expectEqual(label.len, originalOffset(shown.omissions, shown.text.len));
        try testing.expectEqual(shown.text.len, totalLen(shown.runs));
        var it = std.unicode.Utf8View.initUnchecked(shown.text).iterator();
        while (true) {
            const i = it.i;
            if (it.nextCodepointSlice() == null) break;
            const o = originalOffset(shown.omissions, i);
            try testing.expect(o == label.len or label[o] & 0xC0 != 0x80);
        }
    }
    try testing.expect(std.mem.startsWith(u8, truncate(a, flat, 25, Graphemes{}).text, "https://example.com/"));
}

test "partial copies map back to the source" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "https://example.com/abcdefghijklmnopqrstuvwxyz";
    const flat = try linkFlat(a, &.{ .{ source, "https://example.com/destination" }, .{ " between ", null }, .{ "https://second.example/long/path/to/resource", "https://example.com/destination" } });
    const shown = truncate(a, flat, 24, Graphemes{});
    try testing.expectEqual(@as(usize, 2), shown.omissions.len);
    const first = shown.links[0];
    try testing.expectEqualStrings(source, flat.text[originalOffset(shown.omissions, first.start)..originalOffset(shown.omissions, first.end)]);
    try testing.expectEqualStrings("https", flat.text[originalOffset(shown.omissions, 0)..originalOffset(shown.omissions, 5)]);
    const o = shown.omissions[0];
    try testing.expectEqual(o.shown, displayedRange(shown.omissions, .{ .start = o.original.start + 1, .end = o.original.end - 1 }));
}

test "widening recomputes without stale offsets; non-web links keep their shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const flat = try linkFlat(a, &.{.{ "https://example.com/a/long/link", "https://example.com/destination" }});
    const narrow = truncate(a, flat, 15, Graphemes{});
    try testing.expect(std.mem.endsWith(u8, narrow.text, ellipsis));
    const wide = truncate(a, flat, 1000, Graphemes{});
    try testing.expectEqualStrings(flat.text, wide.text);
    try testing.expectEqual(@as(usize, 0), wide.omissions.len);
    const file = try linkFlat(a, &.{.{ "src/some/very/long/path/to/a/file.rs", "src/some/very/long/path/to/a/file.rs" }});
    try testing.expectEqual(@as(usize, 0), truncate(a, file, 5, Graphemes{}).omissions.len);
    try testing.expect(isWebTarget("HTTPS://EXAMPLE.COM"));
    for ([_][]const u8{ "javascript:alert(1)", "mailto:a@b.com", "https://user:pass@example.com", "https://example.com/\npath", "https://", "example.com", "https:///path", "https://example.com/%GG" }) |u|
        try testing.expect(!isWebTarget(u));
}
