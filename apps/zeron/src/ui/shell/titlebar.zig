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
const project_actions = @import("project_actions.zig");

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
    // A window drag strip (double-click zooms): a toolbar node for assistive technology.
    return el.id(id).role(.toolbar).ariaLabel("Title bar")
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
    if (theme.isLiquid()) return liquidCluster(shell, theme, cx); // [liquid-glass]
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

pub fn sessionBar(shell: *Shell, sidebar_now: f32, right_now: f32, files_now: f32, theme: *const Theme, cx: *Context(Shell)) zpui.StatefulDiv {
    const state = shell.state.read(cx);
    const ws = state.workspace.read(cx);
    const chat = ws.selectedChatRow();
    const on_canvas = chat == null;
    const plus_inset: f32 = if (on_canvas) 0 else action_slot_width;
    // In takeover the title hides and the strip owns the band: the row pulls
    // back to the sidebar seam (the strip brings its own 8px pad).
    const takeover = shell.right_expanded and right_now > 0.5;
    const liquid = theme.isLiquid(); // [liquid-glass] Tahoe capsules around item groups
    glass_tint = theme.glassTint();
    const row_left = if (takeover)
        @max(sidebar_now - 8, contentStart() - layout.titlebar_identity_gap + plus_inset - 14)
    else
        @max(sidebar_now + layout.space_lg, contentStart() + plus_inset + if (liquid) capsule_clearance else 0);
    const right_pad = rightPad(shell);

    var inner = div().sizeFull().flex().itemsCenter().pt(px(layout.titlebar_top_pad))
        .gap(px(8)).pl(px(row_left)).pr(px(right_pad));

    if (chat != null and !takeover) {
        const c = chat.?;
        const folder = if (c.spaceId) |sid| (if (ws.space(sid)) |s| model.view.spaceDisplayName(s) else "~") else "~";
        const device = ws.deviceName(c.deviceId) orelse "Unknown device";
        const title_raw = c.title orelse "New session";
        const title = model.view.singleLine(zpui.window.arena_mod.frameAllocator(), title_raw) catch title_raw;
        var ident = div().minW0().overflowHidden().flex().flexRow().itemsCenter().gap(px(6));
        if (c.config) |cfg| ident = ident.child(ui.icon.harness(cfg.harness, 14, theme.text_muted, 1.0));
        ident = ident
            .child(div().minW0().truncate().whitespaceNowrap().textSize(ui.rems(12)).fontWeight(500).textColor(theme.text.opacity(0.85)).child(title))
            .child(div().minW0().truncate().whitespaceNowrap().textSize(ui.rems(12)).textColor(theme.text_muted.opacity(if (liquid) 0.7 else 0.5))
            .child(zpui.fmt("{s} @ {s}", .{ folder, device })));
        // [liquid-glass] The title is the foreground of its own capsule (painted on the
        // plane above the glass), never under it.
        inner = inner.child(if (liquid) titleCapsule(ident) else zpui.intoAnyElement(ident));
    }
    inner = inner.child(div().flex1());

    if (!on_canvas and !takeover) {
        // Session controls: new side chat, fork.
        inner = inner.child(capsule(liquid, "titlebar-session-glass", capsule_pad, div().flexNone().flex().flexRow().itemsCenter().gap(px(2))
            .child(button.headerIcon("session-new-side-chat", .plus, "New side chat", theme))
            .child(button.headerIcon("session-fork", .git_branch, "Fork this session", theme))));
        // Project actions: the split Run/Setup control (24px, radius 7, the
        // composer's material and edge) — project_actions.zig.
        // `available_titlebar_width` (tabs.rs): the row minus the trailing strip,
        // the gaps and the session controls; it decides the action's label.
        const fc = @max(files_now - right_pad, panel_toggle_slots);
        const trailing_w = fc + (if (right_now > 0.5) @max(right_now + files_now - right_pad - fc, 0) else 0);
        const available = @max(shell.viewport_w - row_left - right_pad - trailing_w - 8 * 3 - (28 * 2 + 2 + 8), 0);
        if (chat.?.spaceId != null) {
            if (project_actions.control(shell, available, theme, liquid, cx)) |ctrl| {
                inner = inner.child(if (liquid) capsule(true, "titlebar-action-glass", 0, ctrl) else zpui.intoAnyElement(ctrl));
            }
        }
    }
    if (!on_canvas) {
        // Trailing strip: explorer + pane toggles, right-aligned over the pane.
        // `panel_titlebar_widths`: the toggles anchor over the explorer column
        // (or the window edge); the surface tabs reveal to their left.
        const files_controls = @max(files_now - right_pad, panel_toggle_slots);
        var trailing = div().id("right-titlebar-controls").flexNone().hFull().flex().flexRow().itemsCenter();
        if (right_now > 0.5) {
            const reveal = @max(right_now + files_now - right_pad - files_controls, 0);
            const strip = blk: {
                var l = shell.right_pane.lease(cx);
                defer l.end();
                break :blk l.value.renderStrip(theme, &l.cx);
            };
            trailing = trailing.child(div().w(px(reveal)).hFull().flexNone().flex().flexRow().itemsCenter().gap(px(4))
                .overflowHidden().pl(px(8)).pr(px(4))
                .child(div().flex1().minW0().hFull().overflowHidden().child(strip))
                .child(button.headerIcon("expand-changes", if (shell.right_expanded) .collapse_arrows else .expand_arrows, if (shell.right_expanded) "Collapse panel" else "Expand panel", theme)
                    .onClick(cx.listener(Shell.onToggleExpandClick))));
        }
        const files_btn = blk: {
            const files_open = shell.filesOpen(cx);
            var b = button.headerIcon("toggle-files-panel", .file_tree, if (files_open) "Hide files panel" else "Show files panel", theme)
                .onClick(cx.listener(Shell.onToggleFilesClick));
            if (files_open) b = b.bg(theme.wash(0.09));
            break :blk b;
        };
        const right_btn = button.headerIcon("toggle-changes", .sidebar_minimalistic, "Toggle right sidebar", theme)
            .onClick(cx.listener(Shell.onToggleRightClick));
        const slot = div().w(px(files_controls)).hFull().flexNone().flex().itemsCenter().justifyEnd();
        // [liquid-glass] One capsule around the pane toggles (not the whole slot).
        trailing = trailing.child(if (liquid)
            slot.child(capsule(true, "titlebar-panes-glass", capsule_pad, div().flex().flexRow().itemsCenter().gap(px(panel_toggle_gap)).child(files_btn).child(right_btn)))
        else
            slot.gap(px(panel_toggle_gap)).child(files_btn).child(right_btn));
        inner = inner.child(trailing);
    }

    const bar = div().h(px(layout.titlebar_height)).flexNone().child(inner);
    return dragRegion("chat-titlebar", bar, cx);
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
            // gpui lands this 11.5px label's baseline a device pixel higher
            // than our centering does (measured against the reference).
            .child(div().relative().top(px(-1)).child("Add action")));
}

