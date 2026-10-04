//! The sign-in states around sync (zeron `shell.rs` `SyncFlow`,
//! `render_sync_overlay`, `render_signed_out_restart`, `start_synced_switch`,
//! `spawn_local_import`, `start_local_runtime_transition`, `request_sign_out`):
//!
//! - Enabling / Canceling (browser sign-in from a local workspace);
//! - the switch wizard once signed in on a local runtime: "Sync is ready"
//!   (Bring my work / Start fresh / Switch now / Later), Switching, the
//!   `ImportLocalWorkspace` stream (Importing N of M → You're all set, or
//!   "Import didn't finish" with Retry), and the quit-and-reopen fallback
//!   ("Sync needs a restart");
//! - Sign out? → Signing out… → back on the local runtime, or the
//!   full-window "Signed out" card with Retry local mode.
//!
//! Runtime changes: the Rust app swaps its embedded engine in place. This
//! client spawns `zeron headless`, so a change is `StopEngine` on the current
//! engine; `EngineState` reconnects and spawns a fresh runtime, which comes
//! up in the scope the stored credentials select. The wizard then advances
//! when the replacement engine is attached (`drive_sync_switch`).
//!
//! The pure decision functions are parity-tested against the Rust ones
//! (testdata/sync_flow_parity.json, apps/zeron/scripts/sync_flow_parity.rs).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const ui = @import("../components/root.zig");
const dialog = @import("../components/dialog.zig");
const shell_mod = @import("shell.zig");
const gates = @import("gates.zig");

const json = std.json;
const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const Theme = ui.Theme;
const Shell = shell_mod.Shell;
const Ctx = Context(Shell);
const protocol = engine.protocol;
const Scope = protocol.WorkspaceScope;
const AuthState = protocol.AuthState;

// ---- state ---------------------------------------------------------------------------------

pub const SyncFlow = union(enum) {
    idle,
    enabling,
    canceling,
    /// Signed in on a local runtime: the wizard's choice step. `false` =
    /// postponed (the account menu reopens it).
    switch_offer: bool,
    /// Stopping the local runtime (`true`: import local work afterwards).
    switching: bool,
    importing: struct { done: usize, total: usize },
    import_done: struct { imported: usize, skipped: usize },
    import_failed: bool,
    restart_pending: bool,
    sign_out_confirm,
    signing_out,
    signed_out_restart_required,

    pub fn eql(a: SyncFlow, b: SyncFlow) bool {
        return std.meta.eql(a, b);
    }

    /// States the in-place switch driver owns end-to-end.
    pub fn isSwitchLifecycle(self: SyncFlow) bool {
        return switch (self) {
            .switching, .importing, .import_done, .import_failed => true,
            else => false,
        };
    }

    pub fn hasVisibleOverlay(self: SyncFlow) bool {
        return switch (self) {
            .idle, .signed_out_restart_required => false,
            .switch_offer, .import_failed, .restart_pending => |open| open,
            else => true,
        };
    }
};

pub const AccountMenuAction = enum { enable_sync, sync_in_progress, restart_pending, sign_out };

/// `account_menu_action`.
pub fn accountMenuAction(scope: ?Scope, flow: SyncFlow) ?AccountMenuAction {
    const s = scope orelse return null;
    return switch (s) {
        .local => switch (flow) {
            .idle => .enable_sync,
            .enabling, .canceling => .sync_in_progress,
            .switch_offer, .restart_pending, .import_failed => .restart_pending,
            .switching, .importing, .import_done => .sync_in_progress,
            .sign_out_confirm, .signing_out, .signed_out_restart_required => null,
        },
        .synced => switch (flow) {
            .signed_out_restart_required => null,
            .import_failed => .restart_pending,
            else => if (flow.isSwitchLifecycle()) .sync_in_progress else .sign_out,
        },
        .development => null,
    };
}

/// `sync_flow_after_auth`.
pub fn afterAuth(flow: SyncFlow, scope: ?Scope, auth: ?AuthState) SyncFlow {
    const s = scope orelse return flow;
    switch (s) {
        .local => {
            if (flow.isSwitchLifecycle()) return flow;
            const a = auth orelse return flow;
            switch (a) {
                .signedOut => return switch (flow) {
                    .switch_offer, .restart_pending => .idle,
                    else => flow,
                },
                .signedIn => return switch (flow) {
                    .canceling, .switch_offer, .restart_pending => flow,
                    else => .{ .switch_offer = true },
                },
                .needsOrganization => return flow,
            }
        },
        .synced => {
            if (auth) |a| if (a == .signedOut) return .signed_out_restart_required;
            return switch (flow) {
                .sign_out_confirm, .signing_out, .signed_out_restart_required => flow,
                else => if (flow.isSwitchLifecycle()) flow else .idle,
            };
        },
        .development => return .idle,
    }
}

