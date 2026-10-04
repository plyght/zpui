//! Changes-pane row elements — port of zeron `changes.rs` `notice_row`,
//! `hunk_header_row`, `code_text_viewport`, `diff_line_row`,
//! `meta_line_row`, `split_line_cell`, `split_filler`, `split_row` and
//! `render_file_body_upto` (the fold tween's clipped stand-in).
//!
//! Every row is a fixed 21px line in nowrap mode (the code plane scrolls
//! horizontally per file through a shared `ScrollHandle`), or grows to its
//! wrapped height with `wrap = true`.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const diff = @import("zeron_diff");
const syntax = @import("zeron_syntax");
const md = @import("zeron_ui_markdown");
const m = @import("model.zig");
const hl = @import("highlight.zig");

const Theme = zt.Theme;
const Hsla = zpui.Hsla;
const div = zpui.div;
const px = zpui.px;
const AnyElement = zpui.AnyElement;
const Font = zpui.text.Font;
const DiffLine = diff.DiffLine;
const FileDiff = diff.FileDiff;

fn frameAlloc() std.mem.Allocator {
    return zpui.window.arena_mod.frameAllocator();
}

/// How the code plane is sized.
pub const CodeWidth = union(enum) {
    /// Clip locally (no shared horizontal scroll).
    clipped,
    /// Fixed intrinsic width shared by every row of the file (scrollable).
    scrollable: f32,
    /// Consume the viewport width and wrap.
    wrapped,
};

/// A per-file horizontal scroll slot for one code viewport.
pub const CodeScroll = struct {
    handle: zpui.ScrollHandle,
    /// Unique id for this viewport (string literal or frame-arena string).
    id: []const u8,
};

pub fn addColor(theme: *const Theme) Hsla {
    return theme.diff_add;
}

pub fn delColor(theme: *const Theme) Hsla {
    return theme.diff_del;
}

/// One notice row ("New file", "Binary file — contents not shown", …).
pub fn noticeRow(text: []const u8, theme: *const Theme) zpui.Div {
    return div().h(px(m.notice_height)).wFull().flexNone().flex().itemsCenter()
        .px(px(16)).textSize(px(11)).textColor(theme.text_faint).child(text);
}

/// One `@@ … @@` hunk-header row on the bluish-grey wash.
pub fn hunkHeaderRow(header: []const u8, theme: *const Theme) zpui.Div {
    return div().h(px(m.hunk_header_height)).wFull().flexNone().flex().itemsCenter()
        .px(px(16)).bg(theme.diff_hunk_bg)
        .fontFamily(theme.font_mono).textSize(px(11)).textColor(theme.text_faint)
        .whitespaceNowrap().overflowHidden().child(header);
}

/// `\ No newline at end of file`: indented past the columns, never tinted.
pub fn metaLineRow(text: []const u8, theme: *const Theme, pad_left: f32) zpui.Div {
    return div().h(px(m.line_height)).wFull().flexNone().flex().itemsCenter()
        .pl(px(pad_left)).textSize(px(10.5)).textColor(theme.text_faint).italic().child(text);
}

/// The paint-only syntax runs for one diff line (text already tab-expanded).
pub fn lineRuns(text: []const u8, spans: []const syntax.HighlightSpan, theme: *const Theme) []zpui.text.TextRun {
    const mono: Font = .{ .family = theme.font_mono };
    return md.runsForSyntaxLine(text, spans, mono, theme.text.opacity(0.92), theme);
}

/// Text + runs for a line: tabs expanded (spans dropped then — byte offsets
/// no longer line up), empty lines given one space so the row keeps height.
pub fn lineText(line: *const DiffLine, spans: []const syntax.HighlightSpan, theme: *const Theme) struct { []const u8, []zpui.text.TextRun } {
    const expanded = m.expandTabs(frameAlloc(), line.text);
    const text = if (expanded.len == 0) " " else expanded;
    const use_spans = if (expanded.ptr == line.text.ptr and expanded.len > 0) spans else &[_]syntax.HighlightSpan{};
    return .{ text, lineRuns(text, use_spans, theme) };
}

/// The only part of a row allowed to exceed its viewport.
pub fn codeViewport(text: []const u8, runs: []zpui.text.TextRun, theme: *const Theme, padding_left: f32, width: CodeWidth, scroll: ?CodeScroll) AnyElement {
    const wrapped = width == .wrapped;
    var content = div().pl(px(padding_left)).fontFamily(theme.font_mono)
        .textSize(px(m.text_size)).lineHeight(px(m.line_height));
    content = if (wrapped) content.wFull().minW0().whitespaceNormal() else content.whitespaceNowrap();
    if (width == .scrollable) content = content.w(px(width.scrollable)).flexNone().overflowHidden();
    content = content.child(zpui.StyledText.init(text).withRuns(runs));
    const viewport = div().flex1().minW0().minH(px(m.line_height)).overflowHidden().child(content);
    if (wrapped) return zpui.intoAnyElement(viewport);
    if (scroll) |s| {
        if (width == .scrollable) {
            var sv = viewport.id(s.id).overflowXScroll().trackScroll(s.handle);
            sv.style().restrict_scroll_to_axis = true;
            return zpui.intoAnyElement(sv);
        }
    }
    return zpui.intoAnyElement(viewport);
}

