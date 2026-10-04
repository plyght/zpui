//! The main column (zeron `render_main`): the selected chat's transcript or
//! the new-session canvas, with the composer docked at the bottom; plus the
//! right pane host (`render_right_pane`).
//!
//! Integration points for the transcript and composer views live in
//! `slots.zig` (placeholders until those views land).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const prefs_mod = @import("prefs.zig");
const fixtures_mod = @import("fixtures.zig");
const slots = @import("slots.zig");
const terminal_panel = @import("terminal_panel.zig");
const background = @import("../background/root.zig");
const settings_store_ui = @import("../settings/store.zig");
const harness_updates = @import("harness_updates.zig");
const right_pane = @import("right_pane.zig");
const files = @import("../files/root.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = ui.Theme;
const layout = zt.layout;

pub const MainPanel = struct {
    gpa: std.mem.Allocator,
    state: Entity(model.AppState),
    fixtures: ?*fixtures_mod.Fixtures,
    slots: slots.Slots,
    subs: zpui.Subscriptions = .{},
    /// The bottom terminal drawer (per-chat tabs; `terminal/panel.rs`).
    terminal: Entity(terminal_panel.TerminalPanel),
    /// Column width (set by the shell each frame).
    width: f32 = 800,
    terminal_sub: ?zpui.Subscription = null,
    /// (pointer y, height) when a terminal resize drag began.
    terminal_drag_anchor: ?[2]f32 = null,
    /// The new-thread hero's crossfade state (`new_thread_artwork_ready`).
    artwork_ready: background.hero.Readiness = .{},
    /// Home's agent-update island (`render_harness_update_card`).
    harness_updates: Entity(harness_updates.HarnessUpdateIsland),

    pub fn init(state: Entity(model.AppState), fixtures: ?*fixtures_mod.Fixtures, cx: *Context(MainPanel)) !MainPanel {
        var self: MainPanel = .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .fixtures = fixtures,
            .slots = try slots.Slots.init(state, fixtures, cx),
            .harness_updates = undefined,
            .terminal = try cx.newWith(terminal_panel.TerminalPanel, terminal_panel.TerminalPanel.init, .{state}),
        };
        errdefer self.terminal.release(cx);
        self.terminal_sub = try cx.subscribe(self.terminal, onTerminalHide);
        self.harness_updates = try cx.newWith(harness_updates.HarnessUpdateIsland, harness_updates.HarnessUpdateIsland.init, .{state});
        errdefer self.harness_updates.release(cx);
        const s = state.read(cx);
        try self.subs.add(cx.gpa(), try cx.observe(s.workspace, onChanged));
        try self.subs.add(cx.gpa(), try cx.subscribe(state, onStores));
        return self;
    }

    pub fn deinit(self: *MainPanel, app: *App) void {
        self.subs.deinit(self.gpa);
        self.artwork_ready.deinit(app, self.gpa);
        if (self.terminal_sub) |*t| t.deinit();
        self.terminal.release(app);
        self.slots.deinit(app);
        self.harness_updates.release(app);
        self.state.release(app);
    }

    fn onStores(self: *MainPanel, _: Entity(model.AppState), _: *const model.app_state.SelectedChatStoresChanged, cx: *Context(MainPanel)) void {
        self.slots.loadFixtureTranscript(cx);
        cx.notify();
    }

    fn onChanged(_: *MainPanel, _: Entity(model.WorkspaceStore), cx: *Context(MainPanel)) void {
        cx.notify();
    }

    pub fn render(self: *MainPanel, window: *Window, cx: *Context(MainPanel)) zpui.StatefulDiv {
        const theme = ui.theme.get(cx);
        const ws = self.state.read(cx).workspace.read(cx);
        const has_chat = ws.selected_chat != null;
        const has_spaces = ws.spaces().len > 0 or ws.no_project;

        // The whole conversation receives dropped files in its composer
        // (`chat_dropzone`), with the "Drop to attach" overlay while a file
        // drag hovers it.
        var col = div().id("chat-dropzone").relative().sizeFull().flex().flexCol().overflowHidden()
            .onDragMove(TerminalResize, cx.listener(MainPanel.onTerminalResize))
            .onDrop(zpui.ExternalPaths, cx.listener(MainPanel.onDropPaths))
            .onDrop(right_pane.TabDrag, cx.listener(MainPanel.onDropTab))
            .onDrop(files.WorkspacePathDrag, cx.listener(MainPanel.onDropWorkspacePath));
        const width = self.width;
        if (has_chat) {
            const stack = self.slots.composer_view.read(cx).last_rendered_height;
            const clearance = (if (stack > 0) stack else layout.composer_compact_height) + 64;
            col = col.child(div().relative().flex1().minH0()
                .child(div().absolute().inset0().child(ui.effects.edgeFaded(div().sizeFull().child(self.slots.transcript(clearance, width, cx)), .{
                    .band = layout.transcript_fade_band,
                    .top = true,
                    .bottom = true,
                    .inset_top = layout.titlebar_height,
                    .band_top = layout.transcript_fade_band,
                    .band_bottom = @max(clearance - 64 + 40 - layout.status_strip_height, 1),
                })))
                .child(div().absolute().bottom(px(0)).left(px(0)).right(px(0)).child(self.slots.composer(width, cx))));
        } else if (!has_spaces and ws.spaces_synced) {
            col = col.child(onboarding(theme));
        } else {
            // The new-thread hero sits behind the canvas composition.
            if (self.newThreadHero(window, theme, cx)) |hero| col = col.child(hero);
            // The canvas composer sits a touch above center (the dock's home slot).
            col = col.child(div().flex1().minH0())
                .child(div().mb(px(12)).child(self.slots.composer(width, cx)))
                .child(div().flex1().minH0());
        }
        const terminal_open = prefs_mod.get(cx).terminal_open;
        if (has_chat) {
            // Leaving Home collapses the island (Rust: `has_selection`).
            if (self.harness_updates.read(cx).expanded) _ = self.harness_updates.update(cx, harness_updates.HarnessUpdateIsland.collapse, .{});
        } else if (!terminal_open) {
            // Anchored to the window bottom, behind the terminal dock (fully
            // covered while the dock is open, so it is not mounted then).
            {
                var l = self.harness_updates.lease(cx);
                defer l.end();
                l.value.main_width = width;
                l.value.viewport_height = window.viewportSize().height;
            }
            col = col.child(div().absolute().left(px(0)).right(px(0)).bottom(px(harness_updates.bottom_inset))
                .flex().justifyCenter().child(self.harness_updates));
        }
        if (self.terminal.read(cx).open != terminal_open) self.terminal.update(cx, terminal_panel.TerminalPanel.setOpen, .{ terminal_open, window });
        if (terminal_open) {
            // `terminal_height` (Settings, persisted), limited to the viewport
            // share; the top edge drags it, a double-click resets it.
            const h = terminalHeight(window, cx);
            col = col.child(div().relative().flexNone().h(px(h)).wFull().child(self.terminal)
                .child(div().id("terminal-resize").role(.separator).ariaLabel("Resize terminal").absolute().left(px(0)).right(px(0))
                .top(px(-terminal_resize_hitbox / 2)).h(px(terminal_resize_hitbox)).cursorRowResize()
                .onMouseDown(.left, cx.listener(MainPanel.onTerminalResizeDown))
                .onClick(cx.listener(MainPanel.onTerminalResizeClick))
                .onDrag(TerminalResize{}, buildResizeGhost)
                .child(div().absolute().top(px(terminal_resize_hitbox / 2)).left(px(0)).right(px(0)).h(px(1))
                .hover(sb.bg(theme.border_strong)))));
        }
        // Last child: the overlay covers the terminal dock too (Rust order).
        // A file tab dragged out of the right-pane strip reveals it as well;
        // other surfaces never do (Rust's `drag_over::<RightTabDrag>` predicate).
        const tab_file = if (cx.app.activeDrag(right_pane.TabDrag)) |d| d.workspacePath() != null else false;
        col = col.child(attachmentDropOverlay(theme, tab_file));
        return col;
    }

    /// Prepare the configured artwork (decode/effects run once off-thread,
    /// independent of geometry) and build the hero layer for this frame.
    fn newThreadHero(self: *MainPanel, window: *Window, theme: *const Theme, cx: *Context(MainPanel)) ?zpui.Div {
        const app = cx.app;
        const s = settings_store_ui.current(app);
        background.wallpaper.preload(app);
        const bg = s.newThreadComposerBackground;
        const light = theme.appearance == .light;
        const img = if (bg) |b| background.cache.prepare(app, background.install.ioOf(app), b.path, s.newThreadBackgroundEffect, light) else null;
        const now = app.executor.now();
        const reduced = window.prefersReducedMotion();
        const frame = self.artwork_ready.frame(app, self.gpa, img, if (bg) |b| b.path else null, if (bg) |b| b.adjustment else .{}, bg != null, reduced, now);
        if (frame.current == null and frame.previous == null) return null;
        if (frame.active) window.requestAnimationFrame();
        const composer = self.slots.composer_view.read(cx);
        return background.hero.layer(frame, window.viewportSize().height, self.width, &composer.surface_bounds, theme.surface_treatment == .frosted);
    }

    fn onDropPaths(self: *MainPanel, paths: *const zpui.ExternalPaths, _: *Window, cx: *Context(MainPanel)) void {
        const ComposerView = @TypeOf(self.slots.composer_view).Type;
        self.slots.composer_view.update(cx, ComposerView.addPaths, .{paths.paths});
        cx.notify();
    }

    /// `on_drop::<RightTabDrag>`: a file tab of this chat's strip attaches its
    /// workspace path (`attach_workspace_drag`).
    fn onDropTab(self: *MainPanel, payload: *const right_pane.TabDrag, window: *Window, cx: *Context(MainPanel)) void {
        const path = payload.workspacePath() orelse return;
        const chat = self.state.read(cx).workspace.read(cx).selected_chat orelse return;
        if (!payload.belongsTo(chat)) return;
        const ComposerView = @TypeOf(self.slots.composer_view).Type;
        self.slots.composer_view.update(cx, ComposerView.addWorkspacePath, .{ path, false, window });
        cx.notify();
    }

    /// `on_drop::<WorkspacePathDrag>` (`attach_workspace_drag`): an explorer
    /// row of this chat inserts a workspace file reference; a drag that
    /// outlived a session switch is dropped.
    fn onDropWorkspacePath(self: *MainPanel, payload: *const files.WorkspacePathDrag, window: *Window, cx: *Context(MainPanel)) void {
        const chat = self.state.read(cx).workspace.read(cx).selected_chat orelse return;
        if (!payload.belongsTo(chat)) return;
        const ComposerView = @TypeOf(self.slots.composer_view).Type;
        self.slots.composer_view.update(cx, ComposerView.addWorkspacePath, .{ payload.path(), payload.is_directory, window });
        cx.notify();
    }

    fn onTerminalResizeDown(self: *MainPanel, ev: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(MainPanel)) void {
        self.terminal_drag_anchor = .{ ev.position.y, terminalHeight(window, cx) };
    }

    /// `on_terminal_drag`: the height follows the pointer within the limits.
    fn onTerminalResize(self: *MainPanel, ev: *const zpui.DragMoveEvent(TerminalResize), window: *Window, cx: *Context(MainPanel)) void {
        const anchor = self.terminal_drag_anchor orelse return;
        const vh = window.viewportSize().height;
        const requested = anchor[1] + (anchor[0] - ev.event.position.y);
        const next = clampTerminalHeight(@min(requested, terminalLimit(vh)), vh);
        const W = struct {
            fn f(v: f32, st: *model.UiSettings, _: std.mem.Allocator) void {
                st.terminalHeight = v;
            }
        };
        _ = model.settings_store.update(cx.app, .debounced, next, W.f);
        cx.notify();
    }

    fn onTerminalResizeClick(_: *MainPanel, ev: *const zpui.ClickEvent, _: *Window, cx: *Context(MainPanel)) void {
        if (ev.clickCount() != 2) return;
        const W = struct {
            fn f(_: void, st: *model.UiSettings, _: std.mem.Allocator) void {
                st.terminalHeight = model.settings.terminal_default_height;
            }
        };
        _ = model.settings_store.update(cx.app, .debounced, {}, W.f);
        cx.notify();
    }

    fn onTerminalHide(_: *MainPanel, _: Entity(terminal_panel.TerminalPanel), _: *const terminal_panel.Hide, cx: *Context(MainPanel)) void {
        prefs_mod.mut(cx).terminal_open = false;
        cx.notify();
    }
};

