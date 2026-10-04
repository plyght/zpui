//! `layout/gantt.rs`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("../ir.zig");
const util = @import("../util.zig");
const theme_mod = @import("../theme.zig");
const Theme = theme_mod.Theme;
const LayoutConfig = @import("../config.zig").LayoutConfig;
const text = @import("../text.zig");
const t = @import("types.zig");
const routing = @import("routing.zig");

fn hslColor(a: Allocator, h: f32, s: f32, l: f32) Allocator.Error![]const u8 {
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    return std.fmt.allocPrint(a, "hsl({s}, {s}%, {s}%)", .{ util.writeFixed(&b1, h, 10), util.writeFixed(&b2, s, 10), util.writeFixed(&b3, l, 10) });
}

fn shiftColor(a: Allocator, color: []const u8, ts: f32, tl: f32, strength: f32) Allocator.Error![]const u8 {
    const hsl = theme_mod.parseColorToHsl(color) orelse return color;
    return theme_mod.adjustColor(a, color, 0.0, (ts - hsl[1]) * strength, (tl - hsl[2]) * strength);
}

fn taskColor(a: Allocator, status: ?ir.GanttStatus, base_in: []const u8, fallback: []const u8) Allocator.Error![]const u8 {
    const base = if (theme_mod.parseColorToHsl(base_in) != null) base_in else fallback;
    const st = status orelse return base;
    return switch (st) {
        .done => shiftColor(a, base, 30.0, 80.0, 0.7),
        .active => shiftColor(a, base, 70.0, 52.0, 0.6),
        .crit => if (theme_mod.parseColorToHsl(base)) |h| hslColor(a, 0.0, @max(h[1], 65.0), std.math.clamp(h[2], 45.0, 60.0)) else "#ef4444",
        .milestone => if (theme_mod.parseColorToHsl(base)) |h| hslColor(a, 45.0, @max(h[1], 65.0), std.math.clamp(h[2], 50.0, 65.0)) else "#f59e0b",
    };
}

pub fn parseDuration(a: Allocator, value_in: []const u8) Allocator.Error!?f32 {
    const value = util.trim(value_in);
    if (value.len == 0) return null;
    var digits: std.ArrayList(u8) = .empty;
    var unit: ?u21 = null;
    var i: usize = 0;
    while (i < value.len) {
        const d = util.decodeAt(value, i);
        i += d.len;
        const ch = d.cp;
        if ((ch >= '0' and ch <= '9') or ch == '.') {
            try digits.append(a, @intCast(ch));
        } else if (!util.isWhitespace(ch)) unit = if (ch < 128) std.ascii.toLower(@intCast(ch)) else ch;
    }
    const n = util.parseF32(digits.items) orelse return null;
    const mult: f32 = if (unit) |u| switch (u) {
        'd' => 1.0,
        'w' => 7.0,
        'h' => 1.0 / 24.0,
        'm' => 30.0,
        'y' => 365.0,
        else => 1.0,
    } else 1.0;
    return n * mult;
}

pub fn parseDate(value_in: []const u8) ?i32 {
    const value = util.trim(value_in);
    if (value.len == 0) return null;
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitAny(u8, value, "-/.");
    while (it.next()) |p| {
        if (n == 4) return null;
        parts[n] = p;
        n += 1;
    }
    if (n != 3) return null;
    const year = std.fmt.parseInt(i32, parts[0], 10) catch return null;
    const month = std.fmt.parseInt(u32, parts[1], 10) catch return null;
    const day = std.fmt.parseInt(u32, parts[2], 10) catch return null;
    if (month == 0 or month > 12 or day == 0 or day > 31) return null;
    return daysFromCivil(year, month, day);
}

