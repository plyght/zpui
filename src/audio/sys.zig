//! OS primitives for the audio engine, independent of zpui's `Io`: a
//! monotonic clock, an auto-reset wake event (futex on Linux, a dispatch
//! semaphore on macOS, a Win32 event on Windows), a sleep and a tiny
//! spin lock for the producer side of the command queue.

const std = @import("std");
const builtin = @import("builtin");
const os = builtin.os.tag;

pub const windows = struct {
    pub const HANDLE = *anyopaque;
    pub const BOOL = i32;
    pub const INFINITE: u32 = 0xFFFF_FFFF;
    pub const WAIT_OBJECT_0: u32 = 0;
    pub const WAIT_TIMEOUT: u32 = 0x102;
    pub extern "kernel32" fn QueryPerformanceCounter(out: *i64) callconv(.winapi) BOOL;
    pub extern "kernel32" fn QueryPerformanceFrequency(out: *i64) callconv(.winapi) BOOL;
    pub extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual_reset: BOOL, initial: BOOL, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn SetEvent(h: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
    pub extern "kernel32" fn WaitForMultipleObjects(n: u32, handles: [*]const HANDLE, wait_all: BOOL, ms: u32) callconv(.winapi) u32;
    pub extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
    pub extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn GetProcAddress(module: HANDLE, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
};

const darwin = struct {
    const dispatch_semaphore_t = *opaque {};
    extern "c" fn dispatch_semaphore_create(value: isize) ?dispatch_semaphore_t;
    extern "c" fn dispatch_semaphore_signal(sem: dispatch_semaphore_t) isize;
    extern "c" fn dispatch_semaphore_wait(sem: dispatch_semaphore_t, timeout: u64) isize;
    extern "c" fn dispatch_release(obj: *anyopaque) void;
    extern "c" fn dispatch_time(when: u64, delta: i64) u64;
    const DISPATCH_TIME_NOW: u64 = 0;
    const DISPATCH_TIME_FOREVER: u64 = ~@as(u64, 0);
};

var qpc_freq: std.atomic.Value(i64) = .init(0);

/// Monotonic nanoseconds (arbitrary epoch).
pub fn nowNs() u64 {
    if (os == .windows) {
        var f = qpc_freq.load(.monotonic);
        if (f == 0) {
            _ = windows.QueryPerformanceFrequency(&f);
            qpc_freq.store(f, .monotonic);
        }
        var c: i64 = 0;
        _ = windows.QueryPerformanceCounter(&c);
        const cu: u128 = @intCast(c);
        return @intCast(cu * std.time.ns_per_s / @as(u128, @intCast(f)));
    } else {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }
}

pub fn sleepNs(ns: u64) void {
    if (os == .windows) {
        windows.Sleep(@intCast(@max(1, ns / std.time.ns_per_ms)));
    } else {
        var req: std.c.timespec = .{ .sec = @intCast(ns / std.time.ns_per_s), .nsec = @intCast(ns % std.time.ns_per_s) };
        var rem: std.c.timespec = undefined;
        while (std.c.nanosleep(&req, &rem) != 0) req = rem;
    }
}

/// Auto-reset wake event: `signal` never blocks and is safe from any
/// thread (including a real-time audio thread); `wait` returns once a
/// signal is pending or the timeout passes. Spurious returns are allowed,
/// so callers re-check their condition.
pub const Event = struct {
    impl: Impl = undefined,

    const Impl = switch (os) {
        .linux => struct { word: std.atomic.Value(u32) = .init(0) },
        .macos, .ios => struct { sem: darwin.dispatch_semaphore_t },
        .windows => struct { handle: windows.HANDLE },
        else => struct { word: std.atomic.Value(u32) = .init(0) },
    };

    pub fn init(self: *Event) error{SystemResources}!void {
        switch (os) {
            .macos, .ios => self.impl = .{ .sem = darwin.dispatch_semaphore_create(0) orelse return error.SystemResources },
            .windows => self.impl = .{ .handle = windows.CreateEventW(null, 0, 0, null) orelse return error.SystemResources },
            else => self.impl = .{},
        }
    }

    pub fn deinit(self: *Event) void {
        switch (os) {
            .macos, .ios => darwin.dispatch_release(@ptrCast(self.impl.sem)),
            .windows => _ = windows.CloseHandle(self.impl.handle),
            else => {},
        }
    }

    pub fn signal(self: *Event) void {
        switch (os) {
            .linux => if (self.impl.word.swap(1, .release) == 0) {
                _ = std.os.linux.futex_3arg(&self.impl.word.raw, .{ .cmd = .WAKE, .private = true }, 1);
            },
            .macos, .ios => _ = darwin.dispatch_semaphore_signal(self.impl.sem),
            .windows => _ = windows.SetEvent(self.impl.handle),
            else => self.impl.word.store(1, .release),
        }
    }

    /// Waits for a signal; `timeout_ns == null` waits forever. Returns
    /// true when a signal was consumed.
    pub fn wait(self: *Event, timeout_ns: ?u64) bool {
        switch (os) {
            .linux => {
                if (self.impl.word.swap(0, .acquire) == 1) return true;
                var ts: std.os.linux.timespec = undefined;
                if (timeout_ns) |t| ts = .{ .sec = @intCast(t / std.time.ns_per_s), .nsec = @intCast(t % std.time.ns_per_s) };
                _ = std.os.linux.futex_4arg(&self.impl.word.raw, .{ .cmd = .WAIT, .private = true }, 0, if (timeout_ns != null) &ts else null);
                return self.impl.word.swap(0, .acquire) == 1;
            },
            .macos, .ios => {
                const deadline = if (timeout_ns) |t| darwin.dispatch_time(darwin.DISPATCH_TIME_NOW, @intCast(@min(t, std.math.maxInt(i64)))) else darwin.DISPATCH_TIME_FOREVER;
                return darwin.dispatch_semaphore_wait(self.impl.sem, deadline) == 0;
            },
            .windows => {
                const ms: u32 = if (timeout_ns) |t| @intCast(@min(t / std.time.ns_per_ms, windows.INFINITE - 1)) else windows.INFINITE;
                return windows.WaitForSingleObject(self.impl.handle, ms) == windows.WAIT_OBJECT_0;
            },
            else => {
                if (timeout_ns) |t| sleepNs(@min(t, std.time.ns_per_ms));
                return self.impl.word.swap(0, .acquire) == 1;
            },
        }
    }
};

/// A shared library opened at run time (Linux backends). `load` fills a
/// struct of function pointers by field name and fails if any is missing,
/// so a too-old library is rejected up front.
pub const DynLib = struct {
    handle: *anyopaque,

    pub fn open(names: []const [:0]const u8) ?DynLib {
        if (os != .linux) return null;
        for (names) |n| {
            if (std.c.dlopen(n.ptr, .{ .NOW = true })) |h| return .{ .handle = h };
        }
        return null;
    }

    pub fn close(self: DynLib) void {
        if (os == .linux) _ = std.c.dlclose(self.handle);
    }

    pub fn sym(self: DynLib, comptime T: type, name: [*:0]const u8) ?T {
        const p = std.c.dlsym(self.handle, name) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    /// Resolves every field of `Fns` (all function pointers; optional
    /// fields may be missing).
    pub fn load(self: DynLib, comptime Fns: type) ?Fns {
        var fns: Fns = undefined;
        const info = @typeInfo(Fns).@"struct";
        inline for (info.field_names, info.field_types) |name, T| {
            switch (@typeInfo(T)) {
                .optional => |o| @field(fns, name) = self.sym(o.child, name),
                else => @field(fns, name) = self.sym(T, name) orelse {
                    std.log.scoped(.zpui_audio).debug("audio: missing symbol {s}", .{name});
                    return null;
                },
            }
        }
        return fns;
    }
};

/// Producer-side lock for `Audio.play` from several threads. The audio
/// thread never takes it; it is held for a few dozen instructions.
pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

test "event signal/wait" {
    var ev: Event = .{};
    try ev.init();
    defer ev.deinit();
    try std.testing.expect(!ev.wait(1 * std.time.ns_per_ms));
    ev.signal();
    try std.testing.expect(ev.wait(100 * std.time.ns_per_ms));
    const t0 = nowNs();
    try std.testing.expect(!ev.wait(5 * std.time.ns_per_ms));
    try std.testing.expect(nowNs() - t0 >= 3 * std.time.ns_per_ms);
}