/// The terminal's top-edge resize drag (`TerminalResize`).
pub const TerminalResize = struct {};
const terminal_resize_hitbox: f32 = 10;

const ResizeGhost = struct {
    pub fn render(_: *ResizeGhost, _: *Window, _: *Context(ResizeGhost)) zpui.Div {
        return div();
    }
};

fn buildResizeGhost(_: *const TerminalResize, _: zpui.Point(f32), _: *Window, app: *App) Entity(ResizeGhost) {
    return app.new(ResizeGhost, .{}) catch @panic("OOM");
}

/// The drawer's height limit: 55% of the viewport, and never over the
/// titlebar and status strip.
fn terminalLimit(vh: f32) f32 {
    return @min(vh * layout.terminal_max_vh, @max(vh - layout.titlebar_height - layout.status_strip_height, 0));
}

/// `clamp_terminal_height` (terminal/panel.rs).
pub fn clampTerminalHeight(height: f32, vh: f32) f32 {
    const max = @max(vh * layout.terminal_max_vh, layout.terminal_min_height);
    if (!std.math.isFinite(height)) return layout.terminal_min_height;
    return std.math.clamp(height, layout.terminal_min_height, max);
}

test "terminal height clamps like terminal/panel.rs" {
    try std.testing.expectEqual(@as(f32, 160), clampTerminalHeight(10, 1000));
    try std.testing.expectEqual(@as(f32, 550), clampTerminalHeight(900, 1000));
    try std.testing.expectEqual(@as(f32, 300), clampTerminalHeight(300, 1000));
    try std.testing.expectEqual(@as(f32, 160), clampTerminalHeight(std.math.inf(f32), 1000));
}

