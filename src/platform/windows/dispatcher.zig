//! Windows `platform.Dispatcher`.
//!
//! * Background work: worker threads pull from a weighted priority queue (same policy
//!   as the Linux dispatcher: `realtime` strict, then high/medium/low by lottery 60/30/10)
//!   guarded by an SRW lock + condition variable.
//! * Main-thread work: queued under the lock; the first runnable after an empty queue
//!   posts one `WM_APP_WAKE` to the platform's hidden window, whose window procedure
//!   drains the queue. Being a posted window message, it also runs inside modal loops
//!   (window move/resize, menus) where the platform's own loop is not running.
//! * `dispatchAfter`: a min-heap of deadlines owned by the main thread (other threads
//!   stage requests under the lock and wake it). The run loop sleeps in
//!   `MsgWaitForMultipleObjectsEx` until the earliest deadline; during modal loops a
//!   `SetTimer` on the hidden window covers the same deadline.
//!
//! Idle cost: with no queued work and no timers, the main thread blocks in the kernel
//! and the workers sleep on the condition variable; nothing polls.

const std = @import("std");
const Allocator = std.mem.Allocator;
const platform = @import("../platform.zig");
const w = @import("win32.zig");

const Runnable = platform.Runnable;
const Priority = platform.Priority;

pub const WM_APP_WAKE: w.UINT = w.WM_APP + 1;
pub const modal_timer_id: usize = 0x7a70;

fn weight(p: Priority) u32 {
    return switch (p) {
        .realtime => 0,
        .high => 60,
        .medium => 30,
        .low => 10,
    };
}

