//! The menu bar and the `zeron::*` app-level actions (port of zeron
//! `crates/ui/src/app_menus.rs`).
//!
//! `install` registers the global handlers (once at boot); `refresh` (re)installs the
//! menu bar from `appMenus()` — call it after the keymap changes so the ⌘-key
//! equivalents follow the bindings (zpui renders them at `setMenus` time, like gpui).
//! macOS renders the bar natively; Linux has no global menu, and the same actions work
//! through the keymap (`keymap.zig` binds ⌘Q/⌘H/⌥⌘H/⌘M/⌘W on macOS and `ctrl-,`
//! everywhere, exactly like Rust's `app_key_bindings`).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const actions = @import("zeron_actions");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const lifecycle = @import("root.zig");
const app_update = @import("app_update.zig");
const update = @import("update.zig");

const App = zpui.App;
const MenuItem = zpui.MenuItem;
const Menu = zpui.Menu;
const z = actions.zeron;
const composer = actions.composer;
const shell = actions.shell;

const is_mac = builtin.os.tag == .macos;

/// The zeron menu bar (Rust `app_menus()`); mac-only entries are gated at comptime so
/// the structure is testable on Linux.
pub fn appMenus(comptime macos: bool) []const Menu {
    return comptime build(macos);
}

fn build(comptime macos: bool) []const Menu {
    const app_items = (&[_]MenuItem{
        // The native AppKit about panel; no equivalent elsewhere yet.
        MenuItem.action("About Zeron", z.About{}).disabledIf(!macos),
        // Sparkle's placement: directly under About.
        MenuItem.action("Check for Updates…", z.CheckForUpdates{}),
        .separator,
        MenuItem.action("Settings", shell.OpenSettings{}),
        .separator,
    }) ++ (if (macos) &[_]MenuItem{
        MenuItem.osSubmenu("Services", .services),
        .separator,
        MenuItem.action("Hide Zeron", z.Hide{}),
        MenuItem.action("Hide Others", z.HideOthers{}),
        MenuItem.action("Show All", z.ShowAll{}),
        .separator,
    } else &[_]MenuItem{}) ++ &[_]MenuItem{
        MenuItem.action("Quit Zeron", z.Quit{}),
    };
    const base = &[_]Menu{
        .{ .name = "Zeron", .items = app_items },
        // Clipboard verbs tied to the composer's actions via their native selectors, so
        // the OS routes them through the responder chain to native text fields too.
        .{ .name = "Edit", .items = &.{
            // Undo/Redo have no OsAction counterpart that AppKit would enable for us.
            MenuItem.action("Undo", composer.Undo{}),
            MenuItem.action("Redo", composer.Redo{}),
            .separator,
            MenuItem.osAction("Cut", composer.Cut{}, .cut),
            MenuItem.osAction("Copy", composer.Copy{}, .copy),
            MenuItem.osAction("Paste", composer.Paste{}, .paste),
            .separator,
            MenuItem.osAction("Select All", composer.SelectAll{}, .select_all),
        } },
        // Appearance lives under View on every platform.
        .{ .name = "View", .items = &.{
            MenuItem.action("Appearance: System", z.AppearanceSystem{}),
            MenuItem.action("Appearance: Light", z.AppearanceLight{}),
            MenuItem.action("Appearance: Dark", z.AppearanceDark{}),
        } },
    };
    if (!macos) return base;
    // Standard Window menu; macOS appends the open-window list itself.
    return base ++ &[_]Menu{.{ .name = "Window", .items = &.{
        MenuItem.action("Minimize", z.Minimize{}),
        MenuItem.action("Zoom", z.Zoom{}),
        .separator,
        MenuItem.action("Close Window", z.CloseWindow{}),
    } }};
}

/// Register the global handlers behind the menu bar and its shortcuts (once).
pub fn install(app: *App) !void {
    try app.onAction(z.Quit, {}, struct {
        fn f(_: void, _: *const z.Quit, a: *App) void {
            a.requestQuit();
        }
    }.f);
    try app.onAction(z.About, {}, struct {
        fn f(_: void, _: *const z.About, a: *App) void {
            a.platform.showAboutPanel(.{ .application_name = "Zeron", .version = update.currentVersion() });
        }
    }.f);
    // Global: must work with every window closed; the update lifecycle is app-wide.
    try app.onAction(z.CheckForUpdates, {}, struct {
        fn f(_: void, _: *const z.CheckForUpdates, a: *App) void {
            lifecycle.activateMainWindow(a);
            if (app_update.AppUpdate.global(a)) |u| u.update(a, app_update.AppUpdate.checkForUpdates, .{});
        }
    }.f);
    try app.onAction(z.Hide, {}, struct {
        fn f(_: void, _: *const z.Hide, a: *App) void {
            a.hide();
        }
    }.f);
    try app.onAction(z.HideOthers, {}, struct {
        fn f(_: void, _: *const z.HideOthers, a: *App) void {
            a.hideOtherApps();
        }
    }.f);
    try app.onAction(z.ShowAll, {}, struct {
        fn f(_: void, _: *const z.ShowAll, a: *App) void {
            a.unhideOtherApps();
        }
    }.f);
    try app.onAction(z.Minimize, {}, struct {
        fn f(_: void, _: *const z.Minimize, a: *App) void {
            if (a.activeWindow()) |w| w.minimizeWindow();
        }
    }.f);
    try app.onAction(z.Zoom, {}, struct {
        fn f(_: void, _: *const z.Zoom, a: *App) void {
            if (a.activeWindow()) |w| w.zoomWindow();
        }
    }.f);
    try app.onAction(z.CloseWindow, {}, struct {
        fn f(_: void, _: *const z.CloseWindow, a: *App) void {
            // Actions may arrive while a window is mid-dispatch: act after it.
            a.deferFn(a, struct {
                fn run(app_: *App, _: *App) void {
                    lifecycle.closeActiveWindow(app_);
                }
            }.run);
        }
    }.f);
    inline for (.{
        .{ z.AppearanceSystem, zt.settings.AppearanceMode.system },
        .{ z.AppearanceLight, zt.settings.AppearanceMode.light },
        .{ z.AppearanceDark, zt.settings.AppearanceMode.dark },
    }) |pair| {
        try app.onAction(pair[0], {}, struct {
            fn f(_: void, _: *const pair[0], a: *App) void {
                setAppearance(a, pair[1]);
            }
        }.f);
    }
}

