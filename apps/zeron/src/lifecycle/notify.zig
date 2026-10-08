//! Session sounds and desktop banners (port of zeron `crates/ui/src/sound.rs` (the
//! decision half) + `notify.rs` + the `shell::on_state_changed` block that drives them).
//!
//! One detector serves both outputs. Per session row it keeps a baseline (`SessionState`:
//! effective indicator, last completed turn, freshness); a row's first appearance seeds
//! the baseline silently (boot / replay). Transitions:
//! errored → Attention, awaiting input → Request, a new fresh completed turn → Done
//! (consumed silently while a send is pending). Side chats keep baselines but never ping.
//! Durable connectivity degradation (`Offline`/`Reconnecting`, armed only after a 5 s
//! healthy observation) → Attention. Attention chimes are coalesced over 250 ms.
//!
//! Outputs honor the settings exactly like Rust: chimes need `soundEnabled` + the cue's
//! own flag (`ZERON_DISABLE_SOUND` kills them); banners need `notificationsEnabled`, and
//! with `notificationsBackgroundOnly` only fire while no Zeron window is key
//! (`ZERON_DISABLE_NOTIFICATIONS` kills them). Agent (harness) release discoveries are
//! debounced 1 s into one aggregate banner, deduplicated per version.
//!
//! Banner clicks arrive through `App.onNotificationActivated(tag)`; the tag is the chat
//! id or `agent_updates_target` (root.zig routes them).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine_mod = @import("zeron_engine");
const sounds = @import("zeron_sounds");
const protocol = engine_mod.protocol;
const view = model.view;
const Timestamp = model.time.Timestamp;

const App = zpui.App;
const Entity = zpui.Entity;
const Context = zpui.Context;
const Task = zpui.Task;

/// Reserved banner target routed to Settings → Agents (never a real chat id).
pub const agent_updates_target = "__zeron_agent_updates__";

pub const Sound = enum {
    /// An agent turn completed successfully.
    done,
    /// The agent is waiting on a question.
    request,
    /// A run failed or the durable connection state degraded.
    attention,

    pub fn bytes(s: Sound) []const u8 {
        return switch (s) {
            .done => sounds.done,
            .request => sounds.request,
            .attention => sounds.attention,
        };
    }
};

/// `SessionNotificationState`.
pub const SessionState = struct {
    indicator: view.Indicator,
    /// Owned by the detector.
    last_completed_turn: ?[]const u8,
    fresh: bool,

    pub fn of(s: *const protocol.Session, now: Timestamp) SessionState {
        const updated = model.time.parse(s.updatedAt);
        return .{
            .indicator = view.effectiveIndicator(s, now),
            .last_completed_turn = s.lastCompletedTurn,
            .fresh = if (updated) |u| now.millisSince(u) <= view.session_stale_ms else false,
        };
    }

    /// `sound_since`.
    pub fn soundSince(self: SessionState, prev: SessionState, send_pending: bool) ?Sound {
        if (self.indicator == .errored and prev.indicator != .errored) return .attention;
        if (self.indicator == .awaiting_input and prev.indicator != .awaiting_input) return .request;
        if (!send_pending and self.fresh and self.last_completed_turn != null and
            !eqlOpt(self.last_completed_turn, prev.last_completed_turn)) return .done;
        return null;
    }
};

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// `connectivity_sound_since`.
pub fn connectivitySoundSince(current: protocol.ConnectivityState, previous: protocol.ConnectivityState) ?Sound {
    const degraded = current == .offline or current == .reconnecting;
    const was = previous == .offline or previous == .reconnecting;
    return if (degraded and !was) .attention else null;
}

/// `ConnectivityNotificationState` (times in ms, monotonic).
pub const ConnectivityState = struct {
    previous: ?protocol.ConnectivityState = null,
    first_observed_ms: ?u64 = null,
    armed: bool = false,

    pub const startup_quiet_ms: u64 = 5000;

    pub fn update(self: *ConnectivityState, current: protocol.ConnectivityState, observed: bool, now_ms: u64) ?Sound {
        if (!observed) {
            self.* = .{};
            return null;
        }
        const first = self.first_observed_ms orelse blk: {
            self.first_observed_ms = now_ms;
            break :blk now_ms;
        };
        const previous = self.previous;
        self.previous = current;
        if (!self.armed) {
            if (now_ms -| first >= startup_quiet_ms) {
                self.armed = true;
                return if (previous) |p| connectivitySoundSince(current, p) else null;
            }
            return null;
        }
        return if (previous) |p| connectivitySoundSince(current, p) else null;
    }
};

