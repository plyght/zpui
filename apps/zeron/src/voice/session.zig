//! The dictation session and its worker — zeron `Session`, `run_job`,
//! `record`, `BusyGuard` and the `WORKER` thread (lib.rs).
//!
//! One worker thread serialises model loading and inference and keeps the
//! loaded recognizer for 30 s of idleness (or until `unload`). Each job opens
//! the microphone on its own capture thread while the worker loads the
//! model, so Listening never waits for the model; Stop closes the microphone
//! before inference. A process-wide admission flag (`busy`) is held from
//! `Session.start` until the job's native work has returned, so Settings
//! cannot remove the model mid-load and rapid retries cannot wedge it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const sync = @import("sync.zig");
const capture_mod = @import("capture.zig");
const recognizer = @import("recognizer.zig");

pub const max_seconds = capture_mod.max_seconds;

pub const msg = struct {
    pub const busy = "Dictation is still active or finishing. Wait a moment, then try again.";
    pub const worker = "Dictation worker unavailable";
    pub const load = "Could not load the model. Remove it in Settings and download again.";
    pub const no_microphone = "No microphone available";
    pub const format = "Unsupported microphone format";
    pub const stream = "Could not open the microphone";
    pub const disconnected = "Microphone disconnected. Your draft is safe.";
};

/// Worker → UI. Strings are owned by the receiver of `poll`.
pub const Event = union(enum) {
    listening,
    finalizing,
    final: []u8,
    failed: []u8,

    pub fn deinit(self: Event, gpa: Allocator) void {
        switch (self) {
            .final, .failed => |s| gpa.free(s),
            else => {},
        }
    }
};

/// State shared by the session (UI) and the worker; freed by the last ref.
pub const Job = struct {
    gpa: Allocator,
    io: Io,
    refs: std.atomic.Value(u32) = .init(2),
    dir: []u8,
    device: ?[]u8,
    stop: std.atomic.Value(bool) = .init(false),
    cancel: std.atomic.Value(bool) = .init(false),
    level: std.atomic.Value(u32) = .init(0),
    lock: sync.Mutex = .{},
    events: [4]Event = undefined,
    head: usize = 0,
    len: usize = 0,

    /// `SyncSender::try_send` on a 4-slot channel: drops when full.
    pub fn trySend(self: *Job, ev: Event) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.len == self.events.len) return ev.deinit(self.gpa);
        self.events[(self.head + self.len) % self.events.len] = ev;
        self.len += 1;
    }

    fn tryRecv(self: *Job) ?Event {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.len == 0) return null;
        const ev = self.events[self.head];
        self.head = (self.head + 1) % self.events.len;
        self.len -= 1;
        return ev;
    }

    pub fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        while (self.tryRecv()) |ev| ev.deinit(self.gpa);
        self.gpa.free(self.dir);
        if (self.device) |d| self.gpa.free(d);
        self.gpa.destroy(self);
    }

    fn sendFailed(self: *Job, text: []const u8) void {
        const s = self.gpa.dupe(u8, text) catch return;
        self.trySend(.{ .failed = s });
    }
};

// ---- the coordinator (`run_job` / `record`), with injectable seams ---------

/// An open recording (`Recording`): polled for its end, then finished
/// (closing the device) or aborted.
pub const Recording = struct {
    ctx: *anyopaque,
    ended: *const fn (*anyopaque) bool,
    finish: *const fn (*anyopaque) anyerror!struct { []f32, u32 },
    abort: *const fn (*anyopaque) void,
};

pub const Hooks = struct {
    ctx: *anyopaque,
    /// Open the microphone (may block while the device opens).
    start: *const fn (*anyopaque, *Job) anyerror!Recording,
    /// Make the model ready (cached across jobs).
    load: *const fn (*anyopaque, *Job) anyerror!void,
    /// Transcribe (takes ownership of the samples).
    transcribe: *const fn (*anyopaque, []f32, u32) anyerror![]u8,
};

pub const Failure = struct { message: []const u8 };

