//! `viewport3d(scene)` — a styled box showing a zpui.three `Scene3D`.
//!
//! ```zig
//! div().flex1().child(zpui.viewport3dRounded(&self.scene3d, 12).sizeFull())
//! ```
//!
//! The scene is drawn offscreen (lit HDR, shadows, MSAA, post) and composited
//! at the element's bounds in draw order, so UI painted after it (tooltips,
//! frosted HUD panels with backdrop blur) sits on top. The 3D image is clipped
//! by the content mask and rounded by `viewport3dRounded`'s radius (the box's
//! own `rounded*` style shapes its background/border only). The scene must outlive the frame; update
//! its draw list in `render` or an animation callback and call
//! `window.requestAnimationFrame()` while it animates. For picking, use
//! `scene.pickAt(window_point)` from a mouse handler on this element or a parent.

const geometry = @import("../geometry.zig");
const App = @import("../app/app.zig").App;
const Window = @import("../window/window.zig").Window;
const canvas_mod = @import("canvas.zig");
const three = @import("../three/three.zig");

const Bounds = geometry.Bounds(geometry.Pixels);

const Ctx = struct { scene: *three.Scene3D, corner_radius: ?f32 };

fn paint(ctx: Ctx, bounds: Bounds, window: *Window, cx: *App) void {
    _ = cx;
    const r = ctx.corner_radius orelse 0;
    window.paintViewport3D(bounds, ctx.scene, .{ .corner_radii = .all(r) });
}

/// A box showing `scene` at its bounds every frame it is painted.
pub fn viewport3d(scene: *three.Scene3D) canvas_mod.Canvas {
    return canvas_mod.canvas(Ctx{ .scene = scene, .corner_radius = null }, paint);
}

/// Like `viewport3d` with a uniform corner radius (logical px) for the 3D image.
pub fn viewport3dRounded(scene: *three.Scene3D, corner_radius: f32) canvas_mod.Canvas {
    return canvas_mod.canvas(Ctx{ .scene = scene, .corner_radius = corner_radius }, paint);
}