fn daysFromCivil(year: i32, month: u32, day: u32) i32 {
    const y = year - @as(i32, @intFromBool(month <= 2));
    const era = @divTrunc(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const m: i32 = @intCast(month);
    const d: i32 = @intCast(day);
    const doy = @divTrunc(153 * (m + @as(i32, if (m > 2) -3 else 9)) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn civilFromDays(days: i32) [3]i32 {
    const z = days + 719468;
    const era = @divTrunc(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = mp + @as(i32, if (mp < 10) 3 else -9);
    return .{ y + @as(i32, @intFromBool(m <= 2)), m, d };
}

fn formatDate(a: Allocator, days: i32) Allocator.Error![]const u8 {
    const c = civilFromDays(days);
    if (c[0] < 0) return std.fmt.allocPrint(a, "-{d:0>3}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(-c[0])), @as(u32, @intCast(c[1])), @as(u32, @intCast(c[2])) });
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u32, @intCast(c[0])), @as(u32, @intCast(c[1])), @as(u32, @intCast(c[2])) });
}

pub fn computeGanttLayout(a: Allocator, graph: *const ir.Graph, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!t.Layout {
    const fs = theme.font_size;
    const padding = fs * 1.25;
    const row_h = @max(fs * 1.5, fs + 8.0);
    const label_gap = fs * 1.05;
    const title: ?t.TextBlock = if (graph.gantt_title) |tt| try text.measureLabel(a, tt, theme, config) else null;
    const title_h = if (title) |tb| tb.height + padding else 0.0;
    var task_lw: f32 = 0;
    var sec_lw: f32 = 0;
    for (graph.gantt_tasks.items) |task| {
        task_lw = @max(task_lw, (try text.measureLabel(a, task.label, theme, config)).width);
        if (task.section) |s| sec_lw = @max(sec_lw, (try text.measureLabel(a, s, theme, config)).width);
    }
    task_lw = @max(task_lw, fs * 6.5);
    const label_x = padding;
    const stg: f32 = if (sec_lw > 0.0) fs * 0.8 else 0.0;
    const label_width = sec_lw + stg + task_lw;
    const chart_x = padding + label_width + label_gap;
    const chart_y = title_h + padding;
    const chart_w = fs * 26.0;
    var starts: std.StringHashMapUnmanaged(f32) = .empty;
    var origin: ?f32 = null;
    for (graph.gantt_tasks.items) |task| if (task.start) |s| if (parseDate(s)) |d| {
        const sf: f32 = @floatFromInt(d);
        try starts.put(a, task.id, sf);
        origin = if (origin) |o| @min(o, sf) else sf;
    };
    const has_dates = origin != null;
    var timing: std.StringHashMapUnmanaged([2]f32) = .empty;
    var cursor: f32 = 0;
    var ts: f32 = std.math.floatMax(f32);
    var te: f32 = -std.math.floatMax(f32);
    const Comp = struct { label: []const u8, start: f32, dur: f32, status: ?ir.GanttStatus, section: ?[]const u8 };
    var comp: std.ArrayList(Comp) = .empty;
    for (graph.gantt_tasks.items) |task| {
        const dur = @max((if (task.duration) |d| try parseDuration(a, d) else null) orelse 3.0, 0.1);
        var start = starts.get(task.id);
        if (start == null) if (task.after) |aid| if (timing.get(aid)) |tm| {
            start = tm[1];
        };
        const s = start orelse ((origin orelse 0.0) + cursor);
        const end = s + dur;
        try timing.put(a, task.id, .{ s, end });
        cursor = @max(cursor, end + 0.5);
        ts = @min(ts, s);
        te = @max(te, end);
        try comp.append(a, .{ .label = task.label, .start = s, .dur = dur, .status = task.status, .section = task.section });
    }
    if (ts == std.math.floatMax(f32) or te == -std.math.floatMax(f32)) {
        ts = 0;
        te = 1;
    }
    if (@abs(te - ts) < 0.01) te = ts + 1.0;
    const span = @max(te - ts, 1.0);
    const scale = chart_w / span;
    var layout: t.GanttLayout = .{ .title = title, .time_start = ts, .time_end = te, .chart_x = chart_x, .chart_y = chart_y, .chart_width = chart_w, .chart_height = 0, .row_height = row_h, .label_x = label_x, .label_width = label_width, .section_label_x = label_x, .section_label_width = sec_lw, .task_label_x = label_x + sec_lw + stg, .task_label_width = task_lw, .title_y = chart_y - row_h * 0.6, .compact = false };
    for (0..5) |i| {
        const tt = ts + span * @as(f32, @floatFromInt(i)) / 4.0;
        const lbl = if (has_dates) try formatDate(a, routing.toI32(@round(tt))) else try util.fmtFixed(a, tt - ts, 0);
        try layout.ticks.append(a, .{ .x = chart_x + (tt - ts) * scale, .label = lbl });
    }
    const compact = if (graph.gantt_display_mode) |m| std.ascii.eqlIgnoreCase(m, "compact") else false;
    layout.compact = compact;
    const palette = [_][]const u8{ theme.primary_border_color, "#0ea5e9", "#10b981", "#6366f1", "#f97316" };
    var sec_pal: std.StringHashMapUnmanaged([]const u8) = .empty;
    if (graph.gantt_sections.items.len > 0) {
        const step = 360.0 / @as(f32, @floatFromInt(graph.gantt_sections.items.len));
        for (graph.gantt_sections.items, 0..) |name, idx| {
            var c = try theme_mod.adjustColor(a, theme.primary_border_color, step * @as(f32, @floatFromInt(idx)), 0.0, 0.0);
            c = try shiftColor(a, c, 60.0, 55.0, 0.4);
            try sec_pal.put(a, name, c);
        }
    }
    var current: ?[]const u8 = null;
    var cur_idx: ?usize = null;
    var y = chart_y;
    var lanes: std.ArrayList([2]f32) = .empty;
    const eqlOpt = struct {
        fn f(x: ?[]const u8, z: ?[]const u8) bool {
            if (x == null and z == null) return true;
            if (x == null or z == null) return false;
            return util.eql(x.?, z.?);
        }
    }.f;
    for (comp.items, 0..) |c, idx| {
        if (!eqlOpt(c.section, current)) {
            if (c.section) |sec| {
                if (cur_idx) |pi| layout.sections.items[pi].height = @max(y - layout.sections.items[pi].y, row_h);
                lanes.clearRetainingCapacity();
                const base = sec_pal.get(sec) orelse palette[idx % palette.len];
                try layout.sections.append(a, .{ .label = try text.measureLabel(a, sec, theme, config), .y = y, .height = 0, .color = base, .band_color = try shiftColor(a, base, 20.0, 92.0, 0.7) });
                cur_idx = layout.sections.items.len - 1;
            } else if (cur_idx) |pi| {
                layout.sections.items[pi].height = @max(y - layout.sections.items[pi].y, row_h);
                cur_idx = null;
                lanes.clearRetainingCapacity();
            }
            current = c.section;
        }
        const bar_x = chart_x + (c.start - ts) * scale;
        const bar_w = @max(c.dur * scale, row_h * 0.5);
        const base = if (c.section) |sec| (sec_pal.get(sec) orelse palette[idx % palette.len]) else palette[idx % palette.len];
        const color = try taskColor(a, c.status, base, palette[0]);
        const task_end = c.start + c.dur;
        var task_y: f32 = undefined;
        if (compact) {
            var found = false;
            for (lanes.items) |*lane| if (c.start >= lane[1]) {
                task_y = lane[0];
                lane[1] = task_end;
                found = true;
                break;
            };
            if (!found) {
                task_y = y;
                try lanes.append(a, .{ y, task_end });
                y += row_h;
            }
        } else {
            task_y = y;
            y += row_h;
        }
        try layout.tasks.append(a, .{ .label = try text.measureLabel(a, c.label, theme, config), .x = bar_x, .y = task_y, .width = bar_w, .height = row_h, .color = color, .start = c.start, .duration = c.dur, .status = c.status });
    }
    if (cur_idx) |pi| layout.sections.items[pi].height = @max(y - layout.sections.items[pi].y, row_h);
    var max_half: f32 = 0;
    for (layout.ticks.items) |tk| max_half = @max(max_half, (try text.measureLabelWithFontSize(a, tk.label, fs * 0.8, config, false, theme.font_family)).width / 2.0);
    const axis_pad = row_h * 0.9 + fs;
    const height = y + padding + axis_pad;
    const overflow: f32 = if (compact) padding + task_lw else 0.0;
    const right = @max(@max(max_half + padding * 0.4, overflow), padding);
    layout.chart_height = y - chart_y;
    return .{ .kind = graph.kind, .width = chart_x + chart_w + right, .height = height, .diagram = .{ .gantt = layout } };
}
