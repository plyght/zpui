//! The right-pane surface host (zeron shell.rs `render_right_pane`,
//! `render_right_tab_strip`, `render_surface_picker`, `right_tabs`, the
//! `+` menu and `RightTabDrag` reorder).
//!
//! Tabs are kept per chat in memory (Rust `right_tabs` + `SessionPanels`:
//! nothing is persisted, a fresh run starts closed); the new-session canvas
//! has no pane. Surfaces:
//!   - Diffs: `changes.ChangesPane` (working tree; the scope menu lives in
//!     the pane's own toolbar),
//!   - History: `history.HistoryPane`; a row click opens the commit as its
//!     own `ChangesPane.initCommit` tab,
//!   - Terminal: an embedded `TerminalDock` (no dock chrome),
//!   - Browser: `browser.BrowserPane` (WKWebView on macOS, the WebKitGTK
//!     helper on Linux; "Preview your work" / dev-server previews when empty),
//!   - File: a `ui/editor` `FileEditor` tab (`openFile`: the explorer, a
//!     Changes file header, transcript links).
//!
//! The explorer (`ui/files` `FilesPanel`, mod-e) is a per-chat column docked
//! right of the surface host; both share the chat's `WorkspaceFiles` client.
//!
//! The strip renders in the titlebar band (`titlebar.sessionBar`); the
//! content in the pane below it. `SurfacesEmptied` asks the shell to close
//! the pane (with its width tween) after the last tab closes.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const changes = @import("../changes/root.zig");
const history = @import("../history/root.zig");
const fixtures_mod = @import("fixtures.zig");
const terminal_dock = @import("terminal_dock.zig");
const files = @import("../files/root.zig");
const editor = @import("../editor/root.zig");
const md = @import("zeron_ui_markdown");
const browser = @import("../browser/root.zig");
const surfaces = @import("surfaces.zig"); // [wiring] subagent + side-chat tabs

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = ui.Theme;
const Icon = ui.icon.Icon;
const layout = zt.layout;

/// Fixed chip slot: drag quantisation and slide offsets assume uniform widths.
pub const chip_w: f32 = 112;
const chip_slot: f32 = chip_w + 4;
const fade_width: f32 = 36;

pub const Kind = enum { diffs, history, terminal, browser, files };

pub const Surface = union(enum) {
    changes: Entity(changes.ChangesPane),
    history: Entity(history.HistoryPane),
    terminal: Entity(terminal_dock.TerminalDock),
    browser: Entity(browser.BrowserPane),
    /// Editor tab for a workspace-relative path.
    file: Entity(editor.FileEditor),
    /// [wiring] A spawn chip's subagent transcript.
    subagent: Entity(surfaces.SubagentSurface),
    /// [wiring] A side chat (fork / agent-spawned child) with a reply field.
    side_chat: Entity(surfaces.SideChatSurface),
};

pub const Tab = struct {
    id: u64,
    surface: Surface,
    sub: ?zpui.Subscription = null,

    fn deinit(self: *Tab, _: std.mem.Allocator, app: *App) void {
        if (self.sub) |*s| s.deinit();
        switch (self.surface) {
            .changes => |e| e.release(app),
            .history => |e| e.release(app),
            .terminal => |e| e.release(app),
            .browser => |e| e.release(app),
            .file => |e| e.release(app),
            .subagent => |e| e.release(app),
            .side_chat => |e| e.release(app),
        }
    }
};

/// One chat's surface host state (Rust `ChatPanels` + `right_tabs`).
pub const ChatTabs = struct {
    tabs: std.ArrayList(Tab) = .empty,
    /// The picked surface (validated against `tabs` when rendering).
    active: ?u64 = null,
    /// Unique visits, oldest first (fallback after a close).
    visits: std.ArrayList(u64) = .empty,
    open: bool = false,
    /// The explorer column (mod-e) is docked.
    files_open: bool = false,
    /// The chat's workspace files service (explorer + editors), lazily made.
    files: ?Entity(files.WorkspaceFiles) = null,
    explorer: ?Entity(files.FilesPanel) = null,
    explorer_sub: ?zpui.Subscription = null,
    /// [wiring] Explorer events beyond OpenFile (Add to chat, footer rows).
    explorer_subs: zpui.Subscriptions = .{},
    /// [wiring] Fingerprint of the rows last handed to the explorer footer.
    sections_key: u64 = 0,

    fn deinit(self: *ChatTabs, gpa: std.mem.Allocator, app: *App) void {
        self.explorer_subs.deinit(gpa);
        for (self.tabs.items) |*t| t.deinit(gpa, app);
        self.tabs.deinit(gpa);
        self.visits.deinit(gpa);
        if (self.explorer_sub) |*sub| sub.deinit();
        if (self.explorer) |e| e.release(app);
        if (self.files) |f| f.release(app);
    }

    pub fn indexOf(self: *const ChatTabs, id: u64) ?usize {
        for (self.tabs.items, 0..) |t, i| if (t.id == id) return i;
        return null;
    }

    /// The surface that renders: the stored pick when it exists, else the
    /// most recently visited live tab, else the last tab, else none (picker).
    pub fn resolvedActive(self: *const ChatTabs) ?u64 {
        if (self.active) |a| if (self.indexOf(a) != null) return a;
        var i = self.visits.items.len;
        while (i > 0) {
            i -= 1;
            if (self.indexOf(self.visits.items[i]) != null) return self.visits.items[i];
        }
        if (self.tabs.items.len > 0) return self.tabs.items[self.tabs.items.len - 1].id;
        return null;
    }

    fn visit(self: *ChatTabs, gpa: std.mem.Allocator, id: u64) void {
        for (self.visits.items, 0..) |v, i| if (v == id) {
            _ = self.visits.orderedRemove(i);
            break;
        };
        self.visits.append(gpa, id) catch {};
        self.active = id;
    }

    fn forget(self: *ChatTabs, id: u64) void {
        for (self.visits.items, 0..) |v, i| if (v == id) {
            _ = self.visits.orderedRemove(i);
            break;
        };
        if (self.active == id) self.active = null;
    }

    /// Move a tab within the strip (drag reorder).
    pub fn reorder(self: *ChatTabs, from: usize, to: usize) bool {
        if (from >= self.tabs.items.len or to >= self.tabs.items.len or from == to) return false;
        const t = self.tabs.orderedRemove(from);
        self.tabs.insertAssumeCapacity(to, t);
        return true;
    }
};

