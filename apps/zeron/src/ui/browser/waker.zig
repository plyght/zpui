//! Bridges native callbacks (AppKit delegates, the WebKitGTK reader thread) to
//! the browser view on the main thread, coalesced: any number of `wake`s before
//! the main thread runs become one `target(app)` call. Never re-enters an
//! in-progress entity update (zeron uses a channel for the same reason).
//! Atomically refcounted: the owner holds one reference, each queued runnable another.

const std = @import("std");
const zpui = @import("zpui");

pub const Waker = struct {
    gpa: std.mem.Allocator,
    refs: std.atomic.Value(u32) = .init(1),
    pending: std.atomic.Value(bool) = .init(false),
    dispatcher: zpui.platform.Dispatcher,
    app: *zpui.App,
    /// Opaque target data (e.g. an entity id's bits).
    bits: u64,
    /// Main thread; never called after `disarm`.
    target: *const fn (bits: u64, app: *zpui.App) void,
    armed: std.atomic.Value(bool) = .init(true),

    pub fn create(gpa: std.mem.Allocator, app: *zpui.App, bits: u64, target: *const fn (u64, *zpui.App) void) !*Waker {
        const w = try gpa.create(Waker);
        w.* = .{ .gpa = gpa, .app = app, .dispatcher = app.platform.dispatcher(), .bits = bits, .target = target };
        return w;
    }

    pub fn retain(w: *Waker) void {
        _ = w.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(w: *Waker) void {
        if (w.refs.fetchSub(1, .acq_rel) == 1) w.gpa.destroy(w);
    }

    /// The owner is going away: pending runnables become no-ops.
    pub fn disarm(w: *Waker) void {
        w.armed.store(false, .release);
    }

    /// Any thread.
    pub fn wake(w: *Waker) void {
        if (!w.armed.load(.acquire)) return;
        if (w.pending.swap(true, .acq_rel)) return;
        w.retain();
        w.dispatcher.dispatchOnMainThread(.{ .ctx = w, .run = runMain, .drop = dropRun }, .high);
    }

    fn runMain(ctx: *anyopaque) void {
        const w: *Waker = @ptrCast(@alignCast(ctx));
        defer w.release();
        w.pending.store(false, .release);
        if (w.armed.load(.acquire)) w.target(w.bits, w.app);
    }

    fn dropRun(ctx: *anyopaque) void {
        const w: *Waker = @ptrCast(@alignCast(ctx));
        w.release();
    }
};
