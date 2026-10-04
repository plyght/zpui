//! `AppState`: the root of the model — zeron `AppState::bootstrap` split into
//! focused stores. It owns the `EngineState` connection and one entity per
//! concern, and follows the workspace selection to keep the selected chat's
//! `TranscriptStore` (+ `QueueStore`) live. Recently viewed transcripts stay
//! cached (inactive, no engine watch) up to `transcript_cache_cap`, like
//! Rust's `TRANSCRIPT_CACHE_CAP`.
//!
//! ```zig
//! const state = try app.newWith(AppState, AppState.init, .{ io, .{ .port = port } });
//! defer state.release(app);
//! // views: state.read(app).workspace, .transcript, .queue, .auth, .sync, ...
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const zpui = @import("zpui");
const engine_mod = @import("zeron_engine");
const view = @import("view.zig");
const es = @import("engine_state.zig");
const workspace_mod = @import("workspace.zig");
const transcript_mod = @import("transcript_store.zig");
const queue_mod = @import("queue_store.zig");
const status = @import("status.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Subscription = zpui.Subscription;
const protocol = engine_mod.protocol;

pub const EngineState = es.EngineState;
pub const WorkspaceStore = workspace_mod.WorkspaceStore;
pub const TranscriptStore = transcript_mod.TranscriptStore;
pub const QueueStore = queue_mod.QueueStore;

pub const transcript_cache_cap = 12;

/// The selected chat's live stores changed (views re-observe).
pub const SelectedChatStoresChanged = struct {};

pub const AppState = struct {
    gpa: Allocator,
    engine: Entity(EngineState),
    workspace: Entity(WorkspaceStore),
    auth: Entity(status.AuthStore),
    sync: Entity(status.SyncStore),
    updates: Entity(status.UpdateStore),
    catalog: Entity(status.CatalogStore),
    /// The selected chat's transcript / queue (null on the new-session canvas).
    transcript: ?Entity(TranscriptStore) = null,
    queue: ?Entity(QueueStore) = null,
    /// Warm, inactive transcripts (most recent last).
    cache: std.ArrayList(Entity(TranscriptStore)) = .empty,
    subs: zpui.Subscriptions = .{},

    pub const Events = .{SelectedChatStoresChanged};

    pub fn init(io: std.Io, config: es.Config, cx: *Context(AppState)) !AppState {
        const engine = try cx.newWith(EngineState, EngineState.init, .{ io, config });
        errdefer engine.release(cx);
        var self: AppState = .{
            .gpa = cx.gpa(),
            .engine = engine,
            .workspace = try cx.newWith(WorkspaceStore, WorkspaceStore.init, .{engine}),
            .auth = try cx.newWith(status.AuthStore, status.AuthStore.init, .{engine}),
            .sync = try cx.newWith(status.SyncStore, status.SyncStore.init, .{engine}),
            .updates = try cx.newWith(status.UpdateStore, status.UpdateStore.init, .{engine}),
            .catalog = try cx.newWith(status.CatalogStore, status.CatalogStore.init, .{engine}),
        };
        try self.subs.add(cx.gpa(), try cx.subscribe(self.workspace, onSelection));
        return self;
    }

    pub fn deinit(self: *AppState, app: *App) void {
        self.subs.deinit(self.gpa);
        if (self.transcript) |t| t.release(app);
        if (self.queue) |q| q.release(app);
        for (self.cache.items) |t| t.release(app);
        self.cache.deinit(self.gpa);
        self.catalog.release(app);
        self.updates.release(app);
        self.sync.release(app);
        self.auth.release(app);
        self.workspace.release(app);
        self.engine.release(app);
    }

    /// `gate()`: the boot gate for the current connection/auth state.
    pub fn gate(self: *const AppState, cx: anytype) view.GatePhase {
        const engine = self.engine.read(cx);
        const auth = self.auth.read(cx);
        return view.gatePhase(engine.connection, engine.workspaceScope(), if (auth.auth) |*a| a else null);
    }

    fn onSelection(self: *AppState, ws: Entity(WorkspaceStore), _: *const workspace_mod.SelectionChanged, cx: *Context(AppState)) void {
        const selected = ws.read(cx).selected_chat;
        const current_id: ?[]const u8 = if (self.transcript) |t| t.read(cx).chat_id else null;
        if (eqlOpt(selected, current_id)) return;
        self.swapSelected(selected, cx) catch |err| std.log.scoped(.zeron_app_state).warn("cannot open chat stores: {t}", .{err});
        cx.emit(SelectedChatStoresChanged{});
        cx.notify();
    }

    fn swapSelected(self: *AppState, chat_id: ?[]const u8, cx: *Context(AppState)) !void {
        if (self.queue) |q| q.release(cx);
        self.queue = null;
        if (self.transcript) |t| {
            self.transcript = null;
            t.update(cx, TranscriptStore.setActive, .{false});
            try self.cache.append(self.gpa, t);
            while (self.cache.items.len > transcript_cache_cap) self.cache.orderedRemove(0).release(cx);
        }
        const id = chat_id orelse return;
        // Reuse a warm transcript (rendered immediately, then healed by the
        // fresh watch's reset).
        const t = for (self.cache.items, 0..) |c, i| {
            if (std.mem.eql(u8, c.read(cx).chat_id, id)) break self.cache.orderedRemove(i);
        } else try cx.newWith(TranscriptStore, TranscriptStore.init, .{ self.engine, id });
        t.update(cx, TranscriptStore.setActive, .{true});
        self.transcript = t;
        self.queue = try cx.newWith(QueueStore, QueueStore.init, .{ self.engine, id, t });
    }
};

fn eqlOpt(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}
