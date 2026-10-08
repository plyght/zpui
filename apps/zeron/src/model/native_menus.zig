//! Settings → Appearance → Native menus (Zig client addition, macOS only): plain menus
//! (context menus, "⋯" menus, view options, ...) pop up as native NSMenus, and the
//! menus that stay custom (pickers, palette, ...) take the native metrics
//! (`ui/components/popover.zig`). Off restores the drawn menus and their look.
//! Default on; elsewhere the option does not exist and reads as off.
//!
//! Stored in its own `native-menus.json` (`{"enabled":true}`): the Rust app rewrites
//! `ui-settings.json` from a typed struct and drops unknown keys, so a sidecar file it
//! never opens is the only safe place (as `background_fade.zig`).
//!
//! ```zig
//! native_menus.init(app, io, data_dir);   // boot
//! native_menus.enabled(app)                // true on macOS without a file
//! native_menus.set(app, false);            // saves + refreshes windows
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const json = std.json;
const Io = std.Io;
const zpui = @import("zpui");

const App = zpui.App;
const log = std.log.scoped(.zeron_native_menus);

pub const file_name = "native-menus.json";

/// Whether this platform offers the option at all.
pub const available = builtin.os.tag == .macos;

pub const default = true;

/// The current value for code without an `App` at hand (popover styling): the
/// process has one app, and `init` / `set` keep this in step with its store.
var cached: bool = default;

/// Native menus + metrics are on (always false off macOS).
pub fn look() bool {
    return available and cached;
}

/// NSMenu metrics (macOS 26) for the native look of the custom popovers
/// (`ui/components/popover.zig`, the composer's `chrome.zig`).
pub const metrics = struct {
    pub const font_family = ".SystemUIFont";
    pub const font_size: f32 = 13;
    pub const card_radius: f32 = 12;
    /// Card padding around the rows (the selection's inset from the edge).
    pub const card_inset: f32 = 5;
    pub const row_height: f32 = 24;
    pub const row_padding_x: f32 = 10;
    pub const row_radius: f32 = metrics.card_radius - metrics.card_inset;
    pub const icon_gap: f32 = 6;
    pub const separator_inset_x: f32 = 10;
    pub const separator_margin_y: f32 = 5;
    pub const heading_size: f32 = 11;
    /// Fade-out when a menu closes (NSMenu dismisses in place, it does not travel).
    pub const exit_travel: f32 = 0;
    /// The selection text / icon color.
    pub const selected_text: zpui.Hsla = zpui.hsla(0, 0, 1, 1);

    /// NSMenu's window shadow: a wide soft drop plus a tight contact shadow.
    pub const shadow = [_]zpui.BoxShadow{
        .{ .color = zpui.hsla(0, 0, 0, 0.22), .offset = .{ .x = 0, .y = 8 }, .blur_radius = 24 },
        .{ .color = zpui.hsla(0, 0, 0, 0.12), .offset = .{ .x = 0, .y = 1 }, .blur_radius = 3 },
    };
};

// ---- file -------------------------------------------------------------------

const Stored = struct { enabled: bool };

/// Parse the file's text; the default when missing, corrupt or of the wrong shape.
pub fn parse(gpa: Allocator, text: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = json.parseFromSliceLeaky(json.Value, arena.allocator(), text, .{}) catch |err| {
        log.warn("{s} corrupt; using the default ({t})", .{ file_name, err });
        return default;
    };
    if (root != .object) return default;
    const v = root.object.get("enabled") orelse return default;
    if (v != .bool) return default;
    return v.bool;
}

/// The file's JSON text (caller frees).
pub fn serialize(gpa: Allocator, on: bool) Allocator.Error![]u8 {
    return json.Stringify.valueAlloc(gpa, Stored{ .enabled = on }, .{ .whitespace = .indent_2 });
}

pub fn load(gpa: Allocator, io: Io, data_dir: []const u8) bool {
    const p = std.fs.path.join(gpa, &.{ data_dir, file_name }) catch return default;
    defer gpa.free(p);
    const text = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 16)) catch return default;
    defer gpa.free(text);
    return parse(gpa, text);
}

