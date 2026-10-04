//! Label measurement (mermaid-rs-renderer `layout/text.rs`, `unicode_width.rs`,
//! `text_metrics.rs`).
//!
//! The crate measures with the system font matching the theme's family
//! (fontdb + ttf-parser) and falls back to calibrated per-character widths
//! when no such font is installed. zeron's family is "Geist", which the app
//! embeds rather than installs, so the Rust renderer takes the fallback path;
//! this port implements exactly that path (system fonts are never consulted).

const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util.zig");
const config_mod = @import("config.zig");
const Theme = @import("theme.zig").Theme;
const LayoutConfig = config_mod.LayoutConfig;

pub const TextBlock = struct {
    lines: []const []const u8,
    width: f32,
    height: f32,

    pub fn isEmptyLabel(self: TextBlock) bool {
        return self.lines.len == 1 and util.trim(self.lines[0]).len == 0;
    }
};

// ---------------------------------------------------------------------------------------
// unicode_width.rs
// ---------------------------------------------------------------------------------------

pub fn isCjkWideChar(ch: u21) bool {
    return switch (ch) {
        0x1100...0x11ff, 0x2e80...0xa4cf, 0xa960...0xa97f, 0xac00...0xd7ff, 0xf900...0xfaff, 0xfe10...0xfe1f, 0xfe30...0xfe4f, 0xff01...0xff60, 0xffe0...0xffe6, 0x20000...0x2fa1f, 0x30000...0x323af => true,
        else => false,
    };
}

fn isEmojiWideChar(ch: u21) bool {
    return switch (ch) {
        0x2600...0x27bf, 0x1f000...0x1faff => true,
        else => false,
    };
}

fn isEmojiModifierChar(ch: u21) bool {
    return switch (ch) {
        0x200d, 0x20e3, 0xfe00...0xfe0f, 0x1f3fb...0x1f3ff => true,
        else => false,
    };
}

fn isRegionalIndicator(ch: u21) bool {
    return ch >= 0x1f1e6 and ch <= 0x1f1ff;
}

fn isKeycapStarter(ch: u21) bool {
    return (ch >= '0' and ch <= '9') or ch == '#' or ch == '*';
}

pub const Cluster = enum { wide, zero_width };

pub fn consumeCluster(cps: []const u21, idx: usize) ?struct { kind: Cluster, next: usize } {
    if (idx >= cps.len) return null;
    const ch = cps[idx];
    if (isKeycapStarter(ch)) {
        const next = idx + 1;
        const keycap = if (next < cps.len and cps[next] == 0xfe0f) next + 1 else next;
        if (keycap < cps.len and cps[keycap] == 0x20e3) return .{ .kind = .wide, .next = keycap + 1 };
    }
    if (isRegionalIndicator(ch) and idx + 1 < cps.len and isRegionalIndicator(cps[idx + 1])) {
        return .{ .kind = .wide, .next = idx + 2 };
    }
    if (isEmojiWideChar(ch)) {
        var end = idx + 1;
        while (end < cps.len) {
            if (cps[end] == 0x200d and end + 1 < cps.len and isEmojiWideChar(cps[end + 1])) {
                end += 2;
            } else if (isEmojiModifierChar(cps[end])) {
                end += 1;
            } else break;
        }
        return .{ .kind = .wide, .next = end };
    }
    if (isEmojiModifierChar(ch)) return .{ .kind = .zero_width, .next = idx + 1 };
    return null;
}

// ---------------------------------------------------------------------------------------
// layout/text.rs
// ---------------------------------------------------------------------------------------

