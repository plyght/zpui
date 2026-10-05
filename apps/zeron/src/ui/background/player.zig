//! Moving new-thread backgrounds, playback half (zpui-only; Rust zeron shows
//! stills). A `Player` per file path (an App global keeps at most two: the
//! hero and the Adjust preview share one) decodes on background workers one
//! frame per job, renders each frame through the same proxy + effect
//! pipeline as stills (`artwork.Proxy`, at `motion_proxy_side`), and queues
//! a few frames ahead. Playback runs on the app clock:
//!
//! - frames shorter than 1/30 s are merged (a 30 fps cap);
//! - a late frame holds the current one; lag never snowballs (≤ 250 ms);
//! - GIF / APNG / WebP loop counts are honoured (video loops forever); the
//!   last frame stays once every play is done;
//! - a whole pass is kept in memory (and replayed without decoding) only
//!   while it fits `loop_budget_bytes`; otherwise frames stream and the
//!   decoder rewinds each pass;
//! - nothing runs unless someone asks for a frame: a page that stops
//!   rendering the hero stops the timers, and the queue (≤ 3 frames) stops
//!   the decoder.
//!
//! ```zig
//! const art = player.artwork(app, io, bg, effect, light, window, cx.entityId());
//! // art.image: the frame (or the still/poster), art.stream: crossfade identity
//! ```
//!
//! Reduce motion shows the still at `bg.path` (the poster copy, or the
//! file's first frame); "Pause animations in background" freezes the frame
//! while the window is inactive.

const std = @import("std");
const zpui = @import("zpui");
const model = @import("zeron_model");
const artwork_mod = @import("artwork.zig");
const anim = @import("anim_decode.zig");
const video = @import("video.zig");
const cache = @import("cache.zig");
const motion_settings = @import("../settings/motion.zig");

const App = zpui.App;
const Window = zpui.Window;
const EntityId = zpui.EntityId;
const Allocator = std.mem.Allocator;
const RenderImage = zpui.image.RenderImage;
const Effect = artwork_mod.Effect;
const Background = model.settings.NewThreadComposerBackground;

/// Frames rendered ahead of the one on screen.
pub const queue_capacity = 3;
/// A whole pass is kept (and replayed without decoding) while it fits.
pub var loop_budget_bytes: usize = 48 << 20;
/// Lag beyond this restarts the clock instead of fast-forwarding.
pub const max_lag_ns: u64 = 250 * std.time.ns_per_ms;
/// Animated image files are read whole; larger ones are refused.
pub const max_image_bytes: usize = 128 << 20;
pub const max_players = 2;

pub const Mode = enum {
    /// Reduce motion: show the still / poster.
    still,
    /// Window inactive with "Pause animations in background": hold the frame.
    paused,
    play,
};

/// How the background should move in `window` right now.
pub fn modeFor(app: *App, window: *Window) Mode {
    if (motion_settings.reducedFor(app, true)) return .still;
    if (window.prefersReducedMotion()) return .paused;
    return .play;
}

/// The file that may move: the managed animation copy, else the image itself.
pub fn motionPath(bg: Background) []const u8 {
    return bg.motionPath orelse bg.path;
}

// ---- decoding stream (worker-owned) ------------------------------------------

pub const Stream = struct {
    gpa: Allocator,
    kind: anim.Kind,
    bytes: []u8 = &.{},
    image: ?anim.ImageDecoder = null,
    video: ?video.Decoder = null,

    pub fn deinit(self: *Stream) void {
        if (self.image) |*d| d.deinit(self.gpa);
        if (self.video) |*v| v.deinit();
        self.gpa.free(self.bytes);
        self.gpa.destroy(self);
    }

    fn next(self: *Stream) !?anim.Frame {
        if (self.image) |*d| return d.next(self.gpa);
        if (self.video) |*v| return v.next();
        return null;
    }

    fn rewind(self: *Stream) !void {
        if (self.image) |*d| d.rewind();
        if (self.video) |*v| try v.rewind();
    }
};

