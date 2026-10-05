//! Project actions (zeron `project_actions.rs` + `shell/actions_ui.rs`): the
//! titlebar's split Run/Setup control for the selected session's project,
//! its menu (run, edit, import from `zeron.json`, add), the add/edit/delete
//! dialogs, and `RunProjectAction` into a terminal tab.
//!
//! Host-owned: every RPC carries `spaceId` (+ `targetDeviceId` when the
//! session lives on another device): `ListProjectActions`,
//! `UpsertProjectAction {actionId?, action}`, `DeleteProjectAction`,
//! `RunProjectAction {chatId, actionId, cols, rows}`. Replies are snapshots.
//! The controller keeps a per-(device, space) cache so switching projects
//! never borrows another project's actions, and generation counters drop
//! late replies.
//!
//! ```zig
//! // titlebar.zig
//! if (project_actions.control(shell, available_width, theme, liquid, cx)) |c| inner = inner.child(c);
//! // wiring.overlays
//! if (project_actions.overlay(shell, window, theme, cx)) |d| return d;
//! ```

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const input_mod = @import("zeron_input");
const ui = @import("../components/root.zig");
const dialog = @import("../components/dialog.zig");
const shell_mod = @import("shell.zig");
const right_pane_mod = @import("right_pane.zig");
const terminal_panel = @import("terminal_panel.zig");
const prefs_mod = @import("prefs.zig");

const Allocator = std.mem.Allocator;
const json = std.json;
const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = ui.Theme;
const icon = ui.icon;
const Shell = shell_mod.Shell;
const TextInput = input_mod.TextInput;
const Ctx = Context(Shell);
const protocol = engine.protocol;

// ---- protocol (zeron_proto entities.rs) ----------------------------------------------------

/// `ProjectActionIcon` (kebab-case on the wire).
pub const ActionIcon = enum { play, @"test", lint, configure, build, debug };

pub const Action = struct {
    id: []const u8,
    name: []const u8,
    command: []const u8,
    icon: ActionIcon,
    runOnWorktreeCreate: bool,
};

pub const Draft = struct {
    name: []const u8,
    command: []const u8,
    icon: ActionIcon,
    runOnWorktreeCreate: bool = false,
};

pub const Snapshot = struct {
    spaceId: []const u8,
    actions: []const Action = &.{},
    importableActions: []const Draft = &.{},
    projectFileIssue: ?[]const u8 = null,
};

pub const Run = struct {
    actionId: []const u8,
    actionName: []const u8,
    terminal: protocol.TerminalSession,
};

const parse_opts: json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

// ---- pure helpers (project_actions.rs) -----------------------------------------------------

pub const action_icons = [_]struct { ActionIcon, []const u8 }{
    .{ .play, "Play" },       .{ .@"test", "Test" },   .{ .lint, "Lint" },
    .{ .configure, "Configure" }, .{ .build, "Build" }, .{ .debug, "Debug" },
};

pub fn actionIcon(i: ActionIcon) ui.icon.Icon {
    return switch (i) {
        .play => .action_play,
        .@"test" => .action_test,
        .lint => .action_lint,
        .configure => .action_configure,
        .build => .action_build,
        .debug => .action_debug,
    };
}

const action_label_min_titlebar_width: f32 = 420;

pub fn showActionLabel(available_titlebar_width: f32) bool {
    return available_titlebar_width >= action_label_min_titlebar_width;
}

/// `preferred_action`: the remembered one, else the first non-setup, else the first.
pub fn preferredAction(actions: []const Action, preferred_id: ?[]const u8) ?*const Action {
    if (preferred_id) |p| for (actions) |*a| if (std.mem.eql(u8, a.id, p)) return a;
    for (actions) |*a| if (!a.runOnWorktreeCreate) return a;
    return if (actions.len > 0) &actions[0] else null;
}

pub fn unknownMethod(message: []const u8) bool {
    return containsIgnoreCase(message, "unknown method") or containsIgnoreCase(message, "unknownmethod");
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) if (std.ascii.eqlIgnoreCase(hay[i..][0..needle.len], needle)) return true;
    return false;
}

/// `save_project_action` validation (trimmed inputs).
pub fn validateDraft(name: []const u8, command: []const u8) ?[]const u8 {
    if (name.len == 0) return "Action name is required";
    if ((std.unicode.utf8CountCodepoints(name) catch name.len) > 80) return "Action name must not exceed 80 characters";
    if (command.len == 0) return "Action command is required";
    if (command.len > 16 * 1024) return "Action command must not exceed 16384 bytes";
    return null;
}

/// `tracked_upper`: uppercase with hair-space tracking (menu headings).
pub fn trackedUpper(a: Allocator, label: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (label, 0..) |c, i| {
        if (i > 0) out.appendSlice(a, "\u{200A}") catch return label;
        out.append(a, std.ascii.toUpper(c)) catch return label;
    }
    return out.items;
}

// ---- controller (ProjectActionsController) ---------------------------------------------------

pub const Key = struct {
    device_id: []const u8,
    space_id: []const u8,

    pub fn eql(a: Key, b: Key) bool {
        return std.mem.eql(u8, a.device_id, b.device_id) and std.mem.eql(u8, a.space_id, b.space_id);
    }
};

pub const Status = union(enum) {
    idle,
    loading,
    ready: json.Parsed(Snapshot),
    saving: json.Parsed(Snapshot),
    unavailable: struct { snapshot: ?json.Parsed(Snapshot), message: []u8 },
    unsupported,

    pub fn snapshot(self: *const Status) ?*const Snapshot {
        return switch (self.*) {
            .ready, .saving => |*p| &p.value,
            .unavailable => |*u| if (u.snapshot) |*p| &p.value else null,
            else => null,
        };
    }

    pub fn canRun(self: *const Status) bool {
        return self.* == .ready;
    }

    fn takeSnapshot(self: *Status) ?json.Parsed(Snapshot) {
        return switch (self.*) {
            .ready, .saving => |p| blk: {
                self.* = .idle;
                break :blk p;
            },
            .unavailable => |*u| blk: {
                const p = u.snapshot;
                u.snapshot = null;
                break :blk p;
            },
            else => null,
        };
    }

    fn deinit(self: *Status, gpa: Allocator) void {
        switch (self.*) {
            .ready, .saving => |*p| p.deinit(),
            .unavailable => |*u| {
                if (u.snapshot) |*p| p.deinit();
                gpa.free(u.message);
            },
            else => {},
        }
        self.* = .idle;
    }
};

const Entry = struct { key: Key, status: Status };

pub const Editor = struct {
    key: Key,
    action_id: ?[]u8,
    name: Entity(TextInput),
    command: Entity(TextInput),
    icon: ActionIcon,
    run_on_worktree_create: bool,
    err: ?[]u8 = null,
    saving: bool = false,
    focus_pending: bool = true,
    confirm_delete: bool = false,
    subs: [2]zpui.Subscription,
};