const Recorded = union(enum) { none, audio: struct { []f32, u32 }, failed: []const u8 };

fn record(job: *Job, hooks: Hooks) Recorded {
    if (job.cancel.load(.acquire) or job.stop.load(.acquire)) return .none;
    const rec = hooks.start(hooks.ctx, job) catch |e| return .{ .failed = startMessage(e) };
    // Stop/cancel may arrive while the audio device is opening.
    if (job.cancel.load(.acquire)) {
        rec.abort(rec.ctx);
        return .none;
    }
    if (!job.stop.load(.acquire)) job.trySend(.listening);
    const started = sync.now();
    while (!job.stop.load(.acquire) and !job.cancel.load(.acquire) and !rec.ended(rec.ctx) and
        (sync.now() - started) / std.time.ns_per_s < max_seconds)
    {
        sync.sleepMs(10);
    }
    if (job.cancel.load(.acquire)) {
        rec.abort(rec.ctx);
        return .none;
    }
    // Close the microphone before waiting for the model.
    const audio = rec.finish(rec.ctx) catch |e| return .{ .failed = if (e == error.Disconnected) msg.disconnected else msg.stream };
    job.trySend(.finalizing);
    return .{ .audio = audio };
}

fn startMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.NoMicrophone => msg.no_microphone,
        error.UnsupportedFormat => msg.format,
        else => msg.stream,
    };
}

pub const Outcome = union(enum) {
    /// Cancelled: no event.
    none,
    text: []u8,
    failed: []const u8,
};

/// `run_job`: capture on its own thread while the model loads here.
pub fn runJob(job: *Job, hooks: Hooks) Outcome {
    if (job.cancel.load(.acquire)) return .none;
    var recorded: Recorded = .none;
    const Capture = struct {
        fn run(j: *Job, h: Hooks, out: *Recorded) void {
            out.* = record(j, h);
        }
    };
    const thread = std.Thread.spawn(.{}, Capture.run, .{ job, hooks, &recorded }) catch return .{ .failed = msg.stream };
    const loaded = hooks.load(hooks.ctx, job);
    // A load failure must stop capture even if the user has not pressed Stop.
    if (loaded) |_| {} else |_| job.cancel.store(true, .release);
    thread.join();
    if (loaded) |_| {} else |_| {
        if (recorded == .audio) job.gpa.free(recorded.audio[0]);
        return .{ .failed = msg.load };
    }
    if (job.cancel.load(.acquire)) {
        if (recorded == .audio) job.gpa.free(recorded.audio[0]);
        return .none;
    }
    const samples, const rate = switch (recorded) {
        .none => return .{ .text = job.gpa.dupe(u8, "") catch return .none },
        .failed => |m| return .{ .failed = m },
        .audio => |a| a,
    };
    const text = hooks.transcribe(hooks.ctx, samples, rate) catch |e| return .{ .failed = transcribeMessage(e) };
    if (job.cancel.load(.acquire)) {
        job.gpa.free(text);
        return .none;
    }
    return .{ .text = text };
}

fn transcribeMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.UnsupportedSampleRate => recognizer.msg.rate,
        error.TooLong => recognizer.msg.too_long,
        else => recognizer.msg.transcribe,
    };
}

// ---- admission + worker -----------------------------------------------------

var busy_flag: std.atomic.Value(bool) = .init(false);

pub fn busy() bool {
    return busy_flag.load(.acquire);
}

fn acquireBusy() bool {
    return busy_flag.cmpxchgStrong(false, true, .acq_rel, .monotonic) == null;
}

fn releaseBusy() void {
    busy_flag.store(false, .release);
}

const Worker = struct {
    lock: sync.Mutex = .{},
    cond: sync.Cond = .{},
    started: bool = false,
    pending: ?*Job = null,
    unload: bool = false,
    // Worker-thread only.
    cached: ?recognizer.Recognizer = null,
    cached_dir: ?[]u8 = null,
    cache_gpa: ?Allocator = null,
};

