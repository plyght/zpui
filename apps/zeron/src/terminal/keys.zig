//! Keystroke -> PTY bytes, via Ghostty's key encoder (legacy xterm
//! encoding, DECCKM/DECKPAM, modifyOtherKeys, alt-ESC prefixing and the
//! Kitty keyboard protocol when the running program enables it).
//!
//! Input is a gpui-shaped keystroke (zpui `input.Keystroke`: lowercase key
//! name + typed text + modifiers). `fromKeystroke` adapts any struct with
//! that shape so this module does not depend on zpui.
//!
//! Policy carried over from zeron's `view.rs` `keystroke_bytes`:
//! - platform-primary combos (Cmd on macOS, Super elsewhere) belong to the
//!   app keymap and are never sent to the PTY (`encode` returns null);
//! - Alt is a meta key (ESC prefix), including macOS Option.
const std = @import("std");
const builtin = @import("builtin");
const vt = @import("ghostty-vt");
const Emulator = @import("Emulator.zig");

/// Mirror of zpui `input.Modifiers`.
pub const Mods = packed struct(u8) {
    control: bool = false,
    alt: bool = false,
    shift: bool = false,
    platform: bool = false,
    function: bool = false,
    _pad: u3 = 0,
};

pub const Action = enum { press, repeat, release };

pub const KeyInput = struct {
    /// gpui key name: "a", "enter", "left", "f1", "pageup", "-", ...
    key: []const u8,
    /// Text the keystroke would insert under the current layout, if any.
    key_char: ?[]const u8 = null,
    mods: Mods = .{},
    action: Action = .press,
};

/// Adapt a zpui `input.Keystroke` (or anything with `key`, `key_char`,
/// `modifiers.{control,alt,shift,platform}`).
pub fn fromKeystroke(ks: anytype) KeyInput {
    return .{
        .key = ks.key,
        .key_char = ks.key_char,
        .mods = .{
            .control = ks.modifiers.control,
            .alt = ks.modifiers.alt,
            .shift = ks.modifiers.shift,
            .platform = ks.modifiers.platform,
            .function = if (@hasField(@TypeOf(ks.modifiers), "function")) ks.modifiers.function else false,
        },
    };
}

/// Encoder options derived from terminal state (cursor/keypad modes,
/// backarrow, modifyOtherKeys, Kitty flags).
pub fn optionsFor(emu: *const Emulator) vt.input.KeyEncodeOptions {
    var opts: vt.input.KeyEncodeOptions = .fromTerminal(&emu.terminal);
    // zeron treats Alt/Option as meta everywhere.
    opts.macos_option_as_alt = .true;
    return opts;
}

/// Encode into `buf`. Returns null when the keystroke is not ours (e.g. a
/// platform shortcut) or produces no bytes.
pub fn encode(emu: *const Emulator, input: KeyInput, buf: []u8) ?[]const u8 {
    return encodeWith(optionsFor(emu), input, buf);
}

pub fn encodeWith(opts: vt.input.KeyEncodeOptions, input: KeyInput, buf: []u8) ?[]const u8 {
    if (input.mods.platform) return null;
    if (legacyControl(opts, input, buf)) |out| return out;
    const event = toEvent(input) orelse return null;
    var w: std.Io.Writer = .fixed(buf);
    vt.input.encodeKey(&w, event, opts) catch return null;
    const out = w.buffered();
    if (out.len == 0) return null;
    return out;
}