/// `AttentionSoundGate`: coalesce attention chimes from independent watches.
pub const AttentionGate = struct {
    last_ms: ?u64 = null,
    pub const coalesce_ms: u64 = 250;

    pub fn shouldPlay(self: *AttentionGate, now_ms: u64) bool {
        if (self.last_ms) |l| if (now_ms -| l < coalesce_ms) return false;
        self.last_ms = now_ms;
        return true;
    }
};

/// `UiSettings::session_sound_enabled`.
pub fn sessionSoundEnabled(s: *const model.UiSettings, sound: Sound) bool {
    return s.soundEnabled and switch (sound) {
        .done => s.soundCompletionEnabled,
        .request => s.soundInputEnabled,
        .attention => s.soundAttentionEnabled,
    };
}

/// Banner titles/bodies (shell.rs).
pub fn sessionBody(sound: Sound) []const u8 {
    return switch (sound) {
        .done => "Run finished",
        .request => "Waiting on your input",
        .attention => "Run failed",
    };
}

// ---------------------------------------------------------------------------------------
// The detector entity
// ---------------------------------------------------------------------------------------

const Baseline = struct {
    indicator: view.Indicator,
    turn: ?[]u8,
    fresh: bool,

    fn view_(self: *const Baseline) SessionState {
        return .{ .indicator = self.indicator, .last_completed_turn = self.turn, .fresh = self.fresh };
    }
};

pub const Options = struct {
    io: std.Io,
    /// `ZERON_DISABLE_SOUND` / `ZERON_DISABLE_NOTIFICATIONS` set.
    sound_disabled: bool = false,
    notifications_disabled: bool = false,
    /// macOS dev runs borrow the installed app's identity for banners.
    bundle_id: ?[]const u8 = "sh.zeron.app",
};

