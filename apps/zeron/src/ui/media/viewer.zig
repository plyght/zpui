//! The shared image lightbox (zeron `image_viewer.rs` + `attachments.rs`
//! `lightbox_with_size`): a full-window dim scrim with the image centered in a
//! 90% × 85% viewport and its name below. Ctrl/⌘-wheel zooms about the cursor
//! (wheel up zooms in, `exp(dy * 0.0025)` per pixel), the wheel pans, a left
//! drag (≥ 4px) pans, a plain click anywhere closes, Escape closes. The image
//! starts fitted (never upscaled) and stays fitted across window resizes until
//! the user zooms; pans are clamped so the image never leaves the viewport
//! when it is larger than it.
//!
//! ```zig
//! self.lightbox = try cx.newWith(Lightbox, Lightbox.init, .{ .{ .image = r, .name = name }, window });
//! try self.subs.add(cx.gpa(), try cx.subscribe(self.lightbox.?, onLightboxClosed));
//! // render: root.child(self.lightbox)   (it paints above everything)
//! ```

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const RenderImage = zpui.RenderImage;
const Hsla = zpui.Hsla;
const div = zpui.div;
const px = zpui.px;
const input = zpui.input;

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,

    fn eql(a: Point, b: Point) bool {
        return a.x == b.x and a.y == b.y;
    }
};

pub const Size = struct { width: f32 = 1, height: f32 = 1 };

/// `image_viewer.rs` `Geometry`.
pub const Geometry = struct {
    natural: Size = .{},
    viewport: Size = .{},
    scale: f32 = 1,
    pan: Point = .{},
    fitted: bool = true,

    pub fn fitScale(g: Geometry) f32 {
        return @min(@min(g.viewport.width / g.natural.width, g.viewport.height / g.natural.height), 1.0);
    }

    pub fn resize(g: *Geometry, natural: Size, viewport: Size) void {
        for ([_]f32{ natural.width, natural.height, viewport.width, viewport.height }) |v| {
            if (!std.math.isFinite(v) or v <= 0) return;
        }
        g.natural = natural;
        g.viewport = viewport;
        if (g.fitted) g.fit() else g.clampPan();
    }

    pub fn fit(g: *Geometry) void {
        g.scale = g.fitScale();
        g.pan = .{};
        g.fitted = true;
    }

    pub fn clampPan(g: *Geometry) void {
        const lx = @max((g.natural.width * g.scale - g.viewport.width) / 2.0, 0);
        const ly = @max((g.natural.height * g.scale - g.viewport.height) / 2.0, 0);
        g.pan.x = std.math.clamp(g.pan.x, -lx, lx);
        g.pan.y = std.math.clamp(g.pan.y, -ly, ly);
    }

    pub fn zoom(g: *Geometry, scale_in: f32, anchor_in: Point) void {
        if (!std.math.isFinite(scale_in) or scale_in <= 0 or !std.math.isFinite(anchor_in.x) or !std.math.isFinite(anchor_in.y)) return;
        // Bound layout coordinates even for SVGs with enormous logical dimensions.
        const maximum = @max(@min(131072.0 / @max(g.natural.width, g.natural.height), 32.0), g.fitScale());
        const scale = std.math.clamp(scale_in, @min(g.fitScale(), 0.01), maximum);
        const ratio = scale / g.scale;
        const ax = anchor_in.x - g.viewport.width / 2.0;
        const ay = anchor_in.y - g.viewport.height / 2.0;
        g.pan = .{ .x = ax - (ax - g.pan.x) * ratio, .y = ay - (ay - g.pan.y) * ratio };
        g.scale = scale;
        g.fitted = false;
        g.clampPan();
    }

    pub fn panBy(g: *Geometry, delta: Point) bool {
        if (!std.math.isFinite(delta.x) or !std.math.isFinite(delta.y)) return false;
        const before = g.pan;
        g.pan = .{ .x = g.pan.x + delta.x, .y = g.pan.y + delta.y };
        g.clampPan();
        return !g.pan.eql(before);
    }

    pub fn imageOrigin(g: Geometry) Point {
        return .{
            .x = (g.viewport.width - g.natural.width * g.scale) / 2.0 + g.pan.x,
            .y = (g.viewport.height - g.natural.height * g.scale) / 2.0 + g.pan.y,
        };
    }
};

fn scrollPixels(delta: input.ScrollDelta) Point {
    return switch (delta) {
        .pixels => |p| .{ .x = p.x, .y = p.y },
        .lines => |p| .{ .x = p.x * 40.0, .y = p.y * 40.0 },
    };
}

