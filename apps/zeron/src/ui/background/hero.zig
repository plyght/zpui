//! The new-thread canvas hero (zeron `shell.rs` `new_thread_background*`,
//! `new_thread_background_mask.rs`, `new_thread_background_effects.rs`
//! `Readiness`): object-fit-cover framing with the user's focal point and
//! zoom, a paint-time alpha mask that opens a feathered rounded cutout around
//! the composer and fades the artwork toward the hero's bottom edge, the
//! frosted-theme opacity, and a 180ms crossfade between images.
//!
//! Settings → Appearance → Background fade (`model.background_fade`, Zig
//! client only) picks the mask: `full` is the Rust treatment above,
//! untouched; `subtle` a short bottom fade and a small, gentle cutout feather
//! revealed at 0.82; `none` paints the crop unmasked, edge to edge.
//!
//! ```zig
//! const frame = self.artwork_ready.frame(app, image, path, adjustment, enabled, reduced, now_ns);
//! col = col.child(hero.layer(frame, viewport_h, width, &composer.surface_bounds, theme.surface_treatment == .frosted, fade));
//! ```

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const cache = @import("cache.zig");

const App = zpui.App;
const Window = zpui.Window;
const Bounds = zpui.Bounds(f32);
const RenderImage = zpui.image.RenderImage;
const Adjustment = model.settings.NewThreadBackgroundAdjustment;
pub const Fade = model.background_fade.BackgroundFade;
const div = zpui.div;
const px = zpui.px;

pub const frosted_opacity: f32 = 0.84;
pub const viewport_ratio: f32 = 0.72;
pub const max_height: f32 = 760;
/// Half-strength artwork through the cutout's darkest area (`full`).
pub const cutout_reveal_opacity: f32 = 0.5;

/// `subtle`: the bottom fade band (a fraction of the hero height, clamped),
/// the composer feather and clearance. The artwork holds full strength
/// through the top two thirds and only softens into the window near the
/// hero's edge; around the composer a narrow feather keeps the pill's
/// outline legible without the wide dark halo.
pub const subtle_fade_ratio: f32 = 0.34;
pub const subtle_fade_min: f32 = 72;
pub const subtle_fade_max: f32 = 220;
pub const subtle_feather_ratio: f32 = 0.1;
pub const subtle_feather_min: f32 = 28;
pub const subtle_feather_max: f32 = 64;
pub const subtle_clearance: f32 = 4;

/// The underlay opacity inside the cutout for `fade`.
pub fn cutoutReveal(fade: Fade) f32 {
    return fade.cutoutReveal();
}
/// `composer::COMPOSER_RADIUS`.
pub const composer_radius: f32 = 26;

/// `new_thread_background_opacity`.
pub fn opacity(is_frost: bool) f32 {
    return if (is_frost) frosted_opacity else 1.0;
}

/// `new_thread_background_height`.
pub fn height(viewport_height: f32) f32 {
    return @min(@max(viewport_height, 0) * viewport_ratio, max_height);
}

// ---- geometry ---------------------------------------------------------------

pub const Fitted = struct {
    bounds: Bounds,
    width: f32,
    height: f32,
    overflow_x: f32,
    overflow_y: f32,
};

fn finite(x: f32) bool {
    return std.math.isFinite(x);
}

/// `fitted_geometry`: cover scale × zoom, positioned by the focal point.
pub fn fittedGeometry(source_width: f32, source_height: f32, b: Bounds, adjustment_in: Adjustment) ?Fitted {
    const width = b.size.width;
    const h = b.size.height;
    if (!(width > 0) or !(h > 0) or !finite(width) or !finite(h) or !(source_width > 0) or !(source_height > 0) or !finite(source_width) or !finite(source_height)) return null;
    const a = adjustment_in.normalized();
    const cover = @max(width / source_width, h / source_height);
    const fw = @max(source_width * cover * a.zoom, width);
    const fh = @max(source_height * cover * a.zoom, h);
    const ox = @max(fw - width, 0);
    const oy = @max(fh - h, 0);
    return .{
        .bounds = .{ .origin = .{ .x = b.origin.x - ox * a.focalX, .y = b.origin.y - oy * a.focalY }, .size = .{ .width = fw, .height = fh } },
        .width = fw,
        .height = fh,
        .overflow_x = ox,
        .overflow_y = oy,
    };
}

