//! epoll-based main-thread event loop (the zpui stand-in for gpui_linux's calloop loop).
//!
//! Sources are file descriptors with a callback; timers live in a min-heap keyed by
//! deadline and are multiplexed onto a single `timerfd` armed for the earliest deadline.
//! An `eventfd` lets other threads wake the loop (`wake`), and `Hooks` let a backend run
//! code right before blocking (flush the Wayland/X11 connection) and right after waking.
//!
//! Everything except `wake` is main-thread only.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

pub const Error = error{ SystemResources, Unexpected } || Allocator.Error;

/// Monotonic clock in nanoseconds (CLOCK_MONOTONIC).
pub fn monotonicNow() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn check(rc: usize) Error!usize {
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .NOMEM, .MFILE, .NFILE, .NOSPC => error.SystemResources,
        else => error.Unexpected,
    };
}

/// A callback with an opaque context.
pub fn Handler(comptime Args: type) type {
    return struct {
        ctx: ?*anyopaque,
        func: *const fn (ctx: ?*anyopaque, args: Args) void,

        pub fn call(h: @This(), args: Args) void {
            h.func(h.ctx, args);
        }
    };
}

pub const TimerId = u64;

/// A pending timer: fires `handler` once at `deadline` (monotonic ns).
pub const Timer = struct {
    deadline: u64,
    id: TimerId,
    handler: Handler(TimerId),

    fn order(_: void, a: Timer, b: Timer) std.math.Order {
        // Earlier deadline first; equal deadlines fire in insertion (id) order.
        return switch (std.math.order(a.deadline, b.deadline)) {
            .eq => std.math.order(a.id, b.id),
            else => |o| o,
        };
    }
};

/// Pure timer bookkeeping (no fds), so ordering can be unit-tested.
pub const TimerQueue = struct {
    heap: std.PriorityQueue(Timer, void, Timer.order) = .empty,
    next_id: TimerId = 1,

    pub fn deinit(q: *TimerQueue, gpa: Allocator) void {
        q.heap.deinit(gpa);
    }

    pub fn add(q: *TimerQueue, gpa: Allocator, deadline: u64, handler: Handler(TimerId)) Allocator.Error!TimerId {
        const id = q.next_id;
        q.next_id += 1;
        try q.heap.push(gpa, .{ .deadline = deadline, .id = id, .handler = handler });
        return id;
    }

    /// Removes a pending timer. Returns false if it already fired or never existed.
    pub fn cancel(q: *TimerQueue, id: TimerId) bool {
        for (q.heap.items, 0..) |t, i| if (t.id == id) {
            _ = q.heap.popIndex(i);
            return true;
        };
        return false;
    }

    pub fn nextDeadline(q: *const TimerQueue) ?u64 {
        return if (q.heap.peek()) |t| t.deadline else null;
    }

    /// Pops the earliest timer whose deadline is <= `now`.
    pub fn popExpired(q: *TimerQueue, now: u64) ?Timer {
        const t = q.heap.peek() orelse return null;
        if (t.deadline > now) return null;
        return q.heap.pop();
    }
};

/// A registered file descriptor. Heap-allocated so its address can live in epoll data.
pub const Source = struct {
    fd: linux.fd_t,
    handler: Handler(u32),
    /// Set when the source is removed while the loop is dispatching it.
    dead: bool = false,
};

pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    /// Runs before every blocking wait (flush outgoing requests, prepare reads).
    before_wait: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Runs right after every wait, before any handler or timer (finish or cancel a
    /// prepared read, so handlers that talk to the server, e.g. a Vulkan present that
    /// reads the display itself, never block on a read held across them).
    after_wait: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Runs after every wait, once all ready handlers ran (dispatch queued protocol events).
    after_dispatch: ?*const fn (ctx: ?*anyopaque) void = null,
};

