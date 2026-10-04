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
const terminal_dock = @import("terminal_dock.zig");
const background = @import("../background/root.zig");
const settings_store_ui = @import("../settings/store.zig");
const harness_updates = @import("harness_updates.zig");

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
    terminal: ?Entity(terminal_dock.TerminalDock) = null,
    /// Column width (set by the shell each frame).
    width: f32 = 800,
    terminal_sub: ?zpui.Subscription = null,
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
        };
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
        if (self.terminal) |t| t.release(app);
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
            .onDrop(zpui.ExternalPaths, cx.listener(MainPanel.onDropPaths));
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
        col = col.child(attachmentDropOverlay(theme));
        if (terminal_open) {
            if (self.terminal == null) {
                const chat = ws.selectedChatRow();
                const cwd: ?[]const u8 = if (chat) |c| (c.cwd orelse if (ws.spaceForChat(c)) |sp| sp.path else null) else if (ws.selectedSpaceRow()) |sp| sp.path else null;
                const t = terminal_dock.TerminalDock;
                if (cx.newWith(t, t.init, .{ ws.io, cwd, window })) |dock| {
                    self.terminal = dock;
                    self.terminal_sub = cx.subscribe(dock, onTerminalHide) catch null;
                } else |err| std.log.warn("terminal: {t}", .{err});
            }
            if (self.terminal) |t| {
                const vh = window.viewportSize().height;
                const h = @min(layout.terminal_default_height, vh * layout.terminal_max_vh);
                col = col.child(div().flexNone().h(px(h)).wFull().child(t));
            }
        }
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

    fn onTerminalHide(_: *MainPanel, _: Entity(terminal_dock.TerminalDock), _: *const terminal_dock.Hide, cx: *Context(MainPanel)) void {
        prefs_mod.mut(cx).terminal_open = false;
        cx.notify();
    }
};

/// `attachment_drop_overlay`: a scrim with "Drop to attach", shown only
/// while an external file drag hovers the conversation (typed drag style).
fn attachmentDropOverlay(theme: *const Theme) zpui.StatefulDiv {
    return div().id("attachment-drop-overlay").absolute().inset0().opacity(0)
        .bg(theme.scrim().opacity(0.4 / 0.6)).flex().itemsCenter().justifyCenter()
        .textSize(ui.rems(13)).textColor(theme.text)
        .dragOver(zpui.ExternalPaths, sb.opacity(1))
        .child("Drop to attach");
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
