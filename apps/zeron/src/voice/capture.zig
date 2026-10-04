//! Microphone capture — zeron `Capture` (lib.rs) without cpal. The device's
//! native rate and channel count are kept; every buffer is downmixed to mono
//! f32 into a bounded (60 s) recording while the loudest RMS since the UI
//! last looked is published lock-free.
//!
//! Backends, both loaded at run time so the binary needs neither:
//! - Linux: PulseAudio (`libpulse.so.0` / `libpulse-simple.so.0`; PipeWire
//!   serves it through pipewire-pulse). Device ids are `pulse:<source>`
//!   (Rust's cpal ALSA ids are `alsa:<pcm>`; a saved id from the Rust app
//!   falls back to the system default, as a disconnected device does).
//! - macOS: an AudioToolbox input `AudioQueue` on the CoreAudio device;
//!   ids are cpal's `coreaudio:<device UID>`.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const sync = @import("sync.zig");

pub const max_seconds = 60;

pub const InputDevice = struct {
    id: []u8,
    name: []u8,

    pub fn deinit(self: InputDevice, gpa: Allocator) void {
        gpa.free(self.id);
        gpa.free(self.name);
    }
};

pub fn freeDevices(gpa: Allocator, devices: []InputDevice) void {
    for (devices) |d| d.deinit(gpa);
    gpa.free(devices);
}

/// The recording shared between the audio callback and the worker.
pub const Audio = struct {
    lock: sync.Mutex = .{},
    samples: std.ArrayList(f32) = .empty,
    capacity: usize,
    failed: std.atomic.Value(bool) = .init(false),
    full: std.atomic.Value(bool) = .init(false),

    /// Only the audio callback appends until the stream is dropped; a
    /// contended lock drops the buffer rather than block the callback.
    pub fn append(self: *Audio, data: []const f32, channels: usize) void {
        if (!self.lock.tryLock()) return;
        defer self.lock.unlock();
        appendFrames(&self.samples, self.capacity, &self.full, data, channels);
    }
};

/// Rust `append`: mono mean of each frame, stopping at `capacity`.
pub fn appendFrames(samples: *std.ArrayList(f32), capacity: usize, full: *std.atomic.Value(bool), data: []const f32, channels: usize) void {
    const ch = @max(channels, 1);
    var i: usize = 0;
    while (i + ch <= data.len) : (i += ch) {
        if (samples.items.len >= capacity) {
            full.store(true, .release);
            break;
        }
        var sum: f32 = 0;
        for (data[i .. i + ch]) |s| sum += s;
        // Capacity is reserved up front; never allocate in the callback.
        samples.appendAssumeCapacity(sum / @as(f32, @floatFromInt(ch)));
    }
}

/// Rust `meter`: the buffer's RMS of the mono mixdown folded into `level`
/// with `fetch_max` on the bit pattern (non-negative floats sort like their
/// bits).
pub fn meter(data: []const f32, channels: usize, level: *std.atomic.Value(u32)) void {
    const ch = @max(channels, 1);
    const frames = data.len / ch;
    if (frames == 0) return;
    var energy: f32 = 0;
    var i: usize = 0;
    while (i + ch <= data.len) : (i += ch) {
        var sum: f32 = 0;
        for (data[i .. i + ch]) |s| sum += s;
        const s = sum / @as(f32, @floatFromInt(ch));
        energy += s * s;
    }
    const rms = @sqrt(energy / @as(f32, @floatFromInt(frames)));
    if (std.math.isFinite(rms)) _ = level.fetchMax(@bitCast(rms), .monotonic);
}

pub const StartError = error{ NoMicrophone, UnsupportedFormat, StreamFailed, OutOfMemory };

