//! Text segmentation for the editor: grapheme clusters (zpui's fallback
//! segmenter: combining marks, ZWJ emoji sequences, flags, CRLF) and an
//! approximation of UAX #29 word boundaries — the parts of
//! `unicode-segmentation`'s `split_word_bound_indices` that zeron's
//! `ComposerInput` relies on for word motion, word deletion and double-click
//! selection (`composer.rs` `previous_word_boundary` / `next_word_boundary` /
//! `word_range`).
//!
//! Word rules implemented: CRLF stays together (WB3), each newline is its own
//! segment (WB3a/b), runs of horizontal whitespace merge (WB3d), letters /
//! digits / `_` / Katakana join into words (WB5, 8–10, 13, 13a/b), a single
//! MidLetter / MidNum / MidNumLet between letters (`don't`, `e.g`) or digits
//! (`3.14`, `1,000`) joins (WB6/7, 11/12), Extend/ZWJ/format attach to their
//! grapheme (WB4). Everything else — CJK ideographs, Hiragana, emoji,
//! punctuation — is one segment per grapheme (WB999). Classification of
//! non-ASCII scripts is by block (no Unicode tables).

const std = @import("std");
const zpui = @import("zpui");
const fallback = zpui.text.fallback;

pub const decodeAt = fallback.decodeAt;

/// Byte index just past the grapheme starting at `start` (`start < text.len`).
pub fn graphemeEnd(text: []const u8, start: usize) usize {
    return @min(fallback.graphemeEnd(text, start), text.len);
}

/// The grapheme boundary before `offset` (0 at the start). Scans from the
/// start of the logical line so long documents stay cheap.
pub fn prevGrapheme(text: []const u8, offset: usize) usize {
    const off = @min(offset, text.len);
    if (off == 0) return 0;
    // CRLF is one grapheme.
    if (text[off - 1] == '\n' and off >= 2 and text[off - 2] == '\r') return off - 2;
    var i: usize = if (std.mem.lastIndexOfScalar(u8, text[0 .. off - 1], '\n')) |nl| nl + 1 else 0;
    var prev: usize = i;
    while (i < off) {
        prev = i;
        i = graphemeEnd(text, i);
    }
    return prev;
}

/// The grapheme boundary after `offset` (`text.len` at the end).
pub fn nextGrapheme(text: []const u8, offset: usize) usize {
    if (offset >= text.len) return text.len;
    // Land on a char boundary first.
    var i = offset;
    while (i > 0 and i < text.len and isContinuation(text[i])) i -= 1;
    var end = graphemeEnd(text, i);
    while (end <= offset and end < text.len) end = graphemeEnd(text, end);
    return end;
}

/// Number of grapheme clusters in `text`.
pub fn graphemeCount(text: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) i = graphemeEnd(text, i);
    return n;
}

pub fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

/// Clamp `offset` to `text` and move it back onto a UTF-8 char boundary.
pub fn floorCharBoundary(text: []const u8, offset: usize) usize {
    var i = @min(offset, text.len);
    while (i > 0 and i < text.len and isContinuation(text[i])) i -= 1;
    return i;
}

// ---------------------------------------------------------------------------
// Word boundaries
// ---------------------------------------------------------------------------

pub const WordClass = enum {
    newline,
    space,
    letter,
    numeric,
    extend_num_let,
    katakana,
    mid_letter,
    mid_num,
    mid_num_let,
    /// Ideographs, Hiragana, emoji, symbols, punctuation: one per grapheme.
    other,
};

