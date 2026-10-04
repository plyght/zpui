//! Executors on top of `platform.Dispatcher` (gpui `executor.rs`, minus futures).
//!
//! ## Async model
//! gpui writes async work as `async` closures that re-enter the app with `update`. Zig 0.17
//! has no stackless coroutines; `std.Io.async`/`concurrent` return a `Future` that can only be
//! *awaited* (blocking the caller) or canceled — there is no "notify me on the main thread
//! when done" hook, and the UI thread must never block. So zpui uses **jobs**: a plain struct
//! value with up to two phases:
//!
//! ```zig
//! const Fetch = struct {
//!     url: []const u8,
//!     /// Optional. Runs on a background worker. May take a `CancelToken` second param.
//!     pub fn run(self: *Fetch) Result { ... }        // may freely use std.Io inside
//!     /// Optional. Runs on the main thread with run's result, unless the task was canceled.
//!     pub fn finish(self: *Fetch, result: Result) void { ... }
//!     /// Optional. Called if a produced result is dropped because of cancellation.
//!     pub fn discard(self: *Fetch, result: Result) void { ... }
//!     /// Optional. Called when the task memory is freed (any thread).
//!     pub fn deinit(self: *Fetch) void { ... }
//! };
//! var task = try executor.background().spawn(Fetch{ .url = url });
//! ```
//!
//! Multi-step flows are chains: `finish` spawns the next job. `Context(T).spawn` (context.zig)
//! wraps a job so `finish` re-enters the app as `fn(*T, Result, *Context(T))` through a weak
//! entity handle, which is the Zig spelling of `cx.spawn(async move |this, cx| ...)`.
//!
//! `Task(R)` replaces gpui's drop-to-cancel `Task<R>`: call `cancel()` or `detach()` exactly
//! once. Tasks may carry an owner entity id; `Executor.cancelOwnedBy` (called by the App when
//! the entity is released) cancels them so their `finish` never runs on a dead entity.
//!
//! Allocator used for tasks must be thread-safe (task memory may be freed on a worker).

const std = @import("std");
const platform = @import("../platform/platform.zig");
const Allocator = std.mem.Allocator;
const Dispatcher = platform.Dispatcher;
const Runnable = platform.Runnable;
pub const Priority = platform.Priority;

pub const TaskState = enum(u8) {
    /// Scheduled, not started.
    pending,
    /// Background phase running.
    running,
    /// Background phase produced a result; main-thread phase not yet delivered.
    ran,
    /// `finish` delivered (or no finish phase) — terminal.
    completed,
    /// Canceled before completion — terminal.
    canceled,
};

/// Lets a background `run` poll for cancellation.
pub const CancelToken = struct {
    state: *const std.atomic.Value(TaskState),

    pub fn isCanceled(t: CancelToken) bool {
        return t.state.load(.acquire) == .canceled;
    }
};

/// Shared, type-erased task header. Owned jointly (atomic refcount) by the `Task` handle and
/// the in-flight dispatcher runnable.
pub const Header = struct {
    state: std.atomic.Value(TaskState) = .init(.pending),
    refs: std.atomic.Value(u32) = .init(2),
    /// Main-thread bookkeeping (live list in `Executor`).
    node: std.DoublyLinkedList.Node = .{},
    linked: bool = false,
    owner: u64 = 0,
    executor: *Executor,
    /// Copied so worker threads never touch `executor` (which may be gone after App.deinit).
    dispatcher: Dispatcher,
    vtable: *const VTable,

    pub const VTable = struct {
        finish: *const fn (h: *Header) void,
        discard: *const fn (h: *Header) void,
        destroy: *const fn (h: *Header) void,
        result: *const fn (h: *Header) *anyopaque,
    };

    fn release(h: *Header) void {
        if (h.refs.fetchSub(1, .acq_rel) == 1) h.vtable.destroy(h);
    }

    /// Try to move to canceled. Returns the prior state.
    fn cancel(h: *Header) TaskState {
        var cur = h.state.load(.acquire);
        while (true) switch (cur) {
            .completed, .canceled => return cur,
            else => cur = h.state.cmpxchgWeak(cur, .canceled, .acq_rel, .acquire) orelse return cur,
        };
    }
};

