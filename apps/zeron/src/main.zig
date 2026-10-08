//! zeron desktop app entry (`zig build zeron`, `zig build run-zeron -- …`).
//!
//! Boot: platform → App → Geist fonts → theme global → actions + keymap →
//! settings (`ui-settings.json`) → AppState (connects to the engine on
//! `ZERON_IPC_PORT`, spawning `zeron headless` when nothing answers; binary
//! from `ZERON_BIN`, else a `zeron-engine`/`zeron` sibling, `$PATH`, install dirs; see engine_bin.zig) →
//! main window (1320×880, min 900×600, transparent titlebar, traffic lights
//! at 14,14 on macOS, blurred background on macOS, transparent +
//! client-side decorations on Linux).
//!
//! Flags:
//!   --fixtures <dir>        run without an engine from JSON fixtures (also ZERON_FIXTURES;
//!                           ZERON_FIXTURE_SETTINGS_DIR=<dir> seeds the in-memory settings
//!                           from <dir>/ui-settings.json, new-thread-background-fade.json and
//!                           sf-symbols.json, never written back)
//!   --frames <n>            quit after n presented frames (scripted screenshots)
//!   --size <w>x<h>          initial window size
//!   --light / --dark        appearance override
//!   --server-decorations    square, compositor-framed window (Linux; the default
//!                           without a desktop session, e.g. bare Xvfb)
//!   --csd                   force client-side decorations (rounded corners + captions)
//!   fixture overrides:      --gate ready|loading|sign_in|org_gate|failed:<msg>, --splash,
//!                           --select <chat-id|none>, --compact, --detailed
//!   --backend x11|wayland   force a Linux backend
//!   ZERON_LIQUID_GLASS=1    force Settings → Appearance → Glass → Liquid Glass for this
//!                           run (macOS 26+; frosted elsewhere; docs/LIQUID_GLASS.md);
//!                           =0 keeps "Theme default" frosted (it means Liquid on 26+)
//!   ZERON_SIDEBAR_GLASS=glass|vev, ZERON_SIDEBAR_LAYOUT=floating|flush,
//!   ZERON_SIDEBAR_OPACITY=<0..1> (theme layer under the sidebar glass, default 0.55)
//!                           Liquid Glass sidebar recipe / layout (docs/LIQUID_GLASS.md)
//!   --smoke-frames <n>      CI smoke test (also ZERON_SMOKE_FRAMES): render n frames,
//!                           capture the window to zig-out/zeron-<os>[-light].png and
//!                           exit 0, or exit 1 after a FAIL: line (see smoke.zig)
//!   ZERON_GLASS_LAB=1       open the Liquid Glass lab instead (glass_lab.zig; with
//!                           --smoke-frames: diagnostics + captures to zig-out/glass-lab)

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const assets = @import("zeron_assets");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const actions = @import("zeron_actions");
const ui = @import("ui/components/root.zig");
const prefs_mod = @import("ui/shell/prefs.zig");
const fixtures_mod = @import("ui/shell/fixtures.zig");
const shell_mod = @import("ui/shell/shell.zig");
const settings_ui = @import("ui/settings/root.zig");
const voice_service = @import("voice/service.zig"); // [dictation]
const smoke = @import("smoke.zig");
const bench = @import("bench.zig");
const glass_lab = @import("glass_lab.zig"); // [glass-lab]
const lifecycle = @import("lifecycle/root.zig"); // [lifecycle] menus, quit/reopen, deep links, updates, logs
const engine_bin = @import("engine_bin.zig");
const appshot_service = @import("appshots/service.zig"); // [appshots] global hotkey + capture delivery

const App = zpui.App;
const log = std.log.scoped(.zeron);

// [lifecycle] std.log mirrors into {data_dir}/logs/zeron-headed.log; panics land there too.
pub const std_options: std.Options = .{ .logFn = lifecycle.log_file.logFn, .log_level = .debug };
pub const panic = std.debug.FullPanic(lifecycle.log_file.panicFn);

const is_mac = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

