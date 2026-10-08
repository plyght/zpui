//! Settings → Appearance → Use SF Symbols (Zig client addition, macOS only):
//! control icons draw as Apple's SF Symbols instead of zeron's SVGs (the
//! mapping is `ui/components/icon.zig`). On by default; off restores the SVGs.
//!
//! Stored in its own `sf-symbols.json` (`{"enabled":true}`): the Rust app
//! rewrites `ui-settings.json` from a typed struct and drops unknown keys, so a
//! sidecar file it never opens is the only safe place (the
//! `new-thread-background-fade.json` pattern, `background_fade.zig`).
//!
//! ```zig
//! sf_symbols.init(app, io, data_dir);   // boot
//! sf_symbols.enabled(app)               // macOS and the setting on
//! sf_symbols.set(app, false);           // saves + refreshes windows
//! ```

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const json = std.json;
const Io = std.Io;
const zpui = @import("zpui");

const App = zpui.App;
const log = std.log.scoped(.zeron_sf_symbols);

pub const file_name = "sf-symbols.json";
/// The setting exists only where SF Symbols do.
pub const supported = builtin.os.tag == .macos;
pub const default = true;

// ---- file -------------------------------------------------------------------

const Stored = struct { enabled: bool };

/// Parse the file's text; the default when missing, corrupt or not a bool.
pub fn parse(gpa: Allocator, text: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = json.parseFromSliceLeaky(json.Value, arena.allocator(), text, .{}) catch |err| {
        log.warn("{s} corrupt; using the default ({t})", .{ file_name, err });
        return default;
    };
    if (root != .object) return default;
    const v = root.object.get("enabled") orelse return default;
    return if (v == .bool) v.bool else default;
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

pub const SfSymbolsStore = struct {
    gpa: Allocator,
    io: ?Io,
    data_dir: []u8,
    /// False for an in-memory store (fixture mode, tests): nothing is written.
    persist: bool,
    value: bool,

    pub fn deinit(self: *SfSymbolsStore, _: *App) void {
        self.gpa.free(self.data_dir);
    }
};

/// Load `data_dir`'s file and install the (persisting) global.
pub fn init(app: *App, io: Io, data_dir: []const u8) !void {
    const dir = try app.gpa.dupe(u8, data_dir);
    errdefer app.gpa.free(dir);
    try app.setGlobal(SfSymbolsStore{ .gpa = app.gpa, .io = io, .data_dir = dir, .persist = true, .value = load(app.gpa, io, data_dir) });
}

/// A read-only store seeded from `data_dir` (fixture runs); never written.
pub fn initMemoryFrom(app: *App, io: Io, data_dir: []const u8) !void {
    const dir = try app.gpa.dupe(u8, "");
    errdefer app.gpa.free(dir);
    try app.setGlobal(SfSymbolsStore{ .gpa = app.gpa, .io = io, .data_dir = dir, .persist = false, .value = load(app.gpa, io, data_dir) });
}

/// An in-memory store holding `value` (never written).
pub fn initMemory(app: *App, value: bool) !void {
    const dir = try app.gpa.dupe(u8, "");
    errdefer app.gpa.free(dir);
    try app.setGlobal(SfSymbolsStore{ .gpa = app.gpa, .io = null, .data_dir = dir, .persist = false, .value = value });
}

/// The stored choice (the default when no store is installed), on any OS.
pub fn current(app: *App) bool {
    const s = app.tryGlobal(SfSymbolsStore) orelse return default;
    return s.value;
}

/// Whether icons should draw as SF Symbols: macOS and the setting on.
pub fn enabled(app: *App) bool {
    return supported and current(app);
}

/// Choose `on`: saved (persisting stores) and every window repaints.
pub fn set(app: *App, on: bool) void {
    if (!app.hasGlobal(SfSymbolsStore)) initMemory(app, default) catch return;
    if (current(app) == on) return;
    const Run = struct {
        fn run(v: bool, s: *SfSymbolsStore, _: *App) void {
            s.value = v;
            if (!s.persist) return;
            const io = s.io orelse return;
            save(v, s.gpa, io, s.data_dir) catch |err| log.warn("{s} save failed: {t}", .{ file_name, err });
        }
    };
    app.updateGlobal(SfSymbolsStore, on, Run.run);
    app.refreshWindows();
}

// ---- tests --------------------------------------------------------------------

const testing = std.testing;

test "sf symbols setting round-trips through its file text" {
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

test "a missing, corrupt or odd sf symbols file reads as on" {
    const gpa = testing.allocator;
    try testing.expect(parse(gpa, "{"));
    try testing.expect(parse(gpa, "[]"));
    try testing.expect(parse(gpa, "{\"enabled\":\"no\"}"));
    try testing.expect(!parse(gpa, "{\"enabled\":false,\"later\":1}"));
}

test "sf symbols setting persists to its own file" {
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

test "set updates the in-memory store; enabled is macOS-only" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    try testing.expect(current(app));
    set(app, false);
    try testing.expect(!current(app));
    try testing.expect(!enabled(app));
    set(app, true);
    try testing.expectEqual(supported, enabled(app));
}
