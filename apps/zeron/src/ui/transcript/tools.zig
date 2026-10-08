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
const tool_images = @import("tool_images.zig");

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

// ---- [motion] arrival choreography (`ToolGroupReveal`) -----------------------------------

/// `TOOL_ROW_REVEAL`: each new row grows in (360 ms expo-out).
pub const tool_row_reveal: motion.MotionSpec = .init(360, motion.ease_out_expo);
/// `TOOL_CONNECTOR_REVEAL`: its rail draws briskly then eases into the tip.
pub const tool_connector_reveal: motion.MotionSpec = .init(480, motion.ease_out_quint);
/// `TOOL_FIRST_ROW_DELAY_MS` / `TOOL_ROW_STAGGER_MS`.
pub const tool_first_row_delay_ms: u64 = 90;
pub const tool_row_stagger_ms: u64 = 65;

/// One chip's arrival state for this frame.
pub const Reveal = struct { connector: f32 = 1, continuation: f32 = 0 };

fn revealRaw(spec: motion.MotionSpec, start: u64, now: u64) f32 {
    if (now <= start) return 0;
    // Rust divides by the unscaled span (`TOOL_ROW_REVEAL.total()`).
    const total: f32 = @floatFromInt(spec.totalMs() * std.time.ns_per_ms);
    return @as(f32, @floatFromInt(now - start)) / total;
}

/// `tool_row_reveal_progress`: eased 0..1 (1 with no start or reduced motion).
pub fn rowRevealProgress(start: ?u64, now: u64, reduced: bool) f32 {
    const st = start orelse return 1;
    if (reduced) return 1;
    return tool_row_reveal.curve.eval(revealRaw(tool_row_reveal, st, now));
}

/// `tool_connector_reveal_progress`.
pub fn connectorRevealProgress(start: ?u64, now: u64, reduced: bool) f32 {
    const st = start orelse return 1;
    if (reduced) return 1;
    return tool_connector_reveal.curve.eval(revealRaw(tool_connector_reveal, st, now));
}

/// `tool_connector_parts`: (incoming leg, elbow + branch) of one arrival.
/// A child row's predecessor first grows its continuation to the boundary.
pub fn connectorParts(progress0: f32, has_predecessor: bool) [2]f32 {
    const progress = std.math.clamp(progress0, 0, 1);
    const incoming_start: f32 = if (has_predecessor) 0.45 else 0.0;
    const incoming_end: f32 = if (has_predecessor) 0.72 else 0.62;
    const branch_start: f32 = if (has_predecessor) 0.68 else 0.58;
    return .{
        std.math.clamp((progress - incoming_start) / (incoming_end - incoming_start), 0, 1),
        std.math.clamp((progress - branch_start) / (1.0 - branch_start), 0, 1),
    };
}

/// `tool_connector_continuation`: the outgoing trunk's timing belongs to the
/// next row's arrival.
pub fn connectorContinuation(next: ?f32) f32 {
    const p = next orelse return 0;
    return std.math.clamp(p / 0.45, 0, 1);
}

/// `activity_branch_points`: the elbow (quadratic) + straight branch, cut at
/// `progress` of its arc length. Points are relative to the bend top.
pub fn branchPoints(progress: f32, buf: *[32][2]f32) [][2]f32 {
    var path: [26][2]f32 = undefined;
    for (0..25) |step| {
        const t: f32 = @as(f32, @floatFromInt(step)) / 24.0;
        path[step] = .{ activity_bend_radius * t * t, activity_bend_radius * (2 * t - t * t) };
    }
    path[25] = .{ activity_branch_end_x - activity_trunk_x, activity_bend_radius };
    if (progress >= 1) {
        @memcpy(buf[0..26], &path);
        return buf[0..26];
    }
    var total: f32 = 0;
    for (0..25) |i| total += std.math.hypot(path[i + 1][0] - path[i][0], path[i + 1][1] - path[i][1]);
    var remaining = total * std.math.clamp(progress, 0, 1);
    buf[0] = path[0];
    var n: usize = 1;
    for (0..25) |i| {
        if (remaining <= 0) break;
        const len = std.math.hypot(path[i + 1][0] - path[i][0], path[i + 1][1] - path[i][1]);
        const t = @min(remaining / len, 1);
        buf[n] = .{ lerp(path[i][0], path[i + 1][0], t), lerp(path[i][1], path[i + 1][1], t) };
        n += 1;
        remaining -= len;
    }
    return buf[0..n];
}

