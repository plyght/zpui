//! The sidebar's custom sections and session transfers (zeron
//! `shell/sidebar_sections.rs` render + overlays, and the session-transfer
//! half of `shell/spaces.rs`: `begin/finish/cancel_sidebar_session_transfer`,
//! `render_moving_sidebar_session`).
//!
//! - A section is a disclosure between Pinned and Sessions: 12px top gap,
//!   28px header (name, hover `⋯` → Edit section / Archive all / Delete,
//!   chevron), 4px body inset, 2px row gaps, "Drop sessions here" when empty.
//! - "New section" / "Edit section" dialog (name ≤ 120 chars).
//! - Any active row drags (pinned rows keep their sibling slide): while it
//!   moves the row floats in the list's movement layer (raised surface,
//!   md shadow, following the pointer) above an empty slot; dropping on
//!   Pinned pins it, on a section assigns it, on Sessions unpins and clears
//!   its section. A drop anywhere else slides the row home (TAB_SLIDE).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const dialog = @import("../components/dialog.zig");
const prefs_mod = @import("../shell/prefs.zig");
const input_mod = @import("zeron_input");
const sections = @import("sections.zig");
const sidebar_mod = @import("sidebar.zig");

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
const TextInput = input_mod.TextInput;
const Sidebar = sidebar_mod.Sidebar;
const Ctx = Context(Sidebar);
const protocol = engine.protocol;

pub const Section = sections.Section;

/// The drag payload for every active row (`SidebarSessionDrag`).
pub const SessionDrag = struct {
    /// Row index (into `Sidebar.row_ids`).
    ix: usize,
    /// Index among the pinned rows when the row is pinned.
    pinned_from: ?usize = null,
    height: f32,
    title_buf: [64]u8 = undefined,
    title_len: u8 = 0,
};

/// Empty drag preview: the moving row is drawn by the sidebar itself.
const NoGhost = struct {
    pub fn render(_: *NoGhost, _: *Window, _: *Context(NoGhost)) zpui.Div {
        return div();
    }
};

pub fn buildGhost(_: *const SessionDrag, _: zpui.Point(f32), _: *Window, app: *App) Entity(NoGhost) {
    return app.new(NoGhost, .{}) catch @panic("OOM");
}

/// Where a transfer would land.
pub const Target = union(enum) { pinned, section: usize, regular };

const Transfer = struct {
    chat_id: []u8,
    height: f32,
    /// Window-space pointer y and the grab offset inside the row.
    pointer_y: f32,
    grab_y: f32,
    /// The row's top in list-content coordinates when the drag began.
    origin_top: ?f32 = null,
    preview: ?Target = null,
    /// Bumps when `preview` changes (gap tween keys).
    epoch: u64 = 0,
    prev: ?Target = null,
};

const Return = struct {
    chat_id: []u8,
    height: f32,
    from: f32,
    to: f32,
    epoch: u64,
};

const Dialog = struct {
    profile: []u8,
    id: ?[]u8,
    input: Entity(TextInput),
    sub: zpui.Subscription,
    focus_pending: bool = true,
};

pub const State = struct {
    ctl: sections.Controller = .{},
    /// Section `⋯` menu: (section id, window position).
    menu: ?struct { id: []u8, pos: zpui.Point(f32) } = null,
    header_hover: ?[]u8 = null,
    dialog: ?Dialog = null,
    /// Section ids rendered last frame (owned), for listeners.
    ids: std.ArrayList([]u8) = .empty,
    /// "Archive all" batch: replies still out, failures so far.
    archive_left: usize = 0,
    archive_failed: usize = 0,
    transfer: ?Transfer = null,
    returning: ?Return = null,
    return_epoch: u64 = 0,
    return_task: zpui.Task(void) = .none,

    pub fn deinit(self: *State, gpa: std.mem.Allocator, app: *App) void {
        self.ctl.deinit(gpa);
        if (self.menu) |m| gpa.free(m.id);
        if (self.header_hover) |h| gpa.free(h);
        dropDialog(self, gpa, app);
        for (self.ids.items) |s| gpa.free(s);
        self.ids.deinit(gpa);
        if (self.transfer) |t| gpa.free(t.chat_id);
        if (self.returning) |r| gpa.free(r.chat_id);
        self.return_task.cancel();
        self.* = .{};
    }
};