pub const Notifier = struct {
    gpa: Allocator,
    io: std.Io,
    opts: Options,
    state: Entity(model.AppState),
    subs: zpui.Subscriptions = .{},
    baselines: std.StringHashMapUnmanaged(Baseline) = .empty,
    connectivity: ConnectivityState = .{},
    attention: AttentionGate = .{},
    /// Harness update keys already announced (owned).
    harness_seen: std.StringHashMapUnmanaged(void) = .empty,
    harness_task: Task(void) = .none,
    /// Re-evaluate connectivity arming after the startup quiet window.
    arm_task: Task(void) = .none,
    /// Clock override (tests): monotonic ms and wall time.
    now_ms_override: ?u64 = null,
    now_override: ?Timestamp = null,

    pub fn init(state: Entity(model.AppState), opts: Options, cx: *Context(Notifier)) !Notifier {
        var self: Notifier = .{ .gpa = cx.gpa(), .io = opts.io, .opts = opts, .state = state.retain(cx) };
        errdefer self.state.release(cx);
        const s = state.read(cx);
        try self.subs.add(cx.gpa(), try cx.observe(s.workspace, onWorkspace));
        try self.subs.add(cx.gpa(), try cx.observe(s.sync, onSync));
        try self.subs.add(cx.gpa(), try cx.observe(s.catalog, onCatalog));
        return self;
    }

    pub fn deinit(self: *Notifier, app: *App) void {
        self.subs.deinit(self.gpa);
        self.harness_task.cancel();
        self.arm_task.cancel();
        var it = self.baselines.iterator();
        while (it.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            if (e.value_ptr.turn) |t| self.gpa.free(t);
        }
        self.baselines.deinit(self.gpa);
        var hs = self.harness_seen.keyIterator();
        while (hs.next()) |k| self.gpa.free(k.*);
        self.harness_seen.deinit(self.gpa);
        self.state.release(app);
    }

    fn nowMs(self: *const Notifier) u64 {
        if (self.now_ms_override) |n| return n;
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
    }

    fn now(self: *const Notifier) Timestamp {
        return self.now_override orelse Timestamp.now(self.io);
    }

    fn settings(cx: anytype) model.UiSettings {
        if (model.settings_store.current(cx.app)) |s| return s.*;
        return .{};
    }

    fn onWorkspace(self: *Notifier, _: Entity(model.WorkspaceStore), cx: *Context(Notifier)) void {
        self.checkSessions(cx);
    }
    fn onSync(self: *Notifier, _: Entity(model.SyncStore), cx: *Context(Notifier)) void {
        self.checkConnectivity(cx);
    }
    fn onCatalog(self: *Notifier, _: Entity(model.CatalogStore), cx: *Context(Notifier)) void {
        self.checkHarnessUpdates(cx);
    }

    fn appFocused(cx: anytype) bool {
        return cx.app.activeWindow() != null;
    }

    fn sendPending(self: *Notifier, chat_id: []const u8, n: Timestamp, cx: anytype) bool {
        const st = self.state.read(cx);
        if (st.transcript) |t| if (std.mem.eql(u8, t.read(cx).chat_id, chat_id)) return t.read(cx).sendPending(n);
        for (st.cache.items) |t| if (std.mem.eql(u8, t.read(cx).chat_id, chat_id)) return t.read(cx).sendPending(n);
        return false;
    }

    pub fn checkSessions(self: *Notifier, cx: *Context(Notifier)) void {
        const n = self.now();
        const ws = self.state.read(cx).workspace.read(cx);
        const s = settings(cx);
        const focused = appFocused(cx);
        for (ws.sessions()) |*session| {
            const cur = SessionState.of(session, n);
            const chat = ws.chat(session.chatId);
            const notify = if (chat) |ch| ch.isTopLevel() else false;
            const send_pending = self.sendPending(session.chatId, n, cx);
            const gop = self.baselines.getOrPut(self.gpa, session.chatId) catch continue;
            if (!gop.found_existing) {
                gop.key_ptr.* = self.gpa.dupe(u8, session.chatId) catch {
                    _ = self.baselines.remove(session.chatId);
                    continue;
                };
                gop.value_ptr.* = .{ .indicator = cur.indicator, .turn = dupeOpt(self.gpa, cur.last_completed_turn), .fresh = cur.fresh };
                continue; // first appearance seeds silently
            }
            const prev = gop.value_ptr.view_();
            const sound = cur.soundSince(prev, send_pending);
            // Save the new baseline even when outputs are off: suppressed pings never replay.
            if (!eqlOpt(gop.value_ptr.turn, cur.last_completed_turn)) {
                if (gop.value_ptr.turn) |t| self.gpa.free(t);
                gop.value_ptr.turn = dupeOpt(self.gpa, cur.last_completed_turn);
            }
            gop.value_ptr.indicator = cur.indicator;
            gop.value_ptr.fresh = cur.fresh;
            if (!notify) continue;
            const snd = sound orelse continue;
            if (sessionSoundEnabled(&s, snd)) {
                const play = snd != .attention or self.attention.shouldPlay(self.nowMs());
                if (play) self.playSound(snd, cx);
            }
            if (s.notificationsEnabled and !(s.notificationsBackgroundOnly and focused)) {
                const title = if (chat) |ch| (ch.title orelse "New session") else "New session";
                self.post(title, sessionBody(snd), session.chatId, cx);
            }
        }
    }

    pub fn checkConnectivity(self: *Notifier, cx: *Context(Notifier)) void {
        const sync = self.state.read(cx).sync.read(cx);
        const conn = sync.current();
        const sound = self.connectivity.update(conn.state, sync.connectivity_observed, self.nowMs()) orelse {
            // Arm by elapsed time even when no new frame arrives (Rust: the next frame
            // after the quiet window evaluates the transition).
            if (!self.connectivity.armed and self.connectivity.first_observed_ms != null and self.arm_task.header == null) {
                self.arm_task = cx.timer(ConnectivityState.startup_quiet_ms * std.time.ns_per_ms, onArm) catch .none;
            }
            return;
        };
        const s = settings(cx);
        if (sessionSoundEnabled(&s, sound) and self.attention.shouldPlay(self.nowMs())) self.playSound(sound, cx);
        if (s.notificationsEnabled and !(s.notificationsBackgroundOnly and appFocused(cx))) {
            const body = if (conn.state == .offline) "Your device is offline" else "Zeron is trying to reconnect";
            self.post("Connection unavailable", body, null, cx);
        }
    }

    fn onArm(self: *Notifier, _: *Context(Notifier)) void {
        self.arm_task.detach();
    }

    fn harnessKey(buf: []u8, device: []const u8, status: anytype) ?[]const u8 {
        if (status.phase != .available) return null;
        return if (status.latestVersion) |v|
            std.fmt.bufPrint(buf, "{s}:{t}:{s}", .{ device, status.harness, v }) catch null
        else
            std.fmt.bufPrint(buf, "{s}:{t}:versionless", .{ device, status.harness }) catch null;
    }

    fn unseenHarnessUpdates(self: *Notifier, cx: anytype, collect: ?*std.ArrayList([]u8)) bool {
        const st = self.state.read(cx);
        const device = st.workspace.read(cx).local_device_id orelse "local";
        const statuses = st.catalog.read(cx).updates.value() orelse return false;
        var any = false;
        for (statuses.*) |status| {
            if (status.phase == .current or status.phase == .updated) {
                var vb: [256]u8 = undefined;
                const key = std.fmt.bufPrint(&vb, "{s}:{t}:versionless", .{ device, status.harness }) catch continue;
                if (self.harness_seen.fetchRemove(key)) |kv| self.gpa.free(kv.key);
            }
            var kb: [256]u8 = undefined;
            const key = harnessKey(&kb, device, status) orelse continue;
            if (self.harness_seen.contains(key)) continue;
            any = true;
            if (collect) |list| list.append(self.gpa, self.gpa.dupe(u8, key) catch continue) catch {};
        }
        return any;
    }

    pub fn checkHarnessUpdates(self: *Notifier, cx: *Context(Notifier)) void {
        if (!self.unseenHarnessUpdates(cx, null) or self.harness_task.header != null) return;
        self.harness_task = cx.timer(std.time.ns_per_s, onHarnessDebounced) catch .none;
    }

    fn onHarnessDebounced(self: *Notifier, cx: *Context(Notifier)) void {
        self.harness_task.detach();
        var keys: std.ArrayList([]u8) = .empty;
        defer keys.deinit(self.gpa);
        _ = self.unseenHarnessUpdates(cx, &keys);
        if (keys.items.len == 0) return;
        const count = keys.items.len;
        for (keys.items) |k| self.harness_seen.put(self.gpa, k, {}) catch self.gpa.free(k);
        const s = settings(cx);
        if (s.notificationsEnabled and s.agentUpdateNotifications and !(s.notificationsBackgroundOnly and appFocused(cx))) {
            var tb: [64]u8 = undefined;
            const title = std.fmt.bufPrint(&tb, "{d} agent update{s} available", .{ count, if (count == 1) "" else "s" }) catch return;
            const body = if (count == 1) "A coding agent update is ready" else "Coding agent updates are ready";
            self.post(title, body, agent_updates_target, cx);
        }
    }

    fn playSound(self: *Notifier, sound: Sound, cx: anytype) void {
        if (self.opts.sound_disabled) return;
        cx.app.playSound(sound.bytes());
    }

    fn post(self: *Notifier, title: []const u8, body: []const u8, tag: ?[]const u8, cx: anytype) void {
        if (self.opts.notifications_disabled) return;
        cx.app.postNotification(.{ .title = title, .body = body, .tag = tag, .app_name = "Zeron", .bundle_id = self.opts.bundle_id });
    }
};

