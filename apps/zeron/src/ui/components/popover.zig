//! Floating-menu chrome (zeron `popover.rs`): the frosted card, menu rows,
//! headings, separators, kbd hints and the anchored/deferred mount helpers.
//!
//! ```zig
//! const card = popover.card(theme).w(px(240)).child(popover.heading(theme, "Actions"))
//!     .child(popover.menuRow(theme, false).id("new").role(.menu_item).onClick(...).child(icon.of(.plus, 16, muted)).child("New chat"));
//! // Mounted from the trigger (relative) while open:
//! trigger.child(popover.anchoredAbove(card))      // opens upward, left-aligned
//! trigger.child(popover.anchoredBelow(card))      // dropdown
//! ```
//!
//! `card` is radius 12 with a 4px inset; rows have radius 7 (concentric), a
//! 10px gap and 8×6 padding. On frosted themes the card is wrapped in a 16px
//! backdrop blur and has no shadow; opaque themes get `shadow_lg`.
//!
//! **Native look** (macOS with Settings → Appearance → Native menus on,
//! `nativeLook()`): the menus that stay custom (pickers, palette, ...) take
//! NSMenu's metrics instead — 13 pt system font, 24 px rows with 10 px side
//! padding inside a 5 px card inset, the macOS 26 menu radius (12, rows 7
//! concentric), an inset rounded accent selection with white text, inset
//! hairline separators, plain-text shortcut hints, NSMenu's soft shadow on
//! every surface (glass via `frostedCard` when Liquid Glass is on), and NSMenu
//! timing: no entrance animation, a short in-place fade out. Linux (and the
//! option off) keeps the look above. `native` holds the numbers.

const std = @import("std");
const zpui = @import("zpui");
const theme_mod = @import("theme.zig");
const effects = @import("effects.zig");
const anim = @import("anim.zig");
const motion = @import("zeron_theme").motion;

const native_menus = @import("zeron_model").native_menus;

const Theme = theme_mod.Theme;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;

pub const card_radius: f32 = 12;
pub const card_inset: f32 = 4;
pub const menu_gap: f32 = 2;
pub const menu_item_radius: f32 = card_radius - 1 - card_inset;
pub const palette_item_radius: f32 = 14 - card_inset;

/// NSMenu metrics (macOS 26) for the native look.
pub const native = struct {
    pub const font_family = ".SystemUIFont";
    pub const font_size: f32 = 13;
    pub const card_radius: f32 = 12;
    /// Card padding around the rows (the selection's inset from the edge).
    pub const card_inset: f32 = 5;
    pub const row_height: f32 = 24;
    pub const row_padding_x: f32 = 10;
    pub const row_radius: f32 = native.card_radius - native.card_inset;
    pub const icon_gap: f32 = 6;
    pub const separator_inset_x: f32 = 10;
    pub const separator_margin_y: f32 = 5;
    pub const heading_size: f32 = 11;
    /// Fade-out when a menu closes (NSMenu dismisses in place, it does not travel).
    pub const exit_travel: f32 = 0;
    /// The selection text / icon color.
    pub const selected_text: zpui.Hsla = zpui.hsla(0, 0, 1, 1);

    /// NSMenu's window shadow: a wide soft drop plus a tight contact shadow.
    pub const shadow = [_]zpui.BoxShadow{
        .{ .color = zpui.hsla(0, 0, 0, 0.22), .offset = .{ .x = 0, .y = 8 }, .blur_radius = 24 },
        .{ .color = zpui.hsla(0, 0, 0, 0.12), .offset = .{ .x = 0, .y = 1 }, .blur_radius = 3 },
    };
};

/// The native look is on (macOS + Settings → Appearance → Native menus).
pub fn nativeLook() bool {
    return native_menus.look();
}

/// The card's corner radius in the current look.
pub fn cardRadius() f32 {
    return if (nativeLook()) native.card_radius else card_radius;
}

/// The card's padding around its rows in the current look.
pub fn cardInset() f32 {
    return if (nativeLook()) native.card_inset else card_inset;
}

/// A menu row's corner radius in the current look.
pub fn rowRadius() f32 {
    return if (nativeLook()) native.row_radius else menu_item_radius;
}

