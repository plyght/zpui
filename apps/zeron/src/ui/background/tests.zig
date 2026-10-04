//! New-thread background: install / remove / effects / wallpaper rotation
//! against a real `SettingsStore` in a temp data dir, and the hero in the
//! shell's new-thread canvas.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const prefs_mod = @import("../shell/prefs.zig");
const fixtures_mod = @import("../shell/fixtures.zig");
const shell_mod = @import("../shell/shell.zig");
const store = @import("../settings/store.zig");
const cache = @import("cache.zig");
const install = @import("install.zig");
const wallpaper = @import("wallpaper.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

const Env = struct {
    tmp: testing.TmpDir,
    root: []u8,
    data: []u8,
    app: *zpui.App,

    fn init() !Env {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try cache.test_support.path(tmp.dir, "");
        errdefer gpa.free(root);
        const data = try std.fs.path.join(gpa, &.{ root, "data" });
        errdefer gpa.free(data);
        const app = try zpui.App.initTest(gpa);
        errdefer app.deinit();
        try ui.theme.install(app, zt.Theme.dark());
        try model.settings_store.init(app, io, data);
        return .{ .tmp = tmp, .root = root, .data = data, .app = app };
    }

    fn deinit(e: *Env) void {
        e.app.deinit();
        gpa.free(e.data);
        gpa.free(e.root);
        e.tmp.cleanup();
    }

    fn png(e: *Env, name: []const u8, rgba: [4]u8) ![]u8 {
        try cache.test_support.png(e.tmp.dir, name, 16, 8, rgba);
        return std.fs.path.join(gpa, &.{ e.root, name });
    }

    fn settings(e: *Env) *const model.UiSettings {
        return store.current(e.app);
    }

    fn exists(path: []const u8) bool {
        _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
        return true;
    }
};

test "choosing an image copies it into the data dir, persists, and records the wallpaper color" {
    var e = try Env.init();
    defer e.deinit();
    const src = try e.png("dune.png", .{ 30, 70, 200, 255 });
    defer gpa.free(src);
    install.installAsync(e.app, src);
    e.app.runUntilParked();
    try testing.expect(install.lastError(e.app) == null);
    const bg = e.settings().newThreadComposerBackground.?;
    try testing.expectEqualStrings("dune.png", bg.name);
    try testing.expect(install.isManaged(e.data, bg.path));
    try testing.expect(std.mem.startsWith(u8, std.fs.path.basename(bg.path), "new-thread-background-"));
    try testing.expect(Env.exists(bg.path));
    try testing.expectEqualStrings(src, e.settings().wallpaperSource.?);
    try testing.expectEqualStrings(src, e.settings().wallpaperHistory[0]);
    const c = e.settings().theme.wallpaper_color.?;
    try testing.expect(c.b > c.r);
    // Persisted to ui-settings.json.
    var loaded = try model.settings.load(gpa, io, e.data);
    defer loaded.deinit();
    try testing.expectEqualStrings(bg.path, loaded.value.newThreadComposerBackground.?.path);
    // The decoded proxy seeded the cache: the hero needs no file read.
    try testing.expectEqual(cache.Status.ready, cache.status(e.app, bg.path).?);

    // Replacing retires the old managed copy.
    const old = try gpa.dupe(u8, bg.path);
    defer gpa.free(old);
    const src2 = try e.png("sea.png", .{ 10, 200, 90, 255 });
    defer gpa.free(src2);
    install.installAsync(e.app, src2);
    e.app.runUntilParked();
    try testing.expect(!Env.exists(old));
    try testing.expectEqualStrings("sea.png", e.settings().newThreadComposerBackground.?.name);
    try testing.expectEqualStrings(src2, e.settings().wallpaperHistory[0]);
    try testing.expectEqualStrings(src, e.settings().wallpaperHistory[1]);

    // Remove deletes the managed file and clears source + color.
    const cur = try gpa.dupe(u8, e.settings().newThreadComposerBackground.?.path);
    defer gpa.free(cur);
    try testing.expect(install.remove(e.app) == null);
    try testing.expect(e.settings().newThreadComposerBackground == null);
    try testing.expect(e.settings().wallpaperSource == null);
    try testing.expect(e.settings().theme.wallpaper_color == null);
    try testing.expect(!Env.exists(cur));
}

test "an unsupported or damaged image is refused without touching the current background" {
    var e = try Env.init();
    defer e.deinit();
    try e.tmp.dir.writeFile(io, .{ .sub_path = "broken.png", .data = "definitely not a png" });
    const bad = try std.fs.path.join(gpa, &.{ e.root, "broken.png" });
    defer gpa.free(bad);
    install.installAsync(e.app, bad);
    e.app.runUntilParked();
    try testing.expectEqualStrings(install.msg_unsupported, install.lastError(e.app).?);
    try testing.expect(e.settings().newThreadComposerBackground == null);
    const txt = try std.fs.path.join(gpa, &.{ e.root, "notes.txt" });
    defer gpa.free(txt);
    install.installAsync(e.app, txt);
    e.app.runUntilParked();
    try testing.expectEqualStrings("notes.txt is not a supported image.", install.lastError(e.app).?);
}

test "effect and framing changes persist immediately; a hand-edited path is never deleted" {
    var e = try Env.init();
    defer e.deinit();
    const src = try e.png("hand.png", .{ 1, 2, 3, 255 });
    defer gpa.free(src);
    const Set = struct {
        fn f(p: []const u8, s: *model.UiSettings, a: std.mem.Allocator) void {
            s.newThreadComposerBackground = .{ .path = a.dupe(u8, p) catch return, .name = "hand.png" };
        }
    };
    store.update(e.app, .immediate, src, Set.f);
    install.setEffect(e.app, .halftone);
    install.setAdjustment(e.app, .{ .focalX = 2, .focalY = 0.25, .zoom = 9 });
    var loaded = try model.settings.load(gpa, io, e.data);
    defer loaded.deinit();
    try testing.expectEqual(model.settings.NewThreadBackgroundEffect.halftone, loaded.value.newThreadBackgroundEffect);
    const adj = loaded.value.newThreadComposerBackground.?.adjustment;
    try testing.expectEqual(@as(f32, 1), adj.focalX);
    try testing.expectEqual(@as(f32, 4), adj.zoom);
    try testing.expect(install.remove(e.app) == null);
    try testing.expect(Env.exists(src));
}

test "wallpaper colors: enabling backfills a missing color and re-tints the theme" {
    var e = try Env.init();
    defer e.deinit();
    const src = try e.png("tint.png", .{ 220, 40, 60, 255 });
    defer gpa.free(src);
    const Set = struct {
        fn f(p: []const u8, s: *model.UiSettings, a: std.mem.Allocator) void {
            s.newThreadComposerBackground = .{ .path = a.dupe(u8, p) catch return, .name = "tint.png" };
        }
    };
    store.update(e.app, .immediate, src, Set.f);
    store.applyTheme(e.app);
    const before = ui.theme.get(e.app).accent;
    install.setWallpaperColors(e.app, true);
    e.app.runUntilParked();
    const c = e.settings().theme.wallpaper_color.?;
    try testing.expect(c.r > c.b);
    try testing.expect(!std.meta.eql(before, ui.theme.get(e.app).accent));
    install.setWallpaperColors(e.app, false);
    try testing.expect(std.meta.eql(before, ui.theme.get(e.app).accent));
}

test "wallpaper folder: preload keeps three warm candidates and a switch commits one without reading files" {
    var e = try Env.init();
    defer e.deinit();
    try e.tmp.dir.createDirPath(io, "walls");
    var buf: [32]u8 = undefined;
    for (0..6) |i| {
        const name = try std.fmt.bufPrint(&buf, "walls/{d}.png", .{i});
        const p = try e.png(name, .{ @intCast(i * 30), 100, 200, 255 });
        gpa.free(p);
    }
    const folder = try std.fs.path.join(gpa, &.{ e.root, "walls" });
    defer gpa.free(folder);
    const Set = struct {
        fn f(p: []const u8, s: *model.UiSettings, a: std.mem.Allocator) void {
            s.wallpaperFolder = a.dupe(u8, p) catch return;
            s.newThreadBackgroundEffect = .ascii;
        }
    };
    store.update(e.app, .immediate, folder, Set.f);
    wallpaper.preload(e.app);
    e.app.runUntilParked();
    try testing.expectEqual(@as(usize, wallpaper.lookahead), wallpaper.readyCount(e.app));
    try testing.expect(e.settings().newThreadComposerBackground == null);
    const jobs = cache.jobsStarted(e.app);
    wallpaper.randomize(e.app, .settings);
    // Committed synchronously from the warm queue.
    const bg = e.settings().newThreadComposerBackground.?;
    try testing.expect(install.isManaged(e.data, bg.path));
    try testing.expect(std.mem.startsWith(u8, e.settings().wallpaperSource.?, folder));
    // The preloaded raster is installed for the exact managed path.
    const light = ui.theme.get(e.app).appearance == .light;
    try testing.expect(cache.prepare(e.app, io, bg.path, .ascii, light) != null);
    try testing.expectEqual(jobs, cache.jobsStarted(e.app));
    e.app.runUntilParked();
    try testing.expectEqual(@as(usize, wallpaper.lookahead), wallpaper.readyCount(e.app));
    // Successive shuffles never repeat the previous pick.
    var last = try gpa.dupe(u8, e.settings().wallpaperSource.?);
    defer gpa.free(last);
    for (0..4) |_| {
        wallpaper.randomize(e.app, .settings);
        e.app.runUntilParked();
        const now = e.settings().wallpaperSource.?;
        try testing.expect(!std.mem.eql(u8, now, last));
        gpa.free(last);
        last = try gpa.dupe(u8, now);
    }
    // Only the active managed copy plus the lookahead's prewritten copies exist.
    const dir_path = try std.fs.path.join(gpa, &.{ e.data, install.backgrounds_dir });
    defer gpa.free(dir_path);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try testing.expectEqual(@as(usize, 1 + wallpaper.lookahead), n);
}

test "wallpaper errors: no folder, unreadable folder, empty folder" {
    var e = try Env.init();
    defer e.deinit();
    wallpaper.randomize(e.app, .settings);
    try testing.expectEqualStrings(wallpaper.msg_no_folder, install.lastError(e.app).?);
    try e.tmp.dir.createDirPath(io, "empty");
    const empty = try std.fs.path.join(gpa, &.{ e.root, "empty" });
    defer gpa.free(empty);
    wallpaper.setFolder(e.app, empty);
    e.app.runUntilParked();
    try testing.expectEqualStrings(wallpaper.msg_no_images, install.lastError(e.app).?);
    wallpaper.setFolder(e.app, "/nonexistent/zeron-walls");
    e.app.runUntilParked();
    try testing.expectEqualStrings(wallpaper.msg_unreadable_folder, install.lastError(e.app).?);
}

// ---- the hero in the shell ----------------------------------------------------

fn openShell(app: *zpui.App, f: *fixtures_mod.Fixtures) !struct { zpui.Entity(model.AppState), zpui.WindowHandle(shell_mod.Shell) } {
    try actions.registerAll(app);
    try actions.keymap.applyKeymap(app, &.{}, .enter);
    var prefs: prefs_mod.Prefs = .{ .gpa = gpa };
    fixtures_mod.applyPrefs(f, &prefs);
    try prefs_mod.install(app, prefs);
    store.boot(app, io, .dark);
    const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false, .wake_mode = .poll } });
    fixtures_mod.applyToState(f, io, app, state);
    const handle = try app.openWindow(.{ .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1400, .height = 900 } } }, shell_mod.Shell, shell_mod.Shell.init, .{ state, f, true });
    return .{ state, handle };
}

