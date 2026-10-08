//! Native menus for zeron's plain menus (macOS NSMenu via `zpui.showContextMenu`).
//!
//! A menu owner tries the native menu where it would open its drawn one, and keeps
//! the drawn menu as the fallback (Linux, tests, Settings → Appearance → Native menus
//! off):
//!
//! ```zig
//! const items = [_]native_menu.Item{ .action("Rename", 0), .separator, .{ .label = "Delete", .tag = 1, .destructive = true } };
//! if (native_menu.popUpAt(window, cx, ev.position, &items, cx.listener(onNativePick))) {
//!     self.menu_native = true; // keep the target, skip drawing
//! } else self.menu_open = true;
//! ...
//! fn onNativePick(self: *V, sel: *const native_menu.Selection, window: *Window, cx: *Context(V)) void {
//!     self.menu_native = false;
//!     const tag = sel.tag orelse return; // dismissed
//!     ... // run the same action the drawn row runs
//! }
//! ```
//!
//! Buttons ("⋯", view options, the account menu, ...) use `popUpBelow` with the click's
//! `targetBounds()`, so the menu drops from the trigger like an NSPopUpButton's.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const assets = @import("zeron_assets");
const theme_mod = @import("theme.zig");

const Window = zpui.Window;
const native_menus = model.native_menus;

pub const Item = zpui.ContextMenuItem;
pub const Selection = zpui.ContextMenuSelection;
pub const Listener = zpui.context_menu.Listener;
pub const Shortcut = zpui.context_menu.Shortcut;

/// Gap between a trigger's bottom edge and the menu.
pub const below_gap: f32 = 4;

/// Tests: exercise the native path off macOS (with a `TestWindow` that has
/// `native_menus` set).
pub var force_for_testing: bool = false;

/// Native menus popped up so far (the CI smoke checks a menu really was native).
pub var shown_count: std.atomic.Value(u32) = .init(0);

fn appOf(cx: anytype) *zpui.App {
    const T = @TypeOf(cx);
    if (T == *zpui.App) return cx;
    return cx.app;
}

/// Whether native menus are on for this app (macOS + the setting).
pub fn enabled(cx: anytype) bool {
    const app = appOf(cx);
    if (force_for_testing) return native_menus.stored(app);
    return native_menus.enabled(app);
}

/// Pop `items` up with their top-left at `position` (window coordinates). False when
/// native menus are off or unavailable here: draw the menu instead.
pub fn popUpAt(window: *Window, cx: anytype, position: zpui.Point(f32), items: []const Item, listener: Listener) bool {
    if (!enabled(cx)) return false;
    return popUpWith(window, cx, position, .top_left, items, listener);
}

fn popUpWith(window: *Window, cx: anytype, position: zpui.Point(f32), anchor: zpui.context_menu.Anchor, items: []const Item, listener: Listener) bool {
    if (!enabled(cx)) return false;
    const dark = theme_mod.get(cx).appearance.isDark();
    if (!zpui.context_menu.showWith(window, position, items, .{ .dark = dark, .anchor = anchor }, listener)) return false;
    _ = shown_count.fetchAdd(1, .release);
    return true;
}

/// Pop `items` up above `trigger` (left-aligned, opening upward): footer menus.
pub fn popUpAbove(window: *Window, cx: anytype, trigger: zpui.Bounds(f32), items: []const Item, listener: Listener) bool {
    if (trigger.size.width <= 0 and trigger.size.height <= 0) return popUpAt(window, cx, window.mousePosition(), items, listener);
    return popUpWith(window, cx, .{ .x = trigger.origin.x, .y = trigger.origin.y - below_gap }, .bottom_left, items, listener);
}

