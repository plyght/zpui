//! Windows keyboard helpers: virtual-key codes to gpui key names (`Keystroke.key`),
//! current modifiers, and the coarse classification the global input monitor reports
//! (`GlobalKeyClass` + `key_x`, the key's horizontal position on a US layout, from the
//! hardware scan code so it is layout independent).

const std = @import("std");
const w = @import("win32.zig");
const input = @import("../../input.zig");
const platform = @import("../platform.zig");

/// gpui key name for a virtual key, or null for keys that produce characters (the
/// caller uses the layout's unshifted character then).
pub fn keyName(vk: u32, extended: bool) ?[]const u8 {
    return switch (vk) {
        w.VK_BACK => "backspace",
        w.VK_TAB => "tab",
        w.VK_RETURN => "enter",
        w.VK_ESCAPE => "escape",
        w.VK_SPACE => "space",
        w.VK_PRIOR => "pageup",
        w.VK_NEXT => "pagedown",
        w.VK_END => "end",
        w.VK_HOME => "home",
        w.VK_LEFT => "left",
        w.VK_UP => "up",
        w.VK_RIGHT => "right",
        w.VK_DOWN => "down",
        w.VK_INSERT => "insert",
        w.VK_DELETE => "delete",
        w.VK_APPS => "menu",
        w.VK_SHIFT, w.VK_LSHIFT, w.VK_RSHIFT => "shift",
        w.VK_CONTROL, w.VK_LCONTROL, w.VK_RCONTROL => "control",
        w.VK_MENU, w.VK_LMENU, w.VK_RMENU => "alt",
        w.VK_LWIN, w.VK_RWIN => "platform",
        w.VK_CAPITAL => "capslock",
        w.VK_F1...w.VK_F24 => fkeys[vk - w.VK_F1],
        w.VK_NUMPAD0...w.VK_NUMPAD0 + 9 => digits[vk - w.VK_NUMPAD0],
        w.VK_MULTIPLY => "*",
        w.VK_ADD => "+",
        w.VK_SUBTRACT => "-",
        w.VK_DECIMAL => ".",
        w.VK_DIVIDE => "/",
        w.VK_CLEAR => if (extended) null else "clear",
        else => null,
    };
}

const fkeys = [_][]const u8{
    "f1",  "f2",  "f3",  "f4",  "f5",  "f6",  "f7",  "f8",  "f9",  "f10", "f11", "f12",
    "f13", "f14", "f15", "f16", "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24",
};
const digits = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };

pub fn isModifierKey(vk: u32) bool {
    return switch (vk) {
        w.VK_SHIFT, w.VK_LSHIFT, w.VK_RSHIFT, w.VK_CONTROL, w.VK_LCONTROL, w.VK_RCONTROL, w.VK_MENU, w.VK_LMENU, w.VK_RMENU, w.VK_LWIN, w.VK_RWIN, w.VK_CAPITAL => true,
        else => false,
    };
}

fn down(vk: u32) bool {
    return w.GetKeyState(@intCast(vk)) < 0;
}

/// The current modifier state (GetKeyState: as of the message being processed).
/// AltGr (reported by Windows as Ctrl+Alt) is not a shortcut modifier: it types.
pub fn currentModifiers() input.Modifiers {
    const altgr = down(w.VK_RMENU) and down(w.VK_LCONTROL);
    return .{
        .control = down(w.VK_CONTROL) and !altgr,
        .alt = down(w.VK_MENU) and !altgr,
        .shift = down(w.VK_SHIFT),
        .platform = down(w.VK_LWIN) or down(w.VK_RWIN),
    };
}

pub fn capsLock() bool {
    return w.GetKeyState(@intCast(w.VK_CAPITAL)) & 1 != 0;
}

/// Lowercase key name from the active layout for character keys (`a`, `1`, `;`...).
pub fn charKeyName(vk: u32, scan: u32, buf: *[8]u8) ?[]const u8 {
    var state: [256]u8 = @splat(0);
    var wide: [4]u16 = undefined;
    // flags bit 2 (Windows 10 1607+): do not change the keyboard's dead-key state.
    const n = w.ToUnicode(vk, scan, &state, &wide, wide.len, 0x4);
    if (n <= 0) return null;
    const s = w.wideToUtf8Buf(buf, wide[0..@intCast(n)]);
    if (s.len == 0 or s[0] < 0x20) return null;
    for (s) |*ch| ch.* = std.ascii.toLower(ch.*);
    return s;
}