pub const Controller = struct {
    gpa: Allocator,
    active: ?Key = null,
    generation: u64 = 0,
    mutation_generation: u64 = 0,
    cache: std.ArrayList(Entry) = .empty,
    menu_open: bool = false,
    menu_scroll: ?zpui.ScrollHandle = null,
    editor: ?Editor = null,
    /// In-flight list replies, oldest first (replies carry no context).
    loads: std.ArrayList(struct { key: Key, generation: u64 }) = .empty,
    /// In-flight mutation (upsert / delete).
    mutation: ?struct { key: Key, generation: u64, delete: bool, action_id: ?[]u8 } = null,
    /// In-flight runs (FIFO): the chat, target and tab title.
    /// In-flight `RunProjectAction`s with their reserved terminal tab.
    runs: std.ArrayList(struct { key: Key, chat_id: []u8, target: ?[]u8, action_id: []u8, name: []u8, tab: ?u64 = null }) = .empty,

    pub fn init(gpa: Allocator) Controller {
        return .{ .gpa = gpa };
    }

    fn dupeKey(self: *Controller, k: Key) ?Key {
        const d = self.gpa.dupe(u8, k.device_id) catch return null;
        const s = self.gpa.dupe(u8, k.space_id) catch {
            self.gpa.free(d);
            return null;
        };
        return .{ .device_id = d, .space_id = s };
    }

    fn freeKey(self: *Controller, k: Key) void {
        self.gpa.free(k.device_id);
        self.gpa.free(k.space_id);
    }

    pub fn deinit(self: *Controller, app: *App) void {
        self.closeEditor(app);
        if (self.active) |k| self.freeKey(k);
        for (self.cache.items) |*e| {
            e.status.deinit(self.gpa);
            self.freeKey(e.key);
        }
        self.cache.deinit(self.gpa);
        for (self.loads.items) |l| self.freeKey(l.key);
        self.loads.deinit(self.gpa);
        self.clearMutation();
        for (self.runs.items) |r| {
            self.freeKey(r.key);
            self.gpa.free(r.chat_id);
            if (r.target) |t| self.gpa.free(t);
            self.gpa.free(r.action_id);
            self.gpa.free(r.name);
        }
        self.runs.deinit(self.gpa);
        if (self.menu_scroll) |s| s.release();
    }

    fn clearMutation(self: *Controller) void {
        if (self.mutation) |m| {
            self.freeKey(m.key);
            if (m.action_id) |a| self.gpa.free(a);
        }
        self.mutation = null;
    }

    pub fn closeEditor(self: *Controller, app: *App) void {
        if (self.editor) |*e| {
            for (&e.subs) |*s| s.deinit();
            e.name.release(app);
            e.command.release(app);
            if (e.action_id) |a| self.gpa.free(a);
            if (e.err) |x| self.gpa.free(x);
            self.freeKey(e.key);
        }
        self.editor = null;
    }

    pub fn entry(self: *Controller, key: Key) ?*Entry {
        for (self.cache.items) |*e| if (e.key.eql(key)) return e;
        return null;
    }

    fn put(self: *Controller, key: Key, status: Status) void {
        if (self.entry(key)) |e| {
            e.status.deinit(self.gpa);
            e.status = status;
            return;
        }
        const k = self.dupeKey(key) orelse {
            var s = status;
            s.deinit(self.gpa);
            return;
        };
        self.cache.append(self.gpa, .{ .key = k, .status = status }) catch {
            self.freeKey(k);
            var s = status;
            s.deinit(self.gpa);
        };
    }

    /// `activate`: switching project closes the menu / editor and
    /// invalidates in-flight work. Returns whether the key changed.
    pub fn activate(self: *Controller, key: ?Key, app: *App) bool {
        const same = if (self.active) |a| (if (key) |k| a.eql(k) else false) else key == null;
        if (same) return false;
        if (self.active) |a| self.freeKey(a);
        self.active = if (key) |k| self.dupeKey(k) else null;
        self.generation +%= 1;
        self.menu_open = false;
        self.closeEditor(app);
        self.mutation_generation +%= 1;
        return true;
    }

    pub fn activeStatus(self: *Controller) ?*Status {
        const k = self.active orelse return null;
        return if (self.entry(k)) |e| &e.status else null;
    }

    pub fn activeSnapshot(self: *Controller) ?*const Snapshot {
        const s = self.activeStatus() orelse return null;
        return s.snapshot();
    }

    /// `visible_snapshot`: the active project's actions, or an empty surface
    /// while its first request is pending / failed; none when unsupported.
    pub fn visible(self: *Controller) ?Snapshot {
        const k = self.active orelse return null;
        const s = self.activeStatus() orelse return null;
        if (s.* == .unsupported) return null;
        if (s.snapshot()) |snap| return snap.*;
        return .{ .spaceId = k.space_id };
    }

    /// `begin_load`: a revalidation keeps the cached surface (and a host known
    /// not to support actions stays hidden).
    pub fn beginLoad(self: *Controller, key: Key) u64 {
        self.generation +%= 1;
        const e = self.entry(key);
        const keep = if (e) |x| (x.status == .unsupported or x.status.snapshot() != null) else false;
        if (!keep) self.put(key, .loading);
        return self.generation;
    }

    /// `accept_load`: only the active project's latest request lands.
    pub fn acceptLoad(self: *Controller, key: Key, generation: u64, result: anytype) bool {
        const a = self.active orelse return false;
        if (!a.eql(key) or self.generation != generation) return false;
        const next: Status = switch (result) {
            .ok => |snap| .{ .ready = snap },
            .err => |message| if (unknownMethod(message)) .unsupported else blk: {
                const prev = if (self.entry(key)) |e| e.status.takeSnapshot() else null;
                break :blk .{ .unavailable = .{ .snapshot = prev, .message = self.gpa.dupe(u8, message) catch {
                    if (prev) |p| p.deinit();
                    break :blk .unsupported;
                } } };
            },
        };
        self.put(key, next);
        return true;
    }

    /// `mark_unavailable`: keep the cached snapshot, refuse to run.
    pub fn markUnavailable(self: *Controller, key: Key, message: []const u8) void {
        if (unknownMethod(message)) return self.put(key, .unsupported);
        const prev = if (self.entry(key)) |e| e.status.takeSnapshot() else null;
        const msg = self.gpa.dupe(u8, message) catch {
            if (prev) |p| p.deinit();
            return;
        };
        self.put(key, .{ .unavailable = .{ .snapshot = prev, .message = msg } });
    }

    pub fn beginMutation(self: *Controller) u64 {
        self.mutation_generation +%= 1;
        return self.mutation_generation;
    }

    pub fn isCurrentMutation(self: *const Controller, key: Key, generation: u64) bool {
        const a = self.active orelse return false;
        return a.eql(key) and self.mutation_generation == generation;
    }
};

pub const LoadResult = union(enum) { ok: json.Parsed(Snapshot), err: []const u8 };

// ---- shell glue ---------------------------------------------------------------------------