fn dropDialog(st: *State, gpa: std.mem.Allocator, app: *App) void {
    if (st.dialog) |*d| {
        d.sub.deinit();
        d.input.release(app);
        gpa.free(d.profile);
        if (d.id) |i| gpa.free(i);
    }
    st.dialog = null;
}

fn setOwned(gpa: std.mem.Allocator, slot: *?[]u8, v: ?[]const u8) void {
    if (slot.*) |s| gpa.free(s);
    slot.* = if (v) |x| gpa.dupe(u8, x) catch null else null;
}

/// Attached to an engine (headless tests: calls go to `EngineState.test_sink`).
fn attached(es: *const model.EngineState) bool {
    return es.conn != null or model.engine_state.test_sink != null;
}

// ---- model access ------------------------------------------------------------------------

pub fn env(self: *Sidebar, cx: anytype) sections.Env {
    const st = self.state.read(cx);
    const auth = st.auth.read(cx);
    return .{
        .gpa = self.gpa,
        .app = cx.app,
        .workspace = st.workspace,
        .engine = st.engine,
        .auth = if (auth.auth) |*a| a else null,
    };
}

/// `active_sidebar_sections`, allocated in `a` (the frame arena while
/// rendering; a local arena in handlers, which run outside a draw).
pub fn active(self: *Sidebar, a: std.mem.Allocator, cx: anytype) []Section {
    return self.sec.ctl.active(a, env(self, cx)) catch &.{};
}

/// `change_sidebar_section`: true when applied (or queued).
pub fn change(self: *Sidebar, ch: sections.SectionChange, cx: *Ctx) bool {
    const r = self.sec.ctl.change(ch, env(self, cx));
    switch (r) {
        .applied => {},
        .send => sendHead(self, cx),
        .refused => return false,
        .notice => |n| {
            self.setNotice(n, cx);
            return false;
        },
    }
    // Pins are device-local in this client: a chat that joins a section (or
    // returns to Sessions) leaves the pin list, as the engine's projection does.
    if (ch == .assign) {
        const p = prefs_mod.mut(cx);
        if (ch.assign.sectionId != null and p.isPinned(ch.assign.sessionId)) p.setPinned(ch.assign.sessionId, false);
    }
    cx.notify();
    return true;
}

fn sendHead(self: *Sidebar, cx: *Ctx) void {
    const head = self.sec.ctl.head() orelse return;
    const ws = self.state.read(cx).engine;
    const op: protocol.Mutate = .{ .changeSidebarPin = .{ .change = .{ .section = .{ .change = head } } } };
    model.EngineState.request(ws, cx, Sidebar, cx.entityId(), .Mutate, op, onWriteReply) catch {
        // The connection went away between queueing and sending.
        const id = self.sec.ctl.pendingId() orelse return;
        const f = self.sec.ctl.finish(id, .{ .err = .{ .kind = error.Closed, .message = "Engine not connected" } }, env(self, cx));
        afterFinish(self, f, cx);
    };
}

fn onWriteReply(self: *Sidebar, result: model.engine_state.CallResult, cx: *Ctx) void {
    const id = self.sec.ctl.pendingId() orelse return;
    const f = self.sec.ctl.finish(id, result, env(self, cx));
    afterFinish(self, f, cx);
}

fn afterFinish(self: *Sidebar, f: sections.Controller.Finish, cx: *Ctx) void {
    if (f.clear_notice) if (self.notice) |n| if (std.mem.startsWith(u8, n, "Couldn't save sidebar changes") or
        std.mem.eql(u8, n, sections.notice_waiting))
    {
        self.setNotice(null, cx);
    };
    if (f.notice) |n| self.setNotice(n, cx);
    if (f.notice_error) |e| {
        var buf: [256]u8 = undefined;
        self.setNotice(std.fmt.bufPrint(&buf, "Couldn't save sidebar changes: {s}", .{e}) catch "Couldn't save sidebar changes", cx);
    }
    if (f.send_next) sendHead(self, cx);
    cx.notify();
}

/// Per-frame: hand locally stored sections to a synced profile once.
pub fn migrate(self: *Sidebar, cx: *Ctx) void {
    if (self.sec.ctl.migrate(env(self, cx)) == .send) sendHead(self, cx);
}