pub const Opened = union(enum) {
    still,
    failed: []const u8,
    ready: struct { stream: *Stream, plays: u32 },
};

/// Read the head of a file.
fn readHead(io: std.Io, path: []const u8, buf: []u8) ?[]u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const n = file.readPositionalAll(io, buf, 0) catch return null;
    return buf[0..n];
}

/// Classify `path` and open its decoder (worker-safe).
pub fn openStream(gpa: Allocator, io: std.Io, path: []const u8) Opened {
    var head_buf: [64 * 1024]u8 = undefined;
    const head = readHead(io, path, &head_buf) orelse return .{ .failed = "" };
    var kind = anim.classify(head);
    const is_gif = std.mem.startsWith(u8, head, "GIF8");
    var bytes: []u8 = &.{};
    if (kind == .still and !is_gif) return .still;
    if (kind != .video) {
        bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_image_bytes)) catch return .{ .failed = "" };
        kind = anim.classify(bytes);
        if (kind == .still) {
            gpa.free(bytes);
            return .still;
        }
    }
    const s = gpa.create(Stream) catch {
        gpa.free(bytes);
        return .{ .failed = "" };
    };
    s.* = .{ .gpa = gpa, .kind = kind, .bytes = bytes };
    if (kind == .video) {
        s.video = video.Decoder.open(gpa, path, video.max_decode_side) catch |err| {
            s.deinit();
            return .{ .failed = if (err == error.Unsupported) video.msg_unsupported else video.msg_undecodable };
        };
    } else {
        s.image = anim.ImageDecoder.open(gpa, bytes, kind) catch {
            s.deinit();
            return .{ .failed = "" };
        };
    }
    return .{ .ready = .{ .stream = s, .plays = anim.plays(bytes, kind) } };
}

/// Proxy + effect one composited frame into a RenderImage (worker-safe).
pub fn renderFrame(gpa: Allocator, image: artwork_mod.Rgba, effect: Effect, light: bool) ?*RenderImage {
    var proxy = artwork_mod.Proxy.fromImageSized(gpa, image, artwork_mod.motion_proxy_side) catch return null;
    defer proxy.deinit(gpa);
    return cache.renderRaster(gpa, &proxy, effect, light);
}

// ---- player (main thread) -----------------------------------------------------

pub const State = enum { opening, still, playing, failed };

const Queued = struct { image: *RenderImage, duration_ns: u64 };