pub const EventLoop = struct {
    gpa: Allocator,
    epfd: linux.fd_t,
    wake_fd: linux.fd_t,
    timer_fd: linux.fd_t,
    timers: TimerQueue = .{},
    sources: std.ArrayList(*Source) = .empty,
    /// Called (on the main thread) whenever `wake` was signalled.
    on_wake: ?Handler(void) = null,
    hooks: Hooks = .{},
    armed_deadline: ?u64 = null,
    running: bool = false,
    /// Sources removed during dispatch, freed at the end of `poll`.
    graveyard: std.ArrayList(*Source) = .empty,

    // Sentinel epoll data values for the internal fds.
    const wake_tag: u64 = 1;
    const timer_tag: u64 = 2;

    pub fn init(gpa: Allocator) Error!EventLoop {
        const epfd: linux.fd_t = @intCast(try check(linux.epoll_create1(linux.EPOLL.CLOEXEC)));
        errdefer _ = linux.close(epfd);
        const wake_fd: linux.fd_t = @intCast(try check(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK)));
        errdefer _ = linux.close(wake_fd);
        const timer_fd: linux.fd_t = @intCast(try check(linux.timerfd_create(.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true })));
        errdefer _ = linux.close(timer_fd);

        var ev: linux.epoll_event = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = wake_tag } };
        _ = try check(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, wake_fd, &ev));
        ev = .{ .events = linux.EPOLL.IN, .data = .{ .u64 = timer_tag } };
        _ = try check(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, timer_fd, &ev));
        return .{ .gpa = gpa, .epfd = epfd, .wake_fd = wake_fd, .timer_fd = timer_fd };
    }

    pub fn deinit(l: *EventLoop) void {
        for (l.sources.items) |s| l.gpa.destroy(s);
        l.sources.deinit(l.gpa);
        l.graveyard.deinit(l.gpa);
        l.timers.deinit(l.gpa);
        _ = linux.close(l.timer_fd);
        _ = linux.close(l.wake_fd);
        _ = linux.close(l.epfd);
    }

    /// Watches `fd` for `events` (EPOLL.IN etc.). `handler` receives the ready event mask.
    pub fn addFd(l: *EventLoop, fd: linux.fd_t, events: u32, handler: Handler(u32)) Error!*Source {
        const s = try l.gpa.create(Source);
        errdefer l.gpa.destroy(s);
        s.* = .{ .fd = fd, .handler = handler };
        try l.sources.append(l.gpa, s);
        errdefer _ = l.sources.pop();
        var ev: linux.epoll_event = .{ .events = events, .data = .{ .ptr = @intFromPtr(s) } };
        _ = try check(linux.epoll_ctl(l.epfd, linux.EPOLL.CTL_ADD, fd, &ev));
        return s;
    }

    /// Stops watching a source. The fd itself is not closed.
    pub fn removeFd(l: *EventLoop, s: *Source) void {
        _ = linux.epoll_ctl(l.epfd, linux.EPOLL.CTL_DEL, s.fd, null);
        for (l.sources.items, 0..) |item, i| if (item == s) {
            _ = l.sources.swapRemove(i);
            break;
        };
        // Destroyed after the current dispatch if one may still reference it.
        if (l.running) {
            s.dead = true;
            l.graveyard.append(l.gpa, s) catch {};
        } else l.gpa.destroy(s);
    }

    /// Schedules `handler` at absolute monotonic `deadline` (ns).
    pub fn addTimerAt(l: *EventLoop, deadline: u64, handler: Handler(TimerId)) Allocator.Error!TimerId {
        return l.timers.add(l.gpa, deadline, handler);
    }

    pub fn addTimer(l: *EventLoop, delay_ns: u64, handler: Handler(TimerId)) Allocator.Error!TimerId {
        return l.addTimerAt(monotonicNow() +| delay_ns, handler);
    }

    pub fn cancelTimer(l: *EventLoop, id: TimerId) void {
        _ = l.timers.cancel(id);
    }

    /// Thread-safe: makes the current or next `poll` return promptly and run `on_wake`.
    pub fn wake(l: *EventLoop) void {
        const one: u64 = 1;
        _ = linux.write(l.wake_fd, std.mem.asBytes(&one), 8);
    }

    fn armTimerFd(l: *EventLoop) void {
        const next = l.timers.nextDeadline();
        if (next == l.armed_deadline) return;
        l.armed_deadline = next;
        var spec: linux.itimerspec = .{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{ .sec = 0, .nsec = 0 },
        };
        if (next) |d| {
            // A zero it_value disarms the timer, so clamp to at least 1ns.
            const v = @max(d, 1);
            spec.it_value = .{ .sec = @intCast(v / std.time.ns_per_s), .nsec = @intCast(v % std.time.ns_per_s) };
        }
        _ = linux.timerfd_settime(l.timer_fd, .{ .ABSTIME = true }, &spec, null);
    }

    fn fireTimers(l: *EventLoop) void {
        const now = monotonicNow();
        // Only fire timers that were due when we started, so a handler that re-arms
        // itself with a zero delay cannot starve the loop.
        var budget = l.timers.heap.count();
        while (budget > 0) : (budget -= 1) {
            const t = l.timers.popExpired(now) orelse break;
            t.handler.call(t.id);
        }
    }

    /// Blocks for at most `timeout_ms` (-1 = forever) and dispatches everything ready.
    pub fn poll(l: *EventLoop, timeout_ms: i32) void {
        if (l.hooks.before_wait) |f| f(l.hooks.ctx);
        l.armTimerFd();

        var events: [32]linux.epoll_event = undefined;
        const rc = linux.epoll_wait(l.epfd, &events, events.len, timeout_ms);
        const n: usize = if (linux.errno(rc) == .SUCCESS) rc else 0;
        if (l.hooks.after_wait) |f| f(l.hooks.ctx);

        l.running = true;
        var woke = false;
        for (events[0..n]) |ev| {
            switch (ev.data.u64) {
                wake_tag => {
                    var buf: u64 = 0;
                    _ = linux.read(l.wake_fd, std.mem.asBytes(&buf), 8);
                    woke = true;
                },
                timer_tag => {
                    var buf: u64 = 0;
                    _ = linux.read(l.timer_fd, std.mem.asBytes(&buf), 8);
                    l.armed_deadline = null;
                },
                else => {
                    const s: *Source = @ptrFromInt(ev.data.ptr);
                    if (!s.dead) s.handler.call(ev.events);
                },
            }
        }
        if (woke) if (l.on_wake) |h| h.call({});
        // Timers are checked every iteration, not only when the timerfd fired: a
        // deadline may already have passed by the time we get here.
        l.fireTimers();
        if (l.hooks.after_dispatch) |f| f(l.hooks.ctx);
        l.running = false;
        for (l.graveyard.items) |s| l.gpa.destroy(s);
        l.graveyard.clearRetainingCapacity();
    }
};

