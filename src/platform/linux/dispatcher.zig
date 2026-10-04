//! Linux `platform.Dispatcher` (gpui_linux `LinuxDispatcher`).
//!
//! * Background work: `N = cpu count` worker threads pull from a shared `PriorityQueues`.
//! * Main-thread work: pushed into a second `PriorityQueues` and the event loop is woken
//!   through its eventfd; `drainMain` runs on the loop thread.
//! * `dispatchAfter`: may be called from any thread, so requests are staged under the lock
//!   and moved into the event loop's timer heap (timerfd) on the next wake.
//!
//! Queue selection mirrors gpui's `PriorityQueueReceiver`: `realtime` is strict, the
//! others are picked by weighted lottery among non-empty queues (high 60, medium 30,
//! low 10) so low-priority work cannot starve; each queue is FIFO.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");
const event_loop = @import("event_loop.zig");

const Runnable = platform.Runnable;
const Priority = platform.Priority;

pub fn weight(p: Priority) u32 {
    return switch (p) {
        .realtime => 0,
        .high => 60,
        .medium => 30,
        .low => 10,
    };
}

/// Four FIFO queues with weighted selection. Not thread-safe; callers hold a lock.
pub const PriorityQueues = struct {
    queues: [4]std.Deque(Runnable) = .{ .empty, .empty, .empty, .empty },
    rng: std.Random.DefaultPrng = .init(0),

    pub fn deinit(q: *PriorityQueues, gpa: Allocator) void {
        for (&q.queues) |*d| d.deinit(gpa);
    }

    pub fn push(q: *PriorityQueues, gpa: Allocator, r: Runnable, p: Priority) Allocator.Error!void {
        try q.queues[@backingInt(p)].pushBack(gpa, r);
    }

    pub fn len(q: *const PriorityQueues) usize {
        var n: usize = 0;
        for (q.queues) |d| n += d.len;
        return n;
    }

    pub fn pop(q: *PriorityQueues) ?Runnable {
        if (q.queues[@backingInt(Priority.realtime)].popFront()) |r| return r;
        var mass: u32 = 0;
        for ([_]Priority{ .high, .medium, .low }) |p| {
            if (q.queues[@backingInt(p)].len > 0) mass += weight(p);
        }
        if (mass == 0) return null;
        var ticket = q.rng.random().uintLessThan(u32, mass);
        for ([_]Priority{ .high, .medium, .low }) |p| {
            const d = &q.queues[@backingInt(p)];
            if (d.len == 0) continue;
            if (ticket < weight(p)) return d.popFront();
            ticket -= weight(p);
        }
        unreachable;
    }

    /// Calls `drop` (if any) on every queued runnable.
    pub fn dropAll(q: *PriorityQueues) void {
        for (&q.queues) |*d| while (d.popFront()) |r| if (r.drop) |f| f(r.ctx);
    }
};

const PendingTimer = struct { deadline: u64, runnable: Runnable };