/// `reveal_tool_row`: a growing clip of the row's height.
fn revealToolRow(row: AnyElement, height: f32, progress: f32) AnyElement {
    if (progress >= 1) return row;
    return zpui.intoAnyElement(div().wFull().h(px(height * progress)).flexNone().overflowHidden().child(row));
}

fn partKey(row_key: u64, part_id: []const u8) u64 {
    return std.hash.Wyhash.hash(row_key, part_id);
}

/// A chip's arrival start (null: historical / settled).
fn revealStart(self: *const TranscriptView, row_key: u64, part_id: []const u8) ?u64 {
    return self.tool_starts.get(partKey(row_key, part_id)) orelse null;
}

/// `sync`'s reveal bookkeeping: groups present at attach are history; a
/// new group's header reveals with its rows (first row after 90 ms); tools
/// joining a live group stagger by 65 ms; known tools keep their start.
pub fn updateReveals(self: *TranscriptView, new_rows: []const rows.Row, old_keys: *const std.AutoHashMapUnmanaged(u64, void), historical: bool, now: u64) !void {
    const gpa = self.gpa;
    var starts: std.AutoHashMapUnmanaged(u64, ?u64) = .empty;
    errdefer starts.deinit(gpa);
    var headers: std.AutoHashMapUnmanaged(u64, ?u64) = .empty;
    errdefer headers.deinit(gpa);
    for (new_rows) |r| {
        if (r.kind != .tool_group) continue;
        const g = r.kind.tool_group;
        if (!self.compact_mode and !g.collapses) continue;
        const known_group = self.tool_headers.contains(r.key);
        const is_new_group = !historical and !known_group and !old_keys.contains(r.key);
        const header: ?u64 = if (self.tool_headers.get(r.key)) |h| h else if (is_new_group) now else null;
        try headers.put(gpa, r.key, header);
        const delay: u64 = if (is_new_group) tool_first_row_delay_ms else 0;
        var arrival: u64 = 0;
        for (g.tools) |t| {
            const k = partKey(r.key, t.part_id);
            if (self.tool_starts.get(k)) |prev| {
                try starts.put(gpa, k, prev);
                continue;
            }
            if (historical or (!known_group and !is_new_group)) {
                try starts.put(gpa, k, null);
                continue;
            }
            try starts.put(gpa, k, now + motion.scaledNs((delay + arrival * tool_row_stagger_ms) * std.time.ns_per_ms));
            arrival += 1;
        }
    }
    self.tool_starts.deinit(gpa);
    self.tool_starts = starts;
    self.tool_headers.deinit(gpa);
    self.tool_headers = headers;
}