const Launch = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    fixtures_dir: ?[]const u8 = null,
    max_frames: ?u64 = null,
    smoke_frames: ?u64 = null, // --smoke-frames / ZERON_SMOKE_FRAMES (smoke.zig)
    /// [glass-lab] ZERON_GLASS_LAB=1: open the Liquid Glass lab instead of the app.
    glass_lab: bool = false,
    size: zpui.Size(f32) = .{ .width = 1320, .height = 880 },
    appearance: ?zt.Appearance = null,
    server_decorations: bool = false,
    gate_override: ?[]const u8 = null,
    splash_override: bool = false,
    select_override: ?[]const u8 = null,
    compact_override: ?bool = null,
    zeron_bin: ?[]const u8 = null,
    data_dir: ?[]u8 = null,
    /// [lifecycle] `zeron <url>` (Rust `Cli.open_url`): delivered like an OS open-URL event.
    open_url: ?[]const u8 = null,
    /// [lifecycle] `--size` given: keep it instead of the remembered window geometry.
    size_set: bool = false,
    // Owned by onLaunch, released in main after run returns.
    state: ?zpui.Entity(model.AppState) = null,
    fixtures: ?*fixtures_mod.Fixtures = null,
};

fn resolveZeronBin(l: *Launch, arena: std.mem.Allocator) void {
    // ZERON_BIN, then siblings (incl. inside Zeron.app), PATH, install locations; never ourselves.
    l.zeron_bin = engine_bin.resolve(arena, l.io, l.environ);
}

fn registerFonts(app: *App) void {
    for (std.enums.values(assets.Font)) |font| {
        app.addFont(font.info().data) catch |err| log.err("addFont {t}: {t}", .{ font, err });
    }
}

