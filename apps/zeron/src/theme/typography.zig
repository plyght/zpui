//! Typography: bundled families, the UI base-size setting and per-surface
//! text metrics (zeron `crates/ui/src/typography.rs` plus the size constants
//! of markdown/render.rs, composer.rs, changes.rs, terminal/view.rs, ...).
//!
//! UI text is authored at a 16px baseline and scales with the user's base size
//! (`uiRems`). Code, diff and terminal sizes are absolute pixels.

const std = @import("std");
const builtin = @import("builtin");

/// UI family (bundled Geist, SIL OFL 1.1).
pub const font_sans = "Geist";
/// Code and terminal family (bundled Geist Mono, SIL OFL 1.1).
pub const font_mono = "Geist Mono";
/// System fallbacks when a family fails to register.
pub const system_sans = switch (builtin.os.tag) {
    .macos => "Helvetica",
    .windows => "Segoe UI",
    else => "DejaVu Sans",
};
pub const system_mono = switch (builtin.os.tag) {
    .macos => "Menlo",
    .windows => "Consolas",
    else => "DejaVu Sans Mono",
};

/// CSS-style font weights (gpui `FontWeight`).
pub const Weight = enum(u16) {
    normal = 400,
    medium = 500,
    semibold = 600,
    bold = 700,
};

/// An interface font choice; persisted as `geist`, `geistMono`, `system` or
/// `installed:<family>`.
pub const UiFontFamily = union(enum) {
    geist,
    geist_mono,
    system,
    installed: []const u8,

    pub fn label(self: UiFontFamily) []const u8 {
        return switch (self) {
            .geist => "Geist",
            .geist_mono => "Geist Mono",
            .system => "System UI",
            .installed => |name| name,
        };
    }

    pub fn familyName(self: UiFontFamily) []const u8 {
        return switch (self) {
            .geist => "Geist",
            .geist_mono => "Geist Mono",
            .system => ".SystemUIFont",
            .installed => |name| name,
        };
    }

    /// Parse the persisted form; legacy catalog names map to installed
    /// families and anything unknown falls back to Geist. The result may
    /// borrow from `value`.
    pub fn parse(value: []const u8) UiFontFamily {
        const prefix = "installed:";
        if (std.mem.eql(u8, value, "geist")) return .geist;
        if (std.mem.eql(u8, value, "geistMono")) return .geist_mono;
        if (std.mem.eql(u8, value, "system")) return .system;
        if (std.mem.eql(u8, value, "inter")) return .{ .installed = "Inter" };
        if (std.mem.eql(u8, value, "atkinsonHyperlegibleNext")) return .{ .installed = "Atkinson Hyperlegible Next" };
        if (std.mem.startsWith(u8, value, prefix) and value.len > prefix.len) return .{ .installed = value[prefix.len..] };
        return .geist;
    }
};

/// Base size for rem-based interface text, persisted as a number of pixels.
pub const UiFontSize = struct {
    px: u8 = 16,

    pub const all = [_]UiFontSize{ .{ .px = 12 }, .{ .px = 13 }, .{ .px = 14 }, .{ .px = 15 }, .{ .px = 16 }, .{ .px = 18 }, .{ .px = 20 } };
    pub const default: UiFontSize = .{};

    pub fn pixels(self: UiFontSize) f32 {
        return @floatFromInt(self.px);
    }

    /// The nearest supported choice (ties pick the smaller).
    pub fn normalized(self: UiFontSize) UiFontSize {
        var best = all[0];
        for (all) |c| {
            if (absDiff(c.px, self.px) < absDiff(best.px, self.px)) best = c;
        }
        return best;
    }

    fn absDiff(a: u8, b: u8) u8 {
        return if (a > b) a - b else b - a;
    }
};

/// A size designed at the 16px baseline, in rems of the user's base size.
pub fn uiRems(pixels_at_default: f32) f32 {
    return pixels_at_default / 16.0;
}

/// A size designed at the 16px baseline, scaled to `base` in pixels.
pub fn uiPx(pixels_at_default: f32, base: UiFontSize) f32 {
    return uiRems(pixels_at_default) * base.pixels();
}

pub const code_font_size_default: f32 = 12.5;
pub const terminal_font_size_default: f32 = 13.0;
pub const font_size_min: f32 = 8.0;
pub const font_size_max: f32 = 32.0;

/// Clamp an absolute code/terminal size into the supported range.
pub fn clampFontSize(size: f32) f32 {
    return std.math.clamp(size, font_size_min, font_size_max);
}

/// Text size, line height and weight of one surface.
pub const TextStyle = struct {
    size: f32,
    line_height: f32,
    weight: Weight = .normal,
};

/// Markdown body (14/22) with a 12px block gap.
pub const markdown_body: TextStyle = .{ .size = 14, .line_height = 22 };
pub const markdown_block_gap: f32 = 12;

/// Markdown heading metrics by level (1-based; 4+ share the last entry).
pub fn markdownHeading(level: u8) TextStyle {
    return switch (level) {
        1 => .{ .size = 19, .line_height = 27, .weight = .semibold },
        2 => .{ .size = 16, .line_height = 24, .weight = .semibold },
        3 => .{ .size = 15, .line_height = 22, .weight = .semibold },
        else => .{ .size = 14, .line_height = 22, .weight = .semibold },
    };
}

/// Fenced code block: 12.5/18 (line height scales with the code size).
pub const code_block: TextStyle = .{ .size = 12.5, .line_height = 18 };
pub const code_line_height_ratio: f32 = 18.0 / 12.5;
/// Table header weight; cells use the body scale.
pub const table_header_weight: Weight = .bold;
/// User message bubble text.
pub const user_bubble: TextStyle = .{ .size = 14, .line_height = 22 };
/// Composer input.
pub const composer_input: TextStyle = .{ .size = 14, .line_height = 22.75 };
/// Tool rows in the transcript.
pub const tool_row: TextStyle = .{ .size = 12, .line_height = 18 };
/// Diff lines (mono).
pub const diff_line: TextStyle = .{ .size = 12, .line_height = 21 };
/// Terminal (mono).
pub const terminal: TextStyle = .{ .size = 13, .line_height = 18 };
/// Queue rows.
pub const queue_text_size: f32 = 12.5;
/// Menu rows and their uppercase section heading.
pub const menu_item_text_size: f32 = 13;
pub const menu_heading_size: f32 = 10;
pub const menu_heading_weight: Weight = .medium;
/// Settings rows.
pub const settings_row_title_size: f32 = 13;
pub const settings_row_description_size: f32 = 12;

const testing = std.testing;

test "font family persistence" {
    try testing.expectEqual(UiFontFamily.geist_mono, UiFontFamily.parse("geistMono"));
    try testing.expectEqualStrings("Inter", UiFontFamily.parse("inter").installed);
    try testing.expectEqualStrings("Fira Code", UiFontFamily.parse("installed:Fira Code").installed);
    try testing.expectEqual(UiFontFamily.geist, UiFontFamily.parse("installed:"));
}

test "font size normalization and rems" {
    try testing.expectEqual(@as(u8, 16), (UiFontSize{ .px = 17 }).normalized().px);
    try testing.expectEqual(@as(u8, 12), (UiFontSize{ .px = 3 }).normalized().px);
    try testing.expectEqual(@as(f32, 15), uiPx(12, .{ .px = 20 }));
    try testing.expectEqual(@as(f32, 32), clampFontSize(99));
}
