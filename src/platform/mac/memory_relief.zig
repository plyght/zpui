//! Return the malloc zones' free pages to the OS once the app has gone idle.
//!
//! macOS malloc keeps freed large blocks (and emptied small regions) resident and dirty
//! for reuse, so they count in the phys_footprint Activity Monitor shows until memory
//! pressure. A window parking its display link (nothing to draw) schedules one
//! `malloc_zone_pressure_relief` on a utility queue a moment later, at most every
//! `min_interval_ns`; it frees nothing that is in use, so later allocations are
//! unaffected beyond refaulting the pages they touch.

const std = @import("std");
const ak = @import("appkit.zig");
const dispatcher = @import("dispatcher.zig");

extern "c" fn malloc_zone_pressure_relief(zone: ?*anyopaque, goal: usize) usize;

/// Quiet time after the park before relieving (a burst of activity usually follows soon).
const delay_ns: i64 = 2 * std.time.ns_per_s;
const min_interval_ns: u64 = 10 * std.time.ns_per_s;

var pending = std.atomic.Value(bool).init(false);
/// Main thread only (`schedule`).
var last_scheduled_ns: ?u64 = null;

/// Call on the main thread when the app has nothing left to draw.
pub fn schedule() void {
    const now = dispatcher.now();
    if (last_scheduled_ns) |last| if (now -% last < min_interval_ns) return;
    if (pending.swap(true, .acq_rel)) return;
    last_scheduled_ns = now;
    ak.dispatch_after_f(ak.dispatch_time(ak.DISPATCH_TIME_NOW, delay_ns), ak.dispatch_get_global_queue(ak.QOS_CLASS_UTILITY, 0), null, &run);
}

fn run(_: ?*anyopaque) callconv(.c) void {
    _ = malloc_zone_pressure_relief(null, 0); // all zones, everything free
    pending.store(false, .release);
}
