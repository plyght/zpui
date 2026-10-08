//! Windows activity monitor (see activity.zig): polls WASAPI audio sessions
//! at 1 Hz on its own MTA thread. Other audio = an Active session of another
//! process on the default render endpoint whose peak meter exceeds −60 dBFS
//! (browsers keep paused sessions Active, so state alone is not enough),
//! debounced so pauses between sounds don't flicker. Mic in use = an Active
//! capture session of another process on the default console or
//! communications capture endpoint (chosen over the CapabilityAccessManager
//! registry heuristic: no stale entries after crashes, and it sees only
//! what is actually recording now).

const std = @import("std");
const sys = @import("sys.zig");
const wa = @import("wasapi.zig");
const activity = @import("activity.zig");
const ActivityMonitor = activity.ActivityMonitor;
const GUID = wa.GUID;
const HRESULT = wa.HRESULT;
const Slot = ?*const anyopaque;

const IID_IAudioSessionManager2 = GUID.parse("77aa99a0-1bd6-484f-8bc7-2c654c9a9b6f");
const IID_IAudioSessionControl2 = GUID.parse("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d");
const IID_IAudioMeterInformation = GUID.parse("c02216f6-8c67-4b5b-9d00-d008e73e0064");
const AudioSessionStateActive: u32 = 1;
const peak_threshold: f32 = 0.001; // −60 dBFS

const IAudioSessionManager2 = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IAudioSessionManager2) callconv(.winapi) u32,
        GetAudioSessionControl: Slot,
        GetSimpleAudioVolume: Slot,
        GetSessionEnumerator: *const fn (*IAudioSessionManager2, *?*IAudioSessionEnumerator) callconv(.winapi) HRESULT,
        RegisterSessionNotification: Slot,
        UnregisterSessionNotification: Slot,
        RegisterDuckNotification: Slot,
        UnregisterDuckNotification: Slot,
    };
};

const IAudioSessionEnumerator = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IAudioSessionEnumerator) callconv(.winapi) u32,
        GetCount: *const fn (*IAudioSessionEnumerator, *i32) callconv(.winapi) HRESULT,
        GetSession: *const fn (*IAudioSessionEnumerator, i32, *?*IAudioSessionControl2) callconv(.winapi) HRESULT,
    };
};

/// IAudioSessionControl + IAudioSessionControl2 (GetSession returns the
/// former; we QueryInterface for the latter before using its methods).
const IAudioSessionControl2 = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: *const fn (*IAudioSessionControl2, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: Slot,
        Release: *const fn (*IAudioSessionControl2) callconv(.winapi) u32,
        GetState: *const fn (*IAudioSessionControl2, *u32) callconv(.winapi) HRESULT,
        GetDisplayName: Slot,
        SetDisplayName: Slot,
        GetIconPath: Slot,
        SetIconPath: Slot,
        GetGroupingParam: Slot,
        SetGroupingParam: Slot,
        RegisterAudioSessionNotification: Slot,
        UnregisterAudioSessionNotification: Slot,
        GetSessionIdentifier: Slot,
        GetSessionInstanceIdentifier: Slot,
        GetProcessId: *const fn (*IAudioSessionControl2, *u32) callconv(.winapi) HRESULT,
        IsSystemSoundsSession: *const fn (*IAudioSessionControl2) callconv(.winapi) HRESULT,
        SetDuckingPreference: Slot,
    };
};

const IAudioMeterInformation = extern struct {
    vtbl: *const Vtbl,
    const Vtbl = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IAudioMeterInformation) callconv(.winapi) u32,
        GetPeakValue: *const fn (*IAudioMeterInformation, *f32) callconv(.winapi) HRESULT,
    };
};

const Flow = enum { render, capture };

