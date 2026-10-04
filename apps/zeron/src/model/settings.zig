//! UI settings persisted to `{data_dir}/ui-settings.json` — port of zeron
//! `crates/ui/src/settings.rs` (the persistence/data half; the gpui
//! `SettingsStore` global is `settings_store.zig`).
//!
//! - `UiSettings`: every non-theme field, with the exact serde (camelCase)
//!   names and defaults; the theme subset is `zeron_theme.ThemeSettings`
//!   (`theme` field), parsed from and written into the same JSON object.
//! - `load`/`save`: Rust's migrations (appshot sound, `filesEditorFontSize`,
//!   the `saveFile` keymap migration, free-combo defaults for newer shortcuts),
//!   whole-file fallback to defaults on a type error (serde behavior), then
//!   `clamped()`; atomic temp-file + rename on save.
//! - `ShortcutId` / `KeymapConfig` + combo helpers (`platformCombo`,
//!   `displayCombo`, `badgeCombo`, `comboFromKeystroke`, conflict detection).
//! - `dataDir`: `apps/zeron/src/paths.rs` resolution.
//!
//! Strings are borrowed from an arena the caller owns (`Loaded.arena`).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const json = std.json;
const Io = std.Io;
const zt = @import("zeron_theme");
const protocol = @import("zeron_engine").protocol;
const view = @import("view.zig");

pub const ThemeSettings = zt.ThemeSettings;
pub const SidebarSection = protocol.SidebarSection;

pub const is_mac = builtin.os.tag == .macos;
/// Appshots exist on macOS and Linux (Rust `cfg_attr(not(any(macos, linux)), serde(skip))`).
pub const appshots_platform = builtin.os.tag == .macos or builtin.os.tag == .linux;

pub const file_name = "ui-settings.json";
pub const new_thread_background_dir = "new-thread-backgrounds";

pub const sidebar_min: f32 = 224.0;
pub const sidebar_max: f32 = 400.0;
pub const sidebar_default: f32 = 256.0;
pub const files_panel_default: f32 = 286.0;
pub const files_panel_min: f32 = 220.0;
pub const files_panel_max: f32 = 440.0;
pub const right_pane_min: f32 = 360.0;
pub const right_pane_default: f32 = 520.0;
pub const chat_panel_min: f32 = 300.0;
pub const terminal_min_height: f32 = 160.0;
pub const terminal_max_vh: f32 = 0.55;
pub const terminal_abs_max_height: f32 = 2000.0;
pub const terminal_default_height: f32 = 280.0;
pub const save_debounce_ms: u64 = 400;
pub const files_autosave_delay_default_ms: u64 = 900;
pub const files_autosave_delay_min_ms: u64 = 100;
pub const files_autosave_delay_max_ms: u64 = 10_000;
pub const transcript_width_min: f32 = 560.0;
pub const transcript_width_max: f32 = 1200.0;
pub const transcript_width_default: f32 = 736.0;
pub const transcript_width_step: f32 = 16.0;

pub fn clampOr(value: f32, min: f32, max: f32, default: f32) f32 {
    return if (std.math.isFinite(value)) std.math.clamp(value, min, max) else default;
}

fn minOr(value: f32, min: f32, default: f32) f32 {
    return if (std.math.isFinite(value)) @max(value, min) else default;
}

pub fn normalizeTranscriptWidth(width: f32) f32 {
    const w = clampOr(width, transcript_width_min, transcript_width_max, transcript_width_default);
    return transcript_width_min + @round((w - transcript_width_min) / transcript_width_step) * transcript_width_step;
}

// ---------------------------------------------------------------------------
// Small enums / structs
// ---------------------------------------------------------------------------

pub const NewThreadBackgroundAdjustment = struct {
    focalX: f32 = 0.5,
    focalY: f32 = 0.5,
    zoom: f32 = 1.0,

    pub const min_zoom: f32 = 1.0;
    pub const max_zoom: f32 = 4.0;

    pub fn normalized(self: NewThreadBackgroundAdjustment) NewThreadBackgroundAdjustment {
        return .{
            .focalX = clampOr(self.focalX, 0, 1, 0.5),
            .focalY = clampOr(self.focalY, 0, 1, 0.5),
            .zoom = clampOr(self.zoom, min_zoom, max_zoom, 1.0),
        };
    }
};

pub const NewThreadComposerBackground = struct {
    /// Managed copy inside Zeron's device-local data directory.
    path: []const u8,
    /// Original file name shown in Appearance settings.
    name: []const u8,
    adjustment: NewThreadBackgroundAdjustment = .{},
};

pub const NewThreadBackgroundEffect = enum {
    none,
    dither,
    ascii,
    halftone,
    scanlines,

    pub fn label(self: NewThreadBackgroundEffect) []const u8 {
        return switch (self) {
            .none => "None",
            .dither => "Dither",
            .ascii => "ASCII",
            .halftone => "Halftone",
            .scanlines => "Scanlines",
        };
    }

    pub fn description(self: NewThreadBackgroundEffect) []const u8 {
        return switch (self) {
            .none => "Shows the original artwork.",
            .dither => "Rebuilds the artwork with a dithered color palette.",
            .ascii => "Recreates the artwork with colored characters on black.",
            .halftone => "Recreates the artwork with colored print dots on black.",
            .scanlines => "Adds a pronounced horizontal display-line texture.",
        };
    }
};

pub const GitHistoryColumns = struct { author: bool = true, date: bool = true, sha: bool = true };
pub const GitHistoryColumn = enum { author, date, sha };

pub fn normalizeColumnOrder(arena: Allocator, order: []const GitHistoryColumn) Allocator.Error![]const GitHistoryColumn {
    var out: std.ArrayList(GitHistoryColumn) = .empty;
    for (order) |c| if (std.mem.findScalar(GitHistoryColumn, out.items, c) == null) try out.append(arena, c);
    for ([_]GitHistoryColumn{ .author, .date, .sha }) |c| {
        if (std.mem.findScalar(GitHistoryColumn, out.items, c) == null) try out.append(arena, c);
    }
    return out.items;
}

pub const GitHistoryColumnWidths = struct {
    author: f32 = 88.0,
    date: f32 = 88.0,
    sha: f32 = 74.0,

    pub const author_min: f32 = 44.0;
    pub const author_max: f32 = 220.0;
    pub const date_min: f32 = 68.0;
    pub const date_max: f32 = 180.0;
    pub const sha_min: f32 = 58.0;
    pub const sha_max: f32 = 140.0;

    pub fn clamped(self: GitHistoryColumnWidths) GitHistoryColumnWidths {
        return .{
            .author = clampOr(self.author, author_min, author_max, 88.0),
            .date = clampOr(self.date, date_min, date_max, 88.0),
            .sha = clampOr(self.sha, sha_min, sha_max, 74.0),
        };
    }
};

