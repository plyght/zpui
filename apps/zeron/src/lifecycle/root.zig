//! The desktop app's lifecycle (port of zeron `crates/ui/src/lib.rs` `run_app` wiring,
//! `ReopenState`, `on_app_quit`, `open_main_window`'s should-close hook,
//! `open_notification_target`, `app_menus::request_quit` and the shell's
//! `prepare_exit` gate).
//!
//! * Windows: the main window opens on its remembered geometry (window_state.zig) and
//!   saves it on every move/resize. macOS: closing the last window keeps the app alive
//!   (menu bar only) and a Dock click (`onReopen`) rebuilds the window around the
//!   still-running model; Linux quits when the last window closes (as gpui does).
//! * Exits (⌘Q / menu Quit / Dock Quit, ⌘W / close button, "Restart to update") pass
//!   the unsaved-files gate: dirty editors are saved first and the exit resumes once
//!   they are clean; an editor that cannot save (conflict, failed save, deleted on disk)
//!   cancels the exit and is revealed with its own banner.
//! * Quit: settings flush, then a staged update installs (`install_on_quit`).
//! * Deep links (`zeron://open/chat/…`, from the OS or argv), banner clicks, the menu
//!   bar (app_menus.zig), sounds + banners (notify.zig), the self-updater
//!   (app_update.zig) and the log file (log_file.zig) hang off this module.
//!
//! Single instance: like Rust, none — every launch is a new process (engines are shared
//! through the IPC port), so a second `zeron <url>` opens a second window process.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const model = @import("zeron_model");
const shell_mod = @import("../ui/shell/shell.zig");
const sidebar_mod = @import("../ui/sidebar/sidebar.zig");
const right_pane_mod = @import("../ui/shell/right_pane.zig");
const editor = @import("../ui/editor/root.zig");

pub const app_menus = @import("app_menus.zig");
pub const app_update = @import("app_update.zig");
pub const update = @import("update.zig");
pub const links = @import("links.zig");
pub const notify = @import("notify.zig");
pub const window_state = @import("window_state.zig");
pub const log_file = @import("log_file.zig");
pub const build_info = @import("build_info.zig");

const App = zpui.App;
const Window = zpui.Window;
const Entity = zpui.Entity;
const Shell = shell_mod.Shell;

const log = std.log.scoped(.zeron);
const is_mac = builtin.os.tag == .macos;

/// Opens the main window (main.zig owns the window options); returns its id.
pub const OpenMainFn = *const fn (ctx: *anyopaque, app: *App, restored: ?window_state.Restored) ?zpui.WindowId;

pub const Options = struct {
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    state: Entity(model.AppState),
    /// `{data_dir}` (null in fixture mode: no updater staging, no geometry).
    data_dir: ?[]const u8,
    open_ctx: *anyopaque,
    open_main: OpenMainFn,
    /// Restore / persist window geometry (off for fixtures and explicit `--size`).
    persist_geometry: bool = true,
};

pub const ExitKind = enum { quit, close_window, install_update };

/// App global (`app.global(Lifecycle)`).
pub const Lifecycle = struct {
    gpa: Allocator,
    io: std.Io,
    state: Entity(model.AppState),
    data_dir: ?[]const u8,
    open_ctx: *anyopaque,
    open_main: OpenMainFn,
    persist_geometry: bool,
    main_window: ?zpui.WindowId = null,
    deep_links: ?Entity(links.DeepLinks) = null,
    notifier: ?Entity(notify.Notifier) = null,
    /// The exit waiting for dirty editors to save, and how long it has waited.
    pending_exit: ?ExitKind = null,
    exit_attempts: u32 = 0,
    retry_task: zpui.Task(void) = .none,

    pub fn deinit(self: *Lifecycle, app: *App) void {
        self.retry_task.cancel();
        if (self.deep_links) |d| d.release(app);
        if (self.notifier) |n| n.release(app);
        self.state.release(app);
    }
};

fn get(app: *App) ?*Lifecycle {
    return @constCast(app.tryGlobal(Lifecycle) orelse return null);
}

