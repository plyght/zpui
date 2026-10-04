//! `layout/sequence.rs`: sequence diagram layout, label placement and bounds.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir.zig");
const util = @import("../util.zig");
const Theme = @import("../theme.zig").Theme;
const LayoutConfig = @import("../config.zig").LayoutConfig;
const text = @import("../text.zig");
const t = @import("types.zig");
const L = @import("layout.zig");
const Point = t.Point;
const Rect = t.Rect;
const TextBlock = t.TextBlock;
const NodeLayout = t.NodeLayout;
const EdgeLayout = t.EdgeLayout;
const INF = std.math.inf(f32);
const EPS = std.math.floatEps(f32);

const LABEL_PAD_X: f32 = 3.0;
const LABEL_PAD_Y: f32 = 2.0;
const ENDPOINT_PAD_X: f32 = 2.5;
const ENDPOINT_PAD_Y: f32 = 1.5;
const TOUCH_EPS: f32 = 0.5;
const CENTER_GAP_MIN: f32 = 1.8;
const CENTER_GAP_MAX: f32 = 7.0;
const CENTER_FAR_GAP: f32 = 10.5;
const END_GAP_TARGET: f32 = 2.5;
const END_GAP_MIN: f32 = 1.0;
const END_GAP_MAX: f32 = 6.0;
const END_FAR_GAP: f32 = 10.0;
const TAN_LIN: f32 = 0.22;
const TAN_QUAD: f32 = 0.95;
const TAN_SOFT: f32 = 1.2;
const TAN_FAR: f32 = 3.2;

const Geometry = struct {
    actor_min_width: f32,
    actor_min_height: f32,
    actor_pad_y: f32,
    lane_pitch: f32,
    min_lane_gap: f32,
    message_step: f32,
    note_gap_y: f32,
    note_gap_x: f32,
    note_padding_x: f32,
    note_padding_y: f32,
    lane_side_pad_x: f32,
    footbox_gap: f32,

    fn fromTheme(theme: *const Theme) Geometry {
        const f = @max(theme.font_size, 1.0);
        return .{
            .actor_min_width = @max(f * 9.375, 150.0),
            .actor_min_height = @max(f * 4.0625, 65.0),
            .actor_pad_y = @max(f * 0.75, 12.0),
            .lane_pitch = @max(f * 12.5, 200.0),
            .min_lane_gap = @max(f * 3.125, 50.0),
            .message_step = @max(f * 2.875, 46.0),
            .note_gap_y = @max(f * 0.625, 10.0),
            .note_gap_x = @max(f * 1.5625, 25.0),
            .note_padding_x = @max(f * 1.0, 15.0),
            .note_padding_y = @max(f * 0.55, 6.0),
            .lane_side_pad_x = @max(f * 1.5625, 25.0),
            .footbox_gap = @max(f * 1.375, 22.0),
        };
    }
};

