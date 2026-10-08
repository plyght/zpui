//! Windows output: WASAPI shared mode, event-driven, on a dedicated render
//! thread registered with MMCSS ("Pro Audio"). All COM objects live on
//! that thread (MTA). With IAudioClient3 (Windows 10+) the stream asks for
//! the engine's minimum shared-mode period (commonly 128–240 frames on
//! drivers that support it, else 10 ms); otherwise IAudioClient with the
//! default period. The buffer is kept filled to two periods.
//!
//! Suspend: IAudioClient::Stop + Reset, then the thread blocks on the
//! engine's wake event (no buffer events while stopped). Resume pre-fills
//! a buffer — the pending click included — and calls Start.
//! An IMMNotificationClient flags default-device changes; the thread
//! reopens the new default endpoint (keeping its running state).
//!
//! COM interfaces are declared by hand below (vtable layouts from
//! mmdeviceapi.h / audioclient.h / audiopolicy.h).

const std = @import("std");
const sys = @import("sys.zig");
const engine = @import("engine.zig");
const Engine = engine.Engine;
const w = sys.windows;
const log = std.log.scoped(.zpui_audio);

pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;
pub const S_FALSE: HRESULT = 1;
pub const AUDCLNT_E_DEVICE_INVALIDATED: HRESULT = @bitCast(@as(u32, 0x88890004));
pub const CLSCTX_ALL: u32 = 0x17;
pub const COINIT_MULTITHREADED: u32 = 0;
pub const eRender: u32 = 0;
pub const eCapture: u32 = 1;
pub const eConsole: u32 = 0;
pub const eMultimedia: u32 = 1;
pub const eCommunications: u32 = 2;
const AUDCLNT_SHAREMODE_SHARED: u32 = 0;
const AUDCLNT_STREAMFLAGS_EVENTCALLBACK: u32 = 0x0004_0000;
const AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM: u32 = 0x8000_0000;
const AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY: u32 = 0x0800_0000;
const WAVE_FORMAT_PCM = 1;
const WAVE_FORMAT_IEEE_FLOAT = 3;
const WAVE_FORMAT_EXTENSIBLE = 0xFFFE;

pub const GUID = extern struct {
    d1: u32,
    d2: u16,
    d3: u16,
    d4: [8]u8,

    /// "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    pub fn parse(comptime s: *const [36]u8) GUID {
        @setEvalBranchQuota(10_000);
        const hex = struct {
            fn f(comptime t: []const u8) u64 {
                return std.fmt.parseInt(u64, t, 16) catch unreachable;
            }
        }.f;
        var g: GUID = .{ .d1 = @intCast(hex(s[0..8])), .d2 = @intCast(hex(s[9..13])), .d3 = @intCast(hex(s[14..18])), .d4 = undefined };
        g.d4[0] = @intCast(hex(s[19..21]));
        g.d4[1] = @intCast(hex(s[21..23]));
        for (0..6) |i| g.d4[2 + i] = @intCast(hex(s[24 + 2 * i ..][0..2]));
        return g;
    }

    pub fn eql(a: *const GUID, b: *const GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
    }
};

pub const CLSID_MMDeviceEnumerator = GUID.parse("bcde0395-e52f-467c-8e3d-c4579291692e");
pub const IID_IUnknown = GUID.parse("00000000-0000-0000-c000-000000000046");
pub const IID_IMMDeviceEnumerator = GUID.parse("a95664d2-9614-4f35-a746-de8db63617e6");
pub const IID_IMMNotificationClient = GUID.parse("7991eec9-7e89-4d85-8390-6c703cec60c0");
const IID_IAudioClient = GUID.parse("1cb9ad4c-dbfa-4c32-b178-c2f568a703b2");
const IID_IAudioClient3 = GUID.parse("7ed4ee07-8e67-4cd4-8c1a-2b7a5987ad42");
const IID_IAudioRenderClient = GUID.parse("f294acfc-3146-4483-a7bf-addca7c260e2");
const KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = GUID.parse("00000003-0000-0010-8000-00aa00389b71");

