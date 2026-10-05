//! Appearance → New thread background → Adjust (zeron `appearance.rs`
//! `BackgroundAdjustmentDialog`, `render_background_adjustment_dialog`):
//! a scaled copy of the runtime hero (same aspect as the new-thread canvas)
//! that pans on drag / arrow keys and zooms on scroll, the slider, −/+ and
//! +/-/= keys around the pointer (or the center). Apply persists only the
//! draft, and only for the image the dialog was opened on; Cancel, Escape,
//! a click outside and Reset never touch the saved settings.
//!
//! ```zig
//! view.openBackgroundAdjustment(cx);                 // "Adjust"
//! root.child(background_adjust.render(view, window, cx)) // while open
//! ```

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const prefs_mod = @import("../shell/prefs.zig");
const background = @import("../background/root.zig");
const store = @import("store.zig");
const dialog = @import("../components/dialog.zig");
const w = @import("widgets.zig");
const view_mod = @import("view.zig");

const SettingsView = view_mod.SettingsView;
const Context = zpui.Context;
const Window = zpui.Window;
const Bounds = zpui.Bounds(f32);
const Point = zpui.Point(f32);
const Adjustment = model.settings.NewThreadBackgroundAdjustment;
const RenderImage = zpui.image.RenderImage;
const div = zpui.div;
const px = zpui.px;
const rems = ui.rems;
const sb = zpui.StyleBuilder.init;
const Theme = ui.Theme;

pub const zoom_step: f32 = 0.1;

pub const Dialog = struct {
    /// The image the draft belongs to (owned).
    path: []u8,
    draft: Adjustment,
    /// The ready effect raster's size (null while preparing): the draft only
    /// moves once the preview can show it.
    source: ?[2]f32 = null,
    preview_bounds: ?Bounds = null,
    zoom_bounds: ?Bounds = null,
    drag: ?struct { start: Point, initial: Adjustment } = null,
    zoom_drag: bool = false,

    pub fn deinit(self: *Dialog, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
    }
};

/// `background_zoom_fraction`.
pub fn zoomFraction(zoom: f32) f32 {
    return std.math.clamp((zoom - Adjustment.min_zoom) / (Adjustment.max_zoom - Adjustment.min_zoom), 0, 1);
}

/// `background_zoom_at_x`: the slider track is inset 7px on both sides.
pub fn zoomAtX(b: Bounds, x: f32) f32 {
    const fraction = std.math.clamp((x - b.origin.x - 7) / @max(b.size.width - 14, 1), 0, 1);
    return Adjustment.min_zoom + fraction * (Adjustment.max_zoom - Adjustment.min_zoom);
}

/// `background_preview_size`: the hero (canvas width × hero height) scaled
/// into at most 556 × 258.
pub fn previewSize(viewport: zpui.Size(f32), sidebar_width: f32, sidebar_collapsed: bool) zpui.Size(f32) {
    const hero_w = @max(viewport.width - (if (sidebar_collapsed) 0 else sidebar_width), 1);
    const hero_h = @max(background.hero.height(viewport.height), 1);
    const max_w = std.math.clamp(viewport.width - 84, 1, 556);
    const scale = @min(max_w / hero_w, 258 / hero_h);
    return .{ .width = hero_w * scale, .height = hero_h * scale };
}

// ---- state transitions (SettingsView methods forward here) ------------------------

pub fn open(v: *SettingsView, cx: *Context(SettingsView)) void {
    const bg = store.current(cx).newThreadComposerBackground orelse return;
    close(v, cx);
    v.adjust = .{ .path = v.gpa.dupe(u8, bg.path) catch return, .draft = bg.adjustment.normalized() };
    cx.notify();
}

pub fn close(v: *SettingsView, cx: *Context(SettingsView)) void {
    if (v.adjust) |*d| d.deinit(v.gpa);
    v.adjust = null;
    cx.notify();
}

/// Apply: only a ready preview of the still-current image persists its draft.
pub fn apply(v: *SettingsView, cx: *Context(SettingsView)) void {
    const d = v.adjust orelse return;
    const bg = store.current(cx).newThreadComposerBackground orelse return;
    if (d.source == null or !std.mem.eql(u8, bg.path, d.path)) return;
    background.install.setAdjustment(cx.app, d.draft);
    close(v, cx);
}