/// The native selection fill: the accent.
pub fn nativeSelectionBg(theme: *const Theme) zpui.Hsla {
    return theme.accent;
}

/// `popover::surface_bg`.
pub fn surfaceBg(theme: *const Theme) zpui.Hsla {
    if (theme.isFrost()) {
        return theme.onGlass(if (theme.appearance.isDark()) theme.composerSidebarTint() else theme.glassOverlay()); // [liquid-glass] onGlass
    }
    return theme.inputGlassBg();
}

/// The card body (callers add width / children). Pass `theme.forPopup()`
/// for the text hierarchy of floating surfaces.
pub fn card(theme: *const Theme) zpui.Div {
    if (nativeLook()) return div()
        .border1().borderColor(theme.onGlassBorder(theme.border)) // [liquid-glass] onGlassBorder
        .rounded(px(native.card_radius))
        .bg(surfaceBg(theme))
        .p(px(native.card_inset)).gap(px(0))
        .flex().flexCol()
        .overflowHidden()
        .fontFamily(native.font_family)
        .textSize(px(native.font_size)).textColor(theme.text)
        .shadow(&native.shadow);
    var d = div()
        .border1().borderColor(theme.onGlassBorder(theme.border)) // [liquid-glass] onGlassBorder
        .rounded(px(card_radius))
        .bg(surfaceBg(theme))
        .p(px(card_inset)).gap(px(menu_gap))
        .flex().flexCol()
        .overflowHidden()
        .fontFamily(theme.font_sans)
        .textSize(theme_mod.rems(13)).textColor(theme.text);
    if (!theme.isFrost()) d = d.shadowLg();
    return d;
}

/// The card wrapped in its backdrop blur (what a mount helper paints).
pub fn frostedCard(c: anytype) effects.Frosted {
    return effects.frosted(cardRadius(), theme_mod.layout.menu_blur, c);
}

/// A menu row: 13px, text @0.9 → text on hover, hover wash `card_selected_bg`.
/// Add `.id(...)` + `.onClick(...)` and children (icon 16, label).
pub fn menuRow(theme: *const Theme, active: bool) zpui.Div {
    if (nativeLook()) {
        // NSMenu: 24 px rows, the selection an inset accent capsule with white text.
        const r = div()
            .flex().flexRow().itemsCenter().gap(px(native.icon_gap))
            .minH(px(native.row_height)).px(px(native.row_padding_x)).py(px(2))
            .rounded(px(native.row_radius))
            .textSize(px(native.font_size))
            .cursorDefault();
        if (active) return r.bg(nativeSelectionBg(theme)).textColor(native.selected_text);
        return r.textColor(theme.text)
            .hover(sb.bg(nativeSelectionBg(theme)).textColor(native.selected_text));
    }
    const row = div()
        .flex().flexRow().itemsCenter().gap(px(10))
        .px(px(8)).py(px(6))
        .rounded(px(menu_item_radius))
        .textSize(theme_mod.rems(13))
        .cursorPointer();
    if (active) return row.bg(theme_mod.cardSelectedBg(theme)).textColor(theme.text);
    return row.textColor(theme.text.opacity(0.9))
        .hover(sb.bg(theme_mod.cardSelectedBg(theme)).textColor(theme.text));
}

/// Small uppercase heading (`MenuHeading`): 10px medium muted.
pub fn heading(theme: *const Theme, upper_label: []const u8) zpui.Div {
    if (nativeLook()) return div().px(px(native.row_padding_x)).pb(px(2)).pt(px(5))
        .textSize(px(native.heading_size)).fontWeight(600)
        .textColor(theme.text_muted)
        .child(upper_label);
    return div().px(px(8)).pb(px(4)).pt(px(6))
        .textSize(theme_mod.rems(10)).fontWeight(500)
        .textColor(theme.text_muted)
        .child(upper_label);
}

/// Full-bleed hairline between menu sections.
pub fn separator(theme: *const Theme) zpui.Div {
    // NSMenu: an inset hairline with room above and below.
    if (nativeLook()) return div().h(px(1)).mx(px(native.separator_inset_x - native.card_inset)).my(px(native.separator_margin_y))
        .bg(theme_mod.ink(theme, 0.1));
    return div().h(px(1)).mx(px(-card_inset)).my(px(2)).bg(theme_mod.ink(theme, 0.07));
}

