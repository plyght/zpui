//! The new-session pickers (zeron `pickers.rs`: `PickerKind::{Branch,
//! Checkout, Space, Device}`) — the device + project chips floating above the
//! canvas composer (`render_new_thread_target_selectors`) and the checkout +
//! ref chips under it (`render_footer`'s draft half), each opening an anchored
//! frosted popover with search, keyboard navigation and ranked filtering.
//! The harness/model picker lives in the composer (`ModelPicker`).
//!
//! Data: projects and devices are synced workspace state; refs load through
//! `ListRefs` (stale-while-revalidate on every open, `SwitchRef` checks the
//! project folder out when a plain non-current ref is picked in local mode).
//! Fixture mode reads `refs.json` (`{ "<repo path>": [RepoRef…] }`).
//!
//! Hosting (composer hooks): `PickerRow` views render the two chip rows;
//! `checkoutPlan()` resolves the draft for the send.
//!
//! ```zig
//! const pickers = try cx.newWith(Pickers, Pickers.init, .{ app_state, fixtures });
//! const target = try cx.newWith(PickerRow, PickerRow.init, .{ pickers, .target });
//! composer.target_row = zpui.AnyView.fromEntity(target);
//! ```

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const input = @import("zeron_input");
const ui = @import("../components/root.zig");
const menu = @import("menu.zig");
const fixtures_mod = @import("../shell/fixtures.zig");
const shell_actions = @import("zeron_actions").shell;

const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = ui.Theme;
const Icon = ui.icon.Icon;
const view = model.view;
const RepoRef = view.RepoRef;
const CheckoutKind = view.CheckoutKind;
const es = model.engine_state;
const log = std.log.scoped(.pickers);

pub const Kind = enum { branch, checkout, space, device };

/// `MAX_REF_ROWS`: the ref list shows at most this many rows.
pub const max_ref_rows: usize = 100;
const footer_chip_radius: f32 = 6;
const card_inset = ui.popover.card_inset;

const RefsState = union(enum) { idle, loading, ready, failed: []u8 };