pub const Player = struct {
    gpa: Allocator,
    id: u64,
    path: []u8,
    state: State = .opening,
    /// The Appearance-row message when the file can't play (videos).
    failure: ?[]const u8 = null,
    kind: anim.Kind = .still,
    /// Total plays (0 = forever) and passes produced so far.
    plays: u32 = 0,
    passes: u32 = 0,
    /// Null while a job owns it.
    stream: ?*Stream = null,
    busy: bool = false,
    need_rewind: bool = false,
    produced_all: bool = false,
    /// (effect, light) of queued frames; a change bumps `generation`.
    effect: Effect = .none,
    light: bool = false,
    keyed: bool = false,
    generation: u32 = 0,
    queue: std.ArrayList(Queued) = .empty,
    current: ?Queued = null,
    current_stale: bool = false,
    shown_at: u64 = 0,
    paused: bool = false,
    /// The pass being recorded for replay (frame 0 onward, this generation).
    recording: bool = true,
    overflow: bool = false,
    loop_complete: bool = false,
    loop_frames: std.ArrayList(Queued) = .empty,
    loop_bytes: usize = 0,
    loop_cursor: usize = 0,
    wake_at: ?u64 = null,
    views: [4]?EntityId = @splat(null),
    /// Frames shown (tests read it).
    advanced: u64 = 0,

    fn release(app: *App, q: Queued) void {
        cache.releaseImage(app, q.image);
    }

    fn clearLoop(self: *Player, app: *App) void {
        for (self.loop_frames.items) |q| release(app, q);
        self.loop_frames.clearRetainingCapacity();
        self.loop_bytes = 0;
        self.loop_cursor = 0;
        self.loop_complete = false;
    }

    fn clearQueue(self: *Player, app: *App) void {
        for (self.queue.items) |q| release(app, q);
        self.queue.clearRetainingCapacity();
    }

    fn destroy(self: *Player, app: *App) void {
        self.clearQueue(app);
        self.clearLoop(app);
        self.queue.deinit(self.gpa);
        self.loop_frames.deinit(self.gpa);
        if (self.current) |q| release(app, q);
        if (self.stream) |s| s.deinit();
        self.gpa.free(self.path);
        self.gpa.destroy(self);
    }

    fn addView(self: *Player, v: EntityId) void {
        for (self.views) |x| if (x) |e| if (e == v) return;
        for (&self.views) |*x| if (x.* == null) {
            x.* = v;
            return;
        };
        std.mem.copyForwards(?EntityId, self.views[0..3], self.views[1..4]);
        self.views[3] = v;
    }

    fn wakeViews(self: *Player, app: *App) void {
        for (self.views) |x| if (x) |v| app.notify(v);
    }

    fn setKey(self: *Player, app: *App, effect: Effect, light: bool) void {
        if (self.keyed and self.effect == effect and self.light == light) return;
        const first = !self.keyed;
        self.keyed = true;
        self.effect = effect;
        self.light = light;
        if (first) return;
        self.generation +%= 1;
        self.clearQueue(app);
        self.clearLoop(app);
        // The decoder is mid-pass: record again from its next rewind.
        self.recording = false;
        self.overflow = false;
        self.current_stale = self.current != null;
        if (self.produced_all) {
            // Re-render the final frame state: replay the last pass.
            self.produced_all = false;
            self.passes -|= 1;
            self.need_rewind = true;
        }
    }

    fn enqueue(self: *Player, app: *App, img: *RenderImage, duration_ns: u64) void {
        if (self.recording and !self.overflow) {
            const bytes = img.frames[0].pixels.len;
            if (self.loop_bytes + bytes > loop_budget_bytes) {
                self.clearLoop(app);
                self.overflow = true;
                self.recording = false;
            } else if (self.loop_frames.append(self.gpa, .{ .image = img.retain(), .duration_ns = duration_ns })) |_| {
                self.loop_bytes += bytes;
            } else |_| {
                img.release();
                self.clearLoop(app);
                self.overflow = true;
                self.recording = false;
            }
        }
        self.queue.append(self.gpa, .{ .image = img, .duration_ns = duration_ns }) catch release(app, .{ .image = img, .duration_ns = 0 });
    }

    fn endPass(self: *Player) void {
        self.passes += 1;
        if (self.recording and !self.overflow and self.loop_frames.items.len > 0) self.loop_complete = true;
        self.recording = false;
        if (self.plays != 0 and self.passes >= self.plays) {
            self.produced_all = true;
        } else self.need_rewind = true;
    }

    /// Keep the queue full: replay the recorded pass, or decode the next frame.
    fn pump(self: *Player, app: *App) void {
        if (self.state != .playing or self.produced_all) return;
        while (self.queue.items.len < queue_capacity and !self.produced_all) {
            if (self.loop_complete) {
                const q = self.loop_frames.items[self.loop_cursor];
                self.queue.append(self.gpa, .{ .image = q.image.retain(), .duration_ns = q.duration_ns }) catch return;
                self.loop_cursor += 1;
                if (self.loop_cursor == self.loop_frames.items.len) {
                    self.loop_cursor = 0;
                    self.passes += 1;
                    if (self.plays != 0 and self.passes >= self.plays) self.produced_all = true;
                }
                continue;
            }
            if (self.busy) return;
            const stream = self.stream orelse return;
            const rewind = self.need_rewind;
            if (rewind) {
                self.need_rewind = false;
                if (!self.overflow) {
                    self.clearLoop(app);
                    self.recording = true;
                }
            }
            const job: FrameJob = .{ .app = app, .id = self.id, .stream = stream, .generation = self.generation, .effect = self.effect, .light = self.light, .rewind = rewind };
            var task = app.backgroundExecutor().spawn(job) catch return;
            self.stream = null;
            self.busy = true;
            jobsMut(app).jobs_started += 1;
            task.detach();
            return;
        }
    }

    /// Show the frames whose time has come (app clock).
    fn advance(self: *Player, app: *App, now: u64) void {
        if (self.current == null or self.current_stale) {
            if (self.queue.items.len == 0) return;
            if (self.current) |c| release(app, c);
            self.current = self.queue.orderedRemove(0);
            self.current_stale = false;
            self.shown_at = now;
            self.advanced += 1;
            return;
        }
        while (self.queue.items.len > 0) {
            const due = self.shown_at + self.current.?.duration_ns;
            if (now < due) break;
            const next = self.queue.orderedRemove(0);
            release(app, self.current.?);
            self.current = next;
            self.shown_at = if (now - due > max_lag_ns) now else due;
            self.advanced += 1;
        }
    }

    fn scheduleWake(self: *Player, app: *App, now: u64) void {
        const cur = self.current orelse return;
        if (self.queue.items.len == 0 and (self.produced_all or self.state != .playing)) return;
        const deadline = self.shown_at + cur.duration_ns;
        if (deadline <= now) return; // waiting on a decode: its finish wakes us
        if (self.wake_at) |w| if (w <= deadline and w > now) return;
        self.wake_at = deadline;
        var task = app.foregroundExecutor().timer(deadline - now, WakeJob{ .app = app, .id = self.id, .deadline = deadline }) catch return;
        task.detach();
    }
};