pub const GitHistoryAuthorDisplay = enum { avatar, name };
pub const ComposerSendBehavior = enum { enter, @"mod-enter" };
pub const SidebarOrganization = enum { byProject, byDevice, inOneList };
pub const SidebarSort = enum { lastUpdated, created };
pub const AppshotDestination = enum {
    automatic,
    @"last-session",
    @"new-session",

    pub fn label(self: AppshotDestination) []const u8 {
        return switch (self) {
            .automatic => "Automatic",
            .@"last-session" => "Last session",
            .@"new-session" => "New session",
        };
    }
};

/// The settings sections (`shell::SettingsSection`). Serialized as a slug;
/// an unknown or malformed value reads as `general` (lenient, like Rust).
pub const SettingsSection = enum {
    devices,
    harnesses,
    agents,
    appearance,
    files,
    notifications,
    voice,
    shortcuts,
    general,
    appshots,
    archived,

    pub const all = [_]SettingsSection{ .general, .appearance, .notifications, .voice, .shortcuts, .harnesses, .devices, .files, .appshots, .archived };

    pub fn slug(self: SettingsSection) []const u8 {
        return switch (self) {
            .harnesses => "providers",
            else => @tagName(self),
        };
    }

    pub fn fromSlug(s: []const u8) ?SettingsSection {
        if (std.mem.eql(u8, s, "providers") or std.mem.eql(u8, s, "harnesses")) return .harnesses;
        if (std.mem.eql(u8, s, "general") or std.mem.eql(u8, s, "conversations")) return .general;
        if (std.mem.eql(u8, s, "harnesses")) return null;
        return std.meta.stringToEnum(SettingsSection, s);
    }

    pub fn canonical(self: SettingsSection) SettingsSection {
        return if (self == .agents) .harnesses else self;
    }

    pub fn visibleInNav(self: SettingsSection) bool {
        return self != .agents and (self != .appshots or appshots_platform);
    }

    pub fn reopenable(self: SettingsSection) SettingsSection {
        const s = self.canonical();
        return if (s.visibleInNav()) s else .general;
    }

    pub fn label(self: SettingsSection) []const u8 {
        return switch (self) {
            .devices => "Devices",
            .harnesses => "Providers",
            .agents => "Accounts",
            .appearance => "Appearance",
            .files => "Files",
            .notifications => "Notifications",
            .voice => "Voice",
            .shortcuts => "Shortcuts",
            .general => "General",
            .appshots => "Appshots",
            .archived => "Archived",
        };
    }

    pub fn jsonStringify(self: SettingsSection, jws: anytype) !void {
        try jws.write(self.slug());
    }

    pub fn jsonParse(gpa: Allocator, source: anytype, options: json.ParseOptions) json.ParseError(@TypeOf(source.*))!SettingsSection {
        return jsonParseFromValue(gpa, try json.innerParse(json.Value, gpa, source, options), options);
    }

    pub fn jsonParseFromValue(_: Allocator, value: json.Value, _: json.ParseOptions) json.ParseFromValueError!SettingsSection {
        return if (value == .string) fromSlug(value.string) orelse .general else .general;
    }
};

pub const WindowGeometry = struct {
    displayUuid: ?[]const u8 = null,
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn isValid(self: WindowGeometry) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y) and
            std.math.isFinite(self.width) and std.math.isFinite(self.height) and
            self.width > 0 and self.height > 0;
    }

    pub fn fit(self: WindowGeometry, display: WindowGeometry) WindowGeometry {
        const width = @min(@max(self.width, 900.0), display.width);
        const height = @min(@max(self.height, 600.0), display.height);
        return .{
            .displayUuid = self.displayUuid,
            .x = rustClamp(self.x, display.x, display.x + display.width - width),
            .y = rustClamp(self.y, display.y, display.y + display.height - height),
            .width = width,
            .height = height,
        };
    }

    /// Where to restore on the current displays: the remembered display by
    /// uuid, else the primary, else any valid one.
    pub fn restore(self: WindowGeometry, displays: []const WindowGeometry, primary: usize) ?struct { usize, WindowGeometry } {
        if (!self.isValid()) return null;
        var matched: ?usize = null;
        if (self.displayUuid) |uuid| for (displays, 0..) |d, i| {
            if (d.isValid() and d.displayUuid != null and std.mem.eql(u8, d.displayUuid.?, uuid)) {
                matched = i;
                break;
            }
        };
        const index = matched orelse
            (if (primary < displays.len and displays[primary].isValid()) primary else for (displays, 0..) |d, i| {
                if (d.isValid()) break i;
            } else return null);
        const display = displays[index];
        var g = self.fit(display);
        if (self.displayUuid != null and matched == null) {
            g.x = display.x + (display.width - g.width) / 2.0;
            g.y = display.y + (display.height - g.height) / 2.0;
        }
        g.displayUuid = display.displayUuid;
        return .{ index, g };
    }
};

/// `f32::clamp` panics when min > max; Rust callers never hit that because
/// `fit` keeps width ≤ display width. Mirror the arithmetic without panicking.
fn rustClamp(v: f32, lo: f32, hi: f32) f32 {
    return @max(lo, @min(v, hi));
}

pub const SkillCompletionSettings = struct {
    dollar: bool = true,
    separateFromSlash: bool = true,
};

pub const skill_completion_harnesses = [_]struct { protocol.HarnessId, []const u8 }{
    .{ .antigravity, "Antigravity" },
    .{ .@"claude-code", "Claude Code" },
    .{ .codex, "Codex" },
    .{ .cursor, "Cursor" },
    .{ .devin, "Devin" },
    .{ .grok, "Grok" },
    .{ .hermes, "Hermes" },
    .{ .pi, "Pi" },
    .{ .opencode, "OpenCode" },
};

// ---------------------------------------------------------------------------
// Shortcuts
// ---------------------------------------------------------------------------

/// How many sidebar rows the jump shortcuts reach.
pub const jump_slots = 9;
const jump_defaults = [jump_slots][]const u8{ "mod-1", "mod-2", "mod-3", "mod-4", "mod-5", "mod-6", "mod-7", "mod-8", "mod-9" };
const jump_labels = [jump_slots][]const u8{
    "Jump to session 1", "Jump to session 2", "Jump to session 3",
    "Jump to session 4", "Jump to session 5", "Jump to session 6",
    "Jump to session 7", "Jump to session 8", "Jump to session 9",
};