/// The character `vk` types with the current modifiers (Shift, AltGr, Caps Lock), for
/// `Keystroke.key_char`. Ctrl / Alt shortcuts report none.
pub fn typedChar(vk: u32, scan: u32, buf: *[8]u8) ?[]const u8 {
    var state: [256]u8 = undefined;
    if (w.GetKeyboardState(&state) == 0) return null;
    const m = currentModifiers();
    if (m.control or m.alt or m.platform) return null;
    var wide: [4]u16 = undefined;
    const n = w.ToUnicode(vk, scan, &state, &wide, wide.len, 0x4);
    if (n <= 0) return null;
    const s = w.wideToUtf8Buf(buf, wide[0..@intCast(n)]);
    if (s.len == 0 or s[0] < 0x20 or s[0] == 0x7f) return null;
    return s;
}

// ---- global input classification -------------------------------------------------------

pub fn classify(vk: u32) platform.GlobalKeyClass {
    return switch (vk) {
        'A'...'Z' => .letter,
        '0'...'9', w.VK_NUMPAD0...w.VK_NUMPAD0 + 9 => .digit,
        w.VK_SPACE => .space,
        w.VK_RETURN => .enter,
        w.VK_BACK, w.VK_DELETE => .backspace,
        w.VK_TAB => .tab,
        w.VK_LEFT, w.VK_UP, w.VK_RIGHT, w.VK_DOWN => .arrow,
        else => if (isModifierKey(vk)) .modifier else .other,
    };
}

/// Set-1 scan code (`extended` = E0 prefix) -> Linux input-event code. The non-extended
/// range is identical; the E0 keys are mapped explicitly. Null for unknown keys.
pub fn scanToEvdev(scan: u32, extended: bool) ?u16 {
    if (!extended) return if (scan > 0 and scan < 0x59) @intCast(scan) else null;
    return switch (scan) {
        0x1C => 96, // keypad enter
        0x1D => 97, // right ctrl
        0x35 => 98, // keypad /
        0x38 => 100, // right alt
        0x47 => 102, // home
        0x48 => 103, // up
        0x49 => 104, // page up
        0x4B => 105, // left
        0x4D => 106, // right
        0x4F => 107, // end
        0x50 => 108, // down
        0x51 => 109, // page down
        0x52 => 110, // insert
        0x53 => 111, // delete
        0x5B => 125, // left win
        0x5C => 126, // right win
        0x5D => 127, // menu
        else => null,
    };
}

/// Class + horizontal position for the global input monitor: the shared evdev table
/// (`platform.desktop.evdevKey`, layout independent) from the scan code, falling back to
/// the virtual key when the scan code is unknown (injected / synthetic input).
pub fn globalKey(vk: u32, scan: u32, extended: bool) platform.desktop.KeyInfo {
    if (scanToEvdev(scan, extended)) |code| {
        const info = platform.desktop.evdevKey(code);
        if (info.class != .other or info.x != 0.5) return info;
    }
    return .{ .class = classify(vk), .x = 0.5 };
}

test "key classification and positions" {
    try std.testing.expectEqual(platform.GlobalKeyClass.letter, classify('Q'));
    try std.testing.expectEqual(platform.GlobalKeyClass.modifier, classify(w.VK_LSHIFT));
    try std.testing.expect(globalKey('Q', 0x10, false).x < 0.2); // q: left hand
    try std.testing.expect(globalKey('P', 0x19, false).x > 0.6); // p: right hand
    try std.testing.expectEqual(platform.GlobalKeyClass.arrow, globalKey(w.VK_LEFT, 0x4B, true).class);
    try std.testing.expectEqual(platform.GlobalKeyClass.space, globalKey(w.VK_SPACE, 0x39, false).class);
}