/// zeron's caret-notation Ctrl table (view.rs `control_bytes`), applied in
/// legacy mode before Ghostty's encoder. Ghostty deliberately sends CSI-u
/// for ctrl+[ / ctrl+i / ctrl+m (to keep them distinct from Esc/Tab/Enter);
/// zeron users expect the classic C0 bytes, so plain-legacy terminals keep
/// them. Kitty/modifyOtherKeys modes go straight to Ghostty.
fn legacyControl(opts: vt.input.KeyEncodeOptions, input: KeyInput, buf: []u8) ?[]const u8 {
    if (!input.mods.control or input.mods.shift or input.action == .release) return null;
    if (opts.kitty_flags.int() != 0 or opts.modify_other_keys_state_2) return null;
    const byte: u8 = blk: {
        if (std.mem.eql(u8, input.key, "space")) break :blk 0x00;
        if (input.key.len != 1) return null;
        break :blk switch (input.key[0]) {
            'a'...'z' => |ch| ch - 'a' + 1,
            '@' => 0x00,
            '[' => 0x1b,
            '\\' => 0x1c,
            ']' => 0x1d,
            '^' => 0x1e,
            '_', '/' => 0x1f,
            '?' => 0x7f,
            else => return null,
        };
    };
    var n: usize = 0;
    if (input.mods.alt and opts.alt_esc_prefix) {
        if (buf.len < 2) return null;
        buf[0] = 0x1b;
        n = 1;
    }
    if (buf.len <= n) return null;
    buf[n] = byte;
    return buf[0 .. n + 1];
}

/// gpui key name -> W3C key code.
pub fn keyFromName(name: []const u8) ?vt.input.Key {
    const K = vt.input.Key;
    if (name.len == 1) {
        const ch = std.ascii.toLower(name[0]);
        if (K.fromASCII(ch)) |k| return k;
        return switch (name[0]) {
            // Shifted punctuation (layouts that report the shifted symbol).
            '!' => .digit_1,
            '@' => .digit_2,
            '#' => .digit_3,
            '$' => .digit_4,
            '%' => .digit_5,
            '^' => .digit_6,
            '&' => .digit_7,
            '*' => .digit_8,
            '(' => .digit_9,
            ')' => .digit_0,
            '_' => .minus,
            '+' => .equal,
            '{' => .bracket_left,
            '}' => .bracket_right,
            '|' => .backslash,
            ':' => .semicolon,
            '"' => .quote,
            '<' => .comma,
            '>' => .period,
            '?' => .slash,
            '~' => .backquote,
            else => null,
        };
    }
    const map = std.StaticStringMap(K).initComptime(.{
        .{ "enter", .enter },
        .{ "return", .enter },
        .{ "backspace", .backspace },
        .{ "tab", .tab },
        .{ "escape", .escape },
        .{ "space", .space },
        .{ "up", .arrow_up },
        .{ "down", .arrow_down },
        .{ "left", .arrow_left },
        .{ "right", .arrow_right },
        .{ "home", .home },
        .{ "end", .end },
        .{ "pageup", .page_up },
        .{ "pagedown", .page_down },
        .{ "insert", .insert },
        .{ "delete", .delete },
        .{ "f1", .f1 },
        .{ "f2", .f2 },
        .{ "f3", .f3 },
        .{ "f4", .f4 },
        .{ "f5", .f5 },
        .{ "f6", .f6 },
        .{ "f7", .f7 },
        .{ "f8", .f8 },
        .{ "f9", .f9 },
        .{ "f10", .f10 },
        .{ "f11", .f11 },
        .{ "f12", .f12 },
        .{ "f13", .f13 },
        .{ "f14", .f14 },
        .{ "f15", .f15 },
        .{ "f16", .f16 },
        .{ "f17", .f17 },
        .{ "f18", .f18 },
        .{ "f19", .f19 },
        .{ "f20", .f20 },
        .{ "menu", .context_menu },
        .{ "shift", .shift_left },
        .{ "control", .control_left },
        .{ "alt", .alt_left },
        .{ "platform", .meta_left },
        .{ "capslock", .caps_lock },
    });
    return map.get(name);
}