fn measure(a: Allocator, s: []const u8, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!TextBlock {
    var c = config.*;
    c.max_label_width_chars = @min(c.max_label_width_chars, 14);
    return text.measureLabelWithFontSize(a, s, @max(theme.font_size, 16.0), &c, true, theme.font_family);
}

fn laneCenter(n: *const NodeLayout) f32 {
    return n.x + n.width / 2.0;
}

fn indexOf(list: []const []const u8, id: []const u8) ?usize {
    for (list, 0..) |x, i| if (util.eql(x, id)) return i;
    return null;
}

pub fn computeSequenceLayout(a: Allocator, graph: *const ir.Graph, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!t.Layout {
    var nodes: t.NodeMap = .{};
    var edges: std.ArrayList(EdgeLayout) = .empty;
    var participants: std.ArrayList([]const u8) = .empty;
    try participants.appendSlice(a, graph.sequence_participants.items);
    for (graph.nodes.keys.items) |id| if (indexOf(participants.items, id) == null) try participants.append(a, id);
    const geo = Geometry.fromTheme(theme);
    const labels = try a.alloc(TextBlock, participants.items.len);
    var max_lh: f32 = 0;
    for (participants.items, 0..) |id, i| {
        labels[i] = try measure(a, graph.nodes.get(id).?.label, theme, config);
        max_lh = @max(max_lh, labels[i].height);
    }
    const actor_h = @max(max_lh + geo.actor_pad_y * 2.0, geo.actor_min_height);
    // compute_sequence_lane_centers (all participants use actor_min_width)
    const np = participants.items.len;
    const centers = try a.alloc(f32, np);
    if (np > 0) {
        const pitches = try a.alloc(f32, np - 1);
        for (pitches) |*p| p.* = @max(geo.lane_pitch, geo.actor_min_width + geo.min_lane_gap);
        for (graph.edges.items) |e| {
            const fi = indexOf(participants.items, e.from) orelse continue;
            const ti = indexOf(participants.items, e.to) orelse continue;
            const li = @min(fi, ti);
            const ri = @max(fi, ti);
            if (ri != li + 1) continue;
            const l = e.label orelse continue;
            const block = try measure(a, l, theme, config);
            var base = geo.actor_min_width * 0.5;
            if (li != 0) {
                var sum: f32 = 0;
                for (pitches[0..li]) |p| sum += p;
                base = geo.actor_min_width * 0.5 + sum;
            }
            const mid = base + geo.lane_pitch * 0.5;
            const right_min = mid + block.width * 0.5 + geo.note_gap_x;
            const cur_right = base + pitches[li];
            pitches[li] = @max(pitches[li], right_min - base);
            pitches[li] = @max(pitches[li], cur_right - base);
        }
        centers[0] = geo.actor_min_width * 0.5;
        for (pitches, 0..) |p, i| centers[i + 1] = centers[i] + p;
    }
    for (participants.items, 0..) |id, i| {
        const node = graph.nodes.get(id).?;
        try nodes.put(a, id, .{ .id = id, .x = centers[i] - geo.actor_min_width / 2.0, .y = 0, .width = geo.actor_min_width, .height = actor_h, .label = labels[i], .shape = node.shape, .style = L.resolveNodeStyle(id, graph), .link = graph.node_links.get(id) });
    }
    const base_spacing = @max(geo.message_step, 18.0);
    const ne = graph.edges.items.len;
    const row_spacing = try a.alloc(f32, ne);
    for (graph.edges.items, 0..) |e, i| {
        var rh: f32 = 0;
        for ([_]?[]const u8{ e.label, e.start_label, e.end_label }) |l| if (l) |s| {
            rh = @max(rh, (try measure(a, s, theme, config)).height);
        };
        row_spacing[i] = @max(base_spacing, rh + theme.font_size * 1.25);
    }
    const extra = try a.alloc(f32, ne);
    @memset(extra, 0);
    const frame_end_pad = base_spacing * 0.25;
    for (graph.sequence_frames.items) |f| {
        if (f.start_idx < ne) extra[f.start_idx] += base_spacing;
        if (f.sections.len > 1) for (f.sections[1..]) |s| {
            if (s.start_idx < ne) extra[s.start_idx] += base_spacing;
        };
        if (f.end_idx < ne) extra[f.end_idx] += frame_end_pad;
    }
    var cursor = actor_h;
    var message_ys: std.ArrayList(f32) = .empty;
    var notes: std.ArrayList(t.SequenceNoteLayout) = .empty;
    for (0..ne + 1) |idx| {
        for (graph.sequence_notes.items) |note| {
            if (@min(note.index, ne) != idx) continue;
            cursor += geo.note_gap_y;
            const label = try measure(a, note.label, theme, config);
            var w = @max(label.width + geo.note_padding_x * 2.0, geo.actor_min_width);
            const h = label.height + geo.note_padding_y * 2.0;
            var xs: std.ArrayList(f32) = .empty;
            for (note.participants) |pid| if (nodes.get(pid)) |n| try xs.append(a, laneCenter(n));
            if (xs.items.len == 0) try xs.append(a, 0);
            var mn = INF;
            var mx = -INF;
            for (xs.items) |x| {
                mn = @min(mn, x);
                mx = @max(mx, x);
            }
            if (note.position == .over and note.participants.len > 1) w = @max(w, @abs(mx - mn) + geo.note_gap_x * 2.0);
            const x = switch (note.position) {
                .left_of => xs.items[0] - geo.note_gap_x - w,
                .right_of => xs.items[0] + geo.note_gap_x,
                .over => (mn + mx) / 2.0 - w / 2.0,
            };
            try notes.append(a, .{ .x = x, .y = cursor, .width = w, .height = h, .label = label, .position = note.position, .participants = note.participants, .index = note.index });
            cursor += h;
        }
        if (idx < ne) {
            cursor += extra[idx] + row_spacing[idx];
            try message_ys.append(a, cursor);
        }
    }
    for (graph.edges.items, 0..) |e, idx| {
        const from = nodes.get(e.from).?;
        const to = nodes.get(e.to).?;
        const y = if (idx < message_ys.items.len) message_ys.items[idx] else cursor;
        var pts: std.ArrayList(Point) = .empty;
        if (util.eql(e.from, e.to)) {
            const pad = geo.note_gap_x * 1.4;
            const x = laneCenter(from);
            try pts.appendSlice(a, &.{ .{ x, y }, .{ x + pad, y }, .{ x + pad, y + pad }, .{ x, y + pad } });
        } else try pts.appendSlice(a, &.{ .{ laneCenter(from), y }, .{ laneCenter(to), y } });
        var ov = L.resolveEdgeStyle(idx, graph);
        if (e.style == .dotted and ov.dasharray == null) ov.dasharray = "3 3";
        try edges.append(a, .{
            .from = e.from,
            .to = e.to,
            .label = if (e.label) |l| try measure(a, l, theme, config) else null,
            .start_label = if (e.start_label) |l| try measure(a, l, theme, config) else null,
            .end_label = if (e.end_label) |l| try measure(a, l, theme, config) else null,
            .points = pts,
            .directed = e.directed,
            .arrow_start = e.arrow_start,
            .arrow_end = e.arrow_end,
            .arrow_start_kind = e.arrow_start_kind,
            .arrow_end_kind = e.arrow_end_kind,
            .start_decoration = e.start_decoration,
            .end_decoration = e.end_decoration,
            .style = e.style,
            .override_style = ov,
        });
    }
    var frames_out: std.ArrayList(t.SequenceFrameLayout) = .empty;
    if (graph.sequence_frames.items.len > 0 and message_ys.items.len > 0) {
        const frames = try a.dupe(ir.SequenceFrame, graph.sequence_frames.items);
        std.mem.sort(ir.SequenceFrame, frames, {}, struct {
            fn lt(_: void, x: ir.SequenceFrame, y: ir.SequenceFrame) bool {
                if (x.start_idx != y.start_idx) return x.start_idx < y.start_idx;
                return y.end_idx < x.end_idx;
            }
        }.lt);
        for (frames) |f| {
            if (f.start_idx >= f.end_idx or f.start_idx >= message_ys.items.len) continue;
            var mnc = INF;
            var mxc = -INF;
            const end = @min(f.end_idx, ne);
            if (f.start_idx < end) for (graph.edges.items[f.start_idx..end]) |e| for ([_][]const u8{ e.from, e.to }) |id| if (nodes.get(id)) |n| {
                mnc = @min(mnc, laneCenter(n));
                mxc = @max(mxc, laneCenter(n));
            };
            if (!std.math.isFinite(mnc) or !std.math.isFinite(mxc)) for (nodes.values()) |*n| {
                mnc = @min(mnc, laneCenter(n));
                mxc = @max(mxc, laneCenter(n));
            };
            if (!std.math.isFinite(mnc) or !std.math.isFinite(mxc)) continue;
            const fpx = @max(theme.font_size * 0.7, 11.0);
            const fx = mnc - fpx;
            const fw = (mxc - mnc) + fpx + theme.font_size * 1.05;
            const first_y = message_ys.items[f.start_idx];
            const li = f.end_idx -| 1;
            const last_y = if (li < message_ys.items.len) message_ys.items[li] else first_y;
            var min_y = first_y;
            var max_y = last_y;
            for (notes.items) |n| if (n.index >= f.start_idx and n.index <= f.end_idx) {
                min_y = @min(min_y, n.y);
                max_y = @max(max_y, n.y + n.height);
            };
            const top_off = @max(base_spacing * 1.8, theme.font_size * 3.9);
            const bot_off = @max(theme.font_size * 0.85, 12.0);
            const fy = min_y - top_off;
            const fh = @max(max_y - min_y, 0.0) + top_off + bot_off;
            const kw: []const u8 = switch (f.kind) {
                .alt => "alt",
                .opt => "opt",
                .loop => "loop",
                .par => "par",
                .rect => "rect",
                .critical => "critical",
                .@"break" => "break",
            };
            const lb = try measure(a, kw, theme, config);
            const lbw = @max(lb.width + theme.font_size * 1.2, theme.font_size * 3.1);
            const lbh = @max(theme.font_size * 1.25, 20.0);
            var dividers: std.ArrayList(f32) = .empty;
            if (f.sections.len >= 2) for (0..f.sections.len - 1) |i| {
                const pe = f.sections[i].end_idx -| 1;
                const by = if (pe < message_ys.items.len) message_ys.items[pe] else first_y;
                try dividers.append(a, by + theme.font_size * 0.9);
            };
            var sls: std.ArrayList(t.SequenceLabel) = .empty;
            for (f.sections, 0..) |s, si| {
                const sl = s.label orelse continue;
                const block = try measure(a, try std.fmt.allocPrint(a, "[{s}]", .{sl}), theme, config);
                const ly = if (si == 0) fy + lbh - theme.font_size * 0.15 else (if (si - 1 < dividers.items.len) dividers.items[si - 1] else fy + theme.font_size * 0.7) + theme.font_size * 0.9;
                const side = theme.font_size * 0.45;
                const com = struct {
                    fn pick(pref: f32, mn: f32, mx: f32) f32 {
                        return if (mn <= mx) std.math.clamp(pref, mn, mx) else (mn + mx) / 2.0;
                    }
                }.pick;
                const lx = if (si == 0)
                    com(fx + lbw + theme.font_size * 3.0 + block.width / 2.0, fx + block.width / 2.0 + theme.font_size * 0.4, fx + fw - block.width / 2.0 - theme.font_size * 0.4)
                else
                    com(fx + fw / 2.0, fx + block.width / 2.0 + side, fx + fw - block.width / 2.0 - side);
                try sls.append(a, .{ .x = lx, .y = ly, .text = block });
            }
            try frames_out.append(a, .{ .kind = f.kind, .x = fx, .y = fy, .width = fw, .height = fh, .label_box = .{ fx, fy, lbw, lbh }, .label = .{ .x = fx + lbw / 2.0, .y = fy + lbh / 2.0, .text = lb }, .section_labels = sls.items, .dividers = dividers.items });
        }
    }
    const lifeline_start = actor_h;
    var last_y = if (message_ys.items.len > 0) message_ys.items[message_ys.items.len - 1] else lifeline_start + base_spacing;
    for (notes.items) |n| last_y = @max(last_y, n.y + n.height);
    const lifeline_end = last_y + geo.footbox_gap;
    var data: t.SequenceData = .{};
    for (participants.items) |id| if (nodes.get(id)) |n| {
        try data.lifelines.append(a, .{ .id = n.id, .x = laneCenter(n), .y1 = lifeline_start, .y2 = lifeline_end });
        var foot = n.*;
        foot.y = lifeline_end;
        try data.footboxes.append(a, foot);
    };
    if (graph.sequence_boxes.items.len > 0) {
        const pad_x = geo.lane_side_pad_x;
        const pad_y = theme.font_size * 0.6;
        var bottom = lifeline_end;
        for (data.footboxes.items) |f| bottom = @max(bottom, f.y + f.height);
        for (graph.sequence_boxes.items) |bx| {
            var mnc = INF;
            var mxc = -INF;
            for (bx.participants.items) |pid| if (nodes.get(pid)) |n| {
                mnc = @min(mnc, laneCenter(n));
                mxc = @max(mxc, laneCenter(n));
            };
            if (!std.math.isFinite(mnc) or !std.math.isFinite(mxc)) continue;
            try data.boxes.append(a, .{ .x = mnc - pad_x, .y = 0, .width = (mxc - mnc) + pad_x * 2.0, .height = bottom + pad_y, .label = if (bx.label) |l| try measure(a, l, theme, config) else null, .color = bx.color });
        }
    }
    const aw = @max(theme.font_size * 0.625, 10.0);
    const aoff = @max(aw * 0.6, 4.0);
    const aend = (if (message_ys.items.len > 0) message_ys.items[message_ys.items.len - 1] else lifeline_start + base_spacing * 0.5) + base_spacing * 0.6;
    const Ev = struct { index: usize, order: usize, ev: ir.SequenceActivation };
    var events: std.ArrayList(Ev) = .empty;
    for (graph.sequence_activations.items, 0..) |ev, o| try events.append(a, .{ .index = ev.index, .order = o, .ev = ev });
    std.mem.sort(Ev, events.items, {}, struct {
        fn lt(_: void, x: Ev, y: Ev) bool {
            if (x.index != y.index) return x.index < y.index;
            return x.order < y.order;
        }
    }.lt);
    const Fr = struct { y: f32, depth: usize };
    var stacks: std.StringArrayHashMapUnmanaged(std.ArrayList(Fr)) = .empty;
    for (events.items) |e| {
        const y = if (e.ev.index < message_ys.items.len) message_ys.items[e.ev.index] else aend;
        const gop = try stacks.getOrPut(a, e.ev.participant);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const stack = gop.value_ptr;
        switch (e.ev.kind) {
            .activate => try stack.append(a, .{ .y = y, .depth = stack.items.len }),
            .deactivate => if (stack.pop()) |fr| if (nodes.get(e.ev.participant)) |n| {
                var y0 = @min(fr.y, y);
                var h = @abs(y - fr.y);
                if (h < base_spacing * 0.6) h = base_spacing * 0.6;
                if (y0 < lifeline_start) y0 = lifeline_start;
                try data.activations.append(a, .{ .x = laneCenter(n) - aw / 2.0 + @as(f32, @floatFromInt(fr.depth)) * aoff, .y = y0, .width = aw, .height = h, .participant = e.ev.participant, .depth = fr.depth });
            },
        }
    }
    for (stacks.keys(), stacks.values()) |pid, stack| for (stack.items) |fr| if (nodes.get(pid)) |n| {
        var y0 = @min(fr.y, aend);
        var h = @abs(aend - fr.y);
        if (h < base_spacing * 0.6) h = base_spacing * 0.6;
        if (y0 < lifeline_start) y0 = lifeline_start;
        try data.activations.append(a, .{ .x = laneCenter(n) - aw / 2.0 + @as(f32, @floatFromInt(fr.depth)) * aoff, .y = y0, .width = aw, .height = h, .participant = pid, .depth = fr.depth });
    };
    if (graph.sequence_autonumber) |start| {
        var value = start;
        for (graph.edges.items, 0..) |e, idx| {
            const from = nodes.get(e.from) orelse continue;
            if (idx >= message_ys.items.len) continue;
            const fx = laneCenter(from);
            const tx = if (nodes.get(e.to)) |n| laneCenter(n) else fx;
            try data.numbers.append(a, .{ .x = fx + @as(f32, if (tx >= fx) 16.0 else -16.0), .y = message_ys.items[idx] - @max(theme.font_size * 0.85, 10.0), .value = value });
            value += 1;
        }
    }
    data.frames = frames_out;
    data.notes = notes;
    var layout: t.Layout = .{ .kind = graph.kind, .nodes = nodes, .edges = edges, .width = 1, .height = 1, .diagram = .{ .sequence = data } };
    finalizeSequenceLayoutBounds(&layout);
    return layout;
}

pub fn resolveSequenceLabelPositions(a: Allocator, layout: *t.Layout, theme: *const Theme) Allocator.Error!void {
    if (layout.diagram != .sequence) return;
    const seq = &layout.diagram.sequence;
    const edges = layout.edges.items;
    if (edges.len == 0) return;
    var occ: std.ArrayList(Rect) = .empty;
    for (layout.nodes.values()) |n| try occ.append(a, .{ n.x, n.y, n.width, n.height });
    for (seq.lifelines.items) |l| try occ.append(a, .{ l.x - 1.5, l.y1, 3.0, @max(l.y2 - l.y1, 0.0) });
    for (seq.footboxes.items) |f| try occ.append(a, .{ f.x, f.y, f.width, f.height });
    for (seq.frames.items) |f| {
        try occ.append(a, f.label_box);
        const lp: f32 = 1.5;
        try occ.append(a, .{ f.x - lp, f.y - lp, f.width + lp * 2.0, lp * 2.0 });
        try occ.append(a, .{ f.x - lp, f.y + f.height - lp, f.width + lp * 2.0, lp * 2.0 });
        try occ.append(a, .{ f.x - lp, f.y - lp, lp * 2.0, f.height + lp * 2.0 });
        try occ.append(a, .{ f.x + f.width - lp, f.y - lp, lp * 2.0, f.height + lp * 2.0 });
        const spx = @max(theme.font_size * 0.18, 1.5);
        const spy = @max(theme.font_size * 0.15, 1.2);
        for (f.section_labels) |l| try occ.append(a, .{ l.x - l.text.width / 2.0 - spx, l.y - l.text.height / 2.0 - spy, l.text.width + spx * 2.0, l.text.height + spy * 2.0 });
        for (f.dividers) |d| try occ.append(a, .{ f.x, d - lp, f.width, lp * 2.0 });
    }
    for (seq.notes.items) |n| try occ.append(a, .{ n.x, n.y, n.width, n.height });
    for (seq.activations.items) |ac| try occ.append(a, .{ ac.x, ac.y, ac.width, ac.height });
    const nr = @max(theme.font_size * 0.45, 6.0);
    for (seq.numbers.items) |n| try occ.append(a, .{ n.x - nr, n.y - nr, nr * 2.0, nr * 2.0 });
    const paths = try a.alloc([]const Point, edges.len);
    for (edges, 0..) |e, i| paths[i] = try a.dupe(Point, e.points.items);
    for (edges, 0..) |*e, idx| {
        if (e.label) |l| {
            const an = centerAnchor(paths[idx], &l, occ.items, paths, idx, theme);
            e.label_anchor = an;
            try occ.append(a, labelRect(an, &l, LABEL_PAD_X, LABEL_PAD_Y));
        }
        for ([_]bool{ true, false }) |start| {
            const l = (if (start) e.start_label else e.end_label) orelse continue;
            const an = endpointAnchor(paths[idx], &l, start, occ.items, paths, idx, theme);
            if (start) e.start_label_anchor = an else e.end_label_anchor = an;
            if (an) |c| try occ.append(a, labelRect(c, &l, ENDPOINT_PAD_X, ENDPOINT_PAD_Y));
        }
    }
}

const Mode = enum { center, endpoint };

fn centerAnchor(points: []const Point, label: *const TextBlock, occ: []const Rect, paths: []const []const Point, idx: usize, theme: *const Theme) Point {
    const md = midpointWithDirection(points);
    const anchor = md[0];
    const dir = md[1];
    const normal = Point{ -dir[1], dir[0] };
    const ns = @max(label.height * 0.5 + LABEL_PAD_Y, 6.0);
    const ts = @max(label.width + theme.font_size * 0.35, 10.0) * 0.24;
    const tp = [_]f32{ 0.0, -0.25, 0.25, -0.55, 0.55, -0.95, 0.95, -1.45, 1.45, -2.1, 2.1, -2.9, 2.9, -3.8, 3.8, -4.9, 4.9, -6.2, 6.2 };
    const tw = [_]f32{ 0.0, -0.35, 0.35, -0.75, 0.75, -1.3, 1.3, -2.0, 2.0, -2.9, 2.9, -4.0, 4.0, -5.3, 5.3, -6.8, 6.8, -8.4, 8.4 };
    const n1 = [_]f32{ -1.2, 1.2, -1.35, 1.35, -1.5, 1.5 };
    const n2 = [_]f32{ -1.05, 1.05, -1.8, 1.8, -2.25, 2.25 };
    const n3 = [_]f32{ -0.9, 0.9, -2.7, 2.7, -3.4, 3.4, -4.4, 4.4, -5.8, 5.8, -7.4, 7.4 };
    var best = anchor;
    var best_score = INF;
    const bands = [_][2][]const f32{ .{ &tp, &n1 }, .{ &tp, &n2 }, .{ &tw, &n3 } };
    for (bands) |band| for (band[0]) |tt| for (band[1]) |n| {
        const c = Point{ anchor[0] + dir[0] * ts * tt + normal[0] * ns * n, anchor[1] + dir[1] * ts * tt + normal[1] * ns * n };
        const r = labelRect(c, label, LABEL_PAD_X, LABEL_PAD_Y);
        var score = labelPenalty(r, c, anchor, points, label.height, occ, .center);
        score += edgeOverlapPenalty(r, paths, idx);
        score += pointPolylineDistance(c, points) * 0.045;
        const ta = @abs(tt);
        score += ta * TAN_LIN + ta * ta * TAN_QUAD;
        if (ta > TAN_SOFT) score += (ta - TAN_SOFT) * TAN_FAR;
        if (@abs(dir[0]) > @abs(dir[1]) and c[1] > anchor[1]) score += 0.3;
        if (score < best_score) {
            best_score = score;
            best = c;
        }
    };
    return best;
}

fn endpointAnchor(points: []const Point, label: *const TextBlock, start: bool, occ: []const Rect, paths: []const []const Point, idx: usize, theme: *const Theme) ?Point {
    if (points.len < 2) return null;
    const p0 = if (start) points[0] else points[points.len - 1];
    const p1 = if (start) points[1] else points[points.len - 2];
    const dx = p1[0] - p0[0];
    const dy = p1[1] - p0[1];
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= EPS) return null;
    const dir = Point{ dx / len, dy / len };
    const off = @max(theme.font_size * 0.45, 6.0);
    const anchor = Point{ p0[0] + dir[0] * off * 1.4, p0[1] + dir[1] * off * 1.4 };
    const normal = Point{ -dir[1], dir[0] };
    const step = @max(theme.font_size * 0.45, 6.0);
    var best = anchor;
    var best_score = INF;
    for ([_]f32{ 0.0, 0.6, -0.6, 1.2, -1.2, 2.0, -2.0, 2.9, -2.9 }) |tt| for ([_]f32{ 0.35, -0.35, 0.75, -0.75, 1.1, -1.1, 1.45, -1.45, 1.8, -1.8 }) |n| {
        const c = Point{ anchor[0] + dir[0] * step * tt + normal[0] * step * n, anchor[1] + dir[1] * step * tt + normal[1] * step * n };
        const r = labelRect(c, label, ENDPOINT_PAD_X, ENDPOINT_PAD_Y);
        var score = labelPenalty(r, c, anchor, points, label.height, occ, .endpoint);
        score += edgeOverlapPenalty(r, paths, idx);
        score += distance(c, anchor) * 0.05;
        if (score < best_score) {
            best_score = score;
            best = c;
        }
    };
    return best;
}

fn midpointWithDirection(points: []const Point) [2]Point {
    if (points.len < 2) return .{ if (points.len > 0) points[0] else .{ 0, 0 }, .{ 1, 0 } };
    var total: f32 = 0;
    for (0..points.len - 1) |i| total += distance(points[i], points[i + 1]);
    if (total <= EPS) {
        const dx = points[1][0] - points[0][0];
        const dy = points[1][1] - points[0][1];
        const len = @max(@sqrt(dx * dx + dy * dy), 1e-6);
        return .{ points[0], .{ dx / len, dy / len } };
    }
    const target = total * 0.5;
    var acc: f32 = 0;
    for (0..points.len - 1) |i| {
        const len = distance(points[i], points[i + 1]);
        if (acc + len >= target) {
            const s0 = points[i];
            const s1 = points[i + 1];
            const lt = std.math.clamp((target - acc) / @max(len, 1e-6), 0.0, 1.0);
            const dx = s1[0] - s0[0];
            const dy = s1[1] - s0[1];
            const dl = @max(@sqrt(dx * dx + dy * dy), 1e-6);
            return .{ .{ s0[0] + dx * lt, s0[1] + dy * lt }, .{ dx / dl, dy / dl } };
        }
        acc += len;
    }
    const last = points[points.len - 1];
    const prev = points[points.len - 2];
    const dx = last[0] - prev[0];
    const dy = last[1] - prev[1];
    const len = @max(@sqrt(dx * dx + dy * dy), 1e-6);
    return .{ last, .{ dx / len, dy / len } };
}

fn labelPenalty(r: Rect, center: Point, anchor: Point, own: []const Point, lh: f32, occ: []const Rect, mode: Mode) f32 {
    var area_sum: f32 = 0;
    var count: usize = 0;
    for (occ) |o| {
        const ar = overlapArea(r, o);
        if (ar > 0.0) {
            count += 1;
            area_sum += ar;
        }
    }
    const gap = polylineRectGap(own, r);
    const gp: f32 = switch (mode) {
        .center => blk: {
            const h = @max(lh, 1.0);
            const target = std.math.clamp(h * 0.16, 2.8, 4.8);
            const close = std.math.clamp(h * 0.10, 1.2, 2.6);
            if (!std.math.isFinite(gap)) break :blk 150.0;
            if (gap <= close) break :blk 140.0 + @max(close - gap, 0.0) * 28.0;
            if (gap < CENTER_GAP_MIN) {
                const d = (CENTER_GAP_MIN - gap) / CENTER_GAP_MIN;
                break :blk d * d * 22.0;
            }
            if (gap <= CENTER_GAP_MAX) {
                const d = (gap - target) / @max(target, 1e-3);
                break :blk d * d * 0.85;
            }
            const far = gap - CENTER_GAP_MAX;
            var p = far * far * 1.7 + far * 0.35;
            if (gap > CENTER_FAR_GAP) p += (gap - CENTER_FAR_GAP) * 0.7;
            break :blk p;
        },
        .endpoint => blk: {
            var p: f32 = 0;
            if (gap <= TOUCH_EPS) {
                p += 120.0 + @max(TOUCH_EPS - gap, 0.0) * 30.0;
            } else if (gap < END_GAP_MIN) {
                const d = (END_GAP_MIN - gap) / END_GAP_MIN;
                p += d * d * 14.0;
            } else if (gap <= END_GAP_MAX) {
                const d = (gap - END_GAP_TARGET) / END_GAP_TARGET;
                p += d * d * 0.9;
            } else {
                const far = gap - END_GAP_MAX;
                p += far * far * 2.4 + far * 0.4;
                if (gap > END_FAR_GAP) p += (gap - END_FAR_GAP) * 0.9;
            }
            break :blk p;
        },
    };
    const aw: f32 = if (mode == .center) 0.018 else 0.025;
    const op: f32 = if (count == 0) 0.0 else 10_000.0 + @as(f32, @floatFromInt(count)) * 1_000.0 + area_sum * 4.0;
    return op + gp + distance(center, anchor) * aw;
}

fn edgeOverlapPenalty(r: Rect, paths: []const []const Point, idx: usize) f32 {
    var hits: usize = 0;
    for (paths, 0..) |p, i| {
        if (i == idx or p.len < 2) continue;
        for (0..p.len - 1) |k| if (segmentIntersectsRect(p[k], p[k + 1], r)) {
            hits += 1;
            break;
        };
    }
    return if (hits == 0) 0.0 else 1.0 + @as(f32, @floatFromInt(hits)) * 4.0;
}

fn labelRect(c: Point, l: *const TextBlock, px: f32, py: f32) Rect {
    return .{ c[0] - l.width / 2.0 - px, c[1] - l.height / 2.0 - py, l.width + px * 2.0, l.height + py * 2.0 };
}

fn overlapArea(x: Rect, y: Rect) f32 {
    const x1 = @max(x[0], y[0]);
    const y1 = @max(x[1], y[1]);
    const x2 = @min(x[0] + x[2], y[0] + y[2]);
    const y2 = @min(x[1] + x[3], y[1] + y[3]);
    if (x2 <= x1 or y2 <= y1) return 0.0;
    return (x2 - x1) * (y2 - y1);
}

fn pointPolylineDistance(p: Point, points: []const Point) f32 {
    if (points.len == 0) return 0.0;
    if (points.len == 1) return distance(p, points[0]);
    var best = INF;
    for (0..points.len - 1) |i| best = @min(best, pointSegmentDistance(p, points[i], points[i + 1]));
    return best;
}

fn pointRectDistance(p: Point, r: Rect) f32 {
    const dx: f32 = if (p[0] < r[0]) r[0] - p[0] else if (p[0] > r[0] + r[2]) p[0] - (r[0] + r[2]) else 0.0;
    const dy: f32 = if (p[1] < r[1]) r[1] - p[1] else if (p[1] > r[1] + r[3]) p[1] - (r[1] + r[3]) else 0.0;
    return @sqrt(dx * dx + dy * dy);
}

fn segmentRectDistance(a: Point, b: Point, r: Rect) f32 {
    if (segmentIntersectsRect(a, b, r)) return 0.0;
    var best = @min(pointRectDistance(a, r), pointRectDistance(b, r));
    for ([_]Point{ .{ r[0], r[1] }, .{ r[0] + r[2], r[1] }, .{ r[0] + r[2], r[1] + r[3] }, .{ r[0], r[1] + r[3] } }) |c| best = @min(best, pointSegmentDistance(c, a, b));
    return best;
}

fn polylineRectGap(points: []const Point, r: Rect) f32 {
    if (points.len < 2) return INF;
    var best = INF;
    for (0..points.len - 1) |i| best = @min(best, segmentRectDistance(points[i], points[i + 1], r));
    return best;
}

fn pointSegmentDistance(p: Point, a: Point, b: Point) f32 {
    const ab = Point{ b[0] - a[0], b[1] - a[1] };
    const l2 = ab[0] * ab[0] + ab[1] * ab[1];
    if (l2 <= EPS) return distance(p, a);
    const tt = std.math.clamp(((p[0] - a[0]) * ab[0] + (p[1] - a[1]) * ab[1]) / l2, 0.0, 1.0);
    return distance(p, .{ a[0] + ab[0] * tt, a[1] + ab[1] * tt });
}

fn distance(a: Point, b: Point) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    return @sqrt(dx * dx + dy * dy);
}