fn terminalHeight(window: *Window, cx: anytype) f32 {
    const vh = window.viewportSize().height;
    const stored = if (model.settings_store.current(cx.app)) |st| st.terminalHeight else layout.terminal_default_height;
    return @min(stored, terminalLimit(vh));
}

/// `attachment_drop_overlay`: a scrim with "Drop to attach", shown only
/// while an external file drag hovers the conversation (typed drag style).
pub fn attachmentDropOverlay(theme: *const Theme, tab_file: bool) zpui.StatefulDiv {
    return dropOverlay(theme, tab_file, true);
}

/// The overlay; `external` = OS file drops are accepted too (the side
/// chat's reply field has no attachment staging, so it takes workspace
/// references only).
pub fn dropOverlay(theme: *const Theme, tab_file: bool, external: bool) zpui.StatefulDiv {
    var overlay = div().id("attachment-drop-overlay").absolute().inset0().opacity(0)
        .bg(theme.scrim().opacity(0.4 / 0.6)).flex().itemsCenter().justifyCenter()
        .textSize(ui.rems(13)).textColor(theme.text)
        .dragOver(files.WorkspacePathDrag, sb.opacity(1))
        .child("Drop to attach");
    if (external) overlay = overlay.dragOver(zpui.ExternalPaths, sb.opacity(1));
    if (tab_file) overlay = overlay.dragOver(right_pane.TabDrag, sb.opacity(1));
    return overlay;
}

/// First boot: no folders to work in yet.
fn onboarding(theme: *const Theme) zpui.Div {
    return div().sizeFull().flex().flexCol().itemsCenter().justifyCenter()
        .child(div().flex().flexCol().itemsCenter()
            .child(zpui.svg().source(ui.icon.Icon.zeron_logo.path(), ui.icon.Icon.zeron_logo.svg()).w(px(41.9)).h(px(48)).textColor(theme.text.opacity(0.09)))
            .child(div().mt(px(24)).textSize(ui.rems(16)).fontWeight(500).textColor(theme.text).child("Add a project to get started"))
            .child(div().mt(px(6)).textSize(ui.rems(13)).textColor(theme.text_muted.opacity(0.7)).child("A project is a folder on one of your devices."))
            .child(ui.button.solid("onboarding-add-space", "Add a project", theme).mt(px(20)).h(px(32)).px(px(14)).textSize(ui.rems(13))));
}
