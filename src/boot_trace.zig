//! Startup timeline hook. zpui marks the steps between process start and the first
//! present (platform launch, window creation, Metal device / library / pipelines);
//! an app that wants the timeline installs `hook` (zeron: `ZERON_BENCH=1`,
//! apps/zeron/src/bench.zig). Unset, a mark is one load and branch.

/// Called with a short phase name, on the thread that reached it.
pub var hook: ?*const fn (phase: []const u8) void = null;

pub inline fn mark(phase: []const u8) void {
    if (hook) |f| f(phase);
}
