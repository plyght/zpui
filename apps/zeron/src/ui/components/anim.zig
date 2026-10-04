//! Entrance motions from zeron `motion.rs`, as `zpui.withAnimation` wrappers.
//!
//! ```zig
//! anim.fadeIn("phase-app", page)          // FADE_IN: 500ms ease-out-expo, opacity 0→1, y 4→0
//! anim.menuIn("spaces-menu", card, -2)    // MENU_IN: 140ms ease, opacity 0.3→1, y from→0
//! ```
//! Progress keys on the id: a new id replays the entrance.

const zpui = @import("zpui");

const px = zpui.px;
const ease_out_expo = zpui.easing.cubicBezier(0.16, 1, 0.3, 1);
const ease = zpui.easing.cubicBezier(0.25, 0.1, 0.25, 1);

fn fadeInFrame(el: zpui.Div, t: f32) zpui.Div {
    return el.relative().opacity(t).top(px(4 * (1 - t)));
}

pub fn fadeIn(id: anytype, el: zpui.Div) @TypeOf(zpui.withAnimation(el, id, zpui.Animation.ms(500), fadeInFrame)) {
    return zpui.withAnimation(el, id, zpui.Animation.ms(500).withEasing(ease_out_expo), fadeInFrame);
}

fn menuFrame(from: f32, el: zpui.Div, t: f32) zpui.Div {
    return el.relative().opacity(0.3 + 0.7 * t).top(px(from * (1 - t)));
}

pub fn menuIn(id: anytype, el: zpui.Div, from: f32) @TypeOf(zpui.withAnimationCtx(el, id, zpui.Animation.ms(140), from, menuFrame)) {
    return zpui.withAnimationCtx(el, id, zpui.Animation.ms(140).withEasing(ease), from, menuFrame);
}
