//! The theme-related subset of zeron's `ui-settings.json` (owned by
//! `crates/ui/src/settings.rs`; field names are camelCase serde names).
//!
//! ```json
//! { "appearance": "system",
//!   "themeSelection": { "light": "zeron-light", "dark": "tokyo-night" },
//!   "accent": "themeDefault",          // or { "preset": "cyan" }
//!   "surface": "themeDefault",         // "frosted" | "opaque"
//!   "wallpaperThemeColors": false, "wallpaperColor": "#14408c",
//!   "uiFontFamily": "geist", "uiFontSize": 16,
//!   "codeFontFamily": "geistMono", "codeFontSize": 12.5,
//!   "terminalFontFamily": "geistMono", "terminalFontSize": 13,
//!   "reduceMotion": "system", "pauseAnimationsInBackground": false }
//! ```
//!
//! Parsing is lenient per field: a missing or malformed value keeps its
//! default, and unrelated settings are ignored. The legacy `accentColor` key
//! (with its old aliases) migrates into `accent` once.

const std = @import("std");
const model = @import("model.zig");
const motion = @import("motion.zig");
const typography = @import("typography.zig");

/// The user's appearance preference.
pub const AppearanceMode = enum {
    system,
    light,
    dark,

    pub fn label(self: AppearanceMode) []const u8 {
        return switch (self) {
            .system => "System",
            .light => "Light",
            .dark => "Dark",
        };
    }

    /// The effective appearance given what the OS reports.
    pub fn resolve(self: AppearanceMode, system: model.Appearance) model.Appearance {
        return switch (self) {
            .system => system,
            .light => .light,
            .dark => .dark,
        };
    }
};

