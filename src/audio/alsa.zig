//! ALSA output via libasound.so.2 (dlopen), the last Linux fallback. A
//! dedicated thread renders one period at a time into blocking
//! `snd_pcm_writei` on the "default" PCM. On idle it drops the stream
//! (`snd_pcm_drop`) and blocks on the engine's wake event; the next `play`
//! prepares and refills it. ALSA has no default-device notifications; the
//! "default" PCM resolves through the user's asoundrc / plugin config.

const std = @import("std");
const sys = @import("sys.zig");
const engine = @import("engine.zig");
const Engine = engine.Engine;
const log = std.log.scoped(.zpui_audio);

const Pcm = opaque {};

const Fns = struct {
    snd_pcm_open: *const fn (*?*Pcm, [*:0]const u8, c_int, c_int) callconv(.c) c_int,
    snd_pcm_set_params: *const fn (*Pcm, c_int, c_int, c_uint, c_uint, c_int, c_uint) callconv(.c) c_int,
    snd_pcm_get_params: *const fn (*Pcm, *c_ulong, *c_ulong) callconv(.c) c_int,
    snd_pcm_writei: *const fn (*Pcm, *const anyopaque, c_ulong) callconv(.c) c_long,
    snd_pcm_recover: *const fn (*Pcm, c_int, c_int) callconv(.c) c_int,
    snd_pcm_drop: *const fn (*Pcm) callconv(.c) c_int,
    snd_pcm_prepare: *const fn (*Pcm) callconv(.c) c_int,
    snd_pcm_close: *const fn (*Pcm) callconv(.c) c_int,
    snd_lib_error_set_handler: ?*const fn (?*const anyopaque) callconv(.c) c_int,
};

const SND_PCM_STREAM_PLAYBACK = 0;
const SND_PCM_FORMAT_S16_LE = 2;
const SND_PCM_ACCESS_RW_INTERLEAVED = 3;

/// Swallows libasound's stderr diagnostics (e.g. "cannot find card 0"
/// on machines without sound hardware). The real handler is variadic; the
/// fixed leading arguments are passed identically on the Linux ABIs.
fn silentErrorHandler(_: ?[*:0]const u8, _: c_int, _: ?[*:0]const u8, _: c_int, _: ?[*:0]const u8) callconv(.c) void {}

pub const Backend = struct {
    gpa: std.mem.Allocator,
    fns: Fns,
    lib: sys.DynLib,
    engine: *Engine,
    info: engine.DeviceInfo = .{},
    pcm: *Pcm,
    buf: []i16,
    thread: ?std.Thread = null,

    pub fn open(gpa: std.mem.Allocator, e: *Engine, o: engine.OpenOptions) engine.OpenError!*Backend {
        const lib = sys.DynLib.open(&.{ "libasound.so.2", "libasound.so" }) orelse return error.Unavailable;
        const fns = lib.load(Fns) orelse {
            lib.close();
            return error.Unavailable;
        };
        if (fns.snd_lib_error_set_handler) |f| _ = f(@ptrCast(&silentErrorHandler));
        var pcm: ?*Pcm = null;
        if (fns.snd_pcm_open(&pcm, "default", SND_PCM_STREAM_PLAYBACK, 0) < 0 or pcm == null) {
            lib.close();
            return error.Unavailable;
        }
        const period_req: u32 = if (o.buffer_frames != 0) o.buffer_frames else o.rate / 200; // 5 ms
        // Total buffer ≈ 4 periods (snd_pcm_set_params' split).
        const latency_us: c_uint = @intCast(@as(u64, period_req) * 4 * std.time.us_per_s / o.rate);
        if (fns.snd_pcm_set_params(pcm.?, SND_PCM_FORMAT_S16_LE, SND_PCM_ACCESS_RW_INTERLEAVED, 2, o.rate, 1, latency_us) < 0) {
            _ = fns.snd_pcm_close(pcm.?);
            lib.close();
            return error.Unavailable;
        }
        var buffer_size: c_ulong = 0;
        var period_size: c_ulong = 0;
        _ = fns.snd_pcm_get_params(pcm.?, &buffer_size, &period_size);
        if (period_size == 0) period_size = period_req;
        if (buffer_size == 0) buffer_size = period_size * 4;
        const self = gpa.create(Backend) catch {
            _ = fns.snd_pcm_close(pcm.?);
            lib.close();
            return error.OutOfMemory;
        };
        const buf = gpa.alloc(i16, @as(usize, @intCast(period_size)) * 2) catch {
            gpa.destroy(self);
            _ = fns.snd_pcm_close(pcm.?);
            lib.close();
            return error.OutOfMemory;
        };
        self.* = .{
            .gpa = gpa,
            .fns = fns,
            .lib = lib,
            .engine = e,
            .pcm = pcm.?,
            .buf = buf,
            .info = .{
                .rate = o.rate,
                .channels = 2,
                .period_frames = @intCast(period_size),
                .latency_ns = @as(u64, buffer_size) * std.time.ns_per_s / o.rate,
            },
        };
        self.thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, run, .{self}) catch {
            self.release();
            return error.Unavailable;
        };
        return self;
    }

    fn release(self: *Backend) void {
        _ = self.fns.snd_pcm_close(self.pcm);
        self.lib.close();
        self.gpa.free(self.buf);
        self.gpa.destroy(self);
    }

    /// `Audio.deinit` has already set `engine.quit` and poked the thread.
    pub fn close(self: *Backend) void {
        if (self.thread) |t| t.join();
        self.release();
    }

    fn run(self: *Backend) void {
        const e = self.engine;
        const frames = self.buf.len / 2;
        var prepared = true; // snd_pcm_set_params leaves the PCM prepared
        while (!e.quit.load(.acquire)) {
            if (e.state.load(.seq_cst) == .running) {
                e.render(i16, self.buf, frames, 2);
                var off: usize = 0;
                while (off < frames) {
                    const n = self.fns.snd_pcm_writei(self.pcm, @ptrCast(self.buf[off * 2 ..].ptr), frames - off);
                    if (n < 0) {
                        _ = e.stats.xruns.fetchAdd(1, .monotonic);
                        if (self.fns.snd_pcm_recover(self.pcm, @intCast(n), 1) < 0) {
                            log.warn("audio: ALSA write failed ({d}); suspending", .{n});
                            _ = self.fns.snd_pcm_drop(self.pcm);
                            prepared = false;
                            e.state.store(.suspended, .seq_cst);
                            break;
                        }
                        continue;
                    }
                    off += @intCast(n);
                }
                if (e.trySuspend()) {
                    _ = self.fns.snd_pcm_drop(self.pcm);
                    prepared = false;
                }
            } else {
                _ = e.wake.wait(null);
                if (e.quit.load(.acquire)) break;
                if (!e.hasPending()) continue;
                if (!prepared) {
                    if (self.fns.snd_pcm_prepare(self.pcm) < 0) {
                        while (e.mixer.ring.pop()) |_| _ = e.stats.dropped.fetchAdd(1, .monotonic);
                        continue;
                    }
                    prepared = true;
                }
                e.markRunning();
            }
        }
        _ = self.fns.snd_pcm_drop(self.pcm);
    }
};
