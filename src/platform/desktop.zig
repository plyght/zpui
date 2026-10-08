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

/// `anchoredOrigin` for y-up spaces (AppKit screen coordinates): `visible.origin` is the
/// bottom-left corner of the work area; returns the window's bottom-left origin.
pub fn anchoredOriginYUp(anchor: pf.OverlayAnchor, visible: Bounds, size: Size) Point {
    const flipped: Bounds = .{ .origin = .{ .x = visible.origin.x, .y = -(visible.origin.y + visible.size.height) }, .size = visible.size };
    const o = anchoredOrigin(anchor, flipped, size);
    return .{ .x = o.x, .y = -o.y - size.height };
}

/// Size of an aspect-locked overlay resized by dragging the corner opposite its anchor:
/// `start` is the size at drag start, `delta` the pointer movement since then (screen
/// px, y down). Growth away from the anchor corner enlarges the window; the larger of
/// the two axis scales wins so the handle tracks the pointer; clamped to `min`..`max`
/// width.
pub fn aspectResize(corner: pf.OverlayCorner, start: Size, delta: Point, min_width: f32, max_width: f32) Size {
    // Pointer moving right grows windows anchored on the left, and vice versa.
    const dx = switch (corner) {
        .top_left, .bottom_left => delta.x,
        .top_right, .bottom_right => -delta.x,
    };
    const dy = switch (corner) {
        .top_left, .top_right => delta.y,
        .bottom_left, .bottom_right => -delta.y,
    };
    const aspect = if (start.height > 0) start.width / start.height else 1;
    const sx = (start.width + dx) / @max(start.width, 1);
    const sy = (start.height + dy) / @max(start.height, 1);
    const s = if (@abs(sx - 1) > @abs(sy - 1)) sx else sy;
    const w = std.math.clamp(start.width * s, min_width, max_width);
    return .{ .width = @round(w), .height = @round(w / aspect) };
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

/// Counter → events logic of a permissionless key monitor (macOS
/// `CGEventSourceCounterForEventType`): each poll reads the system key-down counter;
/// the increase since the previous poll becomes that many `key_down` events (capped per
/// poll). Keys identified by a `KeySampler` keep their class and position; the rest are
/// `.other` with `key_x` alternating left / right with a little jitter (so a pet's paws
/// alternate), each followed by a `key_up` on the next poll.
pub const CounterDecoder = struct {
    /// Most key-downs reported per poll (a counter jump after sleep is not a burst).
    pub const max_burst = 32;

    count: u32 = 0,
    primed: bool = false,
    left: bool = false,
    owed_ups: u32 = 0,

    /// Start counting from `counter` (no events for what happened before).
    pub fn reset(d: *CounterDecoder, counter: u32) void {
        d.* = .{ .count = counter, .primed = true };
    }

    /// One poll. `known` are the keys a sampler saw go down since the previous poll
    /// (possibly none). Returns the number of key-downs pushed.
    pub fn poll(d: *CounterDecoder, q: *InputQueue, counter: u32, known: []const KeyInfo, now_ns: u64) u32 {
        while (d.owed_ups > 0) : (d.owed_ups -= 1) q.push(.{ .kind = .key_up, .timestamp_ns = now_ns });
        if (!d.primed) {
            d.reset(counter);
            return 0;
        }
        const delta = counter -% d.count;
        d.count = counter;
        // A wrapped / reset counter reads as a huge delta: treat as noise.
        if (delta > 1 << 20) return 0;
        const n: u32 = @min(delta, max_burst);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (i < known.len) {
                q.push(.{ .kind = .key_down, .key = known[i].class, .key_x = known[i].x, .timestamp_ns = now_ns });
            } else {
                d.left = !d.left;
                // Deterministic jitter 0..0.15 from the counter value.
                const h = (counter +% i) *% 2654435761;
                const jitter: f32 = @as(f32, @floatFromInt((h >> 28) & 15)) / 100.0;
                q.push(.{ .kind = .key_down, .key = .other, .key_x = if (d.left) 0.3 - jitter else 0.7 + jitter, .timestamp_ns = now_ns });
                d.owed_ups += 1;
            }
        }
        return n;
    }
};