// ---- dialog ------------------------------------------------------------------------------

/// `open_section_dialog`: new (`id` null) or edit an existing section.
pub fn openDialog(self: *Sidebar, id: ?[]const u8, cx: *Ctx) void {
    const e = env(self, cx);
    const profile = sections.Controller.profileKey(self.gpa, e.workspace.read(cx).workspace_scope, e.auth) orelse return;
    self.view_menu_open = false;
    self.view_submenu = null;
    if (self.sec.menu) |m| self.gpa.free(m.id);
    self.sec.menu = null;
    var name: []const u8 = "";
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    if (id) |want| for (active(self, scratch.allocator(), cx)) |s| if (std.mem.eql(u8, s.id, want)) {
        name = s.name;
    };
    const theme = ui.theme.get(cx);
    const in = cx.newWith(TextInput, TextInput.init, .{input_mod.Options{
        .placeholder = "Section name",
        .key_context = "Composer",
        .single_line = true,
        .text_size = 13,
        .line_height = 18,
        .colors = .{ .text = theme.text, .placeholder = theme.text_muted.opacity(0.6), .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
        .edge_fade = false,
    }}) catch {
        self.gpa.free(profile);
        return;
    };
    in.update(cx, TextInput.setText, .{name});
    const sub = cx.subscribe(in, onDialogInput) catch {
        in.release(cx);
        self.gpa.free(profile);
        return;
    };
    dropDialog(&self.sec, self.gpa, cx.app);
    self.sec.dialog = .{ .profile = profile, .id = if (id) |i| self.gpa.dupe(u8, i) catch null else null, .input = in, .sub = sub };
    cx.notify();
}

fn onDialogInput(self: *Sidebar, _: Entity(TextInput), ev: *const input_mod.TextInputEvent, cx: *Ctx) void {
    switch (ev.*) {
        .submitted, .modified_submitted => submitDialog(self, cx),
        .escape => closeDialog(self, cx),
        else => cx.notify(),
    }
}

pub fn closeDialog(self: *Sidebar, cx: *Ctx) void {
    dropDialog(&self.sec, self.gpa, cx.app);
    cx.notify();
}

/// `submit_section_dialog`: Create (fresh uuid) or Rename; an invalid name
/// keeps the dialog open, a refused change too.
pub fn submitDialog(self: *Sidebar, cx: *Ctx) void {
    const d = self.sec.dialog orelse return;
    const e = env(self, cx);
    var kbuf: [256]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&kbuf);
    const key = sections.Controller.profileKey(fba.allocator(), e.workspace.read(cx).workspace_scope, e.auth);
    if (key == null or !std.mem.eql(u8, key.?, d.profile)) return closeDialog(self, cx);
    const name = sections.validName(d.input.read(cx).text()) orelse return;
    const owned = self.gpa.dupe(u8, name) catch return;
    defer self.gpa.free(owned);
    var idbuf: [36]u8 = undefined;
    const ch: sections.SectionChange = if (d.id) |id|
        .{ .rename = .{ .id = id, .name = owned } }
    else
        .{ .create = .{ .id = sections.newId(&idbuf, self.state.read(cx).workspace.read(cx).io), .name = owned } };
    if (change(self, ch, cx)) closeDialog(self, cx);
}

fn onDialogSave(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    submitDialog(self, cx);
}

fn onDialogCancel(self: *Sidebar, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    closeDialog(self, cx);
}

fn onDialogScrim(_: *Sidebar, _: *const zpui.input.MouseDownEvent, _: *Window, _: *Ctx) void {}

fn onDialogKey(self: *Sidebar, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Ctx) void {
    if (std.mem.eql(u8, ev.keystroke.key, "escape")) {
        cx.stopPropagation();
        closeDialog(self, cx);
    }
}

