//! Pure helpers behind the desktop-companion contract (docs/DESKTOP_OVERLAY.md), shared
//! by every backend and unit-tested without a display:
//!
//!   * `anchoredOrigin`: where an overlay pinned to a work-area corner goes;
//!   * `evdevKey` / `macKey`: hardware keycode → coarse `GlobalKeyClass` + a horizontal
//!     position on a US keyboard (characters are never derived, stored or exposed);
//!   * `InputQueue`: a fixed-size ring the input monitors fill from their (hot) event
//!     paths and drain once per wakeup, so bursts coalesce and nothing allocates;
//!   * Linux XDG autostart `.desktop` and macOS LaunchAgent plist contents + paths.

const std = @import("std");
const pf = @import("platform.zig");

const Point = pf.Point;
const Size = pf.Size;
const Bounds = pf.Bounds;

// ---------------------------------------------------------------------------------------
// Anchor geometry
// ---------------------------------------------------------------------------------------

/// Top-left origin (same space as `visible`, y down) of a `size` window pinned to
/// `anchor.corner` of `visible`, inset by `anchor.margin`.
pub fn anchoredOrigin(anchor: pf.OverlayAnchor, visible: Bounds, size: Size) Point {
    const left = visible.origin.x + anchor.margin.x;
    const right = visible.origin.x + visible.size.width - size.width - anchor.margin.x;
    const top = visible.origin.y + anchor.margin.y;
    const bottom = visible.origin.y + visible.size.height - size.height - anchor.margin.y;
    return switch (anchor.corner) {
        .top_left => .{ .x = left, .y = top },
        .top_right => .{ .x = right, .y = top },
        .bottom_left => .{ .x = left, .y = bottom },
        .bottom_right => .{ .x = right, .y = bottom },
    };
}

/// wlr-layer-shell anchor bits (top 1, bottom 2, left 4, right 8) and margins
/// (top, right, bottom, left) for an overlay anchor.
pub const LayerPlacement = struct { anchor: u32, margin: [4]i32 };

pub fn layerPlacement(anchor: pf.OverlayAnchor) LayerPlacement {
    const mx: i32 = @intFromFloat(@round(anchor.margin.x));
    const my: i32 = @intFromFloat(@round(anchor.margin.y));
    return switch (anchor.corner) {
        .top_left => .{ .anchor = 1 | 4, .margin = .{ my, 0, 0, mx } },
        .top_right => .{ .anchor = 1 | 8, .margin = .{ my, mx, 0, 0 } },
        .bottom_left => .{ .anchor = 2 | 4, .margin = .{ 0, 0, my, mx } },
        .bottom_right => .{ .anchor = 2 | 8, .margin = .{ 0, mx, my, 0 } },
    };
}

// ---------------------------------------------------------------------------------------
// Keycode tables
// ---------------------------------------------------------------------------------------

pub const KeyInfo = struct { class: pf.GlobalKeyClass, x: f32 };

/// Width of the US ANSI main block in key units; positions are key centres in it.
const board_width: f32 = 15;

fn at(class: pf.GlobalKeyClass, centre: f32) KeyInfo {
    return .{ .class = class, .x = std.math.clamp(centre / board_width, 0, 1) };
}

