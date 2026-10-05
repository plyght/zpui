//! Entrance motions from zeron `motion.rs`, as `zpui.withAnimation` wrappers.
//!
//! ```zig
//! anim.fadeIn("phase-app", page)          // FADE_IN: 500ms ease-out-expo, opacity 0→1, y 4→0
//! anim.settleDown("new-thread", canvas)   // FADE_IN: opacity 0→1, y −10→0
//! anim.fadeQuick("row-in", row)           // FADE_QUICK: 150ms ease, opacity 0→1
//! anim.menuIn("spaces-menu", card, -2)    // MENU_IN: 140ms ease, opacity 0.3→1, y from→0
//! anim.dialogIn("rename-dialog", card)    // DIALOG_IN: 180ms ease, opacity 0→1, y 2→0
//! ```
//! Progress keys on the id: a new id replays the entrance. Every span honors
//! `ZERON_MOTION_SCALE` (`MotionSpec.animation`); reduced motion snaps to the
//! end state (zpui's animation element).

const zpui = @import("zpui");
const motion = @import("zeron_theme").motion;

const px = zpui.px;

fn fadeInFrame(el: zpui.Div, t: f32) zpui.Div {
    const f = motion.fadeInFrame(t);
    return el.relative().opacity(f.opacity).top(px(f.offset_y));
}

pub const FadeIn = @TypeOf(zpui.withAnimation(zpui.div(), "", motion.fade_in.animation(), fadeInFrame));

/// `motion::fade_in`.
pub fn fadeIn(id: anytype, el: zpui.Div) FadeIn {
    return zpui.withAnimation(el, id, motion.fade_in.animation(), fadeInFrame);
}

fn settleDownFrame(el: zpui.Div, t: f32) zpui.Div {
    const f = motion.settleDownFrame(t);
    return el.relative().opacity(f.opacity).top(px(f.offset_y));
}

/// `motion::settle_down` (the new-thread composition entrance).
pub fn settleDown(id: anytype, el: zpui.Div) @TypeOf(zpui.withAnimation(el, id, motion.fade_in.animation(), settleDownFrame)) {
    return zpui.withAnimation(el, id, motion.fade_in.animation(), settleDownFrame);
}

fn fadeQuickFrame(el: zpui.Div, t: f32) zpui.Div {
    return el.opacity(t);
}

pub const FadeQuick = @TypeOf(zpui.withAnimation(zpui.div(), "", motion.fade_quick.animation(), fadeQuickFrame));

/// `motion::fade_quick`: opacity only.
pub fn fadeQuick(id: anytype, el: zpui.Div) FadeQuick {
    return zpui.withAnimation(el, id, motion.fade_quick.animation(), fadeQuickFrame);
}

fn menuFrame(from: f32, el: zpui.Div, t: f32) zpui.Div {
    const f = motion.menuInFrame(t, from);
    return el.relative().opacity(f.opacity).top(px(f.offset_y));
}

/// `motion::menu_in_from` (`menu_in` is `from = -2`).
pub fn menuIn(id: anytype, el: zpui.Div, from: f32) @TypeOf(zpui.withAnimationCtx(el, id, motion.menu_in.animation(), from, menuFrame)) {
    return zpui.withAnimationCtx(el, id, motion.menu_in.animation(), from, menuFrame);
}

fn dialogFrame(el: zpui.Div, t: f32) zpui.Div {
    const f = motion.dialogInFrame(t);
    return el.relative().opacity(f.opacity).top(px(f.offset_y));
}

pub const DialogIn = @TypeOf(zpui.withAnimation(zpui.div(), "", motion.dialog_in.animation(), dialogFrame));

/// `motion::dialog_in`: modal cards and the jump-to-bottom pill.
pub fn dialogIn(id: anytype, el: zpui.Div) DialogIn {
    return zpui.withAnimation(el, id, motion.dialog_in.animation(), dialogFrame);
}

/// `motion::menu_out_toward` / `menu_out` (`toward = -2`): the exit frame for
/// caller-computed eased progress `t` (wall clock from the closing instant;
/// an element-keyed clock would replay from 0 on remount).
pub fn menuOutFrame(el: zpui.Div, toward: f32, t: f32) zpui.Div {
    const f = motion.menuOutFrame(t, toward);
    return el.relative().opacity(f.opacity).top(px(f.offset_y));
}