pub fn renderDialog(self: *Sidebar, window: *Window, theme_in: *const Theme, cx: *Ctx) ?zpui.AnyElement {
    const d = if (self.sec.dialog) |*x| x else return null;
    if (d.focus_pending) {
        d.focus_pending = false;
        window.focus(d.input.read(cx).focusHandle());
    }
    const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
    const edit = d.id != null;
    const valid = sections.validName(d.input.read(cx).text()) != null;
    const card = dialog.card(theme)
        .onKeyDown(cx.listener(onDialogKey))
        .child(div().flex().itemsCenter().justifyBetween()
            .child(dialog.title(theme, if (edit) "Edit section" else "New section"))
            .child(div().id("section-dialog-close").size(px(24)).flex().itemsCenter().justifyCenter().cursorPointer()
            .onClick(cx.listener(onDialogCancel))
            .child(icon.of(.close, 16, theme.text_muted))))
        .child(div().mt(px(8)).textColor(theme.text_muted).child("Group sessions however you like"))
        .child(div().mt(px(16)).h(px(36)).px(px(12)).flex().itemsCenter().rounded(px(8)).border1().borderColor(theme.border)
            .bg(theme.bg).child(div().flex1().minW0().child(d.input)))
        .child(div().mt(px(16)).flex().justifyEnd().gap(px(8))
            .child(dialog.btnGhost(theme, "Cancel").id("section-cancel").onClick(cx.listener(onDialogCancel)))
            .child(dialog.btnPrimary(theme, if (edit) "Save" else "Create section").id("section-save")
            .opacity(if (valid) 1.0 else 0.5).onClick(cx.listener(onDialogSave))));
    return dialog.modal(window, card, cx.listener(onDialogScrim));
}

// ---- section menu ------------------------------------------------------------------------

fn idAt(self: *Sidebar, ix: usize) ?[]const u8 {
    return if (ix < self.sec.ids.items.len) self.sec.ids.items[ix] else null;
}

fn onHeaderHover(self: *Sidebar, ix: usize, hovered: *const bool, _: *Window, cx: *Ctx) void {
    const id = idAt(self, ix) orelse return;
    if (hovered.*) {
        setOwned(self.gpa, &self.sec.header_hover, id);
    } else if (self.sec.header_hover) |h| if (std.mem.eql(u8, h, id)) setOwned(self.gpa, &self.sec.header_hover, null);
    cx.notify();
}

fn onHeaderClick(self: *Sidebar, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    const id = idAt(self, ix) orelse return;
    var open = true;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    for (active(self, scratch.allocator(), cx)) |s| if (std.mem.eql(u8, s.id, id)) {
        open = !s.collapsed;
    };
    const owned = self.gpa.dupe(u8, id) catch return;
    defer self.gpa.free(owned);
    _ = change(self, .{ .collapse = .{ .id = owned, .collapsed = open } }, cx);
}

fn onMenuButton(self: *Sidebar, ix: usize, ev: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    cx.stopPropagation();
    const id = idAt(self, ix) orelse return;
    if (self.sec.menu) |m| self.gpa.free(m.id);
    self.sec.menu = .{ .id = self.gpa.dupe(u8, id) catch return, .pos = ev.mousePosition() orelse .{ .x = 0, .y = 0 } };
    cx.notify();
}

fn closeMenu(self: *Sidebar, cx: *Ctx) void {
    if (self.sec.menu) |m| self.gpa.free(m.id);
    self.sec.menu = null;
    cx.notify();
}

fn onMenuOutside(self: *Sidebar, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Ctx) void {
    closeMenu(self, cx);
}

fn onMenuKey(self: *Sidebar, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Ctx) void {
    if (std.mem.eql(u8, ev.keystroke.key, "escape")) {
        cx.stopPropagation();
        closeMenu(self, cx);
    }
}

/// `activate_section_menu`: 0 Edit section, 1 Archive all, 2 Delete.
fn onMenuAction(self: *Sidebar, action: u8, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    cx.stopPropagation();
    const m = self.sec.menu orelse return;
    self.sec.menu = null;
    defer self.gpa.free(m.id);
    switch (action) {
        0 => openDialog(self, m.id, cx),
        1 => archiveSection(self, m.id, cx),
        else => {
            cancelTransfer(self, cx);
            _ = change(self, .{ .delete = .{ .id = m.id } }, cx);
        },
    }
    cx.notify();
}