fn ctl(shell: *Shell) *Controller {
    if (shell.wiring.project_actions == null) shell.wiring.project_actions = Controller.init(shell.gpa);
    return &shell.wiring.project_actions.?;
}

const Context_ = struct { key: Key, chat_id: []const u8, target: ?[]const u8 };

/// `project_action_context`: the selected session's project on its own device.
fn actionContext(shell: *Shell, cx: anytype) ?Context_ {
    const ws = shell.state.read(cx).workspace.read(cx);
    const chat = ws.selectedChatRow() orelse return null;
    const space_id = chat.spaceId orelse return null;
    const space = ws.space(space_id) orelse return null;
    if (!std.mem.eql(u8, space.deviceId, chat.deviceId)) return null;
    const remote = if (ws.local_device_id) |l| !std.mem.eql(u8, l, chat.deviceId) else true;
    return .{ .key = .{ .device_id = chat.deviceId, .space_id = space_id }, .chat_id = chat.id, .target = if (remote) chat.deviceId else null };
}

fn engineOf(shell: *Shell, cx: anytype) Entity(model.EngineState) {
    return shell.state.read(cx).engine;
}

/// Attached to an engine (headless tests: calls go to `EngineState.test_sink`).
fn attached(es: *const model.EngineState) bool {
    return es.conn != null or model.engine_state.test_sink != null;
}

/// `ensure_project_actions` (every render).
fn ensure(shell: *Shell, cx: *Ctx) void {
    const c = ctl(shell);
    const context = actionContext(shell, cx);
    const changed = c.activate(if (context) |x| x.key else null, cx.app);
    const needs = if (context) |x| (if (c.entry(x.key)) |e| e.status == .idle else true) else false;
    if ((changed or needs) and context != null) refresh(shell, context.?, cx);
}

const ListParams = struct { spaceId: []const u8, targetDeviceId: ?[]const u8 = null };

/// `refresh_project_actions`.
fn refresh(shell: *Shell, context: Context_, cx: *Ctx) void {
    const c = ctl(shell);
    if (!attached(engineOf(shell, cx).read(cx))) {
        c.markUnavailable(context.key, "Engine not connected");
        return cx.notify();
    }
    const generation = c.beginLoad(context.key);
    const k = c.dupeKey(context.key) orelse return;
    c.loads.append(c.gpa, .{ .key = k, .generation = generation }) catch return c.freeKey(k);
    model.EngineState.request(engineOf(shell, cx), cx, Shell, cx.entityId(), .ListProjectActions, ListParams{ .spaceId = context.key.space_id, .targetDeviceId = context.target }, onList) catch |err| {
        const l = c.loads.pop().?;
        c.freeKey(l.key);
        c.markUnavailable(context.key, if (err == error.NotConnected) "Engine not connected" else @errorName(err));
    };
    cx.notify();
}

fn onList(shell: *Shell, result: model.engine_state.CallResult, cx: *Ctx) void {
    const c = ctl(shell);
    if (c.loads.items.len == 0) return;
    const l = c.loads.orderedRemove(0);
    defer c.freeKey(l.key);
    const r: LoadResult = switch (result) {
        .ok => |v| if (json.parseFromValue(Snapshot, c.gpa, v, parse_opts)) |p| .{ .ok = p } else |_| .{ .err = "The engine sent a malformed actions list" },
        .err => |e| .{ .err = e.message },
    };
    if (!c.acceptLoad(l.key, l.generation, r)) if (r == .ok) r.ok.deinit();
    cx.notify();
}

fn toggleMenu(shell: *Shell, cx: *Ctx) void {
    const c = ctl(shell);
    if (c.menu_open) {
        c.menu_open = false;
        return cx.notify();
    }
    c.menu_open = true;
    if (c.menu_scroll) |s| s.setOffset(.{ .x = 0, .y = 0 });
    if (actionContext(shell, cx)) |context| refresh(shell, context, cx);
    cx.notify();
}

fn onChevron(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    cx.stopPropagation();
    toggleMenu(shell, cx);
}

fn onMenuOutside(shell: *Shell, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Ctx) void {
    ctl(shell).menu_open = false;
    cx.notify();
}

fn onRunPreferred(shell: *Shell, _: *const zpui.ClickEvent, window: *Window, cx: *Ctx) void {
    const c = ctl(shell);
    const snap = c.activeSnapshot() orelse return;
    const a = preferredAction(snap.actions, lastAction(cx, snap.spaceId)) orelse return;
    const id = c.gpa.dupe(u8, a.id) catch return;
    defer c.gpa.free(id);
    runAction(shell, id, window, cx);
}

fn onRunRow(shell: *Shell, ix: usize, _: *const zpui.ClickEvent, window: *Window, cx: *Ctx) void {
    const c = ctl(shell);
    const snap = c.activeSnapshot() orelse return;
    if (ix >= snap.actions.len) return;
    const id = c.gpa.dupe(u8, snap.actions[ix].id) catch return;
    defer c.gpa.free(id);
    runAction(shell, id, window, cx);
}

fn onEditRow(shell: *Shell, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    cx.stopPropagation();
    const c = ctl(shell);
    const snap = c.activeSnapshot() orelse return;
    if (ix >= snap.actions.len) return;
    const a = snap.actions[ix];
    openEditor(shell, a.id, .{ .name = a.name, .command = a.command, .icon = a.icon, .runOnWorktreeCreate = a.runOnWorktreeCreate }, cx);
}

fn onImportRow(shell: *Shell, ix: usize, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    const c = ctl(shell);
    const snap = c.activeSnapshot() orelse return;
    if (ix >= snap.importableActions.len) return;
    openEditor(shell, null, snap.importableActions[ix], cx);
}

fn onAdd(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    openEditor(shell, null, null, cx);
}

fn onRetry(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    if (actionContext(shell, cx)) |context| refresh(shell, context, cx);
}

fn lastAction(cx: anytype, space_id: []const u8) ?[]const u8 {
    const s = model.settings_store.current(cx.app) orelse return null;
    return s.lastProjectActionBySpaceId.map.get(space_id);
}

fn setLastAction(app: *App, space_id: []const u8, action_id: ?[]const u8) void {
    const C = struct { space: []const u8, action: ?[]const u8 };
    const W = struct {
        fn f(c: C, s: *model.UiSettings, a: Allocator) void {
            var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
            var it = s.lastProjectActionBySpaceId.map.iterator();
            while (it.next()) |e| if (!std.mem.eql(u8, e.key_ptr.*, c.space)) map.put(a, e.key_ptr.*, e.value_ptr.*) catch return;
            if (c.action) |id| map.put(a, a.dupe(u8, c.space) catch return, a.dupe(u8, id) catch return) catch return;
            s.lastProjectActionBySpaceId = .{ .map = map };
        }
    };
    _ = model.settings_store.update(app, .debounced, C{ .space = space_id, .action = action_id }, W.f);
}

// ---- editor ---------------------------------------------------------------------------------

