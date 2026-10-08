//! App-level access to the desktop-companion platform features (docs/DESKTOP_OVERLAY.md):
//! the global input monitor, the foreground application, a tray / menu bar item whose
//! menu dispatches actions like the app menu, and launch at login.
//!
//! ```zig
//! const status = app.startGlobalInputMonitor(&pet, Pet.onInput);   // fn(*Pet, GlobalInputEvent, *App)
//! try app.onForegroundAppChange(&pet, Pet.foregroundChanged);      // fn(*Pet, *App)
//! var buf: [256]u8 = undefined;
//! if (app.foregroundApp(&buf)) |fg| hideWhen(fg.id);
//! try app.setTray(.{ .icon_png = icon, .tooltip = "typebud", .items = &.{
//!     .action("Quit typebud", Quit{}),
//! } });
//! try app.setLaunchAtLogin("typebud", exe_path, true);
//! ```
//!
//! Callbacks run on the main thread inside an update (entity changes flush afterwards).
//! Tray items use tags from `tray_tag_base` up, so they never collide with `setMenus`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const pf = @import("../platform/platform.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Captures = app_mod.Captures;
const lifecycle = @import("lifecycle.zig");
const action_mod = @import("action.zig");
const AnyAction = action_mod.AnyAction;

/// First menu tag of tray items (`PlatformCallbacks.menu_action` tags below it belong to
/// the menu bar).
pub const tray_tag_base: usize = 1 << 30;

const InputEntry = struct {
    func: *const fn (cap: *const Captures, event: pf.GlobalInputEvent, app: *App) void,
    cap: Captures,
};
const VoidEntry = struct {
    func: *const fn (cap: *const Captures, app: *App) void,
    cap: Captures,
};

/// Embedded in `App` (`app.desktop`).
pub const Desktop = struct {
    input: ?InputEntry = null,
    foreground: std.ArrayList(VoidEntry) = .empty,
    foreground_installed: bool = false,
    tray_arena: ?std.heap.ArenaAllocator = null,
    tray_actions: std.ArrayList(AnyAction) = .empty,

    pub fn deinit(self: *Desktop, gpa: Allocator) void {
        if (self.input) |*e| e.cap.deinit(gpa);
        self.input = null;
        for (self.foreground.items) |*e| e.cap.deinit(gpa);
        self.foreground.deinit(gpa);
        self.clearTray(gpa);
    }

    fn clearTray(self: *Desktop, gpa: Allocator) void {
        for (self.tray_actions.items) |*a| a.deinit(gpa);
        self.tray_actions.deinit(gpa);
        self.tray_actions = .empty;
        if (self.tray_arena) |*a| a.deinit();
        self.tray_arena = null;
    }
};

fn appOf(ctx: ?*anyopaque) *App {
    return @ptrCast(@alignCast(ctx.?));
}

// ---- global input --------------------------------------------------------------------

/// Start (or retarget) the global input monitor; `f(ctx, event, app)` runs per event.
/// Returns what the platform could start (`.needs_permission`: ask with
/// `requestInputPermission`, then call this again).
pub fn startGlobalInputMonitor(app: *App, ctx: anytype, comptime f: anytype) pf.InputMonitorStatus {
    const C = @TypeOf(ctx);
    const Gen = struct {
        fn call(cap: *const Captures, event: pf.GlobalInputEvent, a: *App) void {
            f(app_mod.unwrapCtx(C, cap), event, a);
        }
    };
    if (app.desktop.input) |*e| e.cap.deinit(app.gpa);
    app.desktop.input = .{ .func = Gen.call, .cap = app_mod.wrapCtx(ctx) };
    return app.platform.startGlobalInputMonitor(.{ .ctx = app, .func = onGlobalInput });
}

pub fn stopGlobalInputMonitor(app: *App) void {
    app.platform.stopGlobalInputMonitor();
    if (app.desktop.input) |*e| e.cap.deinit(app.gpa);
    app.desktop.input = null;
}