pub fn classify(cp: u21) WordClass {
    return switch (cp) {
        '\n', '\r', 0x0B, 0x0C, 0x85, 0x2028, 0x2029 => .newline,
        ' ', '\t', 0x1680, 0x2000...0x2006, 0x2008...0x200A, 0x205F, 0x3000 => .space,
        '0'...'9', 0x0660...0x0669, 0x06F0...0x06F9, 0x0966...0x096F, 0xFF10...0xFF19 => .numeric,
        'a'...'z', 'A'...'Z' => .letter,
        '_', 0x203F, 0x2040, 0x2054, 0xFE33, 0xFE34, 0xFE4D...0xFE4F, 0xFF3F => .extend_num_let,
        ':', 0xB7, 0x0387, 0x05F4, 0x2027, 0xFE13, 0xFE55, 0xFF1A => .mid_letter,
        ',', ';', 0x037E, 0x0589, 0x060C, 0x060D, 0x066C, 0x07F8, 0x2044, 0xFE10, 0xFE14, 0xFE50, 0xFE54, 0xFF0C, 0xFF1B => .mid_num,
        '.', '\'', 0x2018, 0x2019, 0x2024, 0xFE52, 0xFF07, 0xFF0E => .mid_num_let,
        // Latin-1 / Latin Extended letters (minus × and ÷), IPA, spacing modifiers.
        0xAA, 0xB5, 0xBA, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x02FF => .letter,
        // Combining marks attach (handled by graphemes); treat as letters if alone.
        0x0300...0x036F => .letter,
        // Greek, Cyrillic, Armenian, Hebrew, Arabic, Syriac, ... through Myanmar,
        // Georgian, Hangul Jamo, Ethiopic, Cherokee, ... (letters by block).
        0x0370...0x037D, 0x037F...0x0386, 0x0388...0x0588, 0x058A...0x05F3, 0x05F5...0x060B => .letter,
        0x060E...0x065F, 0x066A, 0x066B, 0x066D...0x06EF, 0x06FA...0x07F7, 0x07F9...0x0965, 0x0970...0x0E3F => .letter,
        0x0E40...0x0FFF => .other, // Thai/Lao/Tibetan: dictionary segmentation in UAX29; per grapheme here
        0x1000...0x167F, 0x1681...0x1FFF => .letter,
        0x2C00...0x2DFF => .letter, // Glagolitic, Coptic, Georgian sup., Tifinagh, Ethiopic ext.
        0x30A0...0x30FA, 0x30FC...0x30FF, 0x31F0...0x31FF, 0x32D0...0x32FE, 0x3300...0x3357, 0xFF66...0xFF9D => .katakana,
        0xA4D0...0xA4FF, 0xA500...0xA61F, 0xA640...0xA6FF, 0xA720...0xA7FF => .letter,
        0xAC00...0xD7FF => .letter, // Hangul syllables + Jamo ext B
        0xFB00...0xFDFF, 0xFE70...0xFEFF => .letter, // presentation forms
        0xFF21...0xFF3A, 0xFF41...0xFF5A => .letter, // fullwidth Latin
        else => .other,
    };
}

fn isAHLetter(c: WordClass) bool {
    return c == .letter;
}

fn joinsWord(c: WordClass) bool {
    return c == .letter or c == .numeric or c == .extend_num_let or c == .katakana;
}

/// Class of the grapheme starting at `i` (its first code point).
fn classAt(text: []const u8, i: usize) WordClass {
    return classify(decodeAt(text, i).cp);
}

/// End of the word segment that starts at `start`.
pub fn wordSegmentEnd(text: []const u8, start: usize) usize {
    if (start >= text.len) return text.len;
    const first = classAt(text, start);
    var end = graphemeEnd(text, start);
    switch (first) {
        .newline => return end, // CRLF is one grapheme
        .space => {
            while (end < text.len and classAt(text, end) == .space) end = graphemeEnd(text, end);
            return end;
        },
        .letter, .numeric, .extend_num_let, .katakana => {
            var prev = first;
            while (end < text.len) {
                const c = classAt(text, end);
                if (joinsWord(c)) {
                    // Katakana joins Katakana / ExtendNumLet (WB13, 13a/b); letters
                    // and digits join each other and ExtendNumLet.
                    const ok = if (c == .katakana or prev == .katakana)
                        (c == prev or c == .extend_num_let or prev == .extend_num_let)
                    else
                        true;
                    if (!ok) break;
                    prev = c;
                    end = graphemeEnd(text, end);
                    continue;
                }
                // WB6/7 and WB11/12: a single mid char between two of the same kind.
                const mid_ok = switch (c) {
                    .mid_letter => isAHLetter(prev),
                    .mid_num => prev == .numeric,
                    .mid_num_let => isAHLetter(prev) or prev == .numeric,
                    else => false,
                };
                if (!mid_ok) break;
                const after = graphemeEnd(text, end);
                if (after >= text.len) break;
                const next = classAt(text, after);
                const joined = if (prev == .numeric) next == .numeric else isAHLetter(next);
                if (!joined) break;
                end = after;
            }
            return end;
        },
        else => return end,
    }
}