/// Handle to a spawned job. Not copyable in spirit: call `cancel()` or `detach()` once.
pub fn Task(comptime R: type) type {
    return struct {
        const Self = @This();
        header: ?*Header = null,

        /// A handle that refers to nothing (field default).
        pub const none: Self = .{};

        /// Prevent `finish` from running (if it has not yet) and release the handle.
        /// Main thread only. Idempotent.
        pub fn cancel(self: *Self) void {
            const h = self.header orelse return;
            self.header = null;
            const prev = h.cancel();
            if (prev == .ran) h.vtable.discard(h);
            h.release();
        }

        /// Let the job run to completion without holding a handle.
        pub fn detach(self: *Self) void {
            const h = self.header orelse return;
            self.header = null;
            h.release();
        }

        pub fn state(self: Self) TaskState {
            const h = self.header orelse return .canceled;
            return h.state.load(.acquire);
        }

        /// True once the background phase finished (or the task completed).
        pub fn isReady(self: Self) bool {
            return switch (self.state()) {
                .ran, .completed => true,
                else => false,
            };
        }

        /// The background result, once `isReady()`.
        pub fn result(self: Self) ?*R {
            if (!self.isReady()) return null;
            const h = self.header.?;
            return @ptrCast(@alignCast(h.vtable.result(h)));
        }
    };
}

/// Shared scheduler state: dispatcher + live-task registry (main thread).
pub const Executor = struct {
    gpa: Allocator,
    dispatcher: Dispatcher,
    live: std.DoublyLinkedList = .{},
    live_count: usize = 0,

    pub fn init(gpa: Allocator, dispatcher: Dispatcher) Executor {
        return .{ .gpa = gpa, .dispatcher = dispatcher };
    }

    /// Cancel every live task (their runnables still free themselves later).
    pub fn deinit(self: *Executor) void {
        self.cancelWhere(null);
    }

    pub fn foreground(self: *Executor) ForegroundExecutor {
        return .{ .exec = self };
    }

    pub fn background(self: *Executor) BackgroundExecutor {
        return .{ .exec = self };
    }

    /// Cancel all live tasks owned by `owner` (an EntityId's bits). Main thread.
    pub fn cancelOwnedBy(self: *Executor, owner: u64) void {
        if (owner == 0) return;
        self.cancelWhere(owner);
    }

    fn cancelWhere(self: *Executor, owner: ?u64) void {
        var it = self.live.first;
        while (it) |node| {
            it = node.next;
            const h: *Header = @fieldParentPtr("node", node);
            if (owner) |o| if (h.owner != o) continue;
            if (h.cancel() == .ran) h.vtable.discard(h);
            self.unlink(h);
        }
    }

    pub fn now(self: *Executor) u64 {
        return self.dispatcher.now();
    }

    fn link(self: *Executor, h: *Header) void {
        self.live.append(&h.node);
        self.live_count += 1;
        h.linked = true;
    }

    fn unlink(self: *Executor, h: *Header) void {
        if (!h.linked) return;
        self.live.remove(&h.node);
        self.live_count -= 1;
        h.linked = false;
    }

    pub const SpawnMode = union(enum) {
        foreground,
        background: Priority,
        after_ns: u64,
    };

    /// Spawn `job` (see the module doc for the job protocol). `owner` is an EntityId's bits
    /// or 0. Must be called on the main thread.
    pub fn spawn(self: *Executor, job: anytype, mode: SpawnMode, owner: u64) Allocator.Error!Task(JobResult(@TypeOf(job))) {
        const J = @TypeOf(job);
        const Impl = TaskImpl(J);
        const impl = try self.gpa.create(Impl);
        impl.* = .{
            .header = .{ .executor = self, .dispatcher = self.dispatcher, .vtable = &Impl.vtable, .owner = owner },
            .job = job,
            .result = undefined,
            .gpa = self.gpa,
        };
        self.link(&impl.header);
        const runnable: Runnable = .{ .ctx = &impl.header, .run = Impl.runnableEntry, .drop = Impl.runnableDrop };
        switch (mode) {
            .foreground => {
                impl.phase = .main;
                self.dispatcher.dispatchOnMainThread(runnable, .medium);
            },
            .background => |p| {
                impl.phase = if (Impl.has_run) .background else .main;
                if (Impl.has_run)
                    self.dispatcher.dispatch(runnable, p)
                else
                    self.dispatcher.dispatchOnMainThread(runnable, p);
            },
            .after_ns => |ns| {
                // Timers run their background phase (if any) on the main thread on expiry.
                impl.phase = .main;
                self.dispatcher.dispatchAfter(ns, runnable);
            },
        }
        return .{ .header = &impl.header };
    }
};

