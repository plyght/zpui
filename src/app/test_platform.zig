//! Headless, deterministic platform for core tests (gpui `TestDispatcher` + `TestPlatform`).
//!
//! Nothing runs until the test drives the loop:
//! * `runUntilParked()` runs queued main-thread and "background" runnables (all on the
//!   calling thread, FIFO, foreground first) until nothing is ready.
//! * `advanceClock(ns)` moves the fake clock, fires due timers in deadline order, then parks.
//!
//! `isMainThread()` is always true. Windows are not supported yet (`openWindow` errors).

const std = @import("std");
const pf = @import("../platform/platform.zig");
const geometry = @import("../geometry.zig");
const Allocator = std.mem.Allocator;
const Runnable = pf.Runnable;
const Priority = pf.Priority;

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
        r.run(r.ctx);
        return true;
    }

    pub fn runUntilParked(self: *TestDispatcher) void {
        while (self.tick()) {}
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

/// Headless `pf.Platform`. Owns a `TestDispatcher`.
pub const TestPlatform = struct {
    gpa: Allocator,
    test_dispatcher: TestDispatcher,
    clipboard: ?[]u8 = null,
    quit_requested: bool = false,
    cursor: pf.CursorStyle = .arrow,
    callbacks: pf.PlatformCallbacks = .{},
    opened_urls: usize = 0,

    pub fn create(gpa: Allocator) Allocator.Error!*TestPlatform {
        const self = try gpa.create(TestPlatform);
        self.* = .{ .gpa = gpa, .test_dispatcher = .init(gpa) };
        return self;
    }

    pub fn destroy(self: *TestPlatform) void {
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
    fn vTextSystem(_: *anyopaque) pf.TextSystem {
        return NullTextSystem.textSystem();
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
    fn vOpenWindow(_: *anyopaque, _: pf.WindowParams) anyerror!pf.Window {
        return error.Unsupported;
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
    fn vPrefersReducedMotion(_: *anyopaque) bool {
        return false;
    }
    fn vDeinit(ptr: *anyopaque) void {
        cast(ptr).destroy();
    }
};

/// Text system stub: every query fails or returns zeroes.
const NullTextSystem = struct {
    const text = pf.text;
    var dummy: u8 = 0;

    fn textSystem() pf.TextSystem {
        return .{ .ptr = &dummy, .vtable = &vtable };
    }

    const vtable: pf.TextSystem.VTable = .{
        .addFont = addFont,
        .fontId = fontId,
        .fontMetrics = fontMetrics,
        .glyphForChar = glyphForChar,
        .advance = advance,
        .glyphRasterBounds = glyphRasterBounds,
        .rasterizeGlyph = rasterizeGlyph,
        .layoutLine = layoutLine,
    };

    fn addFont(_: *anyopaque, _: []const u8) anyerror!void {
        return error.Unsupported;
    }
    fn fontId(_: *anyopaque, _: text.Font) anyerror!text.FontId {
        return error.Unsupported;
    }
    fn fontMetrics(_: *anyopaque, _: text.FontId) text.FontMetrics {
        return std.mem.zeroes(text.FontMetrics);
    }
    fn glyphForChar(_: *anyopaque, _: text.FontId, _: u21) ?text.GlyphId {
        return null;
    }
    fn advance(_: *anyopaque, _: text.FontId, _: text.GlyphId) geometry.Size(f32) {
        return .{ .width = 0, .height = 0 };
    }
    fn glyphRasterBounds(_: *anyopaque, _: text.RenderGlyphParams) anyerror!geometry.Bounds(pf.DevicePixels) {
        return error.Unsupported;
    }
    fn rasterizeGlyph(_: *anyopaque, _: Allocator, _: text.RenderGlyphParams, _: geometry.Bounds(pf.DevicePixels)) anyerror![]u8 {
        return error.Unsupported;
    }
    fn layoutLine(_: *anyopaque, _: Allocator, _: []const u8, _: pf.Pixels, _: []const text.FontRun) anyerror!text.LineLayout {
        return error.Unsupported;
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