/// A muted kbd hint chip inside menu rows (`⌘↵`-style accelerators).
pub fn kbdHint(theme: *const Theme, label: []const u8) zpui.Div {
    // NSMenu shows key equivalents as plain secondary text.
    if (nativeLook()) return div().flexNone().pl(px(12))
        .textSize(px(native.font_size)).fontFamily(native.font_family)
        .textColor(theme.text_muted)
        .child(label);
    return div().flexNone().px(px(5)).py(px(1)).rounded(px(5))
        .bg(theme_mod.ink(theme, 0.05))
        .textSize(theme_mod.rems(10)).fontFamily(theme.font_mono)
        .textColor(theme.text_muted)
        .child(label);
}

/// zeron `Popup`'s closing phase: when the exit began (executor ns). A
/// popup owner keeps its state mounted while closing, renders the anchored
/// helpers with `exit.progress(now)`, and drops the state once `done`
/// (`reap` schedules the render that does it). Event paths treat a closing
/// popup as closed (`isClosing`); the exit layer occludes its rows.
pub const Exit = struct {
    since: ?u64 = null,

    /// `begin_close`: true when this call started the exit.
    pub fn begin(self: *Exit, now: u64) bool {
        if (self.since != null) return false;
        self.since = now;
        return true;
    }

    pub fn clear(self: *Exit) void {
        self.since = null;
    }

    pub fn isClosing(self: Exit) bool {
        return self.since != null;
    }

    /// `exit_progress`: eased MENU_OUT progress from the wall clock (never
    /// replays on remount); null while open.
    pub fn progress(self: Exit, now: u64) ?f32 {
        const since = self.since orelse return null;
        const total = motion.menu_out.totalNs(1.0);
        if (total == 0) return 1;
        const raw: f32 = @floatCast(@min(@as(f64, @floatFromInt(now -| since)) / @as(f64, @floatFromInt(total)), 1));
        return motion.menu_out.progress(raw);
    }

    /// `finish_close`: the exit ran its course; drop the popup state.
    pub fn done(self: Exit, now: u64) bool {
        const since = self.since orelse return false;
        return now -| since >= motion.menu_out.totalNs(1.0);
    }
};

/// `reap_popup`: repaint `V` once the exit span (+20 ms) has passed, so its
/// render drops the closed popup. The task is detached.
pub fn reap(comptime V: type, cx: *zpui.Context(V)) void {
    const T = struct {
        fn f(_: *V, c: *zpui.Context(V)) void {
            c.notify();
        }
    };
    var task = cx.timer(motion.menu_out.totalNs(1.0) + 20 * std.time.ns_per_ms, T.f) catch return;
    task.detach();
}

/// The app's resolved reduced-motion flag (first window), for owners
/// without a window at hand.
pub fn appReduced(app: *zpui.App) bool {
    if (app.windows.items.len == 0) return false;
    const w = app.windows.items[0] orelse return false;
    return w.prefersReducedMotion();
}

/// Close a boolean popup (`begin_close` + `reap_popup`); reduced motion
/// drops it at once.
pub fn shut(comptime V: type, open: *bool, exit: *Exit, cx: *zpui.Context(V)) void {
    if (!open.*) return;
    open.* = false;
    if (appReduced(cx.app)) {
        exit.clear();
        return;
    }
    if (exit.begin(cx.app.executor.now())) reap(V, cx);
}

/// Toggle a boolean popup (opening cancels a running exit).
pub fn toggle(comptime V: type, open: *bool, exit: *Exit, cx: *zpui.Context(V)) void {
    if (open.*) return shut(V, open, exit, cx);
    open.* = true;
    exit.clear();
}

/// Per-frame settle for a boolean popup: the exit progress to render with
/// (null while open), dropping a finished exit (`finish_close`).
pub fn settle(open: bool, exit: *Exit, now: u64) ?f32 {
    if (open) {
        exit.clear();
        return null;
    }
    if (exit.done(now)) exit.clear();
    return exit.progress(now);
}