/// Unused vtable slot.
const Slot = ?*const anyopaque;

pub fn release(p: anytype) void {
    _ = p.vtbl.Release(p);
}

pub const IMMDeviceEnumerator = extern struct {
    vtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IMMDeviceEnumerator) callconv(.winapi) u32,
        EnumAudioEndpoints: Slot,
        GetDefaultAudioEndpoint: *const fn (*IMMDeviceEnumerator, u32, u32, *?*IMMDevice) callconv(.winapi) HRESULT,
        GetDevice: Slot,
        RegisterEndpointNotificationCallback: *const fn (*IMMDeviceEnumerator, *IMMNotificationClient) callconv(.winapi) HRESULT,
        UnregisterEndpointNotificationCallback: *const fn (*IMMDeviceEnumerator, *IMMNotificationClient) callconv(.winapi) HRESULT,
    };
};

pub const IMMDevice = extern struct {
    vtbl: *const Vtbl,
    pub const Vtbl = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IMMDevice) callconv(.winapi) u32,
        Activate: *const fn (*IMMDevice, *const GUID, u32, ?*anyopaque, *?*anyopaque) callconv(.winapi) HRESULT,
        OpenPropertyStore: Slot,
        GetId: Slot,
        GetState: Slot,
    };
};

pub const WaveFormatEx = extern struct {
    tag: u16,
    channels: u16,
    rate: u32,
    avg_bytes: u32,
    block_align: u16,
    bits: u16,
    cb_size: u16,
    // WAVEFORMATEXTENSIBLE tail (valid when tag == EXTENSIBLE, cb_size ≥ 22).
    valid_bits: u16,
    channel_mask: u32,
    sub_format: GUID,
};
comptime {
    std.debug.assert(@offsetOf(WaveFormatEx, "valid_bits") == 18);
    std.debug.assert(@offsetOf(WaveFormatEx, "sub_format") == 24);
}

const IAudioClient3 = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IAudioClient3) callconv(.winapi) u32,
        Initialize: *const fn (*IAudioClient3, u32, u32, i64, i64, *const WaveFormatEx, ?*const GUID) callconv(.winapi) HRESULT,
        GetBufferSize: *const fn (*IAudioClient3, *u32) callconv(.winapi) HRESULT,
        GetStreamLatency: *const fn (*IAudioClient3, *i64) callconv(.winapi) HRESULT,
        GetCurrentPadding: *const fn (*IAudioClient3, *u32) callconv(.winapi) HRESULT,
        IsFormatSupported: Slot,
        GetMixFormat: *const fn (*IAudioClient3, *?*WaveFormatEx) callconv(.winapi) HRESULT,
        GetDevicePeriod: *const fn (*IAudioClient3, ?*i64, ?*i64) callconv(.winapi) HRESULT,
        Start: *const fn (*IAudioClient3) callconv(.winapi) HRESULT,
        Stop: *const fn (*IAudioClient3) callconv(.winapi) HRESULT,
        Reset: *const fn (*IAudioClient3) callconv(.winapi) HRESULT,
        SetEventHandle: *const fn (*IAudioClient3, w.HANDLE) callconv(.winapi) HRESULT,
        GetService: *const fn (*IAudioClient3, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        // IAudioClient2
        IsOffloadCapable: Slot,
        SetClientProperties: Slot,
        GetBufferSizeLimits: Slot,
        // IAudioClient3 (only called when activated as IAudioClient3)
        GetSharedModeEnginePeriod: *const fn (*IAudioClient3, *const WaveFormatEx, *u32, *u32, *u32, *u32) callconv(.winapi) HRESULT,
        GetCurrentSharedModeEnginePeriod: Slot,
        InitializeSharedAudioStream: *const fn (*IAudioClient3, u32, u32, *const WaveFormatEx, ?*const GUID) callconv(.winapi) HRESULT,
    };
};