pub fn renderMenu(self: *Sidebar, theme_in: *const Theme, cx: *Ctx) ?zpui.AnyElement {
    const m = self.sec.menu orelse return null;
    var known = false;
    for (active(self, zpui.window.arena_mod.frameAllocator(), cx)) |s| if (std.mem.eql(u8, s.id, m.id)) {
        known = true;
    };
    if (!known) {
        self.gpa.free(m.id);
        self.sec.menu = null;
        return null;
    }
    const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
    var card = ui.popover.card(theme).w(px(180)).onMouseDownOut(cx.listener(onMenuOutside)).onKeyDown(cx.listener(onMenuKey));
    for ([_][]const u8{ "Edit section", "Archive all", "Delete" }, 0..) |label, i| {
        card = card.child(ui.popover.menuRow(theme, false).id(.{ "section-action", i })
            .onClick(cx.listenerWith(@as(u8, @intCast(i)), onMenuAction)).child(label));
    }
    return ui.popover.anchoredAt(m.pos, card);
}

// ---- archive all -------------------------------------------------------------------------

const ArchiveParams = struct { op: []const u8 = "setChatArchived", chatId: []const u8, archived: bool = true };

/// `archive_sidebar_section`: one `setChatArchived` per live member (a
/// failure count lands in the notice; membership is kept).
pub fn archiveSection(self: *Sidebar, id: []const u8, cx: *Ctx) void {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const secs = active(self, scratch.allocator(), cx);
    const sec = for (secs) |s| {
        if (std.mem.eql(u8, s.id, id)) break s;
    } else return;
    const st = self.state.read(cx);
    const ws = st.workspace.read(cx);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(self.gpa);
    for (ws.chats()) |*c| {
        if (c.archived) continue;
        for (sec.session_ids) |sid| if (std.mem.eql(u8, sid, c.id)) {
            ids.append(self.gpa, c.id) catch {};
            break;
        };
    }
    if (ids.items.len == 0) return cx.notify();
    if (!attached(st.engine.read(cx))) return self.setNotice("Engine not connected", cx);
    for (ids.items) |chat_id| {
        model.EngineState.request(st.engine, cx, Sidebar, cx.entityId(), .Mutate, ArchiveParams{ .chatId = chat_id }, onArchiveReply) catch {
            self.sec.archive_failed += 1;
            continue;
        };
        self.sec.archive_left += 1;
    }
    if (self.sec.archive_left == 0) reportArchive(self, cx);
    cx.notify();
}

fn onArchiveReply(self: *Sidebar, result: model.engine_state.CallResult, cx: *Ctx) void {
    if (result == .err) self.sec.archive_failed += 1;
    if (self.sec.archive_left > 0) self.sec.archive_left -= 1;
    if (self.sec.archive_left == 0) reportArchive(self, cx);
}

fn reportArchive(self: *Sidebar, cx: *Ctx) void {
    const failed = self.sec.archive_failed;
    self.sec.archive_failed = 0;
    if (failed == 0) return;
    var buf: [96]u8 = undefined;
    self.setNotice(std.fmt.bufPrint(&buf, "Could not archive {d} sessions. Try again.", .{failed}) catch "Could not archive sessions. Try again.", cx);
}

// ---- rendering ----------------------------------------------------------------------------

/// `render_custom_sidebar_section`. `rows` are already-rendered row elements.
pub fn renderSection(self: *Sidebar, ix: usize, section: Section, body_rows: zpui.Div, empty: bool, extra_gap: ?zpui.AnyElement, theme: *const Theme, cx: *Ctx) zpui.StatefulDiv {
    const open = !section.collapsed;
    const tone = theme.text_muted.opacity(0.5);
    const show_menu = (if (self.sec.header_hover) |h| std.mem.eql(u8, h, section.id) else false) or
        (if (self.sec.menu) |m| std.mem.eql(u8, m.id, section.id) else false);
    var header = div().id(.{ "section-header", ix })
        .h(px(28)).px(px(zt.layout.space_sm)).flex().itemsCenter().gap(px(8)).cursorPointer()
        .onHover(cx.listenerWith(ix, onHeaderHover))
        .onClick(cx.listenerWith(ix, onHeaderClick))
        .child(div().flex1().minW0().truncate().textSize(rems(12)).textColor(tone).child(section.name));
    if (show_menu) header = header.child(div().id(.{ "section-menu", ix }).size(px(20)).flex().itemsCenter().justifyCenter()
        .rounded(px(4)).hover(sb.bg(theme.glassHover()))
        .onClick(cx.listenerWith(ix, onMenuButton))
        .tooltipWith(@as([]const u8, "Section options"), ui.tooltip.build)
        .child(icon.of(.more_horizontal, 14, theme.text_muted)));
    header = header.child(icon.of(if (open) .alt_arrow_down else .alt_arrow_right, 12, tone));
    var out = div().id(.{ "custom-section", ix }).wFull().flex().flexCol().pt(px(12))
        .onDragMove(SessionDrag, cx.listenerWith(Target{ .section = ix }, onGroupDragMove))
        .onDrop(SessionDrag, cx.listenerWith(Target{ .section = ix }, onGroupDrop))
        .child(header);
    if (open) {
        var content = div().wFull().flex().flexCol().pt(px(4)).gap(px(2));
        if (empty) content = content.child(div().h(px(40)).px(px(zt.layout.space_sm)).flex().itemsCenter()
            .textSize(rems(12)).textColor(tone).child("Drop sessions here"));
        content = content.child(body_rows).child(extra_gap);
        out = out.child(content);
    }
    return out;
}