/// `local_work_phrase`: what a switch would bring along (null = nothing).
pub fn localWorkPhrase(buf: []u8, chats: usize, spaces: usize) ?[]const u8 {
    const S = struct {
        fn plural(n: usize) []const u8 {
            return if (n == 1) "" else "s";
        }
    };
    if (chats == 0 and spaces == 0) return null;
    if (spaces == 0) return std.fmt.bufPrint(buf, "the {d} session{s}", .{ chats, S.plural(chats) }) catch null;
    if (chats == 0) return std.fmt.bufPrint(buf, "the {d} project{s}", .{ spaces, S.plural(spaces) }) catch null;
    return std.fmt.bufPrint(buf, "the {d} session{s} and {d} project{s}", .{ chats, S.plural(chats), spaces, S.plural(spaces) }) catch null;
}

pub const ImportOutcome = union(enum) { ok: struct { imported: usize, skipped: usize }, err: []const u8 };

/// `import_summary_outcome`: a summary with errors is a FAILED import.
pub fn importSummaryOutcome(buf: []u8, item: json.Value) ImportOutcome {
    const count = struct {
        fn f(v: json.Value, key: []const u8) usize {
            if (v != .object) return 0;
            const x = v.object.get(key) orelse return 0;
            return switch (x) {
                .integer => |i| if (i < 0) 0 else @intCast(i),
                else => 0,
            };
        }
    }.f;
    var errors: usize = 0;
    var first: ?[]const u8 = null;
    if (item == .object) if (item.object.get("errors")) |e| if (e == .array) for (e.array.items) |x| if (x == .string) {
        if (first == null) first = x.string;
        errors += 1;
    };
    if (errors == 0) return .{ .ok = .{ .imported = count(item, "importedChats"), .skipped = count(item, "skippedChats") } };
    const msg = if (errors == 1)
        std.fmt.bufPrint(buf, "{d} imported, 1 failure: {s}", .{ count(item, "importedChats"), first orelse "unknown error" })
    else
        std.fmt.bufPrint(buf, "{d} imported, {d} failures \u{2014} first: {s}", .{ count(item, "importedChats"), errors, first orelse "unknown error" });
    return .{ .err = msg catch "Import failed" };
}

/// `sidebar_account_identity`: the footer label and the menu's identity line.
pub fn identity(scope: ?Scope, flow: SyncFlow, user: ?protocol.UserProfile) struct { []const u8, []const u8 } {
    if (scope) |s| switch (s) {
        .local => return .{ "Local", if (flow == .restart_pending) "Sync ready after restart" else "Stored on this device" },
        .development => return .{ "Development", "Authentication disabled" },
        .synced => {},
    };
    const u = user orelse return .{ "Local", "Not signed in" };
    const name = std.mem.trim(u8, u.name orelse "", " \t\r\n");
    return .{ if (name.len > 0) name else u.email, u.email };
}

/// The flow as an app global, so the sidebar's account menu can read it.
pub const Status = struct { flow: SyncFlow = .idle };

pub fn current(app: *App) SyncFlow {
    return if (app.tryGlobal(Status)) |s| s.flow else .idle;
}

fn publish(app: *App, flow: SyncFlow) void {
    if (!app.hasGlobal(Status)) app.setGlobal(Status{}) catch return;
    app.globalMut(Status).flow = flow;
    app.refreshWindows();
}

/// Shell-owned runtime / import bookkeeping (lives in `wiring.State`).
pub const Runtime = struct {
    /// A runtime change is in flight (Rust `runtime_change_task`).
    changing: bool = false,
    /// Sign out first (explicit sign-out) before stopping the engine.
    sign_out: bool = false,
    /// The engine generation being replaced; the change lands when a newer
    /// one attaches.
    from_generation: u64 = 0,
    err: ?[]u8 = null,
    import_watch: model.engine_state.Watch = .{},
    importing: bool = false,
    import_current: ?[]u8 = null,
    poll: zpui.Task(void) = .none,

    pub fn deinit(self: *Runtime, gpa: std.mem.Allocator) void {
        self.import_watch.close();
        self.poll.cancel();
        if (self.err) |e| gpa.free(e);
        if (self.import_current) |c| gpa.free(c);
        self.* = .{};
    }
};