/// Drop slot for a pointer `rel_x` px into the strip (terminal panel `drop_index`).
pub fn dropIndex(rel_x: f32, slot: f32, count: usize) usize {
    if (count == 0 or slot <= 0) return 0;
    const ix: usize = @intFromFloat(@max(@floor(rel_x / slot), 0));
    return @min(ix, count - 1);
}

/// Tab `ix` shifts one slot toward the vacated gap while `from` hovers `over`.
pub fn slideOffset(ix: usize, from: usize, over: usize) f32 {
    if (from < over and ix > from and ix <= over) return -1;
    if (over < from and ix >= over and ix < from) return 1;
    return 0;
}

/// The dragged chip (strip reorder); the title rides along for the ghost.
/// File tabs also carry their workspace path (Rust `RightTabDrag.workspace_path`):
/// dropped on the conversation, they attach a file reference.
pub const TabDrag = struct {
    key_hash: u64,
    from: usize,
    title_buf: [48]u8 = undefined,
    title_len: u8 = 0,
    path_buf: [1024]u8 = undefined,
    path_len: u16 = 0,

    fn title(self: *const TabDrag) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    /// A file tab's workspace path (null for other surfaces / overlong paths).
    pub fn workspacePath(self: *const TabDrag) ?[]const u8 {
        return if (self.path_len == 0) null else self.path_buf[0..self.path_len];
    }

    /// The drag started in chat `key`'s strip (a drag outliving a chat switch is dropped).
    pub fn belongsTo(self: *const TabDrag, key: []const u8) bool {
        return self.key_hash == RightPane.keyHash(key);
    }
};

const DragState = struct { from: usize, over: usize, epoch: usize, prev_over: usize };

/// The floating chip under the pointer while a tab drags.
pub const TabGhost = struct {
    buf: [48]u8 = undefined,
    len: u8 = 0,

    pub fn render(self: *TabGhost, _: *Window, cx: *Context(TabGhost)) zpui.Div {
        const theme = ui.theme.get(cx);
        return div().h(px(24)).w(px(chip_w)).px(px(8)).flex().itemsCenter().rounded(px(6))
            .bg(theme.surface_raised).border1().borderColor(theme.border_strong)
            .fontFamily(theme.font_sans).textSize(ui.rems(11.5)).textColor(theme.text).opacity(0.85)
            .child(div().truncate().whitespaceNowrap().child(self.buf[0..self.len]));
    }
};

fn buildGhost(drag: *const TabDrag, _: zpui.Point(f32), _: *Window, app: *App) Entity(TabGhost) {
    var g: TabGhost = .{ .len = drag.title_len };
    @memcpy(g.buf[0..drag.title_len], drag.title());
    return app.new(TabGhost, g) catch @panic("OOM");
}

/// Closing the last tab: the shell collapses the pane.
pub const SurfacesEmptied = struct {};
/// The `+` menu's Files row: the shell docks the explorer.
pub const OpenExplorer = struct {};
/// [wiring] The explorer's "Add to chat": the shell inserts a reference into the composer.
pub const AddToChat = struct { path: []const u8, is_directory: bool };
/// [wiring] A side-chat action failed: the shell shows it in the composer.
pub const SideChatError = struct { message: []const u8 };