fn onLaunch(l: *Launch, app: *App) void {
    registerFonts(app);
    if (l.glass_lab) { // [glass-lab] diagnostics window (glass_lab.zig)
        const bg = l.environ.get("ZERON_GLASS_LAB_BG") orelse "opaque";
        glass_lab.open(l.gpa, l.io, app, .{
            .dark = (l.appearance orelse .light) == .dark,
            .background = std.meta.stringToEnum(glass_lab.Background, bg) orelse .@"opaque",
            .frames = l.smoke_frames,
            .out_dir = l.environ.get("ZERON_GLASS_LAB_OUT") orelse "zig-out/glass-lab",
        });
        return;
    }
    actions.registerAll(app) catch |err| log.err("actions: {t}", .{err});
    // Control icons as SF Symbols on macOS (ui/components/icon_symbols.zig).
    ui.icon.installSystemSymbols(app);

    // Settings (skipped in fixture mode so screenshots are reproducible).
    var prefs: prefs_mod.Prefs = .{ .gpa = l.gpa };
    var keymap_cfg: model.KeymapConfig = .{};
    var send: model.settings.ComposerSendBehavior = .enter;
    if (l.fixtures_dir == null) {
        if (model.settings.dataDir(l.gpa, l.environ, l.io)) |dir| {
            l.data_dir = dir;
            model.settings_store.init(app, l.io, dir) catch |err| log.warn("settings: {t}", .{err});
            // Sticky composer picks + the explicit new-thread defaults.
            model.composer_store.init(app, l.io, dir) catch |err| log.warn("composer defaults: {t}", .{err});
            // Settings → Appearance → Background fade (its own file; Rust drops unknown ui-settings keys).
            model.background_fade.init(app, l.io, dir) catch |err| log.warn("background fade: {t}", .{err});
            // Settings → Appearance → Use SF Symbols (macOS; its own sf-symbols.json).
            model.sf_symbols.init(app, l.io, dir) catch |err| log.warn("sf symbols: {t}", .{err});
            model.ui_font_size_choice.init(app, l.io, dir) catch |err| log.warn("ui font size choice: {t}", .{err});
            // The custom theme library joins the registry before the first theme is built.
            settings_ui.theme_library.init(app, l.io, dir, true);
            if (model.settings_store.current(app)) |s| {
                prefs.applySettings(s);
                keymap_cfg = s.keymap;
                send = s.composerSendBehavior;
            }
        } else |err| log.warn("data dir: {t}", .{err});
    } else if (l.environ.get("ZERON_FIXTURE_SETTINGS_DIR")) |dir| {
        // Fixture run with a real (read-only) ui-settings.json, e.g. a background image.
        model.settings_store.initMemoryFrom(app, l.io, dir) catch |err| log.warn("settings: {t}", .{err});
        model.background_fade.initMemoryFrom(app, l.io, dir) catch |err| log.warn("background fade: {t}", .{err});
        model.sf_symbols.initMemoryFrom(app, l.io, dir) catch |err| log.warn("sf symbols: {t}", .{err});
        model.ui_font_size_choice.initMemoryFrom(app, l.io, dir) catch |err| log.warn("ui font size choice: {t}", .{err});
        settings_ui.theme_library.init(app, l.io, dir, false);
    }
    actions.keymap.applyKeymap(app, &keymap_cfg, send) catch |err| log.err("keymap: {t}", .{err});
    // Settings → Appearance → Native menus (macOS; its own native-menus.json, Rust drops unknown ui-settings keys).
    if (l.data_dir) |dir| model.native_menus.init(app, l.io, dir) catch |err| log.warn("native menus: {t}", .{err});
    // [dictation] the voice model + the composer's dictation service (voice/service.zig).
    voice_service.install(app, l.io, l.environ, if (l.fixtures_dir == null) l.data_dir else null);

    if (l.fixtures_dir) |dir| {
        l.fixtures = fixtures_mod.load(l.gpa, l.io, dir) catch |err| blk: {
            log.err("fixtures {s}: {t}", .{ dir, err });
            break :blk null;
        };
        if (l.fixtures) |f| {
            if (l.gate_override) |g| f.meta.gate = g;
            if (l.splash_override) f.meta.splash = true;
            if (l.select_override) |sel| f.meta.selectedChat = if (std.mem.eql(u8, sel, "none")) null else sel;
            if (l.compact_override) |c| f.meta.sidebarCompact = c;
            fixtures_mod.applyPrefs(f, &prefs);
        }
    }

    // Theme.
    var appearance: zt.Appearance = l.appearance orelse .dark;
    if (l.appearance == null) if (l.fixtures) |f| if (f.meta.appearance) |a| {
        if (std.mem.eql(u8, a, "light")) appearance = .light;
    };
    const theme = zt.Theme.forSelection(&zt.registry.builtin, .{
        .appearance = appearance,
        .variant_id = if (appearance == .dark) "zeron-dark" else "zeron-light",
        .surface = .frosted,
    });
    ui.theme.install(app, theme) catch @panic("theme");
    // [motion] ZERON_MOTION_SCALE: stretch every motion timeline (measurement knob).
    zt.motion.speed_scale = zt.motion.parseSpeedScale(l.environ.get("ZERON_MOTION_SCALE"));
    // [liquid-glass] ZERON_LIQUID_GLASS=1: Liquid Glass for this run (not persisted);
    // unsupported systems (Linux, macOS < 26) keep the frosted look. The line below is
    // what CI greps to prove the fallback path ran.
    // [liquid-glass] ZERON_LIQUID_GLASS=0 keeps "Theme default" frosted on macOS 26+
    // (where it otherwise means Liquid Glass); ZERON_SIDEBAR_GLASS / _LAYOUT pick the
    // sidebar recipe to compare on a Mac (docs/LIQUID_GLASS.md).
    if (l.environ.get("ZERON_LIQUID_GLASS")) |v| if (std.mem.eql(u8, v, "0")) {
        settings_ui.store.default_liquid_disabled = true;
    };
    // [liquid-glass] ZERON_GLASS_TINT=<0..1>: theme tint strength on glass (0 = none).
    if (l.environ.get("ZERON_GLASS_TINT")) |v| zt.theme.glass_tint_strength = std.fmt.parseFloat(f32, v) catch zt.theme.glass_tint_strength;
    if (l.environ.get("ZERON_SIDEBAR_GLASS")) |v| {
        if (std.meta.stringToEnum(shell_mod.SidebarGlassMode, v)) |m| shell_mod.sidebar_glass_mode = m;
    }
    if (l.environ.get("ZERON_SIDEBAR_OPACITY")) |v| shell_mod.sidebar_opacity = std.fmt.parseFloat(f32, v) catch shell_mod.sidebar_opacity;
    if (l.environ.get("ZERON_SIDEBAR_LAYOUT")) |v| {
        if (std.meta.stringToEnum(shell_mod.SidebarLayout, v)) |m| shell_mod.sidebar_layout_override = m;
    }
    if (l.environ.get("ZERON_LIQUID_GLASS")) |v| if (v.len > 0 and !std.mem.eql(u8, v, "0")) {
        settings_ui.store.force_liquid = true;
        const native = zpui.platformSupportsLiquidGlass(app);
        std.debug.print("zeron: liquid glass forced: {s}\n", .{if (native) "native (NSGlassEffectView)" else "unsupported, frosted fallback"});
        // With Reduce Transparency on, AppKit draws glass (and the window's material) solid:
        // expected, not a zpui bug. Logged so screenshots can be read correctly.
        if (is_mac) if (native) {
            const a = zpui.mac_platform.glass_debug.accessibility();
            std.debug.print("zeron: accessibility reduceTransparency={} increaseContrast={}\n", .{ a.reduce_transparency, a.increase_contrast });
        };
    };
    // Settings: theme from ui-settings.json (or an in-memory store in fixture mode).
    settings_ui.store.boot(app, l.io, if (l.fixtures != null) appearance else l.appearance);
    // [liquid-glass] What the glass resolved to (also when it is just the default).
    if (is_mac and ui.theme.get(app).isLiquid()) {
        std.debug.print("zeron: liquid glass on (macOS {d}): sidebar={t} layout={t}\n", .{
            zpui.liquidGlassRevision(app), shell_mod.sidebar_glass_mode, shell_mod.sidebarLayout(app),
        });
        if (!settings_ui.store.force_liquid) {
            const a = zpui.mac_platform.glass_debug.accessibility();
            std.debug.print("zeron: accessibility reduceTransparency={} increaseContrast={}\n", .{ a.reduce_transparency, a.increase_contrast });
        }
    }
    prefs_mod.install(app, prefs) catch @panic("prefs");

    // Model.
    const config: model.engine_state.Config = if (l.fixtures != null)
        .{ .port = 1, .zeron_path = null, .reconnect = false }
    else
        .{ .port = engine.portFromEnv(l.environ), .zeron_path = l.zeron_bin, .spawn_environ = l.environ };
    const state = app.newWith(model.AppState, model.AppState.init, .{ l.io, config }) catch |err| {
        log.err("app state: {t}", .{err});
        app.quit();
        return;
    };
    l.state = state;
    if (l.fixtures) |f| fixtures_mod.applyToState(f, l.io, app, state);

    // [lifecycle] menus, quit/close gate, reopen, deep links, banners + sounds, updater.
    lifecycle.install(app, .{
        .gpa = l.gpa,
        .io = l.io,
        .environ = l.environ,
        .state = state,
        .data_dir = l.data_dir,
        .open_ctx = l,
        .open_main = openMainWindow,
        .persist_geometry = l.fixtures == null and !l.size_set,
    }) catch |err| log.err("lifecycle: {t}", .{err});
    // [appshots] Global capture shortcut + `zeron appshot` activation (not in fixture runs).
    if (l.fixtures == null) appshot_service.install(app, .{
        .io = l.io,
        .data_dir = l.data_dir,
        .sound_disabled = l.environ.get("ZERON_DISABLE_SOUND") != null,
    }) catch |err| log.err("appshots: {t}", .{err});
    const window = lifecycle.openMainWindow(app) orelse {
        app.quit();
        return;
    };
    if (l.open_url) |url| zpui.lifecycle.openUrls(app, &.{url});
    // --- benchmark timeline (ZERON_BENCH=1; bench.zig, docs/BENCHMARKS.md) ---
    bench.start(l.gpa, l.io, l.environ, app, window, state);
    // --- smoke test (CI): render N frames, capture, exit (smoke.zig) ---
    if (l.smoke_frames) |n|
        smoke.start(l.gpa, l.io, window, .{ .frames = n, .light = appearance == .light, .out = l.environ.get("ZERON_SMOKE_OUT"), .browser_url = l.environ.get("ZERON_SMOKE_BROWSER_URL"), .diag = l.environ.get("ZERON_SMOKE_DIAG") != null, .menu = l.environ.get("ZERON_SMOKE_MENU") != null, .settings = l.environ.get("ZERON_SMOKE_SETTINGS"), .settings_stress = l.environ.get("ZERON_SMOKE_SETTINGS_STRESS"), .shortcuts = l.environ.get("ZERON_SMOKE_SHORTCUTS") != null, .new_chat = l.environ.get("ZERON_SMOKE_NEW_CHAT") != null, .native_menu = l.environ.get("ZERON_SMOKE_NATIVE_MENU") });
    if (l.max_frames) |n| {
        const Quit = struct {
            left: u64,
            fn tick(self: *const @This(), win: *zpui.Window, a: *App) void {
                if (self.left == 0) a.quit() else win.onNextFrame(@This(){ .left = self.left - 1 }, tick);
            }
        };
        window.onNextFrame(Quit{ .left = n }, Quit.tick);
    }
}

