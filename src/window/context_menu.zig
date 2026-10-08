//! Native context menus (`zpui.showContextMenu`): a platform menu (macOS NSMenu) popped
//! up in a window, for plain menus that need no custom content.
//!
//! ```zig
//! const items = [_]zpui.ContextMenuItem{
//!     .action("Rename", 0),
//!     .{ .label = "Pin", .tag = 1, .check = .on, .shortcut = .{ .key = "p", .modifiers = .{ .platform = true } } },
//!     .separator,
//!     .{ .label = "Delete", .tag = 2, .destructive = true, .icon = trash_svg },
//! };
//! if (!zpui.showContextMenu(window, ev.position, &items, cx.listener(onMenuPick))) {
//!     // unsupported here (Linux, tests): draw the menu instead
//! }
//! fn onMenuPick(self: *V, sel: *const zpui.ContextMenuSelection, window: *Window, cx: *Context(V)) void {
//!     const tag = sel.tag orelse return; // null: dismissed
//! }
//! ```
//!
//! * `show` copies everything (labels, icons rasterized from SVG into coverage masks at
//!   the window's scale) and returns at once; the platform pops the menu up after the
//!   current event, so the app is never inside an update while the menu tracks (frames
//!   keep rendering underneath).
//! * The listener runs exactly once, on the main thread inside an app update, with the
//!   chosen tag or null when the menu was dismissed. It is dropped when the window
//!   closed meanwhile.
//! * Returns false (and never calls the listener) when the window shows no native menus:
//!   every backend but macOS, and `TestWindow` unless `native_menus` is set.

const std = @import("std");
const platform = @import("../platform/platform.zig");
const geometry = @import("../geometry.zig");
const context = @import("../app/context.zig");
const svg = @import("../image/svg.zig");
const window_mod = @import("window.zig");

const Window = window_mod.Window;
const App = @import("../app/app.zig").App;
const Point = geometry.Point(geometry.Pixels);

pub const Kind = platform.ContextMenuItemKind;
pub const Check = platform.ContextMenuCheck;

/// A displayed shortcut: a gpui key name ("n", "enter", "backspace", ...) + modifiers.
pub const Shortcut = platform.KeyEquivalent;

pub const MenuItem = struct {
    kind: Kind = .action,
    label: []const u8 = "",
    /// Reported in `Selection.tag` when this action is chosen.
    tag: u32 = 0,
    /// SVG source (painting with `currentColor` / black), shown as a template image.
    icon: ?[]const u8 = null,
    /// Icon edge in points.
    icon_size: f32 = 16,
    shortcut: ?Shortcut = null,
    check: Check = .off,
    disabled: bool = false,
    destructive: bool = false,
    /// `.submenu` children.
    submenu: []const MenuItem = &.{},

    pub const separator: MenuItem = .{ .kind = .separator };

    pub fn action(label: []const u8, tag: u32) MenuItem {
        return .{ .label = label, .tag = tag };
    }

    pub fn header(label: []const u8) MenuItem {
        return .{ .kind = .header, .label = label };
    }

    pub fn sub(label: []const u8, children: []const MenuItem) MenuItem {
        return .{ .kind = .submenu, .label = label, .submenu = children };
    }
};

/// What the user did with the menu: the chosen item's tag, or null (dismissed).
pub const Selection = struct { tag: ?u32 };

pub const Listener = context.Listener(Selection);

/// Whether `w`'s backend has native menus at all (`show` may still decline, e.g. a
/// `TestWindow` without `native_menus`).
pub fn supported(w: *const Window) bool {
    return !w.platform_closed and w.platform_window.supportsContextMenus();
}

const Pending = struct {
    app: *App,
    window: window_mod.WindowId,
    listener: Listener,
};

/// Pop up `items` at `position` (window coordinates; the menu's top-left). See the
/// module docs. `dark` pins the menu's appearance (null = the window's glass/theme
/// setting, `Window.glass_dark`).
pub fn show(w: *Window, position: Point, items: []const MenuItem, on_select: Listener) bool {
    return showWith(w, position, items, null, on_select);
}

pub fn showWith(w: *Window, position: Point, items: []const MenuItem, dark: ?bool, on_select: Listener) bool {
    if (!supported(w) or items.len == 0) return false;
    var arena_state: std.heap.ArenaAllocator = .init(w.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const converted = convert(a, items, w.scale_factor) catch return false;
    const pending = w.gpa.create(Pending) catch return false;
    pending.* = .{ .app = w.app, .window = w.id, .listener = on_select };
    const request: platform.ContextMenuRequest = .{ .items = converted, .position = position, .dark = dark orelse w.glass_dark };
    if (!w.platform_window.showContextMenu(request, .{ .ctx = pending, .func = finish })) {
        w.gpa.destroy(pending);
        return false;
    }
    return true;
}

fn finish(ctx: ?*anyopaque, selected: ?u32) void {
    const pending: *Pending = @ptrCast(@alignCast(ctx.?));
    const app = pending.app;
    const listener = pending.listener;
    const wid = pending.window;
    app.gpa.destroy(pending);
    app.startUpdate();
    defer app.finishUpdate();
    const w = app.windowById(wid) orelse return;
    const sel: Selection = .{ .tag = selected };
    listener.callIn(&sel, w, app);
    w.refresh();
}

/// Platform items (strings borrowed from `items`, icons and arrays in `a`).
pub fn convert(a: std.mem.Allocator, items: []const MenuItem, scale: f32) ![]platform.ContextMenuItem {
    const out = try a.alloc(platform.ContextMenuItem, items.len);
    for (items, out) |it, *o| {
        o.* = .{
            .kind = it.kind,
            .label = it.label,
            .tag = it.tag,
            .shortcut = it.shortcut,
            .check = it.check,
            .disabled = it.disabled,
            .destructive = it.destructive,
        };
        if (it.kind == .submenu) o.children = try convert(a, it.submenu, scale);
        if (it.icon) |src| o.icon = rasterizeIcon(a, src, it.icon_size, scale);
    }
    return out;
}

/// The SVG's coverage at `size_pt * scale` device pixels; null when it does not render.
pub fn rasterizeIcon(a: std.mem.Allocator, src: []const u8, size_pt: f32, scale: f32) ?platform.ContextMenuIcon {
    const s = @max(scale, 1);
    const edge: i32 = @intFromFloat(@max(@round(size_pt * s), 1));
    const mask = svg.rasterizeAlphaMask(a, src, .{ .width = edge, .height = edge }) catch return null;
    return .{ .width = mask.width, .height = mask.height, .scale = s, .alpha = mask.bytes };
}

/// Count of selectable (enabled action) items, submenus included (tests / diagnostics).
pub fn actionCount(items: []const MenuItem) usize {
    var n: usize = 0;
    for (items) |it| switch (it.kind) {
        .action => if (!it.disabled) {
            n += 1;
        },
        .submenu => n += actionCount(it.submenu),
        else => {},
    };
    return n;
}