fn sourceSize(img: *const RenderImage) [2]f32 {
    const s = img.size(0);
    return .{ @floatFromInt(s.width), @floatFromInt(s.height) };
}

pub fn sourceGeometry(img: *const RenderImage, b: Bounds, adjustment: Adjustment) ?Fitted {
    const s = sourceSize(img);
    return fittedGeometry(s[0], s[1], b, adjustment);
}

/// `pan_adjustment`: a drag delta → viewport-independent framing.
pub fn panAdjustmentSized(source_width: f32, source_height: f32, b: Bounds, adjustment_in: Adjustment, dx: f32, dy: f32) Adjustment {
    const adjustment = adjustment_in.normalized();
    const g = fittedGeometry(source_width, source_height, b, adjustment) orelse return adjustment;
    var next = adjustment;
    if (g.overflow_x > 0) next.focalX -= dx / g.overflow_x;
    if (g.overflow_y > 0) next.focalY -= dy / g.overflow_y;
    return next.normalized();
}

/// `zoom_adjustment_around`: keep the source pixel under `anchor` fixed.
pub fn zoomAdjustmentAroundSized(source_width: f32, source_height: f32, b: Bounds, adjustment_in: Adjustment, zoom: f32, anchor: zpui.Point(f32)) Adjustment {
    const adjustment = adjustment_in.normalized();
    const previous = fittedGeometry(source_width, source_height, b, adjustment) orelse return adjustment;
    var next = adjustment;
    next.zoom = zoom;
    next = next.normalized();
    const fitted = fittedGeometry(source_width, source_height, b, next) orelse return adjustment;
    const sx = (anchor.x - previous.bounds.origin.x) / previous.width;
    const sy = (anchor.y - previous.bounds.origin.y) / previous.height;
    if (fitted.overflow_x > 0) {
        const desired_left = anchor.x - sx * fitted.width;
        next.focalX = (b.origin.x - desired_left) / fitted.overflow_x;
    }
    if (fitted.overflow_y > 0) {
        const desired_top = anchor.y - sy * fitted.height;
        next.focalY = (b.origin.y - desired_top) / fitted.overflow_y;
    }
    return next.normalized();
}

/// `mask`: the cutout pass clears a feathered rounded rect around the
/// composer (kept open through the hero's bottom); the reveal pass only has
/// the shared bottom fade (its exclusion sits below the image).
pub fn mask(b: Bounds, composer: Bounds, cutout: bool) zpui.scene.ImageAlphaMask {
    const h = b.size.height;
    const bottom = b.origin.y + b.size.height;
    const composer_bottom = composer.origin.y + composer.size.height;
    const cleared: Bounds = .{ .origin = composer.origin, .size = .{ .width = composer.size.width, .height = @max(composer_bottom, bottom) - composer.origin.y } };
    return .{
        .bounds = if (cutout) cleared else .{ .origin = .{ .x = b.origin.x, .y = bottom + 1 }, .size = b.size },
        .radius = if (cutout) composer_radius else 0,
        .feather = if (cutout) std.math.clamp(h * 0.52, 120, 280) else 1,
        .clearance = if (cutout) 8 else 0,
        .bottom_fade = .{ .y = bottom, .feather = @max(h, 1) },
    };
}

/// `subtle`: the same two passes and cleared region as `mask`, with a short
/// bottom fade and a small feather.
pub fn subtleMask(b: Bounds, composer: Bounds, cutout: bool) zpui.scene.ImageAlphaMask {
    var m = mask(b, composer, cutout);
    const h = b.size.height;
    m.bottom_fade.?.feather = std.math.clamp(h * subtle_fade_ratio, @min(subtle_fade_min, @max(h, 1)), subtle_fade_max);
    if (cutout) {
        m.feather = std.math.clamp(h * subtle_feather_ratio, subtle_feather_min, subtle_feather_max);
        m.clearance = subtle_clearance;
    }
    return m;
}

/// The mask of one pass for `fade`; null paints the crop unmasked (`none`).
pub fn maskFor(b: Bounds, composer: Bounds, cutout: bool, fade: Fade) ?zpui.scene.ImageAlphaMask {
    return switch (fade) {
        .full => mask(b, composer, cutout),
        .subtle => subtleMask(b, composer, cutout),
        .none => null,
    };
}

