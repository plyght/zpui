//! An inline tool diff body — port of zeron changes.rs
//! `render_file_body_with_syntax` (`hunk_header_row`, `diff_line_row`,
//! `notice_row`): hunk headers on the bluish wash, 21px unified rows with a
//! 3px accent bar, dual line-number gutters, a ± marker column, red/green row
//! tints and paint-only syntax runs in Geist Mono 12.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const diff = @import("zeron_diff");
const syntax = @import("zeron_syntax");
const md = @import("zeron_ui_markdown");

const Theme = zt.Theme;
const Hsla = zpui.Hsla;
const div = zpui.div;
const px = zpui.px;
const AnyElement = zpui.AnyElement;
const Font = zpui.text.Font;

pub const hunk_header_height: f32 = 28;
pub const line_height: f32 = 21;
pub const notice_height: f32 = 24;
pub const body_bottom_pad: f32 = 8;
pub const gutter_min: f32 = 36;
pub const marker_width: f32 = 28;
pub const accent_bar_width: f32 = 3;
pub const text_size: f32 = 12;
const code_padding_left: f32 = 12;

pub fn gutterWidth(file: diff.FileDiff) f32 {
    const digits: f32 = @floatFromInt(std.math.log10_int(@max(file.max_line, 1)) + 1);
    return @max(digits * 6.6 + 8 + 6, gutter_min);
}

fn noticeCount(file: diff.FileDiff) usize {
    var n: usize = file.notices.len;
    if (file.status != .modified) n += 1;
    if (file.binary) n += 1;
    return n;
}

/// Analytic body height (drives the fold tween without measuring).
pub fn bodyHeight(file: diff.FileDiff) f32 {
    var h: f32 = @as(f32, @floatFromInt(noticeCount(file))) * notice_height + body_bottom_pad;
    for (file.hunks) |hunk| h += hunk_header_height + @as(f32, @floatFromInt(hunk.lines.len)) * line_height;
    return h;
}

/// Render the body. `old_text`/`new_text` (when present) feed per-line syntax
/// highlighting keyed by the file path.
pub fn render(file: diff.FileDiff, old_text: ?[]const u8, new_text: ?[]const u8, theme: *const Theme) AnyElement {
    const a = zpui.window.arena_mod.frameAllocator();
    const gutter = gutterWidth(file);
    const new_doc: ?*const syntax.HighlightedDocument = if (new_text) |t| md.code_state.highlightPath(t, file.path) else null;
    const old_doc: ?*const syntax.HighlightedDocument = if (old_text) |t| md.code_state.highlightPath(t, file.path) else null;
    var col = div().flex().flexCol().pb(px(body_bottom_pad)).wFull().minW0();
    const notices = diff.fileNotices(a, file) catch &.{};
    for (notices) |n| col = col.child(div().h(px(notice_height)).wFull().flexNone().flex().itemsCenter().px(px(16))
        .textSize(px(11)).textColor(theme.text_faint).child(n));
    for (file.hunks) |hunk| {
        col = col.child(div().h(px(hunk_header_height)).wFull().flexNone().flex().itemsCenter().px(px(16))
            .bg(theme.diff_hunk_bg).fontFamily(theme.font_mono).textSize(px(11)).textColor(theme.text_faint)
            .whitespaceNowrap().overflowHidden().child(hunk.header));
        for (hunk.lines) |line| col = col.child(lineRow(line, theme, gutter, old_doc, new_doc));
    }
    return zpui.intoAnyElement(col);
}

fn lineSpans(line: diff.DiffLine, old_doc: ?*const syntax.HighlightedDocument, new_doc: ?*const syntax.HighlightedDocument) []const syntax.HighlightSpan {
    if (line.kind == .del) {
        const d = old_doc orelse return &.{};
        const n = (line.old_no orelse return &.{}) - 1;
        return if (n < d.lineCount()) d.line(n) else &.{};
    }
    const d = new_doc orelse return &.{};
    const n = (line.new_no orelse return &.{}) - 1;
    return if (n < d.lineCount()) d.line(n) else &.{};
}

fn lineRow(line: diff.DiffLine, theme: *const Theme, gutter: f32, old_doc: ?*const syntax.HighlightedDocument, new_doc: ?*const syntax.HighlightedDocument) zpui.Div {
    const add = theme.diff_add;
    const del = theme.diff_del;
    if (line.kind == .meta) {
        return div().h(px(line_height)).wFull().flexNone().flex().itemsCenter()
            .pl(px(accent_bar_width + 2 * gutter + marker_width + 12))
            .fontFamily(theme.font_mono).textSize(px(11)).textColor(theme.text_faint).child(line.text);
    }
    const faint_no = theme.text_faint.opacity(0.8);
    const Spec = struct { marker: []const u8, marker_color: Hsla, bg: ?Hsla, accent: ?Hsla, number: Hsla };
    const spec: Spec = switch (line.kind) {
        .add => .{ .marker = "+", .marker_color = add, .bg = add.alpha(0.055), .accent = add.opacity(0.55), .number = add.opacity(0.9) },
        .del => .{ .marker = "\u{2212}", .marker_color = del, .bg = del.alpha(0.055), .accent = del.opacity(0.55), .number = del.opacity(0.9) },
        else => .{ .marker = "\u{00b7}", .marker_color = theme.text_faint.opacity(0.5), .bg = null, .accent = null, .number = faint_no },
    };
    const gutterCell = struct {
        fn f(no: ?u32, color: Hsla, w: f32, t: *const Theme) zpui.Div {
            return div().w(px(w)).flexNone().fontFamily(t.font_mono).textSize(px(11)).lineHeight(px(line_height))
                .textColor(color).flex().justifyEnd().pr(px(8))
                .child(if (no) |n| @as(?[]const u8, zpui.fmt("{d}", .{n})) else null);
        }
    }.f;
    const mono: Font = .{ .family = theme.font_mono };
    // Tabs render at 4 columns.
    const text = expandTabs(line.text);
    const runs = md.runsForSyntaxLine(text, if (text.ptr == line.text.ptr) lineSpans(line, old_doc, new_doc) else &.{}, mono, theme.text.opacity(0.92), theme);
    var row = div().h(px(line_height)).wFull().flexNone().flex().flexRow().itemsStart();
    if (spec.bg) |bg| row = row.bg(bg);
    var bar = div().w(px(accent_bar_width)).selfStretch().flexNone();
    if (spec.accent) |c| bar = bar.bg(c);
    return row.child(bar)
        .child(gutterCell(line.old_no, if (line.kind == .del) spec.number else faint_no, gutter, theme))
        .child(gutterCell(line.new_no, if (line.kind == .add) spec.number else faint_no, gutter, theme))
        .child(div().w(px(marker_width)).flexNone().flex().justifyCenter().textSize(px(text_size)).lineHeight(px(line_height))
            .textColor(spec.marker_color).fontFamily(theme.font_mono).child(spec.marker))
        .child(div().flex1().minW0().minH(px(line_height)).overflowHidden()
            .child(div().pl(px(code_padding_left)).fontFamily(theme.font_mono).textSize(px(text_size))
                .lineHeight(px(line_height)).whitespaceNowrap()
                .child(zpui.StyledText.init(if (text.len == 0) " " else text).withRuns(if (text.len == 0) &.{.{ .len = 1, .font = mono, .color = theme.text }} else runs))));
}

fn expandTabs(s: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, s, '\t') == null) return s;
    return std.mem.replaceOwned(u8, zpui.window.arena_mod.frameAllocator(), s, "\t", "    ") catch s;
}
