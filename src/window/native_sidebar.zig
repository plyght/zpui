//! Window-side bookkeeping for the native sidebar (`WindowParams.sidebar`,
//! `Window.nativeSidebar`; macOS `NSSplitViewController` with a source-list sidebar).
//!
//! The app describes the sidebar every render (`Window.nativeSidebar`): its rows, the
//! selected row and a listener. The state is pushed to the backend only when it differs
//! from what the sidebar already shows. A user selection arrives through
//! `WindowCallbacks.sidebar_select` (`handleSelect`): the stored selection takes the new
//! row first (so the next render does not push a stale one back), then the listener runs
//! inside an app update. A listener that ignores the change leaves the app's selection
//! unchanged; the next render then differs and pushes the app's selection back.

const std = @import("std");
const platform = @import("../platform/platform.zig");
const window_mod = @import("window.zig");
const context = @import("../app/context.zig");
const Window = window_mod.Window;

pub const Listener = context.Listener(platform.SidebarEvent);

pub const State = struct {
    /// What the sidebar shows (last pushed, or last selected by the user). Strings live
    /// in `arena`.
    shown: ?platform.SidebarState = null,
    arena: ?std.heap.ArenaAllocator = null,
    listener: ?Listener = null,
    /// Pushes to the backend (diagnostics / tests).
    push_count: u32 = 0,

    pub fn deinit(self: *State) void {
        if (self.arena) |*a| a.deinit();
        self.arena = null;
        self.shown = null;
    }
};

pub fn stateEql(a: platform.SidebarState, b: platform.SidebarState) bool {
    if (!std.meta.eql(a.selected, b.selected) or !std.meta.eql(a.dark, b.dark)) return false;
    if (!std.mem.eql(u8, a.label, b.label) or a.items.len != b.items.len) return false;
    for (a.items, b.items) |x, y| {
        if (!std.mem.eql(u8, x.title, y.title) or !std.mem.eql(u8, x.symbol, y.symbol) or !std.meta.eql(x.badge, y.badge)) return false;
    }
    return true;
}

fn store(w: *Window, state: platform.SidebarState) void {
    const s = &w.native_sidebar;
    if (s.arena == null) s.arena = .init(w.gpa);
    _ = s.arena.?.reset(.retain_capacity);
    const a = s.arena.?.allocator();
    var copy = state;
    copy.label = a.dupe(u8, state.label) catch "";
    copy.items = blk: {
        const items = a.alloc(platform.SidebarItem, state.items.len) catch break :blk &.{};
        for (state.items, items) |src, *dst| dst.* = .{
            .title = a.dupe(u8, src.title) catch "",
            .symbol = a.dupe(u8, src.symbol) catch "",
            .badge = src.badge,
        };
        break :blk items;
    };
    s.shown = copy;
}

/// Show `state_in` in the window's native sidebar; `listener` receives user selections.
/// False when the window has no native sidebar (draw your own).
pub fn set(w: *Window, state_in: platform.SidebarState, listener: ?Listener) bool {
    if (!w.platform_window.hasSidebar()) return false;
    var state = state_in;
    if (state.dark == null) state.dark = w.glass_dark;
    const s = &w.native_sidebar;
    s.listener = listener;
    if (s.shown) |shown| if (stateEql(shown, state)) return true;
    store(w, state);
    s.push_count += 1;
    w.platform_window.setSidebar(s.shown.?);
    return true;
}

/// A user selection from the backend: record it, then run the listener.
pub fn handleSelect(w: *Window, event: platform.SidebarEvent) void {
    const s = &w.native_sidebar;
    if (s.shown) |*shown| {
        if (event.index >= shown.items.len) return;
        shown.selected = event.index;
    }
    const l = s.listener orelse return;
    const app = w.app;
    app.startUpdate();
    defer app.finishUpdate();
    l.callIn(&event, w, app);
}