const Spec = struct {
    marker: []const u8,
    marker_color: Hsla,
    bg: ?Hsla,
    accent: ?Hsla,
    number: Hsla,
};

fn spec(kind: diff.LineKind, theme: *const Theme) Spec {
    const add = addColor(theme);
    const del = delColor(theme);
    return switch (kind) {
        .add => .{ .marker = "+", .marker_color = add, .bg = add.alpha(0.055), .accent = add.opacity(0.55), .number = add.opacity(0.9) },
        .del => .{ .marker = "\u{2212}", .marker_color = del, .bg = del.alpha(0.055), .accent = del.opacity(0.55), .number = del.opacity(0.9) },
        else => .{ .marker = "\u{00b7}", .marker_color = theme.text_faint.opacity(0.5), .bg = null, .accent = null, .number = theme.text_faint.opacity(0.8) },
    };
}

fn gutterCell(no: ?u32, color: Hsla, w: f32, theme: *const Theme) zpui.Div {
    return div().w(px(w)).flexNone().fontFamily(theme.font_mono).textSize(px(11)).lineHeight(px(m.line_height))
        .textColor(color).flex().justifyEnd().pr(px(8))
        .child(if (no) |n| @as(?[]const u8, zpui.fmt("{d}", .{n})) else null);
}

fn markerCell(s: Spec, w: f32, theme: *const Theme) zpui.Div {
    return div().w(px(w)).flexNone().flex().justifyCenter().textSize(px(m.text_size)).lineHeight(px(m.line_height))
        .textColor(s.marker_color).fontFamily(theme.font_mono).child(s.marker);
}

fn accentBar(s: Spec) zpui.Div {
    var bar = div().w(px(m.accent_bar_width)).selfStretch().flexNone();
    if (s.accent) |c| bar = bar.bg(c);
    return bar;
}

/// Unified content width for a file whose widest line is `max_text` px.
pub fn unifiedContentWidth(max_text: f32) f32 {
    return max_text + m.unified_code_padding_left + m.code_padding_right;
}

pub fn splitContentWidth(max_text: f32) f32 {
    return max_text + m.split_code_padding_left + m.code_padding_right;
}

/// One +/−/context/meta diff line (unified layout).
pub fn diffLineRow(line: *const DiffLine, spans: []const syntax.HighlightSpan, theme: *const Theme, gutter: f32, width: CodeWidth, scroll: ?CodeScroll) zpui.Div {
    if (line.kind == .meta) return metaLineRow(line.text, theme, m.accent_bar_width + 2 * gutter + m.marker_width + 12);
    const s = spec(line.kind, theme);
    const faint_no = theme.text_faint.opacity(0.8);
    const text, const runs = lineText(line, spans, theme);
    var row = div().wFull().flexNone().flex().flexRow().itemsStart();
    row = if (width == .wrapped) row.minH(px(m.line_height)) else row.h(px(m.line_height));
    if (s.bg) |bg| row = row.bg(bg);
    return row.child(accentBar(s))
        .child(gutterCell(line.old_no, if (line.kind == .del) s.number else faint_no, gutter, theme))
        .child(gutterCell(line.new_no, if (line.kind == .add) s.number else faint_no, gutter, theme))
        .child(markerCell(s, m.marker_width, theme))
        .child(codeViewport(text, runs, theme, m.unified_code_padding_left, width, scroll));
}

/// One half of a split row.
pub fn splitLineCell(line: *const DiffLine, number: ?u32, spans: []const syntax.HighlightSpan, theme: *const Theme, gutter: f32, width: CodeWidth, scroll: ?CodeScroll) zpui.Div {
    const s = spec(line.kind, theme);
    const text, const runs = lineText(line, spans, theme);
    var cell = div().flex1().minW0().selfStretch().overflowHidden().flex().flexRow().itemsStart();
    if (s.bg) |bg| cell = cell.bg(bg);
    return cell.child(accentBar(s))
        .child(gutterCell(number, s.number, gutter, theme))
        .child(markerCell(s, m.split_marker_width, theme))
        .child(codeViewport(text, runs, theme, m.split_code_padding_left, width, scroll));
}

