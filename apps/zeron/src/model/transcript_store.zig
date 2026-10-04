//! One chat's transcript as a zpui entity — the `transcript` /
//! `receive_*_transcript_update` / `spawn_transcript_watch` part of zeron
//! `AppState`, plus the optimistic echoes and pending-send overlay that hang
//! off the selected chat.
//!
//! The watch is `WatchDocMessages{chatId, openingTail: true}`: the engine
//! first sends a provisional tail preview (`historyPending: true`), then the
//! full reset, then deltas. Frames apply through `Transcript.applyUpdate`
//! (the engine client's port of `apply_transcript_frame`):
//! - a desync (count/len tripwire) resubscribes immediately — the fresh
//!   stream's opening reset heals the copy;
//! - a malformed frame resubscribes after 2s (in case the reset itself is
//!   what can't parse); a stream end retries after 2s;
//! - a `historyPending` preview never replaces a complete view.
//!
//! Text-only appends (no structural change, no optimistic overlay) emit
//! `TextChanged` without `cx.notify()` — Rust's `TranscriptTextChanged`, so
//! streaming tokens don't rebuild every observer. Everything else emits
//! `Changed` and notifies.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const zpui = @import("zpui");
const engine_mod = @import("zeron_engine");
const time = @import("time.zig");
const es = @import("engine_state.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Task = zpui.Task;
const Subscription = zpui.Subscription;
const protocol = engine_mod.protocol;
const Transcript = engine_mod.Transcript;
const SessionMessageEntry = protocol.SessionMessageEntry;
const EngineState = es.EngineState;
const Timestamp = time.Timestamp;

const log = std.log.scoped(.zeron_transcript);

/// How long an unadopted send reads as Working before flipping to the
/// explicit failed/retry state (`UNDELIVERED_GRACE_MS`).
pub const undelivered_grace_ms: i64 = 120_000;

/// Structure, status, echoes or context usage changed (notified).
pub const Changed = struct { reset: bool = false };
/// Only streaming text grew (not notified).
pub const TextChanged = struct {};
/// A desync forced a resubscribe (informational).
pub const Resubscribed = struct { reason: engine_mod.transcript.DesyncReason };

const Echo = struct {
    arena: *std.heap.ArenaAllocator,
    entry: SessionMessageEntry,

    fn deinit(e: Echo, gpa: Allocator) void {
        e.arena.deinit();
        gpa.destroy(e.arena);
    }
};

const PendingSend = struct {
    message_id: []u8,
    started: Timestamp,
};

pub const TranscriptStore = struct {
    gpa: Allocator,
    io: std.Io,
    engine: Entity(EngineState),
    engine_sub: Subscription,
    chat_id: []u8,
    transcript: Transcript,
    context_usage: ?protocol.ContextUsage = null,
    /// A `WatchDocMessages` reset landed (an empty transcript is otherwise
    /// indistinguishable from the pre-replay gap).
    replayed: bool = false,
    /// Bumps on every content change (rows, echoes, status).
    revision: u64 = 0,
    /// Whether the watch should be live (selected / visible).
    active: bool = true,
    watch: es.Watch = .{},
    retry_task: Task(void) = .none,
    echoes: std.ArrayList(Echo) = .empty,
    pending_send: ?PendingSend = null,
    /// Resubscribes caused by desyncs (diagnostics/tests).
    desyncs: u32 = 0,
    now_override: ?Timestamp = null,

    pub const Events = .{ Changed, TextChanged, Resubscribed };

    pub fn init(engine: Entity(EngineState), chat_id: []const u8, cx: *Context(TranscriptStore)) !TranscriptStore {
        const gpa = cx.gpa();
        var self: TranscriptStore = .{
            .gpa = gpa,
            .io = engine.read(cx).io,
            .engine = engine.retain(cx),
            .engine_sub = undefined,
            .chat_id = try gpa.dupe(u8, chat_id),
            .transcript = .init(gpa),
        };
        errdefer {
            gpa.free(self.chat_id);
            self.engine.release(cx);
        }
        self.engine_sub = try cx.subscribe(engine, onEngineEvent);
        self.open(cx);
        return self;
    }

    pub fn deinit(self: *TranscriptStore, app: *App) void {
        self.engine_sub.deinit();
        self.retry_task.cancel();
        self.watch.close();
        self.transcript.deinit();
        for (self.echoes.items) |e| e.deinit(self.gpa);
        self.echoes.deinit(self.gpa);
        if (self.pending_send) |p| self.gpa.free(p.message_id);
        self.gpa.free(self.chat_id);
        self.engine.release(app);
    }

    fn now(self: *const TranscriptStore) Timestamp {
        return self.now_override orelse Timestamp.now(self.io);
    }

    // ---- queries --------------------------------------------------------------------

    pub fn len(self: *const TranscriptStore) usize {
        return self.transcript.len();
    }

    pub fn entry(self: *const TranscriptStore, i: usize) *const SessionMessageEntry {
        return self.transcript.entry(i);
    }

    pub fn findEntry(self: *const TranscriptStore, id: []const u8) ?*const SessionMessageEntry {
        for (self.transcript.rows.items) |*r| if (std.mem.eql(u8, r.entry.id, id)) return &r.entry;
        return null;
    }

    /// Unconfirmed optimistic echoes, in send order.
    pub fn pendingEchoes(self: *const TranscriptStore) []const Echo {
        return self.echoes.items;
    }

    /// A send is in flight (and still inside the grace window).
    pub fn sendPending(self: *const TranscriptStore, n: Timestamp) bool {
        const p = self.pending_send orelse return false;
        return n.millisSince(p.started) <= undelivered_grace_ms;
    }

    /// A send went unadopted past the grace window: explicit failed state.
    pub fn sendUndelivered(self: *const TranscriptStore, n: Timestamp) bool {
        const p = self.pending_send orelse return false;
        return n.millisSince(p.started) > undelivered_grace_ms;
    }

    // ---- activity ---------------------------------------------------------------------

    /// Open or close the live watch (a cached, unselected transcript keeps its
    /// rows but holds no engine-side subscription).
    pub fn setActive(self: *TranscriptStore, active: bool, cx: *Context(TranscriptStore)) void {
        if (self.active == active) return;
        self.active = active;
        if (active) self.open(cx) else {
            self.retry_task.cancel();
            self.watch.close();
        }
    }

    fn onEngineEvent(self: *TranscriptStore, _: Entity(EngineState), ev: *const es.EngineEvent, cx: *Context(TranscriptStore)) void {
        switch (ev.*) {
            .connected => self.open(cx),
            .disconnected => {
                self.retry_task.cancel();
                self.watch.close();
            },
            .wake => self.drain(cx),
        }
    }

    fn open(self: *TranscriptStore, cx: *Context(TranscriptStore)) void {
        if (!self.active) return;
        const conn = self.engine.read(cx).conn orelse return;
        self.retry_task.cancel();
        self.watch.open(conn, .WatchDocMessages, protocol.params.WatchDocMessages{
            .chatId = self.chat_id,
            .openingTail = true,
        }) catch |err| {
            log.warn("transcript watch for {s} failed: {t}; retrying", .{ self.chat_id, err });
            self.scheduleRetry(cx);
        };
    }

    /// Resubscribe now (desync) or after the retry delay.
    fn resubscribe(self: *TranscriptStore, delayed: bool, cx: *Context(TranscriptStore)) void {
        self.watch.close();
        if (delayed) self.scheduleRetry(cx) else self.open(cx);
    }

    fn scheduleRetry(self: *TranscriptStore, cx: *Context(TranscriptStore)) void {
        if (self.retry_task.header != null) return;
        self.retry_task = cx.timer(es.retry_delay_ns, onRetry) catch return;
    }

    fn onRetry(self: *TranscriptStore, cx: *Context(TranscriptStore)) void {
        self.retry_task.detach();
        if (!self.watch.isOpen()) self.open(cx);
    }

    fn drain(self: *TranscriptStore, cx: *Context(TranscriptStore)) void {
        if (!self.watch.isOpen()) return;
        var changed = false;
        var structural = false;
        var reset = false;
        while (self.watch.next()) |payload| {
            const history_pending = if (payload.value == .object)
                (if (payload.value.object.get("historyPending")) |v| v == .bool and v.bool else false)
            else
                false;
            const update = engine_mod.decode(protocol.TranscriptUpdate, payload) catch |err| {
                // Schema skew: a skipped frame is a silently stale copy.
                log.warn("malformed transcript frame for {s} ({t}); resubscribing", .{ self.chat_id, err });
                self.resubscribe(true, cx);
                break;
            };
            defer update.deinit();
            // The opening tail is provisional: never replace a complete view.
            if (history_pending and self.replayed) continue;
            const frame = update.value.frame;
            const text_only = switch (frame) {
                .delta => |d| d.upsert.len == 0 and d.remove.len == 0 and d.append.len > 0,
                .reset => false,
            };
            self.transcript.applyUpdate(update.value) catch |err| switch (err) {
                error.Desync => {
                    const why = self.transcript.last_desync.?;
                    log.warn("transcript {s} desync ({t}: have {d}, expected {d}); resubscribing", .{
                        self.chat_id, why.reason, why.have, why.expected,
                    });
                    self.desyncs += 1;
                    cx.emit(Resubscribed{ .reason = why.reason });
                    self.resubscribe(false, cx);
                    changed = true;
                    structural = true;
                    break;
                },
                error.OutOfMemory => {
                    self.resubscribe(true, cx);
                    break;
                },
            };
            // Rust replaces the context snapshot on every update (null included).
            if (!std.meta.eql(self.context_usage, update.value.contextUsage)) {
                self.context_usage = update.value.contextUsage;
                structural = true;
            }
            self.transcript.context_usage = self.context_usage;
            if (frame == .reset) {
                reset = true;
                self.replayed = !history_pending;
            }
            changed = true;
            if (!text_only) structural = true;
        }
        if (self.watch.isOpen()) switch (self.watch.end(null)) {
            .open => {},
            .closed => self.watch.close(), // engine reconnect reopens
            .unknown_method, .done, .remote => {
                log.debug("transcript stream for {s} ended; resubscribing", .{self.chat_id});
                self.resubscribe(true, cx);
            },
        };
        if (!changed) return;
        self.revision +%= 1;
        // Doc frames supersede optimistic echoes carrying the same id.
        if (self.dropAdoptedEchoes()) structural = true;
        if (self.ackPendingSend()) structural = true;
        if (structural or self.echoes.items.len > 0 or self.pending_send != null) {
            cx.emit(Changed{ .reset = reset });
            cx.notify();
        } else {
            cx.emit(TextChanged{});
        }
    }

    fn dropAdoptedEchoes(self: *TranscriptStore) bool {
        var dropped = false;
        var i: usize = 0;
        while (i < self.echoes.items.len) {
            if (self.findEntry(self.echoes.items[i].entry.id) != null) {
                self.echoes.orderedRemove(i).deinit(self.gpa);
                dropped = true;
            } else i += 1;
        }
        return dropped;
    }

    fn ackPendingSend(self: *TranscriptStore) bool {
        const p = self.pending_send orelse return false;
        if (self.findEntry(p.message_id) == null) return false;
        self.gpa.free(p.message_id);
        self.pending_send = null;
        return true;
    }

    // ---- optimistic overlay -------------------------------------------------------------

    /// Show `e` until the doc frame carrying the same id arrives (deep-copied).
    pub fn pushEcho(self: *TranscriptStore, e: SessionMessageEntry, cx: *Context(TranscriptStore)) !void {
        const arena = try self.gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(self.gpa);
        errdefer {
            arena.deinit();
            self.gpa.destroy(arena);
        }
        const a = arena.allocator();
        const text = try json.Stringify.valueAlloc(a, e, .{ .emit_null_optional_fields = false });
        const copy = try json.parseFromSliceLeaky(SessionMessageEntry, a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        try self.echoes.append(self.gpa, .{ .arena = arena, .entry = copy });
        self.revision +%= 1;
        cx.emit(Changed{});
        cx.notify();
    }

    pub fn removeEcho(self: *TranscriptStore, message_id: []const u8, cx: *Context(TranscriptStore)) void {
        for (self.echoes.items, 0..) |e, i| if (std.mem.eql(u8, e.entry.id, message_id)) {
            self.echoes.orderedRemove(i).deinit(self.gpa);
            self.revision +%= 1;
            cx.emit(Changed{});
            cx.notify();
            return;
        };
    }

    /// A queued doc command the host hasn't executed yet: reads as Working.
    pub fn beginPendingSend(self: *TranscriptStore, message_id: []const u8, cx: *Context(TranscriptStore)) !void {
        const id = try self.gpa.dupe(u8, message_id);
        if (self.pending_send) |p| self.gpa.free(p.message_id);
        self.pending_send = .{ .message_id = id, .started = self.now() };
        _ = self.ackPendingSend();
        cx.emit(Changed{});
        cx.notify();
    }

    /// `retry_pending_send`: the user asked for another delivery attempt —
    /// restart the grace window so the trailer reads as Sending again.
    pub fn retryPendingSend(self: *TranscriptStore, cx: *Context(TranscriptStore)) void {
        if (self.pending_send) |*p| p.started = self.now();
        self.revision +%= 1;
        cx.emit(Changed{});
        cx.notify();
    }

    pub fn endPendingSend(self: *TranscriptStore, message_id: []const u8, cx: *Context(TranscriptStore)) void {
        const p = self.pending_send orelse return;
        if (!std.mem.eql(u8, p.message_id, message_id)) return;
        self.gpa.free(p.message_id);
        self.pending_send = null;
        cx.emit(Changed{});
        cx.notify();
    }

    /// A queued message (by id) supersedes its echo and the pending send.
    pub fn ackQueued(self: *TranscriptStore, ids: []const []const u8, cx: *Context(TranscriptStore)) void {
        var changed = false;
        var i: usize = 0;
        while (i < self.echoes.items.len) {
            const id = self.echoes.items[i].entry.id;
            const queued = for (ids) |q| {
                if (std.mem.eql(u8, q, id)) break true;
            } else false;
            if (queued) {
                self.echoes.orderedRemove(i).deinit(self.gpa);
                changed = true;
            } else i += 1;
        }
        if (self.pending_send) |p| for (ids) |q| if (std.mem.eql(u8, q, p.message_id)) {
            self.gpa.free(p.message_id);
            self.pending_send = null;
            changed = true;
            break;
        };
        if (changed) {
            self.revision +%= 1;
            cx.emit(Changed{});
            cx.notify();
        }
    }

    // ---- commands -------------------------------------------------------------------

    /// `QueueCommand{chatId, command}` (run / steer / interrupt /
    /// respondInput through the durable command ledger). The reply's
    /// `commandId` is delivered to `f` when given.
    pub fn queueCommand(self: *TranscriptStore, command: protocol.SessionCommandPayload, cx: *Context(TranscriptStore)) !void {
        try EngineState.request(self.engine, cx, TranscriptStore, cx.entityId(), .QueueCommand, protocol.params.QueueCommand{
            .chatId = self.chat_id,
            .command = command,
        }, onQueueCommandReply);
    }

    /// `QueueCommand` escorted by queued-attachment transfers (the uploads the
    /// local engine delivers to the host before the command runs).
    pub fn queueCommandWithTransfers(self: *TranscriptStore, command: protocol.SessionCommandPayload, transfers: []const protocol.AttachmentTransfer, cx: *Context(TranscriptStore)) !void {
        try EngineState.request(self.engine, cx, TranscriptStore, cx.entityId(), .QueueCommand, protocol.params.QueueCommand{
            .chatId = self.chat_id,
            .command = command,
            .transfers = transfers,
        }, onQueueCommandReply);
    }

    fn onQueueCommandReply(self: *TranscriptStore, result: es.CallResult, cx: *Context(TranscriptStore)) void {
        switch (result) {
            .ok => {},
            .err => |e| {
                log.warn("QueueCommand for {s} failed: {t} {s}", .{ self.chat_id, e.kind, e.message });
                if (self.pending_send) |p| {
                    self.gpa.free(p.message_id);
                    self.pending_send = null;
                    cx.emit(Changed{});
                    cx.notify();
                }
            },
        }
    }
};
