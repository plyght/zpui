//! xkbcommon keyboard handling shared by the Wayland and X11 backends.
//!
//! `keyName` is a byte-for-byte port of gpui_linux's `keystroke_from_xkb` key naming
//! (platform.rs), `deadKeyChar` of `keystroke_underlying_dead_key`, and `Keyboard.press`
//! of the compose / dead-key flow in the Wayland `wl_keyboard::Key` handler.

const std = @import("std");
const c = @import("linux_c");
const input = @import("../../input.zig");

pub const Keysym = u32;

/// The keysyms gpui names explicitly (values from xkbcommon-keysyms.h).
pub const key = struct {
    pub const BackSpace: Keysym = 0xff08;
    pub const Tab: Keysym = 0xff09;
    pub const Return: Keysym = 0xff0d;
    pub const Escape: Keysym = 0xff1b;
    pub const Delete: Keysym = 0xffff;
    pub const Home: Keysym = 0xff50;
    pub const Left: Keysym = 0xff51;
    pub const Up: Keysym = 0xff52;
    pub const Right: Keysym = 0xff53;
    pub const Down: Keysym = 0xff54;
    pub const Prior: Keysym = 0xff55;
    pub const Next: Keysym = 0xff56;
    pub const End: Keysym = 0xff57;
    pub const Insert: Keysym = 0xff63;
    pub const Mode_switch: Keysym = 0xff7e;
    pub const Num_Lock: Keysym = 0xff7f;
    pub const KP_Space: Keysym = 0xff80;
    pub const KP_Prior: Keysym = 0xff9a;
    pub const KP_Next: Keysym = 0xff9b;
    pub const KP_Equal: Keysym = 0xffbd;
    pub const Shift_L: Keysym = 0xffe1;
    pub const Hyper_R: Keysym = 0xffee;
    pub const ISO_Lock: Keysym = 0xfe01;
    pub const ISO_Level5_Lock: Keysym = 0xfe13;
    pub const ISO_Left_Tab: Keysym = 0xfe20;
    pub const space: Keysym = 0x20;
    pub const XF86Back: Keysym = 0x1008ff26;
    pub const XF86Forward: Keysym = 0x1008ff27;
    pub const XF86Copy: Keysym = 0x1008ff57;
    pub const XF86Cut: Keysym = 0x1008ff58;
    pub const XF86New: Keysym = 0x1008ff68;
    pub const XF86Open: Keysym = 0x1008ff6b;
    pub const XF86Paste: Keysym = 0x1008ff6d;
    pub const XF86Save: Keysym = 0x1008ff77;
};

pub fn isKeypadKey(sym: Keysym) bool {
    return sym >= key.KP_Space and sym <= key.KP_Equal;
}

pub fn isModifierKey(sym: Keysym) bool {
    return (sym >= key.Shift_L and sym <= key.Hyper_R) or
        (sym >= key.ISO_Lock and sym <= key.ISO_Level5_Lock) or
        sym == key.Mode_switch or sym == key.Num_Lock;
}

/// US-layout fallback for non-Latin layouts (gpui `guess_ascii`), by X keycode.
pub fn guessAscii(keycode: u32, shift: bool) ?u8 {
    return switch (keycode) {
        24 => 'q',
        25 => 'w',
        26 => 'e',
        27 => 'r',
        28 => 't',
        29 => 'y',
        30 => 'u',
        31 => 'i',
        32 => 'o',
        33 => 'p',
        34 => if (shift) '{' else '[',
        35 => if (shift) '}' else ']',
        38 => 'a',
        39 => 's',
        40 => 'd',
        41 => 'f',
        42 => 'g',
        43 => 'h',
        44 => 'j',
        45 => 'k',
        46 => 'l',
        47 => if (shift) ':' else ';',
        48 => if (shift) '"' else '\'',
        49 => if (shift) '~' else '`',
        51 => if (shift) '|' else '\\',
        52 => 'z',
        53 => 'x',
        54 => 'c',
        55 => 'v',
        56 => 'b',
        57 => 'n',
        58 => 'm',
        // Sic: gpui maps shifted ',' to '>' and '.' to '<'.
        59 => if (shift) '>' else ',',
        60 => if (shift) '<' else '.',
        61 => if (shift) '?' else '/',
        else => null,
    };
}