pub const RightPane = struct {
    gpa: std.mem.Allocator,
    state: Entity(model.AppState),
    fixtures: ?*fixtures_mod.Fixtures,
    chats: std.StringHashMapUnmanaged(ChatTabs) = .empty,
    seq: u64 = 0,
    plus_open: bool = false,
    drag: ?DragState = null,
    strip_scroll: zpui.ScrollHandle,
    /// A fresh chat's open flag (fixtures can open every chat's pane).
    default_open: bool = false,
    /// The window hosting the pane (browser new-tab requests).
    window_id: ?zpui.WindowId = null,
    /// Settings → Files (autosave, word wrap, show all) follow live.
    settings_sub: ?zpui.Subscription = null,

    pub const Events = .{ SurfacesEmptied, OpenExplorer, AddToChat, SideChatError };

    pub fn init(state: Entity(model.AppState), fixtures: ?*fixtures_mod.Fixtures, default_open: bool, cx: *Context(RightPane)) RightPane {
        return .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .fixtures = fixtures,
            .strip_scroll = zpui.ScrollHandle.init(cx.gpa()),
            .default_open = default_open,
            .settings_sub = cx.observeGlobal(model.SettingsStore, onSettingsChanged) catch null,
        };
    }

    // ---- Settings → Files ------------------------------------------------------------

    fn filesSettings(cx: anytype) model.UiSettings {
        const s = model.settings_store.current(if (@TypeOf(cx) == *App) cx else cx.app) orelse return .{};
        return s.*;
    }

    /// New editors open with the files defaults (`files_word_wrap`, autosave).
    fn editorOptions(cx: anytype) editor.view.Options {
        const s = filesSettings(cx);
        return .{ .soft_wrap = s.filesWordWrap, .autosave = s.filesAutosaveEnabled, .autosave_delay_ms = s.filesAutosaveDelayMs };
    }

    /// Push the live files settings into every open editor and explorer.
    fn onSettingsChanged(self: *RightPane, cx: *Context(RightPane)) void {
        const s = filesSettings(cx);
        var it = self.chats.valueIterator();
        while (it.next()) |t| {
            for (t.tabs.items) |tab| if (tab.surface == .file) {
                const ed = tab.surface.file;
                ed.update(cx, editor.FileEditor.setSoftWrap, .{s.filesWordWrap});
                ed.update(cx, editor.FileEditor.setAutosave, .{ s.filesAutosaveEnabled, s.filesAutosaveDelayMs });
            };
            if (t.explorer) |e| e.update(cx, files.FilesPanel.setShowAllFiles, .{s.filesShowAll});
        }
    }

    /// An editor's own word-wrap toggle is the global files default (`set_files_word_wrap`).
    fn onEditorWrap(_: *RightPane, _: Entity(editor.FileEditor), ev: *const editor.view.WordWrapChanged, cx: *Context(RightPane)) void {
        const Set = struct {
            fn f(on: bool, s: *model.UiSettings, _: std.mem.Allocator) void {
                s.filesWordWrap = on;
            }
        };
        _ = model.settings_store.update(cx.app, .debounced, ev.enabled, Set.f);
    }

    /// The explorer's eye toggle is the global "show all files" (`set_files_show_all`).
    fn onExplorerShowAll(_: *RightPane, _: Entity(files.FilesPanel), ev: *const files.panel.ShowAllFilesChanged, cx: *Context(RightPane)) void {
        const Set = struct {
            fn f(on: bool, s: *model.UiSettings, _: std.mem.Allocator) void {
                s.filesShowAll = on;
            }
        };
        _ = model.settings_store.update(cx.app, .debounced, ev.show_all, Set.f);
    }

    pub fn deinit(self: *RightPane, app: *App) void {
        var it = self.chats.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.gpa, app);
            self.gpa.free(e.key_ptr.*);
        }
        self.chats.deinit(self.gpa);
        if (self.settings_sub) |*sub| sub.deinit();
        self.strip_scroll.release();
        self.state.release(app);
    }

    // ---- per-chat state ---------------------------------------------------------------

    /// The selected chat (the canvas has no pane).
    pub fn key(self: *const RightPane, cx: anytype) ?[]const u8 {
        return self.state.read(cx).workspace.read(cx).selected_chat;
    }

    fn keyHash(k: []const u8) u64 {
        return std.hash.Wyhash.hash(0x52_50_41_4e, k);
    }

    /// The selected chat's tabs (created on demand), or null on the canvas.
    pub fn current(self: *RightPane, cx: anytype) ?*ChatTabs {
        const k = self.key(cx) orelse return null;
        const gop = self.chats.getOrPut(self.gpa, k) catch return null;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.gpa.dupe(u8, k) catch {
                _ = self.chats.remove(k);
                return null;
            };
            gop.value_ptr.* = .{ .open = self.default_open };
        }
        return gop.value_ptr;
    }

    pub fn peek(self: *const RightPane, cx: anytype) ?*const ChatTabs {
        const k = self.key(cx) orelse return null;
        return self.chats.getPtr(k);
    }

    pub fn isOpen(self: *const RightPane, cx: anytype) bool {
        const k = self.key(cx) orelse return false;
        if (self.chats.getPtr(k)) |t| return t.open;
        return self.default_open;
    }

    pub fn setOpen(self: *RightPane, open: bool, cx: *Context(RightPane)) void {
        const t = self.current(cx) orelse return;
        if (t.open == open) return;
        t.open = open;
        if (!open) self.plus_open = false;
        self.ensureActiveContent(cx);
        cx.notify();
    }

    fn gitDetected(self: *const RightPane, cx: anytype) bool {
        const ws = self.state.read(cx).workspace.read(cx);
        const c = ws.selectedChatRow() orelse return false;
        return if (ws.spaceForChat(c)) |s| s.gitDetected else false;
    }

    fn chatCwd(self: *const RightPane, cx: anytype) ?[]const u8 {
        const ws = self.state.read(cx).workspace.read(cx);
        const c = ws.selectedChatRow() orelse return null;
        return c.cwd orelse if (ws.spaceForChat(c)) |sp| sp.path else null;
    }

    // ---- adding / closing -------------------------------------------------------------

    pub fn push(self: *RightPane, surface: Surface, cx: *Context(RightPane)) ?*Tab {
        const t = self.current(cx) orelse return null;
        self.seq += 1;
        t.tabs.append(self.gpa, .{ .id = self.seq, .surface = surface }) catch return null;
        t.visit(self.gpa, self.seq);
        t.open = true;
        self.plus_open = false;
        self.syncBrowsers(t, cx);
        cx.notify();
        return &t.tabs.items[t.tabs.items.len - 1];
    }

    /// Open a fresh surface of `kind` as the active tab.
    pub fn add(self: *RightPane, kind: Kind, window: *Window, cx: *Context(RightPane)) void {
        switch (kind) {
            .diffs => {
                const pane = cx.newWith(changes.ChangesPane, changes.ChangesPane.init, .{self.state}) catch return;
                self.feedDiffFixture(pane, cx);
                const tab = self.push(.{ .changes = pane }, cx) orelse return pane.release(cx);
                tab.sub = cx.subscribe(pane, onOpenFile) catch null;
                pane.update(cx, changes.ChangesPane.ensureContent, .{});
            },
            .history => {
                const pane = cx.newWith(history.HistoryPane, history.HistoryPane.init, .{self.state}) catch return;
                self.feedHistoryFixture(pane, cx);
                const tab = self.push(.{ .history = pane }, cx) orelse return pane.release(cx);
                tab.sub = cx.subscribe(pane, onOpenCommit) catch null;
            },
            .terminal => {
                const io = self.state.read(cx).workspace.read(cx).io;
                const T = terminal_dock.TerminalDock;
                const e = cx.newWith(T, T.init, .{ io, self.chatCwd(cx), window }) catch return;
                {
                    var l = e.lease(cx);
                    defer l.end();
                    l.value.chrome = false;
                }
                _ = self.push(.{ .terminal = e }, cx) orelse e.release(cx);
            },
            .browser => _ = self.addBrowser(null, window, cx),
            // The Files explorer is its own column (Rust `add_files_surface`).
            .files => cx.emit(OpenExplorer{}),
        }
    }

    /// A new Browser tab (optionally loading `url`, e.g. a page's target=_blank link).
    pub fn addBrowser(self: *RightPane, url: ?[]const u8, window: *Window, cx: *Context(RightPane)) ?Entity(browser.BrowserPane) {
        self.window_id = window.id;
        // Fixture mode has no engine: previews come from `previews.json` when present.
        const chat = if (self.fixtures == null) self.key(cx) else null;
        const pane = cx.newWith(browser.BrowserPane, browser.BrowserPane.init, .{ self.state, chat, window }) catch return null;
        if (self.fixtureBytes("previews.json", cx)) |bytes| pane.update(cx, browser.BrowserPane.applyPreviewFixture, .{bytes});
        const tab = self.push(.{ .browser = pane }, cx) orelse {
            pane.release(cx);
            return null;
        };
        tab.sub = cx.subscribe(pane, onBrowserNewTab) catch null;
        if (cx.subscribe(pane, onBrowserClose)) |sub| {
            var s2 = sub;
            s2.detach();
        } else |_| {}
        {
            // A chat on another device: localhost there is not localhost here.
            const ws = self.state.read(cx).workspace.read(cx);
            const remote = if (ws.selectedChatRow()) |c| (if (ws.local_device_id) |l| !std.mem.eql(u8, l, c.deviceId) else false) else false;
            var l = pane.lease(cx);
            defer l.end();
            l.value.remote = remote;
        }
        if (url) |u| pane.update(cx, browser.BrowserPane.navigate, .{u}) else pane.update(cx, browser.BrowserPane.focusAddress, .{window});
        return pane;
    }

    fn onBrowserNewTab(self: *RightPane, pane: Entity(browser.BrowserPane), ev: *const browser.NewTab, cx: *Context(RightPane)) void {
        // A background page cannot open a tab in the wrong session.
        const t = self.peek(cx) orelse return;
        const active = t.resolvedActive() orelse return;
        const tab = t.tabs.items[t.indexOf(active).?];
        if (tab.surface != .browser or tab.surface.browser.id != pane.id) return;
        const w = cx.app.windowById(self.window_id orelse return) orelse return;
        _ = self.addBrowser(ev.url, w, cx);
    }

    fn onBrowserClose(self: *RightPane, pane: Entity(browser.BrowserPane), _: *const browser.CloseRequested, cx: *Context(RightPane)) void {
        const t = self.current(cx) orelse return;
        for (t.tabs.items) |tab| if (tab.surface == .browser and tab.surface.browser.id == pane.id) return self.close(tab.id, cx);
    }

    /// The chat's workspace files service: engine-backed (the chat's checkout,
    /// relay-forwarded for remote chats) or, in fixture mode, the local folder.
    pub fn filesClient(self: *RightPane, cx: *Context(RightPane)) ?Entity(files.WorkspaceFiles) {
        const t = self.current(cx) orelse return null;
        if (t.files) |f| return f;
        const st = self.state.read(cx);
        const w = st.workspace.read(cx);
        const chat = w.selectedChatRow() orelse return null;
        const cwd = self.chatCwd(cx) orelse return null;
        const source: files.client.Source = if (self.fixtures != null)
            .{ .local = cwd }
        else
            .{ .engine = .{ .state = st.engine, .target = .{ .chat_id = chat.id, .space_id = chat.spaceId, .checkout_path = cwd } } };
        const f = cx.newWith(files.WorkspaceFiles, files.WorkspaceFiles.init, .{ w.io, source }) catch return null;
        t.files = f;
        return f;
    }

    /// The chat's explorer (created on first dock).
    pub fn explorer(self: *RightPane, cx: *Context(RightPane)) ?Entity(files.FilesPanel) {
        const t = self.current(cx) orelse return null;
        if (t.explorer) |e| return e;
        const f = self.filesClient(cx) orelse return null;
        const e = cx.newWith(files.FilesPanel, files.FilesPanel.init, .{ f, files.panel.Options{ .show_all_files = filesSettings(cx).filesShowAll } }) catch return null;
        t.explorer = e;
        if (self.key(cx)) |k| e.update(cx, files.FilesPanel.setDragOwner, .{k});
        t.explorer_sub = cx.subscribe(e, onExplorerOpenFile) catch null;
        if (cx.subscribe(e, onExplorerShowAll)) |sub| t.explorer_subs.add(self.gpa, sub) catch {} else |_| {}
        // Rename/delete propagation to open editors (`shell/file_mutations.rs`).
        if (cx.subscribe(e, onExplorerRenamed)) |sub| t.explorer_subs.add(self.gpa, sub) catch {} else |_| {}
        if (cx.subscribe(e, onExplorerDeleted)) |sub| t.explorer_subs.add(self.gpa, sub) catch {} else |_| {}
        surfaces_glue.subscribeExplorer(self, t, e, cx);
        return e;
    }

    pub fn filesOpen(self: *const RightPane, cx: anytype) bool {
        const t = self.peek(cx) orelse return false;
        return t.files_open;
    }

    pub fn setFilesOpen(self: *RightPane, open: bool, window: ?*Window, cx: *Context(RightPane)) void {
        if (open) {
            const e = self.explorer(cx) orelse return;
            e.update(cx, files.FilesPanel.ensureLoaded, .{});
            if (window) |w| e.update(cx, struct {
                fn f(p: *files.FilesPanel, win: *Window, _: *Context(files.FilesPanel)) void {
                    p.focusTree(win);
                }
            }.f, .{w});
        }
        const t = self.current(cx) orelse return;
        t.files_open = open;
        cx.notify();
    }

    /// The docked explorer view, if open.
    pub fn explorerView(self: *const RightPane, cx: anytype) ?Entity(files.FilesPanel) {
        const t = self.peek(cx) orelse return null;
        return t.explorer;
    }

    /// Every chat's tab set sharing the emitting explorer's workspace
    /// (`shares_workspace`): its own, plus any other chat on the same root.
    fn sharesWorkspace(self: *RightPane, t: *const ChatTabs, src: *const ChatTabs, cx: *Context(RightPane)) bool {
        if (t == src) return true;
        const a = t.files orelse return false;
        const b = src.files orelse return false;
        if (a.id == b.id) return true;
        const ra = a.read(cx).root_label;
        const rb = b.read(cx).root_label;
        _ = self;
        return ra.len > 0 and std.mem.eql(u8, ra, rb);
    }

    fn sourceTabs(self: *RightPane, explorer_id: zpui.EntityId) ?*ChatTabs {
        var it = self.chats.valueIterator();
        while (it.next()) |t| if (t.explorer) |e| if (e.id == explorer_id) return t;
        return null;
    }

    /// An entry moved: editors on it (or under a moved folder) follow the
    /// new path and keep their buffers.
    fn onExplorerRenamed(self: *RightPane, src_e: Entity(files.FilesPanel), ev: *const files.panel.EntryRenamed, cx: *Context(RightPane)) void {
        const src = self.sourceTabs(src_e.id) orelse return;
        var it = self.chats.valueIterator();
        while (it.next()) |t| {
            if (!self.sharesWorkspace(t, src, cx)) continue;
            for (t.tabs.items) |tab| if (tab.surface == .file) {
                const ed = tab.surface.file;
                const p = ed.read(cx).filePath();
                if (std.mem.eql(u8, p, ev.old_path)) {
                    ed.update(cx, editor.FileEditor.setPath, .{ev.new_path});
                } else if (files.model.isDescendant(p, ev.old_path)) {
                    const np = std.fmt.allocPrint(self.gpa, "{s}{s}", .{ ev.new_path, p[ev.old_path.len..] }) catch continue;
                    defer self.gpa.free(np);
                    ed.update(cx, editor.FileEditor.setPath, .{np});
                }
            };
        }
        cx.notify();
    }

    /// An entry was deleted: editors on it keep their buffers for recovery
    /// and show the deleted-on-disk banner.
    fn onExplorerDeleted(self: *RightPane, src_e: Entity(files.FilesPanel), ev: *const files.panel.EntryDeleted, cx: *Context(RightPane)) void {
        const src = self.sourceTabs(src_e.id) orelse return;
        var it = self.chats.valueIterator();
        while (it.next()) |t| {
            if (!self.sharesWorkspace(t, src, cx)) continue;
            for (t.tabs.items) |tab| if (tab.surface == .file) {
                const ed = tab.surface.file;
                const p = ed.read(cx).filePath();
                if (std.mem.eql(u8, p, ev.path) or files.model.isDescendant(p, ev.path)) ed.update(cx, editor.FileEditor.markDeleted, .{});
            };
        }
        cx.notify();
    }

    fn onExplorerOpenFile(self: *RightPane, _: Entity(files.FilesPanel), ev: *const files.panel.OpenFile, cx: *Context(RightPane)) void {
        self.openFile(ev.path, cx);
    }

    fn onEditorReveal(self: *RightPane, _: Entity(editor.FileEditor), ev: *const editor.view.RevealFile, cx: *Context(RightPane)) void {
        const t = self.current(cx) orelse return;
        if (t.explorer) |e| e.update(cx, files.FilesPanel.revealFile, .{ev.path});
    }

    fn onEditorOpenPath(self: *RightPane, _: Entity(editor.FileEditor), ev: *const editor.view.OpenPath, cx: *Context(RightPane)) void {
        self.openFile(ev.path, cx);
    }

    fn onEditorState(_: *RightPane, _: Entity(editor.FileEditor), _: *const editor.view.StateChanged, cx: *Context(RightPane)) void {
        cx.notify();
    }

    /// Open (or focus) an editor tab for `path` (explorer, Changes file
    /// headers, transcript links).
    pub fn openFile(self: *RightPane, path: []const u8, cx: *Context(RightPane)) void {
        if (self.current(cx)) |t| for (t.tabs.items) |tab| if (tab.surface == .file and std.mem.eql(u8, tab.surface.file.read(cx).filePath(), path)) {
            t.visit(self.gpa, tab.id);
            t.open = true;
            if (t.explorer) |e| e.update(cx, files.FilesPanel.revealFile, .{path});
            cx.notify();
            return;
        };
        const f = self.filesClient(cx) orelse return;
        const ed = cx.newWith(editor.FileEditor, editor.FileEditor.init, .{ f, path, editorOptions(cx) }) catch return;
        const tab = self.push(.{ .file = ed }, cx) orelse return ed.release(cx);
        tab.sub = cx.subscribe(ed, onEditorReveal) catch null;
        if (cx.subscribe(ed, onEditorState)) |sub| {
            var s2 = sub;
            s2.detach();
        } else |_| {}
        if (cx.subscribe(ed, onEditorWrap)) |sub| {
            var s3 = sub;
            s3.detach();
        } else |_| {}
        // A Markdown preview link to another workspace document.
        if (cx.subscribe(ed, onEditorOpenPath)) |sub| {
            var s4 = sub;
            s4.detach();
        } else |_| {}
        if (self.peek(cx)) |t| if (t.explorer) |e| e.update(cx, files.FilesPanel.revealFile, .{path});
    }

    fn onOpenFile(self: *RightPane, _: Entity(changes.ChangesPane), ev: *const changes.OpenFile, cx: *Context(RightPane)) void {
        self.openFile(ev.path, cx);
    }

    /// A History row: the commit opens as its own pinned diff tab.
    fn onOpenCommit(self: *RightPane, _: Entity(history.HistoryPane), ev: *const history.OpenCommit, cx: *Context(RightPane)) void {
        const pin: changes.CommitPin = .{ .sha = ev.sha, .subject = ev.subject };
        const pane = cx.newWith(changes.ChangesPane, changes.ChangesPane.initCommit, .{ self.state, pin }) catch return;
        const tab = self.push(.{ .changes = pane }, cx) orelse return pane.release(cx);
        tab.sub = cx.subscribe(pane, onOpenFile) catch null;
        pane.update(cx, changes.ChangesPane.ensureContent, .{});
    }

    pub fn close(self: *RightPane, id: u64, cx: *Context(RightPane)) void {
        const t = self.current(cx) orelse return;
        const ix = t.indexOf(id) orelse return;
        var tab = t.tabs.orderedRemove(ix);
        tab.deinit(self.gpa, cx.app);
        t.forget(id);
        self.drag = null;
        if (t.tabs.items.len == 0) cx.emit(SurfacesEmptied{});
        self.ensureActiveContent(cx);
        cx.notify();
    }

    pub fn activate(self: *RightPane, id: u64, cx: *Context(RightPane)) void {
        const t = self.current(cx) orelse return;
        if (t.indexOf(id) == null) return;
        t.visit(self.gpa, id);
        self.ensureActiveContent(cx);
        cx.notify();
    }

    /// Only the visible browser tab keeps rendering (Rust `set_presentation`).
    fn syncBrowsers(_: *RightPane, t: *ChatTabs, cx: *Context(RightPane)) void {
        const shown = if (t.open) t.resolvedActive() else null;
        for (t.tabs.items) |bt| if (bt.surface == .browser)
            bt.surface.browser.update(cx, browser.BrowserPane.setPresentation, .{if (shown == bt.id) browser.model.Presentation.live else .hidden});
    }

    /// Reopening onto a diff tab revalidates its watch.
    fn ensureActiveContent(self: *RightPane, cx: *Context(RightPane)) void {
        const t = self.current(cx) orelse return;
        self.syncBrowsers(t, cx);
        const id = t.resolvedActive() orelse return;
        const tab = t.tabs.items[t.indexOf(id).?];
        if (tab.surface == .changes) tab.surface.changes.update(cx, changes.ChangesPane.ensureContent, .{});
    }

    /// Ctrl-Tab inside the pane: step through the strip.
    pub fn cycle(self: *RightPane, forward: bool, cx: *Context(RightPane)) void {
        const t = self.current(cx) orelse return;
        const n = t.tabs.items.len;
        if (n <= 1) return;
        const at = if (t.resolvedActive()) |a| t.indexOf(a) else null;
        const next = if (at) |i| (if (forward) (i + 1) % n else (i + n - 1) % n) else if (forward) 0 else n - 1;
        self.activate(t.tabs.items[next].id, cx);
    }

    // ---- fixtures ---------------------------------------------------------------------

    fn fixtureBytes(self: *const RightPane, name: []const u8, cx: anytype) ?[]u8 {
        const f = self.fixtures orelse return null;
        const io = self.state.read(cx).workspace.read(cx).io;
        const a = f.arena.allocator();
        const path = std.fs.path.join(a, &.{ f.dir, name }) catch return null;
        return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20)) catch null;
    }

    fn feedDiffFixture(self: *RightPane, pane: Entity(changes.ChangesPane), cx: *Context(RightPane)) void {
        if (self.fixtures == null) return;
        const store = pane.read(cx).store;
        if (self.fixtureBytes("checkout-diffs.json", cx)) |bytes| {
            changes.ChangesStore.applyFixture(store, cx.app, bytes);
        } else store.update(cx, changes.ChangesStore.setOffline, .{});
    }

    fn feedHistoryFixture(self: *RightPane, pane: Entity(history.HistoryPane), cx: *Context(RightPane)) void {
        if (self.fixtures == null) return;
        const bytes = self.fixtureBytes("git-history.json", cx) orelse return;
        const cwd = self.chatCwd(cx) orelse return;
        const ws = self.state.read(cx).workspace.read(cx);
        const chat = ws.selectedChatRow() orelse return;
        const local = if (ws.local_device_id) |l| std.mem.eql(u8, l, chat.deviceId) else true;
        const k = std.fmt.allocPrint(self.fixtures.?.arena.allocator(), "{s}|{s}", .{ if (local) "local" else chat.deviceId, cwd }) catch return;
        history.HistoryStore.applyFixture(pane.read(cx).store, cx.app, k, bytes);
    }

    // ---- listeners --------------------------------------------------------------------

    fn onChip(self: *RightPane, id: u64, _: *const zpui.ClickEvent, _: *Window, cx: *Context(RightPane)) void {
        cx.stopPropagation();
        self.activate(id, cx);
    }

    fn onChipClose(self: *RightPane, id: u64, _: *const zpui.ClickEvent, _: *Window, cx: *Context(RightPane)) void {
        cx.stopPropagation();
        self.close(id, cx);
    }

    fn onChipMiddle(self: *RightPane, id: u64, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(RightPane)) void {
        self.close(id, cx);
    }

    fn onCloseDown(_: *const zpui.input.MouseDownEvent, window: *Window, app: *App) void {
        window.preventDefault();
        app.propagate_event = false;
    }

    fn onChipDown(_: *const zpui.input.MouseDownEvent, window: *Window, _: *App) void {
        window.preventDefault();
    }

    fn onPlus(self: *RightPane, _: *const zpui.ClickEvent, _: *Window, cx: *Context(RightPane)) void {
        cx.stopPropagation();
        self.plus_open = !self.plus_open;
        cx.notify();
    }

    fn onPlusOut(self: *RightPane, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(RightPane)) void {
        if (!self.plus_open) return;
        self.plus_open = false;
        cx.notify();
    }

    fn onMenuRow(self: *RightPane, kind: Kind, _: *const zpui.ClickEvent, window: *Window, cx: *Context(RightPane)) void {
        cx.stopPropagation();
        self.plus_open = false;
        self.add(kind, window, cx);
    }

    fn onCard(self: *RightPane, kind: Kind, _: *const zpui.ClickEvent, window: *Window, cx: *Context(RightPane)) void {
        self.add(kind, window, cx);
    }

    fn onDragMove(self: *RightPane, ev: *const zpui.DragMoveEvent(TabDrag), _: *Window, cx: *Context(RightPane)) void {
        const k = self.key(cx) orelse return;
        if (ev.value.key_hash != keyHash(k)) return;
        const t = self.peek(cx) orelse return;
        const rel = ev.event.position.x - ev.bounds.origin.x - self.strip_scroll.offset().x;
        const over = dropIndex(rel, chip_slot, t.tabs.items.len);
        if (self.drag) |*d| {
            if (d.over != over) {
                d.prev_over = d.over;
                d.over = over;
                d.epoch += 1;
                cx.notify();
            }
        } else {
            self.drag = .{ .from = ev.value.from, .over = over, .epoch = 0, .prev_over = ev.value.from };
            cx.notify();
        }
    }

    fn onDrop(self: *RightPane, payload: *const TabDrag, _: *Window, cx: *Context(RightPane)) void {
        const to = if (self.drag) |d| d.over else payload.from;
        self.drag = null;
        const k = self.key(cx) orelse return;
        if (payload.key_hash != keyHash(k)) return cx.notify();
        if (self.current(cx)) |t| _ = t.reorder(payload.from, to);
        cx.notify();
    }

    // ---- render -----------------------------------------------------------------------

    fn titleOf(tab: Tab, cx: anytype) []const u8 {
        return switch (tab.surface) {
            .changes => |e| e.read(cx).tabTitle(),
            .history => |e| e.read(cx).tabTitle(),
            .terminal => |e| terminal_dock.surfaceTitle(e.read(cx)),
            .browser => |e| e.read(cx).tabTitle(),
            .file => |e| e.read(cx).tabTitle(),
            .subagent => |e| e.read(cx).tabTitle(),
            .side_chat => |e| e.read(cx).tabTitle(cx),
        };
    }

    fn iconOf(tab: Tab, cx: anytype) Icon {
        return switch (tab.surface) {
            .changes => |e| e.read(cx).tabIcon(),
            .history => |e| e.read(cx).tabIcon(),
            .terminal => .terminal,
            .browser => |e| e.read(cx).tabIcon(),
            .file => .document,
            .subagent => .bot,
            .side_chat => .chat_round_line,
        };
    }

    fn dirty(tab: Tab, cx: anytype) bool {
        return switch (tab.surface) {
            .file => |e| e.read(cx).hasUnsavedChanges(),
            else => false,
        };
    }

    /// The tab strip (chips + `+`) for the titlebar band; null without tabs
    /// (the empty pane's launcher already offers every surface).
    pub fn renderStrip(self: *RightPane, theme: *const Theme, cx: *Context(RightPane)) ?zpui.AnyElement {
        const k = self.key(cx) orelse return null;
        const t = self.peek(cx) orelse return null;
        if (t.tabs.items.len == 0) return null;
        if (self.drag != null and !cx.app.hasActiveDrag()) self.drag = null;
        const active = t.resolvedActive();
        const kh = keyHash(k);

        var strip = div().id("right-surface-strip").flex().flexRow().itemsCenter().gap(px(4)).minW0()
            .overflowXScroll().trackScroll(self.strip_scroll)
            .onDragMove(TabDrag, cx.listener(onDragMove))
            .onDrop(TabDrag, cx.listener(onDrop));
        for (t.tabs.items, 0..) |tab, ix| {
            const is_active = active == tab.id;
            const title = titleOf(tab, cx);
            const group = zpui.fmt("right-surface-tab-{d}", .{ix});
            var drag: TabDrag = .{ .key_hash = kh, .from = ix };
            const n: u8 = @intCast(@min(title.len, drag.title_buf.len));
            @memcpy(drag.title_buf[0..n], title[0..n]);
            drag.title_len = n;
            if (tab.surface == .file) {
                const fp = tab.surface.file.read(cx).filePath();
                if (fp.len > 0 and fp.len <= drag.path_buf.len) {
                    @memcpy(drag.path_buf[0..fp.len], fp);
                    drag.path_len = @intCast(fp.len);
                }
            }
            var chip = div().id(.{ "right-surface-tab", ix }).role(.button).ariaLabel(if (dirty(tab, cx)) zpui.fmt("{s}, unsaved changes", .{title}) else title).ariaSelected(is_active).group(group)
                .h(px(24)).w(px(chip_w)).flexNone().px(px(4)).rounded(px(6))
                .flex().flexRow().itemsCenter().gap(px(3)).cursorPointer()
                .blockMouseExceptScroll()
                .onMouseDown(.left, onChipDown)
                .onMouseDown(.middle, cx.listenerWith(tab.id, onChipMiddle))
                .onClick(cx.listenerWith(tab.id, onChip))
                .onDrag(drag, buildGhost)
                .onDrop(TabDrag, cx.listener(onDrop))
                .child(div().flexNone().size(px(18)).flex().itemsCenter().justifyCenter()
                    .child(if (tab.surface == .file)
                        zpui.intoAnyElement(div().opacity(if (is_active) 1 else 0.78).child(md.file_icons.icon(tab.surface.file.read(cx).tabIcon(), theme, 14)))
                    else
                        zpui.intoAnyElement(ui.icon.of(iconOf(tab, cx), 12, if (is_active) theme.text_muted else theme.text_muted.opacity(0.7)))))
                .child(div().flex1().minW0().truncate().whitespaceNowrap().textSize(ui.rems(11.5))
                    .textColor(if (is_active) theme.text else theme.text_muted).child(title))
                .child(div().id(.{ "right-surface-close", ix }).role(.button).ariaLabel("Close tab").flexNone().size(px(18)).rounded(px(4)).relative()
                    .hover(sb.bg(theme.wash(0.12)))
                    .tooltipWith(@as([]const u8, "Close tab"), ui.tooltip.build)
                    .onMouseDown(.left, onCloseDown)
                    .onClick(cx.listenerWith(tab.id, onChipClose))
                    .child(if (dirty(tab, cx)) div().absolute().inset0().flex().itemsCenter().justifyCenter()
                        .groupHover(group, sb.opacity(0))
                        .child(div().size(px(6)).roundedFull().bg(theme.text_muted)) else null)
                    .child(div().absolute().inset0().flex().itemsCenter().justifyCenter().opacity(0)
                        .groupHover(group, sb.opacity(1))
                        .child(ui.icon.of(.close, 12, theme.text_muted))));
            chip = if (is_active) chip.bg(theme.wash(0.10)) else chip.hover(sb.bg(theme.wash(0.06)));
            // Sliding transform while a sibling drags over; the dragged chip
            // leaves an invisible spacer (the ghost carries it).
            if (self.drag) |d| {
                if (ix == d.from) {
                    strip = strip.child(div().w(px(chip_w)).h(px(24)).flexNone());
                    continue;
                }
                const target = slideOffset(ix, d.from, d.over) * chip_slot;
                const start = slideOffset(ix, d.from, d.prev_over) * chip_slot;
                const Slide = struct {
                    fn f(c: [2]f32, el: zpui.StatefulDiv, p: f32) zpui.StatefulDiv {
                        return el.left(px(c[0] + (c[1] - c[0]) * p));
                    }
                };
                strip = strip.child(div().relative().child(zpui.withAnimationCtx(chip.relative(), .{ "right-tab-slide", (ix & 0xffff) | (d.epoch << 16) }, zt.motion.tab_slide.animation(), [2]f32{ start, target }, Slide.f)));
                continue;
            }
            strip = strip.child(chip);
        }

        // The `+`: a small menu offering the available surfaces.
        var plus = div().id("right-surface-add").role(.button).ariaLabel("New tab").ariaExpanded(self.plus_open).relative().size(px(24)).flexNone().flex().itemsCenter().justifyCenter()
            .rounded(px(6)).cursorPointer()
            .blockMouseExceptScroll()
            .onMouseDown(.left, onChipDown)
            .onClick(cx.listener(onPlus))
            .child(ui.icon.of(.plus, 13, theme.text_muted));
        plus = (if (self.plus_open) plus.bg(theme.wash(0.11)) else plus.hover(sb.bg(theme.wash(0.11))))
            .tooltipWith(@as([]const u8, "New tab"), ui.tooltip.build);
        if (self.plus_open) plus = plus.child(self.plusMenu(theme, cx));
        strip = strip.child(plus);

        // Edge fades on whichever side hides chips.
        const region = div().relative().minW0().sizeFull().flex().itemsCenter().child(strip);
        return zpui.intoAnyElement(ui.effects.edgeFaded(region, .{
            .band = fade_width,
            .left = true,
            .right = true,
            .scroll = self.strip_scroll,
        }));
    }

    fn plusMenu(self: *RightPane, theme: *const Theme, cx: *Context(RightPane)) zpui.Div {
        const pt = zpui.window.arena_mod.current().create(Theme, theme.forPopup());
        var rows = div().flex().flexCol().gap(px(2));
        const entries = [_]struct { Kind, []const u8, Icon }{
            .{ .files, "Files", .folder_with_files },
            .{ .browser, "Browser", .globe },
            .{ .terminal, "Terminal", .terminal },
            .{ .diffs, "Diffs", .list },
            .{ .history, "History", .git_branch },
        };
        const git = self.gitDetected(cx);
        for (entries) |e| {
            if ((e[0] == .diffs or e[0] == .history) and !git) continue;
            rows = rows.child(ui.popover.menuRow(pt, false).id(.{ "right-plus-row", @intFromEnum(e[0]) }).role(.menu_item)
                .onClick(cx.listenerWith(e[0], onMenuRow))
                .child(ui.icon.of(e[2], 13, pt.text_muted))
                .child(e[1]));
        }
        const card = ui.popover.card(pt).w(px(168)).onMouseDownOut(cx.listener(onPlusOut)).child(rows);
        // `anchored_menu_below_gap(…, 10)`: a dropdown 10px under the button.
        return div().absolute().top(zpui.relative(1)).left(px(0)).child(zpui.deferred(
            zpui.anchored().anchorCorner(.top_left).snapToWindowWithMargin(.all(8))
                .child(ui.anim.menuIn("right-plus-menu", div().occlude().pt(px(10)).child(ui.popover.frostedCard(card)), -2)),
        ).withPriority(1));
    }

    /// The pane body: the active surface, or the launcher.
    pub fn renderContent(self: *RightPane, theme: *const Theme, cx: *Context(RightPane)) zpui.AnyElement {
        const t = self.peek(cx) orelse return self.launcher(theme, cx);
        const id = t.resolvedActive() orelse return self.launcher(theme, cx);
        const tab = t.tabs.items[t.indexOf(id).?];
        return switch (tab.surface) {
            .changes => |e| zpui.intoAnyElement(div().sizeFull().child(e)),
            .history => |e| zpui.intoAnyElement(div().sizeFull().child(e)),
            .terminal => |e| zpui.intoAnyElement(div().sizeFull().borderT1().borderColor(theme.border).child(e)),
            .browser => |e| zpui.intoAnyElement(div().sizeFull().child(e)),
            .file => |e| zpui.intoAnyElement(div().sizeFull().child(e)),
            .subagent => |e| zpui.intoAnyElement(div().sizeFull().child(e)),
            .side_chat => |e| zpui.intoAnyElement(div().sizeFull().child(e)),
        };
    }

    /// The empty pane: 44px rows (icon + label) in a 280px column.
    fn launcher(self: *RightPane, theme: *const Theme, cx: *Context(RightPane)) zpui.AnyElement {
        var list = div().wFull().maxW(px(280)).flex().flexCol().gap(px(8))
            .child(surfaceCard(theme, "surface-card-browser", .globe, "Browser").onClick(cx.listenerWith(Kind.browser, onCard)))
            .child(surfaceCard(theme, "surface-card-terminal", .terminal, "Terminal").onClick(cx.listenerWith(Kind.terminal, onCard)));
        if (self.gitDetected(cx)) list = list
            .child(surfaceCard(theme, "surface-card-diffs", .list, "Diffs").onClick(cx.listenerWith(Kind.diffs, onCard)))
            .child(surfaceCard(theme, "surface-card-history", .git_branch, "History").onClick(cx.listenerWith(Kind.history, onCard)));
        return zpui.intoAnyElement(div().sizeFull().relative().flex().itemsCenter().justifyCenter().p(px(16)).child(list));
    }
};