fn setErr(shell: *Shell, msg: ?[]const u8) void {
    const rt = &shell.wiring.runtime;
    if (rt.err) |e| shell.gpa.free(e);
    rt.err = if (msg) |m| shell.gpa.dupe(u8, m) catch null else null;
}

/// Set the flow (and the sidebar's copy).
pub fn set(shell: *Shell, flow: SyncFlow, cx: *Ctx) void {
    shell.wiring.sync_flow = flow;
    publish(cx.app, flow);
    cx.notify();
}

fn engineOf(shell: *Shell, cx: anytype) Entity(model.EngineState) {
    return shell.state.read(cx).engine;
}

fn scopeOf(shell: *Shell, cx: anytype) ?Scope {
    return shell.state.read(cx).workspace.read(cx).workspace_scope;
}

/// Attached to an engine (headless tests: calls go to `EngineState.test_sink`).
fn attached(es: *const model.EngineState) bool {
    return es.conn != null or model.engine_state.test_sink != null;
}

// ---- transitions -----------------------------------------------------------------------------

/// `on_state_changed`'s sync half: follow auth / scope, drive the switch,
/// and leave a signed-out synced runtime automatically.
pub fn onStateChanged(shell: *Shell, cx: *Ctx) void {
    const auth = shell.state.read(cx).auth.read(cx).auth;
    const scope = scopeOf(shell, cx);
    const next = afterAuth(shell.wiring.sync_flow, scope, auth);
    if (!next.eql(shell.wiring.sync_flow)) set(shell, next, cx);
    driveSwitch(shell, cx);
    finishRuntimeChange(shell, cx);
    const signed_out_synced = scope == .synced and auth != null and auth.? == .signedOut;
    if (signed_out_synced and !shell.wiring.runtime.changing) startLocalTransition(shell, false, cx);
}

/// The replacement engine attached: a runtime change is done.
fn finishRuntimeChange(shell: *Shell, cx: *Ctx) void {
    const rt = &shell.wiring.runtime;
    if (!rt.changing) return;
    const es = engineOf(shell, cx).read(cx);
    if (es.conn == null or es.generation == rt.from_generation) {
        if (es.connection == .failed) {
            rt.changing = false;
            setErr(shell, es.failed_message orelse "engine connection failed");
            switch (shell.wiring.sync_flow) {
                .switching => set(shell, .{ .restart_pending = true }, cx),
                .signing_out => set(shell, .signed_out_restart_required, cx),
                else => {},
            }
        }
        return;
    }
    rt.changing = false;
    if (shell.wiring.sync_flow == .signing_out) {
        setErr(shell, null);
        set(shell, .idle, cx);
    }
}

/// `request_sign_out`: a synced workspace asks first.
pub fn requestSignOut(shell: *Shell, cx: *Ctx) void {
    if (scopeOf(shell, cx) != .synced) return;
    set(shell, .sign_out_confirm, cx);
}

const Empty = struct {};

/// `start_local_runtime_transition`: (SignOut, then) stop the synced engine;
/// the reconnect boots the local runtime.
pub fn startLocalTransition(shell: *Shell, sign_out: bool, cx: *Ctx) void {
    const rt = &shell.wiring.runtime;
    if (rt.changing) return;
    const es = engineOf(shell, cx);
    if (!attached(es.read(cx))) {
        setErr(shell, "Engine not connected");
        return set(shell, .signed_out_restart_required, cx);
    }
    set(shell, .signing_out, cx);
    setErr(shell, null);
    rt.changing = true;
    rt.sign_out = sign_out;
    rt.from_generation = es.read(cx).generation;
    if (sign_out) {
        model.EngineState.request(es, cx, Shell, cx.entityId(), .SignOut, Empty{}, onSignedOut) catch return failTransition(shell, "Sign out failed: engine not connected", cx);
    } else stopEngine(shell, cx);
}