// ---- [liquid-glass] Tahoe toolbar capsules (docs/LIQUID_GLASS.md, Option B) ------------
//
// No full-width titlebar glass: each item group gets its own capsule of native glass
// (one `NSGlassEffectView` each, all members of the shell's titlebar
// `NSGlassEffectContainerView`, so neighbours that come closer than
// `capsule_spacing` — e.g. while the sidebar collapses — melt into each other). The
// group's content is the capsule's foreground, painted above the glass.

/// Capsule height (the 38px band, centred on the controls' y = 21).
pub const capsule_h: f32 = 30;
/// Horizontal padding around 24px icon buttons / around the title.
pub const capsule_pad: f32 = 3;
const title_pad: f32 = 10;
/// `NSGlassEffectContainerView.spacing` of the titlebar group.
pub const capsule_spacing: f32 = 6;
/// Glass corner radius for titlebar groups: zeron's own control radius, not pills.
const glass_radius: f32 = layout.chrome_control_radius;
/// Theme tint for the titlebar glass groups, refreshed each render.
var glass_tint: ?zpui.Hsla = null;
/// Extra room between the leading island and the title capsule (sidebar collapsed),
/// on top of the identity gap; keeps them farther apart than `capsule_spacing`.
pub const capsule_clearance: f32 = 8;

/// `child` in a capsule of glass (Liquid Glass), or unchanged.
fn capsule(liquid: bool, name: []const u8, pad: f32, child: anytype) zpui.AnyElement {
    if (!liquid) return zpui.intoAnyElement(child);
    return zpui.intoAnyElement(zpui.liquidGlass(name, .{ .shape = .{ .rounded = glass_radius }, .interactive = true, .tint = glass_tint }, div().flexNone().h(px(capsule_h)).px(px(pad))
        .flex().flexRow().itemsCenter().child(child)));
}

/// The session identity in a shrinkable capsule (it truncates like the bare title).
fn titleCapsule(ident: zpui.Div) zpui.AnyElement {
    return zpui.intoAnyElement(zpui.liquidGlass("titlebar-title-glass", .{ .shape = .{ .rounded = glass_radius }, .tint = glass_tint }, div().minW0().overflowHidden().h(px(capsule_h)).px(px(title_pad))
        .flex().flexRow().itemsCenter().child(ident)));
}