pub const LinuxDispatcher = struct {
    gpa: Allocator,
    io: Io,
    loop: *event_loop.EventLoop,
    main_thread: std.Thread.Id,

    mutex: Io.Mutex = .init,
    work_available: Io.Condition = .init,
    background: PriorityQueues = .{},
    main: PriorityQueues = .{},
    pending_timers: std.ArrayList(PendingTimer) = .empty,
    shutting_down: bool = false,
    workers: []std.Thread = &.{},

    /// Must be called on the main thread. `self` must not move afterwards (workers hold it).
    pub fn init(self: *LinuxDispatcher, gpa: Allocator, io: Io, loop: *event_loop.EventLoop, worker_count: ?usize) !void {
        self.* = .{ .gpa = gpa, .io = io, .loop = loop, .main_thread = std.Thread.getCurrentId() };
        const n = worker_count orelse @max(2, std.Thread.getCpuCount() catch 2);
        self.workers = try gpa.alloc(std.Thread, n);
        var spawned: usize = 0;
        errdefer {
            self.stopWorkers(spawned);
            gpa.free(self.workers);
        }
        while (spawned < n) : (spawned += 1) {
            self.workers[spawned] = try std.Thread.spawn(.{}, workerMain, .{self});
        }
        loop.on_wake = .{ .ctx = self, .func = onWake };
    }

    fn stopWorkers(self: *LinuxDispatcher, count: usize) void {
        self.mutex.lockUncancelable(self.io);
        self.shutting_down = true;
        self.work_available.broadcast(self.io);
        self.mutex.unlock(self.io);
        for (self.workers[0..count]) |t| t.join();
    }

    pub fn deinit(self: *LinuxDispatcher) void {
        self.stopWorkers(self.workers.len);
        self.gpa.free(self.workers);
        self.background.dropAll();
        self.main.dropAll();
        for (self.pending_timers.items) |t| if (t.runnable.drop) |f| f(t.runnable.ctx);
        // Delayed runnables already moved into the loop's timer heap.
        var i: usize = 0;
        while (i < self.loop.timers.heap.items.len) {
            const t = self.loop.timers.heap.items[i];
            if (t.handler.func != fireTimer) {
                i += 1;
                continue;
            }
            _ = self.loop.timers.heap.popIndex(i);
            const box: *TimerBox = @ptrCast(@alignCast(t.handler.ctx.?));
            if (box.runnable.drop) |f| f(box.runnable.ctx);
            self.gpa.destroy(box);
        }
        self.background.deinit(self.gpa);
        self.main.deinit(self.gpa);
        self.pending_timers.deinit(self.gpa);
        self.loop.on_wake = null;
    }

    fn workerMain(self: *LinuxDispatcher) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            const r = while (true) {
                if (self.shutting_down) {
                    self.mutex.unlock(self.io);
                    return;
                }
                if (self.background.pop()) |r| break r;
                self.work_available.waitUncancelable(self.io, &self.mutex);
            };
            self.mutex.unlock(self.io);
            r.run(r.ctx);
        }
    }

    /// Runs the main-thread runnables that were queued when this call started, plus moves
    /// staged `dispatchAfter` requests into the loop's timer heap. Main thread only.
    pub fn drainMain(self: *LinuxDispatcher) void {
        self.mutex.lockUncancelable(self.io);
        var budget = self.main.len();
        const timers = self.pending_timers.toOwnedSlice(self.gpa) catch &.{};
        self.mutex.unlock(self.io);

        for (timers) |t| {
            const box = self.gpa.create(TimerBox) catch {
                if (t.runnable.drop) |f| f(t.runnable.ctx);
                continue;
            };
            box.* = .{ .gpa = self.gpa, .runnable = t.runnable };
            _ = self.loop.addTimerAt(t.deadline, .{ .ctx = box, .func = fireTimer }) catch {
                self.gpa.destroy(box);
                if (t.runnable.drop) |f| f(t.runnable.ctx);
            };
        }
        self.gpa.free(timers);

        while (budget > 0) : (budget -= 1) {
            self.mutex.lockUncancelable(self.io);
            const r = self.main.pop();
            self.mutex.unlock(self.io);
            const runnable = r orelse break;
            runnable.run(runnable.ctx);
        }
        // Anything queued by the runnables themselves runs on the next iteration.
        self.mutex.lockUncancelable(self.io);
        const more = self.main.len() > 0;
        self.mutex.unlock(self.io);
        if (more) self.loop.wake();
    }

    const TimerBox = struct { gpa: Allocator, runnable: Runnable };

    fn fireTimer(ctx: ?*anyopaque, _: event_loop.TimerId) void {
        const box: *TimerBox = @ptrCast(@alignCast(ctx.?));
        const r = box.runnable;
        box.gpa.destroy(box);
        r.run(r.ctx);
    }

    fn onWake(ctx: ?*anyopaque, _: void) void {
        const self: *LinuxDispatcher = @ptrCast(@alignCast(ctx.?));
        self.drainMain();
    }

    pub fn dispatcher(self: *LinuxDispatcher) platform.Dispatcher {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: platform.Dispatcher.VTable = .{
        .isMainThread = isMainThread,
        .dispatch = dispatch,
        .dispatchOnMainThread = dispatchOnMainThread,
        .dispatchAfter = dispatchAfter,
        .now = now,
    };

    fn cast(ptr: *anyopaque) *LinuxDispatcher {
        return @ptrCast(@alignCast(ptr));
    }

    fn isMainThread(ptr: *anyopaque) bool {
        return std.Thread.getCurrentId() == cast(ptr).main_thread;
    }

    fn dispatch(ptr: *anyopaque, r: Runnable, p: Priority) void {
        const self = cast(ptr);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.background.push(self.gpa, r, p) catch {
            if (r.drop) |f| f(r.ctx);
            return;
        };
        self.work_available.signal(self.io);
    }

    fn dispatchOnMainThread(ptr: *anyopaque, r: Runnable, p: Priority) void {
        const self = cast(ptr);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.main.push(self.gpa, r, p) catch {
                if (r.drop) |f| f(r.ctx);
                return;
            };
        }
        self.loop.wake();
    }

    fn dispatchAfter(ptr: *anyopaque, delay_ns: u64, r: Runnable) void {
        const self = cast(ptr);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.pending_timers.append(self.gpa, .{ .deadline = event_loop.monotonicNow() +| delay_ns, .runnable = r }) catch {
                if (r.drop) |f| f(r.ctx);
                return;
            };
        }
        self.loop.wake();
    }

    fn now(_: *anyopaque) u64 {
        return event_loop.monotonicNow();
    }
};