pub const ThemeSettings = struct {
    appearance: AppearanceMode = .system,
    theme_selection: model.ThemeSelection = .{},
    accent: model.AccentSelection = .theme_default,
    surface: model.SurfacePreference = .theme_default,
    wallpaper_theme_colors: bool = false,
    wallpaper_color: ?model.Color = null,
    ui_font_family: typography.UiFontFamily = .geist,
    ui_font_size: typography.UiFontSize = .default,
    code_font_family: typography.UiFontFamily = .geist_mono,
    code_font_size: f32 = typography.code_font_size_default,
    terminal_font_family: typography.UiFontFamily = .geist_mono,
    terminal_font_size: f32 = typography.terminal_font_size_default,
    reduce_motion: motion.ReduceMotion = .system,
    pause_animations_in_background: bool = false,

    /// Parse from the full ui-settings.json text. Strings are copied into
    /// `arena`; free them by freeing the arena.
    pub fn parse(arena: std.mem.Allocator, json: []const u8) !ThemeSettings {
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{ .allocate = .alloc_always });
        if (root != .object) return error.InvalidSettings;
        const obj = root.object;
        var out: ThemeSettings = .{};
        if (enumField(AppearanceMode, obj, "appearance")) |v| out.appearance = v;
        if (obj.get("themeSelection")) |sel| if (sel == .object) {
            if (stringField(sel.object, "light")) |s| out.theme_selection.light = s;
            if (stringField(sel.object, "dark")) |s| out.theme_selection.dark = s;
        };
        if (obj.get("accent")) |v| if (parseAccent(v)) |a| {
            out.accent = a;
        };
        if (out.accent == .theme_default) {
            if (stringField(obj, "accentColor")) |s| if (legacyAccent(s)) |p| {
                out.accent = .{ .preset = p };
            };
        }
        if (stringField(obj, "surface")) |s| if (parseSurface(s)) |p| {
            out.surface = p;
        };
        if (boolField(obj, "wallpaperThemeColors")) |b| out.wallpaper_theme_colors = b;
        if (stringField(obj, "wallpaperColor")) |s| out.wallpaper_color = model.Color.parse(s) catch null;
        if (stringField(obj, "uiFontFamily")) |s| out.ui_font_family = .parse(s);
        if (numberField(obj, "uiFontSize")) |n| if (n >= 0 and n <= 255) {
            out.ui_font_size = .{ .px = @intFromFloat(n) };
        };
        if (stringField(obj, "codeFontFamily")) |s| out.code_font_family = .parse(s);
        if (numberField(obj, "codeFontSize")) |n| out.code_font_size = typography.clampFontSize(@floatCast(n));
        if (stringField(obj, "terminalFontFamily")) |s| out.terminal_font_family = .parse(s);
        if (numberField(obj, "terminalFontSize")) |n| out.terminal_font_size = typography.clampFontSize(@floatCast(n));
        if (enumField(motion.ReduceMotion, obj, "reduceMotion")) |v| out.reduce_motion = v;
        if (boolField(obj, "pauseAnimationsInBackground")) |b| out.pause_animations_in_background = b;
        return out;
    }

    /// The wallpaper overlay color in effect (needs the option and a color;
    /// zeron additionally requires a new-thread background image).
    pub fn effectiveWallpaperColor(self: ThemeSettings, has_background: bool) ?model.Color {
        return if (self.wallpaper_theme_colors and has_background) self.wallpaper_color else null;
    }

    /// Write these fields as JSON object members (no surrounding braces), in
    /// zeron's serialization format.
    pub fn writeFields(self: ThemeSettings, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("\"appearance\":\"{s}\",\"themeSelection\":{{\"light\":", .{@tagName(self.appearance)});
        try std.json.Stringify.encodeJsonString(self.theme_selection.light, .{}, w);
        try w.writeAll(",\"dark\":");
        try std.json.Stringify.encodeJsonString(self.theme_selection.dark, .{}, w);
        try w.writeAll("},\"accent\":");
        switch (self.accent) {
            .theme_default => try w.writeAll("\"themeDefault\""),
            .preset => |p| try w.print("{{\"preset\":\"{s}\"}}", .{@tagName(p)}),
        }
        try w.print(",\"surface\":\"{s}\",\"wallpaperThemeColors\":{},\"wallpaperColor\":", .{ surfaceName(self.surface), self.wallpaper_theme_colors });
        if (self.wallpaper_color) |c| try w.print("\"{f}\"", .{c}) else try w.writeAll("null");
        try w.writeAll(",\"uiFontFamily\":");
        try writeFamily(w, self.ui_font_family);
        try w.print(",\"uiFontSize\":{d},\"terminalFontFamily\":", .{self.ui_font_size.px});
        try writeFamily(w, self.terminal_font_family);
        try w.print(",\"terminalFontSize\":{d},\"codeFontFamily\":", .{self.terminal_font_size});
        try writeFamily(w, self.code_font_family);
        try w.print(",\"codeFontSize\":{d},\"reduceMotion\":\"{s}\",\"pauseAnimationsInBackground\":{}", .{
            self.code_font_size, @tagName(self.reduce_motion), self.pause_animations_in_background,
        });
    }
};

fn writeFamily(w: *std.Io.Writer, f: typography.UiFontFamily) std.Io.Writer.Error!void {
    switch (f) {
        .geist => try w.writeAll("\"geist\""),
        .geist_mono => try w.writeAll("\"geistMono\""),
        .system => try w.writeAll("\"system\""),
        .installed => |name| {
            var buf: [256]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "installed:{s}", .{name}) catch name;
            try std.json.Stringify.encodeJsonString(s, .{}, w);
        },
    }
}

fn surfaceName(s: model.SurfacePreference) []const u8 {
    return switch (s) {
        .theme_default => "themeDefault",
        .frosted => "frosted",
        .opaque_ => "opaque",
        .liquid => "liquid", // [liquid-glass]
    };
}

fn parseSurface(s: []const u8) ?model.SurfacePreference {
    inline for (comptime std.enums.values(model.SurfacePreference)) |p| {
        if (std.mem.eql(u8, s, surfaceName(p))) return p;
    }
    return null;
}

fn parseAccent(v: std.json.Value) ?model.AccentSelection {
    switch (v) {
        .string => |s| if (std.mem.eql(u8, s, "themeDefault")) return .theme_default,
        .object => |o| if (o.count() == 1) if (stringField(o, "preset")) |s| {
            if (std.meta.stringToEnum(model.AccentPreset, s)) |p| return .{ .preset = p };
        },
        else => {},
    }
    return null;
}