test "tool connector parts match tool_connector_parts" {
    try std.testing.expectEqual([2]f32{ 0, 0 }, connectorParts(0, false));
    try std.testing.expectEqual([2]f32{ 0, 0 }, connectorParts(0.44, true));
    try std.testing.expectEqual(@as(f32, 0), connectorContinuation(0));
    try std.testing.expect(connectorContinuation(0.3) > 0);
    try std.testing.expectEqual(@as(f32, 1), connectorContinuation(0.45));
    const p = connectorParts(0.60, true);
    try std.testing.expect(p[0] > 0 and p[0] < 1 and p[1] == 0);
    try std.testing.expectEqual([2]f32{ 1, 1 }, connectorParts(1, true));
    try std.testing.expectEqual(@as(f32, 0), connectorContinuation(null));
    var buf: [32][2]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 26), branchPoints(1, &buf).len);
    try std.testing.expectEqual(@as(usize, 1), branchPoints(0, &buf).len);
    try std.testing.expectEqual(@as(f32, 1), rowRevealProgress(null, 0, false));
    try std.testing.expectEqual(@as(f32, 0), rowRevealProgress(1000, 1000, false));
    try std.testing.expectEqual(@as(f32, 1), rowRevealProgress(1000, 1000, true));
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
    const compact = self.compact_mode;
    // Compact mode: EVERYTHING sits under the one work accordion, spawn chips included.
    const collapses = compact or g.collapses;
    const open = !collapses or (fold.open orelse g.auto_open);
    // The title shimmer reads "working" even under the collapsed compact fold.
    var any_unresolved = false;
    for (g.tools) |t| if (!t.resolved) {
        any_unresolved = true;
    };
    const active = collapses and (g.auto_open or (compact and any_unresolved));
    if (compact and active) self.compact_live.put(self.gpa, row.key, {}) catch {};
    const worked_secs: ?i64 = if (compact) g.worked_secs else null;
    if (worked_secs != null and self.compact_live.remove(row.key)) self.compact_worked_fade_at.put(self.gpa, row.key, now) catch {};
    const fade_ns = motion.fade_in.totalNs(1.0);
    const animate_worked = if (self.compact_worked_fade_at.get(row.key)) |at| now -| at < fade_ns else false;
    const worked_fade_t: f32 = if (worked_secs == null) 0 else if (animate_worked and !reduced)
        motion.fade_in.progress(@as(f32, @floatFromInt(now -| self.compact_worked_fade_at.get(row.key).?)) / @as(f32, @floatFromInt(fade_ns)))
    else
        1;

    // Per-chip detail state.
    const base_row_height: f32 = if (collapses) tool_tree_row_height else chip_height;
    const a = zpui.window.arena_mod.frameAllocator();
    const heights = a.alloc(f32, g.tools.len) catch @panic("OOM");
    const opens = a.alloc(bool, g.tools.len) catch @panic("OOM");
    var animating = false;
    for (g.tools, 0..) |t, ix| {
        const expandable = !t.isSpawnLink() and (t.body != null or t.invocation != null or t.hasImages());
        const df = self.details.get(detailKey(row.key, ix)) orelse Fold{};
        // Compact mode overrides it all: nothing inside the fold opens itself.
        const default_open = t.kind == .thought and !t.resolved and !compact;
        opens[ix] = expandable and (df.open orelse default_open);
        var target = base_row_height;
        if (opens[ix]) {
            if (t.invocation) |inv| target += detailHeight(inv);
            if (t.hasImages()) target += image_strip_height;
            // [wiring] a fetched sidecar blob upgrades the body in place.
            if (self.blobs.effective(t)) |b| target += detailHeight(b);
            var abuf: [96]u8 = undefined;
            if (self.blobs.affordance(t, &abuf) != null) target += blob_affordance_height;
        }
        const p = eased(detail_fold, df.toggled_at, now, reduced);
        if (p < 1) animating = true;
        heights[ix] = if (df.toggled_at != null and p < 1) lerp(df.from, target, p) else target;
    }
    // [motion] Arrival choreography (`tool_row_reveal_progress`,
    // `tool_connector_reveal_progress`): rows grow in, rails draw.
    const reveal = a.alloc(f32, g.tools.len) catch @panic("OOM");
    const connector = a.alloc(f32, g.tools.len) catch @panic("OOM");
    for (g.tools, 0..) |t, ix| {
        const start = revealStart(self, row.key, t.part_id);
        reveal[ix] = rowRevealProgress(start, now, reduced);
        connector[ix] = connectorRevealProgress(start, now, reduced);
        if (reveal[ix] < 1 or connector[ix] < 1) animating = true;
    }
    const header_reveal = rowRevealProgress(self.tool_headers.get(row.key) orelse null, now, reduced);
    if (header_reveal < 1) animating = true;
    var revealed: f32 = chips_top_pad;
    for (heights, reveal) |h, r| revealed += h * r;
    const target_h: f32 = if (open) revealed else 0;
    const fp = eased(tool_fold, fold.toggled_at, now, reduced);
    if (fp < 1) animating = true;
    const body_h = if (fold.toggled_at != null and fp < 1) lerp(fold.from, target_h, fp) else target_h;
    const disclosure: f32 = if (fold.toggled_at != null and fp < 1) (if (open) fp else 1 - fp) else if (open) 1 else 0;
    if (animating or active or animate_worked) window.requestAnimationFrame();

    var group = div().relative().flex().flexCol().fontFamily(theme.font_sans_fixed);
    if (collapses) {
        const shimmer: ?f32 = if (active and !reduced) @as(f32, @floatFromInt(now % shimmer_period_ns)) / @as(f32, @floatFromInt(shimmer_period_ns)) else null;
        const header = div().id(.{ "tg-hdr", row.key }).role(.button).ariaExpanded(open).relative().flex().flexRow().itemsCenter().gap(px(6)).pr(px(4))
            .h(px(tool_group_header_height)).cursorPointer().textSize(px(tool_text_size)).lineHeight(px(tool_label_line_height))
            .textColor(theme.text_muted).hover(sb.textColor(theme.text)).group("tg-hdr")
            .onClick(cx.listenerWith(GroupToggle{ .key = row.key, .height = body_h, .auto_open = g.auto_open, .compact_shell = g.compact_shell }, TranscriptView.onToggleGroup))
            .child(div().w(px(22)).h(px(18)).flexNone().relative().child(
                rotatedIcon(.alt_arrow_down, 14, -std.math.pi / 2.0 * (1 - disclosure), theme.text_muted)
                    .absolute().left(px(activity_trunk_x - 7)).top(px(2)),
            ))
            .child(div().minW0().h(px(tool_label_line_height)).flex().itemsCenter().overflowHidden()
                .child(if (worked_secs) |secs| compactWorkTitle(g.summary, workedForLabel(secs), worked_fade_t, shimmer, theme) else groupTitle(g.summary, shimmer, theme)));
        group = group.child(revealToolRow(zpui.intoAnyElement(header), tool_group_header_height, header_reveal));
    }
    // A compact shell's expanded content is its sibling body rows.
    if (g.compact_shell) return zpui.intoAnyElement(group);
    if (open or body_h > 0) {
        var chips = div().pt(px(chips_top_pad)).flex().flexCol();
        for (g.tools, 0..) |t, ix| {
            const rv: Reveal = .{
                .connector = connector[ix],
                .continuation = connectorContinuation(if (ix + 1 < g.tools.len) connector[ix + 1] else null),
            };
            const chip = chipRow(self, row, t, ix, g.tools.len, collapses, opens[ix], heights[ix], rv, theme, cx);
            chips = chips.child(if (t.isSpawnLink()) chip else revealToolRow(chip, heights[ix], reveal[ix]));
        }
        if (collapses) group = group.child(div().overflowHidden().h(px(body_h)).child(chips)) else group = group.child(chips);
    }
    return zpui.intoAnyElement(group);
}

