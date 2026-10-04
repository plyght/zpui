//! The unified 38px titlebar (zeron `render_titlebar_cluster`,
//! `render_session_title_bar`, `titlebar_drag_region`, Linux caption
//! buttons and CSD resize strips).
//!
//! Geometry (logical px): the control cluster starts at x=88 on macOS
//! (traffic lights at 14,14), x=10 elsewhere; 24px buttons, 8px group gap,
//! 2px control gap, 4px top pad so controls center at y=21. The session
//! identity starts at max(sidebar + 16, cluster end + 12 [+ 32 when the `+`
//! shows]).

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const shell_mod = @import("shell.zig");
const prefs_mod = @import("prefs.zig");

const Shell = shell_mod.Shell;
const Window = zpui.Window;
const Context = zpui.Context;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = ui.Theme;
const layout = zt.layout;
const button = ui.button;

const is_mac = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

const cluster_pad: f32 = 10;
pub const cluster_buttons_width: f32 = 24.0 * 3.0 + layout.titlebar_group_gap + layout.titlebar_control_gap;
const action_slot_width: f32 = layout.titlebar_group_gap + 24.0;
const panel_toggle_gap: f32 = 4;
const panel_toggle_slots: f32 = 28.0 * 2.0 + panel_toggle_gap;

pub fn clusterStart() f32 {
    return if (is_mac) 88 else 10;
}

pub fn contentStart() f32 {
    return clusterStart() + cluster_buttons_width + layout.titlebar_identity_gap;
}

fn rightPad(shell: *const Shell) f32 {
    const captions = shell.linuxCaptions();
    const base = layout.titlebar_action_edge_inset;
    if (captions == 0) return base;
    return base + 10 + @as(f32, @floatFromInt(captions)) * 24 + @as(f32, @floatFromInt(captions - 1)) * 2;
}

// ---- drag strip -------------------------------------------------------------------

fn onStripDown(_: *Shell, _: *const zpui.input.MouseDownEvent, _: *Window, _: *Context(Shell)) void {
    drag_armed = true;
}

fn onStripUp(_: *Shell, _: *const zpui.input.MouseUpEvent, _: *Window, _: *Context(Shell)) void {
    drag_armed = false;
}

fn onStripMove(_: *Shell, ev: *const zpui.input.MouseMoveEvent, window: *Window, _: *Context(Shell)) void {
    if (drag_armed and ev.pressed_button == .left) {
        drag_armed = false;
        window.startWindowMove();
    }
}

fn onStripClick(_: *Shell, ev: *const zpui.ClickEvent, window: *Window, _: *Context(Shell)) void {
    if (ev.clickCount() == 2) window.zoomWindow();
}

/// Armed by a press on empty titlebar space; consumed by the next move.
var drag_armed: bool = false;

/// Make `el` a window-drag strip (double-click zooms).
fn dragRegion(id: []const u8, el: zpui.Div, cx: *Context(Shell)) zpui.StatefulDiv {
    return el.id(id)
        .onMouseDown(.left, cx.listener(onStripDown))
        .onMouseUp(.left, cx.listener(onStripUp))
        .onMouseMove(cx.listener(onStripMove))
        .onClick(cx.listener(onStripClick));
}

/// A plain full-width drag strip (gate pages).
pub fn dragStrip(_: *Shell, id: []const u8, cx: *Context(Shell)) zpui.StatefulDiv {
    return dragRegion(id, div().absolute().top(px(0)).left(px(0)).right(px(0)).h(px(layout.titlebar_height)), cx);
}

// ---- control cluster --------------------------------------------------------------

/// Sidebar toggle, back/forward, and (with a chat selected) new session —
/// pinned at the window's top-left above the sidebar and headers.
pub fn cluster(shell: *Shell, theme: *const Theme, cx: *Context(Shell)) zpui.Div {
    const has_chat = shell.state.read(cx).workspace.read(cx).selected_chat != null;
    var row = div().absolute().top(px(0)).left(px(0)).h(px(layout.titlebar_height))
        .flex().flexRow().itemsCenter().pt(px(layout.titlebar_top_pad)).px(px(cluster_pad));
    if (is_mac) row = row.child(div().flexNone().hFull().w(px(clusterStart() - cluster_pad)));
    row = row.child(button.windowControl("toggle-sidebar", .sidebar_minimalistic_left, "Toggle left sidebar", theme)
        .onClick(cx.listener(Shell.onToggleSidebarClick)));
    const back = if (shell.canBack())
        zpui.intoAnyElement(button.windowControl("nav-back", .arrow_left, "Back", theme).onClick(cx.listener(Shell.navBack)))
    else
        zpui.intoAnyElement(button.disabledControl(.arrow_left, theme));
    const fwd = if (shell.canForward())
        zpui.intoAnyElement(button.windowControl("nav-forward", .arrow_right, "Forward", theme).onClick(cx.listener(Shell.navForward)))
    else
        zpui.intoAnyElement(button.disabledControl(.arrow_right, theme));
    row = row.child(div().ml(px(layout.titlebar_group_gap)).flex().flexRow().itemsCenter()
        .gap(px(layout.titlebar_control_gap)).child(back).child(fwd));
    if (has_chat) row = row.child(div().flexNone().ml(px(layout.titlebar_group_gap))
        .child(button.windowControl("titlebar-new-session", .plus, "New session", theme).onClick(cx.listener(Shell.onNewSessionClick))));
    return row;
}