/// Calibrated per-character widths (16px measurement baseline).
pub fn charWidthFactor(ch: u21) f32 {
    return switch (ch) {
        ' ' => 0.306,
        '\\', '.', ',', ':', ';', '|', '!', '(', ')', '[', ']', '{', '}' => 0.321,
        'A' => 0.652,
        'B' => 0.648,
        'C' => 0.734,
        'D' => 0.723,
        'E' => 0.594,
        'F' => 0.575,
        'G', 'H' => 0.742,
        'I' => 0.272,
        'J' => 0.557,
        'K' => 0.648,
        'L' => 0.559,
        'M' => 0.903,
        'N' => 0.763,
        'O' => 0.754,
        'P' => 0.623,
        'Q' => 0.755,
        'R' => 0.637,
        'S' => 0.633,
        'T' => 0.599,
        'U' => 0.746,
        'V' => 0.661,
        'W' => 0.958,
        'X' => 0.655,
        'Y' => 0.646,
        'Z' => 0.621,
        'a' => 0.550,
        'b' => 0.603,
        'c' => 0.547,
        'd' => 0.609,
        'e' => 0.570,
        'f' => 0.340,
        'g', 'h' => 0.600,
        'i' => 0.235,
        'j' => 0.227,
        'k' => 0.522,
        'l' => 0.239,
        'm' => 0.867,
        'n' => 0.585,
        'o' => 0.574,
        'p' => 0.595,
        'q' => 0.585,
        'r' => 0.364,
        's' => 0.523,
        't' => 0.305,
        'u' => 0.585,
        'v' => 0.545,
        'w' => 0.811,
        'x' => 0.538,
        'y' => 0.556,
        'z' => 0.550,
        '0' => 0.613,
        '1' => 0.396,
        '2' => 0.609,
        '3' => 0.597,
        '4' => 0.614,
        '5' => 0.586,
        '6' => 0.608,
        '7' => 0.559,
        '8' => 0.611,
        '9' => 0.595,
        '@', '#', '%', '&' => 0.946,
        else => if (isCjkWideChar(ch)) 1.0 else 0.568,
    };
}

pub fn fallbackTextWidth(text: []const u8, font_size: f32) f32 {
    var buf: [512]u21 = undefined;
    var list: std.ArrayList(u21) = .initBuffer(&buf);
    var heap: ?[]u21 = null;
    defer if (heap) |h| std.heap.page_allocator.free(h);
    var i: usize = 0;
    var cps: []const u21 = undefined;
    // Decode (most labels fit the stack buffer).
    var n: usize = 0;
    var j: usize = 0;
    while (j < text.len) : (n += 1) j += util.decodeAt(text, j).len;
    if (n <= buf.len) {
        while (i < text.len) {
            const d = util.decodeAt(text, i);
            list.appendAssumeCapacity(d.cp);
            i += d.len;
        }
        cps = list.items;
    } else {
        heap = std.heap.page_allocator.alloc(u21, n) catch return 0;
        var k: usize = 0;
        while (i < text.len) {
            const d = util.decodeAt(text, i);
            heap.?[k] = d.cp;
            k += 1;
            i += d.len;
        }
        cps = heap.?;
    }
    var width: f32 = 0.0;
    var idx: usize = 0;
    while (idx < cps.len) {
        if (consumeCluster(cps, idx)) |c| {
            width += switch (c.kind) {
                .wide => 1.0,
                .zero_width => 0.0,
            };
            idx = c.next;
            continue;
        }
        width += charWidthFactor(cps[idx]);
        idx += 1;
    }
    return width * font_size;
}

/// `text_width`: system-font measurement is unavailable (see module docs).
pub fn textWidth(text: []const u8, font_size: f32, font_family: []const u8, fast_metrics: bool) f32 {
    _ = font_family;
    _ = fast_metrics;
    return fallbackTextWidth(text, font_size);
}

pub fn averageCharWidth(font_family: []const u8, font_size: f32, fast_metrics: bool) f32 {
    _ = font_family;
    _ = fast_metrics;
    return font_size * 0.56;
}

pub fn maxLabelWidthPx(max_chars: usize, font_size: f32, font_family: []const u8, fast_metrics: bool) f32 {
    const avg_char = averageCharWidth(font_family, font_size, fast_metrics);
    return @as(f32, @floatFromInt(@max(max_chars, 1))) * avg_char;
}