var worker: Worker = .{};

fn dropCached() void {
    if (worker.cached) |*r| r.deinit();
    worker.cached = null;
    if (worker.cached_dir) |d| worker.cache_gpa.?.free(d);
    worker.cached_dir = null;
}

const NativeHooks = struct {
    fn start(_: *anyopaque, job: *Job) anyerror!Recording {
        const cap = try capture_mod.Capture.start(job.gpa, job.device, &job.level);
        return .{ .ctx = cap, .ended = ended, .finish = finish, .abort = abort };
    }
    fn ended(ctx: *anyopaque) bool {
        const cap: *capture_mod.Capture = @ptrCast(@alignCast(ctx));
        return cap.ended();
    }
    fn finish(ctx: *anyopaque) anyerror!struct { []f32, u32 } {
        const cap: *capture_mod.Capture = @ptrCast(@alignCast(ctx));
        const samples, const rate = try cap.finish();
        return .{ samples, rate };
    }
    fn abort(ctx: *anyopaque) void {
        const cap: *capture_mod.Capture = @ptrCast(@alignCast(ctx));
        cap.abort();
    }
    fn load(_: *anyopaque, job: *Job) anyerror!void {
        if (worker.cached_dir) |d| if (std.mem.eql(u8, d, job.dir)) return;
        dropCached();
        const r = try recognizer.Recognizer.load(job.gpa, job.io, job.dir);
        worker.cached = r;
        worker.cache_gpa = job.gpa;
        worker.cached_dir = job.gpa.dupe(u8, job.dir) catch null;
    }
    fn transcribe(_: *anyopaque, samples: []f32, rate: u32) anyerror![]u8 {
        return worker.cached.?.transcribe(samples, rate);
    }
};

fn workerLoop() void {
    var dummy: u8 = 0;
    const hooks: Hooks = .{ .ctx = &dummy, .start = NativeHooks.start, .load = NativeHooks.load, .transcribe = NativeHooks.transcribe };
    while (true) {
        worker.lock.lock();
        var job: ?*Job = null;
        var retire = false;
        var timed_out = false;
        while (worker.pending == null and !worker.unload) {
            if (!worker.cond.timedWait(&worker.lock, 30_000)) {
                timed_out = worker.pending == null and !worker.unload;
                break;
            }
        }
        job = worker.pending;
        worker.pending = null;
        retire = worker.unload;
        worker.unload = false;
        worker.lock.unlock();
        if (retire or timed_out) dropCached();
        const j = job orelse continue;
        // Keep loaded weights after a microphone or recording error: it says
        // nothing about the model, and reloading takes seconds.
        switch (runJob(j, hooks)) {
            .none => {},
            .text => |t| j.trySend(.{ .final = t }),
            .failed => |m| j.sendFailed(m),
        }
        j.release();
        releaseBusy();
    }
}

pub const StartError = error{ Busy, WorkerUnavailable, OutOfMemory };

pub const Session = struct {
    job: *Job,

    /// `device` is an `InputDevice.id`; null or a disconnected device
    /// records from the system default. Error messages: `msg.busy` /
    /// `msg.worker`.
    pub fn start(gpa: Allocator, io: Io, dir: []const u8, device: ?[]const u8) StartError!Session {
        if (!acquireBusy()) return error.Busy;
        errdefer releaseBusy();
        const job = try gpa.create(Job);
        errdefer gpa.destroy(job);
        const d = try gpa.dupe(u8, dir);
        errdefer gpa.free(d);
        const dev = if (device) |x| try gpa.dupe(u8, x) else null;
        job.* = .{ .gpa = gpa, .io = io, .dir = d, .device = dev };
        worker.lock.lock();
        defer worker.lock.unlock();
        if (!worker.started) {
            const t = std.Thread.spawn(.{}, workerLoop, .{}) catch {
                if (dev) |x| gpa.free(x);
                return error.WorkerUnavailable;
            };
            t.detach();
            worker.started = true;
        }
        if (worker.pending != null) {
            if (dev) |x| gpa.free(x);
            return error.WorkerUnavailable;
        }
        worker.pending = job;
        worker.cond.signal();
        return .{ .job = job };
    }

    pub fn poll(self: *Session) ?Event {
        return self.job.tryRecv();
    }

    /// Stop recording and transcribe (idempotent).
    pub fn finish(self: *Session) void {
        self.job.stop.store(true, .release);
    }

    /// Peak microphone RMS (0–1) since the previous call.
    pub fn takeLevel(self: *Session) f32 {
        return @bitCast(self.job.level.swap(0, .monotonic));
    }

    /// Drop: cancels capture and any pending result.
    pub fn deinit(self: *Session) void {
        self.job.cancel.store(true, .release);
        self.job.release();
    }
};

