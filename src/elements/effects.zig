//! Element wrappers for zui's fork effects (generic versions of zeron's `edge_fade.rs` and
//! `frost.rs`):
//!
//! * `edgeFaded(band, top, bottom, child)` paints `child`'s whole subtree inside an
//!   `EdgeFade` scope: primitives fade per pixel by distance to the wrapper's edges (a true
//!   gradient that works over translucent/blurred windows, unlike an overlay).
//!   `.fadeOverflowY(handle)` gates the top/bottom fades on the scroll position at paint time.
//! * `frosted(radius, blur, child)` paints a backdrop blur and then the child in one scene
//!   layer (blur first, then shadow, tint, border, rows, text).
//! * `layered(child)` paints the child in a fresh scene layer above what came before.
//!
//! ```zig
//! zpui.edgeFaded(24, true, true, zpui.list(self.state, cx, Self.row).sizeFull())
//!     .fadeOverflowY(self.state)
//! zpui.frosted(12, 16, div().roundedXl().bg(theme.surface.opacity(0.6)).child(menu))
//! ```

const std = @import("std");
const geometry = @import("../geometry.zig");
const App = @import("../app/app.zig").App;
const window_mod = @import("../window/window.zig");
const Window = window_mod.Window;
const EdgeFade = window_mod.EdgeFade;
const WindowId = window_mod.WindowId;
const element = @import("../window/element.zig");
const AnyElement = element.AnyElement;
const GlobalElementId = element.GlobalElementId;
const LayoutId = element.LayoutId;
const arena_mod = @import("../window/arena.zig");
const scrollbar_mod = @import("scrollbar.zig");
const Source = scrollbar_mod.Source;

const Pixels = geometry.Pixels;
const Bounds = geometry.Bounds(Pixels);
const Corners = geometry.Corners(Pixels);

// ---------------------------------------------------------------------------------------
// Edge fade
// ---------------------------------------------------------------------------------------

/// Paint-time vertical overflow `(top, bottom)` for custom scrollers.
pub const OverflowFn = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, app: *App) [2]bool,
};

pub const EdgeFadedData = struct {
    child: AnyElement,
    band: Pixels,
    band_top: ?Pixels = null,
    band_bottom: ?Pixels = null,
    inset_top: Pixels = 0,
    outset_bottom: Pixels = 0,
    top: bool,
    bottom: bool,
    left: bool = false,
    right: bool = false,
    scroll_y: ?Source = null,
    overflow_y: ?OverflowFn = null,
    scroll_x: ?Source = null,
    smooth_overflow_x: bool = false,
    grow_x: bool = false,
};

/// Fade `child` at its own edges: `top`/`bottom` choose the edges, `band` is the ramp
/// height in px. Horizontal edges via `fadeLeft`/`fadeRight`.
pub fn edgeFaded(band: Pixels, top: bool, bottom: bool, child: anytype) EdgeFaded {
    return .{ .d = arena_mod.current().create(EdgeFadedData, .{
        .child = element.intoAnyElement(child),
        .band = band,
        .top = top,
        .bottom = bottom,
    }) };
}

pub const EdgeFaded = struct {
    const Self = @This();
    d: *EdgeFadedData,

    pub fn fadeLeft(self: Self, on: bool) Self {
        self.d.left = on;
        return self;
    }
    pub fn fadeRight(self: Self, on: bool) Self {
        self.d.right = on;
        return self;
    }
    /// Ramp height at the top edge only (asymmetric chrome above/below).
    pub fn bandTop(self: Self, v: Pixels) Self {
        self.d.band_top = v;
        return self;
    }
    pub fn bandBottom(self: Self, v: Pixels) Self {
        self.d.band_bottom = v;
        return self;
    }
    /// Gate the vertical fades on `handle`'s overflow, read at paint time (after the
    /// scroller's prepaint clamped this frame's offset). `handle`: `ScrollHandle`,
    /// `ListState` or `UniformListScrollHandle`.
    pub fn fadeOverflowY(self: Self, handle: anytype) Self {
        self.d.scroll_y = Source.from(handle);
        return self;
    }
    /// Paint-time overflow from `f(ctx, app) [2]bool` (top, bottom); `ctx` is copied into
    /// the frame arena.
    pub fn fadeOverflowYWith(self: Self, ctx: anytype, comptime f: fn (@TypeOf(ctx), *App) [2]bool) Self {
        const C = @TypeOf(ctx);
        const Gen = struct {
            fn call(p: *anyopaque, a: *App) [2]bool {
                return f(@as(*C, @ptrCast(@alignCast(p))).*, a);
            }
        };
        self.d.overflow_y = .{ .ctx = @ptrCast(arena_mod.current().create(C, ctx)), .func = Gen.call };
        return self;
    }
    /// `fadeOverflowY` for the horizontal edges.
    pub fn fadeOverflowX(self: Self, handle: anytype) Self {
        self.d.scroll_x = Source.from(handle);
        return self;
    }
    /// Horizontal fades whose ramps grow with the hidden content (up to the band).
    pub fn fadeScrollX(self: Self, handle: anytype) Self {
        self.d.scroll_x = Source.from(handle);
        self.d.grow_x = true;
        return self;
    }
    /// Ease a right-edge label fade in as overflow grows from zero to one band.
    pub fn fadeLabelOverflow(self: Self, handle: anytype) Self {
        self.d.scroll_x = Source.from(handle);
        self.d.smooth_overflow_x = true;
        return self;
    }
    /// Move the fade's top edge `v` px inside the wrapper (content above it is invisible).
    pub fn insetTop(self: Self, v: Pixels) Self {
        self.d.inset_top = v;
        return self;
    }
    pub fn outsetBottom(self: Self, v: Pixels) Self {
        self.d.outset_bottom = v;
        return self;
    }
    pub fn intoAnyElement(self: Self) AnyElement {
        return AnyElement.new(EdgeFadedElement{ .d = self.d });
    }
};

