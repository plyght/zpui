//! Settings scaffolding (zeron `settings/widgets.rs`): the centered page
//! column, large title, small section labels over filled blocks of
//! hairline-split rows, badges, action buttons, select triggers, the option
//! card and the animated pill switch — so every page reads as one surface.
//!
//! ```zig
//! w.pageColumn().child(w.pageHeader(theme, "General", null))
//!     .child(w.sectionCard(theme).child(w.cardRow(theme, true)
//!         .child(w.textBlock(theme, "Compact mode", &.{.{ .text = "Collapse thinking and tools." }}))
//!         .child(w.switchVisual(theme, position))))
//! ```
//! All functions are pure: listeners and state live in `SettingsView`.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");

const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Div = zpui.Div;
const Hsla = zpui.Hsla;
const Theme = ui.Theme;
const rems = ui.rems;
const Icon = ui.icon.Icon;
const flatten = zt.colorspace.flatten;

pub const row_title_size: f32 = 13;
pub const row_description_size: f32 = 12;
const page_max_width: f32 = 760;
const page_pad_x: f32 = 40;
const section_label_inset: f32 = 8;
const section_gap: f32 = 32;
pub const option_card_height: f32 = 148;
pub const option_card_radius: f32 = 6;
pub const select_height: f32 = 32;
pub const select_menu_min_width: f32 = 160;

/// Centered page column; titlebar clearance lives inside the scroll.
pub fn pageColumn() Div {
    return div().wFull().maxW(px(page_max_width)).mxAuto().px(px(page_pad_x))
        .pt(px(zt.layout.titlebar_height + 16)).pb(px(48))
        .flex().flexCol();
}

/// Headline: 20/26 medium, optional muted count on the same baseline.
pub fn pageHeader(theme: *const Theme, title: []const u8, count: ?usize) Div {
    var d = div().px(px(section_label_inset)).flex().flexRow().itemsBaseline().gap(px(10))
        .child(div().textSize(rems(20)).lineHeight(rems(26)).fontWeight(500).textColor(theme.text).child(title));
    if (count) |n| d = d.child(div().textSize(rems(13)).textColor(theme.text_muted).child(zpui.fmt("{d}", .{n})));
    return d;
}

/// Subtitle under the headline (13/17 muted).
pub fn pageSubtitle(theme: *const Theme, copy: []const u8) Div {
    return div().mt(px(4)).px(px(section_label_inset)).minW0()
        .textSize(rems(13)).lineHeight(rems(17)).textColor(theme.text_muted).child(copy);
}

/// The small plain label above a block ("Desktop", "Motion").
pub fn sectionLabel(theme: *const Theme, label: []const u8) Div {
    return div().px(px(section_label_inset)).textSize(rems(13)).lineHeight(rems(17))
        .textColor(theme.text_muted).child(label);
}

/// A labeled section: the label, then its block 8px underneath.
pub fn section(theme: *const Theme, label: []const u8, block: anytype) Div {
    return div().mt(px(section_gap)).flex().flexCol().gap(px(8))
        .child(sectionLabel(theme, label)).child(block);
}

/// Block fill: a faint solid tint of the theme's ink, no outline.
pub fn blockFill(theme: *const Theme) Hsla {
    return theme.wash(0.045);
}

pub fn rowDivider(theme: *const Theme) Hsla {
    return theme.border.opacity(0.6);
}

/// A filled, rounded block of settings rows (24px top margin standalone).
pub fn sectionCard(theme: *const Theme) Div {
    return div().mt(px(24)).rounded(px(12)).bg(blockFill(theme)).overflowHidden().flex().flexCol();
}

/// One row in a section card: text left, control right, hairline above
/// (inset to the text edge) except on the first row.
pub fn cardRow(theme: *const Theme, first: bool) Div {
    var d = div().mx(px(16)).py(px(12)).minH(px(60));
    if (!first) d = d.borderT1().borderColor(rowDivider(theme));
    return d.flex().flexRow().flexWrap().itemsCenter().gap(px(16));
}

/// Bare leading glyph beside a two-line title.
pub fn rowTile(theme: *const Theme, i: Icon) Div {
    return div().flexNone().w(px(24)).h(px(32)).flex().itemsCenter().justifyCenter()
        .child(ui.icon.of(i, 16, theme.text_muted));
}