/// [lifecycle] Opens the main window (launch, and again on a Dock reopen after ⌘W).
/// `restored` = remembered geometry fitted to the current displays (lifecycle/window_state.zig).
fn openMainWindow(ctx: *anyopaque, app: *App, restored: ?lifecycle.window_state.Restored) ?zpui.WindowId {
    const l: *Launch = @ptrCast(@alignCast(ctx));
    const state = l.state orelse return null;
    const theme = ui.theme.get(app);
    const options: zpui.WindowOptions = .{
        .bounds = if (restored) |r| r.bounds else .{ .origin = .{ .x = 0, .y = 0 }, .size = l.size },
        .display_id = if (restored) |r| r.display_id else null,
        .titlebar = .{
            .title = if (builtin.os.tag == .windows) "Zeron" else "",
            .appears_transparent = true,
            .traffic_light_position = .{ .x = 14, .y = 14 },
        },
        .min_size = .{ .width = 900, .height = 600 },
        .background = switch (theme.windowBackgroundAppearance()) {
            .@"opaque" => .opaque_,
            .transparent => .transparent,
            .blurred => .blurred,
        },
        .decorations = if (is_linux and !l.server_decorations) .client else .server,
        .app_id = "sh.zeron.Zeron",
    };
    const handle = app.openWindow(options, shell_mod.Shell, shell_mod.Shell.init, .{ state, l.fixtures, l.server_decorations }) catch |err| {
        log.err("openWindow: {t}", .{err});
        return null;
    };
    const w = handle.window(app) orelse return null;
    // The settings' base size (14 px for an untouched system font; `applyTheme` keeps it current).
    w.setRemSize(settings_ui.store.effectiveUiFontSize(app, settings_ui.store.current(app)).pixels());
    // Dev/testing knob (Rust parity): `ZERON_OPEN_ROUTE=settings[/<section>]`
    // boots straight into a settings section (headless captures can't click there).
    if (l.environ.get("ZERON_OPEN_ROUTE")) |route| if (settingsRoute(route, settings_ui.store.current(app).settingsSection)) |section| {
        const Set = struct {
            fn f(sec: model.settings.SettingsSection, s: *model.UiSettings, _: std.mem.Allocator) void {
                s.settingsSection = sec;
            }
        };
        settings_ui.store.update(app, .debounced, section, Set.f);
        _ = handle.update(app, shell_mod.Shell.openSettings, .{});
    };
    return handle.id;
}