fn newInput(cx: *Ctx, placeholder: []const u8, text: []const u8, multi: bool) ?Entity(TextInput) {
    const theme = ui.theme.get(cx);
    const in = cx.newWith(TextInput, TextInput.init, .{input_mod.Options{
        .placeholder = placeholder,
        .key_context = "Composer",
        .single_line = !multi,
        .text_size = 13,
        .line_height = 18,
        .colors = .{ .text = theme.text, .placeholder = theme.text_muted.opacity(0.6), .caret = theme.caret, .selection = theme.selection, .ghost = theme.text_faint },
        .edge_fade = false,
    }}) catch return null;
    in.update(cx, TextInput.setText, .{text});
    return in;
}

fn onEditorInput(_: *Shell, _: Entity(TextInput), _: *const input_mod.TextInputEvent, cx: *Ctx) void {
    cx.notify();
}

/// `open_project_action_editor`: edit `action_id`, or a new action seeded
/// from an importable draft (or blank).
pub fn openEditor(shell: *Shell, action_id: ?[]const u8, draft: ?Draft, cx: *Ctx) void {
    const c = ctl(shell);
    const key = c.active orelse return;
    c.menu_open = false;
    c.closeEditor(cx.app);
    const d: Draft = draft orelse .{ .name = "", .command = "", .icon = .play };
    const name = newInput(cx, "Action name", d.name, false) orelse return;
    const command = newInput(cx, "Command", d.command, true) orelse {
        name.release(cx);
        return;
    };
    const s1 = cx.subscribe(name, onEditorInput) catch {
        name.release(cx);
        command.release(cx);
        return;
    };
    const s2 = cx.subscribe(command, onEditorInput) catch {
        var x = s1;
        x.deinit();
        name.release(cx);
        command.release(cx);
        return;
    };
    c.editor = .{
        .key = c.dupeKey(key) orelse return,
        .action_id = if (action_id) |a| c.gpa.dupe(u8, a) catch null else null,
        .name = name,
        .command = command,
        .icon = d.icon,
        .run_on_worktree_create = d.runOnWorktreeCreate,
        .subs = .{ s1, s2 },
    };
    cx.notify();
}

fn setEditorError(c: *Controller, msg: ?[]const u8) void {
    const e = if (c.editor) |*x| x else return;
    if (e.err) |x| c.gpa.free(x);
    e.err = if (msg) |m| c.gpa.dupe(u8, m) catch null else null;
}

const UpsertParams = struct { spaceId: []const u8, actionId: ?[]const u8, action: Draft, targetDeviceId: ?[]const u8 = null };
const DeleteParams = struct { spaceId: []const u8, actionId: []const u8, targetDeviceId: ?[]const u8 = null };

/// `save_project_action`.
pub fn save(shell: *Shell, cx: *Ctx) void {
    const c = ctl(shell);
    const context = actionContext(shell, cx) orelse {
        setEditorError(c, "Project action is no longer available");
        return cx.notify();
    };
    const e = if (c.editor) |*x| x else return;
    if (e.saving) return;
    const name = std.mem.trim(u8, e.name.read(cx).text(), " \t\r\n");
    const command = std.mem.trim(u8, e.command.read(cx).text(), " \t\r\n");
    if (validateDraft(name, command)) |msg| {
        setEditorError(c, msg);
        return cx.notify();
    }
    if (!context.key.eql(e.key)) {
        setEditorError(c, "The selected project changed");
        return cx.notify();
    }
    if (!attached(engineOf(shell, cx).read(cx))) {
        setEditorError(c, "Engine not connected");
        return cx.notify();
    }
    e.saving = true;
    setEditorError(c, null);
    if (c.entry(context.key)) |entry| if (entry.status == .ready) {
        const snap = entry.status.ready;
        entry.status = .{ .saving = snap };
    };
    const gen = c.beginMutation();
    c.clearMutation();
    c.mutation = .{ .key = c.dupeKey(context.key) orelse return, .generation = gen, .delete = false, .action_id = null };
    model.EngineState.request(engineOf(shell, cx), cx, Shell, cx.entityId(), .UpsertProjectAction, UpsertParams{
        .spaceId = context.key.space_id,
        .actionId = e.action_id,
        .action = .{ .name = name, .command = command, .icon = e.icon, .runOnWorktreeCreate = e.run_on_worktree_create },
        .targetDeviceId = context.target,
    }, onMutation) catch |err| {
        c.clearMutation();
        e.saving = false;
        setEditorError(c, if (err == error.NotConnected) "Engine not connected" else @errorName(err));
    };
    cx.notify();
}

/// `delete_project_action`.
fn deleteAction(shell: *Shell, cx: *Ctx) void {
    const c = ctl(shell);
    const context = actionContext(shell, cx) orelse return;
    const e = if (c.editor) |*x| x else return;
    const action_id = e.action_id orelse {
        c.closeEditor(cx.app);
        return cx.notify();
    };
    if (e.saving) return;
    if (!attached(engineOf(shell, cx).read(cx))) return;
    e.saving = true;
    const gen = c.beginMutation();
    c.clearMutation();
    c.mutation = .{ .key = c.dupeKey(context.key) orelse return, .generation = gen, .delete = true, .action_id = c.gpa.dupe(u8, action_id) catch null };
    model.EngineState.request(engineOf(shell, cx), cx, Shell, cx.entityId(), .DeleteProjectAction, DeleteParams{
        .spaceId = context.key.space_id,
        .actionId = action_id,
        .targetDeviceId = context.target,
    }, onMutation) catch {
        c.clearMutation();
        e.saving = false;
    };
    cx.notify();
}

fn onMutation(shell: *Shell, result: model.engine_state.CallResult, cx: *Ctx) void {
    const c = ctl(shell);
    const m = c.mutation orelse return;
    c.mutation = null;
    defer {
        c.freeKey(m.key);
        if (m.action_id) |a| c.gpa.free(a);
    }
    if (!c.isCurrentMutation(m.key, m.generation)) return;
    const editing = if (c.editor) |e| e.key.eql(m.key) and e.saving else false;
    switch (result) {
        .ok => |v| {
            if (json.parseFromValue(Snapshot, c.gpa, v, parse_opts)) |snap| {
                c.put(m.key, .{ .ready = snap });
                if (m.delete) if (m.action_id) |id| if (lastAction(cx, m.key.space_id)) |last| if (std.mem.eql(u8, last, id)) {
                    setLastAction(cx.app, m.key.space_id, null);
                };
                if (editing) c.closeEditor(cx.app);
            } else |_| {
                c.markUnavailable(m.key, "The engine sent a malformed actions list");
                if (editing) {
                    c.editor.?.saving = false;
                    setEditorError(c, "The engine sent a malformed actions list");
                }
            }
        },
        .err => |e| {
            c.markUnavailable(m.key, e.message);
            if (editing) {
                c.editor.?.saving = false;
                c.editor.?.confirm_delete = false;
                setEditorError(c, e.message);
            }
        },
    }
    cx.notify();
}

