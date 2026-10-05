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
const app_update = @import("../../lifecycle/app_update.zig"); // [lifecycle]
const prefs_mod = @import("prefs.zig");
const fixtures_mod = @import("fixtures.zig");
const sidebar_mod = @import("../sidebar/sidebar.zig");
const titlebar = @import("titlebar.zig");
const gates = @import("gates.zig");
const main_panel = @import("main_panel.zig");
const palette_mod = @import("palette.zig");
const terminal_dock = @import("terminal_dock.zig");
const right_pane_mod = @import("right_pane.zig");
const pickers_mod = @import("../pickers/root.zig");
const settings_ui = @import("../settings/root.zig"); // settings mode (ui/settings owns it)
const wiring_mod = @import("wiring.zig"); // [wiring] event routing (composer, links, dialogs, actions)
const smoke_probe = @import("smoke_probe.zig"); // CI smoke: frosted-menu blur probe

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
    /// The explorer column's width tween (mod-e).
    files_tween: ?Tween = null,
    /// Navigation history of selected chats (null = new-session canvas).
    nav: std.ArrayList(?[]u8) = .empty,
    nav_ix: usize = 0,
    nav_suppress: bool = false,
    server_decorations: bool = false,
    palette: ?Entity(palette_mod.Palette) = null,
    /// The "New project" palette (pickers/add_project.zig).
    add_project: ?Entity(pickers_mod.AddProject) = null,
    add_project_subs: zpui.Subscriptions = .{},
    /// The right-pane surface host (per-chat tabs).
    right_pane: Entity(right_pane_mod.RightPane),
    /// Right-pane takeover (the header's expand button).
    right_expanded: bool = false,
    viewport_w: f32 = 1320,
    /// Last OS appearance seen (re-resolves a `system` theme on change).
    system_appearance: ?zpui.platform.WindowAppearance = null,
    palette_subs: zpui.Subscriptions = .{},
    // ---- settings mode (ui/settings/view.zig) ----
    settings_view: ?Entity(settings_ui.SettingsView) = null,
    settings_sub: ?zpui.Subscription = null,
    // [wiring] routed flows' state (ui/shell/wiring.zig).
    wiring: wiring_mod.State = .{},
    /// CI smoke only (`ZERON_SMOKE_MENU`): the frosted-menu blur probe.
    smoke_probe: smoke_probe.Mode = .off,
    /// [appshots] Last selected chat (Appshot "Last session" destination).
    last_appshot_chat: ?[]u8 = null,

    pub fn init(state: Entity(model.AppState), fixtures: ?*fixtures_mod.Fixtures, server_decorations: bool, window: *Window, cx: *Context(Shell)) !Shell {
        const focus = cx.focusHandle();
        window.focus(focus);
        var self: Shell = .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .sidebar = try cx.newWith(sidebar_mod.Sidebar, sidebar_mod.Sidebar.init, .{state}),
            .main = try cx.newWith(main_panel.MainPanel, main_panel.MainPanel.init, .{ state, fixtures }),
            .right_pane = try cx.newWith(right_pane_mod.RightPane, right_pane_mod.RightPane.init, .{ state, fixtures, prefs_mod.get(cx).right_pane_open }),
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
        try self.subs.add(cx.gpa(), try cx.subscribe(self.right_pane, onSurfacesEmptied));
        try self.subs.add(cx.gpa(), try cx.subscribe(self.right_pane, onOpenExplorer));
        try self.subs.add(cx.gpa(), try cx.observe(self.right_pane, onModelChanged));
        if (fixtures) |f| if (f.meta.splash) {
            self.splash = .visible;
        } else {
            self.splash = .gone;
        };
        self.nav.append(self.gpa, null) catch {};
        try wiring_mod.attach(&self, cx); // [wiring]
        return self;
    }

    pub fn deinit(self: *Shell, app: *App) void {
        wiring_mod.detach(self, app); // [wiring]
        self.subs.deinit(self.gpa);
        self.palette_subs.deinit(self.gpa);
        if (self.palette) |p| p.release(app);
        self.add_project_subs.deinit(self.gpa);
        if (self.add_project) |p| p.release(app);
        if (self.settings_sub) |*sub| sub.deinit();
        if (self.settings_view) |v| v.release(app);
        self.right_pane.release(app);
        for (self.nav.items) |e| if (e) |s| self.gpa.free(s);
        self.nav.deinit(self.gpa);
        if (self.last_appshot_chat) |s| self.gpa.free(s); // [appshots]
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
        @import("appshots.zig").noteSelection(self, selected); // [appshots]
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

    pub fn rightOpen(self: *Shell, cx: anytype) bool {
        if (self.state.read(cx).workspace.read(cx).selected_chat == null) return false;
        return self.right_pane.read(cx).isOpen(cx);
    }

    fn rightTarget(self: *Shell, cx: anytype) f32 {
        if (!self.rightOpen(cx)) return 0;
        const p = prefs_mod.get(cx);
        if (self.right_expanded) return @max(self.viewport_w - self.sidebarNow(cx), 0);
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
        return self.sidebar_tween != null or self.right_tween != null or self.files_tween != null;
    }

    // ---- explorer column (ui/files FilesPanel, mod-e) ----------------------------------

    pub fn filesOpen(self: *Shell, cx: anytype) bool {
        if (self.state.read(cx).workspace.read(cx).selected_chat == null) return false;
        return self.right_pane.read(cx).filesOpen(cx);
    }

    fn filesTarget(self: *Shell, cx: anytype) f32 {
        if (!self.filesOpen(cx)) return 0;
        const w = if (model.settings_store.current(cx.app)) |st| st.filesPanelWidth else layout.files_panel_default;
        // Never squeeze the conversation below its floor for the tree.
        const avail = @max(self.viewport_w - self.sidebarNow(cx) - layout.chat_panel_min - self.rightTarget(cx), layout.files_panel_min);
        return @min(w, avail);
    }

    pub fn filesNow(self: *Shell, cx: anytype) f32 {
        const target = self.filesTarget(cx);
        if (self.files_tween) |t| {
            if (t.to == target and !t.done(now(cx), motion.resize)) return t.value(now(cx), motion.resize);
            self.files_tween = null;
        }
        return target;
    }

    /// The explorer's own toggle: docking it opens the pane with just that
    /// portion when the surface host is closed.
    pub fn toggleFiles(self: *Shell, window: *Window, cx: *Context(Shell)) void {
        if (self.state.read(cx).workspace.read(cx).selected_chat == null) return;
        const from = self.filesNow(cx);
        const open = !self.filesOpen(cx);
        self.right_pane.update(cx, right_pane_mod.RightPane.setFilesOpen, .{ open, @as(?*Window, window) });
        if (!open) window.focus(self.focus);
        self.files_tween = .{ .from = from, .to = self.filesTarget(cx), .start_ns = now(cx) };
        cx.notify();
    }

    pub fn onToggleFilesClick(self: *Shell, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Shell)) void {
        self.toggleFiles(window, cx);
    }

    fn onOpenExplorer(_: *Shell, _: Entity(right_pane_mod.RightPane), _: *const right_pane_mod.OpenExplorer, cx: *Context(Shell)) void {
        cx.deferUpdate(struct {
            fn f(sh: *Shell, c: *Context(Shell)) void {
                const w = c.app.windows.items[0] orelse return;
                if (!sh.filesOpen(c)) sh.toggleFiles(w, c);
            }
        }.f);
    }

    fn toggleSidebar(self: *Shell, cx: *Context(Shell)) void {
        const from = self.sidebarNow(cx);
        const p = prefs_mod.mut(cx);
        p.sidebar_collapsed = !p.sidebar_collapsed;
        self.sidebar_tween = .{ .from = from, .to = sidebarTarget(cx), .start_ns = now(cx) };
        cx.notify();
    }

    fn toggleRight(self: *Shell, cx: *Context(Shell)) void {
        self.setRightOpen(!self.rightOpen(cx), cx);
    }

    /// Show or hide the surface host (a no-op on the canvas / when already there).
    pub fn setRightOpen(self: *Shell, open: bool, cx: *Context(Shell)) void {
        if (self.state.read(cx).workspace.read(cx).selected_chat == null) return;
        if (self.rightOpen(cx) == open) return;
        const from = self.rightNow(cx);
        self.right_pane.update(cx, right_pane_mod.RightPane.setOpen, .{open});
        // Closing always leaves takeover mode.
        if (!open) self.right_expanded = false;
        self.right_tween = .{ .from = from, .to = self.rightTarget(cx), .start_ns = now(cx) };
        cx.notify();
    }

    fn onSurfacesEmptied(_: *Shell, _: Entity(right_pane_mod.RightPane), _: *const right_pane_mod.SurfacesEmptied, cx: *Context(Shell)) void {
        cx.deferUpdate(struct {
            fn f(sh: *Shell, c: *Context(Shell)) void {
                sh.setRightOpen(false, c);
            }
        }.f);
    }

    /// The header's expand button: the pane takes over everything right of the sidebar.
    pub fn onToggleExpandClick(self: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Shell)) void {
        const from = self.rightNow(cx);
        self.right_expanded = !self.right_expanded;
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
    fn actToggleFiles(self: *Shell, _: *const shell_actions.ToggleFiles, window: *Window, cx: *Context(Shell)) void {
        self.toggleFiles(window, cx);
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

    /// [wiring] `/resume` and other programmatic opens of the command palette.
    pub fn togglePalette(self: *Shell, window: *Window, cx: *Context(Shell)) void {
        self.actTogglePalette(&shell_actions.ToggleCommandPalette{}, window, cx);
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
            .new_project => {
                self.deferClose(cx);
                cx.deferUpdate(struct {
                    fn f(sh: *Shell, c: *Context(Shell)) void {
                        const w = c.app.windows.items[0] orelse return;
                        sh.openAddProject(w, c);
                    }
                }.f);
                return;
            },
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

    // ---- New project palette ---------------------------------------------------------

    pub fn openAddProject(self: *Shell, window: *Window, cx: *Context(Shell)) void {
        if (self.add_project != null) return;
        if (self.palette != null) self.closePalette(window, cx);
        const P = pickers_mod.AddProject;
        const p = cx.newWith(P, P.init, .{ self.state, self.fixtures, window }) catch return;
        self.add_project_subs.add(self.gpa, cx.subscribe(p, onAddProjectClose) catch return) catch {};
        self.add_project_subs.add(self.gpa, cx.subscribe(p, onAddProjectCreated) catch return) catch {};
        self.add_project = p;
        cx.notify();
    }

    fn closeAddProject(self: *Shell, window: *Window, cx: *Context(Shell)) void {
        self.add_project_subs.deinit(self.gpa);
        self.add_project_subs = .{};
        if (self.add_project) |p| p.release(cx);
        self.add_project = null;
        window.focus(self.focus);
        cx.notify();
    }

    fn deferCloseAddProject(_: *Shell, cx: *Context(Shell)) void {
        cx.deferUpdate(struct {
            fn f(sh: *Shell, c: *Context(Shell)) void {
                const w = c.app.windows.items[0] orelse return;
                sh.closeAddProject(w, c);
            }
        }.f);
    }

    fn onAddProjectClose(self: *Shell, _: Entity(pickers_mod.AddProject), _: *const pickers_mod.add_project.Close, cx: *Context(Shell)) void {
        self.deferCloseAddProject(cx);
    }

    /// `land_in_space`: the new project opens on the canvas (an explicit
    /// sidebar filter follows it).
    fn onAddProjectCreated(self: *Shell, _: Entity(pickers_mod.AddProject), ev: *const pickers_mod.add_project.Created, cx: *Context(Shell)) void {
        const id = self.gpa.dupe(u8, ev.space_id) catch return;
        defer self.gpa.free(id);
        if (prefs_mod.get(cx).space_filter != null) prefs_mod.mut(cx).setFilter(id);
        const ws = self.state.read(cx).workspace;
        ws.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, null)});
        ws.update(cx, model.WorkspaceStore.selectSpace, .{@as(?[]const u8, id)});
        self.deferCloseAddProject(cx);
    }

    fn actAddSpace(self: *Shell, _: *const shell_actions.AddSpacePalette, window: *Window, cx: *Context(Shell)) void {
        if (self.add_project != null) self.closeAddProject(window, cx) else self.openAddProject(window, cx);
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
        p.right_pane_width = std.math.clamp(vw - self.filesNow(cx) - ev.event.position.x, layout.right_pane_min, max);
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
        return div().id(id).role(.separator).ariaLabel(if (T == SidebarResize) "Resize sidebar" else "Resize panel").ariaOrientation(.vertical).absolute().top(px(layout.titlebar_height)).bottom(px(0))
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

    /// CI smoke: show / hide the frosted-menu blur probe (`smoke_probe.zig`).
    pub fn setSmokeProbe(self: *Shell, mode: smoke_probe.Mode, cx: *Context(Shell)) void {
        self.smoke_probe = mode;
        cx.notify();
    }

    pub fn gate(self: *Shell, cx: anytype) model.view.GatePhase {
        if (self.fixtures) |f| return f.gate();
        return self.state.read(cx).gate(cx);
    }

    pub fn render(self: *Shell, window: *Window, cx: *Context(Shell)) zpui.Div {
        // [liquid-glass] Glass material follows zeron's theme, not the OS appearance.
        window.glass_dark = ui.theme.get(cx).appearance == .dark;
        // Reduce motion / pause in background (settings × OS × focus).
        settings_ui.motion.sync(window, cx.app);
        // The OS flipped light/dark (Linux settings portal, macOS effective
        // appearance): re-resolve a `system` theme on the next tick.
        const sys = window.windowAppearance();
        if (self.system_appearance != null and self.system_appearance.? != sys) {
            cx.deferUpdate(struct {
                fn f(_: *Shell, c: *Context(Shell)) void {
                    settings_ui.store.applyTheme(c.app);
                }
            }.f);
        }
        self.system_appearance = sys;
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
            .onAction(shell_actions.AddSpacePalette, cx.listener(Shell.actAddSpace))
            .onAction(shell_actions.ToggleCommandPalette, cx.listener(Shell.actTogglePalette))
            .onAction(shell_actions.OpenSettings, cx.listener(Shell.actOpenSettings))
            .onAction(shell_actions.NextSession, cx.listener(Shell.actNext))
            .onAction(shell_actions.PrevSession, cx.listener(Shell.actPrev))
            .onAction(shell_actions.JumpSession, cx.listener(Shell.actJump))
            .onDragMove(SidebarResize, cx.listener(Shell.onSidebarDrag))
            .onDragMove(RightPaneResize, cx.listener(Shell.onRightDrag))
            .relative().flex().flexRow().sizeFull()
            .textColor(theme.text)
            .fontFamily(theme.font_sans)
            .textSize(ui.rems(14));
        // [liquid-glass] Liquid Glass (ready): renderReady paints the window tint around
        // the sidebar glass instead, leaving alpha 0 under it (the desktop shows through).
        if (!(theme.isLiquid() and g == .ready)) root = root.bg(theme.glass());
        root = wiring_mod.actionsOn(root, cx); // [wiring] SaveFile / ArchiveSession / OpenModelPicker
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

        if (self.smoke_probe != .off) root = root.child(smoke_probe.element(theme, self.smoke_probe));
        if (self.palette) |p| root = root.child(p);
        if (self.add_project) |p| root = root.child(p);
        // [lifecycle] the "Check for Updates…" dialog (lifecycle/app_update.zig).
        if (app_update.AppUpdate.global(cx.app)) |u| if (u.read(cx).prompt != null) {
            root = root.child(u);
        };
        // [wiring] confirmations + per-frame upkeep (link root, explorer rows).
        if (g == .ready) {
            wiring_mod.tick(self, cx);
            if (wiring_mod.overlays(self, window, cx)) |o| root = root.child(o);
        }
        if (g != .ready and !is_mac) root = root.child(titlebar.dragStrip(self, "gate-titlebar-drag", cx));
        root = root.child(titlebar.linuxCaptions(self, window, theme, cx));
        root = root.child(titlebar.linuxResizeBorders(self, window));
        if (self.tweening()) window.requestAnimationFrame();
        ui.hover.tick(window, cx);
        return root;
    }

    /// The right pane: a flush, left-bordered panel under the titlebar band
    /// (the band carries the surface tabs), the active surface or launcher.
    fn renderRightPanel(self: *Shell, window: *Window, theme: *const Theme, cx: *Context(Shell)) zpui.Div {
        const content = blk: {
            var l = self.right_pane.lease(cx);
            defer l.end();
            break :blk l.value.renderContent(theme, &l.cx);
        };
        var panel = div().sizeFull().flex().flexCol().bg(theme.panelBg()).overflowHidden()
            .pt(px(layout.titlebar_height))
            .child(div().flex1().minH0().relative().child(content));
        if (!self.right_expanded) panel = panel.borderL1().borderColor(theme.border);
        const radius = self.windowCornerRadius(window);
        if (radius > 0 and self.filesNow(cx) <= 0) panel = panel.roundedTr(px(radius)).roundedBr(px(radius));
        return panel;
    }

    fn renderReady(self: *Shell, window: *Window, cx: *Context(Shell)) zpui.Div {
        const theme = ui.theme.get(cx);
        const radius = self.windowCornerRadius(window);
        self.viewport_w = window.viewportSize().width;
        const sidebar_now = self.sidebarNow(cx);
        const right_now = self.rightNow(cx);
        const files_now = self.filesNow(cx);
        const prefs = prefs_mod.get(cx);

        // Settings mode takes over the window (ui/settings): tone + page, no titlebar cluster.
        const settings_mode = self.settings_view != null;

        // Sidebar tone: wash 0.05 column with a hairline on its right edge.
        var tone = div().absolute().top(px(0)).bottom(px(0)).left(px(0)).w(px(sidebar_now))
            .bg(theme.wash(0.05)).borderR1().borderColor(theme.border);
        if (radius > 0) {
            if (sidebar_now >= 2 * radius) tone = tone.roundedTl(px(radius)).roundedBl(px(radius)) else tone = tone.top(px(radius)).bottom(px(radius));
        }
        // [liquid-glass] A native glass pane replaces the wash column (the window tint
        // goes around it, so the glass sees the desktop); the sidebar, titlebar and
        // cluster then paint on the overlay plane above glass.
        const liquid = theme.isLiquid();
        if (liquid) tone = liquidSidebar(theme, sidebar_now, window, cx);

        if (settings_mode) return div().absolute().inset0().child(tone).child(div().absolute().inset0().child(zpui.overlayPlane(liquid, div().sizeFull().child(self.settings_view.?)))); // [liquid-glass]

        const sidebar_col = div().hFull().flexNone().overflowHidden().w(px(sidebar_now))
            .child(div().hFull().pt(px(layout.titlebar_height))
                .child(div().w(px(prefs.sidebar_width)).hFull().flexNone().child(self.sidebar)));

        const sidebar_seam = div().w(px(0)).hFull().flexNone().relative()
            .child(if (sidebar_now > 0) resizeHandle(SidebarResize, "sidebar-resize", cx.listener(Shell.onSidebarSeamClick)) else null);

        {
            const vw = window.viewportSize().width;
            var l = self.main.lease(cx);
            defer l.end();
            l.value.width = @max(vw - sidebar_now - right_now - files_now, 0);
        }
        const card = div().flex1().minW0().flex().flexRow().overflowHidden().child(self.main);

        // Right pane: a flush, left-bordered panel padded below the titlebar.
        var right_wrap = div().hFull().flexNone().relative();
        if (right_now > 0.5) {
            right_wrap = right_wrap.child(div().hFull().flexNone().relative().overflowHidden().w(px(right_now))
                .child(div().absolute().top(px(0)).right(px(0)).hFull().w(px(@max(prefs.right_pane_width, right_now)))
                    .child(self.renderRightPanel(window, theme, cx))));
            if (self.right_tween == null)
                right_wrap = right_wrap.child(div().absolute().left(px(0)).top(px(0)).w(px(0)).hFull()
                    .child(resizeHandle(RightPaneResize, "right-pane-resize", cx.listener(Shell.onRightSeamClick))));
        }

        // The explorer: the right pane's rightmost column (its left hairline is
        // the divider from the surface host), fixed-width content clipped by
        // the animated column.
        var files_col: ?zpui.Div = null;
        if (files_now > 0.5) if (self.right_pane.read(cx).explorerView(cx)) |explorer| {
            const content_w = @max(self.filesTarget(cx), if (self.files_tween) |t| @max(t.from, t.to) else 0);
            var inner = div().w(px(content_w)).hFull().pt(px(layout.titlebar_height)).occlude()
                .borderL1().borderColor(theme.border).bg(theme.panelBg()).overflowHidden()
                .child(explorer);
            if (radius > 0) inner = inner.roundedTr(px(radius)).roundedBr(px(radius));
            files_col = div().hFull().flexNone().relative().overflowHidden().w(px(files_now)).child(inner);
        };

        if (liquid) return div().absolute().inset0().child(tone).child(ui.anim.fadeIn("phase-app", div().sizeFull().relative() // [liquid-glass]
            .child(div().sizeFull().flex().flexRow()
                .child(zpui.overlayPlane(true, sidebar_col))
                .child(sidebar_seam)
                .child(card)
                .child(right_wrap)
                .child(files_col))
            .child(liquidTitlebarFade(theme, sidebar_now, right_now + files_now))
            .child(liquidTitlebar(self, sidebar_now, right_now, files_now, theme, cx))));

        const page = div().sizeFull().relative()
            .child(div().sizeFull().flex().flexRow()
                .child(zpui.overlayPlane(liquid, sidebar_col))
                .child(sidebar_seam)
                .child(card)
                .child(right_wrap)
                .child(files_col))
            .child(div().absolute().top(px(0)).left(px(0)).right(px(0)).child(zpui.overlayPlane(liquid, titlebar.sessionBar(self, sidebar_now, right_now, files_now, theme, cx))))
            .child(zpui.overlayPlane(liquid, titlebar.cluster(self, theme, cx))); // [liquid-glass] overlayPlane: pass-through unless Liquid Glass

        return div().absolute().inset0().child(tone).child(ui.anim.fadeIn("phase-app", page));
    }
};