/// The rebindable app shortcuts. `jump_session` slots are zero-based.
pub const ShortcutId = union(enum) {
    toggle_dictation,
    capture_appshot,
    random_wallpaper,
    save_file,
    browser_reload,
    toggle_sidebar,
    toggle_changes,
    toggle_files,
    toggle_terminal,
    new_session,
    new_project,
    open_model_picker,
    next_session,
    prev_session,
    archive_session,
    jump_session: usize,

    pub const all: [15 + jump_slots]ShortcutId = blk: {
        var ids: [15 + jump_slots]ShortcutId = undefined;
        const simple = [_]ShortcutId{
            .toggle_dictation, .capture_appshot,   .random_wallpaper, .save_file,       .browser_reload,
            .toggle_sidebar,   .toggle_changes,    .toggle_files,     .toggle_terminal, .new_session,
            .new_project,      .open_model_picker, .next_session,     .prev_session,    .archive_session,
        };
        for (simple, 0..) |id, i| ids[i] = id;
        for (0..jump_slots) |s| ids[15 + s] = .{ .jump_session = s };
        break :blk ids;
    };

    pub fn eql(a: ShortcutId, b: ShortcutId) bool {
        return std.meta.eql(a, b);
    }

    pub fn available(self: ShortcutId) bool {
        return self != .capture_appshot or appshots_platform;
    }

    /// Row label (zeron lib/shortcuts.ts `SHORTCUT_DEFINITIONS`, verbatim).
    pub fn label(self: ShortcutId) []const u8 {
        return switch (self) {
            .toggle_dictation => "Hold to dictate",
            .random_wallpaper => "Random wallpaper",
            .capture_appshot => "Capture Appshot",
            .save_file => "Save file",
            .browser_reload => "Reload browser page",
            .toggle_sidebar => "Toggle left sidebar",
            .toggle_changes => "Toggle right sidebar",
            .toggle_files => "Toggle files panel",
            .toggle_terminal => "Toggle terminal",
            .new_session => "New session",
            .new_project => "New project",
            .open_model_picker => "Open model picker",
            .next_session => "Next session or right pane tab",
            .prev_session => "Previous session or right pane tab",
            .archive_session => "Archive session",
            .jump_session => |slot| if (slot < jump_slots) jump_labels[slot] else "",
        };
    }

    pub fn defaultCombo(self: ShortcutId) []const u8 {
        return self.defaultComboOn(is_mac);
    }

    pub fn defaultComboOn(self: ShortcutId, mac: bool) []const u8 {
        return switch (self) {
            .toggle_dictation => "mod-d",
            .random_wallpaper => "mod-u",
            .capture_appshot => if (mac) "ctrl-alt-space" else "mod-alt-space",
            .save_file => "mod-s",
            .browser_reload => "mod-shift-r",
            .toggle_sidebar => "mod-b",
            .toggle_changes => "mod-r",
            .toggle_files => "mod-e",
            .toggle_terminal => "mod-j",
            .new_session => "mod-n",
            .new_project => "mod-shift-n",
            .open_model_picker => "mod-/",
            .next_session => if (mac) "ctrl-tab" else "mod-tab",
            .prev_session => if (mac) "ctrl-shift-tab" else "mod-shift-tab",
            .archive_session => "mod-shift-a",
            .jump_session => |slot| if (slot < jump_slots) jump_defaults[slot] else "",
        };
    }

    pub fn jumpSlot(self: ShortcutId) ?usize {
        return switch (self) {
            .jump_session => |s| if (s < jump_slots) s else null,
            else => null,
        };
    }

    /// The KeymapConfig JSON key for non-jump ids.
    pub fn fieldName(self: ShortcutId) ?[]const u8 {
        return switch (self) {
            .toggle_dictation => "toggleDictation",
            .capture_appshot => "captureAppshot",
            .random_wallpaper => "randomWallpaper",
            .save_file => "saveFile",
            .browser_reload => "browserReload",
            .toggle_sidebar => "toggleSidebar",
            .toggle_changes => "toggleChanges",
            .toggle_files => "toggleFiles",
            .toggle_terminal => "toggleTerminal",
            .new_session => "newSession",
            .new_project => "newProject",
            .open_model_picker => "openModelPicker",
            .next_session => "nextSession",
            .prev_session => "prevSession",
            .archive_session => "archiveSession",
            .jump_session => null,
        };
    }
};

/// Persisted shortcut combos, stored platform-neutral ("mod-s") and
/// translated at bind time by `platformCombo`. Strings are borrowed.
pub const KeymapConfig = struct {
    toggleDictation: []const u8 = "mod-d",
    captureAppshot: []const u8 = if (is_mac) "ctrl-alt-space" else "mod-alt-space",
    randomWallpaper: []const u8 = "mod-u",
    saveFile: []const u8 = "mod-s",
    browserReload: []const u8 = "mod-shift-r",
    toggleSidebar: []const u8 = "mod-b",
    toggleChanges: []const u8 = "mod-r",
    toggleFiles: []const u8 = "mod-e",
    toggleTerminal: []const u8 = "mod-j",
    newSession: []const u8 = "mod-n",
    newProject: []const u8 = "mod-shift-n",
    openModelPicker: []const u8 = "mod-/",
    nextSession: []const u8 = if (is_mac) "ctrl-tab" else "mod-tab",
    prevSession: []const u8 = if (is_mac) "ctrl-shift-tab" else "mod-shift-tab",
    archiveSession: []const u8 = "mod-shift-a",
    /// Always exactly `jump_slots` entries in memory (healed on load).
    jumpSession: [jump_slots][]const u8 = jump_defaults,

    const string_fields = [_][]const u8{
        "toggleDictation", "captureAppshot",  "randomWallpaper", "saveFile",       "browserReload",
        "toggleSidebar",   "toggleChanges",   "toggleFiles",     "toggleTerminal", "newSession",
        "newProject",      "openModelPicker", "nextSession",     "prevSession",    "archiveSession",
    };

    pub fn get(self: *const KeymapConfig, id: ShortcutId) []const u8 {
        return switch (id) {
            .jump_session => |slot| if (slot < jump_slots) self.jumpSession[slot] else "",
            inline else => |_, tag| @field(self, fieldOf(tag)),
        };
    }

    pub fn set(self: *KeymapConfig, id: ShortcutId, combo: []const u8) void {
        switch (id) {
            .jump_session => |slot| if (slot < jump_slots) {
                self.jumpSession[slot] = combo;
            },
            inline else => |_, tag| @field(self, fieldOf(tag)) = combo,
        }
    }

    pub fn reset(self: *KeymapConfig, id: ShortcutId) void {
        self.set(id, id.defaultCombo());
    }

    fn fieldOf(comptime tag: std.meta.Tag(ShortcutId)) []const u8 {
        return (@unionInit(ShortcutId, @tagName(tag), {})).fieldName().?;
    }

    /// Cmd/Ctrl+Enter belongs to the composer on every send mode.
    pub fn healReservedComposerShortcuts(self: *KeymapConfig) void {
        for (ShortcutId.all) |id| {
            if (std.mem.eql(u8, self.get(id), "mod-enter")) self.reset(id);
        }
    }

    pub fn jsonStringify(self: KeymapConfig, jws: anytype) !void {
        try jws.beginObject();
        inline for (string_fields) |f| {
            if (appshots_platform or !std.mem.eql(u8, f, "captureAppshot")) {
                try jws.objectField(f);
                try jws.write(@field(self, f));
            }
        }
        try jws.objectField("jumpSession");
        try jws.write(&self.jumpSession);
        try jws.endObject();
    }

    pub fn jsonParse(gpa: Allocator, source: anytype, options: json.ParseOptions) json.ParseError(@TypeOf(source.*))!KeymapConfig {
        return jsonParseFromValue(gpa, try json.innerParse(json.Value, gpa, source, options), options) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.UnexpectedToken,
        };
    }

    /// serde `#[serde(default)]`: missing fields default; a jump list of any
    /// length heals to `jump_slots` entries; wrong types fail the file.
    pub fn jsonParseFromValue(_: Allocator, value: json.Value, _: json.ParseOptions) json.ParseFromValueError!KeymapConfig {
        if (value != .object) return error.UnexpectedToken;
        var out: KeymapConfig = .{};
        var it = value.object.iterator();
        while (it.next()) |e| {
            const key = e.key_ptr.*;
            const v = e.value_ptr.*;
            if (std.mem.eql(u8, key, "jumpSession")) {
                if (v != .array) return error.UnexpectedToken;
                for (v.array.items) |item| if (item != .string) return error.UnexpectedToken;
                for (0..jump_slots) |i| {
                    out.jumpSession[i] = if (i < v.array.items.len) v.array.items[i].string else jump_defaults[i];
                }
                continue;
            }
            inline for (string_fields) |f| {
                if (std.mem.eql(u8, key, f)) {
                    if (!appshots_platform and comptime std.mem.eql(u8, f, "captureAppshot")) break;
                    if (v != .string) return error.UnexpectedToken;
                    @field(out, f) = v.string;
                    break;
                }
            }
        }
        return out;
    }
};