const RunParams = struct { spaceId: []const u8, chatId: []const u8, actionId: []const u8, cols: u16 = 80, rows: u16 = 24, targetDeviceId: ?[]const u8 = null };
const CloseParams = struct { terminalId: []const u8, targetDeviceId: ?[]const u8 = null };

/// `run_project_action`: `RunProjectAction`, then a terminal tab attached
/// to the engine's PTY (titled after the action); remembered per project.
pub fn runAction(shell: *Shell, action_id: []const u8, _: *Window, cx: *Ctx) void {
    const c = ctl(shell);
    const context = actionContext(shell, cx) orelse return;
    const active = c.active orelse return;
    if (!context.key.eql(active)) return;
    const status = c.activeStatus() orelse return;
    if (!status.canRun()) return;
    const snap = status.snapshot() orelse return;
    const action = for (snap.actions) |a| {
        if (std.mem.eql(u8, a.id, action_id)) break a;
    } else return;
    if (!attached(engineOf(shell, cx).read(cx))) return;
    c.menu_open = false;
    // The run's tab is reserved (named, no PTY yet) in the chat's bottom
    // terminal drawer, which opens on it.
    const panel = shell.main.read(cx).terminal;
    const tab = panel.update(cx, terminal_panel.TerminalPanel.reserveTab, .{ context.chat_id, action.name });
    prefs_mod.mut(cx).terminal_open = true;
    if (tab) |t| panel.update(cx, terminal_panel.TerminalPanel.selectTab, .{t});
    const k = c.dupeKey(context.key) orelse return;
    c.runs.append(c.gpa, .{
        .key = k,
        .chat_id = c.gpa.dupe(u8, context.chat_id) catch return c.freeKey(k),
        .target = if (context.target) |t| c.gpa.dupe(u8, t) catch null else null,
        .action_id = c.gpa.dupe(u8, action.id) catch return,
        .name = c.gpa.dupe(u8, action.name) catch return,
        .tab = tab,
    }) catch return c.freeKey(k);
    model.EngineState.request(engineOf(shell, cx), cx, Shell, cx.entityId(), .RunProjectAction, RunParams{
        .spaceId = context.key.space_id,
        .chatId = context.chat_id,
        .actionId = action.id,
        .targetDeviceId = context.target,
    }, onRun) catch {
        const r = c.runs.pop().?;
        freeRun(c, r);
    };
    cx.notify();
}

fn freeRun(c: *Controller, r: anytype) void {
    c.freeKey(r.key);
    c.gpa.free(r.chat_id);
    if (r.target) |t| c.gpa.free(t);
    c.gpa.free(r.action_id);
    c.gpa.free(r.name);
}

fn onRun(shell: *Shell, result: model.engine_state.CallResult, cx: *Ctx) void {
    const c = ctl(shell);
    if (c.runs.items.len == 0) return;
    const r = c.runs.orderedRemove(0);
    defer freeRun(c, r);
    switch (result) {
        .ok => |v| {
            const parsed = json.parseFromValue(Run, c.gpa, v, parse_opts) catch {
                c.markUnavailable(r.key, "The engine sent a malformed run reply");
                return cx.notify();
            };
            defer parsed.deinit();
            if (!attachTerminal(shell, r.chat_id, r.tab, parsed.value, r.target, cx)) {
                model.EngineState.send(engineOf(shell, cx), cx, .CloseTerminal, CloseParams{ .terminalId = parsed.value.terminal.id, .targetDeviceId = r.target }) catch {};
            }
            setLastAction(cx.app, r.key.space_id, r.action_id);
        },
        .err => |e| {
            if (r.tab) |t| shell.main.read(cx).terminal.update(cx, terminal_panel.TerminalPanel.failReserved, .{ r.chat_id, t, e.message });
            c.markUnavailable(r.key, e.message);
        },
    }
    cx.notify();
}

/// `attach_reserved_session`: stream the run's PTY into its reserved tab
/// (false when the tab was closed meanwhile; the caller closes the session).
fn attachTerminal(shell: *Shell, chat_id: []const u8, tab: ?u64, run: Run, target: ?[]const u8, cx: *Ctx) bool {
    const t = tab orelse return false;
    return shell.main.read(cx).terminal.update(cx, terminal_panel.TerminalPanel.attachReserved, .{ chat_id, t, run.terminal, target });
}

/// `attach_worktree_setup`: a new worktree chat's setup action (started by
/// the host when the worktree materialized) streams into a "(setup)" tab of
/// that chat's drawer; the drawer opens on it when the chat is on screen.
pub fn attachWorktreeSetup(shell: *Shell, chat_id: []const u8, run: ?Run, setup_error: ?[]const u8, target: ?[]const u8, cx: *Ctx) void {
    const Sidebar = @import("../sidebar/sidebar.zig").Sidebar;
    var buf: [512]u8 = undefined;
    if (setup_error) |e| shell.sidebar.update(cx, Sidebar.setNotice, .{@as(?[]const u8, std.fmt.bufPrint(&buf, "Setup action failed: {s}", .{e}) catch "Setup action failed")});
    const r = run orelse return cx.notify();
    const panel = shell.main.read(cx).terminal;
    var title_buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s} (setup)", .{r.actionName}) catch r.actionName;
    const tab = panel.update(cx, terminal_panel.TerminalPanel.reserveTab, .{ chat_id, title });
    const ok = if (tab) |t| panel.update(cx, terminal_panel.TerminalPanel.attachReserved, .{ chat_id, t, r.terminal, target }) else false;
    if (!ok) shell.sidebar.update(cx, Sidebar.setNotice, .{@as(?[]const u8, "Setup action started, but its terminal could not be attached")});
    const selected = if (shell.state.read(cx).workspace.read(cx).selected_chat) |s| std.mem.eql(u8, s, chat_id) else false;
    if (selected) {
        prefs_mod.mut(cx).terminal_open = true;
        if (tab) |t| panel.update(cx, terminal_panel.TerminalPanel.selectTab, .{t});
    }
    cx.notify();
}

// ---- rendering --------------------------------------------------------------------------------

const control_height: f32 = 24;
/// Inside a Liquid Glass titlebar capsule (titlebar.zig `capsule_h`).
const liquid_height: f32 = 30;
const control_radius: f32 = 7;

fn actionFill(theme: *const Theme, hover: bool) zpui.Hsla {
    return if (hover) theme.wash(0.04) else theme.composerSurfaceBg();
}

fn preventDefault(_: *const zpui.input.MouseDownEvent, window: *Window, _: *App) void {
    window.preventDefault();
}

fn segment(theme: *const Theme, id: []const u8, enabled: bool) zpui.StatefulDiv {
    var d = div().id(id).role(.button).ariaDisabled(!enabled).relative().hFull().px(px(8)).flex().itemsCenter().gap(px(5))
        .textSize(px(11.5)).fontWeight(500).textColor(theme.text)
        .onMouseDown(.left, preventDefault);
    if (enabled) d = d.hover(sb.bg(actionFill(theme, true)));
    return d;
}

