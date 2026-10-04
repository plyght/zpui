//! Render snapshot: a renderer-friendly copy of the visible grid built from
//! Ghostty's `RenderState` (which already tracks per-row damage, the
//! selection overlay and cursor state).
//!
//! Colors stay *unresolved* (`CellColor`): the view resolves them against
//! the zeron theme (see `palette.zig`), exactly like zeron's
//! `emulator.rs` `CellColor` + `view.rs` `resolve_color`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const vt = @import("ghostty-vt");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }
};

/// A cell's paint color, decoupled from the palette.
pub const CellColor = union(enum) {
    /// Default foreground/background (whichever slot this is).
    default,
    /// Indexed: 0-15 ANSI, 16-231 color cube, 232-255 grayscale ramp.
    indexed: u8,
    /// Direct 24-bit color.
    rgb: Rgb,

    pub fn eql(a: CellColor, b: CellColor) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |i| b == .indexed and b.indexed == i,
            .rgb => |c| b == .rgb and b.rgb.eql(c),
        };
    }

    fn fromStyle(c: vt.Style.Color) CellColor {
        return switch (c) {
            .none => .default,
            .palette => |i| .{ .indexed = i },
            .rgb => |v| .{ .rgb = .{ .r = v.r, .g = v.g, .b = v.b } },
        };
    }
};

pub const Underline = enum { none, single, double, curly, dotted, dashed };

pub const Wide = enum {
    narrow,
    /// A double-width char (occupies this cell plus the next spacer cell).
    wide,
    /// The spacer half of a wide char: never shaped, only background-painted.
    spacer_tail,
    /// End-of-line padding before a wide char that wrapped to the next row.
    spacer_head,
};

pub const Attrs = packed struct(u8) {
    bold: bool = false,
    faint: bool = false,
    italic: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
};

/// Which color slot a resolved color is painted into (needed to resolve
/// `CellColor.default`).
pub const Slot = enum { fg, bg };

pub const Cell = struct {
    /// Base codepoint; 0 = empty cell.
    codepoint: u21 = 0,
    /// Extra codepoints of a grapheme cluster (combining marks, ZWJ
    /// sequences, VS16...). Borrowed from the render state.
    grapheme: []const u21 = &.{},
    fg: CellColor = .default,
    bg: CellColor = .default,
    underline_color: CellColor = .default,
    attrs: Attrs = .{},
    underline: Underline = .none,
    wide: Wide = .narrow,
    /// OSC 8 hyperlink present (see `Emulator.hyperlinkAt` for the URI).
    hyperlink: bool = false,
    /// Inside the active selection: the view paints a wash over this cell.
    selected: bool = false,

    pub fn isEmpty(self: Cell) bool {
        return self.codepoint == 0 and self.grapheme.len == 0;
    }

    /// Effective paint colors after INVERSE/HIDDEN resolution (zeron's
    /// `CellSnapshot::display_colors`). The slots tell `palette.resolve`
    /// which default to use for `.default`.
    pub fn displayColors(self: Cell) struct { fg: CellColor, fg_slot: Slot, bg: CellColor, bg_slot: Slot } {
        var fg = self.fg;
        var fg_slot: Slot = .fg;
        var bg = self.bg;
        var bg_slot: Slot = .bg;
        if (self.attrs.inverse) {
            std.mem.swap(CellColor, &fg, &bg);
            std.mem.swap(Slot, &fg_slot, &bg_slot);
        }
        if (self.attrs.invisible) {
            fg = bg;
            fg_slot = bg_slot;
        }
        return .{ .fg = fg, .fg_slot = fg_slot, .bg = bg, .bg_slot = bg_slot };
    }
};

pub const Row = struct {
    cells: []const Cell,
    /// Changed since the previous snapshot (damage tracking).
    dirty: bool,
    /// The row soft-wraps onto the next one.
    wrapped: bool,
};

pub const CursorStyle = enum { block, bar, underline, block_hollow };

pub const Cursor = struct {
    row: u16,
    col: u16,
    style: CursorStyle,
    blinking: bool,
    /// The cursor sits on the spacer half of a wide char; renderers may
    /// draw it one cell to the left, covering the glyph.
    wide_tail: bool,
};

pub const Damage = enum {
    /// Nothing changed since the last snapshot.
    none,
    /// Some rows changed (see `Row.dirty`).
    partial,
    /// Everything must be redrawn (resize, screen switch, palette...).
    full,
};