/// `frosted_menu`: the card's blur radius rides the exit down to 0 (the
/// backdrop primitive ignores element opacity).
pub fn frostedCardExit(c: anytype, exit: ?f32) effects.Frosted {
    return effects.frosted(cardRadius(), theme_mod.layout.menu_blur * (1 - (exit orelse 0)), c);
}

const MenuOut = struct { exit: f32, toward: f32 };

fn menuOutFrame(c: MenuOut, el: zpui.Div, _: f32) zpui.Div {
    return anim.menuOutFrame(el, c.toward, c.exit);
}

/// `menu_motion_from`: MENU_IN from `from` px, or — while exiting — MENU_OUT
/// toward the trigger under a fresh id (pumping frames for the exit span)
/// with an occluding overlay so the dying rows take no clicks.
pub fn menuMotion(comptime id: []const u8, exit: ?f32, inner: zpui.Div, from: f32) zpui.AnyElement {
    const native_look = nativeLook();
    if (exit) |t| {
        const dying = inner.relative().child(div().absolute().inset0().occlude());
        // Native look: NSMenu fades out in place.
        const toward = if (native_look) native.exit_travel else from;
        return zpui.intoAnyElement(zpui.withAnimationCtx(dying, id ++ "-out", motion.menu_out.animation(), MenuOut{ .exit = t, .toward = toward }, menuOutFrame));
    }
    // Native look: NSMenu appears at once.
    if (native_look) return zpui.intoAnyElement(inner);
    return zpui.intoAnyElement(anim.menuIn(id, inner, from));
}

/// Mount `content` (a card) as a floating layer opening upward from the
/// trigger's top-left (`anchored_menu_above`); the trigger must be `relative`.
pub fn anchoredAbove(content: anytype) zpui.Div {
    return anchoredAboveExit(content, null);
}

pub fn anchoredAboveExit(content: anytype, exit: ?f32) zpui.Div {
    return div().absolute().top(px(0)).left(px(0)).child(zpui.deferred(
        zpui.anchored().anchorCorner(.bottom_left).snapToWindowWithMargin(.all(8))
            .child(menuMotion("menu-above", exit, div().occlude().pb(px(6)).child(frostedCardExit(content, exit)), 4)),
    ).withPriority(1));
}

/// Dropdown below the trigger's bottom-left (`anchored_menu_below`, 6px gap).
pub fn anchoredBelow(content: anytype) zpui.Div {
    return anchoredBelowExit(content, null);
}

pub fn anchoredBelowExit(content: anytype, exit: ?f32) zpui.Div {
    return div().absolute().top(zpui.relative(1)).left(px(0)).child(zpui.deferred(
        zpui.anchored().anchorCorner(.top_left).snapToWindowWithMargin(.all(8))
            .child(menuMotion("menu-below", exit, div().occlude().pt(px(6)).child(frostedCardExit(content, exit)), -2)),
    ).withPriority(1));
}

/// Opens to the right of the trigger, top-aligned (`anchored_menu_right`).
pub fn anchoredRight(content: anytype) zpui.Div {
    return anchoredRightExit(content, null);
}

pub fn anchoredRightExit(content: anytype, exit: ?f32) zpui.Div {
    return div().absolute().top(px(0)).left(zpui.relative(1)).child(zpui.deferred(
        zpui.anchored().anchorCorner(.top_left).snapToWindowWithMargin(.all(8))
            .child(menuMotion("menu-right", exit, div().occlude().pl(px(6)).child(frostedCardExit(content, exit)), -2)),
    ).withPriority(1));
}

/// Floating layer at an absolute window `position` (context menus, `menu_at`).
pub fn anchoredAt(position: zpui.Point(f32), content: anytype) zpui.AnyElement {
    return anchoredAtExit(position, content, null);
}

pub fn anchoredAtExit(position: zpui.Point(f32), content: anytype, exit: ?f32) zpui.AnyElement {
    return zpui.intoAnyElement(zpui.deferred(
        zpui.anchored().position(position).snapToWindowWithMargin(.all(8))
            .child(menuMotion("menu-at", exit, div().occlude().child(frostedCardExit(content, exit)), -2)),
    ).withPriority(1));
}