/// `ViewState`: geometry plus pointer state.
pub const ViewState = struct {
    geometry: Geometry = .{},
    /// Viewport origin in window coordinates (last paint).
    origin: Point = .{},
    drag: ?struct { start: Point, pan: Point } = null,
    dragged: bool = false,

    pub fn local(s: *const ViewState, position: zpui.Point(f32)) Point {
        return .{ .x = position.x - s.origin.x, .y = position.y - s.origin.y };
    }

    pub fn wheel(s: *ViewState, ev: *const input.ScrollWheelEvent) bool {
        const delta = scrollPixels(ev.delta);
        if (ev.modifiers.control or ev.modifiers.platform) {
            const scale = s.geometry.scale * @exp(std.math.clamp(delta.y * 0.0025, -2.0, 2.0));
            s.geometry.zoom(scale, s.local(ev.position));
            return true;
        }
        return s.geometry.panBy(delta);
    }

    pub fn pointerDown(s: *ViewState, position: zpui.Point(f32)) void {
        s.dragged = false;
        s.drag = .{ .start = s.local(position), .pan = s.geometry.pan };
    }

    pub fn pointerMove(s: *ViewState, ev: *const input.MouseMoveEvent) bool {
        if (ev.pressed_button != .left) {
            s.drag = null;
            return false;
        }
        const d = s.drag orelse return false;
        const l = s.local(ev.position);
        const delta: Point = .{ .x = l.x - d.start.x, .y = l.y - d.start.y };
        if (std.math.hypot(delta.x, delta.y) >= 4.0) s.dragged = true;
        if (!s.dragged) return false;
        s.geometry.pan = d.pan;
        _ = s.geometry.panBy(delta);
        return true;
    }
};

/// The lightbox closed (Escape or a click that was not a drag).
pub const Closed = struct {};

pub const Options = struct {
    /// Retained by the lightbox.
    image: *RenderImage,
    name: []const u8 = "",
    /// Logical size the image is framed at (defaults to its render size).
    natural: ?Size = null,
    /// Fill behind an image drawn on a transparent canvas (diagrams).
    plate: ?Hsla = null,
    /// Release callback for `image` (zeron drops atlas tiles on release).
    release: ?*const fn (app: *App, image: *RenderImage) void = null,
    /// The zeron theme's appearance (scrim and caption inks).
    appearance: zt.Appearance = .dark,
};