/// Build a combo from a recorded keystroke; the primary modifier becomes
/// "mod". Bare modifier presses record nothing. Writes into `buf`.
pub fn comboFromKeystroke(buf: []u8, ctrl: bool, alt: bool, shift: bool, cmd: bool, key: []const u8) ?[]const u8 {
    return comboFromKeystrokeOn(buf, is_mac, ctrl, alt, shift, cmd, key);
}

pub fn comboFromKeystrokeOn(buf: []u8, mac: bool, ctrl: bool, alt: bool, shift: bool, cmd: bool, key_raw: []const u8) ?[]const u8 {
    const key_trim = view.trimUnicode(key_raw);
    var key_buf: [64]u8 = undefined;
    if (key_trim.len == 0 or key_trim.len > key_buf.len) return null;
    const key = std.ascii.lowerString(&key_buf, key_trim);
    for ([_][]const u8{ "ctrl", "control", "alt", "shift", "cmd", "platform", "fn" }) |m| {
        if (std.mem.eql(u8, key, m)) return null;
    }
    var w: std.Io.Writer = .fixed(buf);
    const ctrl_is_primary = ctrl and !mac;
    if (cmd or ctrl_is_primary) w.writeAll("mod-") catch return null;
    if (ctrl and !ctrl_is_primary) w.writeAll("ctrl-") catch return null;
    if (alt) w.writeAll("alt-") catch return null;
    if (shift) w.writeAll("shift-") catch return null;
    w.writeAll(key) catch return null;
    return w.buffered();
}

/// Shortcut ids whose combos collide with another shortcut.
pub fn conflictedShortcuts(keymap: *const KeymapConfig, out: *std.ArrayList(ShortcutId), gpa: Allocator) Allocator.Error!void {
    for (ShortcutId.all) |id| {
        const combo = keymap.get(id);
        if (!id.available() or combo.len == 0) continue;
        for (ShortcutId.all) |other| {
            if (other.available() and !other.eql(id) and std.mem.eql(u8, keymap.get(other), combo)) {
                try out.append(gpa, id);
                break;
            }
        }
    }
}

pub const ComboModifiers = struct { mod: bool, alt: bool, shift: bool };

/// The modifiers a stored combo carries; the final segment is the key.
pub fn comboModifiers(combo: []const u8) ComboModifiers {
    var out: ComboModifiers = .{ .mod = false, .alt = false, .shift = false };
    const last = std.mem.findScalarLast(u8, combo, '-') orelse return out;
    var it = std.mem.splitScalar(u8, combo[0..last], '-');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, "mod")) out.mod = true;
        if (std.mem.eql(u8, p, "alt")) out.alt = true;
        if (std.mem.eql(u8, p, "shift")) out.shift = true;
    }
    return out;
}

/// Whether the sidebar shows its jump hints for the held modifiers.
pub fn jumpHintsVisible(keymap: *const KeymapConfig, primary: bool, alt: bool, shift: bool) bool {
    if (!(primary or alt or shift)) return false;
    for (ShortcutId.all) |id| {
        if (id.jumpSlot() == null) continue;
        const m = comboModifiers(keymap.get(id));
        if (m.mod == primary and m.alt == alt and m.shift == shift) return true;
    }
    return false;
}

pub fn modifierSendHintVisible(primary: bool, alt: bool, shift: bool) bool {
    return primary and !alt and !shift;
}

/// Translate a stored combo into a bindable keystroke ("mod" → cmd/ctrl).
pub fn platformCombo(buf: []u8, combo: []const u8) []const u8 {
    return platformComboOn(buf, is_mac, combo);
}

pub fn platformComboOn(buf: []u8, mac: bool, combo: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var it = std.mem.splitScalar(u8, combo, '-');
    var first = true;
    while (it.next()) |part| {
        if (!first) w.writeByte('-') catch break;
        first = false;
        w.writeAll(if (std.mem.eql(u8, part, "mod")) (if (mac) "cmd" else "ctrl") else part) catch break;
    }
    return w.buffered();
}

/// Human-readable combo ("mod-s" → "Cmd+S" / "Ctrl+S").
pub fn displayCombo(buf: []u8, combo: []const u8) []const u8 {
    return displayComboOn(buf, is_mac, combo);
}

pub fn displayComboOn(buf: []u8, mac: bool, combo: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var it = std.mem.splitScalar(u8, combo, '-');
    var first = true;
    while (it.next()) |part| {
        if (!first) w.writeByte('+') catch break;
        first = false;
        if (std.mem.eql(u8, part, "mod")) {
            w.writeAll(if (mac) "Cmd" else "Ctrl") catch break;
        } else if (std.mem.eql(u8, part, "alt")) {
            w.writeAll(if (mac) "Opt" else "Alt") catch break;
        } else if (std.mem.eql(u8, part, "shift")) {
            w.writeAll("Shift") catch break;
        } else writeCapitalized(&w, part) catch break;
    }
    return w.buffered();
}

fn writeCapitalized(w: *std.Io.Writer, s: []const u8) !void {
    if (s.len == 0) return;
    // ASCII uppercasing covers every key name the recorder produces.
    try w.writeByte(std.ascii.toUpper(s[0]));
    try w.writeAll(s[1..]);
}

