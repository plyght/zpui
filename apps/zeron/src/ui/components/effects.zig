//! Paint-scope wrappers (zeron `frost.rs`, `edge_fade.rs`) and the faded
//! single-line label (`sidebar_faded_label`).
//!
//! ```zig
//! effects.frosted(12, 16, card)                 // backdrop blur behind `card`, clipped to radius 12
//! effects.edgeFaded(child, .{ .band = 24, .top = true, .bottom = true, .scroll = handle })
//! effects.fadedText(title, .{ .fill = true })   // one line; fades its last 20px only when clipped
//! ```
//!
//! `frosted` paints `window.paintBackdropBlur` inside a layer and then the
//! child, so the card's translucent fill lands on blurred backdrop (only when
//! the theme is frosted). `edgeFaded` applies a per-primitive `EdgeFade` over
//! the child's bounds; with `scroll` set, top/bottom only fade while there is
//! content beyond that edge.

const std = @import("std");
const zpui = @import("zpui");
const theme_mod = @import("theme.zig");

const Window = zpui.Window;
const App = zpui.App;
const AnyElement = zpui.AnyElement;
const Bounds = zpui.Bounds(f32);
const LayoutId = zpui.LayoutId;
const GlobalElementId = zpui.GlobalElementId;

// ---------------------------------------------------------------------------
// Frosted
// ---------------------------------------------------------------------------

pub const Frosted = struct {
    radius: f32,
    blur: f32,
    child: AnyElement,
    force: bool = false,

    pub fn intoAnyElement(self: Frosted) AnyElement {
        return AnyElement.new(self);
    }

    pub fn requestLayout(self: *Frosted, _: ?GlobalElementId, _: *void, window: *Window, cx: *App) LayoutId {
        return self.child.requestLayout(window, cx);
    }

    pub fn prepaint(self: *Frosted, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        self.child.prepaint(window, cx);
    }

    pub fn paint(self: *Frosted, _: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        if (!self.force and !theme_mod.get(cx).isFrost()) return self.child.paint(window, cx);
        // [liquid-glass] Native glass replaces the in-scene blur (falls through to frost
        // when the window cannot host it).
        if (theme_mod.get(cx).isLiquid() and
            zpui.liquid_glass.paintGlass(window, cx, "frosted-glass", bounds, .{ .shape = .{ .rounded = self.radius } }, self.child)) return;
        const layer = window.pushLayer(bounds);
        defer window.popLayer(layer);
        window.paintBackdropBlur(bounds, zpui.Corners(f32).all(self.radius), self.blur);
        self.child.paint(window, cx);
    }
};

/// Backdrop-blur `child` (corner `radius`, Gaussian `blur` sigma).
pub fn frosted(radius: f32, blur: f32, child: anytype) Frosted {
    return .{ .radius = radius, .blur = blur, .child = zpui.intoAnyElement(child) };
}

// ---------------------------------------------------------------------------
// EdgeFaded
// ---------------------------------------------------------------------------

pub const FadeOptions = struct {
    band: f32 = 24,
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    /// Per-edge band overrides.
    band_top: ?f32 = null,
    band_bottom: ?f32 = null,
    /// Shrink the fade scope from the top: content above it is fully faded
    /// (zeron `inset_top`, used under the titlebar).
    inset_top: f32 = 0,
    /// Gate top/bottom (and left/right) on actual scroll overflow.
    scroll: ?zpui.ScrollHandle = null,
};

pub const EdgeFaded = struct {
    opts: FadeOptions,
    child: AnyElement,

    pub fn intoAnyElement(self: EdgeFaded) AnyElement {
        return AnyElement.new(self);
    }

    pub fn requestLayout(self: *EdgeFaded, _: ?GlobalElementId, _: *void, window: *Window, cx: *App) LayoutId {
        return self.child.requestLayout(window, cx);
    }

    pub fn prepaint(self: *EdgeFaded, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        self.child.prepaint(window, cx);
    }

    pub fn paint(self: *EdgeFaded, _: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        var o = self.opts;
        if (o.scroll) |h| {
            const off = h.offset();
            const max = h.maxOffset();
            o.top = o.top and off.y < -0.5;
            o.bottom = o.bottom and -off.y < max.y - 0.5;
            o.left = o.left and off.x < -0.5;
            o.right = o.right and -off.x < max.x - 0.5;
        }
        var b = bounds;
        b.origin.y += o.inset_top;
        b.size.height = @max(b.size.height - o.inset_top, 0);
        const fade: zpui.EdgeFade = .{ .bounds = b, .band = o.band, .band_top = o.band_top, .band_bottom = o.band_bottom, .top = o.top, .bottom = o.bottom, .left = o.left, .right = o.right };
        const prev = window.pushEdgeFade(fade);
        defer window.popEdgeFade(prev);
        self.child.paint(window, cx);
    }
};

