//! Headless, deterministic platform for core tests (gpui `TestDispatcher` + `TestPlatform`).
//!
//! Nothing runs until the test drives the loop:
//! * `runUntilParked()` runs queued main-thread and "background" runnables (all on the
//!   calling thread, FIFO, foreground first) until nothing is ready.
//! * `advanceClock(ns)` moves the fake clock, fires due timers in deadline order, then parks.
//!
//! `isMainThread()` is always true. `openWindow` returns a headless `TestWindow` that records
//! presented scenes and lets tests inject input; the text system is the deterministic fake
//! from `text/test_platform.zig` (10px advances at 16px).

const std = @import("std");
const pf = @import("../platform/platform.zig");
const geometry = @import("../geometry.zig");
const Allocator = std.mem.Allocator;
const Runnable = pf.Runnable;
const Priority = pf.Priority;
const scene_mod = @import("../scene.zig");
const atlas_mod = @import("../atlas.zig");
const input = @import("../input.zig");
const FakeTextSystem = @import("../text/test_platform.zig");

pub const TestDispatcher = struct {
    gpa: Allocator,
    foreground: std.Deque(Runnable) = .empty,
    background: std.Deque(Runnable) = .empty,
    timers: std.ArrayList(Timer) = .empty,
    now_ns: u64 = 0,
    timer_seq: u64 = 0,
    /// Number of runnables executed so far (handy in tests).
    ran: usize = 0,

    const Timer = struct { deadline: u64, seq: u64, runnable: Runnable };

    pub fn init(gpa: Allocator) TestDispatcher {
        return .{ .gpa = gpa };
    }

    /// Drops (does not run) everything still queued.
    pub fn deinit(self: *TestDispatcher) void {
        while (self.foreground.popFront()) |r| dropRunnable(r);
        while (self.background.popFront()) |r| dropRunnable(r);
        for (self.timers.items) |t| dropRunnable(t.runnable);
        self.foreground.deinit(self.gpa);
        self.background.deinit(self.gpa);
        self.timers.deinit(self.gpa);
    }

    fn dropRunnable(r: Runnable) void {
        if (r.drop) |d| d(r.ctx);
    }

    pub fn dispatcher(self: *TestDispatcher) pf.Dispatcher {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: pf.Dispatcher.VTable = .{
        .isMainThread = isMainThread,
        .dispatch = dispatch,
        .dispatchOnMainThread = dispatchOnMainThread,
        .dispatchAfter = dispatchAfter,
        .now = now,
    };

    fn cast(ptr: *anyopaque) *TestDispatcher {
        return @ptrCast(@alignCast(ptr));
    }
    fn isMainThread(_: *anyopaque) bool {
        return true;
    }
    fn dispatch(ptr: *anyopaque, r: Runnable, _: Priority) void {
        const self = cast(ptr);
        self.background.pushBack(self.gpa, r) catch @panic("OOM");
    }
    fn dispatchOnMainThread(ptr: *anyopaque, r: Runnable, _: Priority) void {
        const self = cast(ptr);
        self.foreground.pushBack(self.gpa, r) catch @panic("OOM");
    }
    fn dispatchAfter(ptr: *anyopaque, delay_ns: u64, r: Runnable) void {
        const self = cast(ptr);
        self.timer_seq += 1;
        self.timers.append(self.gpa, .{ .deadline = self.now_ns +| delay_ns, .seq = self.timer_seq, .runnable = r }) catch @panic("OOM");
    }
    fn now(ptr: *anyopaque) u64 {
        return cast(ptr).now_ns;
    }

    /// Run one ready runnable. Returns false if none was ready.
    pub fn tick(self: *TestDispatcher) bool {
        const r = self.foreground.popFront() orelse self.background.popFront() orelse return false;
        self.ran += 1;
        watchdog.enter();
        defer watchdog.exit();
        r.run(r.ctx);
        return true;
    }

    /// `runUntilParked` gives up (panics) after this many runnables without parking:
    /// something keeps re-queuing work (a livelock), which would otherwise spin forever.
    pub const max_ticks_per_park: usize = 1_000_000;

    pub fn runUntilParked(self: *TestDispatcher) void {
        var n: usize = 0;
        while (self.tick()) {
            n += 1;
            if (n >= max_ticks_per_park) std.debug.panic("TestDispatcher.runUntilParked: still not parked after {d} runnables (a runnable keeps re-queuing work?)", .{n});
        }
    }

    pub fn isParked(self: *const TestDispatcher) bool {
        return self.foreground.len == 0 and self.background.len == 0;
    }

    pub fn pendingTimers(self: *const TestDispatcher) usize {
        return self.timers.items.len;
    }

    /// Advance the fake clock, firing timers whose deadline passed (in order), parking after each.
    pub fn advanceClock(self: *TestDispatcher, delta_ns: u64) void {
        const target = self.now_ns +| delta_ns;
        while (self.popDueTimer(target)) |t| {
            self.now_ns = @max(self.now_ns, t.deadline);
            self.foreground.pushBack(self.gpa, t.runnable) catch @panic("OOM");
            self.runUntilParked();
        }
        self.now_ns = target;
        self.runUntilParked();
    }

    fn popDueTimer(self: *TestDispatcher, target: u64) ?Timer {
        var best: ?usize = null;
        for (self.timers.items, 0..) |t, i| {
            if (t.deadline > target) continue;
            if (best) |b| {
                const bt = self.timers.items[b];
                if (t.deadline < bt.deadline or (t.deadline == bt.deadline and t.seq < bt.seq)) best = i;
            } else best = i;
        }
        const i = best orelse return null;
        return self.timers.orderedRemove(i);
    }
};

/// Hang guard for runnables executed by `TestDispatcher`: everything runs on the test
/// thread, so a job that blocks (a socket read, a lock, a child process) would hang the
/// whole test binary silently. A lazily started watcher thread aborts the process with a
/// message once a single runnable has been running for `limit_s` seconds (default 120,
/// `ZPUI_TEST_WATCHDOG_S` overrides, 0 disables).
pub const watchdog = struct {
    var started = std.atomic.Value(bool).init(false);
    var depth: u32 = 0; // test-thread only
    /// Monotonic ns at which the outermost runnable started; 0 = idle.
    var busy_since = std.atomic.Value(u64).init(0);
    var limit_ns: u64 = 120 * std.time.ns_per_s;

    fn monotonic() u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    fn start() void {
        if (started.swap(true, .acq_rel)) return;
        if (std.c.getenv("ZPUI_TEST_WATCHDOG_S")) |v| {
            const secs = std.fmt.parseInt(u64, std.mem.span(v), 10) catch 120;
            limit_ns = secs * std.time.ns_per_s;
        }
        if (limit_ns == 0) return;
        const t = std.Thread.spawn(.{}, watch, .{}) catch return;
        t.detach();
    }

    fn watch() void {
        while (true) {
            const ts: std.c.timespec = .{ .sec = 1, .nsec = 0 };
            _ = std.c.nanosleep(&ts, null);
            const since = busy_since.load(.acquire);
            if (since != 0 and monotonic() -| since > limit_ns) {
                std.debug.print("\nzpui TestDispatcher watchdog: a runnable has been running for over {d}s " ++
                    "without returning (blocked on I/O, a lock or a child process?); aborting.\n", .{limit_ns / std.time.ns_per_s});
                std.process.abort();
            }
        }
    }

    pub fn enter() void {
        start();
        depth += 1;
        if (depth == 1) busy_since.store(@max(monotonic(), 1), .release);
    }

    pub fn exit() void {
        depth -= 1;
        if (depth == 0) busy_since.store(0, .release);
    }
};

/// Headless `pf.Platform`. Owns a `TestDispatcher`.
pub const TestPlatform = struct {
    gpa: Allocator,
    test_dispatcher: TestDispatcher,
    clipboard: ?[]u8 = null,
    quit_requested: bool = false,
    cursor: pf.CursorStyle = .arrow,
    callbacks: pf.PlatformCallbacks = .{},
    opened_urls: usize = 0,
    fake_text: FakeTextSystem,
    /// Open test windows (most recent last).
    windows: std.ArrayList(*TestWindow) = .empty,
    /// Reported by `prefersReducedMotion`.
    reduced_motion: bool = false,

    pub fn create(gpa: Allocator) Allocator.Error!*TestPlatform {
        const self = try gpa.create(TestPlatform);
        self.* = .{ .gpa = gpa, .test_dispatcher = .init(gpa), .fake_text = .init(gpa) };
        return self;
    }

    pub fn destroy(self: *TestPlatform) void {
        while (self.windows.pop()) |w| w.free();
        self.windows.deinit(self.gpa);
        self.fake_text.deinit();
        self.test_dispatcher.deinit();
        if (self.clipboard) |c| self.gpa.free(c);
        self.gpa.destroy(self);
    }

    pub fn platform(self: *TestPlatform) pf.Platform {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn dispatcher(self: *TestPlatform) *TestDispatcher {
        return &self.test_dispatcher;
    }

    pub fn runUntilParked(self: *TestPlatform) void {
        self.test_dispatcher.runUntilParked();
    }

    pub fn advanceClock(self: *TestPlatform, delta_ns: u64) void {
        self.test_dispatcher.advanceClock(delta_ns);
    }

    fn cast(ptr: *anyopaque) *TestPlatform {
        return @ptrCast(@alignCast(ptr));
    }

    const vtable: pf.Platform.VTable = .{
        .dispatcher = vDispatcher,
        .textSystem = vTextSystem,
        .setCallbacks = vSetCallbacks,
        .run = vRun,
        .quit = vQuit,
        .activate = vActivate,
        .openWindow = vOpenWindow,
        .displays = vDisplays,
        .windowAppearance = vWindowAppearance,
        .setCursorStyle = vSetCursorStyle,
        .writeClipboard = vWriteClipboard,
        .readClipboard = vReadClipboard,
        .openUrl = vOpenUrl,
        .revealPath = vRevealPath,
        .prefersReducedMotion = vPrefersReducedMotion,
        .deinit = vDeinit,
    };

    fn vDispatcher(ptr: *anyopaque) pf.Dispatcher {
        return cast(ptr).test_dispatcher.dispatcher();
    }
    fn vTextSystem(ptr: *anyopaque) pf.TextSystem {
        return cast(ptr).fake_text.textSystem();
    }
    fn vSetCallbacks(ptr: *anyopaque, cbs: pf.PlatformCallbacks) void {
        cast(ptr).callbacks = cbs;
    }
    fn vRun(ptr: *anyopaque, on_launch: pf.Callback(void, void)) void {
        const self = cast(ptr);
        _ = on_launch.call({});
        self.test_dispatcher.runUntilParked();
    }
    fn vQuit(ptr: *anyopaque) void {
        cast(ptr).quit_requested = true;
    }
    fn vActivate(_: *anyopaque, _: bool) void {}
    fn vOpenWindow(ptr: *anyopaque, params: pf.WindowParams) anyerror!pf.Window {
        const self = cast(ptr);
        const w = try self.gpa.create(TestWindow);
        w.* = .{ .platform = self, .bounds = params.bounds, .size = params.bounds.size, .atlas = .init(self.gpa, .{}), .title = "" };
        try self.windows.append(self.gpa, w);
        return w.window();
    }
    fn vDisplays(_: *anyopaque, out: []pf.Display) usize {
        if (out.len == 0) return 0;
        const b: pf.Bounds = .{ .origin = .zero, .size = .{ .width = 1920, .height = 1080 } };
        out[0] = .{ .id = 1, .bounds = b, .visible_bounds = b, .scale_factor = 1 };
        return 1;
    }
    fn vWindowAppearance(_: *anyopaque) pf.WindowAppearance {
        return .light;
    }
    fn vSetCursorStyle(ptr: *anyopaque, style: pf.CursorStyle) void {
        cast(ptr).cursor = style;
    }
    fn vWriteClipboard(ptr: *anyopaque, text: []const u8) void {
        const self = cast(ptr);
        const copy = self.gpa.dupe(u8, text) catch return;
        if (self.clipboard) |c| self.gpa.free(c);
        self.clipboard = copy;
    }
    fn vReadClipboard(ptr: *anyopaque, gpa: Allocator) ?[]u8 {
        const c = cast(ptr).clipboard orelse return null;
        return gpa.dupe(u8, c) catch null;
    }
    fn vOpenUrl(ptr: *anyopaque, _: []const u8) void {
        cast(ptr).opened_urls += 1;
    }
    fn vRevealPath(_: *anyopaque, _: []const u8) void {}
    fn vPrefersReducedMotion(ptr: *anyopaque) bool {
        return cast(ptr).reduced_motion;
    }
    fn vDeinit(ptr: *anyopaque) void {
        cast(ptr).destroy();
    }
};

/// Headless `pf.Window` for tests: records presented scenes, holds its own sprite atlas and
/// lets tests inject input (`simulateInput`, `click`, `moveMouse`, `typeKey`) and resizes.
pub const TestWindow = struct {
    platform: *TestPlatform,
    callbacks: pf.WindowCallbacks = .{},
    bounds: pf.Bounds,
    size: pf.Size,
    scale: f32 = 1,
    atlas: atlas_mod.Atlas,
    title: []const u8,
    input_handler: ?pf.InputHandler = null,
    active: bool = true,
    hovered: bool = true,
    /// Starts outside the window so nothing is hovered until the test moves the mouse.
    mouse: pf.Point = .{ .x = -10000, .y = -10000 },
    modifiers: input.Modifiers = .{},
    background: pf.WindowBackgroundAppearance = .opaque_,
    /// Set by `requestFrame`, cleared by `frame`.
    frame_requested: bool = false,
    /// Number of `draw` (present) calls and the last presented scene (owned by the core).
    present_count: usize = 0,
    last_scene: ?*const scene_mod.Scene = null,
    closed: bool = false,
    title_buf: [128]u8 = undefined,

    pub fn window(self: *TestWindow) pf.Window {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The TestWindow behind a core window's platform window.
    pub fn of(platform_window: pf.Window) *TestWindow {
        std.debug.assert(platform_window.vtable == &vtable);
        return @ptrCast(@alignCast(platform_window.ptr));
    }

    fn free(self: *TestWindow) void {
        self.atlas.deinit();
        self.platform.gpa.destroy(self);
    }

    /// Deliver an input event like the OS would; unhandled printable keys go to the input
    /// handler as text (mirrors the Linux backend).
    pub fn simulateInput(self: *TestWindow, event: input.PlatformInput) pf.DispatchEventResult {
        switch (event) {
            .mouse_move => |e| self.mouse = e.position,
            .mouse_down => |e| self.mouse = e.position,
            .mouse_up => |e| self.mouse = e.position,
            else => {},
        }
        const f = self.callbacks.input orelse return .{};
        const r = f(self.callbacks.ctx, event);
        if (r.propagate) switch (event) {
            .key_down => |kd| if (kd.keystroke.key_char) |ch| if (self.input_handler) |h| {
                const m = kd.keystroke.modifiers;
                if (!m.control and !m.alt and !m.platform) h.vtable.replaceTextInRange(h.ptr, null, ch);
            },
            else => {},
        };
        return r;
    }

    pub fn moveMouse(self: *TestWindow, x: f32, y: f32) void {
        _ = self.simulateInput(.{ .mouse_move = .{ .position = .{ .x = x, .y = y } } });
    }

    /// Mouse down + up at (x, y) with the left button.
    pub fn click(self: *TestWindow, x: f32, y: f32) void {
        self.moveMouse(x, y);
        _ = self.simulateInput(.{ .mouse_down = .{ .button = .left, .position = .{ .x = x, .y = y } } });
        _ = self.simulateInput(.{ .mouse_up = .{ .button = .left, .position = .{ .x = x, .y = y } } });
    }

    /// Key down + up for a keystroke like "cmd-s" or "a" (parsed with the core keymap parser).
    pub fn typeKey(self: *TestWindow, keystroke: []const u8) void {
        const keymap = @import("keymap.zig");
        const ks = keymap.parseKeystroke(self.platform.gpa, keystroke) catch @panic("bad keystroke");
        defer keymap.freeKeystroke(self.platform.gpa, ks);
        _ = self.simulateInput(.{ .key_down = .{ .keystroke = ks } });
        _ = self.simulateInput(.{ .key_up = .{ .keystroke = ks } });
    }

    pub fn simulateResize(self: *TestWindow, size: pf.Size, scale: f32) void {
        self.size = size;
        self.scale = scale;
        if (self.callbacks.resize) |f| f(self.callbacks.ctx, size, scale);
    }

    /// Run a frame callback like a vsync tick would.
    pub fn frame(self: *TestWindow, force: bool) void {
        self.frame_requested = false;
        if (self.callbacks.request_frame) |f| f(self.callbacks.ctx, force);
    }

    /// Simulate the OS closing the window.
    pub fn simulateClose(self: *TestWindow) void {
        vClose(self);
    }

    const vtable: pf.Window.VTable = .{
        .setCallbacks = vSetCallbacks,
        .bounds = vBounds,
        .contentSize = vContentSize,
        .resize = vResize,
        .scaleFactor = vScale,
        .appearance = vAppearance,
        .mousePosition = vMouse,
        .modifiers = vModifiers,
        .isActive = vIsActive,
        .isHovered = vIsHovered,
        .isFullscreen = vFalse,
        .isMaximized = vFalse,
        .setInputHandler = vSetInputHandler,
        .setTitle = vSetTitle,
        .setBackgroundAppearance = vSetBackground,
        .activate = vNoop,
        .minimize = vNoop,
        .zoom = vNoop,
        .toggleFullscreen = vNoop,
        .startWindowMove = vNoop,
        .startWindowResize = vStartResize,
        .setClientInset = vSetClientInset,
        .requestFrame = vRequestFrame,
        .draw = vDraw,
        .spriteAtlas = vAtlas,
        .updateImePosition = vIme,
        .close = vClose,
    };

    fn c(ptr: *anyopaque) *TestWindow {
        return @ptrCast(@alignCast(ptr));
    }
    fn vSetCallbacks(ptr: *anyopaque, cbs: pf.WindowCallbacks) void {
        c(ptr).callbacks = cbs;
    }
    fn vBounds(ptr: *anyopaque) pf.Bounds {
        return c(ptr).bounds;
    }
    fn vContentSize(ptr: *anyopaque) pf.Size {
        return c(ptr).size;
    }
    fn vResize(ptr: *anyopaque, size: pf.Size) void {
        const self = c(ptr);
        self.simulateResize(size, self.scale);
    }
    fn vScale(ptr: *anyopaque) f32 {
        return c(ptr).scale;
    }
    fn vAppearance(_: *anyopaque) pf.WindowAppearance {
        return .light;
    }
    fn vMouse(ptr: *anyopaque) pf.Point {
        return c(ptr).mouse;
    }
    fn vModifiers(ptr: *anyopaque) input.Modifiers {
        return c(ptr).modifiers;
    }
    fn vIsActive(ptr: *anyopaque) bool {
        return c(ptr).active;
    }
    fn vIsHovered(ptr: *anyopaque) bool {
        return c(ptr).hovered;
    }
    fn vFalse(_: *anyopaque) bool {
        return false;
    }
    fn vSetInputHandler(ptr: *anyopaque, h: ?pf.InputHandler) void {
        c(ptr).input_handler = h;
    }
    fn vSetTitle(ptr: *anyopaque, title: []const u8) void {
        const self = c(ptr);
        const n = @min(title.len, self.title_buf.len);
        @memcpy(self.title_buf[0..n], title[0..n]);
        self.title = self.title_buf[0..n];
    }
    fn vSetBackground(ptr: *anyopaque, bg: pf.WindowBackgroundAppearance) void {
        c(ptr).background = bg;
    }
    fn vNoop(_: *anyopaque) void {}
    fn vStartResize(_: *anyopaque, _: pf.ResizeEdge) void {}
    fn vSetClientInset(_: *anyopaque, _: pf.Pixels) void {}
    fn vRequestFrame(ptr: *anyopaque) void {
        c(ptr).frame_requested = true;
    }
    fn vDraw(ptr: *anyopaque, scene: *const scene_mod.Scene) anyerror!void {
        const self = c(ptr);
        self.present_count += 1;
        self.last_scene = scene;
        self.atlas.clearUploads();
    }
    fn vAtlas(ptr: *anyopaque) *atlas_mod.Atlas {
        return &c(ptr).atlas;
    }
    fn vIme(_: *anyopaque, _: pf.Bounds) void {}
    fn vClose(ptr: *anyopaque) void {
        const self = c(ptr);
        if (self.closed) return;
        self.closed = true;
        if (self.callbacks.close) |f| f(self.callbacks.ctx);
        const p = self.platform;
        for (p.windows.items, 0..) |w, i| if (w == self) {
            _ = p.windows.orderedRemove(i);
            break;
        };
        self.free();
    }
};

test "TestDispatcher runs foreground before background, FIFO" {
    var d = TestDispatcher.init(std.testing.allocator);
    defer d.deinit();
    const Log = struct {
        var buf: [8]u8 = undefined;
        var len: usize = 0;
        fn mk(comptime c: u8) *const fn (*anyopaque) void {
            return struct {
                fn f(_: *anyopaque) void {
                    buf[len] = c;
                    len += 1;
                }
            }.f;
        }
    };
    Log.len = 0;
    var x: u8 = 0;
    const disp = d.dispatcher();
    disp.dispatch(.{ .ctx = &x, .run = Log.mk('b') }, .medium);
    disp.dispatchOnMainThread(.{ .ctx = &x, .run = Log.mk('f') }, .medium);
    disp.dispatchAfter(100, .{ .ctx = &x, .run = Log.mk('2') });
    disp.dispatchAfter(50, .{ .ctx = &x, .run = Log.mk('1') });
    d.runUntilParked();
    try std.testing.expectEqualStrings("fb", Log.buf[0..Log.len]);
    d.advanceClock(60);
    try std.testing.expectEqualStrings("fb1", Log.buf[0..Log.len]);
    try std.testing.expectEqual(@as(u64, 60), disp.now());
    d.advanceClock(40);
    try std.testing.expectEqualStrings("fb12", Log.buf[0..Log.len]);
}

test "TestDispatcher hang watchdog brackets each runnable, including nested parks" {
    var d = TestDispatcher.init(std.testing.allocator);
    defer d.deinit();
    const Probe = struct {
        var seen_busy: bool = false;
        var inner: ?*TestDispatcher = null;
        fn outer(_: *anyopaque) void {
            seen_busy = watchdog.busy_since.load(.acquire) != 0;
            // A runnable that parks again (as App.runUntilParked from a job would).
            var y: u8 = 0;
            inner.?.dispatcher().dispatchOnMainThread(.{ .ctx = &y, .run = nested }, .medium);
            inner.?.runUntilParked();
            seen_busy = seen_busy and watchdog.busy_since.load(.acquire) != 0;
        }
        fn nested(_: *anyopaque) void {}
    };
    Probe.inner = &d;
    var x: u8 = 0;
    d.dispatcher().dispatch(.{ .ctx = &x, .run = Probe.outer }, .medium);
    d.runUntilParked();
    try std.testing.expect(Probe.seen_busy);
    try std.testing.expectEqual(@as(u64, 0), watchdog.busy_since.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), watchdog.depth);
}