fn toEvent(input: KeyInput) ?vt.input.KeyEvent {
    const key = keyFromName(input.key) orelse .unidentified;
    var text: []const u8 = input.key_char orelse "";
    // Never forward control characters as "text"; the encoder derives
    // them from the key + mods.
    if (text.len == 1 and (text[0] < 0x20 or text[0] == 0x7f)) text = "";
    if (key == .unidentified and text.len == 0) {
        // Single-codepoint key names we don't map (non-ASCII layouts).
        if (std.unicode.utf8ValidateSlice(input.key) and
            (std.unicode.utf8CountCodepoints(input.key) catch 0) == 1) text = input.key else return null;
    }
    // Named keys never carry text (gpui sets key_char for enter/tab/space).
    switch (key) {
        .enter, .tab, .backspace, .escape, .delete, .arrow_up, .arrow_down, .arrow_left, .arrow_right, .home, .end, .page_up, .page_down, .insert => text = "",
        else => {},
    }
    if (key == .space and text.len == 0 and !input.mods.control) text = " ";
    // With Ctrl/Alt held, gpui reports the unmodified character in
    // key_char; let the encoder build the control/meta sequence.
    const mods: vt.input.KeyMods = .{
        .shift = input.mods.shift,
        .ctrl = input.mods.control,
        .alt = input.mods.alt,
        .super = input.mods.platform,
    };
    var unshifted: u21 = 0;
    if (key.codepoint()) |cp| unshifted = cp;
    if (unshifted == 0 and text.len > 0) {
        unshifted = std.unicode.utf8Decode(text[0..(std.unicode.utf8ByteSequenceLength(text[0]) catch 1)]) catch 0;
    }
    var consumed: vt.input.KeyMods = .{};
    if (text.len > 0 and input.mods.shift) consumed.shift = true;
    return .{
        .action = switch (input.action) {
            .press => .press,
            .repeat => .repeat,
            .release => .release,
        },
        .key = key,
        .mods = mods,
        .consumed_mods = consumed,
        .utf8 = text,
        .unshifted_codepoint = unshifted,
    };
}

// ---------------------------------------------------------------------------
// Tests (ported from zeron view.rs + Ghostty-mode coverage)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn enc(opts: vt.input.KeyEncodeOptions, key: []const u8, key_char: ?[]const u8, mods: Mods) ?[]const u8 {
    const S = struct {
        var buf: [128]u8 = undefined;
    };
    return encodeWith(opts, .{ .key = key, .key_char = key_char, .mods = mods }, &S.buf);
}

const legacy: vt.input.KeyEncodeOptions = blk: {
    var o: vt.input.KeyEncodeOptions = .default;
    o.alt_esc_prefix = true;
    o.macos_option_as_alt = .true;
    break :blk o;
};

fn expectBytes(expected: []const u8, actual: ?[]const u8) !void {
    try testing.expect(actual != null);
    try testing.expectEqualStrings(expected, actual.?);
}

test "printables prefer key_char" {
    try expectBytes("a", enc(legacy, "a", "a", .{}));
    try expectBytes("A", enc(legacy, "a", "A", .{ .shift = true }));
    try expectBytes("é", enc(legacy, "e", "é", .{}));
    try expectBytes("/", enc(legacy, "/", "/", .{}));
    try expectBytes("!", enc(legacy, "1", "!", .{ .shift = true }));
}

test "control keys and sequences" {
    try expectBytes("\r", enc(legacy, "enter", null, .{}));
    try expectBytes("\x7f", enc(legacy, "backspace", null, .{}));
    try expectBytes("\t", enc(legacy, "tab", null, .{}));
    try expectBytes("\x1b[Z", enc(legacy, "tab", null, .{ .shift = true }));
    try expectBytes("\x1b", enc(legacy, "escape", null, .{}));
    try expectBytes(" ", enc(legacy, "space", " ", .{}));
    try expectBytes("\x1b[2~", enc(legacy, "insert", null, .{}));
    try expectBytes("\x1b[3~", enc(legacy, "delete", null, .{}));
    try expectBytes("\x1b[5~", enc(legacy, "pageup", null, .{}));
    try expectBytes("\x1b[6~", enc(legacy, "pagedown", null, .{}));
    try expectBytes("\x1bOP", enc(legacy, "f1", null, .{}));
    try expectBytes("\x1bOS", enc(legacy, "f4", null, .{}));
    try expectBytes("\x1b[15~", enc(legacy, "f5", null, .{}));
    try expectBytes("\x1b[24~", enc(legacy, "f12", null, .{}));
}

