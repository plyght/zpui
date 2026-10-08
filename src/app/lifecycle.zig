//! App lifecycle + application menus (gpui `App::on_quit`, `on_reopen`, `on_open_urls`,
//! `set_menus`, `hide`, ...): the `PlatformCallbacks` the App registers on its platform,
//! re-exposed as App listeners, plus the menu bar model.
//!
//! ```zig
//! try app.onOpenUrls(&state, State.openUrls);          // fn(*State, []const []const u8, *App)
//! try app.onReopen(&state, State.reopen);              // dock click with no visible window
//! try app.onShouldQuit(&state, State.mayQuit);         // veto OS / requested quits (return false)
//! try app.onQuit(&state, State.flush);                 // the app is exiting (run once)
//! try app.onQuitAsync(&state, State.drain);            // ... returning a QuitTeardown task
//! try app.setMenus(&.{ .{ .name = "Zeron", .items = &.{
//!     .action("Settings", OpenSettings{}),
//!     .separator,
//!     .osSubmenu("Services", .services),
//!     .action("Quit Zeron", Quit{}),
//! } } });
//! ```
//!
//! Quit flow (like zeron's `app_menus::request_quit` + `native_quit`): `app.requestQuit()`
//! (menu Quit, ⌘Q) and OS termination requests run every `onShouldQuit` listener; any
//! `false` cancels (the listener finishes its work and calls `requestQuit` / `quit`
//! again). `app.quit()` is never vetoed. `onQuit` listeners run once, when the platform
//! is about to leave its run loop. `onQuitAsync` listeners (gpui `on_app_quit` returning a
//! future) run right after them and hand back a `QuitTeardown` (a spawned task); the exit
//! waits up to `shutdown_timeout_ns` (gpui `SHUTDOWN_TIMEOUT`, 200 ms) for every teardown's
//! background phase to finish, then drops whatever is left.
//!
//! Menu items carry actions; picking one dispatches the action to the active window's
//! focused element (else to global `onAction` listeners), and menus validate items with
//! the same availability rule. Key equivalents are rendered from the keymap at
//! `setMenus` time (call it again after re-binding keys).