pub const GroupToggle = struct { key: u64, height: f32, auto_open: bool, compact_shell: bool = false };

/// `worked_for_label`: "Worked for 5m 10s" (frame arena).
pub fn workedForLabel(secs: i64) []const u8 {
    var buf: [32]u8 = undefined;
    return zpui.fmt("Worked for {s}", .{rows.formatElapsed(&buf, secs)});
}

/// `compact_work_title`: the live tool summary crossfades into "Worked for"
/// (`t` 0 = summary, 1 = duration; the duration rises 4px as it fades in).
fn compactWorkTitle(summary: []const u8, worked: []const u8, t: f32, shimmer: ?f32, theme: *const Theme) AnyElement {
    if (t >= 1) return groupTitle(worked, null, theme);
    if (t <= 0) return groupTitle(summary, shimmer, theme);
    return zpui.intoAnyElement(div().relative().minW0().wFull().h(px(tool_label_line_height))
        .child(div().absolute().left0().right0().top0().h(px(tool_label_line_height)).flex().itemsCenter().overflowHidden()
            .opacity(1 - t).child(groupTitle(summary, null, theme)))
        .child(div().relative().top(px(4 * (1 - t))).h(px(tool_label_line_height)).flex().itemsCenter().overflowHidden()
            .opacity(t).child(groupTitle(worked, null, theme))));
}
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

