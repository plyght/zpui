//! NSEvent → `input.PlatformInput` (port of zui `gpui_macos/src/events.rs`).
//!
//! Key names and `key_char` follow gpui exactly, including the layout-aware
//! fallback that asks `UCKeyTranslate` what a key produces with no modifiers,
//! shift, cmd and cmd-shift (Dvorak-QWERTY⌘, Russian, Armenian, Czech, ...).
//! Strings are copied into a `KeystrokeBuf` owned by the caller, so the
//! resulting `Keystroke` slices stay valid while it lives.

const std = @import("std");
const ak = @import("appkit.zig");
const cf = @import("cf.zig");
const objc = @import("objc.zig");
const input = @import("../../input.zig");

const id = objc.id;
const NSUInteger = ak.NSUInteger;
const NSInteger = ak.NSInteger;
const Point = input.Point;

const backspace_key: u16 = 0x7f;
const space_key: u16 = ' ';
const enter_key: u16 = 0x0d;
const numpad_enter_key: u16 = 0x03;
pub const escape_key: u16 = 0x1b;
const tab_key: u16 = 0x09;
const shift_tab_key: u16 = 0x19;

/// Owned storage for one keystroke's strings.
pub const KeystrokeBuf = struct {
    modifiers: input.Modifiers = .{},
    key_buf: [32]u8 = undefined,
    key_len: u8 = 0,
    char_buf: [32]u8 = undefined,
    char_len: u8 = 0,
    has_char: bool = false,

    pub fn keystroke(self: *const KeystrokeBuf) input.Keystroke {
        return .{
            .modifiers = self.modifiers,
            .key = self.key_buf[0..self.key_len],
            .key_char = if (self.has_char) self.char_buf[0..self.char_len] else null,
        };
    }

    pub fn setKey(self: *KeystrokeBuf, s: []const u8) void {
        const n = @min(s.len, self.key_buf.len);
        @memcpy(self.key_buf[0..n], s[0..n]);
        self.key_len = @intCast(n);
    }

    pub fn setChar(self: *KeystrokeBuf, s: []const u8) void {
        const n = @min(s.len, self.char_buf.len);
        @memcpy(self.char_buf[0..n], s[0..n]);
        self.char_len = @intCast(n);
        self.has_char = true;
    }

    pub fn eql(a: *const KeystrokeBuf, b: *const KeystrokeBuf) bool {
        return a.modifiers.eql(b.modifiers) and
            std.mem.eql(u8, a.key_buf[0..a.key_len], b.key_buf[0..b.key_len]) and
            a.has_char == b.has_char and
            std.mem.eql(u8, a.char_buf[0..a.char_len], b.char_buf[0..b.char_len]);
    }
};

/// A key down/up as stored by the window (keystroke strings live inside).
pub const KeyEvent = struct {
    buf: KeystrokeBuf,
    is_held: bool = false,

    pub fn eql(a: *const KeyEvent, b: *const KeyEvent) bool {
        return a.is_held == b.is_held and a.buf.eql(&b.buf);
    }
};

/// Result of translating one NSEvent. Key events keep their strings in `key`.
pub const Translated = union(enum) {
    input: input.PlatformInput,
    key_down: KeyEvent,
    key_up: KeyEvent,
};

pub fn modifierFlags(event: id) NSUInteger {
    return event.msg(NSUInteger, "modifierFlags", .{});
}

pub fn modifiersFromFlags(flags: NSUInteger) input.Modifiers {
    const M = ak.NSEventModifierFlags;
    return .{
        .control = flags & M.control != 0,
        .alt = flags & M.option != 0,
        .shift = flags & M.shift != 0,
        .platform = flags & M.command != 0,
        .function = flags & M.function != 0,
    };
}

fn locationInWindow(event: id, window_height: f32) Point {
    const p = event.msg(ak.NSPoint, "locationInWindow", .{});
    // macOS window coordinates are relative to the bottom left.
    return .{ .x = @floatCast(p.x), .y = window_height - @as(f32, @floatCast(p.y)) };
}

fn mouseButton(event: id) ?input.MouseButton {
    return switch (event.msg(NSInteger, "buttonNumber", .{})) {
        0 => .left,
        1 => .right,
        2 => .middle,
        3 => .back,
        4 => .forward,
        // Other mouse buttons aren't tracked.
        else => null,
    };
}