/// Map `m` (built in `from`'s space) into `to` (the same rect scaled).
pub fn scaleMask(m: zpui.scene.ImageAlphaMask, from: Bounds, to: Bounds) zpui.scene.ImageAlphaMask {
    const k = if (from.size.width > 0) to.size.width / from.size.width else 1;
    var out = m;
    out.bounds = mapRect(m.bounds, from, to);
    out.radius = m.radius * k;
    out.feather = m.feather * k;
    out.clearance = m.clearance * k;
    if (m.bottom_fade) |bf| out.bottom_fade = .{ .y = to.origin.y + (bf.y - from.origin.y) * k, .feather = bf.feather * k };
    return out;
}

fn mapRect(r: Bounds, from: Bounds, to: Bounds) Bounds {
    const k = if (from.size.width > 0) to.size.width / from.size.width else 1;
    return .{
        .origin = .{ .x = to.origin.x + (r.origin.x - from.origin.x) * k, .y = to.origin.y + (r.origin.y - from.origin.y) * k },
        .size = .{ .width = r.size.width * k, .height = r.size.height * k },
    };
}

/// The hero and composer the canvas last painted with (the Adjust preview
/// scales them to show the chosen fade around the real composer).
pub const Geometry = struct { hero: Bounds, composer: Bounds };
pub var last_geometry: ?Geometry = null;

/// A composer-like rect for a preview before the canvas has painted.
pub fn fallbackGeometry(hero: Bounds) Geometry {
    const w = @max(@min(hero.size.width - 48, 768), 1);
    const h: f32 = 124;
    return .{ .hero = hero, .composer = .{
        .origin = .{ .x = hero.origin.x + (hero.size.width - w) / 2, .y = hero.origin.y + hero.size.height * 0.62 },
        .size = .{ .width = w, .height = h },
    } };
}

/// The Adjust dialog's view of the hero: the last painted geometry scaled
/// into `preview` (same aspect as the runtime hero).
pub fn previewGeometry(preview: Bounds) Geometry {
    const g = last_geometry orelse return fallbackGeometry(preview);
    return .{ .hero = preview, .composer = mapRect(g.composer, g.hero, preview) };
}

/// Preview pixels per runtime hero pixel.
pub fn previewScale(preview: Bounds) f32 {
    const g = last_geometry orelse return 1;
    return if (g.hero.size.width > 0) preview.size.width / g.hero.size.width else 1;
}

/// One preview pass's mask: computed at the runtime hero's size, then scaled,
/// so the feathers keep their proportions.
pub fn previewMask(preview: Bounds, cutout: bool, fade: Fade) ?zpui.scene.ImageAlphaMask {
    const g = last_geometry orelse fallbackGeometry(preview);
    const k = if (g.hero.size.width > 0) preview.size.width / g.hero.size.width else 1;
    // The runtime hero rect that maps exactly onto `preview`.
    const hero: Bounds = .{ .origin = g.hero.origin, .size = .{ .width = g.hero.size.width, .height = preview.size.height / k } };
    const m = maskFor(hero, g.composer, cutout, fade) orelse return null;
    return scaleMask(m, hero, preview);
}

/// Paint the adjusted crop (`paint_adjusted_with_mask`).
pub fn paintAdjusted(window: *Window, img: *const RenderImage, b: Bounds, adjustment: Adjustment, radii: zpui.Corners(f32), alpha_mask: ?zpui.scene.ImageAlphaMask) void {
    const fitted = sourceGeometry(img, b, adjustment) orelse return;
    window.paintImageFitted(b, fitted.bounds, radii, img, 0, false, alpha_mask);
}

// ---- readiness (crossfade) --------------------------------------------------

