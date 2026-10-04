//! zeron's pill switch (`settings::widgets::toggle_switch`): 44.8×28.8 slot,
//! 20.8px track with on/off marks beneath a sliding 24px thumb, frosted rim
//! tones. Static (the caller re-renders on toggle).
//!
//! ```zig
//! row.child(ui.switch_.toggle(theme, settings.compact))
//! ```

const zpui = @import("zpui");
const zt = @import("zeron_theme");
const theme_mod = @import("theme.zig");

const Theme = theme_mod.Theme;
const div = zpui.div;
const px = zpui.px;
const flatten = zt.colorspace.flatten;
const color = zpui.color;

pub const width: f32 = 44.8;
pub const height: f32 = 28.8;
const track_height: f32 = 20.8;
const side_inset: f32 = 1.6;
const thumb_width: f32 = 24.0;
const thumb_height: f32 = track_height - 2.0 * side_inset;
const mark_size: f32 = 7.2;

fn white(a: f32) zpui.Hsla {
    return zpui.hsla(0, 0, 1, a);
}
fn black(a: f32) zpui.Hsla {
    return zpui.hsla(0, 0, 0, a);
}

fn trackColor(theme: *const Theme, on: bool) zpui.Hsla {
    const dark = theme.appearance.isDark();
    if (on) {
        if (dark) return flatten(black(0.14), theme.accent_strong);
        const a = theme.accent;
        return flatten(zpui.hsla(a.h, a.s, a.l + (1.0 - a.l) * 0.10, 0.98), theme.surface);
    }
    const frost = theme.isFrost();
    const opacity: f32 = if (dark) (if (frost) 0.22 else 0.18) else (if (frost) 0.12 else 0.10);
    return flatten(theme.ink(opacity), theme.surface);
}

fn thumbColor(theme: *const Theme) zpui.Hsla {
    const w: f32 = if (theme.isFrost()) (if (theme.appearance.isDark()) 0.94 else 0.96) else (if (theme.appearance.isDark()) 0.96 else 1.0);
    return flatten(white(w), theme.surface);
}

fn tones(theme: *const Theme, base: zpui.Hsla, thumb: bool) [2]zpui.Hsla {
    if (!theme.isFrost()) return .{ base, base };
    const light: f32 = if (thumb) 0.12 else 0.07;
    const shade: f32 = if (thumb) 0.07 else 0.09;
    return .{ flatten(white(light), base), flatten(black(shade), base) };
}

/// The switch visual at rest in state `on`.
pub fn toggle(theme: *const Theme, on: bool) zpui.Div {
    const position: f32 = if (on) 1 else 0;
    const track = trackColor(theme, on);
    const tt = tones(theme, track, false);
    const thumb = thumbColor(theme);
    const th = tones(theme, thumb, true);
    const empty_width = width - thumb_width - side_inset;
    const mark_padding = (empty_width - mark_size) / 2.0;
    const thumb_left = side_inset + (width - thumb_width - 2.0 * side_inset) * position;
    const stop = color.linearColorStop;
    const track_el = div().absolute().top(px((height - track_height) / 2)).left(px(0))
        .w(px(width)).h(px(track_height)).roundedFull()
        .bg(color.linearGradient(180, stop(tt[0], 0), stop(tt[1], 1)))
        .border1().borderColor(if (on) flatten(white(if (theme.isFrost()) 0.16 else 0.12), track) else flatten(theme.border, track))
        .child(div().absolute().inset0().px(px(mark_padding)).flex().itemsCenter().justifyBetween()
            .child(div().size(px(mark_size)).flex().itemsCenter().justifyCenter().opacity(position)
                .child(div().w(px(1.2)).h(px(7.2)).roundedFull().bg(white(0.96))))
            .child(div().size(px(mark_size)).flex().itemsCenter().justifyCenter().opacity(1 - position)
                .child(div().size(px(6.4)).roundedFull().border1().borderColor(white(0.92)))));
    var thumb_el = div().absolute().top(px((height - thumb_height) / 2)).left(px(thumb_left))
        .w(px(thumb_width)).h(px(thumb_height)).roundedFull()
        .bg(color.linearGradient(180, stop(th[0], 0), stop(th[1], 1)))
        .border1().borderColor(flatten(black(if (theme.appearance.isDark()) 0.10 else 0.08), thumb));
    if (theme.isFrost() and on) thumb_el = thumb_el.child(div().absolute().top(px(1.6)).left(px(7.2)).w(px(9.6)).h(px(1))
        .roundedFull().bg(flatten(white(0.45), th[0])));
    return div().relative().flexNone().w(px(width)).h(px(height)).child(track_el).child(thumb_el);
}