fn touchPhase(event: id) input.TouchPhase {
    const phase = event.msg(NSUInteger, "phase", .{});
    if (phase == ak.NSEventPhase.may_begin or phase == ak.NSEventPhase.began) return .started;
    if (phase == ak.NSEventPhase.ended) return .ended;
    return .moved;
}

/// zui `platform_input_from_native`. `window_height` is the content height in points.
pub fn translate(event: id, window_height: f32) ?Translated {
    const T = ak.NSEventType;
    const event_type = event.msg(NSUInteger, "type", .{});
    const flags = modifierFlags(event);
    const mods = modifiersFromFlags(flags);
    switch (event_type) {
        T.flags_changed => return .{ .input = .{ .modifiers_changed = .{
            .modifiers = mods,
            .capslock = flags & ak.NSEventModifierFlags.caps_lock != 0,
        } } },
        T.key_down => return .{ .key_down = .{
            .buf = parseKeystroke(event),
            .is_held = event.msg(objc.BOOL, "isARepeat", .{}) == objc.YES,
        } },
        T.key_up => return .{ .key_up = .{ .buf = parseKeystroke(event) } },
        T.left_mouse_down, T.right_mouse_down, T.other_mouse_down => {
            const button = mouseButton(event) orelse return null;
            return .{ .input = .{ .mouse_down = .{
                .button = button,
                .position = locationInWindow(event, window_height),
                .modifiers = mods,
                .click_count = @intCast(@max(event.msg(NSInteger, "clickCount", .{}), 0)),
                .first_mouse = false,
            } } };
        },
        T.left_mouse_up, T.right_mouse_up, T.other_mouse_up => {
            const button = mouseButton(event) orelse return null;
            return .{ .input = .{ .mouse_up = .{
                .button = button,
                .position = locationInWindow(event, window_height),
                .modifiers = mods,
                .click_count = @intCast(@max(event.msg(NSInteger, "clickCount", .{}), 0)),
            } } };
        },
        // Some mice (e.g. Logitech MX Master) send navigation buttons as swipes.
        T.swipe => {
            if (event.msg(NSUInteger, "phase", .{}) != ak.NSEventPhase.ended) return null;
            const dx = event.msg(ak.CGFloat, "deltaX", .{});
            const button: input.MouseButton = if (dx > 0) .back else if (dx < 0) .forward else return null;
            return .{ .input = .{ .mouse_down = .{
                .button = button,
                .position = locationInWindow(event, window_height),
                .modifiers = mods,
                .click_count = 1,
            } } };
        },
        T.scroll_wheel => {
            const raw: Point = .{
                .x = @floatCast(event.msg(ak.CGFloat, "scrollingDeltaX", .{})),
                .y = @floatCast(event.msg(ak.CGFloat, "scrollingDeltaY", .{})),
            };
            const precise = event.msg(objc.BOOL, "hasPreciseScrollingDeltas", .{}) == objc.YES;
            return .{ .input = .{ .scroll_wheel = .{
                .position = locationInWindow(event, window_height),
                .delta = if (precise) .{ .pixels = raw } else .{ .lines = raw },
                .modifiers = mods,
                .touch_phase = touchPhase(event),
            } } };
        },
        T.left_mouse_dragged, T.right_mouse_dragged, T.other_mouse_dragged => {
            const button = mouseButton(event) orelse return null;
            return .{ .input = .{ .mouse_move = .{
                .position = locationInWindow(event, window_height),
                .pressed_button = button,
                .modifiers = mods,
            } } };
        },
        T.mouse_moved => return .{ .input = .{ .mouse_move = .{
            .position = locationInWindow(event, window_height),
            .modifiers = mods,
        } } },
        T.mouse_exited => return .{ .input = .{ .mouse_exited = .{
            .position = locationInWindow(event, window_height),
            .modifiers = mods,
        } } },
        else => return null,
    }
}

fn functionKeyName(ch: u16) ?[]const u8 {
    const F = ak.FunctionKey;
    return switch (ch) {
        F.up => "up",
        F.down => "down",
        F.left => "left",
        F.right => "right",
        F.page_up => "pageup",
        F.page_down => "pagedown",
        F.home => "home",
        F.end => "end",
        F.delete => "delete",
        // Observed: Insert reports NSHelpFunctionKey, not NSInsertFunctionKey.
        F.help => "insert",
        else => null,
    };
}

