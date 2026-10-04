//! Small paint/layout helpers the composer shares with its popovers: the
//! frosted wrapper (zeron `frost.rs`), popover card + menu rows
//! (`popover.rs`), icons and harness brand marks (`icons.rs`,
//! `pickers.rs::harness_brand_icon`) and the one-line tooltip
//! (`settings::widgets::TextTooltip`). Kept module-local so `zeron_composer`
//! only depends on named modules.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const assets = @import("zeron_assets");
const engine = @import("zeron_engine");

const Window = zpui.Window;
const App = zpui.App;
const AnyElement = zpui.AnyElement;
const Bounds = zpui.Bounds(f32);
const div = zpui.div;
const px = zpui.px;

pub const Theme = zt.Theme;
pub const Hsla = zpui.Hsla;
pub const Icon = assets.Icon;
pub const HarnessId = engine.protocol.HarnessId;

pub const menu_blur: f32 = zt.layout.menu_blur;
pub const card_radius: f32 = zt.layout.popover_card_radius;
pub const card_inset: f32 = zt.layout.popover_card_inset;
pub const menu_gap: f32 = zt.layout.menu_gap;
pub const menu_item_radius: f32 = zt.layout.menu_item_radius;

/// The installed default: the built-in Zeron variant for `appearance`
/// (what the app resolves at runtime, not the `Theme.dark()` fallback).
pub fn defaultTheme(appearance: zt.Appearance) Theme {
    return Theme.forSelection(&zt.registry.builtin, .{
        .appearance = appearance,
        .variant_id = if (appearance.isDark()) "zeron-dark" else "zeron-light",
    });
}

/// zeron `ui_rems(px)`: px/16 rem.
pub fn rems(px_at_16: f32) zpui.Rems {
    return zpui.rems(px_at_16 / 16.0);
}

// ---------------------------------------------------------------------------
// Frosted: backdrop blur in a layer, then the child.
// ---------------------------------------------------------------------------

pub const Frosted = struct {
    radius: f32,
    blur: f32,
    enabled: bool,
    child: AnyElement,

    pub fn intoAnyElement(self: Frosted) AnyElement {
        return AnyElement.new(self);
    }

    pub fn requestLayout(self: *Frosted, _: ?zpui.GlobalElementId, _: *void, window: *Window, cx: *App) zpui.LayoutId {
        return self.child.requestLayout(window, cx);
    }

    pub fn prepaint(self: *Frosted, _: ?zpui.GlobalElementId, _: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        self.child.prepaint(window, cx);
    }

    pub fn paint(self: *Frosted, _: ?zpui.GlobalElementId, bounds: Bounds, _: *void, _: *void, window: *Window, cx: *App) void {
        if (!self.enabled) return self.child.paint(window, cx);
        const layer = window.pushLayer(bounds);
        defer window.popLayer(layer);
        window.paintBackdropBlur(bounds, zpui.Corners(f32).all(self.radius), self.blur);
        self.child.paint(window, cx);
    }
};

/// Backdrop-blur `child` when the theme is frosted (`frost::frosted`).
pub fn frosted(theme: *const Theme, radius: f32, blur: f32, child: anytype) Frosted {
    return .{ .radius = radius, .blur = blur, .enabled = theme.isFrost(), .child = zpui.intoAnyElement(child) };
}

// ---------------------------------------------------------------------------
// Icons
// ---------------------------------------------------------------------------

pub fn icon(i: Icon, size: f32, color: Hsla) zpui.elements.Svg {
    return zpui.svg().source(i.path(), i.svg()).size(px(size)).flexNone().textColor(color);
}

/// `harness_brand_icon`: the mark and its fixed tint (Claude orange).
pub fn harnessMark(h: HarnessId) struct { Icon, ?Hsla } {
    return switch (h) {
        .@"claude-code", .mock => .{ .claude_mark, zt.theme.claude_brand },
        .codex => .{ .openai_mark, null },
        .cursor => .{ .cursor_mark, null },
        .devin => .{ .devin_mark, null },
        .grok => .{ .grok_mark, null },
        .hermes => .{ .hermes_mark, null },
        .pi => .{ .pi_mark, null },
        .opencode => .{ .opencode_mark, null },
        .antigravity => .{ .antigravity_mark, null },
    };
}

pub fn harnessName(h: HarnessId) []const u8 {
    return switch (h) {
        .@"claude-code" => "Claude Code",
        .codex => "Codex",
        .cursor => "Cursor",
        .devin => "Devin",
        .grok => "Grok",
        .hermes => "Hermes",
        .pi => "Pi",
        .opencode => "opencode",
        .antigravity => "Antigravity",
        .mock => "Mock",
    };
}

// ---------------------------------------------------------------------------
// Popover card + rows (popover.rs)
// ---------------------------------------------------------------------------