// ---- the global ---------------------------------------------------------------

pub const Players = struct {
    gpa: Allocator,
    list: std.ArrayList(*Player) = .empty,
    next_id: u64 = 1,
    jobs_started: u64 = 0,

    pub fn deinit(self: *Players, app: *App) void {
        for (self.list.items) |p| p.destroy(app);
        self.list.deinit(self.gpa);
    }

    fn find(self: *Players, id: u64) ?*Player {
        for (self.list.items) |p| if (p.id == id) return p;
        return null;
    }

    fn byPath(self: *Players, path: []const u8) ?*Player {
        for (self.list.items) |p| if (std.mem.eql(u8, p.path, path)) return p;
        return null;
    }
};

fn jobsMut(app: *App) *Players {
    if (app.tryGlobal(Players) == null) app.setGlobal(Players{ .gpa = app.gpa }) catch @panic("OOM");
    return @constCast(app.tryGlobal(Players).?);
}

fn playersMut(app: *App) ?*Players {
    return @constCast(app.tryGlobal(Players) orelse return null);
}

fn obtain(app: *App, io: std.Io, path: []const u8) ?*Player {
    const ps = jobsMut(app);
    if (ps.byPath(path)) |p| {
        // Most recently used last.
        const i = std.mem.indexOfScalar(*Player, ps.list.items, p).?;
        _ = ps.list.orderedRemove(i);
        ps.list.appendAssumeCapacity(p);
        return p;
    }
    const p = app.gpa.create(Player) catch return null;
    p.* = .{ .gpa = app.gpa, .id = ps.next_id, .path = app.gpa.dupe(u8, path) catch {
        app.gpa.destroy(p);
        return null;
    } };
    ps.next_id += 1;
    ps.list.append(app.gpa, p) catch {
        p.destroy(app);
        return null;
    };
    while (ps.list.items.len > max_players) ps.list.orderedRemove(0).destroy(app);
    const job: OpenJob = .{ .app = app, .gpa = app.gpa, .io = io, .id = p.id, .path = app.gpa.dupe(u8, path) catch return p };
    var task = app.backgroundExecutor().spawn(job) catch {
        app.gpa.free(job.path);
        p.state = .failed;
        return p;
    };
    ps.jobs_started += 1;
    task.detach();
    return p;
}