test "the new-thread canvas paints the background around the measured composer" {
    var e = try Env.init();
    defer e.deinit();
    const f = try fixtures_mod.load(gpa, io, "apps/zeron/fixtures/reference");
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    f.meta.selectedChat = null;
    const state, const handle = try openShell(e.app, f);
    defer state.release(e.app);
    const src = try e.png("hero.png", .{ 200, 120, 40, 255 });
    defer gpa.free(src);
    install.installAsync(e.app, src);
    e.app.runUntilParked();
    const bg_path = e.settings().newThreadComposerBackground.?.path;
    // Draw until the raster is ready and adopted.
    const window = handle.window(e.app).?;
    for (0..6) |_| {
        window.drawAndPresent();
        e.app.runUntilParked();
        e.app.advanceClock(400 * std.time.ns_per_ms);
    }
    const shell = handle.rootView(e.app).?;
    const panel = shell.read(e.app).main.read(e.app);
    try testing.expect(panel.slots.composer_view.read(e.app).surface_bounds != null);
    try testing.expect(panel.artwork_ready.current != null);
    try testing.expectEqual(cache.Status.ready, cache.status(e.app, bg_path).?);
    // Removing the background clears the hero.
    _ = install.remove(e.app);
    for (0..3) |_| {
        window.drawAndPresent();
        e.app.runUntilParked();
        e.app.advanceClock(400 * std.time.ns_per_ms); // past the 180ms crossfade
    }
    try testing.expect(shell.read(e.app).main.read(e.app).artwork_ready.current == null);
}
