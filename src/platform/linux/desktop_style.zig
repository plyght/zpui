//! Which desktop the zpui-drawn native controls imitate on Linux
//! (`platform.DesktopTheme.style`, src/elements/desktop_controls.zig).
//!
//! `ZPUI_DESKTOP_STYLE=adwaita|gnome|breeze|kde|none` wins; otherwise
//! `XDG_CURRENT_DESKTOP` (a colon-separated list, e.g. `KDE`, `ubuntu:GNOME`) picks
//! Breeze when it names KDE, libadwaita for everything else (GNOME, Pantheon, Budgie,
//! wlroots compositors, an unset variable): GTK 4 / libadwaita is the de-facto look of
//! modern Linux settings windows outside Plasma.

const std = @import("std");
const platform = @import("../platform.zig");

pub const DesktopStyle = platform.DesktopStyle;

/// The style for `override` (`ZPUI_DESKTOP_STYLE`) and `current_desktop`
/// (`XDG_CURRENT_DESKTOP`).
pub fn resolve(override: ?[]const u8, current_desktop: ?[]const u8) DesktopStyle {
    if (override) |o| if (parseOverride(o)) |s| return s;
    if (current_desktop) |list| {
        var it = std.mem.tokenizeScalar(u8, list, ':');
        while (it.next()) |name| {
            if (std.ascii.eqlIgnoreCase(name, "KDE") or std.ascii.eqlIgnoreCase(name, "plasma")) return .breeze;
        }
    }
    return .adwaita;
}

fn parseOverride(raw: []const u8) ?DesktopStyle {
    const v = std.mem.trim(u8, raw, " \t");
    const table = [_]struct { []const u8, DesktopStyle }{
        .{ "adwaita", .adwaita }, .{ "gnome", .adwaita }, .{ "gtk", .adwaita },
        .{ "breeze", .breeze },   .{ "kde", .breeze },    .{ "plasma", .breeze },
        .{ "none", .none },       .{ "off", .none },      .{ "0", .none },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(v, e[0])) return e[1];
    return null;
}

/// `resolve` from the process environment.
pub fn fromProcess() DesktopStyle {
    const o = std.c.getenv("ZPUI_DESKTOP_STYLE");
    const d = std.c.getenv("XDG_CURRENT_DESKTOP");
    return resolve(if (o) |p| std.mem.span(p) else null, if (d) |p| std.mem.span(p) else null);
}

test "desktop style from XDG_CURRENT_DESKTOP and the override" {
    const t = std.testing;
    try t.expectEqual(DesktopStyle.adwaita, resolve(null, null));
    try t.expectEqual(DesktopStyle.adwaita, resolve(null, "ubuntu:GNOME"));
    try t.expectEqual(DesktopStyle.breeze, resolve(null, "KDE"));
    try t.expectEqual(DesktopStyle.breeze, resolve(null, "foo:kde"));
    try t.expectEqual(DesktopStyle.adwaita, resolve(null, "KDEish"));
    try t.expectEqual(DesktopStyle.breeze, resolve("kde", "GNOME"));
    try t.expectEqual(DesktopStyle.none, resolve("none", "KDE"));
    try t.expectEqual(DesktopStyle.breeze, resolve("bogus", "KDE"));
}
