//! Shared pieces of the frontmost-window capture backends (`linux/window_capture.zig`,
//! `mac/window_capture.zig`): zeron's capture budget (`appshots.rs`
//! `validate_capture_dimensions`), owned-error helpers and the hotkey key tables.

const std = @import("std");
const platform = @import("platform.zig");
const Allocator = std.mem.Allocator;

/// Bounds native capture buffers before platform APIs allocate or stage them.
pub const max_capture_dimension: u32 = 8_192;
pub const max_capture_pixels: u64 = 32 * 1024 * 1024;
pub const max_capture_rgba_bytes: u64 = 128 * 1024 * 1024;
/// zeron's attachment limit (24 MB).
pub const max_attachment_bytes: u64 = 24 * 1024 * 1024;

pub const DimensionError = union(enum) {
    unsupported: struct { w: u32, h: u32 },
    over_budget: struct { w: u32, h: u32 },
};

/// `validate_capture_dimensions`: the RGBA byte count, or why the size is refused.
pub fn validateDimensions(width: u32, height: u32) union(enum) { ok: usize, err: DimensionError } {
    if (width == 0 or height == 0 or width > max_capture_dimension or height > max_capture_dimension)
        return .{ .err = .{ .unsupported = .{ .w = width, .h = height } } };
    const pixels = @as(u64, width) * height;
    const rgba = pixels * 4;
    if (pixels > max_capture_pixels or rgba > max_capture_rgba_bytes)
        return .{ .err = .{ .over_budget = .{ .w = width, .h = height } } };
    return .{ .ok = @intCast(rgba) };
}

/// The user-facing message for a refused size (owned).
pub fn dimensionMessage(gpa: Allocator, e: DimensionError) []u8 {
    return switch (e) {
        .unsupported => |d| std.fmt.allocPrint(gpa, "The captured window dimensions ({d}×{d}) are not supported.", .{ d.w, d.h }),
        .over_budget => |d| std.fmt.allocPrint(gpa, "The captured window ({d}×{d}) exceeds Zeron's capture budget.", .{ d.w, d.h }),
    } catch &.{};
}

/// A `.failed` capture error with an owned, formatted message.
pub fn failed(gpa: Allocator, comptime fmt: []const u8, args: anytype) platform.WindowCaptureResult {
    return .{ .err = .{ .failed = std.fmt.allocPrint(gpa, fmt, args) catch &.{} } };
}

pub fn failedDims(gpa: Allocator, e: DimensionError) platform.WindowCaptureResult {
    return .{ .err = .{ .failed = dimensionMessage(gpa, e) } };
}

/// The XDG "shortcuts" trigger string for a hotkey (`Shortcut::portal_trigger`):
/// `CTRL+ALT+SHIFT+LOGO+<xkb key name>`.
pub fn portalTrigger(buf: []u8, h: platform.GlobalHotkey) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var first = true;
    const parts = [_]struct { bool, []const u8 }{ .{ h.control, "CTRL" }, .{ h.alt, "ALT" }, .{ h.shift, "SHIFT" }, .{ h.platform, "LOGO" } };
    for (parts) |p| if (p[0]) {
        if (!first) w.writeByte('+') catch {};
        w.writeAll(p[1]) catch {};
        first = false;
    };
    if (!first) w.writeByte('+') catch {};
    const k = h.key;
    if (std.mem.eql(u8, k, "enter")) {
        w.writeAll("Return") catch {};
    } else if (std.mem.eql(u8, k, "backspace")) {
        w.writeAll("BackSpace") catch {};
    } else if (std.mem.eql(u8, k, "pageup")) {
        w.writeAll("Page_Up") catch {};
    } else if (std.mem.eql(u8, k, "pagedown")) {
        w.writeAll("Page_Down") catch {};
    } else if (std.mem.eql(u8, k, "space") or k.len <= 1) {
        w.writeAll(k) catch {};
    } else {
        w.writeByte(std.ascii.toUpper(k[0])) catch {};
        w.writeAll(k[1..]) catch {};
    }
    return w.buffered();
}

/// X11 keysym of a hotkey key (`shortcut_keysym`).
pub fn x11Keysym(key: []const u8) ?u32 {
    const named = [_]struct { []const u8, u32 }{
        .{ "space", 0x20 },  .{ "tab", 0xff09 },    .{ "enter", 0xff0d },  .{ "backspace", 0xff08 },
        .{ "delete", 0xffff }, .{ "insert", 0xff63 }, .{ "up", 0xff52 },     .{ "down", 0xff54 },
        .{ "left", 0xff51 }, .{ "right", 0xff53 },  .{ "home", 0xff50 },   .{ "end", 0xff57 },
        .{ "pageup", 0xff55 }, .{ "pagedown", 0xff56 },
    };
    for (named) |n| if (std.mem.eql(u8, key, n[0])) return n[1];
    if (key.len == 1) return key[0];
    if (key.len >= 2 and key[0] == 'f') {
        const n = std.fmt.parseInt(u8, key[1..], 10) catch return null;
        if (n == 0) return null;
        return 0xffbe + @as(u32, n - 1);
    }
    return null;
}

