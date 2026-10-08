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
const native_popover = @import("../components/native_popover.zig");
const crb = @import("../components/change_request_badge.zig"); // [pr-status]
const prefs_mod = @import("../shell/prefs.zig");
const app_update = @import("../../lifecycle/app_update.zig"); // [lifecycle]
const project_icon_mod = @import("project_icon.zig");
// [wiring] chat context menu: Rename (inline), Copy ▸, Delete… (shell confirms).
const chat_menu = @import("chat_menu.zig");
// Custom sections + session transfers (sections.zig / sections_ui.zig).
const sections = @import("sections.zig");
const sections_ui = @import("sections_ui.zig");
const SessionDrag = sections_ui.SessionDrag;
const sync_flow = @import("../shell/sync_flow.zig"); // account menu: sync / sign-out rows
const input_mod = @import("zeron_input");
const TextInput = input_mod.TextInput;

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

/// Slot `y` px into the pinned list (cumulative row slots) → drop index.
pub fn pinDropIndex(y: f32, slots: []const f32) usize {
    if (slots.len == 0) return 0;
    var top: f32 = 0;
    for (slots, 0..) |h, i| {
        if (y < top + h) return i;
        top += h;
    }
    return slots.len - 1;
}

/// Insertion slot `y` px into the pinned list for a row joining it (0…len).
pub fn pinInsertIndex(y: f32, slots: []const f32) usize {
    var top: f32 = 0;
    for (slots, 0..) |h, i| {
        if (y < top + h / 2) return i;
        top += h;
    }
    return slots.len;
}

/// Move `from` to `to` in `ids` (the drop's "after"/"before" neighbours
/// are read off the result).
pub fn movePin(ids: [][]const u8, from: usize, to: usize) void {
    if (from >= ids.len or to >= ids.len or from == to) return;
    const moving = ids[from];
    if (from < to) {
        std.mem.copyForwards([]const u8, ids[from..to], ids[from + 1 .. to + 1]);
    } else {
        std.mem.copyBackwards([]const u8, ids[to + 1 .. from + 1], ids[to..from]);
    }
    ids[to] = moving;
}

fn slideOffsetY(ix: usize, from: usize, over: usize) f32 {
    if (from < over and ix > from and ix <= over) return -1;
    if (over < from and ix >= over and ix < from) return 1;
    return 0;
}

pub const OpenSettings = struct {};
pub const NewSession = struct {};
pub const SignOut = struct {};
/// [wiring] "Delete…" in a row's context menu: the shell asks for confirmation.
pub const DeleteChat = struct { chat_id: []const u8 };
/// [wiring] User menu "Enable sync": the shell starts the browser sign-in.
pub const EnableSync = struct {};
/// The account menu's sync row (`AccountMenuAction`): the shell runs it.
pub const AccountAction = struct { action: sync_flow.AccountMenuAction };
/// [wiring] Project row menu (spaces filter): "Rename…" / "Remove…" (shell dialogs).
pub const RenameSpace = struct { space_id: []const u8 };
pub const DeleteSpace = struct { space_id: []const u8 };

/// [wiring] An inline title editor on a session row (Rust `ChatRename`).
const ChatRename = struct {
    chat_id: []u8,
    input: Entity(TextInput),
    sub: zpui.Subscription,
    blur: ?zpui.Subscription = null,
};

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
    /// Local project folder (artwork lookup); null for home / remote rows.
    space_path: ?[]const u8 = null,
    branch: ?[]const u8,
    pr: ?u64,
    time_ago: []const u8,
    remote: bool,
    selected: bool,
    archived: bool,
    /// Draw the row's project tile (a project group's header wears it instead).
    project_icon: bool = true,
};

/// `sidebar_project_group`: project-mode group of a chat as (key, label).
/// Projects sharing a repository identity fold into one group named for
/// their representative space; project-less sessions group per device and
/// read as `~`. Strings live in the frame arena.
fn projectGroup(ws: *const model.WorkspaceStore, c: *const Chat) struct { key: []const u8, label: []const u8 } {
    if (ws.spaceForChat(c)) |s| return .{ .key = projectKeyString(s), .label = view.spaceDisplayName(ws.representativeSpace(s)) };
    if (c.spaceId) |sid| return .{ .key = sid, .label = "?" };
    return .{ .key = zpui.fmt("home:{s}", .{c.deviceId}), .label = "~" };
}

/// `project_key` in its Rust string form (frame arena).
fn projectKeyString(s: *const engine.protocol.Space) []const u8 {
    const k = view.projectKey(s);
    return if (k.repository_id) |r| zpui.fmt("repo:{s}", .{r}) else s.id;
}

/// The checkout a group's `+` opens a new chat on: this device's checkout
/// of the project keyed `key` when it has one (`project_members` order).
fn groupSpace(ws: *const model.WorkspaceStore, gpa: std.mem.Allocator, key: []const u8) ?[]const u8 {
    for (ws.spaces()) |*s| {
        if (!std.mem.eql(u8, projectKeyString(s), key)) continue;
        const members = ws.projectMembers(gpa, s) catch return s.id;
        defer gpa.free(members);
        return if (members.len > 0) members[0].id else s.id;
    }
    return null;
}