/// Row title: 13/17 medium.
pub fn rowTitle(theme: *const Theme, title: []const u8) Div {
    return div().minW0().textSize(rems(row_title_size)).lineHeight(rems(17)).fontWeight(500)
        .textColor(theme.text).child(title);
}

pub const Fragment = struct {
    text: []const u8,
    color: ?Hsla = null,
};

/// The quiet meta line under a title: 12/16 muted fragments joined by dots.
pub fn metaLine(theme: *const Theme, fragments: []const Fragment) Div {
    var line = div().mt(px(zt.layout.text_stack_gap)).minW0().maxWFull()
        .flex().flexRow().flexWrap().itemsCenter().gapX(px(8)).gapY(px(2))
        .textSize(rems(row_description_size)).lineHeight(rems(16)).textColor(theme.text_muted);
    for (fragments, 0..) |f, i| {
        if (i > 0) line = line.child(div().textColor(theme.text_muted.opacity(0.3)).child("·"));
        var frag = div().minW0().maxWFull().child(f.text);
        if (f.color) |c| frag = frag.textColor(c);
        line = line.child(frag);
    }
    return line;
}

/// Title (+ optional meta line) column that grows to fill the row.
pub fn textBlock(theme: *const Theme, title: []const u8, meta: []const Fragment) Div {
    var d = div().flex1().minW(px(160)).flex().flexCol().child(rowTitle(theme, title));
    if (meta.len > 0) d = d.child(metaLine(theme, meta));
    return d;
}

/// Right-anchored badge pill (filled wash).
pub fn badge(theme: *const Theme, label: []const u8) Div {
    return div().flexNone().px(px(8)).py(px(2)).roundedFull().bg(theme.wash(0.08))
        .textSize(rems(10.5)).textColor(theme.text_muted).child(label);
}

pub const ActionTone = enum { quiet, outlined, filled, solid };

pub fn selectFill(theme: *const Theme, lifted: bool) Hsla {
    return theme.wash(if (lifted) 0.10 else 0.06);
}

/// Small settings button (32px min, radius 8, 12.5px).
pub fn actionButton(theme: *const Theme, tone: ActionTone) Div {
    const b = div().flex().flexRow().itemsCenter().gap(px(6)).rounded(px(8))
        .minH(px(32)).px(px(10)).py(px(5)).textSize(rems(12.5)).cursorPointer();
    return switch (tone) {
        .quiet => b.textColor(theme.text_muted).hover(sb.bg(theme.glassHover()).textColor(theme.text)),
        .outlined => b.bg(theme.inputGlassBg()).border1().borderColor(theme.border).textColor(theme.text)
            .hover(sb.bg(theme.glassHover()).borderColor(theme.border_strong)),
        .filled => b.bg(selectFill(theme, false)).textColor(theme.text).hover(sb.bg(selectFill(theme, true))),
        .solid => b.bg(theme.solid).fontWeight(500).textColor(theme.on_solid).hover(sb.opacity(0.9)),
    };
}

pub fn textAction(theme: *const Theme, tone: ActionTone, label: []const u8) Div {
    return actionButton(theme, tone).child(label);
}

/// Red tinted notice strip.
pub fn errorStrip(theme: *const Theme, message: []const u8) Div {
    const red = theme.danger;
    const text = theme.danger_muted.opacity(0.9);
    return div().mt(px(16)).px(px(16)).py(px(12)).rounded(px(12))
        .border1().borderColor(red.opacity(0.2)).bg(red.opacity(0.06))
        .textSize(rems(12.5)).textColor(text)
        .flex().flexRow().itemsStart().gap(px(8))
        .child(div().flexNone().mt(px(2)).child(ui.icon.of(.danger_triangle, 16, text)))
        .child(div().minW0().child(message));
}

// ---------------------------------------------------------------------------
// Switch
// ---------------------------------------------------------------------------

pub const switch_width: f32 = 44.8;
pub const switch_height: f32 = 28.8;
const track_height: f32 = 20.8;
const side_inset: f32 = 1.6;
const thumb_width: f32 = 24.0;
const thumb_height: f32 = track_height - 2.0 * side_inset;
const mark_size: f32 = 7.2;

fn white(a: f32) Hsla {
    return zpui.hsla(0, 0, 1, a);
}
fn black(a: f32) Hsla {
    return zpui.hsla(0, 0, 0, a);
}

