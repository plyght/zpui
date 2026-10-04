//! [appshots] The headed app's Appshot service (zeron `lib.rs`
//! `start_appshot_service` / `start_appshot_capture` / `deliver_appshot`,
//! `appshots/shortcut.rs` preferences and `appshots/linux/mod.rs`'s activation
//! socket).
//!
//! - The global hotkey (`captureAppshot`, default `ctrl-alt-space` on macOS,
//!   `mod-alt-space` elsewhere) is registered through `Platform.setGlobalHotkey`
//!   while Settings → Appshots → Capture Appshots is on and no shortcut is being
//!   recorded; it follows the settings live.
//! - Linux: `{data_dir}/appshot-activation.sock` (a datagram socket) lets
//!   `zeron appshot`, bound in the desktop's own Keyboard Shortcuts, trigger a
//!   capture when the desktop has no GlobalShortcuts portal.
//! - A press captures only while no Zeron window is focused (portals cannot tell
//!   which window they captured); presses made while a capture is in flight are
//!   coalesced. The capture's PNG is trimmed / decoded on a worker
//!   (`model.appshots.prepare`), then delivered to the first Shell window (reopening
//!   the main window when none is open; captures wait in a queue otherwise), and the
//!   app is brought to the front. Cancellations and self-captures are silent.

const std = @import("std");
const builtin = @import("builtin");
const zpui = @import("zpui");
const model = @import("zeron_model");
const sounds = @import("zeron_sounds");
const shell_mod = @import("../ui/shell/shell.zig");
const shell_appshots = @import("../ui/shell/appshots.zig");
const settings_store = @import("../ui/settings/store.zig");
const lifecycle = @import("../lifecycle/root.zig");

const App = zpui.App;
const Context = zpui.Context;
const Entity = zpui.Entity;
const pf = zpui.platform;
const appshots = model.appshots;
const Captured = appshots.Captured;
const Shell = shell_mod.Shell;
const log = std.log.scoped(.appshots);
var no_message: [0]u8 = .{};

/// App global holding the service entity.
pub const Global = struct {
    entity: Entity(Service),
    pub fn deinit(self: *Global, app: *App) void {
        self.entity.release(app);
    }
};

pub const Options = struct {
    io: std.Io,
    /// The activation socket's directory (Linux); null = no socket.
    data_dir: ?[]const u8 = null,
    /// `ZERON_DISABLE_SOUND`.
    sound_disabled: bool = false,
};

/// What a capture produced, for delivery (`Result<CapturedAppshot, CaptureError>`).
pub const Outcome = union(enum) {
    ok: Captured,
    /// Shown in the composer (owned).
    failed: []u8,
    /// Cancelled / self-capture: nothing to show.
    silent,
};