fn dupeOpt(gpa: Allocator, s: ?[]const u8) ?[]u8 {
    return if (s) |v| gpa.dupe(u8, v) catch null else null;
}

// ---------------------------------------------------------------------------------------

const testing = std.testing;

fn baseline(indicator: view.Indicator, turn: ?[]const u8) SessionState {
    return .{ .indicator = indicator, .last_completed_turn = turn, .fresh = true };
}

test "interrupted and expired activity never chime" {
    try testing.expectEqual(@as(?Sound, null), baseline(.none, "old").soundSince(baseline(.working, "old"), false));
    try testing.expectEqual(@as(?Sound, null), baseline(.none, null).soundSince(baseline(.working, null), false));
}

test "a run error chimes once and never masquerades as completion" {
    const errored = baseline(.errored, "failed");
    try testing.expectEqual(@as(?Sound, .attention), errored.soundSince(baseline(.working, "old"), false));
    try testing.expectEqual(@as(?Sound, null), errored.soundSince(errored, false));
}

test "queue completions survive coalesced working states; pending sends consume completion" {
    const second = baseline(.working, "first");
    try testing.expectEqual(@as(?Sound, .done), second.soundSince(baseline(.working, null), false));
    try testing.expectEqual(@as(?Sound, null), second.soundSince(second, false));
    try testing.expectEqual(@as(?Sound, .done), baseline(.none, "second").soundSince(second, false));
    const settled = baseline(.none, "first");
    try testing.expectEqual(@as(?Sound, null), settled.soundSince(baseline(.working, null), true));
    try testing.expectEqual(@as(?Sound, .request), baseline(.awaiting_input, "first").soundSince(settled, true));
    var stale = baseline(.none, "old");
    stale.fresh = false;
    try testing.expectEqual(@as(?Sound, null), stale.soundSince(baseline(.working, null), false));
}