// Nested EdgeFade scopes replace rather than compose; keep the active wrapper scopes so a
// label fade can inherit its scroll container's vertical fade.
const FadeEntry = struct { window: WindowId, fade: EdgeFade };
var paint_fades: [32]FadeEntry = undefined;
var paint_fades_len: usize = 0;

/// The innermost active `edgeFaded` scope in `window` during paint.
pub fn activeFade(window: *const Window) ?EdgeFade {
    var i = paint_fades_len;
    while (i > 0) {
        i -= 1;
        if (paint_fades[i].window == window.id) return paint_fades[i].fade;
    }
    return null;
}

fn inheritVerticalFade(label: EdgeFade, parent: EdgeFade) EdgeFade {
    var l = label;
    if (!l.top and !l.bottom and (parent.top or parent.bottom)) {
        l.bounds.origin.y = parent.bounds.origin.y;
        l.bounds.size.height = parent.bounds.size.height;
        l.top = parent.top;
        l.bottom = parent.bottom;
        l.band_top = parent.band_top orelse parent.band;
        l.band_bottom = parent.band_bottom orelse parent.band;
    }
    return l;
}

/// Right-edge outset for a label fade easing in (smoothstep over one band).
pub fn labelFadeOutset(overflow: Pixels, band: Pixels) Pixels {
    const b = @max(band, 1);
    const p = std.math.clamp(overflow / b, 0, 1);
    const eased = p * p * (3 - 2 * p);
    return b * (1 - eased);
}

const EdgeFadedElement = struct {
    d: *EdgeFadedData,

    pub fn requestLayout(self: *EdgeFadedElement, _: ?GlobalElementId, _: *void, window: *Window, cx: *App) LayoutId {
        return self.d.child.requestLayout(window, cx);
    }

    pub fn prepaint(self: *EdgeFadedElement, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        self.d.child.prepaint(window, cx);
    }

    pub fn paint(self: *EdgeFadedElement, _: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        const d = self.d;
        var top = d.top;
        var bottom = d.bottom;
        if (d.scroll_y) |s| {
            const scrolled = -s.offset().y;
            const max = s.maxOffset().y;
            top = top and scrolled > 1;
            bottom = bottom and scrolled < max - 1;
        }
        if (d.overflow_y) |o| {
            const ov = o.func(o.ctx, cx);
            top = top and ov[0];
            bottom = bottom and ov[1];
        }
        var left = d.left;
        var right = d.right;
        var outset_right: Pixels = 0;
        var band_left: ?Pixels = null;
        var band_right: ?Pixels = null;
        if (d.scroll_x) |s| {
            const scrolled = -s.offset().x;
            const max = s.maxOffset().x;
            if (d.grow_x) {
                const hidden_left = @max(scrolled, 0);
                const hidden_right = @max(max - hidden_left, 0);
                left = left and hidden_left > 0.5;
                right = right and hidden_right > 0.5;
                band_left = @min(hidden_left, d.band);
                band_right = @min(hidden_right, d.band);
            } else {
                left = left and scrolled > 1;
                if (d.smooth_overflow_x) {
                    const overflow = @max(max - scrolled, 0);
                    right = right and overflow > 0;
                    outset_right = labelFadeOutset(overflow, d.band);
                } else {
                    right = right and scrolled < max - 1;
                }
            }
        }
        if (!(top or bottom or left or right)) {
            d.child.paint(window, cx);
            return;
        }
        var b = bounds;
        b.size.width += outset_right;
        const inset = @min(d.inset_top, b.size.height);
        b.origin.y += inset;
        b.size.height -= inset;
        b.size.height = @max(b.size.height + d.outset_bottom, 0);
        var fade: EdgeFade = .{
            .bounds = b,
            .band = d.band,
            .band_top = d.band_top,
            .band_bottom = d.band_bottom,
            .band_left = band_left,
            .band_right = band_right,
            .top = top,
            .bottom = bottom,
            .left = left,
            .right = right,
        };
        if (d.smooth_overflow_x) if (activeFade(window)) |parent| {
            fade = inheritVerticalFade(fade, parent);
        };
        const pushed = paint_fades_len < paint_fades.len;
        if (pushed) {
            paint_fades[paint_fades_len] = .{ .window = window.id, .fade = fade };
            paint_fades_len += 1;
        }
        const prev = window.pushEdgeFade(fade);
        d.child.paint(window, cx);
        window.popEdgeFade(prev);
        if (pushed) paint_fades_len -= 1;
    }
};