pub const Sidebar = struct {
    gpa: std.mem.Allocator,
    state: Entity(model.AppState),
    scroll: zpui.ScrollHandle,
    subs: zpui.Subscriptions = .{},
    /// [pr-status] This frame's checkout PR snapshots (`WatchCheckoutChangeRequest`).
    prs: ?*const model.ChangeRequestStore = null,

    pinned_open: bool = true,
    sessions_open: bool = true,
    archived_open: bool = false,
    archived_shown: usize = archived_initial_rows,
    user_menu_open: bool = false,
    spaces_menu_open: bool = false,
    view_menu_open: bool = false,
    /// Right-click menu over a row: (row index, window position).
    ctx_menu: ?struct { ix: usize, pos: zpui.Point(f32) } = null,
    /// [motion] Each popup's closing phase (`Popup::begin_close`): the menu
    /// stays mounted for MENU_OUT while it fades toward its trigger.
    ctx_exit: ui.popover.Exit = .{},
    user_menu_exit: ui.popover.Exit = .{},
    spaces_menu_exit: ui.popover.Exit = .{},
    view_menu_exit: ui.popover.Exit = .{},
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
    /// Project artwork (favicons) per local project folder.
    icons: project_icon_mod.Cache = .{},
    /// Pinned-row drag: hovered slot + slide epoch (Rust `PinnedSessionDragState`).
    /// `from` is the pinned count when a non-pinned row is joining (`slot`: its row + gap).
    pin_drag: ?struct { from: usize, over: usize, prev_over: usize, epoch: usize, slot: f32 = 0 } = null,
    /// Pinned rows rendered last frame: count and slot heights (row + gap).
    pinned_count: usize = 0,
    pin_slots: std.ArrayList(f32) = .empty,
    /// [motion] Resort glide (`sidebar_prev_order` / `sidebar_resort` /
    /// `sidebar_new_keys`): last frame's keyed order, the FLIP offsets of
    /// rows whose order changed, and rows that newly appeared (owned keys).
    resort_prev: std.ArrayList(ResortItem) = .empty,
    resort_offsets: std.StringHashMapUnmanaged(f32) = .empty,
    resort_new: std.StringHashMapUnmanaged(void) = .empty,
    resort_epoch: u64 = 0,

    // [wiring] context-menu page, inline rename, inline notice (Rust `sidebar_notice`).
    ctx_page: chat_menu.Page = .root,
    /// The chat context menu is a native menu (macOS): `ctx_menu` keeps its target, the
    /// card is not drawn.
    ctx_native: bool = false,
    rename: ?ChatRename = null,
    notice: ?[]u8 = null,

    /// Custom sections, their menu / dialog, and session transfers (sections_ui.zig).
    sec: sections_ui.State = .{},
    /// The row drawn in the movement layer this frame.
    moving: ?struct { row: zpui.AnyElement, height: f32 } = null,

    /// [wiring] Right-click menu over a project row in the spaces menu.
    space_ctx: ?struct { id: []u8, pos: zpui.Point(f32) } = null,
    emitted_space_id: ?[]u8 = null,

    pub const Events = .{ OpenSettings, NewSession, SignOut, DeleteChat, EnableSync, RenameSpace, DeleteSpace, AccountAction };

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
        try self.subs.add(cx.gpa(), try cx.observe(s.change_requests, onModelChanged)); // [pr-status]
        return self;
    }

    pub fn deinit(self: *Sidebar, app: *App) void {
        self.clearResort();
        self.resort_prev.deinit(self.gpa);
        self.resort_offsets.deinit(self.gpa);
        self.resort_new.deinit(self.gpa);
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
        self.icons.deinit(self.gpa);
        self.pin_slots.deinit(self.gpa);
        self.dropRename(app);
        self.sec.deinit(self.gpa, app);
        self.clearSpaceCtx();
        if (self.emitted_space_id) |e| self.gpa.free(e);
        if (self.notice) |n| self.gpa.free(n);
        self.state.release(app);
    }

    fn clearIds(self: *Sidebar, list: *std.ArrayList([]u8)) void {
        for (list.items) |s| self.gpa.free(s);
        list.clearRetainingCapacity();
    }

    fn onModelChanged(_: *Sidebar, _: anytype, cx: *Context(Sidebar)) void {
        cx.notify();
    }

    /// A row's project tile: the project's artwork once resolved, else the
    /// monogram (also while loading).
    fn projectTile(self: *Sidebar, r: *const RowData, theme: *const Theme, cx: *Context(Sidebar)) zpui.AnyElement {
        const mono = ui.badge.monogram(r.project_name, r.project_seed, harness_icon_size, r.selected, row_group, theme);
        const dir = r.space_path orelse return zpui.intoAnyElement(mono);
        var start = false;
        if (self.icons.get(self.gpa, dir, &start)) |art| {
            return zpui.intoAnyElement(div().size(px(harness_icon_size)).flexNone()
                .child(zpui.img(art.source()).sizeFull().objectFit(.contain)));
        }
        if (start) {
            const io = self.state.read(cx).workspace.read(cx).io;
            const owned = self.gpa.dupe(u8, dir) catch return zpui.intoAnyElement(mono);
            if (cx.spawn(project_icon_mod.LoadJob{ .gpa = self.gpa, .io = io, .dir = owned }, onIconLoaded)) |task| {
                var t = task;
                t.detach();
            } else |_| self.gpa.free(owned);
        }
        return zpui.intoAnyElement(mono);
    }

    fn onPinDragMove(self: *Sidebar, ev: *const zpui.DragMoveEvent(SessionDrag), _: *Window, cx: *Context(Sidebar)) void {
        const inside = ev.bounds.contains(ev.event.position);
        const y = ev.event.position.y - ev.bounds.origin.y;
        if (ev.value.pinned_from) |from| {
            // Pin-to-pin: sibling slide (Rust `update_pinned_session_drag`).
            const over = if (inside) pinDropIndex(y, self.pin_slots.items) else from;
            if (inside) sections_ui.setPreview(self, .pinned);
            if (self.pin_drag) |*d| {
                if (d.over != over) {
                    d.prev_over = d.over;
                    d.over = over;
                    d.epoch += 1;
                    cx.notify();
                }
            } else {
                self.pin_drag = .{ .from = from, .over = over, .prev_over = from, .epoch = 0 };
                cx.notify();
            }
            return;
        }
        // A row joining Pinned opens a slot at its insertion point.
        if (!inside) {
            if (self.pin_drag != null) {
                self.pin_drag = null;
                cx.notify();
            }
            return;
        }
        sections_ui.setPreview(self, .pinned);
        const n = self.pin_slots.items.len;
        const over = pinInsertIndex(y, self.pin_slots.items);
        if (self.pin_drag) |*d| {
            if (d.over != over) {
                d.prev_over = d.over;
                d.over = over;
                d.epoch += 1;
                cx.notify();
            }
        } else {
            self.pin_drag = .{ .from = n, .over = over, .prev_over = n, .epoch = 0, .slot = ev.value.height + list_gap };
            cx.notify();
        }
    }

    /// Drop on Pinned: reorder, or pin a joining row (sections_ui.finishTransfer).
    fn onPinDrop(self: *Sidebar, payload: *const SessionDrag, window: *Window, cx: *Context(Sidebar)) void {
        cx.stopPropagation();
        sections_ui.finishTransfer(self, payload, .pinned, window, cx);
    }

    /// Reorder the local pin list and tell the engine (`changeSidebarPin`
    /// move with the new neighbours).
    pub fn reorderPins(self: *Sidebar, from: usize, to: usize, cx: *Context(Sidebar)) void {
        self.pin_drag = null;
        defer cx.notify();
        const n = @min(self.pinned_count, self.row_ids.items.len);
        if (from >= n or to >= n or from == to) return;
        const order = self.gpa.alloc([]const u8, n) catch return;
        defer self.gpa.free(order);
        for (0..n) |i| order[i] = self.row_ids.items[i];
        // Row ids are rebuilt by the next render: keep copies for the change.
        for (order) |*o| o.* = self.gpa.dupe(u8, o.*) catch "";
        defer for (order) |o| if (o.len > 0) self.gpa.free(o);
        movePin(order, from, to);
        // `changeSidebarPin` move with the new neighbours (synced, local or
        // device-local, through the shared write queue).
        _ = sections_ui.changePin(self, .{ .move = .{
            .sessionId = order[to],
            .after = if (to > 0) order[to - 1] else null,
            .before = if (to + 1 < order.len) order[to + 1] else null,
        } }, cx);
    }

    pub fn rowId(self: *Sidebar, ix: usize) ?[]const u8 {
        return if (ix < self.row_ids.items.len) self.row_ids.items[ix] else null;
    }

    fn onIconLoaded(self: *Sidebar, r: project_icon_mod.LoadJob.Result, cx: *Context(Sidebar)) void {
        const landed = r.art != null;
        self.icons.finish(self.gpa, r);
        if (landed) cx.notify();
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

    fn onRowContext(self: *Sidebar, ix: usize, ev: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(Sidebar)) void {
        self.ctx_menu = .{ .ix = ix, .pos = ev.position };
        self.ctx_exit.clear();
        self.ctx_page = .root;
        self.ctx_native = self.popUpNativeCtx(ix, ev.position, window, cx);
        cx.notify();
    }

    // ---- native menus (macOS; the drawn cards below stay the fallback) ----------------

    const NativeCtx = enum(u32) { rename, pin, archive, delete, copy_path = 10, copy_zeron, copy_harness, copy_session };

    /// `renderContextMenu`'s rows as a native menu, its Copy ▸ page a submenu.
    fn popUpNativeCtx(self: *Sidebar, ix: usize, pos: zpui.Point(f32), window: *Window, cx: *Context(Sidebar)) bool {
        if (!ui.native_menu.enabled(cx)) return false;
        const id = self.rowId(ix) orelse return false;
        const pinned = prefs_mod.get(cx).isPinned(id);
        const c = self.state.read(cx).workspace.read(cx).chat(id);
        var copy: [4]ui.native_menu.Item = undefined;
        var n: usize = 0;
        const copy_icon = ui.native_menu.icon(.copy);
        if (c != null and chat_menu.chatCopyPath(c.?) != null) {
            copy[n] = .{ .label = "Path", .tag = @intFromEnum(NativeCtx.copy_path), .icon = copy_icon };
            n += 1;
        }
        copy[n] = .{ .label = "Zeron conversation link", .tag = @intFromEnum(NativeCtx.copy_zeron), .icon = copy_icon };
        n += 1;
        if (c) |chat| if (chat.config) |cfg| if (cfg.harness == .codex and chat_menu.harnessSessionId(chat) != null) {
            copy[n] = .{ .label = "Codex conversation link", .tag = @intFromEnum(NativeCtx.copy_harness), .icon = copy_icon };
            n += 1;
        };
        if (c != null and chat_menu.harnessSessionId(c.?) != null) {
            copy[n] = .{ .label = "Harness session ID", .tag = @intFromEnum(NativeCtx.copy_session), .icon = copy_icon };
            n += 1;
        }
        const items = [_]ui.native_menu.Item{
            .{ .label = "Rename", .tag = @intFromEnum(NativeCtx.rename), .icon = ui.native_menu.icon(.pen) },
            .{ .label = if (pinned) "Unpin" else "Pin", .tag = @intFromEnum(NativeCtx.pin), .icon = ui.native_menu.icon(.pin) },
            .{ .label = "Archive", .tag = @intFromEnum(NativeCtx.archive), .icon = ui.native_menu.icon(.archive_minimalistic) },
            .{ .kind = .submenu, .label = "Copy", .icon = copy_icon, .submenu = copy[0..n] },
            .separator,
            .{ .label = "Delete\u{2026}", .tag = @intFromEnum(NativeCtx.delete), .icon = ui.native_menu.icon(.trash_bin_minimalistic), .destructive = true },
        };
        return ui.native_menu.popUpAt(window, cx, pos, &items, cx.listener(Sidebar.onNativeCtx));
    }

    fn onNativeCtx(self: *Sidebar, sel: *const ui.native_menu.Selection, window: *Window, cx: *Context(Sidebar)) void {
        if (!self.ctx_native) return;
        const ev: zpui.ClickEvent = .{ .keyboard = .{} };
        if (sel.tag) |tag| switch (@as(NativeCtx, @enumFromInt(tag))) {
            .rename => self.onCtxRename(&ev, window, cx),
            .pin => self.onCtxPin(&ev, window, cx),
            .archive => self.onCtxArchive(&ev, window, cx),
            .delete => self.onCtxDelete(&ev, window, cx),
            .copy_path, .copy_zeron, .copy_harness, .copy_session => self.onCtxCopy(@intCast(tag - @intFromEnum(NativeCtx.copy_path)), &ev, window, cx),
        };
        // The native menu is gone: no exit to play.
        self.ctx_native = false;
        self.ctx_menu = null;
        self.ctx_exit.clear();
        self.ctx_page = .root;
        cx.notify();
    }

    /// The account menu (`renderFooter`) as a native menu, opening upward.
    fn popUpNativeUser(self: *Sidebar, trigger: zpui.Bounds(f32), window: *Window, cx: *Context(Sidebar)) bool {
        if (!ui.native_menu.enabled(cx)) return false;
        const app_state = self.state.read(cx);
        const scope = app_state.engine.read(cx).workspaceScope() orelse app_state.workspace.read(cx).workspace_scope;
        const flow = sync_flow.current(cx.app);
        _, const identity = sync_flow.identity(scope, flow, app_state.auth.read(cx).user());
        var items: [3]ui.native_menu.Item = undefined;
        var n: usize = 0;
        items[n] = .header(identity);
        n += 1;
        if (sync_flow.accountMenuAction(scope, flow)) |action| {
            items[n] = switch (action) {
                .enable_sync => .{ .label = "Enable sync", .icon = ui.native_menu.icon(.global) },
                .sync_in_progress => .{ .label = "Sync setup in progress", .icon = ui.native_menu.icon(.global), .disabled = true },
                .restart_pending => .{ .label = "Finish sync setup", .icon = ui.native_menu.icon(.restart) },
                .sign_out => .{ .label = "Sign out", .icon = ui.native_menu.icon(.logout_2) },
            };
            items[n].tag = @intCast(@intFromEnum(action));
            n += 1;
        }
        if (@import("builtin").os.tag != .macos) {
            items[n] = .{ .label = "Check for updates", .tag = native_check_updates, .icon = ui.native_menu.icon(.refresh) };
            n += 1;
        }
        return ui.native_menu.popUpAbove(window, cx, trigger, items[0..n], cx.listener(Sidebar.onNativeUser));
    }

    const native_check_updates: u32 = 1000;

    fn onNativeUser(self: *Sidebar, sel: *const ui.native_menu.Selection, window: *Window, cx: *Context(Sidebar)) void {
        const tag = sel.tag orelse return;
        const ev: zpui.ClickEvent = .{ .keyboard = .{} };
        if (tag == native_check_updates) return self.onCheckUpdates(&ev, window, cx);
        for (std.enums.values(sync_flow.AccountMenuAction)) |action| {
            if (@intFromEnum(action) == tag) return self.onAccountAction(action, &ev, window, cx);
        }
    }

    const native_all_projects: u32 = std.math.maxInt(u32);
    const native_new_project: u32 = std.math.maxInt(u32) - 1;

    /// The project filter (`renderSpacesMenu`) as a native menu. Its rows' right-click
    /// menu (Rename… / Remove…) has no native equivalent: the drawn menu keeps it.
    fn popUpNativeSpaces(self: *Sidebar, trigger: zpui.Bounds(f32), window: *Window, cx: *Context(Sidebar)) bool {
        if (!ui.native_menu.enabled(cx)) return false;
        const prefs = prefs_mod.get(cx);
        const ws = self.state.read(cx).workspace.read(cx);
        const arena = zpui.window.arena_mod.frameAllocator();
        const spaces = ws.spacesSorted(arena) catch &.{};
        self.clearIds(&self.menu_space_ids);
        const items = arena.alloc(ui.native_menu.Item, spaces.len + 3) catch return false;
        items[0] = .{ .label = "All projects", .tag = native_all_projects, .icon = ui.native_menu.icon(.folder), .check = if (prefs.space_filter == null) .on else .off };
        var buf: [96]u8 = undefined;
        for (spaces, 0..) |s, i| {
            const dup = self.gpa.dupe(u8, s.id) catch return false;
            self.menu_space_ids.append(self.gpa, dup) catch {
                self.gpa.free(dup);
                return false;
            };
            const active = if (prefs.space_filter) |f| std.mem.eql(u8, f, s.id) else false;
            const tag, _ = ws.spaceDeviceTag(&buf, s, prefs.now(ws.io));
            items[i + 1] = .{ .label = zpui.fmt("{s}  {s}", .{ view.spaceDisplayName(s), tag }), .tag = @intCast(i), .check = if (active) .on else .off };
        }
        items[spaces.len + 1] = .separator;
        items[spaces.len + 2] = .{ .label = "New project\u{2026}", .tag = native_new_project, .icon = ui.native_menu.icon(.add_circle) };
        return ui.native_menu.popUpBelow(window, cx, trigger, items, cx.listener(Sidebar.onNativeSpaces));
    }

    fn onNativeSpaces(self: *Sidebar, sel: *const ui.native_menu.Selection, window: *Window, cx: *Context(Sidebar)) void {
        const tag = sel.tag orelse return;
        const ev: zpui.ClickEvent = .{ .keyboard = .{} };
        if (tag == native_new_project) return self.onNewProject(&ev, window, cx);
        const ix: usize = if (tag == native_all_projects) std.math.maxInt(usize) else tag;
        self.onPickSpace(ix, &ev, window, cx);
    }

    const native_create_section: u32 = 100;

    /// The view options (`renderViewMenu`) as a native menu: Organize / Sort / Show
    /// submenus with check marks, Compact, Create Section. Tags are `onToggleView`'s.
    fn popUpNativeView(self: *Sidebar, trigger: zpui.Bounds(f32), window: *Window, cx: *Context(Sidebar)) bool {
        _ = self;
        if (!ui.native_menu.enabled(cx)) return false;
        const prefs = prefs_mod.get(cx);
        const labels = [_][]const u8{ "By device", "By project", "None", "Last updated", "Created", "Branch", "Pull request", "Harness", "Project icon", "Location" };
        const icons = [_]icon.Icon{ .laptop, .folder, .list, .clock_circle, .calendar, .git_branch, .pull_request, .bot, .project_default, .folder };
        const selected = [_]bool{
            prefs.organization == .by_device, prefs.organization == .by_project, prefs.organization == .in_one_list,
            prefs.sort == .last_updated,      prefs.sort == .created,            prefs.show_branch,
            prefs.show_pull_request,          prefs.show_harness,                prefs.show_project_icon,
            prefs.show_project_label,
        };
        var rows: [10]ui.native_menu.Item = undefined;
        for (&rows, 0..) |*r, i| r.* = .{ .label = labels[i], .tag = @intCast(i), .icon = ui.native_menu.icon(icons[i]), .check = if (selected[i]) .on else .off };
        const items = [_]ui.native_menu.Item{
            .sub("Organize", rows[0..3]),
            .sub("Sort", rows[3..5]),
            .separator,
            .sub("Show", rows[5..10]),
            .separator,
            .{ .label = "Compact", .tag = 10, .check = if (prefs.sidebar_compact) .on else .off },
            .separator,
            .{ .label = "Create Section", .tag = native_create_section, .icon = ui.native_menu.icon(.plus) },
        };
        return ui.native_menu.popUpBelow(window, cx, trigger, &items, cx.listener(Sidebar.onNativeView));
    }

    fn onNativeView(self: *Sidebar, sel: *const ui.native_menu.Selection, window: *Window, cx: *Context(Sidebar)) void {
        const tag = sel.tag orelse return;
        const ev: zpui.ClickEvent = .{ .keyboard = .{} };
        if (tag == native_create_section) return self.onCreateSection(&ev, window, cx);
        self.onToggleView(@intCast(tag), &ev, window, cx);
    }

    // ---- [wiring] Rename / Copy ▸ / Delete… -------------------------------------------

    /// The inline notice under the lists (click dismisses).
    pub fn setNotice(self: *Sidebar, text: ?[]const u8, cx: *Context(Sidebar)) void {
        if (self.notice) |n| self.gpa.free(n);
        self.notice = if (text) |t| self.gpa.dupe(u8, t) catch null else null;
        cx.notify();
    }

    fn onNoticeClick(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.setNotice(null, cx);
    }

    fn onCtxRename(self: *Sidebar, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Sidebar)) void {
        const m = self.liveCtx() orelse return;
        self.shutCtx(cx);
        const id = self.rowId(m.ix) orelse return;
        const copy = self.gpa.dupe(u8, id) catch return;
        defer self.gpa.free(copy);
        self.beginRename(copy, window, cx);
    }

    /// `open_rename_chat`: edit `chat_id`'s title in place on its row,
    /// seeded with the current title (all selected). Enter or blur commits a
    /// changed, non-empty title (`renameChat`); Escape drops it.
    pub fn beginRename(self: *Sidebar, chat_id: []const u8, window: *Window, cx: *Context(Sidebar)) void {
        if (self.rename != null) self.finishRename(true, cx);
        const current = (self.state.read(cx).workspace.read(cx).chat(chat_id) orelse return).title orelse "";
        const theme = ui.theme.get(cx);
        const in = cx.newWith(TextInput, TextInput.init, .{input_mod.Options{
            .placeholder = "Session title",
            .key_context = "Composer",
            .single_line = true,
            .text_size = 13,
            .line_height = 17,
            .colors = .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
            .edge_fade = false,
        }}) catch return;
        in.update(cx, TextInput.setText, .{current});
        in.update(cx, TextInput.selectAllText, .{});
        const sub = cx.subscribe(in, onRenameEvent) catch {
            in.release(cx);
            return;
        };
        const owned = self.gpa.dupe(u8, chat_id) catch {
            var s2 = sub;
            s2.deinit();
            in.release(cx);
            return;
        };
        self.rename = .{ .chat_id = owned, .input = in, .sub = sub };
        const focus = in.read(cx).focusHandle();
        window.focus(focus);
        self.rename.?.blur = cx.onBlur(focus, window, onRenameBlur) catch null;
        cx.notify();
    }

    fn onRenameBlur(_: *Sidebar, _: *Window, cx: *Context(Sidebar)) void {
        cx.deferUpdate(struct {
            fn f(sb_: *Sidebar, c: *Context(Sidebar)) void {
                sb_.finishRename(true, c);
            }
        }.f);
    }

    fn onRenameEvent(self: *Sidebar, _: Entity(TextInput), ev: *const input_mod.TextInputEvent, cx: *Context(Sidebar)) void {
        switch (ev.*) {
            .submitted, .modified_submitted => self.finishRename(true, cx),
            .escape => self.finishRename(false, cx),
            else => {},
        }
    }

    fn dropRename(self: *Sidebar, app: *App) void {
        if (self.rename) |*r| {
            if (r.blur) |*b| b.deinit();
            r.sub.deinit();
            r.input.release(app);
            self.gpa.free(r.chat_id);
        }
        self.rename = null;
    }

    /// `finish_rename_chat`.
    pub fn finishRename(self: *Sidebar, commit: bool, cx: *Context(Sidebar)) void {
        const r = self.rename orelse return;
        const title = std.mem.trim(u8, r.input.read(cx).text(), " \t\r\n");
        const ws = self.state.read(cx).workspace;
        const unchanged = if (ws.read(cx).chat(r.chat_id)) |c| (if (c.title) |t| std.mem.eql(u8, t, title) else false) else true;
        if (commit and title.len > 0 and !unchanged) {
            const t = self.gpa.dupe(u8, title) catch null;
            defer if (t) |x| self.gpa.free(x);
            if (t) |owned| ws.update(cx, model.WorkspaceStore.mutate, .{engine.protocol.Mutate{ .renameChat = .{ .chatId = r.chat_id, .title = owned } }}) catch |err| {
                self.setNotice(if (err == error.NotConnected) "Engine not connected" else "Rename failed", cx);
            };
        }
        self.dropRename(cx.app);
        cx.notify();
    }

    fn onCtxCopyPage(self: *Sidebar, page: chat_menu.Page, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        cx.stopPropagation();
        self.ctx_page = page;
        cx.notify();
    }

    fn copyAndNotice(self: *Sidebar, text: []const u8, notice: []const u8, cx: *Context(Sidebar)) void {
        cx.app.platform.vtable.writeClipboard(cx.app.platform.ptr, text);
        self.setNotice(notice, cx);
    }

    /// Copy ▸ rows: 0 path, 1 Zeron conversation link, 2 harness link, 3 session id.
    fn onCtxCopy(self: *Sidebar, which: u8, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        const m = self.liveCtx() orelse return;
        self.shutCtx(cx);
        self.ctx_page = .root;
        const id = self.rowId(m.ix) orelse return;
        const st = self.state.read(cx);
        const ws = st.workspace.read(cx);
        const c = ws.chat(id) orelse return;
        switch (which) {
            0 => if (chat_menu.chatCopyPath(c)) |p| self.copyAndNotice(p, "Path copied", cx),
            1 => {
                var buf: [16]u8 = undefined;
                const auth = st.auth.read(cx).auth;
                if (chat_menu.workspaceLocator(&buf, ws.workspace_scope, auth, ws.local_device_id)) |loc| {
                    const link = chat_menu.zeronConversationLink(self.gpa, id, loc) catch return;
                    defer self.gpa.free(link);
                    self.copyAndNotice(link, "Zeron conversation link copied", cx);
                } else self.setNotice("Conversation link is not ready yet", cx);
            },
            2 => if (chat_menu.harnessConversationLink(self.gpa, c) catch null) |l| {
                defer self.gpa.free(l.url);
                self.copyAndNotice(l.url, zpui.fmt("{s} copied", .{l.label}), cx);
            },
            else => if (chat_menu.harnessSessionId(c)) |sid| self.copyAndNotice(sid, "Harness session ID copied", cx),
        }
        cx.notify();
    }

    fn onCtxDelete(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        const m = self.liveCtx() orelse return;
        self.shutCtx(cx);
        const id = self.rowId(m.ix) orelse return;
        cx.emit(DeleteChat{ .chat_id = id });
        cx.notify();
    }

    /// The row's title, or its inline rename field.
    fn titleCell(self: *Sidebar, r: *const RowData) zpui.Div {
        const cell = div().flex1().minW0().flex().textSize(rems(13)).lineHeight(px(17));
        if (self.rename) |rn| if (std.mem.eql(u8, rn.chat_id, r.chat.id)) return cell.child(rn.input);
        return cell.child(ui.effects.fadedText(r.title, .{ .fill = true }));
    }

    fn onCtxPin(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        const m = self.liveCtx() orelse return;
        self.shutCtx(cx);
        const id = self.rowId(m.ix) orelse return;
        const pin = !prefs_mod.get(cx).isPinned(id);
        const copy = self.gpa.dupe(u8, id) catch return;
        defer self.gpa.free(copy);
        sections_ui.setChatPinned(self, copy, pin, cx);
        cx.notify();
    }

    fn onCtxArchive(self: *Sidebar, e: *const zpui.ClickEvent, w: *Window, cx: *Context(Sidebar)) void {
        const m = self.liveCtx() orelse return;
        self.shutCtx(cx);
        self.onArchiveClick(m.ix, e, w, cx);
    }

    fn onCtxDismiss(self: *Sidebar, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(Sidebar)) void {
        if (self.liveCtx() != null) {
            self.shutCtx(cx);
            cx.notify();
        }
    }

    // ---- [motion] popup closing phases -------------------------------------------------

    fn exitNow(self: *Sidebar, exit: *ui.popover.Exit, cx: *Context(Sidebar)) bool {
        if (self.sec.reduced) return false;
        if (exit.begin(cx.app.executor.now())) ui.popover.reap(Sidebar, cx);
        return true;
    }

    /// Close a boolean menu, playing its exit (MENU_OUT) unless reduced.
    pub fn shutMenu(self: *Sidebar, open: *bool, exit: *ui.popover.Exit, cx: *Context(Sidebar)) void {
        if (!open.*) return;
        open.* = false;
        if (!self.exitNow(exit, cx)) exit.clear();
    }

    fn toggleMenu(self: *Sidebar, open: *bool, exit: *ui.popover.Exit, cx: *Context(Sidebar)) void {
        if (open.*) return self.shutMenu(open, exit, cx);
        open.* = true;
        exit.clear();
    }

    /// The context menu only while genuinely open (`Popup::as_open`).
    fn liveCtx(self: *const Sidebar) @TypeOf(self.ctx_menu) {
        return if (self.ctx_exit.isClosing()) null else self.ctx_menu;
    }

    fn shutCtx(self: *Sidebar, cx: *Context(Sidebar)) void {
        if (self.ctx_menu == null or self.ctx_exit.isClosing()) return;
        if (!self.exitNow(&self.ctx_exit, cx)) self.ctx_menu = null;
    }

    /// Drop a finished exit (`finish_close`) and return the exit progress
    /// for this frame (null while open).
    fn menuExit(open: bool, exit: *ui.popover.Exit, now: u64) ?f32 {
        if (open) {
            exit.clear();
            return null;
        }
        if (exit.done(now)) exit.clear();
        return exit.progress(now);
    }

    fn renderContextMenu(self: *Sidebar, theme_in: *const Theme, cx: *Context(Sidebar)) ?zpui.AnyElement {
        if (self.ctx_exit.done(cx.app.executor.now())) {
            self.ctx_exit.clear();
            self.ctx_menu = null;
        }
        const ctx_exit = self.ctx_exit.progress(cx.app.executor.now());
        const m = self.ctx_menu orelse return null;
        if (self.ctx_native) return null;
        const id = self.rowId(m.ix) orelse return null;
        const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
        const pinned = prefs_mod.get(cx).isPinned(id);
        var card = ui.popover.card(theme).w(px(216)).onMouseDownOut(cx.listener(Sidebar.onCtxDismiss));
        if (self.ctx_page == .copy) {
            const c = self.state.read(cx).workspace.read(cx).chat(id);
            card = card.child(ui.popover.menuRow(theme, false).id("chat-copy-back").role(.menu_item).onClick(cx.listenerWith(chat_menu.Page.root, Sidebar.onCtxCopyPage))
                .child(icon.of(.alt_arrow_left, 16, theme.text_muted)).child("Back"))
                .child(ui.popover.separator(theme));
            if (c != null and chat_menu.chatCopyPath(c.?) != null) card = card.child(ui.popover.menuRow(theme, false).id("chat-copy-path").role(.menu_item).onClick(cx.listenerWith(@as(u8, 0), Sidebar.onCtxCopy))
                .child(icon.of(.copy, 16, theme.text_muted)).child("Path"));
            card = card.child(ui.popover.menuRow(theme, false).id("chat-copy-zeron").role(.menu_item).onClick(cx.listenerWith(@as(u8, 1), Sidebar.onCtxCopy))
                .child(icon.of(.copy, 16, theme.text_muted)).child("Zeron conversation link"));
            if (c) |chat| if (chat.config) |cfg| if (cfg.harness == .codex and chat_menu.harnessSessionId(chat) != null) {
                card = card.child(ui.popover.menuRow(theme, false).id("chat-copy-harness").role(.menu_item).onClick(cx.listenerWith(@as(u8, 2), Sidebar.onCtxCopy))
                    .child(icon.of(.copy, 16, theme.text_muted)).child("Codex conversation link"));
            };
            if (c != null and chat_menu.harnessSessionId(c.?) != null) card = card.child(ui.popover.menuRow(theme, false).id("chat-copy-session").role(.menu_item).onClick(cx.listenerWith(@as(u8, 3), Sidebar.onCtxCopy))
                .child(icon.of(.copy, 16, theme.text_muted)).child("Harness session ID"));
            return ui.popover.anchoredAtExit(m.pos, card, ctx_exit);
        }
        card = card
            .child(ui.popover.menuRow(theme, false).id("chat-menu-rename").role(.menu_item).onClick(cx.listener(Sidebar.onCtxRename))
                .child(icon.of(.pen, 16, theme.text_muted)).child("Rename"))
            .child(ui.popover.menuRow(theme, false).id("chat-menu-pin").role(.menu_item).onClick(cx.listener(Sidebar.onCtxPin))
                .child(icon.of(.pin, 16, theme.text_muted)).child(if (pinned) "Unpin" else "Pin"))
            .child(ui.popover.menuRow(theme, false).id("chat-menu-archive").role(.menu_item).onClick(cx.listener(Sidebar.onCtxArchive))
                .child(icon.of(.archive_minimalistic, 16, theme.text_muted)).child("Archive"))
            .child(ui.popover.menuRow(theme, false).id("chat-menu-copy").role(.menu_item).onClick(cx.listenerWith(chat_menu.Page.copy, Sidebar.onCtxCopyPage))
                .child(icon.of(.copy, 16, theme.text_muted)).child(div().flex1().child("Copy"))
                .child(icon.of(.alt_arrow_right, 14, theme.text_muted)))
            .child(ui.popover.separator(theme))
            .child(ui.popover.menuRow(theme, false).id("chat-menu-delete").role(.menu_item).textColor(theme.danger).onClick(cx.listener(Sidebar.onCtxDelete))
                .child(icon.of(.trash_bin_minimalistic, 16, theme.danger)).child("Delete…"));
        return ui.popover.anchoredAtExit(m.pos, card, ctx_exit);
    }

    /// [wiring] `sidebar-notice`: the inline mutation / copy notice.
    fn renderNotice(self: *Sidebar, theme: *const Theme, cx: *Context(Sidebar)) ?zpui.StatefulDiv {
        const n = self.notice orelse return null;
        return div().id("sidebar-notice").role(.button).mx(px(zt.layout.space_sm)).mb(px(zt.layout.space_sm)).px(px(zt.layout.space_sm)).py(px(4))
            .rounded(px(zt.layout.control_radius)).border1().borderColor(theme.danger)
            .textSize(rems(11)).textColor(theme.danger).cursorPointer()
            .onClick(cx.listener(Sidebar.onNoticeClick))
            .child(n);
    }

    fn onArchiveClick(self: *Sidebar, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        cx.stopPropagation();
        const id = self.rowId(ix) orelse return;
        const s = self.state.read(cx);
        const ws = s.workspace.read(cx);
        const c = ws.chat(id) orelse return;
        setChatArchived(s.workspace, id, !c.archived, cx);
        self.hovered = null;
        cx.notify();
    }

    /// `set_chat_archived`: flip the local row at once, then `setChatArchived`.
    pub fn setChatArchived(ws_e: Entity(model.WorkspaceStore), chat_id: []const u8, archived: bool, cx: anytype) void {
        ws_e.update(cx, struct {
            fn f(w: *model.WorkspaceStore, id: []const u8, value: bool, c2: *Context(model.WorkspaceStore)) void {
                if (w.chatsArena() == null) return;
                for (w.chats()) |*ch| if (std.mem.eql(u8, ch.id, id)) {
                    @constCast(ch).archived = value;
                };
                w.mutate(.{ .setChatArchived = .{ .chatId = id, .archived = value } }, c2) catch {};
                c2.emit(model.workspace.ChatsChanged{});
                c2.notify();
            }
        }.f, .{ chat_id, archived });
    }

    fn toggleSection(self: *Sidebar, which: u8, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        // [motion] `begin_sidebar_disclosure_motion`: the body tweens (COLLAPSE).
        const was_open = switch (which) {
            0 => self.pinned_open,
            1 => self.sessions_open,
            else => self.archived_open,
        };
        sections_ui.toggleMotion(self, disclosureId(which), was_open, cx);
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

    fn onUserMenu(self: *Sidebar, ev: *const zpui.ClickEvent, window: *Window, cx: *Context(Sidebar)) void {
        if (!self.user_menu_open and self.popUpNativeUser(ev.targetBounds(), window, cx)) return cx.notify();
        self.toggleMenu(&self.user_menu_open, &self.user_menu_exit, cx);
        cx.notify();
    }

    fn onCloseMenus(self: *Sidebar, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(Sidebar)) void {
        if (self.user_menu_open or self.spaces_menu_open or self.view_menu_open) {
            self.shutMenu(&self.user_menu_open, &self.user_menu_exit, cx);
            self.shutMenu(&self.spaces_menu_open, &self.spaces_menu_exit, cx);
            self.shutMenu(&self.view_menu_open, &self.view_menu_exit, cx);
            cx.notify();
        }
    }

    fn onSettings(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.shutMenu(&self.user_menu_open, &self.user_menu_exit, cx);
        cx.emit(OpenSettings{});
        cx.notify();
    }

    fn onEnableSync(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.shutMenu(&self.user_menu_open, &self.user_menu_exit, cx);
        cx.emit(EnableSync{});
        cx.notify();
    }

    fn onSignOut(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.shutMenu(&self.user_menu_open, &self.user_menu_exit, cx);
        cx.emit(SignOut{});
        cx.notify();
    }

    fn onSpacesTrigger(self: *Sidebar, ev: *const zpui.ClickEvent, window: *Window, cx: *Context(Sidebar)) void {
        if (!self.spaces_menu_open and self.popUpNativeSpaces(ev.targetBounds(), window, cx)) {
            self.shutMenu(&self.view_menu_open, &self.view_menu_exit, cx);
            return cx.notify();
        }
        self.toggleMenu(&self.spaces_menu_open, &self.spaces_menu_exit, cx);
        self.shutMenu(&self.view_menu_open, &self.view_menu_exit, cx);
        cx.notify();
    }

    fn onViewTrigger(self: *Sidebar, ev: *const zpui.ClickEvent, window: *Window, cx: *Context(Sidebar)) void {
        if (!self.view_menu_open and self.popUpNativeView(ev.targetBounds(), window, cx)) {
            self.view_submenu = null;
            self.shutMenu(&self.spaces_menu_open, &self.spaces_menu_exit, cx);
            return cx.notify();
        }
        self.toggleMenu(&self.view_menu_open, &self.view_menu_exit, cx);
        self.view_submenu = null;
        self.shutMenu(&self.spaces_menu_open, &self.spaces_menu_exit, cx);
        cx.notify();
    }

    fn onPickSpace(self: *Sidebar, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        const p = prefs_mod.mut(cx);
        if (ix == std.math.maxInt(usize)) p.setFilter(null) else if (ix < self.menu_space_ids.items.len) p.setFilter(self.menu_space_ids.items[ix]);
        self.shutMenu(&self.spaces_menu_open, &self.spaces_menu_exit, cx);
        cx.notify();
    }

    fn onNewProject(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.shutMenu(&self.spaces_menu_open, &self.spaces_menu_exit, cx);
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

    /// The native Compact switch (macOS) reports its new state.
    fn onNativeCompact(_: *Sidebar, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Context(Sidebar)) void {
        const p = prefs_mod.mut(cx);
        if (p.sidebar_compact == ev.on) return;
        p.sidebar_compact = ev.on;
        cx.notify();
    }

    fn onCreateSection(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        sections_ui.openDialog(self, null, cx);
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
        const space = ws.spaceForChat(c);
        // The artwork and monogram are shared by every checkout of a project.
        const rep_space = if (space) |s| ws.representativeSpace(s) else null;
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
            .project_name = if (rep_space) |s| view.spaceDisplayName(s) else "Home",
            .project_seed = if (rep_space) |s| s.path else "home",
            .space_path = if (space) |s| localCheckoutPath(ws, s) else null,
            .branch = branch,
            .pr = if (prefs.show_pull_request) (prefs.pullRequest(c.id) orelse if (self.livePr(c)) |pr| pr.number else null) else null,
            .time_ago = ago,
            .remote = remote,
            .selected = if (selected_id) |s| std.mem.eql(u8, s, c.id) else false,
            .archived = c.archived,
        };
    }

    /// This device's checkout of `s`'s project (artwork is read locally).
    fn localCheckoutPath(ws: *const model.WorkspaceStore, s: *const engine.protocol.Space) ?[]const u8 {
        const local = ws.local_device_id orelse return null;
        if (std.mem.eql(u8, s.deviceId, local)) return s.path;
        for (ws.spaces()) |*m| if (std.mem.eql(u8, m.deviceId, local) and view.sameProject(m, s)) return m.path;
        return null;
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
        self.sec.reduced = window.prefersReducedMotion();
        const now_ns = cx.app.executor.now();
        const arena = zpui.window.arena_mod.frameAllocator();
        self.prs = app_state.change_requests.read(cx); // [pr-status]

        self.clearIds(&self.row_ids);
        // A release outside the sidebar ends the drag without a drop: heal.
        sections_ui.heal(self, cx);
        if (self.pin_drag != null and !cx.app.hasActiveDrag()) self.pin_drag = null;
        sections_ui.migrate(self, cx);
        const secs = sections_ui.active(self, arena, cx);
        // Pins follow the account (synced snapshot + queued writes) or this
        // device's settings for a local workspace (`active_sidebar_pins`).
        sections_ui.syncPins(self, secs, cx);
        sections_ui.beginFrame(self, secs);
        const transfer = sections_ui.transferActive(self);
        self.moving = null;

        // Active rows: sidebar order; section members, then pins, then the rest.
        const active: []view.ActiveRow = ws.sidebarChats(arena, now, prefs.space_filter) catch arena.alloc(view.ActiveRow, 0) catch unreachable;
        std.sort.block(view.ActiveRow, active, prefs.sort, struct {
            fn lt(sort: prefs_mod.Sort, a: view.ActiveRow, b: view.ActiveRow) bool {
                return lessThan(sort, a.chat, b.chat);
            }
        }.lt);
        var pinned: std.ArrayList(RowData) = .empty;
        var regular: std.ArrayList(RowData) = .empty;
        const section_rows: []std.ArrayList(RowData) = arena.alloc(std.ArrayList(RowData), secs.len) catch &.{};
        for (section_rows) |*l| l.* = .empty;
        for (active) |r| {
            const d = self.buildRow(ws, r.chat, r.status, now, prefs, ws.selected_chat);
            if (sections.sectionOf(secs, r.chat.id)) |si| {
                if (si < section_rows.len) section_rows[si].append(arena, d) catch {};
            } else if (prefs.isPinned(r.chat.id)) pinned.append(arena, d) catch {} else regular.append(arena, d) catch {};
        }
        std.sort.block(RowData, pinned.items, prefs, struct {
            fn lt(p: *const prefs_mod.Prefs, a: RowData, b: RowData) bool {
                return (p.pinIndex(a.chat.id) orelse 0) < (p.pinIndex(b.chat.id) orelse 0);
            }
        }.lt);
        var sectioned: usize = 0;
        for (section_rows) |l| sectioned += l.items.len;

        // Archived shelf.
        var archived: std.ArrayList(RowData) = .empty;
        for (ws.chats()) |*c| {
            if (!c.archived or !c.isTopLevel()) continue;
            if (prefs.space_filter) |f| if (!ws.projectFilterMatches(f, c)) continue;
            archived.append(arena, self.buildRow(ws, c, ws.displayStatusFor(c, now), now, prefs, ws.selected_chat)) catch {};
        }
        std.sort.block(RowData, archived.items, prefs.sort, struct {
            fn lt(sort: prefs_mod.Sort, a: RowData, b: RowData) bool {
                return lessThan(sort, a.chat, b.chat);
            }
        }.lt);

        // [motion] The keyed order this frame (`sidebar_prev_order`): rows
        // of open groups plus header slots, for the resort glide. Drags own
        // the movement while they run.
        if (!transfer and self.pin_drag == null) {
            var order: std.ArrayList(ResortItem) = .empty;
            const rh = struct {
                fn f(p: *const prefs_mod.Prefs, r: *const RowData) f32 {
                    return rowHeight(p.sidebar_compact, p.show_project_label, r.branch != null, r.pr != null);
                }
            }.f;
            if (pinned.items.len > 0) {
                order.append(arena, .{ .key = "\x00pinned", .height = disclosure_header_height }) catch {};
                if (self.pinned_open) for (pinned.items) |*r| order.append(arena, .{ .key = r.chat.id, .height = rh(prefs, r) }) catch {};
            }
            for (secs, 0..) |sec, si| {
                order.append(arena, .{ .key = zpui.fmt("\x00section:{s}", .{sec.id}), .height = disclosure_header_height + 12 }) catch {};
                if (!sec.collapsed and si < section_rows.len) for (section_rows[si].items) |*r| order.append(arena, .{ .key = r.chat.id, .height = rh(prefs, r) }) catch {};
            }
            if (regular.items.len > 0) {
                order.append(arena, .{ .key = "\x00sessions", .height = disclosure_header_height + section_gap }) catch {};
                const grouped = prefs.organization != .in_one_list;
                if (grouped or self.sessions_open) for (regular.items) |*r| {
                    if (grouped) {
                        const key: []const u8 = if (prefs.organization == .by_device) r.chat.deviceId else projectGroup(ws, r.chat).key;
                        if (self.isCollapsed(key)) continue;
                    }
                    order.append(arena, .{ .key = r.chat.id, .height = rh(prefs, r) }) catch {};
                };
            }
            self.updateResort(order.items);
        }

        var any_working = false;
        var list = div().flex().flexCol().gap(px(list_gap)).pb(px(zt.layout.space_sm));
        const show_pinned = pinned.items.len > 0 or transfer;
        if (pinned.items.len + regular.items.len + sectioned == 0 and secs.len == 0 and !transfer) {
            list = div().px(px(8)).pb(px(8)).textSize(rems(12)).textColor(theme.text_faint).child("No sessions yet");
        } else {
            self.pin_slots.clearRetainingCapacity();
            self.pinned_count = 0;
            if (show_pinned) {
                var body = div().id("sidebar-pinned").flex().flexCol().gap(px(list_gap)).pt(px(disclosure_body_inset))
                    .onDragMove(SessionDrag, cx.listener(Sidebar.onPinDragMove))
                    .onDrop(SessionDrag, cx.listener(Sidebar.onPinDrop));
                if (pinned.items.len == 0) body = body.minH(px(if (self.pin_drag) |d| d.slot else 32));
                var pinned_h: f32 = disclosure_body_inset;
                for (pinned.items, 0..) |*r, pi| {
                    any_working = any_working or r.status == .working;
                    const h = rowHeight(prefs.sidebar_compact, prefs.show_project_label, r.branch != null, r.pr != null);
                    pinned_h += h + (if (pi > 0) list_gap else 0);
                    self.pin_slots.append(self.gpa, h + list_gap) catch {};
                    const row = self.activeRow(r, h, pi, theme, prefs, cx).onDrop(SessionDrag, cx.listener(Sidebar.onPinDrop));
                    if (sections_ui.isMoving(self, r.chat.id)) {
                        body = body.child(sections_ui.sourceSlot(self, h, if (pinned.items.len > 1) list_gap else 0));
                        continue;
                    }
                    if (self.pin_drag) |d| {
                        const slot = if (d.from < pinned.items.len) blk: {
                            const dragged = &pinned.items[d.from];
                            break :blk rowHeight(prefs.sidebar_compact, prefs.show_project_label, dragged.branch != null, dragged.pr != null) + list_gap;
                        } else d.slot;
                        const target = slideOffsetY(pi, d.from, d.over) * slot;
                        const start = slideOffsetY(pi, d.from, d.prev_over) * slot;
                        const Slide = struct {
                            fn f(c: [2]f32, el: zpui.StatefulDiv, t: f32) zpui.StatefulDiv {
                                return el.relative().top(px(c[0] + (c[1] - c[0]) * t));
                            }
                        };
                        body = body.child(zpui.withAnimationCtx(row, .{ "pin-slide", (pi & 0xffff) | (d.epoch << 16) }, zt.motion.tab_slide.animation(), [2]f32{ start, target }, Slide.f));
                        continue;
                    }
                    body = body.child(self.resortRow(r.chat.id, zpui.intoAnyElement(row)));
                }
                // A joining row grows the list by one slot.
                if (self.pin_drag) |d| if (d.from >= pinned.items.len and pinned.items.len > 0) {
                    body = body.child(div().h(px(d.slot - list_gap)).flexNone());
                };
                self.pinned_count = pinned.items.len;
                sections_ui.noteHeight(self, "pinned", pinned_h);
                const pinned_tween = sections_ui.disclosureAnimating(self, "pinned", now_ns);
                list = list.child(div().flex().flexCol()
                    .child(self.sectionHeader(0, if (self.pinned_open) "Pinned" else zpui.fmt("Pinned ({d})", .{pinned.items.len}), self.pinned_open, theme, cx))
                    .child(if (self.pinned_open or transfer or pinned_tween) sections_ui.disclosureBody(self, "pinned", pinned_h, body, now_ns) else null));
            }
            // Custom sections (account-synced), between Pinned and Sessions.
            for (secs, 0..) |sec, si| {
                var body = div().flex().flexCol().gap(px(list_gap));
                const rows = if (si < section_rows.len) section_rows[si].items else &.{};
                // A collapsing section keeps its rows until the height tween ends.
                const show_rows = !sec.collapsed or sections_ui.sectionAnimating(self, sec.id, cx.app.executor.now());
                var rows_height: f32 = 0;
                for (rows, 0..) |*r, ri| {
                    rows_height += rowHeight(prefs.sidebar_compact, prefs.show_project_label, r.branch != null, r.pr != null) + (if (ri > 0) list_gap else 0);
                    if (!show_rows) continue;
                    any_working = any_working or r.status == .working;
                    body = body.child(self.placedRow(r, rows.len > 1, .{ .target = .{ .section = si }, .index = @intCast(ri) }, theme, prefs, cx));
                }
                const extra = sections_ui.extraHeight(self, .{ .section = si });
                list = list.child(sections_ui.renderSection(self, si, sec, body, rows.len == 0, rows_height, sections_ui.extraGap(self, .{ .section = si }), if (extra > 0) extra + list_gap else 0, theme, cx));
            }
            const follows = show_pinned or secs.len > 0;
            if (regular.items.len > 0 and prefs.organization != .in_one_list) {
                list = list.child(self.dropRegion(self.renderGroups(regular.items, follows, ws, theme, prefs, cx, &any_working), cx));
            } else if (regular.items.len > 0 or transfer) {
                var body = div().flex().flexCol().gap(px(list_gap)).pt(px(disclosure_body_inset));
                if (regular.items.len == 0) body = body.child(div().h(px(48)).flex().itemsCenter().px(px(10))
                    .textColor(theme.text_muted).textSize(rems(12)).child("Drop here to unpin"));
                var sessions_h: f32 = disclosure_body_inset + (if (regular.items.len == 0) @as(f32, 48) else 0);
                for (regular.items, 0..) |*r, ri| {
                    any_working = any_working or r.status == .working;
                    sessions_h += rowHeight(prefs.sidebar_compact, prefs.show_project_label, r.branch != null, r.pr != null) + (if (ri > 0) list_gap else 0);
                    body = body.child(self.placedRow(r, regular.items.len > 1, .{ .target = .regular, .index = @intCast(ri) }, theme, prefs, cx));
                }
                body = body.child(sections_ui.extraGap(self, .regular));
                sections_ui.noteHeight(self, "sessions", sessions_h);
                const sessions_tween = sections_ui.disclosureAnimating(self, "sessions", now_ns);
                list = list.child(self.dropRegion(div().flex().flexCol().pt(px(if (follows) section_gap else 0))
                    .child(self.sectionHeader(1, if (self.sessions_open) "Sessions" else zpui.fmt("Sessions ({d})", .{regular.items.len}), self.sessions_open, theme, cx))
                    .child(if (self.sessions_open or transfer or sessions_tween) sections_ui.disclosureBody(self, "sessions", sessions_h, body, now_ns) else null), cx));
            }
        }

        var archived_section: ?zpui.Div = null;
        if (archived.items.len > 0) {
            var sec = div().flex().flexCol()
                .child(self.sectionHeader(2, if (self.archived_open) "Archived" else zpui.fmt("Archived ({d})", .{archived.items.len}), self.archived_open, theme, cx));
            const archived_tween = sections_ui.disclosureAnimating(self, "archived", now_ns);
            if (self.archived_open or archived_tween) {
                var body = div().flex().flexCol().gap(px(list_gap)).pt(px(disclosure_body_inset));
                var archived_h: f32 = disclosure_body_inset;
                for (archived.items, 0..) |*r, i| {
                    if (i >= self.archived_shown) break;
                    archived_h += rowHeight(prefs.sidebar_compact, prefs.show_project_label, r.branch != null, r.pr != null) + (if (i > 0) list_gap else 0);
                    body = body.child(self.renderRow(r, theme, prefs, cx));
                }
                if (archived.items.len > self.archived_shown) archived_h += list_gap + @as(f32, if (prefs.sidebar_compact) 29 else 36);
                if (archived.items.len > self.archived_shown) {
                    body = body.child(div().id("archived-more").role(.button).h(px(if (prefs.sidebar_compact) 29 else 36))
                        .flex().itemsCenter().px(px(8)).rounded(px(8)).cursorPointer()
                        .textSize(rems(12)).textColor(theme.text_muted.opacity(0.7))
                        .hover(sb.bg(theme.glassHover()).textColor(theme.text))
                        .onClick(cx.listener(Sidebar.onShowMoreArchived))
                        .child("Show more"));
                }
                sections_ui.noteHeight(self, "archived", archived_h);
                sec = sec.child(sections_ui.disclosureBody(self, "archived", archived_h, body, now_ns));
            }
            archived_section = sec;
        }

        if (any_working or transfer) window.requestAnimationFrame();

        const moving: ?zpui.AnyElement = if (self.moving) |m| sections_ui.renderMoving(self, m.row, m.height, theme) else null;
        const lists = ui.effects.edgeFaded(
            div().relative().flex1().minH0().child(
                div().id("sidebar-lists").relative().sizeFull().overflowYScroll().trackScroll(self.scroll)
                    .px(px(zt.layout.space_sm)).flex().flexCol().pt(px(4))
                    .onDragMove(SessionDrag, cx.listener(sections_ui.onListDragMove))
                    // Empty space and Archived are not transfer targets.
                    .onDrop(SessionDrag, cx.listener(Sidebar.onListDrop))
                    .child(list)
                    .child(archived_section)
                    .child(moving),
            ),
            .{ .band = fade_band, .top = true, .bottom = true, .scroll = self.scroll },
        );

        return div()
            .wFull().hFull().flex().flexCol()
            .fontFamily(theme.font_sans)
            .child(self.renderFilterRow(theme, prefs, ws, now, cx))
            .child(lists)
            .child(self.renderStarBanner(theme, cx))
            .child(self.renderUpdateStrip(theme, cx))
            .child(self.renderNotice(theme, cx))
            .child(self.renderSpaceMenu(theme, cx))
            .child(div().p(px(zt.layout.space_sm)).flexNone().child(self.renderFooter(theme, cx)))
            .child(self.renderContextMenu(theme, cx))
            .child(sections_ui.renderMenu(self, theme, cx))
            .child(sections_ui.renderDialog(self, window, theme, cx));
    }

    fn onListDrop(self: *Sidebar, _: *const SessionDrag, _: *Window, cx: *Context(Sidebar)) void {
        sections_ui.cancelTransfer(self, cx);
    }

    /// The Sessions group (or the project/device accordions) as a drop target.
    fn dropRegion(self: *Sidebar, el: zpui.Div, cx: *Context(Sidebar)) zpui.StatefulDiv {
        _ = self;
        return el.id("sidebar-regular-sessions")
            .onDragMove(SessionDrag, cx.listenerWith(@as(sections_ui.Target, .regular), sections_ui.onGroupDragMove))
            .onDrop(SessionDrag, cx.listenerWith(@as(sections_ui.Target, .regular), sections_ui.onGroupDrop));
    }

    // ---- [motion] resort glide ----------------------------------------------------------

    fn clearResortMaps(self: *Sidebar) void {
        var it = self.resort_offsets.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.resort_offsets.clearRetainingCapacity();
        var nit = self.resort_new.keyIterator();
        while (nit.next()) |k| self.gpa.free(k.*);
        self.resort_new.clearRetainingCapacity();
    }

    fn clearResort(self: *Sidebar) void {
        self.clearResortMaps();
        for (self.resort_prev.items) |it| self.gpa.free(it.key);
        self.resort_prev.clearRetainingCapacity();
    }

    /// The keyed order changed (not just heights): FLIP every surviving row
    /// from its old y and fade in rows that are new (`render_chat_sidebar`).
    fn updateResort(self: *Sidebar, order: []const ResortItem) void {
        if (resortSame(self.resort_prev.items, order)) return;
        const key_order_changed = keyOrderChanged(self.resort_prev.items, order);
        if (self.resort_prev.items.len > 0 and key_order_changed) {
            const a = zpui.window.arena_mod.frameAllocator();
            const offsets = resortOffsets(a, self.resort_prev.items, order, list_gap) catch return;
            var any_new = false;
            for (order) |o| {
                if (!containsKey(self.resort_prev.items, o.key)) any_new = true;
            }
            if (offsets.len > 0 or any_new) {
                self.clearResortMaps();
                self.resort_epoch +%= 1;
                for (offsets) |o| {
                    const k = self.gpa.dupe(u8, o.key) catch continue;
                    self.resort_offsets.put(self.gpa, k, o.height) catch self.gpa.free(k);
                }
                for (order) |o| if (!containsKey(self.resort_prev.items, o.key) and !std.mem.startsWith(u8, o.key, "\x00")) {
                    const k = self.gpa.dupe(u8, o.key) catch continue;
                    self.resort_new.put(self.gpa, k, {}) catch self.gpa.free(k);
                };
            }
        }
        for (self.resort_prev.items) |it| self.gpa.free(it.key);
        self.resort_prev.clearRetainingCapacity();
        for (order) |o| {
            const k = self.gpa.dupe(u8, o.key) catch continue;
            self.resort_prev.append(self.gpa, .{ .key = k, .height = o.height }) catch self.gpa.free(k);
        }
    }

    /// RESORT glide (`resort-{epoch}-{key}`: top dy → 0) or a FADE_QUICK
    /// entrance (`row-in-{epoch}-{key}`) for a row placed in the list.
    fn resortRow(self: *const Sidebar, key: []const u8, row: zpui.AnyElement) zpui.AnyElement {
        const id_hash = std.hash.Wyhash.hash(self.resort_epoch, key);
        if (self.resort_offsets.get(key)) |dy| {
            const Glide = struct {
                fn f(d: f32, el: zpui.Div, t: f32) zpui.Div {
                    return el.relative().top(px(d * (1 - t)));
                }
            };
            return zpui.intoAnyElement(zpui.withAnimationCtx(div().child(row), .{ "resort", id_hash }, resort_spec.animation(), dy, Glide.f));
        }
        if (self.resort_new.contains(key)) {
            const Fade = struct {
                fn f(el: zpui.Div, t: f32) zpui.Div {
                    return el.opacity(t);
                }
            };
            return zpui.intoAnyElement(zpui.withAnimation(div().child(row), .{ "row-in", id_hash }, zt.motion.fade_quick.animation(), Fade.f));
        }
        return row;
    }

    /// An active (draggable) row: rendered in place, or — while it moves —
    /// an empty slot here and the row in the movement layer.
    /// `multi`: the row shares its group with others (a collapsing source
    /// slot also gives back its list gap).
    fn placedRow(self: *Sidebar, r: *const RowData, multi: bool, slot: sections_ui.Slot, theme: *const Theme, prefs: *const prefs_mod.Prefs, cx: *Context(Sidebar)) zpui.AnyElement {
        const h = rowHeight(prefs.sidebar_compact, prefs.show_project_label, r.branch != null, r.pr != null);
        const row = self.activeRow(r, h, null, theme, prefs, cx);
        if (sections_ui.isMoving(self, r.chat.id)) {
            sections_ui.noteSource(self, slot);
            return sections_ui.sourceSlot(self, h, if (multi) list_gap else 0);
        }
        // Destination siblings slide apart around the insertion point.
        return sections_ui.placeRow(self, self.resortRow(r.chat.id, zpui.intoAnyElement(row)), slot, cx);
    }

    /// `renderRow` + the session drag (`SidebarSessionDrag`); stashes the
    /// moving row for the movement layer.
    fn activeRow(self: *Sidebar, r: *const RowData, h: f32, pinned_ix: ?usize, theme: *const Theme, prefs: *const prefs_mod.Prefs, cx: *Context(Sidebar)) zpui.StatefulDiv {
        var drag: SessionDrag = .{ .ix = self.row_ids.items.len, .pinned_from = pinned_ix, .height = h };
        const n: u8 = @intCast(@min(r.title.len, drag.title_buf.len));
        @memcpy(drag.title_buf[0..n], r.title[0..n]);
        drag.title_len = n;
        const row = self.renderRow(r, theme, prefs, cx).onDrag(drag, sections_ui.buildGhost);
        if (sections_ui.isMoving(self, r.chat.id)) self.moving = .{ .row = zpui.intoAnyElement(row), .height = h };
        return row;
    }

    /// Project / device accordions (`SidebarOrganization::ByProject/ByDevice`):
    /// groups in recency order, this machine's device group first.
    fn renderGroups(self: *Sidebar, rows: []RowData, follows: bool, ws: *const model.WorkspaceStore, theme: *const Theme, prefs: *const prefs_mod.Prefs, cx: *Context(Sidebar), any_working: *bool) zpui.Div {
        const arena = zpui.window.arena_mod.frameAllocator();
        const Group = struct { key: []const u8, label: []const u8, rows: std.ArrayList(*const RowData) = .empty };
        var groups: std.ArrayList(Group) = .empty;
        for (rows) |*r| {
            const by_device = prefs.organization == .by_device;
            const pg = if (by_device) null else projectGroup(ws, r.chat);
            const key: []const u8 = if (pg) |g| g.key else r.chat.deviceId;
            const label: []const u8 = if (pg) |g| g.label else (ws.deviceName(r.chat.deviceId) orelse "Unknown device");
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
            // A project group wears the project icon on its header instead of
            // repeating it on every row.
            const project_group = prefs.organization == .by_project;
            if (project_group) for (g.rows.items) |r| {
                @constCast(r).project_icon = false;
            };
            const group_icon: ?zpui.Div = if (project_group and prefs.show_project_icon and g.rows.items.len > 0) blk: {
                var lead = g.rows.items[0].*;
                lead.selected = false;
                break :blk div().size(px(harness_icon_size)).flexNone().child(self.projectTile(&lead, theme, cx));
            } else null;
            const header = div().id(.{ "sidebar-group", gi }).role(.button).ariaLabel(g.label).ariaExpanded(open)
                .flex().flexRow().itemsCenter().gap(px(8)).h(px(disclosure_header_height)).px(px(zt.layout.space_sm)).cursorPointer()
                .onClick(cx.listenerWith(gi, Sidebar.toggleGroup))
                .child(group_icon)
                .child(div().minW0().flex().textSize(rems(12)).fontWeight(500).textColor(tone).child(ui.effects.fadedText(label, .{})))
                .child(div().flex1())
                .child(if (project_group and groupSpace(ws, arena, g.key) != null)
                    div().id(.{ "group-new-chat", gi }).role(.button).ariaLabel("New chat in project").size(px(20)).flexNone().flex().itemsCenter().justifyCenter()
                        .rounded(px(6)).cursorPointer().hover(sb.bg(theme.glassHover()))
                        .onClick(cx.listenerWith(gi, Sidebar.onGroupNewChat))
                        .tooltipWith(@as([]const u8, "New session in this project"), ui.tooltip.build)
                        .child(icon.of(.plus, 13, tone))
                else
                    null)
                .child(sections_ui.headerChevron(self, groupMotionId(g.key), open, tone, cx.app.executor.now()));
            var sec = div().flex().flexCol().pt(px(if (follows or gi > 0) section_gap else 0)).child(header);
            const motion_id = groupMotionId(g.key);
            const now_ns = cx.app.executor.now();
            if (open or sections_ui.disclosureAnimating(self, motion_id, now_ns)) {
                var body = div().flex().flexCol().gap(px(list_gap)).pt(px(disclosure_body_inset));
                var body_h: f32 = disclosure_body_inset;
                for (g.rows.items, 0..) |r, ri| {
                    body_h += rowHeight(prefs.sidebar_compact, prefs.show_project_label, r.branch != null, r.pr != null) + (if (ri > 0) list_gap else 0);
                    any_working.* = any_working.* or r.status == .working;
                    body = body.child(self.placedRow(r, g.rows.items.len > 1, .{ .target = .regular, .group = @intCast(gi), .index = @intCast(ri) }, theme, prefs, cx));
                }
                body = body.child(sections_ui.extraGapIn(self, .regular, @intCast(gi)));
                sections_ui.noteHeight(self, motion_id, body_h);
                sec = sec.child(sections_ui.disclosureBody(self, motion_id, body_h, body, now_ns));
            }
            out = out.child(sec);
        }
        return out;
    }

    fn onGroupNewChat(self: *Sidebar, gi: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        cx.stopPropagation();
        if (gi >= self.group_keys.items.len) return;
        const ws = self.state.read(cx).workspace;
        // On this device's checkout when it has one, never silently on a
        // possibly offline machine just because it cloned first.
        const key = self.gpa.dupe(u8, groupSpace(ws.read(cx), self.gpa, self.group_keys.items[gi]) orelse return) catch return;
        defer self.gpa.free(key);
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
        var id_buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&id_buf, "group:{s}", .{key})) |id| sections_ui.toggleMotion(self, id, !self.isCollapsed(key), cx) else |_| {}
        for (self.collapsed_groups.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
            self.gpa.free(self.collapsed_groups.orderedRemove(i));
            cx.notify();
            return;
        };
        self.collapsed_groups.append(self.gpa, self.gpa.dupe(u8, key) catch return) catch {};
        cx.notify();
    }

    /// [motion] A project / device group's disclosure motion key
    /// (`group:{collapse_key}`), in the frame arena.
    fn groupMotionId(key: []const u8) []const u8 {
        return zpui.fmt("group:{s}", .{key});
    }

    /// [motion] The disclosure motion key of a built-in group header.
    fn disclosureId(which: u8) []const u8 {
        return switch (which) {
            0 => "pinned",
            1 => "sessions",
            else => "archived",
        };
    }

    fn sectionHeader(self: *Sidebar, which: u8, label: []const u8, open: bool, theme: *const Theme, cx: *Context(Sidebar)) zpui.StatefulDiv {
        const tone = theme.text_muted.opacity(0.5);
        return div().id(.{ "sidebar-disclosure", which }).role(.button).ariaLabel(label).ariaExpanded(open)
            .flex().flexRow().itemsCenter().gap(px(8))
            .h(px(disclosure_header_height)).px(px(zt.layout.space_sm))
            .cursorPointer()
            .onClick(cx.listenerWith(which, Sidebar.toggleSection))
            .child(div().textSize(rems(12)).fontWeight(500).textColor(tone).whitespaceNowrap().child(label))
            .child(div().flex1())
            .child(sections_ui.headerChevron(self, disclosureId(which), open, tone, cx.app.executor.now()));
    }

    /// [pr-status] The live PR for a chat's checkout (`change_request_for_chat`).
    fn livePr(self: *const Sidebar, c: *const Chat) ?*const engine.protocol.ChangeRequestSummary {
        return if (self.prs) |p| p.forChat(c) else null;
    }

    /// [pr-status] The interactive badge for live PRs (tooltip, open in
    /// browser); fixture numbers keep the static chip.
    fn prBadge(self: *const Sidebar, r: *const RowData, n: u64, theme: *const Theme) zpui.AnyElement {
        if (self.livePr(r.chat)) |pr| if (pr.number == n)
            return zpui.intoAnyElement(crb.badge(.{ "sidebar-pr", std.hash.Wyhash.hash(0, r.chat.id) }, pr, .sidebar, true, theme));
        return zpui.intoAnyElement(ui.badge.pullRequest(n, theme));
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
        // zeron `{row}-corner` aria label: Archive / Unarchive while it is the pill.
        if (hovered) corner = corner.role(.button).ariaLabel(if (r.archived) "Unarchive" else "Archive").onClick(cx.listenerWith(ix, Sidebar.onArchiveClick))
            .tooltipWith(@as([]const u8, if (r.archived) "Unarchive session" else "Archive session"), ui.tooltip.buildAbove);
        corner = corner.child(corner_body);

        // Harness + project icons.
        const harness: ?zpui.elements.Svg = if (prefs.show_harness) (if (r.chat.config) |cfg| icon.harness(cfg.harness, harness_icon_size, subline, if (archived_muted) 0.4 else 0.8) else null) else null;
        const project_icon: ?zpui.Div = if (prefs.show_project_icon and r.project_icon)
            div().flexNone().opacity(if (archived_muted) 0.4 else 1.0).child(self.projectTile(r, theme, cx))
        else
            null;

        var row = div().id(.{ "chat-row", ix }).role(.button).ariaLabel(r.title).ariaSelected(r.selected).group(row_group)
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
                .child(self.titleCell(r));
            // Compact trailing cluster, right-packed: the PR badge sits LEFT
            // of one fixed 30px slot that shows the relative time and swaps to
            // the archive affordance while the row is hovered. No remote
            // globe: the fixed slot keeps the column aligned across rows.
            if (r.pr) |n| line = line.child(self.prBadge(r, n, theme));
            var slot = div().id(.{ "row-corner", ix }).w(px(30)).h(px(14)).flexNone().flex().itemsCenter().justifyEnd()
                .ariaLabel(if (hovered) (if (r.archived) "Unarchive" else "Archive") else "Session time");
            slot = if (hovered)
                slot.role(.button).cursorPointer().onClick(cx.listenerWith(ix, Sidebar.onArchiveClick))
                    .tooltipWith(@as([]const u8, if (r.archived) "Unarchive session" else "Archive session"), ui.tooltip.buildAbove)
                    .child(icon.of(if (r.archived) .archive_up_minimalistic else .archive_minimalistic, harness_icon_size, theme.text_muted))
            else
                slot.child(div().whitespaceNowrap().textRight().textSize(rems(11)).lineHeight(px(14)).textColor(subline).child(r.time_ago));
            line = line.child(slot);
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
            .child(self.titleCell(r));
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
            if (r.pr) |n| meta = meta.child(self.prBadge(r, n, theme));
            row = row.child(meta);
        }
        return row;
    }

    fn renderFilterRow(self: *Sidebar, theme: *const Theme, prefs: *const prefs_mod.Prefs, ws: *const model.WorkspaceStore, now: Timestamp, cx: *Context(Sidebar)) zpui.Div {
        var label: []const u8 = "All projects";
        var tag: ?[]const u8 = null;
        var offline = false;
        if (prefs.space_filter) |f| if (ws.space(f)) |s| {
            // The filter names the whole repository: its representative's name
            // and every device holding a checkout.
            label = view.spaceDisplayName(ws.representativeSpace(s));
            const arena = zpui.window.arena_mod.frameAllocator();
            const members = ws.projectMembers(arena, s) catch &.{};
            var buf: [160]u8 = undefined;
            const t, const off = ws.projectDeviceTag(&buf, members, now);
            tag = zpui.fmt("{s}", .{t});
            offline = off;
        };
        var name_group = div().flex1().minW0().flex().flexRow().itemsCenter().gap(px(6))
            .child(ui.effects.fadedText(label, .{}));
        if (tag) |t| {
            name_group = name_group.child(div().minW0().flexShrink1().flex().textSize(rems(10)).fontWeight(400).textColor(theme.text_muted.opacity(0.45)).child(ui.effects.fadedText(t, .{})));
            if (offline) name_group = name_group.child(icon.of(.wifi_off, 12, theme.warning.opacity(0.8)));
        }
        var trigger = div().id("spaces-filter").role(.button).ariaLabel(label).ariaExpanded(self.spaces_menu_open)
            .relative().flex1().minW0().h(px(29)).flex().flexRow().itemsCenter().gap(px(zt.layout.space_sm))
            .rounded(px(8)).px(px(zt.layout.space_sm))
            .textSize(rems(13)).fontWeight(500).lineHeight(px(17))
            .textColor(if (self.spaces_menu_open) theme.text else theme.text.opacity(0.8))
            .bg(if (self.spaces_menu_open) theme.glassHover() else theme.glassHover().opacity(0))
            .hover(sb.bg(theme.glassHover()).textColor(theme.text))
            .cursorPointer()
            .onClick(cx.listener(Sidebar.onSpacesTrigger))
            .child(icon.of(.folder, 16, theme.text_muted))
            .child(name_group);
        const spaces_exit = menuExit(self.spaces_menu_open, &self.spaces_menu_exit, cx.app.executor.now());
        if (self.spaces_menu_open or spaces_exit != null) trigger = trigger.child(ui.popover.anchoredBelowExit(self.renderSpacesMenu(theme, prefs, ws, cx), spaces_exit));

        var view_trigger = div().id("sidebar-view-options").role(.button).ariaLabel("Sidebar view options").ariaExpanded(self.view_menu_open)
            .relative().size(px(29)).flexNone().flex().itemsCenter().justifyCenter()
            .rounded(px(8)).cursorPointer()
            .bg(if (self.view_menu_open) theme.glassHover() else theme.glassHover().opacity(0))
            .hover(sb.bg(theme.glassHover()))
            .onClick(cx.listener(Sidebar.onViewTrigger))
            .child(icon.of(.more_horizontal, 16, theme.text_muted.opacity(0.6)));
        if (!self.view_menu_open) view_trigger = view_trigger.tooltipWith(@as([]const u8, "View options"), ui.tooltip.build)
            .tooltipShowDelay(350 * std.time.ns_per_ms);
        const view_exit = menuExit(self.view_menu_open, &self.view_menu_exit, cx.app.executor.now());
        if (self.view_menu_open or view_exit != null) view_trigger = view_trigger.child(ui.popover.anchoredRightExit(self.renderViewMenu(theme, prefs, cx), view_exit));

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
        card = card.child(ui.popover.menuRow(theme, prefs.space_filter == null).id("spaces-all").role(.menu_item)
            .onClick(cx.listenerWith(@as(usize, std.math.maxInt(usize)), Sidebar.onPickSpace))
            .child(icon.of(.folder, 16, theme.text_muted))
            .child(div().flex1().child("All projects"))
            .child(if (prefs.space_filter == null) icon.of(.check, 14, theme.text_muted) else null));
        // One row per repository across devices, carrying its local-first
        // checkout's id; the host tag keeps same-named projects apart.
        const projects = ws.projects(arena) catch &.{};
        const filter_key: ?[]const u8 = if (prefs.space_filter) |f| (if (ws.space(f)) |fs| projectKeyString(fs) else f) else null;
        var buf: [160]u8 = undefined;
        for (projects, 0..) |members, i| {
            const s = members[0];
            const rs = ws.representativeSpace(s);
            self.menu_space_ids.append(self.gpa, self.gpa.dupe(u8, s.id) catch continue) catch {};
            const active = if (filter_key) |k| std.mem.eql(u8, k, projectKeyString(s)) else false;
            const tag, _ = ws.projectDeviceTag(&buf, members, prefs.now(ws.io));
            card = card.child(ui.popover.menuRow(theme, active).id(.{ "spaces-row", i }).role(.menu_item)
                .onClick(cx.listenerWith(i, Sidebar.onPickSpace))
                .onMouseDown(.right, cx.listenerWith(i, Sidebar.onSpaceContext)) // [wiring]
                .child(ui.badge.monogram(view.spaceDisplayName(rs), rs.path, 16, false, null, theme))
                .child(div().flex1().minW0().flex().itemsCenter().gap(px(6))
                    .child(ui.effects.fadedText(view.spaceDisplayName(rs), .{}))
                    .child(div().textSize(rems(10)).textColor(theme.text_muted.opacity(0.6)).whitespaceNowrap().child(zpui.fmt("{s}", .{tag}))))
                .child(if (active) icon.of(.check, 14, theme.text_muted) else null));
        }
        card = card.child(ui.popover.separator(theme));
        card = card.child(ui.popover.menuRow(theme, false).id("spaces-new").role(.menu_item)
            .onClick(cx.listener(Sidebar.onNewProject))
            .child(icon.of(.add_circle, 16, theme.text_muted))
            .child("New project…"));
        return card;
    }

    // ---- [wiring] project row menu (`render_space_overlays`) ----

    fn onSpaceContext(self: *Sidebar, ix: usize, ev: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(Sidebar)) void {
        if (ix >= self.menu_space_ids.items.len) return;
        self.clearSpaceCtx();
        self.space_ctx = .{ .id = self.gpa.dupe(u8, self.menu_space_ids.items[ix]) catch return, .pos = ev.position };
        cx.notify();
    }

    fn clearSpaceCtx(self: *Sidebar) void {
        if (self.space_ctx) |c| self.gpa.free(c.id);
        self.space_ctx = null;
    }

    fn onSpaceCtxDismiss(self: *Sidebar, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.clearSpaceCtx();
        cx.notify();
    }

    fn onSpaceCtxAction(self: *Sidebar, delete: bool, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        const m = self.space_ctx orelse return;
        self.space_ctx = null;
        // The event is delivered after this handler returns: keep the id alive.
        if (self.emitted_space_id) |old| self.gpa.free(old);
        self.emitted_space_id = m.id;
        self.shutMenu(&self.spaces_menu_open, &self.spaces_menu_exit, cx);
        const id = m.id;
        if (delete) cx.emit(DeleteSpace{ .space_id = id }) else cx.emit(RenameSpace{ .space_id = id });
        cx.notify();
    }

    fn renderSpaceMenu(self: *Sidebar, theme_in: *const Theme, cx: *Context(Sidebar)) ?zpui.AnyElement {
        const m = self.space_ctx orelse return null;
        // Beside the spaces card (Rust overlays it at the pointer; zpui's
        // frosted spaces card composites above a later deferred overlay).
        const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
        const card = ui.popover.card(theme).w(px(170)).onMouseDownOut(cx.listener(Sidebar.onSpaceCtxDismiss))
            .child(ui.popover.menuRow(theme, false).id("space-menu-rename").role(.menu_item).onClick(cx.listenerWith(false, Sidebar.onSpaceCtxAction))
                .child(icon.of(.pen, 16, theme.text_muted)).child("Rename…"))
            .child(ui.popover.separator(theme))
            .child(ui.popover.menuRow(theme, false).id("space-menu-delete").role(.menu_item).textColor(theme.danger).onClick(cx.listenerWith(true, Sidebar.onSpaceCtxAction))
                .child(icon.of(.trash_bin_minimalistic, 16, theme.danger)).child("Remove…"));
        return zpui.intoAnyElement(zpui.deferred(zpui.anchored().position(.{ .x = @max(m.pos.x, prefs_mod.get(cx).sidebar_width - zt.layout.space_sm + 4), .y = m.pos.y }).snapToWindowWithMargin(.all(8))
            .child(div().occlude().child(ui.popover.frostedCard(card)))).withPriority(2));
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
            var row = ui.popover.menuRow(theme, open).id(.{ "sidebar-view-group", gi }).role(.menu_item)
                .relative().h(px(30)).py(px(0))
                .onHover(cx.listenerWith(@as(u8, @intCast(gi)), Sidebar.onViewGroupHover))
                .child(div().flex1().child(g[0]));
            if (gi < values.len) row = row.child(div().textColor(theme.text_muted).child(values[gi]));
            row = row.child(icon.of(.alt_arrow_right, 12, theme.text_muted));
            if (open) {
                var child = ui.popover.card(theme).w(px(232)).child(ui.popover.heading(theme, if (gi == 0) "ORGANIZE" else if (gi == 1) "SORT" else "SHOW"));
                var ix = g[1];
                while (ix < g[2]) : (ix += 1) {
                    child = child.child(ui.popover.menuRow(theme, false).id(.{ "sidebar-view-row", ix }).role(.menu_item)
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
        card = card.child(ui.popover.menuRow(theme, false).id("sidebar-view-compact").role(.menu_item).h(px(30)).py(px(0))
            .onHover(cx.listenerWith(@as(u8, 3), Sidebar.onViewGroupHover))
            .onClick(cx.listenerWith(@as(u8, 10), Sidebar.onToggleView))
            .child(div().flex1().child("Compact"))
            .child(zpui.nativeSwitch("sidebar-view-compact-switch", .{ .on = prefs.sidebar_compact, .label = "Compact", .size = .small }, cx.listener(Sidebar.onNativeCompact), ui.switch_.toggle(theme, prefs.sidebar_compact))));
        card = card.child(ui.popover.separator(theme));
        card = card.child(ui.popover.menuRow(theme, false).id("sidebar-create-section").role(.menu_item)
            .onHover(cx.listenerWith(@as(u8, 4), Sidebar.onViewGroupHover))
            .onClick(cx.listener(Sidebar.onCreateSection))
            .child(icon.of(.plus, 14, theme.text_muted)).child("Create Section"));
        return card;
    }

    /// "Star on GitHub" (`render_github_star_banner`): styled like the update
    /// strip; a click opens the repository, either it or ✕ dismisses for good.
    fn renderStarBanner(self: *Sidebar, theme: *const Theme, cx: *Context(Sidebar)) ?zpui.StatefulDiv {
        const s = model.settings_store.current(cx.app) orelse return null;
        if (s.githubStarBannerDismissed) return null;
        if (prefs_mod.get(cx).star_banner_hidden) return null;
        const above_strip = self.renderUpdateStrip(theme, cx) != null;
        const tone = theme.accent;
        var banner = div().id("github-star-banner").mx(px(zt.layout.space_sm));
        if (above_strip) banner = banner.mb(px(zt.layout.space_xs));
        return banner.pl(px(zt.layout.space_sm)).pr(px(zt.layout.space_xs)).py(px(4))
            .rounded(px(zt.layout.control_radius)).bg(theme.accent_wash)
            .flex().flexRow().itemsCenter().gap(px(6))
            .textSize(rems(11)).fontWeight(500).textColor(tone)
            .cursorPointer().hover(sb.bg(theme.accent.opacity(0.16)))
            .onClick(cx.listener(Sidebar.onStarBanner))
            // Glyphs sit below the line box's optical center: nudge the star.
            .child(icon.of(.star_bold, 12, tone).relative().top(px(0.5)))
            .child(div().flex1().minW0().truncate().child("Star on GitHub"))
            .child(div().id("github-star-banner-dismiss").role(.button).ariaLabel("Dismiss").flexNone().size(px(18)).rounded(px(4))
            .flex().itemsCenter().justifyCenter().cursorPointer()
            .hover(sb.bg(theme.accent.opacity(0.22)))
            .onClick(cx.listener(Sidebar.onStarDismiss))
            .tooltipWith(@as([]const u8, "Dismiss"), ui.tooltip.build)
            .child(icon.of(.close, 10, tone)));
    }

    pub const github_repo_url = "https://github.com/zeronsh/comet";

    fn onStarBanner(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        cx.app.platform.vtable.openUrl(cx.app.platform.ptr, github_repo_url);
        self.dismissStarBanner(cx);
    }

    fn onStarDismiss(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        cx.stopPropagation();
        self.dismissStarBanner(cx);
    }

    fn dismissStarBanner(_: *Sidebar, cx: *Context(Sidebar)) void {
        const W = struct {
            fn f(_: void, s: *model.UiSettings, _: std.mem.Allocator) void {
                s.githubStarBannerDismissed = true;
            }
        };
        _ = model.settings_store.update(cx.app, .debounced, {}, W.f);
        cx.notify();
    }

    /// The update strip above the footer (`render_update_strip`): accent
    /// wash chip, 11px medium accent label.
    fn renderUpdateStrip(self: *Sidebar, theme: *const Theme, cx: *Context(Sidebar)) ?zpui.StatefulDiv {
        const prefs = prefs_mod.get(cx);
        var label: []const u8 = undefined;
        if (prefs.update_label) |l| {
            label = l;
        } else if (app_update.AppUpdate.global(cx.app)) |u| {
            // [lifecycle] The app's own updater drives the strip (Rust `AppUpdate::strip`).
            var buf: [160]u8 = undefined;
            const strip = u.read(cx).strip(&buf) orelse return null;
            label = zpui.fmt("{s}", .{strip[0]});
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
            .onClick(cx.listener(Sidebar.onUpdateStripClick)) // [lifecycle]
            .child(div().flex1().minW0().child(label));
    }

    // [lifecycle] Strip click: download / restart / explain / advise (app_update.zig).
    fn onUpdateStripClick(_: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        app_update.onStripClick(cx.app);
    }

    // [lifecycle] Account menu "Check for updates" (Linux; macOS uses the app menu).
    fn onCheckUpdates(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.shutMenu(&self.user_menu_open, &self.user_menu_exit, cx);
        cx.notify();
        if (app_update.AppUpdate.global(cx.app)) |u| u.update(cx.app, app_update.AppUpdate.checkForUpdates, .{});
    }

    fn onAccountAction(self: *Sidebar, action: sync_flow.AccountMenuAction, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Sidebar)) void {
        self.shutMenu(&self.user_menu_open, &self.user_menu_exit, cx);
        if (action == .sync_in_progress) return cx.notify();
        cx.emit(AccountAction{ .action = action });
        cx.notify();
    }

    /// The account menu card (identity line + the sync / sign-out action).
    fn userMenuCard(_: *Sidebar, theme: *const Theme, identity: []const u8, menu_action: ?sync_flow.AccountMenuAction, cx: *Context(Sidebar)) zpui.Div {
        const prefs = prefs_mod.get(cx);
        var menu = ui.popover.card(theme).w(px(prefs.sidebar_width - 2 * zt.layout.space_sm))
            .onMouseDownOut(cx.listener(Sidebar.onCloseMenus))
            .child(div().px(px(8)).pt(px(6)).pb(px(4)).textSize(rems(11)).textColor(theme.text_muted).truncate().child(identity));
        if (menu_action) |action| {
            const base = ui.popover.menuRow(theme, false);
            const row = switch (action) {
                .enable_sync => base.id("user-menu-enable-sync").child(icon.of(.global, 16, theme.text_muted)).child("Enable sync"),
                .sync_in_progress => base.id("user-menu-sync-progress").opacity(0.6).cursorDefault().child(icon.of(.global, 16, theme.text_muted)).child("Sync setup in progress"),
                .restart_pending => base.id("user-menu-sync-restart").child(icon.of(.restart, 16, theme.text_muted)).child("Finish sync setup"),
                .sign_out => base.id("user-menu-signout").child(icon.of(.logout_2, 16, theme.text_muted)).child("Sign out"),
            };
            menu = menu.child(row.role(.menu_item).ariaDisabled(action == .sync_in_progress).onClick(cx.listenerWith(action, Sidebar.onAccountAction)));
        }
        if (@import("builtin").os.tag != .macos) {
            menu = menu.child(ui.popover.menuRow(theme, false).id("user-menu-check-updates").role(.menu_item)
                .onClick(cx.listener(Sidebar.onCheckUpdates)) // [lifecycle]
                .child(icon.of(.refresh, 16, theme.text_muted)).child("Check for updates"));
        }
        return menu;
    }

    /// [native-popover] `userMenuCard` on the container's material.
    fn nativeUserMenu(self: *Sidebar, _: *Window, cx: *Context(Sidebar)) zpui.Div {
        const theme = zpui.window.arena_mod.current().create(Theme, ui.theme.get(cx).forPopup());
        const app_state = self.state.read(cx);
        const scope = app_state.engine.read(cx).workspaceScope() orelse app_state.workspace.read(cx).workspace_scope;
        const flow = sync_flow.current(cx.app);
        _, const identity = sync_flow.identity(scope, flow, app_state.auth.read(cx).user());
        return native_popover.bare(self.userMenuCard(theme, identity, sync_flow.accountMenuAction(scope, flow), cx));
    }

    fn dismissUserMenu(self: *Sidebar, _: *Window, cx: *Context(Sidebar)) void {
        self.shutMenu(&self.user_menu_open, &self.user_menu_exit, cx);
        cx.notify();
    }

    fn renderFooter(self: *Sidebar, theme_in: *const Theme, cx: *Context(Sidebar)) zpui.Div {
        const theme = &zpui.window.arena_mod.current().create(Theme, theme_in.forPopup()).*;
        const app_state = self.state.read(cx);
        const scope = app_state.engine.read(cx).workspaceScope() orelse app_state.workspace.read(cx).workspace_scope;
        const flow = sync_flow.current(cx.app);
        // `sidebar_account_identity` + `account_menu_action`.
        const user_line, const identity = sync_flow.identity(scope, flow, app_state.auth.read(cx).user());
        const menu_action = sync_flow.accountMenuAction(scope, flow);
        const initial = blk: {
            const t = std.mem.trim(u8, user_line, " ");
            if (t.len == 0) break :blk "?";
            break :blk zpui.fmt("{c}", .{std.ascii.toUpper(t[0])});
        };
        var trigger = div().id("user-menu").role(.button).ariaLabel(zpui.fmt("Account menu: {s}", .{user_line})).ariaExpanded(self.user_menu_open)
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
        const user_exit = menuExit(self.user_menu_open, &self.user_menu_exit, cx.app.executor.now());
        if (self.user_menu_open and native_popover.enabled(cx)) {
            // [native-popover] The account / sync menu in a native popover container (macOS).
            trigger = trigger.child(zpui.nativePopover(
                .trigger("user-menu-native"),
                native_popover.options(theme, .above, .start, null),
                zpui.popoverContent(cx.entity(), nativeUserMenu, dismissUserMenu),
            ));
        } else if (self.user_menu_open or user_exit != null) {
            trigger = trigger.child(ui.popover.anchoredAboveExit(self.userMenuCard(theme, identity, menu_action, cx), user_exit));
        }
        const mac = @import("builtin").os.tag == .macos;
        return div().wFull().flex().itemsCenter().justifyBetween().gap(px(4))
            .child(trigger)
            .child(div().id("settings-trigger").role(.button).ariaLabel("Settings").ariaToggled(false)
                .size(px(footer_button_size)).flexNone().rounded(px(8))
                .flex().itemsCenter().justifyCenter().cursorPointer()
                .hover(sb.bg(theme.glassHover()))
                .tooltipWith(@as([]const u8, if (mac) "Settings · ⌘," else "Settings · Ctrl+,"), ui.tooltip.build)
                .onClick(cx.listener(Sidebar.onSettings))
                .child(icon.of(.settings, 15, theme.text_muted)));
    }
};


test "pinned drop index and reorder" {
    const slots = [_]f32{ 31, 31, 31 };
    try std.testing.expectEqual(@as(usize, 0), pinDropIndex(-4, &slots));
    try std.testing.expectEqual(@as(usize, 1), pinDropIndex(40, &slots));
    try std.testing.expectEqual(@as(usize, 2), pinDropIndex(500, &slots));
    var ids = [_][]const u8{ "a", "b", "c", "d" };
    movePin(&ids, 0, 2);
    try std.testing.expectEqualStrings("b", ids[0]);
    try std.testing.expectEqualStrings("c", ids[1]);
    try std.testing.expectEqualStrings("a", ids[2]);
    movePin(&ids, 3, 0);
    try std.testing.expectEqualStrings("d", ids[0]);
    try std.testing.expectEqualStrings("a", ids[3]);
}


// ---- [motion] resort glide (`resort_offsets`, `sidebar_key_order_changed`) ----------------

/// `RESORT`: 260 ms `cubic-bezier(0.22, 1, 0.36, 1)` (§1.6 View Transitions).
pub const resort_spec: zt.motion.MotionSpec = .init(260, zt.motion.ease_resort);

pub const ResortItem = struct { key: []const u8, height: f32 };

fn containsKey(items: []const ResortItem, key: []const u8) bool {
    for (items) |it| if (std.mem.eql(u8, it.key, key)) return true;
    return false;
}

fn resortSame(a: []const ResortItem, b: []const ResortItem) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x.key, y.key) or x.height != y.height) return false;
    return true;
}

