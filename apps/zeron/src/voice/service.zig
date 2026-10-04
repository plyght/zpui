//! The app half of dictation — zeron `crates/ui/src/dictation.rs` `Native`
//! (`start`, `permission`, `origin_window`) and `dictation/model.rs`
//! `VoiceCard` state (`init`, `directory`, `enabled`, download / remove /
//! microphone list) on top of the engine in this directory.
//!
//! `install` registers the `zeron_input` `dictation.Service` global, the
//! only path from the composer to the engine, and the `VoiceGlobal`
//! (`Entity(VoiceModel)`) the Settings → Voice page renders. Without an
//! ONNX Runtime library the microphone still appears once the model is
//! downloaded; pressing it ends in Rust's "Dictation unavailable" state.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const zmodel = @import("zeron_model");
const input_mod = @import("zeron_input");
const engine = @import("root.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const App = zpui.App;
const Entity = zpui.Entity;
const Context = zpui.Context;
const dict = input_mod.dictation;
const session = engine.session;
const model_files = engine.model;
const capture = engine.capture;
const mac = if (builtin.os.tag == .macos) @import("capture_mac.zig") else struct {};

const log = std.log.scoped(.zeron_voice);

/// Rust copy, surfaced verbatim.
pub const msg = struct {
    pub const packaged = "Dictation requires the packaged Zeron app.";
    pub const denied = "Allow Microphone access for Zeron in System Settings \u{2192} Privacy & Security, then retry.";
    pub const cancelled_download = "Download cancelled.";
    pub const download_failed = "Couldn\u{2019}t download or verify the model. Check your connection and free storage, then retry.";
    pub const download_interrupted = "Download interrupted. Try again.";
    pub const remove_busy = "Stop dictation before removing the model.";
    pub const remove_failed = "Could not remove the model. Check folder permissions and retry.";
};

// ---- permission (dictation.rs `permission` / `origin_window`) ----------------------------

/// 1 authorized, 0 not determined, -1 denied, -2 not a packaged app.
pub fn permission() i32 {
    return if (builtin.os.tag == .macos) mac.microphonePermission() else 1;
}

pub fn permissionPending() bool {
    return permission() == 0;
}

fn originWindow() usize {
    return if (builtin.os.tag == .macos) mac.microphoneWindow() else 1;
}

// ---- Native transcriber -----------------------------------------------------------------

/// Rust `Native`: waits for the permission answer, then starts a voice
/// session on the worker and relays its events.
pub const Native = struct {
    gpa: Allocator,
    io: Io,
    pending_final: bool = false,
    origin_window: usize,
    dir: []u8,
    device: ?[]u8,
    sess: ?session.Session = null,
    finished: bool = false,
    /// Strings of the event handed out last (valid until the next poll).
    last: ?session.Event = null,

    const vtable: dict.Transcriber.VTable = .{ .poll = poll, .finish = finish, .level = level, .deinit = deinit };

    pub fn transcriber(self: *Native) dict.Transcriber {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn dropLast(self: *Native) void {
        if (self.last) |e| e.deinit(self.gpa);
        self.last = null;
    }

    fn poll(ctx: *anyopaque) ?dict.Event {
        const self: *Native = @ptrCast(@alignCast(ctx));
        self.dropLast();
        if (self.pending_final) {
            self.pending_final = false;
            return .{ .final = "" };
        }
        if (self.finished) return null;
        if (self.sess == null) {
            switch (permission()) {
                0 => return null,
                -2 => {
                    self.finished = true;
                    return .{ .unavailable = msg.packaged };
                },
                -1 => {
                    self.finished = true;
                    return .{ .denied = msg.denied };
                },
                else => {},
            }
            if (self.origin_window == 0 or originWindow() != self.origin_window) {
                self.finished = true;
                return .cancelled;
            }
            // The native runtime is optional at build time and loaded off
            // the UI thread; without it dictation is unavailable.
            engine.ort.warm();
            const have = engine.ort.tryAvailable() orelse return null;
            if (!have) {
                self.finished = true;
                return .{ .unavailable = msg.packaged };
            }
            self.sess = session.Session.start(self.gpa, self.io, self.dir, self.device) catch |e| {
                self.finished = true;
                return .{ .failed = if (e == error.Busy) session.msg.busy else session.msg.worker };
            };
        }
        const ev = self.sess.?.poll() orelse return null;
        self.last = ev;
        return switch (ev) {
            .listening => .listening,
            .finalizing => .finalizing,
            .final => |t| .{ .final = t },
            .failed => |t| .{ .failed = t },
        };
    }

    fn finish(ctx: *anyopaque) void {
        const self: *Native = @ptrCast(@alignCast(ctx));
        if (self.sess) |*s| {
            s.finish();
        } else {
            self.finished = true;
            self.pending_final = true;
        }
    }

    fn level(ctx: *anyopaque) f32 {
        const self: *Native = @ptrCast(@alignCast(ctx));
        return if (self.sess) |*s| s.takeLevel() else 0;
    }

    /// Drop: cancels capture and any pending result.
    fn deinit(ctx: *anyopaque) void {
        const self: *Native = @ptrCast(@alignCast(ctx));
        self.dropLast();
        if (self.sess) |*s| s.deinit();
        self.gpa.free(self.dir);
        if (self.device) |d| self.gpa.free(d);
        self.gpa.destroy(self);
    }
};

// ---- the voice model entity (`VoiceCard` state) ------------------------------------------

/// `INPUT_REFRESH`: microphones are rescanned this often while visible.
pub const input_refresh_ns: u64 = 3 * std.time.ns_per_s;

const Download = struct {
    cancel: std.atomic.Value(bool) = .init(false),
    progress: std.atomic.Value(u64) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    failed: bool = false,
};

const Scan = struct {
    gpa: Allocator,

    pub const Result = struct { devices: []capture.InputDevice, default: ?[]u8 };

    pub fn run(self: *Scan) Result {
        return .{ .devices = capture.inputDevices(self.gpa), .default = capture.defaultInputDevice(self.gpa) };
    }

    pub fn discard(self: *Scan, r: Result) void {
        capture.freeDevices(self.gpa, r.devices);
        if (r.default) |d| self.gpa.free(d);
    }
};

pub const VoiceModel = struct {
    gpa: Allocator,
    io: Io,
    environ: ?*const std.process.Environ.Map,
    /// `{data_dir}/models/parakeet-tdt-0.6b-v3-int8`.
    directory: []u8,
    ready: bool,
    cache_present: bool,
    download: ?*Download = null,
    download_task: zpui.Task(void) = .none,
    progress: u64 = 0,
    err: ?[]const u8 = null,
    // ---- microphones (`Inputs`) ----
    devices: []capture.InputDevice = &.{},
    default_device: ?[]u8 = null,
    checked: ?u64 = null,
    scan_task: zpui.Task(Scan.Result) = .none,
    expire_task: zpui.Task(void) = .none,
    scanning: bool = false,

    pub fn init(io: Io, environ: ?*const std.process.Environ.Map, directory: []const u8, cx: *Context(VoiceModel)) !VoiceModel {
        const dir = try cx.gpa().dupe(u8, directory);
        return .{
            .gpa = cx.gpa(),
            .io = io,
            .environ = environ,
            .directory = dir,
            .ready = model_files.installed(io, dir),
            .cache_present = model_files.present(io, dir),
        };
    }

    pub fn deinit(self: *VoiceModel, _: *App) void {
        if (self.download) |d| d.cancel.store(true, .release); // the thread owns `d` from here
        self.download_task.cancel();
        self.scan_task.cancel();
        self.expire_task.cancel();
        capture.freeDevices(self.gpa, self.devices);
        if (self.default_device) |d| self.gpa.free(d);
        self.gpa.free(self.directory);
    }

    pub fn downloading(self: *const VoiceModel) bool {
        return self.download != null;
    }

    fn setEnabled(on: bool, cx: anytype) void {
        const F = struct {
            fn f(v: bool, s: *zmodel.UiSettings, _: Allocator) void {
                s.dictationEnabled = v;
            }
        };
        _ = zmodel.settings_store.update(cx.app, .immediate, on, F.f);
        cx.app.refreshWindows();
    }

    /// `VoiceCard::primary`: the Dictation switch — cancels a download,
    /// toggles dictation once the model is ready, else downloads it.
    pub fn primary(self: *VoiceModel, cx: *Context(VoiceModel)) void {
        if (self.download) |d| {
            d.cancel.store(true, .release);
        } else if (self.ready) {
            const on = if (zmodel.settings_store.current(cx.app)) |s| s.dictationEnabled else false;
            setEnabled(!on, cx);
        } else self.startDownload(cx);
        cx.notify();
        cx.app.refreshWindows();
    }

    const Worker = struct {
        fn run(gpa: Allocator, io: Io, environ: ?*const std.process.Environ.Map, dir: []u8, d: *Download) void {
            defer gpa.free(dir);
            model_files.download(gpa, io, environ, dir, &d.cancel, &d.progress) catch |e| {
                log.warn("model download: {t}", .{e});
                d.failed = true;
            };
            d.done.store(true, .release);
        }
    };

    fn startDownload(self: *VoiceModel, cx: *Context(VoiceModel)) void {
        if (self.download != null) return;
        self.err = null;
        self.progress = 0;
        const d = self.gpa.create(Download) catch return;
        d.* = .{};
        const dir = self.gpa.dupe(u8, self.directory) catch {
            self.gpa.destroy(d);
            return;
        };
        const t = std.Thread.spawn(.{}, Worker.run, .{ self.gpa, self.io, self.environ, dir, d }) catch {
            self.gpa.free(dir);
            self.gpa.destroy(d);
            self.err = msg.download_interrupted;
            return;
        };
        t.detach();
        self.download = d;
        self.download_task = cx.timer(100 * std.time.ns_per_ms, onDownloadTick) catch .none;
    }

    fn onDownloadTick(self: *VoiceModel, cx: *Context(VoiceModel)) void {
        self.download_task.detach();
        self.download_task = .none;
        const d = self.download orelse return;
        self.progress = d.progress.load(.acquire);
        if (d.done.load(.acquire)) {
            self.cache_present = model_files.present(self.io, self.directory);
            const cancelled = d.cancel.load(.acquire);
            if (!d.failed) {
                self.ready = true;
                setEnabled(!cancelled, cx);
            } else self.err = if (cancelled) msg.cancelled_download else msg.download_failed;
            self.download = null;
            self.gpa.destroy(d);
        } else {
            self.download_task = cx.timer(100 * std.time.ns_per_ms, onDownloadTick) catch .none;
        }
        cx.notify();
        cx.app.refreshWindows();
    }

    /// `VoiceCard::remove`: free the model (never mid-dictation).
    pub fn remove(self: *VoiceModel, cx: *Context(VoiceModel)) void {
        defer {
            cx.notify();
            cx.app.refreshWindows();
        }
        if (session.busy()) {
            self.err = msg.remove_busy;
            return;
        }
        setEnabled(false, cx);
        session.unload();
        model_files.remove(self.io, self.directory) catch {
            self.err = msg.remove_failed;
            return;
        };
        self.cache_present = false;
        self.ready = false;
        self.progress = 0;
        self.err = null;
    }

    /// `refresh_inputs`: rescan microphones off the UI thread while the
    /// page is visible (at most every `input_refresh_ns`).
    pub fn refreshInputs(self: *VoiceModel, cx: *Context(VoiceModel)) void {
        if (self.scanning) return;
        if (self.checked) |at| if (cx.app.executor.now() -| at < input_refresh_ns) return;
        self.scanning = true;
        self.scan_task = cx.spawn(Scan{ .gpa = self.gpa }, onScanned) catch {
            self.scanning = false;
            return;
        };
    }

    fn onScanned(self: *VoiceModel, r: Scan.Result, cx: *Context(VoiceModel)) void {
        self.scan_task.detach();
        self.scan_task = .none;
        const changed = !sameDevices(self.devices, r.devices) or !std.meta.eql(self.default_device == null, r.default == null) or
            (self.default_device != null and !std.mem.eql(u8, self.default_device.?, r.default.?));
        capture.freeDevices(self.gpa, self.devices);
        if (self.default_device) |d| self.gpa.free(d);
        self.devices = r.devices;
        self.default_device = r.default;
        self.checked = cx.app.executor.now();
        if (changed) {
            cx.notify();
            cx.app.refreshWindows();
        }
        // Invalidate once when the scan expires; only a visible page starts
        // the next scan, so leaving Settings stops polling devices.
        self.expire_task = cx.timer(input_refresh_ns, onScanExpired) catch .none;
    }

    fn onScanExpired(self: *VoiceModel, cx: *Context(VoiceModel)) void {
        self.expire_task.detach();
        self.expire_task = .none;
        self.scanning = false;
        cx.app.refreshWindows();
    }

    /// Replace the device list (tests).
    pub fn setDevices(self: *VoiceModel, devices: []const struct { []const u8, []const u8 }) !void {
        capture.freeDevices(self.gpa, self.devices);
        const list = try self.gpa.alloc(capture.InputDevice, devices.len);
        for (devices, list) |d, *out| out.* = .{ .id = try self.gpa.dupe(u8, d[0]), .name = try self.gpa.dupe(u8, d[1]) };
        self.devices = list;
    }

    pub const InputOption = struct { label: []const u8, detail: ?[]const u8 = null };

    /// `input_options`: "System default" (+ the default device's name), the
    /// devices, and — for a saved device that is unplugged — "Disconnected
    /// microphone", so the choice stays visible; plus the selected index.
    /// Strings borrow from the model (and `a` for the list).
    pub fn inputOptions(self: *const VoiceModel, a: Allocator, saved: ?[]const u8) struct { []InputOption, usize } {
        var list: std.ArrayList(InputOption) = .empty;
        var default_name: ?[]const u8 = null;
        if (self.default_device) |id| for (self.devices) |d| if (std.mem.eql(u8, d.id, id)) {
            default_name = d.name;
            break;
        };
        list.append(a, .{ .label = "System default", .detail = default_name }) catch {};
        for (self.devices) |d| list.append(a, .{ .label = d.name }) catch {};
        const selected: usize = if (saved) |id| blk: {
            for (self.devices, 0..) |d, i| if (std.mem.eql(u8, d.id, id)) break :blk i + 1;
            list.append(a, .{ .label = "Disconnected microphone" }) catch {};
            break :blk list.items.len - 1;
        } else 0;
        return .{ list.items, selected };
    }

    /// The device id for option `ix` (null: system default; the trailing
    /// "Disconnected microphone" keeps the saved id).
    pub fn inputIdAt(self: *const VoiceModel, ix: usize, saved: ?[]const u8) ?[]const u8 {
        if (ix == 0) return null;
        if (ix - 1 < self.devices.len) return self.devices[ix - 1].id;
        return saved;
    }
};

fn sameDevices(a: []const capture.InputDevice, b: []const capture.InputDevice) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x.id, y.id) or !std.mem.eql(u8, x.name, y.name)) return false;
    return true;
}