/// Wire everything (after the keymap is applied, before the main window opens).
pub fn install(app: *App, opts: Options) !void {
    app.quit_when_last_window_closes = !is_mac;
    try app.setGlobal(Lifecycle{
        .gpa = opts.gpa,
        .io = opts.io,
        .state = opts.state.retain(app),
        .data_dir = opts.data_dir,
        .open_ctx = opts.open_ctx,
        .open_main = opts.open_main,
        .persist_geometry = opts.persist_geometry,
    });
    try app_menus.install(app);
    app_menus.refresh(app);

    const env = opts.environ;
    // Self-updater (global entity; also the "Check for Updates…" dialog view).
    {
        var base_buf: [1024]u8 = undefined;
        const raw = env.get("ZERON_RELEASES_URL") orelse build_info.releases_url;
        const base: ?[]const u8 = if (std.mem.trim(u8, raw, " ").len == 0) null else update.validateReleaseBase(&base_buf, raw) catch |err| blk: {
            log.warn("ignoring update feed {s}: {t}", .{ raw, err });
            break :blk null;
        };
        var arena = std.heap.ArenaAllocator.init(opts.gpa);
        defer arena.deinit();
        const exe: []const u8 = std.process.executablePathAlloc(opts.io, arena.allocator()) catch "";
        const kind = update.detectInstallFrom(arena.allocator(), exe, env.get("HOME"));
        const entity = try app.newWith(app_update.AppUpdate, app_update.AppUpdate.init, .{app_update.Options{
            .io = opts.io,
            .environ = env,
            .data_dir = opts.data_dir orelse "",
            .base = base,
            .install = kind,
            .automatic = update.desktopAutoUpdateEnabled(env.get("ZERON_AUTO_UPDATE")),
        }});
        try app.setGlobal(app_update.AppUpdate.Global{ .entity = entity });
    }

    const lc = get(app).?;
    lc.deep_links = try app.newWith(links.DeepLinks, links.DeepLinks.init, .{opts.state});
    lc.deep_links.?.update(app, struct {
        fn f(d: *links.DeepLinks, _: *zpui.Context(links.DeepLinks)) void {
            d.sink = .{ .func = showNotice };
        }
    }.f, .{});
    lc.notifier = try app.newWith(notify.Notifier, notify.Notifier.init, .{ opts.state, notify.Options{
        .io = opts.io,
        .sound_disabled = env.get("ZERON_DISABLE_SOUND") != null,
        .notifications_disabled = env.get("ZERON_DISABLE_NOTIFICATIONS") != null,
    } });

    try app.onOpenUrls({}, struct {
        fn f(_: void, urls: []const []const u8, a: *App) void {
            const l = get(a) orelse return;
            const d = l.deep_links orelse return;
            for (urls) |url| {
                log.info("open url {s}", .{url});
                d.update(a, links.DeepLinks.open, .{url});
            }
        }
    }.f);
    // Dock click with no window (⌘W closed it): rebuild the main window.
    try app.onReopen({}, struct {
        fn f(_: void, a: *App) void {
            if (a.windowCount() == 0) _ = openMainWindow(a);
        }
    }.f);
    try app.onShouldQuit({}, struct {
        fn f(_: void, a: *App) bool {
            return prepareExit(a, .quit);
        }
    }.f);
    // Graceful teardown: flush settings, then install a staged update.
    try app.onQuit({}, struct {
        fn f(_: void, a: *App) void {
            model.settings_store.flush(a);
            if (app_update.AppUpdate.global(a)) |u| u.update(a, app_update.AppUpdate.installOnQuit, .{});
            log.info("quit", .{});
        }
    }.f);
    // Stop the engine this client spawned (the bundled `zeron-engine headless`) on every
    // platform; macOS `terminate:` never reaches the entity teardown that used to do it.
    try app.onQuitAsync({}, struct {
        fn f(_: void, a: *App) zpui.QuitTeardown {
            const l = get(a) orelse return .none;
            const engine = l.state.read(a).engine;
            return model.EngineState.quitTeardown(engine, a);
        }
    }.f);
    try app.onSystemWake({}, struct {
        fn f(_: void, a: *App) void {
            if (app_update.AppUpdate.global(a)) |u| u.update(a, app_update.AppUpdate.poke, .{});
        }
    }.f);
    try app.onNotificationActivated({}, struct {
        fn f(_: void, tag: []const u8, a: *App) void {
            openNotificationTarget(a, tag);
        }
    }.f);
}

// ---------------------------------------------------------------------------------------
// Main window
// ---------------------------------------------------------------------------------------

pub fn mainWindow(app: *App) ?*Window {
    const lc = get(app) orelse return null;
    const id = lc.main_window orelse return null;
    return app.windowById(id);
}

fn mainShell(app: *App) ?Entity(Shell) {
    const w = mainWindow(app) orelse return null;
    const root = w.root orelse return null;
    return root.entity.downcast(Shell);
}