pub fn reset(v: *SettingsView, cx: *Context(SettingsView)) void {
    if (v.adjust == null) return;
    v.adjust.?.draft = .{};
    v.adjust.?.drag = null;
    cx.notify();
}

/// `zoom_background_around` (anchor null = the preview's center).
pub fn zoomAround(v: *SettingsView, zoom_in: f32, anchor: ?Point, cx: *Context(SettingsView)) void {
    const d = if (v.adjust) |*x| x else return;
    const src = d.source orelse return;
    const zoom = std.math.clamp(zoom_in, Adjustment.min_zoom, Adjustment.max_zoom);
    const next: Adjustment = if (d.preview_bounds) |b|
        background.hero.zoomAdjustmentAroundSized(src[0], src[1], b, d.draft, zoom, anchor orelse Point{ .x = b.origin.x + b.size.width / 2, .y = b.origin.y + b.size.height / 2 })
    else blk: {
        var n = d.draft;
        n.zoom = zoom;
        break :blk n.normalized();
    };
    if (!std.meta.eql(next, d.draft)) {
        d.draft = next;
        d.drag = null;
        cx.notify();
    }
}

pub fn setZoom(v: *SettingsView, zoom: f32, cx: *Context(SettingsView)) void {
    zoomAround(v, zoom, null, cx);
}

/// `pan_background`: a content delta in preview pixels.
pub fn pan(v: *SettingsView, dx: f32, dy: f32, cx: *Context(SettingsView)) void {
    const d = if (v.adjust) |*x| x else return;
    const src = d.source orelse return;
    const b = d.preview_bounds orelse return;
    const next = background.hero.panAdjustmentSized(src[0], src[1], b, d.draft, dx, dy);
    if (!std.meta.eql(next, d.draft)) {
        d.draft = next;
        cx.notify();
    }
}

// ---- listeners ----------------------------------------------------------------------

fn onPreviewDown(v: *SettingsView, ev: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(SettingsView)) void {
    const d = if (v.adjust) |*x| x else return;
    if (d.source == null) return;
    d.drag = .{ .start = ev.position, .initial = d.draft };
    cx.stopPropagation();
    cx.notify();
}

/// The native slider (macOS) moved.
fn onZoomNative(v: *SettingsView, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(SettingsView)) void {
    setZoom(v, @floatCast(ev.value), cx);
}

fn onZoomDown(v: *SettingsView, ev: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(SettingsView)) void {
    const d = if (v.adjust) |*x| x else return;
    d.zoom_drag = true;
    if (d.zoom_bounds) |b| setZoom(v, zoomAtX(b, ev.position.x), cx);
    cx.stopPropagation();
}

fn onMove(v: *SettingsView, ev: *const zpui.input.MouseMoveEvent, _: *Window, cx: *Context(SettingsView)) void {
    const d = if (v.adjust) |*x| x else return;
    if (d.zoom_drag) {
        if (d.zoom_bounds) |b| setZoom(v, zoomAtX(b, ev.position.x), cx);
        return;
    }
    const drag = d.drag orelse return;
    d.draft = drag.initial;
    pan(v, ev.position.x - drag.start.x, ev.position.y - drag.start.y, cx);
    cx.notify();
}

fn onUp(v: *SettingsView, _: *const zpui.input.MouseUpEvent, _: *Window, cx: *Context(SettingsView)) void {
    const d = if (v.adjust) |*x| x else return;
    if (d.drag != null or d.zoom_drag) cx.notify();
    d.drag = null;
    d.zoom_drag = false;
}

fn onWheel(v: *SettingsView, ev: *const zpui.input.ScrollWheelEvent, _: *Window, cx: *Context(SettingsView)) void {
    const d = v.adjust orelse return;
    const delta: f32 = switch (ev.delta) {
        .pixels => |p| p.y,
        .lines => |l| l.y * 40,
    };
    const zoom = d.draft.zoom * @exp(std.math.clamp(delta * 0.0025, -2, 2));
    zoomAround(v, zoom, ev.position, cx);
    cx.stopPropagation();
}