/// The empty half of a one-sided split row.
pub fn splitFiller(theme: *const Theme) zpui.Div {
    return div().flex1().minW0().selfStretch().bg(theme.ink(0.03));
}

/// Compose the two halves with the centre hairline.
pub fn splitRow(left: AnyElement, right: AnyElement, wrapped: bool, theme: *const Theme) zpui.Div {
    var row = div().wFull().flexNone().flex().flexRow().itemsStretch();
    row = if (wrapped) row.minH(px(m.line_height)) else row.h(px(m.line_height));
    return row.child(left)
        .child(div().w(px(m.split_divider_width)).selfStretch().flexNone().bg(theme.hairline(0.06)))
        .child(right);
}

/// A full split row for `pair` within `hunk` (shared by the virtual list and
/// the fold stand-in).
pub fn splitPairRow(hunk: *const diff.Hunk, left_ix: ?u32, right_ix: ?u32, highlights: ?*const hl.FileHighlights, theme: *const Theme, gutter: f32, width: CodeWidth, scroll_left: ?CodeScroll, scroll_right: ?CodeScroll) zpui.Div {
    const left = if (left_ix) |i| &hunk.lines[i] else null;
    const right = if (right_ix) |i| &hunk.lines[i] else null;
    for ([_]?*const DiffLine{ left, right }) |maybe| if (maybe) |l| if (l.kind == .meta) {
        return metaLineRow(l.text, theme, 2 * (m.accent_bar_width + gutter));
    };
    const lcell: AnyElement = if (left) |l|
        zpui.intoAnyElement(splitLineCell(l, l.old_no, hl.spansFor(highlights, l), theme, gutter, width, scroll_left))
    else
        zpui.intoAnyElement(splitFiller(theme));
    const rcell: AnyElement = if (right) |r|
        zpui.intoAnyElement(splitLineCell(r, r.new_no, hl.spansFor(highlights, r), theme, gutter, width, scroll_right))
    else
        zpui.intoAnyElement(splitFiller(theme));
    return splitRow(lcell, rcell, width == .wrapped, theme);
}

/// Build only rows that start above `max_px` (the fold tween's stand-in).
pub fn fileBodyUpto(file: *const FileDiff, highlights: ?*const hl.FileHighlights, theme: *const Theme, max_px: f32, mode: m.DiffMode, width: CodeWidth, scroll: ?zpui.ScrollHandle, prefix: []const u8) zpui.Div {
    const a = frameAlloc();
    var col = div().flex().flexCol().pb(px(m.body_bottom_pad)).wFull();
    var y: f32 = 0;
    const gutter = m.gutterWidth(file);
    const notices = diff.fileNotices(a, file.*) catch &.{};
    for (notices) |n| {
        if (y >= max_px) return col;
        col = col.child(noticeRow(n, theme));
        y += m.notice_height;
    }
    for (file.hunks, 0..) |*hunk, hi| {
        if (y >= max_px) return col;
        col = col.child(hunkHeaderRow(hunk.header, theme));
        y += m.hunk_header_height;
        switch (mode) {
            .unified => for (hunk.lines, 0..) |*line, li| {
                if (y >= max_px) return col;
                const sc: ?CodeScroll = if (scroll) |h| .{ .handle = h, .id = zpui.fmt("{s}-{d}-{d}", .{ prefix, hi, li }) } else null;
                col = col.child(diffLineRow(line, hl.spansFor(highlights, line), theme, gutter, width, sc));
                y += m.line_height;
            },
            .split => {
                const budget: usize = @intFromFloat(@max(@ceil((max_px - y) / m.line_height), 0));
                const pairs = diff.splitPairsUpto(a, hunk.lines, budget) catch &.{};
                for (pairs, 0..) |p, pi| {
                    if (y >= max_px) return col;
                    const sl: ?CodeScroll = if (scroll) |h| .{ .handle = h, .id = zpui.fmt("{s}-{d}-{d}-old", .{ prefix, hi, pi }) } else null;
                    const sr: ?CodeScroll = if (scroll) |h| .{ .handle = h, .id = zpui.fmt("{s}-{d}-{d}-new", .{ prefix, hi, pi }) } else null;
                    col = col.child(splitPairRow(hunk, p.left, p.right, highlights, theme, gutter, width, sl, sr));
                    y += m.line_height;
                }
            },
        }
    }
    return col;
}

/// Stacked body of one file (no virtualization) — for embedding elsewhere.
pub fn fileBody(file: *const FileDiff, highlights: ?*const hl.FileHighlights, theme: *const Theme) zpui.Div {
    return fileBodyUpto(file, highlights, theme, std.math.floatMax(f32), .unified, .clipped, null, "body");
}
