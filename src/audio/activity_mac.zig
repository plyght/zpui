//! macOS activity monitor (see activity.zig). macOS 14.2+: CoreAudio
//! process objects, event-driven through property listeners. Older
//! systems: "is the default output/input device running somewhere".

const std = @import("std");
const ca = @import("ca.zig");
const sys = @import("sys.zig");
const activity = @import("activity.zig");
const ActivityMonitor = activity.ActivityMonitor;

const max_procs = 512;

const list_addr: ca.AudioObjectPropertyAddress = .{ .selector = ca.hw_process_object_list };
const run_out_addr: ca.AudioObjectPropertyAddress = .{ .selector = ca.process_is_running_output };
const run_in_addr: ca.AudioObjectPropertyAddress = .{ .selector = ca.process_is_running_input };
const def_out_addr: ca.AudioObjectPropertyAddress = .{ .selector = ca.hw_default_output_device };
const def_in_addr: ca.AudioObjectPropertyAddress = .{ .selector = ca.hw_default_input_device };
const somewhere_addr: ca.AudioObjectPropertyAddress = .{ .selector = ca.dev_is_running_somewhere };

pub const Monitor = struct {
    gpa: std.mem.Allocator,
    owner: *ActivityMonitor,
    process_api: bool,
    own_pid: u32,
    lock: sys.SpinLock = .{},
    // Process API: objects with listeners attached.
    procs: [max_procs]ca.AudioObjectID = undefined,
    n_procs: usize = 0,
    // Device fallback.
    out_dev: ca.AudioObjectID = 0,
    in_dev: ca.AudioObjectID = 0,
    other: bool = false,
    poll_thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = .init(false),
    wake: sys.Event = .{},

    pub fn open(gpa: std.mem.Allocator, owner: *ActivityMonitor) ?*Monitor {
        const self = gpa.create(Monitor) catch return null;
        self.* = .{
            .gpa = gpa,
            .owner = owner,
            .process_api = ca.AudioObjectHasProperty(ca.system_object, &list_addr) != 0,
            .own_pid = activity.ownPid(),
        };
        if (self.process_api) {
            _ = ca.AudioObjectAddPropertyListener(ca.system_object, &list_addr, onListChanged, self);
            self.lock.lock();
            self.syncProcesses();
            self.lock.unlock();
            return self;
        }
        self.wake.init() catch {
            gpa.destroy(self);
            return null;
        };
        _ = ca.AudioObjectAddPropertyListener(ca.system_object, &def_out_addr, onDefaultChanged, self);
        _ = ca.AudioObjectAddPropertyListener(ca.system_object, &def_in_addr, onDefaultChanged, self);
        self.lock.lock();
        self.retargetDevices();
        self.evaluateDevices();
        self.lock.unlock();
        // Our own engine counts as "running somewhere" on the output device,
        // so while it runs the value is held; a 1 Hz check picks the real
        // value up once it suspends.
        if (owner.opts.audio != null) {
            self.poll_thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, pollLoop, .{self}) catch null;
        }
        return self;
    }

    pub fn close(self: *Monitor) void {
        if (self.process_api) {
            _ = ca.AudioObjectRemovePropertyListener(ca.system_object, &list_addr, onListChanged, self);
            self.lock.lock();
            for (self.procs[0..self.n_procs]) |p| removeProcListeners(p, self);
            self.n_procs = 0;
            self.lock.unlock();
        } else {
            self.quit.store(true, .release);
            self.wake.signal();
            if (self.poll_thread) |t| t.join();
            _ = ca.AudioObjectRemovePropertyListener(ca.system_object, &def_out_addr, onDefaultChanged, self);
            _ = ca.AudioObjectRemovePropertyListener(ca.system_object, &def_in_addr, onDefaultChanged, self);
            self.lock.lock();
            self.setDevices(0, 0);
            self.lock.unlock();
            self.wake.deinit();
        }
        self.gpa.destroy(self);
    }

    // --- macOS 14.2+ process objects -------------------------------------

    fn removeProcListeners(p: ca.AudioObjectID, self: *Monitor) void {
        _ = ca.AudioObjectRemovePropertyListener(p, &run_out_addr, onProcChanged, self);
        _ = ca.AudioObjectRemovePropertyListener(p, &run_in_addr, onProcChanged, self);
    }

    /// Re-reads the process list, attaches listeners to new process objects,
    /// detaches from vanished ones, and publishes. Holds `lock`.
    fn syncProcesses(self: *Monitor) void {
        var ids: [max_procs]ca.AudioObjectID = undefined;
        var size: u32 = @sizeOf(@TypeOf(ids));
        var n: usize = 0;
        if (ca.AudioObjectGetPropertyData(ca.system_object, &list_addr, 0, null, &size, @ptrCast(&ids)) == 0) n = size / @sizeOf(ca.AudioObjectID);
        // Detach from objects that are gone.
        var keep: usize = 0;
        for (self.procs[0..self.n_procs]) |p| {
            if (std.mem.indexOfScalar(ca.AudioObjectID, ids[0..n], p) != null) {
                self.procs[keep] = p;
                keep += 1;
            } else removeProcListeners(p, self);
        }
        self.n_procs = keep;
        // Attach to new ones (skipping our own process).
        for (ids[0..n]) |p| {
            if (std.mem.indexOfScalar(ca.AudioObjectID, self.procs[0..self.n_procs], p) != null) continue;
            if (self.n_procs >= max_procs) break;
            const pid = ca.get(i32, p, .{ .selector = ca.process_pid }) orelse continue;
            if (pid == @as(i32, @intCast(self.own_pid))) continue;
            _ = ca.AudioObjectAddPropertyListener(p, &run_out_addr, onProcChanged, self);
            _ = ca.AudioObjectAddPropertyListener(p, &run_in_addr, onProcChanged, self);
            self.procs[self.n_procs] = p;
            self.n_procs += 1;
        }
        self.evaluateProcesses();
    }

    fn evaluateProcesses(self: *Monitor) void {
        var a: activity.Activity = .{};
        for (self.procs[0..self.n_procs]) |p| {
            if ((ca.get(u32, p, run_out_addr) orelse 0) != 0) a.other_audio = true;
            if ((ca.get(u32, p, run_in_addr) orelse 0) != 0) a.mic_in_use = true;
        }
        self.owner.publish(a);
    }

    fn onListChanged(_: ca.AudioObjectID, _: u32, _: [*]const ca.AudioObjectPropertyAddress, client: ?*anyopaque) callconv(.c) ca.OSStatus {
        const self: *Monitor = @ptrCast(@alignCast(client.?));
        self.lock.lock();
        defer self.lock.unlock();
        self.syncProcesses();
        return 0;
    }

    fn onProcChanged(_: ca.AudioObjectID, _: u32, _: [*]const ca.AudioObjectPropertyAddress, client: ?*anyopaque) callconv(.c) ca.OSStatus {
        const self: *Monitor = @ptrCast(@alignCast(client.?));
        self.lock.lock();
        defer self.lock.unlock();
        self.evaluateProcesses();
        return 0;
    }

    // --- Fallback: default devices "running somewhere" --------------------

    fn setDevices(self: *Monitor, out: ca.AudioObjectID, in: ca.AudioObjectID) void {
        if (out != self.out_dev) {
            if (self.out_dev != 0) _ = ca.AudioObjectRemovePropertyListener(self.out_dev, &somewhere_addr, onDeviceRunning, self);
            if (out != 0) _ = ca.AudioObjectAddPropertyListener(out, &somewhere_addr, onDeviceRunning, self);
            self.out_dev = out;
        }
        if (in != self.in_dev) {
            if (self.in_dev != 0) _ = ca.AudioObjectRemovePropertyListener(self.in_dev, &somewhere_addr, onDeviceRunning, self);
            if (in != 0) _ = ca.AudioObjectAddPropertyListener(in, &somewhere_addr, onDeviceRunning, self);
            self.in_dev = in;
        }
    }

    fn retargetDevices(self: *Monitor) void {
        self.setDevices(
            ca.get(ca.AudioObjectID, ca.system_object, def_out_addr) orelse 0,
            ca.get(ca.AudioObjectID, ca.system_object, def_in_addr) orelse 0,
        );
    }

    fn evaluateDevices(self: *Monitor) void {
        // Output: only meaningful while our own engine is not running.
        if (self.owner.ownEngineIdle()) {
            self.other = self.out_dev != 0 and (ca.get(u32, self.out_dev, somewhere_addr) orelse 0) != 0;
        }
        // An input device used by another app is a call/recording (we never capture).
        const mic = self.in_dev != 0 and (ca.get(u32, self.in_dev, somewhere_addr) orelse 0) != 0;
        self.owner.publish(.{ .other_audio = self.other, .mic_in_use = mic });
    }

    fn onDefaultChanged(_: ca.AudioObjectID, _: u32, _: [*]const ca.AudioObjectPropertyAddress, client: ?*anyopaque) callconv(.c) ca.OSStatus {
        const self: *Monitor = @ptrCast(@alignCast(client.?));
        self.lock.lock();
        defer self.lock.unlock();
        self.retargetDevices();
        self.evaluateDevices();
        return 0;
    }

    fn onDeviceRunning(_: ca.AudioObjectID, _: u32, _: [*]const ca.AudioObjectPropertyAddress, client: ?*anyopaque) callconv(.c) ca.OSStatus {
        const self: *Monitor = @ptrCast(@alignCast(client.?));
        self.lock.lock();
        defer self.lock.unlock();
        self.evaluateDevices();
        return 0;
    }

    fn pollLoop(self: *Monitor) void {
        var was_idle = self.owner.ownEngineIdle();
        while (!self.quit.load(.acquire)) {
            _ = self.wake.wait(std.time.ns_per_s);
            if (self.quit.load(.acquire)) break;
            const idle = self.owner.ownEngineIdle();
            // Only work on the running → suspended edge (the listener covers
            // changes while we are idle).
            if (idle and !was_idle) {
                self.lock.lock();
                self.evaluateDevices();
                self.lock.unlock();
            }
            was_idle = idle;
        }
    }
};
