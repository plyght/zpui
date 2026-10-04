//! `DisplayMap`: buffer lines ↔ display rows for the virtualized editor.
//!
//! Without soft wrap every line is one row (no tables at all, so a
//! 1M-line file costs nothing). With soft wrap each line's row count is
//! computed from its text in *columns*: the editor font is monospace (Geist
//! Mono), so breaking by column count matches shaping without shaping every
//! line of a huge file. Wide (East Asian / emoji) scalars count two columns,
//! tabs expand to `tab_width` columns. Breaks prefer the position after a
//! space run (gpui's `LineWrapper` word wrapping) and fall back to a hard
//! break inside long words.
//!
//! Row counts are kept per line with lazily rebuilt prefix sums; edits
//! splice only the touched lines (`applyLineEdit`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Columns a tab occupies on screen.
pub const tab_width: usize = 4;

/// Display width (columns) of the scalar starting at `b[i]`, and its byte length.
pub fn scalarCols(b: []const u8, i: usize) struct { cols: usize, len: usize } {
    const c = b[i];
    if (c < 0x80) return .{ .cols = if (c == '\t') tab_width else 1, .len = 1 };
    const n: usize = if (c >= 0xF0) 4 else if (c >= 0xE0) 3 else if (c >= 0xC0) 2 else 1;
    const l = @min(n, b.len - i);
    const cp = std.unicode.utf8Decode(b[i .. i + l]) catch return .{ .cols = 1, .len = 1 };
    return .{ .cols = if (isWide(cp)) 2 else if (isZeroWidth(cp)) 0 else 1, .len = l };
}

fn isZeroWidth(cp: u21) bool {
    return (cp >= 0x300 and cp <= 0x36F) or cp == 0x200D or (cp >= 0xFE00 and cp <= 0xFE0F);
}

pub fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1FAFF) or
        (cp >= 0x20000 and cp <= 0x3FFFD);
}

/// Columns of a whole line.
pub fn lineCols(b: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < b.len) {
        if (b[i] < 0x80) {
            cols += if (b[i] == '\t') tab_width else 1;
            i += 1;
            continue;
        }
        const s = scalarCols(b, i);
        cols += s.cols;
        i += s.len;
    }
    return cols;
}

/// Byte offsets where wrapped rows after the first start (appended to `out`).
pub fn wrapBreaks(b: []const u8, max_cols: usize, out: *std.ArrayList(usize), gpa: Allocator) Allocator.Error!void {
    if (max_cols == 0 or b.len <= max_cols and std.mem.indexOfScalar(u8, b, '\t') == null and isAscii(b)) return;
    var row_start: usize = 0;
    var cols: usize = 0;
    var last_break: ?usize = null; // byte after a space run inside the current row
    var i: usize = 0;
    while (i < b.len) {
        const s = scalarCols(b, i);
        if (cols + s.cols > max_cols and i > row_start) {
            const at = if (last_break) |lb| (if (lb > row_start) lb else i) else i;
            try out.append(gpa, at);
            row_start = at;
            last_break = null;
            // Recount the columns carried into the new row.
            cols = 0;
            var j = row_start;
            while (j < i) {
                const t = scalarCols(b, j);
                cols += t.cols;
                j += t.len;
            }
            continue;
        }
        cols += s.cols;
        const was_space = b[i] == ' ' or b[i] == '\t';
        i += s.len;
        if (was_space and (i >= b.len or (b[i] != ' ' and b[i] != '\t'))) last_break = i;
    }
}

fn isAscii(b: []const u8) bool {
    for (b) |c| if (c >= 0x80) return false;
    return true;
}

pub fn rowCountFor(b: []const u8, max_cols: usize, scratch: *std.ArrayList(usize), gpa: Allocator) usize {
    if (max_cols == 0) return 1;
    if (b.len <= max_cols and isAscii(b) and std.mem.indexOfScalar(u8, b, '\t') == null) return 1;
    scratch.clearRetainingCapacity();
    wrapBreaks(b, max_cols, scratch, gpa) catch @panic("OOM");
    return scratch.items.len + 1;
}

pub const RowPos = struct { line: usize, sub: usize };