const fkey_names = blk: {
    @setEvalBranchQuota(20_000);
    var names: [35][]const u8 = undefined;
    for (&names, 1..) |*n, i| n.* = std.fmt.comptimePrint("f{d}", .{i});
    break :blk names;
};

/// zui `parse_keystroke`.
pub fn parseKeystroke(event: id) KeystrokeBuf {
    var out: KeystrokeBuf = .{};
    const chars_ignoring = event.msg(?id, "charactersIgnoringModifiers", .{});
    const first_char: ?u16 = if (chars_ignoring) |s|
        (if (s.msg(NSUInteger, "length", .{}) > 0) s.msg(u16, "characterAtIndex:", .{@as(NSUInteger, 0)}) else null)
    else
        null;

    const flags = modifierFlags(event);
    const M = ak.NSEventModifierFlags;
    const control = flags & M.control != 0;
    const alt = flags & M.option != 0;
    var shift = flags & M.shift != 0;
    const command = flags & M.command != 0;
    const function = flags & M.function != 0 and
        (if (first_char) |ch| !(ch >= ak.FunctionKey.up and ch <= ak.FunctionKey.mode_switch) else true);

    named: {
        const ch = first_char orelse break :named;
        switch (ch) {
            space_key => {
                out.setChar(" ");
                out.setKey("space");
            },
            tab_key => {
                out.setChar("\t");
                out.setKey("tab");
            },
            enter_key, numpad_enter_key => {
                out.setChar("\n");
                out.setKey("enter");
            },
            backspace_key => out.setKey("backspace"),
            escape_key => out.setKey("escape"),
            shift_tab_key => out.setKey("tab"),
            else => {
                if (functionKeyName(ch)) |name| {
                    out.setKey(name);
                } else if (ch >= ak.FunctionKey.f1 and ch <= ak.FunctionKey.f35) {
                    out.setKey(fkey_names[ch - ak.FunctionKey.f1]);
                } else break :named;
            },
        }
        out.modifiers = .{ .control = control, .alt = alt, .shift = shift, .platform = command, .function = function };
        return out;
    }

    // Layout-aware fallback. Cases to test when modifying this:
    //           qwerty key | none | cmd   | cmd-shift
    // * Armenian         s | ս    | cmd-s | cmd-shift-s  (layout is non-ASCII, so we use cmd layout)
    // * Dvorak+QWERTY    s | o    | cmd-s | cmd-shift-s  (layout switches on cmd)
    // * Ukrainian+QWERTY s | с    | cmd-s | cmd-shift-s  (macOS reports cmd-s instead of cmd-S)
    // * Czech            7 | ý    | cmd-ý | cmd-7        (layout has shifted numbers)
    // * Norwegian        7 | 7    | cmd-7 | cmd-/        (macOS reports cmd-shift-7 instead of cmd-/)
    // * Russian          7 | 7    | cmd-7 | cmd-&        (shift-7 is . but when cmd is down, should use cmd layout)
    // * German QWERTZ    ; | ö    | cmd-ö | cmd-Ö        (the shift special case only applies to a-z)
    const key_code = event.msg(u16, "keyCode", .{});
    var ignoring = charsForModifiedKey(key_code, no_mod);
    var with_shift = charsForModifiedKey(key_code, shift_mod);

    if (command or alwaysUseCommandLayout()) {
        const with_cmd = charsForModifiedKey(key_code, cmd_mod);
        const with_both = charsForModifiedKey(key_code, cmd_mod | shift_mod);
        if (!with_both.eql(with_cmd)) {
            with_shift = with_both;
        } else {
            const upper = with_cmd.asciiUpper();
            if (!upper.eql(with_cmd)) with_shift = upper;
        }
        ignoring = with_cmd;
    }

    if (!control and !command and !function) {
        var mods = no_mod;
        if (shift) mods |= shift_mod;
        if (alt) mods |= option_mod;
        out.setChar(charsForModifiedKey(key_code, mods).slice());
    }

    if (shift and ignoring.allAsciiLowercase()) {
        out.setKey(ignoring.slice());
    } else if (shift) {
        shift = false;
        out.setKey(with_shift.slice());
    } else {
        out.setKey(ignoring.slice());
    }
    out.modifiers = .{ .control = control, .alt = alt, .shift = shift, .platform = command, .function = function };
    return out;
}