/// Linux input-event-codes (`KEY_*`, also X11 keycode − 8) → class + position.
/// Keys right of the main block (navigation, arrows, keypad) sit at the right edge.
pub fn evdevKey(code: u16) KeyInfo {
    return switch (code) {
        1 => at(.other, 0.5), // esc
        2...11 => at(.digit, 1.5 + @as(f32, @floatFromInt(code - 2))),
        12 => at(.other, 11.5), // minus
        13 => at(.other, 12.5), // equal
        14 => at(.backspace, 14),
        15 => at(.tab, 0.75),
        16...25 => at(.letter, 2.0 + @as(f32, @floatFromInt(code - 16))), // q .. p
        26 => at(.other, 12), // [
        27 => at(.other, 13), // ]
        28 => at(.enter, 14.125),
        29 => at(.modifier, 0.625), // left ctrl
        30...38 => at(.letter, 2.25 + @as(f32, @floatFromInt(code - 30))), // a .. l
        39 => at(.other, 11.25), // ;
        40 => at(.other, 12.25), // '
        41 => at(.other, 0.5), // `
        42 => at(.modifier, 1.125), // left shift
        43 => at(.other, 14.25), // backslash
        44...50 => at(.letter, 2.75 + @as(f32, @floatFromInt(code - 44))), // z .. m
        51 => at(.other, 9.75), // ,
        52 => at(.other, 10.75), // .
        53 => at(.other, 11.75), // /
        54 => at(.modifier, 13.625), // right shift
        55, 74, 78, 83, 98, 117 => at(.other, 15), // keypad operators / dot / equal
        56 => at(.modifier, 3.125), // left alt
        57 => at(.space, 7.5),
        58 => at(.modifier, 0.875), // caps lock
        59...68 => at(.other, 1.5 + @as(f32, @floatFromInt(code - 59)) * 1.1), // F1 .. F10
        87, 88 => at(.other, 12.5 + @as(f32, @floatFromInt(code - 87)) * 1.1), // F11, F12
        71...73, 75...77, 79...82 => at(.digit, 15), // keypad digits
        96 => at(.enter, 15), // keypad enter
        97 => at(.modifier, 14.375), // right ctrl
        100 => at(.modifier, 11.875), // right alt
        125 => at(.modifier, 1.875), // left meta
        126 => at(.modifier, 13.125), // right meta
        464 => at(.modifier, 0.5), // fn
        103, 105, 106, 108 => at(.arrow, 15),
        else => .{ .class = .other, .x = 0.5 },
    };
}

/// macOS virtual keycode (`kVK_*`) → evdev code (null = not mapped).
pub fn macToEvdev(vk: u16) ?u16 {
    const table = [_]struct { u16, u16 }{
        .{ 0, 30 },  .{ 1, 31 },  .{ 2, 32 },    .{ 3, 33 },    .{ 4, 35 },    .{ 5, 34 },    .{ 6, 44 },
        .{ 7, 45 },  .{ 8, 46 },  .{ 9, 47 },    .{ 11, 48 },   .{ 12, 16 },   .{ 13, 17 },   .{ 14, 18 },
        .{ 15, 19 }, .{ 16, 21 }, .{ 17, 20 },   .{ 18, 2 },    .{ 19, 3 },    .{ 20, 4 },    .{ 21, 5 },
        .{ 22, 7 },  .{ 23, 6 },  .{ 24, 13 },   .{ 25, 10 },   .{ 26, 8 },    .{ 27, 12 },   .{ 28, 9 },
        .{ 29, 11 }, .{ 30, 27 }, .{ 31, 24 },   .{ 32, 22 },   .{ 33, 26 },   .{ 34, 23 },   .{ 35, 25 },
        .{ 36, 28 }, .{ 37, 38 }, .{ 38, 36 },   .{ 39, 40 },   .{ 40, 37 },   .{ 41, 39 },   .{ 42, 43 },
        .{ 43, 51 }, .{ 44, 53 }, .{ 45, 49 },   .{ 46, 50 },   .{ 47, 52 },   .{ 48, 15 },   .{ 49, 57 },
        .{ 50, 41 }, .{ 51, 14 }, .{ 53, 1 },    .{ 54, 126 },  .{ 55, 125 },  .{ 56, 42 },   .{ 57, 58 },
        .{ 58, 56 }, .{ 59, 29 }, .{ 60, 54 },   .{ 61, 100 },  .{ 62, 97 },   .{ 63, 464 },  .{ 65, 83 },
        .{ 67, 55 }, .{ 69, 78 }, .{ 75, 98 },   .{ 76, 96 },   .{ 78, 74 },   .{ 81, 117 },  .{ 82, 82 },
        .{ 83, 79 }, .{ 84, 80 }, .{ 85, 81 },   .{ 86, 75 },   .{ 87, 76 },   .{ 88, 77 },   .{ 89, 71 },
        .{ 91, 72 }, .{ 92, 73 }, .{ 117, 111 }, .{ 123, 105 }, .{ 124, 106 }, .{ 125, 108 }, .{ 126, 103 },
    };
    for (table) |e| if (e[0] == vk) return e[1];
    return null;
}

/// macOS virtual keycode → class + position.
pub fn macKey(vk: u16) KeyInfo {
    const code = macToEvdev(vk) orelse return .{ .class = .other, .x = 0.5 };
    return evdevKey(code);
}

// ---------------------------------------------------------------------------------------
// Event queue
// ---------------------------------------------------------------------------------------