fn chipRow(self: *TranscriptView, row: *const rows.Row, t: ToolItem, ix: usize, count: usize, collapses: bool, open: bool, height: f32, rv: Reveal, theme: *const Theme, cx: *Context(TranscriptView)) AnyElement {
    const base_row_height: f32 = if (collapses) tool_tree_row_height else chip_height;
    const has_pred = ix > 0;
    const continues = ix + 1 < count;
    // The text arrives with the branch tip (rises 4 px as it fades in).
    const content_reveal = connectorParts(rv.connector, has_pred)[1];
    if (t.isSpawnLink()) return subagentChip(t, row.key, ix, collapses, theme, cx);
    const expandable = t.body != null or t.invocation != null or t.hasImages();
    if (!expandable) {
        var r = div().h(px(base_row_height)).wFull().flexNone().flex().flexRow();
        if (collapses) r = r.child(activityRail(t, has_pred, continues, base_row_height, rv, theme));
        var card = div().my(px((base_row_height - chip_card_height) / 2)).h(px(chip_card_height)).minW0().flex1()
            .flex().itemsCenter().overflowHidden();
        if (collapses and content_reveal < 1) card = card.relative().top(px(4 * (1 - content_reveal))).opacity(content_reveal);
        if (collapses) card = card.ml(px(activity_text_gap)) else card = card.rounded(px(9)).border1()
            .borderColor(theme.hairline(0.07)).bg(theme.ink(0.03));
        return zpui.intoAnyElement(r.child(card.child(chipHeaderRow(t, null, collapses, theme))));
    }
    const dkey = detailKey(row.key, ix);
    var card = div().my(px((base_row_height - chip_card_height) / 2)).minW0().flex1().flex().flexCol().overflowHidden();
    if (collapses) card = card.ml(px(activity_text_gap)) else card = card.rounded(px(9)).border1()
        .borderColor(theme.hairline(0.07)).bg(theme.ink(0.03));
    if (collapses and content_reveal < 1) card = card.relative().top(px(4 * (1 - content_reveal))).opacity(content_reveal);
    card = card.child(div().id(.{ "chip-hdr", dkey }).role(.button).ariaExpanded(open).h(px(if (collapses) chip_card_height else chip_header_height)).flexNone()
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
            panel = panel.child(sep).child(detailBody(inv, mixKey(dkey, 0xCA11), theme));
        }
        // Image previews exist only while the chip's body is mounted.
        if (t.hasImages()) panel = panel.child(imageStrip(self, dkey, t, collapses, theme, cx));
        if (self.blobs.effective(t)) |b| {
            var sep = div().h(px(rows.detail_separator)).flexNone();
            if (!collapses) sep = sep.bg(theme.hairline(0.06));
            panel = panel.child(sep).child(detailBody(b, mixKey(dkey, 0xB10B), theme));
        }
        // [wiring] "Show full output" fetches the sidecar blob (FetchToolBlob).
        var abuf: [96]u8 = undefined;
        if (self.blobs.affordance(t, &abuf)) |aff| panel = panel.child(div().id(.{ "blob-affordance", dkey }).role(.button).h(px(blob_affordance_height)).flexNone().flex().itemsCenter()
            .textSize(px(tool_text_size)).textColor(theme.text_faint).cursorPointer().hover(sb.textColor(theme.text_muted))
            .onClick(cx.listenerWith(view_mod.BlobClick{ .row_key = row.key, .tool_ix = ix }, TranscriptView.onBlobClick))
            .child(zpui.window.arena_mod.dupe(aff.label)));
        card = card.child(panel);
    }
    card = card.h(px(height - base_row_height + chip_card_height));
    var r = div().wFull().flexNone().flex().flexRow();
    if (collapses) r = r.child(activityRail(t, has_pred, continues, base_row_height, rv, theme));
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
    var r = div().h(px(chip_height)).wFull().flexNone().flex().flexRow().itemsCenter();
    if (rail) r = r.child(div().ml(px(12)).hFull().w(px(1)).flexNone().bg(theme.ink(0.08)));
    var card = div().id(.{ "spawn", mixKey(row_key, ix) }).role(.link).h(px(chip_card_height)).minW0().flex1().flex().itemsCenter().overflowHidden()
        .rounded(px(9)).border1().borderColor(theme.hairline(0.07)).bg(theme.ink(0.03)).cursorPointer().hover(sb.bg(theme.ink(0.05)))
        .onClick(cx.listenerWith([2]u64{ row_key, ix }, TranscriptView.onSpawnClick)); // [wiring]
    if (rail) card = card.ml(px(12));
    var header = chipHeaderRow(t, null, false, theme);
    header = header.child(div().size(px(18)).flexNone().rounded(px(5)).bg(theme.ink(0.06)).flex().itemsCenter().justifyCenter()
        .child(md.icon(.arrow_up_right, 11, theme.text_muted.opacity(0.8))));
    return zpui.intoAnyElement(r.child(card.child(header)));
}