pub const Service = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    sound_disabled: bool,
    /// The registered hotkey (key in `key_buf`), null = none.
    registered: ?pf.GlobalHotkey = null,
    key_buf: [32]u8 = undefined,
    /// A shortcut is being recorded in Settings (`set_recording`).
    recording: bool = false,
    /// A capture is in flight; further presses coalesce into it.
    in_flight: bool = false,
    /// Captures that found no Shell window (`PENDING`).
    pending: std.ArrayList(Captured) = .empty,
    settings_sub: ?zpui.Subscription = null,
    prepare_task: zpui.Task(appshots.PrepareResult) = .none,
    /// Counters (tests / diagnostics).
    presses: usize = 0,
    captures_started: usize = 0,

    pub fn init(opts: Options, cx: *Context(Service)) !Service {
        return .{ .gpa = cx.gpa(), .io = opts.io, .sound_disabled = opts.sound_disabled };
    }

    pub fn deinit(self: *Service, app: *App) void {
        if (self.settings_sub) |*s| s.deinit();
        self.prepare_task.cancel();
        if (self.registered != null) app.platform.setGlobalHotkey(null, handler(app));
        for (self.pending.items) |*s| s.deinit(self.gpa, app);
        self.pending.deinit(self.gpa);
    }

    /// `capture_allowed`: enabled and not recording a shortcut.
    pub fn captureAllowed(self: *const Service, app: *App) bool {
        return appshots.is_desktop and settings_store.current(app).appshotsEnabled and !self.recording;
    }

    /// The hotkey the settings ask for (`Preferences::active`), key in `buf`.
    fn desired(self: *const Service, app: *App, buf: *[32]u8) ?pf.GlobalHotkey {
        if (!self.captureAllowed(app)) return null;
        const s = settings_store.current(app);
        return appshots.parseShortcut(s.keymap.captureAppshot, buf) orelse
            appshots.parseShortcut(@as(model.ShortcutId, .capture_appshot).defaultCombo(), buf);
    }

    /// Re-register when the enabled state, the combo or recording changed.
    pub fn sync(self: *Service, cx: *Context(Service)) void {
        var buf: [32]u8 = undefined;
        const want = self.desired(cx.app, &buf);
        const same = if (self.registered) |r| (if (want) |w| r.eql(w) else false) else want == null;
        if (same) return;
        if (want) |w| {
            @memcpy(self.key_buf[0..w.key.len], w.key);
            var copy = w;
            copy.key = self.key_buf[0..w.key.len];
            self.registered = copy;
        } else self.registered = null;
        cx.app.platform.setGlobalHotkey(self.registered, handler(cx.app));
    }

    pub fn setRecording(self: *Service, recording: bool, cx: *Context(Service)) void {
        if (self.recording == recording) return;
        self.recording = recording;
        self.sync(cx);
    }

    /// One press of the hotkey (or `zeron appshot`): `start_appshot_capture`.
    pub fn press(self: *Service, cx: *Context(Service)) void {
        self.presses += 1;
        if (!self.captureAllowed(cx.app)) return;
        // Coalesce presses made while a capture is in flight.
        if (self.in_flight) return;
        // Never capture while any Zeron window is focused.
        if (cx.app.activeWindow() != null) return;
        self.in_flight = true;
        self.captures_started += 1;
        cx.app.platform.captureActiveWindow(self.gpa, .{ .ctx = cx.app, .done = onCaptured, .pixels_ready = onPixelsReady });
    }

    fn onPixelsReady(ctx: ?*anyopaque) void {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const svc = get(app) orelse return;
        if (svc.read(app).sound_disabled) return;
        if (!settings_store.current(app).appshotSoundEnabled) return;
        app.playSound(sounds.appshot);
    }

    fn onCaptured(ctx: ?*anyopaque, gpa: std.mem.Allocator, result: *pf.WindowCaptureResult) void {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const svc = get(app) orelse return result.deinit(gpa);
        svc.update(app, Service.captured, .{ gpa, result });
    }

    fn captured(self: *Service, gpa: std.mem.Allocator, result: *pf.WindowCaptureResult, cx: *Context(Service)) void {
        switch (result.*) {
            .err => |e| {
                self.in_flight = false;
                const outcome: Outcome = switch (e) {
                    .cancelled, .self_capture => .silent,
                    else => .{ .failed = self.gpa.dupe(u8, appshots.errorMessage(e)) catch return result.deinit(gpa) },
                };
                result.deinit(gpa);
                self.deliver(outcome, cx);
            },
            .ok => |capture| {
                const job: PrepareJob = .{ .gpa = gpa, .capture = capture };
                result.* = .{ .err = .cancelled }; // moved into the job
                self.prepare_task = cx.spawn(job, Service.prepared) catch {
                    self.in_flight = false;
                    return;
                };
            },
        }
    }

    const PrepareJob = struct {
        gpa: std.mem.Allocator,
        capture: pf.WindowCapture,
        done: bool = false,

        pub fn run(self: *PrepareJob) appshots.PrepareResult {
            self.done = true;
            return appshots.prepare(self.gpa, &self.capture) catch .{ .err = &no_message };
        }
        pub fn discard(self: *PrepareJob, r: appshots.PrepareResult) void {
            var rr = r;
            switch (rr) {
                .ok => |*p| p.deinit(self.gpa),
                .err => |m| self.gpa.free(m),
            }
        }
        pub fn deinit(self: *PrepareJob) void {
            if (!self.done) self.capture.deinit(self.gpa);
        }
    };

    fn prepared(self: *Service, result: appshots.PrepareResult, cx: *Context(Service)) void {
        self.prepare_task.detach();
        self.in_flight = false;
        var r = result;
        const outcome: Outcome = switch (r) {
            .err => |m| blk: {
                if (m.len > 0) break :blk .{ .failed = m };
                break :blk .{ .failed = self.gpa.dupe(u8, "Could not stage the captured window.") catch return };
            },
            .ok => |*p| .{ .ok = appshots.finish(self.gpa, self.io, p) catch return },
        };
        self.deliver(outcome, cx);
    }

    /// `deliver_appshot` (takes `outcome`).
    pub fn deliver(self: *Service, outcome: Outcome, cx: *Context(Service)) void {
        const app = cx.app;
        if (outcome == .silent) return;
        var captures = self.pending;
        self.pending = .empty;
        defer captures.deinit(self.gpa);
        var failure: ?[]u8 = null;
        defer if (failure) |m| self.gpa.free(m);
        switch (outcome) {
            .ok => |shot| captures.append(self.gpa, shot) catch {
                var s = shot;
                s.deinit(self.gpa, app);
            },
            .failed => |m| failure = m,
            .silent => unreachable,
        }
        const win = shellWindow(app) orelse reopen: {
            const w = lifecycle.openMainWindow(app) orelse break :reopen null;
            break :reopen if (isShell(w)) w else null;
        };
        const w = win orelse {
            if (captures.items.len > 0) {
                log.warn("Appshot captured with no Zeron window; preserving {d} for the next delivery", .{captures.items.len});
                self.pending.appendSlice(self.gpa, captures.items) catch {
                    for (captures.items) |*s| s.deinit(self.gpa, app);
                };
            }
            return;
        };
        const any_captured = captures.items.len > 0;
        app.activate(true);
        w.activateWindow();
        const handle: zpui.WindowHandle(Shell) = .{ .id = w.id };
        for (captures.items) |shot| {
            if (handle.update(app, shell_appshots.receive, .{shot}) == null) {
                var s = shot;
                s.deinit(self.gpa, app);
            }
        }
        if (failure) |m| _ = handle.update(app, shell_appshots.showError, .{m});
        if (any_captured) app.platform.foregroundAfterCapture();
    }
};