// ---- session bar ------------------------------------------------------------------

pub fn sessionBar(shell: *Shell, sidebar_now: f32, right_now: f32, theme: *const Theme, cx: *Context(Shell)) zpui.StatefulDiv {
    const state = shell.state.read(cx);
    const ws = state.workspace.read(cx);
    const chat = ws.selectedChatRow();
    const on_canvas = chat == null;
    const plus_inset: f32 = if (on_canvas) 0 else action_slot_width;
    const row_left = @max(sidebar_now + layout.space_lg, contentStart() + plus_inset);
    const right_pad = rightPad(shell);

    var inner = div().sizeFull().flex().itemsCenter().pt(px(layout.titlebar_top_pad))
        .gap(px(8)).pl(px(row_left)).pr(px(right_pad));

    if (chat) |c| {
        const folder = if (c.spaceId) |sid| (if (ws.space(sid)) |s| model.view.spaceDisplayName(s) else "~") else "~";
        const device = ws.deviceName(c.deviceId) orelse "Unknown device";
        const title_raw = c.title orelse "New session";
        const title = model.view.singleLine(zpui.window.arena_mod.frameAllocator(), title_raw) catch title_raw;
        var ident = div().minW0().overflowHidden().flex().flexRow().itemsCenter().gap(px(6));
        if (c.config) |cfg| ident = ident.child(ui.icon.harness(cfg.harness, 14, theme.text_muted, 1.0));
        ident = ident
            .child(div().minW0().truncate().whitespaceNowrap().textSize(ui.rems(12)).fontWeight(500).textColor(theme.text.opacity(0.85)).child(title))
            .child(div().minW0().truncate().whitespaceNowrap().textSize(ui.rems(12)).textColor(theme.text_muted.opacity(0.5))
            .child(zpui.fmt("{s} @ {s}", .{ folder, device })));
        inner = inner.child(ident);
    }
    inner = inner.child(div().flex1());

    if (!on_canvas) {
        // Session controls: new side chat, fork.
        inner = inner.child(div().flexNone().flex().flexRow().itemsCenter().gap(px(2))
            .child(button.headerIcon("session-new-side-chat", .plus, "New side chat", theme))
            .child(button.headerIcon("session-fork", .git_branch, "Fork this session", theme)));
        // Project actions: the empty state's "Add action" pill (24px, radius 7,
        // the composer's material and edge).
        if (chat.?.spaceId != null) inner = inner.child(addActionPill(theme));
        // Trailing strip: explorer + pane toggles, right-aligned over the pane.
        const files_controls = @max(0 - right_pad, panel_toggle_slots);
        var trailing = div().id("right-titlebar-controls").flexNone().hFull().flex().flexRow().itemsCenter();
        if (right_now > 0.5) {
            const reveal = @max(right_now - right_pad - files_controls, 0);
            trailing = trailing.child(div().w(px(reveal)).hFull().flexNone().flex().flexRow().itemsCenter().gap(px(4))
                .overflowHidden().pl(px(8)).pr(px(4))
                .child(div().flex1().minW0().hFull().flex().flexRow().itemsCenter().gap(px(4)).overflowHidden()
                    .child(if (shell.surfaces.items.len > 0) surfaceStrip(shell, theme, cx) else null))
                .child(button.headerIcon("expand-changes", .expand_arrows, "Expand panel", theme)));
        }
        trailing = trailing.child(div().w(px(files_controls)).hFull().flexNone().flex().itemsCenter().justifyEnd()
            .gap(px(panel_toggle_gap))
            .child(button.headerIcon("toggle-files-panel", .file_tree, "Show files panel", theme))
            .child(button.headerIcon("toggle-changes", .sidebar_minimalistic, "Toggle right sidebar", theme)
                .onClick(cx.listener(Shell.onToggleRightClick))));
        inner = inner.child(trailing);
    }

    const bar = div().h(px(layout.titlebar_height)).flexNone().child(inner);
    return dragRegion("chat-titlebar", bar, cx);
}

