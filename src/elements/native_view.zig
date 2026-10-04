//! `nativeView(id)` — a styled box that hosts a native child view (zui fork's
//! native-child compositing; see `platform.NativeViewId` for the model).
//!
//! ```zig
//! const id = try window.attachNativeView(ns_view, .{});            // once
//! div().relative().flex1().child(zpui.nativeView(id).absolute().inset0())
//! window.detachNativeView(id);                                      // when done
//! ```
//!
//! Each frame the element records its layout bounds (and the current content mask as
//! the clip) during paint; the window places the native view right before presenting
//! that frame and hides it in frames where the element is not painted. It paints nothing
//! itself: give the parent an opaque background for the frames before the native view
//! has content. On backends without native views it is an empty box.

const geometry = @import("../geometry.zig");
const platform = @import("../platform/platform.zig");
const App = @import("../app/app.zig").App;
const Window = @import("../window/window.zig").Window;
const canvas_mod = @import("canvas.zig");

const Bounds = geometry.Bounds(geometry.Pixels);

pub const NativeViewOptions = struct {
    /// Uniform corner radius applied to the native view's layer.
    corner_radius: f32 = 0,
};

const Ctx = struct { id: platform.NativeViewId, opts: NativeViewOptions };

fn paint(ctx: Ctx, bounds: Bounds, window: *Window, _: *App) void {
    window.paintNativeView(ctx.id, bounds, ctx.opts.corner_radius);
}

/// A box placing native view `id` at its bounds every frame it is painted.
pub fn nativeView(id: platform.NativeViewId) canvas_mod.Canvas {
    return canvas_mod.canvas(Ctx{ .id = id, .opts = .{} }, paint);
}

pub fn nativeViewWith(id: platform.NativeViewId, opts: NativeViewOptions) canvas_mod.Canvas {
    return canvas_mod.canvas(Ctx{ .id = id, .opts = opts }, paint);
}