/// `appearance::set_mode`: persist and repaint every window.
pub fn setAppearance(app: *App, mode: zt.settings.AppearanceMode) void {
    const settings_ui = @import("../ui/settings/root.zig");
    const Set = struct {
        fn f(m: zt.settings.AppearanceMode, s: *model.UiSettings, _: std.mem.Allocator) void {
            s.theme.appearance = m;
        }
    };
    settings_ui.store.update(app, .debounced, mode, Set.f);
    settings_ui.store.applyTheme(app);
}

/// (Re)install the menu bar from the current keymap.
pub fn refresh(app: *App) void {
    app.setMenus(appMenus(is_mac)) catch |err| std.log.scoped(.zeron).warn("menus: {t}", .{err});
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;

fn findAction(menu: Menu, name: []const u8) ?MenuItem.Action {
    for (menu.items) |it| if (it == .act and std.mem.eql(u8, it.act.name, name)) return it.act;
    return null;
}

test "app menu structure matches Rust app_menus()" {
    inline for (.{ true, false }) |mac| {
        const menus = appMenus(mac);
        try testing.expectEqualStrings("Zeron", menus[0].name);
        // About first (disabled off macOS), Check for Updates… second.
        const first = menus[0].items[0].act;
        try testing.expectEqualStrings(z.About.action_name, first.action.name);
        try testing.expectEqual(!mac, first.disabled);
        const second = menus[0].items[1].act;
        try testing.expectEqualStrings("Check for Updates…", second.name);
        try testing.expect(!second.disabled);
        try testing.expectEqualStrings(shell.OpenSettings.action_name, findAction(menus[0], "Settings").?.action.name);
        const last = menus[0].items[menus[0].items.len - 1].act;
        try testing.expectEqualStrings("Quit Zeron", last.name);
        try testing.expectEqualStrings(z.Quit.action_name, last.action.name);
        try testing.expectEqual(mac, findAction(menus[0], "Hide Zeron") != null);
        // Edit: composer clipboard verbs with their native selectors.
        const edit = menus[1];
        try testing.expectEqualStrings("Edit", edit.name);
        var os_count: usize = 0;
        for (edit.items) |it| if (it == .act) if (it.act.os_action) |_| {
            os_count += 1;
        };
        try testing.expectEqual(@as(usize, 4), os_count);
        try testing.expectEqual(zpui.platform.OsAction.select_all, findAction(edit, "Select All").?.os_action.?);
        // View: the three appearance modes.
        try testing.expectEqualStrings("View", menus[2].name);
        try testing.expectEqualStrings(z.AppearanceDark.action_name, menus[2].items[2].act.action.name);
        try testing.expectEqual(@as(usize, if (mac) 4 else 3), menus.len);
        if (mac) try testing.expectEqualStrings(z.CloseWindow.action_name, findAction(menus[3], "Close Window").?.action.name);
    }
}

test "menu key equivalents come from the zeron keymap" {
    const app = try App.initTest(testing.allocator);
    defer app.deinit();
    try actions.registerAll(app);
    var keymap_cfg: model.KeymapConfig = .{};
    try actions.keymap.applyKeymap(app, &keymap_cfg, .enter);
    try app.setMenus(appMenus(is_mac));
    const tp = app.test_platform.?;
    const settings_item = blk: {
        for (tp.menus[0].items) |it| if (it == .action and std.mem.eql(u8, it.action.name, "Settings")) break :blk it.action;
        return error.TestUnexpectedResult;
    };
    try testing.expectEqualStrings(",", settings_item.key_equivalent.?.key);
    if (is_mac) {
        try testing.expect(settings_item.key_equivalent.?.modifiers.platform);
    } else {
        try testing.expect(settings_item.key_equivalent.?.modifiers.control);
    }
}
