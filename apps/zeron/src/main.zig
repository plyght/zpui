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
//!   --fixtures <dir>        run without an engine from JSON fixtures (also ZERON_FIXTURES)
//!   --frames <n>            quit after n presented frames (scripted screenshots)
//!   --size <w>x<h>          initial window size
//!   --light / --dark        appearance override
//!   --server-decorations    square, compositor-framed window (Linux; the default
//!                           without a desktop session, e.g. bare Xvfb)
//!   --csd                   force client-side decorations (rounded corners + captions)
//!   fixture overrides:      --gate ready|loading|sign_in|org_gate|failed:<msg>, --splash,
//!                           --select <chat-id|none>, --compact, --detailed
//!   --backend x11|wayland   force a Linux backend
//!   --smoke-frames <n>      CI smoke test (also ZERON_SMOKE_FRAMES): render n frames,
//!                           capture the window to zig-out/zeron-<os>[-light].png and
//!                           exit 0, or exit 1 after a FAIL: line (see smoke.zig)

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
const smoke = @import("smoke.zig");
const engine_bin = @import("engine_bin.zig");

const App = zpui.App;
const log = std.log.scoped(.zeron);

const is_mac = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

const Launch = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    fixtures_dir: ?[]const u8 = null,
    max_frames: ?u64 = null,
    smoke_frames: ?u64 = null, // --smoke-frames / ZERON_SMOKE_FRAMES (smoke.zig)
    size: zpui.Size(f32) = .{ .width = 1320, .height = 880 },
    appearance: ?zt.Appearance = null,
    server_decorations: bool = false,
    gate_override: ?[]const u8 = null,
    splash_override: bool = false,
    select_override: ?[]const u8 = null,
    compact_override: ?bool = null,
    zeron_bin: ?[]const u8 = null,
    data_dir: ?[]u8 = null,
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
    app.quit_when_last_window_closes = true;
    registerFonts(app);
    actions.registerAll(app) catch |err| log.err("actions: {t}", .{err});

    // Settings (skipped in fixture mode so screenshots are reproducible).
    var prefs: prefs_mod.Prefs = .{ .gpa = l.gpa };
    var keymap_cfg: model.KeymapConfig = .{};
    var send: model.settings.ComposerSendBehavior = .enter;
    if (l.fixtures_dir == null) {
        if (model.settings.dataDir(l.gpa, l.environ, l.io)) |dir| {
            l.data_dir = dir;
            model.settings_store.init(app, l.io, dir) catch |err| log.warn("settings: {t}", .{err});
            if (model.settings_store.current(app)) |s| {
                prefs.applySettings(s);
                keymap_cfg = s.keymap;
                send = s.composerSendBehavior;
            }
        } else |err| log.warn("data dir: {t}", .{err});
    }
    actions.keymap.applyKeymap(app, &keymap_cfg, send) catch |err| log.err("keymap: {t}", .{err});

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
    // Settings: theme from ui-settings.json (or an in-memory store in fixture mode).
    settings_ui.store.boot(app, l.io, if (l.fixtures != null) appearance else l.appearance);
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

    const options: zpui.WindowOptions = .{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = l.size },
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
        app.quit();
        return;
    };
    if (handle.window(app)) |w| w.setRemSize(16);
    // --- smoke test (CI): render N frames, capture, exit (smoke.zig) ---
    if (l.smoke_frames) |n| if (handle.window(app)) |w|
        smoke.start(l.gpa, l.io, w, .{ .frames = n, .light = appearance == .light, .out = l.environ.get("ZERON_SMOKE_OUT") });
    if (l.max_frames) |n| {
        const Quit = struct {
            left: u64,
            fn tick(self: *const @This(), win: *zpui.Window, a: *App) void {
                if (self.left == 0) a.quit() else win.onNextFrame(@This(){ .left = self.left - 1 }, tick);
            }
        };
        handle.window(app).?.onNextFrame(Quit{ .left = n }, Quit.tick);
    }
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
        }
    }
    if (launch.fixtures_dir == null) launch.fixtures_dir = init.environ_map.get("ZERON_FIXTURES");
    if (launch.smoke_frames == null) if (init.environ_map.get("ZERON_SMOKE_FRAMES")) |v| {
        launch.smoke_frames = try std.fmt.parseInt(u64, v, 10);
    };
    // Client-side decorations need a compositor (gpui falls back to server
    // decorations without one). With no desktop session at all (bare Xvfb,
    // CI) keep the square, compositor-framed window; `--csd` forces CSD.
    if (is_linux and !force_csd and init.environ_map.get("WAYLAND_DISPLAY") == null and
        init.environ_map.get("XDG_CURRENT_DESKTOP") == null and init.environ_map.get("XDG_SESSION_TYPE") == null)
        launch.server_decorations = true;
    resolveZeronBin(&launch, arena);

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
    if (launch.smoke_frames != null) {
        const code = smoke.exitCode(); // smoke test result (smoke.zig)
        if (code != 0) std.process.exit(code);
    }
}

test {
    _ = @import("smoke.zig");
    _ = @import("engine_bin.zig");
    _ = @import("ui/shell/shell_test.zig");
    _ = @import("ui/settings/root.zig");
    _ = @import("ui/pickers/root.zig");
    _ = @import("ui/shell/right_pane.zig");
    _ = @import("ui/sidebar/project_icon.zig");
}
