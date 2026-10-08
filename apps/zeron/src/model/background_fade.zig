//! Settings → Appearance → Background fade (Zig client addition): how the
//! new-thread background blends into the window and around the composer.
//!
//! - `full`: the Rust app's treatment, unchanged (a fade over the hero's full
//!   height, a wide feathered composer cutout revealed at half strength).
//! - `subtle` (default): a short fade near the hero's bottom edge, a small
//!   gentle feather around the composer, the cutout revealed at 0.82.
//! - `none`: no fade and no cutout; the artwork runs edge to edge.
//!
//! Stored in its own `new-thread-background-fade.json` (`{"fade":"subtle"}`):
//! the Rust app rewrites `ui-settings.json` from a typed struct and drops
//! unknown keys, so a sidecar file it never opens is the only safe place
//! (the `new-thread-defaults.json` pattern, `composer_store.zig`).
//!
//! ```zig
//! background_fade.init(app, io, data_dir);       // boot
//! const fade = background_fade.current(app);     // .subtle without a file
//! background_fade.set(app, .full);               // saves + refreshes windows
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const Io = std.Io;
const zpui = @import("zpui");

const App = zpui.App;
const log = std.log.scoped(.zeron_background_fade);

pub const file_name = "new-thread-background-fade.json";

pub const BackgroundFade = enum {
    full,
    subtle,
    none,

    pub const default: BackgroundFade = .subtle;
    /// Menu order (Settings → Appearance).
    pub const all = [_]BackgroundFade{ .subtle, .full, .none };

    pub fn label(self: BackgroundFade) []const u8 {
        return switch (self) {
            .full => "Full",
            .subtle => "Subtle",
            .none => "None",
        };
    }

    pub fn description(self: BackgroundFade) []const u8 {
        return switch (self) {
            .full => "Fades the artwork over its full height and dims it around the composer.",
            .subtle => "A short fade at the bottom edge and a light touch around the composer.",
            .none => "Shows the artwork edge to edge, without a fade or a composer cutout.",
        };
    }

    /// Opacity of the artwork underlay inside the composer cutout
    /// (Rust `CUTOUT_REVEAL_OPACITY` for `full`); 1 = no cutout.
    pub fn cutoutReveal(self: BackgroundFade) f32 {
        return switch (self) {
            .full => 0.5,
            .subtle => 0.82,
            .none => 1.0,
        };
    }
};

// ---- file -------------------------------------------------------------------

const Stored = struct { fade: BackgroundFade };

/// Parse the file's text; the default when missing, corrupt or unknown (a
/// newer build's value reads as the default rather than failing).
pub fn parse(gpa: Allocator, text: []const u8) BackgroundFade {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const root = json.parseFromSliceLeaky(json.Value, arena.allocator(), text, .{}) catch |err| {
        log.warn("{s} corrupt; using the default ({t})", .{ file_name, err });
        return .default;
    };
    if (root != .object) return .default;
    const v = root.object.get("fade") orelse return .default;
    if (v != .string) return .default;
    return std.meta.stringToEnum(BackgroundFade, v.string) orelse .default;
}

/// The file's JSON text (caller frees).
pub fn serialize(gpa: Allocator, fade: BackgroundFade) Allocator.Error![]u8 {
    return json.Stringify.valueAlloc(gpa, Stored{ .fade = fade }, .{ .whitespace = .indent_2 });
}

pub fn load(gpa: Allocator, io: Io, data_dir: []const u8) BackgroundFade {
    const p = std.fs.path.join(gpa, &.{ data_dir, file_name }) catch return .default;
    defer gpa.free(p);
    const text = Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(1 << 16)) catch return .default;
    defer gpa.free(text);
    return parse(gpa, text);
}

/// Write atomically (temp file + rename).
pub fn save(fade: BackgroundFade, gpa: Allocator, io: Io, data_dir: []const u8) !void {
    try Io.Dir.cwd().createDirPath(io, data_dir);
    const final = try std.fs.path.join(gpa, &.{ data_dir, file_name });
    defer gpa.free(final);
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.{x}.tmp", .{ final, std.mem.readInt(u64, &rnd, .little) });
    defer gpa.free(tmp);
    const text = try serialize(gpa, fade);
    defer gpa.free(text);
    Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = text }) catch |err| {
        Io.Dir.cwd().deleteFile(io, tmp) catch {};
        return err;
    };
    try Io.Dir.rename(Io.Dir.cwd(), tmp, Io.Dir.cwd(), final, io);
}

// ---- the global ---------------------------------------------------------------