/// Four FIFO queues with weighted selection. Not thread-safe; callers hold the lock.
const PriorityQueues = struct {
    queues: [4]std.Deque(Runnable) = .{ .empty, .empty, .empty, .empty },
    rng: std.Random.DefaultPrng = .init(0),

    fn deinit(q: *PriorityQueues, gpa: Allocator) void {
        for (&q.queues) |*d| d.deinit(gpa);
    }
    fn push(q: *PriorityQueues, gpa: Allocator, r: Runnable, p: Priority) Allocator.Error!void {
        try q.queues[@backingInt(p)].pushBack(gpa, r);
    }
    fn len(q: *const PriorityQueues) usize {
        var n: usize = 0;
        for (q.queues) |d| n += d.len;
        return n;
    }
    fn pop(q: *PriorityQueues) ?Runnable {
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
    fn dropAll(q: *PriorityQueues) void {
        for (&q.queues) |*d| while (d.popFront()) |r| if (r.drop) |f| f(r.ctx);
    }
};

const Timer = struct { deadline: u64, seq: u64, runnable: Runnable };

fn timerLess(_: void, a: Timer, b: Timer) std.math.Order {
    if (a.deadline != b.deadline) return std.math.order(a.deadline, b.deadline);
    return std.math.order(a.seq, b.seq);
}

pub const WindowsDispatcher = struct {
    gpa: Allocator,
    main_thread: w.DWORD,
    /// Hidden window receiving `WM_APP_WAKE` (set by the platform after creating it).
    wake_hwnd: ?w.HWND = null,
    qpc_freq: u64,

    lock: w.SRWLOCK = .{},
    work_available: w.CONDITION_VARIABLE = .{},
    background: PriorityQueues = .{},
    main: PriorityQueues = .{},
    staged_timers: std.ArrayList(Timer) = .empty,
    wake_posted: bool = false,
    shutting_down: bool = false,
    workers: []std.Thread = &.{},

    /// Main thread only.
    timers: std.PriorityQueue(Timer, void, timerLess) = .empty,
    timer_seq: u64 = 0,
    /// Deadline the modal `SetTimer` is armed for (0 = none).
    modal_armed: u64 = 0,
    /// > 0 while a modal loop (move/size, menu) runs instead of the platform loop.
    modal_depth: u32 = 0,

    /// Main thread. `self` must not move afterwards (workers hold it).
    pub fn init(self: *WindowsDispatcher, gpa: Allocator, worker_count: ?usize) !void {
        var freq: i64 = 0;
        _ = w.QueryPerformanceFrequency(&freq);
        self.* = .{ .gpa = gpa, .main_thread = w.GetCurrentThreadId(), .qpc_freq = @intCast(@max(freq, 1)) };
        const n = worker_count orelse @max(2, std.Thread.getCpuCount() catch 2);
        self.workers = try gpa.alloc(std.Thread, n);
        var spawned: usize = 0;
        errdefer {
            self.stopWorkers(spawned);
            gpa.free(self.workers);
        }
        while (spawned < n) : (spawned += 1) {
            self.workers[spawned] = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, workerMain, .{self});
        }
    }

    fn stopWorkers(self: *WindowsDispatcher, count: usize) void {
        w.AcquireSRWLockExclusive(&self.lock);
        self.shutting_down = true;
        w.WakeAllConditionVariable(&self.work_available);
        w.ReleaseSRWLockExclusive(&self.lock);
        for (self.workers[0..count]) |t| t.join();
    }

    pub fn deinit(self: *WindowsDispatcher) void {
        self.stopWorkers(self.workers.len);
        self.gpa.free(self.workers);
        self.background.dropAll();
        self.main.dropAll();
        for (self.staged_timers.items) |t| if (t.runnable.drop) |f| f(t.runnable.ctx);
        for (self.timers.items) |t| if (t.runnable.drop) |f| f(t.runnable.ctx);
        self.background.deinit(self.gpa);
        self.main.deinit(self.gpa);
        self.staged_timers.deinit(self.gpa);
        self.timers.deinit(self.gpa);
    }

    fn workerMain(self: *WindowsDispatcher) void {
        while (true) {
            w.AcquireSRWLockExclusive(&self.lock);
            const r = while (true) {
                if (self.shutting_down) {
                    w.ReleaseSRWLockExclusive(&self.lock);
                    return;
                }
                if (self.background.pop()) |r| break r;
                _ = w.SleepConditionVariableSRW(&self.work_available, &self.lock, w.INFINITE, 0);
            };
            w.ReleaseSRWLockExclusive(&self.lock);
            r.run(r.ctx);
        }
    }

    pub fn nowNs(self: *const WindowsDispatcher) u64 {
        var t: i64 = 0;
        _ = w.QueryPerformanceCounter(&t);
        const ticks: u64 = @intCast(@max(t, 0));
        return @intCast(@as(u128, ticks) * std.time.ns_per_s / self.qpc_freq);
    }

    /// QPC ticks -> the `now()` clock (hook threads timestamp with raw QPC).
    pub fn qpcToNs(self: *const WindowsDispatcher, ticks: u64) u64 {
        return @intCast(@as(u128, ticks) * std.time.ns_per_s / self.qpc_freq);
    }

    /// Post the wake message unless one is already pending. Caller holds the lock.
    fn wakeLocked(self: *WindowsDispatcher) void {
        if (self.wake_posted) return;
        const hwnd = self.wake_hwnd orelse return;
        if (w.PostMessageW(hwnd, WM_APP_WAKE, 0, 0) != 0) self.wake_posted = true;
    }

    /// Runs the main-thread runnables queued when this call started and moves staged
    /// timers into the heap. Main thread only (the hidden window's `WM_APP_WAKE`).
    pub fn drainMain(self: *WindowsDispatcher) void {
        w.AcquireSRWLockExclusive(&self.lock);
        self.wake_posted = false;
        var budget = self.main.len();
        const staged = self.staged_timers.items.len > 0;
        if (staged) {
            for (self.staged_timers.items) |t| self.timers.push(self.gpa, t) catch if (t.runnable.drop) |f| f(t.runnable.ctx);
            self.staged_timers.clearRetainingCapacity();
        }
        w.ReleaseSRWLockExclusive(&self.lock);
        if (staged) self.armModalTimer();

        while (budget > 0) : (budget -= 1) {
            w.AcquireSRWLockExclusive(&self.lock);
            const r = self.main.pop();
            w.ReleaseSRWLockExclusive(&self.lock);
            const runnable = r orelse break;
            runnable.run(runnable.ctx);
        }
        // Anything queued by the runnables themselves runs on the next wake.
        w.AcquireSRWLockExclusive(&self.lock);
        if (self.main.len() > 0) self.wakeLocked();
        w.ReleaseSRWLockExclusive(&self.lock);
    }

    /// A timer's deadline has passed. Main thread only.
    pub fn timerDue(self: *const WindowsDispatcher) bool {
        const t = self.timers.peek() orelse return false;
        return t.deadline <= self.nowNs();
    }

    /// Run due timers; returns the milliseconds until the next one (INFINITE if none).
    /// Main thread only.
    pub fn runTimers(self: *WindowsDispatcher) w.DWORD {
        var fired: u32 = 0;
        while (self.timers.peek()) |t| {
            const now_ns = self.nowNs();
            if (t.deadline > now_ns) {
                const ms = (t.deadline - now_ns + std.time.ns_per_ms - 1) / std.time.ns_per_ms;
                return @intCast(@min(ms, 0x7fffffff));
            }
            _ = self.timers.pop();
            t.runnable.run(t.runnable.ctx);
            fired += 1;
            // Never starve input: yield after a burst.
            if (fired >= 64) return 0;
        }
        return w.INFINITE;
    }

    /// Modal loops do not run the platform's wait: keep a `SetTimer` armed for the
    /// earliest deadline while one is active.
    pub fn armModalTimer(self: *WindowsDispatcher) void {
        if (self.modal_depth == 0) return;
        const hwnd = self.wake_hwnd orelse return;
        const t = self.timers.peek() orelse {
            if (self.modal_armed != 0) _ = w.KillTimer(hwnd, modal_timer_id);
            self.modal_armed = 0;
            return;
        };
        if (self.modal_armed == t.deadline) return;
        self.modal_armed = t.deadline;
        const now_ns = self.nowNs();
        const ms: u64 = if (t.deadline > now_ns) (t.deadline - now_ns) / std.time.ns_per_ms else 0;
        _ = w.SetTimer(hwnd, modal_timer_id, @intCast(@max(@min(ms, 0x7fffffff), w.USER_TIMER_MINIMUM)), null);
    }

    pub fn enterModal(self: *WindowsDispatcher) void {
        self.modal_depth += 1;
        self.modal_armed = 0;
        self.armModalTimer();
    }

    pub fn exitModal(self: *WindowsDispatcher) void {
        if (self.modal_depth == 0) return;
        self.modal_depth -= 1;
        if (self.modal_depth == 0) {
            if (self.wake_hwnd) |h| _ = w.KillTimer(h, modal_timer_id);
            self.modal_armed = 0;
        }
    }

    /// `WM_TIMER` (modal_timer_id) on the hidden window.
    pub fn onModalTimer(self: *WindowsDispatcher) void {
        self.modal_armed = 0;
        _ = self.runTimers();
        if (self.modal_depth == 0) {
            if (self.wake_hwnd) |h| _ = w.KillTimer(h, modal_timer_id);
        } else self.armModalTimer();
    }

    pub fn dispatcher(self: *WindowsDispatcher) platform.Dispatcher {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: platform.Dispatcher.VTable = .{
        .isMainThread = isMainThread,
        .dispatch = dispatch,
        .dispatchOnMainThread = dispatchOnMainThread,
        .dispatchAfter = dispatchAfter,
        .now = now,
    };

    fn cast(ptr: *anyopaque) *WindowsDispatcher {
        return @ptrCast(@alignCast(ptr));
    }

    fn isMainThread(ptr: *anyopaque) bool {
        return w.GetCurrentThreadId() == cast(ptr).main_thread;
    }

    fn dispatch(ptr: *anyopaque, r: Runnable, p: Priority) void {
        const self = cast(ptr);
        w.AcquireSRWLockExclusive(&self.lock);
        const ok = if (self.shutting_down) false else if (self.background.push(self.gpa, r, p)) |_| true else |_| false;
        if (ok) w.WakeConditionVariable(&self.work_available);
        w.ReleaseSRWLockExclusive(&self.lock);
        if (!ok) if (r.drop) |f| f(r.ctx);
    }

    fn dispatchOnMainThread(ptr: *anyopaque, r: Runnable, p: Priority) void {
        const self = cast(ptr);
        w.AcquireSRWLockExclusive(&self.lock);
        const ok = if (self.main.push(self.gpa, r, p)) |_| true else |_| false;
        if (ok) self.wakeLocked();
        w.ReleaseSRWLockExclusive(&self.lock);
        if (!ok) if (r.drop) |f| f(r.ctx);
    }

    fn dispatchAfter(ptr: *anyopaque, delay_ns: u64, r: Runnable) void {
        const self = cast(ptr);
        const timer: Timer = .{ .deadline = self.nowNs() +| delay_ns, .seq = @atomicRmw(u64, &self.timer_seq, .Add, 1, .monotonic), .runnable = r };
        if (isMainThread(ptr)) {
            self.timers.push(self.gpa, timer) catch {
                if (r.drop) |f| f(r.ctx);
                return;
            };
            self.armModalTimer();
            return;
        }
        w.AcquireSRWLockExclusive(&self.lock);
        const ok = if (self.staged_timers.append(self.gpa, timer)) |_| true else |_| false;
        if (ok) self.wakeLocked();
        w.ReleaseSRWLockExclusive(&self.lock);
        if (!ok) if (r.drop) |f| f(r.ctx);
    }

    fn now(ptr: *anyopaque) u64 {
        return cast(ptr).nowNs();
    }
};
