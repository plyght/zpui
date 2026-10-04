//! A chat's pending-message queue — zeron `spawn_queue_watch` /
//! `AppState::apply_queue` plus the queue mutations
//! (`QueueMessage`, `UpdateQueuedMessage`, `MoveQueuedMessage`,
//! `RemoveQueuedMessage`, `SendQueuedMessageNow`, `SteerQueuedMessageNow`).
//!
//! Whole-list frames from `WatchQueue{chatId}` (only on engines with the
//! `message-queue-v1` capability), retried like the transcript watch. A
//! linked `TranscriptStore` drops echoes / the pending-send overlay for ids
//! that show up as queue rows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const zpui = @import("zpui");
const engine_mod = @import("zeron_engine");
const eql = @import("eql.zig");
const es = @import("engine_state.zig");
const TranscriptStore = @import("transcript_store.zig").TranscriptStore;

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const Task = zpui.Task;
const Subscription = zpui.Subscription;
const protocol = engine_mod.protocol;
const EngineState = es.EngineState;

const log = std.log.scoped(.zeron_queue);

pub const QueueChanged = struct {};

pub const QueueStore = struct {
    gpa: Allocator,
    engine: Entity(EngineState),
    engine_sub: Subscription,
    chat_id: []u8,
    frame: ?json.Parsed(protocol.QueueSnapshot) = null,
    watch: es.Watch = .{},
    retry_task: Task(void) = .none,
    transcript: ?Entity(TranscriptStore) = null,

    pub const Events = .{QueueChanged};

    pub fn init(engine: Entity(EngineState), chat_id: []const u8, transcript: ?Entity(TranscriptStore), cx: *Context(QueueStore)) !QueueStore {
        const gpa = cx.gpa();
        var self: QueueStore = .{
            .gpa = gpa,
            .engine = engine.retain(cx),
            .engine_sub = undefined,
            .chat_id = try gpa.dupe(u8, chat_id),
            .transcript = if (transcript) |t| t.retain(cx) else null,
        };
        self.engine_sub = try cx.subscribe(engine, onEngineEvent);
        self.open(cx);
        return self;
    }

    pub fn deinit(self: *QueueStore, app: *App) void {
        self.engine_sub.deinit();
        self.retry_task.cancel();
        self.watch.close();
        if (self.frame) |f| f.deinit();
        if (self.transcript) |t| t.release(app);
        self.gpa.free(self.chat_id);
        self.engine.release(app);
    }

    /// The queue in send order.
    pub fn items(self: *const QueueStore) []const protocol.QueuedMessage {
        return if (self.frame) |f| f.value.items else &.{};
    }

    fn onEngineEvent(self: *QueueStore, _: Entity(EngineState), ev: *const es.EngineEvent, cx: *Context(QueueStore)) void {
        switch (ev.*) {
            .connected => self.open(cx),
            .disconnected => {
                self.retry_task.cancel();
                self.watch.close();
            },
            .wake => self.drain(cx),
        }
    }

    fn open(self: *QueueStore, cx: *Context(QueueStore)) void {
        const engine = self.engine.read(cx);
        const conn = engine.conn orelse return;
        if (!engine.supports(protocol.capabilities.message_queue_v1)) return;
        self.watch.open(conn, .WatchQueue, protocol.params.ChatId{ .chatId = self.chat_id }) catch |err| {
            log.debug("queue watch for {s} failed: {t}; retrying", .{ self.chat_id, err });
            self.scheduleRetry(cx);
        };
    }

    /// Replace the subscription; its opening frame repairs the local list
    /// after a failed optimistic mutation (`refresh_selected_queue`).
    pub fn refresh(self: *QueueStore, cx: *Context(QueueStore)) void {
        self.watch.close();
        self.open(cx);
    }

    fn scheduleRetry(self: *QueueStore, cx: *Context(QueueStore)) void {
        if (self.retry_task.header != null) return;
        self.retry_task = cx.timer(es.retry_delay_ns, onRetry) catch return;
    }

    fn onRetry(self: *QueueStore, cx: *Context(QueueStore)) void {
        self.retry_task.detach();
        if (!self.watch.isOpen()) self.open(cx);
    }

    fn drain(self: *QueueStore, cx: *Context(QueueStore)) void {
        if (es.latest(protocol.QueueSnapshot, &self.watch, "WatchQueue")) |frame| self.applyQueue(frame, cx);
        if (self.watch.isOpen()) switch (self.watch.end(null)) {
            .open => {},
            .closed => self.watch.close(),
            .unknown_method => {
                self.watch.unsupported = true;
                self.watch.close();
            },
            .done, .remote => {
                self.watch.close();
                self.scheduleRetry(cx);
            },
        };
    }

    /// Takes ownership of `frame`.
    pub fn applyQueue(self: *QueueStore, frame: json.Parsed(protocol.QueueSnapshot), cx: *Context(QueueStore)) void {
        const changed = if (self.frame) |old| !eql.deepEql(old.value.items, frame.value.items) else true;
        if (self.frame) |old| old.deinit();
        self.frame = frame;
        if (self.transcript) |t| {
            var ids: std.ArrayList([]const u8) = .empty;
            defer ids.deinit(self.gpa);
            for (frame.value.items) |q| ids.append(self.gpa, q.id) catch {};
            t.update(cx, TranscriptStore.ackQueued, .{ids.items});
        }
        if (changed) {
            cx.emit(QueueChanged{});
            cx.notify();
        }
    }

    // ---- mutations ------------------------------------------------------------------

    pub fn queueMessage(self: *QueueStore, text: []const u8, attachments: []const []const u8, hold_for_turn_end: bool, cx: *Context(QueueStore)) !void {
        try EngineState.request(self.engine, cx, QueueStore, cx.entityId(), .QueueMessage, protocol.params.QueueMessage{
            .chatId = self.chat_id,
            .text = text,
            .attachments = attachments,
            .holdForTurnEnd = hold_for_turn_end,
        }, onMutationReply);
    }

    pub const QueuedMessageParams = struct {
        chatId: []const u8,
        id: []const u8,
        text: ?[]const u8 = null,
        toIndex: ?usize = null,
    };

    /// Empty text deletes the row (engine semantics).
    pub fn updateQueuedMessage(self: *QueueStore, id: []const u8, text: []const u8, cx: *Context(QueueStore)) !void {
        try self.mutation(.UpdateQueuedMessage, .{ .chatId = self.chat_id, .id = id, .text = text }, cx);
    }

    pub fn moveQueuedMessage(self: *QueueStore, id: []const u8, to_index: usize, cx: *Context(QueueStore)) !void {
        try self.mutation(.MoveQueuedMessage, .{ .chatId = self.chat_id, .id = id, .toIndex = to_index }, cx);
    }

    pub fn removeQueuedMessage(self: *QueueStore, id: []const u8, cx: *Context(QueueStore)) !void {
        try self.mutation(.RemoveQueuedMessage, .{ .chatId = self.chat_id, .id = id }, cx);
    }

    pub fn sendQueuedMessageNow(self: *QueueStore, id: []const u8, cx: *Context(QueueStore)) !void {
        try self.mutation(.SendQueuedMessageNow, .{ .chatId = self.chat_id, .id = id }, cx);
    }

    pub fn steerQueuedMessageNow(self: *QueueStore, id: []const u8, cx: *Context(QueueStore)) !void {
        try self.mutation(.SteerQueuedMessageNow, .{ .chatId = self.chat_id, .id = id }, cx);
    }

    fn mutation(self: *QueueStore, method: engine_mod.Method, params: QueuedMessageParams, cx: *Context(QueueStore)) !void {
        try EngineState.request(self.engine, cx, QueueStore, cx.entityId(), method, params, onMutationReply);
    }

    fn onMutationReply(self: *QueueStore, result: es.CallResult, cx: *Context(QueueStore)) void {
        switch (result) {
            .ok => {},
            .err => |e| {
                log.warn("queue mutation for {s} failed: {t} {s}", .{ self.chat_id, e.kind, e.message });
                self.refresh(cx);
            },
        }
    }
};