/// Fixed-capacity FIFO between an input source and the main-thread callback. When full,
/// the oldest event is dropped (a typing burst only needs the latest few). No allocation.
pub const InputQueue = struct {
    pub const capacity = 64;
    items: [capacity]pf.GlobalInputEvent = undefined,
    head: usize = 0,
    len: usize = 0,
    dropped: u64 = 0,

    pub fn push(q: *InputQueue, e: pf.GlobalInputEvent) void {
        if (q.len == capacity) {
            q.head = (q.head + 1) % capacity;
            q.len -= 1;
            q.dropped += 1;
        }
        q.items[(q.head + q.len) % capacity] = e;
        q.len += 1;
    }

    pub fn pop(q: *InputQueue) ?pf.GlobalInputEvent {
        if (q.len == 0) return null;
        const e = q.items[q.head];
        q.head = (q.head + 1) % capacity;
        q.len -= 1;
        return e;
    }

    /// Delivers every queued event to `cb` (oldest first).
    pub fn drainTo(q: *InputQueue, cb: pf.Callback(pf.GlobalInputEvent, void)) void {
        while (q.pop()) |e| _ = cb.call(e);
    }
};

/// Poll interval of a counter-based (permissionless) input monitor: 60 Hz for 2 s after
/// the last activity, 20 Hz until 6 s, then 4 Hz.
pub fn counterPollInterval(since_activity_ns: u64) u64 {
    if (since_activity_ns < 2 * std.time.ns_per_s) return std.time.ns_per_s / 60;
    if (since_activity_ns < 6 * std.time.ns_per_s) return std.time.ns_per_s / 20;
    return std.time.ns_per_s / 4;
}

// ---------------------------------------------------------------------------------------
// Launch at login files
// ---------------------------------------------------------------------------------------

/// `$XDG_CONFIG_HOME/autostart/<app_id>.desktop` (else `$HOME/.config/autostart/...`).
pub fn autostartPath(buf: []u8, xdg_config_home: ?[]const u8, home: ?[]const u8, app_id: []const u8) ![]const u8 {
    if (xdg_config_home) |x| if (x.len > 0 and x[0] == '/')
        return std.fmt.bufPrint(buf, "{s}/autostart/{s}.desktop", .{ x, app_id });
    const h = home orelse return error.NoHomeDirectory;
    return std.fmt.bufPrint(buf, "{s}/.config/autostart/{s}.desktop", .{ h, app_id });
}

/// Desktop Entry `Exec` quoting: arguments with reserved characters are double-quoted
/// with `"`, `` ` ``, `$` and `\` escaped; `%` is doubled everywhere.
fn writeExecArg(w: *std.Io.Writer, arg: []const u8) !void {
    const reserved = " \t\n\"'\\><~|&;$*?#()`";
    const quote = std.mem.indexOfAny(u8, arg, reserved) != null;
    if (quote) try w.writeByte('"');
    for (arg) |ch| {
        switch (ch) {
            '"', '`', '$', '\\' => if (quote) try w.writeByte('\\'),
            '%' => try w.writeByte('%'),
            else => {},
        }
        try w.writeByte(ch);
    }
    if (quote) try w.writeByte('"');
}

/// The XDG autostart entry launching `exe_path` at login.
pub fn writeAutostartEntry(w: *std.Io.Writer, app_id: []const u8, exe_path: []const u8) !void {
    try w.writeAll("[Desktop Entry]\nType=Application\nVersion=1.0\nName=");
    try w.writeAll(app_id);
    try w.writeAll("\nExec=");
    try writeExecArg(w, exe_path);
    try w.writeAll("\nTerminal=false\nNoDisplay=true\nX-GNOME-Autostart-enabled=true\n");
}

/// `~/Library/LaunchAgents/<app_id>.plist` (macOS fallback when SMAppService is unavailable).
pub fn launchAgentPath(buf: []u8, home: ?[]const u8, app_id: []const u8) ![]const u8 {
    const h = home orelse return error.NoHomeDirectory;
    return std.fmt.bufPrint(buf, "{s}/Library/LaunchAgents/{s}.plist", .{ h, app_id });
}

fn writeXmlEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(ch),
    };
}