/// macOS virtual key code of a named hotkey key (`shortcut_keycode`); letters and
/// digits are resolved against the active keyboard layout by the mac backend.
pub fn macNamedKeycode(key: []const u8) ?u32 {
    const named = [_]struct { []const u8, u32 }{
        .{ "space", 49 },  .{ "tab", 48 },     .{ "enter", 36 }, .{ "backspace", 51 }, .{ "delete", 117 },
        .{ "insert", 114 }, .{ "up", 126 },     .{ "down", 125 }, .{ "left", 123 },     .{ "right", 124 },
        .{ "home", 115 },  .{ "end", 119 },    .{ "pageup", 116 }, .{ "pagedown", 121 },
    };
    for (named) |n| if (std.mem.eql(u8, key, n[0])) return n[1];
    if (key.len >= 2 and key[0] == 'f') {
        const n = std.fmt.parseInt(usize, key[1..], 10) catch return null;
        const table = [_]u32{ 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90 };
        if (n == 0 or n > table.len) return null;
        return table[n - 1];
    }
    return null;
}

/// Rust `char::is_whitespace`.
pub fn isUnicodeWhitespace(cp: u21) bool {
    return switch (cp) {
        0x09...0x0d, 0x20, 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

/// `value.split_whitespace().join(" ")`, keeping at most `max_chars` characters;
/// `ellipsis` appends "…" when characters were dropped (macOS `compact`). Owned.
pub fn compactWhitespace(gpa: Allocator, value: []const u8, max_chars: usize, ellipsis: bool) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chars: usize = 0;
    var pending_space = false;
    var dropped = false;
    var i: usize = 0;
    while (i < value.len) {
        const n = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
        const end = @min(value.len, i + n);
        const cp: u21 = std.unicode.utf8Decode(value[i..end]) catch 0xfffd;
        const bytes: []const u8 = if (end - i == n and cp != 0xfffd) value[i..end] else "\u{fffd}";
        i = end;
        if (isUnicodeWhitespace(cp)) {
            pending_space = out.items.len > 0;
            continue;
        }
        const need: usize = if (pending_space) 2 else 1;
        if (chars + need > max_chars) {
            dropped = true;
            // A trailing separator still counts toward the limit (Rust truncates the
            // joined string by characters).
            if (pending_space and chars < max_chars) {
                try out.append(gpa, ' ');
                chars += 1;
            }
            break;
        }
        if (pending_space) {
            try out.append(gpa, ' ');
            chars += 1;
            pending_space = false;
        }
        try out.appendSlice(gpa, bytes);
        chars += 1;
    }
    if (dropped and ellipsis) try out.appendSlice(gpa, "…");
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "whitespace compaction matches split_whitespace + join" {
    const gpa = testing.allocator;
    const a = try compactWhitespace(gpa, "  a\t b\u{a0}\u{3000}c \n", 100, false);
    defer gpa.free(a);
    try testing.expectEqualStrings("a b c", a);
    const b = try compactWhitespace(gpa, "abc def", 5, true);
    defer gpa.free(b);
    try testing.expectEqualStrings("abc d…", b);
    const c = try compactWhitespace(gpa, "abc def", 4, false);
    defer gpa.free(c);
    try testing.expectEqualStrings("abc ", c);
    const d = try compactWhitespace(gpa, "abc", 3, true);
    defer gpa.free(d);
    try testing.expectEqualStrings("abc", d);
}

test "portal triggers use xkb key names and the selected modifiers" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("CTRL+ALT+space", portalTrigger(&buf, .{ .key = "space", .control = true, .alt = true }));
    try testing.expectEqualStrings("CTRL+SHIFT+Page_Up", portalTrigger(&buf, .{ .key = "pageup", .control = true, .shift = true }));
    try testing.expectEqualStrings("ALT+LOGO+F12", portalTrigger(&buf, .{ .key = "f12", .alt = true, .platform = true }));
    try testing.expectEqualStrings("CTRL+k", portalTrigger(&buf, .{ .key = "k", .control = true }));
}

test "capture dimensions are bounded before allocation" {
    try testing.expectEqual(@as(usize, 4096 * 4096 * 4), validateDimensions(4096, 4096).ok);
    try testing.expect(validateDimensions(8193, 1) == .err);
    try testing.expect(validateDimensions(8192, 8192) == .err);
    try testing.expect(validateDimensions(0, 10) == .err);
    const msg = dimensionMessage(testing.allocator, validateDimensions(9000, 10).err);
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("The captured window dimensions (9000×10) are not supported.", msg);
}

test "hotkey key tables" {
    try testing.expectEqual(@as(?u32, 0x20), x11Keysym("space"));
    try testing.expectEqual(@as(?u32, 0xffc9), x11Keysym("f12"));
    try testing.expectEqual(@as(?u32, 'k'), x11Keysym("k"));
    try testing.expectEqual(@as(?u32, null), x11Keysym("f0"));
    try testing.expectEqual(@as(?u32, 49), macNamedKeycode("space"));
    try testing.expectEqual(@as(?u32, 90), macNamedKeycode("f20"));
    try testing.expectEqual(@as(?u32, null), macNamedKeycode("f21"));
}
