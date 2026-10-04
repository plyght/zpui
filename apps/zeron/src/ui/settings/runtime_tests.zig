//! Runtime effects of Settings controls, end to end through the real Shell
//! (TestPlatform, reference fixtures, in-memory SettingsStore): each test
//! drives the control the way a click would and checks what changes in the
//! running app, not just the stored value.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const prefs_mod = @import("../shell/prefs.zig");
const fixtures_mod = @import("../shell/fixtures.zig");
const shell_mod = @import("../shell/shell.zig");
const background = @import("../background/root.zig");
const store = @import("store.zig");
const select = @import("select.zig");
const view_mod = @import("view.zig");
const prompts = @import("file_prompts.zig");
const fonts = @import("fonts.zig");
const motion = @import("motion.zig");
const adjust = @import("background_adjust.zig");
const appearance = @import("appearance.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestWindow = zpui.core.test_platform.TestWindow;
const SettingsView = view_mod.SettingsView;
const mod = if (builtin.os.tag == .macos) "cmd" else "ctrl";

const Harness = struct {
    app: *zpui.App,
    fixtures: *fixtures_mod.Fixtures,
    state: zpui.Entity(model.AppState),
    handle: zpui.WindowHandle(shell_mod.Shell),
    tmp: testing.TmpDir,
    root: []u8,

    fn init() !Harness {
        const app = try zpui.App.initTest(gpa);
        errdefer app.deinit();
        try actions.registerAll(app);
        try actions.keymap.applyKeymap(app, &.{}, .enter);
        const f = try fixtures_mod.load(gpa, io, "apps/zeron/fixtures/reference");
        f.meta.selectedChat = null;
        var prefs: prefs_mod.Prefs = .{ .gpa = gpa };
        fixtures_mod.applyPrefs(f, &prefs);
        try ui.theme.install(app, zt.Theme.dark());
        try prefs_mod.install(app, prefs);
        store.boot(app, io, .dark);
        const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false, .wake_mode = .poll } });
        fixtures_mod.applyToState(f, io, app, state);
        const handle = try app.openWindow(.{
            .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1600, .height = 1000 } },
        }, shell_mod.Shell, shell_mod.Shell.init, .{ state, f, true });
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [4096]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        return .{ .app = app, .fixtures = f, .state = state, .handle = handle, .tmp = tmp, .root = try gpa.dupe(u8, buf[0..n]) };
    }

    fn deinit(h: *Harness) void {
        prompts.override = null;
        h.state.release(h.app);
        h.app.deinit();
        h.fixtures.deinit();
        gpa.destroy(h.fixtures);
        h.tmp.cleanup();
        gpa.free(h.root);
    }

    fn tw(h: *Harness) *TestWindow {
        return TestWindow.of(h.handle.window(h.app).?.platform_window);
    }

    fn window(h: *Harness) *zpui.Window {
        return h.handle.window(h.app).?;
    }

    fn view(h: *Harness) ?zpui.Entity(SettingsView) {
        const root = h.handle.rootView(h.app) orelse return null;
        return root.read(h.app).settings_view;
    }

    fn settings(h: *Harness) *const model.UiSettings {
        return store.current(h.app);
    }

    fn openSettings(h: *Harness, section: view_mod.Section) zpui.Entity(SettingsView) {
        h.tw().typeKey(mod ++ "-,");
        h.app.runUntilParked();
        const v = h.view().?;
        v.update(h.app, openSection, .{section});
        h.frames(2);
        return v;
    }

    fn frames(h: *Harness, n: usize) void {
        for (0..n) |_| {
            h.window().drawAndPresent();
            h.app.runUntilParked();
            h.app.advanceClock(400 * std.time.ns_per_ms);
        }
    }

    fn png(h: *Harness, name: []const u8, rgba: [4]u8) ![]u8 {
        try background.cache.test_support.png(h.tmp.dir, name, 32, 16, rgba);
        return std.fs.path.join(gpa, &.{ h.root, name });
    }
};

