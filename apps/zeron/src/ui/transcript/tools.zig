//! Tool-group accordion + chips — port of zeron transcript.rs
//! `render_tool_group`, `chip_header_row`, `tool_chip`, `subagent_chip`,
//! `activity_rail`, `detail_body`, `tool_group_title`.
//!
//! A collapsible group is a quiet 26px summary header ("▸ Ran 3 commands ·
//! read 2 files", 12px muted) over a task tree: a 48px gutter with a hairline
//! trunk and rounded elbows ending at each tool's glyph, then the chip label
//! and detail. Chips expand into the full invocation and the output / inline
//! diff. Agent/spawn chips never fold; they render as bordered cards.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const md = @import("zeron_ui_markdown");
const rows = @import("rows.zig");
const thought = @import("thought.zig");
const diff_view = @import("diff_view.zig");
const assets = @import("zeron_assets");
const files = md.file_icons;
const view_mod = @import("view.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Theme = zt.Theme;
const Hsla = zpui.Hsla;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const AnyElement = zpui.AnyElement;
const Bounds = zpui.Bounds(f32);
const TranscriptView = view_mod.TranscriptView;
const ToolItem = rows.ToolItem;
const ToolDetail = rows.ToolDetail;
const motion = zt.motion;

pub const chip_height: f32 = 38;
pub const chip_card_height: f32 = 30;
pub const chip_header_height: f32 = chip_card_height - 2;
pub const activity_gutter_width: f32 = 48;
pub const activity_text_gap: f32 = 8;
pub const activity_trunk_x: f32 = 12.5;
pub const activity_bend_radius: f32 = 6;
pub const activity_branch_end_x: f32 = 28;
pub const activity_icon_left: f32 = 32;
pub const activity_icon_size: f32 = 16;
pub const tool_text_size: f32 = 12;
pub const tool_label_line_height: f32 = 18;
pub const tool_group_header_height: f32 = 26;
pub const tool_tree_row_height: f32 = 32;
pub const chips_top_pad: f32 = 2;
pub const blob_affordance_height: f32 = 24;
pub const tool_fold: motion.MotionSpec = .init(140, motion.ease_out);
pub const detail_fold: motion.MotionSpec = .init(180, motion.ease_out);
pub const shimmer_period_ns: u64 = 3_400 * std.time.ns_per_ms;
pub const shimmer_half_width: f32 = 0.36;

/// Open/closed state of a fold plus its running tween.
pub const Fold = struct {
    open: ?bool = null,
    toggled_at: ?u64 = null,
    /// Height the tween starts from.
    from: f32 = 0,
};

/// Analytic height an open detail adds (separator + body).
pub fn detailHeight(d: ToolDetail) f32 {
    const body: f32 = switch (d) {
        .output => |o| @as(f32, @floatFromInt(o.lines.len + @intFromBool(o.truncated_by > 0))) * rows.output_line_height + rows.output_body_pad,
        .thought => |o| @as(f32, @floatFromInt(o.lines.len + @intFromBool(o.truncated_by > 0))) * rows.output_line_height + rows.output_body_pad,
        .diff => |d2| diff_view.bodyHeight(d2.file),
        .stats => |s| @as(f32, @floatFromInt(s.len)) * rows.output_line_height + rows.output_body_pad,
    };
    return rows.detail_separator + body;
}

fn mixKey(a: u64, b: u64) u64 {
    var h = std.hash.Wyhash.init(a);
    h.update(std.mem.asBytes(&b));
    return h.final();
}

pub fn detailKey(row_key: u64, ix: usize) u64 {
    return mixKey(row_key ^ 0xDE7A, ix);
}

fn affordanceLabel(t: ToolItem) ?[]const u8 {
    if (t.diff_ref != null) return "Show full diff";
    if (t.output_ref != null) {
        if (t.output_bytes) |b| {
            return if (b < 1024) zpui.fmt("Show full output ({d} B)", .{b}) else zpui.fmt("Show full output ({d} KB)", .{(b + 1023) / 1024});
        }
        return "Show full output";
    }
    return null;
}

fn eased(spec: motion.MotionSpec, start: ?u64, now: u64, reduced: bool) f32 {
    const s = start orelse return 1;
    if (reduced) return 1;
    return spec.progressAt(now -| s, 1.0);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Render a tool group row's content.
pub fn renderGroup(self: *TranscriptView, row: *const rows.Row, theme: *const Theme, window: *Window, cx: *Context(TranscriptView)) AnyElement {
    const g = row.kind.tool_group;
    const now = cx.app.executor.now();
    const reduced = window.prefersReducedMotion();
    const fold = self.folds.get(row.key) orelse Fold{};
    const collapses = g.collapses;
    const open = !collapses or (fold.open orelse g.auto_open);
    const active = collapses and g.auto_open;

    // Per-chip detail state.
    const base_row_height: f32 = if (collapses) tool_tree_row_height else chip_height;
    const a = zpui.window.arena_mod.frameAllocator();
    const heights = a.alloc(f32, g.tools.len) catch @panic("OOM");
    const opens = a.alloc(bool, g.tools.len) catch @panic("OOM");
    var animating = false;
    for (g.tools, 0..) |t, ix| {
        const expandable = !t.isSpawnLink() and (t.body != null or t.invocation != null);
        const df = self.details.get(detailKey(row.key, ix)) orelse Fold{};
        const default_open = t.kind == .thought and !t.resolved;
        opens[ix] = expandable and (df.open orelse default_open);
        var target = base_row_height;
        if (opens[ix]) {
            if (t.invocation) |inv| target += detailHeight(inv);
            if (t.body) |b| target += detailHeight(b);
            if (affordanceLabel(t) != null) target += blob_affordance_height;
        }
        const p = eased(detail_fold, df.toggled_at, now, reduced);
        if (p < 1) animating = true;
        heights[ix] = if (df.toggled_at != null and p < 1) lerp(df.from, target, p) else target;
    }
    var revealed: f32 = chips_top_pad;
    for (heights) |h| revealed += h;
    const target_h: f32 = if (open) revealed else 0;
    const fp = eased(tool_fold, fold.toggled_at, now, reduced);
    if (fp < 1) animating = true;
    const body_h = if (fold.toggled_at != null and fp < 1) lerp(fold.from, target_h, fp) else target_h;
    const disclosure: f32 = if (fold.toggled_at != null and fp < 1) (if (open) fp else 1 - fp) else if (open) 1 else 0;
    if (animating or active) window.requestAnimationFrame();

    var group = div().relative().flex().flexCol().fontFamily(theme.font_sans_fixed);
    if (collapses) {
        const shimmer: ?f32 = if (active and !reduced) @as(f32, @floatFromInt(now % shimmer_period_ns)) / @as(f32, @floatFromInt(shimmer_period_ns)) else null;
        const header = div().id(.{ "tg-hdr", row.key }).relative().flex().flexRow().itemsCenter().gap(px(6)).pr(px(4))
            .h(px(tool_group_header_height)).cursorPointer().textSize(px(tool_text_size)).lineHeight(px(tool_label_line_height))
            .textColor(theme.text_muted).hover(sb.textColor(theme.text)).group("tg-hdr")
            .onClick(cx.listenerWith(GroupToggle{ .key = row.key, .height = body_h, .auto_open = g.auto_open }, TranscriptView.onToggleGroup))
            .child(div().w(px(22)).h(px(18)).flexNone().relative().child(
                rotatedIcon(.alt_arrow_down, 14, -std.math.pi / 2.0 * (1 - disclosure), theme.text_muted)
                    .absolute().left(px(activity_trunk_x - 7)).top(px(2)),
            ))
            .child(div().minW0().h(px(tool_label_line_height)).flex().itemsCenter().overflowHidden()
                .child(groupTitle(g.summary, shimmer, theme)));
        group = group.child(header);
    }
    if (open or body_h > 0) {
        var chips = div().pt(px(chips_top_pad)).flex().flexCol();
        for (g.tools, 0..) |t, ix| chips = chips.child(chipRow(self, row, t, ix, g.tools.len, collapses, opens[ix], heights[ix], theme, cx));
        if (collapses) group = group.child(div().overflowHidden().h(px(body_h)).child(chips)) else group = group.child(chips);
    }
    return zpui.intoAnyElement(group);
}

pub const GroupToggle = struct { key: u64, height: f32, auto_open: bool };
pub const DetailToggle = struct { key: u64, height: f32, open: bool };

/// The summary title; while the group is live a soft highlight sweeps across
/// it (`tool_group_title` shimmer, 3.4s).
fn groupTitle(text: []const u8, shimmer: ?f32, theme: *const Theme) AnyElement {
    const phase = shimmer orelse return zpui.intoAnyElement(div().truncate().child(text));
    // Paint-only sweep: per-byte color runs interpolated between muted and text.
    const a = zpui.window.arena_mod.frameAllocator();
    var runs: std.ArrayList(zpui.text.TextRun) = .empty;
    const font: zpui.text.Font = .{ .family = theme.font_sans_fixed };
    const n: f32 = @floatFromInt(@max(text.len, 1));
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const x = (@as(f32, @floatFromInt(i)) + 0.5) / n;
        const amount = shimmerAmount(x, phase);
        runs.append(a, .{ .len = @min(len, text.len - i), .font = font, .color = mixColor(theme.text_muted, theme.text, amount) }) catch @panic("OOM");
        i += len;
    }
    return zpui.intoAnyElement(div().truncate().child(zpui.StyledText.init(text).withRuns(runs.items)));
}

fn shimmerAmount(x: f32, phase: f32) f32 {
    // A band of half-width 0.36 travelling from -0.36 to 1.36 per period.
    const center = -shimmer_half_width + phase * (1 + 2 * shimmer_half_width);
    const d = @abs(x - center) / shimmer_half_width;
    if (d >= 1) return 0;
    const s = 1 - d;
    return s * s * (3 - 2 * s);
}

fn mixColor(a: Hsla, b: Hsla, t: f32) Hsla {
    const ra = a.toRgba();
    const rb = b.toRgba();
    return zpui.Rgba.toHsla(zpui.Rgba{
        .r = lerp(ra.r, rb.r, t),
        .g = lerp(ra.g, rb.g, t),
        .b = lerp(ra.b, rb.b, t),
        .a = lerp(ra.a, rb.a, t),
    });
}

fn chipRow(self: *TranscriptView, row: *const rows.Row, t: ToolItem, ix: usize, count: usize, collapses: bool, open: bool, height: f32, theme: *const Theme, cx: *Context(TranscriptView)) AnyElement {
    const base_row_height: f32 = if (collapses) tool_tree_row_height else chip_height;
    const has_pred = ix > 0;
    const continues = ix + 1 < count;
    if (t.isSpawnLink()) return subagentChip(t, row.key, ix, collapses, theme, cx);
    const expandable = t.body != null or t.invocation != null;
    if (!expandable) {
        var r = div().h(px(base_row_height)).wFull().flexNone().flex().flexRow();
        if (collapses) r = r.child(activityRail(t, has_pred, continues, base_row_height, theme));
        var card = div().my(px((base_row_height - chip_card_height) / 2)).h(px(chip_card_height)).minW0().flex1()
            .flex().itemsCenter().overflowHidden();
        if (collapses) card = card.ml(px(activity_text_gap)) else card = card.rounded(px(9)).border1()
            .borderColor(theme.hairline(0.07)).bg(theme.ink(0.03));
        return zpui.intoAnyElement(r.child(card.child(chipHeaderRow(t, null, collapses, theme))));
    }
    const dkey = detailKey(row.key, ix);
    var card = div().my(px((base_row_height - chip_card_height) / 2)).minW0().flex1().flex().flexCol().overflowHidden();
    if (collapses) card = card.ml(px(activity_text_gap)) else card = card.rounded(px(9)).border1()
        .borderColor(theme.hairline(0.07)).bg(theme.ink(0.03));
    card = card.child(div().id(.{ "chip-hdr", dkey }).h(px(if (collapses) chip_card_height else chip_header_height)).flexNone()
        .flex().itemsCenter().cursorPointer()
        .onClick(cx.listenerWith(DetailToggle{ .key = dkey, .height = height - base_row_height + chip_card_height, .open = open }, TranscriptView.onToggleDetail))
        .child(chipHeaderRow(t, open, collapses, theme)));
    const df = self.details.get(dkey) orelse Fold{};
    const tweening = df.toggled_at != null and (cx.app.executor.now() -| df.toggled_at.?) < detail_fold.totalNs(1.0);
    if (open or tweening) {
        var panel = div().flexNone().minW0().flex().flexCol().overflowHidden();
        if (t.invocation) |inv| {
            var sep = div().h(px(rows.detail_separator)).flexNone();
            if (!collapses) sep = sep.bg(theme.hairline(0.06));
            panel = panel.child(sep).child(detailBody(inv, theme));
        }
        if (t.body) |b| {
            var sep = div().h(px(rows.detail_separator)).flexNone();
            if (!collapses) sep = sep.bg(theme.hairline(0.06));
            panel = panel.child(sep).child(detailBody(b, theme));
        }
        if (affordanceLabel(t)) |label| panel = panel.child(div().h(px(blob_affordance_height)).flexNone().flex().itemsCenter()
            .textSize(px(tool_text_size)).textColor(theme.text_faint).cursorPointer().hover(sb.textColor(theme.text_muted)).child(label));
        card = card.child(panel);
    }
    card = card.h(px(height - base_row_height + chip_card_height));
    var r = div().wFull().flexNone().flex().flexRow();
    if (collapses) r = r.child(activityRail(t, has_pred, continues, base_row_height, theme));
    return zpui.intoAnyElement(r.child(div().minW0().flex1().child(card)));
}

/// The chip's content row: (tile) + label + detail (+ trailing chevron).
fn chipHeaderRow(t: ToolItem, chevron_open: ?bool, activity_in: bool, theme: *const Theme) zpui.Div {
    const activity = activity_in and !t.is_agent;
    const failed = t.is_error or (t.subagent_ref != null and t.subagent_status == .failed);
    const hover_text = activity and chevron_open != null and !failed;
    const tint = if (failed) theme.danger else theme.text_muted;
    var r = div().group("tool-header").h(px(if (activity) chip_card_height else chip_header_height)).wFull().minW0()
        .flex().flexRow().itemsCenter().gap(px(8)).px(px(if (activity) 0 else 8))
        .textSize(px(tool_text_size)).lineHeight(px(tool_label_line_height));
    if (!activity) r = r.child(div().size(px(18)).flexNone().rounded(px(5)).bg(theme.ink(0.08)).flex().itemsCenter().justifyCenter()
        .child(md.icon(t.icon, 12, theme.text_muted)));
    var label = div().flexNone().h(px(tool_label_line_height)).flex().itemsCenter().textColor(tint).child(t.label);
    if (!activity) label = label.fontWeight(500);
    if (hover_text) label = label.groupHover("tool-header", sb.textColor(theme.text));
    r = r.child(label);
    if (!(activity and t.detail.len == 0 and t.file_path == null)) {
        const detail_color = if (failed) theme.danger else if (activity) theme.text_muted else theme.text.opacity(0.85);
        var d = div().minW0().h(px(if (t.file_path != null) 22 else tool_label_line_height)).flex().itemsCenter().overflowHidden().textColor(detail_color);
        if (!activity) d = d.flex1();
        if (hover_text) d = d.groupHover("tool-header", sb.textColor(theme.text));
        if (t.file_path) |path| {
            var badge = div().minW0().h(px(22)).flex().itemsCenter().overflowHidden().gap(px(6)).rounded(px(5)).bg(theme.ink(0.06))
                .pl(px(1)).pr(px(6)).textColor(if (failed) theme.danger else theme.text.opacity(0.85))
                .child(div().size(px(20)).flexNone().flex().itemsCenter().justifyCenter().rounded(px(4)).bg(files.wellBg(theme))
                    .child(files.icon(path, theme, 14)))
                .child(div().minW0().truncate().child(fileBadgeName(path)));
            if (hover_text) badge = badge.groupHover("tool-header", sb.textColor(theme.text));
            d = d.child(badge);
        } else d = d.child(div().minW0().truncate().child(t.detail));
        r = r.child(d);
    }
    if (t.subagent_model) |m| r = r.child(div().flexNone().h(px(18)).flex().itemsCenter().textSize(px(11)).textColor(theme.text_faint).child(m));
    if (chevron_open) |o| {
        var tile = div().size(px(18)).flexNone().flex().itemsCenter().justifyCenter().textColor(theme.text_muted.opacity(0.8));
        if (activity) tile = tile.opacity(0).groupHover("tool-header", sb.opacity(1)) else tile = tile.rounded(px(5)).bg(theme.ink(0.06));
        var caret = div().flex().textColor(theme.text_faint).child(md.iconInherit(if (o) .alt_arrow_down else .alt_arrow_right, 12));
        if (activity) caret = caret.groupHover("tool-header", sb.textColor(if (failed) theme.danger else theme.text));
        r = r.child(tile.child(caret));
    }
    return r;
}

fn fileBadgeName(path: []const u8) []const u8 {
    var it = std.mem.splitBackwardsAny(u8, path, "/\\");
    while (it.next()) |c| if (c.len > 0) return c;
    return path;
}

/// A spawn chip: whole-card link to the subagent (open-arrow tile).
fn subagentChip(t: ToolItem, row_key: u64, ix: usize, rail: bool, theme: *const Theme, cx: *Context(TranscriptView)) AnyElement {
    _ = cx;
    var r = div().h(px(chip_height)).wFull().flexNone().flex().flexRow().itemsCenter();
    if (rail) r = r.child(div().ml(px(12)).hFull().w(px(1)).flexNone().bg(theme.ink(0.08)));
    var card = div().id(.{ "spawn", mixKey(row_key, ix) }).h(px(chip_card_height)).minW0().flex1().flex().itemsCenter().overflowHidden()
        .rounded(px(9)).border1().borderColor(theme.hairline(0.07)).bg(theme.ink(0.03)).cursorPointer().hover(sb.bg(theme.ink(0.05)));
    if (rail) card = card.ml(px(12));
    var header = chipHeaderRow(t, null, false, theme);
    header = header.child(div().size(px(18)).flexNone().rounded(px(5)).bg(theme.ink(0.06)).flex().itemsCenter().justifyCenter()
        .child(md.icon(.arrow_up_right, 11, theme.text_muted.opacity(0.8))));
    return zpui.intoAnyElement(r.child(card.child(header)));
}

/// The task-tree gutter: trunk + rounded elbow to the branch tip, then the
/// tool glyph (one hairline color; quads instead of a path union).
fn activityRail(t: ToolItem, has_pred: bool, continues: bool, row_height: f32, theme: *const Theme) zpui.Div {
    _ = has_pred;
    const Ctx = struct { color: Hsla, row_height: f32, continues: bool };
    const ctx: Ctx = .{ .color = theme.hairline(0.12), .row_height = row_height, .continues = continues };
    const tint = if (t.is_error) theme.danger else theme.text_muted;
    return div().relative().w(px(activity_gutter_width)).flexNone()
        .child(zpui.canvas(ctx, struct {
            fn paint(c: Ctx, b: Bounds, w: *Window, _: *App) void {
                const x = b.origin.x + activity_trunk_x;
                const branch_y = b.origin.y + c.row_height / 2;
                const r = activity_bend_radius;
                const bend_top = branch_y - r;
                if (c.continues) {
                    // Straight trunk through the whole row (expanded rows included).
                    w.paintQuad(zpui.fill(.{ .origin = .{ .x = x - 0.5, .y = b.origin.y }, .size = .{ .width = 1, .height = b.size.height } }, c.color));
                } else {
                    w.paintQuad(zpui.fill(.{ .origin = .{ .x = x - 0.5, .y = b.origin.y }, .size = .{ .width = 1, .height = @max(bend_top - b.origin.y, 0) } }, c.color));
                }
                // Elbow: left + bottom border with a rounded bottom-left corner.
                const elbow: Bounds = .{ .origin = .{ .x = x - 0.5, .y = bend_top }, .size = .{ .width = activity_branch_end_x - activity_trunk_x + 0.5, .height = r + 0.5 } };
                w.paintQuad(zpui.quad(elbow, .{ .top_left = 0, .top_right = 0, .bottom_right = 0, .bottom_left = r + 0.5 }, zpui.color.transparent_black,
                    .{ .top = 0, .right = 0, .bottom = 1, .left = 1 }, c.color, .solid));
            }
        }.paint).absolute().inset0())
        .child(md.icon(t.icon, activity_icon_size, tint).absolute().left(px(activity_icon_left)).top(px(row_height / 2 - activity_icon_size / 2)));
}

/// An open chip's body: output lines, thought lines, stats or an inline diff.
fn detailBody(d: ToolDetail, theme: *const Theme) AnyElement {
    const body = div().wFull().minW0().flex().flexCol().overflowHidden();
    switch (d) {
        .diff => |dd| return zpui.intoAnyElement(body.child(diff_view.render(dd.file, dd.old_text, dd.new_text, theme))),
        .stats => |stats| {
            var b = body.py(px(6)).fontFamily(theme.font_mono).textSize(px(tool_text_size));
            for (stats) |s| b = b.child(div().h(px(rows.output_line_height)).wFull().minW0().flex().itemsCenter().gap(px(8))
                .child(files.icon(s.path, theme, 14))
                .child(div().minW0().flex1().truncate().textColor(theme.text_faint).child(s.path))
                .child(div().flexNone().textColor(theme.success).child(zpui.fmt("+{d}", .{s.additions})))
                .child(div().flexNone().textColor(theme.danger).child(zpui.fmt("\u{2212}{d}", .{s.deletions}))));
            return zpui.intoAnyElement(b);
        },
        .output => |o| {
            var b = body.py(px(6)).fontFamily(theme.font_mono).textSize(px(tool_text_size));
            for (o.lines) |l| b = b.child(div().h(px(rows.output_line_height)).wFull().minW0().flex().itemsCenter()
                .textColor(theme.text_faint).child(div().wFull().minW0().truncate().whitespaceNowrap().child(if (l.len == 0) " " else l)));
            if (o.truncated_by > 0) b = b.child(moreLines(o.truncated_by, theme));
            return zpui.intoAnyElement(b);
        },
        .thought => |o| {
            var b = body.py(px(6)).textSize(px(tool_text_size));
            for (o.lines) |l| {
                var line_row = div().h(px(rows.output_line_height)).wFull().minW0().flex().itemsCenter();
                if (thoughtLineText(l, theme)) |st| line_row = line_row.child(div().wFull().minW0().truncate().whitespaceNowrap().child(st));
                b = b.child(line_row);
            }
            if (o.truncated_by > 0) b = b.child(moreLines(o.truncated_by, theme));
            return zpui.intoAnyElement(b);
        },
    }
}

fn moreLines(n: usize, theme: *const Theme) zpui.Div {
    return div().h(px(rows.output_line_height)).flex().itemsCenter().textSize(px(tool_text_size)).textColor(theme.text_faint)
        .child(zpui.fmt("\u{2026} {d} more lines", .{n}));
}

/// Flattened thought line → styled text (faint prose, semibold bold, mono
/// code, underlined links — not clickable).
fn thoughtLineText(line: thought.Line, theme: *const Theme) ?zpui.StyledText {
    if (thought.isBlank(line)) return null;
    const a = zpui.window.arena_mod.frameAllocator();
    var text: std.ArrayList(u8) = .empty;
    var runs: std.ArrayList(zpui.text.TextRun) = .empty;
    for (line) |r| {
        if (r.text.len == 0) continue;
        text.appendSlice(a, r.text) catch @panic("OOM");
        runs.append(a, .{
            .len = r.text.len,
            .font = .{
                .family = if (r.style.code) theme.font_mono else theme.font_sans_fixed,
                .weight = if (r.style.bold) 600 else 400,
                .style = if (r.style.italic) .italic else .normal,
            },
            .color = theme.text_faint,
            .underline = if (r.style.link != null) .{ .color = theme.text_faint, .thickness = 1 } else null,
            .strikethrough = if (r.style.strikethrough) .{ .color = theme.text_faint, .thickness = 1 } else null,
        }) catch @panic("OOM");
    }
    return zpui.StyledText.init(text.items).withRuns(runs.items);
}

/// An icon rotated about its own center (zpui's svg transformation is
/// applied in window space, gpui's around the element center).
pub fn rotatedIcon(which: assets.Icon, size: f32, angle: f32, color: Hsla) zpui.Div {
    const Ctx = struct { icon: assets.Icon, angle: f32, color: Hsla };
    return div().size(px(size)).child(zpui.canvas(Ctx{ .icon = which, .angle = angle, .color = color }, struct {
        fn paint(c: Ctx, b: Bounds, w: *Window, _: *App) void {
            const s = w.scaleFactor();
            const cx = (b.origin.x + b.size.width / 2) * s;
            const cy = (b.origin.y + b.size.height / 2) * s;
            const r = zpui.scene.TransformationMatrix.unit.rotate(c.angle);
            var m = r;
            m.translation = .{
                cx - (r.rotation_scale[0][0] * cx + r.rotation_scale[0][1] * cy),
                cy - (r.rotation_scale[1][0] * cx + r.rotation_scale[1][1] * cy),
            };
            w.paintSvg(b, c.icon.path(), c.icon.svg(), m, c.color);
        }
    }.paint).sizeFull());
}