/// Iterator over `(start, end)` word segments (`split_word_bound_indices`).
pub const WordIterator = struct {
    text: []const u8,
    pos: usize = 0,

    pub fn next(self: *WordIterator) ?Segment {
        if (self.pos >= self.text.len) return null;
        const start = self.pos;
        self.pos = wordSegmentEnd(self.text, start);
        return .{ .start = start, .end = self.pos };
    }
};

pub const Segment = struct {
    start: usize,
    end: usize,

    pub fn isBlank(self: Segment, text: []const u8) bool {
        // Rust: `word.trim().is_empty()` (Unicode White_Space).
        var i = self.start;
        while (i < self.end) {
            const d = decodeAt(text, i);
            if (!isWhiteSpace(d.cp)) return false;
            i += d.len;
        }
        return true;
    }
};

pub fn isWhiteSpace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

/// Start of the last non-blank word segment that starts before `offset`
/// (`ComposerInput::previous_word_boundary`).
pub fn prevWordBoundary(text: []const u8, offset: usize) usize {
    var it: WordIterator = .{ .text = text };
    var found: usize = 0;
    while (it.next()) |seg| {
        if (seg.start >= offset) break;
        if (!seg.isBlank(text)) found = seg.start;
    }
    return found;
}

/// End of the first non-blank word segment that ends after `offset`
/// (`ComposerInput::next_word_boundary`).
pub fn nextWordBoundary(text: []const u8, offset: usize) usize {
    var it: WordIterator = .{ .text = text };
    while (it.next()) |seg| {
        if (seg.end > offset and !seg.isBlank(text)) return seg.end;
    }
    return text.len;
}

/// The word segment containing `offset` (`composer.rs` `word_range`); an
/// empty range at the end of the text.
pub fn wordRange(text: []const u8, offset: usize) Segment {
    const off = @min(offset, text.len);
    var it: WordIterator = .{ .text = text };
    while (it.next()) |seg| {
        if (seg.start <= off and off < seg.end) return seg;
    }
    return .{ .start = off, .end = off };
}

// ---------------------------------------------------------------------------
// UTF-16 mapping (IME ranges are UTF-16 offsets, as on macOS)
// ---------------------------------------------------------------------------

/// UTF-8 byte offset for a UTF-16 offset (`ComposerInput::utf8_offset`):
/// counts whole code points until `utf16` units are reached.
pub fn utf8FromUtf16(text: []const u8, utf16: usize) usize {
    var u8_off: usize = 0;
    var u16_count: usize = 0;
    while (u8_off < text.len) {
        if (u16_count >= utf16) break;
        const d = decodeAt(text, u8_off);
        u16_count += if (d.cp >= 0x10000) 2 else 1;
        u8_off += d.len;
    }
    return u8_off;
}