fn segmentIntersectsRect(a: Point, b: Point, r: Rect) bool {
    if (@max(a[0], b[0]) < r[0] or @min(a[0], b[0]) > r[0] + r[2] or @max(a[1], b[1]) < r[1] or @min(a[1], b[1]) > r[1] + r[3]) return false;
    if (pointInRect(a, r) or pointInRect(b, r)) return true;
    const c = [4]Point{ .{ r[0], r[1] }, .{ r[0] + r[2], r[1] }, .{ r[0] + r[2], r[1] + r[3] }, .{ r[0], r[1] + r[3] } };
    for (0..4) |i| if (segmentsIntersect(a, b, c[i], c[(i + 1) % 4])) return true;
    return false;
}

fn pointInRect(p: Point, r: Rect) bool {
    return p[0] >= r[0] and p[0] <= r[0] + r[2] and p[1] >= r[1] and p[1] <= r[1] + r[3];
}

fn segmentsIntersect(a: Point, b: Point, c: Point, d: Point) bool {
    const e: f32 = 1e-6;
    const o1 = orient(a, b, c);
    const o2 = orient(a, b, d);
    const o3 = orient(c, d, a);
    const o4 = orient(c, d, b);
    if (@abs(o1) < e and onSegment(a, b, c)) return true;
    if (@abs(o2) < e and onSegment(a, b, d)) return true;
    if (@abs(o3) < e and onSegment(c, d, a)) return true;
    if (@abs(o4) < e and onSegment(c, d, b)) return true;
    return (o1 > 0.0) != (o2 > 0.0) and (o3 > 0.0) != (o4 > 0.0);
}