/// Tracks sampled key states (macOS `CGEventSourceKeyState`, which may or may not
/// report real states without Input Monitoring) and probes whether sampling works: it
/// is `.works` once any sampled key reads as pressed, and gives up (`.broken`, sampling
/// stops) after `probe_polls` polls that counted key-downs without one sampled key
/// pressed.
pub const KeySampler = struct {
    pub const probe_polls = 12;
    pub const Probe = enum { unknown, works, broken };

    probe: Probe = .unknown,
    misses: u8 = 0,
    /// Counted polls since the last retry while `.broken`.
    retry: u8 = 0,
    down: [128]bool = @splat(false),
    new_down: [8]KeyInfo = undefined,
    new_len: usize = 0,
    any_down: bool = false,

    /// A `.broken` probe still samples one counted poll in `retry_every`: synthetic or
    /// very short key presses (down and up between two polls) can fail the probe even
    /// where key states are real, and one held key then turns it into `.works`.
    pub const retry_every = 16;

    /// Whether this poll should read key states (`counted` = key-downs this poll).
    pub fn shouldSample(s: *KeySampler, counted: bool) bool {
        if (s.probe != .broken) return counted or s.any_down;
        if (!counted) return false;
        s.retry += 1;
        if (s.retry < retry_every) return false;
        s.retry = 0;
        return true;
    }

    pub fn begin(s: *KeySampler) void {
        s.new_len = 0;
        s.any_down = false;
    }

    /// One sampled key (macOS virtual keycode < 128). Releases are pushed to `q`.
    pub fn observe(s: *KeySampler, q: *InputQueue, vk: u16, pressed: bool, now_ns: u64) void {
        if (vk >= s.down.len) return;
        if (pressed) {
            s.any_down = true;
            s.probe = .works;
            if (!s.down[vk] and s.new_len < s.new_down.len) {
                s.new_down[s.new_len] = macKey(vk);
                s.new_len += 1;
            }
        } else if (s.down[vk]) {
            const info = macKey(vk);
            q.push(.{ .kind = .key_up, .key = info.class, .key_x = info.x, .timestamp_ns = now_ns });
        }
        s.down[vk] = pressed;
    }

    /// End of a poll that counted `counted` key-downs: updates the probe.
    pub fn end(s: *KeySampler, counted: u32) []const KeyInfo {
        if (s.probe == .unknown and counted > 0 and !s.any_down) {
            s.misses += 1;
            if (s.misses >= probe_polls) s.probe = .broken;
        }
        return s.new_down[0..s.new_len];
    }
};

/// The drawable size an overlay resize presented inside the current Core Animation
/// transaction (macOS): the redisplay the bounds change schedules for that same
/// transaction is skipped instead of drawing a second frame, which would block on a
/// drawable that only frees once the transaction commits.
pub const PresentedFrame = struct {
    size: ?[2]i32 = null,

    pub fn mark(p: *PresentedFrame, width: i32, height: i32) void {
        p.size = .{ width, height };
    }

    /// Consumes the mark: true when a frame of exactly this size was presented.
    pub fn take(p: *PresentedFrame, width: i32, height: i32) bool {
        const s = p.size orelse return false;
        p.size = null;
        return s[0] == width and s[1] == height;
    }
};

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

test "anchoredOriginYUp mirrors anchoredOrigin in AppKit coordinates" {
    // A 1440x900 screen with a 25 pt menu bar and the Dock (70 pt) at the bottom.
    const vis: Bounds = .{ .origin = .{ .x = 0, .y = 70 }, .size = .{ .width = 1440, .height = 805 } };
    const size: Size = .{ .width = 160, .height = 120 };
    const m: Point = .{ .x = 16, .y = 12 };
    try testing.expectEqual(Point{ .x = 1264, .y = 82 }, anchoredOriginYUp(.{ .corner = .bottom_right, .margin = m }, vis, size));
    try testing.expectEqual(Point{ .x = 16, .y = 82 }, anchoredOriginYUp(.{ .corner = .bottom_left, .margin = m }, vis, size));
    try testing.expectEqual(Point{ .x = 16, .y = 743 }, anchoredOriginYUp(.{ .corner = .top_left, .margin = m }, vis, size));
}

