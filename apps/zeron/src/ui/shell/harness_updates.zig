//! Home's agent-update island (zeron `shell/harness_updates.rs`): one
//! bottom-anchored surface for the compact summary ("4 agent updates ·
//! MacBook Pro (2)" + overlapping brand marks + chevron) and the expanded
//! per-agent list with Update / Cancel / Check again / View steps actions.
//!
//! Data: one `WatchHarnessUpdates{targetDeviceId}` stream per device that
//! advertises `harness-updates-v1` (the connected engine's own device
//! included before its registry row arrives). Presence is reconciled every
//! frame like Rust (`reconcile_devices`): an offline host keeps its last
//! known notices (marked disconnected) and is re-watched when it returns;
//! removed / unsupported hosts leave the inventory. A stream that ends is
//! retried after 1, 2, 4, 8, 15, 15… seconds.
//!
//! Geometry runs on the shell's RESIZE tween (200ms ease-out): width, height,
//! corner radius (19 → 16), the mark stack's collapse and the row reveal
//! share one clock; content keeps its final width while the surface clips it.
//!
//! The pure parts (`Inventory`, `visibleRows`, `title`, `detail`, `action`,
//! `activity`, `geometry`) are checked against the Rust code by
//! `harness_updates_test.zig` (fixture dumped by
//! apps/zeron/scripts/harness_updates_parity.rs).
//!
//! Not ported: keyboard focus ring / tab order / aria labels (zpui has no
//! accessibility tree yet) and the list's overlay scroll rail (the list
//! scrolls with the edge fade only).

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const zt = @import("zeron_theme");
const ui = @import("../components/root.zig");
const prefs_mod = @import("prefs.zig");
const native_popover = @import("../components/native_popover.zig");

const Allocator = std.mem.Allocator;
const App = zpui.App;
const Window = zpui.Window;
const Context = zpui.Context;
const Entity = zpui.Entity;
const div = zpui.div;
const px = zpui.px;
const sb = zpui.StyleBuilder.init;
const Theme = ui.Theme;
const rems = ui.rems;
const motion = zt.motion;
const protocol = engine.protocol;
const es = model.engine_state;
const HarnessId = protocol.HarnessId;
pub const Status = model.types.HarnessUpdateStatus;
pub const Phase = model.types.HarnessUpdatePhase;

pub const chip_height: f32 = 38;
pub const row_height: f32 = 64;
pub const max_visible_rows: f32 = 3.5;
pub const list_fade_band: f32 = 32;
pub const list_width: f32 = 360;
pub const mark_size: f32 = 22;
pub const mark_step: f32 = 14;
pub const max_marks: usize = 3;
/// Distance of the island's bottom edge from the window bottom.
pub const bottom_inset: f32 = 24;

// ---------------------------------------------------------------------------
// Inventory (`DeviceUpdates`, `reconcile_devices`, `visible_rows`)
// ---------------------------------------------------------------------------

pub const DeviceUpdates = struct {
    /// Owned.
    id: []u8,
    online: bool = false,
    /// The watch delivered a frame since it (re)opened.
    connected: bool = false,
    statuses: []const Status = &.{},
    frame: ?std.json.Parsed([]Status) = null,
    /// Rust `watch.is_some()`: a watch loop (stream or retry wait) is running.
    watching: bool = false,
    watch: es.Watch = .{},
    /// Next retry delay (seconds) and the pending retry's deadline.
    retry_s: u64 = 1,
    retry_at: ?u64 = null,

    fn stop(d: *DeviceUpdates) void {
        d.watch.close();
        d.watching = false;
        d.retry_at = null;
    }

    fn deinit(d: *DeviceUpdates, gpa: Allocator) void {
        d.watch.close();
        if (d.frame) |f| f.deinit();
        gpa.free(d.id);
    }

    /// Replace the statuses with a decoded `WatchHarnessUpdates` frame.
    pub fn setFrame(d: *DeviceUpdates, frame: std.json.Parsed([]Status)) void {
        if (d.frame) |f| f.deinit();
        d.frame = frame;
        d.statuses = frame.value;
    }
};

pub const Desired = struct { id: []const u8, online: bool };

/// Hosts keyed by device id in byte order (Rust `BTreeMap`).
pub const Inventory = struct {
    gpa: Allocator,
    devices: std.ArrayList(DeviceUpdates) = .empty,

    pub fn deinit(self: *Inventory) void {
        for (self.devices.items) |*d| d.deinit(self.gpa);
        self.devices.deinit(self.gpa);
    }

    pub fn clear(self: *Inventory) void {
        for (self.devices.items) |*d| d.deinit(self.gpa);
        self.devices.clearRetainingCapacity();
    }

    pub fn get(self: *Inventory, id: []const u8) ?*DeviceUpdates {
        for (self.devices.items) |*d| if (std.mem.eql(u8, d.id, id)) return d;
        return null;
    }

    fn insertSorted(self: *Inventory, id: []const u8) !*DeviceUpdates {
        var at: usize = 0;
        while (at < self.devices.items.len and std.mem.order(u8, self.devices.items[at].id, id) == .lt) at += 1;
        const owned = try self.gpa.dupe(u8, id);
        errdefer self.gpa.free(owned);
        try self.devices.insert(self.gpa, at, .{ .id = owned });
        return &self.devices.items[at];
    }

    /// `reconcile_devices`: keep a disconnected device's last known updates;
    /// removed / unsupported devices leave entirely. Appends the ids whose
    /// watch must start (slices of the inventory's own ids) to `start`.
    pub fn reconcile(self: *Inventory, desired: []const Desired, start: *std.ArrayList([]const u8), a: Allocator) !void {
        var i: usize = 0;
        while (i < self.devices.items.len) {
            const keep = for (desired) |d| (if (std.mem.eql(u8, d.id, self.devices.items[i].id)) break true) else false;
            if (keep) {
                i += 1;
            } else {
                var gone = self.devices.orderedRemove(i);
                gone.deinit(self.gpa);
            }
        }
        // Visit in key order like the BTreeMap.
        const order = try a.dupe(Desired, desired);
        defer a.free(order);
        std.sort.block(Desired, order, {}, struct {
            fn lt(_: void, x: Desired, y: Desired) bool {
                return std.mem.order(u8, x.id, y.id) == .lt;
            }
        }.lt);
        for (order) |want| {
            const d = self.get(want.id) orelse try self.insertSorted(want.id);
            d.online = want.online;
            if (!want.online) {
                d.stop();
                d.connected = false;
            } else if (!d.watching) {
                try start.append(a, d.id);
            }
        }
    }
};

