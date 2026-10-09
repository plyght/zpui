//! Headless scroll benchmark: the bench fixture's long transcript (docs/BENCHMARKS.md,
//! 40 mock turns at ZERON_MOCK_REPEAT=6 with code, tables and the mend passage) scrolled
//! one 40 px wheel event per frame, 150 up then 150 down, as bench/run_bench.py does.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const view = @import("view.zig");
const bench_fixture = @import("bench_fixture.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const TestWindow = zpui.core.test_platform.TestWindow;

const Root = struct {
    tv: Entity(view.TranscriptView),

    pub fn deinit(self: *Root, app: *App) void {
        self.tv.release(app);
    }

    pub fn render(self: *Root, _: *zpui.Window, _: *Context(Root)) zpui.Div {
        return zpui.div().sizeFull().child(self.tv);
    }
};

pub const ScrollRun = struct {
    frames: usize,
    total_ns: u64,
    max_ns: u64,
    /// Text-system shaping calls (line layout cache misses) while scrolling.
    shaped: usize,
    rows: usize,
    presents: usize,
};

/// Open the long transcript at the tail and scroll it like the bench driver.
pub fn scrollBench(gpa: std.mem.Allocator, frames: usize) !ScrollRun {
    const app = try App.initTest(gpa);
    defer app.deinit();
    const engine = try app.newWith(model.EngineState, model.EngineState.init, .{ std.testing.io, model.engine_state.Config{
        .port = 1,
        .zeron_path = null,
        .reconnect = false,
        .autoconnect = false,
    } });
    defer engine.release(app);
    const store = try app.newWith(model.TranscriptStore, model.TranscriptStore.init, .{ engine, "chat-1" });
    defer store.release(app);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const json = try bench_fixture.benchTranscript(arena.allocator(), 40, 6);
    const entries = try view.parseFixture(arena.allocator(), json);
    try view.loadEntries(store, entries, app);

    const tv = try app.newWith(view.TranscriptView, view.TranscriptView.initWithStore, .{store});
    defer tv.release(app);
    const Init = struct {
        fn f(t: Entity(view.TranscriptView), _: *zpui.Window, _: *Context(Root)) Root {
            return .{ .tv = t };
        }
    };
    // The transcript column of the bench's 1024×674 window (sidebar open).
    const handle = try app.openWindow(.{ .bounds = .{ .origin = .zero, .size = .{ .width = 760, .height = 640 } } }, Root, Init.f, .{tv.retain(app)});
    const w = handle.window(app).?;
    w.prefers_reduced_motion = true;
    const tw = TestWindow.of(w.platform_window);
    app.runUntilParked();
    const vsync_ns: u64 = 16_666_667;
    for (0..30) |_| {
        app.advanceClock(vsync_ns);
        tw.frame(true);
    }

    const text = &app.test_platform.?.fake_text;
    const shaped_before = text.layout_calls;
    const presents_before = tw.present_count;
    var total: u64 = 0;
    var max: u64 = 0;
    for (0..frames) |i| {
        const dy: f32 = if (i < frames / 2) 40 else -40;
        const t0 = std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds;
        _ = tw.simulateInput(.{ .scroll_wheel = .{
            .position = .{ .x = 380, .y = 320 },
            .delta = .{ .pixels = .{ .x = 0, .y = dy } },
        } });
        app.advanceClock(vsync_ns);
        tw.frame(false);
        const dt: u64 = @intCast(std.Io.Timestamp.now(std.testing.io, .awake).nanoseconds - t0);
        total += dt;
        max = @max(max, dt);
    }
    return .{ .frames = frames, .total_ns = total, .max_ns = max, .shaped = text.layout_calls - shaped_before, .rows = tv.read(app).rowCount(), .presents = tw.present_count - presents_before };
}

test "scrolling the long transcript draws every frame and shapes only what scrolls in" {
    const run = try scrollBench(std.testing.allocator, 60);
    try std.testing.expectEqual(@as(usize, 2040), run.rows);
    try std.testing.expectEqual(run.frames, run.presents);
    // Lines already on screen come from the line layout cache; only rows scrolling
    // into the overdraw band shape (about one line per 40 px step).
    try std.testing.expect(run.shaped <= 2 * run.frames);
}