fn onScrim(v: *SettingsView, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(SettingsView)) void {
    close(v, cx);
}

fn onCancel(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    close(v, cx);
}

fn onApply(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    apply(v, cx);
}

fn onReset(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    reset(v, cx);
}

fn onZoomOut(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    const d = v.adjust orelse return;
    setZoom(v, d.draft.zoom - zoom_step, cx);
}

fn onZoomIn(v: *SettingsView, _: *const zpui.ClickEvent, _: *Window, cx: *Context(SettingsView)) void {
    const d = v.adjust orelse return;
    setZoom(v, d.draft.zoom + zoom_step, cx);
}

/// The card's keys (`on_key_down`); returns whether the key was consumed.
pub fn onKey(v: *SettingsView, ks: zpui.input.Keystroke, cx: *Context(SettingsView)) bool {
    const d = v.adjust orelse return false;
    const key = ks.key;
    const step: f32 = if (ks.modifiers.shift) 24 else 8;
    const eq = std.mem.eql;
    if (eq(u8, key, "escape")) {
        close(v, cx);
    } else if (eq(u8, key, "enter") and (ks.modifiers.platform or ks.modifiers.control)) {
        apply(v, cx);
    } else if (eq(u8, key, "left")) {
        pan(v, step, 0, cx);
    } else if (eq(u8, key, "right")) {
        pan(v, -step, 0, cx);
    } else if (eq(u8, key, "up")) {
        pan(v, 0, step, cx);
    } else if (eq(u8, key, "down")) {
        pan(v, 0, -step, cx);
    } else if (eq(u8, key, "+") or eq(u8, key, "=")) {
        setZoom(v, d.draft.zoom + zoom_step, cx);
    } else if (eq(u8, key, "-")) {
        setZoom(v, d.draft.zoom - zoom_step, cx);
    } else if (eq(u8, key, "home")) {
        setZoom(v, Adjustment.min_zoom, cx);
    } else if (eq(u8, key, "end")) {
        setZoom(v, Adjustment.max_zoom, cx);
    } else return false;
    return true;
}

// ---- rendering ----------------------------------------------------------------------

fn measurePreview(v: *SettingsView, b: Bounds, _: *Window, _: *zpui.App) void {
    if (v.adjust) |*d| d.preview_bounds = b;
}

fn measureZoom(v: *SettingsView, b: Bounds, _: *Window, _: *zpui.App) void {
    if (v.adjust) |*d| d.zoom_bounds = b;
}

const PaintCtx = struct { image: *RenderImage, draft: Adjustment };

fn paintPreview(ctx: PaintCtx, b: Bounds, window: *Window, _: *zpui.App) void {
    background.hero.paintAdjusted(window, ctx.image, b, ctx.draft, zpui.Corners(f32).all(11), null);
}

fn noPaint(_: *SettingsView, _: Bounds, _: *Window, _: *zpui.App) void {}

fn gridLine(vertical: bool, at: f32) zpui.Div {
    const line = div().absolute().bg(zpui.color.white.alpha(0.22));
    return if (vertical) line.left(zpui.relative(at)).top(px(0)).bottom(px(0)).w(px(1)) else line.top(zpui.relative(at)).left(px(0)).right(px(0)).h(px(1));
}

fn compactAction(t: *const Theme, label: []const u8, id: []const u8) zpui.StatefulDiv {
    return w.textAction(t, .outlined, label).id(id).role(.button).ariaLabel(label);
}