test "anchored resize keeps the anchor corner fixed" {
    const vis: Bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1000, .height = 800 } };
    const a: pf.OverlayAnchor = .{ .corner = .bottom_right, .margin = .{ .x = 10, .y = 20 } };
    for ([_]Size{ .{ .width = 100, .height = 80 }, .{ .width = 250, .height = 200 }, .{ .width = 37, .height = 29 } }) |sz| {
        const o = anchoredOrigin(a, vis, sz);
        try testing.expectEqual(@as(f32, 990), o.x + sz.width);
        try testing.expectEqual(@as(f32, 780), o.y + sz.height);
        const u = anchoredOriginYUp(a, vis, sz);
        try testing.expectEqual(@as(f32, 990), u.x + sz.width);
        try testing.expectEqual(@as(f32, 20), u.y);
    }
}

test "aspectResize grows away from the anchor, keeps the aspect, clamps" {
    const start: Size = .{ .width = 160, .height = 120 };
    // Bottom-right anchor: dragging the top-left handle up-left grows.
    const g = aspectResize(.bottom_right, start, .{ .x = -40, .y = -10 }, 64, 512);
    try testing.expectEqual(Size{ .width = 200, .height = 150 }, g);
    const s = aspectResize(.bottom_right, start, .{ .x = 80, .y = 0 }, 64, 512);
    try testing.expectEqual(Size{ .width = 80, .height = 60 }, s);
    // Top-left anchor: the handle is bottom-right; moving right/down grows.
    try testing.expectEqual(Size{ .width = 240, .height = 180 }, aspectResize(.top_left, start, .{ .x = 0, .y = 60 }, 64, 512));
    try testing.expectEqual(@as(f32, 64), aspectResize(.top_left, start, .{ .x = -500, .y = 0 }, 64, 512).width);
    try testing.expectEqual(@as(f32, 512), aspectResize(.top_left, start, .{ .x = 5000, .y = 0 }, 64, 512).width);
}

test "CounterDecoder turns counter deltas into alternating key events" {
    var q: InputQueue = .{};
    var d: CounterDecoder = .{};
    try testing.expectEqual(@as(u32, 0), d.poll(&q, 1000, &.{}, 1)); // primes, no events
    try testing.expect(q.pop() == null);
    try testing.expectEqual(@as(u32, 0), d.poll(&q, 1000, &.{}, 2));
    try testing.expectEqual(@as(u32, 3), d.poll(&q, 1003, &.{}, 3));
    var xs: [3]f32 = undefined;
    for (&xs) |*x| {
        const e = q.pop().?;
        try testing.expectEqual(pf.GlobalInputKind.key_down, e.kind);
        try testing.expectEqual(pf.GlobalKeyClass.other, e.key);
        try testing.expectEqual(@as(u64, 3), e.timestamp_ns);
        x.* = e.key_x;
    }
    // Paws alternate: left, right, left.
    try testing.expect(xs[0] < 0.5 and xs[1] > 0.5 and xs[2] < 0.5);
    try testing.expect(xs[0] >= 0.15 and xs[1] <= 0.85);
    // The next poll owes their releases.
    _ = d.poll(&q, 1003, &.{}, 4);
    var ups: usize = 0;
    while (q.pop()) |e| : (ups += 1) try testing.expectEqual(pf.GlobalInputKind.key_up, e.kind);
    try testing.expectEqual(@as(usize, 3), ups);
    // Sampled keys keep their identity (and owe no release: the sampler reports it).
    const known = [_]KeyInfo{macKey(0)};
    try testing.expectEqual(@as(u32, 2), d.poll(&q, 1005, &known, 5));
    const first = q.pop().?;
    try testing.expectEqual(pf.GlobalKeyClass.letter, first.key);
    try testing.expectEqual(macKey(0).x, first.key_x);
    try testing.expectEqual(pf.GlobalKeyClass.other, q.pop().?.key);
    try testing.expectEqual(@as(u32, 1), d.owed_ups);
    // Wraparound counts correctly; a huge jump is ignored; bursts are capped.
    d.reset(0xFFFF_FFFF);
    try testing.expectEqual(@as(u32, 2), d.poll(&q, 1, &.{}, 6));
    try testing.expectEqual(@as(u32, 0), d.poll(&q, 1 + (1 << 24), &.{}, 7));
    try testing.expectEqual(@as(u32, CounterDecoder.max_burst), d.poll(&q, 1 + (1 << 24) + 500, &.{}, 8));
}