fn openSection(v: *SettingsView, section: view_mod.Section, cx: *zpui.Context(SettingsView)) void {
    v.openSection(section, cx);
}

fn toggleFont(v: *SettingsView, kind: fonts.FontKind, window: *zpui.Window, cx: *zpui.Context(SettingsView)) void {
    fonts.toggle(v, kind, window, cx);
}

fn commitSelect(v: *SettingsView, id: select.SelectId, ix: usize, cx: *zpui.Context(SettingsView)) void {
    select.commit(v, id, ix, cx);
}

fn flipToggle(v: *SettingsView, which: select.Toggle, cx: *zpui.Context(SettingsView)) void {
    select.flip(v, which, cx);
}

/// The prompt answers (the dialog is bypassed in tests).
var answer_image: ?[]const u8 = null;
var answer_folder: ?[]const u8 = null;

fn answer(kind: prompts.Kind) ?[]const u8 {
    return switch (kind) {
        .background_image => answer_image,
        .wallpaper_folder => answer_folder,
        .theme_import => null,
    };
}

/// Run a page action the way its button's listener does.
fn act(h: *Harness, comptime f: anytype) void {
    h.view().?.update(h.app, f, .{});
    h.app.runUntilParked();
}

fn adjustZoomBy(v: *SettingsView, delta: f32, cx: *zpui.Context(SettingsView)) void {
    adjust.setZoom(v, v.adjust.?.draft.zoom + delta, cx);
}

fn typeChar(h: *Harness, ch: u8) void {
    const s: []const u8 = &.{ch};
    _ = h.tw().simulateInput(.{ .key_down = .{ .keystroke = .{ .key = s, .key_char = s } } });
    h.app.runUntilParked();
}

test "Choose image installs the picked file and the new-thread canvas paints it; Remove clears it" {
    var h = try Harness.init();
    defer h.deinit();
    const src = try h.png("dune.png", .{ 200, 140, 40, 255 });
    defer gpa.free(src);
    answer_image = src;
    prompts.override = answer;
    _ = h.openSettings(.appearance);
    act(&h, appearance.chooseBackground);
    h.frames(3);
    const bg = h.settings().newThreadComposerBackground orelse return error.NotInstalled;
    try testing.expectEqualStrings("dune.png", bg.name);
    try testing.expect(background.install.lastError(h.app) == null);
    try testing.expect(background.install.available(h.app, h.settings()));

    // Effect select → the cache renders that effect for the hero.
    const v = h.view().?;
    v.update(h.app, commitSelect, .{ select.SelectId.background_effect, 3 });
    try testing.expectEqual(model.settings.NewThreadBackgroundEffect.halftone, h.settings().newThreadBackgroundEffect);

    // Back on the canvas the hero shows the artwork.
    h.tw().typeKey("escape");
    h.frames(6);
    const panel = h.handle.rootView(h.app).?.read(h.app).main.read(h.app);
    try testing.expect(panel.artwork_ready.current != null);

    _ = h.openSettings(.appearance);
    act(&h, appearance.removeBackground);
    try testing.expect(h.settings().newThreadComposerBackground == null);
}

test "a missing image reads as unavailable and offers Replace / Remove" {
    var h = try Harness.init();
    defer h.deinit();
    const Set = struct {
        fn f(_: void, s: *model.UiSettings, _: std.mem.Allocator) void {
            s.newThreadComposerBackground = .{ .path = "/nonexistent/zeron/statue-cropped.jpg", .name = "statue-cropped.jpg" };
        }
    };
    store.update(h.app, .immediate, {}, Set.f);
    _ = h.openSettings(.appearance);
    try testing.expect(!background.install.available(h.app, h.settings()));
    // The canvas simply shows no artwork.
    h.tw().typeKey("escape");
    h.frames(4);
    const panel = h.handle.rootView(h.app).?.read(h.app).main.read(h.app);
    try testing.expect(panel.artwork_ready.current == null);
}

