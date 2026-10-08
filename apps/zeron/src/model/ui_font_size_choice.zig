//! Whether the user ever chose the interface font size (Zig client addition).
//!
//! The system font (SF Pro on macOS) reads large at the 16 px default that suits
//! Geist, so while the interface font is the system font and the size was never
//! chosen, the UI renders at 14 px (`typography.effectiveUiFontSize`). Switching
//! back to Geist returns to 16; a size picked in Settings is never overridden.
//!
//! `ui-settings.json` always carries `uiFontSize` (the Rust app writes it from a
//! typed struct and drops unknown keys), so "never chosen" can't be told from it:
//! the flag lives in its own `ui-font-size-chosen.json` (`{"chosen":true}`), the
//! `new-thread-defaults.json` pattern (`composer_store.zig`).
//!
//! ```zig
//! ui_font_size_choice.init(app, io, data_dir);   // boot
//! ui_font_size_choice.current(app)               // false without a file
//! ui_font_size_choice.set(app, true);            // the size select was used
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Io = std.Io;
const zpui = @import("zpui");

const App = zpui.App;
const log = std.log.scoped(.zeron_ui_font_size_choice);

pub const file_name = "ui-font-size-chosen.json";

const Stored = struct { chosen: bool };

/// Parse the file's text; false (never chosen) when missing, corrupt or unknown.
pub fn parse(gpa: Allocator, text: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = json.parseFromSliceLeaky(json.Value, arena.allocator(), text, .{}) catch |err| {
        log.warn("{s} corrupt; treating the size as never chosen ({t})", .{ file_name, err });
        return false;
    };
    if (root != .object) return false;
    const v = root.object.get("chosen") orelse return false;
    return v == .bool and v.bool;
}

/// The file's JSON text (caller frees).
pub fn serialize(gpa: Allocator, chosen: bool) Allocator.Error![]u8 {
    return json.Stringify.valueAlloc(gpa, Stored{ .chosen = chosen }, .{ .whitespace = .indent_2 });
}

pub fn load(gpa: Allocator, io: Io, data_dir: []const u8) bool {
    const p = std.fs.path.join(gpa, &.{ data_dir, file_name }) catch return false;
    defer gpa.free(p);
    const text = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 16)) catch return false;
    defer gpa.free(text);
    return parse(gpa, text);
}

/// Write atomically (temp file + rename).
pub fn save(chosen: bool, gpa: Allocator, io: Io, data_dir: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, data_dir);
    const final = try std.fs.path.join(gpa, &.{ data_dir, file_name });
    defer gpa.free(final);
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.{x}.tmp", .{ final, std.mem.readInt(u64, &rnd, .little) });
    defer gpa.free(tmp);
    const text = try serialize(gpa, chosen);
    defer gpa.free(text);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text }) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
    try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), final, io);
}

// ---- the global ---------------------------------------------------------------

pub const UiFontSizeChoiceStore = struct {
    gpa: Allocator,
    io: ?Io,
    data_dir: []u8,
    /// False for an in-memory store (fixture mode, tests): nothing is written.
    persist: bool,
    chosen: bool,

    pub fn deinit(self: *UiFontSizeChoiceStore, _: *App) void {
        self.gpa.free(self.data_dir);
    }
};

/// Load `data_dir`'s file and install the (persisting) global.
pub fn init(app: *App, io: Io, data_dir: []const u8) !void {
    const dir = try app.gpa.dupe(u8, data_dir);
    errdefer app.gpa.free(dir);
    try app.setGlobal(UiFontSizeChoiceStore{ .gpa = app.gpa, .io = io, .data_dir = dir, .persist = true, .chosen = load(app.gpa, io, data_dir) });
}

/// A read-only store seeded from `data_dir` (fixture runs); never written.
pub fn initMemoryFrom(app: *App, io: Io, data_dir: []const u8) !void {
    const dir = try app.gpa.dupe(u8, "");
    errdefer app.gpa.free(dir);
    try app.setGlobal(UiFontSizeChoiceStore{ .gpa = app.gpa, .io = io, .data_dir = dir, .persist = false, .chosen = load(app.gpa, io, data_dir) });
}

/// An in-memory store (never written).
pub fn initMemory(app: *App) !void {
    const dir = try app.gpa.dupe(u8, "");
    errdefer app.gpa.free(dir);
    try app.setGlobal(UiFontSizeChoiceStore{ .gpa = app.gpa, .io = null, .data_dir = dir, .persist = false, .chosen = false });
}

/// Whether the user chose the interface size (false when no store is installed).
pub fn current(app: *App) bool {
    const s = app.tryGlobal(UiFontSizeChoiceStore) orelse return false;
    return s.chosen;
}

/// Record the choice (saved for persisting stores).
pub fn set(app: *App, chosen: bool) void {
    if (!app.hasGlobal(UiFontSizeChoiceStore)) initMemory(app) catch return;
    if (current(app) == chosen) return;
    const Run = struct {
        fn run(c: bool, s: *UiFontSizeChoiceStore, _: *App) void {
            s.chosen = c;
            if (!s.persist) return;
            const io = s.io orelse return;
            save(c, s.gpa, io, s.data_dir) catch |err| log.warn("{s} save failed: {t}", .{ file_name, err });
        }
    };
    app.updateGlobal(UiFontSizeChoiceStore, chosen, Run.run);
}

// ---- tests --------------------------------------------------------------------

const testing = std.testing;

test "font size choice round-trips through its file text" {
    const gpa = testing.allocator;
    for ([_]bool{ false, true }) |c| {
        const text = try serialize(gpa, c);
        defer gpa.free(text);
        try testing.expectEqual(c, parse(gpa, text));
    }
    const text = try serialize(gpa, true);
    defer gpa.free(text);
    try testing.expectEqualStrings("{\n  \"chosen\": true\n}", text);
}

test "a missing, corrupt or odd font size choice reads as never chosen" {
    const gpa = testing.allocator;
    try testing.expect(!parse(gpa, "{"));
    try testing.expect(!parse(gpa, "[]"));
    try testing.expect(!parse(gpa, "{\"chosen\":1}"));
    try testing.expect(!parse(gpa, "{\"chosen\":\"yes\"}"));
    try testing.expect(parse(gpa, "{\"chosen\":true,\"later\":3}"));
}

test "font size choice persists in its own file" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(dir);
    try testing.expect(!load(gpa, io, dir));
    try save(true, gpa, io, dir);
    try testing.expect(load(gpa, io, dir));
    try save(false, gpa, io, dir);
    try testing.expect(!load(gpa, io, dir));
}