// ---------------------------------------------------------------------------------------
// Frost / layers
// ---------------------------------------------------------------------------------------

pub const FrostedData = struct {
    child: AnyElement,
    corner_radius: Pixels,
    blur_radius: Pixels,
    enabled: bool = true,
};

/// Backdrop-blur `child` (a card) with `blur_radius` sigma, clipped to `corner_radius`
/// (must match the card's rounding), all in one scene layer.
pub fn frosted(corner_radius: Pixels, blur_radius: Pixels, child: anytype) Frosted {
    return .{ .d = arena_mod.current().create(FrostedData, .{
        .child = element.intoAnyElement(child),
        .corner_radius = corner_radius,
        .blur_radius = blur_radius,
    }) };
}

/// zeron's shared blur sigma for menus, popovers and palettes.
pub const menu_blur: Pixels = 16;

pub const Frosted = struct {
    const Self = @This();
    d: *FrostedData,

    /// Pass-through (no blur, no layer) when false — e.g. on opaque themes.
    pub fn enabled(self: Self, on: bool) Self {
        self.d.enabled = on;
        return self;
    }
    pub fn intoAnyElement(self: Self) AnyElement {
        return AnyElement.new(FrostedElement{ .d = self.d });
    }
};

const FrostedElement = struct {
    d: *FrostedData,

    pub fn requestLayout(self: *FrostedElement, _: ?GlobalElementId, _: *void, window: *Window, cx: *App) LayoutId {
        return self.d.child.requestLayout(window, cx);
    }
    pub fn prepaint(self: *FrostedElement, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        self.d.child.prepaint(window, cx);
    }
    pub fn paint(self: *FrostedElement, _: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        if (!self.d.enabled) {
            self.d.child.paint(window, cx);
            return;
        }
        const layer = window.pushLayer(bounds);
        window.paintBackdropBlur(bounds, Corners.all(self.d.corner_radius), self.d.blur_radius);
        self.d.child.paint(window, cx);
        window.popLayer(layer);
    }
};

/// Paint `child` in its own scene layer (a fresh draw order above everything painted so far
/// in the enclosing layer) — for overlays inside a frosted card.
pub fn layered(child: anytype) Layered {
    return .{ .child = element.intoAnyElement(child) };
}

pub const Layered = struct {
    child: AnyElement,

    pub fn requestLayout(self: *Layered, _: ?GlobalElementId, _: *void, window: *Window, cx: *App) LayoutId {
        return self.child.requestLayout(window, cx);
    }
    pub fn prepaint(self: *Layered, _: ?GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        self.child.prepaint(window, cx);
    }
    pub fn paint(self: *Layered, _: ?GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        const layer = window.pushLayer(bounds);
        self.child.paint(window, cx);
        window.popLayer(layer);
    }
};

test "label fade outset eases in continuously" {
    const band: f32 = 20;
    try std.testing.expectEqual(band, labelFadeOutset(0, band));
    try std.testing.expectEqual(@as(f32, 0), labelFadeOutset(band, band));
    try std.testing.expectEqual(@as(f32, 0), labelFadeOutset(100, band));
    var prev: f32 = 1;
    for (0..401) |step| {
        const a = std.math.pow(f32, labelFadeOutset(@as(f32, @floatFromInt(step)) / 10, band) / band, 2);
        try std.testing.expect(a <= prev);
        try std.testing.expect(prev - a < 0.02);
        prev = a;
    }
}