/// "Add action" as its own capsule: the glass replaces the frosted fill and edge.
fn liquidActionPill(theme: *const Theme) zpui.AnyElement {
    return capsule(true, "titlebar-action-glass", 0, div().id("project-action-add").h(px(capsule_h)).px(px(10)).flex().itemsCenter().gap(px(5))
        .rounded(px(glass_radius)).cursorPointer().occlude()
        .textSize(px(11.5)).fontWeight(500).textColor(theme.text)
        .hover(sb.bg(theme.wash(0.06)))
        .child(ui.icon.of(.plus, 13, theme.text_muted))
        .child(div().relative().top(px(-1)).child("Add action")));
}

/// The leading capsule (sidebar collapsed): zeron's titlebar "island"
/// (`render_titlebar_cluster` + `titlebar_island_vertical_geometry`, shell.rs): it
/// starts 6px from the window's left edge, so it wraps the traffic lights (at 14,14)
/// as well as the toggle / back / forward (/ +) controls, runs to the cluster's 10px
/// trailing pad, is 32px high centred on the controls (y 5..37) and has radius 12,
/// filled with `glass_overlay` (dark grey in dark themes). Here the island is native
/// glass tinted with that fill. The title / right-hand groups keep the 6px radius.
pub const lead_capsule_left: f32 = 6;
pub const lead_capsule_h: f32 = 32;
pub const lead_capsule_radius: f32 = 12;

/// The island's tint: the Rust island's `glass_overlay` fill (null when
/// `ZERON_GLASS_TINT=0` turns glass tints off).
pub fn leadCapsuleTint(theme: *const Theme) ?zpui.Hsla {
    if (theme.glassTint() == null) return null;
    return theme.glassOverlay();
}

/// Right edge of the leading capsule (window coordinates).
pub fn leadCapsuleRight(has_chat: bool) f32 {
    return clusterStart() + cluster_buttons_width + (if (has_chat) action_slot_width else 0) + cluster_pad;
}

/// The sidebar toggle + back/forward (+ new session) group. Over the sidebar glass it
/// sits bare on the pane (as on Tahoe); with the sidebar collapsed it and the traffic
/// lights share one capsule (the leading island, above).
fn liquidCluster(shell: *Shell, theme: *const Theme, cx: *Context(Shell)) zpui.Div {
    const has_chat = shell.state.read(cx).workspace.read(cx).selected_chat != null;
    var group = div().flex().flexRow().itemsCenter()
        .child(button.windowControl("toggle-sidebar", .sidebar_minimalistic_left, "Toggle left sidebar", theme)
        .onClick(cx.listener(Shell.onToggleSidebarClick)));
    const back = if (shell.canBack())
        zpui.intoAnyElement(button.windowControl("nav-back", .arrow_left, "Back", theme).onClick(cx.listener(Shell.navBack)))
    else
        zpui.intoAnyElement(button.disabledControl(.arrow_left, theme));
    const fwd = if (shell.canForward())
        zpui.intoAnyElement(button.windowControl("nav-forward", .arrow_right, "Forward", theme).onClick(cx.listener(Shell.navForward)))
    else
        zpui.intoAnyElement(button.disabledControl(.arrow_right, theme));
    group = group.child(div().ml(px(layout.titlebar_group_gap)).flex().flexRow().itemsCenter()
        .gap(px(layout.titlebar_control_gap)).child(back).child(fwd));
    if (has_chat) group = group.child(div().flexNone().ml(px(layout.titlebar_group_gap))
        .child(button.windowControl("titlebar-new-session", .plus, "New session", theme).onClick(cx.listener(Shell.onNewSessionClick))));
    const row = div().absolute().top(px(0)).left(px(0)).h(px(layout.titlebar_height))
        .flex().flexRow().itemsCenter().pt(px(layout.titlebar_top_pad));
    // Over the sidebar pane: bare controls at the cluster's usual place.
    const on_sidebar = shell.sidebarNow(cx) >= clusterStart() + cluster_buttons_width;
    if (on_sidebar) return row.pl(px(clusterStart())).pr(px(cluster_pad)).child(group);
    // Collapsed: one island from x = 6, wrapping the traffic lights and the controls.
    const island = div().flexNone().h(px(lead_capsule_h)).flex().flexRow().itemsCenter()
        .pl(px(clusterStart() - lead_capsule_left)).pr(px(cluster_pad)).child(group);
    return row.pl(px(lead_capsule_left)).child(zpui.liquidGlass("titlebar-nav-glass", .{
        .shape = .{ .rounded = lead_capsule_radius },
        .tint = leadCapsuleTint(theme),
    }, island));
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
    // [lifecycle] through the unsaved-files gate + geometry save (lifecycle/root.zig).
    @import("../../lifecycle/root.zig").closeWindow(cx.app, window);
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