fn isShell(w: *zpui.Window) bool {
    const root = w.root orelse return false;
    return root.entity.downcast(Shell) != null;
}

/// The front-most Shell window (`window_stack` order is not tracked: the main
/// window first, then any other).
fn shellWindow(app: *App) ?*zpui.Window {
    if (lifecycle.mainWindow(app)) |w| if (isShell(w)) return w;
    for (app.windows.items) |slot| if (slot) |w| if (!w.removed and isShell(w)) return w;
    return null;
}

fn handler(app: *App) pf.GlobalHotkeyHandler {
    return .{ .ctx = app, .func = onHotkey };
}

fn onHotkey(ctx: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    pressFromApp(app);
}

pub fn pressFromApp(app: *App) void {
    const svc = get(app) orelse return;
    svc.update(app, Service.press, .{});
}

pub fn get(app: *App) ?Entity(Service) {
    const g = app.tryGlobal(Global) orelse return null;
    return g.entity;
}

/// Settings → shortcut recording started / stopped (`appshots::set_recording`).
pub fn setRecording(app: *App, recording: bool) void {
    const svc = get(app) orelse return;
    svc.update(app, Service.setRecording, .{recording});
}

/// Start the service (`start_appshot_service`): hotkey registration following the
/// settings, plus the Linux activation socket.
pub fn install(app: *App, opts: Options) !void {
    const entity = try app.newWith(Service, Service.init, .{opts});
    try app.setGlobal(Global{ .entity = entity });
    const Sync = struct {
        fn onSettings(a: *App) void {
            const s = get(a) orelse return;
            s.update(a, Service.sync, .{});
        }
    };
    const sub = try app.observeGlobal(model.SettingsStore, {}, struct {
        fn f(_: void, a: *App) void {
            Sync.onSettings(a);
        }
    }.f);
    entity.update(app, struct {
        fn f(s: *Service, su: zpui.Subscription, cx: *Context(Service)) void {
            s.settings_sub = su;
            s.sync(cx);
        }
    }.f, .{sub});
    if (builtin.os.tag == .linux) if (opts.data_dir) |dir| startActivationSocket(app, opts.io, dir);
}

