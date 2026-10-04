//! Workspace registry state — the chats / spaces / devices / sessions /
//! sidebar-preferences half of zeron `AppState` (`crates/ui/src/state.rs`):
//! reducers (`applyChats`, `applySessions`, `applySpaces`, `applyDevices`,
//! `applySidebarPreferences`), selection (`selectChat`, `selectSpace`,
//! `selectDevice`, canvas target), and the queries views render from
//! (`visibleChats`, `overviewChats`, `sidebarChats`, `chatsInSpace`,
//! `displayStatusFor`, `indicatorFor`, `deviceOnline`, ...).
//!
//! Data arrives through the snapshot streams `WatchChats`, `WatchSpaces`,
//! `WatchDevices`, `WatchSessions`, `WatchSidebarPreferences` (full list on
//! every change). Each frame is decoded into its own arena and replaces the
//! previous one; a typed event is emitted and `cx.notify()` called only when
//! the presentation changed (sessions/devices ignore pure heartbeat moves the
//! way Rust's `*_presentation` keys do). Streams that end are resubscribed
//! after 2s (`RETRY_DELAY`); the whole set reopens on reconnect.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const zpui = @import("zpui");
const engine_mod = @import("zeron_engine");
const view = @import("view.zig");
const time = @import("time.zig");
const eql = @import("eql.zig");
const es = @import("engine_state.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Task = zpui.Task;
const Subscription = zpui.Subscription;
const protocol = engine_mod.protocol;
const Chat = protocol.Chat;
const Space = protocol.Space;
const Device = protocol.Device;
const Session = protocol.Session;
const Timestamp = time.Timestamp;
const EngineState = es.EngineState;

const log = std.log.scoped(.zeron_workspace);

pub const ChatsChanged = struct {};
pub const SpacesChanged = struct {};
pub const DevicesChanged = struct {};
pub const SessionsChanged = struct {};
pub const SidebarPreferencesChanged = struct {};
/// `selected_chat` / `selected_space` / `selected_device` / `no_project` changed.
pub const SelectionChanged = struct {};

/// The new-session canvas's project/device pick, set aside while a chat is open.
pub const CanvasTarget = struct {
    space: ?[]u8 = null,
    no_project: bool = false,
    device: ?[]u8 = null,

    fn deinit(t: *CanvasTarget, gpa: Allocator) void {
        if (t.space) |s| gpa.free(s);
        if (t.device) |d| gpa.free(d);
        t.* = .{};
    }
};

fn Frame(comptime T: type) type {
    return ?json.Parsed(T);
}

pub const WorkspaceStore = struct {
    gpa: Allocator,
    engine: Entity(EngineState),
    engine_sub: Subscription,

    chats_frame: Frame([]Chat) = null,
    spaces_frame: Frame([]Space) = null,
    devices_frame: Frame([]Device) = null,
    sessions_frame: Frame([]Session) = null,
    sidebar_frame: Frame(protocol.SidebarPreferencesState) = null,
    /// Last published effective indicators per session (presence ticks).
    session_presence: std.ArrayList(view.Indicator) = .empty,

    watch_chats: es.Watch = .{},
    watch_spaces: es.Watch = .{},
    watch_devices: es.Watch = .{},
    watch_sessions: es.Watch = .{},
    watch_sidebar: es.Watch = .{},
    retry_task: Task(void) = .none,
    local_device_task: bool = false,

    /// This engine's device id (EngineInfo, refined by `LocalDevice`).
    local_device_id: ?[]u8 = null,
    workspace_scope: ?protocol.WorkspaceScope = null,

    selected_chat: ?[]u8 = null,
    selected_space: ?[]u8 = null,
    /// Deliberate "Don't work in a project" pick.
    no_project: bool = false,
    selected_device: ?[]u8 = null,
    canvas_target: ?CanvasTarget = null,
    /// Boot auto-select happened (or a manual selection superseded it).
    auto_selected: bool = false,
    /// First chats / spaces frame landed.
    chats_synced: bool = false,
    spaces_synced: bool = false,
    /// Bumps whenever chats/spaces/local device change (file-link roots).
    link_roots_revision: u64 = 0,

    /// Clock override for tests (`null` = wall clock).
    now_override: ?Timestamp = null,
    io: std.Io,

    pub const Events = .{ ChatsChanged, SpacesChanged, DevicesChanged, SessionsChanged, SidebarPreferencesChanged, SelectionChanged };

    pub fn init(engine: Entity(EngineState), cx: *Context(WorkspaceStore)) !WorkspaceStore {
        var self: WorkspaceStore = .{
            .gpa = cx.gpa(),
            .engine = engine.retain(cx),
            .engine_sub = undefined,
            .io = engine.read(cx).io,
        };
        errdefer self.engine.release(cx);
        self.engine_sub = try cx.subscribe(engine, onEngineEvent);
        if (engine.read(cx).isReady()) self.attach(cx);
        return self;
    }

    pub fn deinit(self: *WorkspaceStore, app: *App) void {
        self.engine_sub.deinit();
        self.retry_task.cancel();
        self.closeWatches();
        inline for (.{ "chats_frame", "spaces_frame", "devices_frame", "sessions_frame", "sidebar_frame" }) |f| {
            if (@field(self, f)) |fr| fr.deinit();
        }
        self.session_presence.deinit(self.gpa);
        freeOpt(self.gpa, &self.local_device_id);
        freeOpt(self.gpa, &self.selected_chat);
        freeOpt(self.gpa, &self.selected_space);
        freeOpt(self.gpa, &self.selected_device);
        if (self.canvas_target) |*t| t.deinit(self.gpa);
        self.engine.release(app);
    }

    fn now(self: *const WorkspaceStore) Timestamp {
        return self.now_override orelse Timestamp.now(self.io);
    }

    // ---- connection -----------------------------------------------------------------

    fn onEngineEvent(self: *WorkspaceStore, _: Entity(EngineState), ev: *const es.EngineEvent, cx: *Context(WorkspaceStore)) void {
        switch (ev.*) {
            .connected => self.attach(cx),
            .disconnected => {
                self.closeWatches();
                self.retry_task.cancel();
            },
            .wake => self.drain(cx),
        }
    }

    fn attach(self: *WorkspaceStore, cx: *Context(WorkspaceStore)) void {
        const engine = self.engine.read(cx);
        const info = engine.info() orelse return;
        self.workspace_scope = info.workspaceScope;
        setOpt(self.gpa, &self.local_device_id, info.deviceId);
        self.link_roots_revision +%= 1;
        inline for (.{ "watch_chats", "watch_spaces", "watch_devices", "watch_sessions", "watch_sidebar" }) |f| {
            @field(self, f).unsupported = false;
        }
        self.openWatches(cx);
        // Best-effort `LocalDevice` probe (the "This device" badge).
        EngineState.request(self.engine, cx, WorkspaceStore, cx.entityId(), .LocalDevice, {}, onLocalDevice) catch {};
        cx.notify();
    }

    fn onLocalDevice(self: *WorkspaceStore, result: es.CallResult, cx: *Context(WorkspaceStore)) void {
        const v = switch (result) {
            .ok => |v| v,
            .err => return log.debug("LocalDevice unavailable; skipping this-device badge", .{}),
        };
        if (v != .object) return;
        const id = v.object.get("id") orelse v.object.get("deviceId") orelse return;
        if (id != .string) return;
        setOpt(self.gpa, &self.local_device_id, id.string);
        self.link_roots_revision +%= 1;
        cx.notify();
    }

    fn openWatches(self: *WorkspaceStore, cx: *Context(WorkspaceStore)) void {
        const engine = self.engine.read(cx);
        const conn = engine.conn orelse return;
        const methods = .{
            .{ "watch_chats", engine_mod.Method.WatchChats },
            .{ "watch_spaces", engine_mod.Method.WatchSpaces },
            .{ "watch_devices", engine_mod.Method.WatchDevices },
            .{ "watch_sessions", engine_mod.Method.WatchSessions },
            .{ "watch_sidebar", engine_mod.Method.WatchSidebarPreferences },
        };
        var failed = false;
        inline for (methods) |m| {
            const w = &@field(self, m[0]);
            if (!w.isOpen() and !w.unsupported) w.open(conn, m[1], {}) catch |err| {
                log.debug("{s} unavailable: {t}; retrying", .{ m[1].name(), err });
                failed = true;
            };
        }
        if (failed) self.scheduleRetry(cx);
    }

    fn closeWatches(self: *WorkspaceStore) void {
        self.watch_chats.close();
        self.watch_spaces.close();
        self.watch_devices.close();
        self.watch_sessions.close();
        self.watch_sidebar.close();
    }

    fn scheduleRetry(self: *WorkspaceStore, cx: *Context(WorkspaceStore)) void {
        if (self.retry_task.header != null) return;
        self.retry_task = cx.timer(es.retry_delay_ns, onRetry) catch return;
    }

    fn onRetry(self: *WorkspaceStore, cx: *Context(WorkspaceStore)) void {
        self.retry_task.detach();
        self.openWatches(cx);
    }

    /// Stream ended: resubscribe after the retry delay (stop on UnknownMethod).
    fn checkEnd(self: *WorkspaceStore, w: *es.Watch, method: []const u8, cx: *Context(WorkspaceStore)) void {
        switch (w.end(null)) {
            .open => return,
            .unknown_method => {
                log.debug("{s} not served by this engine", .{method});
                w.unsupported = true;
                w.close();
            },
            .closed => w.close(), // the engine-level reconnect reopens everything
            .done, .remote => {
                log.debug("{s} stream ended; resubscribing", .{method});
                w.close();
                self.scheduleRetry(cx);
            },
        }
    }

    fn drain(self: *WorkspaceStore, cx: *Context(WorkspaceStore)) void {
        if (es.latest([]Chat, &self.watch_chats, "WatchChats")) |frame| self.applyChats(frame, cx);
        self.checkEnd(&self.watch_chats, "WatchChats", cx);
        if (es.latest([]Space, &self.watch_spaces, "WatchSpaces")) |frame| self.applySpaces(frame, cx);
        self.checkEnd(&self.watch_spaces, "WatchSpaces", cx);
        if (es.latest([]Device, &self.watch_devices, "WatchDevices")) |frame| self.applyDevices(frame, cx);
        self.checkEnd(&self.watch_devices, "WatchDevices", cx);
        if (es.latest([]Session, &self.watch_sessions, "WatchSessions")) |frame| self.applySessions(frame, cx);
        self.checkEnd(&self.watch_sessions, "WatchSessions", cx);
        if (es.latest(protocol.SidebarPreferencesState, &self.watch_sidebar, "WatchSidebarPreferences")) |frame| self.applySidebarPreferences(frame, cx);
        self.checkEnd(&self.watch_sidebar, "WatchSidebarPreferences", cx);
    }

    // ---- reducers ---------------------------------------------------------------------

    /// Sorted (`sortChats`); includes archived rows — views filter.
    pub fn chats(self: *const WorkspaceStore) []Chat {
        return if (self.chats_frame) |f| f.value else &.{};
    }

    /// Sorted (`sortSpaces`).
    pub fn spaces(self: *const WorkspaceStore) []Space {
        return if (self.spaces_frame) |f| f.value else &.{};
    }

    pub fn devices(self: *const WorkspaceStore) []Device {
        return if (self.devices_frame) |f| f.value else &.{};
    }

    pub fn sessions(self: *const WorkspaceStore) []Session {
        return if (self.sessions_frame) |f| f.value else &.{};
    }

    pub fn sidebarPreferences(self: *const WorkspaceStore) protocol.SidebarPreferencesState {
        return if (self.sidebar_frame) |f| f.value else .{ .synced = false, .initialized = false };
    }

    /// Takes ownership of `frame`.
    pub fn applyChats(self: *WorkspaceStore, frame: json.Parsed([]Chat), cx: *Context(WorkspaceStore)) void {
        view.sortChats(frame.value);
        const changed = if (self.chats_frame) |old| !eql.deepEql(old.value, frame.value) else true;
        if (self.chats_frame) |old| old.deinit();
        self.chats_frame = frame;
        self.link_roots_revision +%= 1;
        self.chats_synced = true;
        if (self.selected_chat) |selected| {
            if (self.chat(selected) == null) {
                // Selected chat vanished (deleted elsewhere): drop the selection.
                freeOpt(self.gpa, &self.selected_chat);
                self.restoreCanvasTarget();
                cx.emit(SelectionChanged{});
            }
        }
        if (changed) {
            cx.emit(ChatsChanged{});
            cx.notify();
        }
    }

    /// Change = any session field other than `updatedAt` (a liveness lease,
    /// not visible text), or any effective indicator.
    pub fn applySessions(self: *WorkspaceStore, frame: json.Parsed([]Session), cx: *Context(WorkspaceStore)) void {
        const n = self.now();
        var presence: std.ArrayList(view.Indicator) = .empty;
        presence.ensureTotalCapacity(self.gpa, frame.value.len) catch {};
        for (frame.value) |*s| presence.append(self.gpa, view.effectiveIndicator(s, n)) catch {};
        var changed = self.sessions_frame == null or
            !std.mem.eql(view.Indicator, presence.items, self.session_presence.items);
        if (!changed) {
            const old = self.sessions_frame.?.value;
            if (old.len != frame.value.len) changed = true else for (old, frame.value) |a, b| {
                var x = a;
                var y = b;
                x.updatedAt = "";
                y.updatedAt = "";
                if (!eql.deepEql(x, y)) {
                    changed = true;
                    break;
                }
            }
        }
        self.session_presence.deinit(self.gpa);
        self.session_presence = presence;
        if (self.sessions_frame) |old| old.deinit();
        self.sessions_frame = frame;
        if (changed) {
            cx.emit(SessionsChanged{});
            cx.notify();
        }
    }

    pub fn applySpaces(self: *WorkspaceStore, frame: json.Parsed([]Space), cx: *Context(WorkspaceStore)) void {
        view.sortSpaces(frame.value);
        const changed = if (self.spaces_frame) |old| !eql.deepEql(old.value, frame.value) else true;
        if (self.spaces_frame) |old| old.deinit();
        self.spaces_frame = frame;
        self.link_roots_revision +%= 1;
        self.spaces_synced = true;
        const before = self.selected_space;
        var selection_changed = false;
        if (self.no_project) {
            if (self.selected_space != null) {
                freeOpt(self.gpa, &self.selected_space);
                selection_changed = true;
            }
        } else {
            // Heal a vanished selection, then make sure the canvas has a project.
            if (self.selected_space) |sel| if (self.space(sel) == null) {
                self.setSelectedSpace(self.firstSpaceOnPickedDevice());
                selection_changed = true;
            };
            if (self.selected_space == null) {
                self.setSelectedSpace(self.firstSpaceOnPickedDevice());
                selection_changed = selection_changed or self.selected_space != null;
            }
        }
        _ = before;
        if (selection_changed) cx.emit(SelectionChanged{});
        if (changed) cx.emit(SpacesChanged{});
        if (changed or selection_changed) cx.notify();
    }

    /// Change = device metadata (minus `lastSeenAt`), online state, or the
    /// formatted last-seen line, or a session's effective indicator.
    pub fn applyDevices(self: *WorkspaceStore, frame: json.Parsed([]Device), cx: *Context(WorkspaceStore)) void {
        const n = self.now();
        // A local-only workspace keeps the engine's legacy sentinel out of the UI.
        if (self.workspace_scope == .local) if (self.local_device_id) |local| {
            for (frame.value) |*d| if (std.mem.eql(u8, d.id, local) and std.mem.eql(u8, d.name, "unknown-device")) {
                d.name = "Local";
            };
        };
        var changed = self.devices_frame == null;
        if (!changed) {
            const old = self.devices_frame.?.value;
            if (old.len != frame.value.len) changed = true else for (old, frame.value) |a, b| {
                if (!devicePresentationEql(a, b, n)) {
                    changed = true;
                    break;
                }
            }
        }
        for (self.sessions(), 0..) |*s, i| {
            const ind = view.effectiveIndicator(s, n);
            if (i >= self.session_presence.items.len or self.session_presence.items[i] != ind) {
                changed = true;
                if (i < self.session_presence.items.len) self.session_presence.items[i] = ind;
            }
        }
        if (self.devices_frame) |old| old.deinit();
        self.devices_frame = frame;
        if (changed) {
            cx.emit(DevicesChanged{});
            cx.notify();
        }
    }

    fn devicePresentationEql(a: Device, b: Device, n: Timestamp) bool {
        var x = a;
        var y = b;
        const la = time.parseOpt(a.lastSeenAt);
        const lb = time.parseOpt(b.lastSeenAt);
        x.lastSeenAt = null;
        y.lastSeenAt = null;
        if (!eql.deepEql(x, y)) return false;
        if (view.deviceOnline(la, n) != view.deviceOnline(lb, n)) return false;
        var b1: [32]u8 = undefined;
        var b2: [32]u8 = undefined;
        return std.mem.eql(u8, view.formatLastSeen(&b1, la, n), view.formatLastSeen(&b2, lb, n));
    }

    /// Ignores stale revisions and identical frames.
    pub fn applySidebarPreferences(self: *WorkspaceStore, frame: json.Parsed(protocol.SidebarPreferencesState), cx: *Context(WorkspaceStore)) void {
        if (self.sidebar_frame) |old| {
            if (frame.value.revision < old.value.revision or eql.deepEql(frame.value, old.value)) {
                frame.deinit();
                return;
            }
            old.deinit();
        }
        self.sidebar_frame = frame;
        cx.emit(SidebarPreferencesChanged{});
        cx.notify();
    }

    /// Optimistic echo of a `setChatConfig` mutate. `config` strings must
    /// outlive the current chats frame (copy them into `chatsArena()`).
    pub fn applyChatConfig(self: *WorkspaceStore, chat_id: []const u8, config: protocol.ChatConfig, cx: *Context(WorkspaceStore)) void {
        const c = self.chatMut(chat_id) orelse return;
        c.config = config;
        cx.emit(ChatsChanged{});
        cx.notify();
    }

    /// Arena of the current chats frame (for optimistic row edits).
    pub fn chatsArena(self: *WorkspaceStore) ?Allocator {
        return if (self.chats_frame) |*f| f.arena.allocator() else null;
    }

    // ---- queries --------------------------------------------------------------------

    pub fn chat(self: *const WorkspaceStore, id: []const u8) ?*const Chat {
        for (self.chats()) |*c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }

    fn chatMut(self: *WorkspaceStore, id: []const u8) ?*Chat {
        for (self.chats()) |*c| if (std.mem.eql(u8, c.id, id)) return c;
        return null;
    }

    pub fn space(self: *const WorkspaceStore, id: []const u8) ?*const Space {
        for (self.spaces()) |*s| if (std.mem.eql(u8, s.id, id)) return s;
        return null;
    }

    pub fn device(self: *const WorkspaceStore, id: []const u8) ?*const Device {
        for (self.devices()) |*d| if (std.mem.eql(u8, d.id, id)) return d;
        return null;
    }

    pub fn sessionFor(self: *const WorkspaceStore, chat_id: []const u8) ?*const Session {
        for (self.sessions()) |*s| if (std.mem.eql(u8, s.chatId, chat_id)) return s;
        return null;
    }

    /// Non-archived, top-level chats in sidebar order (children of another
    /// chat — `parentChatId` — never take a sidebar row).
    pub fn visibleChats(self: *const WorkspaceStore, gpa: Allocator) Allocator.Error![]*const Chat {
        var out: std.ArrayList(*const Chat) = .empty;
        for (self.chats()) |*c| if (!c.archived and c.parentChatId == null) try out.append(gpa, c);
        return out.toOwnedSlice(gpa);
    }

    /// Non-archived chats of a space in tab (creation) order.
    pub fn chatsInSpace(self: *const WorkspaceStore, gpa: Allocator, space_id: []const u8) Allocator.Error![]*const Chat {
        var out: std.ArrayList(*const Chat) = .empty;
        for (self.chats()) |*c| {
            if (c.archived or c.parentChatId != null) continue;
            if (c.spaceId) |s| if (std.mem.eql(u8, s, space_id)) try out.append(gpa, c);
        }
        view.sortTabs(out.items);
        return out.toOwnedSlice(gpa);
    }

    /// Spaces in display order (case-insensitive alphabetical, id tiebreak).
    pub fn spacesSorted(self: *const WorkspaceStore, gpa: Allocator) Allocator.Error![]*const Space {
        const out = try gpa.alloc(*const Space, self.spaces().len);
        for (self.spaces(), out) |*s, *o| o.* = s;
        std.sort.block(*const Space, out, {}, struct {
            fn lt(_: void, a: *const Space, b: *const Space) bool {
                const o = lowerOrder(view.spaceDisplayName(a), view.spaceDisplayName(b));
                if (o != .eq) return o == .lt;
                return std.mem.order(u8, a.id, b.id) == .lt;
            }
        }.lt);
        return out;
    }

    pub fn spaceForChat(self: *const WorkspaceStore, c: *const Chat) ?*const Space {
        return self.space(c.spaceId orelse return null);
    }

    pub fn deviceName(self: *const WorkspaceStore, device_id: []const u8) ?[]const u8 {
        return if (self.device(device_id)) |d| d.name else null;
    }

    /// Host presence: the local device is online; unknown devices get the
    /// benefit of the doubt.
    pub fn deviceOnline(self: *const WorkspaceStore, device_id: []const u8, n: Timestamp) bool {
        if (self.local_device_id) |l| if (std.mem.eql(u8, l, device_id)) return true;
        const d = self.device(device_id) orelse return true;
        return view.deviceOnline(time.parseOpt(d.lastSeenAt), n);
    }

    /// Full display status for a chat (tab dots, Active list).
    pub fn displayStatusFor(self: *const WorkspaceStore, c: *const Chat, n: Timestamp) view.ChatIndicator {
        return view.displayStatus(c, self.sessionFor(c.id), n);
    }

    /// Staleness-checked status dot for a chat row.
    pub fn indicatorFor(self: *const WorkspaceStore, chat_id: []const u8, n: Timestamp) view.Indicator {
        return view.effectiveIndicator(self.sessionFor(chat_id), n);
    }

    /// The sidebar's Sessions list: non-archived chats of a live space (or
    /// project-less), in pure recency order.
    pub fn overviewChats(self: *const WorkspaceStore, gpa: Allocator, n: Timestamp) Allocator.Error![]view.ActiveRow {
        var out: std.ArrayList(view.ActiveRow) = .empty;
        for (self.chats()) |*c| {
            if (c.archived or c.parentChatId != null) continue;
            if (c.spaceId) |sid| if (self.space(sid) == null) continue;
            try out.append(gpa, .{ .status = self.displayStatusFor(c, n), .chat = c });
        }
        view.sortActive(out.items);
        return out.toOwnedSlice(gpa);
    }

    /// `overviewChats` narrowed to the sidebar's project filter (what the jump
    /// shortcuts count).
    pub fn sidebarChats(self: *const WorkspaceStore, gpa: Allocator, n: Timestamp, space_filter: ?[]const u8) Allocator.Error![]view.ActiveRow {
        const rows = try self.overviewChats(gpa, n);
        const filter = space_filter orelse return rows;
        var kept: usize = 0;
        for (rows) |r| {
            if (r.chat.spaceId) |s| if (std.mem.eql(u8, s, filter)) {
                rows[kept] = r;
                kept += 1;
            };
        }
        if (gpa.resize(rows, kept)) return rows[0..kept];
        const out = try gpa.dupe(view.ActiveRow, rows[0..kept]);
        gpa.free(rows);
        return out;
    }

    pub fn selectedChatRow(self: *const WorkspaceStore) ?*const Chat {
        return self.chat(self.selected_chat orelse return null);
    }

    /// The chat the Archive shortcut acts on (never an archived one).
    pub fn archivableSelectedChat(self: *const WorkspaceStore) ?[]const u8 {
        const c = self.selectedChatRow() orelse return null;
        return if (c.archived) null else c.id;
    }

    pub fn selectedSpaceRow(self: *const WorkspaceStore) ?*const Space {
        if (self.no_project) return null;
        return self.space(self.selected_space orelse return null);
    }

    /// The device the new-session canvas targets.
    pub fn effectiveDeviceId(self: *const WorkspaceStore) ?[]const u8 {
        if (self.selectedSpaceRow()) |s| return s.deviceId;
        return self.selected_device orelse self.local_device_id;
    }

    pub fn selectedSpaceGit(self: *const WorkspaceStore) bool {
        return if (self.selectedSpaceRow()) |s| s.gitDetected else false;
    }

    pub fn deviceVersionAtLeast(self: *const WorkspaceStore, device_id: []const u8, min: [3]u64) bool {
        const d = self.device(device_id) orelse return false;
        const v = view.versionTriple(d.version orelse return false) orelse return false;
        return view.versionAtLeast(v, min);
    }

    /// Live EngineInfo for this device, synced rows for peers.
    pub fn deviceSupports(self: *const WorkspaceStore, engine: *const EngineState, device_id: []const u8, capability: []const u8) bool {
        if (engine.info()) |i| if (std.mem.eql(u8, i.deviceId, device_id)) return i.supports(capability);
        const d = self.device(device_id) orelse return false;
        for (d.capabilities) |c| if (std.mem.eql(u8, c, capability)) return true;
        return false;
    }

    /// "@ device" tag + offline flag for a space row.
    pub fn spaceDeviceTag(self: *const WorkspaceStore, buf: []u8, s: *const Space, n: Timestamp) struct { []const u8, bool } {
        const name = self.deviceName(s.deviceId) orelse "Unknown device";
        const tag = std.fmt.bufPrint(buf, "@ {s}", .{name}) catch name;
        return .{ tag, !self.deviceOnline(s.deviceId, n) };
    }

    /// Is this chat's delivery path degraded (a send would QUEUE)?
    pub fn chatDeliveryDegraded(self: *const WorkspaceStore, connectivity: *const protocol.Connectivity, chat_id: []const u8, n: Timestamp) bool {
        if (connectivity.state == .disabled) return false;
        const c = self.chat(chat_id) orelse return connectivity.state != .connected;
        if (self.local_device_id) |l| if (std.mem.eql(u8, c.deviceId, l)) return false;
        if (connectivity.state == .offline or !self.deviceOnline(c.deviceId, n)) return true;
        const net: ?protocol.ChatConnectivity = for (connectivity.chats) |cc| {
            if (std.mem.eql(u8, cc.chatId, chat_id)) break cc;
        } else null;
        if (connectivity.state == .reconnecting) return !(if (net) |x| x.deliveryLive else false);
        const x = net orelse return false;
        if (x.syncState == .local) return false;
        return !x.connected;
    }

    // ---- selection ------------------------------------------------------------------

    fn firstSpaceOnPickedDevice(self: *const WorkspaceStore) ?[]const u8 {
        const dev = self.selected_device orelse self.local_device_id;
        var best: ?*const Space = null;
        var best_any: ?*const Space = null;
        for (self.spaces()) |*s| {
            if (best_any == null or spaceDisplayLess(s, best_any.?)) best_any = s;
            if (dev) |d| if (std.mem.eql(u8, s.deviceId, d)) {
                if (best == null or spaceDisplayLess(s, best.?)) best = s;
            };
        }
        const pick = best orelse best_any orelse return null;
        return pick.id;
    }

    fn setSelectedSpace(self: *WorkspaceStore, id: ?[]const u8) void {
        setOpt(self.gpa, &self.selected_space, id);
    }

    fn currentCanvasTarget(self: *const WorkspaceStore) CanvasTarget {
        return .{
            .space = if (self.selected_space) |s| self.gpa.dupe(u8, s) catch null else null,
            .no_project = self.no_project,
            .device = if (self.selected_device) |d| self.gpa.dupe(u8, d) catch null else null,
        };
    }

    fn restoreCanvasTarget(self: *WorkspaceStore) void {
        var target = self.canvas_target orelse return;
        self.canvas_target = null;
        freeOpt(self.gpa, &self.selected_device);
        freeOpt(self.gpa, &self.selected_space);
        self.selected_device = target.device;
        self.selected_space = target.space;
        self.no_project = target.no_project;
        target = .{};
        if (self.spaces_synced and !self.no_project) {
            const ok = if (self.selected_space) |s| self.space(s) != null else false;
            if (!ok) self.setSelectedSpace(self.firstSpaceOnPickedDevice());
        }
    }

    /// Select a chat (or the new-session canvas with null). Implies the
    /// chat's project/device; marks it seen; sends the `FocusChat` hint.
    pub fn selectChat(self: *WorkspaceStore, chat_id: ?[]const u8, cx: *Context(WorkspaceStore)) void {
        if (chat_id) |id| EngineState.send(self.engine, cx, .FocusChat, protocol.params.ChatId{ .chatId = id }) catch {};
        const same = if (self.selected_chat) |s| (chat_id != null and std.mem.eql(u8, s, chat_id.?)) else chat_id == null;
        if (same) {
            if (chat_id) |id| self.markChatSeen(id, cx);
            return;
        }
        if (self.selected_chat == null and chat_id != null) {
            if (self.canvas_target) |*t| t.deinit(self.gpa);
            self.canvas_target = self.currentCanvasTarget();
        } else if (self.selected_chat != null and chat_id == null) {
            self.restoreCanvasTarget();
        }
        setOpt(self.gpa, &self.selected_chat, chat_id);
        self.auto_selected = true;
        if (chat_id) |id| {
            if (self.chat(id)) |c| {
                if (c.spaceId) |sid| {
                    self.setSelectedSpace(sid);
                    self.no_project = false;
                } else {
                    freeOpt(self.gpa, &self.selected_space);
                    self.no_project = true;
                    setOpt(self.gpa, &self.selected_device, c.deviceId);
                }
            }
            self.markChatSeen(id, cx);
        }
        cx.emit(SelectionChanged{});
        cx.notify();
    }

    /// Seed the canvas target from sticky composer defaults at boot
    /// (`restore_composer_target`); a chat selection or explicit opt-out wins.
    pub fn restoreComposerTarget(self: *WorkspaceStore, defaults: *const @import("composer_defaults.zig").ComposerDefaults, cx: *Context(WorkspaceStore)) void {
        if (self.selected_chat != null or self.no_project) return;
        if (self.selected_device == null) setOpt(self.gpa, &self.selected_device, defaults.device);
        if (self.selected_space == null) {
            self.no_project = defaults.noProject;
            self.setSelectedSpace(if (defaults.noProject) null else defaults.project);
        }
        cx.emit(SelectionChanged{});
        cx.notify();
    }

    /// Select a project; null is the "Don't work in a project" opt-out.
    pub fn selectSpace(self: *WorkspaceStore, space_id: ?[]const u8, cx: *Context(WorkspaceStore)) void {
        if (space_id) |id| {
            self.no_project = false;
            if (self.space(id)) |s| setOpt(self.gpa, &self.selected_device, s.deviceId);
        } else {
            const eff = self.effectiveDeviceId();
            setOpt(self.gpa, &self.selected_device, eff);
            self.no_project = true;
        }
        self.setSelectedSpace(space_id);
        cx.emit(SelectionChanged{});
        cx.notify();
    }

    /// Pick the composer's device; a project on another device can't survive
    /// the switch.
    pub fn selectDevice(self: *WorkspaceStore, device_id: []const u8, cx: *Context(WorkspaceStore)) void {
        const moves = if (self.selectedSpaceRow()) |s| !std.mem.eql(u8, s.deviceId, device_id) else false;
        if (moves) {
            var first: ?*const Space = null;
            for (self.spaces()) |*s| if (std.mem.eql(u8, s.deviceId, device_id)) {
                if (first == null or spaceDisplayLess(s, first.?)) first = s;
            };
            self.no_project = first == null;
            self.setSelectedSpace(if (first) |f| f.id else null);
        }
        setOpt(self.gpa, &self.selected_device, device_id);
        cx.emit(SelectionChanged{});
        cx.notify();
    }

    /// Synced seen marker: only when unseen; stamps the row optimistically and
    /// fire-and-forgets `Mutate{op: markChatSeen}`.
    pub fn markChatSeen(self: *WorkspaceStore, chat_id: []const u8, cx: *Context(WorkspaceStore)) void {
        const c = self.chatMut(chat_id) orelse return;
        if (!view.chatUnseen(c)) return;
        const arena = self.chatsArena() orelse return;
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        self.now().format(&w) catch return;
        c.lastSeenAt = arena.dupe(u8, w.buffered()) catch return;
        cx.emit(ChatsChanged{});
        cx.notify();
        EngineState.send(self.engine, cx, .Mutate, protocol.Mutate{ .markChatSeen = .{ .chatId = chat_id } }) catch |err| {
            log.warn("markChatSeen failed: {t}", .{err});
        };
    }

    /// Fire-and-forget `Mutate`.
    pub fn mutate(self: *WorkspaceStore, op: protocol.Mutate, cx: *Context(WorkspaceStore)) !void {
        try EngineState.send(self.engine, cx, .Mutate, op);
    }

    /// Window-focus liveness sweep (`ProbeSync`).
    pub fn probeSync(self: *WorkspaceStore, cx: *Context(WorkspaceStore)) void {
        EngineState.send(self.engine, cx, .ProbeSync, .{}) catch {};
    }
};

fn spaceDisplayLess(a: *const Space, b: *const Space) bool {
    const o = lowerOrder(view.spaceDisplayName(a), view.spaceDisplayName(b));
    if (o != .eq) return o == .lt;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

/// Order by `to_lowercase()` (ASCII folding; non-ASCII compares bytewise).
fn lowerOrder(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = std.ascii.toLower(x);
        const ly = std.ascii.toLower(y);
        if (lx != ly) return std.math.order(lx, ly);
    }
    return std.math.order(a.len, b.len);
}

fn freeOpt(gpa: Allocator, slot: *?[]u8) void {
    if (slot.*) |s| gpa.free(s);
    slot.* = null;
}

fn setOpt(gpa: Allocator, slot: *?[]u8, value: ?[]const u8) void {
    const copy: ?[]u8 = if (value) |v| gpa.dupe(u8, v) catch null else null;
    freeOpt(gpa, slot);
    slot.* = copy;
}
