//! Benchmark timeline driver (`ZERON_BENCH=1`; bench/run_bench.py, docs/BENCHMARKS.md).
//!
//! The same timeline, the same marker lines and the same thresholds as the hook the
//! harness adds to the Rust client (bench/rust/bench_hook.rs), so both apps are
//! measured doing the same thing. Every marker is one stderr line
//! `zeron-bench {"ev":"…","t":<epoch µs>,…}`; every drawn frame prints
//! `frame duration: <ms>ms` (gpui's `ZED_MEASUREMENTS` line: draw + present).
//!
//!  1. boot: `window_open`; frames forced until the boot-selected short chat's
//!     transcript is on screen → `first_frame` (2nd frame callback = 1st present),
//!     `shell_loaded` (the frame after the transcript landed);
//!  2. `idle_start` … `idle_end`: no frames requested for ZERON_BENCH_IDLE_S;
//!  3. `open_long`: select the long chat → `long_loaded` once ≥ ZERON_BENCH_LONG_MIN rows;
//!  4. settle (no frames) → `settle1_end`;
//!  5. `scroll_start`: ZERON_BENCH_SCROLL_FRAMES frames, one wheel event each (half up,
//!     half down), frame intervals in `scroll_end`;
//!  6. settle → `settle2_end`, `stream_ready` (the harness queues a mock run); frames
//!     forced until a streaming row appears (`stream_start`) and finishes (`stream_end`);
//!  7. settle → `done`, quit.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");

const App = zpui.App;
const Window = zpui.Window;

const Phase = enum { boot, open_long, scroll, stream, idle };

const Bench = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    app: *App,
    window: *Window,
    state: zpui.Entity(model.AppState),
    long_chat: []const u8,
    short_chat: []const u8,
    long_min: usize,
    idle_ns: u64,
    settle_ns: u64,
    scroll_frames: usize,
    scroll_px: f32,
    scroll_x: f32,
    scroll_y: f32,
    phase: Phase = .boot,
    frames: u64 = 0,
    ready_seen: bool = false,
    phase_started_ns: i96 = 0,
    last_frame_ns: ?i96 = null,
    intervals: std.ArrayList(f64) = .empty,
    scroll_i: usize = 0,
    stream_seen: bool = false,
    boot_selected: bool = false,
    draw_start_ns: i96 = 0,
};

var bench: ?Bench = null;

/// Startup timeline (`boot:<phase>` markers, ZERON_BENCH=1): main.zig and zpui
/// (`zpui.boot_trace`) mark the steps from `main` to the loaded shell; the harness
/// reports each relative to the spawn (bench/run_bench.py `boot_ms`).
var boot_io: ?std.Io = null;

pub fn bootInit(io: std.Io, env: *const std.process.Environ.Map) void {
    const on = env.get("ZERON_BENCH") orelse return;
    if (!std.mem.eql(u8, on, "1")) return;
    boot_io = io;
    zpui.boot_trace.hook = bootHook;
}

/// One startup step reached (no-op unless `bootInit` armed the timeline).
pub fn bootMark(phase: []const u8) void {
    zpui.boot_trace.mark(phase);
}

fn bootHook(phase: []const u8) void {
    const io = boot_io orelse return;
    const t = @divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, 1000);
    std.debug.print("zeron-bench {{\"ev\":\"boot:{s}\",\"t\":{d}}}\n", .{ phase, t });
}

fn envNum(env: *const std.process.Environ.Map, name: []const u8, default: f64) f64 {
    const v = env.get(name) orelse return default;
    return std.fmt.parseFloat(f64, v) catch default;
}

fn monoNs(io: std.Io) i96 {
    return std.Io.Timestamp.now(io, .awake).nanoseconds;
}

fn emit(ev: []const u8, comptime extra_fmt: []const u8, extra: anytype) void {
    const b = &(bench orelse return);
    const t = @divTrunc(std.Io.Timestamp.now(b.io, .real).nanoseconds, 1000);
    if (extra_fmt.len == 0) {
        std.debug.print("zeron-bench {{\"ev\":\"{s}\",\"t\":{d}}}\n", .{ ev, t });
    } else {
        std.debug.print("zeron-bench {{\"ev\":\"{s}\",\"t\":{d}," ++ extra_fmt ++ "}}\n", .{ ev, t } ++ extra);
    }
}

fn emitIntervals(ev: []const u8, rows: usize) void {
    const b = &(bench orelse return);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(b.gpa);
    buf.append(b.gpa, '[') catch return;
    for (b.intervals.items, 0..) |x, i| {
        if (i > 0) buf.append(b.gpa, ',') catch return;
        buf.print(b.gpa, "{d:.3}", .{x}) catch return;
    }
    buf.append(b.gpa, ']') catch return;
    emit(ev, "\"rows\":{d},\"intervals_ms\":{s}", .{ rows, buf.items });
}