/// UTF-16 offset of a UTF-8 byte offset (`ComposerInput::offset_to_utf16`).
pub fn utf16FromUtf8(text: []const u8, utf8: usize) usize {
    var u8_off: usize = 0;
    var u16_off: usize = 0;
    while (u8_off < text.len) {
        if (u8_off >= utf8) break;
        const d = decodeAt(text, u8_off);
        u8_off += d.len;
        u16_off += if (d.cp >= 0x10000) 2 else 1;
    }
    return u16_off;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn segments(text: []const u8, out: *[32][]const u8) [][]const u8 {
    var it: WordIterator = .{ .text = text };
    var n: usize = 0;
    while (it.next()) |s| : (n += 1) out[n] = text[s.start..s.end];
    return out[0..n];
}

fn expectSegments(text: []const u8, want: []const []const u8) !void {
    var buf: [32][]const u8 = undefined;
    const got = segments(text, &buf);
    if (got.len != want.len) {
        std.debug.print("segments of \"{s}\": got {d}, want {d}\n", .{ text, got.len, want.len });
        for (got) |g| std.debug.print("  [{s}]\n", .{g});
        return error.TestUnexpectedResult;
    }
    for (got, want) |g, w| try testing.expectEqualStrings(w, g);
}

test "word segments follow UAX29 basics" {
    try expectSegments("The quick (\"brown\") fox can't jump 32.3 feet, right?", &.{
        "The", " ", "quick", " ", "(", "\"", "brown", "\"", ")", " ", "fox", " ", "can't", " ", "jump", " ", "32.3", " ", "feet", ",", " ", "right", "?",
    });
    try expectSegments("snake_case  x\r\ny", &.{ "snake_case", "  ", "x", "\r\n", "y" });
    try expectSegments("e.g. 1,000.5", &.{ "e.g", ".", " ", "1,000.5" });
    try expectSegments("日本語テキスト", &.{ "日", "本", "語", "テキスト" });
    try expectSegments("héllo wörld", &.{ "héllo", " ", "wörld" });
    try expectSegments("a👍🏽b", &.{ "a", "👍🏽", "b" });
    try expectSegments("trailing.", &.{ "trailing", "." });
}

test "word boundaries match ComposerInput motion" {
    const t = "hello world, foo";
    try testing.expectEqual(@as(usize, 5), nextWordBoundary(t, 0));
    try testing.expectEqual(@as(usize, 11), nextWordBoundary(t, 5));
    try testing.expectEqual(@as(usize, 12), nextWordBoundary(t, 11)); // the comma is a word
    try testing.expectEqual(@as(usize, 16), nextWordBoundary(t, 12));
    try testing.expectEqual(@as(usize, 16), nextWordBoundary(t, 16));
    try testing.expectEqual(@as(usize, 13), prevWordBoundary(t, 16));
    try testing.expectEqual(@as(usize, 11), prevWordBoundary(t, 13));
    try testing.expectEqual(@as(usize, 6), prevWordBoundary(t, 11));
    try testing.expectEqual(@as(usize, 0), prevWordBoundary(t, 3));
    const w = wordRange(t, 7);
    try testing.expectEqualStrings("world", t[w.start..w.end]);
    const sp = wordRange("a   b", 2);
    try testing.expectEqual(@as(usize, 1), sp.start);
    try testing.expectEqual(@as(usize, 4), sp.end);
    try testing.expectEqual(@as(usize, 5), wordRange("hello", 9).start);
}

test "grapheme stepping keeps clusters intact" {
    const t = "a👨‍👩‍👧b"; // family ZWJ sequence
    const fam_end = 1 + "👨‍👩‍👧".len;
    try testing.expectEqual(fam_end, nextGrapheme(t, 1));
    try testing.expectEqual(@as(usize, 1), prevGrapheme(t, fam_end));
    try testing.expectEqual(@as(usize, 0), prevGrapheme(t, 1));
    const flags = "🇯🇵🇫🇷";
    try testing.expectEqual(@as(usize, 8), nextGrapheme(flags, 0));
    try testing.expectEqual(@as(usize, 8), prevGrapheme(flags, 16));
    const combining = "e\u{301}x"; // é as e + combining acute
    try testing.expectEqual(@as(usize, 3), nextGrapheme(combining, 0));
    try testing.expectEqual(@as(usize, 0), prevGrapheme(combining, 3));
    const crlf = "a\r\nb";
    try testing.expectEqual(@as(usize, 3), nextGrapheme(crlf, 1));
    try testing.expectEqual(@as(usize, 1), prevGrapheme(crlf, 3));
    const lf = "ab\ncd";
    try testing.expectEqual(@as(usize, 2), prevGrapheme(lf, 3));
    try testing.expectEqual(@as(usize, 3), prevGrapheme(lf, 4));
    try testing.expectEqual(@as(usize, 3), graphemeCount("中文字"));
    try testing.expectEqual(@as(usize, 3), nextGrapheme("中文字", 1)); // mid-char offset
}

test "utf16 mapping counts astral code points as two units" {
    const t = "a😀b中";
    try testing.expectEqual(@as(usize, 0), utf16FromUtf8(t, 0));
    try testing.expectEqual(@as(usize, 1), utf16FromUtf8(t, 1));
    try testing.expectEqual(@as(usize, 3), utf16FromUtf8(t, 5));
    try testing.expectEqual(@as(usize, 5), utf16FromUtf8(t, t.len));
    try testing.expectEqual(@as(usize, 5), utf8FromUtf16(t, 3));
    try testing.expectEqual(@as(usize, 6), utf8FromUtf16(t, 4));
    try testing.expectEqual(t.len, utf8FromUtf16(t, 99));
    // A UTF-16 offset inside a surrogate pair rounds up past the code point.
    try testing.expectEqual(@as(usize, 5), utf8FromUtf16(t, 2));
}
