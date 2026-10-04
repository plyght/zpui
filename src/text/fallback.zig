//! Font fallback helpers shared by the platform shapers: approximate grapheme
//! segmentation, emoji classification and zui's run-span splitting
//! (`compute_run_spans` / `pick_covering_slot` in `gpui_wgpu/src/cosmic_text_system.rs`).

const std = @import("std");
const types = @import("types.zig");

const FontId = types.FontId;

/// Decode the code point starting at byte `i` (invalid bytes decode as U+FFFD, length 1).
pub fn decodeAt(text: []const u8, i: usize) struct { cp: u21, len: u3 } {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .cp = 0xFFFD, .len = 1 };
    if (i + len > text.len) return .{ .cp = 0xFFFD, .len = 1 };
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return .{ .cp = 0xFFFD, .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// Code points that attach to the preceding grapheme (an approximation of
/// Grapheme_Cluster_Break = Extend | SpacingMark | ZWJ for common scripts).
pub fn isExtend(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036F, 0x0483...0x0489, 0x0591...0x05BD, 0x05BF, 0x05C1...0x05C2, 0x05C4...0x05C5, 0x05C7 => true,
        0x0610...0x061A, 0x064B...0x065F, 0x0670, 0x06D6...0x06DC, 0x06DF...0x06E4, 0x06E7...0x06E8, 0x06EA...0x06ED => true,
        0x0711, 0x0730...0x074A => true,
        // Brahmic scripts share a block layout: signs at 0x00-0x03, dependent vowels/virama 0x3A-0x4F, etc.
        0x0900...0x0DFF => blk: {
            const o = cp & 0x7F;
            break :blk o <= 0x03 or (o >= 0x3A and o <= 0x4F and o != 0x3D) or (o >= 0x51 and o <= 0x57) or o == 0x62 or o == 0x63;
        },
        0x0E31, 0x0E34...0x0E3A, 0x0E47...0x0E4E, 0x0EB1, 0x0EB4...0x0EBC, 0x0EC8...0x0ECE => true,
        0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x200C, 0x200D, 0x20D0...0x20FF => true,
        0x302A...0x302F, 0x3099...0x309A, 0xFE00...0xFE0F, 0xFE20...0xFE2F => true,
        0x1F3FB...0x1F3FF, 0xE0020...0xE007F, 0xE0100...0xE01EF => true,
        else => false,
    };
}

pub fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

/// Characters rendered as color emoji by default (Emoji_Presentation=Yes, approximated by block).
pub fn isEmojiPresentation(cp: u21) bool {
    return switch (cp) {
        0x231A...0x231B, 0x23E9...0x23EC, 0x23F0, 0x23F3, 0x25FD...0x25FE, 0x2614...0x2615 => true,
        0x2648...0x2653, 0x267F, 0x2693, 0x26A1, 0x26AA...0x26AB, 0x26BD...0x26BE, 0x26C4...0x26C5 => true,
        0x26CE, 0x26D4, 0x26EA, 0x26F2...0x26F3, 0x26F5, 0x26FA, 0x26FD, 0x2705, 0x270A...0x270B => true,
        0x2728, 0x274C, 0x274E, 0x2753...0x2755, 0x2757, 0x2795...0x2797, 0x27B0, 0x27BF => true,
        0x2B1B...0x2B1C, 0x2B50, 0x2B55, 0x1F004, 0x1F0CF, 0x1F18E, 0x1F191...0x1F19A => true,
        0x1F1E6...0x1F1FF, 0x1F201, 0x1F21A, 0x1F22F, 0x1F232...0x1F236, 0x1F238...0x1F23A, 0x1F250...0x1F251 => true,
        0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F7E0...0x1F7EB, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF => true,
        else => false,
    };
}