/// Remember the section ids rendered this frame (listeners index into them).
pub fn beginFrame(self: *Sidebar, secs: []const Section) void {
    for (self.sec.ids.items) |s| self.gpa.free(s);
    self.sec.ids.clearRetainingCapacity();
    for (secs) |s| self.sec.ids.append(self.gpa, self.gpa.dupe(u8, s.id) catch continue) catch {};
}

// ---- session transfers ----------------------------------------------------------------------

/// Whether `chat_id` is the row being moved (or sliding home).
pub fn isMoving(self: *const Sidebar, chat_id: []const u8) bool {
    if (self.sec.transfer) |t| if (std.mem.eql(u8, t.chat_id, chat_id)) return true;
    if (self.sec.returning) |r| if (std.mem.eql(u8, r.chat_id, chat_id)) return true;
    return false;
}

pub fn transferActive(self: *const Sidebar) bool {
    return self.sec.transfer != null;
}

pub fn preview(self: *const Sidebar) ?Target {
    return if (self.sec.transfer) |t| t.preview else null;
}

/// Pointer tracking for the movement layer (registered on the list).
pub fn onListDragMove(self: *Sidebar, ev: *const zpui.DragMoveEvent(SessionDrag), _: *Window, cx: *Ctx) void {
    const grab = if (cx.app.active_drag) |d| d.cursor_offset.y else 0;
    if (self.sec.transfer == null) {
        const id = self.rowId(ev.value.ix) orelse return;
        if (self.sec.returning) |r| self.gpa.free(r.chat_id);
        self.sec.returning = null;
        self.sec.transfer = .{ .chat_id = self.gpa.dupe(u8, id) catch return, .height = ev.value.height, .pointer_y = ev.event.position.y, .grab_y = grab };
        self.hovered = null;
    }
    const t = &self.sec.transfer.?;
    t.pointer_y = ev.event.position.y;
    t.grab_y = grab;
    if (t.origin_top == null) t.origin_top = contentY(self, ev.event.position.y - grab);
    cx.notify();
}

pub fn setPreview(self: *Sidebar, target: ?Target) void {
    const t = if (self.sec.transfer) |*x| x else return;
    const same = if (t.preview) |p| (if (target) |q| std.meta.eql(p, q) else false) else target == null;
    if (same) return;
    t.prev = t.preview;
    t.preview = target;
    t.epoch += 1;
}

/// A group container under the pointer becomes the drop preview.
pub fn onGroupDragMove(self: *Sidebar, target: Target, ev: *const zpui.DragMoveEvent(SessionDrag), _: *Window, cx: *Ctx) void {
    if (!ev.bounds.contains(ev.event.position)) return;
    setPreview(self, target);
    cx.notify();
}

/// Window y → list-content y (the movement layer's coordinates).
fn contentY(self: *const Sidebar, y: f32) f32 {
    const b = self.scroll.bounds();
    return y - b.origin.y - self.scroll.offset().y;
}