fn onSignedOut(shell: *Shell, result: model.engine_state.CallResult, cx: *Ctx) void {
    switch (result) {
        .ok => stopEngine(shell, cx),
        .err => |e| {
            var buf: [256]u8 = undefined;
            failTransition(shell, std.fmt.bufPrint(&buf, "Sign out failed: {s}", .{e.message}) catch "Sign out failed", cx);
        },
    }
}

fn stopEngine(shell: *Shell, cx: *Ctx) void {
    model.EngineState.request(engineOf(shell, cx), cx, Shell, cx.entityId(), .StopEngine, Empty{}, onStopped) catch {
        // Already gone: the reconnect brings up the next runtime.
        engineOf(shell, cx).update(cx, model.EngineState.reconnect, .{});
    };
}

fn onStopped(shell: *Shell, result: model.engine_state.CallResult, cx: *Ctx) void {
    switch (result) {
        .ok => {},
        // The engine closing the socket mid-reply is the expected outcome.
        .err => |e| if (e.kind != error.Closed) {
            var buf: [256]u8 = undefined;
            return failTransition(shell, std.fmt.bufPrint(&buf, "Could not stop the engine: {s}. Run `zeron daemon stop`, then quit and reopen Zeron.", .{e.message}) catch "Could not stop the engine", cx);
        },
    }
    // Reattach now (and spawn the replacement runtime) instead of waiting on backoff.
    engineOf(shell, cx).update(cx, model.EngineState.reconnect, .{});
}

fn failTransition(shell: *Shell, msg: []const u8, cx: *Ctx) void {
    shell.wiring.runtime.changing = false;
    setErr(shell, msg);
    switch (shell.wiring.sync_flow) {
        .switching => set(shell, .{ .restart_pending = true }, cx),
        else => set(shell, .signed_out_restart_required, cx),
    }
}

/// `start_synced_switch`: stop the local runtime; the synced one comes up
/// in its place and `driveSwitch` runs the import.
pub fn startSyncedSwitch(shell: *Shell, import: bool, cx: *Ctx) void {
    const rt = &shell.wiring.runtime;
    if (rt.changing) return;
    const es = engineOf(shell, cx);
    if (!attached(es.read(cx))) {
        setErr(shell, "Engine not connected");
        return set(shell, .{ .restart_pending = true }, cx);
    }
    set(shell, .{ .switching = import }, cx);
    setErr(shell, null);
    if (rt.import_current) |c| shell.gpa.free(c);
    rt.import_current = null;
    rt.changing = true;
    rt.from_generation = es.read(cx).generation;
    stopEngine(shell, cx);
}

/// `drive_sync_switch`.
fn driveSwitch(shell: *Shell, cx: *Ctx) void {
    const import = switch (shell.wiring.sync_flow) {
        .switching => |i| i,
        else => return,
    };
    const es = engineOf(shell, cx).read(cx);
    const rt = &shell.wiring.runtime;
    if (rt.changing and (es.conn == null or es.generation == rt.from_generation)) {
        if (es.connection == .failed) finishRuntimeChange(shell, cx);
        return;
    }
    rt.changing = false;
    if (es.conn == null) return;
    switch (scopeOf(shell, cx) orelse return) {
        .synced => if (import) spawnImport(shell, cx) else set(shell, .idle, cx),
        else => {
            setErr(shell, "The synced workspace did not come up \u{2014} restart to finish.");
            set(shell, .{ .restart_pending = true }, cx);
        },
    }
}

/// `spawn_local_import`: the one-time `ImportLocalWorkspace` stream.
pub fn spawnImport(shell: *Shell, cx: *Ctx) void {
    const rt = &shell.wiring.runtime;
    if (rt.importing) return;
    const conn = engineOf(shell, cx).read(cx).conn orelse {
        setErr(shell, "Engine not connected");
        return set(shell, .{ .restart_pending = true }, cx);
    };
    set(shell, .{ .importing = .{ .done = 0, .total = 0 } }, cx);
    setErr(shell, null);
    rt.import_watch.open(conn, .ImportLocalWorkspace, Empty{}) catch |err| {
        setErr(shell, @errorName(err));
        return set(shell, .{ .import_failed = true }, cx);
    };
    rt.importing = true;
    rt.poll.cancel();
    rt.poll = cx.timer(50 * std.time.ns_per_ms, onImportPoll) catch .none;
}

