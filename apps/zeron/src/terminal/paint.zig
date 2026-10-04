//! Renderer-agnostic paint plan for one snapshot, ported from zeron's
//! `view.rs` `TerminalElement::prepaint` + `shape_row`:
//!
//! - background quads for cells whose (display) background is not the
//!   panel default, merged into horizontal runs;
//! - selection quads (the theme selection wash);
//! - column-pinned text segments: runs of ASCII shape together (cell-width
//!   in a mono font) and every other glyph (box drawing, CJK, emoji, any
//!   fallback-font glyph) is its own segment pinned at its column, so a
//!   fallback advance can never slide the rest of the row off the grid;
//! - the cursor quad (block/bar/underline/hollow).
//!
//! Coordinates are in cells; the view multiplies by its measured cell size.
const std = @import("std");
const Allocator = std.mem.Allocator;
const snapshot = @import("snapshot.zig");
const palette_mod = @import("palette.zig");
const Palette = palette_mod.Palette;
const Rgb = snapshot.Rgb;

pub const TextStyle = struct {
    color: Rgb,
    /// 1.0, or 0.6 for faint (zeron dims via alpha).
    alpha: f32 = 1,
    bold: bool = false,
    italic: bool = false,
    underline: snapshot.Underline = .none,
    underline_color: ?Rgb = null,
    strikethrough: bool = false,

    fn eql(a: TextStyle, b: TextStyle) bool {
        return a.color.eql(b.color) and a.alpha == b.alpha and a.bold == b.bold and
            a.italic == b.italic and a.underline == b.underline and
            std.meta.eql(a.underline_color, b.underline_color) and a.strikethrough == b.strikethrough;
    }
};

pub const Run = struct {
    /// Byte length within the segment text.
    len: usize,
    style: TextStyle,
};

pub const Segment = struct {
    row: u16,
    col: u16,
    text: []const u8,
    runs: []const Run,
    /// The segment is a single double-width glyph (spans two cells).
    wide: bool = false,
};

pub const Quad = struct {
    row: u16,
    col: u16,
    /// Width in cells.
    len: u16,
    color: Rgb,
    alpha: u8 = 255,
};

pub const CursorQuad = struct {
    row: u16,
    col: u16,
    /// Width in cells (2 on a wide glyph).
    width: u16,
    style: snapshot.CursorStyle,
    color: Rgb,
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    backgrounds: []const Quad = &.{},
    selections: []const Quad = &.{},
    segments: []const Segment = &.{},
    cursor: ?CursorQuad = null,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }
};

pub fn build(gpa: Allocator, snap: *const snapshot.Snapshot, pal: *const Palette) !Plan {
    var plan: Plan = .{ .arena = .init(gpa) };
    errdefer plan.deinit();
    const a = plan.arena.allocator();

    var bgs: std.ArrayList(Quad) = .empty;
    var sels: std.ArrayList(Quad) = .empty;
    var segs: std.ArrayList(Segment) = .empty;

    for (snap.lines, 0..) |row, ri| {
        const r: u16 = @intCast(ri);
        // Backgrounds + selection, merged into runs.
        for (row.cells, 0..) |cell, ci| {
            const c: u16 = @intCast(ci);
            const dc = cell.displayColors();
            const is_default_bg = dc.bg == .default and dc.bg_slot == .bg;
            if (!is_default_bg) {
                const color = pal.resolve(dc.bg, dc.bg_slot);
                if (bgs.items.len > 0) {
                    const last = &bgs.items[bgs.items.len - 1];
                    if (last.row == r and last.col + last.len == c and last.color.eql(color)) {
                        last.len += 1;
                        continue;
                    }
                }
                try bgs.append(a, .{ .row = r, .col = c, .len = 1, .color = color });
            }
        }
        for (row.cells, 0..) |cell, ci| {
            if (!cell.selected) continue;
            const c: u16 = @intCast(ci);
            if (sels.items.len > 0) {
                const last = &sels.items[sels.items.len - 1];
                if (last.row == r and last.col + last.len == c) {
                    last.len += 1;
                    continue;
                }
            }
            try sels.append(a, .{ .row = r, .col = c, .len = 1, .color = pal.selection, .alpha = pal.selection_alpha });
        }
        try segmentRow(a, &segs, r, row.cells, pal);
    }

    plan.backgrounds = bgs.items;
    plan.selections = sels.items;
    plan.segments = segs.items;
    if (snap.cursor) |cur| {
        var col = cur.col;
        var width: u16 = 1;
        if (cur.wide_tail and col > 0) col -= 1;
        if (col < snap.cols and snap.lines[cur.row].cells[col].wide == .wide) width = 2;
        plan.cursor = .{
            .row = cur.row,
            .col = col,
            .width = width,
            .style = cur.style,
            .color = pal.cursor orelse pal.foreground,
        };
    }
    return plan;
}