test "durable connectivity degradation chimes once per outage" {
    try testing.expectEqual(@as(?Sound, null), connectivitySoundSince(.connected, .disabled));
    try testing.expectEqual(@as(?Sound, .attention), connectivitySoundSince(.reconnecting, .connected));
    try testing.expectEqual(@as(?Sound, null), connectivitySoundSince(.offline, .reconnecting));
    try testing.expectEqual(@as(?Sound, null), connectivitySoundSince(.connected, .offline));
    try testing.expectEqual(@as(?Sound, .attention), connectivitySoundSince(.offline, .connected));
}

test "connectivity boot outages seed silently then later outages alert" {
    var warm: ConnectivityState = .{};
    try testing.expectEqual(@as(?Sound, null), warm.update(.disabled, false, 0));
    try testing.expectEqual(@as(?Sound, null), warm.update(.offline, true, 0));
    try testing.expectEqual(@as(?Sound, null), warm.update(.connected, true, 6000));
    try testing.expectEqual(@as(?Sound, .attention), warm.update(.offline, true, 7000));
    var cold: ConnectivityState = .{};
    try testing.expectEqual(@as(?Sound, null), cold.update(.connected, true, 0));
    try testing.expectEqual(@as(?Sound, null), cold.update(.offline, true, 4000));
    try testing.expectEqual(@as(?Sound, null), cold.update(.connected, true, 5000));
    try testing.expectEqual(@as(?Sound, .attention), cold.update(.reconnecting, true, 6000));
    var healthy: ConnectivityState = .{};
    try testing.expectEqual(@as(?Sound, null), healthy.update(.connected, true, 0));
    try testing.expectEqual(@as(?Sound, .attention), healthy.update(.offline, true, 6000));
    try testing.expectEqual(@as(?Sound, null), healthy.update(.disabled, false, 7000));
    try testing.expectEqual(@as(?Sound, null), healthy.update(.offline, true, 7000));
}

test "attention gate coalesces" {
    var g: AttentionGate = .{};
    try testing.expect(g.shouldPlay(1000));
    try testing.expect(!g.shouldPlay(1000));
    try testing.expect(!g.shouldPlay(1200));
    try testing.expect(g.shouldPlay(1250));
}

test "embedded chimes are WAV" {
    for ([_]Sound{ .done, .request, .attention }) |s| {
        const d = s.bytes();
        try testing.expect(d.len > 1000);
        try testing.expectEqualStrings("RIFF", d[0..4]);
        try testing.expectEqualStrings("WAVE", d[8..12]);
    }
}

test "session sound settings" {
    var s: model.UiSettings = .{};
    try testing.expect(sessionSoundEnabled(&s, .done));
    s.soundCompletionEnabled = false;
    try testing.expect(!sessionSoundEnabled(&s, .done));
    try testing.expect(sessionSoundEnabled(&s, .request));
    s.soundEnabled = false;
    try testing.expect(!sessionSoundEnabled(&s, .attention));
}