/// Returns the byte index just past the grapheme cluster starting at `start`.
/// Keeps combining marks, variation selectors, emoji modifiers/tags, ZWJ
/// sequences and regional-indicator pairs together.
pub fn graphemeEnd(text: []const u8, start: usize) usize {
    const first = decodeAt(text, start);
    var i = start + first.len;
    if (first.cp == '\r' and i < text.len and text[i] == '\n') return i + 1;
    if (isRegionalIndicator(first.cp) and i < text.len) {
        const next = decodeAt(text, i);
        if (isRegionalIndicator(next.cp)) i += next.len;
    }
    while (i < text.len) {
        const next = decodeAt(text, i);
        if (next.cp == 0x200D) {
            i += next.len;
            if (i < text.len) i += decodeAt(text, i).len;
        } else if (isExtend(next.cp)) {
            i += next.len;
        } else break;
    }
    return i;
}

/// Whether a grapheme wants color emoji presentation (default emoji or VS16).
pub fn graphemeWantsEmoji(grapheme: []const u8) bool {
    var i: usize = 0;
    var first = true;
    while (i < grapheme.len) {
        const d = decodeAt(grapheme, i);
        if (d.cp == 0xFE0F or d.cp == 0x20E3) return true;
        if (d.cp == 0xFE0E) return false;
        if (first and isEmojiPresentation(d.cp)) return true;
        first = false;
        i += d.len;
    }
    return false;
}

/// One contiguous slice of a `FontRun` mapped to a single fallback slot.
/// `slot` is null for the primary font and `i` for `fallback_chain[i]`.
pub const RunSpan = struct {
    start: usize,
    end: usize,
    slot: ?usize,
    font_id: FontId,
};

fn slotFontId(slot: ?usize, primary: FontId, chain: []const FontId) FontId {
    return if (slot) |ix| chain[ix] else primary;
}

/// zui `pick_covering_slot`: ASCII and primary-covered chars stay on the primary;
/// otherwise prefer the current slot, then the first covering chain entry.
/// `covers` must have `fn covers(self, FontId, u21) bool`.
pub fn pickCoveringSlot(ch: u21, current: ?usize, primary: FontId, chain: []const FontId, covers: anytype) ?usize {
    if (ch <= 0x7F) return null;
    if (covers.covers(primary, ch)) return null;
    if (covers.covers(slotFontId(current, primary, chain), ch)) return current;
    for (chain, 0..) |fb, ix| {
        if (covers.covers(fb, ch)) return ix;
    }
    return null;
}

/// zui `compute_run_spans`: split `text[run_offset..][0..run_len]` into spans by
/// covering font, grapheme by grapheme, so clusters are never torn apart.
pub fn computeRunSpans(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(RunSpan),
    text: []const u8,
    run_offset: usize,
    run_len: usize,
    primary: FontId,
    chain: []const FontId,
    covers: anytype,
) !void {
    const run_end = run_offset + run_len;
    if (run_len == 0) return;
    if (chain.len == 0) {
        try out.append(gpa, .{ .start = run_offset, .end = run_end, .slot = null, .font_id = primary });
        return;
    }
    var span_start = run_offset;
    var span_slot: ?usize = null;
    var i = run_offset;
    while (i < run_end) {
        const ch = decodeAt(text, i).cp;
        const next_slot = pickCoveringSlot(ch, span_slot, primary, chain, covers);
        if (next_slot != span_slot) {
            if (i > span_start) try out.append(gpa, .{
                .start = span_start,
                .end = i,
                .slot = span_slot,
                .font_id = slotFontId(span_slot, primary, chain),
            });
            span_start = i;
            span_slot = next_slot;
        }
        i = @min(graphemeEnd(text, i), run_end);
    }
    if (span_start < run_end) try out.append(gpa, .{
        .start = span_start,
        .end = run_end,
        .slot = span_slot,
        .font_id = slotFontId(span_slot, primary, chain),
    });
}

// ---------------------------------------------------------------------------
// Tests (ported from cosmic_text_system.rs)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fid(i: u32) FontId {
    return @enumFromInt(i);
}

const AsciiPrimary = struct {
    primary: FontId,
    pub fn covers(self: @This(), id: FontId, ch: u21) bool {
        return if (id == self.primary) ch < 0x80 else ch >= 0x80;
    }
};

fn expectSpans(expected: []const RunSpan, text: []const u8, off: usize, len: usize, chain: []const FontId, covers: anytype) !void {
    var out: std.ArrayList(RunSpan) = .empty;
    defer out.deinit(testing.allocator);
    try computeRunSpans(testing.allocator, &out, text, off, len, fid(0), chain, covers);
    try testing.expectEqualSlices(RunSpan, expected, out.items);
}