fn segmentRow(a: Allocator, segs: *std.ArrayList(Segment), r: u16, cells: []const snapshot.Cell, pal: *const Palette) !void {
    var text: std.ArrayList(u8) = .empty;
    var runs: std.ArrayList(Run) = .empty;
    var seg_col: u16 = 0;

    for (cells, 0..) |cell, ci| {
        const c: u16 = @intCast(ci);
        if (cell.wide == .spacer_tail or cell.wide == .spacer_head) continue;
        const blank = cell.isEmpty() or cell.attrs.invisible;
        const cp: u21 = if (blank) ' ' else cell.codepoint;
        const pinned = cp >= 0x80 or cell.grapheme.len > 0 or cell.wide == .wide;
        if (pinned) try flush(a, segs, &text, &runs, r, seg_col, false);
        if (text.items.len == 0) seg_col = c;

        const dc = cell.displayColors();
        var style: TextStyle = .{
            .color = pal.resolve(dc.fg, dc.fg_slot),
            .alpha = if (cell.attrs.faint) 0.6 else 1,
            .bold = cell.attrs.bold,
            .italic = cell.attrs.italic,
            .underline = cell.underline,
            .strikethrough = cell.attrs.strikethrough,
        };
        if (cell.underline != .none and cell.underline_color != .default) {
            style.underline_color = pal.resolve(cell.underline_color, .fg);
        }

        const start = text.items.len;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch 1;
        try text.appendSlice(a, buf[0..n]);
        if (!blank) for (cell.grapheme) |g| {
            const m = std.unicode.utf8Encode(g, &buf) catch continue;
            try text.appendSlice(a, buf[0..m]);
        };
        const len = text.items.len - start;
        if (runs.items.len > 0 and runs.items[runs.items.len - 1].style.eql(style)) {
            runs.items[runs.items.len - 1].len += len;
        } else try runs.append(a, .{ .len = len, .style = style });

        if (pinned) try flush(a, segs, &text, &runs, r, seg_col, cell.wide == .wide);
    }
    try flush(a, segs, &text, &runs, r, seg_col, false);
}

fn flush(a: Allocator, segs: *std.ArrayList(Segment), text: *std.ArrayList(u8), runs: *std.ArrayList(Run), r: u16, col: u16, wide: bool) !void {
    if (text.items.len == 0) return;
    // Drop all-blank segments (nothing to draw; backgrounds are quads).
    if (std.mem.trim(u8, text.items, " ").len == 0) {
        text.clearRetainingCapacity();
        runs.clearRetainingCapacity();
        return;
    }
    // Trim trailing undecorated blanks (common: the rest of the row).
    while (text.items.len > 0 and text.items[text.items.len - 1] == ' ') {
        const last = &runs.items[runs.items.len - 1];
        if (last.style.underline != .none or last.style.strikethrough) break;
        text.items.len -= 1;
        last.len -= 1;
        if (last.len == 0) runs.items.len -= 1;
    }
    try segs.append(a, .{
        .row = r,
        .col = col,
        .text = try text.toOwnedSlice(a),
        .runs = try runs.toOwnedSlice(a),
        .wide = wide,
    });
}

// ---------------------------------------------------------------------------

test "plan pins non-ascii glyphs and merges backgrounds" {
    const Emulator = @import("Emulator.zig");
    const testing = std.testing;
    const e = try Emulator.create(testing.allocator, .{ .cols = 20, .rows = 3, .io = testing.io });
    defer e.destroy();
    _ = e.feed("ab│cd宽\x1b[41m  \x1b[0m\x1b[1;31mX");
    const snap = try e.snapshot();
    var plan = try build(testing.allocator, snap, &palette_mod.zeron_dark_fallback);
    defer plan.deinit();
    // "ab" | "│" | "cd" | "宽" | "  X" (blank cells draw nothing; bg is a quad)
    try testing.expectEqual(@as(usize, 5), plan.segments.len);
    try testing.expectEqualStrings("ab", plan.segments[0].text);
    try testing.expectEqual(@as(u16, 2), plan.segments[1].col);
    try testing.expectEqualStrings("│", plan.segments[1].text);
    try testing.expectEqual(@as(u16, 5), plan.segments[3].col);
    try testing.expect(plan.segments[3].wide);
    try testing.expectEqual(@as(u16, 7), plan.segments[4].col);
    try testing.expectEqualStrings("  X", plan.segments[4].text);
    // Bold keeps its base color (no bold-as-bright, like zeron).
    try testing.expectEqual(palette_mod.zeron_dark_fallback.ansi[1], plan.segments[4].runs[1].style.color);
    try testing.expect(plan.segments[4].runs[1].style.bold);
    try testing.expectEqual(@as(usize, 1), plan.backgrounds.len);
    try testing.expectEqual(@as(u16, 7), plan.backgrounds[0].col);
    try testing.expectEqual(@as(u16, 2), plan.backgrounds[0].len);
    try testing.expectEqual(@as(u16, 10), plan.cursor.?.col);
}
