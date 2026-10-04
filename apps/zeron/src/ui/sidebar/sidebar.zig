//! The chat sidebar (zeron `shell.rs::render_chat_sidebar`, `render_chat_row`,
//! `shell/spaces.rs` filter + disclosure sections, `render_user_menu`).
//!
//! ```zig
//! const sidebar = try cx.newWith(Sidebar, Sidebar.init, .{app_state});
//! div().child(sidebar)            // the shell gives it width + pads it below the titlebar
//! // events: Sidebar.OpenSettings, Sidebar.NewSession
//! ```
//!
//! Layout (dark, 1x): filter row (29px trigger) → scrolling list with a 24px
//! edge fade (Pinned / Sessions / Archived disclosures, 28px headers, rows
//! 45/61/63px detailed or 29px compact, 2px gaps) → footer (28px account
//! pill + settings button). Rows select through `WorkspaceStore.selectChat`.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const prefs_mod = @import("../shell/prefs.zig");

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const rems = ui.rems;
const Theme = ui.Theme;
const icon = ui.icon;
const view = model.view;
const Timestamp = model.time.Timestamp;
const Chat = engine.protocol.Chat;
const ChatIndicator = view.ChatIndicator;

pub const OpenSettings = struct {};
pub const NewSession = struct {};
pub const SignOut = struct {};

const list_gap: f32 = 2;
const section_gap: f32 = 12;
const disclosure_header_height: f32 = 28;
const disclosure_body_inset: f32 = 4;
const harness_icon_size: f32 = 13;
const footer_button_size: f32 = 28;
const footer_avatar_size: f32 = 16;
const fade_band: f32 = 24;
const archived_initial_rows: usize = 10;
const row_group = "sidebar-session-row";

pub fn chatRowHeight(branch: bool, pr: bool) f32 {
    var meta: f32 = 0;
    if (branch) meta = @max(meta, 14);
    if (pr) meta = @max(meta, 16);
    return if (meta == 0) 45 else 47 + meta;
}

pub fn rowHeight(compact: bool, show_label: bool, branch: bool, pr: bool) f32 {
    if (compact) return 29;
    return chatRowHeight(branch, pr) - (if (show_label) @as(f32, 0) else 16);
}

/// `status_dot_color`.
pub fn statusColor(status: ChatIndicator, theme: *const Theme) zpui.Hsla {
    return switch (status) {
        .working => theme.busy.opacity(0.55),
        .awaitingInput => theme.accent.opacity(0.6),
        .errored => theme.danger.opacity(0.65),
        .completed => theme.success.opacity(0.9),
        .idle => theme.ink(0.14),
    };
}

fn statusLabel(status: ChatIndicator) ?[]const u8 {
    return switch (status) {
        .working => "Working",
        .awaitingInput => "Input",
        .errored => "Failed",
        .completed => "Done",
        .idle => null,
    };
}

/// One rendered row's data (strings borrow the workspace frame / frame arena).
const RowData = struct {
    chat: *const Chat,
    status: ChatIndicator,
    title: []const u8,
    folder: []const u8,
    project_name: []const u8,
    project_seed: []const u8,
    branch: ?[]const u8,
    pr: ?u64,
    time_ago: []const u8,
    remote: bool,
    selected: bool,
    archived: bool,
};

