//! `deferred(child)` — lay a child out in place but paint it after everything else, above
//! the rest of the window (gpui `elements/deferred.rs`). Higher `priority` paints later.
//! Combine with `anchored()` for popovers and menus.

const geometry = @import("../geometry.zig");
const App = @import("../app/app.zig").App;
const Window = @import("../window/window.zig").Window;
const element = @import("../window/element.zig");

const Bounds = geometry.Bounds(geometry.Pixels);

pub fn deferred(child: anytype) Deferred {
    return .{ .child = element.intoAnyElement(child) };
}

pub const Deferred = struct {
    child: element.AnyElement,
    priority: usize = 0,

    pub fn withPriority(self: Deferred, priority: usize) Deferred {
        var d = self;
        d.priority = priority;
        return d;
    }

    pub fn requestLayout(self: *Deferred, _: ?element.GlobalElementId, _: *void, window: *Window, cx: *App) element.LayoutId {
        return self.child.requestLayout(window, cx);
    }

    pub fn prepaint(self: *Deferred, _: ?element.GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, _: *App) void {
        window.deferDraw(self.child, window.elementOffset(), self.priority, null);
    }

    pub fn paint(_: *Deferred, _: ?element.GlobalElementId, _: Bounds, _: *void, _: *void, _: *Window, _: *App) void {}
};