/// The extra gap a destination group opens for the incoming row.
pub fn extraGap(self: *const Sidebar, target: Target) ?zpui.AnyElement {
    const t = self.sec.transfer orelse return null;
    const into = if (t.preview) |p| std.meta.eql(p, target) else false;
    const was = if (t.prev) |p| std.meta.eql(p, target) else false;
    if (!into and !was) return null;
    const full = t.height + 2;
    const Grow = struct {
        fn f(c: [2]f32, el: zpui.Div, k: f32) zpui.Div {
            return el.h(px(c[0] + (c[1] - c[0]) * k));
        }
    };
    const range = if (into) [2]f32{ 0, full } else [2]f32{ full, 0 };
    return zpui.intoAnyElement(zpui.withAnimationCtx(div().flexNone(), .{ "session-gap", @intFromEnum(std.meta.activeTag(target)) | (switch (target) {
        .section => |i| i << 2,
        else => 0,
    }) | (t.epoch << 16) }, zpui.Animation.ms(150).withEasing(zpui.easing.ease_out_quint), range, Grow.f));
}

/// The moving row (`render_moving_sidebar_session`): follows the pointer on a
/// raised surface while dragging; slides back to its slot when cancelled.
pub fn renderMoving(self: *Sidebar, row: zpui.AnyElement, height: f32, theme: *const Theme) zpui.AnyElement {
    const frame = div().absolute().left(px(zt.layout.space_sm)).right(px(zt.layout.space_sm)).h(px(height)).rounded(px(8));
    if (self.sec.transfer) |t| {
        const top = contentY(self, t.pointer_y - t.grab_y);
        return zpui.intoAnyElement(frame.top(px(top)).bg(theme.surface_raised).shadowMd().child(row));
    }
    const r = self.sec.returning orelse return row;
    const Slide = struct {
        fn f(c: [2]f32, el: zpui.Div, k: f32) zpui.Div {
            return el.top(px(c[0] + (c[1] - c[0]) * k));
        }
    };
    return zpui.intoAnyElement(zpui.withAnimationCtx(frame.child(row), .{ "sidebar-session-slide", r.epoch }, zpui.Animation.ms(150).withEasing(zpui.easing.ease_out_quint), [2]f32{ r.from, r.to }, Slide.f));
}

/// `cancel_sidebar_session_transfer`: the row slides home.
pub fn cancelTransfer(self: *Sidebar, cx: *Ctx) void {
    const t = self.sec.transfer orelse return;
    self.sec.transfer = null;
    self.pin_drag = null;
    const from = contentY(self, t.pointer_y - t.grab_y);
    if (t.origin_top) |to| if (@abs(to - from) > 0.5 and !reducedMotion(cx)) {
        if (self.sec.returning) |r| self.gpa.free(r.chat_id);
        self.sec.return_epoch += 1;
        self.sec.returning = .{ .chat_id = t.chat_id, .height = t.height, .from = from, .to = to, .epoch = self.sec.return_epoch };
        self.sec.return_task.cancel();
        self.sec.return_task = cx.timer(170 * std.time.ns_per_ms, onReturned) catch .none;
        cx.notify();
        return;
    };
    self.gpa.free(t.chat_id);
    cx.notify();
}

fn reducedMotion(cx: *Ctx) bool {
    const s = model.settings_store.current(cx.app) orelse return false;
    return s.theme.reduce_motion == .on;
}

fn onReturned(self: *Sidebar, cx: *Ctx) void {
    self.sec.return_task.detach();
    if (self.sec.returning) |r| self.gpa.free(r.chat_id);
    self.sec.returning = null;
    cx.notify();
}

/// Heal a drag released outside every drop target (`render_chat_sidebar`).
pub fn heal(self: *Sidebar, cx: *Ctx) void {
    if (self.sec.transfer != null and !cx.app.hasActiveDrag()) cancelTransfer(self, cx);
}

/// Drop on Pinned / a section / Sessions (`finish_sidebar_session_transfer`).
pub fn onGroupDrop(self: *Sidebar, target: Target, payload: *const SessionDrag, window: *Window, cx: *Ctx) void {
    cx.stopPropagation();
    finishTransfer(self, payload, target, window, cx);
}