fn onImportPoll(shell: *Shell, cx: *Ctx) void {
    const rt = &shell.wiring.runtime;
    rt.poll.detach();
    if (!rt.importing) return;
    while (rt.import_watch.next()) |payload| {
        defer payload.deinit();
        applyImportEvent(shell, payload.value, cx);
    }
    const end = rt.import_watch.end(null);
    if (end != .open) {
        rt.import_watch.close();
        rt.importing = false;
        if (rt.import_current) |c| shell.gpa.free(c);
        rt.import_current = null;
        // A stream that died before its summary is a failure (retry is idempotent).
        if (shell.wiring.sync_flow == .importing) {
            setErr(shell, if (end == .unknown_method) "This engine cannot import local work." else "The import stream ended before it finished.");
            set(shell, .{ .import_failed = true }, cx);
        }
        return cx.notify();
    }
    rt.poll = cx.timer(50 * std.time.ns_per_ms, onImportPoll) catch .none;
}

/// `apply_import_event`.
pub fn applyImportEvent(shell: *Shell, item: json.Value, cx: *Ctx) void {
    if (item != .object) return;
    const kind = item.object.get("kind") orelse return;
    if (kind != .string) return;
    const num = struct {
        fn f(v: json.Value, key: []const u8) usize {
            const x = v.object.get(key) orelse return 0;
            return if (x == .integer and x.integer >= 0) @intCast(x.integer) else 0;
        }
    }.f;
    const rt = &shell.wiring.runtime;
    if (std.mem.eql(u8, kind.string, "start")) {
        set(shell, .{ .importing = .{ .done = 0, .total = num(item, "chats") } }, cx);
    } else if (std.mem.eql(u8, kind.string, "chat")) {
        if (rt.import_current) |c| shell.gpa.free(c);
        rt.import_current = null;
        if (item.object.get("title")) |t| if (t == .string) {
            rt.import_current = shell.gpa.dupe(u8, t.string) catch null;
        };
        set(shell, .{ .importing = .{ .done = num(item, "index"), .total = num(item, "total") } }, cx);
    } else if (std.mem.eql(u8, kind.string, "summary")) {
        if (rt.import_current) |c| shell.gpa.free(c);
        rt.import_current = null;
        var buf: [512]u8 = undefined;
        switch (importSummaryOutcome(&buf, item)) {
            .ok => |o| set(shell, .{ .import_done = .{ .imported = o.imported, .skipped = o.skipped } }, cx),
            .err => |m| {
                setErr(shell, m);
                set(shell, .{ .import_failed = true }, cx);
            },
        }
    }
}

/// `postpone_sync_restart`.
pub fn postpone(shell: *Shell, cx: *Ctx) void {
    switch (shell.wiring.sync_flow) {
        .restart_pending => set(shell, .{ .restart_pending = false }, cx),
        .switch_offer => set(shell, .{ .switch_offer = false }, cx),
        .import_failed => set(shell, .{ .import_failed = false }, cx),
        else => {},
    }
}

/// `reopen_sync_notice` (account menu "Finish sync setup").
pub fn reopen(shell: *Shell, cx: *Ctx) void {
    switch (shell.wiring.sync_flow) {
        .restart_pending => set(shell, .{ .restart_pending = true }, cx),
        .switch_offer => set(shell, .{ .switch_offer = true }, cx),
        .import_failed => set(shell, .{ .import_failed = true }, cx),
        else => {},
    }
}

/// `quit_for_runtime_change`: stop the engine, then quit (reopening starts
/// the synced runtime).
pub fn quitForRuntimeChange(shell: *Shell, cx: *Ctx) void {
    const rt = &shell.wiring.runtime;
    if (rt.changing) return;
    const es = engineOf(shell, cx);
    if (!attached(es.read(cx))) {
        setErr(shell, "Engine not connected");
        return cx.notify();
    }
    setErr(shell, null);
    rt.changing = true;
    model.EngineState.request(es, cx, Shell, cx.entityId(), .StopEngine, Empty{}, onStoppedForQuit) catch {
        rt.changing = false;
    };
    cx.notify();
}

fn onStoppedForQuit(shell: *Shell, result: model.engine_state.CallResult, cx: *Ctx) void {
    shell.wiring.runtime.changing = false;
    switch (result) {
        .err => |e| if (e.kind != error.Closed) {
            var buf: [256]u8 = undefined;
            setErr(shell, std.fmt.bufPrint(&buf, "Could not stop the remote engine: {s}. Run `zeron daemon stop`, then quit and reopen Zeron.", .{e.message}) catch "Could not stop the remote engine");
            return cx.notify();
        },
        .ok => {},
    }
    cx.app.requestQuit();
}