// ---------------------------------------------------------------------------------------

const testing = std.testing;

fn recordTimer(ctx: ?*anyopaque, id: TimerId) void {
    const list: *std.ArrayList(TimerId) = @ptrCast(@alignCast(ctx.?));
    list.appendAssumeCapacity(id);
}

test "TimerQueue fires in deadline order, ties by insertion" {
    var q: TimerQueue = .{};
    defer q.deinit(testing.allocator);
    var fired: std.ArrayList(TimerId) = try .initCapacity(testing.allocator, 8);
    defer fired.deinit(testing.allocator);
    const h: Handler(TimerId) = .{ .ctx = &fired, .func = recordTimer };

    const a = try q.add(testing.allocator, 300, h);
    const b = try q.add(testing.allocator, 100, h);
    const c = try q.add(testing.allocator, 200, h);
    const d = try q.add(testing.allocator, 100, h);
    const e = try q.add(testing.allocator, 50, h);
    try testing.expect(q.cancel(e));
    try testing.expect(!q.cancel(e));
    try testing.expectEqual(@as(?u64, 100), q.nextDeadline());

    try testing.expect(q.popExpired(99) == null);
    while (q.popExpired(250)) |t| t.handler.call(t.id);
    try testing.expectEqualSlices(TimerId, &.{ b, d, c }, fired.items);
    while (q.popExpired(1000)) |t| t.handler.call(t.id);
    try testing.expectEqualSlices(TimerId, &.{ b, d, c, a }, fired.items);
    try testing.expect(q.nextDeadline() == null);
}

test "EventLoop timers and wake" {
    var l = try EventLoop.init(testing.allocator);
    defer l.deinit();
    var fired: std.ArrayList(TimerId) = try .initCapacity(testing.allocator, 8);
    defer fired.deinit(testing.allocator);
    const h: Handler(TimerId) = .{ .ctx = &fired, .func = recordTimer };

    // Taken before arming: the 20ms deadline is relative to `addTimer`, so a start taken
    // afterwards can be late by scheduling delay under load (flaked in parallel runs).
    const start = monotonicNow();
    const late = try l.addTimer(20 * std.time.ns_per_ms, h);
    const early = try l.addTimer(5 * std.time.ns_per_ms, h);
    const cancelled = try l.addTimer(1 * std.time.ns_per_ms, h);
    l.cancelTimer(cancelled);

    while (fired.items.len < 2 and monotonicNow() - start < std.time.ns_per_s) l.poll(100);
    try testing.expectEqualSlices(TimerId, &.{ early, late }, fired.items);
    try testing.expect(monotonicNow() - start >= 20 * std.time.ns_per_ms);

    var woken = false;
    l.on_wake = .{ .ctx = &woken, .func = struct {
        fn f(ctx: ?*anyopaque, _: void) void {
            @as(*bool, @ptrCast(ctx.?)).* = true;
        }
    }.f };
    l.wake();
    l.poll(1000);
    try testing.expect(woken);
}

test "EventLoop fd source" {
    var l = try EventLoop.init(testing.allocator);
    defer l.deinit();
    var fds: [2]linux.fd_t = undefined;
    _ = linux.pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true });
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    var got: u32 = 0;
    const src = try l.addFd(fds[0], linux.EPOLL.IN, .{ .ctx = &got, .func = struct {
        fn f(ctx: ?*anyopaque, events: u32) void {
            @as(*u32, @ptrCast(@alignCast(ctx.?))).* = events;
        }
    }.f });
    _ = linux.write(fds[1], "x", 1);
    l.poll(1000);
    try testing.expect(got & linux.EPOLL.IN != 0);
    l.removeFd(src);
}
