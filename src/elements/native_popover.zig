//! `nativePopover(anchor, options, content)` — rich floating content in a native
//! popover container (window/native_popover.zig has the model and lifecycle).
//!
//! ```zig
//! // Inside a `relative` trigger, while open:
//! trigger.child(zpui.nativePopover(.trigger("branch-picker"), .{ .edge = .below },
//!     zpui.popoverContent(cx.entity(), Pickers.nativeCard, Pickers.dismissNative))
//!     .fallback(ui.popover.anchoredBelow(card)));
//! ```
//!
//! Where the window shows native popovers the element is an invisible box covering the
//! trigger (`.trigger`) or nothing at all (`.point` / `.bounds`, window coordinates);
//! it records the popover in paint and the window opens, places and closes the popover
//! window. Elsewhere (Linux, tests by default, `options.native = false`) it lays out and
//! paints `fallback` exactly as if the fallback were the child itself.

const geometry = @import("../geometry.zig");
const style_mod = @import("../style.zig");
const refine = @import("../style/refine.zig");
const StyleBuilder = @import("../style/builder.zig").StyleBuilder;
const App = @import("../app/app.zig").App;
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const element = @import("../window/element.zig");
const core = @import("../window/native_popover.zig");

const Bounds = geometry.Bounds(geometry.Pixels);
const Point = geometry.Point(geometry.Pixels);

pub const Options = core.Options;
pub const Content = core.Content;
pub const Edge = core.Edge;
pub const Align = core.Align;
pub const content = core.content;

/// What the popover is placed against. `id` keys the popover (with the element id
/// stack), so keep it stable while the popover is open.
pub const Anchor = struct {
    id: element.ElementId,
    at: union(enum) {
        /// The element's own bounds: it covers its (relative) parent, the trigger.
        trigger,
        /// Window content coordinates.
        bounds: Bounds,
        point: Point,
    } = .trigger,

    pub fn trigger(id: anytype) Anchor {
        return .{ .id = .from(id) };
    }
    pub fn bounds(id: anytype, b: Bounds) Anchor {
        return .{ .id = .from(id), .at = .{ .bounds = b } };
    }
    pub fn point(id: anytype, p: Point) Anchor {
        return .{ .id = .from(id), .at = .{ .point = p } };
    }
};

pub fn nativePopover(anchor: Anchor, options: Options, c: Content) NativePopover {
    return .{ .anchor = anchor, .options = options, .content = c };
}

pub const NativePopover = struct {
    anchor: Anchor,
    options: Options,
    content: Content,
    fallback_el: ?element.AnyElement = null,

    /// Whether this frame uses the native popover (else the fallback).
    pub const RequestLayoutState = bool;

    /// What to render where native popovers are unavailable (the in-window popover).
    pub fn fallback(self: NativePopover, el: anytype) NativePopover {
        var s = self;
        s.fallback_el = element.intoAnyElement(el);
        return s;
    }

    pub fn elementId(self: *NativePopover) ?element.ElementId {
        return self.anchor.id;
    }

    pub fn requestLayout(self: *NativePopover, _: ?element.GlobalElementId, native: *bool, window: *Window, cx: *App) element.LayoutId {
        native.* = self.options.native and window.nativePopoversAvailable();
        if (!native.*) {
            if (self.fallback_el) |f| return f.requestLayout(window, cx);
            return window.requestLayout(.{}, &.{});
        }
        const r = switch (self.anchor.at) {
            .trigger => StyleBuilder.init.absolute().inset0().refinement,
            else => StyleBuilder.init.absolute().size(geometry.px(0)).refinement,
        };
        var s: style_mod.Style = .{};
        refine.refine(&s, r);
        return window.requestLayout(s, &.{});
    }

    pub fn prepaint(self: *NativePopover, _: ?element.GlobalElementId, _: Bounds, native: *bool, _: *void, window: *Window, cx: *App) void {
        if (native.*) return;
        if (self.fallback_el) |f| f.prepaint(window, cx);
    }

    pub fn paint(self: *NativePopover, gid: ?element.GlobalElementId, b: Bounds, native: *bool, _: *void, window: *Window, cx: *App) void {
        if (!native.*) {
            if (self.fallback_el) |f| f.paint(window, cx);
            return;
        }
        const anchor: Bounds = switch (self.anchor.at) {
            .trigger => b,
            .bounds => |x| x,
            .point => |p| .{ .origin = p, .size = .{ .width = 0, .height = 0 } },
        };
        core.request(window, .{ .key = gid.?.toKey(), .anchor = anchor, .options = self.options, .content = self.content });
    }
};