/// Hold the displayed artwork while the next one loads, then crossfade
/// (`motion::WALLPAPER_CROSSFADE`); finish each blend before adopting another.
pub const Readiness = struct {
    current: ?*RenderImage = null,
    previous: ?*RenderImage = null,
    current_adjustment: Adjustment = .{},
    previous_adjustment: Adjustment = .{},
    current_path: std.ArrayList(u8) = .empty,
    previous_path: std.ArrayList(u8) = .empty,
    has_current_path: bool = false,
    has_previous_path: bool = false,
    started: ?u64 = null,
    /// zpui-only: the moving background `current` is a frame of (0 = a still).
    /// Its next frames replace `current` in place instead of crossfading.
    current_stream: u64 = 0,

    pub const Frame = struct {
        current: ?*RenderImage,
        previous: ?*RenderImage,
        current_adjustment: Adjustment,
        previous_adjustment: Adjustment,
        mix: f32,
        active: bool,
    };

    pub fn deinit(self: *Readiness, app: ?*App, gpa: std.mem.Allocator) void {
        self.setImage(app, .current, null);
        self.setImage(app, .previous, null);
        self.current_path.deinit(gpa);
        self.previous_path.deinit(gpa);
    }

    fn setImage(self: *Readiness, app: ?*App, comptime which: enum { current, previous }, img: ?*RenderImage) void {
        const slot = switch (which) {
            .current => &self.current,
            .previous => &self.previous,
        };
        if (slot.* == img) return;
        if (img) |i| _ = i.retain();
        if (slot.*) |old| if (app) |a| cache.releaseImage(a, old) else old.release();
        slot.* = img;
    }

    fn mixAt(start: u64, now: u64) f32 {
        return zt.motion.wallpaper_crossfade.progressAt(now -| start, 1.0);
    }

    fn samePath(list: *const std.ArrayList(u8), has: bool, path: ?[]const u8) bool {
        const p = path orelse return false;
        return has and std.mem.eql(u8, list.items, p);
    }

    pub fn frame(self: *Readiness, app: ?*App, gpa: std.mem.Allocator, image: ?*RenderImage, path: ?[]const u8, adjustment: Adjustment, enabled: bool, reduced: bool, now: u64) Frame {
        return self.frameStream(app, gpa, image, path, adjustment, enabled, reduced, now, 0);
    }

    /// `frame` for an image that may be a frame of the moving background `stream`.
    pub fn frameStream(self: *Readiness, app: ?*App, gpa: std.mem.Allocator, image: ?*RenderImage, path: ?[]const u8, adjustment: Adjustment, enabled: bool, reduced: bool, now: u64, stream: u64) Frame {
        if (stream != 0 and enabled and self.current != null and self.current_stream == stream and samePath(&self.current_path, self.has_current_path, path)) {
            if (image) |img| self.setImage(app, .current, img);
        }
        const progress: f32 = if (self.started) |s| mixAt(s, now) else 1.0;
        if (reduced or progress >= 1.0) {
            self.setImage(app, .previous, null);
            self.has_previous_path = false;
            self.started = null;
        }
        // A crop belongs to the source path, not its (possibly loading) effect raster.
        if (samePath(&self.current_path, self.has_current_path, path)) self.current_adjustment = adjustment.normalized();
        if (samePath(&self.previous_path, self.has_previous_path, path)) self.previous_adjustment = adjustment.normalized();
        // Null while enabled means "still loading", not "remove the artwork".
        if (self.started == null and (!enabled or image != null)) {
            const target: ?*RenderImage = if (enabled) image else null;
            const cur_id: ?u64 = if (self.current) |c| c.id else null;
            const tgt_id: ?u64 = if (target) |t| t.id else null;
            if (cur_id != tgt_id) {
                // previous ← current
                self.setImage(app, .previous, self.current);
                self.previous_adjustment = self.current_adjustment;
                std.mem.swap(std.ArrayList(u8), &self.previous_path, &self.current_path);
                self.has_previous_path = self.has_current_path;
                self.setImage(app, .current, target);
                self.current_stream = if (target != null) stream else 0;
                self.current_adjustment = adjustment.normalized();
                self.current_path.clearRetainingCapacity();
                self.has_current_path = false;
                if (path) |p| {
                    self.current_path.appendSlice(gpa, p) catch {};
                    self.has_current_path = true;
                }
                if (reduced) {
                    self.setImage(app, .previous, null);
                    self.has_previous_path = false;
                } else self.started = now;
            }
        }
        return .{
            .current = self.current,
            .previous = self.previous,
            .current_adjustment = self.current_adjustment,
            .previous_adjustment = self.previous_adjustment,
            .mix = if (self.started) |s| mixAt(s, now) else 1.0,
            .active = self.started != null,
        };
    }
};