fn surfaceCard(theme: *const Theme, id: []const u8, i: Icon, title: []const u8) zpui.StatefulDiv {
    return div().id(id).role(.button).ariaLabel(title).wFull().h(px(44)).px(px(14)).rounded(px(10))
        .border1().borderColor(theme.border).bg(theme.ink(0.02))
        .flex().flexRow().itemsCenter().gap(px(10)).cursorPointer()
        .hover(sb.bg(theme.ink(0.05)).borderColor(theme.border_strong))
        .child(ui.icon.of(i, 15, theme.text_muted))
        .child(div().textSize(ui.rems(13)).fontWeight(500).textColor(theme.text).child(title));
}

test "file tab drags carry their workspace path and chat (chat drop zone)" {
    var d: TabDrag = .{ .key_hash = RightPane.keyHash("chat-a"), .from = 0 };
    try std.testing.expect(d.workspacePath() == null);
    @memcpy(d.path_buf[0..10], "src/lib.rs");
    d.path_len = 10;
    try std.testing.expectEqualStrings("src/lib.rs", d.workspacePath().?);
    try std.testing.expect(d.belongsTo("chat-a"));
    try std.testing.expect(!d.belongsTo("chat-b"));
}

test "drop index and slide offsets" {
    try std.testing.expectEqual(@as(usize, 0), dropIndex(-5, chip_slot, 3));
    try std.testing.expectEqual(@as(usize, 1), dropIndex(chip_slot + 1, chip_slot, 3));
    try std.testing.expectEqual(@as(usize, 2), dropIndex(10 * chip_slot, chip_slot, 3));
    try std.testing.expectEqual(@as(usize, 0), dropIndex(50, chip_slot, 0));
    try std.testing.expectEqual(@as(f32, -1), slideOffset(1, 0, 2));
    try std.testing.expectEqual(@as(f32, -1), slideOffset(2, 0, 2));
    try std.testing.expectEqual(@as(f32, 0), slideOffset(3, 0, 2));
    try std.testing.expectEqual(@as(f32, 1), slideOffset(0, 2, 0));
    try std.testing.expectEqual(@as(f32, 0), slideOffset(2, 2, 0));
}