pub const Status = State;

/// Where the player for `path` stands (starts no work).
pub fn status(app: *App, path: []const u8) ?Status {
    const ps = playersMut(app) orelse return null;
    const p = ps.byPath(path) orelse return null;
    return p.state;
}

/// The message for a file that can't move here (e.g. a video without a backend).
pub fn failure(app: *App, path: []const u8) ?[]const u8 {
    const ps = playersMut(app) orelse return null;
    const p = ps.byPath(path) orelse return null;
    const f = p.failure orelse return null;
    return if (f.len > 0) f else null;
}

pub fn jobsStarted(app: *App) u64 {
    return if (app.tryGlobal(Players)) |ps| ps.jobs_started else 0;
}

/// Frames shown so far for `path` (tests).
pub fn framesShown(app: *App, path: []const u8) u64 {
    const ps = playersMut(app) orelse return 0;
    return if (ps.byPath(path)) |p| p.advanced else 0;
}

/// Drop the player for `path` (a removed or replaced file).
pub fn forget(app: *App, path: []const u8) void {
    const ps = playersMut(app) orelse return;
    const p = ps.byPath(path) orelse return;
    const i = std.mem.indexOfScalar(*Player, ps.list.items, p).?;
    _ = ps.list.orderedRemove(i);
    p.destroy(app);
}

pub const Frame = struct { image: *RenderImage, stream: u64 };

/// The frame of `path` to paint now, or null when it doesn't move (a still,
/// still opening, or unplayable): then paint the still. `view` is woken for
/// the next frame.
pub fn frame(app: *App, io: std.Io, path: []const u8, effect: Effect, light_in: bool, mode: Mode, view: ?EntityId, now: u64) ?Frame {
    if (mode == .still) return null;
    const p = obtain(app, io, path) orelse return null;
    if (view) |v| p.addView(v);
    if (p.state != .playing) return null;
    p.setKey(app, effect, artwork_mod.effectUsesLight(effect, light_in));
    p.pump(app);
    if (mode == .paused) {
        p.paused = true;
        // A key change still swaps in a re-rendered frame.
        if (p.current_stale or p.current == null) p.advance(app, now);
    } else {
        if (p.paused) {
            p.paused = false;
            p.shown_at = now;
        }
        p.advance(app, now);
        p.pump(app);
        p.scheduleWake(app, now);
    }
    const cur = p.current orelse return null;
    return .{ .image = cur.image, .stream = p.id };
}

pub const Artwork = struct { image: ?*RenderImage, stream: u64 = 0 };

/// What the hero / Adjust preview paints for `bg`: the moving frame, else the
/// still (`cache.prepare(bg.path)`: the poster, or a still image as in Rust).
pub fn artwork(app: *App, io: std.Io, bg: Background, effect: Effect, light: bool, window: *Window, view: ?EntityId) Artwork {
    const mode = modeFor(app, window);
    if (frame(app, io, motionPath(bg), effect, light, mode, view, app.executor.now())) |f| return .{ .image = f.image, .stream = f.stream };
    return .{ .image = cache.prepare(app, io, bg.path, effect, light) };
}

// ---- jobs -------------------------------------------------------------------