test "arrows respect app cursor mode" {
    try expectBytes("\x1b[A", enc(legacy, "up", null, .{}));
    try expectBytes("\x1b[D", enc(legacy, "left", null, .{}));
    try expectBytes("\x1b[H", enc(legacy, "home", null, .{}));
    try expectBytes("\x1b[F", enc(legacy, "end", null, .{}));
    var app = legacy;
    app.cursor_key_application = true;
    try expectBytes("\x1bOA", enc(app, "up", null, .{}));
    try expectBytes("\x1bOB", enc(app, "down", null, .{}));
    try expectBytes("\x1bOC", enc(app, "right", null, .{}));
    try expectBytes("\x1bOD", enc(app, "left", null, .{}));
    try expectBytes("\x1bOH", enc(app, "home", null, .{}));
    try expectBytes("\x1bOF", enc(app, "end", null, .{}));
    // Modified arrows use the CSI 1;mod form regardless of DECCKM.
    try expectBytes("\x1b[1;5A", enc(app, "up", null, .{ .control = true }));
    try expectBytes("\x1b[1;2C", enc(legacy, "right", null, .{ .shift = true }));
}

test "ctrl combos map to control bytes" {
    try expectBytes("\x01", enc(legacy, "a", "a", .{ .control = true }));
    try expectBytes("\x03", enc(legacy, "c", "c", .{ .control = true }));
    try expectBytes("\x1a", enc(legacy, "z", "z", .{ .control = true }));
    try expectBytes("\x00", enc(legacy, "space", null, .{ .control = true }));
    try expectBytes("\x1b", enc(legacy, "[", "[", .{ .control = true }));
    try expectBytes("\x1c", enc(legacy, "\\", "\\", .{ .control = true }));
    try expectBytes("\x1d", enc(legacy, "]", "]", .{ .control = true }));
    try expectBytes("\x1f", enc(legacy, "/", "/", .{ .control = true }));
    try expectBytes("\x09", enc(legacy, "i", "i", .{ .control = true }));
    try expectBytes("\x0d", enc(legacy, "m", "m", .{ .control = true }));
    try expectBytes("\x7f", enc(legacy, "?", "?", .{ .control = true }));
}

test "alt prefixes escape" {
    try expectBytes("\x1bx", enc(legacy, "x", "x", .{ .alt = true }));
    try expectBytes("\x1b\r", enc(legacy, "enter", null, .{ .alt = true }));
    try expectBytes("\x1b\x01", enc(legacy, "a", "a", .{ .alt = true, .control = true }));
}

test "platform primary combos fall through" {
    try testing.expectEqual(@as(?[]const u8, null), enc(legacy, "c", "c", .{ .platform = true }));
    try testing.expectEqual(@as(?[]const u8, null), enc(legacy, "v", "v", .{ .platform = true }));
}

test "keypad application mode and backarrow" {
    var o = legacy;
    o.backarrow_key_mode = true;
    try expectBytes("\x08", enc(o, "backspace", null, .{}));
}

test "kitty keyboard protocol disambiguate" {
    var o = legacy;
    o.kitty_flags = .{ .disambiguate = true };
    try expectBytes("\x1b[27u", enc(o, "escape", null, .{}));
    try expectBytes("\x1b[99;5u", enc(o, "c", "c", .{ .control = true }));
    try expectBytes("a", enc(o, "a", "a", .{}));
    try expectBytes("\r", enc(o, "enter", null, .{}));
}

test "fromKeystroke adapts zpui-shaped keystrokes" {
    const Ks = struct {
        modifiers: struct { control: bool = false, alt: bool = false, shift: bool = false, platform: bool = false, function: bool = false } = .{},
        key: []const u8,
        key_char: ?[]const u8 = null,
    };
    const k = fromKeystroke(Ks{ .key = "a", .key_char = "a", .modifiers = .{ .control = true } });
    try testing.expect(k.mods.control);
    try expectBytes("\x01", encodeWith(legacy, k, &struct {
        var b: [16]u8 = undefined;
    }.b));
}