/// The task-tree gutter: trunk + rounded elbow to the branch tip, then the
/// tool glyph (one hairline color; quads instead of a path union).
fn activityRail(t: ToolItem, has_pred: bool, continues: bool, row_height: f32, rv: Reveal, theme: *const Theme) zpui.Div {
    const parts = connectorParts(rv.connector, has_pred);
    const Ctx = struct { color: Hsla, row_height: f32, continues: bool, incoming: f32, branch: f32, continuation: f32 };
    const ctx: Ctx = .{ .color = theme.hairline(0.12), .row_height = row_height, .continues = continues, .incoming = parts[0], .branch = parts[1], .continuation = rv.continuation };
    const tint = if (t.is_error) theme.danger else theme.text_muted;
    return div().relative().w(px(activity_gutter_width)).flexNone()
        .child(zpui.canvas(ctx, struct {
            fn paint(c: Ctx, b: Bounds, w: *Window, _: *App) void {
                const x = b.origin.x + activity_trunk_x;
                const branch_y = b.origin.y + c.row_height / 2;
                const r = activity_bend_radius;
                const bend_top = branch_y - r;
                const settled = c.incoming >= 1 and c.branch >= 1 and (!c.continues or c.continuation >= 1);
                if (!settled) {
                    // [motion] Mid-arrival: the incoming leg grows down, then the
                    // elbow + branch draw by arc length (`activity_branch_points`).
                    if (c.incoming > 0) {
                        var bottom = b.origin.y + (c.row_height / 2 - r) * c.incoming;
                        if (c.incoming >= 1 and c.continues and c.continuation > 0) {
                            const cont_h = @max(b.size.height - (c.row_height / 2 - r), 0);
                            bottom = bend_top + cont_h * c.continuation;
                        }
                        w.paintQuad(zpui.fill(.{ .origin = .{ .x = x - 0.5, .y = b.origin.y }, .size = .{ .width = 1, .height = @max(bottom - b.origin.y, 0) } }, c.color));
                    }
                    if (c.branch > 0) {
                        var buf: [32][2]f32 = undefined;
                        const pts = branchPoints(c.branch, &buf);
                        if (pts.len >= 2) {
                            var path = zpui.scene.Path.init(.{ .x = b.origin.x, .y = b.origin.y });
                            ribbon(&path, pts, x, bend_top);
                            w.paintPath(path, c.color);
                        }
                    }
                    return;
                }
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
        .child(md.icon(t.icon, activity_icon_size, tint).opacity(parts[1]).absolute().left(px(activity_icon_left)).top(px(row_height / 2 - activity_icon_size / 2)));
}

/// `activity_ribbon`: a 1 px ribbon along `pts` (relative to the bend),
/// tessellated as quads between the left and right offset curves.
fn ribbon(path: *zpui.scene.Path, pts: []const [2]f32, ox: f32, oy: f32) void {
    const a = zpui.window.arena_mod.frameAllocator();
    var prev_l: [2]f32 = undefined;
    var prev_r: [2]f32 = undefined;
    for (pts, 0..) |p, ix| {
        const pa = pts[if (ix == 0) 0 else ix - 1];
        const pb = pts[@min(ix + 1, pts.len - 1)];
        const dx = pb[0] - pa[0];
        const dy = pb[1] - pa[1];
        const len = @max(@sqrt(dx * dx + dy * dy), 0.0001);
        const n = [2]f32{ -dy / len * 0.5, dx / len * 0.5 };
        const l = [2]f32{ ox + p[0] + n[0], oy + p[1] + n[1] };
        const rr = [2]f32{ ox + p[0] - n[0], oy + p[1] - n[1] };
        if (ix > 0) {
            const uv = [3]zpui.Point(f32){ .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 1 } };
            path.pushTriangle(a, .{ .{ .x = prev_l[0], .y = prev_l[1] }, .{ .x = l[0], .y = l[1] }, .{ .x = rr[0], .y = rr[1] } }, uv) catch {};
            path.pushTriangle(a, .{ .{ .x = prev_l[0], .y = prev_l[1] }, .{ .x = rr[0], .y = rr[1] }, .{ .x = prev_r[0], .y = prev_r[1] } }, uv) catch {};
        }
        prev_l = l;
        prev_r = rr;
    }
}

/// `TOOL_IMAGE_STRIP_HEIGHT`: analytic height an open chip's image strip
/// adds (separator + frames).
pub const image_strip_height: f32 = rows.detail_separator + tool_images.image_height + 2 * tool_images.image_pad;

/// `render_tool_image_strip`: a separator over a sideways-scrolling row of
/// 220px frames whose widths follow each image's aspect.
fn imageStrip(self: *TranscriptView, dkey: u64, t: ToolItem, collapses: bool, theme: *const Theme, cx: *Context(TranscriptView)) zpui.Div {
    const host = self.imageHost(cx);
    const a = zpui.window.arena_mod.frameAllocator();
    var strip = div().id(.{ "tool-images", dkey }).h(px(tool_images.image_height + 2 * tool_images.image_pad)).py(px(tool_images.image_pad))
        .flex().flexRow().gap(px(tool_images.image_pad)).overflowXScroll();
    if (!collapses) strip = strip.px(px(tool_images.image_pad));
    const h = tool_images.image_height;
    for (t.images, 0..) |raw, ix| {
        const path = tool_images.resolvePath(a, raw, host.cwd) catch raw;
        const name = fileBadgeName(path);
        const state = if (host.device) |d| self.imageState(&.{d}, path, null, cx) else @import("zeron_model").attachments.Snapshot{ .failed = .{ .retry_in_ns = std.math.maxInt(u64) } };
        const width: f32 = switch (state) {
            .loaded => |l| blk: {
                const size = l.image.size(0);
                const aspect = @as(f32, @floatFromInt(@max(size.width, 1))) / @as(f32, @floatFromInt(@max(size.height, 1)));
                break :blk std.math.clamp(h * aspect, 48, tool_images.image_max_width);
            },
            else => h * 4.0 / 3.0,
        };
        var frame = div().id(.{ "tool-img", mixKey(dkey, ix) }).ariaLabel(name).w(px(width)).h(px(h)).flexNone().flex().itemsCenter().justifyCenter()
            .rounded(px(8)).overflowHidden().border1().borderColor(theme.hairline(0.07)).bg(theme.ink(0.035));
        frame = switch (state) {
            .loaded => |l| frame.child(zpui.img(l.image).w(px(width - 2)).h(px(h - 2)).rounded(px(7)).objectFit(.contain)),
            .loading => frame.textSize(px(tool_text_size)).textColor(theme.text_faint).child("Loading image\u{2026}"),
            .failed => frame.flexCol().gap(px(4)).px(px(12)).textSize(px(tool_text_size)).textColor(theme.text_faint)
                .child("Image unavailable").child(div().maxWFull().truncate().child(name)),
        };
        strip = strip.child(frame);
    }
    var sep = div().h(px(rows.detail_separator)).flexNone();
    if (!collapses) sep = sep.bg(theme.hairline(0.06));
    return div().h(px(image_strip_height)).flexNone().flex().flexCol().child(sep).child(strip);
}

/// One selectable output line: joins the transcript's selection so paths,
/// commands and output can be drag-selected and copied. Lines clip rather
/// than ellipsize (selection maps the pointer onto the full text).
fn selectableLine(key: u64, ix: usize, text: zpui.StyledText, theme: *const Theme) zpui.Div {
    return div().wFull().minW0().overflowHidden().whitespaceNowrap().child(zpui.intoAnyElement(md.RichText{
        .id = .{ .hash = mixKey(key, ix) },
        .key = mixKey(key, ix),
        .text = text,
        .selection_wash = theme.selection,
        .truncate_links = false,
        .disclose_links = false,
    }));
}

/// An open chip's body: output lines, thought lines, stats or an inline diff.
fn detailBody(d: ToolDetail, key: u64, theme: *const Theme) AnyElement {
    const body = div().wFull().minW0().flex().flexCol().overflowHidden();
    switch (d) {
        .diff => |dd| return zpui.intoAnyElement(body.child(diff_view.render(dd.file, dd.old_text, dd.new_text, theme))),
        .stats => |stats| {
            var b = body.py(px(6)).fontFamily(theme.font_mono).textSize(px(tool_text_size));
            for (stats, 0..) |s, six| b = b.child(div().h(px(rows.output_line_height)).wFull().minW0().flex().itemsCenter().gap(px(8))
                .child(files.icon(s.path, theme, 14))
                .child(div().minW0().flex1().textColor(theme.text_faint).child(selectableLine(key, six, zpui.StyledText.init(s.path), theme)))
                .child(div().flexNone().textColor(theme.success).child(zpui.fmt("+{d}", .{s.additions})))
                .child(div().flexNone().textColor(theme.danger).child(zpui.fmt("\u{2212}{d}", .{s.deletions}))));
            return zpui.intoAnyElement(b);
        },
        .output => |o| {
            var b = body.py(px(6)).fontFamily(theme.font_mono).textSize(px(tool_text_size));
            for (o.lines, 0..) |l, lix| {
                const line_row = div().h(px(rows.output_line_height)).wFull().minW0().flex().itemsCenter().textColor(theme.text_faint);
                b = b.child(if (l.len == 0) line_row else line_row.child(selectableLine(key, lix, zpui.StyledText.init(l), theme)));
            }
            if (o.truncated_by > 0) b = b.child(moreLines(o.truncated_by, theme));
            return zpui.intoAnyElement(b);
        },
        .thought => |o| {
            var b = body.py(px(6)).textSize(px(tool_text_size));
            for (o.lines, 0..) |l, lix| {
                var line_row = div().h(px(rows.output_line_height)).wFull().minW0().flex().itemsCenter();
                if (thoughtLineText(l, theme)) |st| line_row = line_row.child(selectableLine(key, lix, st, theme));
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

/// An icon rotated about its own center (gpui `Transformation::rotate`).
pub fn rotatedIcon(which: assets.Icon, size: f32, angle: f32, color: Hsla) zpui.Svg {
    return zpui.svg().source(which.path(), which.svg()).size(px(size)).flexNone().textColor(color)
        .withTransformation(.rotate(angle));
}