fn frameObserver(end: bool) void {
    const b = &(bench orelse return);
    if (b.phase == .boot and b.frames < 2) bootMark(if (end) "draw_end" else "draw_start");
    const now = monoNs(b.io);
    if (!end) {
        b.draw_start_ns = now;
    } else {
        const ns: f64 = @floatFromInt(now - b.draw_start_ns);
        std.debug.print("frame duration: {d:.6}ms\n", .{ns / 1e6});
    }
}

/// Arm the benchmark for the main window (no-op unless ZERON_BENCH=1).
pub fn start(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, app: *App, window: *Window, state: zpui.Entity(model.AppState)) void {
    const on = env.get("ZERON_BENCH") orelse return;
    if (!std.mem.eql(u8, on, "1")) return;
    bench = .{
        .io = io,
        .gpa = gpa,
        .app = app,
        .window = window,
        .state = state,
        .long_chat = env.get("ZERON_BENCH_LONG_CHAT") orelse "",
        .short_chat = env.get("ZERON_BENCH_SHORT_CHAT") orelse "",
        .long_min = @intFromFloat(envNum(env, "ZERON_BENCH_LONG_MIN", 2)),
        .idle_ns = @intFromFloat(envNum(env, "ZERON_BENCH_IDLE_S", 6) * 1e9),
        .settle_ns = @intFromFloat(envNum(env, "ZERON_BENCH_SETTLE_S", 4) * 1e9),
        .scroll_frames = @intFromFloat(envNum(env, "ZERON_BENCH_SCROLL_FRAMES", 300)),
        .scroll_px = @floatCast(envNum(env, "ZERON_BENCH_SCROLL_PX", 40)),
        .scroll_x = @floatCast(envNum(env, "ZERON_BENCH_SCROLL_X", 800)),
        .scroll_y = @floatCast(envNum(env, "ZERON_BENCH_SCROLL_Y", 420)),
    };
    bench.?.phase_started_ns = monoNs(io);
    // The "plain" configuration (docs/BENCHMARKS.md): AppKit controls drawn by zpui
    // instead (ZERON_LIQUID_GLASS=0 turns the glass off, main.zig).
    if (env.get("ZERON_BENCH_NATIVE_CONTROLS")) |v| if (std.mem.eql(u8, v, "0")) window.setNativeControlsEnabled(false);
    Window.frame_observer = frameObserver;
    emit("window_open", "", .{});
    schedule(window);
}

const Tick = struct {
    fn f(_: *const Tick, win: *Window, app: *App) void {
        frame(win, app);
    }
};

fn schedule(win: *Window) void {
    win.onNextFrame(Tick{}, Tick.f);
}

fn beginFrames(phase: Phase) void {
    const b = &bench.?;
    b.phase = phase;
    b.phase_started_ns = monoNs(b.io);
    b.last_frame_ns = null;
    b.intervals.clearRetainingCapacity();
    b.ready_seen = false;
    b.window.refresh();
    schedule(b.window);
}

const Then = enum { open_long, start_scroll, settle2_done, finish };

const AfterJob = struct {
    then: Then,
    pub fn finish(j: *AfterJob) void {
        const b = &(bench orelse return);
        b.app.startUpdate();
        defer b.app.finishUpdate();
        switch (j.then) {
            .open_long => openLong(),
            .start_scroll => {
                emit("settle1_end", "", .{});
                emit("scroll_start", "", .{});
                b.scroll_i = 0;
                beginFrames(.scroll);
            },
            .settle2_done => {
                emit("settle2_end", "", .{});
                // Back to the tail (follow mode) so the streamed reply is on screen.
                _ = b.window.dispatchEvent(.{ .scroll_wheel = .{
                    .position = .{ .x = b.scroll_x, .y = b.scroll_y },
                    .delta = .{ .pixels = .{ .x = 0, .y = -1_000_000 } },
                } });
                emit("stream_ready", "", .{});
                b.stream_seen = false;
                beginFrames(.stream);
            },
            .finish => {
                emit("done", "", .{});
                b.intervals.deinit(b.gpa);
                b.app.quit();
            },
        }
    }
};

/// Run `then` after `delay_ns` with no frames requested meanwhile.
fn after(delay_ns: u64, then: Then) void {
    const b = &bench.?;
    b.phase = .idle;
    var task = b.app.foregroundExecutor().timer(delay_ns, AfterJob{ .then = then }) catch {
        emit("error", "\"phase\":\"timer\"", .{});
        return b.app.quit();
    };
    task.detach();
}

const Info = struct { selected: ?[]const u8, rows: usize, replayed: bool, streaming: bool };