const std = @import("std");
const Allocator = std.mem.Allocator;
const pf = @import("../platform/platform.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Captures = app_mod.Captures;
const wrapCtx = app_mod.wrapCtx;
const unwrapCtx = app_mod.unwrapCtx;
const action_mod = @import("action.zig");
const AnyAction = action_mod.AnyAction;
const type_id = @import("type_id.zig");
const TypeId = type_id.TypeId;
const keymap_mod = @import("keymap.zig");
const executor_mod = @import("executor.zig");

/// gpui `SHUTDOWN_TIMEOUT`: how long the exit waits for `onQuitAsync` teardowns.
pub const shutdown_timeout_ns: u64 = 200 * std.time.ns_per_ms;

/// The async part of an `onQuitAsync` listener (gpui's `on_app_quit` future): owns a
/// spawned task; the exit waits for its background phase (`run`) to finish. Its `finish`
/// phase is not awaited (the main loop is gone), so put the teardown in `run`.
pub const QuitTeardown = struct {
    header: ?*executor_mod.Header = null,

    /// Nothing to wait for.
    pub const none: QuitTeardown = .{};

    /// Take ownership of `task` (an `executor.Task(R)`); don't cancel / detach it yourself.
    pub fn of(task: anytype) QuitTeardown {
        return .{ .header = task.header };
    }

    fn done(self: QuitTeardown) bool {
        const h = self.header orelse return true;
        return switch (h.state.load(.acquire)) {
            .ran, .completed, .canceled => true,
            else => false,
        };
    }

    fn release(self: *QuitTeardown) void {
        var t: executor_mod.Task(void) = .{ .header = self.header };
        self.header = null;
        t.detach();
    }
};

// ---------------------------------------------------------------------------------------
// Menus (app-level model)
// ---------------------------------------------------------------------------------------

/// A comptime-known action value a menu item dispatches (unit or default-buildable).
pub const ActionRef = struct {
    type_id: TypeId,
    name: []const u8,
    build: *const fn (gpa: Allocator) Allocator.Error!AnyAction,

    pub fn of(comptime value: anytype) ActionRef {
        const T = @TypeOf(value);
        comptime action_mod.assertAction(T);
        return .{
            .type_id = type_id.typeId(T),
            .name = T.action_name,
            .build = struct {
                fn build(gpa: Allocator) Allocator.Error!AnyAction {
                    return AnyAction.init(gpa, value);
                }
            }.build,
        };
    }
};

pub const MenuItem = union(enum) {
    separator,
    /// Built with `MenuItem.action` / `MenuItem.osAction`.
    act: Action,
    submenu: Menu,
    os_submenu: struct { name: []const u8, kind: pf.SystemMenuType },

    pub const Action = struct {
        name: []const u8,
        action: ActionRef,
        os_action: ?pf.OsAction = null,
        checked: bool = false,
        disabled: bool = false,
    };

    pub fn action(name: []const u8, comptime value: anytype) MenuItem {
        return .{ .act = .{ .name = name, .action = .of(value) } };
    }
    /// An action that also maps to the native editing selector (`cut:`, ...).
    pub fn osAction(name: []const u8, comptime value: anytype, os: pf.OsAction) MenuItem {
        return .{ .act = .{ .name = name, .action = .of(value), .os_action = os } };
    }
    pub fn osSubmenu(name: []const u8, kind: pf.SystemMenuType) MenuItem {
        return .{ .os_submenu = .{ .name = name, .kind = kind } };
    }
    pub fn disabledIf(self: MenuItem, disabled: bool) MenuItem {
        var copy = self;
        if (copy == .act) copy.act.disabled = disabled;
        return copy;
    }
    pub fn checkedIf(self: MenuItem, checked: bool) MenuItem {
        var copy = self;
        if (copy == .act) copy.act.checked = checked;
        return copy;
    }
};

pub const Menu = struct {
    name: []const u8,
    items: []const MenuItem,
    disabled: bool = false,
};

// ---------------------------------------------------------------------------------------
// Listener lists
// ---------------------------------------------------------------------------------------

fn ListenerList(comptime Args: type, comptime Ret: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct {
            func: *const fn (cap: *const Captures, args: Args, app: *App) Ret,
            cap: Captures,
        };
        items: std.ArrayList(Entry) = .empty,

        fn add(self: *Self, gpa: Allocator, entry: Entry) Allocator.Error!void {
            try self.items.append(gpa, entry);
        }
        fn deinit(self: *Self, gpa: Allocator) void {
            for (self.items.items) |*e| e.cap.deinit(gpa);
            self.items.deinit(gpa);
        }
        /// Snapshot, so listeners may register more listeners.
        fn snapshot(self: *const Self, gpa: Allocator) []Entry {
            return gpa.dupe(Entry, self.items.items) catch @panic("OOM");
        }
    };
}

fn makeEntry(comptime L: type, comptime Args: type, comptime Ret: type, ctx: anytype, comptime f: anytype) L.Entry {
    const C = @TypeOf(ctx);
    const Gen = struct {
        fn call(cap: *const Captures, args: Args, app: *App) Ret {
            const c = unwrapCtx(C, cap);
            return if (Args == void) f(c, app) else f(c, args, app);
        }
    };
    return .{ .func = Gen.call, .cap = wrapCtx(ctx) };
}

const VoidList = ListenerList(void, void);
const BoolList = ListenerList(void, bool);
const TeardownList = ListenerList(void, QuitTeardown);
const UrlsList = ListenerList([]const []const u8, void);
const TagList = ListenerList([]const u8, void);