// ---- element ----------------------------------------------------------------

const PaintCtx = struct {
    image: *RenderImage,
    adjustment: Adjustment,
    composer: *const ?Bounds,
    cutout: bool,
    fade: Fade = .full,
};

fn paintPass(ctx: PaintCtx, b: Bounds, window: *Window, _: *App) void {
    const none = zpui.Corners(f32).all(0);
    // All prepaint finished before paint, so this is the current frame's composer.
    const composer = ctx.composer.* orelse {
        // Unmasked artwork does not wait for the composer's first measurement.
        if (ctx.fade == .none) paintAdjusted(window, ctx.image, b, ctx.adjustment, none, null);
        return;
    };
    if (ctx.cutout or ctx.fade == .none) last_geometry = .{ .hero = b, .composer = composer };
    paintAdjusted(window, ctx.image, b, ctx.adjustment, none, maskFor(b, composer, ctx.cutout, ctx.fade));
}

/// One artwork's hero (`new_thread_background`): fixed crop at the canvas
/// origin, the reveal pass (`cutoutReveal(fade)`) under the masked pass;
/// `none` is one unmasked pass.
pub fn imageLayer(artwork: ?*RenderImage, adjustment: Adjustment, viewport_height: f32, hero_width: f32, composer: *const ?Bounds, dissolve: f32, alpha: f32, fade: Fade) ?zpui.Div {
    const img = artwork orelse return null;
    const d = std.math.clamp(dissolve, 0, 1);
    var root = div().absolute().top(px(0)).left(px(0)).w(px(hero_width)).h(px(height(viewport_height))).overflowHidden()
        .opacity((1 - d) * alpha);
    if (fade == .none) return root.child(zpui.canvas(PaintCtx{ .image = img, .adjustment = adjustment, .composer = composer, .cutout = false, .fade = fade }, paintPass).absolute().inset0());
    for ([_]bool{ false, true }) |cutout| {
        root = root.child(div().absolute().inset0().opacity(if (cutout) 1 else cutoutReveal(fade))
            .child(zpui.canvas(PaintCtx{ .image = img, .adjustment = adjustment, .composer = composer, .cutout = cutout, .fade = fade }, paintPass).absolute().inset0()));
    }
    return root;
}

/// The whole layer (previous fading out under current fading in).
pub fn layer(f: Readiness.Frame, viewport_height: f32, width: f32, composer: *const ?Bounds, is_frost: bool, fade: Fade) zpui.Div {
    const o = opacity(is_frost);
    var root = div().absolute().inset0();
    if (imageLayer(f.previous, f.previous_adjustment, viewport_height, width, composer, 0, (1 - f.mix) * o, fade)) |e| root = root.child(e);
    if (imageLayer(f.current, f.current_adjustment, viewport_height, width, composer, 0, f.mix * o, fade)) |e| root = root.child(e);
    return root;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

fn rect(x: f32, y: f32, w: f32, h: f32) Bounds {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}

test "hero size and opacity match the shell constants" {
    try testing.expectEqual(@as(f32, 1.0), opacity(false));
    try testing.expectEqual(frosted_opacity, opacity(true));
    try testing.expectEqual(@as(f32, 288), height(400));
    try testing.expectApproxEqAbs(@as(f32, 432), height(600), 0.001);
    try testing.expectEqual(@as(f32, 720), height(1000));
    try testing.expectEqual(@as(f32, 760), height(1200));
    try testing.expect(height(848) > 848.0 / 2.0);
}

test "cover framing honours focal point and zoom" {
    const hero = rect(40, 24, 800, 400);
    // Wide source: covers height, overflows width, centered by default.
    const g = fittedGeometry(2000, 500, hero, .{}).?;
    try testing.expectApproxEqAbs(@as(f32, 1600), g.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 400), g.height, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 40 - 400), g.bounds.origin.x, 0.01);
    try testing.expectEqual(@as(f32, 0), g.overflow_y);
    // Left focal shows the left edge; zoom 2 doubles both overflows.
    const left = fittedGeometry(2000, 500, hero, .{ .focalX = 0, .focalY = 0.5, .zoom = 1 }).?;
    try testing.expectApproxEqAbs(@as(f32, 40), left.bounds.origin.x, 0.01);
    const z = fittedGeometry(2000, 500, hero, .{ .zoom = 2 }).?;
    try testing.expectApproxEqAbs(@as(f32, 3200), z.width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 400), z.overflow_y, 0.01);
    try testing.expect(fittedGeometry(0, 10, hero, .{}) == null);
    try testing.expect(fittedGeometry(10, 10, rect(0, 0, 0, 10), .{}) == null);
}