// ---------------------------------------------------------------------------------------

const testing = std.testing;

const Recorder = struct {
    mutex: Io.Mutex = .init,
    order: std.ArrayList(u32) = .empty,

    const Item = struct { rec: *Recorder, tag: u32 };

    fn run(ctx: *anyopaque) void {
        const it: *Item = @ptrCast(@alignCast(ctx));
        it.rec.mutex.lockUncancelable(testing.io);
        defer it.rec.mutex.unlock(testing.io);
        it.rec.order.append(testing.allocator, it.tag) catch unreachable;
    }
};

fn noopRun(_: *anyopaque) void {}

test "PriorityQueues: realtime strict, FIFO within a queue, weighted across" {
    var q: PriorityQueues = .{};
    defer q.deinit(testing.allocator);
    var tags: [6]u32 = .{ 0, 1, 2, 3, 4, 5 };
    for (tags[0..3]) |*t| try q.push(testing.allocator, .{ .ctx = t, .run = noopRun }, .low);
    try q.push(testing.allocator, .{ .ctx = &tags[3], .run = noopRun }, .realtime);
    try q.push(testing.allocator, .{ .ctx = &tags[4], .run = noopRun }, .realtime);
    try testing.expectEqual(@as(usize, 5), q.len());

    try testing.expectEqual(@as(*anyopaque, &tags[3]), q.pop().?.ctx);
    try testing.expectEqual(@as(*anyopaque, &tags[4]), q.pop().?.ctx);
    for (tags[0..3]) |*t| try testing.expectEqual(@as(*anyopaque, t), q.pop().?.ctx);
    try testing.expect(q.pop() == null);

    // Weighted lottery: with both queues always non-empty, high wins ~60/70 of the time.
    var high_wins: usize = 0;
    var high_tag: u32 = 0;
    var low_tag: u32 = 1;
    for (0..7000) |_| {
        try q.push(testing.allocator, .{ .ctx = &high_tag, .run = noopRun }, .high);
        try q.push(testing.allocator, .{ .ctx = &low_tag, .run = noopRun }, .low);
        if (q.pop().?.ctx == @as(*anyopaque, &high_tag)) high_wins += 1;
        _ = q.pop();
    }
    try testing.expect(high_wins > 5600 and high_wins < 6400);
}

test "LinuxDispatcher runs background, main-thread and delayed work" {
    var loop = try event_loop.EventLoop.init(testing.allocator);
    defer loop.deinit();
    var d: LinuxDispatcher = undefined;
    try d.init(testing.allocator, testing.io, &loop, 3);
    defer d.deinit();
    const disp = d.dispatcher();
    try testing.expect(disp.isMainThread());

    var rec: Recorder = .{};
    defer rec.order.deinit(testing.allocator);
    var items: [6]Recorder.Item = undefined;
    for (&items, 0..) |*it, i| it.* = .{ .rec = &rec, .tag = @intCast(i) };

    // Delayed work fires in deadline order on the main thread, after immediate work.
    const start = disp.now();
    disp.dispatchAfter(30 * std.time.ns_per_ms, .{ .ctx = &items[5], .run = Recorder.run });
    disp.dispatchAfter(10 * std.time.ns_per_ms, .{ .ctx = &items[4], .run = Recorder.run });
    disp.dispatchOnMainThread(.{ .ctx = &items[2], .run = Recorder.run }, .low);
    disp.dispatchOnMainThread(.{ .ctx = &items[3], .run = Recorder.run }, .realtime);

    while (disp.now() - start < 2 * std.time.ns_per_s) {
        loop.poll(50);
        if (rec.order.items.len >= 4) break;
    }
    try testing.expectEqualSlices(u32, &.{ 3, 2, 4, 5 }, rec.order.items);
    try testing.expect(disp.now() - start >= 30 * std.time.ns_per_ms);

    // Background work runs off the main thread.
    const Bg = struct {
        done: std.atomic.Value(u32) = .init(0),
        off_main: std.atomic.Value(bool) = .init(true),
        disp: platform.Dispatcher,
        fn run(ctx: *anyopaque) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            if (s.disp.isMainThread()) s.off_main.store(false, .seq_cst);
            _ = s.done.fetchAdd(1, .seq_cst);
        }
    };
    var bg: Bg = .{ .disp = disp };
    for (0..64) |i| disp.dispatch(.{ .ctx = &bg, .run = Bg.run }, @fromBackingInt(@intCast(i % 4)));
    while (bg.done.load(.seq_cst) < 64 and disp.now() - start < 5 * std.time.ns_per_s) loop.poll(5);
    try testing.expectEqual(@as(u32, 64), bg.done.load(.seq_cst));
    try testing.expect(bg.off_main.load(.seq_cst));
}