pub const Pickers = struct {
    gpa: std.mem.Allocator,
    state: Entity(model.AppState),
    fixtures: ?*fixtures_mod.Fixtures,
    search: Entity(input.TextInput),
    focus: zpui.FocusHandle,
    menu_scroll: zpui.ScrollHandle,
    subs: zpui.Subscriptions = .{},

    open: ?Kind = null,
    /// Keyboard highlight (null: nothing highlighted until the user navigates).
    active: ?usize = null,
    geometry: [4]menu.MenuGeometry = @splat(.{ .height = 320, .below = false }),
    /// The press that dismissed a menu (so the same press on its trigger
    /// doesn't reopen it).
    dismiss_press: ?zpui.Point(f32) = null,
    press_was_open: bool = false,
    last_dismissed: ?Kind = null,
    search_reset_muted: bool = false,

    // ---- draft checkout (new sessions) ----
    checkout: CheckoutKind = .local,
    branch: ?[]u8 = null,
    refs: RefsState = .idle,
    refs_arena: std.heap.ArenaAllocator,
    /// Transient lists (filtered rows) for listeners and renders; reset at
    /// each row render (nothing outlives one handler or one render).
    scratch: std.heap.ArenaAllocator,
    ref_rows: []RepoRef = &.{},
    refs_space: ?[]u8 = null,
    switching: ?[]u8 = null,
    switch_error: ?[]u8 = null,
    /// The space the branch draft belongs to (dropped when it changes).
    space_owner: ?[]u8 = null,

    pub fn init(state: Entity(model.AppState), fixtures: ?*fixtures_mod.Fixtures, cx: *Context(Pickers)) !Pickers {
        const theme = ui.theme.get(cx).forPopup();
        const search = try cx.newWith(input.TextInput, input.TextInput.init, .{input.Options{
            .placeholder = "Search…",
            .key_context = "PaletteSearch",
            .single_line = true,
            .edge_fade = false,
            .colors = .{ .text = theme.text, .placeholder = theme.text_faint, .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
        }});
        var self: Pickers = .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .fixtures = fixtures,
            .search = search,
            .focus = cx.focusHandle(),
            .menu_scroll = zpui.ScrollHandle.init(cx.gpa()),
            .refs_arena = std.heap.ArenaAllocator.init(cx.gpa()),
            .scratch = std.heap.ArenaAllocator.init(cx.gpa()),
        };
        try self.subs.add(cx.gpa(), try cx.subscribe(search, onSearch));
        try self.subs.add(cx.gpa(), try cx.observe(state.read(cx).workspace, onWorkspace));
        // Dev/testing knob (Rust parity): `ZERON_OPEN_PICKER=branch|checkout|
        // project|device` boots with that popover open (headless captures).
        if (std.c.getenv("ZERON_OPEN_PICKER")) |raw| {
            const v = std.mem.span(raw);
            self.open = if (std.mem.eql(u8, v, "branch")) .branch else if (std.mem.eql(u8, v, "checkout")) .checkout else if (std.mem.eql(u8, v, "project") or std.mem.eql(u8, v, "repo")) .space else if (std.mem.eql(u8, v, "device")) .device else null;
        }
        return self;
    }

    pub fn deinit(self: *Pickers, app: *App) void {
        self.subs.deinit(self.gpa);
        freeOpt(self.gpa, &self.branch);
        freeOpt(self.gpa, &self.refs_space);
        freeOpt(self.gpa, &self.switching);
        freeOpt(self.gpa, &self.switch_error);
        freeOpt(self.gpa, &self.space_owner);
        if (self.refs == .failed) self.gpa.free(self.refs.failed);
        self.refs_arena.deinit();
        self.scratch.deinit();
        self.menu_scroll.release();
        self.focus.release(app);
        self.search.release(app);
        self.state.release(app);
    }

    fn ws(self: *const Pickers, cx: anytype) *const model.WorkspaceStore {
        return self.state.read(cx).workspace.read(cx);
    }

    /// A project change drops the branch draft and the ref cache (the state
    /// observer's job in Rust).
    fn onWorkspace(self: *Pickers, _: Entity(model.WorkspaceStore), cx: *Context(Pickers)) void {
        const sel = self.ws(cx).selected_space;
        const same = if (self.space_owner) |o| (sel != null and std.mem.eql(u8, o, sel.?)) else sel == null;
        if (same) return;
        freeOpt(self.gpa, &self.space_owner);
        if (sel) |s| self.space_owner = self.gpa.dupe(u8, s) catch null;
        freeOpt(self.gpa, &self.branch);
        self.checkout = .local;
        if (self.open == .branch or self.open == .checkout) self.open = null;
        cx.notify();
    }

    // ---- open / close -----------------------------------------------------------------

    pub fn isOpen(self: *const Pickers) bool {
        return self.open != null;
    }

    pub fn toggle(self: *Pickers, kind: Kind, window: *Window, cx: *Context(Pickers)) void {
        const pressed_open = self.press_was_open;
        self.press_was_open = false;
        if (self.open == kind or pressed_open) {
            self.close(window, cx);
            return;
        }
        self.open = kind;
        self.menu_scroll.setOffset(.{ .x = 0, .y = 0 });
        // Clearing stale text emits `edited` after this returns: mute that one
        // event so its reset can't clobber the highlight anchored below.
        if (!self.search.read(cx).isEmpty()) {
            self.search_reset_muted = true;
            self.search.update(cx, input.TextInput.setText, .{""});
        }
        self.active = switch (kind) {
            .checkout => @as(usize, if (self.checkout == .local) 0 else 1),
            .branch => self.selectedRefIndex(cx),
            .space => self.selectedSpaceIndex(cx),
            .device => self.selectedDeviceIndex(cx),
        };
        const placeholder: ?[]const u8 = switch (kind) {
            .branch => "Search refs…",
            .space => "Search projects…",
            .device => "Search devices…",
            .checkout => null,
        };
        if (placeholder) |p| {
            self.search.update(cx, input.TextInput.setPlaceholder, .{p});
            window.focus(self.search.read(cx).focusHandle());
        } else window.focus(self.focus);
        if (kind == .branch or kind == .checkout) {
            freeOpt(self.gpa, &self.switch_error);
            self.ensureRefs(true, cx);
        }
        cx.notify();
    }

    pub fn close(self: *Pickers, window: ?*Window, cx: *Context(Pickers)) void {
        if (self.open == null) return;
        self.open = null;
        if (window) |w| if (self.focus.containsFocused(w) or self.search.read(cx).isFocused(w)) w.blur();
        cx.notify();
    }

    // ---- refs -------------------------------------------------------------------------

    /// `ensure_refs`: idle → load; forced → revalidate (rows stay while loading).
    pub fn ensureRefs(self: *Pickers, force: bool, cx: *Context(Pickers)) void {
        const w = self.ws(cx);
        const space = w.selectedSpaceRow() orelse return;
        if (!space.gitDetected) return;
        const fresh = if (self.refs_space) |rs| std.mem.eql(u8, rs, space.id) else false;
        if (fresh and self.refs == .loading) return;
        if (!force and fresh and self.refs != .idle) return;
        if (!fresh) self.resetRefs();
        freeOpt(self.gpa, &self.refs_space);
        self.refs_space = self.gpa.dupe(u8, space.id) catch null;
        if (self.fixtures != null) return self.loadFixtureRefs(space.path, cx);
        const st = self.state.read(cx);
        if (st.engine.read(cx).conn == null) return;
        if (!(force and fresh and self.refs == .ready)) self.setRefsState(.loading);
        const local = if (w.local_device_id) |l| std.mem.eql(u8, l, space.deviceId) else true;
        es.EngineState.request(st.engine, cx, Pickers, cx.entityId(), .ListRefs, ListRefsParams{
            .repoPath = space.path,
            .targetDeviceId = if (local) null else space.deviceId,
        }, onRefs) catch {
            self.setRefsState(.idle);
        };
    }

    const ListRefsParams = struct { repoPath: []const u8, targetDeviceId: ?[]const u8 = null };
    const SwitchRefParams = struct { repoPath: []const u8, refName: []const u8, targetDeviceId: ?[]const u8 = null };

    fn resetRefs(self: *Pickers) void {
        _ = self.refs_arena.reset(.retain_capacity);
        self.ref_rows = &.{};
        self.setRefsState(.idle);
    }

    fn setRefsState(self: *Pickers, s: RefsState) void {
        if (self.refs == .failed) self.gpa.free(self.refs.failed);
        self.refs = s;
    }

    fn onRefs(self: *Pickers, result: es.CallResult, cx: *Context(Pickers)) void {
        switch (result) {
            .ok => |v| {
                _ = self.refs_arena.reset(.retain_capacity);
                const a = self.refs_arena.allocator();
                const rows = std.json.parseFromValueLeaky([]RepoRef, a, v, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                    self.setRefsState(.{ .failed = std.fmt.allocPrint(self.gpa, "{t}", .{err}) catch return });
                    return cx.notify();
                };
                self.ref_rows = rows;
                self.setRefsState(.ready);
            },
            .err => |e| self.setRefsState(.{ .failed = self.gpa.dupe(u8, e.message) catch return }),
        }
        // Rows landed under an open, unsearched popover: re-home the highlight.
        if (self.open == .branch and self.search.read(cx).isEmpty()) self.active = self.selectedRefIndex(cx);
        cx.notify();
    }

    fn loadFixtureRefs(self: *Pickers, repo_path: []const u8, cx: *Context(Pickers)) void {
        const f = self.fixtures.?;
        _ = self.refs_arena.reset(.retain_capacity);
        const a = self.refs_arena.allocator();
        const io = self.ws(cx).io;
        const path = std.fs.path.join(a, &.{ f.dir, "refs.json" }) catch return;
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch {
            self.ref_rows = &.{};
            return self.setRefsState(.ready);
        };
        const map = std.json.parseFromSliceLeaky(std.json.ArrayHashMap([]RepoRef), a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
            log.warn("refs.json: {t}", .{err});
            return self.setRefsState(.{ .failed = self.gpa.dupe(u8, "invalid refs fixture") catch return });
        };
        self.ref_rows = map.map.get(repo_path) orelse &.{};
        self.setRefsState(.ready);
        cx.notify();
    }

    fn filteredRefs(self: *const Pickers, cx: anytype, out: []usize) []usize {
        const a = @constCast(&self.scratch).allocator();
        const names = a.alloc([]const u8, self.ref_rows.len) catch return out[0..0];
        for (self.ref_rows, 0..) |r, i| names[i] = r.name;
        return menu.filterIndices(self.search.read(cx).text(), names, out);
    }

    fn filteredRefsAlloc(self: *const Pickers, cx: anytype) []usize {
        const a = @constCast(&self.scratch).allocator();
        const buf = a.alloc(usize, self.ref_rows.len) catch return &.{};
        return self.filteredRefs(cx, buf);
    }

    /// The session's branch on an existing chat, the draft pick on a new one,
    /// else the current branch; capped to the displayed window.
    fn selectedRefIndex(self: *const Pickers, cx: anytype) usize {
        const rows = self.filteredRefsAlloc(cx);
        const chat_branch = if (self.ws(cx).selectedChatRow()) |c| c.branch else null;
        const selected = chat_branch orelse self.branch;
        var index: usize = 0;
        for (rows, 0..) |ix, pos| {
            const r = self.ref_rows[ix];
            if (selected) |name| {
                if (std.mem.eql(u8, r.name, name)) {
                    index = pos;
                    break;
                }
            } else if (r.current) {
                index = pos;
                break;
            }
        }
        return @min(index, max_ref_rows - 1);
    }

    /// The picked ref's row, else the repo's current branch's row.
    fn selectedRef(self: *const Pickers) ?*const RepoRef {
        for (self.ref_rows) |*r| {
            if (self.branch) |b| {
                if (std.mem.eql(u8, r.name, b)) return r;
            } else if (r.current) return r;
        }
        return null;
    }

    fn effectiveRefName(self: *const Pickers) ?[]const u8 {
        return self.branch orelse if (self.selectedRef()) |r| r.name else null;
    }

    /// The resolved on-send checkout action (strings owned by the picker).
    pub fn checkoutPlan(self: *const Pickers) view.CheckoutPlan {
        const name = self.effectiveRefName();
        return switch (self.checkout) {
            .new_worktree => .{ .new_worktree = .{ .base = name } },
            .local => if (self.selectedRef()) |r| (if (r.worktreePath) |path|
                view.CheckoutPlan{ .reuse_worktree = .{ .path = path, .branch = name orelse "" } }
            else
                view.CheckoutPlan{ .current_checkout = .{ .branch = name } }) else .{ .current_checkout = .{ .branch = name } },
        };
    }

    fn checkoutLabel(self: *const Pickers) []const u8 {
        return view.checkoutLabel(self.checkout, self.selectedRef());
    }

    /// `From <ref>` only when a NEW worktree will be created off it.
    fn refLabel(self: *const Pickers) []const u8 {
        const name = self.effectiveRefName() orelse return "Select ref";
        return if (self.checkout == .new_worktree) zpui.fmt("From {s}", .{name}) else name;
    }

    fn pickRef(self: *Pickers, row: RepoRef, window: ?*Window, cx: *Context(Pickers)) void {
        // Refs are fixed at creation: an existing session never moves.
        if (self.ws(cx).selectedChatRow() != null) return;
        if (row.worktreePath != null) {
            self.setBranch(row.name);
            self.checkout = .local;
        } else if (self.checkout == .new_worktree or row.current) {
            self.setBranch(row.name);
        } else {
            // Local mode + a plain non-current ref: check the project folder out.
            return self.switchDraftRef(row.name, cx);
        }
        self.close(window, cx);
    }

    fn setBranch(self: *Pickers, name: []const u8) void {
        const copy = self.gpa.dupe(u8, name) catch return;
        freeOpt(self.gpa, &self.branch);
        self.branch = copy;
    }

    fn switchDraftRef(self: *Pickers, name: []const u8, cx: *Context(Pickers)) void {
        if (self.switching != null) return;
        const w = self.ws(cx);
        const space = w.selectedSpaceRow() orelse return;
        freeOpt(self.gpa, &self.switch_error);
        self.switching = self.gpa.dupe(u8, name) catch return;
        if (self.fixtures != null) {
            // Fixture mode: pretend git switched the checkout.
            for (self.ref_rows) |*r| r.current = std.mem.eql(u8, r.name, name);
            return self.onSwitched(.{ .ok = .null }, cx);
        }
        const st = self.state.read(cx);
        const local = if (w.local_device_id) |l| std.mem.eql(u8, l, space.deviceId) else true;
        es.EngineState.request(st.engine, cx, Pickers, cx.entityId(), .SwitchRef, SwitchRefParams{
            .repoPath = space.path,
            .refName = name,
            .targetDeviceId = if (local) null else space.deviceId,
        }, onSwitched) catch {
            freeOpt(self.gpa, &self.switching);
            self.switch_error = self.gpa.dupe(u8, "Engine not connected") catch null;
        };
        cx.notify();
    }

    fn onSwitched(self: *Pickers, result: es.CallResult, cx: *Context(Pickers)) void {
        const name = self.switching orelse return;
        self.switching = null;
        defer self.gpa.free(name);
        switch (result) {
            .ok => {
                self.setBranch(name);
                self.open = null;
                self.ensureRefs(true, cx);
            },
            .err => |e| self.switch_error = self.gpa.dupe(u8, e.message) catch null,
        }
        cx.notify();
    }

    fn pickCheckout(self: *Pickers, kind: CheckoutKind, window: ?*Window, cx: *Context(Pickers)) void {
        if (kind == .local and self.checkout == .new_worktree) {
            if (self.selectedRef()) |r| if (r.worktreePath == null and !r.current) freeOpt(self.gpa, &self.branch);
        }
        self.checkout = kind;
        self.close(window, cx);
    }

    // ---- projects / devices -----------------------------------------------------------

    /// Projects on the canvas's device, sorted by display name.
    fn scopedSpaces(self: *const Pickers, cx: anytype) []*const engine.protocol.Space {
        const w = self.ws(cx);
        const a = @constCast(&self.scratch).allocator();
        const all = w.spacesSorted(a) catch return &.{};
        const device = w.effectiveDeviceId();
        var out: std.ArrayList(*const engine.protocol.Space) = .empty;
        for (all) |s| {
            if (device) |d| if (!std.mem.eql(u8, s.deviceId, d)) continue;
            out.append(a, s) catch {};
        }
        return out.items;
    }

    fn filteredSpaces(self: *const Pickers, cx: anytype) []*const engine.protocol.Space {
        const a = @constCast(&self.scratch).allocator();
        const spaces = self.scopedSpaces(cx);
        const names = a.alloc([]const u8, spaces.len) catch return &.{};
        for (spaces, 0..) |s, i| names[i] = view.spaceDisplayName(s);
        const buf = a.alloc(usize, spaces.len) catch return &.{};
        const ix = menu.filterIndices(self.search.read(cx).text(), names, buf);
        const out = a.alloc(*const engine.protocol.Space, ix.len) catch return &.{};
        for (ix, 0..) |i, j| out[j] = spaces[i];
        return out;
    }

    /// The current project row, or the final opt-out row; nothing when the
    /// selection is implicit.
    fn selectedSpaceIndex(self: *const Pickers, cx: anytype) ?usize {
        const w = self.ws(cx);
        const rows = self.scopedSpaces(cx);
        if (w.no_project) return rows.len;
        const sel = w.selected_space orelse return null;
        for (rows, 0..) |s, i| if (std.mem.eql(u8, s.id, sel)) return i;
        return null;
    }

    fn pickSpace(self: *Pickers, id: ?[]const u8, window: ?*Window, cx: *Context(Pickers)) void {
        const w = self.state.read(cx).workspace;
        const copy: ?[]u8 = if (id) |s| self.gpa.dupe(u8, s) catch return else null;
        defer if (copy) |c| self.gpa.free(c);
        w.update(cx, model.WorkspaceStore.selectSpace, .{@as(?[]const u8, copy)});
        self.close(window, cx);
    }

    fn pickDevice(self: *Pickers, id: []const u8, window: ?*Window, cx: *Context(Pickers)) void {
        const w = self.state.read(cx).workspace;
        const copy = self.gpa.dupe(u8, id) catch return;
        defer self.gpa.free(copy);
        w.update(cx, model.WorkspaceStore.selectDevice, .{@as([]const u8, copy)});
        self.close(window, cx);
    }

    /// This device first, then by name.
    fn deviceRows(self: *const Pickers, cx: anytype) []*const engine.protocol.Device {
        const w = self.ws(cx);
        const a = @constCast(&self.scratch).allocator();
        const devs = w.devices();
        const out = a.alloc(*const engine.protocol.Device, devs.len) catch return &.{};
        for (devs, 0..) |*d, i| out[i] = d;
        const Ctx = struct {
            local: ?[]const u8,
            fn less(c: @This(), l: *const engine.protocol.Device, r: *const engine.protocol.Device) bool {
                const ll = if (c.local) |x| std.mem.eql(u8, x, l.id) else false;
                const rl = if (c.local) |x| std.mem.eql(u8, x, r.id) else false;
                if (ll != rl) return ll;
                const o = std.ascii.orderIgnoreCase(l.name, r.name);
                if (o != .eq) return o == .lt;
                return std.mem.lessThan(u8, l.id, r.id);
            }
        };
        std.mem.sort(*const engine.protocol.Device, out, Ctx{ .local = w.local_device_id }, Ctx.less);
        return out;
    }

    fn filteredDevices(self: *const Pickers, cx: anytype) []*const engine.protocol.Device {
        const a = @constCast(&self.scratch).allocator();
        const rows = self.deviceRows(cx);
        const names = a.alloc([]const u8, rows.len) catch return &.{};
        for (rows, 0..) |d, i| names[i] = d.name;
        const buf = a.alloc(usize, rows.len) catch return &.{};
        const ix = menu.filterIndices(self.search.read(cx).text(), names, buf);
        const out = a.alloc(*const engine.protocol.Device, ix.len) catch return &.{};
        for (ix, 0..) |i, j| out[j] = rows[i];
        return out;
    }

    fn selectedDeviceIndex(self: *const Pickers, cx: anytype) usize {
        const eff = self.ws(cx).effectiveDeviceId() orelse return 0;
        for (self.deviceRows(cx), 0..) |d, i| if (std.mem.eql(u8, d.id, eff)) return i;
        return 0;
    }

    fn nowTs(self: *const Pickers, cx: anytype) model.time.Timestamp {
        if (self.fixtures) |f| if (f.meta.now) |n| if (model.time.parse(n)) |t| return t;
        return model.time.Timestamp.now(self.ws(cx).io);
    }

    // ---- keyboard ---------------------------------------------------------------------

    fn rowCount(self: *const Pickers, cx: anytype) usize {
        return switch (self.open orelse return 0) {
            .branch => @min(self.filteredRefsAlloc(cx).len, max_ref_rows),
            .checkout => 2,
            .space => self.filteredSpaces(cx).len + 1,
            .device => self.filteredDevices(cx).len,
        };
    }

    fn onSearch(self: *Pickers, _: Entity(input.TextInput), ev: *const input.TextInputEvent, cx: *Context(Pickers)) void {
        switch (ev.*) {
            .edited => {
                if (self.search_reset_muted) {
                    self.search_reset_muted = false;
                    return;
                }
                // Typing re-ranks: the highlight returns to the top row.
                self.active = if (self.search.read(cx).isEmpty()) switch (self.open orelse return) {
                    .branch => self.selectedRefIndex(cx),
                    .space => self.selectedSpaceIndex(cx),
                    .device => self.selectedDeviceIndex(cx),
                    .checkout => self.active,
                } else 0;
                self.menu_scroll.setOffset(.{ .x = 0, .y = 0 });
                cx.notify();
            },
            .escape => self.close(null, cx),
            .submitted => self.submit(null, cx),
            else => {},
        }
    }

    fn submit(self: *Pickers, window: ?*Window, cx: *Context(Pickers)) void {
        const kind = self.open orelse return;
        const active = self.active orelse return;
        switch (kind) {
            .branch => {
                const rows = self.filteredRefsAlloc(cx);
                if (active < rows.len) self.pickRef(self.ref_rows[rows[active]], window, cx);
            },
            .checkout => self.pickCheckout(if (active == 0) .local else .new_worktree, window, cx),
            .space => {
                const rows = self.filteredSpaces(cx);
                if (active < rows.len) self.pickSpace(rows[active].id, window, cx) else if (active == rows.len) self.pickSpace(null, window, cx);
            },
            .device => {
                const rows = self.filteredDevices(cx);
                if (active < rows.len) self.pickDevice(rows[active].id, window, cx);
            },
        }
    }

    fn onKey(self: *Pickers, ev: *const zpui.input.KeyDownEvent, window: *Window, cx: *Context(Pickers)) void {
        if (self.open == null) return;
        const k = ev.keystroke;
        switch (menu.classifyKey(k.key, k.modifiers.platform, k.modifiers.control)) {
            .escape => self.close(window, cx),
            .up, .down => |d| {
                self.active = menu.menuStep(self.active, self.rowCount(cx), if (d == .up) -1 else 1);
                if (self.active) |a| self.menu_scroll.scrollToItem(a);
                cx.notify();
            },
            .enter, .mod_enter => self.submit(window, cx),
            else => return,
        }
        cx.stopPropagation();
    }

    // ---- listeners --------------------------------------------------------------------

    fn onChipDown(self: *Pickers, kind: Kind, ev: *const zpui.input.MouseDownEvent, _: *Window, _: *Context(Pickers)) void {
        // A press that found this picker open closes it: the card's
        // mouse-down-out already began the close on this very press.
        const closed_here = if (self.dismiss_press) |p| p.x == ev.position.x and p.y == ev.position.y else false;
        self.press_was_open = (closed_here and self.last_dismissed == kind) or self.open == kind;
        self.dismiss_press = null;
    }

    fn onChipClick(self: *Pickers, kind: Kind, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Pickers)) void {
        self.toggle(kind, window, cx);
    }

    fn onCardOut(self: *Pickers, ev: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(Pickers)) void {
        const kind = self.open orelse return;
        self.dismiss_press = ev.position;
        self.last_dismissed = kind;
        self.close(window, cx);
    }

    fn onCardDown(self: *Pickers, _: *const zpui.input.MouseDownEvent, window: *Window, cx: *Context(Pickers)) void {
        if (self.open == null) return;
        if (!self.focus.containsFocused(window) and !self.search.read(cx).isFocused(window)) window.focus(self.focus);
    }

    fn onRefRow(self: *Pickers, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Pickers)) void {
        if (ix < self.ref_rows.len) self.pickRef(self.ref_rows[ix], window, cx);
    }

    fn onCheckoutRow(self: *Pickers, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Pickers)) void {
        self.pickCheckout(if (ix == 0) .local else .new_worktree, window, cx);
    }

    fn onSpaceRow(self: *Pickers, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Pickers)) void {
        const rows = self.filteredSpaces(cx);
        if (ix < rows.len) self.pickSpace(rows[ix].id, window, cx);
    }

    fn onNoProject(self: *Pickers, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Pickers)) void {
        self.pickSpace(null, window, cx);
    }

    fn onNewProject(self: *Pickers, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Pickers)) void {
        self.close(window, cx);
        window.dispatchAction(shell_actions.AddSpacePalette{});
    }

    fn onDeviceRow(self: *Pickers, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Context(Pickers)) void {
        const rows = self.filteredDevices(cx);
        if (ix < rows.len) self.pickDevice(rows[ix].id, window, cx);
    }

    fn onRetry(self: *Pickers, _: *const zpui.ClickEvent, _: *Window, cx: *Context(Pickers)) void {
        self.ensureRefs(true, cx);
    }

    fn setGeometry(self: *Pickers, kind: Kind, g: menu.MenuGeometry, cx: *Context(Pickers)) void {
        const slot = &self.geometry[@intFromEnum(kind)];
        if (slot.height == g.height and slot.below == g.below) return;
        slot.* = g;
        cx.notify();
    }

    // ---- render: triggers ---------------------------------------------------------------

    const Measure = struct {
        id: zpui.EntityId,
        kind: Kind,
        prefer_below: bool,
    };

    /// `measure_trigger`: records the space around the trigger for the menu.
    fn paintMeasure(m: Measure, bounds: zpui.Bounds(f32), window: *Window, app: *App) void {
        const g = menu.triggerGeometry(bounds.origin.y, bounds.origin.y + bounds.size.height, window.viewportSize().height, m.prefer_below);
        const weak: zpui.WeakEntity(Pickers) = .{ .id = m.id };
        _ = weak.update(app, setGeometry, .{ m.kind, g });
    }

    /// A footer-row trigger (t3code ghost `Button size="xs"`): icon, truncating
    /// label, chevron — the open picker keeps the hover wash.
    fn footerChip(self: *Pickers, kind: Kind, id: []const u8, i: Icon, label: []const u8, theme: *const Theme, cx: *Context(Pickers)) zpui.StatefulDiv {
        const open = self.open == kind;
        const on_canvas = self.ws(cx).selected_chat == null;
        const measure: Measure = .{ .id = cx.entityId(), .kind = kind, .prefer_below = on_canvas and (kind == .branch or kind == .checkout) };
        var chip = div().id(id).relative()
            .h(px(20)).maxW(px(280)).flex().flexRow().itemsCenter().gap(px(6)).px(px(8))
            .rounded(px(footer_chip_radius))
            .textSize(ui.rems(12)).fontWeight(500)
            .cursorPointer()
            .onMouseDown(.left, cx.listenerWith(kind, onChipDown))
            .onClick(cx.listenerWith(kind, onChipClick))
            .child(zpui.canvas(measure, paintMeasure).absolute().inset0())
            .child(ui.icon.of(i, 12, theme.text_muted.opacity(0.7)))
            .child(div().minW0().truncate().whitespaceNowrap().child(label))
            .child(ui.icon.of(.alt_arrow_down, 12, theme.text_muted.opacity(0.5)));
        chip = if (open)
            chip.bg(theme.element_hover).textColor(theme.text.opacity(0.8))
        else
            chip.textColor(theme.text_muted.opacity(0.7)).hover(sb.bg(theme.element_hover).textColor(theme.text.opacity(0.8)));
        return chip;
    }

    /// New-session destination chips (device + project) floating above the
    /// composer's trailing edge; their menus open above, right-aligned.
    pub fn renderTargetRow(self: *Pickers, cx: *Context(Pickers)) zpui.Div {
        const theme = ui.theme.get(cx);
        const w = self.ws(cx);
        const device_id = w.effectiveDeviceId();
        const device_label = if (device_id) |d| w.deviceName(d) orelse "This device" else "This device";
        const offline = if (device_id) |d| !w.deviceOnline(d, self.nowTs(cx)) else false;
        const project_label = if (w.selectedSpaceRow()) |s| view.spaceDisplayName(s) else "No project";
        var device_chip = self.footerChip(.device, "picker-device", .monitor, device_label, theme, cx);
        if (offline) device_chip = device_chip.textColor(theme.warning.opacity(0.8));
        var project_chip = self.footerChip(.space, "picker-project", .folder, project_label, theme, cx);
        if (self.open == .device) device_chip = device_chip.child(self.overlayEnd(.device, cx));
        if (self.open == .space) project_chip = project_chip.child(self.overlayEnd(.space, cx));
        return div().flexNone().flex().flexRow().itemsCenter().gap(px(4)).child(device_chip).child(project_chip);
    }

    /// New-session Git chips (checkout kind + ref) under the composer's
    /// leading edge; null when the project has no git.
    pub fn renderGitRow(self: *Pickers, cx: *Context(Pickers)) ?zpui.Div {
        const w = self.ws(cx);
        const space = w.selectedSpaceRow() orelse return null;
        if (!space.gitDetected) return null;
        self.ensureRefs(false, cx);
        const theme = ui.theme.get(cx);
        const kind_icon: Icon = if (self.checkout == .local and (self.selectedRef() == null or self.selectedRef().?.worktreePath == null)) .folder else .folder_with_files;
        var checkout_chip = self.footerChip(.checkout, "picker-checkout", kind_icon, self.checkoutLabel(), theme, cx);
        var branch_chip = self.footerChip(.branch, "picker-branch", .git_branch, self.refLabel(), theme, cx);
        if (self.open == .checkout) checkout_chip = checkout_chip.child(self.overlayStart(.checkout, cx));
        if (self.open == .branch) branch_chip = branch_chip.child(self.overlayStart(.branch, cx));
        return div().wFull().minW0().flex().flexRow().itemsCenter().gap(px(4))
            .child(div().flex().flexRow().itemsCenter().minW0().child(checkout_chip))
            .child(div().flex().flexRow().itemsCenter().minW0().child(branch_chip));
    }

    // ---- render: popovers ---------------------------------------------------------------

    fn popTheme(cx: anytype) *const Theme {
        return zpui.window.arena_mod.current().create(Theme, ui.theme.get(cx).forPopup());
    }

    fn content(self: *Pickers, kind: Kind, cx: *Context(Pickers)) zpui.Div {
        const width: f32 = switch (kind) {
            .branch => 320,
            .checkout => 224,
            .space => 280,
            .device => 224,
        };
        const theme = popTheme(cx);
        const body = switch (kind) {
            .branch => self.branchPopover(theme, cx),
            .checkout => self.checkoutPopover(theme, cx),
            .space => self.spacePopover(theme, cx),
            .device => self.devicePopover(theme, cx),
        };
        return ui.popover.card(theme).w(px(width)).maxH(px(self.geometry[@intFromEnum(kind)].height))
            .trackFocus(self.focus)
            .captureKeyDown(cx.listener(onKey))
            .onMouseDown(.left, cx.listener(onCardDown))
            .onMouseDownOut(cx.listener(onCardOut))
            .child(body);
    }

    /// Below-left (branch / checkout on the canvas) or above-left.
    fn overlayStart(self: *Pickers, kind: Kind, cx: *Context(Pickers)) zpui.Div {
        const card = self.content(kind, cx);
        return if (self.geometry[@intFromEnum(kind)].below) ui.popover.anchoredBelow(card) else ui.popover.anchoredAbove(card);
    }

    /// Right-aligned to the trigger: above (default) or below when flipped.
    fn overlayEnd(self: *Pickers, kind: Kind, cx: *Context(Pickers)) zpui.Div {
        const card = self.content(kind, cx);
        const framed = ui.popover.frostedCard(card);
        if (self.geometry[@intFromEnum(kind)].below) {
            return div().absolute().bottom(px(0)).right(px(0)).size(px(0)).child(zpui.deferred(
                zpui.anchored().anchorCorner(.top_right).snapToWindowWithMargin(.all(8))
                    .child(ui.anim.menuIn("picker-below-end", div().occlude().pt(px(6)).child(framed), -2)),
            ).withPriority(1));
        }
        return div().absolute().top(px(0)).right(px(0)).size(px(0)).child(zpui.deferred(
            zpui.anchored().anchorCorner(.bottom_right).snapToWindowWithMargin(.all(8))
                .child(ui.anim.menuIn("picker-above-end", div().occlude().pb(px(6)).child(framed), 4)),
        ).withPriority(1));
    }

    /// `search_input_frame`: full width, 4px under, ink 0.04, radius 7.
    fn searchBox(self: *Pickers) zpui.Div {
        _ = self;
        return div().mb(px(4)).px(px(10)).py(px(6)).rounded(px(ui.popover.menu_item_radius))
            .bg(zpui.Hsla{ .h = 0, .s = 0, .l = 0, .a = 0 }).textSize(ui.rems(13));
    }

    fn searchFrame(self: *Pickers, theme: *const Theme) zpui.Div {
        return self.searchBox().bg(theme.ink(0.04)).child(self.search);
    }

    /// `menu_row_nav`: selected = full wash; the keyboard cursor the same
    /// wash on an unselected row.
    fn navRow(theme: *const Theme, selected: bool, highlighted: bool) zpui.Div {
        return ui.popover.menuRow(theme, selected or highlighted);
    }

    /// `menu_scroll_host` + `menu_scroll_list` + `faded_menu_list`.
    fn scrollList(self: *Pickers, id: []const u8, max_h: f32, rows: zpui.StatefulDiv) zpui.Div {
        _ = id;
        return div().relative().mx(px(-card_inset)).child(ui.effects.edgeFaded(
            rows.px(px(card_inset)).overflowYScroll().trackScroll(self.menu_scroll).maxH(px(max_h)).flex().flexCol().gap(px(2)),
            .{ .band = 12, .top = true, .bottom = true, .scroll = self.menu_scroll },
        ));
    }

    fn note(theme: *const Theme, text: []const u8) zpui.Div {
        return div().p(px(8)).textSize(ui.rems(12)).textColor(theme.text_faint).child(text);
    }

    fn tag(theme: *const Theme, text: []const u8) zpui.Div {
        return div().flexNone().textSize(ui.rems(10)).textColor(theme.text_muted).child(text);
    }

    /// The ref picker: search, rows with right-aligned `current`/`worktree`
    /// tags, and a "Showing X of Y refs" footer when capped.
    fn branchPopover(self: *Pickers, theme: *const Theme, cx: *Context(Pickers)) zpui.Div {
        const w = self.ws(cx);
        if (w.selectedSpaceRow() == null) return note(theme, "No project selected");
        const rows = self.filteredRefsAlloc(cx);
        const total = rows.len;
        const shown = @min(total, max_ref_rows);
        const session_branch = if (w.selectedChatRow()) |c| c.branch else null;
        const selected = session_branch orelse self.branch orelse (if (self.selectedRef()) |r| r.name else null);
        const body: zpui.AnyElement = switch (self.refs) {
            .idle, .loading => zpui.intoAnyElement(skeletonRows(theme, 4, cx)),
            .failed => |msg| zpui.intoAnyElement(div().flex().flexCol().gap(px(6)).p(px(8)).textSize(ui.rems(12)).textColor(theme.danger)
                .child(msg)
                .child(div().id("branch-retry").px(px(8)).py(px(3)).rounded(px(6)).border1().borderColor(theme.border)
                    .textColor(theme.text).cursorPointer().hover(sb.bg(theme.element_hover))
                    .onClick(cx.listener(onRetry)).child("Retry"))),
            .ready => if (total == 0) zpui.intoAnyElement(note(theme, "No refs found.")) else blk: {
                var list = div().id("branch-list");
                for (rows[0..shown], 0..) |ref_ix, pos| {
                    const r = self.ref_rows[ref_ix];
                    const is_sel = if (selected) |s| std.mem.eql(u8, s, r.name) else false;
                    var row = navRow(theme, is_sel, self.active == pos).id(.{ "branch-row", pos })
                        .onClick(cx.listenerWith(ref_ix, onRefRow))
                        .child(div().flex1().minW0().truncate().whitespaceNowrap().child(r.name));
                    if (self.switching != null) row = row.opacity(0.55);
                    if (self.switching) |sw| if (std.mem.eql(u8, sw, r.name)) {
                        row = row.child(tag(theme, "switching…"));
                    };
                    if (r.current) row = row.child(tag(theme, "current")) else if (r.worktreePath != null) row = row.child(tag(theme, "worktree"));
                    list = list.child(row);
                }
                break :blk zpui.intoAnyElement(self.scrollList("branch-list", menu.listBudget(self.geometry[0].height, 144), list));
            },
        };
        var pop = div().flex().flexCol().child(self.searchFrame(theme)).child(body);
        if (self.switch_error) |e| pop = pop.child(menuSection(theme).child(div().px(px(8)).py(px(4)).textSize(ui.rems(11)).textColor(theme.danger.opacity(0.9)).child(e)));
        if (total > shown) pop = pop.child(menuSection(theme).child(div().px(px(8)).py(px(4)).textSize(ui.rems(11)).textColor(theme.text_faint)
            .child(zpui.fmt("Showing {d} of {d} refs", .{ shown, total }))));
        return pop;
    }

    /// Two rows: "Current checkout"/"Current worktree" and "New worktree".
    fn checkoutPopover(self: *Pickers, theme: *const Theme, cx: *Context(Pickers)) zpui.Div {
        const has_wt = if (self.selectedRef()) |r| r.worktreePath != null else false;
        const opts = [_]struct { CheckoutKind, []const u8, Icon }{
            .{ .local, if (has_wt) "Current worktree" else "Current checkout", if (has_wt) .folder_with_files else .folder },
            .{ .new_worktree, "New worktree", .folder_with_files },
        };
        var col = div().flex().flexCol().gap(px(2));
        for (opts, 0..) |o, ix| {
            col = col.child(navRow(theme, self.checkout == o[0], self.active == ix).id(.{ "checkout-row", ix })
                .onClick(cx.listenerWith(ix, onCheckoutRow))
                .child(ui.icon.of(o[2], 14, theme.text_muted))
                .child(div().flex1().minW0().truncate().whitespaceNowrap().child(o[1])));
        }
        return col;
    }

    /// The project popover: search, one row per project on the picked device,
    /// a full-bleed hairline, "New project…" and the opt-out row.
    fn spacePopover(self: *Pickers, theme: *const Theme, cx: *Context(Pickers)) zpui.Div {
        const w = self.ws(cx);
        const rows = self.filteredSpaces(cx);
        const selected = w.selected_space;
        const body: zpui.AnyElement = if (rows.len == 0)
            zpui.intoAnyElement(note(theme, if (self.search.read(cx).isEmpty()) "No projects on this device." else "No projects match."))
        else blk: {
            var list = div().id("space-list");
            for (rows, 0..) |s, ix| {
                const is_sel = !w.no_project and selected != null and std.mem.eql(u8, selected.?, s.id);
                list = list.child(navRow(theme, is_sel, self.active == ix).id(.{ "space-row", ix })
                    .onClick(cx.listenerWith(ix, onSpaceRow))
                    .child(div().flex1().minW0().truncate().whitespaceNowrap().child(view.spaceDisplayName(s))));
            }
            break :blk zpui.intoAnyElement(self.scrollList("space-list", menu.listBudget(self.geometry[2].height, 152), list));
        };
        const new_project = navRow(theme, false, false).id("project-new")
            .onClick(cx.listener(onNewProject))
            .child(ui.icon.of(.plus, 12, theme.text_muted))
            .child(div().flex1().minW0().truncate().whitespaceNowrap().child("New project…"));
        const no_project = navRow(theme, w.no_project, self.active == rows.len).id("project-none")
            .onClick(cx.listener(onNoProject))
            .child(ui.icon.of(.close, 12, theme.text_muted))
            .child(div().flex1().minW0().truncate().whitespaceNowrap().child("Don't work in a project"));
        return div().flex().flexCol().gap(px(2))
            .child(self.searchFrame(theme))
            .child(body)
            .child(div().my(px(2)).mx(px(-card_inset)).h(px(1)).flexNone().bg(theme.border.opacity(0.6)))
            .child(new_project)
            .child(no_project);
    }

    /// The device popover: search + one row per device (muted "You" on this
    /// device, a wifi-off glyph when offline).
    fn devicePopover(self: *Pickers, theme: *const Theme, cx: *Context(Pickers)) zpui.Div {
        const w = self.ws(cx);
        const rows = self.filteredDevices(cx);
        const eff = w.effectiveDeviceId();
        const now = self.nowTs(cx);
        const body: zpui.AnyElement = if (rows.len == 0) zpui.intoAnyElement(note(theme, "No devices match.")) else blk: {
            var list = div().id("device-list");
            for (rows, 0..) |d, ix| {
                const is_local = if (w.local_device_id) |l| std.mem.eql(u8, l, d.id) else false;
                const is_sel = if (eff) |e| std.mem.eql(u8, e, d.id) else false;
                var row = navRow(theme, is_sel, self.active == ix).id(.{ "device-row", ix })
                    .onClick(cx.listenerWith(ix, onDeviceRow))
                    .child(div().flex1().minW0().truncate().whitespaceNowrap().child(d.name));
                if (is_local) row = row.child(tag(theme, "You"));
                if (!w.deviceOnline(d.id, now)) row = row.child(ui.icon.of(.wifi_off, 12, theme.warning.opacity(0.8)));
                list = list.child(row);
            }
            break :blk zpui.intoAnyElement(self.scrollList("device-list", menu.listBudget(self.geometry[3].height, 64), list));
        };
        return div().flex().flexCol().child(self.searchFrame(theme)).child(body);
    }
};