// ---- [liquid-glass] native glass chrome (Settings → Appearance → Glass → Liquid Glass) ----
//
// The sidebar is a native glass pane that shows the DESKTOP: zpui paints the window
// tint everywhere except under the glass (alpha 0 there), and in `glass` mode cuts the
// same shape out of the window's behind-window blur (`zpui.backdropHole`), so the glass
// samples the wallpaper through the non-opaque window. `vev` mode instead puts AppKit's
// behind-window `.sidebar` material under that transparent region with `.regular` glass
// on top (the pre-Tahoe recipe; compare both on a Mac with `ZERON_SIDEBAR_GLASS`).
// Layout: flush with the window edges, zeron's original column (default), or a
// floating pane inset 8px (`ZERON_SIDEBAR_LAYOUT=floating`).

pub const SidebarGlassMode = enum { glass, vev };
pub const SidebarLayout = enum { floating, flush };

/// `ZERON_SIDEBAR_GLASS=glass|vev` (main.zig). Default `glass`: regular glass straight
/// on the desktop (user preference); `vev` adds AppKit's frosted sidebar material under it.
pub var sidebar_glass_mode: SidebarGlassMode = .glass;
/// `ZERON_SIDEBAR_LAYOUT=floating|flush` (main.zig); null = flush.
pub var sidebar_layout_override: ?SidebarLayout = null;
/// Opacity of the theme background drawn inside the sidebar glass (Ghostty's
/// `background-opacity`) (`ZERON_SIDEBAR_OPACITY`,
/// 0 = glass straight on the desktop). Keeps `.regular` glass, just less see-through.
pub var sidebar_opacity: f32 = 0.55;