fn divider(theme: *const Theme) zpui.Div {
    return div().relative().flexNone().w(px(1)).h(px(control_height - 10)).bg(theme.text.opacity(0.14));
}

fn chevron(theme: *const Theme, enabled: bool, cx: *Ctx) zpui.StatefulDiv {
    var d = div().id("project-actions-chevron").role(.button).ariaLabel("Project actions").ariaDisabled(!enabled).hFull().relative().flexNone().w(px(22))
        .roundedR(px(control_radius)).flex().itemsCenter().justifyCenter()
        .onMouseDown(.left, preventDefault);
    if (!enabled) d = d.opacity(0.45) else d = d.cursorPointer().hover(sb.bg(actionFill(theme, true)))
        .onClick(cx.listener(onChevron))
        .tooltipWith(@as([]const u8, "Project actions"), ui.tooltip.build);
    return d.child(icon.of(.alt_arrow_down, 11, theme.text_muted));
}

/// Label baseline nudge (gpui lands 11.5px labels a device pixel higher).
fn labelText(text: []const u8) zpui.Div {
    return div().relative().top(px(-1)).child(text);
}

/// `render_project_actions_control`: null without a project (or when the
/// host has no project actions). `liquid` wraps it as a titlebar capsule.
pub fn control(shell: *Shell, available_width: f32, theme: *const Theme, liquid: bool, cx: *Ctx) ?zpui.Div {
    ensure(shell, cx);
    const c = ctl(shell);
    const status = c.activeStatus() orelse return null;
    const snapshot = c.visible() orelse return null;
    const loading = status.* == .idle or status.* == .loading;
    const can_run = status.canRun();
    const unavailable = status.* == .unavailable;
    const preferred = preferredAction(snapshot.actions, lastAction(cx, snapshot.spaceId));
    const has_imports = snapshot.importableActions.len > 0;
    const has_actions = snapshot.actions.len > 0;
    const show_label = showActionLabel(available_width);

    const fill = div().sizeFull().rounded(px(control_radius)).border1().borderColor(theme.composerSurfaceBorder()).bg(actionFill(theme, false));
    var ctrl = div().relative().flexNone().flex().flexRow().itemsCenter().h(px(if (liquid) liquid_height else control_height)).rounded(px(control_radius)).occlude();
    // [liquid-glass] The titlebar capsule's glass replaces the frosted fill and edge.
    if (!liquid) ctrl = ctrl.child(div().absolute().inset0().child(ui.effects.frosted(control_radius, zt.layout.menu_blur, if (theme.isFrost()) fill else fill.shadowSm())));

    if (loading) {
        var seg = segment(theme, "project-action-loading", false).ariaLabel("Loading project actions").roundedL(px(control_radius)).opacity(0.45)
            .child(div().size(px(13)).flexNone().flex().itemsCenter().justifyCenter()
            .child(ui.loaders.miniGlyphSpinner(2, .{ theme.text_muted, theme.text_muted, theme.text_muted }, ui.loaders.phaseOf(cx, zt.motion.gradient_spin))));
        if (show_label) seg = seg.child(labelText("Loading…"));
        if (cx.app.windows.items.len > 0) if (cx.app.windows.items[0]) |w| w.requestAnimationFrame();
        ctrl = ctrl.child(seg).child(divider(theme)).child(chevron(theme, false, cx));
    } else if (preferred) |action| {
        var main = segment(theme, "project-action-main", can_run).ariaLabel(zpui.fmt("Run {s}", .{action.name})).roundedL(px(control_radius));
        if (!can_run) main = main.opacity(0.45);
        if (can_run) main = main.cursorPointer().onClick(cx.listener(onRunPreferred));
        if (!show_label) main = main.tooltipWith(zpui.fmt("Run {s}", .{action.name}), ui.tooltip.build);
        main = main.child(icon.of(actionIcon(action.icon), 13, theme.text_muted));
        if (show_label) main = main.child(div().maxW(px(150)).truncate().relative().top(px(-1)).child(action.name));
        ctrl = ctrl.child(main).child(divider(theme)).child(chevron(theme, true, cx));
    } else if (unavailable) {
        var retry = segment(theme, "project-actions-unavailable", true).ariaLabel("Actions unavailable").rounded(px(control_radius)).cursorPointer()
            .onClick(cx.listener(onChevron))
            .child(icon.of(.danger_triangle, 13, theme.danger));
        if (show_label) retry = retry.child(labelText("Actions unavailable"));
        ctrl = ctrl.child(retry);
    } else {
        var add = segment(theme, "project-action-add", true).ariaLabel("Add action").roundedL(px(control_radius)).cursorPointer()
            .onClick(cx.listener(onAdd))
            .child(icon.of(.plus, 13, theme.text_muted))
            .child(labelText("Add action"));
        if (!has_imports) add = add.roundedR(px(control_radius));
        ctrl = ctrl.child(add);
        if (has_imports) ctrl = ctrl.child(divider(theme)).child(chevron(theme, true, cx));
    }

    if (!loading and c.menu_open and (has_actions or has_imports or !can_run)) {
        ctrl = ctrl.child(ui.popover.anchoredBelow(renderMenu(shell, status, snapshot, theme, cx)));
    }
    return ctrl;
}

fn renderMenu(shell: *Shell, status: *const Status, snapshot: Snapshot, theme_in: *const Theme, cx: *Ctx) zpui.StatefulDiv {
    const c = ctl(shell);
    const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
    const a = zpui.window.arena_mod.frameAllocator();
    if (c.menu_scroll == null) c.menu_scroll = zpui.ScrollHandle.init(c.gpa);
    const vh = if (cx.app.windows.items.len > 0) (if (cx.app.windows.items[0]) |w| w.viewportSize().height else 800) else 800;
    var card = ui.popover.card(theme).id("project-actions-scroll").w(px(280))
        .maxH(px(@max(vh - (zt.layout.titlebar_height + 6 + 16), 0)))
        .overflowYScroll().trackScroll(c.menu_scroll.?)
        .onMouseDownOut(cx.listener(onMenuOutside))
        .child(ui.popover.heading(theme, trackedUpper(a, "Project actions")));
    if (status.* == .unavailable) {
        card = card.child(div().px(px(8)).py(px(6)).textSize(px(12)).textColor(theme.danger).child(status.unavailable.message));
        if (actionContext(shell, cx) != null) card = card.child(ui.popover.menuRow(theme, false).id("project-actions-retry").role(.menu_item)
            .onClick(cx.listener(onRetry))
            .child(icon.of(.refresh, 15, theme.text_muted)).child("Retry"));
    }
    for (snapshot.actions, 0..) |action, i| {
        var row = ui.popover.menuRow(theme, false).id(.{ "project-action-row", i }).role(.menu_item);
        if (status.canRun()) row = row.onClick(cx.listenerWith(i, onRunRow));
        row = row.child(icon.of(actionIcon(action.icon), 15, theme.text_muted))
            .child(div().flex1().minW0().truncate().child(if (action.runOnWorktreeCreate) zpui.fmt("{s} (setup)", .{action.name}) else action.name))
            .child(div().id(.{ "edit-project-action", i }).role(.button).ariaLabel("Edit action").size(px(22)).flex().itemsCenter().justifyCenter().rounded(px(5))
            .hover(sb.bg(theme.ink(0.08)))
            .onClick(cx.listenerWith(i, onEditRow))
            .child(icon.of(.settings_minimalistic, 14, theme.text_muted)));
        card = card.child(row);
    }
    if (snapshot.importableActions.len > 0) {
        card = card.child(ui.popover.separator(theme)).child(ui.popover.heading(theme, trackedUpper(a, "Import from zeron.json")));
        for (snapshot.importableActions, 0..) |draft, i| {
            card = card.child(ui.popover.menuRow(theme, false).id(.{ "import-project-action", i }).role(.menu_item)
                .onClick(cx.listenerWith(i, onImportRow))
                .child(icon.of(actionIcon(draft.icon), 15, theme.text_muted)).child(draft.name));
        }
    }
    if (snapshot.projectFileIssue) |issue| card = card.child(div().px(px(8)).py(px(5)).textSize(px(11)).textColor(theme.text_muted).child(issue));
    return card.child(ui.popover.separator(theme))
        .child(ui.popover.menuRow(theme, false).id("project-actions-add-row").role(.menu_item)
        .onClick(cx.listener(onAdd))
        .child(icon.of(.plus, 15, theme.text_muted)).child("Add action"));
}