pub fn render(v: *SettingsView, window: *Window, cx: *Context(SettingsView)) ?zpui.AnyElement {
    const d = if (v.adjust) |*x| x else return null;
    const t_val = ui.theme.get(cx).forPopup();
    const t = &t_val;
    const app = cx.app;
    const s = store.current(cx);
    const same_image = if (s.newThreadComposerBackground) |bg| std.mem.eql(u8, bg.path, d.path) else false;
    const available = same_image and background.install.available(app, s);
    // A moving background previews its animation (`player.artwork`).
    const image: ?*RenderImage = if (available)
        background.player.artwork(app, background.install.ioOf(app), s.newThreadComposerBackground.?, s.newThreadBackgroundEffect, t.appearance == .light, window, cx.entityId()).image
    else
        null;
    d.source = if (image) |img| blk: {
        const sz = img.size(0);
        break :blk .{ @floatFromInt(sz.width), @floatFromInt(sz.height) };
    } else null;
    const ready = image != null;
    const viewport = window.viewportSize();
    const prefs = prefs_mod.get(cx);
    const size = previewSize(viewport, prefs.sidebar_width, prefs.sidebar_collapsed);
    const dragging = d.drag != null;

    var preview = div().id("new-thread-background-adjustment-preview").relative()
        .w(px(size.width + 2)).h(px(size.height + 2)).overflowHidden().rounded(px(12))
        .border1().borderColor(t.hairline(0.12)).bg(t.bg)
        .onScrollWheel(cx.listener(onWheel))
        .onMouseDown(.left, cx.listener(onPreviewDown))
        .child(zpui.canvas(v, noPaint).withPrepaint(*SettingsView, measurePreview).w(px(size.width)).h(px(size.height)).absolute().top(px(0)).left(px(0)));
    if (ready) preview = preview.cursor(if (dragging) .closed_hand else .open_hand);
    if (image) |img| preview = preview.child(zpui.canvas(PaintCtx{ .image = img, .draft = d.draft }, paintPreview).w(px(size.width)).h(px(size.height)));
    if (!ready) preview = preview.child(div().absolute().inset0().flex().itemsCenter().justifyCenter()
        .textSize(rems(11.5)).textColor(t.text_muted)
        .child(if (!same_image) "Background changed. Close and adjust the new image." else if (!available) "Image unavailable. Choose a replacement or remove it." else "Preparing preview…"));
    if (dragging) preview = preview.child(gridLine(true, 1.0 / 3.0)).child(gridLine(true, 2.0 / 3.0))
        .child(gridLine(false, 1.0 / 3.0)).child(gridLine(false, 2.0 / 3.0));
    if (!ready) window.requestAnimationFrame();

    const fraction = zoomFraction(d.draft.zoom);
    const slider = div().id("new-thread-background-adjustment-zoom")
        .role(.slider).ariaLabel("Background zoom").ariaNumericValue(d.draft.zoom * 100)
        .ariaMinNumericValue(Adjustment.min_zoom * 100).ariaMaxNumericValue(Adjustment.max_zoom * 100)
        .ariaNumericValueStep(zoom_step * 100).ariaValue(zpui.fmt("{d:.0}%", .{d.draft.zoom * 100})).relative().w(px(168)).h(px(28)).cursorPointer()
        .onMouseDown(.left, cx.listener(onZoomDown))
        .child(zpui.canvas(v, noPaint).withPrepaint(*SettingsView, measureZoom).absolute().inset0())
        .child(div().absolute().left(px(7)).right(px(7)).top(px(12)).h(px(4)).roundedFull().bg(t.border)
        .child(div().hFull().w(zpui.relative(fraction)).roundedFull().bg(t.accent))
        .child(div().absolute().left(zpui.relative(fraction)).ml(px(-7)).top(px(-5)).size(px(14)).roundedFull().bg(t.accent)));
    const controls = div().mt(px(14)).flex().itemsCenter().justifyBetween().gap(px(12))
        .child(compactAction(t, "Reset", "new-thread-background-adjustment-reset").onClick(cx.listener(onReset)))
        .child(div().flex().itemsCenter().gap(px(6))
        .child(compactAction(t, "−", "new-thread-background-adjustment-zoom-out").ariaLabel("Zoom out").onClick(cx.listener(onZoomOut)))
        .child(zpui.nativeSlider("new-thread-background-adjustment-zoom-native", .{
        .value = d.draft.zoom,
        .min = Adjustment.min_zoom,
        .max = Adjustment.max_zoom,
        .enabled = ready,
        .label = "Background zoom",
        .width = px(168),
    }, cx.listener(onZoomNative), slider))
        .child(div().w(px(52)).textCenter().textSize(rems(11.5)).textColor(t.text_muted).child(zpui.fmt("{d:.0}%", .{d.draft.zoom * 100})))
        .child(compactAction(t, "+", "new-thread-background-adjustment-zoom-in").ariaLabel("Zoom in").onClick(cx.listener(onZoomIn))));

    var apply_btn = w.textAction(t, .solid, "Apply").id("new-thread-background-adjustment-apply").role(.button).ariaLabel("Apply").h(px(34)).px(px(14)).py(px(0)).flex().itemsCenter();
    apply_btn = if (ready) apply_btn.onClick(cx.listener(onApply)) else apply_btn.opacity(0.45);
    const footer = div().mt(px(18)).pt(px(12)).borderT1().borderColor(t.border).flex().itemsCenter().justifyEnd().gap(px(8))
        .child(compactAction(t, "Cancel", "new-thread-background-adjustment-cancel").h(px(34)).px(px(13)).onClick(cx.listener(onCancel)))
        .child(apply_btn);
    const header = div().flex().itemsStart().gap(px(16))
        .child(div().flex1().minW0()
        .child(dialog.title(t, "Adjust background"))
        .child(dialog.body(t, "Drag to reposition. Scroll or pinch to zoom.").mt(px(4))))
        .child(div().id("new-thread-background-adjustment-close").role(.button).ariaLabel("Close background adjustment").size(px(28)).rounded(px(7)).border1().borderColor(t.border)
        .bg(t.surface_raised.opacity(0.28)).flex().itemsCenter().justifyCenter().cursorPointer()
        .hover(sb.bg(t.surface_raised_hover)).onClick(cx.listener(onCancel))
        .child(ui.icon.of(.close, 12, t.text_muted)));

    const card = dialog.card(t).id("new-thread-background-adjustment-card")
        .w(px(std.math.clamp(viewport.width - 40, 1, 600))).p(px(20))
        .onMouseDownOut(cx.listener(onScrim))
        .child(header)
        .child(div().h(px(16)))
        .child(div().wFull().h(px(260)).flex().itemsCenter().justifyCenter().child(preview))
        .child(controls)
        .child(footer);
    return zpui.intoAnyElement(zpui.deferred(zpui.anchored().position(.{ .x = 0, .y = 0 }).child(
        div().id("new-thread-background-adjustment-dialog").occlude().w(px(viewport.width)).h(px(viewport.height))
            .bg(zpui.color.black.alpha(0.35)).flex().itemsCenter().justifyCenter()
            .onMouseMove(cx.listener(onMove))
            .onMouseUp(.left, cx.listener(onUp))
            .child(ui.anim.dialogIn("background-adjust-in", div().child(ui.effects.frosted(16, zt.layout.menu_blur, card)))),
    )).withPriority(3));
}