pub fn measureLabel(a: Allocator, text: []const u8, theme: *const Theme, config: *const LayoutConfig) Allocator.Error!TextBlock {
    const measure_font_size = @max(theme.font_size, 16.0);
    return measureLabelWithFontSize(a, text, measure_font_size, config, true, theme.font_family);
}

pub fn measureLabelWithFontSize(a: Allocator, text: []const u8, font_size: f32, config: *const LayoutConfig, wrap: bool, font_family: []const u8) Allocator.Error!TextBlock {
    const max_width_px = maxLabelWidthPx(config.max_label_width_chars, font_size, font_family, config.fast_text_metrics);
    return measureLabelWithMaxWidth(a, text, font_size, max_width_px, config, wrap, font_family);
}

pub fn measureLabelWithMaxWidth(a: Allocator, text: []const u8, font_size: f32, max_width_in: f32, config: *const LayoutConfig, wrap: bool, font_family: []const u8) Allocator.Error!TextBlock {
    const raw_lines = try splitLines(a, text);
    var lines_list: std.ArrayList([]const u8) = .empty;
    const fast = config.fast_text_metrics;
    const max_width = @max(max_width_in, 1.0);
    for (raw_lines) |line| {
        if (wrap) {
            const wrapped = try wrapLine(a, line, max_width, font_size, font_family, fast);
            try lines_list.appendSlice(a, wrapped);
        } else try lines_list.append(a, line);
    }
    if (lines_list.items.len == 0) try lines_list.append(a, "");
    var max_len: usize = 0;
    for (lines_list.items) |l| max_len = @max(max_len, util.charCount(l));
    if (lines_list.items.len == 0) max_len = 1;
    var widest: f32 = 0.0;
    for (lines_list.items) |l| widest = @max(widest, textWidth(l, font_size, font_family, fast));
    const avg_char = averageCharWidth(font_family, font_size, fast);
    const guard_width = @as(f32, @floatFromInt(max_len)) * avg_char;
    const width = @max(widest, guard_width);
    const height = @as(f32, @floatFromInt(lines_list.items.len)) * font_size * config.label_line_height;
    return .{ .lines = lines_list.items, .width = width, .height = height };
}

pub fn splitLines(a: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var current = try normalizeDisplayMath(a, text);
    current = try util.replace(a, current, "<br/>", "\n");
    current = try util.replace(a, current, "<br>", "\n");
    current = try util.replace(a, current, "\\n", "\n");
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, current, '\n');
    while (it.next()) |line| try out.append(a, util.trim(line));
    return out.items;
}

fn normalizeDisplayMath(a: Allocator, text: []const u8) Allocator.Error![]u8 {
    if (std.mem.indexOf(u8, text, "$$") == null) return a.dupe(u8, text);
    var out: std.ArrayList(u8) = .empty;
    var rest = text;
    while (std.mem.indexOf(u8, rest, "$$")) |start| {
        try out.appendSlice(a, rest[0..start]);
        const after = rest[start + 2 ..];
        if (std.mem.indexOf(u8, after, "$$")) |end| {
            try out.appendSlice(a, try renderPlainMath(a, after[0..end]));
            rest = after[end + 2 ..];
        } else {
            try out.appendSlice(a, "$$");
            try out.appendSlice(a, after);
            return out.items;
        }
    }
    try out.appendSlice(a, rest);
    return out.items;
}

fn matchingBrace(cps: []const u21, open: usize) ?usize {
    if (open >= cps.len or cps[open] != '{') return null;
    var depth: usize = 0;
    var idx = open;
    while (idx < cps.len) : (idx += 1) {
        switch (cps[idx]) {
            '{' => depth += 1,
            '}' => {
                depth -|= 1;
                if (depth == 0) return idx;
            },
            else => {},
        }
    }
    return null;
}