/// Compact combo for badges: macOS glyphs (⌃⌥⇧⌘) without separators,
/// `displayCombo` elsewhere.
pub fn badgeCombo(buf: []u8, combo: []const u8) []const u8 {
    return badgeComboOn(buf, is_mac, combo);
}

pub fn badgeComboOn(buf: []u8, mac: bool, combo: []const u8) []const u8 {
    if (!mac) return displayComboOn(buf, false, combo);
    const last = std.mem.findScalarLast(u8, combo, '-');
    const mods = if (last) |l| combo[0..l] else "";
    const key = if (last) |l| combo[l + 1 ..] else combo;
    var w: std.Io.Writer = .fixed(buf);
    for ([_][2][]const u8{ .{ "ctrl", "⌃" }, .{ "alt", "⌥" }, .{ "shift", "⇧" }, .{ "mod", "⌘" } }) |pair| {
        var it = std.mem.splitScalar(u8, mods, '-');
        while (it.next()) |p| if (std.mem.eql(u8, p, pair[0])) {
            w.writeAll(pair[1]) catch {};
            break;
        };
    }
    writeCapitalized(&w, key) catch {};
    return w.buffered();
}

/// Stable key for device-local preferences that belong to one workspace
/// profile; null while identity isn't ready.
pub fn sidebarPinProfileKey(
    gpa: Allocator,
    scope: ?protocol.WorkspaceScope,
    auth: ?*const protocol.AuthState,
    development_org_id: ?[]const u8,
) Allocator.Error!?[]u8 {
    switch (scope orelse return null) {
        .local => return try gpa.dupe(u8, "local"),
        .synced => {
            const a = auth orelse return null;
            if (a.* != .signedIn) return null;
            const org = a.signedIn.orgId orelse return null;
            return try std.fmt.allocPrint(gpa, "synced:{s}:{s}", .{ org, a.signedIn.user.id });
        },
        .development => {
            const a = auth orelse return null;
            if (a.* != .signedIn) return null;
            const id = a.signedIn.user.id;
            var user_id = id;
            var token_org: ?[]const u8 = null;
            if (std.mem.findScalar(u8, id, '@')) |at| {
                user_id = id[0..at];
                if (at + 1 < id.len) token_org = id[at + 1 ..];
            }
            if (user_id.len == 0) return null;
            const org = token_org orelse (if (development_org_id) |d| (if (d.len > 0) d else null) else null) orelse default_org_id;
            return try std.fmt.allocPrint(gpa, "development:{s}:{s}", .{ org, user_id });
        },
    }
}

/// `zeron_engine::DEFAULT_ORG_ID`.
pub const default_org_id = "default";

// ---------------------------------------------------------------------------
// UiSettings
// ---------------------------------------------------------------------------