/// Height changes do not constitute a reorder (disclosures animate their own).
pub fn keyOrderChanged(old: []const ResortItem, new: []const ResortItem) bool {
    if (old.len != new.len) return true;
    for (old, new) |a, b| if (!std.mem.eql(u8, a.key, b.key)) return true;
    return false;
}

/// `resort_offsets`: old y − new y for every surviving key that moved more
/// than half a pixel (returned as `{key, dy}` in `height`).
pub fn resortOffsets(a: std.mem.Allocator, old: []const ResortItem, new: []const ResortItem, gap: f32) ![]ResortItem {
    var out: std.ArrayList(ResortItem) = .empty;
    var y: f32 = 0;
    for (new) |n| {
        var oy: f32 = 0;
        const prev: ?f32 = for (old) |o| {
            if (std.mem.eql(u8, o.key, n.key)) break oy;
            oy += o.height + gap;
        } else null;
        if (prev) |p| if (@abs(p - y) > 0.5) try out.append(a, .{ .key = n.key, .height = p - y });
        y += n.height + gap;
    }
    return out.items;
}

test "resort offsets match shell.rs" {
    const a = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const K = ResortItem;
    const same = [_]K{ .{ .key = "a", .height = 29 }, .{ .key = "b", .height = 29 }, .{ .key = "c", .height = 45 } };
    try std.testing.expectEqual(@as(usize, 0), (try resortOffsets(aa, &same, &same, 2)).len);
    // c jumps to the top: +62; a and b shift down by 31.
    const old1 = [_]K{ .{ .key = "a", .height = 29 }, .{ .key = "b", .height = 29 }, .{ .key = "c", .height = 29 } };
    const new1 = [_]K{ .{ .key = "c", .height = 29 }, .{ .key = "a", .height = 29 }, .{ .key = "b", .height = 29 } };
    const o1 = try resortOffsets(aa, &old1, &new1, 2);
    try std.testing.expectEqual(@as(usize, 3), o1.len);
    try std.testing.expectEqualStrings("c", o1[0].key);
    try std.testing.expectEqual(@as(f32, 62), o1[0].height);
    try std.testing.expectEqual(@as(f32, -31), o1[1].height);
    try std.testing.expectEqual(@as(f32, -31), o1[2].height);
    // Heights and gap respected.
    const old2 = [_]K{ .{ .key = "tall", .height = 45 }, .{ .key = "short", .height = 29 } };
    const new2 = [_]K{ .{ .key = "short", .height = 29 }, .{ .key = "tall", .height = 45 } };
    const o2 = try resortOffsets(aa, &old2, &new2, 2);
    try std.testing.expectEqual(@as(f32, 47), o2[0].height);
    try std.testing.expectEqual(@as(f32, -31), o2[1].height);
    // Added / removed keys get no offset.
    const old3 = [_]K{ .{ .key = "a", .height = 29 }, .{ .key = "gone", .height = 29 }, .{ .key = "b", .height = 29 } };
    const new3 = [_]K{ .{ .key = "new", .height = 29 }, .{ .key = "a", .height = 29 }, .{ .key = "b", .height = 29 } };
    const o3 = try resortOffsets(aa, &old3, &new3, 2);
    try std.testing.expectEqual(@as(usize, 1), o3.len);
    try std.testing.expectEqualStrings("a", o3[0].key);
    try std.testing.expectEqual(@as(f32, -31), o3[0].height);
    try std.testing.expect(keyOrderChanged(&old1, &new1));
    try std.testing.expect(!keyOrderChanged(&old1, &old1));
    try std.testing.expectEqual(@as(u64, 260), resort_spec.duration_ms);
}
