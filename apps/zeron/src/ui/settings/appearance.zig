//! Settings → Appearance (zeron `settings/appearance.rs`): color scheme
//! cards (System split / Light / Dark miniatures), light + dark theme
//! dropdowns over the 30 built-in variants, accent swatches, wallpaper
//! colors; glass, new-thread background, wallpaper folder; motion; theme
//! library; fonts and the conversation-width slider. Every change re-themes
//! the whole app immediately (`store.applyTheme`).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const store = @import("store.zig");
const w = @import("widgets.zig");
const select = @import("select.zig");
const view_mod = @import("view.zig");

const SettingsView = view_mod.SettingsView;
const Theme = ui.Theme;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const rems = ui.rems;
const Hsla = zpui.Hsla;
const AppearanceMode = zt.settings.AppearanceMode;
const UiSettings = model.UiSettings;

const Corners = enum { all, left, right };

fn bar(fraction: f32, tone: Hsla) zpui.Div {
    return div().h(px(5)).w(zpui.relative(fraction)).rounded(px(3)).bg(tone);
}

/// A tiny shell: sidebar lines + an inset card of lines (`miniature`).
fn miniature(t: *const Theme, corners: Corners) zpui.Div {
    const line = t.text.opacity(0.22);
    const strong = t.text.opacity(0.34);
    const r = px(w.option_card_radius);
    var root = div().sizeFull().flex().flexRow().bg(t.surface);
    root = switch (corners) {
        .all => root.rounded(r),
        .left => root.roundedTl(r).roundedBl(r),
        .right => root.roundedTr(r).roundedBr(r),
    };
    return root
        .child(div().w(px(44)).hFull().flexNone().overflowHidden().flex().flexCol().gap(px(7)).px(px(8)).pt(px(14))
        .child(bar(0.70, strong)).child(bar(1.0, line)).child(bar(0.85, line)).child(bar(1.0, line)))
        .child(div().flex1().minW0().my(px(8)).mr(px(8)).rounded(px(6)).border1().borderColor(t.border).bg(t.bg)
        .overflowHidden().flex().flexCol().gap(px(7)).p(px(10))
        .child(bar(0.62, strong)).child(bar(0.88, line)).child(bar(0.76, line)).child(bar(0.52, line)));
}

fn themeFor(s: *const UiSettings, appearance: zt.Appearance) *Theme {
    const t = zpui.window.arena_mod.current().create(Theme, store.themeFor(s, appearance));
    return @constCast(t);
}

fn preview(mode: AppearanceMode, s: *const UiSettings) zpui.Div {
    return switch (mode) {
        .system => div().sizeFull().flex().flexRow()
            .child(div().w1_2().hFull().overflowHidden().child(miniature(themeFor(s, .light), .left)))
            .child(div().w1_2().hFull().overflowHidden().child(miniature(themeFor(s, .dark), .right))),
        .light => miniature(themeFor(s, .light), .all),
        .dark => miniature(themeFor(s, .dark), .all),
    };
}

fn modeIcon(mode: AppearanceMode) ui.icon.Icon {
    return switch (mode) {
        .system => .monitor,
        .light => .sun,
        .dark => .moon,
    };
}

fn accentLabel(sel: zt.AccentSelection) []const u8 {
    return switch (sel) {
        .theme_default => "Theme default",
        .preset => |p| p.label(),
    };
}

fn accentSwatch(page: *const Theme, sel: zt.AccentSelection, selected: bool) zpui.Div {
    const sw = zpui.window.arena_mod.current().create(Theme, zt.Theme.forSelection(&zt.registry.builtin, .{
        .appearance = page.appearance,
        .variant_id = page.variant_id,
        .accent = sel,
        .surface = page.surface_preference,
    }));
    const sample = switch (sel) {
        .theme_default => div().sizeFull().rounded(px(6)).bg(sw.accent_wash).flex().itemsCenter().justifyCenter().gap(px(2))
            .child(div().w(px(4)).h(px(13)).rounded(px(2)).bg(sw.glyph.light))
            .child(div().w(px(4)).h(px(16)).rounded(px(2)).bg(sw.glyph.mid))
            .child(div().w(px(4)).h(px(11)).rounded(px(2)).bg(sw.glyph.deep)),
        .preset => div().sizeFull().rounded(px(6)).bg(sw.accent),
    };
    return div().flexNone().w(px(30)).h(px(34)).pb(px(4)).borderB2()
        .borderColor(if (selected) sw.accent else zpui.hsla(0, 0, 0, 0)).cursorPointer()
        .child(div().size(px(30)).p(px(2)).rounded(px(8)).border1()
        .borderColor(if (selected) page.border_strong else page.border)
        .bg(page.surface_raised.opacity(0.42)).child(sample));
}

fn surfaceHelper(s: zt.SurfacePreference, resolved: zt.SurfaceTreatment) []const u8 {
    return switch (s) {
        .theme_default => if (resolved == .frosted) "Theme default: frosted" else "Theme default: opaque",
        .frosted => "Translucent surfaces",
        .opaque_ => "Solid surfaces",
        .liquid => "Native macOS Liquid Glass", // [liquid-glass]
    };
}