/// gpui `ForegroundExecutor`: runs jobs on the main thread.
pub const ForegroundExecutor = struct {
    exec: *Executor,

    /// Run `job.finish` on the main thread on a later loop iteration.
    pub fn spawn(self: ForegroundExecutor, job: anytype) Allocator.Error!Task(JobResult(@TypeOf(job))) {
        return self.exec.spawn(job, .foreground, 0);
    }

    /// Run `job.finish` on the main thread after `delay_ns`.
    pub fn timer(self: ForegroundExecutor, delay_ns: u64, job: anytype) Allocator.Error!Task(JobResult(@TypeOf(job))) {
        return self.exec.spawn(job, .{ .after_ns = delay_ns }, 0);
    }
};

/// gpui `BackgroundExecutor`: runs `job.run` on a worker, then `job.finish` on the main thread.
pub const BackgroundExecutor = struct {
    exec: *Executor,

    pub fn spawn(self: BackgroundExecutor, job: anytype) Allocator.Error!Task(JobResult(@TypeOf(job))) {
        return self.exec.spawn(job, .{ .background = .medium }, 0);
    }

    pub fn spawnWithPriority(self: BackgroundExecutor, priority: Priority, job: anytype) Allocator.Error!Task(JobResult(@TypeOf(job))) {
        return self.exec.spawn(job, .{ .background = priority }, 0);
    }

    /// A task that becomes ready after `delay_ns` (gpui `BackgroundExecutor::timer`).
    pub fn timer(self: BackgroundExecutor, delay_ns: u64) Allocator.Error!Task(void) {
        return self.exec.spawn(Noop{}, .{ .after_ns = delay_ns }, 0);
    }
};

const Noop = struct {};

/// Result type of a job: the return type of `run`, or void.
pub fn JobResult(comptime J: type) type {
    if (hasFn(J, "run")) return @typeInfo(@TypeOf(J.run)).@"fn".return_type.?;
    return void;
}

/// True if `J` declares a function named `name` (a decl set to `{}` does not count, which
/// lets wrappers declare phases conditionally: `pub const run = if (cond) runImpl else {};`).
pub fn hasFn(comptime J: type, comptime name: []const u8) bool {
    if (!@hasDecl(J, name)) return false;
    return @typeInfo(@TypeOf(@field(J, name))) == .@"fn";
}

fn TaskImpl(comptime J: type) type {
    const R = JobResult(J);
    return struct {
        const Self = @This();
        const has_run = hasFn(J, "run");
        const run_takes_token = has_run and @typeInfo(@TypeOf(J.run)).@"fn".param_types.len == 2;
        const has_finish = hasFn(J, "finish");
        const finish_takes_result = has_finish and @typeInfo(@TypeOf(J.finish)).@"fn".param_types.len == 2;

        header: Header,
        job: J,
        result: R,
        gpa: Allocator,
        phase: enum { background, main } = .main,

        const vtable: Header.VTable = .{
            .finish = finishMain,
            .discard = discard,
            .destroy = destroy,
            .result = resultPtr,
        };

        fn fromHeader(h: *Header) *Self {
            // Self may be more aligned than Header (over-aligned job fields).
            return @alignCast(@fieldParentPtr("header", h));
        }

        fn resultPtr(h: *Header) *anyopaque {
            return @ptrCast(&fromHeader(h).result);
        }

        fn runnableEntry(ctx: *anyopaque) void {
            const h: *Header = @ptrCast(@alignCast(ctx));
            const self = fromHeader(h);
            switch (self.phase) {
                .background => {
                    runBackground(h);
                    // Hop to the main thread for unlinking + finish (also when canceled).
                    self.phase = .main;
                    h.dispatcher.dispatchOnMainThread(.{ .ctx = h, .run = runnableEntry, .drop = runnableDrop }, .medium);
                },
                .main => {
                    // Timers / foreground jobs with a `run` phase execute it inline.
                    if (has_run and h.state.load(.acquire) == .pending) runBackground(h);
                    finishMain(h);
                    h.release();
                },
            }
        }

        fn runnableDrop(ctx: *anyopaque) void {
            const h: *Header = @ptrCast(@alignCast(ctx));
            h.release();
        }

        fn runBackground(h: *Header) void {
            const self = fromHeader(h);
            if (comptime !has_run) return;
            if (h.state.cmpxchgStrong(.pending, .running, .acq_rel, .acquire) != null) return;
            self.result = if (run_takes_token) self.job.run(.{ .state = &h.state }) else self.job.run();
            if (h.state.cmpxchgStrong(.running, .ran, .acq_rel, .acquire) != null) {
                // Canceled while running: the result will never be delivered.
                if (comptime hasFn(J, "discard")) self.job.discard(self.result);
            }
        }

        fn finishMain(h: *Header) void {
            const self = fromHeader(h);
            h.executor.unlink(h);
            const from: TaskState = if (has_run) .ran else .pending;
            if (h.state.cmpxchgStrong(from, .completed, .acq_rel, .acquire) != null) return;
            if (comptime has_finish) {
                if (finish_takes_result) self.job.finish(self.result) else self.job.finish();
            }
        }

        fn discard(h: *Header) void {
            const self = fromHeader(h);
            if (comptime hasFn(J, "discard")) self.job.discard(self.result);
        }

        fn destroy(h: *Header) void {
            const self = fromHeader(h);
            if (comptime hasFn(J, "deinit")) self.job.deinit();
            self.gpa.destroy(self);
        }
    };
}