// ---- editor overlay -----------------------------------------------------------------------------

fn onEditorCancel(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    ctl(shell).closeEditor(cx.app);
    cx.notify();
}

fn onEditorScrim(_: *Shell, _: *const zpui.input.MouseDownEvent, _: *Window, _: *Ctx) void {}

fn onEditorKey(shell: *Shell, ev: *const zpui.input.KeyDownEvent, _: *Window, cx: *Ctx) void {
    if (!std.mem.eql(u8, ev.keystroke.key, "escape")) return;
    cx.stopPropagation();
    ctl(shell).closeEditor(cx.app);
    cx.notify();
}

fn onSave(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    save(shell, cx);
}

fn onPickIcon(shell: *Shell, i: ActionIcon, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    if (ctl(shell).editor) |*e| e.icon = i;
    cx.notify();
}

fn onToggleSetup(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    if (ctl(shell).editor) |*e| e.run_on_worktree_create = !e.run_on_worktree_create;
    cx.notify();
}

/// The native checkbox (macOS) reports its new state.
fn onNativeSetup(shell: *Shell, ev: *const zpui.NativeControlEvent, _: *Window, cx: *Ctx) void {
    if (ctl(shell).editor) |*e| e.run_on_worktree_create = ev.on;
    cx.notify();
}

fn onAskDelete(shell: *Shell, confirm: bool, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    if (ctl(shell).editor) |*e| e.confirm_delete = confirm;
    cx.notify();
}

fn onDelete(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    deleteAction(shell, cx);
}

fn fieldLabel(theme: *const Theme, text: []const u8) zpui.Div {
    return div().mt(px(12)).mb(px(5)).textSize(px(12)).fontWeight(500).textColor(theme.text_muted).child(text);
}

fn field(theme: *const Theme, child: anytype) zpui.Div {
    return div().px(px(12)).py(px(9)).rounded(px(8)).border1().borderColor(theme.border).bg(theme.bg).child(child);
}

/// Whether the editor (a modal) is up (keyboard ownership).
pub fn editorOpen(shell: *const Shell) bool {
    return if (shell.wiring.project_actions) |c| c.editor != null else false;
}

/// `render_project_action_overlay`: the add/edit dialog, or its delete confirm.
pub fn overlay(shell: *Shell, window: *Window, theme_in: *const Theme, cx: *Ctx) ?zpui.AnyElement {
    const c = if (shell.wiring.project_actions) |*x| x else return null;
    const e = if (c.editor) |*x| x else return null;
    if (e.focus_pending) {
        e.focus_pending = false;
        window.focus(e.name.read(cx).focusHandle());
    }
    const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
    if (e.confirm_delete) {
        const name = std.mem.trim(u8, e.name.read(cx).text(), " \t\r\n");
        const card = dialog.card(theme)
            .child(dialog.title(theme, "Delete action?"))
            .child(div().mt(px(6)).child(dialog.body(theme, zpui.fmt("\u{201C}{s}\u{201D} will be permanently deleted.", .{name}))))
            .child(div().mt(px(16)).flex().justifyEnd().gap(px(8))
            .child(dialog.btnGhost(theme, "Cancel").id("action-delete-cancel").role(.button).onClick(cx.listenerWith(false, onAskDelete)))
            .child(dialog.btnDanger(theme, "Delete").id("action-delete-confirm").role(.button).onClick(cx.listener(onDelete))));
        return dialog.modal(window, card, cx.listener(onEditorScrim));
    }
    const editing = e.action_id != null;
    var icons = div().flex().flexRow().gap(px(6));
    for (action_icons) |pair| {
        const selected = pair[0] == e.icon;
        icons = icons.child(div().id(.{ "action-icon", @intFromEnum(pair[0]) }).role(.radio_button).ariaLabel(pair[1]).ariaToggled(selected).size(px(34)).flex().itemsCenter().justifyCenter()
            .rounded(px(7)).border1().borderColor(if (selected) theme.text_muted else theme.border)
            .bg(if (selected) theme.ink(0.10) else theme.ink(0.03)).cursorPointer()
            .onClick(cx.listenerWith(pair[0], onPickIcon))
            .tooltipWith(pair[1], ui.tooltip.build)
            .child(icon.of(actionIcon(pair[0]), 16, theme.text_muted)));
    }
    const setup = e.run_on_worktree_create;
    var check = div().size(px(16)).rounded(px(4)).border1().borderColor(if (setup) theme.text else theme.border)
        .bg(if (setup) theme.text else theme.ink(0.03)).flex().itemsCenter().justifyCenter();
    if (setup) check = check.child(icon.of(.check, 12, theme.on_solid));
    var card = dialog.card(theme).w(px(440))
        .onKeyDown(cx.listener(onEditorKey))
        .child(dialog.title(theme, if (editing) "Edit action" else "Add action"))
        .child(fieldLabel(theme, "Name"))
        .child(field(theme, e.name))
        .child(fieldLabel(theme, "Command"))
        .child(field(theme, div().h(px(88)).overflowHidden().child(e.command)).fontFamily(theme.font_mono))
        .child(fieldLabel(theme, "Icon"))
        .child(icons)
        .child(div().mt(px(14)).child(zpui.nativeCheckbox("action-setup-native", .{ .on = setup, .title = "Run automatically on worktree creation" }, cx.listener(onNativeSetup), div().id("action-setup-toggle").role(.check_box).ariaToggled(setup).flex().itemsCenter().gap(px(9)).cursorPointer()
        .onClick(cx.listener(onToggleSetup))
        .child(check).child("Run automatically on worktree creation"))));
    if (e.err) |msg| card = card.child(div().mt(px(10)).textSize(px(12)).textColor(theme.danger).child(msg));
    var left = div();
    if (editing) left = left.child(dialog.btnGhost(theme, "Delete action").id("action-delete").role(.button).textColor(theme.danger).onClick(cx.listenerWith(true, onAskDelete)));
    var save_btn = dialog.btnPrimary(theme, if (e.saving) "Saving…" else "Save action").id("action-save").role(.button);
    if (!e.saving) save_btn = save_btn.onClick(cx.listener(onSave));
    card = card.child(div().mt(px(18)).flex().itemsCenter().justifyBetween()
        .child(left)
        .child(div().flex().gap(px(8))
        .child(dialog.btnGhost(theme, "Cancel").id("action-cancel").role(.button).onClick(cx.listener(onEditorCancel)))
        .child(save_btn)));
    return dialog.modal(window, card, cx.listener(onEditorScrim));
}