pub fn sidebarLayout(cx: anytype) SidebarLayout {
    if (sidebar_layout_override) |l| return l;
    // The original zeron sidebar: a straight full-height column, just made of glass
    // (user preference; the floating pane is opt-in via ZERON_SIDEBAR_LAYOUT=floating).
    _ = cx;
    return .flush;
}

/// Inset of the floating sidebar glass pane from the window edges.
const liquid_sidebar_inset: f32 = 8;
/// Corner radius of the floating pane.
const liquid_sidebar_radius: f32 = 12;
/// Flush pane: square corners (the window's own corner mask rounds the outer ones).
const liquid_flush_radius: f32 = 0;
/// Width of the tint ring around the floating pane (only its inner, glass-concentric
/// edge is visible; the rest is clipped to the sidebar column).
const tint_ring: f32 = 48;

const GlassRect = struct { x: f32, y: f32, w: f32, h: f32, r: f32 };

/// The sidebar column [0, sidebar_now]: glass pane + the window tint around it (the
/// main area's tint is painted here too, so the window has exactly one tint layer).
fn liquidSidebar(theme: *const Theme, sidebar_now: f32, window: *Window, cx: anytype) zpui.Div {
    const vp = window.viewportSize();
    const tint = theme.glass();
    const lay = sidebarLayout(cx);
    const mode = sidebar_glass_mode;
    var out = div().absolute().inset0();
    // Main area tint (right of the column); a hairline seam for the flush pane.
    var main_tint = div().absolute().top(px(0)).bottom(px(0)).left(px(sidebar_now)).right(px(0)).bg(tint);
    if (lay == .flush and sidebar_now > 1) main_tint = main_tint.borderL1().borderColor(theme.border);
    out = out.child(main_tint);
    if (sidebar_now <= 1) return out;

    const inset: f32 = if (lay == .floating) liquid_sidebar_inset else 0;
    const g: GlassRect = .{
        .x = inset,
        .y = inset,
        .w = @max(sidebar_now - 2 * inset, 0),
        .h = @max(vp.height - 2 * inset, 0),
        .r = if (lay == .floating) liquid_sidebar_radius else liquid_flush_radius,
    };
    var column = div().absolute().top(px(0)).bottom(px(0)).left(px(0)).w(px(sidebar_now)).overflowHidden();
    if (g.w <= 2 * g.r or g.w <= 1) {
        // Too narrow for a pane (mid-collapse): plain tint.
        return out.child(column.bg(tint));
    }
    if (lay == .floating) {
        // A ring of tint whose inner edge is the pane's rounded rect (alpha 0 inside).
        column = column.child(div().absolute().left(px(g.x - tint_ring)).top(px(g.y - tint_ring))
            .w(px(g.w + 2 * tint_ring)).h(px(g.h + 2 * tint_ring))
            .border(px(tint_ring)).borderColor(tint).rounded(px(g.r + tint_ring)));
    }
    // The flush pane's glass extends past the seam by its radius and is clipped there
    // (square inner edge, rounded window-side corners).
    const glass_w = if (lay == .flush) g.w + g.r else g.w;
    // Regular (translucent) glass in both recipes: Apple's `.clear` is the permanently
    // transparent variant for media, and over the sidebar material it reads as plain blur.
    const style: zpui.LiquidGlassStyle = .regular;
    // Ghostty's `macos-glass-regular` recipe: one regular glass straight on the desktop
    // (no window blur under it: see the backdrop hole below), with the theme background
    // at `sidebar_opacity` drawn INSIDE the glass as its content, not under it (a layer
    // under the glass gets blurred by it and reads as a second blur).
    const content: zpui.Div = if (mode == .glass and sidebar_opacity > 0)
        div().sizeFull().rounded(px(g.r)).bg(tint.alpha(@min(sidebar_opacity, 1)))
    else
        div().sizeFull();
    const glass_tint: ?zpui.Hsla = if (mode == .glass) null else theme.glassTint();
    const pane = div().absolute().left(px(g.x)).top(px(g.y)).w(px(glass_w)).h(px(g.h))
        .child(if (mode == .vev) zpui.sidebarMaterial("sidebar-material", .{ .corner_radius = if (lay == .floating) g.r else 0 }, div().sizeFull()) else null)
        .child(zpui.liquidGlass("sidebar-glass", .{ .style = style, .shape = .{ .rounded = g.r }, .tint = glass_tint }, content));
    column = column.child(pane);
    // Cut the pane out of the window's behind-window blur (glass mode).
    const radii: [4]f32 = if (lay == .floating) .{ g.r, g.r, g.r, g.r } else .{ g.r, 0, 0, g.r };
    const hole = div().absolute().left(px(g.x)).top(px(g.y)).w(px(g.w)).h(px(g.h));
    out = out.child(column).child(zpui.backdropHole(mode == .glass, radii, hole));
    return out;
}