const IAudioRenderClient = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IAudioRenderClient) callconv(.winapi) u32,
        GetBuffer: *const fn (*IAudioRenderClient, u32, *?[*]u8) callconv(.winapi) HRESULT,
        ReleaseBuffer: *const fn (*IAudioRenderClient, u32, u32) callconv(.winapi) HRESULT,
    };
};

pub const PROPERTYKEY = extern struct { fmtid: GUID, pid: u32 };

/// Our IMMNotificationClient implementation (static vtable, no refcount:
/// it lives as long as the backend and is unregistered before freeing).
pub const IMMNotificationClient = extern struct {
    vtbl: *const Vtbl,
    engine: ?*Engine = null,
    ctx: ?*anyopaque = null,
    pub const Vtbl = extern struct {
        QueryInterface: *const fn (*IMMNotificationClient, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IMMNotificationClient) callconv(.winapi) u32,
        Release: *const fn (*IMMNotificationClient) callconv(.winapi) u32,
        OnDeviceStateChanged: *const fn (*IMMNotificationClient, ?[*:0]const u16, u32) callconv(.winapi) HRESULT,
        OnDeviceAdded: *const fn (*IMMNotificationClient, ?[*:0]const u16) callconv(.winapi) HRESULT,
        OnDeviceRemoved: *const fn (*IMMNotificationClient, ?[*:0]const u16) callconv(.winapi) HRESULT,
        OnDefaultDeviceChanged: *const fn (*IMMNotificationClient, u32, u32, ?[*:0]const u16) callconv(.winapi) HRESULT,
        OnPropertyValueChanged: *const fn (*IMMNotificationClient, ?[*:0]const u16, PROPERTYKEY) callconv(.winapi) HRESULT,
    };

    const vtable: Vtbl = .{
        .QueryInterface = qi,
        .AddRef = addRef,
        .Release = addRef,
        .OnDeviceStateChanged = onState,
        .OnDeviceAdded = onId,
        .OnDeviceRemoved = onId,
        .OnDefaultDeviceChanged = onDefault,
        .OnPropertyValueChanged = onProp,
    };

    fn qi(self: *IMMNotificationClient, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        if (iid.eql(&IID_IUnknown) or iid.eql(&IID_IMMNotificationClient)) {
            out.* = self;
            return S_OK;
        }
        out.* = null;
        return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
    }
    fn addRef(_: *IMMNotificationClient) callconv(.winapi) u32 {
        return 1;
    }
    fn onState(_: *IMMNotificationClient, _: ?[*:0]const u16, _: u32) callconv(.winapi) HRESULT {
        return S_OK;
    }
    fn onId(_: *IMMNotificationClient, _: ?[*:0]const u16) callconv(.winapi) HRESULT {
        return S_OK;
    }
    fn onProp(_: *IMMNotificationClient, _: ?[*:0]const u16, _: PROPERTYKEY) callconv(.winapi) HRESULT {
        return S_OK;
    }
    fn onDefault(self: *IMMNotificationClient, flow: u32, role: u32, _: ?[*:0]const u16) callconv(.winapi) HRESULT {
        if (flow == eRender and role == eConsole) {
            if (self.engine) |e| {
                e.device_changed.store(true, .release);
                e.poke();
            }
        }
        return S_OK;
    }
};

pub extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, coinit: u32) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, ctx: u32, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;

pub fn createEnumerator() ?*IMMDeviceEnumerator {
    var p: ?*anyopaque = null;
    if (CoCreateInstance(&CLSID_MMDeviceEnumerator, null, CLSCTX_ALL, &IID_IMMDeviceEnumerator, &p) < 0) return null;
    return @ptrCast(@alignCast(p orelse return null));
}