/// `open_main_window`: restore geometry, open, wire should-close + geometry saves.
pub fn openMainWindow(app: *App) ?*Window {
    const lc = get(app) orelse return null;
    var restored: ?window_state.Restored = null;
    if (lc.persist_geometry) {
        var ds: [16]zpui.platform.Display = undefined;
        const n = app.displays(&ds);
        const saved = if (model.settings_store.current(app)) |s| s.windowGeometry else null;
        restored = window_state.restoredBounds(saved, ds[0..n], .{ .width = 1320, .height = 880 });
    }
    const id = lc.open_main(lc.open_ctx, app, restored) orelse return null;
    lc.main_window = id;
    const w = app.windowById(id) orelse return null;
    w.onShouldClose({}, struct {
        fn f(_: void, win: *Window, a: *App) bool {
            if (!prepareExit(a, .close_window)) return false;
            if (get(a)) |l| if (l.persist_geometry) window_state.save(win, a, false);
            model.settings_store.flush(a);
            return true;
        }
    }.f) catch {};
    if (lc.persist_geometry) {
        window_state.observe(w) catch {};
        window_state.save(w, app, true);
    }
    return w;
}

/// Bring Zeron forward, reopening the main window first if ⌘W closed it.
pub fn activateMainWindow(app: *App) void {
    app.activate(true);
    if (mainWindow(app)) |w| {
        w.activateWindow();
        return;
    }
    if (app.windowCount() == 0) _ = openMainWindow(app);
}

/// A clicked banner: bring Zeron forward on its chat or on Settings → Agents.
pub fn openNotificationTarget(app: *App, tag: []const u8) void {
    activateMainWindow(app);
    const lc = get(app) orelse return;
    if (std.mem.eql(u8, tag, notify.agent_updates_target)) {
        const Set = struct {
            fn f(_: void, s: *model.UiSettings, _: Allocator) void {
                s.settingsSection = .harnesses;
            }
        };
        _ = model.settings_store.update(app, .debounced, {}, Set.f);
        const shell = mainShell(app) orelse return;
        const w = mainWindow(app) orelse return;
        shell.update(app, Shell.openSettings, .{w});
        return;
    }
    lc.state.read(app).workspace.update(app, model.WorkspaceStore.selectChat, .{@as(?[]const u8, tag)});
}

fn showNotice(_: ?*anyopaque, app: *App, text: []const u8) void {
    const shell = mainShell(app) orelse return;
    shell.read(app).sidebar.update(app, sidebar_mod.Sidebar.setNotice, .{@as(?[]const u8, text)});
}

/// ⌘W / Window ▸ Close Window: the right pane's active surface closes first; an empty or
/// closed pane falls through to the window close (unsaved-file gate and all).
pub fn closeActiveWindow(app: *App) void {
    const w = app.activeWindow() orelse return;
    const main = mainWindow(app);
    if (main == null or main.? != w) {
        w.removeWindow();
        return;
    }
    if (closeActiveSurface(app)) return;
    if (!prepareExit(app, .close_window)) return;
    if (get(app)) |l| if (l.persist_geometry) window_state.save(w, app, false);
    model.settings_store.flush(app);
    w.removeWindow();
}

/// The window's own close control (Linux CSD caption button): the unsaved-files gate,
/// a geometry save and a settings flush, then the window closes.
pub fn closeWindow(app: *App, w: *Window) void {
    // Deferred: the caller (a click listener) holds the Shell leased.
    app.deferFn(w, closeWindowNow);
}

fn closeWindowNow(w: *Window, app: *App) void {
    if (w.removed) return;
    const main = mainWindow(app);
    if (main != null and main.? == w) {
        if (!prepareExit(app, .close_window)) return;
        if (get(app)) |l| if (l.persist_geometry) window_state.save(w, app, false);
        model.settings_store.flush(app);
    }
    w.removeWindow();
}

fn closeActiveSurface(app: *App) bool {
    const shell = mainShell(app) orelse return false;
    const rp_entity = shell.read(app).right_pane;
    const rp = rp_entity.read(app);
    if (!shell.update(app, Shell.rightOpen, .{})) return false;
    const tabs = rp.peek(app) orelse return false;
    const active = tabs.resolvedActive() orelse return false;
    const ix = tabs.indexOf(active) orelse return false;
    switch (tabs.tabs.items[ix].surface) {
        .file => |ed| if (ed.read(app).hasUnsavedChanges()) {
            // Save instead of discarding; a second ⌘W closes the clean tab.
            ed.update(app, editor.FileEditor.save, .{});
            return true;
        },
        else => {},
    }
    rp_entity.update(app, right_pane_mod.RightPane.close, .{active});
    return true;
}

/// "Restart to update": gate on unsaved files, install the staged update with a
/// relauncher, quit.
pub fn restartToUpdate(app: *App) void {
    // Deferred: callers are listeners of the sidebar / the update dialog.
    app.deferFn(app, struct {
        fn f(a: *App, _: *App) void {
            restartNow(a);
        }
    }.f);
}

fn restartNow(app: *App) void {
    if (!prepareExit(app, .install_update)) return;
    const u = app_update.AppUpdate.global(app) orelse return;
    u.update(app, struct {
        fn f(au: *app_update.AppUpdate, cx: *zpui.Context(app_update.AppUpdate)) void {
            au.installForRestart(cx) catch return;
            cx.app.quit();
        }
    }.f, .{});
}