/// The pre-theme `accentColor` key and its preview-era aliases.
fn legacyAccent(s: []const u8) ?model.AccentPreset {
    for ([_][]const u8{ "violet", "indigo", "red", "purple" }) |alias| {
        if (std.mem.eql(u8, s, alias)) return .zeron;
    }
    if (std.mem.eql(u8, s, "teal")) return .cyan;
    return std.meta.stringToEnum(model.AccentPreset, s);
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn numberField(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn enumField(comptime E: type, obj: std.json.ObjectMap, key: []const u8) ?E {
    return std.meta.stringToEnum(E, stringField(obj, key) orelse return null);
}

const testing = std.testing;

test "parse theme settings" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try ThemeSettings.parse(arena.allocator(),
        \\{"sidebarWidth": 300, "appearance": "dark",
        \\ "themeSelection": {"light": "github-light", "dark": "tokyo-night"},
        \\ "accent": {"preset": "cyan"}, "surface": "opaque",
        \\ "wallpaperThemeColors": true, "wallpaperColor": "#14408c",
        \\ "uiFontFamily": "installed:Inter", "uiFontSize": 14, "codeFontSize": 99,
        \\ "reduceMotion": "on", "pauseAnimationsInBackground": true}
    );
    try testing.expectEqual(AppearanceMode.dark, s.appearance);
    try testing.expectEqualStrings("tokyo-night", s.theme_selection.variantId(.dark));
    try testing.expectEqualStrings("github-light", s.theme_selection.light);
    try testing.expect(s.accent.eql(.{ .preset = .cyan }));
    try testing.expectEqual(model.SurfacePreference.opaque_, s.surface);
    try testing.expect(s.wallpaper_color.?.eql(.rgb(0x14, 0x40, 0x8c)));
    try testing.expectEqualStrings("Inter", s.ui_font_family.installed);
    try testing.expectEqual(@as(u8, 14), s.ui_font_size.px);
    try testing.expectEqual(@as(f32, 32), s.code_font_size);
    try testing.expectEqual(motion.ReduceMotion.on, s.reduce_motion);
    try testing.expect(s.effectiveWallpaperColor(true) != null and s.effectiveWallpaperColor(false) == null);
}

test "defaults and legacy accent migration" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const empty = try ThemeSettings.parse(arena.allocator(), "{}");
    try testing.expectEqualStrings("zeron-dark", empty.theme_selection.dark);
    try testing.expect(empty.accent == .theme_default);
    const legacy = try ThemeSettings.parse(arena.allocator(), "{\"accentColor\":\"teal\",\"surface\":42}");
    try testing.expect(legacy.accent.eql(.{ .preset = .cyan }));
    try testing.expectEqual(model.SurfacePreference.theme_default, legacy.surface);
    const violet = try ThemeSettings.parse(arena.allocator(), "{\"accentColor\":\"violet\"}");
    try testing.expect(violet.accent.eql(.{ .preset = .zeron }));
}

test "write fields round trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s: ThemeSettings = .{ .appearance = .light, .accent = .{ .preset = .pink }, .surface = .frosted, .wallpaper_color = .rgb(1, 2, 3), .code_font_family = .{ .installed = "Fira Code" } };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeByte('{');
    try s.writeFields(&w);
    try w.writeByte('}');
    const back = try ThemeSettings.parse(arena.allocator(), w.buffered());
    try testing.expectEqual(AppearanceMode.light, back.appearance);
    try testing.expect(back.accent.eql(.{ .preset = .pink }));
    try testing.expectEqual(model.SurfacePreference.frosted, back.surface);
    try testing.expect(back.wallpaper_color.?.eql(.rgb(1, 2, 3)));
    try testing.expectEqualStrings("Fira Code", back.code_font_family.installed);
}

// [liquid-glass]
test "liquid surface preference round trips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s: ThemeSettings = .{ .surface = .liquid };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeByte('{');
    try s.writeFields(&w);
    try w.writeByte('}');
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"surface\":\"liquid\"") != null);
    const back = try ThemeSettings.parse(arena.allocator(), w.buffered());
    try testing.expectEqual(model.SurfacePreference.liquid, back.surface);
}