fn reduceMotionHelper(pref: zt.motion.ReduceMotion) []const u8 {
    return switch (pref) {
        .system => "Following the system, which currently allows motion.",
        .on => "Animations skip straight to their final state.",
        .off => "Animations play even if the system asks for less motion.",
    };
}

fn compactAction(t: *const Theme, label: []const u8, id: []const u8) zpui.StatefulDiv {
    return w.textAction(t, .outlined, label).id(id);
}

pub fn render(v: *SettingsView, t: *const Theme, window: *zpui.Window, cx: *Context(SettingsView)) zpui.Div {
    _ = window;
    const s = store.current(cx);
    const ts = s.theme;

    // Color scheme cards.
    var cards = div().flex().flexRow().itemsStart().gap(px(16)).wFull();
    for ([_]AppearanceMode{ .system, .light, .dark }) |mode| {
        const selected = mode == ts.appearance;
        const sel_t = v.travel(cx, 0x30000 | @as(u32, @intFromEnum(mode)), if (selected) 1 else 0, 150);
        cards = cards.child(w.optionCard(t, modeIcon(mode), mode.label(), selected, sel_t, preview(mode, s))
            .id(.{ "appearance-mode", @intFromEnum(mode) })
            .onClick(cx.listenerWith(mode, onMode)));
    }

    // Accent swatches.
    var swatches = div().maxWFull().flex().flexWrap().itemsCenter().gap(px(8));
    {
        const choice: zt.AccentSelection = .theme_default;
        swatches = swatches.child(accentSwatch(t, choice, ts.accent == .theme_default).id("accent-default")
            .onClick(cx.listenerWith(@as(u8, 255), onAccent)));
    }
    for (zt.AccentPreset.all, 0..) |p, i| {
        const choice: zt.AccentSelection = .{ .preset = p };
        swatches = swatches.child(accentSwatch(t, choice, ts.accent.eql(choice)).id(.{ "accent", i })
            .onClick(cx.listenerWith(@as(u8, @intCast(i)), onAccent)));
    }

    const color_rows = w.sectionCard(t).mt(px(16))
        .child(w.cardRow(t, true).child(div().flex1().minW(px(160)).child(w.rowTitle(t, "Light theme")))
        .child(select.render(v, .light_theme, t, cx)))
        .child(w.cardRow(t, false).child(div().flex1().minW(px(160)).child(w.rowTitle(t, "Dark theme")))
        .child(select.render(v, .dark_theme, t, cx)))
        .child(w.cardRow(t, false)
        .child(w.textBlock(t, "Accent color", &.{.{ .text = if (ts.wallpaper_theme_colors) "Wallpaper colors are enabled; this accent is used when they are off." else accentLabel(ts.accent) }}))
        .child(swatches))
        .child(w.cardRow(t, false)
        .child(w.textBlock(t, "Match wallpaper colors", &.{.{ .text = "Use wallpaper colors for accents, highlights, and subtle surface tints." }}).minW0())
        .child(v.toggle(.match_wallpaper, ts.wallpaper_theme_colors, true, t, cx)));

    // Material and background.
    const folder_label = s.wallpaperFolder orelse "Choose a folder of wallpaper images.";
    var combo_buf: [64]u8 = undefined;
    const shortcut = model.settings.displayCombo(&combo_buf, s.keymap.randomWallpaper);
    const background_meta = if (s.newThreadComposerBackground) |b| b.name else "No image selected";
    const material = w.sectionCard(t).mt0()
        .child(w.cardRow(t, true)
        .child(w.textBlock(t, "Glass", &.{.{ .text = if (ts.surface == .liquid and !store.liquidSupported(cx)) "Liquid Glass needs macOS 26; showing frosted" else surfaceHelper(ts.surface, t.surface_treatment) }}))
        .child(select.render(v, .surface, t, cx)))
        .child(w.cardRow(t, false)
        .child(w.textBlock(t, "New thread background", &.{.{ .text = background_meta }}))
        .child(div().maxWFull().flex().flexWrap().itemsCenter().gap(px(8))
        .child(compactAction(t, "Choose image", "new-thread-background-choose"))))
        .child(w.cardRow(t, false)
        .child(w.textBlock(t, "Wallpaper folder", &.{.{ .text = zpui.fmt("{s} · {s} picks a random image", .{ folder_label, shortcut }) }}))
        .child(div().flex().gap(px(8)).child(compactAction(t, "Choose folder", "wallpaper-folder-choose"))));

    const motion = w.sectionCard(t).mt0()
        .child(w.cardRow(t, true)
        .child(w.textBlock(t, "Reduce motion", &.{.{ .text = reduceMotionHelper(ts.reduce_motion) }}))
        .child(select.render(v, .reduce_motion, t, cx)))
        .child(w.cardRow(t, false)
        .child(w.textBlock(t, "Pause animations in background", &.{.{ .text = "Hold animations still while Zeron isn't the focused window." }}).minW0())
        .child(v.toggle(.pause_animations, ts.pause_animations_in_background, true, t, cx)));

    const library = w.sectionCard(t).mt(px(32))
        .child(w.cardRow(t, true).child(div().flex1().minW(px(160)).child(w.rowTitle(t, "Theme library")))
        .child(w.textAction(t, .solid, "Add theme").id("theme-library-add")));

    var fonts = w.sectionCard(t).mt0().fontFamily(t.font_sans_fixed);
    const kinds = [_]struct { []const u8, []const u8, select.SelectId, select.SelectId }{
        .{ "Interface font", "Menus and conversations", .ui_font, .ui_size },
        .{ "Terminal font", "Terminal output · monospace only", .terminal_font, .terminal_size },
        .{ "Code & diff font", "Code, diffs, and files", .code_font, .code_size },
    };
    for (kinds, 0..) |k, i| {
        fonts = fonts.child(w.cardRow(t, i == 0).justifyBetween()
            .child(w.textBlock(t, k[0], &.{.{ .text = k[1] }}))
            .child(div().flexNone().maxWFull().flex().flexRow().flexWrap().itemsCenter().gap(px(8))
            .child(select.render(v, k[2], t, cx)).child(select.render(v, k[3], t, cx))));
    }
    fonts = fonts.child(widthRow(v, t, s, cx));

    return w.pageColumn()
        .child(w.pageHeader(t, "Appearance", null))
        .child(w.section(t, "Color scheme", cards).mt(px(24)).gap(px(12)))
        .child(color_rows)
        .child(w.section(t, "Material and background", material))
        .child(w.section(t, "Motion", motion))
        .child(library)
        .child(w.section(t, "Fonts and layout", fonts));
}