fn trackColor(theme: *const Theme, on: bool) Hsla {
    const dark = theme.appearance.isDark();
    if (on) {
        if (dark) return flatten(black(0.14), theme.accent_strong);
        const a = theme.accent;
        return flatten(zpui.hsla(a.h, a.s, a.l + (1.0 - a.l) * 0.10, 0.98), theme.surface);
    }
    const frost = theme.isFrost();
    const op: f32 = if (dark) (if (frost) 0.22 else 0.18) else (if (frost) 0.12 else 0.10);
    return flatten(theme.ink(op), theme.surface);
}

fn thumbColor(theme: *const Theme) Hsla {
    const w: f32 = if (theme.isFrost()) (if (theme.appearance.isDark()) 0.94 else 0.96) else (if (theme.appearance.isDark()) 0.96 else 1.0);
    return flatten(white(w), theme.surface);
}

fn tones(theme: *const Theme, base: Hsla, thumb: bool) [2]Hsla {
    if (!theme.isFrost()) return .{ base, base };
    const light: f32 = if (thumb) 0.12 else 0.07;
    const shade: f32 = if (thumb) 0.07 else 0.09;
    return .{ flatten(white(light), base), flatten(black(shade), base) };
}

fn mixColor(a: Hsla, b: Hsla, t: f32) Hsla {
    return zt.colorspace.mix(a, b, t);
}

/// The pill switch at thumb `position` (0 off … 1 on): on/off marks nested
/// beneath a sliding thumb (`SwitchVisual`).
pub fn switchVisual(theme: *const Theme, position: f32) Div {
    const on = position > 0.5;
    const track = trackColor(theme, on);
    const tt = tones(theme, track, false);
    const thumb = thumbColor(theme);
    const th = tones(theme, thumb, true);
    const empty_width = switch_width - thumb_width - side_inset;
    const mark_padding = (empty_width - mark_size) / 2.0;
    const thumb_left = side_inset + (switch_width - thumb_width - 2.0 * side_inset) * position;
    const stop = zpui.color.linearColorStop;
    const rim = if (on) flatten(white(if (theme.isFrost()) 0.16 else 0.12), track) else flatten(theme.border, track);
    const track_el = div().absolute().top(px((switch_height - track_height) / 2)).left(px(0))
        .w(px(switch_width)).h(px(track_height)).roundedFull()
        .bg(zpui.color.linearGradient(180, stop(tt[0], 0), stop(tt[1], 1)))
        .border1().borderColor(rim)
        .child(div().absolute().inset0().px(px(mark_padding)).flex().itemsCenter().justifyBetween()
        .child(div().size(px(mark_size)).flex().itemsCenter().justifyCenter().opacity(position)
            .child(div().w(px(1.2)).h(px(7.2)).roundedFull().bg(white(0.96))))
        .child(div().size(px(mark_size)).flex().itemsCenter().justifyCenter().opacity(1 - position)
            .child(div().size(px(6.4)).roundedFull().border1().borderColor(white(0.92)))));
    var thumb_el = div().absolute().top(px((switch_height - thumb_height) / 2)).left(px(thumb_left))
        .w(px(thumb_width)).h(px(thumb_height)).roundedFull()
        .bg(zpui.color.linearGradient(180, stop(th[0], 0), stop(th[1], 1)))
        .border1().borderColor(flatten(black(if (theme.appearance.isDark()) 0.10 else 0.08), thumb));
    if (theme.isFrost() and position > 0.001) thumb_el = thumb_el.child(div().absolute().top(px(1.6)).left(px(7.2))
        .w(px(9.6)).h(px(1)).opacity(position).roundedFull().bg(flatten(white(0.45), th[0])));
    return div().relative().flexNone().w(px(switch_width)).h(px(switch_height)).child(track_el).child(thumb_el);
}

/// Why a dimmed switch does nothing (its accessible help / tooltip).
pub const unavailable_help = "Unavailable while its parent setting is off";

/// The settings switch on macOS: a mini NSSwitch (like System Settings), disabled
/// when not `enabled`; `fallback` (the drawn switch) everywhere else.
pub fn nativeSwitch(id: anytype, on: bool, enabled: bool, label: []const u8, listener: anytype, fallback: anytype) zpui.native_control.NativeControl {
    return zpui.nativeSwitch(id, .{ .on = on, .enabled = enabled, .label = label, .help = if (enabled) "" else unavailable_help, .size = .mini }, listener, fallback);
}