fn transcriptInfo(app: *App) Info {
    const b = &bench.?;
    const st = b.state.read(app);
    const selected = st.workspace.read(app).selected_chat;
    const t = st.transcript orelse return .{ .selected = selected, .rows = 0, .replayed = false, .streaming = false };
    const ts = t.read(app);
    var streaming = false;
    for (ts.transcript.rows.items) |r| {
        if (r.entry.status) |s| if (s == .streaming) {
            streaming = true;
        };
    }
    return .{ .selected = selected, .rows = ts.transcript.rows.items.len, .replayed = ts.replayed, .streaming = streaming };
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

fn frame(win: *Window, app: *App) void {
    const b = &(bench orelse return);
    const now = monoNs(b.io);
    b.frames += 1;
    if (b.last_frame_ns) |last| {
        const dt: f64 = @floatFromInt(now - last);
        b.intervals.append(b.gpa, dt / 1e6) catch {};
    }
    b.last_frame_ns = now;
    const timeout = now - b.phase_started_ns > 90 * std.time.ns_per_s;
    switch (b.phase) {
        .idle => {},
        .boot => {
            if (b.frames == 2) {
                const vp = win.viewportSize();
                emit("first_frame", "\"w\":{d},\"h\":{d},\"scale\":{d}", .{ vp.width, vp.height, win.scaleFactor() });
            }
            // The shell's boot landing (`Shell.bootSelectChat`, Rust
            // `Shell::boot_select_chat`) opens the most recent chat, the short one, in
            // the same update that syncs chats, so this fallback only fires when nothing
            // got selected, exactly as the Rust driver's.
            const ws_e = b.state.read(app).workspace;
            if (ws_e.read(app).chats_synced and ws_e.read(app).selected_chat == null and b.short_chat.len > 0) {
                if (!b.boot_selected) emit("boot_select", "", .{});
                b.boot_selected = true;
                ws_e.update(app, model.WorkspaceStore.selectChat, .{@as(?[]const u8, b.short_chat)});
            }
            const info = transcriptInfo(app);
            const ok = info.replayed and info.rows > 0 and (b.short_chat.len == 0 or eqlOpt(info.selected, b.short_chat));
            if (b.ready_seen) {
                zpui.boot_trace.hook = null; // the startup timeline ends with the loaded shell
                emit("shell_loaded", "\"selected\":\"{s}\",\"rows\":{d}", .{ info.selected orelse "", info.rows });
                emit("idle_start", "", .{});
                return after(b.idle_ns, .open_long);
            }
            if (ok) b.ready_seen = true;
            if (timeout) {
                const st = b.state.read(app);
                const ws = st.workspace.read(app);
                emit("error", "\"phase\":\"boot\",\"selected\":\"{s}\",\"rows\":{d},\"gate\":\"{t}\",\"chats_synced\":{},\"chats\":{d}", .{ info.selected orelse "", info.rows, st.gate(app), ws.chats_synced, ws.chats().len });
                b.intervals.deinit(b.gpa);
                return app.quit();
            }
            schedule(win);
        },
        .open_long => {
            const info = transcriptInfo(app);
            if (b.ready_seen) {
                emit("long_loaded", "\"rows\":{d}", .{info.rows});
                return after(b.settle_ns, .start_scroll);
            }
            if (info.replayed and info.rows >= b.long_min and eqlOpt(info.selected, b.long_chat)) b.ready_seen = true;
            if (timeout) {
                emit("error", "\"phase\":\"open_long\",\"rows\":{d}", .{info.rows});
                b.intervals.deinit(b.gpa);
                return app.quit();
            }
            schedule(win);
        },
        .scroll => {
            const n = b.scroll_frames;
            if (b.scroll_i >= n) {
                emitIntervals("scroll_end", transcriptInfo(app).rows);
                return after(b.settle_ns, .settle2_done);
            }
            // Positive y scrolls toward older content (up), as a trackpad does.
            const dy: f32 = if (b.scroll_i < n / 2) b.scroll_px else -b.scroll_px;
            _ = win.dispatchEvent(.{ .scroll_wheel = .{
                .position = .{ .x = b.scroll_x, .y = b.scroll_y },
                .delta = .{ .pixels = .{ .x = 0, .y = dy } },
            } });
            b.scroll_i += 1;
            schedule(win);
        },
        .stream => {
            const info = transcriptInfo(app);
            if (info.streaming and !b.stream_seen) {
                b.stream_seen = true;
                b.intervals.clearRetainingCapacity();
                emit("stream_start", "\"rows\":{d}", .{info.rows});
            } else if (b.stream_seen and !info.streaming) {
                emitIntervals("stream_end", info.rows);
                return after(b.settle_ns, .finish);
            }
            if (timeout) {
                emit("error", "\"phase\":\"stream\",\"seen\":{}", .{b.stream_seen});
                b.intervals.deinit(b.gpa);
                return app.quit();
            }
            schedule(win);
        },
    }
}

fn openLong() void {
    const b = &bench.?;
    emit("idle_end", "", .{});
    emit("open_long", "", .{});
    const ws = b.state.read(b.app).workspace;
    ws.update(b.app, model.WorkspaceStore.selectChat, .{@as(?[]const u8, b.long_chat)});
    beginFrames(.open_long);
}