/// A per-user LaunchAgent that runs `exe_path` once at login.
pub fn writeLaunchAgentPlist(w: *std.Io.Writer, app_id: []const u8, exe_path: []const u8) !void {
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>
    );
    try writeXmlEscaped(w, app_id);
    try w.writeAll(
        \\</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>
    );
    try writeXmlEscaped(w, exe_path);
    try w.writeAll(
        \\</string>
        \\  </array>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\  <key>ProcessType</key>
        \\  <string>Interactive</string>
        \\</dict>
        \\</plist>
        \\
    );
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;

test "anchoredOrigin pins each corner of the work area" {
    const vis: Bounds = .{ .origin = .{ .x = 0, .y = 25 }, .size = .{ .width = 1440, .height = 845 } };
    const size: Size = .{ .width = 160, .height = 120 };
    const m: Point = .{ .x = 16, .y = 12 };
    try testing.expectEqual(Point{ .x = 16, .y = 37 }, anchoredOrigin(.{ .corner = .top_left, .margin = m }, vis, size));
    try testing.expectEqual(Point{ .x = 1264, .y = 37 }, anchoredOrigin(.{ .corner = .top_right, .margin = m }, vis, size));
    try testing.expectEqual(Point{ .x = 16, .y = 738 }, anchoredOrigin(.{ .corner = .bottom_left, .margin = m }, vis, size));
    try testing.expectEqual(Point{ .x = 1264, .y = 738 }, anchoredOrigin(.{ .corner = .bottom_right, .margin = m }, vis, size));
    // A second display to the right with a panel on its left edge.
    const vis2: Bounds = .{ .origin = .{ .x = 1488, .y = 0 }, .size = .{ .width = 1872, .height = 1080 } };
    try testing.expectEqual(Point{ .x = 3184, .y = 944 }, anchoredOrigin(.{}, vis2, size));
}

test "layerPlacement maps corners to layer-shell anchors and margins" {
    const p = layerPlacement(.{ .corner = .bottom_right, .margin = .{ .x = 16, .y = 24 } });
    try testing.expectEqual(@as(u32, 2 | 8), p.anchor);
    try testing.expectEqual([4]i32{ 0, 16, 24, 0 }, p.margin);
    const q = layerPlacement(.{ .corner = .top_left, .margin = .{ .x = 5, .y = 7 } });
    try testing.expectEqual(@as(u32, 1 | 4), q.anchor);
    try testing.expectEqual([4]i32{ 7, 0, 0, 5 }, q.margin);
}

test "evdevKey classes and left/right positions" {
    // KEY_A, KEY_L, KEY_Q, KEY_P, KEY_Z, KEY_M
    try testing.expectEqual(pf.GlobalKeyClass.letter, evdevKey(30).class);
    try testing.expect(evdevKey(30).x < 0.25 and evdevKey(38).x > 0.6);
    try testing.expect(evdevKey(16).x < evdevKey(17).x and evdevKey(25).x > 0.7);
    try testing.expect(evdevKey(44).x < evdevKey(50).x);
    try testing.expectEqual(pf.GlobalKeyClass.digit, evdevKey(2).class);
    try testing.expectEqual(pf.GlobalKeyClass.digit, evdevKey(11).class);
    try testing.expectEqual(pf.GlobalKeyClass.space, evdevKey(57).class);
    try testing.expectApproxEqAbs(@as(f32, 0.5), evdevKey(57).x, 0.001);
    try testing.expectEqual(pf.GlobalKeyClass.enter, evdevKey(28).class);
    try testing.expectEqual(pf.GlobalKeyClass.enter, evdevKey(96).class);
    try testing.expectEqual(pf.GlobalKeyClass.backspace, evdevKey(14).class);
    try testing.expectEqual(pf.GlobalKeyClass.tab, evdevKey(15).class);
    for ([_]u16{ 29, 42, 54, 56, 97, 100, 125, 126, 58 }) |c| try testing.expectEqual(pf.GlobalKeyClass.modifier, evdevKey(c).class);
    for ([_]u16{ 103, 105, 106, 108 }) |c| try testing.expectEqual(pf.GlobalKeyClass.arrow, evdevKey(c).class);
    try testing.expectEqual(pf.GlobalKeyClass.other, evdevKey(1).class);
    try testing.expectEqual(KeyInfo{ .class = .other, .x = 0.5 }, evdevKey(999));
    // Every position stays within 0..1.
    var c: u16 = 0;
    while (c < 600) : (c += 1) {
        const k = evdevKey(c);
        try testing.expect(k.x >= 0 and k.x <= 1);
    }
}