pub const Lightbox = struct {
    gpa: std.mem.Allocator,
    image: *RenderImage,
    name: []u8,
    natural: Size,
    plate: ?Hsla,
    release_fn: ?*const fn (app: *App, image: *RenderImage) void,
    appearance: zt.Appearance,
    state: ViewState = .{},
    focus: zpui.FocusHandle,

    pub const Events = .{Closed};

    pub fn init(opts: Options, window: *Window, cx: *Context(Lightbox)) !Lightbox {
        const rs = opts.image.renderSize(0);
        const focus = cx.focusHandle();
        window.focus(focus);
        return .{
            .gpa = cx.gpa(),
            .image = opts.image.retain(),
            .name = try cx.gpa().dupe(u8, opts.name),
            .natural = opts.natural orelse .{ .width = @max(rs.width, 1), .height = @max(rs.height, 1) },
            .plate = opts.plate,
            .release_fn = opts.release,
            .appearance = opts.appearance,
            .focus = focus,
        };
    }

    pub fn deinit(self: *Lightbox, app: *App) void {
        if (self.release_fn) |f| f(app, self.image) else self.image.release();
        self.gpa.free(self.name);
        self.focus.release(app);
    }

    fn close(_: *Lightbox, cx: *Context(Lightbox)) void {
        cx.emit(Closed{});
    }

    fn onKey(self: *Lightbox, ev: *const input.KeyDownEvent, _: *Window, cx: *Context(Lightbox)) void {
        if (std.mem.eql(u8, ev.keystroke.key, "escape")) {
            cx.stopPropagation();
            self.close(cx);
        }
    }

    fn onScrimDown(self: *Lightbox, ev: *const input.MouseDownEvent, _: *Window, _: *Context(Lightbox)) void {
        if (ev.button == .left) {
            self.state.drag = null;
            self.state.dragged = false;
        }
    }

    fn onScrimClick(self: *Lightbox, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Lightbox)) void {
        cx.stopPropagation();
        if (!self.state.dragged) self.close(cx);
    }

    fn onWheel(self: *Lightbox, ev: *const input.ScrollWheelEvent, window: *Window, cx: *Context(Lightbox)) void {
        if (self.state.wheel(ev)) {
            cx.stopPropagation();
            window.preventDefault();
            cx.notify();
        }
    }

    fn onScrimWheel(_: *Lightbox, _: *const input.ScrollWheelEvent, _: *Window, cx: *Context(Lightbox)) void {
        cx.stopPropagation();
    }

    fn onViewportDown(self: *Lightbox, ev: *const input.MouseDownEvent, window: *Window, _: *Context(Lightbox)) void {
        self.state.pointerDown(ev.position);
        window.preventDefault();
    }

    fn onViewportUp(self: *Lightbox, _: *const input.MouseUpEvent, _: *Window, _: *Context(Lightbox)) void {
        self.state.drag = null;
    }

    const Measure = struct { id: zpui.EntityId };

    /// Records the viewport origin and keeps a drag going beyond the viewport.
    fn paintMeasure(m: Measure, bounds: zpui.Bounds(f32), window: *Window, app: *App) void {
        const weak: zpui.WeakEntity(Lightbox) = .{ .id = m.id };
        const e = weak.upgrade(app) orelse return;
        defer e.release(app);
        {
            var l = e.lease(app);
            defer l.end();
            l.value.state.origin = .{ .x = bounds.origin.x, .y = bounds.origin.y };
        }
        window.onMouseEvent(input.MouseMoveEvent, m, struct {
            fn f(c: *Measure, ev: *const input.MouseMoveEvent, phase: zpui.DispatchPhase, _: *Window, a: *App) void {
                if (phase != .bubble) return;
                const w2: zpui.WeakEntity(Lightbox) = .{ .id = c.id };
                const ent = w2.upgrade(a) orelse return;
                defer ent.release(a);
                var l = ent.lease(a);
                defer l.end();
                if (l.value.state.pointerMove(ev)) {
                    a.propagate_event = false;
                    l.cx.notify();
                }
            }
        }.f);
        window.onMouseEvent(input.MouseUpEvent, m, struct {
            fn f(c: *Measure, ev: *const input.MouseUpEvent, phase: zpui.DispatchPhase, _: *Window, a: *App) void {
                if (phase != .bubble or ev.button != .left) return;
                const w2: zpui.WeakEntity(Lightbox) = .{ .id = c.id };
                const ent = w2.upgrade(a) orelse return;
                defer ent.release(a);
                var l = ent.lease(a);
                defer l.end();
                l.value.state.drag = null;
            }
        }.f);
    }

    pub fn render(self: *Lightbox, window: *Window, cx: *Context(Lightbox)) zpui.AnyElement {
        const vp = window.viewportSize();
        const appearance = self.appearance;
        const max_w = vp.width * 0.9;
        const max_h = vp.height * 0.85;
        self.state.geometry.resize(self.natural, .{ .width = max_w, .height = max_h });
        const g = self.state.geometry;
        const origin = g.imageOrigin();
        const w = self.natural.width * g.scale;
        const h = self.natural.height * g.scale;

        var viewport = div().id("image-viewport").flex1().minW0().minH0().wFull().relative().overflowHidden()
            .onScrollWheel(cx.listener(Lightbox.onWheel))
            .onMouseDown(.left, cx.listener(Lightbox.onViewportDown))
            .onMouseUp(.left, cx.listener(Lightbox.onViewportUp));
        if (self.plate) |plate| viewport = viewport.child(div().absolute().left(px(origin.x)).top(px(origin.y)).w(px(w)).h(px(h)).rounded(px(10)).bg(plate));
        viewport = viewport
            .child(zpui.img(self.image).absolute().left(px(origin.x)).top(px(origin.y)).w(px(w)).h(px(h)).objectFit(.contain))
            .child(zpui.canvas(Measure{ .id = cx.entityId() }, paintMeasure).absolute().inset0());

        const content = div().w(px(max_w)).h(px(max_h)).flex().flexCol().child(viewport);
        const scrim = div().id("attachment-lightbox").occlude().trackFocus(self.focus)
            .w(px(vp.width)).h(px(vp.height)).bg(zt.theme.scrimFor(appearance, 0.7))
            .flex().flexCol().itemsCenter().justifyCenter().gap(px(12))
            .onKeyDown(cx.listener(Lightbox.onKey))
            .captureAnyMouseDown(cx.listener(Lightbox.onScrimDown))
            .onClick(cx.listener(Lightbox.onScrimClick))
            .onScrollWheel(cx.listener(Lightbox.onScrimWheel))
            .child(content)
            .child(div().maxW(px(max_w)).overflowHidden().textSize(px(11 * window.remSize() / 16.0)).textColor(zt.theme.inkFor(appearance, 0.45)).child(self.name));
        return zpui.intoAnyElement(zpui.deferred(zpui.anchored().position(.{ .x = 0, .y = 0 }).child(scrim)).withPriority(3));
    }
};

