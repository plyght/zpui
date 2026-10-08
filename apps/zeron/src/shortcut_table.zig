//! The app-level shortcuts the shortcut matrix test (ui/shell/shortcuts_test.zig) and
//! the macOS CI smoke (`ZERON_SMOKE_SHORTCUTS`, smoke.zig) drive: the default bindings
//! of keymap.zig (Rust `shell::apply_keymap` + `app_menus::app_key_bindings`) that work
//! from anywhere in the window, with what each must fire.

pub const Case = struct {
    /// `mod-` spelling: cmd on macOS, ctrl elsewhere.
    keys: []const u8,
    /// Spelled out when the platforms differ in more than `mod`.
    mac_keys: ?[]const u8 = null,
    action: []const u8,
    /// Fire twice so the window ends where it started (toggles).
    toggle: bool = false,
    /// Press escape afterwards (pickers / palettes).
    escape_after: bool = false,
    /// Part of the headless matrix (false: needs a real platform, e.g. the PTY).
    headless: bool = true,
    /// Bound on macOS only (Rust `app_key_bindings(macos)`).
    mac_only: bool = false,
};

pub const global = [_]Case{
    .{ .keys = "mod-b", .action = "shell::ToggleSidebar", .toggle = true },
    .{ .keys = "mod-r", .action = "shell::ToggleChanges", .toggle = true },
    .{ .keys = "mod-e", .action = "shell::ToggleFiles", .toggle = true },
    .{ .keys = "mod-j", .action = "terminal::ToggleTerminal", .toggle = true, .headless = false },
    .{ .keys = "mod-k", .action = "shell::ToggleCommandPalette", .toggle = true },
    .{ .keys = "mod-/", .action = "shell::OpenModelPicker", .escape_after = true },
    .{ .keys = "mod-,", .action = "shell::OpenSettings", .toggle = true },
    .{ .keys = "ctrl-tab", .action = "shell::NextSession" },
    .{ .keys = "ctrl-shift-tab", .action = "shell::PrevSession" },
    .{ .keys = "mod-1", .action = "shell::JumpSession" },
    .{ .keys = "mod-shift-n", .action = "shell::AddSpacePalette", .escape_after = true },
    .{ .keys = "mod-s", .action = "shell::SaveFile" },
};

/// The platform keystroke for `case` (static strings; `mod` resolved).
pub fn keysFor(comptime case: Case, comptime mac: bool) []const u8 {
    if (mac) if (case.mac_keys) |k| return k;
    comptime var out: []const u8 = "";
    comptime var rest: []const u8 = case.keys;
    inline while (true) {
        const ix = comptime std.mem.indexOf(u8, rest, "mod") orelse break;
        out = out ++ rest[0..ix] ++ (if (mac) "cmd" else "ctrl");
        rest = rest[ix + 3 ..];
    }
    return out ++ rest;
}

const std = @import("std");

test "keysFor resolves mod per platform" {
    try std.testing.expectEqualStrings("cmd-shift-n", comptime keysFor(global[10], true));
    try std.testing.expectEqualStrings("ctrl-shift-n", comptime keysFor(global[10], false));
    try std.testing.expectEqualStrings("ctrl-tab", comptime keysFor(global[7], true));
}