test "an unsupported file reports the Rust error under the row" {
    var h = try Harness.init();
    defer h.deinit();
    try h.tmp.dir.writeFile(io, .{ .sub_path = "notes.png", .data = "not an image" });
    const bad = try std.fs.path.join(gpa, &.{ h.root, "notes.png" });
    defer gpa.free(bad);
    answer_image = bad;
    prompts.override = answer;
    _ = h.openSettings(.appearance);
    act(&h, appearance.chooseBackground);
    h.frames(2);
    try testing.expectEqualStrings(background.install.msg_unsupported, background.install.lastError(h.app).?);
    try testing.expect(h.settings().newThreadComposerBackground == null);
}

test "Adjust: Apply persists only the draft, Cancel and Reset leave the saved framing" {
    var h = try Harness.init();
    defer h.deinit();
    const src = try h.png("wide.png", .{ 20, 80, 160, 255 });
    defer gpa.free(src);
    answer_image = src;
    prompts.override = answer;
    const v = h.openSettings(.appearance);
    act(&h, appearance.chooseBackground);
    h.frames(3);
    act(&h, adjust.open);
    h.frames(4); // preview raster
    try testing.expect(v.read(h.app).adjust != null);
    try testing.expect(v.read(h.app).adjust.?.source != null);
    // Zoom in twice with the + button, then Cancel: nothing saved.
    v.update(h.app, adjustZoomBy, .{adjust.zoom_step});
    v.update(h.app, adjustZoomBy, .{adjust.zoom_step});
    try testing.expectApproxEqAbs(@as(f32, 1.2), v.read(h.app).adjust.?.draft.zoom, 0.001);
    act(&h, adjust.close);
    try testing.expect(v.read(h.app).adjust == null);
    try testing.expectEqual(@as(f32, 1), h.settings().newThreadComposerBackground.?.adjustment.zoom);
    // Again, Apply this time.
    act(&h, adjust.open);
    h.frames(2);
    v.update(h.app, adjustZoomBy, .{adjust.zoom_step});
    act(&h, adjust.apply);
    try testing.expectApproxEqAbs(@as(f32, 1.1), h.settings().newThreadComposerBackground.?.adjustment.zoom, 0.001);
    // Reset returns the draft to the default framing (unsaved until Apply).
    act(&h, adjust.open);
    h.frames(2);
    act(&h, adjust.reset);
    try testing.expectEqual(@as(f32, 1), v.read(h.app).adjust.?.draft.zoom);
    h.tw().typeKey("escape");
    h.app.runUntilParked();
    try testing.expect(v.read(h.app).adjust == null);
    try testing.expect(h.view() != null); // Escape closed the dialog, not Settings
    try testing.expectApproxEqAbs(@as(f32, 1.1), h.settings().newThreadComposerBackground.?.adjustment.zoom, 0.001);
}

test "Choose folder sets the wallpaper folder and shuffles in an image; mod-u switches again" {
    var h = try Harness.init();
    defer h.deinit();
    try h.tmp.dir.createDirPath(io, "walls");
    for ([_][]const u8{ "walls/a.png", "walls/b.png", "walls/c.png" }, 0..) |name, i| {
        const p = try h.png(name, .{ @intCast(40 * i), 90, 200, 255 });
        gpa.free(p);
    }
    const folder = try std.fs.path.join(gpa, &.{ h.root, "walls" });
    defer gpa.free(folder);
    answer_folder = folder;
    prompts.override = answer;
    _ = h.openSettings(.appearance);
    act(&h, appearance.chooseFolder);
    h.frames(4);
    try testing.expectEqualStrings(folder, h.settings().wallpaperFolder.?);
    const first = h.settings().newThreadComposerBackground orelse return error.NoWallpaper;
    try testing.expect(std.mem.startsWith(u8, first.path, folder));
    const first_path = try gpa.dupe(u8, first.path);
    defer gpa.free(first_path);
    // mod-u on the canvas picks a different recent-avoiding image.
    h.tw().typeKey("escape");
    h.frames(4);
    h.tw().typeKey(mod ++ "-u");
    h.frames(4);
    try testing.expect(!std.mem.eql(u8, first_path, h.settings().newThreadComposerBackground.?.path));
}