test "pan and zoom adjustments stay normalized and keep the anchor fixed" {
    const hero = rect(0, 0, 800, 400);
    const panned = panAdjustmentSized(2000, 500, hero, .{}, 400, 0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), panned.focalX, 0.001);
    const clamped = panAdjustmentSized(2000, 500, hero, .{}, -10_000, 0);
    try testing.expectEqual(@as(f32, 1), clamped.focalX);
    const anchor: zpui.Point(f32) = .{ .x = 200, .y = 100 };
    const before = fittedGeometry(2000, 500, hero, .{}).?;
    const zoomed = zoomAdjustmentAroundSized(2000, 500, hero, .{}, 2, anchor);
    const after = fittedGeometry(2000, 500, hero, zoomed).?;
    const sx0 = (anchor.x - before.bounds.origin.x) / before.width;
    const sx1 = (anchor.x - after.bounds.origin.x) / after.width;
    try testing.expectApproxEqAbs(sx0, sx1, 0.001);
    try testing.expectEqual(@as(f32, 2), zoomed.zoom);
}

test "the mask clears the composer through the hero bottom with a clamped feather" {
    const hero = rect(0, 0, 1000, 600);
    const composer = rect(200, 300, 600, 120);
    const m = mask(hero, composer, true);
    try testing.expectEqual(@as(f32, 300), m.bounds.size.height);
    try testing.expectEqual(composer_radius, m.radius);
    try testing.expectApproxEqAbs(@as(f32, 280), m.feather, 0.001);
    try testing.expectEqual(@as(f32, 8), m.clearance);
    try testing.expectEqual(@as(f32, 600), m.bottom_fade.?.y);
    const short = mask(rect(0, 0, 1000, 100), composer, true);
    try testing.expectEqual(@as(f32, 120), short.feather);
    const reveal = mask(hero, composer, false);
    try testing.expectEqual(@as(f32, 601), reveal.bounds.origin.y);
    try testing.expectEqual(@as(f32, 0), reveal.radius);
}

test "Full is the Rust mask at every window size (new_thread_background_mask.rs parity)" {
    // `mask_tracks_current_surface_in_window_space_without_rounding`.
    for ([_]f32{ 0.0, 112.25, 224.0 }) |sidebar| {
        for ([_]f32{ 0.0, 360.0 }) |right| {
            const h = rect(sidebar, 40, 1200 - sidebar, 440);
            const c = rect(sidebar + 40.5, 360.25, 900 - sidebar - right, 124);
            const m = maskFor(h, c, true, .full).?;
            try testing.expectEqual(c, m.bounds);
            try testing.expectEqual(@as(f32, 480), m.bottom_fade.?.y);
            try testing.expectEqual(@as(f32, 440), m.bottom_fade.?.feather);
            try testing.expectApproxEqAbs(@as(f32, 440 * 0.52), m.feather, 0.001);
            try testing.expectEqual(@as(f32, 8), m.clearance);
        }
    }
    // `taller_background_stays_cleared_below_the_composer` + the reveal pass.
    const tall = rect(0, 0, 1440, 691.2);
    const c = rect(352, 406, 736, 124);
    const cut = maskFor(tall, c, true, .full).?;
    try testing.expectEqual(c.origin, cut.bounds.origin);
    try testing.expectEqual(@as(f32, 691.2), cut.bounds.origin.y + cut.bounds.size.height);
    try testing.expectEqual(@as(f32, 280), cut.feather);
    const rev = maskFor(tall, c, false, .full).?;
    try testing.expectEqual(cut.bottom_fade, rev.bottom_fade);
    try testing.expect(rev.bounds.origin.y - rev.feather >= 691.2);
    try testing.expectEqual(@as(f32, 0), rev.radius);
    try testing.expectEqual(@as(f32, 0), rev.clearance);
    try testing.expectEqual(@as(f32, 0.5), cutoutReveal(.full));
    try testing.expectEqual(cutout_reveal_opacity, cutoutReveal(.full));
    // `new_thread_main_fade_uses_the_full_height_at_every_window_size`.
    for ([_]f32{ 288.0, 489.6, 691.2, 760.0 }) |hh| {
        for ([_]bool{ false, true }) |cutout| {
            const h = rect(224.25, 40.5, 1000, hh);
            const bf = maskFor(h, c, cutout, .full).?.bottom_fade.?;
            try testing.expectApproxEqAbs(@as(f32, 0), bf.y - bf.feather - h.origin.y, 0.0001);
            try testing.expectEqual(h.origin.y + hh, bf.y);
            // And identical to the untouched Rust-port function.
            try testing.expectEqual(mask(h, c, cutout), maskFor(h, c, cutout, .full).?);
        }
    }
}