// ---------------------------------------------------------------------------------------

/// Minimal real-thread dispatcher for testing the cross-thread path: background runnables run
/// on a spawned thread; main-thread runnables land in a one-slot mailbox drained by the test.
const ThreadTestDispatcher = struct {
    worker: ?std.Thread = null,
    mailbox: std.atomic.Value(?*anyopaque) = .init(null),
    mailbox_run: ?*const fn (*anyopaque) void = null,

    fn dispatcher(self: *ThreadTestDispatcher) Dispatcher {
        return .{ .ptr = self, .vtable = &.{
            .isMainThread = isMain,
            .dispatch = dispatch,
            .dispatchOnMainThread = onMain,
            .dispatchAfter = after,
            .now = now,
        } };
    }
    fn cast(p: *anyopaque) *ThreadTestDispatcher {
        return @ptrCast(@alignCast(p));
    }
    fn isMain(_: *anyopaque) bool {
        return false;
    }
    fn dispatch(p: *anyopaque, r: Runnable, _: Priority) void {
        cast(p).worker = std.Thread.spawn(.{}, struct {
            fn f(run: Runnable) void {
                run.run(run.ctx);
            }
        }.f, .{r}) catch @panic("spawn failed");
    }
    fn onMain(p: *anyopaque, r: Runnable, _: Priority) void {
        const self = cast(p);
        self.mailbox_run = r.run;
        self.mailbox.store(r.ctx, .release);
    }
    fn after(_: *anyopaque, _: u64, _: Runnable) void {
        unreachable;
    }
    fn now(_: *anyopaque) u64 {
        return 0;
    }
};

test "background phase runs on another thread, finish on the caller" {
    var d: ThreadTestDispatcher = .{};
    var exec = Executor.init(std.testing.allocator, d.dispatcher());
    defer exec.deinit();

    const Job = struct {
        main_thread: std.Thread.Id,
        ran_on: *std.Thread.Id,
        finished: *bool,
        pub fn run(self: *@This()) u32 {
            self.ran_on.* = std.Thread.getCurrentId();
            return 7;
        }
        pub fn finish(self: *@This(), r: u32) void {
            std.debug.assert(r == 7);
            std.debug.assert(std.Thread.getCurrentId() == self.main_thread);
            self.finished.* = true;
        }
    };
    var ran_on: std.Thread.Id = undefined;
    var finished = false;
    var task = try exec.background().spawn(Job{ .main_thread = std.Thread.getCurrentId(), .ran_on = &ran_on, .finished = &finished });
    d.worker.?.join();
    try std.testing.expect(ran_on != std.Thread.getCurrentId());
    try std.testing.expect(task.isReady());
    const ctx = d.mailbox.load(.acquire).?;
    d.mailbox_run.?(ctx);
    try std.testing.expect(finished);
    try std.testing.expectEqual(@as(u32, 7), task.result().?.*);
    task.detach();
    try std.testing.expectEqual(@as(usize, 0), exec.live_count);
}

test "jobs with over-aligned fields" {
    const Job = struct {
        v: @Vector(4, u32) align(32) = @splat(7),
        out: *u32,
        pub fn run(self: *@This()) u32 {
            return self.v[0];
        }
        pub fn finish(self: *@This(), r: u32) void {
            self.out.* = r;
        }
    };
    const tp = try @import("test_platform.zig").TestPlatform.create(std.testing.allocator);
    defer tp.destroy();
    var ex = Executor.init(std.testing.allocator, tp.platform().dispatcher());
    defer ex.deinit();
    var out: u32 = 0;
    var t = try ex.background().spawn(Job{ .out = &out });
    t.detach();
    tp.runUntilParked();
    try std.testing.expectEqual(@as(u32, 7), out);
}