/// Retire cached weights on the worker, never on the UI thread.
pub fn unload() void {
    worker.lock.lock();
    defer worker.lock.unlock();
    if (!worker.started) return;
    worker.unload = true;
    worker.cond.signal();
}

// ---- tests (session_tests.rs, on the same coordinator with fakes) ----------

const testing = std.testing;

const Fake = struct {
    gpa: Allocator,
    ended_flag: std.atomic.Value(bool) = .init(false),
    closed: std.atomic.Value(u32) = .init(0),
    opened: std.atomic.Value(bool) = .init(false),
    open_gate: std.atomic.Value(bool) = .init(true),
    load_gate: std.atomic.Value(bool) = .init(false),
    load_fails: bool = false,
    loading: std.atomic.Value(bool) = .init(false),
    transcribed: std.atomic.Value(u32) = .init(0),

    fn hooks(self: *Fake) Hooks {
        return .{ .ctx = self, .start = start, .load = load, .transcribe = transcribe };
    }
    fn start(ctx: *anyopaque, _: *Job) anyerror!Recording {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        while (!self.open_gate.load(.acquire)) sync.sleepMs(1);
        self.opened.store(true, .release);
        return .{ .ctx = self, .ended = ended, .finish = finish, .abort = abort };
    }
    fn ended(ctx: *anyopaque) bool {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.ended_flag.load(.acquire);
    }
    fn finish(ctx: *anyopaque) anyerror!struct { []f32, u32 } {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        _ = self.closed.fetchAdd(1, .acq_rel);
        const s = try self.gpa.alloc(f32, 3200);
        @memset(s, 0.25);
        return .{ s, 16_000 };
    }
    fn abort(ctx: *anyopaque) void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        _ = self.closed.fetchAdd(1, .acq_rel);
    }
    fn load(ctx: *anyopaque, _: *Job) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        self.loading.store(true, .release);
        while (!self.load_gate.load(.acquire)) sync.sleepMs(1);
        if (self.load_fails) return error.LoadFailed;
    }
    fn transcribe(ctx: *anyopaque, samples: []f32, rate: u32) anyerror![]u8 {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        defer self.gpa.free(samples);
        _ = self.transcribed.fetchAdd(1, .acq_rel);
        // Stop during load must retain the exact recording.
        if (samples.len != 3200 or samples[0] != 0.25 or rate != 16_000) return error.Mismatch;
        return self.gpa.dupe(u8, "retained speech");
    }
};

const Harness = struct {
    job: *Job,
    outcome: Outcome = .none,
    thread: std.Thread = undefined,

    fn spawn(self: *Harness, fake: *Fake) !void {
        const Run = struct {
            fn run(h: *Harness, f: *Fake) void {
                h.outcome = runJob(h.job, f.hooks());
            }
        };
        self.thread = try std.Thread.spawn(.{}, Run.run, .{ self, fake });
    }

    fn waitEvent(self: *Harness) ?Event {
        const t0 = sync.now();
        while (sync.now() - t0 < 5 * std.time.ns_per_s) {
            if (self.job.tryRecv()) |ev| return ev;
            sync.sleepMs(1);
        }
        return null;
    }
};