/// Every non-theme `ui-settings.json` field (serde names, Rust defaults).
pub const UiSettings = struct {
    dictationEnabled: bool = false,
    dictationInput: ?[]const u8 = null,
    windowGeometry: ?WindowGeometry = null,
    composerSendBehavior: ComposerSendBehavior = .enter,
    skillsInSlashMenu: bool = false,
    skillCompletionByHarness: json.ArrayHashMap(SkillCompletionSettings) = .{},
    compactModelPicker: bool = true,
    sidebarWidth: f32 = sidebar_default,
    sidebarCollapsed: bool = false,
    /// Legacy; kept for file compatibility.
    sidebarGrouped: bool = false,
    sidebarOrganization: SidebarOrganization = .inOneList,
    sidebarSort: SidebarSort = .lastUpdated,
    sidebarShowProjectLabel: bool = true,
    sidebarCompact: bool = true,
    sidebarShowProjectIcon: bool = true,
    sidebarShowHarness: bool = true,
    sidebarShowBranch: bool = true,
    sidebarShowPullRequest: bool = true,
    githubStarBannerDismissed: bool = false,
    lastSpaceId: ?[]const u8 = null,
    lastProjectActionBySpaceId: json.ArrayHashMap([]const u8) = .{},
    /// Open session tabs in visual order; null = written by a pre-tabs build.
    openTabs: ?[]const []const u8 = null,
    /// Sidebar session filter: a space id, or null for "All spaces".
    spaceFilter: ?[]const u8 = null,
    sidebarSectionsByProfile: json.ArrayHashMap([]const SidebarSection) = .{},
    sidebarPinnedSessionIdsByProfile: json.ArrayHashMap([]const []const u8) = .{},
    /// Legacy; kept for file compatibility.
    tabOrder: json.ArrayHashMap([]const []const u8) = .{},
    /// Legacy; kept for file compatibility.
    spaceOrder: []const []const u8 = &.{},
    soundEnabled: bool = true,
    soundCompletionEnabled: bool = true,
    soundInputEnabled: bool = true,
    soundAttentionEnabled: bool = true,
    notificationsEnabled: bool = true,
    notificationsBackgroundOnly: bool = true,
    filesPanelWidth: f32 = files_panel_default,
    agentUpdateNotifications: bool = true,
    rightPaneWidth: f32 = right_pane_default,
    /// Legacy; kept for file compatibility.
    rightPaneOpen: bool = false,
    terminalHeight: f32 = terminal_default_height,
    /// Legacy; kept for file compatibility.
    terminalOpen: bool = false,
    keymap: KeymapConfig = .{},
    appshotsEnabled: bool = false,
    appshotSoundEnabled: bool = true,
    appshotDestination: AppshotDestination = .automatic,
    escapeStopsActiveAgent: bool = false,
    settingsSection: SettingsSection = .general,
    gitHistoryColumns: GitHistoryColumns = .{},
    gitHistoryColumnWidths: GitHistoryColumnWidths = .{},
    gitHistoryColumnOrder: []const GitHistoryColumn = &.{ .author, .date, .sha },
    gitHistoryAuthorDisplay: GitHistoryAuthorDisplay = .avatar,
    diffSplit: bool = false,
    diffWrap: bool = false,
    codeFencesFitContent: bool = false,
    transcriptWidth: f32 = transcript_width_default,
    openWebLinksInZeron: bool = true,
    transcriptCompactMode: bool = false,
    filesAutosaveEnabled: bool = false,
    filesAutosaveDelayMs: u64 = files_autosave_delay_default_ms,
    filesWordWrap: bool = false,
    filesShowAll: bool = false,
    newThreadComposerBackground: ?NewThreadComposerBackground = null,
    wallpaperFolder: ?[]const u8 = null,
    wallpaperSource: ?[]const u8 = null,
    wallpaperHistory: []const []const u8 = &.{},
    newThreadBackgroundEffect: NewThreadBackgroundEffect = .none,

    /// The theme subset (appearance, theme selection, accent, surface,
    /// fonts, motion, wallpaper colors): `zeron_theme.ThemeSettings`.
    theme: ThemeSettings = .{},

    /// Fields excluded from the JSON object written by `write` (written via
    /// `ThemeSettings.writeFields` instead).
    const non_wire = [_][]const u8{"theme"};

    pub fn sidebarPins(self: *const UiSettings, profile_key: []const u8) []const []const u8 {
        return self.sidebarPinnedSessionIdsByProfile.map.get(profile_key) orelse &.{};
    }

    pub fn skillCompletion(self: *const UiSettings, harness: protocol.HarnessId) SkillCompletionSettings {
        if (self.skillCompletionByHarness.map.get(@tagName(harness))) |s| return s;
        if (self.skillsInSlashMenu) return .{ .dollar = true, .separateFromSlash = false };
        return .{};
    }

    pub fn transcriptWidthOr(self: *const UiSettings) f32 {
        return self.transcriptWidth;
    }

    /// Clamp widths into their legal ranges (also heals NaN to defaults).
    /// `arena` backs the normalized column order.
    pub fn clamped(self: UiSettings, arena: Allocator) Allocator.Error!UiSettings {
        var s = self;
        s.transcriptWidth = normalizeTranscriptWidth(s.transcriptWidth);
        if (s.windowGeometry) |g| if (!g.isValid()) {
            s.windowGeometry = null;
        };
        s.sidebarWidth = clampOr(s.sidebarWidth, sidebar_min, sidebar_max, sidebar_default);
        s.filesPanelWidth = clampOr(s.filesPanelWidth, files_panel_min, files_panel_max, files_panel_default);
        s.rightPaneWidth = minOr(s.rightPaneWidth, right_pane_min, right_pane_default);
        s.terminalHeight = clampOr(s.terminalHeight, terminal_min_height, terminal_abs_max_height, terminal_default_height);
        s.filesAutosaveDelayMs = std.math.clamp(s.filesAutosaveDelayMs, files_autosave_delay_min_ms, files_autosave_delay_max_ms);
        s.theme.terminal_font_size = clampOr(s.theme.terminal_font_size, zt.typography.font_size_min, zt.typography.font_size_max, zt.typography.terminal_font_size_default);
        s.theme.code_font_size = clampOr(s.theme.code_font_size, zt.typography.font_size_min, zt.typography.font_size_max, zt.typography.code_font_size_default);
        s.theme.ui_font_size = s.theme.ui_font_size.normalized();
        s.gitHistoryColumnWidths = s.gitHistoryColumnWidths.clamped();
        s.gitHistoryColumnOrder = try normalizeColumnOrder(arena, s.gitHistoryColumnOrder);
        if (s.newThreadComposerBackground) |*bg| bg.adjustment = bg.adjustment.normalized();
        s.keymap.healReservedComposerShortcuts();
        return s;
    }

    /// Three-way merge: fields `edited` changed since `base` win, the rest
    /// keep `current` (a stale working copy never reverts another save).
    pub fn mergeChanges(base: *const UiSettings, edited: *const UiSettings, current: UiSettings) UiSettings {
        var out = current;
        inline for (@typeInfo(UiSettings).@"struct".field_names) |name| {
            if (!deepEql(@field(edited, name), @field(base, name))) @field(out, name) = @field(edited, name);
        }
        return out;
    }

    pub fn eql(a: *const UiSettings, b: *const UiSettings) bool {
        return deepEql(a.*, b.*);
    }

    /// Write the whole settings object (non-theme fields, then theme fields).
    pub fn write(self: *const UiSettings, w: *Io.Writer) Io.Writer.Error!void {
        var s: json.Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false, .whitespace = .indent_2 } };
        try s.beginObject();
        inline for (@typeInfo(UiSettings).@"struct".field_names) |name| {
            const skip = comptime std.mem.eql(u8, name, "theme") or (!appshots_platform and std.mem.startsWith(u8, name, "appshot"));
            if (!skip) {
                const v = @field(self, name);
                if (@typeInfo(@TypeOf(v)) != .optional or v != null) {
                    try s.objectField(name);
                    try s.write(v);
                }
            }
        }
        // Theme members are written raw after the last field.
        try w.writeAll(",\n  ");
        try self.theme.writeFields(w);
        try w.writeAll("\n}");
    }

    pub fn toJson(self: *const UiSettings, gpa: Allocator) Allocator.Error![]u8 {
        var aw: Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        self.write(&aw.writer) catch return error.OutOfMemory;
        return aw.toOwnedSlice();
    }
};

pub const deepEql = @import("eql.zig").deepEql;

/// Settings plus the arena that owns their strings.
pub const Loaded = struct {
    arena: *std.heap.ArenaAllocator,
    value: UiSettings,

    pub fn deinit(self: Loaded) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self.arena);
    }
};

pub fn defaults(gpa: Allocator) Allocator.Error!Loaded {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    return .{ .arena = arena, .value = .{} };
}

/// `{data_dir}/ui-settings.json`. Caller frees.
pub fn path(gpa: Allocator, data_dir: []const u8) Allocator.Error![]u8 {
    return std.fs.path.join(gpa, &.{ data_dir, file_name });
}

/// Load from `{data_dir}/ui-settings.json`; defaults on any failure.
pub fn load(gpa: Allocator, io: Io, data_dir: []const u8) Allocator.Error!Loaded {
    const p = try path(gpa, data_dir);
    defer gpa.free(p);
    const text = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(16 << 20)) catch return defaults(gpa);
    defer gpa.free(text);
    return parse(gpa, text);
}

/// Parse a settings file's text (with Rust's migrations); defaults when
/// the text is corrupt or any known field has the wrong type.
pub fn parse(gpa: Allocator, text: []const u8) Allocator.Error!Loaded {
    var loaded = try defaults(gpa);
    errdefer loaded.deinit();
    const a = loaded.arena.allocator();
    loaded.value = parseInto(a, text) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            std.log.scoped(.zeron_settings).warn("ui-settings corrupt; using defaults ({t})", .{err});
            break :blk .{};
        },
    };
    loaded.value = try loaded.value.clamped(a);
    return loaded;
}

fn parseInto(a: Allocator, text: []const u8) !UiSettings {
    var root = try json.parseFromSliceLeaky(json.Value, a, text, .{ .allocate = .alloc_always });
    if (root != .object) return error.UnexpectedToken;
    const obj = &root.object;

    const previous_sound = if (obj.get("soundEnabled")) |v| (if (v == .bool) v.bool else true) else true;
    if (!obj.contains("appshotSoundEnabled")) try obj.put(a, "appshotSoundEnabled", .{ .bool = previous_sound });
    // The files-editor size was the first user-facing code size.
    if (obj.fetchOrderedRemove("filesEditorFontSize")) |legacy| {
        if (!obj.contains("codeFontSize")) try obj.put(a, "codeFontSize", legacy.value);
    }
    if (obj.getPtr("keymap")) |km| if (km.* == .object) try migrateKeymap(a, &km.object);

    var settings = try json.parseFromValueLeaky(UiSettings, a, root, .{ .ignore_unknown_fields = true });
    if (!appshots_platform) {
        settings.appshotsEnabled = false;
        settings.appshotSoundEnabled = true;
        settings.appshotDestination = .automatic;
    }
    // The theme subset (lenient per field) from the migrated object.
    const migrated = try json.Stringify.valueAlloc(a, root, .{});
    settings.theme = ThemeSettings.parse(a, migrated) catch .{};
    return settings;
}