const chip_w: f32 = 112;

/// The right pane's surface tabs (t3 RightPanelTabs): 112px chips (icon,
/// 11.5px title, close on hover) and the `+` new-tab menu.
fn surfaceStrip(shell: *Shell, theme: *const Theme, cx: *Context(Shell)) zpui.Div {
    var strip = div().flex().flexRow().itemsCenter().gap(px(4));
    for (shell.surfaces.items, 0..) |e, ix| {
        const active = ix == @min(shell.surface_active, shell.surfaces.items.len - 1);
        const group = zpui.fmt("right-surface-tab-{d}", .{ix});
        const title = zpui.fmt("{s}", .{@import("terminal_dock.zig").surfaceTitle(e.read(cx))});
        var chip = div().id(.{ "right-surface-tab", ix }).group(group)
            .h(px(24)).w(px(chip_w)).flexNone().px(px(4)).rounded(px(6))
            .flex().flexRow().itemsCenter().gap(px(3)).cursorPointer()
            .blockMouseExceptScroll()
            .onClick(cx.listenerWith(ix, Shell.onSelectSurface))
            .child(div().flexNone().size(px(18)).flex().itemsCenter().justifyCenter()
                .child(ui.icon.of(.terminal, 12, if (active) theme.text_muted else theme.text_muted.opacity(0.7))))
            .child(div().flex1().minW0().truncate().whitespaceNowrap().textSize(ui.rems(11.5))
                .textColor(if (active) theme.text else theme.text_muted).child(title))
            .child(div().id(.{ "right-surface-close", ix }).flexNone().size(px(18)).rounded(px(4)).relative()
                .hover(sb.bg(theme.wash(0.12)))
                .onClick(cx.listenerWith(ix, Shell.onCloseSurface))
                .child(div().absolute().inset0().flex().itemsCenter().justifyCenter().opacity(0)
                    .groupHover(group, sb.opacity(1))
                    .child(ui.icon.of(.close, 12, theme.text_muted))));
        chip = if (active) chip.bg(theme.wash(0.10)) else chip.hover(sb.bg(theme.wash(0.06)));
        strip = strip.child(chip);
    }
    var plus = div().id("right-surface-new").relative().size(px(24)).flexNone().flex().itemsCenter().justifyCenter()
        .rounded(px(6)).cursorPointer().hover(sb.bg(theme.wash(0.06)))
        .onClick(cx.listener(Shell.onNewTabMenu))
        .child(ui.icon.of(.plus, 14, theme.text_muted));
    if (!shell.newtab_menu_open) plus = plus.tooltipWith(@as([]const u8, "New tab"), ui.tooltip.build);
    if (shell.newtab_menu_open) {
        const pt = zpui.window.arena_mod.current().create(Theme, theme.forPopup());
        var menu = ui.popover.card(pt).w(px(168)).onMouseDownOut(cx.listener(Shell.onCloseNewTabMenu));
        const rows = [_]struct { []const u8, ui.icon.Icon }{ .{ "Files", .document }, .{ "Browser", .globe }, .{ "Terminal", .terminal }, .{ "Diffs", .list }, .{ "History", .git_branch } };
        for (rows, 0..) |r, i| {
            var row = ui.popover.menuRow(pt, false).id(.{ "newtab-row", i })
                .child(ui.icon.of(r[1], 16, pt.text_muted)).child(r[0]);
            if (i == 2) row = row.onClick(cx.listener(Shell.onAddTerminalSurface));
            menu = menu.child(row);
        }
        plus = plus.child(ui.popover.anchoredBelow(menu));
    }
    return strip.child(plus);
}

fn addActionPill(theme: *const Theme) zpui.Div {
    const radius: f32 = 7;
    const fill = div().sizeFull().rounded(px(radius)).border1().borderColor(theme.composerSurfaceBorder())
        .bg(theme.composerSurfaceBg());
    return div().relative().flexNone().flex().flexRow().itemsCenter().h(px(24)).rounded(px(radius)).occlude()
        .child(div().absolute().inset0().child(ui.effects.frosted(radius, layout.menu_blur, if (theme.isFrost()) fill else fill.shadowSm())))
        .child(div().id("project-action-add").relative().hFull().px(px(8)).flex().itemsCenter().gap(px(5))
            .rounded(px(radius)).cursorPointer()
            .textSize(px(11.5)).fontWeight(500).textColor(theme.text)
            .hover(sb.bg(theme.wash(0.04)))
            .child(ui.icon.of(.plus, 13, theme.text_muted))
            .child("Add action"));
}

