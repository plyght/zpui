//! `FilesPanel`: the session's file explorer — zeron's explorer-mode
//! `FilesSurface` (`files/mod.rs`, `tree.rs`, `search.rs`, `rename.rs`,
//! `context_menu.rs`, `drag.rs` root target, `sections.rs`) as hosted by
//! `shell/files_panel.rs`.
//!
//! - header: the 38px toolbar with the "Search files" field and the
//!   hidden/ignored files toggle (eye);
//! - the "Workspace root" row, then the lazily loaded tree in a virtualized
//!   `uniformList` (27px rows, 14px indent, ancestor guides drawn per row,
//!   chevrons, polychrome file / folder icons, git-status colors, ignored
//!   entries dimmed), 24px edge fades and zeron's compact scrollbar;
//! - keyboard: ↑/↓ select, ←/→ collapse / expand / parent / first child,
//!   Enter/Space activate, F2 rename, Delete delete, Menu / Shift-F10 menu;
//! - search: fuzzy matches as a tree (ancestors for context), ↑/↓/Enter
//!   from the field, Escape clears and returns focus to the tree; opening a
//!   result reveals it in the tree;
//! - context menu: Add to chat, Copy path, Rename…, Delete…; inline rename
//!   and a permanent-delete confirmation (zeron `dialog_card`);
//! - footer: the Subagents / Chats sections with zeron's empty states.
//!
//! ```zig
//! const panel = try cx.newWith(FilesPanel, FilesPanel.init, .{ files, .{} });
//! div().child(panel)      // header + tree (+ footer), fills its parent
//! // events: OpenFile{ .path }, AddToChat{…}, ShowAllFilesChanged{…}, EntryRenamed{…}, …
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const input = @import("zeron_input");
const ui = @import("../components/root.zig");
const dialog = @import("../components/dialog.zig");
const client = @import("client.zig");
const proto = @import("protocol.zig");
const model = @import("model.zig");
const deco = @import("decorations.zig");
const icons = @import("icons.zig");
const search_mod = @import("search.zig");
const drag_mod = @import("drag.zig");
pub const WorkspacePathDrag = drag_mod.WorkspacePathDrag;

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Task = zpui.Task;
const AnyElement = zpui.AnyElement;
const Hsla = zpui.Hsla;
const Point = zpui.Point(f32);
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = zt.Theme;
const TextInput = input.TextInput;

pub const tree_row_height: f32 = 27;
pub const tree_indent: f32 = 14;
pub const root_row_height: f32 = 24;
pub const tree_fade_band: f32 = 24;
pub const header_height: f32 = zt.layout.titlebar_height;
pub const control_size: f32 = 24;
pub const control_radius: f32 = 6;
pub const search_debounce_ms: u64 = 90;

// Sections footer (`sections.rs`).
pub const section_header_height: f32 = 28;
pub const section_body_inset: f32 = 4;
pub const section_row_height: f32 = 29;
pub const section_row_gap: f32 = 2;
pub const empty_copy_height: f32 = 36;
pub const empty_actions_height: f32 = 40;
pub const empty_pad: f32 = 10;
pub const min_body_height: f32 = 120;
pub const footer_pad_top: f32 = 4;
pub const footer_pad_bottom: f32 = 6;
pub const footer_height: f32 = 510;

pub const Options = struct {
    show_all_files: bool = false,
    show_sections: bool = true,
    /// "Files in ~/x · Device" for a chat without a project.
    projectless_label: ?[]const u8 = null,
};

pub const OpenFile = struct { path: []const u8 };
pub const AddToChat = struct { path: []const u8, is_directory: bool };
pub const ShowAllFilesChanged = struct { show_all: bool };
pub const EntryRenamed = struct { old_path: []const u8, new_path: []const u8 };
pub const EntryDeleted = struct { path: []const u8 };
pub const OpenSubagent = struct { doc_id: []const u8, title: []const u8 };
pub const OpenChildChat = struct { chat_id: []const u8 };
pub const NewChildChat = struct {};
pub const ForkChat = struct {};

pub const RowStatus = enum { idle, working, completed, failed, attention };

pub const SectionRow = struct {
    id: []const u8,
    title: []const u8,
    time_ago: []const u8 = "",
    status: RowStatus = .idle,
};

const SectionKind = enum { subagents, chats };

const Rename = struct {
    path: []u8,
    input: Entity(TextInput),
    sub: zpui.Subscription,
};

/// `TreeDrag`: an entry dragged within the tree (move into a folder).
const TreeDrag = struct {
    payload: ?WorkspacePathDrag = null,
    /// The folder under the pointer ("" = workspace root); owned.
    destination: ?[]u8 = null,
    pointer: Point = .{ .x = 0, .y = 0 },
    bounds: zpui.Bounds(f32) = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } },
    hover_since: ?u64 = null,
    last_tick: ?u64 = null,
    ticking: bool = false,
};

const DeleteFlow = struct {
    path: []u8,
    is_dir: bool,
    revision: ?[]u8,
    confirm_focused: bool = false,
};

const ContextMenu = struct {
    path: []u8,
    position: Point,
};