const OpenJob = struct {
    app: *App,
    gpa: Allocator,
    io: std.Io,
    id: u64,
    path: []u8,

    pub fn run(self: *OpenJob) Opened {
        return openStream(self.gpa, self.io, self.path);
    }

    /// Canceled after `run` (app shutdown): drop the opened stream.
    pub fn discard(_: *OpenJob, result: Opened) void {
        if (result == .ready) result.ready.stream.deinit();
    }

    pub fn deinit(self: *OpenJob) void {
        self.gpa.free(self.path);
    }

    pub fn finish(self: *OpenJob, result: Opened) void {
        const app = self.app;
        const ps = playersMut(app) orelse {
            if (result == .ready) result.ready.stream.deinit();
            return;
        };
        const p = ps.find(self.id) orelse {
            if (result == .ready) result.ready.stream.deinit();
            return;
        };
        switch (result) {
            .still => p.state = .still,
            .failed => |m| {
                p.state = .failed;
                p.failure = m;
            },
            .ready => |r| {
                p.state = .playing;
                p.stream = r.stream;
                p.kind = r.stream.kind;
                p.plays = r.plays;
            },
        }
        p.wakeViews(app);
    }
};

const FrameResult = struct {
    stream: *Stream,
    image: ?*RenderImage = null,
    duration_ns: u64 = 0,
    /// The pass ended (before or right after this frame).
    eos: bool = false,
    err: bool = false,
};

const FrameJob = struct {
    app: *App,
    id: u64,
    stream: *Stream,
    generation: u32,
    effect: Effect,
    light: bool,
    rewind: bool,
    /// The stream went back to its player (or was freed with a dropped result).
    handed: bool = false,

    /// Canceled after `run`: free what the player will never receive.
    pub fn discard(self: *FrameJob, r: FrameResult) void {
        if (r.image) |img| img.release();
        r.stream.deinit();
        self.handed = true;
    }

    /// Canceled before `run` (app shutdown): the job still owns the stream.
    pub fn deinit(self: *FrameJob) void {
        if (!self.handed) self.stream.deinit();
    }

    pub fn run(self: *FrameJob) FrameResult {
        const s = self.stream;
        var out: FrameResult = .{ .stream = s };
        if (self.rewind) s.rewind() catch {
            out.err = true;
            return out;
        };
        const f = (s.next() catch {
            out.err = true;
            return out;
        }) orelse {
            out.eos = true;
            return out;
        };
        out.duration_ns = f.duration_ns;
        out.image = renderFrame(s.gpa, f.image, self.effect, self.light);
        // The 30 fps cap: fold faster frames into this one (decoded, not rendered).
        while (out.duration_ns < anim.min_frame_ns) {
            const g = (s.next() catch {
                out.err = true;
                break;
            }) orelse {
                out.eos = true;
                break;
            };
            out.duration_ns += g.duration_ns;
        }
        out.duration_ns = @max(out.duration_ns, anim.min_frame_ns);
        return out;
    }

    pub fn finish(self: *FrameJob, r: FrameResult) void {
        self.handed = true;
        const app = self.app;
        const ps = playersMut(app) orelse {
            if (r.image) |img| img.release();
            r.stream.deinit();
            return;
        };
        const p = ps.find(self.id) orelse {
            if (r.image) |img| img.release();
            r.stream.deinit();
            return;
        };
        p.stream = r.stream;
        p.busy = false;
        if (r.image) |img| {
            if (self.generation == p.generation) p.enqueue(app, img, r.duration_ns) else cache.releaseImage(app, img);
        }
        if (r.err) {
            // Keep what is on screen; stop decoding this file.
            p.produced_all = true;
        } else if (r.eos) {
            p.endPass();
        } else if (r.image == null) {
            p.produced_all = true; // render failed (out of memory)
        }
        p.pump(app);
        p.wakeViews(app);
    }
};

const WakeJob = struct {
    app: *App,
    id: u64,
    deadline: u64,

    pub fn finish(self: *WakeJob) void {
        const ps = playersMut(self.app) orelse return;
        const p = ps.find(self.id) orelse return;
        if (p.wake_at == self.deadline) p.wake_at = null;
        p.wakeViews(self.app);
    }
};
