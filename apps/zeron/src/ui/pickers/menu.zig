//! Pure picker reducers (zeron `popover.rs`): row stepping, ranked search
//! filtering, key classification and the adaptive menu geometry.

const std = @import("std");

/// Step the active row: wraps at both ends; `null` enters at the edge
/// matching the direction. Empty menus stay `null`.
pub fn menuStep(active: ?usize, count: usize, delta: isize) ?usize {
    if (count == 0) return null;
    const n: isize = @intCast(count);
    const next: isize = if (active) |at| @mod(@as(isize, @intCast(at)) + delta, n) else if (delta >= 0) 0 else n - 1;
    return @intCast(next);
}

fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// `0` prefix match, `1` substring, `null` no match. Case-insensitive; an
/// empty query matches everything at rank 1 (input order preserved).
pub fn matchRank(query: []const u8, label: []const u8) ?u1 {
    const q = trimAscii(query);
    if (q.len == 0) return 1;
    if (q.len <= label.len and std.ascii.eqlIgnoreCase(label[0..q.len], q)) return 0;
    if (std.ascii.findIgnoreCase(label, q) != null) return 1;
    return null;
}

/// Filter + rank: prefix matches first, then substring, stable within each
/// rank. Writes indices into `out` (len ≥ labels.len) and returns the slice.
pub fn filterIndices(query: []const u8, labels: []const []const u8, out: []usize) []usize {
    var n: usize = 0;
    for (0..2) |pass| {
        for (labels, 0..) |label, ix| {
            const r = matchRank(query, label) orelse continue;
            if (r == pass) {
                out[n] = ix;
                n += 1;
            }
        }
    }
    return out[0..n];
}

pub const MenuKey = enum { up, down, enter, mod_enter, escape, backspace, other };

/// Keys the pickers care about; ctrl-n / ctrl-p mirror ↓ / ↑ (readline).
pub fn classifyKey(key: []const u8, cmd: bool, ctrl: bool) MenuKey {
    const eql = std.mem.eql;
    if (eql(u8, key, "up")) return .up;
    if (eql(u8, key, "down")) return .down;
    if (ctrl and eql(u8, key, "n")) return .down;
    if (ctrl and eql(u8, key, "p")) return .up;
    if (eql(u8, key, "enter")) return if (cmd or ctrl) .mod_enter else .enter;
    if (eql(u8, key, "escape")) return .escape;
    if (eql(u8, key, "backspace")) return .backspace;
    return .other;
}

/// Space available at a measured trigger (menu gap + window margin included).
pub const MenuGeometry = struct {
    height: f32,
    below: bool,
};

/// Prefer above; flip only when above cannot fit useful chrome.
pub fn menuGeometry(top: f32, bottom: f32, viewport_height: f32) MenuGeometry {
    const above = @max(top - 14, 0);
    const below = @max(viewport_height - bottom - 14, 0);
    const flip = above < 180 and below > above;
    return .{ .height = @min(if (flip) below else above, 640), .below = flip };
}

/// `Pickers::measure_trigger`: new-thread branch / checkout menus open down
/// when at least 180px fit below.
pub fn triggerGeometry(top: f32, bottom: f32, viewport_height: f32, prefer_below: bool) MenuGeometry {
    var g = menuGeometry(top, bottom, viewport_height);
    const space_below = std.math.clamp(viewport_height - bottom - 14, 0, 640);
    if (prefer_below and space_below >= 180) g = .{ .height = space_below, .below = true };
    return g;
}

/// `list_budget`: list height left after `chrome` px of card furniture.
pub fn listBudget(height: f32, chrome: f32) f32 {
    return std.math.clamp(height - chrome, 0, 224);
}

const testing = std.testing;

test "menu_step wraps and enters from the edge" {
    try testing.expectEqual(@as(?usize, null), menuStep(null, 0, 1));
    try testing.expectEqual(@as(?usize, 0), menuStep(null, 3, 1));
    try testing.expectEqual(@as(?usize, 2), menuStep(null, 3, -1));
    try testing.expectEqual(@as(?usize, 0), menuStep(2, 3, 1));
    try testing.expectEqual(@as(?usize, 2), menuStep(0, 3, -1));
    try testing.expectEqual(@as(?usize, 1), menuStep(0, 3, 1));
}

test "filter ranks prefix before substring, stable" {
    const labels = [_][]const u8{ "lumen-web", "aurora", "notes-cli", "Auth" };
    var buf: [4]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 0, 1, 2, 3 }, filterIndices("", &labels, &buf));
    try testing.expectEqualSlices(usize, &.{ 1, 3 }, filterIndices("au", &labels, &buf));
    try testing.expectEqualSlices(usize, &.{ 2, 0 }, filterIndices("  n ", &labels, &buf));
    try testing.expectEqualSlices(usize, &.{}, filterIndices("zzz", &labels, &buf));
    try testing.expectEqual(@as(?u1, 1), matchRank("WEB", "lumen-web"));
}

test "classify keys" {
    try testing.expectEqual(MenuKey.down, classifyKey("n", false, true));
    try testing.expectEqual(MenuKey.other, classifyKey("n", false, false));
    try testing.expectEqual(MenuKey.mod_enter, classifyKey("enter", true, false));
    try testing.expectEqual(MenuKey.enter, classifyKey("enter", false, false));
    try testing.expectEqual(MenuKey.escape, classifyKey("escape", false, false));
}

test "adaptive geometry (popover.rs tests)" {
    try testing.expectEqual(MenuGeometry{ .height = 286, .below = false }, menuGeometry(300, 320, 500));
    try testing.expectEqual(MenuGeometry{ .height = 386, .below = true }, menuGeometry(80, 100, 500));
    try testing.expectEqual(@as(f32, 640), menuGeometry(900, 920, 1000).height);
    try testing.expectEqual(MenuGeometry{ .height = 419, .below = true }, triggerGeometry(557, 577, 1010, true));
    try testing.expectEqual(MenuGeometry{ .height = 543, .below = false }, triggerGeometry(557, 577, 1010, false));
    try testing.expectEqual(@as(f32, 224), listBudget(600, 144));
    try testing.expectEqual(@as(f32, 0), listBudget(100, 144));
}
