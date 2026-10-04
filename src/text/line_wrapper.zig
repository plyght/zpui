//! Width-based line wrapping and truncation (gpui `text_system/line_wrapper.rs`,
//! including zui's rule that keeps closing punctuation attached to its word).

const std = @import("std");
const types = @import("types.zig");
const fallback = @import("fallback.zig");
const text_system_mod = @import("text_system.zig");

const Allocator = std.mem.Allocator;
const Pixels = types.Pixels;
const FontId = types.FontId;
const TextRun = types.TextRun;

pub const TruncateFrom = enum { start, end, middle };

/// A soft-wrap point: wrap before UTF-8 index `ix`, indenting the next line by `next_indent` spaces.
pub const Boundary = struct {
    ix: usize,
    next_indent: u32,
};

/// A piece of a line: text, or an inline element of fixed width occupying `len_utf8` bytes.
pub const LineFragment = union(enum) {
    text: []const u8,
    element: struct { width: Pixels, len_utf8: usize },

    pub fn txt(s: []const u8) LineFragment {
        return .{ .text = s };
    }
    pub fn elem(width: Pixels, len_utf8: usize) LineFragment {
        return .{ .element = .{ .width = width, .len_utf8 = len_utf8 } };
    }
};

/// Characters that never start a wrap opportunity inside a word (gpui `is_word_char`).
pub fn isWordChar(c: u21) bool {
    return switch (c) {
        '0'...'9', 'a'...'z', 'A'...'Z' => true,
        // Latin-1 Supplement, Latin Extended-A/B, Cyrillic
        0x00C0...0x00FF, 0x0100...0x017F, 0x0180...0x024F, 0x0400...0x04FF => true,
        // Vietnamese: Latin Extended Additional + combining diacritics
        0x1E00...0x1EFF, 0x0300...0x036F => true,
        // Bengali
        0x0980...0x09FF => true,
        // Joiners such as `a-b`, `var_name`, `I'm`, `@mention`, `100%`, `3.14`, and trailing `,.:;`.
        '-', '_', '.', '\'', 0x2019, 0x2018, '$', '%', '@', '#', '^', '~', ',', '=', ':', ';' => true,
        // `⋯`
        0x22EF => true,
        // Non-breaking glue
        0x202F, 0x00A0, 0x2011 => true,
        else => false,
    };
}