// ---------------------------------------------------------------------------------------
// Linux activation socket (`start_activation_socket` / `request_running_appshot`)
// ---------------------------------------------------------------------------------------

const linux = std.os.linux;

fn socketAddress(data_dir: []const u8) ?linux.sockaddr.un {
    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    const name = appshots.activation_socket;
    if (data_dir.len + 1 + name.len >= addr.path.len) return null;
    @memcpy(addr.path[0..data_dir.len], data_dir);
    addr.path[data_dir.len] = '/';
    @memcpy(addr.path[data_dir.len + 1 ..][0..name.len], name);
    return addr;
}

const Activation = struct {
    app: *App,
    fn run(ctx: *anyopaque) void {
        const a: *Activation = @ptrCast(@alignCast(ctx));
        const app = a.app;
        app.gpa.destroy(a);
        pressFromApp(app);
    }
    fn drop(ctx: *anyopaque) void {
        const a: *Activation = @ptrCast(@alignCast(ctx));
        a.app.gpa.destroy(a);
    }
};

fn startActivationSocket(app: *App, io: std.Io, data_dir: []const u8) void {
    if (builtin.os.tag != .linux) return;
    const addr = socketAddress(data_dir) orelse return;
    const T = struct {
        fn main(a: *App, sa: linux.sockaddr.un) void {
            // The socket belongs to this feature: a stale inode is removed so a
            // restarted Zeron becomes reachable.
            const path: [*:0]const u8 = @ptrCast(&sa.path);
            _ = linux.unlink(path);
            const rc = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
            if (linux.errno(rc) != .SUCCESS) return;
            const fd: linux.fd_t = @intCast(rc);
            defer _ = linux.close(fd);
            if (linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return;
            defer _ = linux.unlink(path);
            var buf: [32]u8 = undefined;
            while (true) {
                const n = linux.recvfrom(fd, &buf, buf.len, 0, null, null);
                switch (linux.errno(n)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => return,
                }
                if (n == 0) continue;
                const act = a.gpa.create(Activation) catch continue;
                act.* = .{ .app = a };
                a.executor.dispatcher.dispatchOnMainThread(.{ .ctx = act, .run = Activation.run, .drop = Activation.drop }, .high);
            }
        }
    };
    std.Io.Dir.cwd().createDirPath(io, data_dir) catch {};
    const t = std.Thread.spawn(.{}, T.main, .{ app, addr }) catch return;
    t.detach();
}

/// `zeron appshot`: ask the running headed Zeron to capture. Returns an error
/// message (static) on failure.
pub fn requestRunningAppshot(data_dir: []const u8) ?[]const u8 {
    if (builtin.os.tag != .linux) return appshots.errorMessage(.shortcut_unavailable);
    const addr = socketAddress(data_dir) orelse return "Could not reach a running Zeron instance for Appshot capture: path too long";
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return "Could not create Appshot activation socket.";
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const msg = "capture";
    const sent = linux.sendto(fd, msg, msg.len, 0, @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
    if (linux.errno(sent) != .SUCCESS) return "Could not reach a running Zeron instance for Appshot capture.";
    return null;
}