// ---- tests ------------------------------------------------------------------------

const testing = std.testing;

test "zoom slider maps its inset track to the zoom range and clamps" {
    const b: Bounds = .{ .origin = .{ .x = 100, .y = 0 }, .size = .{ .width = 168, .height = 28 } };
    try testing.expectEqual(Adjustment.min_zoom, zoomAtX(b, 0));
    try testing.expectEqual(Adjustment.max_zoom, zoomAtX(b, 1000));
    try testing.expectApproxEqAbs(@as(f32, 2.5), zoomAtX(b, 100 + 7 + 77), 0.001);
    try testing.expectEqual(@as(f32, 0), zoomFraction(0.5));
    try testing.expectEqual(@as(f32, 1), zoomFraction(9));
}

test "the preview matches the runtime hero's aspect ratio" {
    const vp: zpui.Size(f32) = .{ .width = 1400, .height = 900 };
    const sz = previewSize(vp, 260, false);
    const hero_ratio = (1400.0 - 260.0) / background.hero.height(900);
    try testing.expectApproxEqAbs(hero_ratio, sz.width / sz.height, 0.01);
    try testing.expect(sz.width <= 556.01 and sz.height <= 258.01);
    const collapsed = previewSize(vp, 260, true);
    try testing.expectApproxEqAbs(1400.0 / background.hero.height(900), collapsed.width / collapsed.height, 0.01);
}