/// Conversation width: a 240px slider with value/reset and range labels
/// that appear on hover or drag.
fn widthRow(v: *SettingsView, t: *const Theme, s: *const UiSettings, cx: *Context(SettingsView)) zpui.Div {
    const lay = zt.layout;
    const width = s.transcriptWidthOr();
    const fraction = std.math.clamp((width - lay.transcript_width_min) / (lay.transcript_width_max - lay.transcript_width_min), 0, 1);
    const details = v.width_hovered or v.width_pressed;
    const slider = div().id("transcript-width-slider").relative().w(px(240)).h(px(28)).cursorPointer()
        .onMouseDown(.left, cx.listener(SettingsView.onWidthDown))
        .child(zpui.canvas(v, recordBounds).absolute().sizeFull())
        .child(div().absolute().left(px(7)).right(px(7)).top(px(12)).h(px(4)).roundedFull().bg(t.border)
        .child(div().hFull().w(zpui.relative(fraction)).roundedFull().bg(t.accent))
        .child(div().absolute().left(zpui.relative(fraction)).ml(px(-7)).top(px(-5)).size(px(14)).roundedFull().bg(t.accent)));
    var value_row = div().flex().justifyBetween().textSize(rems(12)).lineHeight(px(16))
        .child(zpui.fmt("{d:.0} px", .{width}))
        .child(div().id("reset-transcript-width").cursorPointer().textColor(t.text_muted)
        .hover(sb.textColor(t.text)).onClick(cx.listener(SettingsView.onWidthReset)).child("Reset"));
    var range_row = div().flex().justifyBetween().textSize(rems(11)).lineHeight(px(14)).textColor(t.text_muted)
        .child("560 px").child("1,200 px");
    if (!details) {
        value_row = value_row.invisible();
        range_row = range_row.invisible();
    }
    return w.cardRow(t, false).gap(px(20))
        .child(w.textBlock(t, "Conversation width", &.{.{ .text = "Maximum width for messages and the composer." }}).minW(px(200)))
        .child(div().id("transcript-width-control").onHover(cx.listener(SettingsView.onWidthHover))
        .my(px(-12)).flexNone().flex().flexCol().gap(px(4))
        .child(value_row).child(slider).child(range_row));
}

fn recordBounds(v: *SettingsView, bounds: zpui.Bounds(f32), _: *zpui.Window, _: *zpui.App) void {
    v.width_bounds = bounds;
}

fn onMode(_: *SettingsView, mode: AppearanceMode, _: *const zpui.ClickEvent, _: *zpui.Window, cx: *Context(SettingsView)) void {
    const Set = struct {
        fn f(m: AppearanceMode, s: *UiSettings, _: std.mem.Allocator) void {
            s.theme.appearance = m;
        }
    };
    store.update(cx, .debounced, mode, Set.f);
    store.applyTheme(cx.app);
    cx.notify();
}

fn onAccent(_: *SettingsView, ix: u8, _: *const zpui.ClickEvent, _: *zpui.Window, cx: *Context(SettingsView)) void {
    const sel: zt.AccentSelection = if (ix == 255) .theme_default else .{ .preset = zt.AccentPreset.all[ix] };
    const Set = struct {
        fn f(a: zt.AccentSelection, s: *UiSettings, _: std.mem.Allocator) void {
            s.theme.accent = a;
        }
    };
    store.update(cx, .debounced, sel, Set.f);
    store.applyTheme(cx.app);
    cx.notify();
}