fn orient(a: Point, b: Point, c: Point) f32 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

fn onSegment(a: Point, b: Point, c: Point) bool {
    const e: f32 = 1e-6;
    return c[0] >= @min(a[0], b[0]) - e and c[0] <= @max(a[0], b[0]) + e and c[1] >= @min(a[1], b[1]) - e and c[1] <= @max(a[1], b[1]) + e;
}

fn ext(b: *[4]f32, x: f32, y: f32, w: f32, h: f32) void {
    b[0] = @min(b[0], x);
    b[1] = @min(b[1], y);
    b[2] = @max(b[2], x + w);
    b[3] = @max(b[3], y + h);
}

pub fn finalizeSequenceLayoutBounds(layout: *t.Layout) void {
    if (layout.diagram != .sequence) return;
    const seq = &layout.diagram.sequence;
    var b = [4]f32{ INF, INF, -INF, -INF };
    for (layout.nodes.values()) |n| ext(&b, n.x, n.y, n.width, n.height);
    for (seq.footboxes.items) |n| ext(&b, n.x, n.y, n.width, n.height);
    for (seq.boxes.items) |n| ext(&b, n.x, n.y, n.width, n.height);
    for (seq.frames.items) |n| ext(&b, n.x, n.y, n.width, n.height);
    for (seq.notes.items) |n| ext(&b, n.x, n.y, n.width, n.height);
    for (seq.activations.items) |n| ext(&b, n.x, n.y, n.width, n.height);
    for (seq.numbers.items) |n| ext(&b, n.x, n.y, 0, 0);
    for (layout.edges.items) |e| {
        for (e.points.items) |p| ext(&b, p[0], p[1], 0, 0);
        if (e.label) |l| if (e.label_anchor) |c| ext(&b, c[0] - l.width / 2.0 - LABEL_PAD_X, c[1] - l.height / 2.0 - LABEL_PAD_Y, l.width + 2.0 * LABEL_PAD_X, l.height + 2.0 * LABEL_PAD_Y);
        if (e.start_label) |l| if (e.start_label_anchor) |c| ext(&b, c[0] - l.width / 2.0 - ENDPOINT_PAD_X, c[1] - l.height / 2.0 - ENDPOINT_PAD_Y, l.width + 2.0 * ENDPOINT_PAD_X, l.height + 2.0 * ENDPOINT_PAD_Y);
        if (e.end_label) |l| if (e.end_label_anchor) |c| ext(&b, c[0] - l.width / 2.0 - ENDPOINT_PAD_X, c[1] - l.height / 2.0 - ENDPOINT_PAD_Y, l.width + 2.0 * ENDPOINT_PAD_X, l.height + 2.0 * ENDPOINT_PAD_Y);
    }
    for (b) |v| if (!std.math.isFinite(v)) {
        layout.width = 1;
        layout.height = 1;
        return;
    };
    const sx = -b[0];
    const sy = -b[1];
    if (@abs(sx) > 1e-3 or @abs(sy) > 1e-3) {
        for (layout.nodes.values()) |*n| {
            n.x += sx;
            n.y += sy;
        }
        for (layout.edges.items) |*e| {
            for (e.points.items) |*p| p.* = .{ p[0] + sx, p[1] + sy };
            inline for (.{ "label_anchor", "start_label_anchor", "end_label_anchor" }) |f| {
                if (@field(e, f)) |*p| p.* = .{ p[0] + sx, p[1] + sy };
            }
        }
        for (seq.lifelines.items) |*l| {
            l.x += sx;
            l.y1 += sy;
            l.y2 += sy;
        }
        for (seq.footboxes.items) |*n| {
            n.x += sx;
            n.y += sy;
        }
        for (seq.boxes.items) |*n| {
            n.x += sx;
            n.y += sy;
        }
        for (seq.frames.items) |*f| {
            f.x += sx;
            f.y += sy;
            f.label_box[0] += sx;
            f.label_box[1] += sy;
            f.label.x += sx;
            f.label.y += sy;
            for (f.section_labels) |*l| {
                l.x += sx;
                l.y += sy;
            }
            for (f.dividers) |*d| d.* += sy;
        }
        for (seq.notes.items) |*n| {
            n.x += sx;
            n.y += sy;
        }
        for (seq.activations.items) |*n| {
            n.x += sx;
            n.y += sy;
        }
        for (seq.numbers.items) |*n| {
            n.x += sx;
            n.y += sy;
        }
        b[0] += sx;
        b[1] += sy;
        b[2] += sx;
        b[3] += sy;
    }
    layout.width = @max(b[2] - b[0], 1.0);
    layout.height = @max(b[3] - b[1], 1.0);
}