// ---- rendering -------------------------------------------------------------------------------

fn onLater(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    postpone(shell, cx);
}
fn onSwitchFresh(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    startSyncedSwitch(shell, false, cx);
}
fn onSwitchImport(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    startSyncedSwitch(shell, true, cx);
}
fn onDone(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    set(shell, .idle, cx);
}
fn onRetryImport(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    spawnImport(shell, cx);
}
fn onQuit(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    quitForRuntimeChange(shell, cx);
}
fn onSignOutCancel(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    set(shell, .idle, cx);
}
fn onSignOutConfirm(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    startLocalTransition(shell, true, cx);
}
fn onRetryLocal(shell: *Shell, _: *const zpui.ClickEvent, _: *Window, cx: *Ctx) void {
    startLocalTransition(shell, false, cx);
}
fn onScrim(_: *Shell, _: *const zpui.input.MouseDownEvent, _: *Window, _: *Ctx) void {}

fn actionsRow() zpui.Div {
    return div().mt(px(16)).flex().flexRow().justifyEnd().gap(px(8));
}

fn errorLine(shell: *Shell, theme: *const Theme) ?zpui.Div {
    const e = shell.wiring.runtime.err orelse return null;
    return div().mt(px(10)).textSize(ui.rems(12)).lineHeight(px(17)).textColor(theme.danger).child(e);
}