/// `settings_open_route`: bare `settings` reopens the remembered section,
/// `settings/<slug>` names one; null for anything else.
fn settingsRoute(route: []const u8, remembered: model.settings.SettingsSection) ?model.settings.SettingsSection {
    if (std.mem.eql(u8, route, "settings")) return remembered.reopenable();
    if (!std.mem.startsWith(u8, route, "settings/")) return null;
    const sec = model.settings.SettingsSection.fromSlug(route["settings/".len..]) orelse return null;
    return sec.canonical();
}

pub fn main(init: std.process.Init) !void {
    const gpa = if (is_mac) std.heap.c_allocator else init.gpa;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    // This is the desktop client; the engine (`zeron headless`) is a separate
    // binary that shares the name. Refuse instead of opening a window, so a
    // mis-resolved engine path can never make us respawn ourselves.
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "headless")) {
        std.debug.print("zeron: this is the zeron desktop client, not the engine; point ZERON_BIN at the engine binary\n", .{});
        std.process.exit(2);
    }
    // [lifecycle] `zeron --version` (the self-updater verifies staged binaries with it).
    if (argv.len > 1 and (std.mem.eql(u8, argv[1], "--version") or std.mem.eql(u8, argv[1], "-V"))) {
        var out_buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&out_buf, "zeron {s}\n", .{lifecycle.build_info.version}) catch unreachable;
        _ = std.c.write(1, line.ptr, line.len);
        return;
    }
    // [appshots] `zeron appshot`: ask the running headed Zeron to capture (Linux
    // desktops bind it in their Keyboard Shortcuts when there is no portal).
    if (argv.len > 1 and std.mem.eql(u8, argv[1], "appshot")) {
        const dir = model.settings.dataDir(arena, init.environ_map, init.io) catch {
            std.debug.print("zeron: could not resolve the data directory\n", .{});
            std.process.exit(1);
        };
        if (appshot_service.requestRunningAppshot(dir)) |msg| {
            std.debug.print("zeron: {s}\n", .{msg});
            std.process.exit(1);
        }
        return;
    }
    var launch: Launch = .{ .gpa = gpa, .io = init.io, .environ = init.environ_map };
    var backend: if (is_linux) ?zpui.linux_platform.BackendKind else ?void = null;
    var force_csd = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--fixtures") and i + 1 < argv.len) {
            i += 1;
            launch.fixtures_dir = argv[i];
        } else if (std.mem.eql(u8, a, "--frames") and i + 1 < argv.len) {
            i += 1;
            launch.max_frames = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--smoke-frames") and i + 1 < argv.len) {
            i += 1;
            launch.smoke_frames = try std.fmt.parseInt(u64, argv[i], 10);
        } else if (std.mem.eql(u8, a, "--size") and i + 1 < argv.len) {
            i += 1;
            var it = std.mem.splitScalar(u8, argv[i], 'x');
            launch.size.width = try std.fmt.parseFloat(f32, it.next() orelse "1320");
            launch.size.height = try std.fmt.parseFloat(f32, it.next() orelse "880");
            launch.size_set = true;
        } else if (std.mem.eql(u8, a, "--light")) {
            launch.appearance = .light;
        } else if (std.mem.eql(u8, a, "--dark")) {
            launch.appearance = .dark;
        } else if (std.mem.eql(u8, a, "--gate") and i + 1 < argv.len) {
            i += 1;
            launch.gate_override = argv[i];
        } else if (std.mem.eql(u8, a, "--select") and i + 1 < argv.len) {
            i += 1;
            launch.select_override = argv[i];
        } else if (std.mem.eql(u8, a, "--splash")) {
            launch.splash_override = true;
        } else if (std.mem.eql(u8, a, "--compact")) {
            launch.compact_override = true;
        } else if (std.mem.eql(u8, a, "--detailed")) {
            launch.compact_override = false;
        } else if (std.mem.eql(u8, a, "--server-decorations")) {
            launch.server_decorations = true;
        } else if (std.mem.eql(u8, a, "--csd")) {
            force_csd = true;
        } else if (std.mem.eql(u8, a, "--backend") and i + 1 < argv.len) {
            i += 1;
            if (is_linux) backend = std.meta.stringToEnum(zpui.linux_platform.BackendKind, argv[i]);
        } else if (a.len > 0 and a[0] != '-' and launch.open_url == null) {
            launch.open_url = a; // [lifecycle] positional URL (`Exec=zeron %u`)
        }
    }
    if (launch.fixtures_dir == null) launch.fixtures_dir = init.environ_map.get("ZERON_FIXTURES");
    if (launch.smoke_frames == null) if (init.environ_map.get("ZERON_SMOKE_FRAMES")) |v| {
        launch.smoke_frames = try std.fmt.parseInt(u64, v, 10);
    };
    if (init.environ_map.get("ZERON_GLASS_LAB")) |v| launch.glass_lab = v.len > 0 and !std.mem.eql(u8, v, "0");
    // Client-side decorations need a compositor (gpui falls back to server
    // decorations without one). With no desktop session at all (bare Xvfb,
    // CI) keep the square, compositor-framed window; `--csd` forces CSD.
    if (is_linux and !force_csd and init.environ_map.get("WAYLAND_DISPLAY") == null and
        init.environ_map.get("XDG_CURRENT_DESKTOP") == null and init.environ_map.get("XDG_SESSION_TYPE") == null)
        launch.server_decorations = true;
    resolveZeronBin(&launch, arena);
    // [lifecycle] Rust `open_log_file("headed")`: {data_dir}/logs, rotated per launch.
    lifecycle.log_file.setLevelFromEnv(init.environ_map.get("ZERON_LOG"));
    if (launch.fixtures_dir == null) if (model.settings.dataDir(arena, init.environ_map, init.io)) |dir| {
        const logs = try std.fs.path.join(arena, &.{ dir, "logs" });
        if (lifecycle.log_file.open(logs, "headed") == null) log.warn("cannot open a log file in {s}", .{logs});
    } else |_| {};
    lifecycle.log_file.installCrashHandlers(); // fatal signals / NSExceptions into the log
    log.info("zeron {s} starting", .{lifecycle.build_info.version});

    const plat = if (is_linux)
        try zpui.linux_platform.create(gpa, .{ .io = init.io, .backend = backend })
    else if (is_mac)
        try zpui.mac_platform.create(gpa)
    else
        @compileError("zeron: unsupported OS");
    const app = try App.init(gpa, plat);
    defer app.deinit();
    app.run(&launch, onLaunch);
    if (launch.state) |s| s.release(app);
    if (launch.fixtures) |f| {
        f.deinit();
        gpa.destroy(f);
    }
    if (launch.data_dir) |d| gpa.free(d);
    if (launch.glass_lab) {
        const code = glass_lab.exitCode(); // [glass-lab]
        if (code != 0) std.process.exit(code);
    } else if (launch.smoke_frames != null) {
        const code = smoke.exitCode(); // smoke test result (smoke.zig)
        if (code != 0) std.process.exit(code);
    }
}

test {
    _ = @import("appshots/tests.zig"); // [appshots]
    _ = @import("lifecycle/root.zig");
    _ = @import("smoke.zig");
    _ = @import("smoke_shortcuts.zig");
    _ = @import("shortcut_table.zig");
    _ = @import("glass_lab.zig");
    _ = @import("engine_bin.zig");
    _ = @import("ui/shell/shell_test.zig");
    _ = @import("ui/shell/native_popover_test.zig");
    _ = @import("ui/shell/harness_updates_test.zig");
    _ = @import("ui/shell/sidebar_sync_parity_test.zig");
    _ = @import("ui/shell/sidebar_sync_test.zig");
    _ = @import("ui/settings/root.zig");
    _ = @import("ui/components/icon_symbols.zig");
    _ = @import("ui/background/root.zig");
    _ = @import("ui/pickers/root.zig");
    _ = @import("ui/shell/right_pane.zig");
    _ = @import("ui/shell/terminal_panel.zig");
    _ = @import("ui/sidebar/project_icon.zig");
    _ = @import("voice/service.zig"); // [dictation]
    _ = @import("ui/shell/dictation_test.zig"); // [dictation]
    _ = @import("ui/sidebar/sections_ui.zig");
}