/// `VoiceGlobal`.
pub const VoiceGlobal = struct {
    model: Entity(VoiceModel),
    gpa: Allocator,
    io: Io,

    pub fn deinit(self: *VoiceGlobal, app: *App) void {
        self.model.release(app);
    }
};

/// The voice model (null before `install`).
pub fn voiceModel(app: *App) ?Entity(VoiceModel) {
    const g = app.tryGlobal(VoiceGlobal) orelse return null;
    return g.model;
}

// ---- dictation.Service ------------------------------------------------------------------

fn enabledFn(_: ?*anyopaque, app: *App) bool {
    const s = zmodel.settings_store.current(app) orelse return false;
    if (!s.dictationEnabled) return false;
    const m = voiceModel(app) orelse return false;
    return m.read(app).ready;
}

fn startFn(_: ?*anyopaque, app: *App) ?dict.Transcriber {
    const g = app.tryGlobal(VoiceGlobal) orelse return null;
    const vm = g.model.read(app);
    const origin = originWindow();
    if (builtin.os.tag == .macos and permission() == 0) mac.requestMicrophone();
    const n = g.gpa.create(Native) catch return null;
    const dir = g.gpa.dupe(u8, vm.directory) catch {
        g.gpa.destroy(n);
        return null;
    };
    const saved = if (zmodel.settings_store.current(app)) |s| s.dictationInput else null;
    const device = if (saved) |d| g.gpa.dupe(u8, d) catch null else null;
    n.* = .{ .gpa = g.gpa, .io = g.io, .origin_window = origin, .dir = dir, .device = device };
    return n.transcriber();
}