/// `menu_section`: a trailing section under an edge-to-edge hairline.
fn menuSection(theme: *const Theme) zpui.Div {
    return div().mt(px(4)).pt(px(4)).borderT1().borderColor(theme.hairline(0.06)).flex().flexCol().gap(px(2));
}

/// Pulsing skeleton rows while refs load (`skeleton_rows`).
fn skeletonRows(theme: *const Theme, count: usize, cx: anytype) zpui.Div {
    const phase = ui.loaders.phaseOf(cx, zt.motion.zeron_pulse);
    var col = div().flex().flexCol().gap(px(6)).py(px(4));
    for (0..count) |i| {
        const p = @mod(phase - @as(f32, @floatFromInt(i)) * 0.08, 1.0);
        const wave = 0.5 - 0.5 * @cos(p * 2 * std.math.pi);
        col = col.child(div().h(px(28)).rounded(px(6)).bg(theme.ink(0.04)).opacity(0.35 + 0.4 * wave));
    }
    return col;
}

fn freeOpt(gpa: std.mem.Allocator, slot: *?[]u8) void {
    if (slot.*) |s| gpa.free(s);
    slot.* = null;
}

/// One of the composer's picker chip rows, as a view the composer mounts.
pub const PickerRow = struct {
    pickers: Entity(Pickers),
    which: Which,

    pub const Which = enum { target, git };

    pub fn init(pickers: Entity(Pickers), which: Which, cx: *Context(PickerRow)) PickerRow {
        return .{ .pickers = pickers.retain(cx), .which = which };
    }

    pub fn deinit(self: *PickerRow, app: *App) void {
        self.pickers.release(app);
    }

    pub fn render(self: *PickerRow, window: *Window, cx: *Context(PickerRow)) zpui.AnyElement {
        var l = self.pickers.lease(cx);
        defer l.end();
        _ = l.value.scratch.reset(.retain_capacity);
        if (l.value.open != null) {
            // Animations and skeleton pulses run while a menu is up.
            if (l.value.refs == .loading) window.requestAnimationFrame();
        }
        return switch (self.which) {
            .target => zpui.intoAnyElement(l.value.renderTargetRow(&l.cx)),
            .git => if (l.value.renderGitRow(&l.cx)) |r| zpui.intoAnyElement(r) else zpui.intoAnyElement(div()),
        };
    }
};
