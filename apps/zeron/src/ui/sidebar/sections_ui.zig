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
const menu_nav = @import("../pickers/menu.zig");

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

/// A row's place in the list (`render_sidebar_gap_row`'s `group`/`index`):
/// its drop target, which accordion of that target (project / device
/// groups all drop on `.regular`), and its index inside that group.
pub const Slot = struct { target: Target, group: u32 = 0, index: u32 };

/// The preview's insertion point inside the destination group
/// (`SidebarSessionGap.group` + `.index`).
pub const Insertion = struct {
    target: Target,
    group: u32 = 0,
    index: u32 = 0,
    /// The moving row's index when it lives in this same group.
    source: ?u32 = null,
};

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
    /// The group the row starts in (`source_group`); its slot collapses
    /// while another group previews the drop.
    source: ?Target = null,
    /// A pinned row (pin-to-pin keeps the sibling slide; no edge scroll).
    pinned: bool = false,
    pointer_x: f32 = 0,
    /// The row-level insertion point (siblings at/after it slide apart).
    insertion: ?Insertion = null,
    /// The moving row's own slot (recorded while its source slot renders).
    source_slot: ?Slot = null,
};

const Return = struct {
    chat_id: []u8,
    height: f32,
    from: f32,
    to: f32,
    epoch: u64,
    /// The source slot's collapse when cancelled (re-expands on the way home).
    removed: f32 = 0,
    /// The insertion the siblings had slid apart for; they slide back.
    insertion: ?Insertion = null,
    /// The destination group's extra gap when cancelled (closes on the way home).
    gap: ?Target = null,
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
    /// [motion] The section menu's closing phase (MENU_OUT).
    menu_exit: ui.popover.Exit = .{},
    /// Keyboard-highlighted menu row (`section_menu_active`).
    menu_active: ?usize = null,
    /// The menu is a native menu (macOS): `menu` keeps its target, nothing is drawn.
    menu_native: bool = false,
    /// The open menu's key focus (`section_menu_focus`).
    menu_focus: ?zpui.FocusHandle = null,
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
    /// Section open/close tweens by section id (owned keys).
    motions: std.StringHashMapUnmanaged(Motion) = .empty,
    /// Each section's open body height last frame (owned keys).
    body_heights: std.StringHashMapUnmanaged(f32) = .empty,
    /// The pending write's 20 s confirmation deadline (keyed by its id).
    write_timer: zpui.Task(void) = .none,
    write_timer_id: u64 = 0,
    /// The transfer's 16 ms frame loop (layout tweens + edge autoscroll).
    scroll_task: zpui.Task(void) = .none,
    /// The window's resolved reduced-motion flag, sampled each render
    /// (Rust `Shell::reduced_motion`: preference × OS × focus).
    reduced: bool = false,

    pub fn deinit(self: *State, gpa: std.mem.Allocator, app: *App) void {
        self.write_timer.cancel();
        self.scroll_task.cancel();
        if (self.menu_focus) |f| f.release(app);
        freeKeys(gpa, Motion, &self.motions);
        freeKeys(gpa, f32, &self.body_heights);
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

fn freeKeys(gpa: std.mem.Allocator, comptime V: type, m: *std.StringHashMapUnmanaged(V)) void {
    var it = m.keyIterator();
    while (it.next()) |k| gpa.free(k.*);
    m.deinit(gpa);
}

// ---- disclosure motion (`SidebarDisclosureMotion`, `render_sidebar_disclosure_body`) ----

/// `motion::COLLAPSE` (180 ms, CSS ease-out) plus the 120 ms settle grace.
pub const collapse_ns: u64 = 180 * std.time.ns_per_ms;
const tween_grace_ns: u64 = 120 * std.time.ns_per_ms;

pub const Motion = struct {
    epoch: u64,
    from: f32,
    to: f32,
    started: u64,

    pub fn animating(m: Motion, now: u64) bool {
        return now -| m.started < zt.motion.collapse.totalNs(1.0) + tween_grace_ns;
    }

    /// The tweened height right now (`current`).
    pub fn current(m: Motion, now: u64) f32 {
        const raw = @min(@as(f32, @floatFromInt(now -| m.started)) / @as(f32, @floatFromInt(@max(zt.motion.collapse.totalNs(1.0), 1))), 1);
        const t = zpui.easing.css_ease_out.apply(raw);
        return m.from + (m.to - m.from) * t;
    }
};

/// `begin_sidebar_disclosure_motion`: tween from the live height (or
/// `resting`) to `target`; each restart bumps the epoch.
pub fn beginMotion(self: *Sidebar, id: []const u8, resting: f32, target: f32, now: u64) void {
    const prev = self.sec.motions.get(id);
    const from = if (prev) |m| (if (m.animating(now)) m.current(now) else resting) else resting;
    const epoch = if (prev) |m| m.epoch + 1 else 1;
    const gop = self.sec.motions.getOrPut(self.gpa, id) catch return;
    if (!gop.found_existing) gop.key_ptr.* = self.gpa.dupe(u8, id) catch {
        _ = self.sec.motions.remove(id);
        return;
    };
    gop.value_ptr.* = .{ .epoch = epoch, .from = from, .to = target, .started = now };
}

fn liveMotion(self: *const Sidebar, id: []const u8, now: u64) ?Motion {
    const m = self.sec.motions.get(id) orelse return null;
    return if (m.animating(now)) m else null;
}

/// A collapsing section keeps rendering its rows until the tween ends.
pub fn sectionAnimating(self: *const Sidebar, id: []const u8, now: u64) bool {
    return liveMotion(self, id, now) != null;
}

const BodyTween = struct { from: f32, to: f32, full: f32 };

fn bodyFrame(c: BodyTween, el: zpui.Div, t: f32) zpui.Div {
    const h = c.from + (c.to - c.from) * t;
    const reveal = std.math.clamp(h / @max(c.full, 1), 0, 1);
    return el.h(px(h)).opacity(0.35 + 0.65 * reveal).relative().top(px(-3 * (1 - reveal)));
}

fn chevronFrame(c: [2]f32, el: zpui.elements.Svg, t: f32) zpui.elements.Svg {
    const reveal = c[0] + (c[1] - c[0]) * t;
    return el.withTransformation(.rotate(reveal * std.math.pi / 2.0));
}

/// `sidebar_disclosure_chevron`: the right chevron turning a quarter turn open.
fn disclosureChevron(self: *const Sidebar, id: []const u8, key_hash: u64, open: bool, tone: zpui.Hsla, now: u64) zpui.AnyElement {
    const chevron = icon.of(.alt_arrow_right, 12, tone);
    const frame = div().flexNone().size(px(12));
    if (liveMotion(self, id, now)) |m| {
        const denom = @max(@max(m.from, m.to), 1);
        const ctx = [2]f32{ std.math.clamp(m.from / denom, 0, 1), std.math.clamp(m.to / denom, 0, 1) };
        return zpui.intoAnyElement(frame.child(zpui.withAnimationCtx(chevron, .{ "sidebar-chevron", key_hash +% m.epoch }, zt.motion.collapse.animation(), ctx, chevronFrame)));
    }
    const resting: f32 = if (open) 1 else 0;
    return zpui.intoAnyElement(frame.child(chevron.withTransformation(.rotate(resting * std.math.pi / 2.0))));
}

// ---- built-in disclosures (Pinned / Sessions / Archived / project & device groups) ----

/// Record a disclosure's open body height this frame (the next toggle
/// tweens from / to it; `begin_queued_sidebar_reveal`'s measured height).
pub fn noteHeight(self: *Sidebar, id: []const u8, height: f32) void {
    if (self.sec.body_heights.getPtr(id)) |h| {
        h.* = height;
        return;
    }
    const k = self.gpa.dupe(u8, id) catch return;
    self.sec.body_heights.put(self.gpa, k, height) catch self.gpa.free(k);
}

/// A header click (`begin_sidebar_disclosure_motion`): tween from the open
/// height to 0 or back. Reduced motion skips the tween.
pub fn toggleMotion(self: *Sidebar, id: []const u8, was_open: bool, cx: *Ctx) void {
    if (self.sec.reduced) return;
    const h = self.sec.body_heights.get(id) orelse return;
    beginMotion(self, id, if (was_open) h else 0, if (was_open) 0 else h, cx.app.executor.now());
}

/// Whether a disclosure body is mid-tween (a closing body stays mounted).
pub fn disclosureAnimating(self: *const Sidebar, id: []const u8, now: u64) bool {
    return liveMotion(self, id, now) != null;
}

/// `sidebar_disclosure_chevron` for a built-in disclosure.
pub fn headerChevron(self: *const Sidebar, id: []const u8, open: bool, tone: zpui.Hsla, now: u64) zpui.AnyElement {
    return disclosureChevron(self, id, std.hash.Wyhash.hash(0, id), open, tone, now);
}

/// `render_sidebar_disclosure_body`: mid-tween the body is clipped to the
/// COLLAPSE height (fading from 0.35 and settling 3 px down), else as is.
pub fn disclosureBody(self: *const Sidebar, id: []const u8, height: f32, content: anytype, now: u64) zpui.AnyElement {
    const m = liveMotion(self, id, now) orelse return zpui.intoAnyElement(content);
    const frame = div().wFull().flexNone().overflowHidden().child(content);
    const tween: BodyTween = .{ .from = m.from, .to = m.to, .full = height };
    return zpui.intoAnyElement(zpui.withAnimationCtx(frame, .{ "sidebar-disclosure", std.hash.Wyhash.hash(0, id) +% m.epoch }, zt.motion.collapse.animation(), tween, bodyFrame));
}

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
    // The shown pin list follows the projection on the next frame; mirror it
    // now so handlers in the same frame agree (a chat joining a section
    // leaves the pins).
    if (ch == .assign) {
        const p = prefs_mod.mut(cx);
        if (ch.assign.sectionId != null and p.isPinned(ch.assign.sessionId)) p.setPinned(ch.assign.sessionId, false);
    }
    cx.notify();
    return true;
}

/// `apply_sidebar_pin_change` for pin / move / unpin: true when applied
/// (or queued). The shown list (`Prefs.pins`) is updated optimistically.
pub fn changePin(self: *Sidebar, ch: sections.PinChange, cx: *Ctx) bool {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const shown = prefs_mod.get(cx).pins.items;
    const shown_c = a.alloc([]const u8, shown.len) catch return false;
    for (shown, shown_c) |x, *y| y.* = x;
    const ws = self.state.read(cx).workspace.read(cx);
    if (ws.workspace_scope == null) {
        // No workspace scope (fixtures, before the engine reports one): the
        // device-local list is the only source.
        var next: std.ArrayList([]const u8) = .empty;
        next.appendSlice(a, shown_c) catch return false;
        sections.projectPins(a, &next, ch) catch return false;
        setShownPins(self, next.items, cx);
        cx.notify();
        return true;
    }
    const r = self.sec.ctl.changePin(ch, shown_c, env(self, cx));
    switch (r) {
        .applied => {},
        .send => sendHead(self, cx),
        .refused => return false,
        .notice => |n| {
            self.setNotice(n, cx);
            return false;
        },
    }
    var next: std.ArrayList([]const u8) = .empty;
    next.appendSlice(a, shown_c) catch return true;
    sections.projectPins(a, &next, ch) catch return true;
    setShownPins(self, next.items, cx);
    cx.notify();
    return true;
}

fn setShownPins(self: *Sidebar, ids: []const []const u8, cx: *Ctx) void {
    const p = prefs_mod.mut(cx);
    var owned: std.ArrayList([]u8) = .empty;
    for (ids) |id| owned.append(self.gpa, self.gpa.dupe(u8, id) catch continue) catch {};
    for (p.pins.items) |x| self.gpa.free(x);
    p.pins.deinit(self.gpa);
    p.pins = owned;
}

/// Per frame: the shown pins are the raw pins (overlay / local settings /
/// synced snapshot) minus section members (`active_sidebar_pins`). Without
/// a workspace scope the device-local list stays as it is.
pub fn syncPins(self: *Sidebar, secs: []const Section, cx: *Ctx) void {
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    const raw = (self.sec.ctl.rawPins(a, env(self, cx)) catch return) orelse return;
    var shown: std.ArrayList([]const u8) = .empty;
    for (raw) |id| if (sections.sectionOf(secs, id) == null) shown.append(a, id) catch return;
    const cur = prefs_mod.get(cx).pins.items;
    var same = cur.len == shown.items.len;
    if (same) for (cur, shown.items) |x, y| if (!std.mem.eql(u8, x, y)) {
        same = false;
        break;
    };
    if (!same) setShownPins(self, shown.items, cx);
}

fn sendHead(self: *Sidebar, cx: *Ctx) void {
    const head = self.sec.ctl.head() orelse return;
    const ws = self.state.read(cx).engine;
    const op: protocol.Mutate = .{ .changeSidebarPin = .{ .change = head } };
    model.EngineState.request(ws, cx, Sidebar, cx.entityId(), .Mutate, op, onWriteReply) catch {
        // The connection went away between queueing and sending.
        const id = self.sec.ctl.pendingId() orelse return;
        const f = self.sec.ctl.finish(id, .{ .err = .{ .kind = error.Closed, .message = "Engine not connected" } }, env(self, cx));
        afterFinish(self, f, cx);
        return;
    };
    // 20 s without a reply: stop the queue (the request may still run, so no
    // later intent may overtake it).
    self.sec.write_timer.cancel();
    self.sec.write_timer_id = self.sec.ctl.pendingId() orelse 0;
    self.sec.write_timer = cx.timer(sections.write_timeout_ns, onWriteTimeout) catch .none;
}

fn onWriteTimeout(self: *Sidebar, cx: *Ctx) void {
    self.sec.write_timer.detach();
    self.sec.write_timer = .none;
    if (self.sec.ctl.markUnconfirmed(self.sec.write_timer_id, env(self, cx))) {
        self.setNotice(sections.notice_unconfirmed, cx);
        cx.notify();
    }
}

fn onWriteReply(self: *Sidebar, result: model.engine_state.CallResult, cx: *Ctx) void {
    self.sec.write_timer.cancel();
    self.sec.write_timer = .none;
    const id = self.sec.ctl.pendingId() orelse return;
    const f = self.sec.ctl.finish(id, result, env(self, cx));
    afterFinish(self, f, cx);
}

fn afterFinish(self: *Sidebar, f: sections.Controller.Finish, cx: *Ctx) void {
    if (f.clear_notice) if (self.notice) |n| if (std.mem.startsWith(u8, n, "Couldn't save sidebar changes") or
        std.mem.eql(u8, n, sections.notice_waiting) or std.mem.eql(u8, n, sections.notice_unconfirmed))
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
    self.shutMenu(&self.view_menu_open, &self.view_menu_exit, cx);
    self.view_submenu = null;
    if (self.sec.menu) |m| self.gpa.free(m.id);
    self.sec.menu = null;
    self.sec.menu_exit.clear();
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
            .child(dialog.btnGhost(theme, "Cancel").id("section-cancel").role(.button).onClick(cx.listener(onDialogCancel)))
            .child(dialog.btnPrimary(theme, if (edit) "Save" else "Create section").id("section-save").role(.button)
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
    const height = self.sec.body_heights.get(owned) orelse 0;
    if (change(self, .{ .collapse = .{ .id = owned, .collapsed = open } }, cx))
        beginMotion(self, owned, if (open) height else 0, if (open) 0 else height, cx.app.executor.now());
}

fn onMenuButton(self: *Sidebar, ix: usize, ev: *const zpui.ClickEvent, window: *Window, cx: *Ctx) void {
    cx.stopPropagation();
    const id = idAt(self, ix) orelse return;
    if (self.sec.menu) |m| self.gpa.free(m.id);
    self.sec.menu = .{ .id = self.gpa.dupe(u8, id) catch return, .pos = ev.mousePosition() orelse .{ .x = 0, .y = 0 } };
    self.sec.menu_exit.clear();
    self.sec.menu_active = null;
    // macOS: the same rows as a native menu under the ⋯ button.
    const items = [_]ui.native_menu.Item{ .action("Edit section", 0), .action("Archive all", 1), .action("Delete", 2) };
    self.sec.menu_native = ui.native_menu.popUpFromClick(window, cx, ev, &items, cx.listener(onNativeMenu));
    if (self.sec.menu_native) return cx.notify();
    if (self.sec.menu_focus == null) self.sec.menu_focus = cx.focusHandle();
    window.focus(self.sec.menu_focus.?);
    cx.notify();
}

fn onNativeMenu(self: *Sidebar, sel: *const ui.native_menu.Selection, _: *Window, cx: *Ctx) void {
    if (!self.sec.menu_native) return;
    if (sel.tag) |tag| activateMenu(self, @intCast(tag), cx);
    // The native menu is gone: no exit to play.
    self.sec.menu_native = false;
    if (self.sec.menu) |m| self.gpa.free(m.id);
    self.sec.menu = null;
    self.sec.menu_exit.clear();
    cx.notify();
}

/// `begin_close`: the menu plays MENU_OUT before it is dropped (reduced
/// motion drops it at once).
fn closeMenu(self: *Sidebar, cx: *Ctx) void {
    if (self.sec.menu == null or self.sec.menu_exit.isClosing()) return;
    if (self.sec.reduced or !self.sec.menu_exit.begin(cx.app.executor.now())) {
        if (self.sec.menu) |m| self.gpa.free(m.id);
        self.sec.menu = null;
        self.sec.menu_exit.clear();
    } else ui.popover.reap(Sidebar, cx);
    cx.notify();
}

fn onMenuOutside(self: *Sidebar, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Ctx) void {
    closeMenu(self, cx);
}

/// The menu's keys: Escape closes, ↑/↓ move the highlight (wrapping),
/// Enter runs the highlighted action.
fn onMenuKey(self: *Sidebar, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Ctx) void {
    const key = ev.keystroke.key;
    if (self.sec.menu_exit.isClosing()) return;
    if (std.mem.eql(u8, key, "escape")) {
        closeMenu(self, cx);
    } else if (std.mem.eql(u8, key, "up") or std.mem.eql(u8, key, "down")) {
        self.sec.menu_active = menu_nav.menuStep(self.sec.menu_active, 3, if (std.mem.eql(u8, key, "up")) -1 else 1);
    } else if (std.mem.eql(u8, key, "enter")) {
        if (self.sec.menu_active) |action| activateMenu(self, @intCast(action), cx);
    } else return;
    cx.stopPropagation();
    cx.notify();
}

fn onMenuAction(self: *Sidebar, action: u8, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    cx.stopPropagation();
    activateMenu(self, action, cx);
}

/// `activate_section_menu`: 0 Edit section, 1 Archive all, 2 Delete.
fn activateMenu(self: *Sidebar, action: u8, cx: *Ctx) void {
    if (self.sec.menu_exit.isClosing()) return;
    const m = self.sec.menu orelse return;
    const id = self.gpa.dupe(u8, m.id) catch return;
    defer self.gpa.free(id);
    closeMenu(self, cx);
    switch (action) {
        0 => openDialog(self, id, cx),
        1 => archiveSection(self, id, cx),
        else => {
            cancelTransfer(self, cx);
            _ = change(self, .{ .delete = .{ .id = id } }, cx);
        },
    }
    cx.notify();
}

pub fn renderMenu(self: *Sidebar, theme_in: *const Theme, cx: *Ctx) ?zpui.AnyElement {
    const now = cx.app.executor.now();
    if (self.sec.menu_exit.done(now)) {
        if (self.sec.menu) |m| self.gpa.free(m.id);
        self.sec.menu = null;
        self.sec.menu_exit.clear();
    }
    const exit = self.sec.menu_exit.progress(now);
    const m = self.sec.menu orelse return null;
    if (self.sec.menu_native) return null;
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
    if (self.sec.menu_focus) |f| card = card.trackFocus(f);
    for ([_][]const u8{ "Edit section", "Archive all", "Delete" }, 0..) |label, i| {
        card = card.child(ui.popover.menuRow(theme, self.sec.menu_active == i).id(.{ "section-action", i }).role(.menu_item)
            .onClick(cx.listenerWith(@as(u8, @intCast(i)), onMenuAction)).child(label));
    }
    return ui.popover.anchoredAtExit(m.pos, card, exit);
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

/// `render_custom_sidebar_section`. `rows_height` is the members' rows
/// plus their gaps; the body tweens its height on open / close.
pub fn renderSection(self: *Sidebar, ix: usize, section: Section, body_rows: zpui.Div, empty: bool, rows_height: f32, extra_gap: ?zpui.AnyElement, extra: f32, theme: *const Theme, cx: *Ctx) zpui.StatefulDiv {
    const open = !section.collapsed;
    const now = cx.app.executor.now();
    const key_hash = std.hash.Wyhash.hash(0, section.id);
    const height = 4 + extra + (if (empty) @as(f32, 40) else rows_height);
    if (self.sec.body_heights.getPtr(section.id)) |h| h.* = height else if (self.gpa.dupe(u8, section.id)) |k| {
        self.sec.body_heights.put(self.gpa, k, height) catch self.gpa.free(k);
    } else |_| {}
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
    header = header.child(disclosureChevron(self, section.id, key_hash, open, tone, now));
    var out = div().id(.{ "custom-section", ix }).wFull().flex().flexCol().pt(px(12))
        .onDragMove(SessionDrag, cx.listenerWith(Target{ .section = ix }, onGroupDragMove))
        .onDrop(SessionDrag, cx.listenerWith(Target{ .section = ix }, onGroupDrop))
        .child(header);
    const motion = liveMotion(self, section.id, now);
    if (open or motion != null) {
        var content = div().wFull().flex().flexCol().pt(px(4)).gap(px(2));
        if (empty) content = content.child(div().h(px(40)).px(px(zt.layout.space_sm)).flex().itemsCenter()
            .textSize(rems(12)).textColor(tone).child("Drop sessions here"));
        content = content.child(body_rows).child(extra_gap);
        if (motion) |m| {
            const frame = div().wFull().flexNone().overflowHidden().child(content);
            const tween: BodyTween = .{ .from = m.from, .to = m.to, .full = height };
            out = out.child(zpui.withAnimationCtx(frame, .{ "sidebar-disclosure", key_hash +% m.epoch }, zt.motion.collapse.animation(), tween, bodyFrame));
        } else out = out.child(content);
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
        self.sec.transfer = .{
            .chat_id = self.gpa.dupe(u8, id) catch return,
            .height = ev.value.height,
            .pointer_y = ev.event.position.y,
            .grab_y = grab,
            .pinned = ev.value.pinned_from != null,
            .source = sourceOf(self, id, cx),
        };
        self.hovered = null;
        startDragLoop(self, cx);
    }
    const t = &self.sec.transfer.?;
    t.pointer_x = ev.event.position.x;
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

/// The group `chat_id` is shown in (`source_group`).
fn sourceOf(self: *Sidebar, chat_id: []const u8, cx: *Ctx) Target {
    if (prefs_mod.get(cx).isPinned(chat_id)) return .pinned;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const secs = active(self, scratch.allocator(), cx);
    return if (sections.sectionOf(secs, chat_id)) |i| .{ .section = i } else .regular;
}

// ---- drag frame loop + edge autoscroll (`begin_sidebar_session_transfer`) --------------

/// `SIDEBAR_DRAG_SCROLL_BAND` / `SIDEBAR_DRAG_SCROLL_MAX` / `_FRAME_MS`.
pub const drag_scroll_band: f32 = 48;
pub const drag_scroll_max: f32 = 12;
const drag_frame_ns: u64 = 16 * std.time.ns_per_ms;

/// `pinned_drag_scroll_delta`: px per frame toward the nearer edge,
/// proportional to how deep the pointer sits in the 48px band.
pub fn dragScrollDelta(pointer_y: f32, top: f32, bottom: f32) f32 {
    if (bottom <= top) return 0;
    if (pointer_y < top + drag_scroll_band)
        return -drag_scroll_max * std.math.clamp((top + drag_scroll_band - pointer_y) / drag_scroll_band, 0, 1);
    if (pointer_y > bottom - drag_scroll_band)
        return drag_scroll_max * std.math.clamp((pointer_y - (bottom - drag_scroll_band)) / drag_scroll_band, 0, 1);
    return 0;
}

fn startDragLoop(self: *Sidebar, cx: *Ctx) void {
    self.sec.scroll_task.cancel();
    self.sec.scroll_task = cx.timer(drag_frame_ns, onDragFrame) catch .none;
}

/// One frame of the transfer loop: layout keeps animating while the pointer
/// rests, and a non-pinned row scrolls the list near the viewport edges
/// (pinned rows keep their sibling-slide reorder).
fn onDragFrame(self: *Sidebar, cx: *Ctx) void {
    self.sec.scroll_task.detach();
    self.sec.scroll_task = .none;
    const t = self.sec.transfer orelse return;
    if (!cx.app.hasActiveDrag()) return;
    cx.notify();
    if (!t.pinned) {
        const b = self.scroll.bounds();
        const inside = t.pointer_x >= b.origin.x and t.pointer_x <= b.origin.x + b.size.width and
            t.pointer_y >= b.origin.y and t.pointer_y <= b.origin.y + b.size.height;
        if (inside) {
            const delta = dragScrollDelta(t.pointer_y, b.origin.y, b.origin.y + b.size.height);
            const off = self.scroll.offset();
            const top = -off.y;
            const next = std.math.clamp(top + delta, 0, @max(self.scroll.maxOffset().y, 0));
            if (next != top) self.scroll.setOffset(.{ .x = off.x, .y = -next });
        }
    }
    startDragLoop(self, cx);
}

/// The height a destination group's gap opens to (0 when not previewed).
pub fn extraHeight(self: *const Sidebar, target: Target) f32 {
    const t = self.sec.transfer orelse return 0;
    const p = t.preview orelse return 0;
    return if (std.meta.eql(p, target) and !isSource(t, target)) t.height + 2 else 0;
}

/// The destination is the row's own group (no extra gap: the source slot
/// stays open there).
fn isSource(t: Transfer, target: Target) bool {
    const src = t.source orelse return false;
    return std.meta.eql(src, target);
}

fn collapsesFrom(src: Target, target: ?Target) bool {
    const p = target orelse return false;
    return !std.meta.eql(p, src);
}

/// The moving row's vacated slot: it collapses (row + the list gap it
/// shares) while another group previews the drop, so the vacancy moves to
/// the destination instead of leaving two holes; it re-opens when the
/// preview returns or the row slides home.
pub fn sourceSlot(self: *const Sidebar, h: f32, gap: f32) zpui.AnyElement {
    const full = h + gap;
    const SlotAnim = struct {
        fn f(c: [3]f32, el: zpui.Div, k: f32) zpui.Div {
            const left = c[0] - (c[1] + (c[2] - c[1]) * k);
            return el.h(px(@max(left, 0))).mb(px(@min(left, 0)));
        }
    };
    const anim = zt.motion.tab_slide.animation();
    if (self.sec.transfer) |t| {
        const src = t.source orelse return zpui.intoAnyElement(div().h(px(h)).flexNone());
        const now = collapsesFrom(src, t.preview);
        const was = collapsesFrom(src, t.prev);
        if (!now and !was) return zpui.intoAnyElement(div().h(px(h)).flexNone());
        const range = [3]f32{ h, if (was) full else 0, if (now) full else 0 };
        return zpui.intoAnyElement(zpui.withAnimationCtx(div().flexNone(), .{ "session-source-slot", t.epoch }, anim, range, SlotAnim.f));
    }
    if (self.sec.returning) |r| if (r.removed > 0) {
        return zpui.intoAnyElement(zpui.withAnimationCtx(div().flexNone(), .{ "session-source-return", r.epoch }, anim, [3]f32{ h, full, 0 }, SlotAnim.f));
    };
    return zpui.intoAnyElement(div().h(px(h)).flexNone());
}

/// The extra gap a destination group opens for the incoming row.
pub fn extraGap(self: *const Sidebar, target: Target) ?zpui.AnyElement {
    return extraGapIn(self, target, 0);
}

/// `extraGap` for accordion `group` of `target` (project / device groups
/// share `.regular`; only the previewed one opens).
pub fn extraGapIn(self: *const Sidebar, target: Target, group: u32) ?zpui.AnyElement {
    const Grow = struct {
        fn f(c: [2]f32, el: zpui.Div, k: f32) zpui.Div {
            return el.h(px(c[0] + (c[1] - c[0]) * k));
        }
    };
    const t = self.sec.transfer orelse {
        // Cancelled: the destination's gap closes while the row slides home.
        const r = self.sec.returning orelse return null;
        const g = r.gap orelse return null;
        if (!std.meta.eql(g, target) or self.sec.reduced) return null;
        if (r.insertion) |ins| if (ins.group != group) return null;
        return zpui.intoAnyElement(zpui.withAnimationCtx(div().flexNone(), .{ "session-gap-return", r.epoch }, zt.motion.tab_slide.animation(), [2]f32{ r.height + 2, 0 }, Grow.f));
    };
    if (t.insertion) |ins| if (std.meta.eql(ins.target, target) and ins.group != group) return null;
    const into = if (t.preview) |p| std.meta.eql(p, target) and !isSource(t, target) else false;
    const was = if (t.prev) |p| std.meta.eql(p, target) and !isSource(t, target) else false;
    if (!into and !was) return null;
    const full = t.height + 2;
    if (self.sec.reduced) return if (into) zpui.intoAnyElement(div().flexNone().h(px(full))) else null;
    const range = if (into) [2]f32{ 0, full } else [2]f32{ full, 0 };
    return zpui.intoAnyElement(zpui.withAnimationCtx(div().flexNone(), .{ "session-gap", @intFromEnum(std.meta.activeTag(target)) | (switch (target) {
        .section => |i| i << 2,
        else => 0,
    }) | (t.epoch << 16) }, zt.motion.tab_slide.animation(), range, Grow.f));
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
    return zpui.intoAnyElement(zpui.withAnimationCtx(frame.child(row), .{ "sidebar-session-slide", r.epoch }, zt.motion.tab_slide.animation(), [2]f32{ r.from, r.to }, Slide.f));
}

/// `cancel_sidebar_session_transfer`: the row slides home.
pub fn cancelTransfer(self: *Sidebar, cx: *Ctx) void {
    const t = self.sec.transfer orelse return;
    self.sec.transfer = null;
    self.pin_drag = null;
    self.sec.scroll_task.cancel();
    self.sec.scroll_task = .none;
    const from = contentY(self, t.pointer_y - t.grab_y);
    if (t.origin_top) |to| if (@abs(to - from) > 0.5 and !reducedMotion(self, cx)) {
        if (self.sec.returning) |r| self.gpa.free(r.chat_id);
        self.sec.return_epoch += 1;
        const removed: f32 = if (t.source) |src| (if (collapsesFrom(src, t.preview)) t.height + 2 else 0) else 0;
        const gap: ?Target = if (t.preview) |p| (if (isSource(t, p) or p == .pinned) null else p) else null;
        self.sec.returning = .{ .chat_id = t.chat_id, .height = t.height, .from = from, .to = to, .epoch = self.sec.return_epoch, .removed = removed, .insertion = t.insertion, .gap = gap };
        self.sec.return_task.cancel();
        self.sec.return_task = cx.timer(zt.motion.tab_slide.totalNs(1.0) + 20 * std.time.ns_per_ms, onReturned) catch .none;
        cx.notify();
        return;
    };
    self.gpa.free(t.chat_id);
    cx.notify();
}

fn reducedMotion(self: *const Sidebar, cx: *Ctx) bool {
    if (self.sec.reduced) return true;
    const s = model.settings_store.current(cx.app) orelse return false;
    return s.theme.reduce_motion == .on;
}

// ---- destination sibling slide (`render_sidebar_gap_row`) -------------------------------

/// `sidebar_gap_offset`: how far row `row` of a group moves to open the
/// insertion `boundary` (`source` = the moving row's index when it lives in
/// the same group).
pub fn gapOffset(row: u32, source: ?u32, boundary: u32, height: f32) f32 {
    if (source) |src| {
        if (row == src) return 0;
        if (row < src and row >= boundary) return height;
        if (row > src and row < boundary) return -height;
        return 0;
    }
    return if (row >= boundary) height else 0;
}

/// A destination row's vertical offset for the live preview: siblings at
/// and after the insertion point slide apart by one slot. Pin-to-pin keeps
/// its own sibling slide; a row never offsets in another accordion.
fn liveOffset(t: Transfer, slot: Slot) f32 {
    const ins = t.insertion orelse return 0;
    if (slot.target == .pinned) return 0;
    if (!std.meta.eql(ins.target, slot.target) or ins.group != slot.group) return 0;
    const p = t.preview orelse return 0;
    if (!std.meta.eql(p, slot.target)) return 0;
    return gapOffset(slot.index, ins.source, ins.index, t.height + 2);
}

/// Wrap a placed row: the hit region (and its insertion listener) stays at
/// the natural slot while the content slides. While dragging the offset is
/// applied directly (Rust: `frame.top(px(to))`); a cancelled drop slides the
/// siblings back over TAB_SLIDE.
pub fn placeRow(self: *Sidebar, row: zpui.AnyElement, slot: Slot, cx: *Ctx) zpui.AnyElement {
    const outer = div().flexNone().onDragMove(SessionDrag, cx.listenerWith(slot, onRowDragMove));
    if (self.sec.transfer) |t| {
        const dy = liveOffset(t, slot);
        if (dy == 0) return zpui.intoAnyElement(outer.child(row));
        return zpui.intoAnyElement(outer.child(div().relative().top(px(dy)).child(row)));
    }
    if (self.sec.returning) |r| if (r.insertion) |ins| if (!self.sec.reduced) {
        if (slot.target != .pinned and std.meta.eql(ins.target, slot.target) and ins.group == slot.group) {
            const from = gapOffset(slot.index, ins.source, ins.index, r.height + 2);
            if (from != 0) {
                const Slide = struct {
                    fn f(c: [2]f32, el: zpui.Div, k: f32) zpui.Div {
                        return el.top(px(c[0] + (c[1] - c[0]) * k));
                    }
                };
                return zpui.intoAnyElement(outer.child(zpui.withAnimationCtx(div().relative().child(row), .{ "session-gap-row", (slot.index & 0xffff) | (r.epoch << 16) }, zt.motion.tab_slide.animation(), [2]f32{ from, 0 }, Slide.f)));
            }
        }
    };
    return zpui.intoAnyElement(outer.child(row));
}

/// Record the moving row's own slot (its source slot is rendering).
pub fn noteSource(self: *Sidebar, slot: Slot) void {
    if (self.sec.transfer) |*t| t.source_slot = slot;
}

/// Row-level insertion tracking: past a row's centre inserts after it.
fn onRowDragMove(self: *Sidebar, slot: Slot, ev: *const zpui.DragMoveEvent(SessionDrag), _: *Window, cx: *Ctx) void {
    if (!ev.bounds.contains(ev.event.position)) return;
    const t = if (self.sec.transfer) |*x| x else return;
    const after = ev.event.position.y >= ev.bounds.origin.y + ev.bounds.size.height / 2;
    const src: ?u32 = if (t.source_slot) |s| (if (std.meta.eql(s.target, slot.target) and s.group == slot.group) s.index else null) else null;
    const next: Insertion = .{ .target = slot.target, .group = slot.group, .index = slot.index + @intFromBool(after), .source = src };
    if (t.insertion) |cur| if (std.meta.eql(cur, next)) return;
    t.insertion = next;
    cx.notify();
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
    self.sec.scroll_task.cancel();
    self.sec.scroll_task = .none;
    self.pin_drag = null;
    cx.notify();
}

/// Pin `chat_id` before the visible pin at `index` (or after the last).
fn pinAt(self: *Sidebar, chat_id: []const u8, index: usize, cx: *Ctx) void {
    if (prefs_mod.get(cx).isPinned(chat_id)) return;
    const n = @min(self.pinned_count, self.row_ids.items.len);
    const before: ?[]const u8 = if (index < n) self.row_ids.items[index] else null;
    const after: ?[]const u8 = if (index > 0 and index - 1 < n) self.row_ids.items[index - 1] else if (n > 0 and before == null) self.row_ids.items[n - 1] else null;
    _ = changePin(self, .{ .pin = .{ .sessionId = chat_id, .after = after, .before = before } }, cx);
}

fn unpin(self: *Sidebar, chat_id: []const u8, cx: *Ctx) void {
    _ = changePin(self, .{ .unpin = .{ .sessionId = chat_id } }, cx);
}

/// `set_chat_pinned` (the row menu's Pin / Unpin).
pub fn setChatPinned(self: *Sidebar, chat_id: []const u8, pinned: bool, cx: *Ctx) void {
    if (prefs_mod.get(cx).isPinned(chat_id) == pinned) return;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const a = scratch.allocator();
    // Pinned but hidden by a section: clearing the membership shows the pin.
    const raw: ?[]const []const u8 = self.sec.ctl.rawPins(a, env(self, cx)) catch null;
    if (pinned) if (raw) |ids| for (ids) |id| if (std.mem.eql(u8, id, chat_id)) {
        _ = change(self, .{ .assign = .{ .sessionId = chat_id, .sectionId = null } }, cx);
        return;
    };
    const shown = prefs_mod.get(cx).pins.items;
    const last: ?[]const u8 = if (shown.len > 0) a.dupe(u8, shown[shown.len - 1]) catch null else null;
    const ok = if (pinned)
        changePin(self, .{ .pin = .{ .sessionId = chat_id, .after = last, .before = null } }, cx)
    else
        changePin(self, .{ .unpin = .{ .sessionId = chat_id } }, cx);
    const scope = self.state.read(cx).workspace.read(cx).workspace_scope;
    const local = scope == null or scope.? == .local;
    if (ok and pinned and local) onPinned(self, chat_id, true, cx);
}

/// `set_chat_pinned`: pinning takes the chat out of its section.
pub fn onPinned(self: *Sidebar, chat_id: []const u8, pinned: bool, cx: *Ctx) void {
    if (!pinned) return;
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const secs = active(self, scratch.allocator(), cx);
    if (sections.sectionOf(secs, chat_id) != null) _ = change(self, .{ .assign = .{ .sessionId = chat_id, .sectionId = null } }, cx);
}

test "edge autoscroll is proportional inside the band (spaces.rs pinned_edge_scroll)" {
    const t = std.testing;
    try t.expectEqual(@as(f32, 0), dragScrollDelta(200, 100, 300));
    try t.expectEqual(@as(f32, -6), dragScrollDelta(124, 100, 300));
    try t.expectEqual(@as(f32, 6), dragScrollDelta(276, 100, 300));
    try t.expectEqual(@as(f32, -12), dragScrollDelta(90, 100, 300));
    try t.expectEqual(@as(f32, 0), dragScrollDelta(150, 300, 100));
}
