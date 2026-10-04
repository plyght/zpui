//! Terminal color resolution against the zeron theme, ported from zeron's
//! `crates/ui/src/terminal/view.rs` (`resolve_color`,
//! `extended_indexed_rgb`):
//!
//! - default fg/bg and ANSI 0-15 come from the theme's terminal palette
//!   (`zeron_theme` `TerminalColors`);
//! - 16-231 is the xterm 6x6x6 cube, appearance independent;
//! - 232-255 is the grayscale ramp, mirrored in light mode so index 232
//!   stays the faintest and 255 the strongest on both backgrounds.
const std = @import("std");
const snapshot = @import("snapshot.zig");
const CellColor = snapshot.CellColor;
const Slot = snapshot.Slot;
pub const Rgb = snapshot.Rgb;

pub const Appearance = enum { dark, light };

pub const Palette = struct {
    foreground: Rgb,
    background: Rgb,
    /// Selection wash (with alpha, 0-255).
    selection: Rgb,
    selection_alpha: u8 = 255,
    cursor: ?Rgb = null,
    ansi: [16]Rgb,
    appearance: Appearance,

    /// Build from a zeron `theme.TerminalColors` (any struct with
    /// `background`, `foreground`, `selection` and `ansi: [16]` colors that
    /// have a `toRgba()` returning 0..1 floats, i.e. zpui `Hsla`).
    pub fn fromTheme(terminal_colors: anytype, appearance: Appearance) Palette {
        var ansi: [16]Rgb = undefined;
        for (&ansi, terminal_colors.ansi) |*dst, c| dst.* = rgbOf(c);
        const sel = terminal_colors.selection.toRgba();
        return .{
            .foreground = rgbOf(terminal_colors.foreground),
            .background = rgbOf(terminal_colors.background),
            .selection = rgbOf(terminal_colors.selection),
            .selection_alpha = to8(sel.a),
            .ansi = ansi,
            .appearance = appearance,
        };
    }

    /// Resolve a cell color painted into `slot`.
    pub fn resolve(self: *const Palette, color: CellColor, slot: Slot) Rgb {
        return switch (color) {
            .default => switch (slot) {
                .fg => self.foreground,
                .bg => self.background,
            },
            .indexed => |ix| if (ix < 16) self.ansi[ix] else extendedIndexed(self.appearance, ix),
            .rgb => |c| c,
        };
    }
};

fn to8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

fn rgbOf(c: anytype) Rgb {
    const rgba = c.toRgba();
    return .{ .r = to8(rgba.r), .g = to8(rgba.g), .b = to8(rgba.b) };
}

/// xterm 256-color cube component levels.
pub const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

/// Resolve the xterm extended range (16-255) to RGB (`index` >= 16).
pub fn extendedIndexed(appearance: Appearance, index: u8) Rgb {
    std.debug.assert(index >= 16);
    if (index <= 231) {
        const n: usize = index - 16;
        return .{ .r = cube_levels[n / 36], .g = cube_levels[(n / 6) % 6], .b = cube_levels[n % 6] };
    }
    var step: u8 = index - 232;
    if (appearance == .light) step = 23 - step;
    const v: u8 = 8 + 10 * step;
    return .{ .r = v, .g = v, .b = v };
}

/// zeron-dark terminal seeds (apps/zeron/src/theme/builtins.zig) for code
/// that does not load `zeron_theme` (tests). Foreground/selection are
/// approximations of the derived tokens; real UI code uses `fromTheme`.
pub const zeron_dark_fallback: Palette = .{
    .foreground = .{ .r = 0xe8, .g = 0xe8, .b = 0xea },
    .background = .{ .r = 0x09, .g = 0x09, .b = 0x09 },
    .selection = .{ .r = 0x8b, .g = 0x7c, .b = 0xf6 },
    .selection_alpha = 0x55,
    .ansi = .{
        .{ .r = 0x24, .g = 0x24, .b = 0x24 }, .{ .r = 0xf8, .g = 0x71, .b = 0x71 },
        .{ .r = 0x4a, .g = 0xde, .b = 0x80 }, .{ .r = 0xfa, .g = 0xcc, .b = 0x15 },
        .{ .r = 0x60, .g = 0xa5, .b = 0xfa }, .{ .r = 0xc0, .g = 0x84, .b = 0xfc },
        .{ .r = 0x22, .g = 0xd3, .b = 0xee }, .{ .r = 0xd4, .g = 0xd4, .b = 0xd8 },
        .{ .r = 0x52, .g = 0x52, .b = 0x5b }, .{ .r = 0xfc, .g = 0xa5, .b = 0xa5 },
        .{ .r = 0x86, .g = 0xef, .b = 0xac }, .{ .r = 0xfd, .g = 0xe0, .b = 0x47 },
        .{ .r = 0x93, .g = 0xc5, .b = 0xfd }, .{ .r = 0xd8, .g = 0xb4, .b = 0xfe },
        .{ .r = 0x67, .g = 0xe8, .b = 0xf9 }, .{ .r = 0xfa, .g = 0xfa, .b = 0xfa },
    },
    .appearance = .dark,
};

test "cube is appearance independent" {
    // zeron view.rs `cube_is_appearance_independent`
    for (16..232) |i| {
        const ix: u8 = @intCast(i);
        try std.testing.expectEqual(extendedIndexed(.dark, ix), extendedIndexed(.light, ix));
    }
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, extendedIndexed(.dark, 196));
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0 }, extendedIndexed(.dark, 16));
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 255, .b = 255 }, extendedIndexed(.dark, 231));
}

test "grayscale ramp mirrors in light" {
    // zeron view.rs `grayscale_ramp_mirrors_in_light`
    try std.testing.expectEqual(@as(u8, 8), extendedIndexed(.dark, 232).r);
    try std.testing.expectEqual(@as(u8, 238), extendedIndexed(.dark, 255).r);
    try std.testing.expectEqual(@as(u8, 238), extendedIndexed(.light, 232).r);
    try std.testing.expectEqual(@as(u8, 8), extendedIndexed(.light, 255).r);
}

test "resolve defaults, ansi, rgb" {
    const p = zeron_dark_fallback;
    try std.testing.expectEqual(p.foreground, p.resolve(.default, .fg));
    try std.testing.expectEqual(p.background, p.resolve(.default, .bg));
    try std.testing.expectEqual(p.ansi[1], p.resolve(.{ .indexed = 1 }, .fg));
    try std.testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, p.resolve(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .bg));
}
