//! zpui.audio demo: plays a synthesized mechanical-keyboard click pattern
//! (typing bursts with per-key pan and subtle gain/pitch randomization),
//! waits for the output to auto-suspend, then plays again to measure the
//! restart latency.
//!
//!     zig build audio-demo                         # default output device
//!     ZPUI_AUDIO_OFFLINE=out.wav zig build audio-demo   # render to a WAV (CI)
//!     zig build audio-demo -- --seconds 5 --backend pulse
//!
//! Prints the backend, period and latency, and the average callback CPU time.

const std = @import("std");
const za = @import("zpui_audio");

const variants = 4;

const Pattern = struct {
    prng: std.Random.DefaultPrng,

    /// Next keystroke: delay since the previous one (ns) and play options.
    fn next(self: *Pattern) struct { delay_ns: u64, variant: usize, opts: za.PlayOptions } {
        const r = self.prng.random();
        // Bursts of fast typing (60–160 ms) with occasional pauses.
        const pause = r.uintLessThan(u32, 12) == 0;
        const ms: u64 = if (pause) 350 + r.uintLessThan(u64, 400) else 60 + r.uintLessThan(u64, 100);
        return .{
            .delay_ns = ms * std.time.ns_per_ms,
            .variant = r.uintLessThan(usize, variants),
            .opts = .{
                .gain = 0.65 + r.float(f32) * 0.3,
                .pan = r.float(f32) * 1.2 - 0.6,
                .pitch = 0.96 + r.float(f32) * 0.08,
            },
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var seconds: f64 = 4;
    var backend: za.Preference = .auto;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--seconds") and i + 1 < argv.len) {
            i += 1;
            seconds = std.fmt.parseFloat(f64, argv[i]) catch 4;
        } else if (std.mem.eql(u8, a, "--backend") and i + 1 < argv.len) {
            i += 1;
            backend = std.meta.stringToEnum(za.Preference, argv[i]) orelse .auto;
        }
    }
    const offline = init.environ_map.get("ZPUI_AUDIO_OFFLINE");
    if (offline != null) backend = .null;

    const audio = try za.Audio.init(gpa, .{ .sample_rate = 48000, .backend = backend, .app_name = "zpui audio demo" });
    defer audio.deinit();
    const st = audio.status();
    std.debug.print("backend: {s}{s}{s}\n", .{ @tagName(st.backend), if (st.reason.len > 0) " — " else "", st.reason });
    if (st.backend != .none) std.debug.print("device: {d} Hz, {d} ch, {d}-frame period, ~{d:.2} ms output latency\n", .{
        st.device.rate, st.device.channels, st.device.period_frames, @as(f64, @floatFromInt(st.device.latency_ns)) / 1e6,
    });

    var clicks: [variants]za.SoundId = undefined;
    for (&clicks, 0..) |*c, v| {
        const pcm = try za.synthesizeClick(gpa, 48000, 0x5eed + v);
        defer gpa.free(pcm);
        c.* = try audio.loadPcm(pcm, 48000);
    }
    var pattern: Pattern = .{ .prng = .init(42) };

    if (offline) |path| {
        try renderOffline(gpa, io, audio, &clicks, &pattern, seconds, path);
        return;
    }

    if (st.backend == .none) {
        std.debug.print("no output device; nothing to play (play() is a no-op)\n", .{});
        return;
    }

    // Typing for `seconds`.
    var played: usize = 0;
    const t_end = za.sys.nowNs() + @as(u64, @intFromFloat(seconds * std.time.ns_per_s));
    while (za.sys.nowNs() < t_end) {
        const k = pattern.next();
        za.sys.sleepNs(k.delay_ns);
        audio.play(clicks[k.variant], k.opts);
        played += 1;
    }
    std.debug.print("played {d} clicks; waiting for auto-suspend…\n", .{played});
    const s0 = audio.stats();
    var waited: u32 = 0;
    while (audio.status().running and waited < 60) : (waited += 1) {
        za.sys.sleepNs(100 * std.time.ns_per_ms);
    }
    std.debug.print("suspended: {} (after ~{d} ms idle wait)\n", .{ !audio.status().running, waited * 100 });

    // Resume: a few isolated clicks from the suspended state.
    for (0..3) |_| {
        audio.play(clicks[0], .{});
        za.sys.sleepNs(400 * std.time.ns_per_ms);
        std.debug.print("restart latency (play → first callback): {d:.2} ms\n", .{@as(f64, @floatFromInt(audio.stats().last_resume_ns)) / 1e6});
        var w: u32 = 0;
        while (audio.status().running and w < 40) : (w += 1) za.sys.sleepNs(100 * std.time.ns_per_ms);
    }
    printStats(audio.stats(), s0);
}