/// Characters for printable ASCII keysyms gpui lists explicitly (keysym == codepoint).
const ascii_punct = ",.<>/?;:'\"[{]}\\|`~!@#$%^&*()-_=+";

/// Inputs to `keyName`, everything gpui reads from the xkb state for one key.
pub const KeyInfo = struct {
    keysym: Keysym,
    /// `xkb_keysym_get_name(keysym)`.
    keysym_name: []const u8,
    /// `xkb_state_key_get_utf8`.
    utf8: []const u8,
    /// `xkb_state_key_get_utf32`.
    utf32: u32,
    /// X keycode (evdev + 8).
    keycode: u32,
    shift: bool,
};

/// gpui key name for a key press. Returns a static string or a slice of `buf`.
pub fn keyName(buf: []u8, k: KeyInfo) []const u8 {
    switch (k.keysym) {
        key.Return => return "enter",
        key.Prior, key.KP_Prior => return "pageup",
        key.Next, key.KP_Next => return "pagedown",
        key.ISO_Left_Tab, key.Tab => return "tab",
        key.XF86Back => return "back",
        key.XF86Forward => return "forward",
        key.XF86Cut => return "cut",
        key.XF86Copy => return "copy",
        key.XF86Paste => return "paste",
        key.XF86New => return "new",
        key.XF86Open => return "open",
        key.XF86Save => return "save",
        key.space => return "space",
        key.BackSpace => return "backspace",
        key.Delete => return "delete",
        key.Escape => return "escape",
        key.Left => return "left",
        key.Right => return "right",
        key.Up => return "up",
        key.Down => return "down",
        key.Home => return "home",
        key.End => return "end",
        key.Insert => return "insert",
        else => {},
    }
    if (k.keysym < 0x80) {
        if (std.mem.indexOfScalar(u8, ascii_punct, @intCast(k.keysym))) |i| return ascii_punct[i .. i + 1];
    }

    const name = lowerInto(buf, k.keysym_name);
    if (isKeypadKey(k.keysym)) {
        // `name.replace("kp_", "")`
        if (std.mem.startsWith(u8, name, "kp_")) return name[3..];
        return name;
    }
    if (k.utf8.len == 1 and k.utf8[0] < 0x80) {
        const ch = k.utf8[0];
        if ((ch > 0x20 and ch < 0x7f)) {
            buf[0] = std.ascii.toLower(ch);
            return buf[0..1];
        }
        // ctrl-a arrives as 0x01: map it back to "a" (but not ctrl-digit control codes).
        if (k.utf32 <= 0x1f and !(name.len > 0 and std.ascii.isDigit(name[0]))) {
            buf[0] = std.ascii.toLower(@intCast(k.utf32 + 0x40));
            return buf[0..1];
        }
        return name;
    }
    if (guessAscii(k.keycode, k.shift)) |ch| {
        buf[0] = ch;
        return buf[0..1];
    }
    return name;
}

fn lowerInto(buf: []u8, s: []const u8) []u8 {
    const n = @min(buf.len, s.len);
    for (s[0..n], buf[0..n]) |ch, *o| o.* = std.ascii.toLower(ch);
    return buf[0..n];
}

/// gpui only keeps `shift` for keys whose name changes case (letters, "tab", "enter"...).
pub fn adjustShift(mods: input.Modifiers, name: []const u8) input.Modifiers {
    var m = mods;
    if (m.shift) {
        const view = std.unicode.Utf8View.init(name) catch return m;
        var it = view.iterator();
        const first = it.nextCodepoint() orelse return m;
        if (it.nextCodepoint() == null) {
            // A single char with no case distinction (digits, symbols) drops shift.
            const lower_eq_upper = if (first < 0x80)
                std.ascii.toLower(@intCast(first)) == std.ascii.toUpper(@intCast(first))
            else
                true;
            if (lower_eq_upper) m.shift = false;
        }
    }
    return m;
}