fn newJob(gpa: Allocator) !*Job {
    const job = try gpa.create(Job);
    job.* = .{ .gpa = gpa, .io = testing.io, .dir = try gpa.dupe(u8, ""), .device = null, .refs = .init(1) };
    return job;
}

test "listening and stop do not wait for the model and audio is retained" {
    const gpa = testing.allocator;
    var fake: Fake = .{ .gpa = gpa };
    var h: Harness = .{ .job = try newJob(gpa) };
    defer h.job.release();
    try h.spawn(&fake);
    try testing.expect(h.waitEvent().? == .listening);
    h.job.stop.store(true, .release);
    h.job.stop.store(true, .release); // repeated Stop is idempotent
    try testing.expect(h.waitEvent().? == .finalizing);
    try testing.expectEqual(@as(u32, 1), fake.closed.load(.acquire));
    try testing.expectEqual(@as(u32, 0), fake.transcribed.load(.acquire));
    fake.load_gate.store(true, .release);
    h.thread.join();
    try testing.expectEqualStrings("retained speech", h.outcome.text);
    gpa.free(h.outcome.text);
}

test "cancel during load closes the microphone without waiting for the model" {
    const gpa = testing.allocator;
    var fake: Fake = .{ .gpa = gpa };
    var h: Harness = .{ .job = try newJob(gpa) };
    defer h.job.release();
    try h.spawn(&fake);
    try testing.expect(h.waitEvent().? == .listening);
    h.job.cancel.store(true, .release);
    const t0 = sync.now();
    while (fake.closed.load(.acquire) == 0 and sync.now() - t0 < 5 * std.time.ns_per_s) sync.sleepMs(1);
    try testing.expectEqual(@as(u32, 1), fake.closed.load(.acquire));
    fake.load_gate.store(true, .release);
    h.thread.join();
    try testing.expect(h.outcome == .none);
    try testing.expectEqual(@as(u32, 0), fake.transcribed.load(.acquire));
}

test "load failure closes the live microphone before returning the error" {
    const gpa = testing.allocator;
    var fake: Fake = .{ .gpa = gpa, .load_fails = true };
    var h: Harness = .{ .job = try newJob(gpa) };
    defer h.job.release();
    try h.spawn(&fake);
    try testing.expect(h.waitEvent().? == .listening);
    fake.load_gate.store(true, .release);
    h.thread.join();
    try testing.expectEqual(@as(u32, 1), fake.closed.load(.acquire));
    try testing.expectEqualStrings(msg.load, h.outcome.failed);
}

test "stop before capture start never opens the microphone" {
    const gpa = testing.allocator;
    var fake: Fake = .{ .gpa = gpa };
    var h: Harness = .{ .job = try newJob(gpa) };
    defer h.job.release();
    h.job.stop.store(true, .release);
    fake.load_gate.store(true, .release);
    try h.spawn(&fake);
    h.thread.join();
    try testing.expect(!fake.opened.load(.acquire));
    try testing.expectEqualStrings("", h.outcome.text);
    gpa.free(h.outcome.text);
}

test "recording limit closes capture while the model is still loading" {
    const gpa = testing.allocator;
    var fake: Fake = .{ .gpa = gpa };
    var h: Harness = .{ .job = try newJob(gpa) };
    defer h.job.release();
    try h.spawn(&fake);
    try testing.expect(h.waitEvent().? == .listening);
    fake.ended_flag.store(true, .release);
    try testing.expect(h.waitEvent().? == .finalizing);
    try testing.expectEqual(@as(u32, 1), fake.closed.load(.acquire));
    fake.load_gate.store(true, .release);
    h.thread.join();
    try testing.expectEqualStrings("retained speech", h.outcome.text);
    gpa.free(h.outcome.text);
}

test "admission is exclusive until released" {
    try testing.expect(acquireBusy());
    try testing.expect(busy());
    try testing.expectError(error.Busy, Session.start(testing.allocator, testing.io, "", null));
    releaseBusy();
    try testing.expect(!busy());
}