pub const Monitor = struct {
    gpa: std.mem.Allocator,
    owner: *ActivityMonitor,
    thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = .init(false),
    wake: sys.Event = .{},
    own_pid: u32,
    other: activity.Debounce = .{ .on_after = 1, .off_after = 3 },

    pub fn open(gpa: std.mem.Allocator, owner: *ActivityMonitor) ?*Monitor {
        const self = gpa.create(Monitor) catch return null;
        self.* = .{ .gpa = gpa, .owner = owner, .own_pid = activity.ownPid() };
        self.wake.init() catch {
            gpa.destroy(self);
            return null;
        };
        self.thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, run, .{self}) catch {
            self.wake.deinit();
            gpa.destroy(self);
            return null;
        };
        return self;
    }

    pub fn close(self: *Monitor) void {
        self.quit.store(true, .release);
        self.wake.signal();
        if (self.thread) |t| t.join();
        self.wake.deinit();
        self.gpa.destroy(self);
    }

    fn run(self: *Monitor) void {
        const co = wa.CoInitializeEx(null, wa.COINIT_MULTITHREADED);
        defer if (co >= 0) wa.CoUninitialize();
        const en = wa.createEnumerator() orelse return;
        defer wa.release(en);
        while (!self.quit.load(.acquire)) {
            const playing = self.scan(en, wa.eRender, wa.eConsole, .render);
            const mic = self.scan(en, wa.eCapture, wa.eConsole, .capture) or
                self.scan(en, wa.eCapture, wa.eCommunications, .capture);
            self.owner.publish(.{ .other_audio = self.other.update(playing), .mic_in_use = mic });
            _ = self.wake.wait(std.time.ns_per_s);
        }
    }

    /// True if an Active session of another process exists on the default
    /// endpoint for (flow, role) — for render, one that is audible.
    fn scan(self: *Monitor, en: *wa.IMMDeviceEnumerator, flow: u32, role: u32, kind: Flow) bool {
        var dev: ?*wa.IMMDevice = null;
        if (en.vtbl.GetDefaultAudioEndpoint(en, flow, role, &dev) < 0 or dev == null) return false;
        defer wa.release(dev.?);
        var p: ?*anyopaque = null;
        if (dev.?.vtbl.Activate(dev.?, &IID_IAudioSessionManager2, wa.CLSCTX_ALL, null, &p) < 0 or p == null) return false;
        const mgr: *IAudioSessionManager2 = @ptrCast(@alignCast(p.?));
        defer wa.release(mgr);
        var sessions: ?*IAudioSessionEnumerator = null;
        if (mgr.vtbl.GetSessionEnumerator(mgr, &sessions) < 0 or sessions == null) return false;
        const se = sessions.?;
        defer wa.release(se);
        var count: i32 = 0;
        if (se.vtbl.GetCount(se, &count) < 0) return false;
        var i: i32 = 0;
        while (i < count) : (i += 1) {
            var ctl1: ?*IAudioSessionControl2 = null;
            if (se.vtbl.GetSession(se, i, &ctl1) < 0 or ctl1 == null) continue;
            defer wa.release(ctl1.?);
            var state: u32 = 0;
            if (ctl1.?.vtbl.GetState(ctl1.?, &state) < 0 or state != AudioSessionStateActive) continue;
            var q: ?*anyopaque = null;
            if (ctl1.?.vtbl.QueryInterface(ctl1.?, &IID_IAudioSessionControl2, &q) < 0 or q == null) continue;
            const ctl: *IAudioSessionControl2 = @ptrCast(@alignCast(q.?));
            defer wa.release(ctl);
            if (ctl.vtbl.IsSystemSoundsSession(ctl) == wa.S_OK) continue;
            var pid: u32 = 0;
            _ = ctl.vtbl.GetProcessId(ctl, &pid);
            if (pid == self.own_pid) continue;
            if (kind == .capture) return true;
            var m: ?*anyopaque = null;
            if (ctl.vtbl.QueryInterface(ctl, &IID_IAudioMeterInformation, &m) < 0 or m == null) continue;
            const meter: *IAudioMeterInformation = @ptrCast(@alignCast(m.?));
            defer wa.release(meter);
            var peak: f32 = 0;
            if (meter.vtbl.GetPeakValue(meter, &peak) >= 0 and peak > peak_threshold) return true;
        }
        return false;
    }
};
