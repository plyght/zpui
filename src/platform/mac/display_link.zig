//! Frame pacing for macOS windows on `CVDisplayLink` (port of zui
//! `gpui_macos/src/display_link.rs`).
//!
//! `CVDisplayLinkStop` returns before the link's io thread is done, so links
//! are never released: one immortal link per display lives in a static
//! registry, and the output callback's context is the display id (an integer),
//! so a straggler callback after `stop` only reads the registry. Each window
//! owns one `DISPATCH_SOURCE_TYPE_DATA_ADD` source targeting the main queue;
//! the io thread merges into it, GCD coalesces ticks, and the window's handler
//! runs on the main thread. A display's link runs iff it has subscribers.
//!
//! Lock ordering: never call CoreVideo while holding the registry lock (the
//! callback takes it while CoreVideo may hold internal locks). Registry
//! mutations and start/stop happen on the main thread only.

const std = @import("std");
const ak = @import("appkit.zig");

const log = std.log.scoped(.mac_display_link);

const max_displays = 16;
const max_subscribers = 128;

const DisplayEntry = struct {
    display_id: u32,
    link: ak.CVDisplayLinkRef,
    running: bool,
};

const Subscriber = struct {
    display_id: u32,
    source: ak.dispatch_source_t,
};

var lock: ak.UnfairLock = .{};
var displays: [max_displays]DisplayEntry = undefined;
var display_count: usize = 0;
var subscribers: [max_subscribers]?Subscriber = @splat(null);

fn outputCallback(
    _: ak.CVDisplayLinkRef,
    _: *const ak.CVTimeStamp,
    _: *const ak.CVTimeStamp,
    _: u64,
    _: *u64,
    context: ?*anyopaque,
) callconv(.c) ak.CVReturn {
    const display_id: u32 = @truncate(@intFromPtr(context));
    lock.lock();
    defer lock.unlock();
    for (subscribers) |maybe| {
        const sub = maybe orelse continue;
        if (sub.display_id == display_id) ak.dispatch_source_merge_data(sub.source, 1);
    }
    return 0;
}

fn findDisplay(display_id: u32) ?*DisplayEntry {
    for (displays[0..display_count]) |*e| if (e.display_id == display_id) return e;
    return null;
}

fn createLink(display_id: u32) !ak.CVDisplayLinkRef {
    var link: ?ak.CVDisplayLinkRef = null;
    var code = ak.CVDisplayLinkCreateWithActiveCGDisplays(&link);
    if (code != 0 or link == null) {
        log.err("CVDisplayLinkCreateWithActiveCGDisplays failed: {d}", .{code});
        return error.DisplayLinkFailed;
    }
    code = ak.CVDisplayLinkSetOutputCallback(link.?, outputCallback, @ptrFromInt(@as(usize, display_id)));
    if (code == 0) code = ak.CVDisplayLinkSetCurrentCGDisplay(link.?, display_id);
    if (code != 0) {
        // Never started, so no io thread exists: releasing is safe.
        ak.CVDisplayLinkRelease(link.?);
        log.err("could not configure display link for display {d}: {d}", .{ display_id, code });
        return error.DisplayLinkFailed;
    }
    return link.?;
}

