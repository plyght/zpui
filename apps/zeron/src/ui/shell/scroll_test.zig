//! Scrolling a long transcript in the full shell (the CI benchmark's scroll phase,
//! docs/BENCHMARKS.md): 150 chats in the sidebar, the bench's long chat open, one
//! 40 px wheel event per frame over the transcript in a 1024×674 window.
//! Headless, on zpui's TestPlatform with no engine.

const std = @import("std");
const zpui = @import("zpui");
const zt = @import("zeron_theme");
const model = @import("zeron_model");
const actions = @import("zeron_actions");
const transcript_ui = @import("zeron_ui_transcript");
const ui = @import("../components/root.zig");
const prefs_mod = @import("prefs.zig");
const shell_mod = @import("shell.zig");
const fixtures_mod = @import("fixtures.zig");
const sidebar_mod = @import("../sidebar/sidebar.zig");

const testing = std.testing;
const App = zpui.App;
const TestWindow = zpui.core.test_platform.TestWindow;

pub const ScrollRun = struct {
    frames: usize,
    total_ns: u64,
    sidebar_renders: usize,
    presents: usize,
    rows: usize,
};

/// The scroll phase alone (a profiler can collect just this: `--toggle-collect=*scrollFrames`).
fn scrollFrames(app: *App, tw: *TestWindow, frames: usize) u64 {
    const io = testing.io;
    const vsync_ns: u64 = 16_666_667;
    var total: u64 = 0;
    for (0..frames) |i| {
        const dy: f32 = if (i < frames / 2) 40 else -40;
        const t0 = std.Io.Timestamp.now(io, .awake).nanoseconds;
        _ = tw.simulateInput(.{ .scroll_wheel = .{
            .position = .{ .x = 800, .y = 420 },
            .delta = .{ .pixels = .{ .x = 0, .y = dy } },
        } });
        app.advanceClock(vsync_ns);
        tw.frame(false);
        total += @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds - t0);
    }
    return total;
}

pub fn scrollShell(gpa: std.mem.Allocator, frames: usize) !ScrollRun {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    {
        var out: std.Io.Writer.Allocating = .init(a);
        try out.writer.writeAll("[");
        for (0..150) |i| {
            if (i > 0) try out.writer.writeAll(",");
            try out.writer.print("{{\"id\":\"c{d}\",\"deviceId\":\"dev\",\"title\":\"Bench chat {d}: sidebar truncation\",\"archived\":false,\"createdAt\":\"2026-01-01T00:00:00Z\",\"spaceId\":\"sp\",\"branch\":\"main\",\"lastMessagePreview\":\"Mock harness reporting in.\",\"lastMessageAt\":\"2026-02-01T{d:0>2}:{d:0>2}:00Z\"}}", .{ i, i, 23 - i / 60, 59 - i % 60 });
        }
        try out.writer.writeAll("]");
        try tmp.dir.writeFile(io, .{ .sub_path = "chats.json", .data = out.written() });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "spaces.json", .data = "[{\"id\":\"sp\",\"deviceId\":\"dev\",\"path\":\"/w/app\",\"createdAt\":\"2026-01-01T00:00:00Z\"}]" });
    try tmp.dir.writeFile(io, .{ .sub_path = "meta.json", .data = "{\"now\":\"2026-02-02T00:00:00Z\",\"localDeviceId\":\"dev\",\"selectedChat\":\"c0\"}" });
    try tmp.dir.createDirPath(io, "transcripts");
    try tmp.dir.writeFile(io, .{ .sub_path = "transcripts/c0.json", .data = try transcript_ui.bench_fixture.benchTranscript(a, 40, 6) });
    const dir = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    const app = try App.initTest(gpa);
    defer app.deinit();
    try actions.registerAll(app);
    try actions.keymap.applyKeymap(app, &.{}, .enter);
    const f = try fixtures_mod.load(gpa, io, dir);
    defer {
        f.deinit();
        gpa.destroy(f);
    }
    var prefs: prefs_mod.Prefs = .{ .gpa = gpa };
    fixtures_mod.applyPrefs(f, &prefs);
    try ui.theme.install(app, zt.Theme.dark());
    try prefs_mod.install(app, prefs);
    const state = try app.newWith(model.AppState, model.AppState.init, .{ io, model.engine_state.Config{ .port = 1, .zeron_path = null, .reconnect = false, .autoconnect = false, .wake_mode = .poll } });
    defer state.release(app);
    fixtures_mod.applyToState(f, io, app, state);
    const handle = try app.openWindow(.{
        .bounds = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 1024, .height = 674 } },
    }, shell_mod.Shell, shell_mod.Shell.init, .{ state, f, true });
    const w = handle.window(app).?;
    w.prefers_reduced_motion = true;
    const tw = TestWindow.of(w.platform_window);
    app.runUntilParked();
    const vsync_ns: u64 = 16_666_667;
    for (0..30) |_| {
        app.advanceClock(vsync_ns);
        tw.frame(true);
    }

    const renders_before = sidebar_mod.Sidebar.render_count;
    const presents_before = tw.present_count;
    const total = @call(.never_inline, scrollFrames, .{ app, tw, frames });
    return .{
        .frames = frames,
        .total_ns = total,
        .sidebar_renders = sidebar_mod.Sidebar.render_count - renders_before,
        .presents = tw.present_count - presents_before,
        .rows = handle.rootView(app).?.read(app).main.read(app).slots.transcript_view.read(app).rowCount(),
    };
}

test "scrolling the transcript redraws every frame without rebuilding the sidebar" {
    // docs/BENCHMARKS.md: the sidebar was an uncached child of the shell, so every
    // transcript scroll frame rebuilt all 150 rows. It is a cached view now (Rust
    // `sidebar_pane.cached(..)`); a scroll notifies the transcript only. (The first
    // wheel event moves the mouse onto the transcript: one hover refresh.)
    const frames: usize = if (testing.environ.getPosix("ZERON_SCROLL_FRAMES")) |v| std.fmt.parseInt(usize, v, 10) catch 60 else 60;
    const run = try scrollShell(testing.allocator, frames);
    if (testing.environ.getPosix("ZERON_SCROLL_FRAMES") != null) std.debug.print("\nshell scroll: {d} frames, avg {d:.3} ms, sidebar renders {d}, presents {d}\n", .{ run.frames, @as(f64, @floatFromInt(run.total_ns)) / @as(f64, @floatFromInt(run.frames)) / 1e6, run.sidebar_renders, run.presents });
    try testing.expectEqual(@as(usize, 2040), run.rows);
    try testing.expect(run.presents >= run.frames);
    try testing.expect(run.sidebar_renders <= 1);
}