fn rightTab(theme: *const Theme, label: []const u8, active: bool) zpui.Div {
    var t = div().h(px(26)).px(px(8)).flex().itemsCenter().rounded(px(7))
        .textSize(ui.rems(12)).fontWeight(500).whitespaceNowrap();
    if (active) t = t.bg(theme.wash(0.09)).textColor(theme.text) else t = t.textColor(theme.text_muted.opacity(0.8)).hover(sb.textColor(theme.text));
    return t.child(label);
}

// ---- Linux CSD --------------------------------------------------------------------

fn onMinimize(_: *Shell, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Shell)) void {
    cx.stopPropagation();
    window.minimizeWindow();
}
fn onMaximize(_: *Shell, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Shell)) void {
    cx.stopPropagation();
    window.zoomWindow();
}
fn onClose(_: *Shell, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Shell)) void {
    cx.stopPropagation();
    window.removeWindow();
}

fn preventDefault(_: *const zpui.input.MouseDownEvent, window: *Window, _: *zpui.App) void {
    window.preventDefault();
}

fn captionButton(id: []const u8, i: ui.icon.Icon, close: bool, theme: *const Theme) zpui.StatefulDiv {
    const red = zpui.rgb(0xe81123).toHsla();
    const group = "linux-caption-button";
    return div().id(id).group(group)
        .size(px(24)).flexNone().flex().itemsCenter().justifyCenter()
        .rounded(px(6)).cursorPointer()
        .hover(sb.bg(if (close) red else theme.glassHover()))
        .occlude()
        .onMouseDown(.left, preventDefault)
        .child(ui.icon.of(i, 16, theme.text_muted));
}

/// zeron-drawn caption buttons (default GNOME layout: minimize, maximize, close on the right).
pub fn linuxCaptions(shell: *Shell, window: *Window, theme: *const Theme, cx: *Context(Shell)) ?zpui.Div {
    if (shell.linuxCaptions() == 0) return null;
    const maximized = window.isMaximized();
    return div().absolute().top(px(0)).right(px(0)).h(px(layout.titlebar_height))
        .flex().flexRow().itemsCenter().pt(px(layout.titlebar_top_pad)).gap(px(2)).px(px(10))
        .child(captionButton("window-minimize", .window_minimize, false, theme).onClick(cx.listener(onMinimize)))
        .child(captionButton(if (maximized) "window-restore" else "window-maximize", if (maximized) .window_restore else .window_maximize, false, theme)
        .onClick(cx.listener(onMaximize)))
        .child(captionButton("window-close", .close, true, theme).onClick(cx.listener(onClose)));
}

fn resizeStrip(comptime edge: zpui.platform.ResizeEdge) fn (*const zpui.input.MouseDownEvent, *Window, *zpui.App) void {
    return struct {
        fn f(_: *const zpui.input.MouseDownEvent, window: *Window, app: *zpui.App) void {
            app.propagate_event = false;
            window.startWindowResize(edge);
        }
    }.f;
}

/// Invisible edge strips that hand presses to the compositor as resizes.
pub fn linuxResizeBorders(shell: *Shell, window: *Window) ?zpui.Div {
    if (shell.linuxCaptions() == 0 or window.isMaximized() or window.isFullscreen()) return null;
    const edge: f32 = 6;
    const corner: f32 = 14;
    return div().absolute().inset0()
        .child(div().absolute().top(px(0)).left(px(corner)).right(px(corner)).h(px(edge)).cursorNsResize().onMouseDown(.left, resizeStrip(.top)))
        .child(div().absolute().bottom(px(0)).left(px(corner)).right(px(corner)).h(px(edge)).cursorNsResize().onMouseDown(.left, resizeStrip(.bottom)))
        .child(div().absolute().left(px(0)).top(px(corner)).bottom(px(corner)).w(px(edge)).cursorEwResize().onMouseDown(.left, resizeStrip(.left)))
        .child(div().absolute().right(px(0)).top(px(corner)).bottom(px(corner)).w(px(edge)).cursorEwResize().onMouseDown(.left, resizeStrip(.right)))
        .child(div().absolute().top(px(0)).left(px(0)).size(px(corner)).onMouseDown(.left, resizeStrip(.top_left)))
        .child(div().absolute().top(px(0)).right(px(0)).size(px(corner)).onMouseDown(.left, resizeStrip(.top_right)))
        .child(div().absolute().bottom(px(0)).left(px(0)).size(px(corner)).onMouseDown(.left, resizeStrip(.bottom_left)))
        .child(div().absolute().bottom(px(0)).right(px(0)).size(px(corner)).onMouseDown(.left, resizeStrip(.bottom_right)));
}