/// Per-(font, size) wrapper with a character width cache. Obtain one from
/// `TextSystem.lineWrapper` and return it with `TextSystem.releaseLineWrapper`.
pub const LineWrapper = struct {
    text_system: *text_system_mod.TextSystem,
    font_id: FontId,
    font_size: Pixels,
    cached_ascii_char_widths: [128]?Pixels = @splat(null),
    cached_other_char_widths: std.AutoHashMapUnmanaged(u21, Pixels) = .empty,

    pub const max_indent: u32 = 256;

    pub fn init(text_system: *text_system_mod.TextSystem, font_id: FontId, font_size: Pixels) LineWrapper {
        return .{ .text_system = text_system, .font_id = font_id, .font_size = font_size };
    }

    pub fn deinit(self: *LineWrapper) void {
        self.cached_other_char_widths.deinit(self.text_system.gpa);
    }

    /// Shaped advance of a single character (cached).
    pub fn widthForChar(self: *LineWrapper, c: u21) Pixels {
        if (c < 128) {
            if (self.cached_ascii_char_widths[c]) |w| return w;
            const w = self.text_system.layoutWidth(self.font_id, self.font_size, c);
            self.cached_ascii_char_widths[c] = w;
            return w;
        }
        if (self.cached_other_char_widths.get(c)) |w| return w;
        const w = self.text_system.layoutWidth(self.font_id, self.font_size, c);
        self.cached_other_char_widths.put(self.text_system.gpa, c, w) catch {};
        return w;
    }

    fn widthForStr(self: *LineWrapper, s: []const u8) Pixels {
        var w: Pixels = 0;
        var it = CharIter{ .s = s };
        while (it.next()) |c| w += self.widthForChar(c.cp);
        return w;
    }

    /// gpui `wrap_line`: soft-wrap boundaries for `fragments` at `wrap_width`.
    /// Caller owns the returned slice.
    pub fn wrapLine(self: *LineWrapper, gpa: Allocator, fragments: []const LineFragment, wrap_width: Pixels) ![]Boundary {
        var out: std.ArrayList(Boundary) = .empty;
        errdefer out.deinit(gpa);

        var width: Pixels = 0;
        var first_non_whitespace_ix: ?usize = null;
        var indent: ?u32 = null;
        var last_candidate_ix: usize = 0;
        var last_candidate_width: Pixels = 0;
        var last_wrap_ix: usize = 0;
        var prev_c: u21 = 0;
        var index: usize = 0;

        for (fragments) |fragment| {
            var it = CharIter{ .s = switch (fragment) {
                .text => |t| t,
                .element => "\x00",
            } };
            while (it.next()) |ch| {
                const ix = index;
                var new_prev_c = prev_c;
                var item_width: Pixels = undefined;
                switch (fragment) {
                    .text => {
                        const c = ch.cp;
                        index += ch.len;
                        if (c == '\n') continue;
                        if (isWordChar(c)) {
                            if (prev_c == ' ' and c != ' ' and first_non_whitespace_ix != null) {
                                last_candidate_ix = ix;
                                last_candidate_width = width;
                            }
                        } else if (c != ' ' and !isWordChar(prev_c) and first_non_whitespace_ix != null) {
                            // CJK breaks anywhere, but a non-word char right after a word
                            // char is closing punctuation and stays with the word.
                            last_candidate_ix = ix;
                            last_candidate_width = width;
                        }
                        if (c != ' ' and first_non_whitespace_ix == null) first_non_whitespace_ix = ix;
                        new_prev_c = c;
                        item_width = self.widthForChar(c);
                    },
                    .element => |e| {
                        index += e.len_utf8;
                        if (prev_c == ' ' and first_non_whitespace_ix != null) {
                            last_candidate_ix = ix;
                            last_candidate_width = width;
                        }
                        if (first_non_whitespace_ix == null) first_non_whitespace_ix = ix;
                        item_width = e.width;
                    },
                }

                width += item_width;
                if (width > wrap_width and ix > last_wrap_ix) {
                    if (indent == null) {
                        if (first_non_whitespace_ix) |f| indent = @min(max_indent, @as(u32, @intCast(f - last_wrap_ix)));
                    }
                    if (last_candidate_ix > 0) {
                        last_wrap_ix = last_candidate_ix;
                        width -= last_candidate_width;
                        last_candidate_ix = 0;
                    } else {
                        last_wrap_ix = ix;
                        width = item_width;
                    }
                    if (indent) |n| width += self.widthForChar(' ') * @as(Pixels, @floatFromInt(n));
                    try out.append(gpa, .{ .ix = last_wrap_ix, .next_indent = indent orelse 0 });
                }
                prev_c = new_prev_c;
            }
        }
        return out.toOwnedSlice(gpa);
    }

    /// Byte index at which to cut `line` so that it plus `affix` fits `truncate_width`, or null if it fits.
    pub fn shouldTruncateLine(self: *LineWrapper, line: []const u8, truncate_width: Pixels, affix: []const u8, from: TruncateFrom) ?usize {
        var width: Pixels = 0;
        const suffix_width = self.widthForStr(affix);
        var truncate_ix: usize = 0;
        switch (from) {
            .end => {
                var it = CharIter{ .s = line };
                while (it.next()) |c| {
                    if (width + suffix_width < truncate_width) truncate_ix = c.ix;
                    width += self.widthForChar(c.cp);
                    if (@floor(width) > truncate_width) return truncate_ix;
                }
            },
            .start => {
                var ix = line.len;
                while (ix > 0) {
                    ix -= 1;
                    while (ix > 0 and (line[ix] & 0xC0) == 0x80) ix -= 1;
                    if (width + suffix_width < truncate_width) truncate_ix = ix;
                    width += self.widthForChar(fallback.decodeAt(line, ix).cp);
                    if (@floor(width) > truncate_width) return truncate_ix;
                }
            },
            .middle => {},
        }
        return null;
    }

    fn shouldTruncateLineMiddle(self: *LineWrapper, line: []const u8, truncate_width: Pixels, affix: []const u8) ?[2]usize {
        const suffix_width = self.widthForStr(affix);
        if (self.widthForStr(line) <= truncate_width) return null;
        const budget = truncate_width - suffix_width;
        if (budget <= 0) return .{ 0, line.len };
        const front_budget = budget * (2.0 / 3.0);
        const back_budget = budget - front_budget;

        var front_width: Pixels = 0;
        var front_end: usize = 0;
        var it = CharIter{ .s = line };
        while (it.next()) |c| {
            const w = self.widthForChar(c.cp);
            if (front_width + w > front_budget) break;
            front_width += w;
            front_end = c.ix + c.len;
        }
        var back_width: Pixels = 0;
        var back_start = line.len;
        var ix = line.len;
        while (ix > 0) {
            ix -= 1;
            while (ix > 0 and (line[ix] & 0xC0) == 0x80) ix -= 1;
            const w = self.widthForChar(fallback.decodeAt(line, ix).cp);
            if (back_width + w > back_budget) break;
            back_width += w;
            back_start = ix;
        }
        if (front_end >= back_start) return .{ 0, line.len };
        return .{ front_end, back_start };
    }

    /// Truncated text and runs, owned by the allocator passed to `truncateLine`.
    pub const Truncated = struct {
        text: []u8,
        runs: []TextRun,

        pub fn deinit(self: Truncated, gpa: Allocator) void {
            gpa.free(self.text);
            gpa.free(self.runs);
        }
    };

    /// gpui `truncate_line`: shorten `line` with `affix` (e.g. "…") to fit `truncate_width`.
    /// Returns null when no truncation is needed.
    pub fn truncateLine(self: *LineWrapper, gpa: Allocator, line: []const u8, truncate_width: Pixels, affix: []const u8, runs: []const TextRun, from: TruncateFrom) !?Truncated {
        if (from == .middle) {
            const cut = self.shouldTruncateLineMiddle(line, truncate_width, affix) orelse return null;
            const text = try std.mem.concat(gpa, u8, &.{ line[0..cut[0]], affix, line[cut[1]..] });
            errdefer gpa.free(text);
            return .{ .text = text, .runs = try runsAfterMiddleTruncation(gpa, affix, runs, cut[0], cut[1]) };
        }
        const truncate_ix = self.shouldTruncateLine(line, truncate_width, affix, from) orelse return null;
        const text = switch (from) {
            .start => blk: {
                var cut = @min(truncate_ix + 1, line.len);
                while (cut < line.len and (line[cut] & 0xC0) == 0x80) cut += 1;
                break :blk try std.mem.concat(gpa, u8, &.{ affix, line[cut..] });
            },
            .end => try std.mem.concat(gpa, u8, &.{ trimEndWhitespacePunct(line[0..truncate_ix]), affix }),
            .middle => unreachable,
        };
        errdefer gpa.free(text);
        return .{ .text = text, .runs = try runsAfterTruncation(gpa, text, affix, runs, from) };
    }

    /// gpui `truncate_wrapped_line`: truncate so the text fits `max_lines` lines of `wrap_width`.
    pub fn truncateWrappedLine(self: *LineWrapper, gpa: Allocator, text: []const u8, wrap_width: Pixels, max_lines: usize, affix: []const u8, runs: []const TextRun, from: TruncateFrom) !?Truncated {
        if (max_lines <= 1 or from == .start)
            return self.truncateLine(gpa, text, wrap_width * @as(Pixels, @floatFromInt(max_lines)), affix, runs, from);
        if (from == .middle) return self.truncateLine(gpa, text, wrap_width, affix, runs, from);

        const affix_width = self.widthForStr(affix);
        var width: Pixels = 0;
        var line: usize = 0;
        var first_non_whitespace_ix: ?usize = null;
        var last_candidate_ix: usize = 0;
        var last_candidate_width: Pixels = 0;
        var last_wrap_ix: usize = 0;
        var prev_c: u21 = 0;
        var indent: ?u32 = null;
        var truncate_ix: usize = 0;

        var it = CharIter{ .s = text };
        while (it.next()) |ch| {
            const ix = ch.ix;
            const c = ch.cp;
            if (c == '\n') {
                if (line >= max_lines - 1 and std.mem.trim(u8, text[ix + 1 ..], " \t\r\n").len != 0) {
                    return try self.finishEndTruncation(gpa, text[0..truncate_ix], affix, runs);
                }
                line += 1;
                width = 0;
                first_non_whitespace_ix = null;
                last_candidate_ix = 0;
                last_candidate_width = 0;
                last_wrap_ix = ix + 1;
                prev_c = 0;
                indent = null;
                truncate_ix = ix + 1;
                continue;
            }
            const char_width = self.widthForChar(c);
            if (isWordChar(c)) {
                if (prev_c == ' ' and first_non_whitespace_ix != null) {
                    last_candidate_ix = ix;
                    last_candidate_width = width;
                }
            } else if (c != ' ' and first_non_whitespace_ix != null) {
                last_candidate_ix = ix;
                last_candidate_width = width;
            }
            if (c != ' ' and first_non_whitespace_ix == null) first_non_whitespace_ix = ix;
            width += char_width;

            if (line < max_lines - 1) {
                if (width > wrap_width and ix > last_wrap_ix) {
                    if (indent == null) {
                        if (first_non_whitespace_ix) |f| indent = @min(max_indent, @as(u32, @intCast(f - last_wrap_ix)));
                    }
                    if (last_candidate_ix > last_wrap_ix) {
                        last_wrap_ix = last_candidate_ix;
                        width -= last_candidate_width;
                        last_candidate_ix = 0;
                    } else {
                        last_wrap_ix = ix;
                        width = char_width;
                    }
                    if (indent) |n| width += self.widthForChar(' ') * @as(Pixels, @floatFromInt(n));
                    line += 1;
                    truncate_ix = last_wrap_ix;
                }
            } else {
                if (width + affix_width <= wrap_width) truncate_ix = ix + ch.len;
                if (width > wrap_width) return try self.finishEndTruncation(gpa, text[0..truncate_ix], affix, runs);
            }
            prev_c = c;
        }
        return null;
    }

    fn finishEndTruncation(_: *LineWrapper, gpa: Allocator, head: []const u8, affix: []const u8, runs: []const TextRun) !Truncated {
        const result = try std.mem.concat(gpa, u8, &.{ trimEndWhitespacePunct(head), affix });
        errdefer gpa.free(result);
        return .{ .text = result, .runs = try runsAfterTruncation(gpa, result, affix, runs, .end) };
    }
};