// ---- tests (project_actions.rs) ------------------------------------------------------------------

const testing = std.testing;

fn testAction(id: []const u8, setup: bool) Action {
    return .{ .id = id, .name = id, .command = id, .icon = .play, .runOnWorktreeCreate = setup };
}

fn testSnapshot(space: []const u8, actions: []const Action) json.Parsed(Snapshot) {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    json.Stringify.value(Snapshot{ .spaceId = space, .actions = actions }, .{}, &aw.writer) catch unreachable;
    return json.parseFromSlice(Snapshot, testing.allocator, aw.written(), parse_opts) catch unreachable;
}

test "preferred selection and responsive cutoff" {
    const actions = [_]Action{ testAction("setup", true), testAction("dev", false) };
    try testing.expectEqualStrings("setup", preferredAction(&actions, "setup").?.id);
    try testing.expectEqualStrings("dev", preferredAction(&actions, "gone").?.id);
    try testing.expectEqualStrings("dev", preferredAction(&actions, null).?.id);
    try testing.expect(!showActionLabel(419));
    try testing.expect(showActionLabel(420));
    try testing.expect(validateDraft("", "x") != null);
    try testing.expect(validateDraft("n", "") != null);
    try testing.expect(validateDraft("n", "x") == null);
}

test "first load keeps an empty disabled surface until the response" {
    var c = Controller.init(testing.allocator);
    defer c.deinit(undefined);
    const key: Key = .{ .device_id = "local", .space_id = "project" };
    _ = c.activate(key, undefined);
    c.put(key, .idle);
    try testing.expectEqual(@as(usize, 0), c.visible().?.actions.len);
    try testing.expect(!c.activeStatus().?.canRun());
    const generation = c.beginLoad(key);
    for (0..3) |_| {
        try testing.expect(!c.activate(key, undefined));
        try testing.expectEqualStrings("project", c.visible().?.spaceId);
        try testing.expect(!c.activeStatus().?.canRun());
        try testing.expectEqual(generation, c.generation);
    }
    const acts = [_]Action{testAction("dev", false)};
    try testing.expect(c.acceptLoad(key, generation, LoadResult{ .ok = testSnapshot("project", &acts) }));
    try testing.expectEqualStrings("dev", c.visible().?.actions[0].id);
    try testing.expect(c.activeStatus().?.canRun());
}

test "switching projects isolates actions; late responses never land" {
    var c = Controller.init(testing.allocator);
    defer c.deinit(undefined);
    const first: Key = .{ .device_id = "a", .space_id = "project" };
    const second: Key = .{ .device_id = "b", .space_id = "project" };
    const acts = [_]Action{testAction("dev", false)};
    _ = c.activate(first, undefined);
    const initial = c.beginLoad(first);
    try testing.expect(c.acceptLoad(first, initial, LoadResult{ .ok = testSnapshot("project", &acts) }));
    const refresh_gen = c.beginLoad(first);
    try testing.expectEqual(@as(usize, 1), c.visible().?.actions.len);
    _ = c.activate(second, undefined);
    const second_gen = c.beginLoad(second);
    try testing.expectEqual(@as(usize, 0), c.visible().?.actions.len);
    try testing.expect(!c.activeStatus().?.canRun());
    var stale = testSnapshot("project", &acts);
    try testing.expect(!c.acceptLoad(first, refresh_gen, LoadResult{ .ok = stale }));
    stale.deinit();
    _ = c.activate(first, undefined);
    const current = c.beginLoad(first);
    try testing.expectEqual(@as(usize, 1), c.visible().?.actions.len);
    try testing.expect(c.activeStatus().?.canRun());
    var other = testSnapshot("project", &acts);
    try testing.expect(!c.acceptLoad(second, second_gen, LoadResult{ .ok = other }));
    other.deinit();
    try testing.expect(c.acceptLoad(first, current, LoadResult{ .ok = testSnapshot("project", &acts) }));
}

test "unknown method hides; transport errors keep the snapshot" {
    var c = Controller.init(testing.allocator);
    defer c.deinit(undefined);
    const key: Key = .{ .device_id = "a", .space_id = "one" };
    _ = c.activate(key, undefined);
    const generation = c.beginLoad(key);
    try testing.expect(c.acceptLoad(key, generation, LoadResult{ .err = "Unknown method ListProjectActions" }));
    try testing.expect(c.activeStatus().?.* == .unsupported);
    _ = c.beginLoad(key);
    try testing.expect(c.visible() == null);
    const acts = [_]Action{testAction("dev", false)};
    c.put(key, .{ .ready = testSnapshot("one", &acts) });
    c.markUnavailable(key, "offline");
    try testing.expectEqualStrings("dev", c.activeSnapshot().?.actions[0].id);
    try testing.expect(!c.activeStatus().?.canRun());
    // An initial transport error keeps a visible retry surface.
    const remote: Key = .{ .device_id = "remote", .space_id = "project" };
    _ = c.activate(remote, undefined);
    const g = c.beginLoad(remote);
    try testing.expect(c.acceptLoad(remote, g, LoadResult{ .err = "remote routing unavailable" }));
    try testing.expect(c.activeSnapshot() == null);
    try testing.expectEqualStrings("project", c.visible().?.spaceId);
}

test "mutations are invalidated by project changes and newer mutations" {
    var c = Controller.init(testing.allocator);
    defer c.deinit(undefined);
    const first: Key = .{ .device_id = "a", .space_id = "one" };
    const second: Key = .{ .device_id = "b", .space_id = "two" };
    _ = c.activate(first, undefined);
    const g1 = c.beginMutation();
    try testing.expect(c.isCurrentMutation(first, g1));
    _ = c.activate(second, undefined);
    try testing.expect(!c.isCurrentMutation(first, g1));
    const superseded = c.beginMutation();
    const current = c.beginMutation();
    try testing.expect(!c.isCurrentMutation(second, superseded));
    try testing.expect(c.isCurrentMutation(second, current));
}