// ---------------------------------------------------------------------------
// Select
// ---------------------------------------------------------------------------

/// Leading glyph of a select option / trigger (no closures: a tagged value).
pub const Leading = union(enum) {
    none,
    /// Theme palette preview: surface | bg | accent thirds.
    palette: struct { surface: Hsla, bg: Hsla, accent: Hsla, border: Hsla },
    icon: struct { icon: Icon, color: Hsla },

    pub fn element(self: Leading) ?Div {
        return switch (self) {
            .none => null,
            .palette => |p| palettePreview(p.surface, p.bg, p.accent, p.border),
            .icon => |i| div().flexNone().child(ui.icon.of(i.icon, 16, i.color)),
        };
    }
};

/// 30×18 theme swatch (`palette_preview`).
pub fn palettePreview(surface: Hsla, bg: Hsla, accent: Hsla, border: Hsla) Div {
    return div().flexNone().w(px(30)).h(px(18)).rounded(px(5)).overflowHidden()
        .border1().borderColor(border).flex()
        .child(div().w1_3().hFull().bg(surface))
        .child(div().w1_3().hFull().bg(bg))
        .child(div().w1_3().hFull().bg(accent));
}

pub fn paletteOf(t: *const Theme) Leading {
    return .{ .palette = .{ .surface = t.surface, .bg = t.bg, .accent = t.accent, .border = t.border } };
}

/// The trigger body (32px, radius 8, 12.5px, wash fill).
pub fn selectTrigger(theme: *const Theme, fill: Hsla) Div {
    return div().relative().flexNone().maxWFull().h(px(select_height)).pl(px(10)).pr(px(8)).rounded(px(8))
        .border1().borderColor(zpui.hsla(0, 0, 0, 0)).bg(fill)
        .flex().flexRow().itemsCenter().gap(px(8)).cursorPointer()
        .textSize(rems(12.5)).textColor(theme.text);
}

pub fn selectChevron(theme: *const Theme, open: bool) zpui.elements.Svg {
    return ui.icon.of(.alt_arrow_down, 14, if (open) theme.text else theme.text_muted);
}

pub fn selectCheck(theme: *const Theme, selected: bool) Div {
    var d = div().w(px(18)).flexNone().flex().justifyEnd();
    if (selected) d = d.child(ui.icon.of(.check, 14, theme.accent));
    return d;
}

/// Uppercase menu heading with hair-space tracking (`menu_heading`).
pub fn menuHeading(theme: *const Theme, label: []const u8) Div {
    var buf: std.ArrayList(u8) = .empty;
    const a = zpui.window.arena_mod.frameAllocator();
    for (label, 0..) |c, i| {
        if (i > 0) buf.appendSlice(a, "\u{200A}") catch {};
        buf.append(a, std.ascii.toUpper(c)) catch {};
    }
    return div().px(px(8)).pb(px(4)).pt(px(6)).textSize(rems(10)).fontWeight(500)
        .textColor(theme.forPopup().text_muted).child(buf.items);
}

// ---------------------------------------------------------------------------
// Option card (color scheme picker)
// ---------------------------------------------------------------------------

/// A fixed-height preview frame with a quiet selected edge and a caption.
pub fn optionCard(theme: *const Theme, i: Icon, label: []const u8, selected: bool, t: f32, preview: anytype) Div {
    const color = mixColor(theme.text_muted, theme.accent, t);
    return div().flex1().minW0().flex().flexCol().itemsCenter().gap(px(8)).cursorPointer()
        .child(div().h(px(option_card_height)).flexNone().wFull().rounded(px(option_card_radius)).overflowHidden()
        .border1().borderColor(mixColor(theme.border, theme.accent, t)).child(preview))
        .child(div().flex().itemsCenter().gap(px(6)).textSize(rems(13))
        .fontWeight(if (selected) 500 else 400).textColor(color)
        .child(ui.icon.of(i, 16, color)).child(label));
}

pub fn mix(a: Hsla, b: Hsla, t: f32) Hsla {
    return mixColor(a, b, t);
}