fn readGroup(a: Allocator, cps: []const u21, idx: *usize) Allocator.Error!?[]const u8 {
    while (idx.* < cps.len and util.isWhitespace(cps[idx.*])) idx.* += 1;
    const end = matchingBrace(cps, idx.*) orelse return null;
    const inner = try util.encode(a, cps[idx.* + 1 .. end]);
    idx.* = end + 1;
    return try renderPlainMath(a, inner);
}

fn scriptChar(ch: u21, superscript: bool) ?u21 {
    const from = "0123456789+-=()";
    const sup = [_]u21{ '⁰', '¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹', '⁺', '⁻', '⁼', '⁽', '⁾' };
    const sub = [_]u21{ '₀', '₁', '₂', '₃', '₄', '₅', '₆', '₇', '₈', '₉', '₊', '₋', '₌', '₍', '₎' };
    for (from, 0..) |f, i| if (f == ch) return if (superscript) sup[i] else sub[i];
    return null;
}

fn renderScript(a: Allocator, value: []const u8, superscript: bool) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var all_mapped = true;
    var i: usize = 0;
    while (i < value.len) {
        const d = util.decodeAt(value, i);
        if (scriptChar(d.cp, superscript)) |m| {
            try util.appendCp(a, &out, m);
        } else {
            all_mapped = false;
            break;
        }
        i += d.len;
    }
    if (all_mapped and out.items.len > 0) return out.items;
    const inner = try renderPlainMath(a, value);
    return if (superscript) std.fmt.allocPrint(a, "^({s})", .{inner}) else std.fmt.allocPrint(a, "_({s})", .{inner});
}

fn renderPlainMath(a: Allocator, input: []const u8) Allocator.Error![]const u8 {
    const cps = try util.chars(a, input);
    var out: std.ArrayList(u8) = .empty;
    var idx: usize = 0;
    while (idx < cps.len) {
        switch (cps[idx]) {
            '\\' => {
                if (idx + 1 < cps.len and cps[idx + 1] == '\\') {
                    try out.appendSlice(a, "; ");
                    idx += 2;
                    continue;
                }
                idx += 1;
                const start = idx;
                while (idx < cps.len and cps[idx] < 0x80 and std.ascii.isAlphabetic(@intCast(cps[idx]))) idx += 1;
                const command = try util.encode(a, cps[start..idx]);
                const eq = std.mem.eql;
                if (eq(u8, command, "sqrt")) {
                    if (try readGroup(a, cps, &idx)) |g| {
                        try out.appendSlice(a, "√(");
                        try out.appendSlice(a, g);
                        try out.append(a, ')');
                    }
                } else if (eq(u8, command, "frac")) {
                    const num = (try readGroup(a, cps, &idx)) orelse "";
                    const den = (try readGroup(a, cps, &idx)) orelse "";
                    try out.append(a, '(');
                    try out.appendSlice(a, num);
                    try out.appendSlice(a, ")/(");
                    try out.appendSlice(a, den);
                    try out.append(a, ')');
                } else if (eq(u8, command, "text") or eq(u8, command, "overbrace")) {
                    if (try readGroup(a, cps, &idx)) |g| try out.appendSlice(a, g);
                } else if (eq(u8, command, "begin")) {
                    const env = (try readGroup(a, cps, &idx)) orelse "";
                    if (std.mem.indexOf(u8, env, "matrix") != null) try out.append(a, '[');
                } else if (eq(u8, command, "end")) {
                    const env = (try readGroup(a, cps, &idx)) orelse "";
                    if (std.mem.indexOf(u8, env, "matrix") != null) try out.append(a, ']');
                } else if (eq(u8, command, "pi")) {
                    try out.appendSlice(a, "π");
                } else if (eq(u8, command, "alpha")) {
                    try out.appendSlice(a, "α");
                } else if (eq(u8, command, "beta")) {
                    try out.appendSlice(a, "β");
                } else if (eq(u8, command, "gamma")) {
                    try out.appendSlice(a, "γ");
                } else if (eq(u8, command, "delta")) {
                    try out.appendSlice(a, "δ");
                } else if (eq(u8, command, "lambda")) {
                    try out.appendSlice(a, "λ");
                } else if (eq(u8, command, "mu")) {
                    try out.appendSlice(a, "μ");
                } else if (eq(u8, command, "sigma")) {
                    try out.appendSlice(a, "σ");
                } else if (eq(u8, command, "theta")) {
                    try out.appendSlice(a, "θ");
                } else if (eq(u8, command, "cos") or eq(u8, command, "sin") or eq(u8, command, "tan") or eq(u8, command, "log") or eq(u8, command, "ln") or eq(u8, command, "exp")) {
                    try out.appendSlice(a, command);
                } else if (eq(u8, command, "left") or eq(u8, command, "right") or eq(u8, command, "cdot")) {
                    // dropped
                } else if (command.len > 0) {
                    try out.appendSlice(a, command);
                } else try out.append(a, '\\');
            },
            '^', '_' => {
                const sup = cps[idx] == '^';
                idx += 1;
                var script: []const u8 = "";
                if (idx < cps.len and cps[idx] == '{') {
                    script = (try readGroup(a, cps, &idx)) orelse "";
                } else if (idx < cps.len) {
                    script = try util.encode(a, cps[idx .. idx + 1]);
                    idx += 1;
                }
                try out.appendSlice(a, try renderScript(a, script, sup));
            },
            '{', '}' => idx += 1,
            '&' => {
                try out.append(a, ' ');
                idx += 1;
            },
            else => |ch| {
                try util.appendCp(a, &out, ch);
                idx += 1;
            },
        }
    }
    const words = try util.collectWhitespace(a, out.items);
    return util.join(a, words, " ");
}