fn platformEql(x: []const u8, y: []const u8) bool {
    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    return std.mem.eql(u8, platformCombo(&b1, x), platformCombo(&b2, y));
}

/// The `saveFile` migration and free-combo defaults for newer shortcuts.
fn migrateKeymap(a: Allocator, keymap: *json.ObjectMap) !void {
    if (!keymap.contains("saveFile")) {
        const Migration = struct { id: ShortcutId, field: []const u8, old: []const u8, fallback: []const u8 };
        var migrating: std.ArrayList(Migration) = .empty;
        try migrating.append(a, .{ .id = .save_file, .field = "saveFile", .old = "", .fallback = "mod-shift-s" });
        for ([_]Migration{
            .{ .id = .toggle_sidebar, .field = "toggleSidebar", .old = "mod-s", .fallback = "mod-shift-b" },
            .{ .id = .toggle_changes, .field = "toggleChanges", .old = "mod-b", .fallback = "mod-shift-r" },
        }) |m| {
            const current = if (keymap.get(m.field)) |v| (if (v == .string) v.string else m.old) else m.old;
            if (std.mem.eql(u8, current, m.old)) try migrating.append(a, m);
        }
        for (migrating.items) |m| try keymap.put(a, m.field, .{ .string = "" });
        var resolved = try KeymapConfig.jsonParseFromValue(a, .{ .object = keymap.* }, .{});
        for (migrating.items) |m| {
            const combo = for ([_][]const u8{ m.id.defaultCombo(), m.old, m.fallback }) |candidate| {
                if (candidate.len == 0) continue;
                const taken = for (ShortcutId.all) |other| {
                    const existing = resolved.get(other);
                    if (existing.len > 0 and platformEql(existing, candidate)) break true;
                } else false;
                if (!taken) break candidate;
            } else "";
            resolved.set(m.id, combo);
            try keymap.put(a, m.field, .{ .string = combo });
        }
    }
    // A shortcut added after the file was written takes its default only
    // when that combo is free.
    const id: ShortcutId = .toggle_files;
    const field_name = "toggleFiles";
    if (!keymap.contains(field_name)) {
        var it = keymap.iterator();
        const taken = while (it.next()) |e| {
            if (e.value_ptr.* == .string and platformEql(e.value_ptr.string, id.defaultCombo())) break true;
        } else false;
        if (taken) try keymap.put(a, field_name, .{ .string = "" });
    }
}

/// Write atomically (temp file + rename) so a crash mid-write never corrupts.
pub fn save(settings: *const UiSettings, gpa: Allocator, io: Io, data_dir: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, data_dir);
    const final = try path(gpa, data_dir);
    defer gpa.free(final);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{final});
    defer gpa.free(tmp);
    const text = try settings.toJson(gpa);
    defer gpa.free(text);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text });
    try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), final, io);
}

// ---------------------------------------------------------------------------
// Data dir (apps/zeron/src/paths.rs)
// ---------------------------------------------------------------------------

pub const DataDirError = error{ HomeNotSet, LocalAppDataNotSet } || Allocator.Error;

/// `ZERON_DATA_DIR`, else `%LOCALAPPDATA%\Zeron` (Windows; `USERPROFILE`
/// fallback), else `$HOME/.zeron` (adopting a pre-rename `~/.comet-native`
/// once when `io` is given). Caller frees.
pub fn dataDir(gpa: Allocator, environ: *const std.process.Environ.Map, io: ?Io) DataDirError![]u8 {
    return dataDirFor(gpa, environ, io, builtin.os.tag == .windows);
}