/// Soft scroll edge under the titlebar (replaces a material strip): the transcript
/// fades into the window tint as it scrolls under the capsules.
fn liquidTitlebarFade(theme: *const Theme, sidebar_now: f32, right_w: f32) zpui.Div {
    const stop = zpui.color.linearColorStop;
    return div().absolute().top(px(0)).left(px(sidebar_now)).right(px(right_w)).h(px(layout.titlebar_height + 12))
        .bg(zpui.color.linearGradient(180, stop(theme.surface.opacity(0.72), 0), stop(theme.surface.opacity(0), 1)));
}

/// The titlebar band: session bar + control cluster, their capsules members of one
/// `NSGlassEffectContainerView` so neighbours morph (titlebar.zig, "Tahoe capsules").
fn liquidTitlebar(self: *Shell, sidebar_now: f32, right_now: f32, files_now: f32, theme: *const Theme, cx: *Context(Shell)) zpui.Div {
    return div().absolute().top(px(0)).left(px(0)).right(px(0)).h(px(layout.titlebar_height))
        .child(zpui.overlayPlane(true, zpui.liquidGlassGroup("titlebar-glass", .{ .spacing = titlebar.capsule_spacing }, div().sizeFull().relative()
        .child(div().absolute().top(px(0)).left(px(0)).right(px(0)).child(titlebar.sessionBar(self, sidebar_now, right_now, files_now, theme, cx)))
        .child(titlebar.cluster(self, theme, cx)))));
}