/// MMCSS registration via avrt.dll (loaded at run time).
const Mmcss = struct {
    handle: ?w.HANDLE = null,
    revert: ?*const fn (w.HANDLE) callconv(.winapi) w.BOOL = null,

    fn join() Mmcss {
        const lib = w.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("avrt.dll")) orelse return .{};
        const set: *const fn ([*:0]const u16, *u32) callconv(.winapi) ?w.HANDLE = @ptrCast(w.GetProcAddress(lib, "AvSetMmThreadCharacteristicsW") orelse return .{});
        const revert: *const fn (w.HANDLE) callconv(.winapi) w.BOOL = @ptrCast(w.GetProcAddress(lib, "AvRevertMmThreadCharacteristics") orelse return .{});
        var task: u32 = 0;
        const h = set(std.unicode.utf8ToUtf16LeStringLiteral("Pro Audio"), &task) orelse return .{};
        return .{ .handle = h, .revert = revert };
    }

    fn leave(self: Mmcss) void {
        if (self.handle) |h| _ = self.revert.?(h);
    }
};

const SampleType = enum { f32, i16 };

pub const Backend = struct {
    gpa: std.mem.Allocator,
    engine: *Engine,
    info: engine.DeviceInfo = .{},
    want_frames: u32,
    thread: ?std.Thread = null,
    ready: sys.Event = .{},
    open_ok: std.atomic.Value(u8) = .init(0), // 0 pending, 1 ok, 2 failed
    // Render-thread state.
    enumerator: ?*IMMDeviceEnumerator = null,
    notif: IMMNotificationClient = .{ .vtbl = &IMMNotificationClient.vtable },
    notif_registered: bool = false,
    device: ?*IMMDevice = null,
    client: ?*IAudioClient3 = null,
    render_client: ?*IAudioRenderClient = null,
    buffer_event: ?w.HANDLE = null,
    sample: SampleType = .f32,
    channels: u32 = 2,
    buffer_frames: u32 = 0,
    target_frames: u32 = 0,

    pub fn open(gpa: std.mem.Allocator, e: *Engine, o: engine.OpenOptions) engine.OpenError!*Backend {
        const self = try gpa.create(Backend);
        self.* = .{ .gpa = gpa, .engine = e, .want_frames = o.buffer_frames };
        self.notif.engine = e;
        self.ready.init() catch {
            gpa.destroy(self);
            return error.Unavailable;
        };
        self.buffer_event = w.CreateEventW(null, 0, 0, null) orelse {
            self.ready.deinit();
            gpa.destroy(self);
            return error.Unavailable;
        };
        self.thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, run, .{self}) catch {
            self.free();
            return error.Unavailable;
        };
        while (self.open_ok.load(.acquire) == 0) _ = self.ready.wait(100 * std.time.ns_per_ms);
        if (self.open_ok.load(.acquire) != 1) {
            self.thread.?.join();
            self.free();
            return error.Unavailable;
        }
        return self;
    }

    fn free(self: *Backend) void {
        if (self.buffer_event) |h| _ = w.CloseHandle(h);
        self.ready.deinit();
        self.gpa.destroy(self);
    }

    /// `Audio.deinit` has already set `engine.quit` and signalled the wake event.
    pub fn close(self: *Backend) void {
        if (self.thread) |t| t.join();
        self.free();
    }

    fn releaseDevice(self: *Backend) void {
        if (self.client) |c| _ = c.vtbl.Stop(c);
        if (self.render_client) |r| release(r);
        if (self.client) |c| release(c);
        if (self.device) |d| release(d);
        self.render_client = null;
        self.client = null;
        self.device = null;
    }

    /// Render thread: opens the default render endpoint and initializes a
    /// stopped, event-driven shared stream.
    fn openDevice(self: *Backend) bool {
        const en = self.enumerator orelse return false;
        var dev: ?*IMMDevice = null;
        if (en.vtbl.GetDefaultAudioEndpoint(en, eRender, eConsole, &dev) < 0 or dev == null) return false;
        self.device = dev;
        var p: ?*anyopaque = null;
        var v3 = true;
        if (dev.?.vtbl.Activate(dev.?, &IID_IAudioClient3, CLSCTX_ALL, null, &p) < 0 or p == null) {
            v3 = false;
            if (dev.?.vtbl.Activate(dev.?, &IID_IAudioClient, CLSCTX_ALL, null, &p) < 0 or p == null) return false;
        }
        const client: *IAudioClient3 = @ptrCast(@alignCast(p.?));
        self.client = client;

        var mix: ?*WaveFormatEx = null;
        if (client.vtbl.GetMixFormat(client, &mix) < 0 or mix == null) return false;
        defer CoTaskMemFree(mix);
        const m = mix.?;
        const is_ext = m.tag == WAVE_FORMAT_EXTENSIBLE and m.cb_size >= 22;
        const is_float = (m.tag == WAVE_FORMAT_IEEE_FLOAT or (is_ext and m.sub_format.d1 == WAVE_FORMAT_IEEE_FLOAT)) and m.bits == 32;
        const is_i16 = (m.tag == WAVE_FORMAT_PCM or (is_ext and m.sub_format.d1 == WAVE_FORMAT_PCM)) and m.bits == 16;
        var own: WaveFormatEx = undefined;
        var fmt: *const WaveFormatEx = m;
        var flags: u32 = AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
        if (is_float or is_i16) {
            self.sample = if (is_float) .f32 else .i16;
            self.channels = m.channels;
        } else {
            // Unusual mix format: ask for float stereo and let WASAPI convert.
            own = .{
                .tag = WAVE_FORMAT_EXTENSIBLE,
                .channels = 2,
                .rate = m.rate,
                .avg_bytes = m.rate * 8,
                .block_align = 8,
                .bits = 32,
                .cb_size = 22,
                .valid_bits = 32,
                .channel_mask = 0x3, // FL | FR
                .sub_format = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT,
            };
            fmt = &own;
            self.sample = .f32;
            self.channels = 2;
            flags |= AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
            v3 = false;
        }
        const rate = fmt.rate;

        var period: u32 = 0;
        var initialized = false;
        if (v3) {
            var def: u32 = 0;
            var fund: u32 = 0;
            var min: u32 = 0;
            var max: u32 = 0;
            if (client.vtbl.GetSharedModeEnginePeriod(client, fmt, &def, &fund, &min, &max) >= 0 and fund != 0) {
                var want = if (self.want_frames != 0) self.want_frames else min;
                want = std.math.clamp(want, min, max);
                period = (want + fund - 1) / fund * fund;
                if (period > max) period = max;
                initialized = client.vtbl.InitializeSharedAudioStream(client, flags, period, fmt, null) >= 0;
            }
        }
        if (!initialized) {
            var def_period: i64 = 0;
            _ = client.vtbl.GetDevicePeriod(client, &def_period, null);
            // Buffer duration 0 → the engine's minimum for the default period.
            if (client.vtbl.Initialize(client, AUDCLNT_SHAREMODE_SHARED, flags, 0, 0, fmt, null) < 0) return false;
            period = @intCast(@divTrunc(@max(def_period, 1) * rate + 5_000_000, 10_000_000));
        }
        if (client.vtbl.SetEventHandle(client, self.buffer_event.?) < 0) return false;
        if (client.vtbl.GetBufferSize(client, &self.buffer_frames) < 0) return false;
        var rc: ?*anyopaque = null;
        if (client.vtbl.GetService(client, &IID_IAudioRenderClient, &rc) < 0 or rc == null) return false;
        self.render_client = @ptrCast(@alignCast(rc.?));
        self.target_frames = @min(self.buffer_frames, @max(period, 1) * 2);
        var stream_latency: i64 = 0;
        _ = client.vtbl.GetStreamLatency(client, &stream_latency);
        self.engine.mixer.setRate(rate);
        self.info = .{
            .rate = rate,
            .channels = self.channels,
            .period_frames = period,
            .latency_ns = @as(u64, self.target_frames) * std.time.ns_per_s / rate + @as(u64, @intCast(@max(stream_latency, 0))) * 100,
        };
        log.info("audio: WASAPI {s}: {d} Hz, {d} ch {s}, period {d}, buffer {d} frames", .{
            if (initialized) "IAudioClient3 low-latency" else "IAudioClient", rate, self.channels, @tagName(self.sample), period, self.buffer_frames,
        });
        return true;
    }

    /// Tops the device buffer up to `target_frames`. Returns false when the
    /// device went away.
    fn fill(self: *Backend) bool {
        const c = self.client orelse return false;
        const r = self.render_client orelse return false;
        var padding: u32 = 0;
        if (c.vtbl.GetCurrentPadding(c, &padding) < 0) return false;
        if (padding >= self.target_frames) return true;
        const n = self.target_frames - padding;
        var data: ?[*]u8 = null;
        if (r.vtbl.GetBuffer(r, n, &data) < 0 or data == null) return false;
        const ch = self.channels;
        switch (self.sample) {
            .f32 => {
                const out: [*]f32 = @ptrCast(@alignCast(data.?));
                self.engine.render(f32, out[0 .. n * ch], n, ch);
            },
            .i16 => {
                const out: [*]i16 = @ptrCast(@alignCast(data.?));
                self.engine.render(i16, out[0 .. n * ch], n, ch);
            },
        }
        return r.vtbl.ReleaseBuffer(r, n, 0) >= 0;
    }

    /// Pre-fills (applying the pending play) and starts the stream.
    fn resume_(self: *Backend) bool {
        if (self.client == null) {
            self.releaseDevice();
            if (!self.openDevice()) return false;
        }
        if (!self.fill()) return false;
        return self.client.?.vtbl.Start(self.client.?) >= 0;
    }

    fn reopen(self: *Backend, running: bool) void {
        self.releaseDevice();
        if (!self.openDevice()) {
            log.warn("audio: no default output after a device change", .{});
            self.releaseDevice();
            self.engine.state.store(.suspended, .seq_cst);
            return;
        }
        if (running and !self.resume_()) self.engine.state.store(.suspended, .seq_cst);
    }

    fn run(self: *Backend) void {
        const co = CoInitializeEx(null, COINIT_MULTITHREADED);
        defer if (co >= 0) CoUninitialize();
        const mmcss = Mmcss.join();
        defer mmcss.leave();

        self.enumerator = createEnumerator();
        var ok = false;
        if (self.enumerator) |en| {
            self.notif_registered = en.vtbl.RegisterEndpointNotificationCallback(en, &self.notif) >= 0;
            ok = self.openDevice();
        }
        if (!ok) self.releaseDevice();
        self.open_ok.store(if (ok) 1 else 2, .release);
        self.ready.signal();
        if (ok) self.loop();

        self.releaseDevice();
        if (self.enumerator) |en| {
            if (self.notif_registered) _ = en.vtbl.UnregisterEndpointNotificationCallback(en, &self.notif);
            release(en);
        }
    }

    fn loop(self: *Backend) void {
        const e = self.engine;
        const handles = [2]w.HANDLE{ self.buffer_event.?, e.wake.impl.handle };
        while (!e.quit.load(.acquire)) {
            if (e.device_changed.swap(false, .acq_rel)) self.reopen(e.state.load(.seq_cst) == .running);
            if (e.state.load(.seq_cst) == .running) {
                _ = w.WaitForMultipleObjects(2, &handles, 0, 200);
                if (e.quit.load(.acquire)) break;
                if (!self.fill()) {
                    // Device invalidated/unplugged: reopen the default.
                    e.device_changed.store(true, .release);
                    continue;
                }
                if (e.trySuspend()) {
                    if (self.client) |c| {
                        _ = c.vtbl.Stop(c);
                        _ = c.vtbl.Reset(c);
                    }
                }
            } else {
                _ = e.wake.wait(null);
                if (e.quit.load(.acquire)) break;
                if (e.device_changed.load(.acquire)) continue;
                if (!e.hasPending()) continue;
                e.markRunning();
                if (!self.resume_()) {
                    e.state.store(.suspended, .seq_cst);
                    e.wake_requested_ns.store(0, .monotonic);
                    while (e.mixer.ring.pop()) |_| _ = e.stats.dropped.fetchAdd(1, .monotonic);
                    self.releaseDevice(); // retried on the next play()
                }
            }
        }
    }
};