test "macKey agrees with evdevKey through the kVK table" {
    try testing.expectEqual(evdevKey(30), macKey(0)); // kVK_ANSI_A
    try testing.expectEqual(pf.GlobalKeyClass.letter, macKey(46).class); // M
    try testing.expectEqual(pf.GlobalKeyClass.space, macKey(49).class);
    try testing.expectEqual(pf.GlobalKeyClass.enter, macKey(36).class);
    try testing.expectEqual(pf.GlobalKeyClass.backspace, macKey(51).class);
    try testing.expectEqual(pf.GlobalKeyClass.tab, macKey(48).class);
    try testing.expectEqual(pf.GlobalKeyClass.modifier, macKey(55).class); // command
    try testing.expectEqual(pf.GlobalKeyClass.arrow, macKey(123).class);
    try testing.expectEqual(pf.GlobalKeyClass.digit, macKey(29).class); // 0
    try testing.expectEqual(pf.GlobalKeyClass.other, macKey(200).class);
    // Every ANSI letter maps to a letter.
    for ([_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40, 45, 46 }) |vk|
        try testing.expectEqual(pf.GlobalKeyClass.letter, macKey(vk).class);
}

test "InputQueue is FIFO and drops the oldest when full" {
    var q: InputQueue = .{};
    try testing.expect(q.pop() == null);
    var i: u64 = 0;
    while (i < InputQueue.capacity + 3) : (i += 1) q.push(.{ .kind = .key_down, .timestamp_ns = i });
    try testing.expectEqual(@as(u64, 3), q.dropped);
    try testing.expectEqual(@as(u64, 3), q.pop().?.timestamp_ns);
    var last: u64 = 3;
    while (q.pop()) |e| last = e.timestamp_ns;
    try testing.expectEqual(@as(u64, InputQueue.capacity + 2), last);
}

test "counterPollInterval backs off after activity" {
    try testing.expectEqual(std.time.ns_per_s / 60, counterPollInterval(0));
    try testing.expectEqual(std.time.ns_per_s / 20, counterPollInterval(3 * std.time.ns_per_s));
    try testing.expectEqual(std.time.ns_per_s / 4, counterPollInterval(60 * std.time.ns_per_s));
}

test "autostart desktop entry path and contents" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/home/u/.config/autostart/typebud.desktop", try autostartPath(&buf, null, "/home/u", "typebud"));
    try testing.expectEqualStrings("/x/cfg/autostart/typebud.desktop", try autostartPath(&buf, "/x/cfg", "/home/u", "typebud"));
    try testing.expectEqualStrings("/home/u/.config/autostart/a.desktop", try autostartPath(&buf, "relative", "/home/u", "a"));
    try testing.expectError(error.NoHomeDirectory, autostartPath(&buf, null, null, "a"));

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeAutostartEntry(&out.writer, "typebud", "/opt/type bud/bin/typebud");
    try testing.expectEqualStrings(
        \\[Desktop Entry]
        \\Type=Application
        \\Version=1.0
        \\Name=typebud
        \\Exec="/opt/type bud/bin/typebud"
        \\Terminal=false
        \\NoDisplay=true
        \\X-GNOME-Autostart-enabled=true
        \\
    , out.written());

    out.clearRetainingCapacity();
    try writeAutostartEntry(&out.writer, "t", "/usr/bin/t");
    try testing.expect(std.mem.indexOf(u8, out.written(), "\nExec=/usr/bin/t\n") != null);
    out.clearRetainingCapacity();
    try writeAutostartEntry(&out.writer, "t", "/a/$b\"c%d");
    try testing.expect(std.mem.indexOf(u8, out.written(), "\nExec=\"/a/\\$b\\\"c%%d\"\n") != null);
}

test "launch agent plist" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/Users/u/Library/LaunchAgents/com.x.typebud.plist", try launchAgentPath(&buf, "/Users/u", "com.x.typebud"));
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeLaunchAgentPlist(&out.writer, "com.x.typebud", "/Applications/A&B.app/Contents/MacOS/t");
    const s = out.written();
    try testing.expect(std.mem.indexOf(u8, s, "<string>com.x.typebud</string>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<string>/Applications/A&amp;B.app/Contents/MacOS/t</string>") != null);
    try testing.expect(std.mem.indexOf(u8, s, "<key>RunAtLoad</key>\n  <true/>") != null);
}