pub const UpdateRow = struct {
    device_id: []const u8,
    device_name: []const u8,
    connected: bool,
    status: Status,
};

/// `visible_rows`: every host's notice rows, hosts in key order, statuses in
/// the engine's registry order (a phase change never reshuffles them).
/// `names.name(id)` resolves a display name.
pub fn visibleRows(a: Allocator, inv: *const Inventory, names: anytype) ![]UpdateRow {
    var out: std.ArrayList(UpdateRow) = .empty;
    for (inv.devices.items) |*d| {
        const name = names.name(d.id);
        for (d.statuses) |st| if (st.showUpdateNotice()) try out.append(a, .{
            .device_id = d.id,
            .device_name = name,
            .connected = d.online and d.connected,
            .status = st,
        });
    }
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// Copy and actions
// ---------------------------------------------------------------------------

/// `agent_name` (the island's own spelling: "OpenCode").
pub fn agentName(h: HarnessId) []const u8 {
    return switch (h) {
        .@"claude-code" => "Claude Code",
        .codex => "Codex",
        .cursor => "Cursor",
        .devin => "Devin",
        .grok => "Grok",
        .hermes => "Hermes",
        .pi => "Pi",
        .opencode => "OpenCode",
        .antigravity => "Antigravity",
        .mock => "Mock",
    };
}

/// An update in flight on the host.
pub fn isActive(st: Status) bool {
    return switch (st.phase) {
        .@"waiting-for-idle", .preparing, .downloading, .installing, .verifying => true,
        else => false,
    };
}

pub const Action = struct {
    label: []const u8,
    /// null: "View steps" (local UI, opens Settings → Agents).
    method: ?engine.Method,
};

pub fn action(st: Status) ?Action {
    return switch (st.phase) {
        .available => if (st.canApply) .{ .label = "Update", .method = .ApplyHarnessUpdate } else .{ .label = "View steps", .method = null },
        .@"waiting-for-idle", .preparing, .downloading => .{ .label = "Cancel", .method = .CancelHarnessUpdate },
        .failed => .{ .label = "Check again", .method = .CheckHarnessUpdates },
        else => null,
    };
}

pub fn rightInset(has_button: bool) f32 {
    return if (has_button) 5 else 12;
}

/// The row's second line.
pub fn detail(a: Allocator, st: Status) ![]const u8 {
    return switch (st.phase) {
        .available => if (st.latestVersion) |latest|
            (if (st.installedVersion) |installed| try std.fmt.allocPrint(a, "{s} → {s}", .{ installed, latest }) else try std.fmt.allocPrint(a, "Version {s} available", .{latest}))
        else
            "Update available",
        .@"waiting-for-idle" => "Waiting for the current run",
        .preparing => "Preparing update…",
        .downloading => if (st.progress) |p| (p.message orelse "Downloading…") else "Downloading…",
        .installing => "Installing…",
        .verifying => "Verifying installation…",
        .updated => if (st.installedVersion) |v| try std.fmt.allocPrint(a, "Updated to {s}", .{v}) else "Updated",
        .failed => if (st.@"error") |e| e.message else "Couldn’t check for updates",
        else => "Checking for updates…",
    };
}

fn deviceCount(rows: []const UpdateRow) usize {
    var n: usize = 0;
    for (rows, 0..) |r, i| {
        const seen = for (rows[0..i]) |p| (if (std.mem.eql(u8, p.device_id, r.device_id)) break true) else false;
        if (!seen) n += 1;
    }
    return n;
}

/// The summary line ("4 agent updates · MacBook Pro (2)"). `rows` is non-empty.
pub fn title(a: Allocator, rows: []const UpdateRow) !?[]const u8 {
    const row = rows[0];
    const st = row.status;
    const multiple = rows.len > 1;
    const name = agentName(st.harness);
    var all_updated = true;
    for (rows) |r| all_updated = all_updated and r.status.phase == .updated;
    var t: []const u8 = if (multiple)
        (if (all_updated) try std.fmt.allocPrint(a, "{d} agents updated", .{rows.len}) else try std.fmt.allocPrint(a, "{d} agent updates", .{rows.len}))
    else switch (st.phase) {
        .available => if (st.latestVersion) |v| try std.fmt.allocPrint(a, "{s} {s} available", .{ name, v }) else try std.fmt.allocPrint(a, "{s} update available", .{name}),
        .@"waiting-for-idle" => try std.fmt.allocPrint(a, "{s} · waiting for idle", .{name}),
        .preparing => try std.fmt.allocPrint(a, "Preparing {s}…", .{name}),
        .downloading => try std.fmt.allocPrint(a, "Downloading {s}…", .{name}),
        .installing => try std.fmt.allocPrint(a, "Updating {s}…", .{name}),
        .verifying => try std.fmt.allocPrint(a, "Verifying {s}…", .{name}),
        .updated => try std.fmt.allocPrint(a, "{s} updated", .{name}),
        .failed => try std.fmt.allocPrint(a, "{s} update check failed", .{name}),
        else => return null,
    };
    const devices = deviceCount(rows);
    t = if (devices == 1)
        try std.fmt.allocPrint(a, "{s} · {s}", .{ t, row.device_name })
    else
        try std.fmt.allocPrint(a, "{s} · {d} devices", .{ t, devices });
    for (rows) |r| if (!r.connected) {
        t = try std.fmt.allocPrint(a, "{s} · disconnected", .{t});
        break;
    };
    return t;
}

pub const Activity = enum { spinner, check, danger };

/// The glyph trailing the title.
pub fn activity(rows: []const UpdateRow) ?Activity {
    var all_updated = true;
    var busy = false;
    for (rows) |r| {
        all_updated = all_updated and r.status.phase == .updated;
        busy = busy or (r.connected and isActive(r.status));
    }
    if (busy) return .spinner;
    if (all_updated) return .check;
    if (rows.len == 1 and rows[0].status.phase == .failed) return .danger;
    return null;
}

pub const Geometry = struct {
    trailing: f32,
    marks_width: f32,
    compact_width: f32,
    list_width: f32,
    list_height: f32,
};

pub fn marksWidth(n_rows: usize) f32 {
    const n = @min(n_rows, max_marks);
    return mark_size + mark_step * @as(f32, @floatFromInt(n -| 1));
}

/// The compact chip and expanded list sizes. `title_width` / `action_width`
/// are the shaped widths of the title (12px medium) and the compact action
/// label (11.5px medium).
pub fn geometry(rows: []const UpdateRow, title_width: f32, action_width: f32, main_width: f32, viewport_height: f32) Geometry {
    const multiple = rows.len > 1;
    const has_activity = activity(rows) != null;
    const has_action = !multiple and action(rows[0].status) != null;
    const trailing: f32 = if (multiple) 8 else rightInset(has_action);
    const marks = marksWidth(rows.len);
    const controls: f32 = if (multiple) 24 + 8 else if (has_action) action_width + 20 + 8 else 0;
    const max_width = @max(main_width - 32, 0);
    const compact = @min(12 + marks + 8 + title_width + @as(f32, if (has_activity) 22 else 0) + controls + trailing + 2, max_width);
    const n: f32 = @floatFromInt(rows.len);
    return .{
        .trailing = trailing,
        .marks_width = marks,
        .compact_width = compact,
        .list_width = @min(list_width, max_width),
        .list_height = @min(chip_height + row_height * @min(n, max_visible_rows), @max(viewport_height - zt.layout.titlebar_height - 64, chip_height)),
    };
}

/// `composer_dock::stage`: smoothstep of `value` across `[start, end]`.
pub fn stage(value: f32, start: f32, end: f32) f32 {
    const t = std.math.clamp((value - start) / (end - start), 0, 1);
    return t * t * (3 - 2 * t);
}

// ---------------------------------------------------------------------------
// The view
// ---------------------------------------------------------------------------

/// "View steps": open Settings → Agents for `device_id` (borrowed for the emit).
pub const OpenSteps = struct { device_id: []const u8, local: bool };
/// An action failed: the shell shows it as the sidebar notice.
pub const Notice = struct { text: []const u8 };

const Tween = struct {
    from: f32,
    to: f32,
    start_ns: u64,
};

pub const ActionKey = struct { row: u16, harness: HarnessId, expanded_row: bool };

pub const HarnessUpdateIsland = struct {
    gpa: Allocator,
    state: Entity(model.AppState),
    subs: zpui.Subscriptions = .{},
    inv: Inventory,
    expanded: bool = false,
    transition: ?Tween = null,
    geometry: [2]?Tween = .{ null, null },
    scroll: zpui.ScrollHandle,
    retry_task: zpui.Task(void) = .none,
    /// Set by the main panel each frame.
    main_width: f32 = 800,
    viewport_height: f32 = 880,
    reduced_motion: bool = false,
    /// Tests: the inventory is supplied directly (no engine gating / watches).
    injected: bool = false,
    /// Devices of in-flight action RPCs, per method (replies carry no context).
    pending: [3]std.ArrayList([]u8) = .{ .empty, .empty, .empty },
    /// Last frame's laid-out surface size (tests / smoke probes).
    last_size: [2]f32 = .{ 0, 0 },

    pub const Events = .{ OpenSteps, Notice };

    pub fn init(state: Entity(model.AppState), cx: *Context(HarnessUpdateIsland)) !HarnessUpdateIsland {
        var self: HarnessUpdateIsland = .{
            .gpa = cx.gpa(),
            .state = state.retain(cx),
            .inv = .{ .gpa = cx.gpa() },
            .scroll = zpui.ScrollHandle.init(cx.gpa()),
        };
        const s = state.read(cx);
        try self.subs.add(cx.gpa(), try cx.subscribe(s.engine, onEngineEvent));
        try self.subs.add(cx.gpa(), try cx.observe(s.workspace, onWorkspace));
        return self;
    }

    pub fn deinit(self: *HarnessUpdateIsland, app: *App) void {
        self.subs.deinit(self.gpa);
        self.retry_task.cancel();
        self.inv.deinit();
        self.scroll.release();
        for (&self.pending) |*p| {
            for (p.items) |d| self.gpa.free(d);
            p.deinit(self.gpa);
        }
        self.state.release(app);
    }

    fn onWorkspace(_: *HarnessUpdateIsland, _: Entity(model.WorkspaceStore), cx: *Context(HarnessUpdateIsland)) void {
        cx.notify();
    }

    fn onEngineEvent(self: *HarnessUpdateIsland, _: Entity(model.EngineState), ev: *const es.EngineEvent, cx: *Context(HarnessUpdateIsland)) void {
        if (self.injected) return;
        switch (ev.*) {
            .connected => cx.notify(),
            .disconnected => {
                self.reset();
                cx.notify();
            },
            .wake => self.drain(cx),
        }
    }

    fn reset(self: *HarnessUpdateIsland) void {
        self.retry_task.cancel();
        self.inv.clear();
        self.expanded = false;
        self.transition = null;
        self.geometry = .{ null, null };
    }

    // ---- watches -----------------------------------------------------------------------

    fn now(cx: anytype) u64 {
        return ui.loaders.nowNs(cx);
    }

    /// `refresh_harness_update_watch`: the inventory follows the device
    /// registry + the connected engine; selection never affects it.
    pub fn refresh(self: *HarnessUpdateIsland, cx: *Context(HarnessUpdateIsland)) void {
        if (self.injected) return;
        const s = self.state.read(cx);
        const eng = s.engine.read(cx);
        if (!eng.isReady()) {
            if (self.inv.devices.items.len > 0 or self.expanded) self.reset();
            return;
        }
        const ws = s.workspace.read(cx);
        const ts = prefs_mod.get(cx).now(ws.io);
        const a = zpui.window.arena_mod.frameAllocator();
        var desired: std.ArrayList(Desired) = .empty;
        const local = eng.deviceId();
        var ids: std.ArrayList([]const u8) = .empty;
        for (ws.devices()) |d| ids.append(a, d.id) catch return;
        if (local) |l| ids.append(a, l) catch return;
        for (ids.items) |id| {
            const dup = for (desired.items) |d| (if (std.mem.eql(u8, d.id, id)) break true) else false;
            if (dup or !ws.deviceSupports(eng, id, protocol.capabilities.harness_updates_v1)) continue;
            desired.append(a, .{ .id = id, .online = ws.deviceOnline(id, ts) }) catch return;
        }
        var start: std.ArrayList([]const u8) = .empty;
        self.inv.reconcile(desired.items, &start, a) catch return;
        for (start.items) |id| if (self.inv.get(id)) |d| self.startWatch(d, cx);
    }

    fn startWatch(self: *HarnessUpdateIsland, d: *DeviceUpdates, cx: *Context(HarnessUpdateIsland)) void {
        d.watching = true;
        d.retry_at = null;
        const conn = self.state.read(cx).engine.read(cx).conn orelse return self.ended(d, cx);
        d.watch.open(conn, .WatchHarnessUpdates, .{ .targetDeviceId = d.id }) catch return self.ended(d, cx);
    }

    /// The stream ended or could not open: keep the rows, mark the host
    /// disconnected, retry with backoff (1s doubling to 15s).
    fn ended(self: *HarnessUpdateIsland, d: *DeviceUpdates, cx: *Context(HarnessUpdateIsland)) void {
        d.watch.close();
        d.connected = false;
        d.retry_at = now(cx) + d.retry_s * std.time.ns_per_s;
        d.retry_s = @min(d.retry_s * 2, 15);
        self.armRetry(cx);
    }

    fn armRetry(self: *HarnessUpdateIsland, cx: *Context(HarnessUpdateIsland)) void {
        var next: ?u64 = null;
        for (self.inv.devices.items) |d| if (d.retry_at) |t| {
            next = if (next) |n| @min(n, t) else t;
        };
        self.retry_task.cancel();
        const at = next orelse return;
        self.retry_task = cx.timer(at -| now(cx), onRetry) catch .none;
    }

    fn onRetry(self: *HarnessUpdateIsland, cx: *Context(HarnessUpdateIsland)) void {
        self.retry_task.detach();
        const t = now(cx);
        for (self.inv.devices.items) |*d| if (d.retry_at) |at| if (at <= t and d.watching and d.online) self.startWatch(d, cx);
        self.armRetry(cx);
        cx.notify();
    }

    fn drain(self: *HarnessUpdateIsland, cx: *Context(HarnessUpdateIsland)) void {
        var changed = false;
        for (self.inv.devices.items) |*d| {
            if (!d.watch.isOpen()) continue;
            if (es.latest([]Status, &d.watch, "WatchHarnessUpdates")) |frame| {
                d.setFrame(frame);
                d.connected = true;
                d.retry_s = 1;
                changed = true;
            }
            switch (d.watch.end(null)) {
                .open => {},
                else => {
                    self.ended(d, cx);
                    changed = true;
                },
            }
        }
        if (changed) cx.notify();
    }

    // ---- expansion ---------------------------------------------------------------------

    fn noticeCount(self: *const HarnessUpdateIsland) usize {
        var n: usize = 0;
        for (self.inv.devices.items) |d| for (d.statuses) |st| {
            if (st.showUpdateNotice()) n += 1;
        };
        return n;
    }

    fn tweenValue(self: *const HarnessUpdateIsland, tween: ?Tween, target: f32, t_now: u64) f32 {
        const tw = tween orelse return target;
        if (self.reduced_motion) return target;
        const elapsed = t_now -| tw.start_ns;
        if (elapsed >= motion.resize.totalNs(1.0)) return target;
        return motion.lerp(tw.from, tw.to, motion.resize.progressAt(elapsed, 1.0));
    }

    fn animating(self: *const HarnessUpdateIsland, tween: ?Tween, t_now: u64) bool {
        const tw = tween orelse return false;
        return !self.reduced_motion and t_now -| tw.start_ns < motion.resize.totalNs(1.0);
    }

    /// `set_harness_updates_expanded` (only expands with more than one notice).
    pub fn setExpanded(self: *HarnessUpdateIsland, expanded: bool, cx: *Context(HarnessUpdateIsland)) void {
        const want = expanded and self.noticeCount() > 1;
        if (self.expanded == want) return;
        if (want) self.scroll.setOffset(.{ .x = 0, .y = 0 });
        const t = now(cx);
        const from = self.tweenValue(self.transition, if (self.expanded) 1 else 0, t);
        self.expanded = want;
        self.transition = .{ .from = from, .to = if (want) 1 else 0, .start_ns = t };
        cx.notify();
    }

    /// Escape / leaving Home: collapse. True if it was expanded.
    pub fn collapse(self: *HarnessUpdateIsland, cx: *Context(HarnessUpdateIsland)) bool {
        if (!self.expanded) return false;
        self.setExpanded(false, cx);
        return true;
    }

    fn onToggle(self: *HarnessUpdateIsland, _: *const zpui.ClickEvent, _: *Window, cx: *Context(HarnessUpdateIsland)) void {
        cx.stopPropagation();
        self.setExpanded(!self.expanded, cx);
    }

    fn onOutside(self: *HarnessUpdateIsland, _: *const zpui.input.MouseDownEvent, _: *Window, cx: *Context(HarnessUpdateIsland)) void {
        self.setExpanded(false, cx);
    }

    // ---- actions -----------------------------------------------------------------------

    const Names = struct {
        ws: *const model.WorkspaceStore,
        pub fn name(n: Names, id: []const u8) []const u8 {
            return n.ws.deviceName(id) orelse id;
        }
    };

    fn rows(self: *const HarnessUpdateIsland, a: Allocator, cx: anytype) []UpdateRow {
        const names: Names = .{ .ws = self.state.read(cx).workspace.read(cx) };
        return visibleRows(a, &self.inv, names) catch &.{};
    }

    fn onAction(self: *HarnessUpdateIsland, key: ActionKey, _: *const zpui.ClickEvent, _: *Window, cx: *Context(HarnessUpdateIsland)) void {
        cx.stopPropagation();
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const list = self.rows(arena.allocator(), cx);
        if (key.row >= list.len) return;
        const row = list[key.row];
        if (row.status.harness != key.harness) return;
        const act = action(row.status) orelse return;
        if (act.method) |m| {
            if (!row.connected) return;
            self.runAction(row.device_id, m, row.status.harness, cx);
        } else {
            self.openSteps(row.device_id, cx);
        }
    }

    fn openSteps(self: *HarnessUpdateIsland, device_id: []const u8, cx: *Context(HarnessUpdateIsland)) void {
        const eng = self.state.read(cx).engine.read(cx);
        const local = if (eng.deviceId()) |l| std.mem.eql(u8, l, device_id) else false;
        const owned = self.gpa.dupe(u8, device_id) catch return;
        defer self.gpa.free(owned);
        self.setExpanded(false, cx);
        cx.emit(OpenSteps{ .device_id = owned, .local = local });
    }

    fn methodSlot(m: engine.Method) usize {
        return switch (m) {
            .ApplyHarnessUpdate => 0,
            .CancelHarnessUpdate => 1,
            else => 2,
        };
    }

    /// `run_harness_update_action`: `{harness, targetDeviceId}` to the host;
    /// each request owns its lifetime and progress arrives on the watches.
    pub fn runAction(self: *HarnessUpdateIsland, device_id: []const u8, method: engine.Method, harness: HarnessId, cx: *Context(HarnessUpdateIsland)) void {
        const s = self.state.read(cx);
        const ws = s.workspace.read(cx);
        const eng = s.engine.read(cx);
        const d = self.inv.get(device_id) orelse return;
        if (!(d.online and d.connected)) return;
        if (!ws.deviceOnline(device_id, prefs_mod.get(cx).now(ws.io))) return;
        if (!ws.deviceSupports(eng, device_id, protocol.capabilities.harness_updates_v1)) return;
        const P = struct { harness: HarnessId, targetDeviceId: []const u8 };
        const params: P = .{ .harness = harness, .targetDeviceId = device_id };
        const slot = methodSlot(method);
        const owned = self.gpa.dupe(u8, device_id) catch return;
        self.pending[slot].append(self.gpa, owned) catch {
            self.gpa.free(owned);
            return;
        };
        const r = switch (method) {
            .ApplyHarnessUpdate => model.EngineState.request(s.engine, cx, HarnessUpdateIsland, cx.entityId(), method, params, Reply(.ApplyHarnessUpdate).f),
            .CancelHarnessUpdate => model.EngineState.request(s.engine, cx, HarnessUpdateIsland, cx.entityId(), method, params, Reply(.CancelHarnessUpdate).f),
            else => model.EngineState.request(s.engine, cx, HarnessUpdateIsland, cx.entityId(), method, params, Reply(.CheckHarnessUpdates).f),
        };
        r catch |err| {
            _ = self.pending[slot].pop();
            self.gpa.free(owned);
            self.notice(device_id, if (err == error.NotConnected) "connection closed" else @errorName(err), cx);
        };
    }

    fn Reply(comptime m: engine.Method) type {
        return struct {
            fn f(self: *HarnessUpdateIsland, result: es.CallResult, cx: *Context(HarnessUpdateIsland)) void {
                const list = &self.pending[methodSlot(m)];
                const device: []u8 = if (list.items.len > 0) list.orderedRemove(0) else self.gpa.dupe(u8, "") catch return;
                defer self.gpa.free(device);
                switch (result) {
                    .ok => {},
                    .err => |e| {
                        if (m == .ApplyHarnessUpdate and std.mem.eql(u8, e.message, "update cancelled")) return cx.notify();
                        self.notice(device, if (e.message.len > 0) e.message else "connection closed", cx);
                    },
                }
                cx.notify();
            }
        };
    }

    fn notice(self: *HarnessUpdateIsland, device: []const u8, message: []const u8, cx: *Context(HarnessUpdateIsland)) void {
        const text = std.fmt.allocPrint(self.gpa, "Agent update ({s}): {s}", .{ device, message }) catch return;
        defer self.gpa.free(text);
        cx.emit(Notice{ .text = text });
    }

    // ---- render ------------------------------------------------------------------------

    fn textWidth(gpa: Allocator, window: *Window, text: []const u8, size: f32, theme: *const Theme) f32 {
        const runs = [_]zpui.text.TextRun{.{ .len = text.len, .font = .{ .family = theme.font_sans, .weight = zpui.text.weight.medium }, .color = theme.text }};
        const font_px = size / 16.0 * window.remSize();
        const line = window.text_system.shapeLine(text, font_px, &runs, null) catch return @as(f32, @floatFromInt(text.len)) * size * 0.55;
        defer line.deinit(gpa);
        return @ceil(line.width());
    }

    fn actionButton(self: *HarnessUpdateIsland, ix: usize, row: UpdateRow, interactive: bool, theme: *const Theme, cx: *Context(HarnessUpdateIsland)) ?zpui.StatefulDiv {
        _ = self;
        const act = action(row.status) orelse return null;
        // The settings/details link is local UI and stays usable offline.
        const available = act.method == null or row.connected;
        const enabled = interactive and available;
        const primary = act.method != null and act.method.? == .ApplyHarnessUpdate;
        var b = div().id(.{ "harness-update-action", ix }).role(.button).ariaLabel(zpui.fmt("{s} · {s} · {s}", .{ act.label, agentName(row.status.harness), row.device_name })).ariaDisabled(!enabled).h(px(26)).px(px(9)).flexNone().roundedFull()
            .border1().borderColor(zpui.color.transparent_black)
            .flex().itemsCenter().justifyCenter()
            .textSize(rems(11.5)).fontWeight(500)
            .bg(if (primary) theme.text else theme.element_hover)
            .textColor(if (primary) theme.on_solid else theme.text_muted)
            .opacity(if (available) 1 else 0.45)
            .child(act.label);
        if (enabled) b = b.cursorPointer().hover(sb.opacity(0.85))
            .onClick(cx.listenerWith(ActionKey{ .row = @intCast(ix), .harness = row.status.harness, .expanded_row = interactive }, onAction));
        return b;
    }

    fn markStack(list: []const UpdateRow, theme: *const Theme) zpui.Div {
        const count = @min(list.len, max_marks);
        const bg = zt.colorspace.flatten(theme.inputGlassBg(), theme.bg);
        var stack = div().relative().flexNone().w(px(marksWidth(list.len))).h(px(mark_size));
        // Back to front: the first row's mark is on top.
        var i: usize = count;
        while (i > 0) {
            i -= 1;
            const mark, const tint = ui.icon.harnessMark(list[i].status.harness);
            var m = div().absolute().left(px(@as(f32, @floatFromInt(i)) * mark_step)).top0().size(px(mark_size)).roundedFull()
                .flex().itemsCenter().justifyCenter()
                .child(ui.icon.of(mark, 16, tint orelse theme.text_muted));
            if (count > 1) m = m.bg(bg).border1().borderColor(theme.composerSurfaceBorder());
            stack = stack.child(ui.effects.layered(m));
        }
        return stack;
    }

    /// The per-agent rows (the expanded list's scroll column).
    fn rowsColumn(self: *HarnessUpdateIsland, list: []const UpdateRow, theme: *const Theme, devices: usize, row_reveal: f32, interactive: bool, cx: *Context(HarnessUpdateIsland)) zpui.StatefulDiv {
        const a = zpui.window.arena_mod.frameAllocator();
        var rows_col = div().id("home-harness-update-list").sizeFull().overflowYScroll().trackScroll(self.scroll).flex().flexCol();
        for (list, 0..) |row, ix| {
            const st = row.status;
            const mark, const tint = ui.icon.harnessMark(st.harness);
            const label = if (row.connected) (detail(a, st) catch "") else "Disconnected · reconnect to update";
            const extra = if (st.@"error") |e| e.message else st.manualCommand orelse label;
            var text_col = div().flex1().minW0().flex().flexCol().gap(px(1))
                .child(div().textSize(rems(12)).lineHeight(rems(16)).fontWeight(500).truncate().child(agentName(st.harness)));
            if (devices > 1) text_col = text_col.child(div().textSize(rems(11)).lineHeight(rems(14)).textColor(theme.text_muted).truncate().child(row.device_name));
            text_col = text_col.child(div().textSize(rems(11)).lineHeight(rems(14))
                .textColor(if (st.phase == .failed) theme.danger else theme.text_muted).truncate().child(label));
            var r = div().id(.{ "harness-update-row", ix }).relative().top(px(3 * (1 - row_reveal))).opacity(row_reveal)
                .h(px(row_height)).flexNone().px(px(12)).flex().itemsCenter().gap(px(10));
            if (ix > 0) r = r.child(div().absolute().top0().left(px(42)).right(px(12)).h(px(1)).bg(rowDivider(theme)));
            r = r.child(ui.icon.of(mark, 20, tint orelse theme.text_muted)).child(text_col);
            if (st.phase == .updated) r = r.child(ui.icon.of(.check, 14, theme.success));
            if (self.actionButton(ix, row, interactive, theme, cx)) |b| r = r.child(b);
            r = r.tooltipWith(zpui.fmt("{s} · {s}\n{s}", .{ agentName(st.harness), row.device_name, extra }), ui.tooltip.build);
            rows_col = rows_col.child(r);
        }
        return rows_col;
    }

    /// [native-popover] The expanded list in its native popover (list geometry, no
    /// surface of its own: the container's material is the card).
    fn nativeList(self: *HarnessUpdateIsland, window: *Window, cx: *Context(HarnessUpdateIsland)) zpui.AnyElement {
        const a = zpui.window.arena_mod.frameAllocator();
        const list = self.rows(a, cx);
        if (list.len < 2 or !self.expanded) return zpui.empty();
        const theme_v = ui.theme.get(cx).forSettingsSurface();
        const theme = zpui.window.arena_mod.current().create(Theme, theme_v);
        const title_text = (title(a, list) catch null) orelse "";
        const g = geometry(list, textWidth(self.gpa, window, title_text, 12, theme), 0, self.main_width, self.viewport_height);
        const rows_col = self.rowsColumn(list, theme, deviceCount(list), 1, true, cx);
        return zpui.intoAnyElement(div().w(px(g.list_width)).h(px(@max(g.list_height - chip_height, row_height)))
            .fontFamily(theme.font_sans).textColor(theme.text)
            .child(ui.effects.edgeFaded(rows_col, .{ .band = list_fade_band, .top = true, .bottom = true, .scroll = self.scroll })));
    }

    fn dismissNative(self: *HarnessUpdateIsland, _: *Window, cx: *Context(HarnessUpdateIsland)) void {
        self.setExpanded(false, cx);
    }

    pub fn render(self: *HarnessUpdateIsland, window: *Window, cx: *Context(HarnessUpdateIsland)) zpui.AnyElement {
        self.refresh(cx);
        self.reduced_motion = window.prefersReducedMotion();
        const a = zpui.window.arena_mod.frameAllocator();
        const list = self.rows(a, cx);
        if (list.len == 0) {
            self.expanded = false;
            self.transition = null;
            self.geometry = .{ null, null };
            self.last_size = .{ 0, 0 };
            return zpui.intoAnyElement(div());
        }
        const row0 = list[0];
        const multiple = list.len > 1;
        if (!multiple and self.expanded) {
            self.expanded = false;
            self.transition = null;
        }
        const expanded = self.expanded;
        // [native-popover] The expanded list opens in a native popover above the chip
        // (macOS); the island itself stays compact.
        const native = multiple and native_popover.enabled(cx);
        const t_now = now(cx);
        const reveal = if (native) 0 else self.tweenValue(self.transition, if (expanded) 1 else 0, t_now);
        const theme_v = ui.theme.get(cx).forSettingsSurface();
        const theme = &theme_v;
        const title_text = (title(a, list) catch null) orelse {
            self.last_size = .{ 0, 0 };
            return zpui.intoAnyElement(div());
        };
        const act = if (multiple) null else action(row0.status);
        const action_w = if (act) |x| textWidth(self.gpa, window, x.label, 11.5, theme) else 0;
        const g = geometry(list, textWidth(self.gpa, window, title_text, 12, theme), action_w, self.main_width, self.viewport_height);
        const targets: [2]f32 = if (expanded and !native) .{ g.list_width, g.list_height } else .{ g.compact_width, chip_height };
        var size = targets;
        for (targets, 0..) |target, axis| {
            const old = self.geometry[axis];
            if (old) |tw| {
                if (@abs(tw.to - target) > 0.5) self.geometry[axis] = .{ .from = self.tweenValue(old, tw.to, t_now), .to = target, .start_ns = t_now };
            } else self.geometry[axis] = .{ .from = target, .to = target, .start_ns = t_now };
            size[axis] = self.tweenValue(self.geometry[axis], target, t_now);
        }
        self.last_size = size;
        if (self.animating(self.transition, t_now) or self.animating(self.geometry[0], t_now) or self.animating(self.geometry[1], t_now)) window.requestAnimationFrame();
        const radius = motion.lerp(19, 16, reveal);
        const list_bottom_radius = @max(radius - 1, 0);
        const devices = deviceCount(list);

        // ---- summary ----
        var summary = div().id("home-harness-update-summary").h(px(chip_height)).wFull().flexNone()
            .pl(px(12)).pr(px(g.trailing)).flex().itemsCenter();
        if (multiple) summary = summary.role(.button).ariaLabel(if (expanded) "Collapse agent updates" else "Show agent updates").ariaExpanded(expanded).cursorPointer().rounded(px(radius)).onClick(cx.listener(onToggle));
        summary = summary
            .child(div().flexNone().w(px(g.marks_width * (1 - reveal))).mr(px(8 * (1 - reveal))).overflowHidden()
            .opacity(1 - stage(reveal, 0, 0.55)).child(markStack(list, theme)))
            .child(div().flex1().minW0().truncate().textSize(rems(12)).fontWeight(500).child(title_text));
        if (activity(list)) |kind| {
            const glyph = switch (kind) {
                .spinner => blk: {
                    break :blk zpui.intoAnyElement(ui.loaders.miniGlyphSpinner(2, theme.glyph.rows(), zt.pulse.activity(window)));
                },
                .check => zpui.intoAnyElement(ui.icon.of(.check, 14, theme.success)),
                .danger => zpui.intoAnyElement(ui.icon.of(.danger_triangle, 14, theme.danger)),
            };
            summary = summary.child(div().flexNone().ml(px(8)).child(glyph));
        }
        if (!multiple) if (self.actionButton(0, row0, true, theme, cx)) |b| {
            summary = summary.child(div().flexNone().ml(px(8)).child(b));
        };
        if (multiple) summary = summary.child(div().relative().size(px(24)).flexNone().ml(px(8))
            .child(div().absolute().left(px(5)).top(px(5)).size(px(14))
            .child(ui.icon.of(.alt_arrow_down, 14, theme.text_muted).withTransformation(.rotate(std.math.pi * (1 - (if (native) @as(f32, if (expanded) 1 else 0) else reveal)))))));

        // ---- card ----
        var card = div().id("home-harness-update-card").relative().w(px(size[0])).h(px(size[1]))
            .rounded(px(radius)).overflowHidden().border1().borderColor(theme.border.opacity(0.7))
            .fontFamily(theme.font_sans).textColor(theme.text).bg(ui.popover.surfaceBg(theme));
        if (!theme.isFrost()) card = card.shadowLg();
        if (expanded and !native) card = card.onMouseDownOut(cx.listener(onOutside));
        if (expanded and native) card = card.child(zpui.nativePopover(
            .trigger("harness-updates-native"),
            native_popover.options(theme, .above, .center, null),
            zpui.popoverContent(cx.entity(), nativeList, dismissNative),
        ));
        if (!multiple) {
            const tip: ?[]const u8 = if (row0.status.@"error") |e| e.message else row0.status.manualCommand;
            if (tip) |t| card = card.tooltipWith(zpui.fmt("{s}", .{t}), ui.tooltip.buildAbove);
        }
        card = card.child(summary);
        if (reveal > 0) {
            card = card.child(div().absolute().top(px(chip_height)).left(px(0)).right(px(0)).h(px(1))
                .bg(rowDivider(theme)).opacity(stage(reveal, 0.2, 0.65)));
            // Reveal after the surface has made room; the same reversible
            // progress drives the exit (never a replayed mount animation).
            const row_reveal = stage(reveal, 0.42, 0.9);
            var rows_col = self.rowsColumn(list, theme, devices, row_reveal, expanded and row_reveal >= 0.95, cx);
            // The fading list is inert while collapsing or before its reveal:
            // it must not intercept a click through clipped rows.
            if (!expanded or reveal < 0.85) rows_col = rows_col.child(div().absolute().inset0().occlude());
            const host = div().absolute().top(px(chip_height))
                .left(px((size[0] - g.list_width) * 0.5 + 1)).w(px(@max(g.list_width - 2, 0)))
                .h(px(@max(g.list_height - chip_height - 1, 0)))
                .roundedBl(px(list_bottom_radius)).roundedBr(px(list_bottom_radius)).overflowHidden()
                .bg(blockFill(theme)).opacity(stage(reveal, 0.3, 0.72))
                .child(ui.effects.edgeFaded(rows_col, .{ .band = list_fade_band, .top = true, .bottom = true, .scroll = self.scroll }));
            card = card.child(host);
        }
        return zpui.intoAnyElement(ui.effects.frosted(radius, 16, card));
    }
};

/// settings `widgets::row_divider` / `block_fill` (kept local: the settings
/// widgets module pulls the whole settings view).
fn rowDivider(theme: *const Theme) zpui.Hsla {
    return theme.border.opacity(0.6);
}

fn blockFill(theme: *const Theme) zpui.Hsla {
    return theme.wash(0.045);
}