/// Floating-surface fill (`popover::surface_bg`).
pub fn surfaceBg(theme: *const Theme) Hsla {
    if (theme.isFrost()) {
        return if (theme.appearance.isDark()) theme.composerSidebarTint() else theme.glassOverlay();
    }
    return theme.inputGlassBg();
}

/// `popover_card`: hairline border, radius 12, 4px inset, 13px text.
pub fn card(theme: *const Theme) zpui.Div {
    var d = div().border1().borderColor(theme.border).rounded(px(card_radius))
        .bg(surfaceBg(theme)).p(px(card_inset)).gap(px(menu_gap)).overflowHidden()
        .textSize(rems(13)).textColor(theme.text);
    if (!theme.isFrost()) d = d.shadowLg();
    return d;
}

pub fn cardSelectedBg(theme: *const Theme) Hsla {
    return zt.theme.cardSelectedBg(theme.appearance);
}

/// `menu_row`: 10px gap, 8×6 padding, radius 7, 13px.
pub fn menuRow(theme: *const Theme, id: anytype, active: bool) zpui.StatefulDiv {
    const row = div().id(id).flex().flexRow().itemsCenter().gap(px(10)).px(px(8)).py(px(6))
        .rounded(px(menu_item_radius)).textSize(rems(13)).cursorPointer();
    if (active) return row.bg(cardSelectedBg(theme)).textColor(theme.text);
    return row.textColor(theme.text.opacity(0.9)).hover(zpui.StyleBuilder.init.bg(cardSelectedBg(theme)).textColor(theme.text));
}

// ---------------------------------------------------------------------------
// Tooltip (settings::widgets::text_tooltip)
// ---------------------------------------------------------------------------

pub const TextTooltip = struct {
    text: []const u8,
    theme: Theme,

    pub fn render(self: *TextTooltip, _: *Window, _: *zpui.Context(TextTooltip)) Frosted {
        const theme = &self.theme;
        const c = div()
            .maxW(px(320)).px(px(9)).py(px(6)).rounded(px(6))
            .border1().borderColor(theme.border)
            .bg(surfaceBg(theme))
            .fontFamily(theme.font_sans)
            .textSize(px(11)).lineHeight(px(14)).textColor(theme.text_muted)
            .whitespaceNowrap()
            .child(self.text);
        return frosted(theme, 6, menu_blur, c);
    }
};

/// Tooltip payload: a static label and the theme to paint it with.
pub const TipData = struct {
    text: []const u8,
    dark: bool = true,
};

pub fn buildTooltip(data: TipData, _: *Window, cx: *App) zpui.Entity(TextTooltip) {
    const theme = defaultTheme(if (data.dark) .dark else .light);
    return cx.new(TextTooltip, .{ .text = data.text, .theme = theme }) catch @panic("OOM");
}

/// `hover_blend`-style wash for circular action buttons (`ink(0.10)`).
pub fn actionWash(theme: *const Theme) Hsla {
    return theme.ink(0.10);
}

// ---------------------------------------------------------------------------
// Progress ring (context_usage::ring): 16px, 1.8px stroke, radius 6
// ---------------------------------------------------------------------------

const RingCtx = struct { fraction: f32, color: Hsla, track: Hsla };

fn paintArc(window: *Window, center: zpui.Point(f32), fraction: f32, color: Hsla) void {
    if (fraction <= 0) return;
    const steps: usize = @intFromFloat(@max(@ceil(64.0 * fraction), 2));
    const r_out: f32 = 6 + 0.9;
    const r_in: f32 = 6 - 0.9;
    var path = zpui.scene.Path.init(center);
    defer path.deinit(window.gpa);
    const fill_st: [3]zpui.Point(f32) = .{ .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 1 }, .{ .x = 0, .y = 1 } };
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        const a0 = -std.math.pi / 2.0 + std.math.tau * fraction * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const a1 = -std.math.pi / 2.0 + std.math.tau * fraction * @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(steps));
        const o0: zpui.Point(f32) = .{ .x = center.x + r_out * @cos(a0), .y = center.y + r_out * @sin(a0) };
        const o1: zpui.Point(f32) = .{ .x = center.x + r_out * @cos(a1), .y = center.y + r_out * @sin(a1) };
        const in0: zpui.Point(f32) = .{ .x = center.x + r_in * @cos(a0), .y = center.y + r_in * @sin(a0) };
        const in1: zpui.Point(f32) = .{ .x = center.x + r_in * @cos(a1), .y = center.y + r_in * @sin(a1) };
        path.pushTriangle(window.gpa, .{ o0, o1, in0 }, fill_st) catch return;
        path.pushTriangle(window.gpa, .{ in0, o1, in1 }, fill_st) catch return;
    }
    window.paintPath(path, color);
}