test "Subtle keeps the art further down with a small gentle cutout" {
    const c = rect(352, 406, 736, 124);
    for ([_]f32{ 120.0, 288.0, 489.6, 691.2, 760.0 }) |hh| {
        const h = rect(0, 0, 1440, hh);
        const full = maskFor(h, c, true, .full).?;
        const cut = maskFor(h, c, true, .subtle).?;
        const rev = maskFor(h, c, false, .subtle).?;
        // Same cleared region and passes as Full; only the softness changes.
        try testing.expectEqual(full.bounds, cut.bounds);
        try testing.expectEqual(composer_radius, cut.radius);
        try testing.expectEqual(mask(h, c, false).bounds, rev.bounds);
        try testing.expectEqual(cut.bottom_fade, rev.bottom_fade);
        // Short bottom band: full strength through (at least) the top 60%.
        const bf = cut.bottom_fade.?;
        try testing.expectEqual(hh, bf.y);
        try testing.expect(bf.feather <= @max(hh * subtle_fade_ratio, @min(subtle_fade_min, hh)) + 0.001);
        try testing.expect(bf.feather < full.bottom_fade.?.feather or hh <= subtle_fade_min);
        try testing.expect(bf.feather <= subtle_fade_max);
        try testing.expect(bf.feather > 0);
        // Much smaller feather and clearance than Full.
        try testing.expect(cut.feather >= subtle_feather_min and cut.feather <= subtle_feather_max);
        try testing.expect(cut.feather * 2 < full.feather);
        try testing.expectEqual(subtle_clearance, cut.clearance);
    }
    try testing.expectEqual(@as(f32, 220), maskFor(rect(0, 0, 1440, 760), c, true, .subtle).?.bottom_fade.?.feather);
    try testing.expectEqual(@as(f32, 64), maskFor(rect(0, 0, 1440, 760), c, true, .subtle).?.feather);
    try testing.expectApproxEqAbs(@as(f32, 288 * 0.34), maskFor(rect(0, 0, 1440, 288), c, true, .subtle).?.bottom_fade.?.feather, 0.001);
    const r = cutoutReveal(.subtle);
    try testing.expect(r >= 0.8 and r <= 0.85);
}

test "None paints the crop unmasked" {
    const h = rect(0, 0, 1440, 691.2);
    const c = rect(352, 406, 736, 124);
    try testing.expect(maskFor(h, c, true, .none) == null);
    try testing.expect(maskFor(h, c, false, .none) == null);
    try testing.expectEqual(@as(f32, 1), cutoutReveal(.none));
}

