//! Fixture mode: run the UI without an engine from JSON files
//! (`zeron --fixtures <dir>` / `ZERON_FIXTURES=<dir>`).
//!
//! Directory layout (every file optional):
//!   meta.json      — see `Meta` (clock, local device, scope, auth, gate,
//!                    selection, pins, PR numbers, sidebar/pane prefs, update)
//!   chats.json     — `[]Chat`     (WatchChats frame)
//!   spaces.json    — `[]Space`    (WatchSpaces frame)
//!   devices.json   — `[]Device`   (WatchDevices frame)
//!   sessions.json  — `[]Session`  (WatchSessions frame)
//!   transcripts/<chat-id>.json — read by the transcript view (`Fixtures.dir`)
//!
//! The frames are fed through the real `WorkspaceStore` reducers, so the
//! sidebar/shell render exactly what a live engine frame would produce.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const engine = @import("zeron_engine");
const prefs_mod = @import("prefs.zig");

const protocol = engine.protocol;
const json = std.json;
const log = std.log.scoped(.zeron_fixtures);

pub const Meta = struct {
    /// Frozen "now" (RFC 3339) so relative times and staleness are stable.
    now: ?[]const u8 = null,
    localDeviceId: ?[]const u8 = null,
    workspaceScope: ?protocol.WorkspaceScope = null,
    auth: ?json.Value = null,
    /// "ready" (default), "loading", "sign_in", "org_gate", or "failed:<message>".
    gate: ?[]const u8 = null,
    selectedChat: ?[]const u8 = null,
    selectedSpace: ?[]const u8 = null,
    spaceFilter: ?[]const u8 = null,
    pins: []const []const u8 = &.{},
    pullRequests: ?json.ArrayHashMap(u64) = null,
    sidebarCollapsed: ?bool = null,
    sidebarCompact: ?bool = null,
    sidebarWidth: ?f32 = null,
    showProjectLabel: ?bool = null,
    showProjectIcon: ?bool = null,
    showBranch: ?bool = null,
    showPullRequest: ?bool = null,
    showHarness: ?bool = null,
    rightPaneOpen: ?bool = null,
    rightPaneWidth: ?f32 = null,
    appearance: ?[]const u8 = null,
    updateAvailable: ?[]const u8 = null,
    /// Keep the boot splash up (screenshots of the splash).
    splash: bool = false,
    /// Show the sidebar's "Star on GitHub" banner (references capture it dismissed).
    githubStarBanner: bool = false,
};

pub const Fixtures = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    dir: []const u8,
    meta: Meta = .{},

    pub fn deinit(self: *Fixtures) void {
        self.arena.deinit();
    }

    /// The gate phase the fixture asks for.
    pub fn gate(self: *const Fixtures) model.view.GatePhase {
        const g = self.meta.gate orelse return .ready;
        if (std.mem.eql(u8, g, "loading")) return .loading;
        if (std.mem.eql(u8, g, "sign_in")) return .sign_in;
        if (std.mem.eql(u8, g, "org_gate")) return .org_gate;
        if (std.mem.startsWith(u8, g, "failed:")) return .{ .failed = g["failed:".len..] };
        return .ready;
    }
};

fn readFile(io: std.Io, a: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    const path = std.fs.path.join(a, &.{ dir, name }) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20)) catch null;
}

fn parseFrame(comptime T: type, gpa: std.mem.Allocator, bytes: []const u8) ?json.Parsed(T) {
    return json.parseFromSlice(T, gpa, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        log.warn("fixture {s}: {t}", .{ @typeName(T), err });
        return null;
    };
}