/// Pop `items` up under `trigger` (left-aligned, `below_gap` below its bottom edge).
/// A zero-sized `trigger` (unknown) falls back to the mouse position.
pub fn popUpBelow(window: *Window, cx: anytype, trigger: zpui.Bounds(f32), items: []const Item, listener: Listener) bool {
    if (trigger.size.width <= 0 and trigger.size.height <= 0) return popUpAt(window, cx, window.mousePosition(), items, listener);
    return popUpAt(window, cx, .{ .x = trigger.origin.x, .y = trigger.origin.y + trigger.size.height + below_gap }, items, listener);
}

/// Pop up from a click: under the clicked element for buttons, at the pointer otherwise.
pub fn popUpFromClick(window: *Window, cx: anytype, ev: *const zpui.ClickEvent, items: []const Item, listener: Listener) bool {
    return popUpBelow(window, cx, ev.targetBounds(), items, listener);
}

/// An icon's SVG source for `Item.icon`.
pub fn icon(i: assets.Icon) []const u8 {
    return i.svg();
}

/// Parse a drawn kbd hint ("⌘N", "⇧⌘↵", "⌘⌫", "Esc") into a displayed key equivalent;
/// null when it is not a single keystroke.
pub fn shortcutFromHint(hint: []const u8) ?Shortcut {
    var mods: zpui.input.Modifiers = .{};
    var rest = hint;
    const Prefix = struct { []const u8, enum { platform, shift, alt, control } };
    const prefixes = [_]Prefix{ .{ "⌘", .platform }, .{ "⇧", .shift }, .{ "⌥", .alt }, .{ "⌃", .control } };
    outer: while (rest.len > 0) {
        for (prefixes) |p| if (std.mem.startsWith(u8, rest, p[0])) {
            switch (p[1]) {
                .platform => mods.platform = true,
                .shift => mods.shift = true,
                .alt => mods.alt = true,
                .control => mods.control = true,
            }
            rest = rest[p[0].len..];
            continue :outer;
        };
        break;
    }
    if (rest.len == 0) return null;
    const named = [_]struct { []const u8, []const u8 }{
        .{ "↵", "enter" },    .{ "⏎", "enter" },  .{ "⌫", "backspace" }, .{ "⌦", "delete" },
        .{ "⎋", "escape" },   .{ "Esc", "escape" }, .{ "⇥", "tab" },     .{ "←", "left" },
        .{ "→", "right" },    .{ "↑", "up" },       .{ "↓", "down" },    .{ "Space", "space" },
        .{ "Enter", "enter" }, .{ "Tab", "tab" },
    };
    for (named) |n| if (std.mem.eql(u8, rest, n[0])) return .{ .key = n[1], .modifiers = mods };
    if (rest.len == 1 and std.ascii.isPrint(rest[0])) return .{ .key = lowerKey(rest[0]), .modifiers = mods };
    return null;
}

fn lowerKey(c: u8) []const u8 {
    const table = "abcdefghijklmnopqrstuvwxyz";
    if (std.ascii.isUpper(c)) {
        const i = c - 'A';
        return table[i .. i + 1];
    }
    const all = comptime blk: {
        var t: [128]u8 = undefined;
        for (&t, 0..) |*b, i| b.* = @intCast(i);
        break :blk t;
    };
    return all[c .. c + 1];
}

// ---- tests ----------------------------------------------------------------------

const testing = std.testing;

test "kbd hints become key equivalents" {
    const a = shortcutFromHint("⌘N").?;
    try testing.expectEqualStrings("n", a.key);
    try testing.expect(a.modifiers.platform and !a.modifiers.shift);
    const b = shortcutFromHint("⇧⌘↵").?;
    try testing.expectEqualStrings("enter", b.key);
    try testing.expect(b.modifiers.platform and b.modifiers.shift);
    try testing.expectEqualStrings("backspace", shortcutFromHint("⌘⌫").?.key);
    try testing.expectEqualStrings(",", shortcutFromHint("⌘,").?.key);
    try testing.expect(shortcutFromHint("") == null);
    try testing.expect(shortcutFromHint("⌘") == null);
    try testing.expect(shortcutFromHint("⌘K ⌘S") == null);
}