pub const BackgroundFadeStore = struct {
    gpa: Allocator,
    io: ?Io,
    data_dir: []u8,
    /// False for an in-memory store (fixture mode, tests): nothing is written.
    persist: bool,
    value: BackgroundFade,

    pub fn deinit(self: *BackgroundFadeStore, _: *App) void {
        self.gpa.free(self.data_dir);
    }
};

/// Load `data_dir`'s file and install the (persisting) global.
pub fn init(app: *App, io: Io, data_dir: []const u8) !void {
    const dir = try app.gpa.dupe(u8, data_dir);
    errdefer app.gpa.free(dir);
    try app.setGlobal(BackgroundFadeStore{ .gpa = app.gpa, .io = io, .data_dir = dir, .persist = true, .value = load(app.gpa, io, data_dir) });
}

/// A read-only store seeded from `data_dir` (fixture runs); never written.
pub fn initMemoryFrom(app: *App, io: Io, data_dir: []const u8) !void {
    const dir = try app.gpa.dupe(u8, "");
    errdefer app.gpa.free(dir);
    try app.setGlobal(BackgroundFadeStore{ .gpa = app.gpa, .io = io, .data_dir = dir, .persist = false, .value = load(app.gpa, io, data_dir) });
}

/// An in-memory store holding the default (never written).
pub fn initMemory(app: *App) !void {
    const dir = try app.gpa.dupe(u8, "");
    errdefer app.gpa.free(dir);
    try app.setGlobal(BackgroundFadeStore{ .gpa = app.gpa, .io = null, .data_dir = dir, .persist = false, .value = .default });
}

/// The current option (the default when no store is installed).
pub fn current(app: *App) BackgroundFade {
    const s = app.tryGlobal(BackgroundFadeStore) orelse return .default;
    return s.value;
}

/// Choose `fade`: saved (persisting stores) and every window repaints.
pub fn set(app: *App, fade: BackgroundFade) void {
    if (!app.hasGlobal(BackgroundFadeStore)) initMemory(app) catch return;
    if (current(app) == fade) return;
    const Run = struct {
        fn run(f: BackgroundFade, s: *BackgroundFadeStore, _: *App) void {
            s.value = f;
            if (!s.persist) return;
            const io = s.io orelse return;
            save(f, s.gpa, io, s.data_dir) catch |err| log.warn("{s} save failed: {t}", .{ file_name, err });
        }
    };
    app.updateGlobal(BackgroundFadeStore, fade, Run.run);
    app.refreshWindows();
}

// ---- tests --------------------------------------------------------------------

const testing = std.testing;

test "background fade round-trips through its file text" {
    const gpa = testing.allocator;
    for (std.enums.values(BackgroundFade)) |f| {
        const text = try serialize(gpa, f);
        defer gpa.free(text);
        try testing.expectEqual(f, parse(gpa, text));
    }
    const text = try serialize(gpa, .none);
    defer gpa.free(text);
    try testing.expectEqualStrings("{\n  \"fade\": \"none\"\n}", text);
}

test "a missing, corrupt or unknown fade reads as Subtle" {
    const gpa = testing.allocator;
    try testing.expectEqual(BackgroundFade.subtle, BackgroundFade.default);
    try testing.expectEqual(BackgroundFade.subtle, parse(gpa, "{"));
    try testing.expectEqual(BackgroundFade.subtle, parse(gpa, "[]"));
    try testing.expectEqual(BackgroundFade.subtle, parse(gpa, "{\"fade\":\"sparkle\"}"));
    try testing.expectEqual(BackgroundFade.subtle, parse(gpa, "{\"fade\":3}"));
    try testing.expectEqual(BackgroundFade.full, parse(gpa, "{\"fade\":\"full\",\"later\":true}"));
}

test "background fade persists to its own file" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(dir);
    try testing.expectEqual(BackgroundFade.subtle, load(gpa, io, dir));
    try save(.full, gpa, io, dir);
    try testing.expectEqual(BackgroundFade.full, load(gpa, io, dir));
    try save(.none, gpa, io, dir);
    try testing.expectEqual(BackgroundFade.none, load(gpa, io, dir));
}

test "cutout reveal per option keeps Full at the Rust constant" {
    try testing.expectEqual(@as(f32, 0.5), BackgroundFade.full.cutoutReveal());
    const s = BackgroundFade.subtle.cutoutReveal();
    try testing.expect(s >= 0.8 and s <= 0.85);
    try testing.expectEqual(@as(f32, 1.0), BackgroundFade.none.cutoutReveal());
}