test "the Adjust preview scales the runtime mask with the hero" {
    const saved = last_geometry;
    defer last_geometry = saved;
    const runtime = rect(224, 0, 1096, 633.6);
    const c = rect(388, 360, 768, 124);
    last_geometry = .{ .hero = runtime, .composer = c };
    const k: f32 = 0.25;
    const preview = rect(10, 20, 1096 * k, 633.6 * k);
    for ([_]Fade{ .full, .subtle }) |fade| {
        for ([_]bool{ false, true }) |cutout| {
            const want = maskFor(runtime, c, cutout, fade).?;
            const got = previewMask(preview, cutout, fade).?;
            try testing.expectApproxEqAbs(want.feather * k, got.feather, 0.001);
            try testing.expectApproxEqAbs(want.radius * k, got.radius, 0.001);
            try testing.expectApproxEqAbs(want.clearance * k, got.clearance, 0.001);
            try testing.expectApproxEqAbs(want.bottom_fade.?.feather * k, got.bottom_fade.?.feather, 0.001);
            try testing.expectApproxEqAbs(preview.origin.y + preview.size.height, got.bottom_fade.?.y, 0.01);
            // The cutout pass clears the scaled composer; the reveal pass's exclusion sits below the image.
            if (cutout) {
                try testing.expectApproxEqAbs(10 + (388 - 224) * k, got.bounds.origin.x, 0.001);
                try testing.expectApproxEqAbs(20 + 360 * k, got.bounds.origin.y, 0.001);
            } else try testing.expect(got.bounds.origin.y >= preview.origin.y + preview.size.height);
        }
    }
    try testing.expect(previewMask(preview, true, .none) == null);
    const pg = previewGeometry(preview);
    try testing.expectApproxEqAbs(@as(f32, 768 * k), pg.composer.size.width, 0.001);
    // Before the canvas has painted: a centered composer-like rect.
    last_geometry = null;
    const fb = previewGeometry(preview);
    try testing.expect(fb.composer.size.width <= preview.size.width);
    try testing.expect(previewMask(preview, true, .subtle) != null);
}

fn artworkStub() !*RenderImage {
    const gpa = testing.allocator;
    const frames = try gpa.alloc(zpui.image.Frame, 1);
    frames[0] = .{ .width = 1, .height = 1, .pixels = try gpa.alloc(u8, 4) };
    return RenderImage.create(gpa, .{ .frames = frames });
}

test "crossfade holds while loading and finishes each blend before adopting another" {
    const gpa = testing.allocator;
    const first = try artworkStub();
    defer first.release();
    const next = try artworkStub();
    defer next.release();
    const latest = try artworkStub();
    defer latest.release();
    var ready: Readiness = .{};
    defer ready.deinit(null, gpa);
    const ms = std.time.ns_per_ms;
    const now: u64 = 1000 * ms;
    const path = "background.png";
    _ = ready.frame(null, gpa, first, path, .{}, true, true, now);
    const loading = ready.frame(null, gpa, null, path, .{}, true, false, now);
    try testing.expect(loading.current.? == first);
    try testing.expect(!loading.active);
    const start = ready.frame(null, gpa, next, path, .{}, true, false, now);
    try testing.expectEqual(@as(f32, 0), start.mix);
    try testing.expect(start.previous.? == first);
    const half = ready.frame(null, gpa, latest, path, .{}, true, false, now + 90 * ms);
    try testing.expectApproxEqAbs(@as(f32, 0.875), half.mix, 0.001);
    try testing.expect(half.current.? == next);
    const done = ready.frame(null, gpa, latest, path, .{}, true, false, now + 1000 * ms);
    try testing.expect(done.previous.? == next and done.current.? == latest);
    try testing.expectEqual(@as(f32, 0), done.mix);
    const snapped = ready.frame(null, gpa, latest, path, .{}, true, true, now + 1000 * ms);
    try testing.expect(!snapped.active and snapped.previous == null and snapped.mix == 1);
    const removed = ready.frame(null, gpa, null, null, .{}, false, true, now + 1000 * ms);
    try testing.expect(removed.current == null and removed.previous == null);
}

test "a replacement keeps the departing image's crop" {
    const gpa = testing.allocator;
    const first = try artworkStub();
    defer first.release();
    const next = try artworkStub();
    defer next.release();
    const cropped: Adjustment = .{ .focalX = 0.2, .focalY = 0.8, .zoom = 2 };
    var ready: Readiness = .{};
    defer ready.deinit(null, gpa);
    _ = ready.frame(null, gpa, first, "first.png", cropped, true, true, 0);
    const loading = ready.frame(null, gpa, null, "next.png", .{}, true, false, 0);
    try testing.expectEqual(cropped, loading.current_adjustment);
    const start = ready.frame(null, gpa, next, "next.png", .{}, true, false, 0);
    try testing.expectEqual(cropped, start.previous_adjustment);
    try testing.expectEqual(Adjustment{}, start.current_adjustment);
}