/// Lifecycle state embedded in `App` (`app.lifecycle`).
pub const Lifecycle = struct {
    quit: VoidList = .{},
    quit_async: TeardownList = .{},
    reopen: VoidList = .{},
    open_urls: UrlsList = .{},
    system_wake: VoidList = .{},
    keyboard_layout: VoidList = .{},
    should_quit: BoolList = .{},
    notification: TagList = .{},
    /// `onQuit` listeners ran (they run once).
    quit_ran: bool = false,
    /// A `requestQuit` is queued (coalesces repeated ⌘Q / OS requests).
    quit_request_pending: bool = false,
    /// URLs that arrived before any `onOpenUrls` listener (cold launch), owned.
    pending_urls: std.ArrayList([]u8) = .empty,

    // menus
    menu_arena: ?std.heap.ArenaAllocator = null,
    /// The app-level model last passed to `setMenus` (in `menu_arena`).
    menus: []const Menu = &.{},
    /// The platform translation (tags index `menu_actions`).
    platform_menus: []const pf.Menu = &.{},
    menu_actions: std.ArrayList(AnyAction) = .empty,

    pub fn deinit(self: *Lifecycle, gpa: Allocator) void {
        self.quit.deinit(gpa);
        self.quit_async.deinit(gpa);
        self.reopen.deinit(gpa);
        self.open_urls.deinit(gpa);
        self.system_wake.deinit(gpa);
        self.keyboard_layout.deinit(gpa);
        self.should_quit.deinit(gpa);
        self.notification.deinit(gpa);
        for (self.pending_urls.items) |u| gpa.free(u);
        self.pending_urls.deinit(gpa);
        self.clearMenus(gpa);
    }

    fn clearMenus(self: *Lifecycle, gpa: Allocator) void {
        for (self.menu_actions.items) |*a| a.deinit(gpa);
        self.menu_actions.deinit(gpa);
        self.menu_actions = .empty;
        if (self.menu_arena) |*a| a.deinit();
        self.menu_arena = null;
        self.menus = &.{};
        self.platform_menus = &.{};
    }
};

// ---------------------------------------------------------------------------------------
// Registration (called from App)
// ---------------------------------------------------------------------------------------

/// Register the App on its platform (once, from `App.init`).
pub fn install(app: *App) void {
    app.platform.vtable.setCallbacks(app.platform.ptr, .{
        .ctx = app,
        .quit = cbQuit,
        .reopen = cbReopen,
        .open_urls = cbOpenUrls,
        .keyboard_layout_change = cbKeyboardLayout,
        .system_wake = cbSystemWake,
        .should_quit = cbShouldQuit,
        .menu_action = cbMenuAction,
        .validate_menu = cbValidateMenu,
        .notification_activated = cbNotification,
    });
}

fn appOf(ctx: ?*anyopaque) *App {
    return @ptrCast(@alignCast(ctx.?));
}

pub fn onQuit(app: *App, ctx: anytype, comptime f: anytype) Allocator.Error!void {
    try app.lifecycle.quit.add(app.gpa, makeEntry(VoidList, void, void, ctx, f));
}
/// `f(ctx, app) QuitTeardown`: like `onQuit`, but the exit waits (bounded) for the task.
pub fn onQuitAsync(app: *App, ctx: anytype, comptime f: anytype) Allocator.Error!void {
    try app.lifecycle.quit_async.add(app.gpa, makeEntry(TeardownList, void, QuitTeardown, ctx, f));
}
pub fn onReopen(app: *App, ctx: anytype, comptime f: anytype) Allocator.Error!void {
    try app.lifecycle.reopen.add(app.gpa, makeEntry(VoidList, void, void, ctx, f));
}
pub fn onSystemWake(app: *App, ctx: anytype, comptime f: anytype) Allocator.Error!void {
    try app.lifecycle.system_wake.add(app.gpa, makeEntry(VoidList, void, void, ctx, f));
}
pub fn onKeyboardLayoutChange(app: *App, ctx: anytype, comptime f: anytype) Allocator.Error!void {
    try app.lifecycle.keyboard_layout.add(app.gpa, makeEntry(VoidList, void, void, ctx, f));
}
pub fn onShouldQuit(app: *App, ctx: anytype, comptime f: anytype) Allocator.Error!void {
    try app.lifecycle.should_quit.add(app.gpa, makeEntry(BoolList, void, bool, ctx, f));
}
pub fn onNotificationActivated(app: *App, ctx: anytype, comptime f: anytype) Allocator.Error!void {
    try app.lifecycle.notification.add(app.gpa, makeEntry(TagList, []const u8, void, ctx, f));
}
/// URLs that arrived before the first listener (cold launch) are delivered to it at once.
pub fn onOpenUrls(app: *App, ctx: anytype, comptime f: anytype) Allocator.Error!void {
    try app.lifecycle.open_urls.add(app.gpa, makeEntry(UrlsList, []const []const u8, void, ctx, f));
    if (app.lifecycle.pending_urls.items.len > 0) {
        var pending = app.lifecycle.pending_urls;
        app.lifecycle.pending_urls = .empty;
        defer {
            for (pending.items) |u| app.gpa.free(u);
            pending.deinit(app.gpa);
        }
        const view: []const []const u8 = @ptrCast(pending.items);
        deliverUrls(app, view);
    }
}

