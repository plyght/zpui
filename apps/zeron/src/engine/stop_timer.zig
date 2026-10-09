//! A sleep on a helper thread that the owner can end early, without
//! `Io.Future.cancel`.
//!
//! `std.Io.Threaded` cancels a future that is blocked in a syscall (a sleep
//! included) by sending its thread `SIGIO`. A thread that has `SIGIO` blocked
//! never sees it, so `cancel` waits out the whole sleep. New threads inherit
//! the creating thread's signal mask, and libdispatch worker threads block
//! nearly every signal. zpui's macOS background executor runs on those
//! workers, so every future the engine connect started on macOS had `SIGIO`
//! blocked. Each `cancel` of the WebSocket handshake watchdog then waited the
//! full 5 s `handshake_timeout`, which was the 5 s macOS boot delay in
//! docs/BENCHMARKS.md. A futex wake needs no signal, so `stop` returns at
//! once on any thread.
//!
//! ```
//! var timer: StopTimer = .{};
//! var f = io.concurrent(watch, .{ io, &timer }) catch null; // watch: `if (timer.sleep(io, d)) fire();`
//! defer if (f) |*w| timer.stopAndAwait(io, w);
//! ```

const std = @import("std");
const Io = std.Io;

pub const StopTimer = struct {
    stopped: Io.Event = .unset,

    /// Wait `duration` unless `stop` comes first. True when the time ran out
    /// (the caller's timeout action should run); false when stopped or
    /// canceled.
    pub fn sleep(t: *StopTimer, io: Io, duration: Io.Duration) bool {
        const deadline = (Io.Timeout{ .duration = .{ .raw = duration, .clock = .awake } }).toDeadline(io);
        while (true) {
            t.stopped.waitTimeout(io, deadline) catch |err| switch (err) {
                error.Canceled => return false,
                // A timeout or a spurious wake: recheck the flag and the clock.
                error.Timeout => {
                    if (t.stopped.isSet()) return false;
                    const left = deadline.toDurationFromNow(io) orelse return true;
                    if (left.raw.nanoseconds <= 0) return true;
                    continue;
                },
            };
            return false;
        }
    }

    /// End a pending (or future) `sleep` with false. Thread-safe.
    pub fn stop(t: *StopTimer, io: Io) void {
        t.stopped.set(io);
    }

    /// `stop`, then wait for the future that sleeps on this timer. Returns as
    /// soon as that thread wakes, whatever its signal mask.
    pub fn stopAndAwait(t: *StopTimer, io: Io, future: anytype) void {
        t.stop(io);
        _ = future.await(io);
    }
};

const testing = std.testing;

fn sleeper(io: Io, t: *StopTimer, d: Io.Duration, out: *std.atomic.Value(u8)) void {
    out.store(if (t.sleep(io, d)) 1 else 2, .release);
}

test "StopTimer: runs out when not stopped" {
    const io = testing.io;
    var t: StopTimer = .{};
    var out = std.atomic.Value(u8).init(0);
    var f = try io.concurrent(sleeper, .{ io, &t, Io.Duration.fromMilliseconds(20), &out });
    f.await(io);
    try testing.expectEqual(@as(u8, 1), out.load(.acquire));
}

/// Runs on a thread that blocks every signal, like a libdispatch worker.
fn stopFromMaskedThread(io: Io, result: *?i96, out: *std.atomic.Value(u8)) void {
    var all = std.posix.sigfillset();
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &all, null);
    const start = Io.Timestamp.now(io, .awake).nanoseconds;
    var t: StopTimer = .{};
    var f = io.concurrent(sleeper, .{ io, &t, Io.Duration.fromSeconds(5), out }) catch return;
    // Let the sleeper reach its wait.
    io.sleep(.fromMilliseconds(20), .awake) catch {};
    t.stopAndAwait(io, &f);
    result.* = Io.Timestamp.now(io, .awake).nanoseconds - start;
}

test "StopTimer: stop returns at once from a thread that blocks SIGIO (the macOS boot delay)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const io = testing.io;
    var elapsed: ?i96 = null;
    var out = std.atomic.Value(u8).init(0);
    const th = try std.Thread.spawn(.{}, stopFromMaskedThread, .{ io, &elapsed, &out });
    th.join();
    const ns = elapsed orelse return error.ConcurrencyUnavailable;
    // `Future.cancel` here would have waited the full 5 s sleep.
    try testing.expect(ns < 2 * std.time.ns_per_s);
    try testing.expectEqual(@as(u8, 2), out.load(.acquire));
}