/// The wizard / sign-out steps of `render_sync_overlay` (Enabling and
/// Canceling stay in wiring.zig). Null when nothing is up.
pub fn overlay(shell: *Shell, window: *Window, theme_in: *const Theme, cx: *Ctx) ?zpui.AnyElement {
    const theme = zpui.window.arena_mod.current().create(Theme, theme_in.forPopup());
    const ws = shell.state.read(cx).workspace.read(cx);
    const changing = shell.wiring.runtime.changing;
    const remote_engine = blk: {
        // `EngineMode::Remote`: an engine this client did not spawn (a daemon).
        const c = engineOf(shell, cx).read(cx).conn orelse break :blk false;
        break :blk c.engine.child == null;
    };
    const card: zpui.Div = switch (shell.wiring.sync_flow) {
        .switch_offer => |open| blk: {
            if (!open) return null;
            const user = shell.state.read(cx).auth.read(cx).user();
            var pbuf: [96]u8 = undefined;
            const phrase = localWorkPhrase(&pbuf, ws.chats().len, ws.spaces().len);
            const body = if (user) |u| (if (phrase) |p|
                zpui.fmt("You're signed in as {s}. Bring {s} from this device into your synced workspace, or start it fresh.", .{ u.email, p })
            else
                zpui.fmt("You're signed in as {s}. Zeron can switch to your synced workspace now.", .{u.email})) else if (phrase) |p|
                zpui.fmt("Bring {s} from this device into your synced workspace, or start it fresh.", .{p})
            else
                "Zeron can switch to your synced workspace now.";
            var actions = actionsRow().child(dialog.btnGhost(theme, "Later").id("sync-switch-later").onClick(cx.listener(onLater)));
            if (phrase != null) {
                actions = actions
                    .child(dialog.btnGhost(theme, "Start fresh").id("sync-switch-fresh").onClick(cx.listener(onSwitchFresh)))
                    .child(dialog.btnPrimary(theme, "Bring my work").id("sync-switch-import").onClick(cx.listener(onSwitchImport)));
            } else actions = actions.child(dialog.btnPrimary(theme, "Switch now").id("sync-switch-now").onClick(cx.listener(onSwitchFresh)));
            break :blk dialog.card(theme).child(dialog.title(theme, "Sync is ready"))
                .child(div().mt(px(6)).child(dialog.body(theme, body))).child(actions);
        },
        .switching => |import| dialog.card(theme).child(dialog.title(theme, "Switching to your synced workspace\u{2026}"))
            .child(div().mt(px(6)).child(dialog.body(theme, if (import)
            "Handing the engine over to your account. Your local sessions come along next."
        else
            "Handing the engine over to your account."))),
        .importing => |p| blk: {
            const fraction: f32 = if (p.total == 0) 0 else std.math.clamp(@as(f32, @floatFromInt(p.done)) / @as(f32, @floatFromInt(p.total)), 0, 1);
            const label = if (p.total == 0) "Looking for local sessions\u{2026}" else zpui.fmt("Importing session {d} of {d}", .{ @min(p.done + 1, p.total), p.total });
            var c = dialog.card(theme).child(dialog.title(theme, "Bringing your work over"))
                .child(div().mt(px(6)).child(dialog.body(theme, label)));
            if (shell.wiring.runtime.import_current) |t| c = c.child(div().mt(px(4)).textSize(ui.rems(12)).lineHeight(px(17)).textColor(theme.text_muted).overflowHidden().child(t));
            break :blk c.child(div().mt(px(14)).h(px(4)).wFull().rounded(px(2)).bg(theme.border)
                .child(div().hFull().rounded(px(2)).bg(theme.accent_strong).w(zpui.relative(@max(fraction, 0.04)))));
        },
        .import_done => |d| blk: {
            const body = if (d.imported == 0 and d.skipped == 0)
                "Your synced workspace is ready."
            else if (d.skipped == 0)
                zpui.fmt("{d} session{s} moved into your synced workspace.", .{ d.imported, if (d.imported == 1) "" else "s" })
            else
                zpui.fmt("{d} session{s} imported, {d} already present.", .{ d.imported, if (d.imported == 1) "" else "s", d.skipped });
            break :blk dialog.card(theme).child(dialog.title(theme, "You're all set"))
                .child(div().mt(px(6)).child(dialog.body(theme, body)))
                .child(div().mt(px(16)).flex().flexRow().justifyEnd()
                .child(dialog.btnPrimary(theme, "Continue").id("sync-switch-done").onClick(cx.listener(onDone))));
        },
        .import_failed => |open| blk: {
            if (!open) return null;
            break :blk dialog.card(theme).child(dialog.title(theme, "Import didn't finish"))
                .child(div().mt(px(6)).child(dialog.body(theme, "Anything already imported is kept; retrying only copies what's missing.")))
                .child(errorLine(shell, theme))
                .child(actionsRow()
                .child(dialog.btnGhost(theme, "Later").id("import-failed-dismiss").onClick(cx.listener(onLater)))
                .child(dialog.btnPrimary(theme, "Retry import").id("import-failed-retry").onClick(cx.listener(onRetryImport))));
        },
        .restart_pending => |open| blk: {
            if (!open) return null;
            const label = if (changing) "Stopping engine\u{2026}" else if (remote_engine) "Stop daemon and quit" else "Quit Zeron";
            break :blk dialog.card(theme).child(dialog.title(theme, "Sync needs a restart"))
                .child(div().mt(px(6)).child(dialog.body(theme, if (remote_engine)
                "Zeron is using a background daemon. Stop it and quit Zeron, then reopen to start the synced workspace. Existing local sessions stay on this device and will not be uploaded."
            else
                "Quit and reopen Zeron to start the synced workspace. Existing local sessions stay on this device and will not be uploaded.")))
                .child(errorLine(shell, theme))
                .child(actionsRow()
                .child(dialog.btnGhost(theme, "Later").id("sync-restart-later").onClick(cx.listener(onLater)))
                .child(dialog.btnPrimary(theme, label).id("sync-restart-quit").opacity(if (changing) 0.6 else 1).onClick(cx.listener(onQuit))));
        },
        .sign_out_confirm => dialog.card(theme).child(dialog.title(theme, "Sign out?"))
            .child(div().mt(px(6)).child(dialog.body(theme, "Zeron will remove your credentials, close the synced workspace, and continue in local mode.")))
            .child(actionsRow()
            .child(dialog.btnGhost(theme, "Cancel").id("signout-cancel").onClick(cx.listener(onSignOutCancel)))
            .child(dialog.btnDanger(theme, "Sign out").id("signout-confirm").onClick(cx.listener(onSignOutConfirm)))),
        .signing_out => dialog.card(theme).child(dialog.title(theme, "Signing out\u{2026}"))
            .child(div().mt(px(6)).child(dialog.body(theme, "Removing account credentials and closing the synced workspace."))),
        else => return null,
    };
    return dialog.modal(window, card, cx.listener(onScrim));
}

