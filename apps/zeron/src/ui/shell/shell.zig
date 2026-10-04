//! The root view (zeron `shell.rs` `impl Render for Shell`): glass window
//! frame, unified 38px titlebar, sidebar | main | right pane with drag
//! resize, pane toggles, boot splash, connection/auth/org gates, Linux CSD
//! caption buttons + resize strips.
//!
//! ```zig
//! _ = try app.openWindow(options, Shell, Shell.init, .{ app_state, fixtures });
//! ```

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const actions = @import("zeron_actions");
const ui = @import("../components/root.zig");
const prefs_mod = @import("prefs.zig");
const fixtures_mod = @import("fixtures.zig");
const sidebar_mod = @import("../sidebar/sidebar.zig");
const titlebar = @import("titlebar.zig");
const gates = @import("gates.zig");
const main_panel = @import("main_panel.zig");
const palette_mod = @import("palette.zig");
const terminal_dock = @import("terminal_dock.zig");
const settings_ui = @import("../settings/root.zig"); // settings mode (ui/settings owns it)

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = ui.Theme;
const layout = zt.layout;
const motion = zt.motion;
const shell_actions = actions.shell;

const is_mac = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

/// Half-width of the invisible pane-resize hit target straddling a seam.
const resize_hitbox_half: f32 = 10;

pub const SidebarResize = struct {};
pub const RightPaneResize = struct {};

/// Empty drag preview for pane resizes (the Zed dock idiom).
pub const DragGhost = struct {
    pub fn render(_: *DragGhost, _: *Window, _: *Context(DragGhost)) zpui.Div {
        return div();
    }
};

fn buildGhost(comptime T: type) fn (*const T, zpui.Point(f32), *Window, *App) Entity(DragGhost) {
    return struct {
        fn f(_: *const T, _: zpui.Point(f32), _: *Window, app: *App) Entity(DragGhost) {
            return app.new(DragGhost, .{}) catch @panic("OOM");
        }
    }.f;
}

/// A manually driven width tween (zeron `WidthTween`, RESIZE 200ms ease-out).
pub const Tween = struct {
    from: f32,
    to: f32,
    start_ns: u64,

    pub fn value(self: Tween, now: u64, spec: motion.MotionSpec) f32 {
        const elapsed = now -| self.start_ns;
        const t = spec.progressAt(elapsed, 1.0);
        return motion.lerp(self.from, self.to, t);
    }

    pub fn done(self: Tween, now: u64, spec: motion.MotionSpec) bool {
        return now -| self.start_ns >= spec.totalNs(1.0);
    }
};

pub const SplashPhase = enum { visible, fading, gone };