pub const FilesPanel = struct {
    gpa: Allocator,
    files: Entity(client.WorkspaceFiles),
    subs: zpui.Subscriptions = .{},
    opts: Options,
    tree: model.TreeModel,
    decorations: deco.Decorations,
    scroll: zpui.UniformListScrollHandle,
    tree_focus: zpui.FocusHandle,
    delete_focus: zpui.FocusHandle,
    focus_delete: bool = false,
    started: bool = false,
    root_error: ?[]u8 = null,
    capabilities: proto.MutationCapabilities = .{},

    // search
    search: Entity(TextInput),
    query: std.ArrayList(u8) = .empty,
    results: ?client.SearchResult = null,
    search_tree: search_mod.SearchTree,
    search_active: usize = 0,
    search_loading: bool = false,
    search_error: ?[]u8 = null,
    search_generation: u64 = 0,
    search_timer: Task(void) = .none,
    search_scroll: zpui.UniformListScrollHandle,
    restore_tree_focus: bool = false,

    // reveal (search result / editor sync)
    reveal_path: ?[]u8 = null,

    // mutations
    menu: ?ContextMenu = null,
    rename: ?Rename = null,
    delete_flow: ?DeleteFlow = null,
    mutation_error: ?[]u8 = null,
    mutation_busy: bool = false,
    pending_old: ?[]u8 = null,
    pending_new: ?[]u8 = null,
    window_id: zpui.WindowId = undefined,
    refresh_timer: Task(void) = .none,
    refresh_dirs: std.StringArrayHashMapUnmanaged(void) = .empty,

    // drag (`files/drag.rs`)
    /// The chat whose explorer this is (`drag.ownerOf`); stamped on drags.
    drag_owner: u64 = 0,
    tree_drag: TreeDrag = .{},
    drag_timer: Task(void) = .none,

    // sections
    subagents: std.ArrayList(SectionRow) = .empty,
    chats: std.ArrayList(SectionRow) = .empty,
    section_arena: std.heap.ArenaAllocator,
    /// Event payload strings (emits are delivered after the callback returns).
    event_arena: std.heap.ArenaAllocator,
    subagents_open: bool = true,
    chats_open: bool = true,

    pub const Events = .{ OpenFile, AddToChat, ShowAllFilesChanged, EntryRenamed, EntryDeleted, OpenSubagent, OpenChildChat, NewChildChat, ForkChat };

    pub fn init(files: Entity(client.WorkspaceFiles), opts: Options, cx: *Context(FilesPanel)) !FilesPanel {
        const gpa = cx.gpa();
        const theme = ui.theme.get(cx);
        const search = try cx.newWith(TextInput, TextInput.init, .{input.Options{
            .placeholder = "Search files",
            .key_context = "Composer",
            .role = .search_input,
            .single_line = true,
            .text_size = 11.5,
            .line_height = 16,
            .colors = .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
            .edge_fade = false,
        }});
        var self: FilesPanel = .{
            .gpa = gpa,
            .files = files.retain(cx),
            .opts = opts,
            .tree = .init(gpa, opts.show_all_files),
            .decorations = .init(gpa),
            .scroll = zpui.UniformListScrollHandle.init(gpa),
            .tree_focus = cx.focusHandle().tabStop(true),
            .delete_focus = cx.focusHandle(),
            .search = search,
            .search_tree = .init(gpa),
            .search_scroll = zpui.UniformListScrollHandle.init(gpa),
            .section_arena = .init(gpa),
            .event_arena = .init(gpa),
        };
        if (opts.projectless_label) |l| self.opts.projectless_label = try gpa.dupe(u8, l);
        try self.subs.add(gpa, try cx.subscribe(search, onSearchEvent));
        try self.subs.add(gpa, try cx.subscribe(files, onFileChanges));
        try self.subs.add(gpa, try cx.subscribe(files, onGitStatus));
        self.decorations.load(files.read(cx).gitStatus());
        return self;
    }

    pub fn deinit(self: *FilesPanel, app: *App) void {
        self.subs.deinit(self.gpa);
        self.search_timer.cancel();
        self.refresh_timer.cancel();
        self.drag_timer.cancel();
        self.freeOpt(&self.tree_drag.destination);
        self.tree.deinit();
        self.decorations.deinit();
        self.scroll.release();
        self.search_scroll.release();
        self.tree_focus.release(app);
        self.delete_focus.release(app);
        self.search.release(app);
        self.query.deinit(self.gpa);
        if (self.results) |r| r.deinit();
        self.search_tree.deinit();
        self.freeOpt(&self.root_error);
        self.freeOpt(&self.search_error);
        self.freeOpt(&self.reveal_path);
        self.freeOpt(&self.mutation_error);
        self.freeOpt(&self.pending_old);
        self.freeOpt(&self.pending_new);
        if (self.menu) |m| self.gpa.free(m.path);
        self.dropRename(app);
        self.dropDelete();
        for (self.refresh_dirs.keys()) |k| self.gpa.free(k);
        self.refresh_dirs.deinit(self.gpa);
        self.subagents.deinit(self.gpa);
        self.chats.deinit(self.gpa);
        self.section_arena.deinit();
        self.event_arena.deinit();
        if (self.opts.projectless_label) |l| self.gpa.free(l);
        self.files.release(app);
    }

    /// A copy that lives until the next render (for event payloads).
    fn keep(self: *FilesPanel, v: []const u8) []const u8 {
        return self.event_arena.allocator().dupe(u8, v) catch v;
    }

    fn freeOpt(self: *FilesPanel, p: *?[]u8) void {
        if (p.*) |s| self.gpa.free(s);
        p.* = null;
    }

    fn setOpt(self: *FilesPanel, p: *?[]u8, v: ?[]const u8) void {
        self.freeOpt(p);
        if (v) |s| p.* = self.gpa.dupe(u8, s) catch null;
    }

    // ---- public API -----------------------------------------------------------------

    pub fn tabTitle(_: *const FilesPanel) []const u8 {
        return "Files";
    }

    pub fn tabIcon(_: *const FilesPanel) ui.icon.Icon {
        return .file_tree;
    }

    /// Start loading the root (idempotent; the host calls it when shown).
    /// The chat this explorer belongs to (drags into the conversation are
    /// accepted only by that chat).
    pub fn setDragOwner(self: *FilesPanel, chat_id: []const u8, _: *Context(FilesPanel)) void {
        self.drag_owner = drag_mod.ownerOf(chat_id);
    }

    pub fn ensureLoaded(self: *FilesPanel, cx: *Context(FilesPanel)) void {
        self.files.update(cx, client.WorkspaceFiles.ensureWatch, .{});
        if (self.started) return;
        self.started = true;
        self.loadDirectory("", false, cx);
    }

    /// Focus the tree (re-applied on the next render, once it is laid out).
    pub fn focusTree(self: *FilesPanel, window: *Window) void {
        window.focus(self.tree_focus);
        self.restore_tree_focus = true;
    }

    pub fn includeIgnored(self: *const FilesPanel) bool {
        return self.tree.include_ignored;
    }

    /// Apply the host's "show all files" preference.
    pub fn setShowAllFiles(self: *FilesPanel, show: bool, cx: *Context(FilesPanel)) void {
        if (!self.tree.setIncludeIgnored(show)) return;
        self.started = false;
        self.freeOpt(&self.root_error);
        self.ensureLoaded(cx);
        if (self.query.items.len > 0) self.runSearch(cx);
        cx.notify();
    }

    /// Select (and reveal) the active editor's file without touching the search
    /// (zeron `reveal_file`).
    pub fn revealFile(self: *FilesPanel, path: []const u8, cx: *Context(FilesPanel)) void {
        if (self.tree.selected) |s| if (std.mem.eql(u8, s, path)) return;
        self.setOpt(&self.reveal_path, path);
        self.continueReveal(cx);
    }

    /// Footer rows (the host maps subagents / side chats into them).
    pub fn setSections(self: *FilesPanel, subagents: []const SectionRow, chats: []const SectionRow, cx: *Context(FilesPanel)) void {
        _ = self.section_arena.reset(.retain_capacity);
        const a = self.section_arena.allocator();
        self.subagents.clearRetainingCapacity();
        self.chats.clearRetainingCapacity();
        for (subagents) |r| self.subagents.append(self.gpa, dupRow(a, r)) catch {};
        for (chats) |r| self.chats.append(self.gpa, dupRow(a, r)) catch {};
        cx.notify();
    }

    fn dupRow(a: Allocator, r: SectionRow) SectionRow {
        return .{ .id = a.dupe(u8, r.id) catch "", .title = a.dupe(u8, r.title) catch "", .time_ago = a.dupe(u8, r.time_ago) catch "", .status = r.status };
    }

    // ---- loading ------------------------------------------------------------------

    pub fn loadDirectory(self: *FilesPanel, directory: []const u8, paging: bool, cx: *Context(FilesPanel)) void {
        if (!self.tree.beginLoad(directory, paging)) return;
        var cursor: ?[]const u8 = null;
        if (paging) if (self.tree.node(directory)) |n| switch (n.load) {
            .loaded => |l| cursor = l.next_cursor,
            else => {},
        };
        self.files.read(cx).listDirectory(cx, .{ .directory = directory, .include_ignored = self.tree.include_ignored, .cursor = cursor }, onListed);
        if (directory.len > 0) self.files.update(cx, client.WorkspaceFiles.watchDirectory, .{directory});
        cx.notify();
    }

    fn onListed(self: *FilesPanel, res: client.DirectoryResult, cx: *Context(FilesPanel)) void {
        defer res.deinit();
        const anchor = self.captureAnchor();
        if (res.err) |e| {
            const dir = if (res.value) |v| v.directory else "";
            if (res.value == null) {
                // Engine errors carry no directory: fail every pending load.
                var it = self.tree.nodes.valueIterator();
                while (it.next()) |n| if (n.*.load == .loading) self.tree.failLoad(n.*.path, e, false);
            } else self.tree.failLoad(dir, e, false);
            if (dir.len == 0 and !self.tree.rootLoaded()) self.setOpt(&self.root_error, e);
        } else if (res.value) |page| {
            if (page.mutationCapabilities) |c| self.capabilities = c;
            self.tree.applyPage(page, false);
            if (page.directory.len == 0) {
                self.freeOpt(&self.root_error);
                self.files.update(cx, client.WorkspaceFiles.watchDirectory, .{""});
            }
            if (self.tree.node(page.directory)) |n| if (n.stale) self.loadDirectory(page.directory, false, cx);
        }
        self.restoreAnchor(anchor);
        self.continueReveal(cx);
        cx.notify();
    }

    fn retryRoot(self: *FilesPanel, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FilesPanel)) void {
        self.freeOpt(&self.root_error);
        self.loadDirectory("", false, cx);
    }

    /// Reload every loaded directory (watch resync / "Refresh now").
    pub fn refresh(self: *FilesPanel, cx: *Context(FilesPanel)) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        self.loadDirectory("", false, cx);
        for (self.tree.expandedDirectories(arena.allocator())) |d| self.loadDirectory(d, false, cx);
    }

    fn onFileChanges(self: *FilesPanel, _: Entity(client.WorkspaceFiles), ev: *const client.FileChangesEvent, cx: *Context(FilesPanel)) void {
        if (ev.resync) return self.refresh(cx);
        for (ev.changes) |ch| {
            self.queueRefresh(model.parentPath(ch.path));
            if (self.tree.node(ch.path)) |n| if (n.kind == .directory) self.queueRefresh(ch.path);
            if (ch.oldPath) |old| self.queueRefresh(model.parentPath(old));
        }
        if (self.refresh_timer.header == null) self.refresh_timer = cx.timer(60 * std.time.ns_per_ms, onRefreshTimer) catch .none;
    }

    fn queueRefresh(self: *FilesPanel, dir: []const u8) void {
        if (self.refresh_dirs.contains(dir)) return;
        self.refresh_dirs.put(self.gpa, self.gpa.dupe(u8, dir) catch return, {}) catch {};
    }

    fn onRefreshTimer(self: *FilesPanel, cx: *Context(FilesPanel)) void {
        self.refresh_timer.detach();
        self.refresh_timer = .none;
        for (self.refresh_dirs.keys()) |d| {
            if (self.tree.node(d)) |n| if (n.has_loaded and (d.len == 0 or self.tree.isExpanded(d))) {
                self.loadDirectory(n.path, false, cx);
            } else if (n.has_loaded) {
                n.stale = true;
            };
            self.gpa.free(d);
        }
        self.refresh_dirs.clearRetainingCapacity();
        if (self.query.items.len > 0) self.runSearch(cx);
    }

    fn onGitStatus(self: *FilesPanel, files: Entity(client.WorkspaceFiles), _: *const client.GitStatusChanged, cx: *Context(FilesPanel)) void {
        self.decorations.load(files.read(cx).gitStatus());
        cx.notify();
    }

    // ---- scroll anchoring (zeron `sync_list_rows`) ---------------------------------

    const Anchor = struct { path: ?[]u8, within: f32 };

    fn captureAnchor(self: *FilesPanel) Anchor {
        const rows = self.tree.rows();
        const y = -self.scroll.offset().y;
        if (rows.len == 0 or y <= 0) return .{ .path = null, .within = 0 };
        const ix: usize = @min(@as(usize, @intFromFloat(@floor(y / tree_row_height))), rows.len - 1);
        return .{ .path = self.gpa.dupe(u8, rows[ix].path) catch null, .within = y - @as(f32, @floatFromInt(ix)) * tree_row_height };
    }

    fn restoreAnchor(self: *FilesPanel, anchor: Anchor) void {
        const path = anchor.path orelse return;
        defer self.gpa.free(path);
        var candidate: []const u8 = path;
        const rows = self.tree.rows();
        while (true) {
            for (rows, 0..) |r, i| if (std.mem.eql(u8, r.path, candidate)) {
                const y = @as(f32, @floatFromInt(i)) * tree_row_height + anchor.within;
                self.scroll.setOffset(.{ .x = 0, .y = -y });
                return;
            };
            if (candidate.len == 0) return;
            candidate = model.parentPath(candidate);
        }
    }

    // ---- activation ----------------------------------------------------------------

    fn activatePath(self: *FilesPanel, path: []const u8, cx: *Context(FilesPanel)) void {
        self.tree.select(path);
        const n = self.tree.node(path) orelse return;
        if (n.kind == .directory) {
            self.toggleDirectory(n.path, cx);
        } else {
            cx.emit(OpenFile{ .path = self.keep(n.path) });
        }
        self.revealSelection();
        cx.notify();
    }

    fn toggleDirectory(self: *FilesPanel, path: []const u8, cx: *Context(FilesPanel)) void {
        const anchor = self.captureAnchor();
        if (!self.tree.toggleExpanded(path)) {
            if (anchor.path) |p| self.gpa.free(p);
            return;
        }
        self.restoreAnchor(anchor);
        const n = self.tree.node(path) orelse return;
        if (self.tree.isExpanded(path)) {
            const needs = n.stale or n.load == .unloaded or n.load == .failed;
            if (needs) self.loadDirectory(n.path, false, cx);
            self.files.update(cx, client.WorkspaceFiles.watchDirectory, .{n.path});
        } else {
            self.files.update(cx, client.WorkspaceFiles.unwatchDirectory, .{n.path});
        }
    }

    fn revealSelection(self: *FilesPanel) void {
        if (self.tree.selectedIndex()) |ix| self.scroll.scrollToItem(ix, .nearest);
    }

    /// Expand ancestors of `reveal_path` (loading them as needed), then select it.
    fn continueReveal(self: *FilesPanel, cx: *Context(FilesPanel)) void {
        const path = self.reveal_path orelse return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const pending = self.tree.revealAncestors(path, arena.allocator());
        for (pending) |dir| {
            const n = self.tree.node(dir) orelse return; // wait for the parent's listing
            if (n.load != .loading) self.loadDirectory(n.path, false, cx);
            return;
        }
        if (self.tree.node(path) != null) {
            self.tree.select(path);
            self.revealSelection();
            self.freeOpt(&self.reveal_path);
            cx.notify();
        }
    }

    // ---- tree input ----------------------------------------------------------------

    fn onRowClick(self: *FilesPanel, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(FilesPanel)) void {
        window.focus(self.tree_focus);
        const rows = self.tree.rows();
        if (ix >= rows.len) return;
        const r = rows[ix];
        switch (r.kind) {
            .entry => self.activatePath(r.path, cx),
            .failed => self.loadDirectory(r.path, false, cx),
            .load_more => self.loadDirectory(r.path, true, cx),
            else => {},
        }
    }

    fn onRowRightDown(self: *FilesPanel, ix: usize, ev: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(FilesPanel)) void {
        const rows = self.tree.rows();
        if (ix >= rows.len or rows[ix].kind != .entry) return;
        window.preventDefault();
        cx.stopPropagation();
        self.openMenu(rows[ix].path, ev.position, cx);
        window.focus(self.tree_focus);
    }

    fn openMenu(self: *FilesPanel, path: []const u8, pos: Point, cx: *Context(FilesPanel)) void {
        self.tree.select(path);
        if (self.menu) |m| self.gpa.free(m.path);
        self.menu = .{ .path = self.gpa.dupe(u8, path) catch return, .position = pos };
        cx.notify();
    }

    fn closeMenu(self: *FilesPanel) void {
        if (self.menu) |m| self.gpa.free(m.path);
        self.menu = null;
    }

    fn onTreeMouseDown(self: *FilesPanel, _: *const zpui.input.MouseDownEvent, window: *Window, _: *Context(FilesPanel)) void {
        window.focus(self.tree_focus);
    }

    fn onTreeKey(self: *FilesPanel, ev: *const zpui.input.KeyDownEvent, window: *Window, cx: *Context(FilesPanel)) void {
        if (self.rename != null) return;
        const key = ev.keystroke.key;
        const handled = blk: {
            if (std.mem.eql(u8, key, "menu") or (std.mem.eql(u8, key, "f10") and ev.keystroke.modifiers.shift)) {
                if (self.tree.selected) |s| {
                    const p = self.gpa.dupe(u8, s) catch break :blk true;
                    defer self.gpa.free(p);
                    self.openMenu(p, .{ .x = 1360, .y = 120 }, cx);
                }
                break :blk true;
            }
            if (std.mem.eql(u8, key, "f2") or std.mem.eql(u8, key, "delete")) {
                if (self.tree.selected) |s| {
                    const p = self.gpa.dupe(u8, s) catch break :blk true;
                    defer self.gpa.free(p);
                    if (key[0] == 'f') self.beginRename(p, window, cx) else self.beginDelete(p, cx);
                }
                break :blk true;
            }
            if (std.mem.eql(u8, key, "up")) {
                self.tree.selectPrevious();
                break :blk true;
            }
            if (std.mem.eql(u8, key, "down")) {
                self.tree.selectNext();
                break :blk true;
            }
            if (std.mem.eql(u8, key, "left")) {
                if (self.tree.selected) |s| {
                    if (self.tree.isExpanded(s)) {
                        const p = self.gpa.dupe(u8, s) catch break :blk true;
                        defer self.gpa.free(p);
                        self.toggleDirectory(p, cx);
                    } else self.tree.selectParent();
                }
                break :blk true;
            }
            if (std.mem.eql(u8, key, "right")) {
                if (self.tree.selected) |s| if (self.tree.node(s)) |n| if (n.kind == .directory) {
                    if (self.tree.isExpanded(s)) self.tree.selectFirstChild() else self.toggleDirectory(n.path, cx);
                };
                break :blk true;
            }
            if (std.mem.eql(u8, key, "enter") or std.mem.eql(u8, key, "space")) {
                if (self.tree.selected) |s| {
                    const p = self.gpa.dupe(u8, s) catch break :blk true;
                    defer self.gpa.free(p);
                    self.activatePath(p, cx);
                }
                break :blk true;
            }
            break :blk false;
        };
        if (handled) {
            window.preventDefault();
            cx.stopPropagation();
            self.revealSelection();
            cx.notify();
        }
    }

    fn onToggleIgnored(self: *FilesPanel, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FilesPanel)) void {
        const next = !self.tree.include_ignored;
        cx.emit(ShowAllFilesChanged{ .show_all = next });
        self.setShowAllFiles(next, cx);
    }

    // ---- search --------------------------------------------------------------------

    fn onSearchEvent(self: *FilesPanel, _: Entity(TextInput), ev: *const input.TextInputEvent, cx: *Context(FilesPanel)) void {
        switch (ev.*) {
            .edited => self.onSearchEdited(cx),
            .submitted, .modified_submitted, .mention_accept => self.activateSearchResult(cx),
            .mention_navigate => |d| {
                const n = self.search_tree.rows.items.len;
                if (n == 0) return;
                self.search_active = if (d < 0) self.search_active -| 1 else @min(self.search_active + 1, n - 1);
                self.search_scroll.scrollToItem(self.search_active, .nearest);
                cx.notify();
            },
            .mention_dismiss, .escape => self.closeSearch(cx),
            else => {},
        }
    }

    fn onSearchEdited(self: *FilesPanel, cx: *Context(FilesPanel)) void {
        const q = std.mem.trim(u8, self.search.read(cx).text(), " \t");
        if (std.mem.eql(u8, q, self.query.items)) return;
        self.query.clearRetainingCapacity();
        self.query.appendSlice(self.gpa, q) catch {};
        self.search_generation += 1;
        self.search_active = 0;
        self.freeOpt(&self.search_error);
        self.search_timer.cancel();
        self.search_timer = .none;
        if (q.len == 0) {
            self.search_loading = false;
            if (self.results) |r| r.deinit();
            self.results = null;
            self.search_tree.clear();
            self.search.update(cx, TextInput.setMentionControls, .{ false, false });
            self.revealSelection();
            cx.notify();
            return;
        }
        self.search_loading = true;
        self.search_timer = cx.timer(search_debounce_ms * std.time.ns_per_ms, onSearchTimer) catch .none;
        cx.notify();
    }

    fn onSearchTimer(self: *FilesPanel, cx: *Context(FilesPanel)) void {
        self.search_timer.detach();
        self.search_timer = .none;
        self.runSearch(cx);
    }

    fn runSearch(self: *FilesPanel, cx: *Context(FilesPanel)) void {
        if (self.query.items.len == 0) return;
        self.search_generation += 1;
        self.search_loading = true;
        self.files.read(cx).search(cx, self.query.items, self.tree.include_ignored, onSearchResults);
    }

    fn onSearchResults(self: *FilesPanel, res: client.SearchResult, cx: *Context(FilesPanel)) void {
        // Only the newest request counts (results arrive in order per request id).
        if (self.query.items.len == 0) {
            res.deinit();
            return;
        }
        self.search_loading = false;
        if (res.err) |e| {
            self.setOpt(&self.search_error, e);
            res.deinit();
            cx.notify();
            return;
        }
        if (self.results) |r| r.deinit();
        self.results = res;
        self.search_tree.rebuild(res.value orelse &.{});
        self.search_active = @min(self.search_active, self.search_tree.rows.items.len -| 1);
        self.search.update(cx, TextInput.setMentionControls, .{ true, self.search_tree.rows.items.len > 0 });
        cx.notify();
    }

    fn closeSearch(self: *FilesPanel, cx: *Context(FilesPanel)) void {
        self.search.update(cx, TextInput.setText, .{""});
        self.onSearchEdited(cx);
        self.restore_tree_focus = true;
        cx.notify();
    }

    fn activateSearchResult(self: *FilesPanel, cx: *Context(FilesPanel)) void {
        const rows = self.search_tree.rows.items;
        if (self.search_active >= rows.len) return;
        const r = rows[self.search_active];
        if (r.kind == .directory and r.has_children) {
            const path = r.path;
            if (self.search_tree.toggle(path)) {
                for (self.search_tree.rows.items, 0..) |x, i| if (std.mem.eql(u8, x.path, path)) {
                    self.search_active = i;
                };
                cx.notify();
                return;
            }
        }
        const path = self.gpa.dupe(u8, r.path) catch return;
        defer self.gpa.free(path);
        const is_dir = r.kind == .directory;
        // Reveal in the tree, clear the search, and open files.
        self.setOpt(&self.reveal_path, path);
        self.closeSearch(cx);
        if (is_dir) {
            self.setOpt(&self.reveal_path, path);
            self.continueReveal(cx);
            if (self.tree.node(path)) |n| if (!self.tree.isExpanded(path)) self.toggleDirectory(n.path, cx);
        } else {
            self.continueReveal(cx);
            cx.emit(OpenFile{ .path = self.keep(path) });
        }
    }

    fn onSearchRowClick(self: *FilesPanel, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FilesPanel)) void {
        self.search_active = ix;
        self.activateSearchResult(cx);
    }

    fn onSearchFieldDown(self: *FilesPanel, _: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(FilesPanel)) void {
        window.focus(self.search.read(cx).focusHandle());
        cx.stopPropagation();
    }

    fn onHeaderKey(self: *FilesPanel, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Context(FilesPanel)) void {
        if (std.mem.eql(u8, ev.keystroke.key, "escape")) {
            self.closeSearch(cx);
            cx.stopPropagation();
        }
    }

    // ---- drag (`files/drag.rs`) --------------------------------------------------------

    /// A row's drag payload (`WorkspacePathDrag::new(..).with_origin(..)`).
    fn dragPayload(self: *const FilesPanel, source: drag_mod.Source, path: []const u8, is_dir: bool, revision: ?[]const u8) ?WorkspacePathDrag {
        return WorkspacePathDrag.init(self.drag_owner, source, path, is_dir, revision);
    }

    /// `tree_drag_compatible`: a tree drag from this explorer whose entry
    /// is still the revision it started as, while no mutation is in flight.
    fn treeDragCompatible(self: *const FilesPanel, p: *const WorkspacePathDrag) bool {
        if (p.source != .tree or p.owner == 0 or p.owner != self.drag_owner) return false;
        if (self.mutation_busy or self.rename != null or self.delete_flow != null) return false;
        if (!self.capabilities.moveEntry) return false;
        const n = self.tree.node(p.path()) orelse return false;
        if (n.kind == .symlink) return false;
        const rev = n.revision orelse return false;
        const prev = p.revision() orelse return false;
        return std.mem.eql(u8, rev, prev);
    }

    /// `drop_directory_at`: the folder a drop at `point` targets ("" = the
    /// workspace root), borrowed from the tree. The root row, folder rows,
    /// file rows (their parent) and an empty folder's placeholder are targets;
    /// the empty space below the last row is the root; the scrollbar rail is not.
    fn dropDirectoryAt(self: *const FilesPanel, point: Point) ?[]const u8 {
        const b = self.tree_drag.bounds;
        if (!b.contains(point)) return null;
        if (point.x > b.right() - drag_mod.rail_width) return null;
        if (point.y < b.origin.y + root_row_height) return "";
        const handle = self.scroll.baseHandle();
        const vp = handle.bounds();
        if (!vp.contains(point)) return null;
        const rel = point.y - vp.origin.y - handle.offset().y;
        if (rel < 0) return null;
        const ix: usize = @intFromFloat(@floor(rel / tree_row_height));
        const rows = self.tree.rows();
        if (ix >= rows.len) return "";
        const r = rows[ix];
        switch (r.kind) {
            .entry => {
                const n = self.tree.node(r.path) orelse return null;
                return switch (n.kind) {
                    .directory => n.path,
                    .file => model.parentPath(n.path),
                    .symlink => null,
                };
            },
            .empty => return r.path,
            else => return null,
        }
    }

    /// The valid destination folder at `point` for `p` (owned copy), if any.
    fn destinationAt(self: *FilesPanel, p: *const WorkspacePathDrag, point: Point) ?[]u8 {
        const dir = self.dropDirectoryAt(point) orelse return null;
        var buf: [2048]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        _ = drag_mod.destinationPath(fba.allocator(), p.path(), dir, p.is_directory) orelse return null;
        return self.gpa.dupe(u8, dir) catch null;
    }

    fn setDestination(self: *FilesPanel, dest: ?[]u8, now: u64) bool {
        const same = if (self.tree_drag.destination) |a| (if (dest) |b| std.mem.eql(u8, a, b) else false) else dest == null;
        if (same) {
            if (dest) |d| self.gpa.free(d);
            return false;
        }
        self.freeOpt(&self.tree_drag.destination);
        self.tree_drag.destination = dest;
        self.tree_drag.hover_since = now;
        return true;
    }

    fn setDragCursor(cx: anytype, style: zpui.platform.CursorStyle) void {
        if (cx.app.active_drag) |*d| d.cursor_style = style;
    }

    /// `on_tree_drag_move`.
    fn onTreeDragMove(self: *FilesPanel, ev: *const zpui.DragMoveEvent(WorkspacePathDrag), window: *Window, cx: *Context(FilesPanel)) void {
        const payload = ev.value.*;
        self.tree_drag.bounds = ev.bounds;
        if (!ev.bounds.contains(ev.event.position) or !self.treeDragCompatible(&payload)) {
            self.clearTreeDrag(cx);
            return;
        }
        if (self.menu != null) self.closeMenu();
        self.window_id = window.id;
        self.tree_drag.pointer = ev.event.position;
        self.tree_drag.payload = payload;
        const now = cx.app.executor.now();
        if (self.setDestination(self.destinationAt(&payload, ev.event.position), now)) cx.notify();
        if (!self.tree_drag.ticking) {
            self.tree_drag.ticking = true;
            self.tree_drag.last_tick = now;
            self.drag_timer = cx.timer(drag_mod.tick_ns, onDragTick) catch .none;
        }
        setDragCursor(cx, if (self.tree_drag.destination != null) .closed_hand else .operation_not_allowed);
    }

    /// `on_tree_drop`: move the entry into the folder under the pointer.
    fn onTreeDrop(self: *FilesPanel, payload: *const WorkspacePathDrag, window: *Window, cx: *Context(FilesPanel)) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const dest: ?[]const u8 = if (self.treeDragCompatible(payload)) blk: {
            const dir = self.dropDirectoryAt(window.mousePosition()) orelse break :blk null;
            break :blk drag_mod.destinationPath(arena.allocator(), payload.path(), dir, payload.is_directory);
        } else null;
        self.clearTreeDrag(cx);
        const d = dest orelse return;
        const n = self.tree.node(payload.path()) orelse return;
        self.freeOpt(&self.mutation_error);
        self.mutation_busy = true;
        self.setOpt(&self.pending_old, payload.path());
        self.setOpt(&self.pending_new, d);
        self.files.read(cx).moveEntry(cx, .{ .source = payload.path(), .destination = d, .revision = n.revision orelse "", .kind = n.kind }, onMoved);
        cx.notify();
    }

    /// `tree_drag_tick`: edge autoscroll and hover-to-expand, every 16 ms
    /// while the drag stays over the tree.
    fn onDragTick(self: *FilesPanel, cx: *Context(FilesPanel)) void {
        self.drag_timer.detach();
        self.drag_timer = .none;
        self.tree_drag.ticking = false;
        const payload = self.tree_drag.payload orelse return;
        const window = cx.app.windowById(self.window_id) orelse return self.clearTreeDrag(cx);
        const pointer = window.mousePosition();
        if (cx.app.activeDrag(WorkspacePathDrag) == null or !window.isWindowActive() or
            !self.treeDragCompatible(&payload) or !self.tree_drag.bounds.contains(pointer))
        {
            self.clearTreeDrag(cx);
            return;
        }
        const now = cx.app.executor.now();
        const elapsed: f32 = if (self.tree_drag.last_tick) |last| @min(@as(f32, @floatFromInt(now -| last)) / std.time.ns_per_s, 0.05) else 0;
        self.tree_drag.last_tick = now;
        const handle = self.scroll.baseHandle();
        const vp = handle.bounds();
        const speed = if (vp.contains(pointer)) drag_mod.edgeScrollSpeed(pointer.y, vp.origin.y, vp.bottom()) else 0;
        if (speed != 0) {
            const off = handle.offset();
            const max = handle.maxOffset();
            // Offsets are negative going down (`max_offset` is the positive extent).
            const y = std.math.clamp(off.y - speed * elapsed, -max.y, 0);
            handle.setOffset(.{ .x = off.x, .y = y });
            cx.notify();
        }
        if (self.setDestination(self.destinationAt(&payload, pointer), now)) cx.notify();
        if (self.tree_drag.hover_since) |since| if (now -| since >= drag_mod.hover_expand_ns) {
            self.tree_drag.hover_since = null;
            if (self.tree_drag.destination) |dir| if (dir.len > 0 and !self.tree.isExpanded(dir)) {
                const copy = self.gpa.dupe(u8, dir) catch return;
                defer self.gpa.free(copy);
                if (self.tree.expand(copy)) {
                    if (self.tree.node(copy)) |n| {
                        if (n.stale or !n.has_loaded) self.loadDirectory(n.path, false, cx);
                        self.files.update(cx, client.WorkspaceFiles.watchDirectory, .{n.path});
                    }
                    cx.notify();
                }
            };
        };
        self.tree_drag.ticking = true;
        self.drag_timer = cx.timer(drag_mod.tick_ns, onDragTick) catch blk: {
            self.tree_drag.ticking = false;
            break :blk .none;
        };
    }

    /// `clear_tree_drag`.
    fn clearTreeDrag(self: *FilesPanel, cx: *Context(FilesPanel)) void {
        self.drag_timer.cancel();
        self.drag_timer = .none;
        self.tree_drag.ticking = false;
        self.tree_drag.hover_since = null;
        self.tree_drag.last_tick = null;
        if (self.tree_drag.payload != null or self.tree_drag.destination != null) {
            self.tree_drag.payload = null;
            self.freeOpt(&self.tree_drag.destination);
            setDragCursor(cx, .arrow);
            cx.notify();
        }
    }

    /// The highlighted drop folder (`tree_drag.destination`).
    fn dropHighlighted(self: *const FilesPanel, path: []const u8) bool {
        const d = self.tree_drag.destination orelse return false;
        return std.mem.eql(u8, d, path);
    }

    // ---- mutations -----------------------------------------------------------------

    fn canMutate(self: *const FilesPanel, path: []const u8, deleting: bool) bool {
        if (self.mutation_busy) return false;
        const allowed = if (deleting) self.capabilities.deleteEntry else self.capabilities.moveEntry;
        if (!allowed) return false;
        const n = self.tree.node(path) orelse return false;
        return n.kind != .symlink and n.revision != null;
    }

    fn onMenuRow(self: *FilesPanel, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(FilesPanel)) void {
        const m = self.menu orelse return;
        const path = self.gpa.dupe(u8, m.path) catch return;
        defer self.gpa.free(path);
        self.closeMenu();
        switch (ix) {
            0 => {
                const is_dir = if (self.tree.node(path)) |n| n.kind == .directory else false;
                cx.emit(AddToChat{ .path = self.keep(path), .is_directory = is_dir });
            },
            1 => {
                var arena = std.heap.ArenaAllocator.init(self.gpa);
                defer arena.deinit();
                input.text_input.writeClipboard(cx.app, self.files.read(cx).absolutePath(arena.allocator(), path));
                window.focus(self.tree_focus);
            },
            2 => self.beginRename(path, window, cx),
            3 => self.beginDelete(path, cx),
            else => {},
        }
        cx.notify();
    }

    fn onMenuOutside(self: *FilesPanel, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(FilesPanel)) void {
        self.closeMenu();
        cx.notify();
    }

    pub fn beginRename(self: *FilesPanel, path: []const u8, window: *Window, cx: *Context(FilesPanel)) void {
        if (!self.canMutate(path, false)) return;
        const n = self.tree.node(path) orelse return;
        self.dropRename(cx.app);
        const theme = ui.theme.get(cx);
        const in = cx.newWith(TextInput, TextInput.init, .{input.Options{
            .key_context = "Composer",
            .single_line = true,
            .text_size = 11.5,
            .line_height = 16,
            .colors = .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
            .edge_fade = false,
        }}) catch return;
        in.update(cx, TextInput.setText, .{n.name});
        // Select the stem (zeron `name_selection`).
        const stem_end = if (n.kind == .directory) n.name.len else (if (std.mem.lastIndexOfScalar(u8, n.name, '.')) |d| (if (d > 0) d else n.name.len) else n.name.len);
        in.update(cx, TextInput.replaceRange, .{ 0, 0, "" });
        const Sel = struct {
            fn f(t: *TextInput, end: usize, c: *Context(TextInput)) void {
                t.state.selectRange(.{ .start = 0, .end = end });
                c.notify();
            }
        };
        in.update(cx, Sel.f, .{stem_end});
        const sub = cx.subscribe(in, onRenameEvent) catch return;
        self.tree.select(path);
        self.revealSelection();
        self.freeOpt(&self.mutation_error);
        self.rename = .{ .path = self.gpa.dupe(u8, path) catch return, .input = in, .sub = sub };
        window.focus(in.read(cx).focusHandle());
        cx.notify();
    }

    fn dropRename(self: *FilesPanel, app: *App) void {
        if (self.rename) |*r| {
            r.sub.deinit();
            r.input.release(app);
            self.gpa.free(r.path);
        }
        self.rename = null;
    }

    fn onRenameEvent(self: *FilesPanel, _: Entity(TextInput), ev: *const input.TextInputEvent, cx: *Context(FilesPanel)) void {
        switch (ev.*) {
            .submitted, .modified_submitted => self.submitRename(cx),
            .escape => {
                self.dropRename(cx.app);
                self.restore_tree_focus = true;
                cx.notify();
            },
            else => {},
        }
    }

    pub fn renamedPath(a: Allocator, path: []const u8, name: []const u8) ?[]const u8 {
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or std.ascii.eqlIgnoreCase(name, ".git")) return null;
        if (std.mem.indexOfAny(u8, name, "/\\\x00:") != null) return null;
        const parent = model.parentPath(path);
        if (parent.len == 0) return a.dupe(u8, name) catch null;
        return std.fmt.allocPrint(a, "{s}/{s}", .{ parent, name }) catch null;
    }

    fn submitRename(self: *FilesPanel, cx: *Context(FilesPanel)) void {
        const r = self.rename orelse return;
        const name = std.mem.trim(u8, r.input.read(cx).text(), " ");
        const n = self.tree.node(r.path) orelse return;
        if (std.mem.eql(u8, name, n.name)) {
            self.dropRename(cx.app);
            self.restore_tree_focus = true;
            cx.notify();
            return;
        }
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const dest = renamedPath(arena.allocator(), r.path, name) orelse {
            self.setOpt(&self.mutation_error, "Enter a single file name without path separators");
            cx.notify();
            return;
        };
        self.mutation_busy = true;
        self.setOpt(&self.pending_old, r.path);
        self.setOpt(&self.pending_new, dest);
        self.files.read(cx).moveEntry(cx, .{ .source = r.path, .destination = dest, .revision = n.revision orelse "", .kind = n.kind }, onMoved);
        self.dropRename(cx.app);
        self.restore_tree_focus = true;
        cx.notify();
    }

    fn onMoved(self: *FilesPanel, res: client.MutationResult, cx: *Context(FilesPanel)) void {
        defer res.deinit();
        self.mutation_busy = false;
        defer self.freeOpt(&self.pending_old);
        defer self.freeOpt(&self.pending_new);
        if (res.err) |e| {
            self.setOpt(&self.mutation_error, e);
        } else if (res.value) |v| switch (v) {
            .applied => {
                const old = self.pending_old orelse "";
                const new = self.pending_new orelse "";
                cx.emit(EntryRenamed{ .old_path = self.keep(old), .new_path = self.keep(new) });
                self.setOpt(&self.reveal_path, new);
                self.loadDirectory(model.parentPath(new), false, cx);
                if (!std.mem.eql(u8, model.parentPath(old), model.parentPath(new))) self.loadDirectory(model.parentPath(old), false, cx);
            },
            .rejected => |rj| self.setOpt(&self.mutation_error, if (rj.message.len > 0) rj.message else "Rename failed"),
        };
        cx.notify();
    }

    pub fn beginDelete(self: *FilesPanel, path: []const u8, cx: *Context(FilesPanel)) void {
        if (!self.canMutate(path, true)) return;
        const n = self.tree.node(path) orelse return;
        self.dropDelete();
        self.delete_flow = .{
            .path = self.gpa.dupe(u8, path) catch return,
            .is_dir = n.kind == .directory,
            .revision = if (n.revision) |r| self.gpa.dupe(u8, r) catch null else null,
        };
        self.focus_delete = true;
        cx.notify();
    }

    fn dropDelete(self: *FilesPanel) void {
        if (self.delete_flow) |d| {
            self.gpa.free(d.path);
            if (d.revision) |r| self.gpa.free(r);
        }
        self.delete_flow = null;
    }

    pub fn dismissDelete(self: *FilesPanel, confirm: bool, cx: *Context(FilesPanel)) void {
        const d = self.delete_flow orelse return;
        if (confirm) {
            const current = if (self.tree.node(d.path)) |n| n.revision else null;
            const same = if (current) |c| (if (d.revision) |r| std.mem.eql(u8, c, r) else false) else d.revision == null;
            if (!same) {
                self.setOpt(&self.mutation_error, "Entry changed; reopen Delete to confirm its current contents");
            } else {
                self.mutation_busy = true;
                self.setOpt(&self.pending_old, d.path);
                self.files.read(cx).deleteEntry(cx, .{ .path = d.path, .revision = d.revision orelse "", .kind = if (d.is_dir) .directory else .file, .recursive = d.is_dir }, onDeleted);
            }
        }
        self.dropDelete();
        self.restore_tree_focus = true;
        cx.notify();
    }

    fn onDeleted(self: *FilesPanel, res: client.MutationResult, cx: *Context(FilesPanel)) void {
        defer res.deinit();
        self.mutation_busy = false;
        defer self.freeOpt(&self.pending_old);
        if (res.err) |e| {
            self.setOpt(&self.mutation_error, e);
        } else if (res.value) |v| switch (v) {
            .applied => {
                const path = self.pending_old orelse "";
                cx.emit(EntryDeleted{ .path = self.keep(path) });
                const anchor = self.captureAnchor();
                _ = self.tree.remove(path);
                self.restoreAnchor(anchor);
                self.loadDirectory(model.parentPath(path), false, cx);
            },
            .rejected => |rj| self.setOpt(&self.mutation_error, if (rj.message.len > 0) rj.message else "Delete failed"),
        };
        cx.notify();
    }

    fn onDeleteCancel(self: *FilesPanel, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FilesPanel)) void {
        self.dismissDelete(false, cx);
    }
    fn onDeleteConfirm(self: *FilesPanel, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FilesPanel)) void {
        self.dismissDelete(true, cx);
    }
    fn onDeleteScrim(self: *FilesPanel, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(FilesPanel)) void {
        self.dismissDelete(false, cx);
    }
    fn onDeleteKey(self: *FilesPanel, ev: *const zpui.input.KeyDownEvent, window: *Window, cx: *Context(FilesPanel)) void {
        const key = ev.keystroke.key;
        if (std.mem.eql(u8, key, "escape")) {
            self.dismissDelete(false, cx);
        } else if (std.mem.eql(u8, key, "tab") or std.mem.eql(u8, key, "left") or std.mem.eql(u8, key, "right")) {
            if (self.delete_flow) |*d| d.confirm_focused = !d.confirm_focused;
            cx.notify();
        } else if (std.mem.eql(u8, key, "enter")) {
            self.dismissDelete(if (self.delete_flow) |d| d.confirm_focused else false, cx);
        } else return;
        window.preventDefault();
        cx.stopPropagation();
    }

    fn onDismissError(self: *FilesPanel, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FilesPanel)) void {
        self.freeOpt(&self.mutation_error);
        cx.notify();
    }

    // ---- sections ------------------------------------------------------------------

    fn onSectionToggle(self: *FilesPanel, which: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FilesPanel)) void {
        if (which == 0) self.subagents_open = !self.subagents_open else self.chats_open = !self.chats_open;
        cx.notify();
    }
    fn onFork(_: *FilesPanel, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FilesPanel)) void {
        cx.stopPropagation();
        cx.emit(ForkChat{});
    }
    fn onNewSideChat(_: *FilesPanel, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FilesPanel)) void {
        cx.stopPropagation();
        cx.emit(NewChildChat{});
    }
    fn onSubagentRow(self: *FilesPanel, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FilesPanel)) void {
        if (ix < self.subagents.items.len) cx.emit(OpenSubagent{ .doc_id = self.subagents.items[ix].id, .title = self.subagents.items[ix].title });
    }
    fn onChatRow(self: *FilesPanel, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(FilesPanel)) void {
        if (ix < self.chats.items.len) cx.emit(OpenChildChat{ .chat_id = self.chats.items[ix].id });
    }

    fn preventDefault(_: *const zpui.input.MouseDownEvent, window: *Window, _: *App) void {
        window.preventDefault();
    }

    // ---- render --------------------------------------------------------------------

    pub fn render(self: *FilesPanel, window: *Window, cx: *Context(FilesPanel)) AnyElement {
        const theme = zpui.window.arena_mod.current().create(Theme, ui.theme.get(cx).*);
        self.window_id = window.id;
        _ = self.event_arena.reset(.retain_capacity);
        if (self.restore_tree_focus) {
            self.restore_tree_focus = false;
            window.focus(self.tree_focus);
        }
        self.ensureLoaded(cx);
        if (self.focus_delete and self.delete_flow != null) {
            self.focus_delete = false;
            window.focus(self.delete_focus);
        }
        var root = div().id("files-panel").sizeFull().relative().flex().flexCol().fontFamily(theme.font_sans).textColor(theme.text)
            .child(self.renderHeader(theme, cx))
            .child(div().flex1().minH0().wFull().child(self.renderExplorer(theme, cx)));
        if (self.mutation_error) |msg| {
            root = root.child(div().id("files-mutation-error").role(.button).flexNone().mx(px(8)).mb(px(6)).px(px(10)).py(px(6)).rounded(px(7))
                .bg(theme.danger.opacity(0.08)).border1().borderColor(theme.danger.opacity(0.2)).flex().itemsCenter().gap(px(6))
                .textSize(px(11)).textColor(theme.danger_muted).cursorPointer().onClick(cx.listener(onDismissError))
                .child(ui.icon.of(.danger_triangle, 12, theme.danger_muted))
                .child(div().flex1().minW0().child(msg)));
        }
        if (self.opts.show_sections) root = root.child(self.renderSections(theme, cx));
        if (self.menu) |m| root = root.child(self.renderMenu(m, theme, cx));
        if (self.delete_flow) |d| root = root.child(self.renderDeleteDialog(d, theme, window, cx));
        return zpui.intoAnyElement(root);
    }

    fn renderHeader(self: *FilesPanel, theme: *const Theme, cx: *Context(FilesPanel)) zpui.StatefulDiv {
        const include = self.tree.include_ignored;
        const field = div().id("files-search").h(px(control_size)).minW0().flex1().px(px(8)).rounded(px(control_radius))
            .bg(theme.ink(0.035)).flex().itemsCenter().gap(px(6)).textSize(px(11.5))
            .overflowHidden().cursorText().hover(sb.bg(theme.ink(0.055)))
            .onMouseDown(.left, cx.listener(onSearchFieldDown))
            .child(ui.icon.of(.magnifer, 12, theme.text_faint))
            .child(div().minW0().flex1().overflowHidden().child(self.search));
        var eye = div().id("files-toggle-ignored").role(.button).ariaLabel(if (include) "Hide hidden and ignored files" else "Show all files (even hidden)").size(px(control_size)).flexNone().rounded(px(control_radius)).flex().itemsCenter().justifyCenter()
            .cursorPointer().occlude().onMouseDown(.left, preventDefault).hover(sb.bg(theme.wash(0.14)))
            .tooltipWith(@as([]const u8, if (include) "Hide hidden and ignored files" else "Show all files (even hidden)"), ui.tooltip.build)
            .onClick(cx.listener(onToggleIgnored))
            .child(ui.icon.of(if (include) .eye else .eye_closed, 14, if (include) theme.text else theme.text_muted));
        if (include) eye = eye.bg(theme.wash(0.1));
        return div().id("files-explorer-header").h(px(header_height)).wFull().flexNone().px(px(8)).flex().itemsCenter().gap(px(4))
            .borderT1().borderB1().borderColor(theme.border)
            .bg(if (theme.isGlass()) theme.surface.opacity(0.26) else theme.surface)
            .onKeyDown(cx.listener(onHeaderKey))
            .child(field).child(eye);
    }

    fn centeredMessage(msg: []const u8, color: Hsla) zpui.Div {
        return div().flex1().flex().itemsCenter().justifyCenter().px(px(24)).textCenter().textSize(px(11)).textColor(color).child(msg);
    }

    fn renderExplorer(self: *FilesPanel, theme: *const Theme, cx: *Context(FilesPanel)) zpui.Div {
        var col = div().sizeFull().minW0().flex().flexCol();
        if (self.opts.projectless_label) |label| {
            col = col.child(div().flexNone().px(px(10)).py(px(5)).textSize(px(10)).textColor(theme.text_faint).truncate().child(label));
        }
        if (self.query.items.len > 0) return col.child(self.renderSearchResults(theme, cx));
        if (self.root_error) |e| if (!self.tree.rootLoaded()) {
            // Keep the tree's focus target in the frame while the error replaces the tree,
            // so focusing the explorer (mod-e) doesn't strand focus outside the shell's key
            // context and swallow every shortcut.
            return col.child(div().id("files-root-error").role(.tree).ariaLabel("Workspace file tree").trackFocus(self.tree_focus).flex1().flex().flexCol().itemsCenter().justifyCenter().gap(px(10)).px(px(28))
                .child(div().textCenter().textSize(px(12)).textColor(theme.text_muted).child(e))
                .child(div().id("files-retry-root").role(.button).h(px(28)).px(px(12)).rounded(px(7)).border1().borderColor(theme.border)
                .bg(theme.wash(0.04)).hover(sb.bg(theme.wash(0.09))).cursorPointer().flex().itemsCenter()
                .textSize(px(11.5)).textColor(theme.text).child("Retry").onClick(cx.listener(retryRoot))));
        };
        if (!self.tree.rootLoaded()) return col.child(div().id("files-root-loading").role(.tree).ariaLabel("Workspace file tree").trackFocus(self.tree_focus).flex1());
        return col.child(self.renderTree(theme, cx));
    }

    fn renderTree(self: *FilesPanel, theme: *const Theme, cx: *Context(FilesPanel)) zpui.StatefulDiv {
        const n = self.tree.rows().len;
        const list = zpui.uniformList("files-tree-rows", n, cx, renderTreeRows).trackScroll(self.scroll).sizeFull();
        // `render_tree_root_target`.
        const root_active = if (self.tree_drag.destination) |d| d.len == 0 else false;
        const root_label = if (self.tree_drag.payload != null) "Move to workspace root" else "Workspace root";
        var root_row = div().id("tree-workspace-root").ariaLabel(root_label).h(px(root_row_height)).wFull().flexNone().px(px(8)).flex().itemsCenter()
            .textSize(px(10.5)).textColor(theme.text_muted).child(root_label);
        if (root_active) root_row = root_row.bg(theme.wash(0.16));
        return div().id("files-tree").role(.tree).ariaLabel("Workspace file tree").relative().flex1().minH0().flex().flexCol()
            .onDragMove(WorkspacePathDrag, cx.listener(onTreeDragMove))
            .onDrop(WorkspacePathDrag, cx.listener(onTreeDrop))
            .trackFocus(self.tree_focus)
            .onMouseDown(.left, cx.listener(onTreeMouseDown))
            .onKeyDown(cx.listener(onTreeKey))
            .child(root_row)
            .child(div().relative().flex1().minH0()
            .child(zpui.edgeFaded(tree_fade_band, true, true, list).fadeOverflowY(self.scroll))
            .child(zpui.scrollbar(self.scroll).id("files-tree-scrollbar").withStyle(compactBar(theme))));
    }

    fn compactBar(theme: *const Theme) zpui.ScrollbarStyle {
        var s = zpui.ScrollbarStyle.compact;
        s.thumb = theme.text.opacity(0.22);
        s.thumb_hover = theme.text.opacity(0.36);
        s.thumb_active = theme.text.opacity(0.46);
        return s;
    }

    fn renderTreeRows(self: *FilesPanel, range: zpui.Range, _: *Window, cx: *Context(FilesPanel)) []AnyElement {
        const a = zpui.window.arena_mod.frameAllocator();
        const theme = ui.theme.get(cx);
        const out = a.alloc(AnyElement, range.end - range.start) catch return &.{};
        for (out, range.start..) |*e, ix| e.* = self.treeRow(ix, theme, cx);
        return out;
    }

    fn withGuides(row: anytype, depth: usize, theme: *const Theme) zpui.Div {
        var d = div().relative().h(px(tree_row_height)).wFull().flexNone();
        for (0..depth) |level| {
            d = d.child(div().absolute().top(px(0)).bottom(px(0)).left(px(8 + 7 + @as(f32, @floatFromInt(level)) * tree_indent)).w(px(1)).bg(theme.border));
        }
        return d.child(row);
    }

    fn treeRow(self: *FilesPanel, ix: usize, theme: *const Theme, cx: *Context(FilesPanel)) AnyElement {
        const rows = self.tree.rows();
        if (ix >= rows.len) return zpui.empty();
        const r = rows[ix];
        const padding = 8 + @as(f32, @floatFromInt(r.depth)) * tree_indent;
        switch (r.kind) {
            .entry => {},
            .loading, .empty => {
                return zpui.intoAnyElement(withGuides(div().h(px(tree_row_height)).wFull().pl(px(padding + tree_indent)).pr(px(8)).flex().itemsCenter()
                    .textSize(px(10.5)).textColor(if (r.kind == .loading) theme.text_faint else theme.text_faint.opacity(0.7))
                    .child(if (r.kind == .loading) "Loading\u{2026}" else "Empty folder"), r.depth, theme));
            },
            .failed => {
                const msg = if (self.tree.node(r.path)) |n| (switch (n.load) {
                    .failed => |f| f.message,
                    else => "Error",
                }) else "Error";
                return zpui.intoAnyElement(withGuides(div().id(.{ "files-tree-error", ix }).role(.button).h(px(tree_row_height)).wFull().pl(px(padding + tree_indent)).pr(px(8))
                    .flex().itemsCenter().gap(px(6)).cursorPointer().hover(sb.bg(theme.wash(0.055)))
                    .onClick(cx.listenerWith(ix, onRowClick))
                    .child(div().minW0().truncate().whitespaceNowrap().textSize(px(10.5)).textColor(theme.danger.opacity(0.82)).child(zpui.fmt("{s} \u{2014} Retry", .{msg}))), r.depth, theme));
            },
            .load_more => {
                return zpui.intoAnyElement(withGuides(div().id(.{ "files-tree-more", ix }).role(.button).h(px(tree_row_height)).wFull().pl(px(padding + tree_indent)).pr(px(8))
                    .flex().itemsCenter().cursorPointer().hover(sb.bg(theme.wash(0.055)))
                    .onClick(cx.listenerWith(ix, onRowClick))
                    .child(div().textSize(px(10.5)).textColor(theme.text_muted).child("Load more\u{2026}")), r.depth, theme));
            },
        }
        const n = self.tree.node(r.path) orelse return zpui.empty();
        const selected = if (self.tree.selected) |s| std.mem.eql(u8, s, n.path) else false;
        const is_dir = n.kind == .directory;
        const expanded = is_dir and self.tree.isExpanded(n.path);
        const decoration = self.decorations.get(n.path, is_dir);
        const text_color = if (decoration) |d| d.color(theme) else if (selected) theme.text else theme.text_muted;
        const focused = if (cx.app.windowById(self.window_id)) |w| self.tree_focus.isFocused(w) else false;
        var row = div().id(.{ "files-tree-entry", ix }).role(.tree_item).ariaLabel(std.fs.path.basename(n.path)).ariaSelected(selected)
            .h(px(tree_row_height)).wFull().flexNone().pl(px(padding)).pr(px(8))
            .flex().itemsCenter().gap(px(4)).cursorPointer()
            .onClick(cx.listenerWith(ix, onRowClick))
            .onMouseDown(.right, cx.listenerWith(ix, onRowRightDown));
        if (is_dir) row = row.ariaExpanded(expanded);
        if (is_dir and self.dropHighlighted(n.path)) row = row.bg(theme.wash(0.18));
        if (n.ignored and decoration == null) row = row.opacity(0.52);
        row = if (selected) row.bg(theme.wash(if (focused) 0.12 else 0.08)) else row.hover(sb.bg(theme.wash(0.055)));
        var disclosure = div().size(px(14)).flexNone().flex().itemsCenter().justifyCenter();
        if (is_dir) disclosure = disclosure.child(ui.icon.of(if (expanded) .alt_arrow_down else .alt_arrow_right, 11, theme.text_faint));
        row = row.child(disclosure)
            .child(icons.entryIcon(switch (n.kind) {
            .directory => .directory,
            .file => .file,
            .symlink => .symlink,
        }, n.name, theme, 14));
        const renaming = if (self.rename) |rn| std.mem.eql(u8, rn.path, n.path) else false;
        if (!renaming) if (self.dragPayload(.tree, n.path, is_dir, n.revision)) |payload| {
            row = row.onDrag(payload, drag_mod.buildGhost);
        };
        if (renaming) {
            row = row.child(div().id("files-tree-rename").flex1().minW0().h(px(22)).px(px(6)).rounded(px(5)).border1().borderColor(theme.accent)
                .bg(theme.inputGlassBg()).flex().itemsCenter().textSize(px(11.5)).textColor(theme.text).cursorText().occlude()
                .child(self.rename.?.input));
        } else {
            row = row.child(div().minW0().truncate().whitespaceNowrap().fontFamily(theme.font_sans).textSize(px(11.5)).textColor(text_color).child(n.name));
        }
        return zpui.intoAnyElement(withGuides(row, r.depth, theme));
    }

    fn renderSearchResults(self: *FilesPanel, theme: *const Theme, cx: *Context(FilesPanel)) zpui.Div {
        if (self.search_error) |e| return centeredMessage(e, theme.danger.opacity(0.82));
        const rows = self.search_tree.rows.items;
        if (rows.len == 0) return centeredMessage(if (self.search_loading) "Searching\u{2026}" else "No files found.", theme.text_faint);
        var col = div().flex1().minH0().flex().flexCol();
        if ((self.results orelse client.SearchResult{}).value) |v| if (v.len >= proto.max_search_results) {
            col = col.child(div().h(px(24)).flexNone().px(px(10)).flex().itemsCenter().textSize(px(10)).textColor(theme.text_faint).child("Showing the first 200 matches"));
        };
        const list = zpui.uniformList("files-search-rows", rows.len, cx, renderSearchRows).trackScroll(self.search_scroll).sizeFull();
        return col.child(div().id("files-search-results").role(.tree).ariaLabel("Fuzzy workspace file results").relative().flex1().minH0().child(list)
            .child(zpui.scrollbar(self.search_scroll).id("files-search-scrollbar").withStyle(compactBar(theme))));
    }

    fn renderSearchRows(self: *FilesPanel, range: zpui.Range, _: *Window, cx: *Context(FilesPanel)) []AnyElement {
        const a = zpui.window.arena_mod.frameAllocator();
        const theme = ui.theme.get(cx);
        const out = a.alloc(AnyElement, range.end - range.start) catch return &.{};
        for (out, range.start..) |*e, ix| e.* = self.searchRow(ix, theme, cx);
        return out;
    }

    fn searchRow(self: *FilesPanel, ix: usize, theme: *const Theme, cx: *Context(FilesPanel)) AnyElement {
        const rows = self.search_tree.rows.items;
        if (ix >= rows.len) return zpui.empty();
        const r = rows[ix];
        const selected = self.search_active == ix;
        const is_dir = r.kind == .directory;
        const expanded = r.has_children and self.search_tree.isExpanded(r.path);
        const decoration = self.decorations.get(r.path, is_dir);
        const padding = 8 + @as(f32, @floatFromInt(r.depth)) * tree_indent;
        var row = div().id(.{ "files-search-result", ix }).role(.tree_item).ariaLabel(r.name).ariaSelected(selected).h(px(tree_row_height)).wFull().flexNone().pl(px(padding)).pr(px(8))
            .flex().itemsCenter().gap(px(4)).cursorPointer().onClick(cx.listenerWith(ix, onSearchRowClick));
        if (self.dragPayload(.search, r.path, is_dir, null)) |payload| row = row.onDrag(payload, drag_mod.buildGhost);
        row = if (selected) row.bg(theme.wash(0.1)) else row.hover(sb.bg(theme.wash(0.055)));
        if (r.has_children) row = row.ariaExpanded(expanded);
        var disclosure = div().size(px(14)).flexNone().flex().itemsCenter().justifyCenter();
        if (r.has_children) disclosure = disclosure.child(ui.icon.of(if (expanded) .alt_arrow_down else .alt_arrow_right, 11, theme.text_faint));
        const color = if (decoration) |d| d.color(theme) else if (is_dir) theme.text_muted else theme.text;
        row = row.child(disclosure)
            .child(icons.entryIcon(if (is_dir) .directory else .file, r.name, theme, 14))
            .child(div().minW0().truncate().whitespaceNowrap().fontFamily(theme.font_sans).textSize(px(11.5)).textColor(color).child(r.name));
        return zpui.intoAnyElement(withGuides(row, r.depth, theme));
    }

    fn renderMenu(self: *FilesPanel, m: ContextMenu, theme_in: *const Theme, cx: *Context(FilesPanel)) AnyElement {
        const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
        const entries = [_]struct { []const u8, ui.icon.Icon }{
            .{ "Add to chat", .chat_round_line },
            .{ "Copy path", .copy },
            .{ "Rename\u{2026}", .pen },
            .{ "Delete\u{2026}", .trash_bin_minimalistic },
        };
        var card = ui.popover.card(theme).w(px(190)).onMouseDownOut(cx.listener(onMenuOutside));
        for (entries, 0..) |e, i| {
            if (i == 2) card = card.child(ui.popover.separator(theme));
            const enabled = i < 2 or self.canMutate(m.path, i == 3);
            const danger = i == 3;
            var row = ui.popover.menuRow(theme, false).id(.{ "tree-menu", i }).role(.menu_item)
                .child(ui.icon.of(e[1], 16, if (danger) theme.danger else theme.text_muted))
                .child(e[0]);
            if (danger) row = row.textColor(theme.danger);
            row = if (enabled) row.onClick(cx.listenerWith(i, onMenuRow)) else row.opacity(0.38);
            card = card.child(row);
        }
        return ui.popover.anchoredAt(m.position, card);
    }

    fn renderDeleteDialog(self: *FilesPanel, d: DeleteFlow, theme_in: *const Theme, window: *Window, cx: *Context(FilesPanel)) AnyElement {
        const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
        const name = model.baseName(d.path);
        const copy = zpui.fmt("Permanently delete {s}? {s}Open editor buffers will be kept for recovery.", .{
            name,
            if (d.is_dir) "All current folder contents will be deleted. " else "This cannot be undone. ",
        });
        var cancel = dialog.btnGhost(theme, "Cancel").id("tree-delete-cancel").role(.button).onClick(cx.listener(onDeleteCancel));
        if (!d.confirm_focused) cancel = cancel.bg(theme.wash(0.12));
        var confirm = dialog.btnDanger(theme, "Delete").id("tree-delete-confirm").role(.button).onClick(cx.listener(onDeleteConfirm));
        if (d.confirm_focused) confirm = confirm.border1().borderColor(theme.text);
        const card = dialog.card(theme).w(px(380)).gap(px(12))
            .child(dialog.title(theme, "Delete permanently?"))
            .child(dialog.body(theme, copy))
            .child(div().flex().justifyEnd().gap(px(8)).child(cancel).child(confirm));
        return dialog.modal(window, div().trackFocus(self.delete_focus).onKeyDown(cx.listener(onDeleteKey)).child(card), cx.listener(onDeleteScrim));
    }

    // Sections footer -------------------------------------------------------------------

    fn sectionWant(kind: SectionKind, count: usize) f32 {
        const raw: f32 = if (count == 0)
            section_body_inset + empty_pad * 2 + empty_copy_height + (if (kind == .chats) empty_actions_height else 0)
        else
            section_body_inset + @as(f32, @floatFromInt(count)) * section_row_height + @as(f32, @floatFromInt(count -| 1)) * section_row_gap;
        return @max(raw, min_body_height);
    }

    pub fn bodyBudget(budget_in: f32, wants: [2]f32, open: [2]bool) [2]f32 {
        const budget = @max(budget_in, 0);
        const a = if (open[0]) wants[0] else 0;
        const b = if (open[1]) wants[1] else 0;
        if (a + b <= budget) return .{ a, b };
        const half = budget / 2;
        const first = @min(a, budget - @min(b, half));
        return .{ first, @min(b, budget - first) };
    }

    fn renderSections(self: *FilesPanel, theme: *const Theme, cx: *Context(FilesPanel)) zpui.StatefulDiv {
        const wants = [2]f32{ sectionWant(.subagents, self.subagents.items.len), sectionWant(.chats, self.chats.items.len) };
        const heights = bodyBudget(footer_height - (footer_pad_top + footer_pad_bottom + 2 * section_header_height), wants, .{ self.subagents_open, self.chats_open });
        return div().id("files-sections").relative().flexNone().wFull().flex().flexCol().px(px(6)).pt(px(footer_pad_top)).pb(px(footer_pad_bottom))
            .child(self.renderSection(.subagents, heights[0], theme, cx))
            .child(self.renderSection(.chats, heights[1], theme, cx));
    }

    fn renderSection(self: *FilesPanel, kind: SectionKind, height: f32, theme: *const Theme, cx: *Context(FilesPanel)) zpui.Div {
        const open = if (kind == .subagents) self.subagents_open else self.chats_open;
        const rows = if (kind == .subagents) self.subagents.items else self.chats.items;
        const label_base = if (kind == .subagents) "Subagents" else "Chats";
        const label = if (open or rows.len == 0) label_base else zpui.fmt("{s} ({d})", .{ label_base, rows.len });
        const group = if (kind == .subagents) "files-section-header-subagents" else "files-section-header-chats";
        var header = div().id(.{ "files-section", @intFromEnum(kind) }).role(.button).ariaLabel(zpui.fmt("{s} {s}", .{ if (open) "Collapse" else "Expand", label_base })).group(group).flexNone().flex().flexRow().itemsCenter().gap(px(6))
            .h(px(section_header_height)).pl(px(8)).pr(px(4)).rounded(px(6)).cursorPointer()
            .onClick(cx.listenerWith(@as(usize, @intFromEnum(kind)), onSectionToggle))
            .child(div().flex1().minW0().truncate().whitespaceNowrap().textSize(ui.rems(12)).fontWeight(500).textColor(theme.text_muted.opacity(0.5)).child(label));
        if (kind == .chats) {
            header = header.child(div().flexNone().flex().flexRow().itemsCenter().gap(px(2)).opacity(0).groupHover(group, sb.opacity(1))
                .child(headerAction("files-sections-new-chat", .plus, "New side chat", theme).onClick(cx.listener(onNewSideChat)))
                .child(headerAction("files-sections-fork", .git_branch, "Fork this chat", theme).onClick(cx.listener(onFork))));
        }
        header = header.child(div().flexNone().size(px(20)).flex().itemsCenter().justifyCenter()
            .child(ui.icon.of(if (open) .alt_arrow_down else .alt_arrow_right, 12, theme.text_muted.opacity(0.5))));
        var body = div().wFull().flexNone().overflowHidden().h(px(if (open) height else 0));
        if (open) body = body.child(self.sectionBody(kind, rows, theme, cx));
        return div().flexNone().flex().flexCol().child(header).child(body);
    }

    fn headerAction(id: []const u8, i: ui.icon.Icon, label: []const u8, theme: *const Theme) zpui.StatefulDiv {
        return div().id(id).role(.button).ariaLabel(label).flexNone().size(px(20)).rounded(px(5)).flex().itemsCenter().justifyCenter().cursorPointer()
            .hover(sb.bg(theme.wash(0.09))).onMouseDown(.left, preventDefault)
            .tooltipWith(label, ui.tooltip.build)
            .child(ui.icon.of(i, 13, theme.text_muted.opacity(0.85)));
    }

    fn pillButton(id: []const u8, i: ui.icon.Icon, label: []const u8, theme: *const Theme) zpui.StatefulDiv {
        return div().id(id).role(.button).ariaLabel(label).h(px(26)).px(px(10)).rounded(px(7)).border1().borderColor(theme.border).bg(theme.wash(0.04))
            .hover(sb.bg(theme.wash(0.09))).cursorPointer().flex().flexRow().itemsCenter().gap(px(5))
            .textSize(px(11.5)).textColor(theme.text).onMouseDown(.left, preventDefault)
            .child(ui.icon.of(i, 12, theme.text_muted)).child(label);
    }

    fn sectionBody(_: *FilesPanel, kind: SectionKind, rows: []const SectionRow, theme: *const Theme, cx: *Context(FilesPanel)) zpui.Div {
        if (rows.len == 0) {
            var empty = div().pt(px(section_body_inset + empty_pad)).pb(px(empty_pad)).px(px(8)).flex().flexCol()
                .child(div().minH(px(empty_copy_height)).maxH(px(empty_copy_height)).overflowHidden().py(px(2))
                .textSize(ui.rems(12)).lineHeight(px(16)).textColor(theme.text_muted.opacity(0.5))
                .child(if (kind == .subagents) "Subagents will appear here when they are created" else "Side chats will appear here when they are created"));
            if (kind == .chats) empty = empty.child(div().flex().flexRow().itemsCenter().gap(px(6)).h(px(empty_actions_height))
                .child(pillButton("files-sections-empty-fork", .git_branch, "Fork", theme).onClick(cx.listener(onFork)))
                .child(pillButton("files-sections-empty-new", .plus, "New side chat", theme).onClick(cx.listener(onNewSideChat))));
            return empty;
        }
        var list = div().id(.{ "files-section-rows", @intFromEnum(kind) }).sizeFull().flex().flexCol().gap(px(section_row_gap)).pt(px(section_body_inset)).overflowYScroll();
        for (rows, 0..) |r, i| {
            var row = div().id(.{ "files-section-row", @as(usize, @intFromEnum(kind)) * 100000 + i }).role(.button)
                .ariaLabel(zpui.fmt("{s} {s}", .{ if (kind == .subagents) "Open subagent" else "Open side chat", r.title })).flexNone().h(px(section_row_height)).flex().flexRow().itemsCenter().gap(px(4))
                .rounded(px(8)).px(px(8)).cursorPointer().textColor(theme.text.opacity(0.8))
                .hover(sb.bg(theme.glassHover()).textColor(theme.text));
            row = if (kind == .subagents) row.onClick(cx.listenerWith(i, onSubagentRow)) else row.onClick(cx.listenerWith(i, onChatRow));
            list = list.child(row
                .child(statusGlyph(r.status, theme))
                .child(div().flex1().minW0().truncate().whitespaceNowrap().textSize(ui.rems(13)).lineHeight(px(17)).child(r.title))
                .child(div().flexNone().textSize(ui.rems(11)).textColor(theme.text_muted.opacity(0.5)).child(r.time_ago)));
        }
        return div().relative().sizeFull().child(list);
    }

    fn statusGlyph(status: RowStatus, theme: *const Theme) zpui.Div {
        const slot = div().flexNone().size(px(13)).flex().itemsCenter().justifyCenter();
        return switch (status) {
            .completed => slot.child(ui.icon.of(.check, 11, theme.success)),
            .working => slot.child(div().size(px(6)).roundedFull().bg(theme.busy)),
            .failed => slot.child(div().size(px(6)).roundedFull().bg(theme.danger)),
            .attention => slot.child(div().size(px(6)).roundedFull().bg(theme.warning)),
            .idle => slot.child(div().size(px(6)).roundedFull().bg(theme.text_faint)),
        };
    }
};