pub fn edgeFaded(child: anytype, opts: FadeOptions) EdgeFaded {
    return .{ .opts = opts, .child = zpui.intoAnyElement(child) };
}

// ---------------------------------------------------------------------------
// FadedText
// ---------------------------------------------------------------------------

pub const FadedTextOptions = struct {
    /// Grow to fill the row (`flex_1`); otherwise hug the text and shrink.
    fill: bool = false,
    /// Fade band at the clipped (right) edge.
    band: f32 = 20,
};

const TextState = struct {
    gpa: std.mem.Allocator,
    lines: []zpui.text.WrappedLine = &.{},
    natural: f32 = 0,
    /// Unrounded shaped width (the overflow that drives the fade ease-in).
    natural_exact: f32 = 0,
    line_height: f32 = 0,

    pub fn deinit(self: *TextState) void {
        if (self.lines.len > 0) zpui.text.freeLines(self.gpa, self.lines);
        self.lines = &.{};
    }
};

/// One nowrap line in the inherited text style that never wraps or
/// ellipsizes: when clipped, its last `band` px fade out instead.
pub const FadedText = struct {
    text: []const u8,
    opts: FadedTextOptions,
    state: *TextState,

    pub fn intoAnyElement(self: FadedText) AnyElement {
        return AnyElement.new(self);
    }

    const Measure = struct {
        state: *TextState,
        text: []const u8,
        runs: []const zpui.text.TextRun,
        font_size: f32,
    };

    fn measure(c: *Measure, _: zpui.layout.Dims(?f32), _: zpui.layout.Dims(zpui.layout.AvailableSpace), window: *Window, _: *App) zpui.Size(f32) {
        if (c.state.lines.len == 0 and c.text.len > 0) {
            c.state.lines = window.text_system.shapeText(c.text, c.font_size, c.runs, .{}) catch &.{};
            var w: f32 = 0;
            for (c.state.lines) |l| w = @max(w, l.size(c.state.line_height).width);
            c.state.natural_exact = w;
            c.state.natural = @ceil(w);
        }
        return .{ .width = c.state.natural, .height = c.state.line_height };
    }

    pub fn requestLayout(self: *FadedText, _: ?GlobalElementId, _: *void, window: *Window, _: *App) LayoutId {
        const ts = window.textStyle();
        const rem = window.remSize();
        const font_size = ts.font_size.toPixels(rem);
        self.state.line_height = window.pixelSnap(ts.line_height.toPixels(.{ .pixels = font_size }, rem));
        const runs = zpui.window.arena_mod.frameAllocator().alloc(zpui.text.TextRun, 1) catch @panic("OOM");
        runs[0] = ts.toRun(self.text.len);
        const ctx = zpui.window.arena_mod.current().create(Measure, .{ .state = self.state, .text = self.text, .runs = runs, .font_size = font_size });
        var style: zpui.Style = .{};
        style.min_size.width = .{ .definite = .{ .absolute = .{ .pixels = 0 } } };
        style.flex_shrink = 1;
        style.flex_grow = if (self.opts.fill) 1 else 0;
        return window.requestMeasuredLayout(style, ctx, measure);
    }

    pub fn prepaint(_: *FadedText, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, _: *Window, _: *App) void {}

    pub fn paint(self: *FadedText, _: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, _: *App) void {
        // zeron `edge_faded(..).fade_right(true).fade_label_overflow(..)`: fade only while
        // clipped, and ease the ramp in as the overflow grows from zero to one band by
        // pushing the fade's right edge out past the clip (`label_fade_outset`), so a
        // barely-clipped title does not dim its last characters a whole band early.
        const overflow = self.state.natural_exact - bounds.size.width;
        const clipped = overflow > 0.01;
        const mask: zpui.ContentMask = .{ .bounds = bounds };
        if (clipped) window.pushContentMask(mask);
        defer if (clipped) window.popContentMask(mask);
        var fade_bounds = bounds;
        fade_bounds.size.width += zpui.effects.labelFadeOutset(overflow, self.opts.band);
        const prev = if (clipped) window.pushEdgeFade(.{ .bounds = fade_bounds, .band = self.opts.band, .right = true }) else null;
        defer if (clipped) window.popEdgeFade(prev);
        const painter = window.glyphPainter();
        var origin = bounds.origin;
        for (self.state.lines) |line| {
            line.paint(painter, origin, self.state.line_height, .left, null) catch {};
            origin.y += self.state.line_height;
        }
    }
};

pub fn fadedText(text: []const u8, opts: FadedTextOptions) FadedText {
    const arena = zpui.window.arena_mod.current();
    const st = arena.create(TextState, .{ .gpa = arena.gpa });
    return .{ .text = text, .opts = opts, .state = st };
}