/// The character a dead key represents (gpui `keystroke_underlying_dead_key`).
pub fn deadKeyChar(sym: Keysym) ?[]const u8 {
    return switch (sym) {
        0xfe50 => "\u{60}",
        0xfe51 => "\u{b4}",
        0xfe52 => "\u{5e}",
        0xfe53 => "\u{7e}",
        0xfe54 => "\u{af}",
        0xfe55 => "\u{2d8}",
        0xfe56 => "\u{2d9}",
        0xfe57 => "\u{a8}",
        0xfe58 => "\u{2da}",
        0xfe59 => "\u{2dd}",
        0xfe5a => "\u{2c7}",
        0xfe5b => "\u{b8}",
        0xfe5c => "\u{2db}",
        0xfe5d => "\u{345}",
        0xfe5e => "\u{3099}",
        0xfe5f => "\u{309a}",
        0xfe60 => "\u{323}\u{323}",
        0xfe61 => "\u{321}",
        0xfe62 => "\u{31b}",
        0xfe63 => "\u{336}\u{336}",
        0xfe64 => "\u{313}\u{313}",
        0xfe65 => "\u{2bd}",
        0xfe66 => "\u{30f}",
        0xfe67 => "\u{2f3}",
        0xfe68 => "\u{331}",
        0xfe69 => "\u{a788}",
        0xfe6a => "\u{330}",
        0xfe6b => "\u{32e}",
        0xfe6c => "\u{324}",
        0xfe6d => "\u{32f}",
        0xfe6e => "\u{326}",
        0xfe8a => "\u{259}",
        0xfe8b => "\u{18f}",
        else => null,
    };
}

// ---------------------------------------------------------------------------------------
// xkbcommon state
// ---------------------------------------------------------------------------------------

/// A keystroke whose strings live in fixed buffers, so it can be copied (key repeat).
pub const OwnedKeystroke = struct {
    modifiers: input.Modifiers = .{},
    key_buf: [64]u8 = undefined,
    key_len: u8 = 0,
    char_buf: [64]u8 = undefined,
    char_len: ?u8 = null,

    pub fn keystroke(self: *const OwnedKeystroke) input.Keystroke {
        return .{
            .modifiers = self.modifiers,
            .key = self.key_buf[0..self.key_len],
            .key_char = if (self.char_len) |n| self.char_buf[0..n] else null,
        };
    }

    pub fn setKey(self: *OwnedKeystroke, s: []const u8) void {
        const n = @min(s.len, self.key_buf.len);
        @memcpy(self.key_buf[0..n], s[0..n]);
        self.key_len = @intCast(n);
    }

    pub fn setChar(self: *OwnedKeystroke, s: ?[]const u8) void {
        const v = s orelse {
            self.char_len = null;
            return;
        };
        const n = @min(v.len, self.char_buf.len);
        @memcpy(self.char_buf[0..n], v[0..n]);
        self.char_len = @intCast(n);
    }
};

/// What a key press asks the window to do, in order: IME insert, IME mark, key down.
pub const PressResult = struct {
    keystroke: OwnedKeystroke = .{},
    ime_insert: ?[]const u8 = null,
    ime_marked: ?[]const u8 = null,
    insert_buf: [64]u8 = undefined,
    marked_buf: [64]u8 = undefined,
};

