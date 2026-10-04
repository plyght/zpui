//! CI smoke probe (`ZERON_SMOKE_MENU=1`, see `smoke.zig`): high-contrast stripes
//! painted in the window, optionally covered by a frosted floating card built from
//! the real menu chrome (`popover.card` + `popover.frostedCard`'s blur, deferred like
//! every menu). The smoke compares the stripes' high-frequency energy under the card
//! with and without it: a working backdrop blur flattens them; a blur that samples
//! the wrong plane (the macOS overlay-plane regression) leaves them crisp under the tint.

const zpui = @import("zpui");
const ui = @import("../components/root.zig");

const div = zpui.div;
const px = zpui.px;

pub const Mode = enum { off, stripes, menu };

/// Window-space geometry (logical px) shared with the smoke's measurement.
pub const origin: zpui.Point(f32) = .{ .x = 72, .y = 132 };
pub const stripes_size: zpui.Size(f32) = .{ .width = 264, .height = 168 };
pub const stripe_w: f32 = 6;
/// The card inside the stripes block.
pub const card_inset: f32 = 24;
/// Measure this far inside the card (border, rounded corners, blur edge falloff).
pub const measure_inset: f32 = 18;

/// The measured rect (logical px, window space).
pub fn measureRect() zpui.Bounds(f32) {
    const m = card_inset + measure_inset;
    return .{
        .origin = .{ .x = origin.x + m, .y = origin.y + m },
        .size = .{ .width = stripes_size.width - 2 * m, .height = stripes_size.height - 2 * m },
    };
}

pub fn element(theme: *const ui.Theme, mode: Mode) zpui.Div {
    var stripes = div().absolute().left(px(origin.x)).top(px(origin.y))
        .w(px(stripes_size.width)).h(px(stripes_size.height)).flex().flexRow();
    const n: usize = @intFromFloat(stripes_size.width / stripe_w);
    for (0..n) |i| {
        stripes = stripes.child(div().flexNone().w(px(stripe_w)).hFull()
            .bg(if (i % 2 == 0) zpui.color.black else zpui.color.white));
    }
    if (mode != .menu) return stripes;
    // The real floating-menu chrome; frosted even when the theme is opaque, with the
    // frosted card tint in that case, so the check always exercises the blur.
    const popup = theme.forPopup();
    var card = ui.popover.card(&popup)
        .w(px(stripes_size.width - 2 * card_inset)).h(px(stripes_size.height - 2 * card_inset));
    if (!theme.isFrost()) card = card.bg(theme.surface_overlay.opacity(0.5));
    const frosted: ui.effects.Frosted = .{
        .radius = ui.popover.card_radius,
        .blur = ui.theme.layout.menu_blur,
        .child = zpui.intoAnyElement(card),
        .force = true,
    };
    return stripes.child(div().absolute().left(px(card_inset)).top(px(card_inset))
        .child(zpui.deferred(div().occlude().child(frosted)).withPriority(1)));
}