test "chat tabs resolve, reorder and fall back after close" {
    const gpa = std.testing.allocator;
    var t: ChatTabs = .{};
    defer {
        t.tabs.deinit(gpa);
        t.visits.deinit(gpa);
    }
    try std.testing.expectEqual(@as(?u64, null), t.resolvedActive());
    try t.tabs.append(gpa, .{ .id = 1, .surface = .{ .browser = undefined } });
    try t.tabs.append(gpa, .{ .id = 2, .surface = .{ .browser = undefined } });
    try t.tabs.append(gpa, .{ .id = 3, .surface = .{ .browser = undefined } });
    t.visit(gpa, 1);
    t.visit(gpa, 3);
    t.visit(gpa, 2);
    try std.testing.expectEqual(@as(?u64, 2), t.resolvedActive());
    // Close the active tab: the last visited live tab takes over.
    _ = t.tabs.orderedRemove(t.indexOf(2).?);
    t.forget(2);
    try std.testing.expectEqual(@as(?u64, 3), t.resolvedActive());
    try std.testing.expect(t.reorder(1, 0));
    try std.testing.expectEqual(@as(u64, 3), t.tabs.items[0].id);
    try std.testing.expect(!t.reorder(0, 0));
}

// [wiring] Subagent / side-chat tabs, explorer footer rows, Add to chat.
pub const surfaces_glue = @import("right_pane_chats.zig");