/// Up to 4 UTF-16 units from UCKeyTranslate, as UTF-8.
const KeyChars = struct {
    buf: [16]u8 = undefined,
    len: u8 = 0,

    fn slice(self: *const KeyChars) []const u8 {
        return self.buf[0..self.len];
    }
    fn eql(a: KeyChars, b: KeyChars) bool {
        return std.mem.eql(u8, a.slice(), b.slice());
    }
    fn isAscii(self: KeyChars) bool {
        for (self.slice()) |c| if (c >= 0x80) return false;
        return true;
    }
    fn asciiUpper(self: KeyChars) KeyChars {
        var out = self;
        for (out.buf[0..out.len]) |*c| c.* = std.ascii.toUpper(c.*);
        return out;
    }
    fn allAsciiLowercase(self: KeyChars) bool {
        for (self.slice()) |c| if (!std.ascii.isLower(c)) return false;
        return true;
    }
};

const no_mod: u32 = 0;
const cmd_mod: u32 = 1;
const shift_mod: u32 = 2;
const option_mod: u32 = 8;

fn alwaysUseCommandLayout() bool {
    if (charsForModifiedKey(0, no_mod).isAscii()) return false;
    return charsForModifiedKey(0, cmd_mod).isAscii();
}

/// zui `chars_for_modified_key`: what `code` types under the current keyboard
/// layout with Carbon modifier state `modifiers` (cmd=1, shift=2, option=8; >>8 form).
fn charsForModifiedKey(code: u16, modifiers: u32) KeyChars {
    const cg_space_key: u16 = 49;
    const kUCKeyActionDown: u16 = 0;
    const kUCKeyTranslateNoDeadKeysMask: u32 = 0;

    var result: KeyChars = .{};
    const keyboard = ak.TISCopyCurrentKeyboardLayoutInputSource() orelse return result;
    defer cf.CFRelease(keyboard);
    const layout_data: cf.CFDataRef = @ptrCast(ak.TISGetInputSourceProperty(keyboard, ak.kTISPropertyUnicodeKeyLayoutData) orelse return result);
    const layout = cf.CFDataGetBytePtr(layout_data) orelse return result;

    const keyboard_type: u32 = ak.LMGetKbdType();
    var dead_key_state: u32 = 0;
    var buffer: [4]u16 = @splat(0);
    var len: usize = 0;
    _ = ak.UCKeyTranslate(layout, code, kUCKeyActionDown, modifiers, keyboard_type, kUCKeyTranslateNoDeadKeysMask, &dead_key_state, buffer.len, &len, &buffer);
    if (dead_key_state != 0) {
        _ = ak.UCKeyTranslate(layout, cg_space_key, kUCKeyActionDown, modifiers, keyboard_type, kUCKeyTranslateNoDeadKeysMask, &dead_key_state, buffer.len, &len, &buffer);
    }
    const n = std.unicode.utf16LeToUtf8(&result.buf, buffer[0..@min(len, buffer.len)]) catch return .{};
    result.len = @intCast(n);
    return result;
}

/// Whether the current input source is a composition IME (Japanese kana,
/// Korean, Pinyin, ...) that produces non-ASCII output (zui `is_ime_input_source_active`).
pub fn isImeInputSourceActive() bool {
    const source = ak.TISCopyCurrentKeyboardInputSource() orelse return false;
    defer cf.CFRelease(source);
    const source_type = ak.TISGetInputSourceProperty(source, ak.kTISPropertyInputSourceType);
    const is_input_mode = if (source_type) |t| cf.CFEqual(t, ak.kTISTypeKeyboardInputMode) != 0 else false;
    const ascii = ak.TISGetInputSourceProperty(source, ak.kTISPropertyInputSourceIsASCIICapable);
    const is_ascii_capable = if (ascii) |a| cf.CFBooleanGetValue(@ptrCast(a)) != 0 else false;
    return is_input_mode and !is_ascii_capable;
}

test "fkey names" {
    try std.testing.expectEqualStrings("f1", fkey_names[0]);
    try std.testing.expectEqualStrings("f35", fkey_names[34]);
}