/// Write atomically (temp file + rename).
pub fn save(on: bool, gpa: Allocator, io: Io, data_dir: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, data_dir);
    const final = try std.fs.path.join(gpa, &.{ data_dir, file_name });
    defer gpa.free(final);
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.{x}.tmp", .{ final, std.mem.readInt(u64, &rnd, .little) });
    defer gpa.free(tmp);
    const text = try serialize(gpa, on);
    defer gpa.free(text);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text }) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
    try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), final, io);
}

// ---- the global ---------------------------------------------------------------

pub const NativeMenusStore = struct {
    gpa: Allocator,
    io: ?Io,
    data_dir: []u8,
    /// False for an in-memory store (fixture mode, tests): nothing is written.
    persist: bool,
    value: bool,

    pub fn deinit(self: *NativeMenusStore, _: *App) void {
        self.gpa.free(self.data_dir);
    }
};

/// Load `data_dir`'s file and install the (persisting) global.
pub fn init(app: *App, io: Io, data_dir: []const u8) !void {
    const dir = try app.gpa.dupe(u8, data_dir);
    errdefer app.gpa.free(dir);
    const value = load(app.gpa, io, data_dir);
    try app.setGlobal(NativeMenusStore{ .gpa = app.gpa, .io = io, .data_dir = dir, .persist = true, .value = value });
    cached = value;
}

/// An in-memory store holding `value` (never written).
pub fn initMemory(app: *App, value: bool) !void {
    const dir = try app.gpa.dupe(u8, "");
    errdefer app.gpa.free(dir);
    try app.setGlobal(NativeMenusStore{ .gpa = app.gpa, .io = null, .data_dir = dir, .persist = false, .value = value });
    cached = value;
}

/// The stored choice (the default without a store), ignoring the platform.
pub fn stored(app: *App) bool {
    const s = app.tryGlobal(NativeMenusStore) orelse return default;
    return s.value;
}

/// Native menus are on for `app` (macOS and the option on).
pub fn enabled(app: *App) bool {
    return available and stored(app);
}

/// Turn native menus on / off: saved (persisting stores) and every window repaints.
pub fn set(app: *App, on: bool) void {
    if (!app.hasGlobal(NativeMenusStore)) initMemory(app, default) catch return;
    cached = on;
    if (stored(app) == on) return;
    const Run = struct {
        fn run(v: bool, s: *NativeMenusStore, _: *App) void {
            s.value = v;
            if (!s.persist) return;
            const io = s.io orelse return;
            save(v, s.gpa, io, s.data_dir) catch |err| log.warn("{s} save failed: {t}", .{ file_name, err });
        }
    };
    app.updateGlobal(NativeMenusStore, on, Run.run);
    app.refreshWindows();
}

/// Tests: force the process-wide look (popover metrics) without an app.
pub fn setLookForTesting(on: bool) void {
    cached = on;
}

// ---- tests --------------------------------------------------------------------

const testing = std.testing;

test "native menus round-trip through their file text" {
    const gpa = testing.allocator;
    for ([_]bool{ true, false }) |v| {
        const text = try serialize(gpa, v);
        defer gpa.free(text);
        try testing.expectEqual(v, parse(gpa, text));
    }
    const text = try serialize(gpa, false);
    defer gpa.free(text);
    try testing.expectEqualStrings("{\n  \"enabled\": false\n}", text);
}

test "a missing, corrupt or odd native-menus file reads as on" {
    const gpa = testing.allocator;
    try testing.expect(parse(gpa, "{"));
    try testing.expect(parse(gpa, "[]"));
    try testing.expect(parse(gpa, "{\"enabled\":\"no\"}"));
    try testing.expect(!parse(gpa, "{\"enabled\":false,\"later\":1}"));
}

test "native menus persist to their own file" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(dir);
    try testing.expect(load(gpa, io, dir));
    try save(false, gpa, io, dir);
    try testing.expect(!load(gpa, io, dir));
    try save(true, gpa, io, dir);
    try testing.expect(load(gpa, io, dir));
}