test "mod-u without a folder opens Settings → Appearance and asks for one" {
    var h = try Harness.init();
    defer h.deinit();
    const Asked = struct {
        var kind: ?prompts.Kind = null;
        fn f(k: prompts.Kind) ?[]const u8 {
            kind = k;
            return null;
        }
    };
    prompts.override = Asked.f;
    h.tw().typeKey(mod ++ "-u");
    h.frames(2);
    const v = h.view() orelse return error.SettingsNotOpened;
    try testing.expectEqual(view_mod.Section.appearance, v.read(h.app).section);
    try testing.expectEqual(prompts.Kind.wallpaper_folder, Asked.kind.?);
}

test "Match wallpaper colors tints the theme from the background image" {
    var h = try Harness.init();
    defer h.deinit();
    const src = try h.png("red.png", .{ 220, 30, 40, 255 });
    defer gpa.free(src);
    answer_image = src;
    prompts.override = answer;
    const v = h.openSettings(.appearance);
    act(&h, appearance.chooseBackground);
    h.frames(2);
    try testing.expect(h.settings().theme.wallpaper_color != null);
    const before = ui.theme.get(h.app).accent;
    v.update(h.app, flipToggle, .{select.Toggle.match_wallpaper});
    const after = ui.theme.get(h.app).accent;
    try testing.expect(!std.meta.eql(before, after));
    // The accent leans red (hue near 0/360).
    try testing.expect(after.h < 0.08 or after.h > 0.92);
}

test "Reduce motion and Pause animations drive the window's reduced-motion flag" {
    var h = try Harness.init();
    defer h.deinit();
    const v = h.openSettings(.appearance);
    const w = h.window();
    try testing.expect(!w.prefersReducedMotion());
    v.update(h.app, commitSelect, .{ select.SelectId.reduce_motion, 1 }); // On
    try testing.expect(w.prefersReducedMotion());
    v.update(h.app, commitSelect, .{ select.SelectId.reduce_motion, 2 }); // Off
    try testing.expect(!w.prefersReducedMotion());
    // Pause in background: an inactive window holds still.
    v.update(h.app, flipToggle, .{select.Toggle.pause_animations});
    try testing.expect(h.settings().theme.pause_animations_in_background);
    w.active = false;
    motion.sync(w, h.app);
    try testing.expect(w.prefersReducedMotion());
    w.active = true;
    motion.sync(w, h.app);
    try testing.expect(!w.prefersReducedMotion());
}

test "font pickers: search narrows, Enter applies an installed family, the terminal stays monospace" {
    var h = try Harness.init();
    defer h.deinit();
    const saved = fonts.catalog;
    defer fonts.catalog = saved;
    var fams = [_]zpui.text.font_catalog.Family{
        .{ .name = "Arial", .fixed_width = false },
        .{ .name = "DejaVu Sans Mono", .fixed_width = true },
        .{ .name = "Noto Serif", .fixed_width = false },
    };
    fonts.catalog = .{ .families = &fams };
    const v = h.openSettings(.appearance);
    v.update(h.app, toggleFont, .{ fonts.FontKind.ui, h.window() });
    try testing.expectEqual(fonts.FontKind.ui, v.read(h.app).fonts.open.?);
    h.frames(1); // the search field mounts (and takes focus)
    // Type "ser" → only Noto Serif; Enter applies it.
    for ("ser") |ch| typeChar(&h, ch);
    h.tw().typeKey("enter");
    h.app.runUntilParked();
    try testing.expect(v.read(h.app).fonts.open == null);
    try testing.expectEqualStrings("Noto Serif", h.settings().theme.ui_font_family.installed);
    try testing.expectEqualStrings("Noto Serif", ui.theme.get(h.app).font_sans);
    // A proportional family is not offered (nor applied) for the terminal.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    for (fonts.choices(arena.allocator(), .terminal)) |f| if (f == .installed) try testing.expect(!std.mem.eql(u8, f.installed, "Arial"));
    // A saved family that disappeared renders as the fallback, saved value kept.
    fonts.catalog = .{ .families = fams[0..1] };
    store.applyTheme(h.app);
    try testing.expectEqualStrings("Geist", ui.theme.get(h.app).font_sans);
    try testing.expectEqualStrings("Noto Serif", h.settings().theme.ui_font_family.installed);
}