fn renderOffline(gpa: std.mem.Allocator, io: std.Io, audio: *za.Audio, clicks: []const za.SoundId, pattern: *Pattern, seconds: f64, path: []const u8) !void {
    const rate = audio.sampleRate();
    const period = 256;
    const total: usize = @intFromFloat(seconds * @as(f64, @floatFromInt(rate)));
    const out = try gpa.alloc(f32, (total + period) * 2);
    defer gpa.free(out);
    var next_ns: u64 = 0;
    var k = pattern.next();
    next_ns += k.delay_ns;
    var frame: usize = 0;
    var cpu_ns: u64 = 0;
    var callbacks: u64 = 0;
    while (frame < total) : (frame += period) {
        // Keystrokes due before this period's start are queued first,
        // like a device callback picking up play() calls.
        const now_ns = frame * std.time.ns_per_s / rate;
        while (next_ns <= now_ns) {
            audio.play(clicks[k.variant], k.opts);
            k = pattern.next();
            next_ns += k.delay_ns;
        }
        const t0 = za.sys.nowNs();
        audio.renderOffline(out[frame * 2 ..][0 .. period * 2]);
        cpu_ns += za.sys.nowNs() - t0;
        callbacks += 1;
    }
    const wav = try za.wav.encode16(gpa, out[0 .. total * 2], 2, rate);
    defer gpa.free(wav);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = wav });
    var peak: f32 = 0;
    for (out[0 .. total * 2]) |s| peak = @max(peak, @abs(s));
    const s = audio.stats();
    std.debug.print("wrote {s}: {d:.1} s, {d} Hz stereo, {d} clicks, peak {d:.3}\n", .{ path, seconds, rate, s.voices_started, peak });
    std.debug.print("average callback CPU time: {d:.2} µs per {d}-frame callback ({d:.3}% of real time); busy callbacks {d:.2} µs, max {d:.2} µs\n", .{
        @as(f64, @floatFromInt(cpu_ns / @max(1, callbacks))) / 1e3,                                                                  period,
        @as(f64, @floatFromInt(cpu_ns)) / (@as(f64, @floatFromInt(callbacks * period)) / @as(f64, @floatFromInt(rate)) * 1e9) * 100, @as(f64, @floatFromInt(s.avg_busy_render_ns)) / 1e3,
        @as(f64, @floatFromInt(s.max_render_ns)) / 1e3,
    });
    if (s.voices_started == 0 or peak < 0.05) return error.SilentRender;
}

fn printStats(s: za.StatsSnapshot, before: za.StatsSnapshot) void {
    _ = before;
    std.debug.print(
        \\callbacks: {d} ({d} frames), avg callback CPU {d:.2} µs (busy {d:.2} µs, max {d:.2} µs)
        \\voices: {d} started, {d} stolen, {d} dropped; xruns {d}
        \\suspends: {d}, resumes: {d}, restart latency avg {d:.2} ms / max {d:.2} ms
        \\
    , .{
        s.callbacks,                                    s.frames,
        @as(f64, @floatFromInt(s.avg_render_ns)) / 1e3, @as(f64, @floatFromInt(s.avg_busy_render_ns)) / 1e3,
        @as(f64, @floatFromInt(s.max_render_ns)) / 1e3, s.voices_started,
        s.voices_stolen,                                s.dropped,
        s.xruns,                                        s.suspends,
        s.resumes,                                      @as(f64, @floatFromInt(s.avg_resume_ns)) / 1e6,
        @as(f64, @floatFromInt(s.max_resume_ns)) / 1e6,
    });
}