/// Feed URLs as if the OS delivered them (cold-launch argv, tests).
pub fn openUrls(app: *App, urls: []const []const u8) void {
    deliverUrls(app, urls);
}

fn deliverUrls(app: *App, urls: []const []const u8) void {
    if (urls.len == 0) return;
    if (app.lifecycle.open_urls.items.items.len == 0) {
        for (urls) |u| {
            const copy = app.gpa.dupe(u8, u) catch continue;
            app.lifecycle.pending_urls.append(app.gpa, copy) catch app.gpa.free(copy);
        }
        return;
    }
    app.startUpdate();
    defer app.finishUpdate();
    const items = app.lifecycle.open_urls.snapshot(app.gpa);
    defer app.gpa.free(items);
    for (items) |*e| e.func(&e.cap, urls, app);
}

fn runVoid(app: *App, list: *VoidList) void {
    app.startUpdate();
    defer app.finishUpdate();
    const items = list.snapshot(app.gpa);
    defer app.gpa.free(items);
    for (items) |*e| e.func(&e.cap, {}, app);
}

/// Ask every `onShouldQuit` listener (deferred to the end of the current update, like
/// zeron's `cx.defer(prepare_quit)`); quits when all allow.
pub fn requestQuit(app: *App) void {
    if (app.quit_requested or app.lifecycle.quit_request_pending) return;
    app.lifecycle.quit_request_pending = true;
    app.deferFn(app, struct {
        fn run(a: *App, _: *App) void {
            a.lifecycle.quit_request_pending = false;
            if (a.quit_requested) return;
            if (askShouldQuit(a)) a.quit();
        }
    }.run);
}

fn askShouldQuit(app: *App) bool {
    app.startUpdate();
    defer app.finishUpdate();
    const items = app.lifecycle.should_quit.snapshot(app.gpa);
    defer app.gpa.free(items);
    var ok = true;
    // Every listener runs (each flushes / prompts its own state), like zeron's
    // `ready &= shell.prepare_quit(cx)`.
    for (items) |*e| ok = e.func(&e.cap, {}, app) and ok;
    return ok;
}

/// Run the `onQuit` listeners now (idempotent). Platforms call this through the `quit`
/// callback right before their run loop returns.
pub fn runQuitListeners(app: *App) void {
    if (app.lifecycle.quit_ran) return;
    app.lifecycle.quit_ran = true;
    runVoid(app, &app.lifecycle.quit);
    if (app.lifecycle.quit_async.items.items.len == 0) return;
    var teardowns: std.ArrayList(QuitTeardown) = .empty;
    defer teardowns.deinit(app.gpa);
    {
        app.startUpdate();
        defer app.finishUpdate();
        const items = app.lifecycle.quit_async.snapshot(app.gpa);
        defer app.gpa.free(items);
        for (items) |*e| {
            var t = e.func(&e.cap, {}, app);
            teardowns.append(app.gpa, t) catch t.release();
        }
    }
    awaitTeardowns(app, teardowns.items);
    for (teardowns.items) |*t| t.release();
}