pub const Keyboard = struct {
    context: *c.struct_xkb_context,
    keymap: ?*c.struct_xkb_keymap = null,
    state: ?*c.struct_xkb_state = null,
    compose_table: ?*c.struct_xkb_compose_table = null,
    compose: ?*c.struct_xkb_compose_state = null,
    /// Dead-key / compose preedit currently shown as marked text.
    pre_edit: ?OwnedKeystroke = null,

    pub fn init() !Keyboard {
        const ctx = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContext;
        return .{ .context = ctx };
    }

    pub fn deinit(k: *Keyboard) void {
        k.clearKeymap();
        c.xkb_context_unref(k.context);
    }

    fn clearKeymap(k: *Keyboard) void {
        if (k.compose) |s| c.xkb_compose_state_unref(s);
        if (k.compose_table) |t| c.xkb_compose_table_unref(t);
        if (k.state) |s| c.xkb_state_unref(s);
        if (k.keymap) |m| c.xkb_keymap_unref(m);
        k.compose = null;
        k.compose_table = null;
        k.state = null;
        k.keymap = null;
    }

    /// Installs a keymap and fresh state (takes ownership of both).
    pub fn setKeymap(k: *Keyboard, keymap: *c.struct_xkb_keymap, state: ?*c.struct_xkb_state) !void {
        k.clearKeymap();
        k.keymap = keymap;
        k.state = state orelse c.xkb_state_new(keymap) orelse return error.XkbState;
        k.initCompose();
    }

    /// Keymap from a text buffer (Wayland `wl_keyboard.keymap`).
    pub fn setKeymapFromString(k: *Keyboard, text: [*:0]const u8) !void {
        const keymap = c.xkb_keymap_new_from_string(k.context, text, c.XKB_KEYMAP_FORMAT_TEXT_V1, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.XkbKeymap;
        try k.setKeymap(keymap, null);
    }

    /// Keymap from RMLVO names (tests, headless).
    pub fn setKeymapFromNames(k: *Keyboard, layout: [*:0]const u8, variant: ?[*:0]const u8) !void {
        const names: c.struct_xkb_rule_names = .{ .rules = null, .model = null, .layout = layout, .variant = variant, .options = null };
        const keymap = c.xkb_keymap_new_from_names(k.context, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.XkbKeymap;
        try k.setKeymap(keymap, null);
    }

    /// Compose table from $LC_ALL / $LC_CTYPE / $LANG, falling back to "C" (gpui `get_xkb_compose_state`).
    fn initCompose(k: *Keyboard) void {
        const env_locale: ?[*:0]const u8 = blk: {
            for ([_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
                if (std.c.getenv(name)) |v| if (v[0] != 0) break :blk v;
            }
            break :blk null;
        };
        const candidates = [_]?[*:0]const u8{ env_locale, "C" };
        for (candidates) |loc| {
            const l = loc orelse continue;
            if (c.xkb_compose_table_new_from_locale(k.context, l, c.XKB_COMPOSE_COMPILE_NO_FLAGS)) |t| {
                k.compose_table = t;
                k.compose = c.xkb_compose_state_new(t, c.XKB_COMPOSE_STATE_NO_FLAGS);
                return;
            }
        }
    }

    pub fn updateMask(k: *Keyboard, depressed: u32, latched: u32, locked: u32, depressed_layout: u32, latched_layout: u32, locked_layout: u32) void {
        const s = k.state orelse return;
        _ = c.xkb_state_update_mask(s, depressed, latched, locked, depressed_layout, latched_layout, locked_layout);
    }

    pub fn layoutIndex(k: *const Keyboard) u32 {
        const s = k.state orelse return 0;
        return c.xkb_state_serialize_layout(s, c.XKB_STATE_LAYOUT_EFFECTIVE);
    }

    fn modActive(s: *c.struct_xkb_state, name: [*:0]const u8) bool {
        return c.xkb_state_mod_name_is_active(s, name, c.XKB_STATE_MODS_EFFECTIVE) > 0;
    }

    pub fn modifiers(k: *const Keyboard) input.Modifiers {
        const s = k.state orelse return .{};
        return .{
            .shift = modActive(s, c.XKB_MOD_NAME_SHIFT),
            .alt = modActive(s, c.XKB_MOD_NAME_ALT),
            .control = modActive(s, c.XKB_MOD_NAME_CTRL),
            .platform = modActive(s, c.XKB_MOD_NAME_LOGO),
        };
    }

    pub fn capslock(k: *const Keyboard) bool {
        const s = k.state orelse return false;
        return modActive(s, c.XKB_MOD_NAME_CAPS);
    }

    pub fn keysym(k: *const Keyboard, keycode: u32) Keysym {
        const s = k.state orelse return 0;
        return c.xkb_state_key_get_one_sym(s, keycode);
    }

    /// gpui `keystroke_from_xkb`.
    pub fn keystroke(k: *const Keyboard, mods: input.Modifiers, keycode: u32) OwnedKeystroke {
        var out: OwnedKeystroke = .{};
        const s = k.state orelse return out;
        const sym = c.xkb_state_key_get_one_sym(s, keycode);
        var utf8_buf: [64]u8 = undefined;
        const n = c.xkb_state_key_get_utf8(s, keycode, &utf8_buf, utf8_buf.len);
        const utf8 = utf8_buf[0..@intCast(@max(0, @min(n, utf8_buf.len - 1)))];
        const utf32 = c.xkb_state_key_get_utf32(s, keycode);
        var name_buf: [64]u8 = undefined;
        const name = keysymName(sym, &name_buf);

        var key_buf: [64]u8 = undefined;
        const kname = keyName(&key_buf, .{ .keysym = sym, .keysym_name = name, .utf8 = utf8, .utf32 = utf32, .keycode = keycode, .shift = mods.shift });
        out.setKey(kname);
        out.modifiers = adjustShift(mods, kname);
        // Control characters (and DEL) never produce key_char.
        out.setChar(if (utf32 >= 32 and utf32 != 127 and utf8.len > 0) utf8 else null);
        return out;
    }

    /// Key press with compose / dead-key handling (gpui wayland `wl_keyboard::Key`).
    pub fn press(k: *Keyboard, mods: input.Modifiers, keycode: u32, out: *PressResult) void {
        out.* = .{ .keystroke = k.keystroke(mods, keycode) };
        const compose = k.compose orelse return;
        const sym = k.keysym(keycode);
        _ = c.xkb_compose_state_feed(compose, sym);
        switch (c.xkb_compose_state_get_status(compose)) {
            c.XKB_COMPOSE_COMPOSING => {
                out.keystroke.setChar(null);
                var tmp: [64]u8 = undefined;
                const composed = composeUtf8(compose, &tmp);
                const text = if (composed.len > 0) composed else deadKeyChar(sym) orelse "";
                k.pre_edit = .{};
                k.pre_edit.?.setKey(text);
                out.ime_marked = copyInto(&out.marked_buf, text);
            },
            c.XKB_COMPOSE_COMPOSED => {
                k.pre_edit = null;
                var tmp: [64]u8 = undefined;
                out.keystroke.setChar(composeUtf8(compose, &tmp));
                const csym = c.xkb_compose_state_get_one_sym(compose);
                if (csym != 0) {
                    var name_buf: [64]u8 = undefined;
                    out.keystroke.setKey(keysymName(csym, &name_buf));
                }
            },
            c.XKB_COMPOSE_CANCELLED => {
                if (k.pre_edit) |*p| out.ime_insert = copyInto(&out.insert_buf, p.key_buf[0..p.key_len]);
                k.pre_edit = null;
                if (deadKeyChar(sym)) |d| {
                    k.pre_edit = .{};
                    k.pre_edit.?.setKey(d);
                    out.ime_marked = copyInto(&out.marked_buf, d);
                }
                _ = c.xkb_compose_state_feed(compose, sym);
            },
            else => {},
        }
    }

    /// Focus lost: forget any half-typed compose sequence.
    pub fn resetCompose(k: *Keyboard) void {
        if (k.compose) |s| c.xkb_compose_state_reset(s);
        k.pre_edit = null;
    }
};

fn copyInto(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

fn composeUtf8(s: *c.struct_xkb_compose_state, buf: *[64]u8) []const u8 {
    const n = c.xkb_compose_state_get_utf8(s, buf, buf.len);
    return buf[0..@intCast(@max(0, @min(n, buf.len - 1)))];
}

pub fn keysymName(sym: Keysym, buf: *[64]u8) []const u8 {
    const n = c.xkb_keysym_get_name(sym, buf, buf.len);
    return buf[0..@intCast(@max(0, @min(n, buf.len - 1)))];
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;

fn nameOf(info: KeyInfo) []const u8 {
    const S = struct {
        var buf: [64]u8 = undefined;
    };
    return keyName(&S.buf, info);
}

test "keyName: named keys and punctuation" {
    const base: KeyInfo = .{ .keysym = 0, .keysym_name = "", .utf8 = "", .utf32 = 0, .keycode = 0, .shift = false };
    var k = base;
    k.keysym = key.Return;
    try testing.expectEqualStrings("enter", nameOf(k));
    k.keysym = key.ISO_Left_Tab;
    try testing.expectEqualStrings("tab", nameOf(k));
    k.keysym = key.KP_Prior;
    try testing.expectEqualStrings("pageup", nameOf(k));
    k.keysym = key.XF86Paste;
    try testing.expectEqualStrings("paste", nameOf(k));
    k.keysym = ',';
    try testing.expectEqualStrings(",", nameOf(k));
    k.keysym = '+';
    try testing.expectEqualStrings("+", nameOf(k));
    k.keysym = key.space;
    try testing.expectEqualStrings("space", nameOf(k));
}

test "keyName: letters, ctrl codes, keypad, function keys, non-latin fallback" {
    // Shift+A: utf8 "A" -> lowercased name "a".
    try testing.expectEqualStrings("a", nameOf(.{ .keysym = 'A', .keysym_name = "A", .utf8 = "A", .utf32 = 'A', .keycode = 38, .shift = true }));
    // Ctrl+A yields U+0001.
    try testing.expectEqualStrings("a", nameOf(.{ .keysym = 'a', .keysym_name = "a", .utf8 = "\x01", .utf32 = 1, .keycode = 38, .shift = false }));
    // Ctrl+2 may yield U+0000: keep the keysym name "2".
    try testing.expectEqualStrings("2", nameOf(.{ .keysym = '2', .keysym_name = "2", .utf8 = "\x00", .utf32 = 0, .keycode = 11, .shift = false }));
    try testing.expectEqualStrings("5", nameOf(.{ .keysym = 0xffb5, .keysym_name = "KP_5", .utf8 = "5", .utf32 = '5', .keycode = 84, .shift = false }));
    try testing.expectEqualStrings("f5", nameOf(.{ .keysym = 0xffc2, .keysym_name = "F5", .utf8 = "", .utf32 = 0, .keycode = 71, .shift = false }));
    // Cyrillic "ф" on the 'a' key falls back to the US letter.
    try testing.expectEqualStrings("a", nameOf(.{ .keysym = 0x6c6, .keysym_name = "Cyrillic_ef", .utf8 = "ф", .utf32 = 0x444, .keycode = 38, .shift = false }));
    // Non-latin key without a US fallback keeps the lowercased keysym name.
    try testing.expectEqualStrings("cyrillic_io", nameOf(.{ .keysym = 0x6a3, .keysym_name = "Cyrillic_io", .utf8 = "ё", .utf32 = 0x451, .keycode = 200, .shift = false }));
}

test "adjustShift keeps shift only for case-changing names" {
    const shifted: input.Modifiers = .{ .shift = true };
    try testing.expect(!adjustShift(shifted, "1").shift);
    try testing.expect(!adjustShift(shifted, "!").shift);
    try testing.expect(adjustShift(shifted, "a").shift);
    try testing.expect(adjustShift(shifted, "tab").shift);
}

test "deadKeyChar and modifier keysyms" {
    try testing.expectEqualStrings("\u{b4}", deadKeyChar(0xfe51).?);
    try testing.expect(deadKeyChar(0xfe80) == null);
    try testing.expect(isModifierKey(key.Shift_L));
    try testing.expect(isModifierKey(key.Num_Lock));
    try testing.expect(!isModifierKey('a'));
}

test "Keyboard with a real us keymap" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.setKeymapFromNames("us", null) catch return error.SkipZigTest; // no xkb data installed
    // evdev KEY_A = 30 -> X keycode 38.
    var ks = kb.keystroke(.{}, 38);
    try testing.expectEqualStrings("a", ks.keystroke().key);
    try testing.expectEqualStrings("a", ks.keystroke().key_char.?);
    ks = kb.keystroke(.{}, 36); // Return
    try testing.expectEqualStrings("enter", ks.keystroke().key);
    try testing.expect(ks.keystroke().key_char == null);
    ks = kb.keystroke(.{}, 67); // F1
    try testing.expectEqualStrings("f1", ks.keystroke().key);

    // Shift held via the modifier mask: "A" -> key "a", key_char "A", shift kept.
    const shift_mask = @as(u32, 1) << @intCast(c.xkb_keymap_mod_get_index(kb.keymap.?, c.XKB_MOD_NAME_SHIFT));
    kb.updateMask(shift_mask, 0, 0, 0, 0, 0);
    try testing.expect(kb.modifiers().shift);
    ks = kb.keystroke(kb.modifiers(), 38);
    try testing.expectEqualStrings("a", ks.keystroke().key);
    try testing.expectEqualStrings("A", ks.keystroke().key_char.?);
    try testing.expect(ks.modifiers.shift);
    ks = kb.keystroke(kb.modifiers(), 10); // Shift+1 = "!"
    try testing.expectEqualStrings("!", ks.keystroke().key);
    try testing.expect(!ks.modifiers.shift);
}

test "Keyboard dead keys compose (us intl)" {
    var kb = try Keyboard.init();
    defer kb.deinit();
    kb.setKeymapFromNames("us", "intl") catch return error.SkipZigTest;
    if (kb.compose == null) return error.SkipZigTest;
    var r: PressResult = undefined;
    // us(intl): the apostrophe key (keycode 48) is dead_acute.
    kb.press(.{}, 48, &r);
    try testing.expectEqualStrings("\u{b4}", r.ime_marked.?);
    try testing.expect(r.keystroke.char_len == null);
    kb.press(.{}, 26, &r); // 'e'
    try testing.expectEqualStrings("é", r.keystroke.keystroke().key_char.?);
    try testing.expect(kb.pre_edit == null);
}