pub const DisplayMap = struct {
    gpa: Allocator,
    /// Wrap width in columns; null = no soft wrap.
    wrap_cols: ?usize = null,
    /// Rows per line (only with wrap).
    counts: std.ArrayList(u32) = .empty,
    /// prefix[i] = rows before line i (len = lines + 1), rebuilt lazily.
    prefix: std.ArrayList(u32) = .empty,
    prefix_valid: bool = false,
    lines: usize = 1,
    scratch: std.ArrayList(usize) = .empty,

    pub fn init(gpa: Allocator) DisplayMap {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *DisplayMap) void {
        self.counts.deinit(self.gpa);
        self.prefix.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
    }

    pub fn wraps(self: *const DisplayMap) bool {
        return self.wrap_cols != null;
    }

    /// Rebuild for `line_count` lines; `textOf(ctx, line)` yields a line's text.
    pub fn rebuild(self: *DisplayMap, wrap_cols: ?usize, line_count: usize, ctx: anytype, comptime textOf: fn (@TypeOf(ctx), usize) []const u8) void {
        self.wrap_cols = wrap_cols;
        self.lines = line_count;
        self.prefix_valid = false;
        if (wrap_cols == null) {
            self.counts.clearRetainingCapacity();
            return;
        }
        self.counts.resize(self.gpa, line_count) catch @panic("OOM");
        for (0..line_count) |l| {
            self.counts.items[l] = @intCast(rowCountFor(textOf(ctx, l), wrap_cols.?, &self.scratch, self.gpa));
        }
    }

    /// Lines `[line, line + removed)` became `added` lines.
    pub fn applyLineEdit(self: *DisplayMap, line: usize, removed: usize, added: usize, ctx: anytype, comptime textOf: fn (@TypeOf(ctx), usize) []const u8) void {
        self.lines = self.lines - removed + added;
        self.prefix_valid = false;
        const cols = self.wrap_cols orelse return;
        const at = @min(line, self.counts.items.len);
        const rm = @min(removed, self.counts.items.len - at);
        var fresh: [64]u32 = undefined;
        if (added <= fresh.len) {
            for (0..added) |k| fresh[k] = @intCast(rowCountFor(textOf(ctx, line + k), cols, &self.scratch, self.gpa));
            self.counts.replaceRange(self.gpa, at, rm, fresh[0..added]) catch @panic("OOM");
        } else {
            const buf = self.gpa.alloc(u32, added) catch @panic("OOM");
            defer self.gpa.free(buf);
            for (0..added) |k| buf[k] = @intCast(rowCountFor(textOf(ctx, line + k), cols, &self.scratch, self.gpa));
            self.counts.replaceRange(self.gpa, at, rm, buf) catch @panic("OOM");
        }
    }

    fn ensurePrefix(self: *DisplayMap) void {
        if (self.prefix_valid or self.wrap_cols == null) return;
        const n = self.counts.items.len;
        self.prefix.resize(self.gpa, n + 1) catch @panic("OOM");
        var acc: u32 = 0;
        for (self.counts.items, 0..) |c, i| {
            self.prefix.items[i] = acc;
            acc += c;
        }
        self.prefix.items[n] = acc;
        self.prefix_valid = true;
    }

    pub fn rowCount(self: *DisplayMap) usize {
        if (self.wrap_cols == null) return self.lines;
        self.ensurePrefix();
        return self.prefix.items[self.prefix.items.len - 1];
    }

    pub fn rowsOfLine(self: *DisplayMap, line: usize) usize {
        if (self.wrap_cols == null) return 1;
        return if (line < self.counts.items.len) self.counts.items[line] else 1;
    }

    pub fn firstRowOfLine(self: *DisplayMap, line: usize) usize {
        if (self.wrap_cols == null) return line;
        self.ensurePrefix();
        return self.prefix.items[@min(line, self.prefix.items.len - 1)];
    }

    pub fn lineForRow(self: *DisplayMap, row: usize) RowPos {
        if (self.wrap_cols == null) return .{ .line = @min(row, self.lines -| 1), .sub = 0 };
        self.ensurePrefix();
        const p = self.prefix.items;
        const n = self.counts.items.len;
        if (n == 0) return .{ .line = 0, .sub = 0 };
        if (row >= p[n]) return .{ .line = n - 1, .sub = self.counts.items[n - 1] - 1 };
        var lo: usize = 0;
        var hi: usize = n; // p[lo] <= row < p[hi]
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (p[mid] <= row) lo = mid else hi = mid;
        }
        return .{ .line = lo, .sub = row - p[lo] };
    }

    /// Byte ranges (line-relative) of each row of `text` (`out` gets row starts; the
    /// row's end is the next start or text.len).
    pub fn rowStarts(self: *DisplayMap, text: []const u8, out: *std.ArrayList(usize), gpa: Allocator) void {
        out.clearRetainingCapacity();
        out.append(gpa, 0) catch @panic("OOM");
        const cols = self.wrap_cols orelse return;
        wrapBreaks(text, cols, out, gpa) catch @panic("OOM");
    }
};

const testing = std.testing;

test "word wrap prefers spaces and hard-breaks long words" {
    var out: std.ArrayList(usize) = .empty;
    defer out.deinit(testing.allocator);
    try wrapBreaks("hello world foo", 8, &out, testing.allocator);
    try testing.expectEqualSlices(usize, &.{ 6, 12 }, out.items);
    out.clearRetainingCapacity();
    try wrapBreaks("abcdefghijkl", 5, &out, testing.allocator);
    try testing.expectEqualSlices(usize, &.{ 5, 10 }, out.items);
}

const Lines = struct {
    items: []const []const u8,
    fn text(self: *const Lines, i: usize) []const u8 {
        return self.items[i];
    }
};

test "display map row lookup with wrap" {
    var m = DisplayMap.init(testing.allocator);
    defer m.deinit();
    const lines = Lines{ .items = &.{ "short", "a long line that wraps around", "", "x" } };
    m.rebuild(10, lines.items.len, &lines, Lines.text);
    try testing.expectEqual(@as(usize, 1), m.rowsOfLine(0));
    try testing.expect(m.rowsOfLine(1) >= 3);
    const total = m.rowCount();
    try testing.expectEqual(@as(usize, 3) + m.rowsOfLine(1), total);
    const pos = m.lineForRow(2);
    try testing.expectEqual(@as(usize, 1), pos.line);
    try testing.expectEqual(@as(usize, 1), pos.sub);
    try testing.expectEqual(@as(usize, 1), m.firstRowOfLine(1));
    try testing.expectEqual(RowPos{ .line = 3, .sub = 0 }, m.lineForRow(total - 1));
    // Without wrap rows are lines.
    m.rebuild(null, 4, &lines, Lines.text);
    try testing.expectEqual(@as(usize, 4), m.rowCount());
    try testing.expectEqual(RowPos{ .line = 2, .sub = 0 }, m.lineForRow(2));
}