pub const Shell = struct {
    gpa: std.mem.Allocator,
    state: Entity(model.AppState),
    sidebar: Entity(sidebar_mod.Sidebar),
    main: Entity(main_panel.MainPanel),
    focus: zpui.FocusHandle,
    fixtures: ?*fixtures_mod.Fixtures,
    subs: zpui.Subscriptions = .{},

    splash: SplashPhase = .visible,
    splash_fade_start: u64 = 0,
    sidebar_tween: ?Tween = null,
    right_tween: ?Tween = null,
    /// Navigation history of selected chats (null = new-session canvas).
    nav: std.ArrayList(?[]u8) = .empty,
    nav_ix: usize = 0,
    nav_suppress: bool = false,
    server_decorations: bool = false,
    palette: ?Entity(palette_mod.Palette) = null,
    /// Right-pane surfaces (terminals) and the active one.
    surfaces: std.ArrayList(Entity(terminal_dock.TerminalDock)) = .empty,
    surface_active: usize = 0,
    newtab_menu_open: bool = false,
    palette_subs: zpui.Subscriptions = .{},
    // ---- settings mode (ui/settings/view.zig) ----
    settings_view: ?Entity(settings_ui.SettingsView) = null,
    settings_sub: ?zpui.Subscription = null,

    pub fn init(state: Entity(model.AppState), fixtures: ?*fixtures_mod.Fixtures, server_decorations: bool, window: *Window, cx: *Context(Shell)) !Shell {
        const focus = cx.focusHandle();
        window.focus(focus);
        var self: Shell = .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .sidebar = try cx.newWith(sidebar_mod.Sidebar, sidebar_mod.Sidebar.init, .{state}),
            .main = try cx.newWith(main_panel.MainPanel, main_panel.MainPanel.init, .{ state, fixtures }),
            .focus = focus,
            .fixtures = fixtures,
            .server_decorations = server_decorations,
        };
        const s = state.read(cx);
        try self.subs.add(cx.gpa(), try cx.observe(s.engine, onModelChanged));
        try self.subs.add(cx.gpa(), try cx.observe(s.auth, onModelChanged));
        try self.subs.add(cx.gpa(), try cx.observe(s.workspace, onWorkspaceChanged));
        try self.subs.add(cx.gpa(), try cx.subscribe(self.sidebar, onOpenSettings));
        try self.subs.add(cx.gpa(), try cx.subscribe(self.sidebar, onNewSessionEvent));
        try self.subs.add(cx.gpa(), try cx.subscribe(self.sidebar, onSignOutEvent));
        if (fixtures) |f| if (f.meta.splash) {
            self.splash = .visible;
        } else {
            self.splash = .gone;
        };
        self.nav.append(self.gpa, null) catch {};
        return self;
    }

    pub fn deinit(self: *Shell, app: *App) void {
        self.subs.deinit(self.gpa);
        self.palette_subs.deinit(self.gpa);
        if (self.palette) |p| p.release(app);
        if (self.settings_sub) |*sub| sub.deinit();
        if (self.settings_view) |v| v.release(app);
        for (self.surfaces.items) |e| e.release(app);
        self.surfaces.deinit(self.gpa);
        for (self.nav.items) |e| if (e) |s| self.gpa.free(s);
        self.nav.deinit(self.gpa);
        self.focus.release(app);
        self.main.release(app);
        self.sidebar.release(app);
        self.state.release(app);
    }

    fn onModelChanged(_: *Shell, _: anytype, cx: *Context(Shell)) void {
        cx.notify();
    }

    fn onWorkspaceChanged(self: *Shell, ws: Entity(model.WorkspaceStore), cx: *Context(Shell)) void {
        const selected = ws.read(cx).selected_chat;
        self.recordNav(selected);
        cx.notify();
    }

    fn onOpenSettings(self: *Shell, _: Entity(sidebar_mod.Sidebar), _: *const sidebar_mod.OpenSettings, cx: *Context(Shell)) void {
        const w = cx.app.windows.items[0] orelse return;
        self.openSettings(w, cx);
    }

    // ---- settings mode (the page itself lives in ui/settings) -------------------------

    pub fn openSettings(self: *Shell, window: *Window, cx: *Context(Shell)) void {
        if (self.settings_view != null) return;
        if (self.palette != null) self.closePalette(window, cx);
        const V = settings_ui.SettingsView;
        const io = self.state.read(cx).workspace.read(cx).io;
        const dir: ?[]const u8 = if (self.fixtures) |f| f.dir else null;
        const v = cx.newWith(V, V.init, .{ self.state, dir, io, window }) catch return;
        self.settings_sub = cx.subscribe(v, onSettingsClose) catch null;
        self.settings_view = v;
        cx.notify();
    }

    pub fn closeSettings(self: *Shell, window: *Window, cx: *Context(Shell)) void {
        if (self.settings_sub) |*sub| sub.deinit();
        self.settings_sub = null;
        if (self.settings_view) |v| v.release(cx);
        self.settings_view = null;
        window.focus(self.focus);
        cx.notify();
    }

    fn onSettingsClose(_: *Shell, _: Entity(settings_ui.SettingsView), _: *const settings_ui.Close, cx: *Context(Shell)) void {
        cx.deferUpdate(struct {
            fn f(sh: *Shell, c: *Context(Shell)) void {
                const w = c.app.windows.items[0] orelse return;
                sh.closeSettings(w, c);
            }
        }.f);
    }

    fn actOpenSettings(self: *Shell, _: *const shell_actions.OpenSettings, window: *Window, cx: *Context(Shell)) void {
        if (self.settings_view != null) self.closeSettings(window, cx) else self.openSettings(window, cx);
    }

    fn onNewSessionEvent(self: *Shell, _: Entity(sidebar_mod.Sidebar), _: *const sidebar_mod.NewSession, cx: *Context(Shell)) void {
        self.newSession(cx);
    }

    fn onSignOutEvent(self: *Shell, _: Entity(sidebar_mod.Sidebar), _: *const sidebar_mod.SignOut, cx: *Context(Shell)) void {
        const auth = self.state.read(cx).auth;
        auth.update(cx, model.AuthStore.signOut, .{}) catch {};
    }

    // ---- navigation -----------------------------------------------------------------

    fn recordNav(self: *Shell, selected: ?[]const u8) void {
        if (self.nav_suppress) return;
        const cur = self.nav.items[self.nav_ix];
        const same = if (cur) |c| (selected != null and std.mem.eql(u8, c, selected.?)) else selected == null;
        if (same) return;
        // Drop forward history.
        while (self.nav.items.len > self.nav_ix + 1) if (self.nav.pop()) |e| if (e) |s| self.gpa.free(s);
        const copy: ?[]u8 = if (selected) |s| self.gpa.dupe(u8, s) catch null else null;
        self.nav.append(self.gpa, copy) catch return;
        self.nav_ix = self.nav.items.len - 1;
    }

    pub fn canBack(self: *const Shell) bool {
        return self.nav_ix > 0;
    }

    pub fn canForward(self: *const Shell) bool {
        return self.nav_ix + 1 < self.nav.items.len;
    }

    fn applyNav(self: *Shell, cx: *Context(Shell)) void {
        const target = self.nav.items[self.nav_ix];
        self.nav_suppress = true;
        defer self.nav_suppress = false;
        const ws = self.state.read(cx).workspace;
        ws.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, target)});
        cx.notify();
    }

    pub fn navBack(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
        if (!self.canBack()) return;
        self.nav_ix -= 1;
        self.applyNav(cx);
    }

    pub fn navForward(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
        if (!self.canForward()) return;
        self.nav_ix += 1;
        self.applyNav(cx);
    }

    fn newSession(self: *Shell, cx: *Context(Shell)) void {
        const ws = self.state.read(cx).workspace;
        ws.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, null)});
        cx.notify();
    }

    // ---- pane state -----------------------------------------------------------------

    fn now(cx: anytype) u64 {
        return ui.loaders.nowNs(cx);
    }

    pub fn sidebarTarget(cx: anytype) f32 {
        const p = prefs_mod.get(cx);
        return if (p.sidebar_collapsed) 0 else p.sidebar_width;
    }

    pub fn sidebarNow(self: *Shell, cx: anytype) f32 {
        const target = sidebarTarget(cx);
        if (self.sidebar_tween) |t| {
            if (t.to == target and !t.done(now(cx), motion.resize)) return t.value(now(cx), motion.resize);
            self.sidebar_tween = null;
        }
        return target;
    }

    fn rightTarget(self: *Shell, cx: anytype) f32 {
        const p = prefs_mod.get(cx);
        if (!p.right_pane_open) return 0;
        if (self.state.read(cx).workspace.read(cx).selected_chat == null) return 0;
        return p.right_pane_width;
    }

    pub fn rightNow(self: *Shell, cx: anytype) f32 {
        const target = self.rightTarget(cx);
        if (self.right_tween) |t| {
            if (t.to == target and !t.done(now(cx), motion.resize)) return t.value(now(cx), motion.resize);
            self.right_tween = null;
        }
        return target;
    }

    fn tweening(self: *const Shell) bool {
        return self.sidebar_tween != null or self.right_tween != null;
    }

    fn toggleSidebar(self: *Shell, cx: *Context(Shell)) void {
        const from = self.sidebarNow(cx);
        const p = prefs_mod.mut(cx);
        p.sidebar_collapsed = !p.sidebar_collapsed;
        self.sidebar_tween = .{ .from = from, .to = sidebarTarget(cx), .start_ns = now(cx) };
        cx.notify();
    }

    fn toggleRight(self: *Shell, cx: *Context(Shell)) void {
        const from = self.rightNow(cx);
        const p = prefs_mod.mut(cx);
        p.right_pane_open = !p.right_pane_open;
        self.right_tween = .{ .from = from, .to = self.rightTarget(cx), .start_ns = now(cx) };
        cx.notify();
    }

    pub fn onToggleSidebarClick(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
        self.toggleSidebar(cx);
    }

    pub fn onToggleRightClick(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
        self.toggleRight(cx);
    }

    pub fn onNewSessionClick(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
        self.newSession(cx);
    }

    // ---- actions ----------------------------------------------------------------------

    fn actToggleSidebar(self: *Shell, _: *const shell_actions.ToggleSidebar, _: *Window, cx: *Context(Shell)) void {
        self.toggleSidebar(cx);
    }
    fn actToggleChanges(self: *Shell, _: *const shell_actions.ToggleChanges, _: *Window, cx: *Context(Shell)) void {
        self.toggleRight(cx);
    }
    fn actToggleFiles(self: *Shell, _: *const shell_actions.ToggleFiles, _: *Window, cx: *Context(Shell)) void {
        self.toggleRight(cx);
    }
    fn actToggleTerminal(_: *Shell, _: *const actions.terminal.ToggleTerminal, _: *Window, cx: *Context(Shell)) void {
        const p = prefs_mod.mut(cx);
        p.terminal_open = !p.terminal_open;
        cx.notify();
    }
    fn actTogglePalette(self: *Shell, _: *const shell_actions.ToggleCommandPalette, window: *Window, cx: *Context(Shell)) void {
        if (self.palette != null) return self.closePalette(window, cx);
        const p = palette_mod.Palette;
        const pal = cx.newWith(p, p.init, .{ self.state, window }) catch return;
        self.palette_subs.add(self.gpa, cx.subscribe(pal, onPaletteClose) catch return) catch {};
        self.palette_subs.add(self.gpa, cx.subscribe(pal, onPaletteActivate) catch return) catch {};
        self.palette = pal;
        cx.notify();
    }

    fn closePalette(self: *Shell, window: *Window, cx: *Context(Shell)) void {
        self.palette_subs.deinit(self.gpa);
        self.palette_subs = .{};
        if (self.palette) |p| p.release(cx);
        self.palette = null;
        window.focus(self.focus);
        cx.notify();
    }

    fn onPaletteClose(self: *Shell, _: Entity(palette_mod.Palette), _: *const palette_mod.Close, cx: *Context(Shell)) void {
        self.deferClose(cx);
    }

    fn deferClose(self: *Shell, cx: *Context(Shell)) void {
        _ = self;
        cx.deferUpdate(struct {
            fn f(sh: *Shell, c: *Context(Shell)) void {
                const w = c.app.windows.items[0] orelse return;
                sh.closePalette(w, c);
            }
        }.f);
    }

    fn onPaletteActivate(self: *Shell, _: Entity(palette_mod.Palette), ev: *const palette_mod.Activate, cx: *Context(Shell)) void {
        switch (ev.entry) {
            .theme_light, .theme_dark => {
                const appearance: zt.Appearance = if (ev.entry == .theme_light) .light else .dark;
                ui.theme.set(cx.app, zt.Theme.forSelection(&zt.registry.builtin, .{
                    .appearance = appearance,
                    .variant_id = if (appearance == .dark) "zeron-dark" else "zeron-light",
                    .surface = .frosted,
                }));
                return;
            },
            .new_chat => self.newSession(cx),
            .chat => if (ev.chat_id) |id| {
                const copy = self.gpa.dupe(u8, id) catch return;
                defer self.gpa.free(copy);
                const ws = self.state.read(cx).workspace;
                ws.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, copy)});
            },
            else => {},
        }
        self.deferClose(cx);
    }

    pub fn activeSurface(self: *Shell) ?Entity(terminal_dock.TerminalDock) {
        if (self.surfaces.items.len == 0) return null;
        return self.surfaces.items[@min(self.surface_active, self.surfaces.items.len - 1)];
    }

    pub fn onAddTerminalSurface(self: *Shell, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Shell)) void {
        self.newtab_menu_open = false;
        const ws = self.state.read(cx).workspace.read(cx);
        const chat = ws.selectedChatRow();
        const cwd: ?[]const u8 = if (chat) |c| (c.cwd orelse if (ws.spaceForChat(c)) |sp| sp.path else null) else null;
        const T = terminal_dock.TerminalDock;
        const e = cx.newWith(T, T.init, .{ ws.io, cwd, window }) catch return;
        {
            var l = e.lease(cx);
            defer l.end();
            l.value.chrome = false;
        }
        self.surfaces.append(self.gpa, e) catch {
            e.release(cx);
            return;
        };
        self.surface_active = self.surfaces.items.len - 1;
        cx.notify();
    }

    pub fn onSelectSurface(self: *Shell, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
        self.surface_active = ix;
        cx.notify();
    }

    pub fn onCloseSurface(self: *Shell, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
        cx.stopPropagation();
        if (ix >= self.surfaces.items.len) return;
        self.surfaces.orderedRemove(ix).release(cx);
        if (self.surface_active >= self.surfaces.items.len and self.surface_active > 0) self.surface_active -= 1;
        cx.notify();
    }

    pub fn onNewTabMenu(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
        self.newtab_menu_open = !self.newtab_menu_open;
        cx.notify();
    }

    pub fn onCloseNewTabMenu(self: *Shell, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(Shell)) void {
        if (self.newtab_menu_open) {
            self.newtab_menu_open = false;
            cx.notify();
        }
    }

    fn actNewSession(self: *Shell, _: *const shell_actions.NewSession, _: *Window, cx: *Context(Shell)) void {
        self.newSession(cx);
    }
    fn actCycle(self: *Shell, forward: bool, cx: *Context(Shell)) void {
        const ws_e = self.state.read(cx).workspace;
        const ws = ws_e.read(cx);
        const p = prefs_mod.get(cx);
        const arena = zpui.window.arena_mod.frameAllocator();
        const rows = ws.sidebarChats(arena, p.now(ws.io), p.space_filter) catch return;
        if (rows.len == 0) return;
        var ix: usize = 0;
        var found = false;
        if (ws.selected_chat) |sel| for (rows, 0..) |r, i| if (std.mem.eql(u8, r.chat.id, sel)) {
            ix = i;
            found = true;
        };
        const next = if (!found) 0 else if (forward) (ix + 1) % rows.len else (ix + rows.len - 1) % rows.len;
        const id = arena.dupe(u8, rows[next].chat.id) catch return;
        ws_e.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, id)});
    }
    fn actNext(self: *Shell, _: *const shell_actions.NextSession, _: *Window, cx: *Context(Shell)) void {
        self.actCycle(true, cx);
    }
    fn actPrev(self: *Shell, _: *const shell_actions.PrevSession, _: *Window, cx: *Context(Shell)) void {
        self.actCycle(false, cx);
    }
    fn actJump(self: *Shell, jump: *const shell_actions.JumpSession, _: *Window, cx: *Context(Shell)) void {
        const ws_e = self.state.read(cx).workspace;
        const ws = ws_e.read(cx);
        const p = prefs_mod.get(cx);
        const arena = zpui.window.arena_mod.frameAllocator();
        const rows = ws.sidebarChats(arena, p.now(ws.io), p.space_filter) catch return;
        if (jump.slot >= rows.len) return;
        const id = arena.dupe(u8, rows[jump.slot].chat.id) catch return;
        ws_e.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, id)});
    }

    // ---- resize -----------------------------------------------------------------------

    fn onSidebarDrag(self: *Shell, ev: *const zpui.DragMoveEvent(SidebarResize), _: *Window, cx: *Context(Shell)) void {
        const p = prefs_mod.mut(cx);
        p.sidebar_width = std.math.clamp(ev.event.position.x, layout.sidebar_min, layout.sidebar_max);
        p.sidebar_collapsed = false;
        self.sidebar_tween = null;
        cx.notify();
    }

    fn onRightDrag(self: *Shell, ev: *const zpui.DragMoveEvent(RightPaneResize), window: *Window, cx: *Context(Shell)) void {
        const vw = window.viewportSize().width;
        const p = prefs_mod.mut(cx);
        const max = @max(layout.right_pane_min, vw - sidebarTarget(cx) - layout.chat_panel_min);
        p.right_pane_width = std.math.clamp(vw - ev.event.position.x, layout.right_pane_min, max);
        self.right_tween = null;
        cx.notify();
    }

    fn onSidebarSeamClick(_: *Shell, ev: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
        if (ev.clickCount() == 2) {
            prefs_mod.mut(cx).sidebar_width = layout.sidebar_default;
            cx.notify();
        }
    }

    fn onRightSeamClick(_: *Shell, ev: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
        if (ev.clickCount() == 2) {
            prefs_mod.mut(cx).right_pane_width = layout.right_pane_default;
            cx.notify();
        }
    }

    fn resizeHandle(comptime T: type, id: []const u8, listener: anytype) zpui.StatefulDiv {
        return div().id(id).absolute().top(px(layout.titlebar_height)).bottom(px(0))
            .left(px(-resize_hitbox_half)).w(px(resize_hitbox_half * 2))
            .cursorColResize()
            .onDrag(T{}, buildGhost(T))
            .onClick(listener);
    }

    // ---- window chrome ----------------------------------------------------------------

    pub fn windowCornerRadius(self: *const Shell, window: *Window) f32 {
        if (!is_linux or self.server_decorations) return 0;
        if (window.isMaximized() or window.isFullscreen()) return 0;
        return layout.linux_window_corner_radius;
    }

    pub fn linuxCaptions(self: *const Shell) usize {
        return if (is_linux and !self.server_decorations) 3 else 0;
    }

    // ---- render -----------------------------------------------------------------------

    pub fn gate(self: *Shell, cx: anytype) model.view.GatePhase {
        if (self.fixtures) |f| return f.gate();
        return self.state.read(cx).gate(cx);
    }

    pub fn render(self: *Shell, window: *Window, cx: *Context(Shell)) zpui.Div {
        const theme = ui.theme.get(cx);
        const g = self.gate(cx);
        const radius = self.windowCornerRadius(window);

        // Splash lifecycle: visible while loading, then a 650ms lift-out.
        const fixture_splash = if (self.fixtures) |f| f.meta.splash else false;
        if (self.splash == .visible and g != .loading and !fixture_splash) {
            self.splash = .fading;
            self.splash_fade_start = now(cx);
        }
        if (self.splash == .fading and now(cx) -| self.splash_fade_start > motion.splash_out.totalNs(1.0)) self.splash = .gone;

        var root = div()
            .trackFocus(self.focus)
            .keyContext("Shell")
            .onAction(shell_actions.ToggleSidebar, cx.listener(Shell.actToggleSidebar))
            .onAction(shell_actions.ToggleChanges, cx.listener(Shell.actToggleChanges))
            .onAction(shell_actions.ToggleFiles, cx.listener(Shell.actToggleFiles))
            .onAction(actions.terminal.ToggleTerminal, cx.listener(Shell.actToggleTerminal))
            .onAction(shell_actions.NewSession, cx.listener(Shell.actNewSession))
            .onAction(shell_actions.ToggleCommandPalette, cx.listener(Shell.actTogglePalette))
            .onAction(shell_actions.OpenSettings, cx.listener(Shell.actOpenSettings))
            .onAction(shell_actions.NextSession, cx.listener(Shell.actNext))
            .onAction(shell_actions.PrevSession, cx.listener(Shell.actPrev))
            .onAction(shell_actions.JumpSession, cx.listener(Shell.actJump))
            .onDragMove(SidebarResize, cx.listener(Shell.onSidebarDrag))
            .onDragMove(RightPaneResize, cx.listener(Shell.onRightDrag))
            .relative().flex().flexRow().sizeFull()
            .bg(theme.glass())
            .textColor(theme.text)
            .fontFamily(theme.font_sans)
            .textSize(ui.rems(14));
        if (radius > 0) root = root.rounded(px(radius)).overflowHidden();

        root = switch (g) {
            .ready => root.child(self.renderReady(window, cx)),
            .loading => root,
            .org_gate => root.child(gates.orgGate(self, theme, cx)),
            .failed => |msg| root.child(gates.failedGate(self, msg, theme, cx)),
            .sign_in => root.child(gates.signInGate(self, theme, cx)),
        };

        if (self.splash != .gone) {
            const t: f32 = if (self.splash == .fading)
                motion.splash_out.progressAt(now(cx) -| self.splash_fade_start, 1.0)
            else
                0;
            const frame = motion.splashOutFrame(t);
            root = root.child(div().absolute().inset0().top(px(frame.offset_y)).opacity(frame.opacity)
                .bg(theme.glass()).flex().flexCol().itemsCenter().justifyCenter().gap(px(12))
                .child(ui.loaders.gradientSpinner(2.5, ui.loaders.phaseOf(cx, motion.gradient_spin)))
                .child(div().textSize(ui.rems(12)).textColor(theme.text_muted.opacity(0.7)).child("Setting up Zeron environment")));
            window.requestAnimationFrame();
        }

        if (self.palette) |p| root = root.child(p);
        if (g != .ready and !is_mac) root = root.child(titlebar.dragStrip(self, "gate-titlebar-drag", cx));
        root = root.child(titlebar.linuxCaptions(self, window, theme, cx));
        root = root.child(titlebar.linuxResizeBorders(self, window));
        if (self.tweening()) window.requestAnimationFrame();
        ui.hover.tick(window, cx);
        return root;
    }

    fn renderReady(self: *Shell, window: *Window, cx: *Context(Shell)) zpui.Div {
        const theme = ui.theme.get(cx);
        const radius = self.windowCornerRadius(window);
        const sidebar_now = self.sidebarNow(cx);
        const right_now = self.rightNow(cx);
        const prefs = prefs_mod.get(cx);

        // Settings mode takes over the window (ui/settings): tone + page, no titlebar cluster.
        const settings_mode = self.settings_view != null;

        // Sidebar tone: wash 0.05 column with a hairline on its right edge.
        var tone = div().absolute().top(px(0)).bottom(px(0)).left(px(0)).w(px(sidebar_now))
            .bg(theme.wash(0.05)).borderR1().borderColor(theme.border);
        if (radius > 0) {
            if (sidebar_now >= 2 * radius) tone = tone.roundedTl(px(radius)).roundedBl(px(radius)) else tone = tone.top(px(radius)).bottom(px(radius));
        }

        if (settings_mode) return div().absolute().inset0().child(tone).child(div().absolute().inset0().child(self.settings_view.?));

        const sidebar_col = div().hFull().flexNone().overflowHidden().w(px(sidebar_now))
            .child(div().hFull().pt(px(layout.titlebar_height))
                .child(div().w(px(prefs.sidebar_width)).hFull().flexNone().child(self.sidebar)));

        const sidebar_seam = div().w(px(0)).hFull().flexNone().relative()
            .child(if (sidebar_now > 0) resizeHandle(SidebarResize, "sidebar-resize", cx.listener(Shell.onSidebarSeamClick)) else null);

        {
            const vw = window.viewportSize().width;
            var l = self.main.lease(cx);
            defer l.end();
            l.value.width = @max(vw - sidebar_now - right_now, 0);
        }
        const card = div().flex1().minW0().flex().flexRow().overflowHidden().child(self.main);

        // Right pane: a flush, left-bordered panel padded below the titlebar.
        var right_wrap = div().hFull().flexNone().relative();
        if (right_now > 0.5) {
            right_wrap = right_wrap.child(div().hFull().flexNone().relative().overflowHidden().w(px(right_now))
                .child(div().absolute().top(px(0)).right(px(0)).hFull().w(px(@max(prefs.right_pane_width, right_now)))
                    .child(main_panel.rightPane(self, theme, cx))));
            if (self.right_tween == null)
                right_wrap = right_wrap.child(div().absolute().left(px(0)).top(px(0)).w(px(0)).hFull()
                    .child(resizeHandle(RightPaneResize, "right-pane-resize", cx.listener(Shell.onRightSeamClick))));
        }

        const page = div().sizeFull().relative()
            .child(div().sizeFull().flex().flexRow()
                .child(sidebar_col)
                .child(sidebar_seam)
                .child(card)
                .child(right_wrap))
            .child(div().absolute().top(px(0)).left(px(0)).right(px(0)).child(titlebar.sessionBar(self, sidebar_now, right_now, theme, cx)))
            .child(titlebar.cluster(self, theme, cx));

        return div().absolute().inset0().child(tone).child(ui.anim.fadeIn("phase-app", page));
    }
};