pub fn wrapLine(a: Allocator, line: []const u8, max_width: f32, font_size: f32, font_family: []const u8, fast: bool) Allocator.Error![]const []const u8 {
    if (textWidth(line, font_size, font_family, fast) <= max_width) {
        const one = try a.alloc([]const u8, 1);
        one[0] = line;
        return one;
    }
    var out: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var it = util.splitWhitespace(line);
    while (it.next()) |word| {
        const candidate = if (current.items.len == 0) try a.dupe(u8, word) else try std.fmt.allocPrint(a, "{s} {s}", .{ current.items, word });
        if (textWidth(candidate, font_size, font_family, fast) > max_width) {
            if (current.items.len > 0) {
                try out.append(a, try a.dupe(u8, current.items));
                current = .empty;
            }
            try current.appendSlice(a, word);
        } else {
            current = .empty;
            try current.appendSlice(a, candidate);
        }
    }
    if (current.items.len > 0) try out.append(a, current.items);
    return out.items;
}

test "fallback widths" {
    try std.testing.expectEqual(@as(f32, 16.0), fallbackTextWidth("🙂", 16.0));
    try std.testing.expectEqual(@as(f32, 16.0), fallbackTextWidth("👨‍👩‍👧‍👦", 16.0));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try splitLines(a, "a<br/>b");
    try std.testing.expectEqual(@as(usize, 2), l.len);
    // Rust: "Request" at 16px = 54.88 label width with guard (7 chars * 8.96 = 62.72)? the
    // reference layout dump says 54.88 for "Request" at font 14 -> measured at 16.
    const theme = try Theme.modern(a);
    var cfg: LayoutConfig = .{};
    cfg.node_padding_x = 18;
    var t = theme;
    t.font_size = 14;
    t.font_family = "Geist";
    const b = try measureLabelWithFontSize(a, "Request", 14, &cfg, true, "Geist");
    try std.testing.expectApproxEqAbs(@as(f32, 54.88), b.width, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 21.0), b.height, 0.001);
}