const theme_library = @import("theme_library.zig");
const input_mod = @import("zeron_input");

fn setImportText(v: *SettingsView, text: []const u8, cx: *zpui.Context(SettingsView)) void {
    v.import.?.input.update(cx, input_mod.TextInput.setText, .{text});
}

fn variantIndex(id: []const u8) usize {
    var it = zt.registry.active().variantsFor(.dark);
    var i: usize = 0;
    while (it.next()) |variant| : (i += 1) if (std.mem.eql(u8, variant.id, id)) return i;
    return std.math.maxInt(usize);
}

test "Add theme imports a VS Code theme into the library, the dark list and the live theme; Remove reconciles" {
    var h = try Harness.init();
    defer h.deinit();
    try h.tmp.dir.writeFile(io, .{ .sub_path = "midnight.json", .data =
        \\{ // JSONC
        \\  "name": "Midnight", "type": "dark",
        \\  "colors": { "editor.background": "#0b1020", "foreground": "#d6deeb", "focusBorder": "#7fdbca", },
        \\  "tokenColors": [ { "scope": "keyword", "settings": { "foreground": "#c792ea" } } ]
        \\}
    });
    const path = try std.fs.path.join(gpa, &.{ h.root, "midnight.json" });
    defer gpa.free(path);
    const v = h.openSettings(.appearance);
    act(&h, theme_library.openImport);
    h.frames(1);
    try testing.expect(v.read(h.app).import != null);
    // Analyze with an empty source → the Rust message.
    act(&h, theme_library.submit);
    try testing.expectEqualStrings("Choose a local theme file or extension folder.", v.read(h.app).import.?.err.?);
    v.update(h.app, setImportText, .{path});
    act(&h, theme_library.submit); // analyze
    const d = v.read(h.app).import.?;
    try testing.expect(d.compilation != null);
    try testing.expectEqual(@as(usize, 1), d.selected.items.len);
    act(&h, theme_library.submit); // import selected
    try testing.expect(v.read(h.app).import == null);
    const lib = theme_library.entries(h.app);
    try testing.expectEqual(@as(usize, 1), lib.len);
    try testing.expectEqualStrings("custom-midnight", lib[0].id);
    // The variant joins the dark list; picking it re-themes the app.
    const ix = variantIndex("custom-midnight");
    try testing.expect(ix != std.math.maxInt(usize));
    v.update(h.app, commitSelect, .{ select.SelectId.dark_theme, ix });
    try testing.expectEqualStrings("custom-midnight", ui.theme.get(h.app).variant_id);
    // Remove: the selection falls back to an existing dark variant.
    var diag: zt.vscode.Diagnostic = .{};
    try testing.expect(theme_library.run(h.app, .remove, "custom-midnight", &diag));
    try testing.expectEqual(@as(usize, 0), theme_library.entries(h.app).len);
    try testing.expect(zt.registry.active().variant(h.settings().theme.theme_selection.dark) != null);
    try testing.expect(!std.mem.eql(u8, "custom-midnight", ui.theme.get(h.app).variant_id));
}

test "Escape closes the import dialog before Settings" {
    var h = try Harness.init();
    defer h.deinit();
    const v = h.openSettings(.appearance);
    act(&h, theme_library.openImport);
    h.frames(1);
    h.tw().typeKey("escape");
    h.app.runUntilParked();
    try testing.expect(v.read(h.app).import == null);
    try testing.expect(h.view() != null);
}