test "pick covering slot" {
    const Cov = struct {
        f: *const fn (FontId, u21) bool,
        pub fn covers(self: @This(), id: FontId, ch: u21) bool {
            return self.f(id, ch);
        }
    };
    const zero_or_one: Cov = .{ .f = struct {
        fn f(id: FontId, _: u21) bool {
            return id == fid(0) or id == fid(1);
        }
    }.f };
    const chain = [_]FontId{ fid(1), fid(2) };
    try testing.expectEqual(@as(?usize, null), pickCoveringSlot('a', 0, fid(0), &chain, zero_or_one));
    const only_two: Cov = .{ .f = struct {
        fn f(id: FontId, _: u21) bool {
            return id == fid(2);
        }
    }.f };
    try testing.expectEqual(@as(?usize, 1), pickCoveringSlot(0x5B57, null, fid(0), &chain, only_two));
    const none: Cov = .{ .f = struct {
        fn f(_: FontId, _: u21) bool {
            return false;
        }
    }.f };
    try testing.expectEqual(@as(?usize, null), pickCoveringSlot(0x1F600, 1, fid(0), &chain, none));
}

test "run spans split by byte offsets and respect run offset" {
    const chain = [_]FontId{fid(1)};
    const cov: AsciiPrimary = .{ .primary = fid(0) };
    try expectSpans(&.{
        .{ .start = 0, .end = 1, .slot = null, .font_id = fid(0) },
        .{ .start = 1, .end = 4, .slot = 0, .font_id = fid(1) },
        .{ .start = 4, .end = 5, .slot = null, .font_id = fid(0) },
    }, "a字b", 0, 5, &chain, cov);
    try expectSpans(&.{
        .{ .start = 2, .end = 5, .slot = 0, .font_id = fid(1) },
        .{ .start = 5, .end = 6, .slot = null, .font_id = fid(0) },
    }, "xx字y", 2, 4, &chain, cov);
    try expectSpans(&.{.{ .start = 0, .end = 9, .slot = 0, .font_id = fid(1) }}, "字字字", 0, 9, &chain, cov);
    try expectSpans(&.{}, "anything", 3, 0, &chain, cov);
    try expectSpans(&.{.{ .start = 0, .end = 5, .slot = null, .font_id = fid(0) }}, "hello", 0, 5, &.{}, cov);
}

test "run spans keep clusters together" {
    const chain = [_]FontId{fid(1)};
    const Devanagari = struct {
        pub fn covers(_: @This(), id: FontId, ch: u21) bool {
            return if (id == fid(0)) ch < 0x80 else ch == 0x0905;
        }
    };
    try expectSpans(&.{.{ .start = 0, .end = 6, .slot = 0, .font_id = fid(1) }}, "\u{0905}\u{0902}", 0, 6, &chain, Devanagari{});
    const Emoji = struct {
        pub fn covers(_: @This(), id: FontId, ch: u21) bool {
            return id == fid(1) and ch != 0x200D;
        }
    };
    const zwj = "\u{1F469}\u{200D}\u{1F467}";
    try expectSpans(&.{.{ .start = 0, .end = zwj.len, .slot = 0, .font_id = fid(1) }}, zwj, 0, zwj.len, &chain, Emoji{});
}

test "grapheme segmentation" {
    try testing.expectEqual(@as(usize, 1), graphemeEnd("ab", 0));
    try testing.expectEqual(@as(usize, 3), graphemeEnd("e\u{0301}x", 0));
    const flag = "\u{1F1FA}\u{1F1F8}\u{1F1EB}";
    try testing.expectEqual(@as(usize, 8), graphemeEnd(flag, 0));
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}!";
    try testing.expectEqual(family.len - 1, graphemeEnd(family, 0));
    try testing.expect(graphemeWantsEmoji("\u{1F600}"));
    try testing.expect(graphemeWantsEmoji("\u{2764}\u{FE0F}"));
    try testing.expect(!graphemeWantsEmoji("\u{2764}"));
    try testing.expect(!graphemeWantsEmoji("a"));
}