// ---------------------------------------------------------------------------------------
// The unsaved-files gate (Rust `Shell::prepare_exit`)
// ---------------------------------------------------------------------------------------

const DirtyScan = struct { dirty: usize = 0, blocked: ?Entity(editor.FileEditor) = null, blocked_tab: ?u64 = null, blocked_chat: ?[]const u8 = null };

fn scanEditors(app: *App, save: bool) DirtyScan {
    var scan: DirtyScan = .{};
    for (app.windows.items) |slot| {
        const w = slot orelse continue;
        if (w.removed) continue;
        const root = w.root orelse continue;
        const shell = root.entity.downcast(Shell) orelse continue;
        const rp = shell.read(app).right_pane.read(app);
        var it = rp.chats.iterator();
        while (it.next()) |e| for (e.value_ptr.tabs.items) |tab| switch (tab.surface) {
            .file => |ed| {
                const fe = ed.read(app);
                if (!fe.hasUnsavedChanges()) continue;
                scan.dirty += 1;
                switch (fe.phase) {
                    .ready => if (save) ed.update(app, editor.FileEditor.save, .{}),
                    .saving, .loading => {},
                    else => if (scan.blocked == null) {
                        scan.blocked = ed;
                        scan.blocked_tab = tab.id;
                        scan.blocked_chat = e.key_ptr.*;
                    },
                }
            },
            else => {},
        };
    }
    return scan;
}

/// True when no editor holds unsaved changes. Otherwise saves what can be saved, vetoes,
/// and resumes `kind` once everything is clean (an unsavable file cancels the exit and
/// is revealed).
pub fn prepareExit(app: *App, kind: ExitKind) bool {
    const lc = get(app) orelse return true;
    const scan = scanEditors(app, true);
    if (scan.dirty == 0) {
        lc.pending_exit = null;
        lc.exit_attempts = 0;
        return true;
    }
    if (scan.blocked) |_| {
        lc.pending_exit = null;
        lc.exit_attempts = 0;
        revealBlocked(app, scan);
        log.info("exit canceled: an open file cannot be saved", .{});
        return false;
    }
    lc.pending_exit = kind;
    if (lc.retry_task.header == null) {
        lc.retry_task = app.foregroundExecutor().timer(100 * std.time.ns_per_ms, RetryExit{ .app = app }) catch .none;
    }
    return false;
}

fn revealBlocked(app: *App, scan: DirtyScan) void {
    const chat = scan.blocked_chat orelse return;
    const tab = scan.blocked_tab orelse return;
    const lc = get(app) orelse return;
    const ws = lc.state.read(app).workspace;
    const selected = ws.read(app).selected_chat;
    if (selected == null or !std.mem.eql(u8, selected.?, chat)) {
        const copy = app.gpa.dupe(u8, chat) catch return;
        defer app.gpa.free(copy);
        ws.update(app, model.WorkspaceStore.selectChat, .{@as(?[]const u8, copy)});
    }
    const shell = mainShell(app) orelse return;
    shell.update(app, Shell.setRightOpen, .{true});
    shell.read(app).right_pane.update(app, right_pane_mod.RightPane.activate, .{tab});
    activateMainWindow(app);
}

const RetryExit = struct {
    app: *App,
    pub fn finish(self: *RetryExit) void {
        const app = self.app;
        const lc = get(app) orelse return;
        lc.retry_task.detach();
        const kind = lc.pending_exit orelse return;
        lc.exit_attempts += 1;
        // Saves normally land in milliseconds; give up after ~15 s.
        if (lc.exit_attempts > 150) {
            log.warn("exit canceled: open files did not finish saving", .{});
            lc.pending_exit = null;
            lc.exit_attempts = 0;
            return;
        }
        const scan = scanEditors(app, false);
        if (scan.dirty > 0 and scan.blocked == null) {
            lc.retry_task = app.foregroundExecutor().timer(100 * std.time.ns_per_ms, RetryExit{ .app = app }) catch .none;
            return;
        }
        lc.pending_exit = null;
        lc.exit_attempts = 0;
        switch (kind) {
            .quit => app.requestQuit(),
            .close_window => if (mainWindow(app)) |w| {
                if (prepareExit(app, .close_window)) {
                    if (lc.persist_geometry) window_state.save(w, app, false);
                    model.settings_store.flush(app);
                    w.removeWindow();
                }
            },
            .install_update => restartToUpdate(app),
        }
    }
};

test {
    _ = app_menus;
    _ = app_update;
    _ = update;
    _ = links;
    _ = notify;
    _ = window_state;
    _ = log_file;
    _ = @import("lifecycle_test.zig");
    _ = @import("engine_lifecycle_test.zig");
}