fn trimEndWhitespacePunct(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) {
        const c = s[end - 1];
        if (std.ascii.isWhitespace(c) or (c < 0x80 and std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ')) {
            end -= 1;
        } else break;
    }
    return s[0..end];
}

fn runsAfterTruncation(gpa: Allocator, result: []const u8, affix: []const u8, runs: []const TextRun, from: TruncateFrom) ![]TextRun {
    var truncate_at = result.len - affix.len;
    switch (from) {
        .start => {
            var i = runs.len;
            while (i > 0) {
                i -= 1;
                if (runs[i].len <= truncate_at) {
                    truncate_at -= runs[i].len;
                } else {
                    const out = try gpa.dupe(TextRun, runs[i..]);
                    out[0].len = truncate_at + affix.len;
                    return out;
                }
            }
        },
        .end => {
            for (runs, 0..) |run, i| {
                if (run.len <= truncate_at) {
                    truncate_at -= run.len;
                } else {
                    const out = try gpa.dupe(TextRun, runs[0 .. i + 1]);
                    out[i].len = truncate_at + affix.len;
                    return out;
                }
            }
        },
        .middle => unreachable,
    }
    return gpa.dupe(TextRun, runs);
}

fn runsAfterMiddleTruncation(gpa: Allocator, affix: []const u8, runs: []const TextRun, front_end: usize, back_start: usize) ![]TextRun {
    var out: std.ArrayList(TextRun) = .empty;
    errdefer out.deinit(gpa);
    var front_remaining = front_end;
    var front_done = false;
    for (runs) |run| {
        if (front_done) break;
        if (run.len <= front_remaining) {
            try out.append(gpa, run);
            front_remaining -= run.len;
        } else {
            var partial = run;
            partial.len = front_remaining + affix.len;
            try out.append(gpa, partial);
            front_done = true;
        }
    }
    if (!front_done) {
        if (out.items.len > 0) {
            out.items[out.items.len - 1].len += affix.len;
        } else if (runs.len > 0) {
            var r = runs[0];
            r.len = affix.len;
            try out.append(gpa, r);
        }
    }
    var pos: usize = 0;
    for (runs) |run| {
        const run_end = pos + run.len;
        if (run_end > back_start) {
            var r = run;
            if (pos < back_start) r.len = run_end - back_start;
            try out.append(gpa, r);
        }
        pos = run_end;
    }
    return out.toOwnedSlice(gpa);
}

/// UTF-8 code point iterator yielding byte index and length.
pub const CharIter = struct {
    s: []const u8,
    i: usize = 0,

    pub const Item = struct { ix: usize, cp: u21, len: u3 };

    pub fn next(self: *CharIter) ?Item {
        if (self.i >= self.s.len) return null;
        const d = fallback.decodeAt(self.s, self.i);
        const item: Item = .{ .ix = self.i, .cp = d.cp, .len = d.len };
        self.i += d.len;
        return item;
    }
};