fn permissionPendingFn(_: ?*anyopaque) bool {
    return permissionPending();
}

fn bindingFn(_: ?*anyopaque, app: *App, buf: []u8) []const u8 {
    const id: zmodel.settings.ShortcutId = .toggle_dictation;
    const combo = if (zmodel.settings_store.current(app)) |s| s.keymap.toggleDictation else id.defaultCombo();
    // Mirror `apply_keymap`, which binds the default for an unparseable combo.
    var scratch: [128]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&scratch);
    const platform = zmodel.settings.platformCombo(buf, combo);
    if (zpui.core.parseKeystroke(fba.allocator(), platform)) |_| return platform else |_| {}
    return zmodel.settings.platformCombo(buf, id.defaultCombo());
}

/// Rust `dictation::model::init` + the transcriber factory: install the
/// voice globals. `data_dir` null (fixture runs) keeps the model under the
/// temp dir, never ready unless downloaded there.
pub fn install(app: *App, io: Io, environ: ?*const std.process.Environ.Map, data_dir: ?[]const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = data_dir orelse "/tmp/zeron-voice";
    const dir = std.fmt.bufPrint(&buf, "{s}/models/{s}", .{ root, model_files.directory_name }) catch return;
    const m = app.newWith(VoiceModel, VoiceModel.init, .{ io, environ, dir }) catch |e| {
        log.warn("voice: {t}", .{e});
        return;
    };
    app.setGlobal(VoiceGlobal{ .model = m, .gpa = app.gpa, .io = io }) catch return;
    app.setGlobal(dict.Service{
        .enabled = enabledFn,
        .start = startFn,
        .permission_pending = permissionPendingFn,
        .binding = bindingFn,
    }) catch return;
}

test {
    _ = Native;
    _ = VoiceModel;
}