/// gpui `block_with_timeout(SHUTDOWN_TIMEOUT, join_all(futures))`. The TestPlatform runs
/// its queued work deterministically instead of sleeping.
fn awaitTeardowns(app: *App, teardowns: []const QuitTeardown) void {
    const allDone = struct {
        fn f(ts: []const QuitTeardown) bool {
            for (ts) |t| if (!t.done()) return false;
            return true;
        }
    }.f;
    if (app.test_platform) |tp| {
        const d = tp.dispatcher();
        while (!allDone(teardowns)) if (!d.tick()) break;
        return;
    }
    const start = app.executor.now();
    while (!allDone(teardowns)) {
        if (app.executor.now() -| start >= shutdown_timeout_ns) {
            std.log.scoped(.zpui).err("timed out waiting on app quit teardown", .{});
            return;
        }
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
}

fn cbQuit(ctx: ?*anyopaque) void {
    runQuitListeners(appOf(ctx));
}

fn cbShouldQuit(ctx: ?*anyopaque) bool {
    const app = appOf(ctx);
    if (app.quit_requested) return true;
    if (app.lifecycle.should_quit.items.items.len == 0) {
        app.quit_requested = true;
        return true;
    }
    requestQuit(app);
    // `requestQuit` deferred to the end of an update; run that update now.
    app.startUpdate();
    app.finishUpdate();
    return false;
}

fn cbReopen(ctx: ?*anyopaque) void {
    const app = appOf(ctx);
    runVoid(app, &app.lifecycle.reopen);
}

fn cbOpenUrls(ctx: ?*anyopaque, urls: []const []const u8) void {
    deliverUrls(appOf(ctx), urls);
}

fn cbKeyboardLayout(ctx: ?*anyopaque) void {
    const app = appOf(ctx);
    runVoid(app, &app.lifecycle.keyboard_layout);
}

fn cbSystemWake(ctx: ?*anyopaque) void {
    const app = appOf(ctx);
    runVoid(app, &app.lifecycle.system_wake);
}

fn cbNotification(ctx: ?*anyopaque, tag: []const u8) void {
    const app = appOf(ctx);
    app.startUpdate();
    defer app.finishUpdate();
    const items = app.lifecycle.notification.snapshot(app.gpa);
    defer app.gpa.free(items);
    for (items) |*e| e.func(&e.cap, tag, app);
}

// ---------------------------------------------------------------------------------------
// Menus
// ---------------------------------------------------------------------------------------

/// Install the application menu bar (gpui `set_menus`). Key equivalents come from the
/// current keymap: the earliest context-free single-keystroke binding of each action
/// (gpui prefers earlier bindings for display), else the earliest single-keystroke one.
pub fn setMenus(app: *App, menus: []const Menu) Allocator.Error!void {
    const gpa = app.gpa;
    app.lifecycle.clearMenus(gpa);
    app.lifecycle.menu_arena = .init(gpa);
    const arena = app.lifecycle.menu_arena.?.allocator();
    app.lifecycle.menus = try dupeMenus(arena, menus);
    const out = try arena.alloc(pf.Menu, menus.len);
    for (app.lifecycle.menus, out) |m, *o| o.* = try translateMenu(app, arena, m);
    app.lifecycle.platform_menus = out;
    app.platform.setMenus(out);
}

fn dupeMenus(arena: Allocator, menus: []const Menu) Allocator.Error![]const Menu {
    const out = try arena.alloc(Menu, menus.len);
    for (menus, out) |m, *o| o.* = try dupeMenu(arena, m);
    return out;
}

fn dupeMenu(arena: Allocator, m: Menu) Allocator.Error!Menu {
    const items = try arena.alloc(MenuItem, m.items.len);
    for (m.items, items) |it, *o| o.* = switch (it) {
        .separator => .separator,
        .act => |a| blk: {
            var copy = a;
            copy.name = try arena.dupe(u8, a.name);
            break :blk .{ .act = copy };
        },
        .submenu => |sm| .{ .submenu = try dupeMenu(arena, sm) },
        .os_submenu => |os| .{ .os_submenu = .{ .name = try arena.dupe(u8, os.name), .kind = os.kind } },
    };
    return .{ .name = try arena.dupe(u8, m.name), .items = items, .disabled = m.disabled };
}

fn translateMenu(app: *App, arena: Allocator, m: Menu) Allocator.Error!pf.Menu {
    const items = try arena.alloc(pf.MenuItem, m.items.len);
    for (m.items, items) |it, *o| o.* = switch (it) {
        .separator => .separator,
        .act => |a| blk: {
            const tag = app.lifecycle.menu_actions.items.len;
            var built = try a.action.build(app.gpa);
            app.lifecycle.menu_actions.append(app.gpa, built) catch |err| {
                built.deinit(app.gpa);
                return err;
            };
            break :blk .{ .action = .{
                .name = a.name,
                .tag = tag,
                .key_equivalent = try keyEquivalent(app, arena, built),
                .os_action = a.os_action,
                .checked = a.checked,
                .disabled = a.disabled,
            } };
        },
        .submenu => |sm| .{ .submenu = try translateMenu(app, arena, sm) },
        .os_submenu => |os| .{ .system_menu = .{ .name = os.name, .kind = os.kind } },
    };
    return .{ .name = m.name, .items = items, .disabled = m.disabled };
}

fn keyEquivalent(app: *App, arena: Allocator, action: AnyAction) Allocator.Error!?pf.KeyEquivalent {
    var list = try app.keymap.bindingsForAction(app.gpa, action);
    defer list.deinit(app.gpa);
    var pick: ?*const keymap_mod.KeyBinding = null;
    for (list.items) |b| if (b.keystrokes.len == 1 and b.predicate == null) {
        pick = b;
        break;
    };
    if (pick == null) for (list.items) |b| if (b.keystrokes.len == 1) {
        pick = b;
        break;
    };
    const b = pick orelse return null;
    const ks = b.keystrokes[0];
    return .{ .key = try arena.dupe(u8, ks.key), .modifiers = ks.modifiers };
}

/// The menu action for `tag` (null if stale).
pub fn menuAction(app: *App, tag: usize) ?*const AnyAction {
    if (tag >= @import("desktop.zig").tray_tag_base) return @import("desktop.zig").trayAction(app, tag);
    if (tag >= app.lifecycle.menu_actions.items.len) return null;
    return &app.lifecycle.menu_actions.items[tag];
}

fn cbMenuAction(ctx: ?*anyopaque, tag: usize) void {
    const app = appOf(ctx);
    const a = menuAction(app, tag) orelse return;
    // Copy: the handler may call `setMenus`, which frees the table.
    var copy = a.clone(app.gpa) catch return;
    defer copy.deinit(app.gpa);
    dispatchAction(app, &copy);
}

fn cbValidateMenu(ctx: ?*anyopaque, tag: usize) bool {
    const app = appOf(ctx);
    const a = menuAction(app, tag) orelse return false;
    return isActionAvailable(app, a.type_id);
}

/// Dispatch `action` like a menu pick: to the active window's focus path (then globals),
/// or straight to the global listeners when no window is active.
pub fn dispatchAction(app: *App, action: *const AnyAction) void {
    if (app.activeWindow()) |w| {
        @import("../window/dispatch.zig").dispatchAnyAction(w, action);
        return;
    }
    app.startUpdate();
    defer app.finishUpdate();
    app.propagate_event = true;
    app.dispatchGlobalAction(action, .capture);
    if (app.propagate_event) app.dispatchGlobalAction(action, .bubble);
    @import("../window/dispatch.zig").traceAction(app, action);
}

/// gpui `is_action_available` for the menu: a global listener, or a listener on the
/// active window's focus path.
pub fn isActionAvailable(app: *App, tid: TypeId) bool {
    if (app.global_action_listeners.contains(type_id.key(tid))) return true;
    const w = app.activeWindow() orelse return false;
    return @import("../window/dispatch.zig").isActionTypeAvailable(w, tid);
}
