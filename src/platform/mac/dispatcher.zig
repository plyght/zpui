//! `platform.Dispatcher` on Grand Central Dispatch (zui `gpui_macos/src/dispatcher.rs`).
//!
//! Background work goes to the global concurrent queue whose QoS matches the
//! priority; main-thread work and timers go to the main queue, which the
//! NSApplication run loop drains. Each `Runnable` is boxed (malloc) because GCD
//! carries a single context pointer.

const std = @import("std");
const platform = @import("../platform.zig");
const ak = @import("appkit.zig");
const objc = @import("objc.zig");

const Runnable = platform.Runnable;
const Priority = platform.Priority;
const box_allocator = std.heap.c_allocator;

pub const MacDispatcher = struct {
    pub fn dispatcher(self: *MacDispatcher) platform.Dispatcher {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: platform.Dispatcher.VTable = .{
        .isMainThread = isMainThreadImpl,
        .dispatch = dispatchImpl,
        .dispatchOnMainThread = dispatchOnMainThreadImpl,
        .dispatchAfter = dispatchAfterImpl,
        .now = nowImpl,
    };
};

pub fn isMainThread() bool {
    return ak.pthread_main_np() != 0;
}

pub fn now() u64 {
    return ak.clock_gettime_nsec_np(ak.CLOCK_UPTIME_RAW);
}

/// QoS class for a priority (zui maps High/Medium/Low to the high/default/low
/// global queues, which correspond to these QoS classes).
pub fn qosForPriority(p: Priority) isize {
    return switch (p) {
        .realtime => ak.QOS_CLASS_USER_INTERACTIVE,
        .high => ak.QOS_CLASS_USER_INITIATED,
        .medium => ak.QOS_CLASS_DEFAULT,
        .low => ak.QOS_CLASS_UTILITY,
    };
}

fn box(r: Runnable) ?*Runnable {
    const b = box_allocator.create(Runnable) catch {
        // Out of memory: honour the contract by dropping rather than running inline on the wrong thread.
        if (r.drop) |d| d(r.ctx);
        return null;
    };
    b.* = r;
    return b;
}

fn trampoline(ctx: ?*anyopaque) callconv(.c) void {
    const b: *Runnable = @ptrCast(@alignCast(ctx.?));
    const r = b.*;
    box_allocator.destroy(b);
    const pool = objc.AutoreleasePool.push();
    defer pool.pop();
    r.run(r.ctx);
}

fn isMainThreadImpl(_: *anyopaque) bool {
    return isMainThread();
}

fn dispatchImpl(_: *anyopaque, r: Runnable, p: Priority) void {
    const b = box(r) orelse return;
    ak.dispatch_async_f(ak.dispatch_get_global_queue(qosForPriority(p), 0), b, trampoline);
}

fn dispatchOnMainThreadImpl(_: *anyopaque, r: Runnable, _: Priority) void {
    const b = box(r) orelse return;
    ak.dispatch_async_f(ak.mainQueue(), b, trampoline);
}

fn dispatchAfterImpl(_: *anyopaque, delay_ns: u64, r: Runnable) void {
    const b = box(r) orelse return;
    const delta: i64 = @intCast(@min(delay_ns, std.math.maxInt(i64)));
    ak.dispatch_after_f(ak.dispatch_time(ak.DISPATCH_TIME_NOW, delta), ak.mainQueue(), b, trampoline);
}

fn nowImpl(_: *anyopaque) u64 {
    return now();
}

/// Run `func(ctx)` on the main queue (fire-and-forget helper for the backend).
pub fn onMain(ctx: ?*anyopaque, func: ak.dispatch_function_t) void {
    ak.dispatch_async_f(ak.mainQueue(), ctx, func);
}

/// Run `func(ctx)` on the main queue after `delay_ns`.
pub fn onMainAfter(delay_ns: u64, ctx: ?*anyopaque, func: ak.dispatch_function_t) void {
    ak.dispatch_after_f(ak.dispatch_time(ak.DISPATCH_TIME_NOW, @intCast(delay_ns)), ak.mainQueue(), ctx, func);
}