/// Load `dir/meta.json` (prefs + clock) — call before the window opens.
pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !*Fixtures {
    const f = try gpa.create(Fixtures);
    f.* = .{ .gpa = gpa, .arena = .init(gpa), .dir = undefined };
    const a = f.arena.allocator();
    f.dir = try a.dupe(u8, dir);
    if (readFile(io, a, dir, "meta.json")) |bytes| {
        f.meta = json.parseFromSliceLeaky(Meta, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| blk: {
            log.warn("meta.json: {t}", .{err});
            break :blk .{};
        };
    }
    // Real engine exports (research/reference/fixtures) carry engine-info.json
    // instead of meta: take the local device + scope from it.
    if (f.meta.localDeviceId == null) if (readFile(io, a, dir, "engine-info.json")) |bytes| {
        if (json.parseFromSliceLeaky(protocol.EngineInfo, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |info| {
            f.meta.localDeviceId = info.deviceId;
            if (f.meta.workspaceScope == null) f.meta.workspaceScope = info.workspaceScope;
        } else |_| {}
    };
    // Freeze the clock at the export's newest device heartbeat so relative
    // times match the screenshots taken alongside it.
    if (f.meta.now == null) if (readFile(io, a, dir, "devices.json")) |bytes| {
        if (json.parseFromSliceLeaky([]protocol.Device, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |devs| {
            var best: ?[]const u8 = null;
            for (devs) |d| if (d.lastSeenAt) |t| {
                if (best == null or std.mem.order(u8, t, best.?) == .gt) best = t;
            };
            f.meta.now = best;
        } else |_| {}
    };
    return f;
}

/// Seed `Prefs` from the fixture meta.
pub fn applyPrefs(f: *const Fixtures, p: *prefs_mod.Prefs) void {
    const m = f.meta;
    if (m.now) |n| p.now_override = model.time.parse(n);
    if (m.sidebarCollapsed) |v| p.sidebar_collapsed = v;
    if (m.sidebarCompact) |v| p.sidebar_compact = v;
    if (m.sidebarWidth) |v| p.sidebar_width = v;
    if (m.showProjectLabel) |v| p.show_project_label = v;
    if (m.showProjectIcon) |v| p.show_project_icon = v;
    if (m.showBranch) |v| p.show_branch = v;
    if (m.showPullRequest) |v| p.show_pull_request = v;
    if (m.showHarness) |v| p.show_harness = v;
    if (m.rightPaneOpen) |v| p.right_pane_open = v;
    if (m.rightPaneWidth) |v| p.right_pane_width = v;
    if (m.spaceFilter) |v| p.setFilter(v);
    if (m.updateAvailable) |v| p.update_label = v;
    p.star_banner_hidden = !m.githubStarBanner;
    for (m.pins) |id| p.setPinned(id, true);
    if (m.pullRequests) |prs| {
        var it = prs.map.iterator();
        while (it.next()) |e| {
            const k = p.gpa.dupe(u8, e.key_ptr.*) catch continue;
            p.pull_requests.put(p.gpa, k, e.value_ptr.*) catch p.gpa.free(k);
        }
    }
}

/// Feed the fixture frames through the model stores.
pub fn applyToState(f: *Fixtures, io: std.Io, app: *zpui.App, state: zpui.Entity(model.AppState)) void {
    const a = f.arena.allocator();
    const s = state.read(app);
    const ws = s.workspace;
    {
        var l = ws.lease(app);
        defer l.end();
        const w = l.value;
        if (f.meta.now) |n| w.now_override = model.time.parse(n);
        if (f.meta.localDeviceId) |d| w.local_device_id = f.gpa.dupe(u8, d) catch null;
        w.workspace_scope = f.meta.workspaceScope orelse .local;
        // A capture shows exactly `selectedChat` (null = the canvas), never the boot
        // landing: zeron's fixture examples set `auto_selected` the same way.
        w.auto_selected = true;
    }
    if (readFile(io, a, f.dir, "devices.json")) |b| if (parseFrame([]protocol.Device, f.gpa, b)) |fr| ws.update(app, model.WorkspaceStore.applyDevices, .{fr});
    if (readFile(io, a, f.dir, "spaces.json")) |b| if (parseFrame([]protocol.Space, f.gpa, b)) |fr| ws.update(app, model.WorkspaceStore.applySpaces, .{fr});
    if (readFile(io, a, f.dir, "chats.json")) |b| if (parseFrame([]protocol.Chat, f.gpa, b)) |fr| ws.update(app, model.WorkspaceStore.applyChats, .{fr});
    if (readFile(io, a, f.dir, "sidebar-preferences.json")) |b| if (parseFrame(protocol.SidebarPreferencesState, f.gpa, b)) |fr| ws.update(app, model.WorkspaceStore.applySidebarPreferences, .{fr});
    if (readFile(io, a, f.dir, "sessions.json")) |b| if (parseFrame([]protocol.Session, f.gpa, b)) |fr| ws.update(app, model.WorkspaceStore.applySessions, .{fr});
    if (f.meta.auth) |v| {
        var l = s.auth.lease(app);
        defer l.end();
        l.value.auth = model.view.parseAuthState(a, v);
        l.cx.notify();
    }
    applyCatalog(f, io, app, s.catalog);
    if (f.meta.selectedChat) |id| ws.update(app, model.WorkspaceStore.selectChat, .{@as(?[]const u8, id)});
}

/// `harnesses.json` + `models-<harness>.json` → the harness/model catalog
/// (what ListHarnesses / ListModels would return).
fn applyCatalog(f: *Fixtures, io: std.Io, app: *zpui.App, catalog: zpui.Entity(model.CatalogStore)) void {
    const a = f.arena.allocator();
    var l = catalog.lease(app);
    defer l.end();
    const c = l.value;
    if (readFile(io, a, f.dir, "harnesses.json")) |b| {
        if (json.parseFromSliceLeaky(json.Value, a, b, .{})) |v| {
            if (model.status.OwnedJson([]protocol.HarnessDescriptor).fromValue(f.gpa, v)) |h| {
                if (c.harnesses) |old| old.deinit();
                c.harnesses = h;
            } else |err| log.warn("harnesses.json: {t}", .{err});
        } else |_| {}
    }
    for (std.enums.values(protocol.HarnessId)) |id| {
        const name = std.fmt.allocPrint(a, "models-{t}.json", .{id}) catch return;
        if (readFile(io, a, f.dir, name)) |b| {
            if (json.parseFromSliceLeaky(json.Value, a, b, .{})) |v| {
                if (model.status.OwnedJson([]protocol.Model).fromValue(f.gpa, v)) |m| {
                    if (c.models.get(id)) |old| old.deinit();
                    c.models.set(id, m);
                } else |err| log.warn("{s}: {t}", .{ name, err });
            } else |_| {}
        }
    }
    l.cx.emit(model.status.HarnessesChanged{});
    l.cx.notify();
}

/// The fixture transcript for `chat_id`: `transcripts/<chat-id>.json`, else
/// `transcript-<name>.json` where `seed-ids.json` maps name → chat id.
pub fn transcriptBytes(f: *Fixtures, io: std.Io, chat_id: []const u8) ?[]u8 {
    const a = f.arena.allocator();
    if (readFile(io, a, f.dir, std.fmt.allocPrint(a, "transcripts/{s}.json", .{chat_id}) catch return null)) |b| return b;
    const ids_bytes = readFile(io, a, f.dir, "seed-ids.json") orelse return null;
    const ids = json.parseFromSliceLeaky(json.Value, a, ids_bytes, .{}) catch return null;
    if (ids != .object) return null;
    const chats = ids.object.get("chats") orelse return null;
    if (chats != .object) return null;
    var it = chats.object.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == .string and std.mem.eql(u8, e.value_ptr.string, chat_id)) {
            return readFile(io, a, f.dir, std.fmt.allocPrint(a, "transcript-{s}.json", .{e.key_ptr.*}) catch return null);
        }
    }
    return null;
}