fn paintRing(ctx: RingCtx, bounds: Bounds, window: *Window, _: *App) void {
    const center: zpui.Point(f32) = .{ .x = bounds.origin.x + bounds.size.width / 2, .y = bounds.origin.y + bounds.size.height / 2 };
    paintArc(window, center, 1.0, ctx.track);
    paintArc(window, center, std.math.clamp(ctx.fraction, 0, 1), ctx.color);
}

pub fn ring(fraction: f32, color: Hsla, track: Hsla) zpui.elements.Canvas {
    return zpui.canvas(RingCtx{ .fraction = fraction, .color = color, .track = track }, paintRing).size(px(16)).flexNone();
}

// ---------------------------------------------------------------------------
// Glass plates (glass.rs): vertical gradient, hairline rim, inset top
// highlight and a soft drop.
// ---------------------------------------------------------------------------

pub const Plate = struct {
    top: Hsla,
    bottom: Hsla,
    rim: Hsla,
    shadows: []const zpui.BoxShadow,

    /// Style `d` with the plate (fill, 1px rim, shadows).
    pub fn apply(self: Plate, d: anytype) @TypeOf(d) {
        return d.bg(zpui.color.linearGradient(180, zpui.color.linearColorStop(self.top, 0), zpui.color.linearColorStop(self.bottom, 1)))
            .border1().borderColor(self.rim).shadow(self.shadows);
    }
};

fn white(a: f32) Hsla {
    return zpui.hsla(0, 0, 1, a);
}
fn black(a: f32) Hsla {
    return zpui.hsla(0, 0, 0, a);
}
fn sh(color: Hsla, y: f32, blur: f32, spread: f32, inset: bool) zpui.BoxShadow {
    return .{ .color = color, .offset = .{ .x = 0, .y = y }, .blur_radius = blur, .spread_radius = spread, .inset = inset };
}
fn arenaShadows(list: []const zpui.BoxShadow) []const zpui.BoxShadow {
    return zpui.window.arena_mod.current().allocator().dupe(zpui.BoxShadow, list) catch @panic("OOM");
}
fn mix(a: Hsla, b: Hsla, t: f32) Hsla {
    const ra = a.toRgba();
    const rb = b.toRgba();
    return (zpui.Rgba{ .r = ra.r + (rb.r - ra.r) * t, .g = ra.g + (rb.g - ra.g) * t, .b = ra.b + (rb.b - ra.b) * t, .a = ra.a + (rb.a - ra.a) * t }).toHsla();
}

/// Neutral glass (`light_plate`).
pub fn lightPlate(theme: *const Theme, t: f32) Plate {
    if (theme.appearance.isDark()) return .{
        .top = white(0.08 * t),
        .bottom = white(0.05 * t),
        .rim = white(0.09 * t),
        .shadows = arenaShadows(&.{ sh(white(0.07 * t), 1, 0, 0, true), sh(black(0.16 * t), 1, 2, 0, false) }),
    };
    return .{
        .top = black(0.075 * t),
        .bottom = black(0.04 * t),
        .rim = black(0.08 * t),
        .shadows = arenaShadows(&.{ sh(black(0.08 * t), 1, 2, 0, true), sh(white(0.55 * t), -1, 0, 0, true) }),
    };
}

/// Accent glass (`accent_plate`).
pub fn accentPlate(theme: *const Theme, t: f32, glow: f32) Plate {
    const dark = theme.appearance.isDark();
    const base = theme.accent_strong;
    const top = mix(base, white(base.a), if (dark) 0.06 else 0.22);
    const rim = if (dark) mix(base, white(base.a), 0.35).opacity(0.35) else mix(base, black(1), 0.14);
    const highlight = white(if (dark) 0.12 else 0.32);
    const ring_c = white(if (dark) 0.0 else 0.22);
    const halo = base.opacity(((if (dark) @as(f32, 0) else 0.14) + 0.3 * glow) * t);
    return .{
        .top = top.opacity(t),
        .bottom = base.opacity(t),
        .rim = rim.opacity(t),
        .shadows = arenaShadows(&.{ sh(highlight.opacity(t), 1, 0, 0, true), sh(ring_c.opacity(t), 0, 0, 1, true), sh(halo, 2 + 2 * glow, 6 + 14 * glow, 0, false) }),
    };
}

/// The opaque slider handle (`thumb_plate`).
pub fn thumbPlate(theme: *const Theme) Plate {
    const dark = theme.appearance.isDark();
    return .{
        .top = zpui.hsla(0, 0, 1, 1),
        .bottom = zpui.hsla(0, 0, 0.965, 1),
        .rim = black(if (dark) 0.12 else 0.11),
        .shadows = if (dark)
            arenaShadows(&.{ sh(white(0.8), 1, 0, 0, true), sh(black(0.22), 1, 2, 0, false) })
        else
            arenaShadows(&.{ sh(white(0.8), 1, 0, 0, true), sh(black(0.14), 1, 2, 0, false), sh(black(0.06), 2, 6, 0, false) }),
    };
}