pub const Snapshot = struct {
    cols: u16 = 0,
    rows: u16 = 0,
    lines: []const Row = &.{},
    /// Null when hidden (DECTCEM) or scrolled out of the viewport.
    cursor: ?Cursor = null,
    damage: Damage = .full,
    /// Lines scrolled back into history (0 = live bottom).
    display_offset: usize = 0,
    history_lines: usize = 0,

    pub fn cell(self: *const Snapshot, row: usize, col: usize) Cell {
        return self.lines[row].cells[col];
    }

    /// A row as trimmed UTF-8 text (wide spacers skipped). Caller owns.
    pub fn rowText(self: *const Snapshot, gpa: Allocator, row: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        for (self.lines[row].cells) |c| {
            if (c.wide == .spacer_tail or c.wide == .spacer_head) continue;
            try appendCp(&out, gpa, if (c.codepoint == 0) ' ' else c.codepoint);
            for (c.grapheme) |g| try appendCp(&out, gpa, g);
        }
        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
        return out.toOwnedSlice(gpa);
    }
};

fn appendCp(out: *std.ArrayList(u8), gpa: Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try out.appendSlice(gpa, buf[0..n]);
}

/// Owned backing memory for a `Snapshot`, reused across frames.
pub const Storage = struct {
    cells: std.ArrayList(Cell) = .empty,
    rows: std.ArrayList(Row) = .empty,
    snapshot: Snapshot = .{},

    pub fn deinit(self: *Storage, gpa: Allocator) void {
        self.cells.deinit(gpa);
        self.rows.deinit(gpa);
        self.* = undefined;
    }

    pub fn fill(
        self: *Storage,
        gpa: Allocator,
        rs: *const vt.RenderState,
        display_offset: usize,
        history_lines: usize,
    ) !void {
        const ncols: usize = rs.cols;
        const range = rs.rowDataRange();
        const nrows: usize = range.end - range.start;
        try self.cells.resize(gpa, ncols * nrows);
        try self.rows.resize(gpa, nrows);

        const data = rs.row_data.slice();
        const row_cells = data.items(.cells);
        const row_raw = data.items(.raw);
        const row_dirty = data.items(.dirty);
        const row_sel = data.items(.selection);

        for (range.start..range.end, 0..) |i, y| {
            const out = self.cells.items[y * ncols ..][0..ncols];
            const cs = row_cells[i].slice();
            const raws = cs.items(.raw);
            const graphemes = cs.items(.grapheme);
            const styles = cs.items(.style);
            const sel = row_sel[i];
            for (out, 0..) |*o, x| {
                const raw = raws[x];
                o.* = .{};
                switch (raw.content_tag) {
                    .codepoint => o.codepoint = raw.content.codepoint.data,
                    .codepoint_grapheme => {
                        o.codepoint = raw.content.codepoint.data;
                        o.grapheme = graphemes[x];
                    },
                    .bg_color_palette => o.bg = .{ .indexed = raw.content.color_palette.data },
                    .bg_color_rgb => {
                        const c = raw.content.color_rgb;
                        o.bg = .{ .rgb = .{ .r = c.r, .g = c.g, .b = c.b } };
                    },
                }
                o.wide = switch (raw.wide) {
                    .narrow => .narrow,
                    .wide => .wide,
                    .spacer_tail => .spacer_tail,
                    .spacer_head => .spacer_head,
                };
                o.hyperlink = raw.hyperlink;
                if (raw.style_id != 0) {
                    const st = styles[x];
                    o.fg = .fromStyle(st.fg_color);
                    if (raw.content_tag == .codepoint or raw.content_tag == .codepoint_grapheme) {
                        o.bg = .fromStyle(st.bg_color);
                    }
                    o.underline_color = .fromStyle(st.underline_color);
                    o.attrs = .{
                        .bold = st.flags.bold,
                        .faint = st.flags.faint,
                        .italic = st.flags.italic,
                        .blink = st.flags.blink,
                        .inverse = st.flags.inverse,
                        .invisible = st.flags.invisible,
                        .strikethrough = st.flags.strikethrough,
                        .overline = st.flags.overline,
                    };
                    o.underline = switch (st.flags.underline) {
                        .none => .none,
                        .single => .single,
                        .double => .double,
                        .curly => .curly,
                        .dotted => .dotted,
                        .dashed => .dashed,
                    };
                }
                if (sel) |s| o.selected = x >= s[0] and x <= s[1];
            }
            self.rows.items[y] = .{
                .cells = out,
                .dirty = row_dirty[i] or rs.dirty == .full,
                .wrapped = row_raw[i].wrap,
            };
        }

        const c = rs.cursor;
        const cursor: ?Cursor = if (c.visible) if (c.viewport) |vp| .{
            .row = vp.y,
            .col = vp.x,
            .style = switch (c.visual_style) {
                .bar => .bar,
                .block => .block,
                .underline => .underline,
                .block_hollow => .block_hollow,
            },
            .blinking = c.blinking,
            .wide_tail = vp.wide_tail,
        } else null else null;

        self.snapshot = .{
            .cols = rs.cols,
            .rows = @intCast(nrows),
            .lines = self.rows.items,
            .cursor = cursor,
            .damage = switch (rs.dirty) {
                .false => .none,
                .partial => .partial,
                .full => .full,
            },
            .display_offset = display_offset,
            .history_lines = history_lines,
        };
    }
};