/// Subscribe `source` to `display_id`'s vsync. Main thread only. Returns a subscriber slot.
fn subscribe(display_id: u32, source: ak.dispatch_source_t) !usize {
    lock.lock();
    const needs_link = findDisplay(display_id) == null;
    lock.unlock();

    const new_link: ?ak.CVDisplayLinkRef = if (needs_link) try createLink(display_id) else null;

    var link_to_start: ?ak.CVDisplayLinkRef = null;
    var slot: usize = undefined;
    {
        lock.lock();
        defer lock.unlock();
        const entry = findDisplay(display_id) orelse blk: {
            if (display_count == max_displays) return error.TooManyDisplays;
            displays[display_count] = .{ .display_id = display_id, .link = new_link.?, .running = false };
            display_count += 1;
            break :blk &displays[display_count - 1];
        };
        slot = for (subscribers, 0..) |s, i| {
            if (s == null) break i;
        } else return error.TooManySubscribers;
        subscribers[slot] = .{ .display_id = display_id, .source = source };
        if (!entry.running) {
            entry.running = true;
            link_to_start = entry.link;
        }
    }

    if (link_to_start) |link| {
        const code = ak.CVDisplayLinkStart(link);
        // A rapid idle stop/start can find CoreVideo still running; keep the subscriber then.
        if (code != 0 and ak.CVDisplayLinkIsRunning(link) == 0) {
            lock.lock();
            defer lock.unlock();
            if (findDisplay(display_id)) |e| e.running = false;
            subscribers[slot] = null;
            log.err("could not start display link: {d}", .{code});
            return error.DisplayLinkFailed;
        }
    }
    return slot;
}

fn unsubscribe(display_id: u32, slot: usize) void {
    var link_to_stop: ?ak.CVDisplayLinkRef = null;
    {
        lock.lock();
        defer lock.unlock();
        subscribers[slot] = null;
        const entry = findDisplay(display_id) orelse return;
        const any_left = for (subscribers) |s| {
            if (s != null and s.?.display_id == display_id) break true;
        } else false;
        if (!any_left and entry.running) {
            entry.running = false;
            link_to_stop = entry.link;
        }
    }
    if (link_to_stop) |link| {
        // A final output callback may still fire; it finds no subscribers.
        const code = ak.CVDisplayLinkStop(link);
        if (code != 0 and ak.CVDisplayLinkIsRunning(link) != 0) log.warn("could not stop display link: {d}", .{code});
    }
}

/// A per-window source of vsync ticks, delivered to `handler(context)` on the main queue.
pub const FrameSource = struct {
    source: ak.dispatch_source_t,
    registration: ?struct { display_id: u32, slot: usize } = null,

    pub fn init(context: *anyopaque, handler: ak.dispatch_function_t) !FrameSource {
        const source = ak.dispatch_source_create(ak.sourceTypeDataAdd(), 0, 0, ak.mainQueue()) orelse
            return error.DispatchSourceFailed;
        ak.dispatch_set_context(source, context);
        ak.dispatch_source_set_event_handler_f(source, handler);
        // Resume before it can ever be released: destroying a suspended source is UB.
        ak.dispatch_resume(source);
        return .{ .source = source };
    }

    pub fn isRunning(self: *const FrameSource) bool {
        return self.registration != null;
    }

    /// (Re)subscribe to `display_id`. Main thread only.
    pub fn start(self: *FrameSource, display_id: u32) !void {
        self.stop();
        const slot = try subscribe(display_id, self.source);
        self.registration = .{ .display_id = display_id, .slot = slot };
    }

    pub fn stop(self: *FrameSource) void {
        const reg = self.registration orelse return;
        self.registration = null;
        unsubscribe(reg.display_id, reg.slot);
    }

    /// Unsubscribe, cancel (the handler never runs again) and release.
    pub fn deinit(self: *FrameSource) void {
        self.stop();
        ak.dispatch_source_cancel(self.source);
        ak.dispatch_release(self.source);
        self.* = undefined;
    }
};

/// Restart is a no-op here: links are per display and immortal. After system
/// wake windows call `FrameSource.start` again, which re-runs `CVDisplayLinkStart`
/// only when the registry thinks the link is stopped; a link CoreVideo stopped
/// behind our back is recovered by forcing a stop/start cycle.
pub fn recoverAfterWake() void {
    var links: [max_displays]ak.CVDisplayLinkRef = undefined;
    var n: usize = 0;
    lock.lock();
    for (displays[0..display_count]) |e| if (e.running) {
        links[n] = e.link;
        n += 1;
    };
    lock.unlock();
    for (links[0..n]) |link| if (ak.CVDisplayLinkIsRunning(link) == 0) {
        _ = ak.CVDisplayLinkStart(link);
    };
}