/// `render_signed_out_restart`: the full-window "Signed out" page.
pub fn signedOutPage(shell: *Shell, window: *Window, theme: *const Theme, cx: *Ctx) ?zpui.AnyElement {
    if (shell.wiring.sync_flow != .signed_out_restart_required) return null;
    const changing = shell.wiring.runtime.changing;
    var card = div().w(px(380)).px(px(32)).py(px(40)).rounded(px(12))
        .border1().borderColor(theme.border).bg(theme.surface_card).shadowLg()
        .flex().flexCol().itemsCenter().textCenter()
        .child(zpui.svg().source(ui.icon.Icon.zeron_logo.path(), ui.icon.Icon.zeron_logo.svg()).w(px(31.4)).h(px(36)).flexNone().textColor(theme.text))
        .child(div().mt(px(24)).textSize(ui.rems(18)).fontWeight(600).textColor(theme.text).child("Signed out"))
        .child(div().mt(px(6)).mb(px(24)).textSize(ui.rems(13)).lineHeight(px(19)).textColor(theme.text_muted)
        .child("Zeron removed your credentials but could not finish closing the previous synced workspace. Retry before continuing in local mode."));
    if (shell.wiring.runtime.err) |e| card = card.child(div().mb(px(16)).textSize(ui.rems(12)).lineHeight(px(17)).textColor(theme.danger).child(e));
    card = card.child(dialog.btnPrimary(theme, if (changing) "Stopping engine\u{2026}" else "Retry local mode").id("signed-out-quit")
        .opacity(if (changing) 0.6 else 1).onClick(cx.listener(onRetryLocal)));
    const vp = window.viewportSize();
    return zpui.intoAnyElement(zpui.deferred(zpui.anchored().position(.{ .x = 0, .y = 0 }).child(
        div().occlude().w(px(vp.width)).h(px(vp.height)).relative().bg(theme.bg)
            .child(gates.gridBackdrop(theme))
            .child(div().absolute().inset0().flex().itemsCenter().justifyCenter().child(ui.anim.fadeIn("signed-out-restart", card))),
    )).withPriority(4));
}

// ---- tests ------------------------------------------------------------------------------------

const testing = std.testing;

test "local work phrase and import outcomes" {
    var buf: [128]u8 = undefined;
    try testing.expect(localWorkPhrase(&buf, 0, 0) == null);
    try testing.expectEqualStrings("the 1 session", localWorkPhrase(&buf, 1, 0).?);
    try testing.expectEqualStrings("the 2 projects", localWorkPhrase(&buf, 0, 2).?);
    try testing.expectEqualStrings("the 3 sessions and 1 project", localWorkPhrase(&buf, 3, 1).?);
    const ok = try json.parseFromSlice(json.Value, testing.allocator, "{\"importedChats\":4,\"skippedChats\":1,\"errors\":[]}", .{});
    defer ok.deinit();
    const o = importSummaryOutcome(&buf, ok.value);
    try testing.expectEqual(@as(usize, 4), o.ok.imported);
    const bad = try json.parseFromSlice(json.Value, testing.allocator, "{\"importedChats\":2,\"errors\":[\"a\",\"b\"]}", .{});
    defer bad.deinit();
    try testing.expectEqualStrings("2 imported, 2 failures \u{2014} first: a", importSummaryOutcome(&buf, bad.value).err);
}

test "flow after auth and the account menu" {
    const signed_in: AuthState = .{ .signedIn = .{ .user = .{ .id = "u", .email = "e" } } };
    try testing.expect(afterAuth(.idle, .local, signed_in).eql(.{ .switch_offer = true }));
    try testing.expect(afterAuth(.{ .switch_offer = false }, .local, signed_in).eql(.{ .switch_offer = false }));
    try testing.expect(afterAuth(.{ .switch_offer = false }, .local, .signedOut).eql(.idle));
    try testing.expect(afterAuth(.{ .switching = true }, .local, .signedOut).eql(.{ .switching = true }));
    try testing.expect(afterAuth(.idle, .synced, .signedOut).eql(.signed_out_restart_required));
    try testing.expect(afterAuth(.enabling, .synced, signed_in).eql(.idle));
    try testing.expectEqual(@as(?AccountMenuAction, .enable_sync), accountMenuAction(.local, .idle));
    try testing.expectEqual(@as(?AccountMenuAction, .restart_pending), accountMenuAction(.synced, .{ .import_failed = false }));
    try testing.expectEqual(@as(?AccountMenuAction, .sign_out), accountMenuAction(.synced, .idle));
    try testing.expectEqual(@as(?AccountMenuAction, null), accountMenuAction(.development, .idle));
}