pub const Sidebar = struct {
    gpa: std.mem.Allocator,
    state: Entity(model.AppState),
    scroll: zpui.ScrollHandle,
    subs: zpui.Subscriptions = .{},

    pinned_open: bool = true,
    sessions_open: bool = true,
    archived_open: bool = false,
    archived_shown: usize = archived_initial_rows,
    user_menu_open: bool = false,
    spaces_menu_open: bool = false,
    view_menu_open: bool = false,
    /// Right-click menu over a row: (row index, window position).
    ctx_menu: ?struct { ix: usize, pos: zpui.Point(f32) } = null,
    /// Open child of the view menu (0 Organize, 1 Sort, 2 Show).
    view_submenu: ?u8 = null,
    /// Row under the pointer (index into `row_ids`).
    hovered: ?usize = null,
    /// Chat ids of the rows rendered last frame (owned), for listeners.
    row_ids: std.ArrayList([]u8) = .empty,
    /// Group keys rendered last frame / collapsed group keys (owned).
    group_keys: std.ArrayList([]u8) = .empty,
    collapsed_groups: std.ArrayList([]u8) = .empty,
    /// Space ids listed in the open spaces menu (owned).
    menu_space_ids: std.ArrayList([]u8) = .empty,

    pub const Events = .{ OpenSettings, NewSession, SignOut };

    pub fn init(state: Entity(model.AppState), cx: *Context(Sidebar)) !Sidebar {
        var self: Sidebar = .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .scroll = zpui.ScrollHandle.init(cx.gpa()),
        };
        const s = state.read(cx);
        try self.subs.add(cx.gpa(), try cx.observe(s.workspace, onModelChanged));
        try self.subs.add(cx.gpa(), try cx.observe(s.auth, onModelChanged));
        try self.subs.add(cx.gpa(), try cx.observe(s.updates, onModelChanged));
        return self;
    }

    pub fn deinit(self: *Sidebar, app: *App) void {
        self.subs.deinit(self.gpa);
        self.scroll.release();
        self.clearIds(&self.row_ids);
        self.row_ids.deinit(self.gpa);
        self.clearIds(&self.menu_space_ids);
        self.menu_space_ids.deinit(self.gpa);
        self.clearIds(&self.group_keys);
        self.group_keys.deinit(self.gpa);
        self.clearIds(&self.collapsed_groups);
        self.collapsed_groups.deinit(self.gpa);
        self.state.release(app);
    }

    fn clearIds(self: *Sidebar, list: *std.ArrayList([]u8)) void {
        for (list.items) |s| self.gpa.free(s);
        list.clearRetainingCapacity();
    }

    fn onModelChanged(_: *Sidebar, _: anytype, cx: *Context(Sidebar)) void {
        cx.notify();
    }

    fn rowId(self: *Sidebar, ix: usize) ?[]const u8 {
        return if (ix < self.row_ids.items.len) self.row_ids.items[ix] else null;
    }

    // ---- listeners --------------------------------------------------------------------

    fn onRowClick(self: *Sidebar, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        const id = self.rowId(ix) orelse return;
        const copy = self.gpa.dupe(u8, id) catch return;
        defer self.gpa.free(copy);
        const ws = self.state.read(cx).workspace;
        ws.update(cx, model.WorkspaceStore.selectChat, .{copy});
    }

    fn onRowHover(self: *Sidebar, ix: usize, hovered: *const bool, _: *Window, cx: *Context(Sidebar)) void {
        if (self.rowId(ix)) |id| {
            var buf: [160]u8 = undefined;
            ui.hover.set(cx, std.fmt.bufPrint(&buf, "sidebar-row-{s}", .{id}) catch id, hovered.*);
        }
        if (hovered.*) {
            if (self.hovered != ix) {
                self.hovered = ix;
                cx.notify();
            }
        } else if (self.hovered == ix) {
            self.hovered = null;
            cx.notify();
        }
    }

    fn onRowContext(self: *Sidebar, ix: usize, ev: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.ctx_menu = .{ .ix = ix, .pos = ev.position };
        cx.notify();
    }

    fn onCtxPin(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        const m = self.ctx_menu orelse return;
        self.ctx_menu = null;
        const id = self.rowId(m.ix) orelse return;
        const p = prefs_mod.mut(cx);
        p.setPinned(id, !p.isPinned(id));
        cx.notify();
    }

    fn onCtxArchive(self: *Sidebar, e: *const zpui.ClickEvent, w: *Window, cx: *Context(Sidebar)) void {
        const m = self.ctx_menu orelse return;
        self.ctx_menu = null;
        self.onArchiveClick(m.ix, e, w, cx);
    }

    fn onCtxDismiss(self: *Sidebar, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(Sidebar)) void {
        if (self.ctx_menu != null) {
            self.ctx_menu = null;
            cx.notify();
        }
    }

    fn onCtxNoop(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.ctx_menu = null;
        cx.notify();
    }

    fn renderContextMenu(self: *Sidebar, theme_in: *const Theme, cx: *Context(Sidebar)) ?zpui.AnyElement {
        const m = self.ctx_menu orelse return null;
        const id = self.rowId(m.ix) orelse return null;
        const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
        const pinned = prefs_mod.get(cx).isPinned(id);
        const card = ui.popover.card(theme).w(px(216)).onMouseDownOut(cx.listener(Sidebar.onCtxDismiss))
            .child(ui.popover.menuRow(theme, false).id("chat-menu-rename").onClick(cx.listener(Sidebar.onCtxNoop))
                .child(icon.of(.pen, 16, theme.text_muted)).child("Rename"))
            .child(ui.popover.menuRow(theme, false).id("chat-menu-pin").onClick(cx.listener(Sidebar.onCtxPin))
                .child(icon.of(.pin, 16, theme.text_muted)).child(if (pinned) "Unpin" else "Pin"))
            .child(ui.popover.menuRow(theme, false).id("chat-menu-archive").onClick(cx.listener(Sidebar.onCtxArchive))
                .child(icon.of(.archive_minimalistic, 16, theme.text_muted)).child("Archive"))
            .child(ui.popover.menuRow(theme, false).id("chat-menu-copy").onClick(cx.listener(Sidebar.onCtxNoop))
                .child(icon.of(.copy, 16, theme.text_muted)).child(div().flex1().child("Copy"))
                .child(icon.of(.alt_arrow_right, 12, theme.text_muted)))
            .child(ui.popover.separator(theme))
            .child(ui.popover.menuRow(theme, false).id("chat-menu-delete").onClick(cx.listener(Sidebar.onCtxNoop))
                .child(icon.of(.trash_bin_minimalistic, 16, theme.text_muted)).child("Delete…"));
        return ui.popover.anchoredAt(m.pos, card);
    }

    fn onArchiveClick(self: *Sidebar, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        cx.stopPropagation();
        const id = self.rowId(ix) orelse return;
        const s = self.state.read(cx);
        const ws = s.workspace.read(cx);
        const c = ws.chat(id) orelse return;
        const archived = !c.archived;
        s.workspace.update(cx, struct {
            fn f(w: *model.WorkspaceStore, chat_id: []const u8, value: bool, c2: *Context(model.WorkspaceStore)) void {
                if (w.chatsArena() == null) return;
                for (w.chats()) |*ch| if (std.mem.eql(u8, ch.id, chat_id)) {
                    @constCast(ch).archived = value;
                };
                w.mutate(.{ .setChatArchived = .{ .chatId = chat_id, .archived = value } }, c2) catch {};
                c2.emit(model.workspace.ChatsChanged{});
                c2.notify();
            }
        }.f, .{ id, archived });
        self.hovered = null;
        cx.notify();
    }

    fn toggleSection(self: *Sidebar, which: u8, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        switch (which) {
            0 => self.pinned_open = !self.pinned_open,
            1 => self.sessions_open = !self.sessions_open,
            else => {
                self.archived_open = !self.archived_open;
                self.archived_shown = archived_initial_rows;
            },
        }
        cx.notify();
    }

    fn onShowMoreArchived(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.archived_shown += 25;
        cx.notify();
    }

    fn onUserMenu(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.user_menu_open = !self.user_menu_open;
        cx.notify();
    }

    fn onCloseMenus(self: *Sidebar, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(Sidebar)) void {
        if (self.user_menu_open or self.spaces_menu_open or self.view_menu_open) {
            self.user_menu_open = false;
            self.spaces_menu_open = false;
            self.view_menu_open = false;
            cx.notify();
        }
    }

    fn onSettings(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.user_menu_open = false;
        cx.emit(OpenSettings{});
        cx.notify();
    }

    fn onSignOut(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.user_menu_open = false;
        cx.emit(SignOut{});
        cx.notify();
    }

    fn onSpacesTrigger(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.spaces_menu_open = !self.spaces_menu_open;
        self.view_menu_open = false;
        cx.notify();
    }

    fn onViewTrigger(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.view_menu_open = !self.view_menu_open;
        self.view_submenu = null;
        self.spaces_menu_open = false;
        cx.notify();
    }

    fn onPickSpace(self: *Sidebar, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        const p = prefs_mod.mut(cx);
        if (ix == std.math.maxInt(usize)) p.setFilter(null) else if (ix < self.menu_space_ids.items.len) p.setFilter(self.menu_space_ids.items[ix]);
        self.spaces_menu_open = false;
        cx.notify();
    }

    fn onNewProject(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.spaces_menu_open = false;
        cx.emit(NewSession{});
        cx.notify();
    }

    fn onToggleView(self: *Sidebar, which: u8, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        const p = prefs_mod.mut(cx);
        switch (which) {
            0 => p.organization = .by_device,
            1 => p.organization = .by_project,
            2 => p.organization = .in_one_list,
            3 => p.sort = .last_updated,
            4 => p.sort = .created,
            5 => p.show_branch = !p.show_branch,
            6 => p.show_pull_request = !p.show_pull_request,
            7 => p.show_harness = !p.show_harness,
            8 => p.show_project_icon = !p.show_project_icon,
            9 => p.show_project_label = !p.show_project_label,
            10 => p.sidebar_compact = !p.sidebar_compact,
            else => {},
        }
        // Radio choices close the child; toggles stay open.
        if (which <= 4) self.view_submenu = null;
        cx.notify();
    }

    fn onViewGroupHover(self: *Sidebar, group: u8, hovered: *const bool, _: *Window, cx: *Context(Sidebar)) void {
        if (hovered.* and self.view_submenu != group) {
            self.view_submenu = if (group < 3) group else null;
            cx.notify();
        }
    }

    // ---- data -----------------------------------------------------------------------

    fn buildRow(
        self: *Sidebar,
        ws: *const model.WorkspaceStore,
        c: *const Chat,
        status: ChatIndicator,
        now: Timestamp,
        prefs: *const prefs_mod.Prefs,
        selected_id: ?[]const u8,
    ) RowData {
        _ = self;
        const space = ws.spaceForChat(c);
        const project: []const u8 = if (space) |s| view.spaceDisplayName(s) else if (c.spaceId == null) "~" else "?";
        const dev_name = ws.deviceName(c.deviceId);
        const folder = if (dev_name) |d| zpui.fmt("{s} @ {s}", .{ project, d }) else project;
        const branch: ?[]const u8 = blk: {
            if (!prefs.show_branch) break :blk null;
            const sc = c.sourceContext orelse break :blk null;
            const b = std.mem.trim(u8, sc.branch, " \t");
            break :blk if (b.len > 0) b else null;
        };
        const title_raw = c.title orelse "New session";
        const title = view.singleLine(zpui.window.arena_mod.frameAllocator(), title_raw) catch title_raw;
        const then = model.time.parseOpt(c.lastMessageAt) orelse model.time.parseOpt(c.createdAt) orelse now;
        var buf: [16]u8 = undefined;
        const ago = zpui.fmt("{s}", .{view.formatTimeAgo(&buf, then, now)});
        const remote = if (ws.local_device_id) |l| !std.mem.eql(u8, l, c.deviceId) else false;
        return .{
            .chat = c,
            .status = status,
            .title = title,
            .folder = folder,
            .project_name = if (space) |s| view.spaceDisplayName(s) else "Home",
            .project_seed = if (space) |s| s.path else "home",
            .branch = branch,
            .pr = if (prefs.show_pull_request) prefs.pullRequest(c.id) else null,
            .time_ago = ago,
            .remote = remote,
            .selected = if (selected_id) |s| std.mem.eql(u8, s, c.id) else false,
            .archived = c.archived,
        };
    }

    fn lessThan(sort: prefs_mod.Sort, a: *const Chat, b: *const Chat) bool {
        const ka = switch (sort) {
            .created => a.createdAt,
            .last_updated => a.lastMessageAt orelse a.createdAt,
        };
        const kb = switch (sort) {
            .created => b.createdAt,
            .last_updated => b.lastMessageAt orelse b.createdAt,
        };
        const o = std.mem.order(u8, kb, ka);
        if (o != .eq) return o == .lt;
        return std.mem.order(u8, a.id, b.id) == .lt;
    }

    // ---- render ---------------------------------------------------------------------

    pub fn render(self: *Sidebar, window: *Window, cx: *Context(Sidebar)) zpui.Div {
        const theme = ui.theme.get(cx);
        const prefs = prefs_mod.get(cx);
        const app_state = self.state.read(cx);
        const ws = app_state.workspace.read(cx);
        const now = prefs.now(ws.io);
        const arena = zpui.window.arena_mod.frameAllocator();

        self.clearIds(&self.row_ids);

        // Active rows: sidebar order, pinned first.
        const active: []view.ActiveRow = ws.sidebarChats(arena, now, prefs.space_filter) catch arena.alloc(view.ActiveRow, 0) catch unreachable;
        std.sort.block(view.ActiveRow, active, prefs.sort, struct {
            fn lt(sort: prefs_mod.Sort, a: view.ActiveRow, b: view.ActiveRow) bool {
                return lessThan(sort, a.chat, b.chat);
            }
        }.lt);
        var pinned: std.ArrayList(RowData) = .empty;
        var regular: std.ArrayList(RowData) = .empty;
        for (active) |r| {
            const d = self.buildRow(ws, r.chat, r.status, now, prefs, ws.selected_chat);
            if (prefs.isPinned(r.chat.id)) pinned.append(arena, d) catch {} else regular.append(arena, d) catch {};
        }
        std.sort.block(RowData, pinned.items, prefs, struct {
            fn lt(p: *const prefs_mod.Prefs, a: RowData, b: RowData) bool {
                return (p.pinIndex(a.chat.id) orelse 0) < (p.pinIndex(b.chat.id) orelse 0);
            }
        }.lt);

        // Archived shelf.
        var archived: std.ArrayList(RowData) = .empty;
        for (ws.chats()) |*c| {
            if (!c.archived or c.parentChatId != null) continue;
            if (prefs.space_filter) |f| if (!std.mem.eql(u8, c.spaceId orelse "", f)) continue;
            archived.append(arena, self.buildRow(ws, c, ws.displayStatusFor(c, now), now, prefs, ws.selected_chat)) catch {};
        }
        std.sort.block(RowData, archived.items, prefs.sort, struct {
            fn lt(sort: prefs_mod.Sort, a: RowData, b: RowData) bool {
                return lessThan(sort, a.chat, b.chat);
            }
        }.lt);

        var any_working = false;
        var list = div().flex().flexCol().gap(px(list_gap)).pb(px(zt.layout.space_sm));
        const show_pinned = pinned.items.len > 0;
        if (pinned.items.len + regular.items.len == 0) {
            list = div().px(px(8)).pb(px(8)).textSize(rems(12)).textColor(theme.text_faint).child("No sessions yet");
        } else {
            if (show_pinned) {
                var body = div().flex().flexCol().gap(px(list_gap)).pt(px(disclosure_body_inset));
                for (pinned.items) |*r| {
                    any_working = any_working or r.status == .working;
                    body = body.child(self.renderRow(r, theme, prefs, cx));
                }
                list = list.child(div().flex().flexCol()
                    .child(self.sectionHeader(0, if (self.pinned_open) "Pinned" else zpui.fmt("Pinned ({d})", .{pinned.items.len}), self.pinned_open, theme, cx))
                    .child(if (self.pinned_open) body else null));
            }
            if (regular.items.len > 0 and prefs.organization != .in_one_list) {
                list = list.child(self.renderGroups(regular.items, show_pinned, ws, theme, prefs, cx, &any_working));
            } else if (regular.items.len > 0) {
                var body = div().flex().flexCol().gap(px(list_gap)).pt(px(disclosure_body_inset));
                for (regular.items) |*r| {
                    any_working = any_working or r.status == .working;
                    body = body.child(self.renderRow(r, theme, prefs, cx));
                }
                list = list.child(div().flex().flexCol().pt(px(if (show_pinned) section_gap else 0))
                    .child(self.sectionHeader(1, if (self.sessions_open) "Sessions" else zpui.fmt("Sessions ({d})", .{regular.items.len}), self.sessions_open, theme, cx))
                    .child(if (self.sessions_open) body else null));
            }
        }

        var archived_section: ?zpui.Div = null;
        if (archived.items.len > 0) {
            var sec = div().flex().flexCol()
                .child(self.sectionHeader(2, if (self.archived_open) "Archived" else zpui.fmt("Archived ({d})", .{archived.items.len}), self.archived_open, theme, cx));
            if (self.archived_open) {
                var body = div().flex().flexCol().gap(px(list_gap)).pt(px(disclosure_body_inset));
                for (archived.items, 0..) |*r, i| {
                    if (i >= self.archived_shown) break;
                    body = body.child(self.renderRow(r, theme, prefs, cx));
                }
                if (archived.items.len > self.archived_shown) {
                    body = body.child(div().id("archived-more").h(px(if (prefs.sidebar_compact) 29 else 36))
                        .flex().itemsCenter().px(px(8)).rounded(px(8)).cursorPointer()
                        .textSize(rems(12)).textColor(theme.text_muted.opacity(0.7))
                        .hover(sb.bg(theme.glassHover()).textColor(theme.text))
                        .onClick(cx.listener(Sidebar.onShowMoreArchived))
                        .child("Show more"));
                }
                sec = sec.child(body);
            }
            archived_section = sec;
        }

        if (any_working) window.requestAnimationFrame();

        const lists = ui.effects.edgeFaded(
            div().relative().flex1().minH0().child(
                div().id("sidebar-lists").relative().sizeFull().overflowYScroll().trackScroll(self.scroll)
                    .px(px(zt.layout.space_sm)).flex().flexCol().pt(px(4))
                    .child(list)
                    .child(archived_section),
            ),
            .{ .band = fade_band, .top = true, .bottom = true, .scroll = self.scroll },
        );

        return div()
            .wFull().hFull().flex().flexCol()
            .fontFamily(theme.font_sans)
            .child(self.renderFilterRow(theme, prefs, ws, now, cx))
            .child(lists)
            .child(self.renderUpdateStrip(theme, cx))
            .child(div().p(px(zt.layout.space_sm)).flexNone().child(self.renderFooter(theme, cx)))
            .child(self.renderContextMenu(theme, cx));
    }

    /// Project / device accordions (`SidebarOrganization::ByProject/ByDevice`):
    /// groups in recency order, this machine's device group first.
    fn renderGroups(self: *Sidebar, rows: []RowData, follows: bool, ws: *const model.WorkspaceStore, theme: *const Theme, prefs: *const prefs_mod.Prefs, cx: *Context(Sidebar), any_working: *bool) zpui.Div {
        const arena = zpui.window.arena_mod.frameAllocator();
        const Group = struct { key: []const u8, label: []const u8, rows: std.ArrayList(*const RowData) = .empty };
        var groups: std.ArrayList(Group) = .empty;
        for (rows) |*r| {
            const by_device = prefs.organization == .by_device;
            const key: []const u8 = if (by_device) r.chat.deviceId else (r.chat.spaceId orelse "~");
            const label: []const u8 = if (by_device) (ws.deviceName(r.chat.deviceId) orelse "Unknown device") else r.project_name;
            const g = for (groups.items) |*g| {
                if (std.mem.eql(u8, g.key, key)) break g;
            } else blk: {
                groups.append(arena, .{ .key = key, .label = label }) catch continue;
                break :blk &groups.items[groups.items.len - 1];
            };
            g.rows.append(arena, r) catch {};
        }
        if (prefs.organization == .by_device) if (ws.local_device_id) |local| {
            for (groups.items, 0..) |g, i| if (i > 0 and std.mem.eql(u8, g.key, local)) {
                const moved = groups.orderedRemove(i);
                groups.insert(arena, 0, moved) catch {};
                break;
            };
        };
        self.clearIds(&self.group_keys);
        var out = div().flex().flexCol();
        for (groups.items, 0..) |g, gi| {
            self.group_keys.append(self.gpa, self.gpa.dupe(u8, g.key) catch continue) catch {};
            const open = !self.isCollapsed(g.key);
            const label = if (open) g.label else zpui.fmt("{s} ({d})", .{ g.label, g.rows.items.len });
            const tone = theme.text_muted.opacity(0.5);
            const header = div().id(.{ "sidebar-group", gi })
                .flex().flexRow().itemsCenter().gap(px(8)).h(px(disclosure_header_height)).px(px(zt.layout.space_sm)).cursorPointer()
                .onClick(cx.listenerWith(gi, Sidebar.toggleGroup))
                .child(div().minW0().flex().textSize(rems(12)).fontWeight(500).textColor(tone).child(ui.effects.fadedText(label, .{})))
                .child(div().flex1())
                .child(if (prefs.organization == .by_project and !std.mem.eql(u8, g.key, "~"))
                    div().id(.{ "group-new-chat", gi }).size(px(20)).flexNone().flex().itemsCenter().justifyCenter()
                        .rounded(px(6)).cursorPointer().hover(sb.bg(theme.glassHover()))
                        .onClick(cx.listenerWith(gi, Sidebar.onGroupNewChat))
                        .tooltipWith(@as([]const u8, "New session in this project"), ui.tooltip.build)
                        .child(icon.of(.plus, 13, tone))
                else
                    null)
                .child(icon.of(if (open) .alt_arrow_down else .alt_arrow_right, 12, tone));
            var sec = div().flex().flexCol().pt(px(if (follows or gi > 0) section_gap else 0)).child(header);
            if (open) {
                var body = div().flex().flexCol().gap(px(list_gap)).pt(px(disclosure_body_inset));
                for (g.rows.items) |r| {
                    any_working.* = any_working.* or r.status == .working;
                    body = body.child(self.renderRow(r, theme, prefs, cx));
                }
                sec = sec.child(body);
            }
            out = out.child(sec);
        }
        return out;
    }

    fn onGroupNewChat(self: *Sidebar, gi: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        cx.stopPropagation();
        if (gi >= self.group_keys.items.len) return;
        const key = self.gpa.dupe(u8, self.group_keys.items[gi]) catch return;
        defer self.gpa.free(key);
        const ws = self.state.read(cx).workspace;
        ws.update(cx, model.WorkspaceStore.selectChat, .{@as(?[]const u8, null)});
        ws.update(cx, model.WorkspaceStore.selectSpace, .{@as(?[]const u8, key)});
        cx.emit(NewSession{});
    }

    fn isCollapsed(self: *const Sidebar, key: []const u8) bool {
        for (self.collapsed_groups.items) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }

    fn toggleGroup(self: *Sidebar, gi: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        if (gi >= self.group_keys.items.len) return;
        const key = self.group_keys.items[gi];
        for (self.collapsed_groups.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
            self.gpa.free(self.collapsed_groups.orderedRemove(i));
            cx.notify();
            return;
        };
        self.collapsed_groups.append(self.gpa, self.gpa.dupe(u8, key) catch return) catch {};
        cx.notify();
    }

    fn sectionHeader(self: *Sidebar, which: u8, label: []const u8, open: bool, theme: *const Theme, cx: *Context(Sidebar)) zpui.StatefulDiv {
        _ = self;
        const tone = theme.text_muted.opacity(0.5);
        return div().id(.{ "sidebar-disclosure", which })
            .flex().flexRow().itemsCenter().gap(px(8))
            .h(px(disclosure_header_height)).px(px(zt.layout.space_sm))
            .cursorPointer()
            .onClick(cx.listenerWith(which, Sidebar.toggleSection))
            .child(div().textSize(rems(12)).fontWeight(500).textColor(tone).whitespaceNowrap().child(label))
            .child(div().flex1())
            .child(icon.of(if (open) .alt_arrow_down else .alt_arrow_right, 12, tone));
    }

    fn renderRow(self: *Sidebar, r: *const RowData, theme: *const Theme, prefs: *const prefs_mod.Prefs, cx: *Context(Sidebar)) zpui.StatefulDiv {
        const ix = self.row_ids.items.len;
        if (self.gpa.dupe(u8, r.chat.id)) |id_copy| {
            self.row_ids.append(self.gpa, id_copy) catch self.gpa.free(id_copy);
        } else |_| {}

        const hover_key = zpui.fmt("sidebar-row-{s}", .{r.chat.id});
        const compact = prefs.sidebar_compact;
        const show_label = prefs.show_project_label;
        const hovered = self.hovered == ix;
        const archived_muted = r.archived and !r.selected and !hovered;
        const subline = theme.text_muted.opacity(0.5);
        const status_color = statusColor(r.status, theme);
        const label = statusLabel(r.status);
        const working = r.status == .working;
        const height = rowHeight(compact, show_label, r.branch != null, r.pr != null);
        const rest_text = if (r.selected) theme.text else if (r.archived) theme.text.opacity(0.55) else theme.text.opacity(0.8);
        const rest_bg = if (r.selected) ui.theme.glassSelectedBg(theme) else theme.wash(0);
        const hover_bg = if (r.selected) ui.theme.glassSelectedBg(theme) else theme.glassHover();

        // Corner: status word / time, or the Archive pill while hovered.
        const corner_body: zpui.AnyElement = blk: {
            if (hovered) {
                var pill = div().flex().flexRow().itemsCenter().gap(px(4)).h(px(18));
                if (!compact) pill = pill.px(px(4)).mr(px(-4)).rounded(px(5)).bg(theme.wash(0.10)).hover(sb.bg(theme.wash(0.18)));
                pill = pill.child(icon.of(if (r.archived) .archive_up_minimalistic else .archive_minimalistic, if (compact) harness_icon_size else 11, theme.text_muted));
                if (!compact) pill = pill.child(div().textSize(rems(10)).lineHeight(px(14)).textColor(theme.text_muted).child(if (r.archived) "Unarchive" else "Archive"));
                break :blk zpui.intoAnyElement(pill);
            }
            if (compact) {
                if (r.remote) break :blk zpui.intoAnyElement(icon.of(.remote_server, harness_icon_size, theme.text_muted.opacity(0.5)));
                break :blk zpui.intoAnyElement(div());
            }
            if (label) |l| {
                const glyph: zpui.AnyElement = if (r.status == .completed)
                    zpui.intoAnyElement(icon.of(.check, 11, status_color))
                else if (working)
                    zpui.intoAnyElement(ui.loaders.miniGlyphSpinner(2, theme.glyph.rows(), ui.loaders.phaseOf(cx, zt.motion.gradient_spin)))
                else
                    zpui.intoAnyElement(div().size(px(6)).flexNone().roundedFull().bg(status_color));
                break :blk zpui.intoAnyElement(div().flex().flexRow().itemsCenter().gap(px(4)).child(glyph)
                    .child(div().textSize(rems(10)).lineHeight(px(14)).fontWeight(500).textColor(status_color).child(l)));
            }
            break :blk zpui.intoAnyElement(div().textSize(rems(10)).lineHeight(px(14)).fontWeight(500).whitespaceNowrap().child(r.time_ago));
        };
        var corner = div().id(.{ "row-corner", ix }).flexNone().h(px(14)).flex().itemsCenter().textColor(subline).cursorPointer();
        if (compact) corner = corner.w(px(18)).justifyCenter();
        if (hovered) corner = corner.onClick(cx.listenerWith(ix, Sidebar.onArchiveClick))
            .tooltipWith(@as([]const u8, if (r.archived) "Unarchive session" else "Archive session"), ui.tooltip.buildAbove);
        corner = corner.child(corner_body);

        // Harness + project icons.
        const harness: ?zpui.elements.Svg = if (prefs.show_harness) (if (r.chat.config) |cfg| icon.harness(cfg.harness, harness_icon_size, subline, if (archived_muted) 0.4 else 0.8) else null) else null;
        const project_icon: ?zpui.Div = if (prefs.show_project_icon)
            div().flexNone().opacity(if (archived_muted) 0.4 else 1.0).child(ui.badge.monogram(r.project_name, r.project_seed, harness_icon_size, r.selected, row_group, theme))
        else
            null;

        var row = div().id(.{ "chat-row", ix }).group(row_group)
            .h(px(height)).flexNone().flex().flexCol().gap(px(2))
            .rounded(px(8)).px(px(zt.layout.space_sm)).py(px(6))
            .textColor(ui.hover.blend(cx, hover_key, rest_text, theme.text))
            .bg(ui.hover.blend(cx, hover_key, rest_bg, hover_bg))
            .cursorPointer()
            .onHover(cx.listenerWith(ix, Sidebar.onRowHover))
            .onMouseDown(.right, cx.listenerWith(ix, Sidebar.onRowContext))
            .onClick(cx.listenerWith(ix, Sidebar.onRowClick));

        if (compact) {
            const status_glyph: zpui.AnyElement = if (working)
                zpui.intoAnyElement(ui.loaders.miniGlyphSpinner(2, theme.glyph.rows(), ui.loaders.phaseOf(cx, zt.motion.gradient_spin)))
            else if (r.status == .completed)
                zpui.intoAnyElement(icon.of(.check, 11, status_color))
            else
                zpui.intoAnyElement(div().size(px(6)).roundedFull().bg(status_color));
            var line = div().wFull().flex().flexRow().itemsCenter().gap(px(4))
                .child(div().size(px(13)).flexNone().flex().itemsCenter().justifyCenter().child(status_glyph))
                .child(harness)
                .child(project_icon)
                .child(div().flex1().minW0().flex().textSize(rems(13)).lineHeight(px(17)).child(ui.effects.fadedText(r.title, .{ .fill = true })));
            if (r.remote or hovered) line = line.child(corner);
            if (r.pr) |n| line = line.child(ui.badge.pullRequest(n, theme));
            line = line.child(div().w(px(30)).flexNone().whitespaceNowrap().textRight().textSize(rems(11)).lineHeight(px(14)).textColor(subline).child(r.time_ago));
            return row.child(line);
        }

        if (show_label) {
            row = row.child(div().wFull().flex().flexRow().itemsCenter().gap(px(zt.layout.space_sm))
                .child(div().flex1().minW0().flex().textSize(rems(11)).lineHeight(px(14)).textColor(subline)
                    .child(ui.effects.fadedText(r.folder, .{ .fill = true })))
                .child(corner));
        }
        var title_line = div().wFull().flex().flexRow().itemsCenter().gap(px(zt.layout.space_sm))
            .child(harness)
            .child(project_icon)
            .child(div().flex1().minW0().flex().textSize(rems(13)).lineHeight(px(17)).child(ui.effects.fadedText(r.title, .{ .fill = true })));
        if (!show_label) {
            if (r.remote) title_line = title_line.child(icon.of(.remote_server, harness_icon_size, subline));
            title_line = title_line.child(corner);
        }
        row = row.child(title_line);
        if (r.branch != null or r.pr != null) {
            var meta = div().wFull().flex().flexRow().itemsCenter().gap(px(4));
            if (r.branch) |b| meta = meta.child(icon.of(.git_branch, 11, subline))
                .child(div().minW0().flexShrink1().flex().textSize(rems(11)).lineHeight(px(14)).textColor(subline).child(ui.effects.fadedText(b, .{})));
            meta = meta.child(div().flex1().minW0());
            if (r.pr) |n| meta = meta.child(ui.badge.pullRequest(n, theme));
            row = row.child(meta);
        }
        return row;
    }

    fn renderFilterRow(self: *Sidebar, theme: *const Theme, prefs: *const prefs_mod.Prefs, ws: *const model.WorkspaceStore, now: Timestamp, cx: *Context(Sidebar)) zpui.Div {
        var label: []const u8 = "All projects";
        var tag: ?[]const u8 = null;
        var offline = false;
        if (prefs.space_filter) |f| if (ws.space(f)) |s| {
            label = view.spaceDisplayName(s);
            var buf: [96]u8 = undefined;
            const t, const off = ws.spaceDeviceTag(&buf, s, now);
            tag = zpui.fmt("{s}", .{t});
            offline = off;
        };
        var name_group = div().flex1().minW0().flex().flexRow().itemsCenter().gap(px(6))
            .child(ui.effects.fadedText(label, .{}));
        if (tag) |t| {
            name_group = name_group.child(div().minW0().flexShrink1().flex().textSize(rems(10)).fontWeight(400).textColor(theme.text_muted.opacity(0.45)).child(ui.effects.fadedText(t, .{})));
            if (offline) name_group = name_group.child(icon.of(.wifi_off, 12, theme.warning.opacity(0.8)));
        }
        var trigger = div().id("spaces-filter")
            .relative().flex1().minW0().h(px(29)).flex().flexRow().itemsCenter().gap(px(zt.layout.space_sm))
            .rounded(px(8)).px(px(zt.layout.space_sm))
            .textSize(rems(13)).fontWeight(500).lineHeight(px(17))
            .textColor(if (self.spaces_menu_open) theme.text else theme.text.opacity(0.8))
            .bg(if (self.spaces_menu_open) theme.glassHover() else theme.glassHover().opacity(0))
            .hover(sb.bg(theme.glassHover()).textColor(theme.text))
            .cursorPointer()
            .onClick(cx.listener(Sidebar.onSpacesTrigger))
            .child(icon.of(.folder, 16, theme.text_muted))
            .child(name_group)
            .child(icon.of(.alt_arrow_down, 14, theme.text_muted.opacity(0.6)));
        if (self.spaces_menu_open) trigger = trigger.child(ui.popover.anchoredBelow(self.renderSpacesMenu(theme, prefs, ws, cx)));

        var view_trigger = div().id("sidebar-view-options")
            .relative().size(px(29)).flexNone().flex().itemsCenter().justifyCenter()
            .rounded(px(8)).cursorPointer()
            .bg(if (self.view_menu_open) theme.glassHover() else theme.glassHover().opacity(0))
            .hover(sb.bg(theme.glassHover()))
            .onClick(cx.listener(Sidebar.onViewTrigger))
            .child(icon.of(.more_horizontal, 16, theme.text_muted.opacity(0.6)));
        if (!self.view_menu_open) view_trigger = view_trigger.tooltipWith(@as([]const u8, "View options"), ui.tooltip.build)
            .tooltipShowDelay(350 * std.time.ns_per_ms);
        if (self.view_menu_open) view_trigger = view_trigger.child(ui.popover.anchoredRight(self.renderViewMenu(theme, prefs, cx)));

        return div().flexNone().flex().flexRow().itemsCenter().gap(px(4))
            .px(px(zt.layout.space_sm)).pt(px(8)).pb(px(4))
            .child(trigger).child(view_trigger);
    }

    fn renderSpacesMenu(self: *Sidebar, theme_in: *const Theme, prefs: *const prefs_mod.Prefs, ws: *const model.WorkspaceStore, cx: *Context(Sidebar)) zpui.Div {
        const theme = &zpui.window.arena_mod.current().create(Theme, theme_in.forPopup()).*;
        self.clearIds(&self.menu_space_ids);
        const arena = zpui.window.arena_mod.frameAllocator();
        const width = prefs.sidebar_width - 2 * zt.layout.space_sm;
        var card = ui.popover.card(theme).w(px(width)).onMouseDownOut(cx.listener(Sidebar.onCloseMenus));
        card = card.child(ui.popover.menuRow(theme, prefs.space_filter == null).id("spaces-all")
            .onClick(cx.listenerWith(@as(usize, std.math.maxInt(usize)), Sidebar.onPickSpace))
            .child(icon.of(.folder, 16, theme.text_muted))
            .child(div().flex1().child("All projects"))
            .child(if (prefs.space_filter == null) icon.of(.check, 14, theme.text_muted) else null));
        const spaces = ws.spacesSorted(arena) catch &.{};
        var buf: [96]u8 = undefined;
        for (spaces, 0..) |s, i| {
            self.menu_space_ids.append(self.gpa, self.gpa.dupe(u8, s.id) catch continue) catch {};
            const active = if (prefs.space_filter) |f| std.mem.eql(u8, f, s.id) else false;
            const tag, _ = ws.spaceDeviceTag(&buf, s, prefs.now(ws.io));
            card = card.child(ui.popover.menuRow(theme, active).id(.{ "spaces-row", i })
                .onClick(cx.listenerWith(i, Sidebar.onPickSpace))
                .child(ui.badge.monogram(view.spaceDisplayName(s), s.path, 16, false, null, theme))
                .child(div().flex1().minW0().flex().itemsCenter().gap(px(6))
                    .child(ui.effects.fadedText(view.spaceDisplayName(s), .{}))
                    .child(div().textSize(rems(10)).textColor(theme.text_muted.opacity(0.6)).whitespaceNowrap().child(zpui.fmt("{s}", .{tag}))))
                .child(if (active) icon.of(.check, 14, theme.text_muted) else null));
        }
        card = card.child(ui.popover.separator(theme));
        card = card.child(ui.popover.menuRow(theme, false).id("spaces-new")
            .onClick(cx.listener(Sidebar.onNewProject))
            .child(icon.of(.add_circle, 16, theme.text_muted))
            .child("New project…"));
        return card;
    }

    fn renderViewMenu(self: *Sidebar, theme_in: *const Theme, prefs: *const prefs_mod.Prefs, cx: *Context(Sidebar)) zpui.Div {
        const theme = &zpui.window.arena_mod.current().create(Theme, theme_in.forPopup()).*;
        const labels = [_][]const u8{ "By device", "By project", "None", "Last updated", "Created", "Branch", "Pull request", "Harness", "Project icon", "Location" };
        const icons = [_]icon.Icon{ .laptop, .folder, .list, .clock_circle, .calendar, .git_branch, .pull_request, .bot, .project_default, .folder };
        const selected = [_]bool{
            prefs.organization == .by_device, prefs.organization == .by_project, prefs.organization == .in_one_list,
            prefs.sort == .last_updated,      prefs.sort == .created,            prefs.show_branch,
            prefs.show_pull_request,          prefs.show_harness,                prefs.show_project_icon,
            prefs.show_project_label,
        };
        const groups = [_]struct { []const u8, u8, u8 }{ .{ "Organize", 0, 3 }, .{ "Sort", 3, 5 }, .{ "Show", 5, 10 } };
        const values = [_][]const u8{
            if (selected[0]) labels[0] else if (selected[1]) labels[1] else labels[2],
            if (selected[3]) labels[3] else labels[4],
        };
        var card = ui.popover.card(theme).w(px(prefs.sidebar_width - 2 * zt.layout.space_sm))
            .onMouseDownOut(cx.listener(Sidebar.onCloseMenus));
        for (groups, 0..) |g, gi| {
            if (gi == 2) card = card.child(ui.popover.separator(theme));
            const open = self.view_submenu == @as(u8, @intCast(gi));
            var row = ui.popover.menuRow(theme, open).id(.{ "sidebar-view-group", gi })
                .relative().h(px(30)).py(px(0))
                .onHover(cx.listenerWith(@as(u8, @intCast(gi)), Sidebar.onViewGroupHover))
                .child(div().flex1().child(g[0]));
            if (gi < values.len) row = row.child(div().textColor(theme.text_muted).child(values[gi]));
            row = row.child(icon.of(.alt_arrow_right, 12, theme.text_muted));
            if (open) {
                var child = ui.popover.card(theme).w(px(232)).child(ui.popover.heading(theme, if (gi == 0) "ORGANIZE" else if (gi == 1) "SORT" else "SHOW"));
                var ix = g[1];
                while (ix < g[2]) : (ix += 1) {
                    child = child.child(ui.popover.menuRow(theme, false).id(.{ "sidebar-view-row", ix })
                        .onClick(cx.listenerWith(ix, Sidebar.onToggleView))
                        .child(icon.of(icons[ix], 15, theme.text_muted))
                        .child(div().flex1().child(labels[ix]))
                        .child(div().w(px(14)).flexNone().child(if (selected[ix]) icon.of(.check, 14, theme.text_muted) else null)));
                }
                row = row.child(div().absolute().top(px(-ui.popover.card_inset - 1)).right(px(-(ui.popover.card_inset + 6))).size(px(0))
                    .child(zpui.deferred(zpui.anchored().anchorCorner(.top_left).snapToWindowWithMargin(.all(8))
                    .child(div().occlude().child(ui.popover.frostedCard(child)))).withPriority(2)));
            }
            card = card.child(row);
        }
        card = card.child(ui.popover.separator(theme));
        card = card.child(ui.popover.menuRow(theme, false).id("sidebar-view-compact").h(px(30)).py(px(0))
            .onHover(cx.listenerWith(@as(u8, 3), Sidebar.onViewGroupHover))
            .onClick(cx.listenerWith(@as(u8, 10), Sidebar.onToggleView))
            .child(div().flex1().child("Compact"))
            .child(ui.switch_.toggle(theme, prefs.sidebar_compact)));
        card = card.child(ui.popover.separator(theme));
        card = card.child(ui.popover.menuRow(theme, false).id("sidebar-create-section")
            .onHover(cx.listenerWith(@as(u8, 4), Sidebar.onViewGroupHover))
            .child(icon.of(.plus, 14, theme.text_muted)).child("Create Section"));
        return card;
    }

    /// The update strip above the footer (`render_update_strip`): accent
    /// wash chip, 11px medium accent label.
    fn renderUpdateStrip(self: *Sidebar, theme: *const Theme, cx: *Context(Sidebar)) ?zpui.StatefulDiv {
        const prefs = prefs_mod.get(cx);
        var label: []const u8 = undefined;
        if (prefs.update_label) |l| {
            label = l;
        } else {
            const up = self.state.read(cx).updates.read(cx).current() orelse return null;
            if (!up.updateAvailable) return null;
            label = zpui.fmt("Update available — v{s}", .{up.latestVersion orelse ""});
        }
        return div().id("update-strip").mx(px(zt.layout.space_sm)).px(px(zt.layout.space_sm)).py(px(6))
            .rounded(px(zt.layout.control_radius)).bg(theme.accent_wash)
            .flex().flexRow().itemsCenter()
            .textSize(rems(11)).fontWeight(500).textColor(theme.accent)
            .cursorPointer().hover(sb.bg(theme.accent.opacity(0.16)))
            .child(div().flex1().minW0().child(label));
    }

    fn renderFooter(self: *Sidebar, theme_in: *const Theme, cx: *Context(Sidebar)) zpui.Div {
        const theme = &zpui.window.arena_mod.current().create(Theme, theme_in.forPopup()).*;
        const app_state = self.state.read(cx);
        const scope = app_state.engine.read(cx).workspaceScope() orelse app_state.workspace.read(cx).workspace_scope;
        const user = app_state.auth.read(cx).user();
        var user_line: []const u8 = "Local";
        var identity: []const u8 = "Stored on this device";
        var signed_in = false;
        if (scope) |sc| switch (sc) {
            .local => {},
            .development => {
                user_line = "Development";
                identity = "Authentication disabled";
            },
            .synced => if (user) |u| {
                const name = std.mem.trim(u8, u.name orelse "", " ");
                user_line = if (name.len > 0) name else u.email;
                identity = u.email;
                signed_in = true;
            } else {
                identity = "Not signed in";
            },
        };
        const initial = blk: {
            const t = std.mem.trim(u8, user_line, " ");
            if (t.len == 0) break :blk "?";
            break :blk zpui.fmt("{c}", .{std.ascii.toUpper(t[0])});
        };
        var trigger = div().id("user-menu")
            .relative().h(px(footer_button_size)).minW0().flexShrink1()
            .rounded(px(8)).px(px(zt.layout.space_sm))
            .flex().flexRow().itemsCenter().gap(px(zt.layout.space_sm))
            .textSize(rems(13)).fontWeight(500)
            .textColor(if (self.user_menu_open) theme.text else theme.text.opacity(0.8))
            .bg(if (self.user_menu_open) theme.glassHover() else theme.glassHover().opacity(0))
            .hover(sb.bg(theme.glassHover().opacity(0.8)).textColor(theme.text))
            .cursorPointer()
            .onClick(cx.listener(Sidebar.onUserMenu))
            .child(div().size(px(footer_avatar_size)).flexNone().roundedFull().bg(theme.text)
                .flex().itemsCenter().justifyCenter()
                .fontFamily(theme.font_mono).textSize(px(10)).lineHeight(px(footer_avatar_size))
                .fontWeight(600).textColor(theme.bg)
                .child(div().wFull().textCenter().child(initial)))
            .child(div().minW0().flex().lineHeight(px(17)).child(ui.effects.fadedText(user_line, .{})));
        if (self.user_menu_open) {
            const prefs = prefs_mod.get(cx);
            var menu = ui.popover.card(theme).w(px(prefs.sidebar_width - 2 * zt.layout.space_sm))
                .onMouseDownOut(cx.listener(Sidebar.onCloseMenus))
                .child(div().px(px(8)).pt(px(6)).pb(px(4)).textSize(rems(11)).textColor(theme.text_muted).truncate().child(identity));
            if (scope != null and scope.? == .local) {
                menu = menu.child(ui.popover.menuRow(theme, false).id("user-menu-enable-sync")
                    .child(icon.of(.global, 16, theme.text_muted)).child("Enable sync"));
            } else if (signed_in) {
                menu = menu.child(ui.popover.menuRow(theme, false).id("user-menu-signout")
                    .onClick(cx.listener(Sidebar.onSignOut))
                    .child(icon.of(.logout_2, 16, theme.text_muted)).child("Sign out"));
            }
            if (@import("builtin").os.tag != .macos) {
                menu = menu.child(ui.popover.menuRow(theme, false).id("user-menu-check-updates")
                    .child(icon.of(.refresh, 16, theme.text_muted)).child("Check for updates"));
            }
            trigger = trigger.child(ui.popover.anchoredAbove(menu));
        }
        const mac = @import("builtin").os.tag == .macos;
        return div().wFull().flex().itemsCenter().justifyBetween().gap(px(4))
            .child(trigger)
            .child(div().id("settings-trigger")
                .size(px(footer_button_size)).flexNone().rounded(px(8))
                .flex().itemsCenter().justifyCenter().cursorPointer()
                .hover(sb.bg(theme.glassHover()))
                .tooltipWith(@as([]const u8, if (mac) "Settings · ⌘," else "Settings · Ctrl+,"), ui.tooltip.build)
                .onClick(cx.listener(Sidebar.onSettings))
                .child(icon.of(.settings, 15, theme.text_muted)));
    }
};