pub fn finishTransfer(self: *Sidebar, payload: *const SessionDrag, target: Target, _: *Window, cx: *Ctx) void {
    const id_borrowed = self.rowId(payload.ix) orelse return cancelTransfer(self, cx);
    const chat_id = self.gpa.dupe(u8, id_borrowed) catch return cancelTransfer(self, cx);
    defer self.gpa.free(chat_id);
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const secs = active(self, scratch.allocator(), cx);
    const source_section: ?[]const u8 = if (sections.sectionOf(secs, chat_id)) |i| secs[i].id else null;
    const target_section: ?[]const u8 = switch (target) {
        .section => |i| if (idAt(self, i)) |sid| sid else return cancelTransfer(self, cx),
        else => null,
    };
    if (target_section) |sid| {
        var known = false;
        for (secs) |s| if (std.mem.eql(u8, s.id, sid)) {
            known = true;
        };
        if (!known) return cancelTransfer(self, cx);
    }
    const p = prefs_mod.get(cx);
    const was_pinned = p.isPinned(chat_id);
    switch (target) {
        .pinned => {
            if (payload.pinned_from) |from| {
                // Pin-to-pin keeps the sibling-slide reorder.
                const to = if (self.pin_drag) |d| d.over else from;
                self.reorderPins(from, to, cx);
            } else {
                const index = if (self.pin_drag) |d| d.over else self.pinned_count;
                pinAt(self, chat_id, index, cx);
                if (source_section != null) _ = change(self, .{ .assign = .{ .sessionId = chat_id, .sectionId = null } }, cx);
            }
            self.pinned_open = true;
        },
        .section, .regular => {
            const same_section = if (source_section) |s| (if (target_section) |t| std.mem.eql(u8, s, t) else false) else target_section == null;
            if (same_section and !was_pinned) {
                // A no-op drop animates home; groups keep their recency order.
                return cancelTransfer(self, cx);
            }
            if (was_pinned) unpin(self, chat_id, cx);
            if (!same_section and !change(self, .{ .assign = .{ .sessionId = chat_id, .sectionId = target_section } }, cx)) return cancelTransfer(self, cx);
            if (target == .regular) self.sessions_open = true;
        },
    }
    if (self.sec.transfer) |t| self.gpa.free(t.chat_id);
    self.sec.transfer = null;
    self.pin_drag = null;
    cx.notify();
}

/// Pin `chat_id` before the visible pin at `index` (or after the last).
fn pinAt(self: *Sidebar, chat_id: []const u8, index: usize, cx: *Ctx) void {
    const p = prefs_mod.mut(cx);
    if (p.isPinned(chat_id)) return;
    const n = @min(self.pinned_count, self.row_ids.items.len);
    const before: ?[]const u8 = if (index < n) self.row_ids.items[index] else null;
    const after: ?[]const u8 = if (index > 0 and index - 1 < n) self.row_ids.items[index - 1] else if (n > 0 and before == null) self.row_ids.items[n - 1] else null;
    const copy = self.gpa.dupe(u8, chat_id) catch return;
    const at = if (before) |b| p.pinIndex(b) orelse p.pins.items.len else if (after) |a| (if (p.pinIndex(a)) |i| i + 1 else p.pins.items.len) else p.pins.items.len;
    p.pins.insert(self.gpa, @min(at, p.pins.items.len), copy) catch {
        self.gpa.free(copy);
        return;
    };
    const ws = self.state.read(cx).workspace;
    ws.update(cx, model.WorkspaceStore.mutate, .{protocol.Mutate{ .changeSidebarPin = .{ .change = .{ .pin = .{
        .sessionId = chat_id,
        .after = after,
        .before = before,
    } } } }}) catch {};
}

fn unpin(self: *Sidebar, chat_id: []const u8, cx: *Ctx) void {
    const p = prefs_mod.mut(cx);
    p.setPinned(chat_id, false);
    const ws = self.state.read(cx).workspace;
    ws.update(cx, model.WorkspaceStore.mutate, .{protocol.Mutate{ .changeSidebarPin = .{ .change = .{ .unpin = .{ .sessionId = chat_id } } } }}) catch {};
}

/// `set_chat_pinned`: pinning takes the chat out of its section.
pub fn onPinned(self: *Sidebar, chat_id: []const u8, pinned: bool, cx: *Ctx) void {
    if (!pinned) return;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const secs = active(self, scratch.allocator(), cx);
    if (sections.sectionOf(secs, chat_id) != null) _ = change(self, .{ .assign = .{ .sessionId = chat_id, .sectionId = null } }, cx);
}
