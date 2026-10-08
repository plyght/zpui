//! macOS output: the DefaultOutput AudioUnit (AudioToolbox) with a render
//! callback that mixes straight into the HAL's IO buffer. The stream format
//! is f32 interleaved stereo at the device's nominal rate (no converter),
//! and the device IO buffer is set to 256 frames (≈5.3 ms at 48 kHz),
//! clamped to the device's range. Suspend = AudioOutputUnitStop (the unit
//! stays initialized, so a restart is just AudioOutputUnitStart); with no
//! running IO proc the HAL stops the device's IO thread entirely.
//! A listener on kAudioHardwarePropertyDefaultOutputDevice re-applies the
//! format/buffer size when the user switches outputs.

const std = @import("std");
const ca = @import("ca.zig");
const engine = @import("engine.zig");
const Engine = engine.Engine;
const log = std.log.scoped(.zpui_audio);

const default_output_addr: ca.AudioObjectPropertyAddress = .{ .selector = ca.hw_default_output_device };

pub const Backend = struct {
    gpa: std.mem.Allocator,
    engine: *Engine,
    info: engine.DeviceInfo = .{},
    unit: ca.AudioUnit,
    want_frames: u32,
    fallback_rate: u32,
    initialized: bool = false,

    pub fn open(gpa: std.mem.Allocator, e: *Engine, o: engine.OpenOptions) engine.OpenError!*Backend {
        const desc: ca.AudioComponentDescription = .{
            .componentType = ca.kAudioUnitType_Output,
            .componentSubType = ca.kAudioUnitSubType_DefaultOutput,
            .componentManufacturer = ca.kAudioUnitManufacturer_Apple,
        };
        const comp = ca.AudioComponentFindNext(null, &desc) orelse return error.Unavailable;
        var unit: ?ca.AudioUnit = null;
        if (ca.AudioComponentInstanceNew(comp, &unit) != 0 or unit == null) return error.Unavailable;
        const self = gpa.create(Backend) catch {
            _ = ca.AudioComponentInstanceDispose(unit.?);
            return error.OutOfMemory;
        };
        self.* = .{
            .gpa = gpa,
            .engine = e,
            .unit = unit.?,
            .want_frames = if (o.buffer_frames != 0) o.buffer_frames else 256,
            .fallback_rate = o.rate,
        };
        const cb: ca.AURenderCallbackStruct = .{ .inputProc = render, .inputProcRefCon = self };
        if (ca.AudioUnitSetProperty(self.unit, ca.kAudioUnitProperty_SetRenderCallback, ca.kAudioUnitScope_Input, 0, &cb, @sizeOf(ca.AURenderCallbackStruct)) != 0 or
            !self.configure())
        {
            _ = ca.AudioComponentInstanceDispose(self.unit);
            gpa.destroy(self);
            return error.Unavailable;
        }
        _ = ca.AudioObjectAddPropertyListener(ca.system_object, &default_output_addr, onDefaultChanged, self);
        return self;
    }

    /// Applies rate, format and IO buffer size for the current default
    /// device and initializes the unit. The unit must be stopped.
    fn configure(self: *Backend) bool {
        if (self.initialized) {
            _ = ca.AudioUnitUninitialize(self.unit);
            self.initialized = false;
        }
        const dev = ca.get(ca.AudioObjectID, ca.system_object, default_output_addr) orelse 0;
        var rate: u32 = self.fallback_rate;
        var frames = self.want_frames;
        var dev_latency: u32 = 0;
        if (dev != 0) {
            if (ca.get(f64, dev, .{ .selector = ca.dev_nominal_sample_rate })) |r| {
                if (r >= 8000) rate = @intFromFloat(r);
            }
            if (ca.get(ca.AudioValueRange, dev, .{ .selector = ca.dev_buffer_frame_size_range })) |range| {
                frames = std.math.clamp(frames, @as(u32, @intFromFloat(range.min)), @as(u32, @intFromFloat(range.max)));
            }
            const addr: ca.AudioObjectPropertyAddress = .{ .selector = ca.dev_buffer_frame_size };
            if (ca.AudioObjectSetPropertyData(dev, &addr, 0, null, @sizeOf(u32), &frames) != 0) {
                log.debug("audio: could not set the CoreAudio IO buffer size", .{});
            }
            frames = ca.get(u32, dev, addr) orelse frames;
            dev_latency = (ca.get(u32, dev, .{ .selector = ca.dev_latency, .scope = ca.scope_output }) orelse 0) +
                (ca.get(u32, dev, .{ .selector = ca.dev_safety_offset, .scope = ca.scope_output }) orelse 0);
        }
        const asbd: ca.AudioStreamBasicDescription = .{
            .mSampleRate = @floatFromInt(rate),
            .mFormatID = ca.kAudioFormatLinearPCM,
            .mFormatFlags = ca.kAudioFormatFlagIsFloat | ca.kAudioFormatFlagIsPacked,
            .mBytesPerPacket = 8,
            .mFramesPerPacket = 1,
            .mBytesPerFrame = 8,
            .mChannelsPerFrame = 2,
            .mBitsPerChannel = 32,
        };
        if (ca.AudioUnitSetProperty(self.unit, ca.kAudioUnitProperty_StreamFormat, ca.kAudioUnitScope_Input, 0, &asbd, @sizeOf(ca.AudioStreamBasicDescription)) != 0) return false;
        if (ca.AudioUnitInitialize(self.unit) != 0) return false;
        self.initialized = true;
        self.engine.mixer.setRate(rate);
        self.info = .{
            .rate = rate,
            .channels = 2,
            .period_frames = frames,
            .latency_ns = @as(u64, frames + dev_latency) * std.time.ns_per_s / rate,
        };
        return true;
    }

    pub fn close(self: *Backend) void {
        _ = ca.AudioObjectRemovePropertyListener(ca.system_object, &default_output_addr, onDefaultChanged, self);
        _ = ca.AudioOutputUnitStop(self.unit);
        if (self.initialized) _ = ca.AudioUnitUninitialize(self.unit);
        _ = ca.AudioComponentInstanceDispose(self.unit);
        self.gpa.destroy(self);
    }

    pub fn start(self: *Backend) bool {
        if (!self.initialized and !self.configure()) return false;
        return ca.AudioOutputUnitStart(self.unit) == 0;
    }

    pub fn stop(self: *Backend) void {
        _ = ca.AudioOutputUnitStop(self.unit);
    }

    /// Control thread: the default output changed. The DefaultOutput unit
    /// already follows it; re-apply the rate and IO buffer size for it.
    pub fn deviceChanged(self: *Backend, running: bool) void {
        if (running) _ = ca.AudioOutputUnitStop(self.unit);
        if (!self.configure()) log.warn("audio: could not configure the new default output", .{});
        if (running and self.initialized) _ = ca.AudioOutputUnitStart(self.unit);
        log.info("audio: default output changed: {d} Hz, {d}-frame buffer", .{ self.info.rate, self.info.period_frames });
    }

    fn onDefaultChanged(_: ca.AudioObjectID, _: u32, _: [*]const ca.AudioObjectPropertyAddress, client: ?*anyopaque) callconv(.c) ca.OSStatus {
        const self: *Backend = @ptrCast(@alignCast(client.?));
        self.engine.device_changed.store(true, .release);
        self.engine.poke();
        return 0;
    }

    fn render(refcon: ?*anyopaque, flags: *u32, _: *const ca.AudioTimeStamp, _: u32, frames: u32, io: ?*ca.AudioBufferList) callconv(.c) ca.OSStatus {
        _ = flags;
        const self: *Backend = @ptrCast(@alignCast(refcon.?));
        const list = io orelse return 0;
        if (list.mNumberBuffers == 0) return 0;
        const b = &list.mBuffers[0];
        const ptr = b.mData orelse return 0;
        const ch: usize = @max(1, b.mNumberChannels);
        const n = @min(frames, b.mDataByteSize / @as(u32, @intCast(ch * 4)));
        const out: [*]f32 = @ptrCast(@alignCast(ptr));
        self.engine.render(f32, out[0 .. n * ch], n, ch);
        return 0;
    }
};