test "KeySampler reports presses and releases and probes whether sampling works" {
    var q: InputQueue = .{};
    var s: KeySampler = .{};
    try testing.expect(s.shouldSample(true));
    try testing.expect(!s.shouldSample(false));
    s.begin();
    s.observe(&q, 0, true, 1); // A down
    s.observe(&q, 49, false, 1);
    const known = s.end(1);
    try testing.expectEqual(@as(usize, 1), known.len);
    try testing.expectEqual(KeySampler.Probe.works, s.probe);
    try testing.expect(s.shouldSample(false)); // a key is held: keep sampling for its release
    s.begin();
    s.observe(&q, 0, false, 2);
    try testing.expectEqual(@as(usize, 0), s.end(0).len);
    const up = q.pop().?;
    try testing.expectEqual(pf.GlobalInputKind.key_up, up.kind);
    try testing.expectEqual(pf.GlobalKeyClass.letter, up.key);

    // Without real key states, sampling is abandoned after the probe window.
    var b: KeySampler = .{};
    var i: usize = 0;
    while (i < KeySampler.probe_polls) : (i += 1) {
        b.begin();
        b.observe(&q, 0, false, 0);
        _ = b.end(2);
    }
    try testing.expectEqual(KeySampler.Probe.broken, b.probe);
    try testing.expect(!b.shouldSample(true));
    try testing.expect(!b.shouldSample(false));
    // ...but retries every `retry_every` counted polls; a held key revives it.
    i = 1;
    while (i < KeySampler.retry_every - 1) : (i += 1) try testing.expect(!b.shouldSample(true));
    try testing.expect(b.shouldSample(true));
    try testing.expect(!b.shouldSample(true));
    b.begin();
    b.observe(&q, 2, true, 9); // D held
    const revived = b.end(1);
    try testing.expectEqual(KeySampler.Probe.works, b.probe);
    try testing.expectEqual(@as(usize, 1), revived.len);
    try testing.expectEqual(macKey(2).x, revived[0].x);
    try testing.expect(b.shouldSample(false));
}

test "KeySampler positions: left-hand keys left of right-hand keys" {
    var q: InputQueue = .{};
    var s: KeySampler = .{};
    s.begin();
    s.observe(&q, 0, true, 1); // A
    s.observe(&q, 37, true, 1); // L
    const known = s.end(2);
    try testing.expectEqual(@as(usize, 2), known.len);
    try testing.expect(known[0].x < 0.5 and known[1].x > 0.5);
    // The decoder hands those positions to the key-downs (paws), no alternation.
    var d: CounterDecoder = .{};
    d.reset(10);
    try testing.expectEqual(@as(u32, 2), d.poll(&q, 12, known, 2));
    try testing.expect(q.pop().?.key_x < 0.5);
    try testing.expect(q.pop().?.key_x > 0.5);
    try testing.expectEqual(@as(u32, 0), d.owed_ups);
}

test "PresentedFrame skips only the matching redisplay, once" {
    var p: PresentedFrame = .{};
    try testing.expect(!p.take(10, 10));
    p.mark(320, 320);
    try testing.expect(p.take(320, 320));
    try testing.expect(!p.take(320, 320));
    p.mark(320, 320);
    try testing.expect(!p.take(322, 322)); // size changed since: draw
    try testing.expect(!p.take(320, 320));
}
