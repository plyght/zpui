//! libc-backed threading helpers for the voice worker, which runs outside
//! zpui's executor and its `Io`: a pthread mutex/condition pair, a
//! monotonic clock and a sleep.

const std = @import("std");
const c = std.c;

pub const Mutex = struct {
    inner: c.pthread_mutex_t = .{},

    pub fn lock(self: *Mutex) void {
        _ = c.pthread_mutex_lock(&self.inner);
    }
    pub fn tryLock(self: *Mutex) bool {
        return c.pthread_mutex_trylock(&self.inner) == .SUCCESS;
    }
    pub fn unlock(self: *Mutex) void {
        _ = c.pthread_mutex_unlock(&self.inner);
    }
};

pub const Cond = struct {
    inner: c.pthread_cond_t = .{},

    pub fn signal(self: *Cond) void {
        _ = c.pthread_cond_signal(&self.inner);
    }
    /// Waits up to `ms`; returns false on timeout.
    pub fn timedWait(self: *Cond, m: *Mutex, ms: u64) bool {
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(.REALTIME, &ts);
        var sec: i64 = @intCast(ts.sec);
        var nsec: i64 = @intCast(ts.nsec);
        nsec += @intCast((ms % 1000) * std.time.ns_per_ms);
        sec += @intCast(ms / 1000);
        if (nsec >= std.time.ns_per_s) {
            nsec -= std.time.ns_per_s;
            sec += 1;
        }
        const deadline: c.timespec = .{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
        return c.pthread_cond_timedwait(&self.inner, &m.inner, &deadline) != .TIMEDOUT;
    }
};

/// Monotonic nanoseconds.
pub fn now() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub fn sleepMs(ms: u64) void {
    var req: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    var rem: c.timespec = undefined;
    while (c.nanosleep(&req, &rem) != 0) req = rem;
}