// ---------------------------------------------------------------------------
// Tests (image_viewer.rs)
// ---------------------------------------------------------------------------

const testing = std.testing;

fn geometry() Geometry {
    var g: Geometry = .{};
    g.resize(.{ .width = 1000, .height = 500 }, .{ .width = 500, .height = 300 });
    return g;
}

test "fit preserves aspect ratio and never upscales" {
    var g = geometry();
    try testing.expectEqual(@as(f32, 0.5), g.scale);
    try testing.expect(g.imageOrigin().eql(.{ .x = 0, .y = 25 }));
    g.resize(.{ .width = 100, .height = 50 }, .{ .width = 500, .height = 300 });
    try testing.expectEqual(@as(f32, 1.0), g.scale);
    try testing.expect(g.imageOrigin().eql(.{ .x = 200, .y = 125 }));
}

test "zoom keeps the cursor over the same image point" {
    var g = geometry();
    const anchor: Point = .{ .x = 100, .y = 150 };
    const o1 = g.imageOrigin();
    const bx = (anchor.x - o1.x) / g.scale;
    const by = (anchor.y - o1.y) / g.scale;
    g.zoom(2.0, anchor);
    const o2 = g.imageOrigin();
    try testing.expectApproxEqAbs(bx, (anchor.x - o2.x) / g.scale, 0.001);
    try testing.expectApproxEqAbs(by, (anchor.y - o2.y) / g.scale, 0.001);
}

test "pan, zoom and resize stay bounded" {
    var g = geometry();
    g.zoom(1e9, .{ .x = 250, .y = 150 });
    try testing.expectEqual(@as(f32, 32.0), g.scale);
    _ = g.panBy(.{ .x = 1e9, .y = -1e9 });
    try testing.expect(g.pan.eql(.{ .x = 15750, .y = -7850 }));
    g.zoom(1e-9, .{ .x = 250, .y = 150 });
    try testing.expectEqual(@as(f32, 0.01), g.scale);
    try testing.expect(g.pan.eql(.{}));
    g.zoom(std.math.nan(f32), .{});
    try testing.expectEqual(@as(f32, 0.01), g.scale);
    g.fit();
    g.resize(.{ .width = 1000, .height = 500 }, .{ .width = 250, .height = 200 });
    try testing.expectEqual(@as(f32, 0.25), g.scale);
    g.zoom(1.0, .{ .x = 125, .y = 100 });
    g.resize(.{ .width = 1000, .height = 500 }, .{ .width = 300, .height = 200 });
    try testing.expectEqual(@as(f32, 1.0), g.scale);
}

test "wheel requires control and normalizes lines" {
    var s: ViewState = .{ .geometry = geometry() };
    var ev: input.ScrollWheelEvent = .{ .position = .{ .x = 250, .y = 150 }, .delta = .{ .lines = .{ .x = 0, .y = 1 } } };
    try testing.expect(!s.wheel(&ev));
    try testing.expectEqual(@as(f32, 0.5), s.geometry.scale);
    ev.modifiers.control = true;
    try testing.expect(s.wheel(&ev));
    const scale = s.geometry.scale;
    try testing.expect(scale > 0.5);
    s.geometry.fit();
    ev.delta = .{ .pixels = .{ .x = 0, .y = 40 } };
    _ = s.wheel(&ev);
    try testing.expectEqual(scale, s.geometry.scale);
    ev.delta = .{ .lines = .{ .x = 0, .y = -1 } };
    _ = s.wheel(&ev);
    try testing.expectApproxEqAbs(@as(f32, 0.5), s.geometry.scale, 0.0001);
}

test "a drag does not click" {
    var s: ViewState = .{ .geometry = geometry() };
    s.pointerDown(.{ .x = 200, .y = 150 });
    try testing.expect(!s.pointerMove(&.{ .position = .{ .x = 202, .y = 150 }, .pressed_button = .left }));
    try testing.expect(s.pointerMove(&.{ .position = .{ .x = 220, .y = 150 }, .pressed_button = .left }));
    try testing.expect(s.dragged);
    s.pointerDown(.{ .x = 200, .y = 150 });
    try testing.expect(!s.dragged);
}

test {
    testing.refAllDecls(Lightbox);
}