pub fn dataDirFor(gpa: Allocator, environ: *const std.process.Environ.Map, io: ?Io, windows: bool) DataDirError![]u8 {
    if (environ.get("ZERON_DATA_DIR")) |dir| return gpa.dupe(u8, dir);
    if (windows) {
        if (environ.get("LOCALAPPDATA")) |local| if (local.len > 0) {
            return std.mem.concat(gpa, u8, &.{ local, "\\Zeron" });
        };
        if (environ.get("USERPROFILE")) |home| if (home.len > 0) {
            return std.mem.concat(gpa, u8, &.{ home, "\\AppData\\Local\\Zeron" });
        };
        return error.LocalAppDataNotSet;
    }
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    const dir = try std.fs.path.join(gpa, &.{ home, ".zeron" });
    if (io) |i| migrate: {
        Io.Dir.cwd().access(i, dir, .{}) catch {
            const old = std.fs.path.join(gpa, &.{ home, ".comet-native" }) catch break :migrate;
            defer gpa.free(old);
            Io.Dir.cwd().access(i, old, .{}) catch break :migrate;
            Io.Dir.rename(Io.Dir.cwd(), old, Io.Dir.cwd(), dir, i) catch break :migrate;
            std.log.scoped(.zeron_settings).info("migrated data dir {s} -> {s}", .{ old, dir });
        };
    }
    return dir;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "defaults match Rust and round-trip through JSON" {
    var loaded = try defaults(testing.allocator);
    defer loaded.deinit();
    const text = try loaded.value.toJson(testing.allocator);
    defer testing.allocator.free(text);
    var back = try parse(testing.allocator, text);
    defer back.deinit();
    try testing.expect(back.value.eql(&loaded.value));
    try testing.expectEqual(@as(f32, 256), back.value.sidebarWidth);
    try testing.expectEqualStrings("mod-b", back.value.keymap.toggleSidebar);
    try testing.expectEqual(SettingsSection.general, back.value.settingsSection);
}

test "load: corrupt or mistyped files default; clamps; lenient section" {
    {
        var l = try parse(testing.allocator, "{not json");
        defer l.deinit();
        try testing.expectEqual(@as(f32, 256), l.value.sidebarWidth);
    }
    {
        var l = try parse(testing.allocator, "{\"sidebarWidth\": \"wide\", \"diffSplit\": true}");
        defer l.deinit();
        try testing.expect(!l.value.diffSplit); // whole file defaulted, like serde
    }
    {
        var l = try parse(testing.allocator,
            \\{"sidebarWidth": 9999, "transcriptWidth": 741, "settingsSection": "bogus",
            \\ "filesAutosaveDelayMs": 5, "gitHistoryColumnOrder": ["sha", "sha"],
            \\ "keymap": {"saveFile": "mod-s", "newSession": "mod-enter", "jumpSession": ["mod-0"]},
            \\ "appearance": "dark", "openTabs": ["a", "b"]}
        );
        defer l.deinit();
        try testing.expectEqual(sidebar_max, l.value.sidebarWidth);
        try testing.expectEqual(@as(f32, 736), l.value.transcriptWidth);
        try testing.expectEqual(SettingsSection.general, l.value.settingsSection);
        try testing.expectEqual(files_autosave_delay_min_ms, l.value.filesAutosaveDelayMs);
        try testing.expectEqualSlices(GitHistoryColumn, &.{ .sha, .author, .date }, l.value.gitHistoryColumnOrder);
        try testing.expectEqualStrings("mod-n", l.value.keymap.newSession); // reserved combo healed
        try testing.expectEqualStrings("mod-0", l.value.keymap.jumpSession[0]);
        try testing.expectEqualStrings("mod-2", l.value.keymap.jumpSession[1]);
        try testing.expectEqual(zt.settings.AppearanceMode.dark, l.value.theme.appearance);
        try testing.expectEqual(@as(usize, 2), l.value.openTabs.?.len);
    }
    {
        // Sections: "providers" and its former name.
        var l = try parse(testing.allocator, "{\"settingsSection\": \"harnesses\"}");
        defer l.deinit();
        try testing.expectEqual(SettingsSection.harnesses, l.value.settingsSection);
    }
}

test "load migrations: appshot sound, files editor size, saveFile keymap" {
    var l = try parse(testing.allocator,
        \\{"soundEnabled": false, "filesEditorFontSize": 15,
        \\ "keymap": {"toggleSidebar": "mod-s", "toggleChanges": "mod-b", "newSession": "mod-e"}}
    );
    defer l.deinit();
    try testing.expect(!l.value.appshotSoundEnabled or !appshots_platform);
    try testing.expectEqual(@as(f32, 15), l.value.theme.code_font_size);
    // saveFile takes mod-s (freed by the sidebar migration); the sidebar takes
    // its new default mod-b (freed by the changes migration), changes mod-r.
    try testing.expectEqualStrings("mod-s", l.value.keymap.saveFile);
    try testing.expectEqualStrings("mod-b", l.value.keymap.toggleSidebar);
    try testing.expectEqualStrings("mod-r", l.value.keymap.toggleChanges);
    // toggleFiles' default (mod-e) is taken by newSession: it arrives unbound.
    try testing.expectEqualStrings("", l.value.keymap.toggleFiles);
}

test "save + load through the filesystem" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/data", .{&tmp.sub_path});
    defer testing.allocator.free(dir);
    var s = try defaults(testing.allocator);
    defer s.deinit();
    s.value.sidebarCollapsed = true;
    s.value.openTabs = &.{ "chat-1", "chat-2" };
    s.value.theme.appearance = .light;
    try save(&s.value, testing.allocator, io, dir);
    var back = try load(testing.allocator, io, dir);
    defer back.deinit();
    try testing.expect(back.value.sidebarCollapsed);
    try testing.expectEqualStrings("chat-2", back.value.openTabs.?[1]);
    try testing.expectEqual(zt.settings.AppearanceMode.light, back.value.theme.appearance);
}

test "combo helpers" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("cmd-shift-a", platformComboOn(&buf, true, "mod-shift-a"));
    try testing.expectEqualStrings("ctrl-tab", platformComboOn(&buf, false, "mod-tab"));
    try testing.expectEqualStrings("Cmd+Shift+A", displayComboOn(&buf, true, "mod-shift-a"));
    try testing.expectEqualStrings("Ctrl+Alt+Space", displayComboOn(&buf, false, "mod-alt-space"));
    try testing.expectEqualStrings("⇧⌘A", badgeComboOn(&buf, true, "mod-shift-a"));
    try testing.expectEqualStrings("⌘1", badgeComboOn(&buf, true, "mod-1"));
    try testing.expectEqualStrings("Ctrl+1", badgeComboOn(&buf, false, "mod-1"));
    try testing.expectEqualStrings("ctrl-tab", comboFromKeystrokeOn(&buf, true, true, false, false, false, "Tab").?);
    try testing.expectEqualStrings("mod-tab", comboFromKeystrokeOn(&buf, false, true, false, false, false, "tab").?);
    try testing.expect(comboFromKeystrokeOn(&buf, false, true, false, false, false, "shift") == null);
    try testing.expectEqualStrings("ctrl-tab", @as(ShortcutId, .next_session).defaultComboOn(true));
    try testing.expectEqualStrings("mod-tab", @as(ShortcutId, .next_session).defaultComboOn(false));
    const km: KeymapConfig = .{};
    try testing.expect(jumpHintsVisible(&km, true, false, false));
    try testing.expect(!jumpHintsVisible(&km, true, false, true));
    var conflicts: std.ArrayList(ShortcutId) = .empty;
    defer conflicts.deinit(testing.allocator);
    try conflictedShortcuts(&km, &conflicts, testing.allocator);
    try testing.expectEqual(@as(usize, 0), conflicts.items.len);
    var km2 = km;
    km2.set(.new_session, "mod-b");
    try conflictedShortcuts(&km2, &conflicts, testing.allocator);
    try testing.expectEqual(@as(usize, 2), conflicts.items.len);
}

test "data dir resolution" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectError(error.HomeNotSet, dataDirFor(testing.allocator, &env, null, false));
    try env.put("HOME", "/home/u");
    const d = try dataDirFor(testing.allocator, &env, null, false);
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("/home/u/.zeron", d);
    try env.put("LOCALAPPDATA", "C:\\Local");
    const w = try dataDirFor(testing.allocator, &env, null, true);
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("C:\\Local\\Zeron", w);
    try env.put("ZERON_DATA_DIR", "custom data");
    const c = try dataDirFor(testing.allocator, &env, null, false);
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("custom data", c);
}

test "profile keys and merge" {
    const user: protocol.UserProfile = .{ .id = "u1@org9", .email = "e" };
    const auth: protocol.AuthState = .{ .signedIn = .{ .user = user, .orgId = "o" } };
    const k = (try sidebarPinProfileKey(testing.allocator, .development, &auth, null)).?;
    defer testing.allocator.free(k);
    try testing.expectEqualStrings("development:org9:u1", k);
    const k2 = (try sidebarPinProfileKey(testing.allocator, .synced, &auth, null)).?;
    defer testing.allocator.free(k2);
    try testing.expectEqualStrings("synced:o:u1@org9", k2);
    try testing.expect((try sidebarPinProfileKey(testing.allocator, .synced, null, null)) == null);

    const base: UiSettings = .{};
    var edited = base;
    edited.diffSplit = true;
    var current = base;
    current.sidebarCollapsed = true;
    const merged = UiSettings.mergeChanges(&base, &edited, current);
    try testing.expect(merged.diffSplit and merged.sidebarCollapsed);
}
