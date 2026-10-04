//! zeron's hover cross-fade (`motion::hover_blend` / `hover_listener`):
//! every interactive wash blends rest → hover over 150ms (Tailwind ease)
//! instead of snapping. One app-global registry keyed by stable strings.
//!
//! ```zig
//! // render:
//! .bg(hover.blend(cx, key, rest_bg, hover_bg)).onHover(cx.listenerWith(ix, Self.onRowHover))
//! // listener:
//! hover.set(cx, key, hovered.*);   // key: any stable string (copied)
//! // once per frame (the shell does this):
//! hover.tick(window, cx);
//! ```

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");

const HoverFades = zt.motion.HoverFades;

pub const HoverGlobal = struct {
    gpa: std.mem.Allocator,
    fades: HoverFades = .{},

    pub fn deinit(self: *HoverGlobal) void {
        self.fades.deinit(self.gpa);
    }
};

fn appOf(cx: anytype) *zpui.App {
    if (@TypeOf(cx) == *zpui.App) return cx;
    return cx.app;
}

fn now(app: *zpui.App) u64 {
    return app.platform.dispatcher().now();
}

fn global(app: *zpui.App) *HoverGlobal {
    if (!app.hasGlobal(HoverGlobal)) app.setGlobal(HoverGlobal{ .gpa = app.gpa }) catch @panic("OOM");
    return app.globalMut(HoverGlobal);
}

/// Pointer entered/left the element behind `key`.
pub fn set(cx: anytype, key: []const u8, hovered: bool) void {
    const app = appOf(cx);
    const g = global(app);
    g.fades.set(g.gpa, key, hovered, false, now(app)) catch {};
    app.refreshWindows();
}

/// 0..1 hover progress for `key`.
pub fn value(cx: anytype, key: []const u8) f32 {
    const app = appOf(cx);
    return global(app).fades.value(key, now(app));
}

/// `rest` → `hover` at `key`'s progress.
pub fn blend(cx: anytype, key: []const u8, rest: zpui.Hsla, hover: zpui.Hsla) zpui.Hsla {
    const app = appOf(cx);
    return global(app).fades.blend(key, rest, hover, now(app));
}

/// Once per frame from the root view: prunes, and keeps frames coming while
/// any fade is mid-flight.
pub fn tick(window: *zpui.Window, cx: anytype) void {
    const app = appOf(cx);
    const g = global(app);
    if (g.fades.tick(g.gpa, now(app))) window.requestAnimationFrame();
}