pub const Capture = struct {
    gpa: Allocator,
    audio: *Audio,
    level: *std.atomic.Value(u32),
    rate: u32,
    channels: usize,
    backend: Backend,

    /// `device` is an `InputDevice.id`; null or a disconnected device
    /// records from the system default.
    pub fn start(gpa: Allocator, device: ?[]const u8, level: *std.atomic.Value(u32)) StartError!*Capture {
        const self = try gpa.create(Capture);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .audio = undefined, .level = level, .rate = 0, .channels = 1, .backend = undefined };
        try Backend.open(self, device);
        return self;
    }

    /// Called from the backend once the native format is known.
    pub fn allocAudio(self: *Capture, rate: u32, channels: usize) StartError!void {
        self.rate = rate;
        self.channels = channels;
        const audio = try self.gpa.create(Audio);
        audio.* = .{ .capacity = @as(usize, rate) * max_seconds };
        audio.samples.ensureTotalCapacity(self.gpa, audio.capacity) catch {
            self.gpa.destroy(audio);
            return error.OutOfMemory;
        };
        self.audio = audio;
    }

    /// The real-time callback body.
    pub fn deliver(self: *Capture, data: []const f32) void {
        meter(data, self.channels, self.level);
        self.audio.append(data, self.channels);
    }

    pub fn ended(self: *const Capture) bool {
        return self.audio.full.load(.acquire) or self.audio.failed.load(.acquire);
    }

    /// Close the stream and hand back the mono recording and its rate.
    pub fn finish(self: *Capture) error{ Disconnected, OutOfMemory }!struct { []f32, u32 } {
        self.backend.close();
        defer self.destroy();
        if (self.audio.failed.load(.acquire)) return error.Disconnected;
        self.audio.lock.lock();
        defer self.audio.lock.unlock();
        const out = try self.audio.samples.toOwnedSlice(self.gpa);
        return .{ out, self.rate };
    }

    /// Close and discard (cancellation).
    pub fn abort(self: *Capture) void {
        self.backend.close();
        self.destroy();
    }

    fn destroy(self: *Capture) void {
        self.audio.samples.deinit(self.gpa);
        self.gpa.destroy(self.audio);
        self.gpa.destroy(self);
    }
};

const Backend = switch (builtin.os.tag) {
    .linux => @import("capture_pulse.zig").Backend,
    .macos => @import("capture_mac.zig").Backend,
    else => struct {
        fn open(_: *Capture, _: ?[]const u8) StartError!void {
            return error.NoMicrophone;
        }
        fn close(_: *@This()) void {}
    },
};

/// Every input device the default host reports (blocks on the audio
/// server: call it off the UI thread). Caller frees with `freeDevices`.
pub fn inputDevices(gpa: Allocator) []InputDevice {
    return switch (builtin.os.tag) {
        .linux => @import("capture_pulse.zig").inputDevices(gpa),
        .macos => @import("capture_mac.zig").inputDevices(gpa),
        else => &.{},
    };
}

/// The id of the device the system records from by default (caller frees).
pub fn defaultInputDevice(gpa: Allocator) ?[]u8 {
    return switch (builtin.os.tag) {
        .linux => @import("capture_pulse.zig").defaultInputDevice(gpa),
        .macos => @import("capture_mac.zig").defaultInputDevice(gpa),
        else => null,
    };
}

test "native sample formats preserve levels and downmix channels" {
    const gpa = std.testing.allocator;
    const input = [_]f32{ -0.5, 0.5, 0.25, 0.75, 0.0, 0.0 };
    var samples: std.ArrayList(f32) = .empty;
    defer samples.deinit(gpa);
    try samples.ensureTotalCapacity(gpa, 16);
    var full: std.atomic.Value(bool) = .init(false);
    appendFrames(&samples, 16, &full, &input, 2);
    try std.testing.expectEqualSlices(f32, &.{ 0.0, 0.5, 0.0 }, samples.items);
    var level: std.atomic.Value(u32) = .init(0);
    meter(&input, 2, &level);
    const rms: f32 = @bitCast(level.load(.monotonic));
    try std.testing.expect(@abs(rms - @sqrt(@as(f32, 0.25) / 3.0)) < 0.01);
    meter(input[4..], 2, &level);
    try std.testing.expectEqual(rms, @as(f32, @bitCast(level.load(.monotonic))));
    // The bound flags the recording full instead of growing.
    appendFrames(&samples, 4, &full, &input, 2);
    try std.testing.expectEqual(@as(usize, 4), samples.items.len);
    try std.testing.expect(full.load(.acquire));
}

test "device enumeration and capture start degrade without an audio server" {
    const gpa = std.testing.allocator;
    const devices = inputDevices(gpa);
    defer freeDevices(gpa, devices);
    if (defaultInputDevice(gpa)) |d| gpa.free(d);
    var level: std.atomic.Value(u32) = .init(0);
    if (Capture.start(gpa, "pulse:missing", &level)) |cap| {
        cap.abort();
    } else |err| switch (err) {
        error.NoMicrophone, error.UnsupportedFormat, error.StreamFailed => {},
        error.OutOfMemory => return err,
    }
}