fn onGlobalInput(ctx: ?*anyopaque, event: pf.GlobalInputEvent) void {
    const app = appOf(ctx);
    const e = app.desktop.input orelse return;
    app.startUpdate();
    defer app.finishUpdate();
    e.func(&e.cap, event, app);
}

// ---- foreground app ------------------------------------------------------------------

/// `f(ctx, app)` runs whenever the foreground application changes.
pub fn onForegroundAppChange(app: *App, ctx: anytype, comptime f: anytype) Allocator.Error!void {
    const C = @TypeOf(ctx);
    const Gen = struct {
        fn call(cap: *const Captures, a: *App) void {
            f(app_mod.unwrapCtx(C, cap), a);
        }
    };
    try app.desktop.foreground.append(app.gpa, .{ .func = Gen.call, .cap = app_mod.wrapCtx(ctx) });
    if (!app.desktop.foreground_installed) {
        app.desktop.foreground_installed = true;
        app.platform.setForegroundAppCallback(.{ .ctx = app, .func = onForegroundChanged });
    }
}

fn onForegroundChanged(ctx: ?*anyopaque, _: void) void {
    const app = appOf(ctx);
    app.startUpdate();
    defer app.finishUpdate();
    const items = app.gpa.dupe(VoidEntry, app.desktop.foreground.items) catch return;
    defer app.gpa.free(items);
    for (items) |*e| e.func(&e.cap, app);
}

// ---- tray ----------------------------------------------------------------------------

/// A tray / menu bar item whose menu holds app-menu items (actions dispatch like menu
/// bar picks: to the active window's focus path, else global `onAction` listeners).
pub const Tray = struct {
    icon_png: []const u8,
    template: bool = true,
    tooltip: []const u8 = "",
    items: []const lifecycle.MenuItem,
};

/// Install / replace (or with null, remove) the tray item. `error.Unsupported` when the
/// desktop has no tray host (e.g. GNOME without an AppIndicator extension).
pub fn setTray(app: *App, tray: ?Tray) !void {
    const gpa = app.gpa;
    app.desktop.clearTray(gpa);
    const t = tray orelse return app.platform.setTrayItem(null);
    app.desktop.tray_arena = .init(gpa);
    const arena = app.desktop.tray_arena.?.allocator();
    const items = try translate(app, arena, t.items);
    try app.platform.setTrayItem(.{
        .icon_png = try arena.dupe(u8, t.icon_png),
        .template = t.template,
        .tooltip = try arena.dupe(u8, t.tooltip),
        .menu = items,
    });
}

fn translate(app: *App, arena: Allocator, items: []const lifecycle.MenuItem) ![]const pf.MenuItem {
    const out = try arena.alloc(pf.MenuItem, items.len);
    for (items, out) |it, *o| o.* = switch (it) {
        .separator => .separator,
        .act => |a| blk: {
            const tag = tray_tag_base + app.desktop.tray_actions.items.len;
            var built = try a.action.build(app.gpa);
            app.desktop.tray_actions.append(app.gpa, built) catch |err| {
                built.deinit(app.gpa);
                return err;
            };
            break :blk .{ .action = .{ .name = try arena.dupe(u8, a.name), .tag = tag, .os_action = a.os_action, .checked = a.checked, .disabled = a.disabled } };
        },
        .submenu => |sm| .{ .submenu = .{ .name = try arena.dupe(u8, sm.name), .items = try translate(app, arena, sm.items), .disabled = sm.disabled } },
        .os_submenu => |os| .{ .system_menu = .{ .name = try arena.dupe(u8, os.name), .kind = os.kind } },
    };
    return out;
}

/// The tray action for `tag` (null when `tag` is not a live tray tag).
pub fn trayAction(app: *App, tag: usize) ?*const AnyAction {
    if (tag < tray_tag_base) return null;
    const i = tag - tray_tag_base;
    if (i >= app.desktop.tray_actions.items.len) return null;
    return &app.desktop.tray_actions.items[i];
}

// ---- launch at login -----------------------------------------------------------------

pub fn setLaunchAtLogin(app: *App, app_id: []const u8, exe_path: []const u8, on: bool) !void {
    return app.platform.setLaunchAtLogin(app_id, exe_path, on);
}
